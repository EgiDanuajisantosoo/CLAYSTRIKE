--!strict
--[[
	AircraftService.luau
	Authoritative server lifecycle service for player aircraft.
	Task: CLAY-003 (Create Placeholder Aircraft Model Factory)

	Manages player aircraft instances in Workspace.ActivePlanes, ensuring:
	- Exactly one plane per joining player.
	- Model attributes (OwnerUserId, Health, etc.) are properly set.
	- Clean despawn on PlayerRemoving with zero orphaned models or memory leaks.
	- Protection against stale lookups and race conditions on player disconnect.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local AircraftFactory = require(script.Parent:WaitForChild("AircraftFactory"))

local AircraftService = {}

local activePlanesFolder: Folder? = nil
local playerPlanes: { [number]: Model } = {}
local isInitialized = false

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
		if child:IsA("Model") and child:GetAttribute("OwnerUserId") == userId then
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

	-- P1 Fix: Guard against player leaving before spawn executes
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

	-- P1 Fix: Re-verify player connectivity before parenting to Workspace.ActivePlanes
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

	local plane = playerPlanes[userId]
	if plane then
		plane:Destroy()
		playerPlanes[userId] = nil
	end

	purgeLingeringPlanes(userId)
	print(string.format("[AircraftService] Despawned aircraft for UserId %d.", userId))
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
	-- P2 Fix: Validate model vitality and active location
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

	-- Handle players already present in the session (P1 Fix: Check isPlayerConnected inside deferred thread)
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
	Test/harness reset helper. Cleans all planes and state.
]]
function AircraftService._Reset()
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
