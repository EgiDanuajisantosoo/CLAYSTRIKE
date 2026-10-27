--!strict
--[[
	AircraftService.luau
	Authoritative server lifecycle service for player aircraft.
	Task: CLAY-003 (Create Placeholder Aircraft Model Factory)

	Manages player aircraft instances in Workspace.ActivePlanes, ensuring:
	- Exactly one plane per joining player.
	- Model attributes (OwnerUserId, Health, etc.) are properly set.
	- Clean despawn on PlayerRemoving with zero orphaned models or memory leaks.
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
]]
function AircraftService.SpawnPlaneForPlayer(player: any, initialPosition: Vector3?): Model
	assert(
		(typeof(player) == "Instance" and player:IsA("Player"))
			or (typeof(player) == "table" and typeof(player.UserId) == "number"),
		"AircraftService: Expected Player instance or player mock."
	)
	local userId = player.UserId
	local folder = getActivePlanesFolder()
	assert(folder ~= nil, "Workspace.ActivePlanes folder is missing.")

	-- 1. Check for existing active plane
	local existingPlane = playerPlanes[userId]
	if existingPlane and existingPlane.Parent == folder then
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
	newPlane.Parent = folder
	playerPlanes[userId] = newPlane

	-- 4. Listen for accidental external destruction
	newPlane.AncestryChanged:Connect(function(_, parent)
		if parent == nil and playerPlanes[userId] == newPlane then
			playerPlanes[userId] = nil
		end
	end)

	print(string.format("[AircraftService] Spawned aircraft '%s' for player %s (UserId: %d).", newPlane.Name, player.Name, userId))
	return newPlane
end

--[[
	Despawns an aircraft for a player or numeric userId.
	Removes model from Workspace.ActivePlanes and clears state tracking.
]]
function AircraftService.DespawnPlaneForPlayer(playerOrUserId: Player | number)
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
	Returns the aircraft Model belonging to the given Player, if alive.
]]
function AircraftService.GetPlaneForPlayer(player: any): Model?
	local userId = if typeof(player) == "number" then player else player.UserId
	return playerPlanes[userId]
end

--[[
	Returns the aircraft Model belonging to the given UserId, if alive.
]]
function AircraftService.GetPlaneByUserId(userId: number): Model?
	return playerPlanes[userId]
end

--[[
	Returns a copy of all currently active planes mapped by UserId.
]]
function AircraftService.GetAllPlanes(): { [number]: Model }
	local copy: { [number]: Model } = {}
	for id, plane in pairs(playerPlanes) do
		copy[id] = plane
	end
	return copy
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
			AircraftService.SpawnPlaneForPlayer(player)
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
