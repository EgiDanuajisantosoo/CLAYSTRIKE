--!strict
--[[
	WaveManagerTests.luau
	Comprehensive unit tests for WaveService and WaveConfig.
	Task: CLAY-020 (Wave Manager & Mission Wave Config)
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
if (EnemyConfig :: any).Archetypes == nil then
	EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"):Clone())
end

local WaveConfig = require(SharedFolder:WaitForChild("WaveConfig"))
if (WaveConfig :: any).GetDefaultMission == nil then
	WaveConfig = require(SharedFolder:WaitForChild("WaveConfig"):Clone())
end

local sharedGameConfig = SharedFolder:WaitForChild("GameConfig")
local GameConfig = require(sharedGameConfig)
if (GameConfig :: any).CONTRACT_VERSION == nil then
	GameConfig = require(sharedGameConfig:Clone())
end

local RemoteContracts = require(SharedFolder:WaitForChild("RemoteContracts"))

local WaveManagerTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function WaveManagerTests.RunTests(waveServiceModule: any?, enemyServiceModule: any?): {
	total: number,
	passed: number,
	failed: number,
	results: { [number]: TestResult },
}
	local SSS = game:GetService("ServerScriptService")
	local Services = SSS:WaitForChild("Services")

	local EnemyService = enemyServiceModule
	if not EnemyService then
		EnemyService = require(Services:WaitForChild("EnemyService"))
	end

	local WaveService = waveServiceModule
	if not WaveService then
		WaveService = require(Services:WaitForChild("WaveService"))
	end

	local RemoteManager = require(Services:WaitForChild("RemoteManager"))
	local originalIsInitialized = RemoteManager.IsInitialized
	local originalBroadcast = RemoteManager.BroadcastGameState
	RemoteManager.IsInitialized = function()
		return true
	end

	local broadcasts: { { state: string, details: any, payloadValid: boolean } } = {}
	RemoteManager.BroadcastGameState = function(state: string, details: any)
		local payload: RemoteContracts.GameStateChangedPayload = {
			contractVersion = GameConfig.CONTRACT_VERSION,
			serverTimestamp = os.clock(),
			state = state,
			details = details,
		}
		local ok, err = RemoteContracts.ValidateGameStateChanged(payload)
		table.insert(broadcasts, { state = state, details = details, payloadValid = (ok == true and err == nil) })
		if RunService:IsServer() then
			pcall(originalBroadcast, state, details)
		end
	end

	local results: { [number]: TestResult } = {}
	local passedCount = 0
	local failedCount = 0

	local function assertTest(name: string, condition: boolean, errorMsg: string?)
		local testIndex = #results + 1
		if condition then
			passedCount += 1
			results[testIndex] = { name = name, passed = true }
		else
			failedCount += 1
			local failureText = errorMsg or "Assertion failed"
			results[testIndex] = { name = name, passed = false, error = failureText }
			warn(string.format("[WaveManagerTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Clean baseline teardown
	WaveService._Teardown()
	EnemyService._Teardown()
	assertTest("WaveService uninitialized at test start", WaveService.IsInitialized() == false)
	assertTest("WaveService state starts as Idle", WaveService.GetState() == "Idle")
	assertTest("Current wave starts at 0", WaveService.GetCurrentWaveNumber() == 0)

	-- 1. Initialize services
	EnemyService.Initialize()
	WaveService.Initialize()
	assertTest("WaveService is initialized", WaveService.IsInitialized() == true)

	-- 2. Validate canonical default mission config
	local defaultMission = WaveConfig.GetDefaultMission()
	assertTest("Default mission is not nil", defaultMission ~= nil)
	local validDef, errDef = WaveConfig.ValidateMission(defaultMission)
	assertTest("Default mission passes validation", validDef == true and errDef == nil)
	assertTest("Default mission has 3 waves", #defaultMission.waves == 3)

	-- 3. Schema validation edge cases
	local emptyWaveMission: WaveConfig.MissionConfig = {
		missionId = "Bad_Empty",
		missionName = "Empty Waves",
		waves = {},
	}
	local badEmptyValid, _ = WaveConfig.ValidateMission(emptyWaveMission)
	assertTest("Reject mission with empty waves array", badEmptyValid == false)

	local badWaveOrderMission: WaveConfig.MissionConfig = {
		missionId = "Bad_Order",
		missionName = "Bad Wave Order",
		waves = {
			{
				waveNumber = 2, -- Out of order (expected 1)
				waveName = "Out of order wave",
				delayBeforeWave = 1,
				spawns = { { archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 0, delayAfterPrev = 0 } },
			},
		},
	}
	local badOrderValid, _ = WaveConfig.ValidateMission(badWaveOrderMission)
	assertTest("Reject mission with out-of-order wave numbers", badOrderValid == false)

	local badArchetypeWave: WaveConfig.WaveDefinition = {
		waveNumber = 1,
		waveName = "Bad Enemy",
		delayBeforeWave = 1,
		spawns = { { archetypeId = "AlienBossNonExistent", spawnY = 0, delayAfterPrev = 0 } },
	}
	local badArchValid, _ = WaveConfig.ValidateWave(badArchetypeWave)
	assertTest("Reject wave with unknown archetypeId", badArchValid == false)

	-- 3B. Count & spawnInterval schema validation
	local badNegativeCountEntry: WaveConfig.SpawnEntry = {
		archetypeId = EnemyConfig.Archetypes.StraightFlyer,
		spawnY = 0,
		delayAfterPrev = 0,
		count = -1,
	}
	local negCountValid, _ = WaveConfig.ValidateSpawnEntry(badNegativeCountEntry)
	assertTest("Reject SpawnEntry with negative count", negCountValid == false)

	local badFractionalCountEntry: WaveConfig.SpawnEntry = {
		archetypeId = EnemyConfig.Archetypes.StraightFlyer,
		spawnY = 0,
		delayAfterPrev = 0,
		count = 2.5,
	}
	local fracCountValid, _ = WaveConfig.ValidateSpawnEntry(badFractionalCountEntry)
	assertTest("Reject SpawnEntry with fractional count", fracCountValid == false)

	local badNegativeIntervalEntry: WaveConfig.SpawnEntry = {
		archetypeId = EnemyConfig.Archetypes.StraightFlyer,
		spawnY = 0,
		delayAfterPrev = 0,
		count = 2,
		spawnInterval = -0.5,
	}
	local negIntervalValid, _ = WaveConfig.ValidateSpawnEntry(badNegativeIntervalEntry)
	assertTest("Reject SpawnEntry with negative spawnInterval", negIntervalValid == false)

	local validZeroCountEntry: WaveConfig.SpawnEntry = {
		archetypeId = EnemyConfig.Archetypes.StraightFlyer,
		spawnY = 0,
		delayAfterPrev = 0,
		count = 0,
	}
	local zeroCountValid, _ = WaveConfig.ValidateSpawnEntry(validZeroCountEntry)
	assertTest("Accept valid SpawnEntry with count = 0", zeroCountValid == true)

	-- 3C. Finite number enforcement & MAX_SPAWN_COUNT bounds
	local hugeSpawnYEntry: WaveConfig.SpawnEntry = {
		archetypeId = EnemyConfig.Archetypes.StraightFlyer,
		spawnY = math.huge,
		delayAfterPrev = 0,
	}
	local hugeSpawnYValid, _ = WaveConfig.ValidateSpawnEntry(hugeSpawnYEntry)
	assertTest("Reject SpawnEntry with math.huge spawnY", hugeSpawnYValid == false)

	local negHugeSpawnYEntry: WaveConfig.SpawnEntry = {
		archetypeId = EnemyConfig.Archetypes.StraightFlyer,
		spawnY = -math.huge,
		delayAfterPrev = 0,
	}
	local negHugeSpawnYValid, _ = WaveConfig.ValidateSpawnEntry(negHugeSpawnYEntry)
	assertTest("Reject SpawnEntry with -math.huge spawnY", negHugeSpawnYValid == false)

	local hugeDelayEntry: WaveConfig.SpawnEntry = {
		archetypeId = EnemyConfig.Archetypes.StraightFlyer,
		spawnY = 0,
		delayAfterPrev = math.huge,
	}
	local hugeDelayValid, _ = WaveConfig.ValidateSpawnEntry(hugeDelayEntry)
	assertTest("Reject SpawnEntry with math.huge delayAfterPrev", hugeDelayValid == false)

	local hugeIntervalEntry: WaveConfig.SpawnEntry = {
		archetypeId = EnemyConfig.Archetypes.StraightFlyer,
		spawnY = 0,
		delayAfterPrev = 0,
		count = 2,
		spawnInterval = math.huge,
	}
	local hugeIntervalValid, _ = WaveConfig.ValidateSpawnEntry(hugeIntervalEntry)
	assertTest("Reject SpawnEntry with math.huge spawnInterval", hugeIntervalValid == false)

	local hugeCountEntry: WaveConfig.SpawnEntry = {
		archetypeId = EnemyConfig.Archetypes.StraightFlyer,
		spawnY = 0,
		delayAfterPrev = 0,
		count = math.huge,
	}
	local hugeCountValid, _ = WaveConfig.ValidateSpawnEntry(hugeCountEntry)
	assertTest("Reject SpawnEntry with math.huge count", hugeCountValid == false)

	local exceedMaxCountEntry: WaveConfig.SpawnEntry = {
		archetypeId = EnemyConfig.Archetypes.StraightFlyer,
		spawnY = 0,
		delayAfterPrev = 0,
		count = 51,
	}
	local exceedMaxValid, _ = WaveConfig.ValidateSpawnEntry(exceedMaxCountEntry)
	assertTest("Reject SpawnEntry with count exceeding MAX_SPAWN_COUNT (51 > 50)", exceedMaxValid == false)

	local boundaryMaxCountEntry: WaveConfig.SpawnEntry = {
		archetypeId = EnemyConfig.Archetypes.StraightFlyer,
		spawnY = 0,
		delayAfterPrev = 0,
		count = 50,
	}
	local boundaryMaxValid, _ = WaveConfig.ValidateSpawnEntry(boundaryMaxCountEntry)
	assertTest("Accept SpawnEntry with count exactly at MAX_SPAWN_COUNT (50)", boundaryMaxValid == true)

	local hugeWaveDelayDef: WaveConfig.WaveDefinition = {
		waveNumber = 1,
		waveName = "Infinite Delay Wave",
		delayBeforeWave = math.huge,
		spawns = { { archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 0, delayAfterPrev = 0 } },
	}
	local hugeWaveDelayValid, _ = WaveConfig.ValidateWave(hugeWaveDelayDef)
	assertTest("Reject WaveDefinition with math.huge delayBeforeWave", hugeWaveDelayValid == false)

	local hugeWaveNumDef: WaveConfig.WaveDefinition = {
		waveNumber = math.huge,
		waveName = "Infinite Wave Num",
		delayBeforeWave = 1,
		spawns = { { archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 0, delayAfterPrev = 0 } },
	}
	local hugeWaveNumValid, _ = WaveConfig.ValidateWave(hugeWaveNumDef)
	assertTest("Reject WaveDefinition with math.huge waveNumber", hugeWaveNumValid == false)

	-- 4. Zero-count entry handling in active wave
	local zeroCountMission: WaveConfig.MissionConfig = {
		missionId = "Test_ZeroCount",
		missionName = "Zero Count Mission",
		waves = {
			{
				waveNumber = 1,
				waveName = "Wave with Zero Count Entry",
				delayBeforeWave = 0.2,
				spawns = {
					{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 0, delayAfterPrev = 0.0, count = 0 },
					{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 10, delayAfterPrev = 0.1, count = 1 },
				},
			},
		},
	}
	local startZeroOk, _ = WaveService.StartMission(zeroCountMission)
	assertTest("StartMission with zero-count entry succeeds", startZeroOk == true)
	WaveService.Step(0.25) -- Step past intermission
	assertTest("Zero-count wave enters Spawning state", WaveService.GetState() == "Spawning")
	assertTest("Zero-count entry skipped: queue contains only 1 spawn", WaveService.GetRemainingEnemiesInWave() == 1)

	WaveService.Step(0.15) -- Spawn the 1 valid enemy
	assertTest("Exactly 1 enemy spawned from zero-count wave", EnemyService.GetActiveEnemyCount() == 1)
	WaveService.Step(0.01)
	assertTest("Zero-count wave transitions to Active state", WaveService.GetState() == "Active")

	EnemyService.CleanupAll()
	WaveService.Step(0.01)
	assertTest("Zero-count single wave completes after valid enemy resolved", WaveService.GetState() == "Completed")
	WaveService.ResetMission()

	-- 5. Enemy Despawn tracking (culling offscreen resolves wave)
	local despawnMission: WaveConfig.MissionConfig = {
		missionId = "Test_Despawn",
		missionName = "Despawn Tracking Mission",
		waves = {
			{
				waveNumber = 1,
				waveName = "Wave with 2 Enemies",
				delayBeforeWave = 0.1,
				spawns = {
					{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 10, delayAfterPrev = 0.0, count = 2, spawnInterval = 0.1 },
				},
			},
		},
	}
	WaveService.StartMission(despawnMission)
	WaveService.Step(0.15) -- Past intermission
	WaveService.Step(0.01) -- First spawn
	WaveService.Step(0.15) -- Second spawn
	WaveService.Step(0.01) -- State to Active
	assertTest("Despawn test spawned 2 active enemies", EnemyService.GetActiveEnemyCount() == 2)
	assertTest("Remaining enemies in wave is 2", WaveService.GetRemainingEnemiesInWave() == 2)

	local activeEnemies = EnemyService.GetAllActiveEnemies()
	local firstEnemyId: string? = nil
	for id, _ in pairs(activeEnemies) do
		firstEnemyId = id
		break
	end
	assertTest("Found active enemy ID to despawn", firstEnemyId ~= nil)
	if firstEnemyId then
		EnemyService.DespawnEnemy(firstEnemyId)
	end
	assertTest("DespawnEnemy removed 1 enemy from EnemyService", EnemyService.GetActiveEnemyCount() == 1)
	assertTest("Despawned enemy decreases wave remaining count to 1", WaveService.GetRemainingEnemiesInWave() == 1)

	-- Resolve second enemy
	EnemyService.CleanupAll()
	WaveService.Step(0.01)
	assertTest("Wave advances/completes when remaining enemy is resolved after despawn", WaveService.GetState() == "Completed")
	WaveService.ResetMission()

	-- 6. Reset during active spawn queue (mid-queue reset)
	local midQueueMission: WaveConfig.MissionConfig = {
		missionId = "Test_MidQueue",
		missionName = "Mid Queue Reset Mission",
		waves = {
			{
				waveNumber = 1,
				waveName = "Delayed Wave",
				delayBeforeWave = 0.1,
				spawns = {
					{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 0, delayAfterPrev = 0.0, count = 3, spawnInterval = 1.0 },
				},
			},
		},
	}
	WaveService.StartMission(midQueueMission)
	WaveService.Step(0.15) -- Past intermission
	WaveService.Step(0.01) -- First enemy spawned, 2 pending
	assertTest("Mid-queue test is currently in Spawning state", WaveService.GetState() == "Spawning")
	assertTest("Mid-queue has 1 spawned and 2 pending in queue", EnemyService.GetActiveEnemyCount() == 1 and WaveService.GetRemainingEnemiesInWave() == 3)

	-- Reset while queue still has pending items
	WaveService.ResetMission()
	assertTest("ResetMission clears state to Idle", WaveService.GetState() == "Idle")
	assertTest("ResetMission clears current wave number to 0", WaveService.GetCurrentWaveNumber() == 0)
	assertTest("ResetMission clears remaining enemies to 0", WaveService.GetRemainingEnemiesInWave() == 0)
	assertTest("ResetMission purges all spawned enemy models", EnemyService.GetActiveEnemyCount() == 0)

	-- 7. Spawn failure policy: retry up to 2 times, then fail mission (never false success)
	local originalSpawnEnemy = EnemyService.SpawnEnemy
	local spawnAttempts = 0
	local enemySvcAny = EnemyService :: any
	enemySvcAny.SpawnEnemy = function(arch: string, pos: Vector3)
		spawnAttempts += 1
		return nil, "Simulated spawn failure"
	end

	local failMission: WaveConfig.MissionConfig = {
		missionId = "Test_FailPolicy",
		missionName = "Failure Policy Mission",
		waves = {
			{
				waveNumber = 1,
				waveName = "Failing Wave",
				delayBeforeWave = 0.1,
				spawns = {
					{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 0, delayAfterPrev = 0.0, count = 1 },
				},
			},
		},
	}

	local observedFinalState: string? = nil
	local observedBroadcastState: string? = nil
	local unsubscribe = WaveService.OnWaveStateChanged(function(state, waveNum, details)
		observedFinalState = state
		if details and details.failureReason then
			observedBroadcastState = "MissionFailed"
		end
	end)

	WaveService.StartMission(failMission)
	WaveService.Step(0.15) -- Past intermission into Spawning

	-- Attempt 1 (initial): fails
	WaveService.Step(0.01)
	assertTest("Attempt 1 fails and triggers retry pause", spawnAttempts == 1)
	assertTest("State remains Spawning during retry pause", WaveService.GetState() == "Spawning")

	-- Advance 0.25s: pause is 0.5s, so no new attempt yet
	WaveService.Step(0.25)
	assertTest("No retry before 0.5s pause expires", spawnAttempts == 1)

	-- Attempt 2 (retry 1): step another 0.3s (total 0.55s) -> fails
	WaveService.Step(0.3)
	assertTest("Attempt 2 (retry 1) triggers after 0.5s pause", spawnAttempts == 2)
	assertTest("State remains Spawning on retry 1 failure", WaveService.GetState() == "Spawning")

	-- Attempt 3 (retry 2): step another 0.55s -> fails -> exhausts 3 attempts
	WaveService.Step(0.55)
	assertTest("Attempt 3 (retry 2) triggers after second 0.5s pause", spawnAttempts == 3)
	assertTest("Wave transitions to Failed state after exhausting 3 attempts", WaveService.GetState() == "Failed")
	assertTest("Failed state callback received internal state 'Failed'", observedFinalState == "Failed")
	assertTest("Failure broadcast dispatched with failureReason", observedBroadcastState == "MissionFailed")

	-- Deterministic cleanup on failure assertions
	assertTest("Failed mission empties remaining spawn queue", WaveService.GetRemainingEnemiesInWave() == 0)
	assertTest("Failed mission purges all active enemies via CleanupAll", EnemyService.GetActiveEnemyCount() == 0)
	local activeEnemiesFolder = Workspace:FindFirstChild("ActiveEnemies")
	assertTest("No orphaned enemy models remaining in ActiveEnemies container", activeEnemiesFolder == nil or #activeEnemiesFolder:GetChildren() == 0)

	-- Remote broadcast validation for MissionFailed
	local latestBroadcast = broadcasts[#broadcasts]
	assertTest("Network broadcast for failure sent state 'MissionFailed'", latestBroadcast ~= nil and latestBroadcast.state == "MissionFailed")
	assertTest("MissionFailed payload passes RemoteContracts deep validation", latestBroadcast ~= nil and latestBroadcast.payloadValid == true)

	-- Simulation steps while Failed do NOT advance waves
	for _ = 1, 10 do
		WaveService.Step(0.1)
	end
	assertTest("Failed state does not falsely advance to Completed or Intermission", WaveService.GetState() == "Failed")

	unsubscribe()
	enemySvcAny.SpawnEnemy = originalSpawnEnemy
	WaveService.ResetMission()
	assertTest("ResetMission recovers from Failed state back to Idle", WaveService.GetState() == "Idle")
	local resetBroadcast = broadcasts[#broadcasts]
	assertTest("ResetMission broadcasts network state 'Lobby'", resetBroadcast ~= nil and resetBroadcast.state == "Lobby")
	assertTest("ResetMission Lobby payload has countdown = 0", resetBroadcast ~= nil and resetBroadcast.details and resetBroadcast.details.countdown == 0)
	assertTest("ResetMission Lobby payload passes RemoteContracts deep validation", resetBroadcast ~= nil and resetBroadcast.payloadValid == true)

	-- 8. Full Multi-Wave Mission Completion (Wave 1 -> Intermission -> Wave 2 -> Completed)
	local fullTwoWaveMission: WaveConfig.MissionConfig = {
		missionId = "Test_FullMission",
		missionName = "Full Two Wave Mission",
		waves = {
			{
				waveNumber = 1,
				waveName = "Wave 1 - Vanguard",
				delayBeforeWave = 0.2,
				spawns = {
					{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 10, delayAfterPrev = 0.0, count = 2, spawnInterval = 0.2 },
				},
			},
			{
				waveNumber = 2,
				waveName = "Wave 2 - Rearguard",
				delayBeforeWave = 0.3,
				spawns = {
					{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = -10, delayAfterPrev = 0.0, count = 1 },
				},
			},
		},
	}

	local startFullOk, _ = WaveService.StartMission(fullTwoWaveMission)
	assertTest("StartMission with fullTwoWaveMission succeeds", startFullOk == true)
	assertTest("Mission starts in Intermission for Wave 1", WaveService.GetState() == "Intermission")

	-- Intermission 1 (0.2s)
	WaveService.Step(0.25)
	assertTest("Wave 1 transitions to Spawning", WaveService.GetState() == "Spawning")
	assertTest("Current wave is 1", WaveService.GetCurrentWaveNumber() == 1)

	-- Spawn both enemies
	WaveService.Step(0.01) -- First enemy
	assertTest("Wave 1 first drone spawned", EnemyService.GetActiveEnemyCount() == 1)
	WaveService.Step(0.25) -- Second enemy
	assertTest("Wave 1 second drone spawned", EnemyService.GetActiveEnemyCount() == 2)
	WaveService.Step(0.01)
	assertTest("Wave 1 transitions to Active", WaveService.GetState() == "Active")

	-- Defeat all Wave 1 enemies
	EnemyService.CleanupAll()
	WaveService.Step(0.01)
	assertTest("Wave 1 cleared transitions to Intermission for Wave 2", WaveService.GetState() == "Intermission")
	assertTest("Intermission points to Wave 2", WaveService.GetCurrentWaveNumber() == 1)

	-- Intermission 2 (0.3s)
	WaveService.Step(0.35)
	assertTest("Wave 2 transitions to Spawning", WaveService.GetState() == "Spawning")
	assertTest("Current wave is now 2", WaveService.GetCurrentWaveNumber() == 2)

	-- Spawn Wave 2 enemy
	WaveService.Step(0.01)
	assertTest("Wave 2 drone spawned", EnemyService.GetActiveEnemyCount() == 1)
	WaveService.Step(0.01)
	assertTest("Wave 2 transitions to Active", WaveService.GetState() == "Active")

	-- Defeat Wave 2 enemy
	EnemyService.CleanupAll()
	WaveService.Step(0.01)
	assertTest("Entire mission transitions to Completed state upon final wave clear", WaveService.GetState() == "Completed")
	assertTest("Final wave number remains 2 upon completion", WaveService.GetCurrentWaveNumber() == 2)
	assertTest("No active enemies left upon mission completion", EnemyService.GetActiveEnemyCount() == 0)

	local successBroadcast = broadcasts[#broadcasts]
	assertTest("Mission completion dispatched MissionSuccess network broadcast", successBroadcast ~= nil and successBroadcast.state == "MissionSuccess")
	assertTest("MissionSuccess payload passes RemoteContracts deep validation", successBroadcast ~= nil and successBroadcast.payloadValid == true)

	-- 9. Clean Teardown
	WaveService._Teardown()
	EnemyService._Teardown()
	RemoteManager.BroadcastGameState = originalBroadcast
	RemoteManager.IsInitialized = originalIsInitialized
	assertTest("WaveService uninitialized after _Teardown()", WaveService.IsInitialized() == false)
	assertTest("EnemyService uninitialized after _Teardown()", EnemyService.IsInitialized() == false)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return WaveManagerTests
