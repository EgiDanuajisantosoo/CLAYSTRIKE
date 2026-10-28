--!strict
--[[
	WaveService.luau
	Authoritative server wave manager and mission progression orchestrator.
	Task: CLAY-020 (Wave Manager & Mission Wave Config)

	RESPONSIBILITIES:
	- Loads data-driven wave configurations from WaveConfig.
	- Spawns enemy formations in authored sequence with exact timing.
	- Ensures wave advances ONLY when all enemies in the current wave are resolved (defeated or culled).
	- Broadcasts authoritative game state and wave progression to clients.
	- Deterministic mission start, stop, and reset without orphaned tasks or instances.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local WaveConfig = require(SharedFolder:WaitForChild("WaveConfig"))
if (WaveConfig :: any).GetDefaultMission == nil then
	WaveConfig = require(SharedFolder:WaitForChild("WaveConfig"):Clone())
end
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
local DifficultyConfig = require(SharedFolder:WaitForChild("DifficultyConfig"))

local EnemyService = require(script.Parent:WaitForChild("EnemyService"))
local RemoteManager = require(script.Parent:WaitForChild("RemoteManager"))

export type WaveState = "Idle" | "Intermission" | "Spawning" | "Active" | "Completed" | "Failed"

type QueueItem = {
	archetypeId: string,
	spawnY: number,
	dueDelay: number, -- Time in seconds remaining before this spawn triggers
	retryCount: number, -- Retries attempted so far (0 = initial try, max 2 retries = 3 attempts total)
	healthOverride: number?,
	scoreOverride: number?,
}

local WaveService = {}

local isInitialized = false
local currentState: WaveState = "Idle"
local currentMission: WaveConfig.MissionConfig? = nil
local currentWaveIndex = 0
local intermissionTimer = 0
local spawnQueue: { QueueItem } = {}
local activeWaveEnemyIds: { [string]: boolean } = {}
local missionStartTime = 0
local heartbeatConnection: RBXScriptConnection? = nil

type StateCallback = (state: WaveState, waveNumber: number, details: any) -> ()
local stateCallbacks: { StateCallback } = {}

-- Broadcasts GameStateChanged to network clients and local observers
local function broadcastState(stateName: string, details: { [string]: any }?)
	if RemoteManager.BroadcastGameState and RemoteManager.IsInitialized() then
		RemoteManager.BroadcastGameState(stateName, details)
	end

	for _, cb in ipairs(stateCallbacks) do
		task.spawn(cb, currentState, currentWaveIndex, details)
	end
end

local forcedPlayerCount: number? = nil
local waveCheckpointPlayerCount: number = 1
local waveScaling: DifficultyConfig.ScalingFactors = DifficultyConfig.GetScaling(1)

-- Helper to safely resolve SessionService
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
	Starts a wave at the given wave index.
	Authoritatively samples active player count checkpoint and applies co-op difficulty scaling.
]]
local function beginWave(waveIdx: number)
	if not currentMission then
		return
	end

	local wave = currentMission.waves[waveIdx]
	if not wave then
		currentState = "Completed"
		local totalTime = os.clock() - missionStartTime
		broadcastState("MissionSuccess", {
			totalWaves = #currentMission.waves,
			missionDuration = totalTime,
		})
		print(string.format("[WaveService] Mission '%s' completed successfully in %.1fs!", currentMission.missionName, totalTime))
		return
	end

	-- Sample difficulty scaling checkpoint based on active players at wave start
	local activePlayers = 1
	if forcedPlayerCount ~= nil then
		activePlayers = forcedPlayerCount
	else
		local ss = getSessionService()
		if ss and ss.IsInitialized and ss.IsInitialized() then
			local count = ss.GetActivePlayerCount()
			activePlayers = if count > 0 then count else 1
		end
	end
	waveCheckpointPlayerCount = math.clamp(activePlayers, 1, 4)
	waveScaling = DifficultyConfig.GetScaling(waveCheckpointPlayerCount)

	currentWaveIndex = waveIdx
	currentState = "Spawning"
	activeWaveEnemyIds = {}
	spawnQueue = {}

	for _, entry in ipairs(wave.spawns) do
		local baseCount = if entry.count ~= nil then entry.count else 1
		local scaledCount = DifficultyConfig.CalculateSpawnCount(baseCount, waveCheckpointPlayerCount)
		local spawnInterval = if entry.spawnInterval ~= nil then entry.spawnInterval else 0.5

		local def = EnemyConfig.GetEnemy(entry.archetypeId)
		local scaledHealth = if def then DifficultyConfig.CalculateHealth(def.maxHealth, waveCheckpointPlayerCount, false) else nil
		local scaledReward = if def then DifficultyConfig.CalculateReward(def.scoreValue, waveCheckpointPlayerCount) else nil

		for i = 1, scaledCount do
			local delay = if i == 1 then entry.delayAfterPrev else spawnInterval
			table.insert(spawnQueue, {
				archetypeId = entry.archetypeId,
				spawnY = entry.spawnY,
				dueDelay = delay,
				retryCount = 0,
				healthOverride = scaledHealth,
				scoreOverride = scaledReward,
			})
		end
	end

	local totalEnemies = #spawnQueue
	broadcastState("WaveActive", {
		waveNumber = waveIdx,
		remainingEnemies = totalEnemies,
	})
	print(string.format("[WaveService] Wave %d ('%s') started with %d-player scaling (x%.2f HP, x%.2f spawns). Total enemies: %d.",
		waveIdx, wave.waveName, waveCheckpointPlayerCount, waveScaling.healthMult, waveScaling.spawnCountMult, totalEnemies))
end

--[[
	Authoritative simulation step for WaveService.
	Can be called directly by unit tests or via Heartbeat.
]]
function WaveService.Step(dt: number)
	if dt <= 0 or currentState == "Failed" or currentState == "Completed" or currentState == "Idle" then
		return
	end

	if currentState == "Intermission" then
		intermissionTimer -= dt
		if intermissionTimer <= 0 then
			intermissionTimer = 0
			beginWave(currentWaveIndex + 1)
		end

	elseif currentState == "Spawning" then
		if #spawnQueue > 0 then
			local nextItem = spawnQueue[1]
			nextItem.dueDelay -= dt
			if nextItem.dueDelay <= 0 then
				local spawnPos = Vector3.new(
					GameConfig.Arena.MaxX + 5,
					nextItem.spawnY,
					GameConfig.Arena.PlayPlaneZ
				)

				local model, err = EnemyService.SpawnEnemy(nextItem.archetypeId, spawnPos, nextItem.healthOverride, nextItem.scoreOverride)
				if model then
					-- Successfully spawned: remove from queue and track
					table.remove(spawnQueue, 1)
					local enemyId = model:GetAttribute("EnemyId") :: string
					activeWaveEnemyIds[enemyId] = true
				else
					-- Failed attempt: retry up to maxRetries = 2 (3 attempts total) with 0.5s pause
					warn(string.format("[WaveService] Failed to spawn enemy archetype '%s' (attempt %d/3): %s",
						nextItem.archetypeId, nextItem.retryCount + 1, tostring(err)))
					if nextItem.retryCount < 2 then
						nextItem.retryCount += 1
						nextItem.dueDelay = 0.5
					else
						-- Exhausted 3 attempts: fail mission and perform deterministic cleanup
						table.remove(spawnQueue, 1)
						currentState = "Failed"
						spawnQueue = {}
						activeWaveEnemyIds = {}
						EnemyService.CleanupAll()

						local failReason = string.format("Failed to spawn '%s' after 3 attempts: %s", nextItem.archetypeId, tostring(err))
						broadcastState("MissionFailed", {
							waveReached = currentWaveIndex,
							failureReason = string.sub(failReason, 1, 100),
						})
						warn(string.format("[WaveService] Mission failed on Wave %d: %s", currentWaveIndex, failReason))
						return
					end
				end
			end
		else
			-- All items in queue have been spawned; transition to Active combat state
			currentState = "Active"
		end

	elseif currentState == "Active" then
		-- Check if all spawned enemies are resolved (either defeated or culled offscreen)
		local remainingCount = 0
		for id, _ in pairs(activeWaveEnemyIds) do
			if EnemyService.GetActiveEnemy(id) ~= nil then
				remainingCount += 1
			end
		end

		if remainingCount == 0 then
			-- Wave is completely resolved!
			if currentMission and currentWaveIndex < #currentMission.waves then
				local nextWave = currentMission.waves[currentWaveIndex + 1]
				currentState = "Intermission"
				intermissionTimer = nextWave.delayBeforeWave
				broadcastState("Intermission", {
					countdown = nextWave.delayBeforeWave,
					nextWave = currentWaveIndex + 1,
				})
				print(string.format("[WaveService] Wave %d cleared! Intermission for %.1fs until Wave %d.", currentWaveIndex, nextWave.delayBeforeWave, currentWaveIndex + 1))
			else
				currentState = "Completed"
				local totalTime = os.clock() - missionStartTime
				broadcastState("MissionSuccess", {
					totalWaves = if currentMission then #currentMission.waves else currentWaveIndex,
					missionDuration = totalTime,
				})
				print("[WaveService] All mission waves cleared! Mission Success.")
			end
		end
	end
end

--[[
	Starts execution of a mission by ID, custom MissionConfig, or default if nil.
	Returns (success: boolean, error: string?).
]]
function WaveService.StartMission(missionIdOrConfig: (string | WaveConfig.MissionConfig)?): (boolean, string?)
	local mission: WaveConfig.MissionConfig? = nil
	if typeof(missionIdOrConfig) == "table" then
		mission = missionIdOrConfig :: WaveConfig.MissionConfig
	elseif typeof(missionIdOrConfig) == "string" then
		mission = WaveConfig.GetMission(missionIdOrConfig)
	else
		mission = WaveConfig.GetDefaultMission()
	end

	if not mission then
		return false, string.format("Unknown mission: '%s'", tostring(missionIdOrConfig))
	end

	local valid, valErr = WaveConfig.ValidateMission(mission)
	if not valid then
		return false, string.format("Invalid mission config: %s", tostring(valErr))
	end

	WaveService.ResetMission()

	currentMission = mission
	missionStartTime = os.clock()
	currentWaveIndex = 0

	local firstWave = mission.waves[1]
	currentState = "Intermission"
	intermissionTimer = firstWave.delayBeforeWave

	broadcastState("Intermission", {
		countdown = firstWave.delayBeforeWave,
		nextWave = 1,
	})

	print(string.format("[WaveService] Started mission '%s'. Intermission for %.1fs before Wave 1.", mission.missionName, firstWave.delayBeforeWave))
	return true, nil
end

--[[
	Stops and cleans up the active mission immediately.
]]
function WaveService.ResetMission()
	currentState = "Idle"
	currentWaveIndex = 0
	intermissionTimer = 0
	spawnQueue = {}
	activeWaveEnemyIds = {}
	currentMission = nil

	EnemyService.CleanupAll()

	-- Broadcast authoritative reset to clients using existing Lobby state contract
	broadcastState("Lobby", {
		countdown = 0,
	})
end

--[[
	Returns the current wave state machine state.
]]
function WaveService.GetState(): WaveState
	return currentState
end

--[[
	Returns the active player count sampled at the start of the current wave.
]]
function WaveService.GetWaveCheckpointPlayerCount(): number
	return waveCheckpointPlayerCount
end

--[[
	Returns the scaling factors applied to the current wave.
]]
function WaveService.GetWaveScaling(): DifficultyConfig.ScalingFactors
	return waveScaling
end

--[[
	Overrides the active player count for unit testing and deterministic simulation.
]]
function WaveService.SetForcedPlayerCount(forcedCount: number?)
	forcedPlayerCount = forcedCount
end

--[[
	Returns current active wave number (0 if Idle).
]]
function WaveService.GetCurrentWaveNumber(): number
	return currentWaveIndex
end

--[[
	Returns total unresolved enemies remaining in the current active wave.
]]
function WaveService.GetRemainingEnemiesInWave(): number
	local remaining = #spawnQueue
	for id, _ in pairs(activeWaveEnemyIds) do
		if EnemyService.GetActiveEnemy(id) ~= nil then
			remaining += 1
		end
	end
	return remaining
end

--[[
	Registers a callback for wave state transitions. Returns an unsubscribe function.
]]
function WaveService.OnWaveStateChanged(callback: StateCallback): () -> ()
	table.insert(stateCallbacks, callback)
	return function()
		local idx = table.find(stateCallbacks, callback)
		if idx then
			table.remove(stateCallbacks, idx)
		end
	end
end

--[[
	Initializes WaveService and binds to RunService.Heartbeat. Idempotent.
]]
function WaveService.Initialize()
	if isInitialized then
		return
	end
	isInitialized = true

	if heartbeatConnection == nil and RunService:IsRunning() then
		heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
			WaveService.Step(dt)
		end)
	end

	print("[WaveService] Authoritative wave progression service initialized.")
end

--[[
	Returns true if WaveService is currently initialized.
]]
function WaveService.IsInitialized(): boolean
	return isInitialized
end

--[[
	Cleans up all mission state, timers, enemies, and disconnects Heartbeat loop.
]]
function WaveService._Teardown()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end

	WaveService.ResetMission()
	stateCallbacks = {}
	isInitialized = false
end

return WaveService
