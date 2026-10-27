--!strict
--[[
	RemoteContracts.luau
	Public network contract schemas, validation boundaries, and RemoteEvent identifiers.
	Task: CLAY-002 (Define Remote Contracts & Shared Config)

	SECURITY POLICY:
	1. Pure Movement Intent: Client sends moveDirection; server calculates and enforces position.
	2. Authoritative Firing Origin: Client sends weaponId and aimDirection; server determines origin from authoritative aircraft state.
	3. Strict Whitelist Schema: Unknown or illegal fields (including client-claimed 'position' or 'origin') cause immediate rejection.
	4. Finite Value Verification: Non-finite values (NaN, Inf, -Inf) cause immediate rejection.
	5. No Client Authority: Client payloads NEVER contain authoritative damage, health, rewards, or game outcome.
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

-- Check if a number is real, finite, and not NaN
local function isFiniteNumber(n: any): boolean
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
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

	-- Move direction magnitude cannot exceed unit vector with reasonable input tolerance
	if payload.moveDirection.Magnitude > 1.05 then
		return false, "moveDirection magnitude exceeds normalized unit vector."
	end

	return true, nil
end

--[[
	Validates incoming FireWeapon client request.
	Direction: Client -> Server
	Note: Client requests weapon fire intent; server resolves firing origin from authoritative aircraft model.
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
		return false, "Invalid, non-finite, or zero aimDirection Vector2."
	end

	return true, nil
end

--[[
	Validates outgoing GameStateChanged server notification.
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

	return true, nil
end

return RemoteContracts
