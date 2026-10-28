--!strict
--[[
	SessionController.luau
	Client-side controller for observing co-op team state and teammate lifecycle.
	Task: CLAY-022 (Co-op Player State & Team Session)

	RESPONSIBILITIES:
	- Listens to replicated team state from ReplicatedStorage.TeamState.
	- Provides safe read-only teammate queries for HUD, scoreboards, and camera framing.
	- Client is strictly a presentation observer; all team state is server-authoritative.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local SessionConfig = require(SharedFolder:WaitForChild("SessionConfig"))

export type TeammateView = {
	userId: number,
	username: string,
	state: SessionConfig.PlayerLifecycleState,
	score: number,
	lives: number,
	joinTime: number,
}

type TeammateUpdateCallback = (userId: number, record: TeammateView) -> ()
type TeammateRemoveCallback = (userId: number) -> ()

local SessionController = {}

local teammates: { [number]: TeammateView } = {}
local isInitialized = false
local childAddedConn: RBXScriptConnection? = nil
local childRemovedConn: RBXScriptConnection? = nil
local attributeConns: { [number]: RBXScriptConnection } = {}

local updateCallbacks: { TeammateUpdateCallback } = {}
local removeCallbacks: { TeammateRemoveCallback } = {}

local function parseTeammateFolder(folder: Instance): TeammateView?
	if not folder:IsA("Folder") then
		return nil
	end

	local userId = folder:GetAttribute("UserId") :: number?
	local username = folder:GetAttribute("Username") :: string?
	local state = folder:GetAttribute("State") :: string?
	local score = folder:GetAttribute("Score") :: number?
	local lives = folder:GetAttribute("Lives") :: number?
	local joinTime = folder:GetAttribute("JoinTime") :: number?

	if userId and username and state and score and lives and joinTime then
		return {
			userId = userId,
			username = username,
			state = state :: any,
			score = score,
			lives = lives,
			joinTime = joinTime,
		}
	end
	return nil
end

local function onPlayerFolderAdded(folder: Instance)
	local record = parseTeammateFolder(folder)
	if record then
		teammates[record.userId] = record
		for _, cb in ipairs(updateCallbacks) do
			task.spawn(cb, record.userId, record)
		end
	end

	-- Watch for attribute changes
	local conn = folder.AttributeChanged:Connect(function()
		local updated = parseTeammateFolder(folder)
		if updated then
			teammates[updated.userId] = updated
			for _, cb in ipairs(updateCallbacks) do
				task.spawn(cb, updated.userId, updated)
			end
		end
	end)

	local uid = folder:GetAttribute("UserId") :: number?
	if uid then
		if attributeConns[uid] then
			attributeConns[uid]:Disconnect()
		end
		attributeConns[uid] = conn
	end
end

local function onPlayerFolderRemoved(folder: Instance)
	local uid = folder:GetAttribute("UserId") :: number?
	if uid then
		if attributeConns[uid] then
			attributeConns[uid]:Disconnect()
			attributeConns[uid] = nil
		end
		teammates[uid] = nil
		for _, cb in ipairs(removeCallbacks) do
			task.spawn(cb, uid)
		end
	end
end

--[[
	Returns snapshot of all current teammates.
]]
function SessionController.GetTeammates(): { [number]: TeammateView }
	local copy = {}
	for id, view in pairs(teammates) do
		copy[id] = view
	end
	return copy
end

--[[
	Returns record for specific teammate by userId.
]]
function SessionController.GetTeammate(userId: number): TeammateView?
	return teammates[userId]
end

--[[
	Returns the local player's lifecycle state.
]]
function SessionController.GetMyState(): SessionConfig.PlayerLifecycleState?
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return nil
	end
	local rec = teammates[localPlayer.UserId]
	return rec and rec.state or nil
end

--[[
	Registers a listener for teammate state/score updates.
]]
function SessionController.OnTeammateUpdated(callback: TeammateUpdateCallback): () -> ()
	table.insert(updateCallbacks, callback)
	return function()
		local idx = table.find(updateCallbacks, callback)
		if idx then
			table.remove(updateCallbacks, idx)
		end
	end
end

--[[
	Registers a listener for teammate removal/disconnect.
]]
function SessionController.OnTeammateRemoved(callback: TeammateRemoveCallback): () -> ()
	table.insert(removeCallbacks, callback)
	return function()
		local idx = table.find(removeCallbacks, callback)
		if idx then
			table.remove(removeCallbacks, idx)
		end
	end
end

--[[
	Initializes the controller and binds to ReplicatedStorage.TeamState.
]]
function SessionController.Initialize()
	if isInitialized then
		return
	end
	isInitialized = true

	local container = ReplicatedStorage:WaitForChild("TeamState")

	childAddedConn = container.ChildAdded:Connect(onPlayerFolderAdded)
	childRemovedConn = container.ChildRemoved:Connect(onPlayerFolderRemoved)

	for _, child in ipairs(container:GetChildren()) do
		onPlayerFolderAdded(child)
	end

	print("[SessionController] Co-op session controller initialized.")
end

--[[
	Returns true if SessionController is initialized.
]]
function SessionController.IsInitialized(): boolean
	return isInitialized
end

--[[
	Teardown helper for unit tests.
]]
function SessionController._Teardown()
	if childAddedConn then
		childAddedConn:Disconnect()
		childAddedConn = nil
	end
	if childRemovedConn then
		childRemovedConn:Disconnect()
		childRemovedConn = nil
	end
	for _, conn in pairs(attributeConns) do
		conn:Disconnect()
	end
	attributeConns = {}
	teammates = {}
	updateCallbacks = {}
	removeCallbacks = {}
	isInitialized = false
end

return SessionController
