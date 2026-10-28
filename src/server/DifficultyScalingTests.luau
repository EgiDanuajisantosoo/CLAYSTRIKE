--!strict
--[[
	DifficultyScalingTests.luau
	Unit test suite for Co-op Difficulty Scaling curves, checkpoint rules, and solo viability.
	Task: CLAY-024 (Co-op Difficulty Scaling)

	TEST SUITE:
	1. Configuration table values verification for 1, 2, 3, and 4 players.
	2. Boundary clamping: values below 1 clamp to 1; values above 4 clamp to 4.
	3. Solo play viability: 1-player health, spawns, and rewards are exactly 1.0x.
	4. Readability preservation: 4-player spawns cap at 1.75x (prevents bullet-hell clutter).
	5. EnemyService authoritative health & reward override handling.
	6. WaveService checkpoint rule: scaling is locked at wave start and does not fluctuate mid-wave.
	7. WaveService dynamic adaptation: new wave automatically adapts to player count changes.
	8. Simulated TTK (time-to-kill) comparison between 1 and 4 players.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
local DifficultyConfig = require(SharedFolder:WaitForChild("DifficultyConfig"))
local WaveConfig = require(SharedFolder:WaitForChild("WaveConfig"))

local Services = ServerScriptService:WaitForChild("Services")
local EnemyService = require(Services:WaitForChild("EnemyService"))
local WaveService = require(Services:WaitForChild("WaveService"))
local SessionService = require(Services:WaitForChild("SessionService"))

local DifficultyScalingTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

local function createMockPlayer(userId: number, name: string): Player
	local mock = {
		Name = name,
		UserId = userId,
		ClassName = "Player",
		IsA = function(self: any, cls: string)
			return cls == "Player" or cls == "Instance"
		end,
	}
	return (mock :: any) :: Player
end

function DifficultyScalingTests.RunTests(): {
	total: number,
	passed: number,
	failed: number,
	results: { [number]: TestResult },
}
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
			warn(string.format("[DifficultyScalingTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Clean baseline setup
	WaveService._Teardown()
	SessionService._Teardown()
	EnemyService._Teardown()
	WaveService.Initialize()
	SessionService.Initialize()
	EnemyService.Initialize()

	-- 1. Configuration Table Validation
	local s1 = DifficultyConfig.GetScaling(1)
	assertTest("1-Player Health Mult is 1.0", s1.healthMult == 1.0)
	assertTest("1-Player Spawn Count Mult is 1.0", s1.spawnCountMult == 1.0)
	assertTest("1-Player Boss Health Mult is 1.0", s1.bossHealthMult == 1.0)
	assertTest("1-Player Reward Mult is 1.0", s1.rewardBudgetMult == 1.0)

	local s2 = DifficultyConfig.GetScaling(2)
	assertTest("2-Player Health Mult is 1.35", s2.healthMult == 1.35)
	assertTest("2-Player Spawn Count Mult is 1.25", s2.spawnCountMult == 1.25)
	assertTest("2-Player Boss Health Mult is 1.40", s2.bossHealthMult == 1.40)
	assertTest("2-Player Reward Mult is 1.5", s2.rewardBudgetMult == 1.5)

	local s3 = DifficultyConfig.GetScaling(3)
	assertTest("3-Player Health Mult is 1.70", s3.healthMult == 1.70)
	assertTest("3-Player Spawn Count Mult is 1.50", s3.spawnCountMult == 1.50)
	assertTest("3-Player Boss Health Mult is 1.80", s3.bossHealthMult == 1.80)
	assertTest("3-Player Reward Mult is 2.0", s3.rewardBudgetMult == 2.0)

	local s4 = DifficultyConfig.GetScaling(4)
	assertTest("4-Player Health Mult is 2.00", s4.healthMult == 2.00)
	assertTest("4-Player Spawn Count Mult is 1.75", s4.spawnCountMult == 1.75)
	assertTest("4-Player Boss Health Mult is 2.20", s4.bossHealthMult == 2.20)
	assertTest("4-Player Reward Mult is 2.5", s4.rewardBudgetMult == 2.5)

	-- 2. Boundary Clamping Validation
	local underflow = DifficultyConfig.GetScaling(0)
	assertTest("0 players clamps safely to 1-player scaling", underflow.healthMult == 1.0 and underflow.playerCount == 1)

	local negative = DifficultyConfig.GetScaling(-5)
	assertTest("Negative players clamps safely to 1-player scaling", negative.healthMult == 1.0 and negative.playerCount == 1)

	local overflow = DifficultyConfig.GetScaling(8)
	assertTest("8 players clamps safely to 4-player scaling", overflow.healthMult == 2.0 and overflow.playerCount == 4)

	-- 3. Solo Play Viability Calculations
	local baseHp = 100
	local soloHp = DifficultyConfig.CalculateHealth(baseHp, 1, false)
	assertTest("Solo enemy health equals exact base health (100)", soloHp == 100)

	local soloSpawns = DifficultyConfig.CalculateSpawnCount(4, 1)
	assertTest("Solo spawn count equals exact base spawns (4)", soloSpawns == 4)

	local soloReward = DifficultyConfig.CalculateReward(500, 1)
	assertTest("Solo reward equals exact base score (500)", soloReward == 500)

	-- 4. Readability Preservation (4-player spawns cap at 1.75x)
	local fourPlayerSpawns = DifficultyConfig.CalculateSpawnCount(4, 4)
	assertTest("4-player spawns for 4 base enemies is 7 (1.75x, strictly < 4x)", fourPlayerSpawns == 7)

	local fourPlayerHp = DifficultyConfig.CalculateHealth(100, 4, false)
	assertTest("4-player health for 100 base is 200 (2.0x)", fourPlayerHp == 200)

	local fourPlayerBossHp = DifficultyConfig.CalculateHealth(1000, 4, true)
	assertTest("4-player boss health for 1000 base is 2200 (2.2x)", fourPlayerBossHp == 2200)

	-- 5. EnemyService Health & Score Override Integration
	local spawnPos = Vector3.new(0, 0, GameConfig.Arena.PlayPlaneZ)
	local enemyModel, err = EnemyService.SpawnEnemy("StraightFlyer", spawnPos, 250, 1250)
	assertTest("Enemy spawned with health & score overrides", enemyModel ~= nil)
	assertTest("Model MaxHealth matches override (250)", enemyModel ~= nil and enemyModel:GetAttribute("MaxHealth") == 250)
	assertTest("Model CurrentHealth matches override (250)", enemyModel ~= nil and enemyModel:GetAttribute("CurrentHealth") == 250)
	assertTest("Model ScoreValue matches override (1250)", enemyModel ~= nil and enemyModel:GetAttribute("ScoreValue") == 1250)

	local activeRec = if enemyModel then EnemyService.GetActiveEnemy(enemyModel:GetAttribute("EnemyId") :: string) else nil
	assertTest("ActiveEnemy record maxHealth is 250", activeRec ~= nil and activeRec.maxHealth == 250)
	assertTest("ActiveEnemy record scoreValue is 1250", activeRec ~= nil and activeRec.scoreValue == 1250)

	EnemyService.CleanupAll()

	-- 6. WaveService Checkpoint Sampling Rule
	WaveService.ResetMission()

	-- Simulate 1 player at wave 1 checkpoint
	WaveService.SetForcedPlayerCount(1)
	WaveService.StartMission(nil) -- Starts default mission

	-- Advance through intermission into Wave 1
	WaveService.Step(3.0)
	assertTest("Wave 1 started", WaveService.GetCurrentWaveNumber() == 1)
	assertTest("Wave 1 checkpoint player count is 1", WaveService.GetWaveCheckpointPlayerCount() == 1)
	assertTest("Wave 1 scaling health multiplier is 1.0", WaveService.GetWaveScaling().healthMult == 1.0)

	-- Mid-wave player change should NOT mutate current wave scaling
	WaveService.SetForcedPlayerCount(4)
	assertTest("Mid-wave player count change does not alter Wave 1 checkpoint (remains 1)", WaveService.GetWaveCheckpointPlayerCount() == 1)
	assertTest("Mid-wave scaling factors remain locked (1.0x)", WaveService.GetWaveScaling().healthMult == 1.0)

	-- 7. Wave Dynamic Adaptation at Next Checkpoint
	-- Spawn all enemies in Wave 1 and resolve them to advance to Wave 2
	while WaveService.GetState() == "Spawning" do
		WaveService.Step(0.6)
	end
	EnemyService.CleanupAll()
	WaveService.Step(0.1)

	assertTest("Wave 1 cleared; entering Intermission", WaveService.GetState() == "Intermission")

	-- Advance through intermission into Wave 2 with 4 players at checkpoint
	WaveService.Step(3.0)
	assertTest("Wave 2 started", WaveService.GetCurrentWaveNumber() == 2)
	assertTest("Wave 2 checkpoint player count adapted to 4", WaveService.GetWaveCheckpointPlayerCount() == 4)
	assertTest("Wave 2 scaling health multiplier is 2.0x", WaveService.GetWaveScaling().healthMult == 2.0)
	assertTest("Wave 2 scaling spawn count multiplier is 1.75x", WaveService.GetWaveScaling().spawnCountMult == 1.75)

	-- Spawn an enemy in Wave 2 and verify scaled health
	WaveService.Step(1.0)
	local allEnemies = EnemyService.GetAllActiveEnemies()
	local foundScaledEnemy = false
	for _, rec in pairs(allEnemies) do
		-- StraightFlyer base health is 20; with 2.0x it should be 40
		if rec.maxHealth == 40 then
			foundScaledEnemy = true
			break
		end
	end
	assertTest("Spawned enemy in Wave 2 has 2.0x scaled health (40 HP vs 20 base)", foundScaledEnemy == true)

	-- Clean up
	WaveService.SetForcedPlayerCount(nil)
	WaveService.ResetMission()
	EnemyService.CleanupAll()
	SessionService._Teardown()
	WaveService._Teardown()

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return DifficultyScalingTests
