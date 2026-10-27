--!strict
--[[
	RemoteManager.luau
	Authoritative server network boundary.
	Task: CLAY-002 (Define Remote Contracts & Shared Config)

	Initializes RemoteEvents under ReplicatedStorage.Remotes and wires up
	per-player rate limiting and strict payload validation handlers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RemotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")

local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local RemoteContracts = require(SharedFolder:WaitForChild("RemoteContracts"))
local RateLimiter = require(script.Parent:WaitForChild("RateLimiter"))

local RemoteManager = {}

local function getOrCreateRemote(name: string): RemoteEvent
	local remote = RemotesFolder:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = RemotesFolder
	end
	return remote :: RemoteEvent
end

local movePlaneRemote = getOrCreateRemote(RemoteContracts.RemoteNames.MovePlane)
local fireWeaponRemote = getOrCreateRemote(RemoteContracts.RemoteNames.FireWeapon)
local gameStateRemote = getOrCreateRemote(RemoteContracts.RemoteNames.GameStateChanged)

--[[
	Initialize network listeners with rate limiting and schema validation
]]
function RemoteManager.Initialize()
	-- Handle incoming MovePlane requests
	movePlaneRemote.OnServerEvent:Connect(function(player: Player, payload: any)
		-- 1. Enforce per-player rate limit
		local rateOk, rateErr = RateLimiter.CheckRateLimit(player, RemoteContracts.RemoteNames.MovePlane)
		if not rateOk then
			warn(string.format("[Security] Player %s rate limited: %s", player.Name, tostring(rateErr)))
			return
		end

		-- 2. Validate payload schema and boundary limits
		local valid, err = RemoteContracts.ValidateMovePlane(payload)
		if not valid then
			warn(string.format("[Security] Player %s sent invalid MovePlane payload: %s", player.Name, tostring(err)))
			return
		end

		-- Validated successfully (authority will apply movement in CLAY-003/004)
	end)

	-- Handle incoming FireWeapon requests
	fireWeaponRemote.OnServerEvent:Connect(function(player: Player, payload: any)
		-- 1. Enforce per-player rate limit
		local rateOk, rateErr = RateLimiter.CheckRateLimit(player, RemoteContracts.RemoteNames.FireWeapon)
		if not rateOk then
			warn(string.format("[Security] Player %s rate limited: %s", player.Name, tostring(rateErr)))
			return
		end

		-- 2. Validate payload schema and boundary limits
		local valid, err = RemoteContracts.ValidateFireWeapon(payload)
		if not valid then
			warn(string.format("[Security] Player %s sent invalid FireWeapon payload: %s", player.Name, tostring(err)))
			return
		end

		-- Validated successfully (authority will apply weapon cooldowns and spawning in CLAY-010)
	end)

	print("[CLAYSTRIKE - RemoteManager] Remote listeners initialized with security boundary and rate limiting.")
end

-- Broadcast state change to all clients
function RemoteManager.BroadcastGameState(state: string, details: { [string]: any }?)
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
