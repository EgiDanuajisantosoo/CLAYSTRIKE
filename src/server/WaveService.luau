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

local EnemyService = require(script.Parent:WaitForChild("EnemyService"))
local RemoteManager = require(script.Parent:WaitForChild("RemoteManager"))

export type WaveState = "Idle" | "Intermission" | "Spawning" | "Active" | "Completed"

type QueueItem = {
	entry: WaveConfig.SpawnEntry,
	dueDelay: number, -- Time in seconds remaining before this spawn triggers
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

--[[
	Starts a wave at the given wave index.
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

	currentWaveIndex = waveIdx
	currentState = "Spawning"
	activeWaveEnemyIds = {}
	spawnQueue = {}

	for _, entry in ipairs(wave.spawns) do
		table.insert(spawnQueue, {
			entry = entry,
			dueDelay = entry.delayAfterPrev,
		})
	end

	local totalEnemies = #wave.spawns
	broadcastState("WaveActive", {
		waveNumber = waveIdx,
		remainingEnemies = totalEnemies,
	})
	print(string.format("[WaveService] Wave %d ('%s') started. Spawning %d enemies.", waveIdx, wave.waveName, totalEnemies))
end

--[[
	Authoritative simulation step for WaveService.
	Can be called directly by unit tests or via Heartbeat.
]]
function WaveService.Step(dt: number)
	if dt <= 0 then
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
				table.remove(spawnQueue, 1)

				local entry = nextItem.entry
				local spawnPos = Vector3.new(
					GameConfig.Arena.MaxX + 5,
					entry.spawnY,
					GameConfig.Arena.PlayPlaneZ
				)

				local model, err = EnemyService.SpawnEnemy(entry.archetypeId, spawnPos)
				if model then
					local enemyId = model:GetAttribute("EnemyId") :: string
					activeWaveEnemyIds[enemyId] = true
				else
					warn(string.format("[WaveService] Failed to spawn enemy archetype '%s': %s", entry.archetypeId, tostring(err)))
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
	Starts execution of a mission by ID (or default if nil).
	Returns (success: boolean, error: string?).
]]
function WaveService.StartMission(missionId: string?): (boolean, string?)
	local mission = if missionId then WaveConfig.GetMission(missionId) else WaveConfig.GetDefaultMission()
	if not mission then
		return false, string.format("Unknown mission ID: '%s'", tostring(missionId))
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
end

--[[
	Returns the current wave state machine state.
]]
function WaveService.GetState(): WaveState
	return currentState
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

	if heartbeatConnection == nil then
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
