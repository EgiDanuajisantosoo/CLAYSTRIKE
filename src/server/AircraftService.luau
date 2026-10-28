--!strict
--[[
	AircraftService.luau
	Authoritative server lifecycle service for player aircraft.
	Task: CLAY-003, CLAY-023 (Player Damage, Death & Respawn Rules)

	Manages player aircraft instances in Workspace.ActivePlanes, ensuring:
	- Exactly one plane per joining player.
	- Model attributes (OwnerUserId, Health, Invulnerable, State) are properly set.
	- Server-authoritative damage calculation, iframes/invulnerability, and downed state.
	- Automated respawn after configured delay without duplicating aircraft.
	- Clean despawn on PlayerRemoving with zero orphaned models or memory leaks.
	- Protection against stale lookups and race conditions on player disconnect.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local SessionConfig = require(SharedFolder:WaitForChild("SessionConfig"))

local AircraftFactory = require(script.Parent:WaitForChild("AircraftFactory"))

export type DamageCallback = (userId: number, damage: number, newHealth: number) -> ()
export type DownedCallback = (userId: number, livesRemaining: number) -> ()
export type RespawnCallback = (userId: number, plane: Model) -> ()

local AircraftService = {}

local activePlanesFolder: Folder? = nil
local playerPlanes: { [number]: Model } = {}
local isInitialized = false

local damageCallbacks: { DamageCallback } = {}
local downedCallbacks: { DownedCallback } = {}
local respawnCallbacks: { RespawnCallback } = {}
local respawnTasks: { [number]: thread } = {}

--[[
	Returns or lazily resolves Workspace.ActivePlanes folder.
]]
local function getActivePlanesFolder(): Folder?
	if not activePlanesFolder then
		local folder = Workspace:FindFirstChild("ActivePlanes")
		if folder and folder:IsA("Folder") then
			activePlanesFolder = folder
		end
	end
	return activePlanesFolder
end

--[[
	Safely resolves SessionService without circular require deadlock.
]]
local function getSessionService(): any?
	local servicesFolder = if script.Parent then script.Parent else game:GetService("ServerScriptService"):FindFirstChild("Services")
	if servicesFolder then
		local sMod = servicesFolder:FindFirstChild("SessionService")
		if sMod then
			local ok, svc = pcall(require, sMod)
			if ok then
				return svc
			end
		end
	end
	return nil
end

--[[
	Helper to verify if a player (real Player instance or test mock) is still connected.
]]
local function isPlayerConnected(player: any): boolean
	if typeof(player) == "Instance" and player:IsA("Player") then
		return player:IsDescendantOf(Players)
	elseif typeof(player) == "table" then
		return player.isDisconnected ~= true
	end
	return false
end

--[[
	Finds and removes any lingering models in ActivePlanes matching the given userId.
	Guarantees no orphaned models remain.
]]
local function purgeLingeringPlanes(userId: number)
	local folder = getActivePlanesFolder()
	if not folder then
		return
	end

	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") and (child.Name == string.format("Plane_%d", userId) or child:GetAttribute("OwnerUserId") == userId) then
			child:Destroy()
		end
	end
end

--[[
	Spawns an aircraft for the specified player.
	If the player already has a valid plane, returns it without creating a duplicate.
	Aborts safely if player has already disconnected.
]]
function AircraftService.SpawnPlaneForPlayer(player: any, initialPosition: Vector3?): Model?
	assert(
		(typeof(player) == "Instance" and player:IsA("Player"))
			or (typeof(player) == "table" and typeof(player.UserId) == "number"),
		"AircraftService: Expected Player instance or player mock."
	)
	local userId = player.UserId
	local folder = getActivePlanesFolder()
	assert(folder ~= nil, "Workspace.ActivePlanes folder is missing.")

	-- Guard against player leaving before spawn executes
	if not isPlayerConnected(player) then
		warn(string.format("[AircraftService] Aborting spawn: player %s (UserId: %d) is no longer connected.", player.Name or "Unknown", userId))
		return nil
	end

	-- 1. Check for existing active plane
	local existingPlane = playerPlanes[userId]
	if existingPlane and existingPlane.Parent == folder and existingPlane.PrimaryPart ~= nil then
		return existingPlane
	end

	-- 2. Clean up any stale or orphaned instances
	if existingPlane then
		existingPlane:Destroy()
		playerPlanes[userId] = nil
	end
	purgeLingeringPlanes(userId)

	-- 3. Construct new aircraft via factory
	local newPlane = AircraftFactory.CreatePlaceholderPlane(userId, initialPosition)

	-- Re-verify player connectivity before parenting to Workspace.ActivePlanes
	if not isPlayerConnected(player) then
		newPlane:Destroy()
		warn(string.format("[AircraftService] Player %s left during aircraft assembly; destroyed unparented plane.", player.Name or "Unknown"))
		return nil
	end

	newPlane.Parent = folder
	playerPlanes[userId] = newPlane

	-- 4. Listen for accidental external destruction
	newPlane.AncestryChanged:Connect(function(_, parent)
		if parent == nil and playerPlanes[userId] == newPlane then
			playerPlanes[userId] = nil
		end
	end)

	print(string.format("[AircraftService] Spawned aircraft '%s' for player %s (UserId: %d).", newPlane.Name, player.Name or tostring(userId), userId))
	return newPlane
end

--[[
	Despawns an aircraft for a player or numeric userId.
	Removes model from Workspace.ActivePlanes and clears state tracking.
]]
function AircraftService.DespawnPlaneForPlayer(playerOrUserId: Player | any)
	local userId = if typeof(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId

	if respawnTasks[userId] then
		task.cancel(respawnTasks[userId])
		respawnTasks[userId] = nil
	end

	local plane = playerPlanes[userId]
	if plane then
		plane:Destroy()
		playerPlanes[userId] = nil
	end

	purgeLingeringPlanes(userId)
	print(string.format("[AircraftService] Despawned aircraft for UserId %d.", userId))
end

--[[
	Authoritatively applies damage to a player aircraft on the server.
	Enforces invulnerability window (iframes), health deduction, downed state, and life deduction.
	Returns (hitValid: boolean, wasDowned: boolean).
]]
function AircraftService.ApplyDamage(
	playerOrUserIdOrModel: any,
	damage: number,
	damageSource: string?
): (boolean, boolean)
	if damage <= 0 then
		return false, false
	end

	local userId: number? = nil
	local plane: Model? = nil

	if typeof(playerOrUserIdOrModel) == "number" then
		userId = playerOrUserIdOrModel
		plane = AircraftService.GetPlaneByUserId(userId)
	elseif typeof(playerOrUserIdOrModel) == "Instance" and playerOrUserIdOrModel:IsA("Model") then
		plane = playerOrUserIdOrModel
		userId = plane:GetAttribute("OwnerUserId") :: number?
		if not userId then
			local numStr = string.match(plane.Name, "Plane_(%d+)")
			if numStr then
				userId = tonumber(numStr)
			end
		end
	elseif typeof(playerOrUserIdOrModel) == "Instance" and playerOrUserIdOrModel:IsA("Player") then
		userId = playerOrUserIdOrModel.UserId
		plane = AircraftService.GetPlaneByUserId(userId)
	elseif typeof(playerOrUserIdOrModel) == "table" and playerOrUserIdOrModel.UserId then
		userId = playerOrUserIdOrModel.UserId
		plane = AircraftService.GetPlaneByUserId(userId)
	end

	if not userId or not plane or not plane.PrimaryPart or not plane:IsDescendantOf(Workspace) then
		return false, false
	end

	local sessionService = getSessionService()
	if sessionService and sessionService.IsInitialized and sessionService.IsInitialized() then
		local pState = sessionService.GetPlayerState(userId)
		if pState and pState ~= "Active" then
			return false, false
		end
	end

	-- Check invulnerability / iframes
	local invulnUntil = plane:GetAttribute("InvulnerableUntil") :: number? or 0
	local isInvuln = plane:GetAttribute("Invulnerable") == true
	if isInvuln or os.clock() < invulnUntil then
		return false, false
	end

	local currentHp = plane:GetAttribute("Health") :: number? or SessionConfig.MAX_PLAYER_HEALTH
	local newHp = math.max(0, currentHp - damage)
	plane:SetAttribute("Health", newHp)

	if newHp > 0 then
		-- Hit lands: grant iframes
		local expireTime = os.clock() + SessionConfig.INVULNERABILITY_DURATION
		plane:SetAttribute("Invulnerable", true)
		plane:SetAttribute("InvulnerableUntil", expireTime)

		task.delay(SessionConfig.INVULNERABILITY_DURATION, function()
			if plane and plane.Parent and (plane:GetAttribute("InvulnerableUntil") :: number? or 0) <= os.clock() then
				plane:SetAttribute("Invulnerable", false)
			end
		end)

		for _, cb in ipairs(damageCallbacks) do
			task.spawn(cb, userId, damage, newHp)
		end

		return true, false
	else
		-- Fatal damage: Player is Downed!
		plane:SetAttribute("Invulnerable", false)
		plane:SetAttribute("InvulnerableUntil", 0)
		plane:SetAttribute("State", "Downed")

		local livesRemaining = 0
		if sessionService and sessionService.IsInitialized and sessionService.IsInitialized() then
			sessionService.SetPlayerState(userId, "Downed")
			livesRemaining = sessionService.DeductLife(userId)
		end

		for _, cb in ipairs(downedCallbacks) do
			task.spawn(cb, userId, livesRemaining)
		end

		if livesRemaining > 0 then
			-- Schedule automatic respawn after RESPAWN_DELAY
			if respawnTasks[userId] then
				task.cancel(respawnTasks[userId])
				respawnTasks[userId] = nil
			end

			respawnTasks[userId] = task.delay(SessionConfig.RESPAWN_DELAY, function()
				respawnTasks[userId] = nil
				if sessionService and sessionService.IsInitialized and sessionService.IsInitialized() then
					local curState = sessionService.GetPlayerState(userId)
					if curState == "Downed" then
						sessionService.SetPlayerState(userId, "Respawning")
						AircraftService.RespawnPlaneForPlayer(userId)
					end
				else
					AircraftService.RespawnPlaneForPlayer(userId)
				end
			end)
		else
			-- No lives remaining: aircraft is permanently downed
			plane:Destroy()
			playerPlanes[userId] = nil
		end

		return true, true
	end
end

--[[
	Respawns an aircraft for a downed player.
	Cleans up existing models, positions safely within arena bounds,
	resets health to maximum, and grants respawn invulnerability.
]]
function AircraftService.RespawnPlaneForPlayer(playerOrUserId: any, spawnPos: Vector3?): Model?
	local userId = if typeof(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId
	if not userId then
		return nil
	end

	if respawnTasks[userId] then
		task.cancel(respawnTasks[userId])
		respawnTasks[userId] = nil
	end

	-- 1. Purge old model
	local oldPlane = playerPlanes[userId]
	if oldPlane then
		oldPlane:Destroy()
		playerPlanes[userId] = nil
	end
	purgeLingeringPlanes(userId)

	-- 2. Determine safe spawn position
	local arena = GameConfig.Arena
	local defaultPos = Vector3.new(arena.MinX + 15, 0, arena.PlayPlaneZ)
	local targetPos = spawnPos or defaultPos

	local clampedX = math.clamp(targetPos.X, arena.MinX + 5, arena.MaxX - 10)
	local clampedY = math.clamp(targetPos.Y, arena.MinY + 5, arena.MaxY - 5)
	local clampedPos = Vector3.new(clampedX, clampedY, arena.PlayPlaneZ)

	-- 3. Construct fresh aircraft via factory
	local newPlane = AircraftFactory.CreatePlaceholderPlane(userId, clampedPos)
	local folder = getActivePlanesFolder()
	if folder then
		newPlane.Parent = folder
	end
	playerPlanes[userId] = newPlane

	-- 4. Set authoritative attributes: full health, iframes, and active state
	newPlane:SetAttribute("Health", SessionConfig.MAX_PLAYER_HEALTH)
	newPlane:SetAttribute("MaxHealth", SessionConfig.MAX_PLAYER_HEALTH)
	newPlane:SetAttribute("State", "Active")
	newPlane:SetAttribute("Invulnerable", true)
	local invulnExpiry = os.clock() + SessionConfig.RESPAWN_INVULNERABILITY
	newPlane:SetAttribute("InvulnerableUntil", invulnExpiry)

	task.delay(SessionConfig.RESPAWN_INVULNERABILITY, function()
		if newPlane and newPlane.Parent and (newPlane:GetAttribute("InvulnerableUntil") :: number? or 0) <= os.clock() then
			newPlane:SetAttribute("Invulnerable", false)
		end
	end)

	-- 5. Link with SessionService
	local sessionService = getSessionService()
	if sessionService and sessionService.IsInitialized and sessionService.IsInitialized() then
		if sessionService.SetPlayerPlane then
			sessionService.SetPlayerPlane(userId, newPlane)
		end
		local curState = sessionService.GetPlayerState(userId)
		if curState == "Downed" then
			sessionService.SetPlayerState(userId, "Respawning")
		end
		sessionService.SetPlayerState(userId, "Active")
	end

	newPlane.AncestryChanged:Connect(function(_, parent)
		if parent == nil and playerPlanes[userId] == newPlane then
			playerPlanes[userId] = nil
		end
	end)

	for _, cb in ipairs(respawnCallbacks) do
		task.spawn(cb, userId, newPlane)
	end

	print(string.format("[AircraftService] Respawned aircraft for player UserId %d with %.1fs iframes.",
		userId, SessionConfig.RESPAWN_INVULNERABILITY))
	return newPlane
end

--[[
	Registers a callback when a player aircraft takes damage.
]]
function AircraftService.OnPlayerDamaged(callback: DamageCallback): () -> ()
	table.insert(damageCallbacks, callback)
	return function()
		local idx = table.find(damageCallbacks, callback)
		if idx then
			table.remove(damageCallbacks, idx)
		end
	end
end

--[[
	Registers a callback when a player aircraft is downed.
]]
function AircraftService.OnPlayerDowned(callback: DownedCallback): () -> ()
	table.insert(downedCallbacks, callback)
	return function()
		local idx = table.find(downedCallbacks, callback)
		if idx then
			table.remove(downedCallbacks, idx)
		end
	end
end

--[[
	Registers a callback when a player aircraft respawns.
]]
function AircraftService.OnPlayerRespawned(callback: RespawnCallback): () -> ()
	table.insert(respawnCallbacks, callback)
	return function()
		local idx = table.find(respawnCallbacks, callback)
		if idx then
			table.remove(respawnCallbacks, idx)
		end
	end
end

--[[
	Returns the aircraft Model belonging to the given UserId.
	Validates that the model is active and parented to Workspace.ActivePlanes.
	Cleans up stale tracking entries if the model was unparented/destroyed externally.
]]
function AircraftService.GetPlaneByUserId(userId: number): Model?
	local plane = playerPlanes[userId]
	if not plane then
		return nil
	end

	local folder = getActivePlanesFolder()
	if plane.Parent ~= folder or not plane.PrimaryPart or not plane:IsDescendantOf(Workspace) then
		playerPlanes[userId] = nil
		return nil
	end

	return plane
end

--[[
	Returns the aircraft Model belonging to the given Player.
	Validates that the model is active; cleans stale tracking records.
]]
function AircraftService.GetPlaneForPlayer(player: any): Model?
	local userId = if typeof(player) == "number" then player else player.UserId
	if not userId then
		return nil
	end
	return AircraftService.GetPlaneByUserId(userId)
end

--[[
	Returns a copy of all currently active planes mapped by UserId.
	Filters out any stale or unparented models.
]]
function AircraftService.GetAllPlanes(): { [number]: Model }
	local folder = getActivePlanesFolder()
	local validPlanes: { [number]: Model } = {}
	for id, plane in pairs(playerPlanes) do
		if folder and plane.Parent == folder and plane.PrimaryPart and plane:IsDescendantOf(Workspace) then
			validPlanes[id] = plane
		else
			playerPlanes[id] = nil
		end
	end
	return validPlanes
end

--[[
	Initializes the aircraft service.
	Binds to PlayerAdded and PlayerRemoving events, and spawns planes for any existing players.
]]
function AircraftService.Initialize()
	if isInitialized then
		warn("[AircraftService] Initialize() already called; skipping redundant setup.")
		return
	end

	activePlanesFolder = Workspace:WaitForChild("ActivePlanes") :: Folder
	isInitialized = true

	-- Handle player joining
	Players.PlayerAdded:Connect(function(player)
		AircraftService.SpawnPlaneForPlayer(player)
	end)

	-- Handle player leaving
	Players.PlayerRemoving:Connect(function(player)
		AircraftService.DespawnPlaneForPlayer(player)
	end)

	-- Handle players already present in the session
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			if isPlayerConnected(player) then
				AircraftService.SpawnPlaneForPlayer(player)
			end
		end)
	end

	print("[AircraftService] Aircraft service initialized. Listening for player join/leave.")
end

--[[
	Test/harness reset helper. Cleans all planes, timers, and callbacks.
]]
function AircraftService._Reset()
	for userId, t in pairs(respawnTasks) do
		task.cancel(t)
	end
	respawnTasks = {}
	damageCallbacks = {}
	downedCallbacks = {}
	respawnCallbacks = {}

	for userId, plane in pairs(playerPlanes) do
		plane:Destroy()
	end
	playerPlanes = {}
	local folder = getActivePlanesFolder()
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Model") and child:GetAttribute("OwnerUserId") ~= nil then
				child:Destroy()
			end
		end
	end
end

return AircraftService
