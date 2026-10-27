--!strict
--[[
	RemoteManager.luau
	Authoritative server network boundary.
	Task: CLAY-002 (Define Remote Contracts & Shared Config)

	Initializes RemoteEvents under ReplicatedStorage.Remotes upon explicit Initialize() call,
	verifies instance ClassName, normalizes input vectors, and wires up rate limiting and schema validators.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RemotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")

local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local RemoteContracts = require(SharedFolder:WaitForChild("RemoteContracts"))
local RateLimiter = require(script.Parent:WaitForChild("RateLimiter"))
local MovementService = require(script.Parent:WaitForChild("MovementService"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))

local RemoteManager = {}

-- References to RemoteEvents (populated purely inside Initialize())
local movePlaneRemote: RemoteEvent? = nil
local fireWeaponRemote: RemoteEvent? = nil
local gameStateRemote: RemoteEvent? = nil
local isInitialized = false

-- Safely retrieves or creates a RemoteEvent with strict ClassName verification
local function getOrCreateRemote(name: string): RemoteEvent
	local existing = RemotesFolder:FindFirstChild(name)
	if existing then
		if not existing:IsA("RemoteEvent") then
			error(string.format(
				"[RemoteManager] Critical Conflict: Instance '%s' under ReplicatedStorage.Remotes is a '%s', expected 'RemoteEvent'. Halting network initialization.",
				name,
				existing.ClassName
			))
		end
		return existing :: RemoteEvent
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = RemotesFolder
	return remote
end

--[[
	Initializes network listeners with rate limiting and schema validation.
	Precondition: Baseline folders and contract unit tests must have already passed.
]]
function RemoteManager.Initialize()
	if isInitialized then
		warn("[RemoteManager] Initialize() called more than once; skipping redundant initialization.")
		return
	end

	-- Create or verify RemoteEvents strictly at runtime inside Initialize()
	movePlaneRemote = getOrCreateRemote(RemoteContracts.RemoteNames.MovePlane)
	fireWeaponRemote = getOrCreateRemote(RemoteContracts.RemoteNames.FireWeapon)
	gameStateRemote = getOrCreateRemote(RemoteContracts.RemoteNames.GameStateChanged)

	-- Handle incoming MovePlane requests (Pure Intent)
	movePlaneRemote.OnServerEvent:Connect(function(player: Player, payload: any)
		-- 1. Enforce per-player rate limit (Fail-closed)
		local rateOk, rateErr = RateLimiter.CheckRateLimit(player, RemoteContracts.RemoteNames.MovePlane)
		if not rateOk then
			warn(string.format("[Security] Player %s rate limited: %s", player.Name, tostring(rateErr)))
			return
		end

		-- 2. Validate payload schema (pure moveDirection intent)
		local valid, err = RemoteContracts.ValidateMovePlane(payload)
		if not valid then
			warn(string.format("[Security] Player %s sent invalid MovePlane payload: %s", player.Name, tostring(err)))
			return
		end

		-- 3. Route validated movement intent to MovementService
		MovementService.HandleMoveIntent(player, payload.moveDirection)
	end)

	-- Handle incoming FireWeapon requests (Pure Intent)
	fireWeaponRemote.OnServerEvent:Connect(function(player: Player, payload: any)
		-- 1. Enforce per-player rate limit (Fail-closed)
		local rateOk, rateErr = RateLimiter.CheckRateLimit(player, RemoteContracts.RemoteNames.FireWeapon)
		if not rateOk then
			warn(string.format("[Security] Player %s rate limited: %s", player.Name, tostring(rateErr)))
			return
		end

		-- 2. Validate payload schema
		local valid, err = RemoteContracts.ValidateFireWeapon(payload)
		if not valid then
			warn(string.format("[Security] Player %s sent invalid FireWeapon payload: %s", player.Name, tostring(err)))
			return
		end

		-- 3. Normalize raw aimDirection so raw vector magnitude cannot alter projectile speed
		local normalizedAimDirection = payload.aimDirection.Unit

		-- 4. Authoritatively process firing intent with cooldown and projectile generation
		local fired, fireErr = WeaponService.HandleFireIntent(player, payload.weaponId, normalizedAimDirection)
		if not fired and fireErr ~= "CooldownActive" then
			warn(string.format("[WeaponService] Rejected fire intent from %s: %s", player.Name, tostring(fireErr)))
		end
	end)

	isInitialized = true
	print("[CLAYSTRIKE - RemoteManager] Remote listeners initialized with security boundary and rate limiting.")
end

-- Broadcast state change to all clients
function RemoteManager.BroadcastGameState(state: string, details: { [string]: any }?)
	if not gameStateRemote then
		warn("[RemoteManager] BroadcastGameState called before RemoteManager.Initialize().")
		return
	end

	local payload: RemoteContracts.GameStateChangedPayload = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		serverTimestamp = os.clock(),
		state = state,
		details = details,
	}

	local valid, err = RemoteContracts.ValidateGameStateChanged(payload)
	if valid then
		gameStateRemote:FireAllClients(payload)
	else
		warn(string.format("[RemoteManager] Failed to broadcast GameStateChanged: %s", tostring(err)))
	end
end

return RemoteManager
