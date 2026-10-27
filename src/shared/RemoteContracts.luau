--!strict
--[[
	RemoteContracts.luau
	Public network contract schemas, validation boundaries, and RemoteEvent identifiers.
	Task: CLAY-002 (Define Remote Contracts & Shared Config)

	SECURITY POLICY:
	1. Pure Movement Intent: Client sends moveDirection; server calculates and enforces position.
	2. Authoritative Firing Origin: Client sends weaponId and aimDirection; server determines origin from authoritative aircraft state.
	3. Strict Whitelist Schema: Unknown or illegal fields cause immediate rejection.
	4. Deep Details Validation: GameStateChanged.details is strictly checked against per-state schemas.
	5. Finite Value Verification: Non-finite values (NaN, Inf, -Inf) cause immediate rejection.
	6. Magnitude Limits: Analog input vectors are capped at 1.05 to prevent abnormal acceleration.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local WeaponConfig = require(SharedFolder:WaitForChild("WeaponConfig"))

export type MovePlanePayload = {
	contractVersion: string,
	clientTimestamp: number,
	moveDirection: Vector2,
}

export type FireWeaponPayload = {
	contractVersion: string,
	clientTimestamp: number,
	weaponId: string,
	aimDirection: Vector2,
}

export type GameStateChangedPayload = {
	contractVersion: string,
	serverTimestamp: number,
	state: string,
	details: { [string]: any }?,
}

local RemoteContracts = {}

-- Canonical RemoteEvent names
RemoteContracts.RemoteNames = {
	MovePlane = "MovePlane",
	FireWeapon = "FireWeapon",
	GameStateChanged = "GameStateChanged",
}

-- Maximum magnitude permitted for normalized directional input (allowing 5% tolerance for analog diagonal inputs)
RemoteContracts.MAX_DIRECTION_MAGNITUDE = 1.05

-- Check if a number is real, finite, and not NaN
local function isFiniteNumber(n: any): boolean
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Check if a number is a non-negative finite integer
local function isNonNegativeInteger(n: any): boolean
	return isFiniteNumber(n) and n >= 0 and math.floor(n) == n
end

-- Check if a number is a positive finite integer (>= 1)
local function isPositiveInteger(n: any): boolean
	return isFiniteNumber(n) and n >= 1 and math.floor(n) == n
end

-- Check if a Vector2 contains purely finite coordinates
local function isFiniteVector2(v: any): boolean
	return typeof(v) == "Vector2" and isFiniteNumber(v.X) and isFiniteNumber(v.Y)
end

-- Ensure payload contains exactly allowed keys and no unexpected/forbidden fields
local function hasOnlyAllowedKeys(tbl: { [any]: any }, allowed: { [string]: boolean }): (boolean, string?)
	if typeof(tbl) ~= "table" then
		return false, "Payload must be a table."
	end
	for key in pairs(tbl) do
		if typeof(key) ~= "string" or not allowed[key] then
			return false, string.format("Illegal or unexpected payload field: '%s'", tostring(key))
		end
	end
	return true, nil
end

local MOVE_PLANE_ALLOWED_KEYS = {
	contractVersion = true,
	clientTimestamp = true,
	moveDirection = true,
}

local FIRE_WEAPON_ALLOWED_KEYS = {
	contractVersion = true,
	clientTimestamp = true,
	weaponId = true,
	aimDirection = true,
}

local GAME_STATE_ALLOWED_KEYS = {
	contractVersion = true,
	serverTimestamp = true,
	state = true,
	details = true,
}

-- Per-state allowed detail keys
local STATE_DETAILS_ALLOWED_KEYS: { [string]: { [string]: boolean } } = {
	Lobby = {
		countdown = true,
	},
	WaveActive = {
		waveNumber = true,
		remainingEnemies = true,
	},
	Intermission = {
		countdown = true,
		nextWave = true,
	},
	BossPhase = {
		bossName = true,
		phaseNumber = true,
	},
	MissionSuccess = {
		totalWaves = true,
		missionDuration = true,
	},
	MissionFailed = {
		waveReached = true,
		failureReason = true,
	},
}

-- Deep validation of details table per game state
local function validateStateDetails(state: string, details: any): (boolean, string?)
	if details == nil then
		-- Details is optional for Lobby, but required for structured active states
		if state == "WaveActive" or state == "BossPhase" or state == "MissionSuccess" or state == "MissionFailed" then
			return false, string.format("Details table is required for state '%s'.", state)
		end
		return true, nil
	end

	if typeof(details) ~= "table" then
		return false, "Details must be a dictionary table."
	end

	-- Enforce maximum field count in details to prevent unbounded metadata
	local keyCount = 0
	for _ in pairs(details) do
		keyCount += 1
		if keyCount > 5 then
			return false, "Details table exceeds maximum limit of 5 fields."
		end
	end

	local allowedKeys = STATE_DETAILS_ALLOWED_KEYS[state]
	if not allowedKeys then
		return false, string.format("Unknown state '%s' has no defined details schema.", state)
	end

	local keysOk, keyErr = hasOnlyAllowedKeys(details, allowedKeys)
	if not keysOk then
		return false, string.format("In state '%s': %s", state, tostring(keyErr))
	end

	-- Deep type and boundary checks per state
	if state == "WaveActive" then
		if not isPositiveInteger(details.waveNumber) then
			return false, "WaveActive details requires waveNumber as a positive integer (>= 1)."
		end
		if not isNonNegativeInteger(details.remainingEnemies) then
			return false, "WaveActive details requires remainingEnemies as a non-negative integer (>= 0)."
		end
	elseif state == "Intermission" then
		if not isFiniteNumber(details.countdown) or details.countdown < 0 then
			return false, "Intermission details requires countdown as a finite non-negative number."
		end
		if not isPositiveInteger(details.nextWave) then
			return false, "Intermission details requires nextWave as a positive integer (>= 1)."
		end
	elseif state == "BossPhase" then
		if typeof(details.bossName) ~= "string" or #details.bossName == 0 or #details.bossName > 50 then
			return false, "BossPhase details requires bossName as a non-empty string (<= 50 chars)."
		end
		if not isPositiveInteger(details.phaseNumber) then
			return false, "BossPhase details requires phaseNumber as a positive integer (>= 1)."
		end
	elseif state == "MissionSuccess" then
		if not isPositiveInteger(details.totalWaves) then
			return false, "MissionSuccess details requires totalWaves as a positive integer (>= 1)."
		end
		if not isFiniteNumber(details.missionDuration) or details.missionDuration < 0 then
			return false, "MissionSuccess details requires missionDuration as a finite non-negative number."
		end
	elseif state == "MissionFailed" then
		if not isPositiveInteger(details.waveReached) then
			return false, "MissionFailed details requires waveReached as a positive integer (>= 1)."
		end
		if typeof(details.failureReason) ~= "string" or #details.failureReason == 0 or #details.failureReason > 100 then
			return false, "MissionFailed details requires failureReason as a string (1-100 chars)."
		end
	elseif state == "Lobby" then
		if details.countdown ~= nil and (not isFiniteNumber(details.countdown) or details.countdown < 0) then
			return false, "Lobby details countdown must be a finite non-negative number."
		end
	end

	return true, nil
end

--[[
	Validates incoming MovePlane client request.
	Direction: Client -> Server
	Note: Client submits directional intent; server calculates actual position.
]]
function RemoteContracts.ValidateMovePlane(payload: any): (boolean, string?)
	local keysOk, keyErr = hasOnlyAllowedKeys(payload, MOVE_PLANE_ALLOWED_KEYS)
	if not keysOk then
		return false, keyErr
	end

	if payload.contractVersion ~= GameConfig.CONTRACT_VERSION then
		return false, string.format("Contract version mismatch. Expected %s, received %s", GameConfig.CONTRACT_VERSION, tostring(payload.contractVersion))
	end

	if not isFiniteNumber(payload.clientTimestamp) or payload.clientTimestamp < 0 then
		return false, "Invalid or non-finite clientTimestamp."
	end

	if not isFiniteVector2(payload.moveDirection) then
		return false, "Invalid or non-finite moveDirection Vector2."
	end

	-- Move direction magnitude is capped at MAX_DIRECTION_MAGNITUDE (1.05) to accommodate analog diagonal tolerance
	if payload.moveDirection.Magnitude > RemoteContracts.MAX_DIRECTION_MAGNITUDE then
		return false, string.format("moveDirection magnitude (%.3f) exceeds maximum limit (%.2f).", payload.moveDirection.Magnitude, RemoteContracts.MAX_DIRECTION_MAGNITUDE)
	end

	return true, nil
end

--[[
	Validates incoming FireWeapon client request.
	Direction: Client -> Server
	Note: Client requests weapon fire intent; server resolves firing origin and normalizes direction.
]]
function RemoteContracts.ValidateFireWeapon(payload: any): (boolean, string?)
	local keysOk, keyErr = hasOnlyAllowedKeys(payload, FIRE_WEAPON_ALLOWED_KEYS)
	if not keysOk then
		return false, keyErr
	end

	if payload.contractVersion ~= GameConfig.CONTRACT_VERSION then
		return false, string.format("Contract version mismatch. Expected %s, received %s", GameConfig.CONTRACT_VERSION, tostring(payload.contractVersion))
	end

	if not isFiniteNumber(payload.clientTimestamp) or payload.clientTimestamp < 0 then
		return false, "Invalid or non-finite clientTimestamp."
	end

	if typeof(payload.weaponId) ~= "string" or not WeaponConfig.GetWeapon(payload.weaponId) then
		return false, string.format("Unknown or invalid weaponId: %s", tostring(payload.weaponId))
	end

	if not isFiniteVector2(payload.aimDirection) or payload.aimDirection.Magnitude < 0.001 then
		return false, "Invalid, non-finite, or near-zero aimDirection Vector2."
	end

	-- Cap aim vector magnitude at MAX_DIRECTION_MAGNITUDE (1.05) to prevent raw physics distortion
	if payload.aimDirection.Magnitude > RemoteContracts.MAX_DIRECTION_MAGNITUDE then
		return false, string.format("aimDirection magnitude (%.3f) exceeds maximum limit (%.2f).", payload.aimDirection.Magnitude, RemoteContracts.MAX_DIRECTION_MAGNITUDE)
	end

	return true, nil
end

--[[
	Validates outgoing GameStateChanged server notification with deep details verification.
	Direction: Server -> Client
]]
function RemoteContracts.ValidateGameStateChanged(payload: any): (boolean, string?)
	local keysOk, keyErr = hasOnlyAllowedKeys(payload, GAME_STATE_ALLOWED_KEYS)
	if not keysOk then
		return false, keyErr
	end

	if payload.contractVersion ~= GameConfig.CONTRACT_VERSION then
		return false, "Contract version mismatch on GameStateChanged."
	end

	if not isFiniteNumber(payload.serverTimestamp) then
		return false, "Invalid serverTimestamp."
	end

	if typeof(payload.state) ~= "string" or not GameConfig.GameStates[payload.state] then
		return false, string.format("Invalid game state: %s", tostring(payload.state))
	end

	-- Deep details validation
	local detailsOk, detailsErr = validateStateDetails(payload.state, payload.details)
	if not detailsOk then
		return false, detailsErr
	end

	return true, nil
end

return RemoteContracts
