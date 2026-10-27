--!strict
--[[
	WaveManagerTests.luau
	Comprehensive unit tests for WaveService and WaveConfig.
	Task: CLAY-020 (Wave Manager & Mission Wave Config)
]]

local Workspace = game:GetService("Workspace")
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

	-- 4. Start mission with mini 2-wave test mission
	local testMission: WaveConfig.MissionConfig = {
		missionId = "Test_MiniMission",
		missionName = "Test Mini Mission",
		waves = {
			{
				waveNumber = 1,
				waveName = "Wave 1 - Two Drones",
				delayBeforeWave = 0.5,
				spawns = {
					{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 10, delayAfterPrev = 0.0 },
					{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = -10, delayAfterPrev = 0.2 },
				},
			},
			{
				waveNumber = 2,
				waveName = "Wave 2 - One Drone",
				delayBeforeWave = 0.5,
				spawns = {
					{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 0, delayAfterPrev = 0.0 },
				},
			},
		},
	}

	-- Add to mock lookup or pass directly
	local startOk, startErr = WaveService.StartMission(defaultMission.missionId)
	assertTest("StartMission with default mission succeeds", startOk == true and startErr == nil)
	assertTest("State transitions to Intermission before Wave 1", WaveService.GetState() == "Intermission")

	-- Step through intermission delay of wave 1 (2.0s)
	WaveService.Step(1.0)
	assertTest("Still in Intermission at 1.0s elapsed", WaveService.GetState() == "Intermission")

	WaveService.Step(1.1) -- Total 2.1s elapsed, exceeds 2.0s delay
	assertTest("Transitions to Spawning after intermission expires", WaveService.GetState() == "Spawning")
	assertTest("Current wave number is 1", WaveService.GetCurrentWaveNumber() == 1)

	-- 5. Spawn sequencing in Wave 1
	-- In defaultMission wave 1:
	-- Entry 1: delayAfterPrev = 0.0 -> spawns immediately on next step
	WaveService.Step(0.01)
	assertTest("First enemy spawned immediately", EnemyService.GetActiveEnemyCount() == 1)

	-- Entry 2: delayAfterPrev = 1.0 -> step 0.5s -> not yet
	WaveService.Step(0.5)
	assertTest("Second enemy not yet spawned at 0.5s", EnemyService.GetActiveEnemyCount() == 1)

	-- Step another 0.6s -> total 1.1s -> second enemy spawns
	WaveService.Step(0.6)
	assertTest("Second enemy spawned after 1.0s interval", EnemyService.GetActiveEnemyCount() == 2)

	-- Entry 3: delayAfterPrev = 1.0 -> step 1.1s -> third enemy spawns
	WaveService.Step(1.1)
	assertTest("Third enemy spawned after second 1.0s interval", EnemyService.GetActiveEnemyCount() == 3)

	-- Step small dt -> queue is now empty -> transitions to Active
	WaveService.Step(0.01)
	assertTest("Transitions to Active state once all wave enemies are spawned", WaveService.GetState() == "Active")

	-- 6. Wave cannot advance while enemies remain active
	for _ = 1, 10 do
		WaveService.Step(0.1)
	end
	assertTest("Wave does not advance while enemies remain alive", WaveService.GetCurrentWaveNumber() == 1)
	assertTest("State remains Active while enemies remain alive", WaveService.GetState() == "Active")

	-- 7. Wave advances only when active enemies are resolved
	-- Defeat all 3 active enemies
	EnemyService.CleanupAll()
	assertTest("Active enemies cleaned up", EnemyService.GetActiveEnemyCount() == 0)

	-- Step simulation: WaveService detects remainingCount == 0 and advances to Wave 2 Intermission
	WaveService.Step(0.01)
	assertTest("Advances to Intermission for Wave 2 after Wave 1 is cleared", WaveService.GetState() == "Intermission")

	-- 8. ResetMission clears all state, timers, and enemies immediately
	WaveService.ResetMission()
	assertTest("ResetMission sets state to Idle", WaveService.GetState() == "Idle")
	assertTest("ResetMission resets current wave to 0", WaveService.GetCurrentWaveNumber() == 0)
	assertTest("ResetMission leaves 0 active enemies", EnemyService.GetActiveEnemyCount() == 0)

	-- 9. Clean Teardown
	WaveService._Teardown()
	EnemyService._Teardown()
	assertTest("WaveService uninitialized after _Teardown()", WaveService.IsInitialized() == false)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return WaveManagerTests
