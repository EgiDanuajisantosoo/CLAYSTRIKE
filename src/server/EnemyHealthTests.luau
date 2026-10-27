--!strict
--[[
	EnemyHealthTests.luau
	Comprehensive unit tests for enemy health lifecycle, authoritative damage,
	non-negative health clamping, one-time defeat transition, and idempotent callback handling.
	Task: CLAY-012 (Enemy Health, Damage & Defeat Lifecycle)
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
if (EnemyConfig :: any).Archetypes == nil then
	EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"):Clone())
end

local EnemyHealthTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function EnemyHealthTests.RunTests(enemyServiceModule: any?): {
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
			warn(string.format("[EnemyHealthTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Clean baseline teardown
	EnemyService._Teardown()
	assertTest("EnemyService uninitialized at test start", EnemyService.IsInitialized() == false)
	assertTest("Active count starts at 0", EnemyService.GetActiveEnemyCount() == 0)

	-- 1. Initialize
	EnemyService.Initialize()
	assertTest("EnemyService initialized", EnemyService.IsInitialized() == true)

	-- 2. Non-lethal damage test
	local m1, err1 = EnemyService.SpawnEnemy(EnemyConfig.Archetypes.StraightFlyer, Vector3.new(40, 0, 0))
	assertTest("Spawned enemy m1 successfully", m1 ~= nil and err1 == nil)
	local id1 = if m1 then (m1:GetAttribute("EnemyId") :: string) else ""

	local damagedCalls = 0
	local lastDamagedAmount = 0
	local disconnectDamaged = EnemyService.OnEnemyDamaged(function(rec, dmg, attacker)
		damagedCalls += 1
		lastDamagedAmount = dmg
	end)

	local valid1, defeated1 = EnemyService.ApplyDamage(id1, 8, nil)
	assertTest("ApplyDamage(8) on 20 HP enemy is valid", valid1 == true)
	assertTest("Enemy is not defeated after 8 damage", defeated1 == false)

	local rec1 = EnemyService.GetActiveEnemy(id1)
	assertTest("Active record currentHealth is 12", rec1 ~= nil and rec1.currentHealth == 12)
	assertTest("Model CurrentHealth attribute is 12", m1 ~= nil and m1:GetAttribute("CurrentHealth") == 12)
	assertTest("OnEnemyDamaged callback was fired once", damagedCalls == 1 and lastDamagedAmount == 8)

	disconnectDamaged()

	-- 3. Health clamping: excess damage clamps to 0, never negative
	local defeatCalls = 0
	local defeatedRecId = ""
	local disconnectDefeat = EnemyService.OnEnemyDefeated(function(rec, attacker)
		defeatCalls += 1
		defeatedRecId = rec.id
	end)

	-- Deal 999 damage (well exceeding remaining 12 HP)
	local valid2, defeated2 = EnemyService.ApplyDamage(id1, 999, nil)
	assertTest("Excess lethal damage is valid", valid2 == true)
	assertTest("Enemy was defeated by excess damage", defeated2 == true)
	assertTest("OnEnemyDefeated fired exactly once", defeatCalls == 1 and defeatedRecId == id1)
	assertTest("Defeated enemy removed from activeEnemies", EnemyService.GetActiveEnemy(id1) == nil)
	assertTest("Defeated model is unparented/destroyed", m1 == nil or m1.Parent == nil)

	-- 4. An enemy can be defeated only once (repeated lethal hits are rejected)
	local valid3, defeated3 = EnemyService.ApplyDamage(id1, 50, nil)
	assertTest("Damage to already defeated enemy is rejected (valid = false)", valid3 == false)
	assertTest("Repeated hit does not report defeated again", defeated3 == false)
	assertTest("OnEnemyDefeated count remains strictly 1", defeatCalls == 1)

	disconnectDefeat()

	-- 5. Simultaneous lethal hits from two players on the same enemy
	local m2, _ = EnemyService.SpawnEnemy(EnemyConfig.Archetypes.StraightFlyer, Vector3.new(40, 10, 0))
	local id2 = if m2 then (m2:GetAttribute("EnemyId") :: string) else ""

	local simDefeatCount = 0
	local disconnectSim = EnemyService.OnEnemyDefeated(function(rec, attacker)
		simDefeatCount += 1
	end)

	-- Simulate 3 rapid simultaneous lethal hits
	local hit1Valid, hit1Def = EnemyService.ApplyDamage(id2, 25, nil)
	local hit2Valid, hit2Def = EnemyService.ApplyDamage(id2, 25, nil)
	local hit3Valid, hit3Def = EnemyService.ApplyDamage(id2, 25, nil)

	assertTest("First simultaneous hit succeeds and defeats", hit1Valid == true and hit1Def == true)
	assertTest("Second simultaneous hit in same step is rejected", hit2Valid == false and hit2Def == false)
	assertTest("Third simultaneous hit in same step is rejected", hit3Valid == false and hit3Def == false)
	assertTest("Defeat event was fired exactly once across simultaneous hits", simDefeatCount == 1)

	disconnectSim()

	-- 6. Reject invalid enemy targets
	local badValid, badDef = EnemyService.ApplyDamage("NonExistentEnemyId_9999", 10, nil)
	assertTest("ApplyDamage on non-existent enemy returns false, false", badValid == false and badDef == false)

	-- 7. Reject non-positive damage
	local m3, _ = EnemyService.SpawnEnemy(EnemyConfig.Archetypes.StraightFlyer, Vector3.new(40, -10, 0))
	local id3 = if m3 then (m3:GetAttribute("EnemyId") :: string) else ""

	local zeroValid, zeroDef = EnemyService.ApplyDamage(id3, 0, nil)
	assertTest("ApplyDamage with 0 damage returns false, false", zeroValid == false and zeroDef == false)

	local negValid, negDef = EnemyService.ApplyDamage(id3, -15, nil)
	assertTest("ApplyDamage with negative damage returns false, false", negValid == false and negDef == false)

	local rec3 = EnemyService.GetActiveEnemy(id3)
	assertTest("Health remains at max after non-positive damage", rec3 ~= nil and rec3.currentHealth == rec3.maxHealth)

	-- 8. ProjectileService hit hook integration
	local m4, _ = EnemyService.SpawnEnemy(EnemyConfig.Archetypes.StraightFlyer, Vector3.new(40, 5, 0))
	local id4 = if m4 then (m4:GetAttribute("EnemyId") :: string) else ""
	local proxy = if m4 then m4.PrimaryPart else nil

	-- Mock a ProjectileService observer callback
	local mockHitDispatcher: ((any) -> ())? = nil
	local mockProjectileService = {
		RegisterHitCallback = function(cb: (any) -> ())
			mockHitDispatcher = cb
			return function() mockHitDispatcher = nil end
		end,
	}

	local hookCleanup = EnemyService.HookProjectileHits(mockProjectileService)
	assertTest("HookProjectileHits returned cleanup function", hookCleanup ~= nil)
	assertTest("Mock ProjectileService received hit callback", mockHitDispatcher ~= nil)

	if mockHitDispatcher and proxy then
		-- Simulate swept raycast projectile hit on proxy
		mockHitDispatcher({
			hitInstance = proxy,
			hitPosition = proxy.Position,
			hitNormal = Vector3.new(1, 0, 0),
			damage = 10,
			attackerPlayer = nil,
		})

		local rec4 = EnemyService.GetActiveEnemy(id4)
		assertTest("Projectile hit successfully routed to ApplyDamage (HP = 10)", rec4 ~= nil and rec4.currentHealth == 10)

		-- Simulate lethal hit
		mockHitDispatcher({
			hitInstance = proxy,
			hitPosition = proxy.Position,
			hitNormal = Vector3.new(1, 0, 0),
			damage = 15,
			attackerPlayer = nil,
		})
		assertTest("Lethal projectile hit defeated enemy via hook", EnemyService.GetActiveEnemy(id4) == nil)
	end

	if hookCleanup then
		hookCleanup()
	end

	-- 9. Clean Teardown
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

return EnemyHealthTests
