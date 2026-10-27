--!strict
--[[
	StraightFlyerTests.luau
	Comprehensive unit tests for Enemy Archetype A (StraightFlyer) movement simulation,
	predictable trajectory along -X, 2.5D plane constraint, boundary culling, and mid-flight despawn.
	Task: CLAY-017 (Enemy Archetype A — Straight Flyer)
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
if (EnemyConfig :: any).Archetypes == nil then
	EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"):Clone())
end

local StraightFlyerTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function StraightFlyerTests.RunTests(enemyServiceModule: any?): {
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
			warn(string.format("[StraightFlyerTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Clean baseline teardown
	EnemyService._Teardown()
	assertTest("EnemyService uninitialized at test start", EnemyService.IsInitialized() == false)
	assertTest("Active enemy count starts at 0", EnemyService.GetActiveEnemyCount() == 0)

	-- 1. Initialize
	EnemyService.Initialize()
	assertTest("EnemyService initialized", EnemyService.IsInitialized() == true)

	-- 2. Spawn StraightFlyer at right spawn edge
	local spawnPos = Vector3.new(70, 15, 0)
	local model, err = EnemyService.SpawnEnemy(EnemyConfig.Archetypes.StraightFlyer, spawnPos)
	assertTest("StraightFlyer spawned successfully", model ~= nil and err == nil)

	local enemyId = if model then (model:GetAttribute("EnemyId") :: string) else ""
	local primary = if model then model.PrimaryPart else nil
	assertTest("StraightFlyer has HitProxy PrimaryPart", primary ~= nil and primary.Name == "HitProxy")
	if primary then
		assertTest("StraightFlyer spawned at exact spawnPos", (primary.Position - spawnPos).Magnitude < 0.05)
	end

	local sfDef = EnemyConfig.GetEnemy(EnemyConfig.Archetypes.StraightFlyer)
	local flySpeed = if sfDef then sfDef.speed else 18

	-- 3. Step simulation by 0.1s
	EnemyService.StepEnemySimulation(0.1)
	if primary then
		local expectedX = 70 - (flySpeed * 0.1)
		assertTest("Position advances along -X after 0.1s step", math.abs(primary.Position.X - expectedX) < 0.1)
		assertTest("Position Y remains at spawn height (15)", math.abs(primary.Position.Y - 15) < 0.1)
		assertTest("Position Z strictly locked to PlayPlaneZ (0)", math.abs(primary.Position.Z - GameConfig.Arena.PlayPlaneZ) < 0.001)
	end

	-- 4. Multi-step simulation (10 steps of 0.1s = 1.0s elapsed)
	for _ = 1, 10 do
		EnemyService.StepEnemySimulation(0.1)
	end
	if primary then
		-- Total dt = 0.1 + 1.0 = 1.1s -> dx = flySpeed * 1.1 -> X = 70 - dx
		local expectedX = 70 - (flySpeed * 1.1)
		assertTest("Position advances monotonically along -X across 10 steps", math.abs(primary.Position.X - expectedX) < 0.2)
	end

	-- 5. Offscreen left boundary culling
	-- Arena.MinX is -80, cull boundary is -95.
	-- Simulate 100 steps of 0.1s = 10s (180 studs movement -> X far past -95)
	for _ = 1, 100 do
		EnemyService.StepEnemySimulation(0.1)
	end
	assertTest("StraightFlyer automatically culled when exiting arena left bound", EnemyService.GetActiveEnemy(enemyId) == nil)
	assertTest("Culled StraightFlyer model destroyed from Workspace", model == nil or model.Parent == nil)
	assertTest("Active enemy count is 0 after boundary cull", EnemyService.GetActiveEnemyCount() == 0)

	-- 6. Different spawn heights
	local heights = { -25, 0, 25 }
	local spawnedHeightIds: { string } = {}
	for _, y in ipairs(heights) do
		local hModel, hErr = EnemyService.SpawnEnemy(EnemyConfig.Archetypes.StraightFlyer, Vector3.new(70, y, 0))
		assertTest(string.format("Spawned StraightFlyer at height Y = %d", y), hModel ~= nil and hErr == nil)
		if hModel then
			local id = hModel:GetAttribute("EnemyId") :: string
			table.insert(spawnedHeightIds, id)
			assertTest(string.format("Height Y = %d matches initial position", y), math.abs(hModel.PrimaryPart.Position.Y - y) < 0.05)
		end
	end
	assertTest("Active count is 3 for multi-height wave", EnemyService.GetActiveEnemyCount() == 3)

	-- Advance multi-height enemies 5 steps
	for _ = 1, 5 do
		EnemyService.StepEnemySimulation(0.1)
	end
	for i, y in ipairs(heights) do
		local rec = EnemyService.GetActiveEnemy(spawnedHeightIds[i])
		if rec and rec.primaryPart then
			assertTest(string.format("Height Y = %d retained during simulation step", y), math.abs(rec.primaryPart.Position.Y - y) < 0.1)
		end
	end

	-- 7. Mid-flight defeat / despawn
	local midId = spawnedHeightIds[1]
	local despawnedMid = EnemyService.DespawnEnemy(midId)
	assertTest("DespawnEnemy returns true for mid-flight enemy", despawnedMid == true)
	assertTest("Active count decremented to 2", EnemyService.GetActiveEnemyCount() == 2)

	-- Step simulation again to ensure no errors with partially despawned set
	EnemyService.StepEnemySimulation(0.1)
	assertTest("Simulation continues smoothly after mid-flight despawn", EnemyService.GetActiveEnemyCount() == 2)

	-- 8. Clean up remaining multi-height enemies
	EnemyService.CleanupAll()
	assertTest("CleanupAll cleans remaining multi-height enemies", EnemyService.GetActiveEnemyCount() == 0)

	-- 9. Out-of-bounds vertical cull check
	local oobModel, _ = EnemyService.SpawnEnemy(EnemyConfig.Archetypes.StraightFlyer, Vector3.new(70, 75, 0))
	assertTest("Spawned test enemy outside vertical arena bound", oobModel ~= nil)
	EnemyService.StepEnemySimulation(0.1)
	assertTest("Out-of-bounds vertical enemy immediately culled on simulation step", EnemyService.GetActiveEnemyCount() == 0)

	-- 10. Clean Teardown
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

return StraightFlyerTests
