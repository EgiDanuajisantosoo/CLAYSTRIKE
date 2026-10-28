--!strict
--[[
	SessionService.luau
	Authoritative server manager for co-op multiplayer team sessions and player lifecycle states.
	Task: CLAY-022 (Co-op Player State & Team Session)

	RESPONSIBILITIES:
	- Authoritative management of co-op team members (max 4 players).
	- Strict player lifecycle state tracking (Joining -> Active -> Downed -> Respawning -> Disconnected).
	- Replicates team state safely to all clients via ReplicatedStorage.TeamState.
	- Coordinates join/leave events seamlessly with AircraftService and WaveService.
	- Player removal never breaks wave progression or corrupts enemy tracking.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local SessionConfig = require(SharedFolder:WaitForChild("SessionConfig"))

local Services = ServerScriptService:WaitForChild("Services")
local AircraftService = require(Services:WaitForChild("AircraftService"))
local WaveService = require(Services:WaitForChild("WaveService"))

export type PlayerStateCallback = (userId: number, oldState: SessionConfig.PlayerLifecycleState, newState: SessionConfig.PlayerLifecycleState) -> ()
export type MembershipCallback = (activeCount: number) -> ()

local SessionService = {}

local activeRecords: { [number]: SessionConfig.PlayerSessionRecord } = {}
local isInitialized = false
local playerAddedConn: RBXScriptConnection? = nil
local playerRemovingConn: RBXScriptConnection? = nil
local stateChangeCallbacks: { PlayerStateCallback } = {}
local membershipCallbacks: { MembershipCallback } = {}

-- Helper to retrieve or create the authoritative TeamState replication folder
local function getTeamStateFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild("TeamState")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "TeamState"
	folder.Parent = ReplicatedStorage
	return folder
end

-- Replicates player state record attributes to ReplicatedStorage.TeamState
local function syncPlayerReplication(record: SessionConfig.PlayerSessionRecord)
	local container = getTeamStateFolder()
	local folderName = string.format("Player_%d", record.userId)
	local pFolder = container:FindFirstChild(folderName)
	if not pFolder then
		pFolder = Instance.new("Folder")
		pFolder.Name = folderName
		pFolder.Parent = container
	end

	pFolder:SetAttribute("UserId", record.userId)
	pFolder:SetAttribute("Username", record.username)
	pFolder:SetAttribute("State", record.state)
	pFolder:SetAttribute("Score", record.score)
	pFolder:SetAttribute("Lives", record.lives)
	pFolder:SetAttribute("JoinTime", record.joinTime)
end

-- Removes player folder from ReplicatedStorage.TeamState
local function removePlayerReplication(userId: number)
	local container = getTeamStateFolder()
	local folderName = string.format("Player_%d", userId)
	local pFolder = container:FindFirstChild(folderName)
	if pFolder then
		pFolder:Destroy()
	end
end

--[[
	Adds a player to the authoritative co-op session.
	Returns (success: boolean, errorMessage: string?).
]]
function SessionService.AddPlayer(player: Player): (boolean, string?)
	if not player or not player.UserId then
		return false, "Invalid player instance"
	end

	local userId = player.UserId
	if activeRecords[userId] and activeRecords[userId].state ~= "Disconnected" then
		return false, string.format("Player %d is already in session", userId)
	end

	-- Check team capacity
	local activeCount = SessionService.GetActivePlayerCount()
	if activeCount >= SessionConfig.MAX_TEAM_SIZE then
		return false, string.format("Team session is full (%d/%d)", activeCount, SessionConfig.MAX_TEAM_SIZE)
	end

	-- 1. Create session record in Joining state
	local record: SessionConfig.PlayerSessionRecord = {
		userId = userId,
		username = player.Name,
		state = "Joining",
		score = 0,
		lives = SessionConfig.DEFAULT_LIVES,
		joinTime = os.clock(),
		planeModel = nil,
	}

	activeRecords[userId] = record
	syncPlayerReplication(record)

	-- 2. Spawn player plane
	local plane = AircraftService.SpawnPlaneForPlayer(player)
	record.planeModel = plane
	if plane then
		plane:SetAttribute("OwnerUserId", userId)
		plane:SetAttribute("State", "Active")
	end

	-- 3. Transition to Active state
	record.state = "Active"
	syncPlayerReplication(record)

	-- 4. If mission is idle, start default mission (only during active gameplay session)
	if RunService:IsRunning() and WaveService.GetState() == "Idle" then
		WaveService.StartMission(nil)
	end

	-- Notify observers
	for _, cb in ipairs(stateChangeCallbacks) do
		task.spawn(cb, userId, "Joining", "Active")
	end
	for _, cb in ipairs(membershipCallbacks) do
		task.spawn(cb, SessionService.GetActivePlayerCount())
	end

	print(string.format("[SessionService] Player %s (%d) joined team session (Total: %d/%d).",
		player.Name, userId, SessionService.GetActivePlayerCount(), SessionConfig.MAX_TEAM_SIZE))
	return true, nil
end

--[[
	Removes a player from the team session (e.g. disconnect or kick).
	Deterministic cleanup without breaking wave progression.
]]
function SessionService.RemovePlayer(userId: number): boolean
	local record = activeRecords[userId]
	if not record then
		return false
	end

	local oldState = record.state
	record.state = "Disconnected"
	syncPlayerReplication(record)

	-- Despawn player aircraft cleanly
	local player = Players:GetPlayerByUserId(userId)
	if player then
		AircraftService.DespawnPlaneForPlayer(player)
	elseif record.planeModel and record.planeModel.Parent then
		record.planeModel:Destroy()
	end
	record.planeModel = nil

	-- Remove replication folder
	removePlayerReplication(userId)
	activeRecords[userId] = nil

	-- Notify observers
	for _, cb in ipairs(stateChangeCallbacks) do
		task.spawn(cb, userId, oldState, "Disconnected")
	end

	local remainingActive = SessionService.GetActivePlayerCount()
	for _, cb in ipairs(membershipCallbacks) do
		task.spawn(cb, remainingActive)
	end

	print(string.format("[SessionService] Player %s (%d) removed from team session (Remaining: %d).",
		record.username, userId, remainingActive))

	-- If all players left during an active mission, reset mission to Idle
	if remainingActive == 0 and WaveService.GetState() ~= "Idle" then
		print("[SessionService] All team members left; resetting active mission to Lobby/Idle.")
		WaveService.ResetMission()
	end

	return true
end

--[[
	Authoritatively sets the lifecycle state of a player.
	Enforces state machine rules and replicates changes.
]]
function SessionService.SetPlayerState(userId: number, newState: SessionConfig.PlayerLifecycleState): boolean
	local record = activeRecords[userId]
	if not record then
		warn(string.format("[SessionService] Cannot set state for unknown player %d", userId))
		return false
	end

	if not SessionConfig.IsValidState(newState) then
		warn(string.format("[SessionService] Invalid target state '%s'", tostring(newState)))
		return false
	end

	local oldState = record.state
	if oldState == newState then
		return true
	end

	if not SessionConfig.CanTransition(oldState, newState) then
		warn(string.format("[SessionService] Illegal state transition for player %d: '%s' -> '%s'",
			userId, oldState, newState))
		return false
	end

	record.state = newState
	if record.planeModel and record.planeModel.Parent then
		record.planeModel:SetAttribute("State", newState)
	end
	syncPlayerReplication(record)

	for _, cb in ipairs(stateChangeCallbacks) do
		task.spawn(cb, userId, oldState, newState)
	end

	return true
end

--[[
	Returns the current lifecycle state of a player, or nil if not registered.
]]
function SessionService.GetPlayerState(userId: number): SessionConfig.PlayerLifecycleState?
	local record = activeRecords[userId]
	return record and record.state or nil
end

--[[
	Returns a copy of the player session record, or nil if not registered.
]]
function SessionService.GetPlayerRecord(userId: number): SessionConfig.PlayerSessionRecord?
	local record = activeRecords[userId]
	if not record then
		return nil
	end
	return {
		userId = record.userId,
		username = record.username,
		state = record.state,
		score = record.score,
		lives = record.lives,
		joinTime = record.joinTime,
		planeModel = record.planeModel,
	}
end

--[[
	Returns the count of active players in the team session.
]]
function SessionService.GetActivePlayerCount(): number
	local count = 0
	for _, record in pairs(activeRecords) do
		if record.state ~= "Disconnected" then
			count += 1
		end
	end
	return count
end

--[[
	Returns all active player records in the session.
]]
function SessionService.GetAllPlayers(): { [number]: SessionConfig.PlayerSessionRecord }
	local copy: { [number]: SessionConfig.PlayerSessionRecord } = {}
	for id, record in pairs(activeRecords) do
		copy[id] = {
			userId = record.userId,
			username = record.username,
			state = record.state,
			score = record.score,
			lives = record.lives,
			joinTime = record.joinTime,
			planeModel = record.planeModel,
		}
	end
	return copy
end

--[[
	Authoritatively adds score to a player.
]]
function SessionService.AddScore(userId: number, amount: number): number
	local record = activeRecords[userId]
	if not record or amount <= 0 then
		return record and record.score or 0
	end

	record.score += math.floor(amount)
	syncPlayerReplication(record)
	return record.score
end

--[[
	Authoritatively deducts a life from a player.
]]
function SessionService.DeductLife(userId: number): number
	local record = activeRecords[userId]
	if not record then
		return 0
	end

	record.lives = math.max(0, record.lives - 1)
	syncPlayerReplication(record)
	return record.lives
end

--[[
	Registers a callback for player lifecycle state changes. Returns an unsubscribe function.
]]
function SessionService.OnPlayerStateChanged(callback: PlayerStateCallback): () -> ()
	table.insert(stateChangeCallbacks, callback)
	return function()
		local idx = table.find(stateChangeCallbacks, callback)
		if idx then
			table.remove(stateChangeCallbacks, idx)
		end
	end
end

--[[
	Registers a callback for team membership count changes. Returns an unsubscribe function.
]]
function SessionService.OnTeamMembershipChanged(callback: MembershipCallback): () -> ()
	table.insert(membershipCallbacks, callback)
	return function()
		local idx = table.find(membershipCallbacks, callback)
		if idx then
			table.remove(membershipCallbacks, idx)
		end
	end
end

--[[
	Resets the team session to clean state.
]]
function SessionService.ResetSession()
	for _, record in pairs(activeRecords) do
		record.score = 0
		record.lives = SessionConfig.DEFAULT_LIVES
		record.state = "Active"
		syncPlayerReplication(record)
	end
end

--[[
	Initializes SessionService and connects PlayerAdded/PlayerRemoving handlers. Idempotent.
]]
function SessionService.Initialize()
	if isInitialized then
		return
	end
	isInitialized = true

	getTeamStateFolder()

	if RunService:IsRunning() then
		playerAddedConn = Players.PlayerAdded:Connect(function(player)
			SessionService.AddPlayer(player)
		end)

		playerRemovingConn = Players.PlayerRemoving:Connect(function(player)
			SessionService.RemovePlayer(player.UserId)
		end)

		for _, player in ipairs(Players:GetPlayers()) do
			task.spawn(function()
				SessionService.AddPlayer(player)
			end)
		end
	end

	print("[SessionService] Co-op player state and team session service initialized.")
end

--[[
	Returns true if SessionService is initialized.
]]
function SessionService.IsInitialized(): boolean
	return isInitialized
end

--[[
	Tears down SessionService, cleans connections, and clears state.
]]
function SessionService._Teardown()
	if playerAddedConn then
		playerAddedConn:Disconnect()
		playerAddedConn = nil
	end
	if playerRemovingConn then
		playerRemovingConn:Disconnect()
		playerRemovingConn = nil
	end

	for userId, record in pairs(activeRecords) do
		if record.planeModel then
			AircraftService.DespawnPlaneForPlayer(userId)
		end
	end

	local container = ReplicatedStorage:FindFirstChild("TeamState")
	if container then
		container:ClearAllChildren()
	end

	activeRecords = {}
	stateChangeCallbacks = {}
	membershipCallbacks = {}
	isInitialized = false
end

return SessionService
