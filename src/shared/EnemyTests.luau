--!strict
--[[
	EnemyTests.luau
	Unit test harness for EnemyConfig data schema, archetype validation, and error reporting.
	Task: CLAY-015 (Enemy Definition Schema)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
if (EnemyConfig :: any).Archetypes == nil then
	EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"):Clone())
end

local EnemyTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function EnemyTests.RunTests(enemyConfigModule: any?): {
	total: number,
	passed: number,
	failed: number,
	results: { [number]: TestResult },
}
	local Config = enemyConfigModule or EnemyConfig
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
			warn(string.format("[EnemyTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- 1. Validate all registered enemies in EnemyConfig
	local allValid, errors = Config.ValidateAll()
	assertTest("All registered enemy definitions pass schema validation", allValid == true, table.concat(errors, "; "))
	assertTest("Zero validation errors across all registered definitions", #errors == 0)

	-- 2. Verify MVP enemy archetypes exist
	local straightFlyer = Config.GetEnemy(Config.Archetypes.StraightFlyer)
	assertTest("StraightFlyer archetype exists", straightFlyer ~= nil)
	if straightFlyer then
		assertTest("StraightFlyer has positive health (20)", straightFlyer.maxHealth == 20)
		assertTest("StraightFlyer has movementType 'Straight'", straightFlyer.movementType == "Straight")
		assertTest("StraightFlyer has speed 18", straightFlyer.speed == 18)
		assertTest("StraightFlyer has positive collision size", straightFlyer.collisionSize.X > 0 and straightFlyer.collisionSize.Y > 0)
		assertTest("StraightFlyer score value is 100", straightFlyer.scoreValue == 100)
		assertTest("StraightFlyer canShoot is false", straightFlyer.firingPattern ~= nil and straightFlyer.firingPattern.canShoot == false)
	end

	local pursuer = Config.GetEnemy(Config.Archetypes.Pursuer)
	assertTest("Pursuer archetype exists", pursuer ~= nil)
	if pursuer then
		assertTest("Pursuer has positive health (35)", pursuer.maxHealth == 35)
		assertTest("Pursuer has movementType 'Pursuit'", pursuer.movementType == "Pursuit")
		assertTest("Pursuer has verticalSpeed defined", pursuer.verticalSpeed ~= nil and pursuer.verticalSpeed > 0)
		assertTest("Pursuer score value is 250", pursuer.scoreValue == 250)
	end

	local turretShooter = Config.GetEnemy(Config.Archetypes.TurretShooter)
	assertTest("TurretShooter archetype exists", turretShooter ~= nil)
	if turretShooter then
		assertTest("TurretShooter has positive health (55)", turretShooter.maxHealth == 55)
		assertTest("TurretShooter has movementType 'DriftAndShoot'", turretShooter.movementType == "DriftAndShoot")
		assertTest("TurretShooter canShoot is true", turretShooter.firingPattern ~= nil and turretShooter.firingPattern.canShoot == true)
		assertTest("TurretShooter has positive projectileSpeed", turretShooter.firingPattern ~= nil and turretShooter.firingPattern.projectileSpeed > 0)
		assertTest("TurretShooter has positive projectileDamage", turretShooter.firingPattern ~= nil and turretShooter.firingPattern.projectileDamage > 0)
		assertTest("TurretShooter score value is 400", turretShooter.scoreValue == 400)
	end

	-- 3. Accessor functions
	local allEnemies = Config.GetAllEnemies()
	assertTest("GetAllEnemies() returns at least 3 archetypes", allEnemies[Config.Archetypes.StraightFlyer] ~= nil and allEnemies[Config.Archetypes.Pursuer] ~= nil and allEnemies[Config.Archetypes.TurretShooter] ~= nil)

	local enemyIds = Config.GetEnemyIds()
	assertTest("GetEnemyIds() returns a list containing all 3 archetype IDs", #enemyIds >= 3)
	assertTest("GetEnemy() returns nil for unknown ID", Config.GetEnemy("UnknownBoss") == nil)

	-- 4. Rejection of invalid definitions with clear error reporting
	local badDefMissingId = { displayName = "Bad Drone", maxHealth = 10 }
	local validId, errId = Config.ValidateDefinition(badDefMissingId)
	assertTest("Rejects definition with missing ID", validId == false)
	assertTest("Error indicates missing 'id'", errId ~= nil and string.find(errId, "id") ~= nil)

	local badDefNegativeHealth = {
		id = "BadDrone",
		displayName = "Bad Drone",
		maxHealth = -10,
		movementType = "Straight",
		speed = 10,
		collisionSize = Vector3.new(2, 2, 2),
		scoreValue = 50,
		clayColor = Color3.new(1, 1, 1),
		templateName = "Template",
	}
	local validHealth, errHealth = Config.ValidateDefinition(badDefNegativeHealth)
	assertTest("Rejects definition with negative health", validHealth == false)
	assertTest("Error identifies enemy ID and field 'maxHealth'", errHealth ~= nil and string.find(errHealth, "BadDrone") ~= nil and string.find(errHealth, "maxHealth") ~= nil)

	local badDefInvalidMove = table.clone(badDefNegativeHealth)
	badDefInvalidMove.maxHealth = 20
	badDefInvalidMove.movementType = "Teleport" :: any
	local validMove, errMove = Config.ValidateDefinition(badDefInvalidMove)
	assertTest("Rejects definition with invalid movementType", validMove == false)
	assertTest("Error identifies enemy ID and field 'movementType'", errMove ~= nil and string.find(errMove, "movementType") ~= nil)

	local badDefNegativeCollision = table.clone(badDefNegativeHealth)
	badDefNegativeCollision.maxHealth = 20
	badDefNegativeCollision.collisionSize = Vector3.new(-2, 2, 2)
	local validColl, errColl = Config.ValidateDefinition(badDefNegativeCollision)
	assertTest("Rejects definition with negative collision dimension", validColl == false)
	assertTest("Error identifies field 'collisionSize'", errColl ~= nil and string.find(errColl, "collisionSize") ~= nil)

	local badDefShooterMissingSpeed = table.clone(badDefNegativeHealth)
	badDefShooterMissingSpeed.maxHealth = 20
	badDefShooterMissingSpeed.firingPattern = {
		canShoot = true,
		fireRate = 1.0,
		projectileSpeed = -5, -- Negative
		projectileDamage = 10,
		projectileColor = Color3.new(1, 0, 0),
	}
	local validShooter, errShooter = Config.ValidateDefinition(badDefShooterMissingSpeed)
	assertTest("Rejects shooting enemy with negative projectileSpeed", validShooter == false)
	assertTest("Error identifies field 'projectileSpeed'", errShooter ~= nil and string.find(errShooter, "projectileSpeed") ~= nil)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return EnemyTests
