--!strict
--[[
	MissionService.luau
	Authoritative server orchestrator for mission lifecycle state machine and multiplayer join/leave handling.
	Task: CLAY-025 (Mission State Machine & Join/Leave Handling)

	RESPONSIBILITIES:
	- Strict authoritative state machine: Lobby -> Starting -> InProgress -> Boss -> Success / Failed -> Reset -> Lobby.
	- Enforces valid state transitions and guards against duplicate end events.
	- Coordinates join/leave events, empty server resets, and team wipe detection.
	- Broadcasts game state, mission timer, and wave progression via RemoteManager.
	- Fully decoupled, deterministic, and unit-tested without side effects.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local MissionStateConfig = require(SharedFolder:WaitForChild("MissionStateConfig"))
local WaveConfig = require(SharedFolder:WaitForChild("WaveConfig"))

local Services = ServerScriptService:WaitForChild("Services")
local WaveService = require(Services:WaitForChild("WaveService"))
local EnemyService = require(Services:WaitForChild("EnemyService"))
local SessionService = require(Services:WaitForChild("SessionService"))
local RemoteManager = require(Services:WaitForChild("RemoteManager"))

export type StateChangeCallback = (oldState: MissionStateConfig.MissionState, newState: MissionStateConfig.MissionState, details: any?) -> ()

local MissionService = {}

local currentState: MissionStateConfig.MissionState = "Lobby"
local currentMissionId: string = "default_mission"
local missionStartTime: number = 0
local isInitialized = false

local countdownTimer: number = 0
local startingThread: thread? = nil
local stateChangeCallbacks: { StateChangeCallback } = {}

-- Unsubscribe handles for connected dependencies
local unsubsSessionState: (() -> ())? = nil
local unsubsTeamMembership: (() -> ())? = nil
local unsubsWaveState: (() -> ())? = nil

--[[
	Authoritatively broadcasts the current game state to clients and fires local observers.
]]
local function broadcastState(networkState: string, details: { [string]: any }?)
	if RemoteManager.BroadcastGameState and RemoteManager.IsInitialized() then
		RemoteManager.BroadcastGameState(networkState, details)
	end
end

local function fireCallbacks(oldState: MissionStateConfig.MissionState, newState: MissionStateConfig.MissionState, details: any?)
	for _, cb in ipairs(stateChangeCallbacks) do
		task.spawn(cb, oldState, newState, details)
	end
end

--[[
	Returns the current authoritative mission state.
]]
function MissionService.GetState(): MissionStateConfig.MissionState
	return currentState
end

--[[
	Returns true if the mission is currently in an active gameplay state (Starting, InProgress, or Boss).
]]
function MissionService.IsActive(): boolean
	return currentState == "Starting" or currentState == "InProgress" or currentState == "Boss"
end

--[[
	Authoritatively transitions to a new mission state.
	Validates against MissionStateConfig.CanTransition and guards against duplicate terminal events.
	Returns (success: boolean, errorMessage: string?).
]]
function MissionService.TransitionTo(
	newState: MissionStateConfig.MissionState,
	details: any?
): (boolean, string?)
	if not MissionStateConfig.IsValidState(newState) then
		return false, string.format("Invalid mission state '%s'", tostring(newState))
	end

	local oldState = currentState
	if oldState == newState then
		return true, nil
	end

	-- Guard against duplicate end events: terminal states cannot re-trigger another terminal state
	if (oldState == "Success" or oldState == "Failed") and (newState == "Success" or newState == "Failed") then
		return false, string.format("Mission already concluded in terminal state '%s'; ignoring duplicate '%s'", oldState, newState)
	end

	if not MissionStateConfig.CanTransition(oldState, newState) then
		return false, string.format("Illegal state transition from '%s' to '%s'", oldState, newState)
	end

	currentState = newState

	-- Map internal mission states to public network contracts
	if newState == "Lobby" then
		broadcastState("Lobby", {
			countdown = if details and details.countdown ~= nil then details.countdown else 0,
		})
	elseif newState == "Starting" then
		broadcastState("Lobby", {
			countdown = if details and details.countdown ~= nil then details.countdown else MissionStateConfig.COUNTDOWN_DURATION,
		})
	elseif newState == "InProgress" then
		local waveNum = WaveService.GetCurrentWaveNumber()
		local remaining = WaveService.GetRemainingEnemiesInWave()
		broadcastState("WaveActive", {
			waveNumber = math.max(1, waveNum),
			remainingEnemies = remaining,
		})
	elseif newState == "Boss" then
		broadcastState("BossPhase", {
			bossName = if details and details.bossName then details.bossName else "ClayTitan",
			phaseNumber = if details and details.phaseNumber then details.phaseNumber else 1,
		})
	elseif newState == "Success" then
		local duration = if missionStartTime > 0 then os.clock() - missionStartTime else 0
		broadcastState("MissionSuccess", {
			totalWaves = if details and details.totalWaves then details.totalWaves else math.max(1, WaveService.GetCurrentWaveNumber()),
			missionDuration = if details and details.missionDuration then details.missionDuration else duration,
		})
	elseif newState == "Failed" then
		local waveReached = WaveService.GetCurrentWaveNumber()
		local reason = if details and details.failureReason then details.failureReason else "Mission Failed"
		broadcastState("MissionFailed", {
			waveReached = math.max(1, waveReached),
			failureReason = string.sub(reason, 1, 100),
		})
	elseif newState == "Reset" then
		-- Execute full cleanup across services
		if startingThread then
			task.cancel(startingThread)
			startingThread = nil
		end
		WaveService.ResetMission()
		EnemyService.CleanupAll()

		-- Transition smoothly from Reset into Lobby
		currentState = "Lobby"
		broadcastState("Lobby", { countdown = 0 })
		fireCallbacks(oldState, "Reset", details)
		fireCallbacks("Reset", "Lobby", { countdown = 0 })
		return true, nil
	end

	fireCallbacks(oldState, newState, details)
	print(string.format("[MissionService] State changed: '%s' -> '%s'.", oldState, newState))
	return true, nil
end

--[[
	Starts a mission, transitioning Lobby -> Starting -> InProgress.
	Optional countdown can be specified (default: MissionStateConfig.COUNTDOWN_DURATION).
	Returns (success: boolean, errorMessage: string?).
]]
function MissionService.StartMission(
	missionIdOrConfig: (string | WaveConfig.MissionConfig)?,
	countdown: number?
): (boolean, string?)
	if currentState ~= "Lobby" and currentState ~= "Reset" then
		return false, string.format("Cannot start mission from state '%s'; must be in 'Lobby'", currentState)
	end

	if startingThread then
		task.cancel(startingThread)
		startingThread = nil
	end

	local delaySeconds = if countdown ~= nil then countdown else MissionStateConfig.COUNTDOWN_DURATION
	local ok, err = MissionService.TransitionTo("Starting", { countdown = delaySeconds })
	if not ok then
		return false, err
	end

	if delaySeconds <= 0 then
		-- Instant launch
		missionStartTime = os.clock()
		local transOk, transErr = MissionService.TransitionTo("InProgress")
		if not transOk then
			return false, transErr
		end
		WaveService.StartMission(missionIdOrConfig)
	else
		-- Counted launch
		startingThread = task.delay(delaySeconds, function()
			startingThread = nil
			if currentState == "Starting" then
				missionStartTime = os.clock()
				MissionService.TransitionTo("InProgress")
				WaveService.StartMission(missionIdOrConfig)
			end
		end)
	end

	return true, nil
end

--[[
	Authoritatively completes the active mission with success.
	Guaranteed single-trigger; rejects duplicate calls.
]]
function MissionService.CompleteMission(details: { totalWaves: number?, missionDuration: number? }?): (boolean, string?)
	if currentState ~= "InProgress" and currentState ~= "Boss" then
		return false, string.format("Cannot complete mission from non-active state '%s'", currentState)
	end

	local duration = if missionStartTime > 0 then os.clock() - missionStartTime else 0
	return MissionService.TransitionTo("Success", {
		totalWaves = if details and details.totalWaves then details.totalWaves else math.max(1, WaveService.GetCurrentWaveNumber()),
		missionDuration = if details and details.missionDuration then details.missionDuration else duration,
	})
end

--[[
	Authoritatively marks the mission as failed.
	Guaranteed single-trigger; rejects duplicate calls.
]]
function MissionService.FailMission(reason: string?): (boolean, string?)
	if currentState ~= "Starting" and currentState ~= "InProgress" and currentState ~= "Boss" then
		return false, string.format("Cannot fail mission from non-active state '%s'", currentState)
	end

	local failReason = reason or "Mission objective failed"
	return MissionService.TransitionTo("Failed", {
		waveReached = math.max(1, WaveService.GetCurrentWaveNumber()),
		failureReason = string.sub(failReason, 1, 100),
	})
end

--[[
	Authoritatively resets the mission to a clean Lobby state.
	Idempotent and safe against race conditions.
]]
function MissionService.ResetMission(): boolean
	if startingThread then
		task.cancel(startingThread)
		startingThread = nil
	end

	if currentState == "Lobby" then
		WaveService.ResetMission()
		EnemyService.CleanupAll()
		return true
	end

	local ok, err = MissionService.TransitionTo("Reset")
	if not ok then
		-- Fallback force reset if in an unusual state
		currentState = "Lobby"
		WaveService.ResetMission()
		EnemyService.CleanupAll()
		broadcastState("Lobby", { countdown = 0 })
	end

	return true
end

--[[
	Checks if all active members of the co-op session have been defeated with 0 lives.
	If wiped, authoritatively triggers FailMission.
]]
local function checkTeamWipe()
	if not MissionService.IsActive() then
		return
	end

	local allPlayers = SessionService.GetAllPlayers()
	local activeCount = 0
	local downedWithoutLives = 0

	for _, rec in pairs(allPlayers) do
		if rec.state ~= "Disconnected" then
			activeCount += 1
			if rec.state == "Downed" and rec.lives <= 0 then
				downedWithoutLives += 1
			end
		end
	end

	if activeCount > 0 and downedWithoutLives >= activeCount then
		print(string.format("[MissionService] Team wipe detected (%d/%d players downed with 0 lives). Failing mission.",
			downedWithoutLives, activeCount))
		MissionService.FailMission("Team wipe - all aircraft destroyed")
	end
end

--[[
	Registers a callback for mission state transitions. Returns an unsubscribe function.
]]
function MissionService.OnMissionStateChanged(callback: StateChangeCallback): () -> ()
	table.insert(stateChangeCallbacks, callback)
	return function()
		local idx = table.find(stateChangeCallbacks, callback)
		if idx then
			table.remove(stateChangeCallbacks, idx)
		end
	end
end

--[[
	Initializes MissionService and binds listeners to SessionService and WaveService. Idempotent.
]]
function MissionService.Initialize()
	if isInitialized then
		return
	end
	isInitialized = true

	-- Bind to SessionService player state changes for team wipe detection
	unsubsSessionState = SessionService.OnPlayerStateChanged(function(_userId, _oldState, newState)
		if newState == "Downed" then
			checkTeamWipe()
		end
	end)

	-- Bind to team membership changes: reset if empty during active mission
	unsubsTeamMembership = SessionService.OnTeamMembershipChanged(function(activeCount)
		if activeCount == 0 and MissionService.IsActive() then
			print("[MissionService] All players left during active mission; returning to Lobby.")
			MissionService.ResetMission()
		end
	end)

	-- Bind to WaveService state changes
	unsubsWaveState = WaveService.OnWaveStateChanged(function(waveState, _waveNum, _details)
		if waveState == "Completed" and MissionService.IsActive() then
			MissionService.CompleteMission()
		elseif waveState == "Failed" and MissionService.IsActive() then
			MissionService.FailMission("Wave progression failed")
		end
	end)

	print("[MissionService] Authoritative mission state machine service initialized.")
end

--[[
	Returns true if MissionService is initialized.
]]
function MissionService.IsInitialized(): boolean
	return isInitialized
end

--[[
	Teardown helper for unit tests and clean restarts.
]]
function MissionService._Teardown()
	if startingThread then
		task.cancel(startingThread)
		startingThread = nil
	end

	if unsubsSessionState then
		unsubsSessionState()
		unsubsSessionState = nil
	end
	if unsubsTeamMembership then
		unsubsTeamMembership()
		unsubsTeamMembership = nil
	end
	if unsubsWaveState then
		unsubsWaveState()
		unsubsWaveState = nil
	end

	MissionService.ResetMission()
	stateChangeCallbacks = {}
	isInitialized = false
end

return MissionService
