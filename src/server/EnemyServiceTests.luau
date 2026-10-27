--!strict
--[[
	EnemyServiceTests.luau
	Comprehensive unit tests for enemy model factory, authoritative spawning, tracking, and cleanup.
	Task: CLAY-016 (Enemy Spawn Factory & Cleanup)
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
if (EnemyConfig :: any).Archetypes == nil then
	EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"):Clone())
end

local EnemyServiceTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function EnemyServiceTests.RunTests(enemyServiceModule: any?): {
	total: number,
	passed: number,
	failed: number,
	results: { [number]: TestResult },
}
	local EnemyService = enemyServiceModule
	if not EnemyService then
		local SSS = game:GetService("ServerScriptService")
		local Services = SSS:WaitForChild("Services")
		EnemyService = require(Services:WaitForChild("EnemyService"))
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
			warn(string.format("[EnemyServiceTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Baseline clean teardown
	EnemyService._Teardown()
	assertTest("EnemyService starts with 0 active enemies", EnemyService.GetActiveEnemyCount() == 0)

	-- 1. Initialize
	EnemyService.Initialize()
	assertTest("EnemyService is initialized", EnemyService.IsInitialized() == true)

	-- 2. Spawning StraightFlyer
	local sfPos = Vector3.new(60, 10, 0)
	local sfModel, sfErr = EnemyService.SpawnEnemy(EnemyConfig.Archetypes.StraightFlyer, sfPos)
	assertTest("StraightFlyer spawned without error", sfModel ~= nil and sfErr == nil)
	if sfModel then
		assertTest("StraightFlyer is a Model", sfModel:IsA("Model"))
		assertTest("StraightFlyer PrimaryPart is named HitProxy", sfModel.PrimaryPart ~= nil and sfModel.PrimaryPart.Name == "HitProxy")
		assertTest("StraightFlyer PrimaryPart positioned at spawnPosition", (sfModel.PrimaryPart.Position - sfPos).Magnitude < 0.1)
		assertTest("StraightFlyer has MaxHealth attribute = 20", sfModel:GetAttribute("MaxHealth") == 20)
		assertTest("StraightFlyer has CurrentHealth attribute = 20", sfModel:GetAttribute("CurrentHealth") == 20)
		assertTest("StraightFlyer has ScoreValue attribute = 100", sfModel:GetAttribute("ScoreValue") == 100)
		assertTest("StraightFlyer has IsAlive attribute = true", sfModel:GetAttribute("IsAlive") == true)
		assertTest("StraightFlyer parent is ActiveEnemies or Enemies", sfModel.Parent ~= nil and (sfModel.Parent.Name == "ActiveEnemies" or sfModel.Parent.Name == "Enemies"))
	end
	assertTest("Active count is 1 after first spawn", EnemyService.GetActiveEnemyCount() == 1)

	-- 3. Spawning Pursuer
	local pPos = Vector3.new(60, -10, 0)
	local pModel, pErr = EnemyService.SpawnEnemy(EnemyConfig.Archetypes.Pursuer, pPos)
	assertTest("Pursuer spawned without error", pModel ~= nil and pErr == nil)
	if pModel then
		assertTest("Pursuer has MaxHealth attribute = 35", pModel:GetAttribute("MaxHealth") == 35)
		assertTest("Pursuer has ScoreValue attribute = 250", pModel:GetAttribute("ScoreValue") == 250)
	end
	assertTest("Active count is 2 after second spawn", EnemyService.GetActiveEnemyCount() == 2)

	-- 4. Spawning TurretShooter
	local tsPos = Vector3.new(50, 0, 0)
	local tsModel, tsErr = EnemyService.SpawnEnemy(EnemyConfig.Archetypes.TurretShooter, tsPos)
	assertTest("TurretShooter spawned without error", tsModel ~= nil and tsErr == nil)
	if tsModel then
		assertTest("TurretShooter has MaxHealth attribute = 55", tsModel:GetAttribute("MaxHealth") == 55)
		assertTest("TurretShooter has ScoreValue attribute = 400", tsModel:GetAttribute("ScoreValue") == 400)
	end
	assertTest("Active count is 3 after third spawn", EnemyService.GetActiveEnemyCount() == 3)

	-- 5. Query active enemy record
	if sfModel then
		local sfId = sfModel:GetAttribute("EnemyId") :: string
		local record = EnemyService.GetActiveEnemy(sfId)
		assertTest("GetActiveEnemy() returns record for StraightFlyer", record ~= nil)
		if record then
			assertTest("Record has matching ID", record.id == sfId)
			assertTest("Record has matching archetypeId", record.archetypeId == EnemyConfig.Archetypes.StraightFlyer)
			assertTest("Record tracks currentHealth = 20", record.currentHealth == 20)
			assertTest("Record isAlive = true", record.isAlive == true)
		end

		-- 6. Despawn single enemy
		local despawnResult = EnemyService.DespawnEnemy(sfId)
		assertTest("DespawnEnemy() returned true for active enemy", despawnResult == true)
		assertTest("Despawned model destroyed from Workspace", sfModel.Parent == nil)
		assertTest("GetActiveEnemy() returns nil for despawned enemy", EnemyService.GetActiveEnemy(sfId) == nil)
		assertTest("Active count decremented to 2", EnemyService.GetActiveEnemyCount() == 2)
	end

	-- 7. Reject unknown archetype
	local badModel, badErr = EnemyService.SpawnEnemy("InvalidBossArchetype", Vector3.zero)
	assertTest("Reject spawn of unknown archetype", badModel == nil and badErr ~= nil)

	-- 8. CleanupAll()
	local cleanedCount = EnemyService.CleanupAll()
	assertTest("CleanupAll() removed remaining 2 enemies", cleanedCount == 2)
	assertTest("Active enemy count is 0 after CleanupAll()", EnemyService.GetActiveEnemyCount() == 0)
	if pModel then
		assertTest("Pursuer model destroyed by CleanupAll()", pModel.Parent == nil)
	end
	if tsModel then
		assertTest("TurretShooter model destroyed by CleanupAll()", tsModel.Parent == nil)
	end

	-- 9. Teardown
	EnemyService._Teardown()
	assertTest("EnemyService uninitialized after _Teardown()", EnemyService.IsInitialized() == false)
	assertTest("Active count is 0 after _Teardown()", EnemyService.GetActiveEnemyCount() == 0)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return EnemyServiceTests
