--!strict
--[[
	TurretShooterTests.luau
	Comprehensive unit tests for Enemy Archetype C (Turret Shooter).
	Task: CLAY-019 (Enemy Archetype C — Turret Shooter)
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
if (EnemyConfig :: any).Archetypes == nil then
	EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"):Clone())
end

local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
if (GameConfig :: any).CONTRACT_VERSION == nil then
	GameConfig = require(SharedFolder:WaitForChild("GameConfig"):Clone())
end

local Services = ServerScriptService:WaitForChild("Services")
local EnemyFactory = require(Services:WaitForChild("EnemyFactory"))
local EnemyService = require(Services:WaitForChild("EnemyService"))
local ProjectileService = require(Services:WaitForChild("ProjectileService"))

local TurretShooterTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function TurretShooterTests.RunTests(): {
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
			warn(string.format("[TurretShooterTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Teardown services for clean baseline
	EnemyService._Teardown()
	ProjectileService._Teardown()
	EnemyService.Initialize()
	ProjectileService.Initialize()

	-- Clean ActivePlanes container
	local activePlanes = Workspace:FindFirstChild("ActivePlanes")
	if not activePlanes then
		activePlanes = Instance.new("Folder")
		activePlanes.Name = "ActivePlanes"
		activePlanes.Parent = Workspace
	else
		activePlanes:ClearAllChildren()
	end

	-- 1. EnemyConfig Schema Validation
	local turretDef = EnemyConfig.GetEnemy(EnemyConfig.Archetypes.TurretShooter)
	assertTest("TurretShooter definition exists in EnemyConfig", turretDef ~= nil)
	if turretDef then
		local valid, err = EnemyConfig.ValidateDefinition(turretDef)
		assertTest("TurretShooter definition passes schema validation", valid == true and err == nil)
		assertTest("TurretShooter maxHealth is 55", turretDef.maxHealth == 55)
		assertTest("TurretShooter movementType is 'DriftAndShoot'", turretDef.movementType == "DriftAndShoot")
		assertTest("TurretShooter speed is 7", turretDef.speed == 7)
		assertTest("TurretShooter has verticalSpeed >= 0", (turretDef.verticalSpeed or 0) >= 0)
		assertTest("TurretShooter firingPattern canShoot is true", turretDef.firingPattern ~= nil and turretDef.firingPattern.canShoot == true)
		assertTest("TurretShooter fireRate is 2.0s", turretDef.firingPattern ~= nil and turretDef.firingPattern.fireRate == 2.0)
		assertTest("TurretShooter projectileDamage is 15", turretDef.firingPattern ~= nil and turretDef.firingPattern.projectileDamage == 15)
	end

	-- 2. EnemyFactory Model Structure
	if turretDef then
		local model = EnemyFactory.CreateProceduralPlaceholder(turretDef)
		assertTest("Procedural placeholder creates valid Model", model:IsA("Model"))
		assertTest("Model has HitProxy as PrimaryPart", model.PrimaryPart ~= nil and model.PrimaryPart.Name == "HitProxy")
		assertTest("Model contains VisualTurret cannon", model:FindFirstChild("VisualTurret") ~= nil)

		local cannon = model:FindFirstChild("VisualTurret")
		if cannon then
			assertTest("Cannon has MuzzleAttachment", cannon:FindFirstChild("MuzzleAttachment") ~= nil)
			local light = cannon:FindFirstChild("TelegraphLight")
			assertTest("Cannon has TelegraphLight PointLight", light ~= nil and light:IsA("PointLight"))

			-- Test telegraph attribute binding
			model:SetAttribute("IsTelegraphing", true)
			task.wait()
			assertTest("TelegraphLight activates when IsTelegraphing is true", light ~= nil and (light :: PointLight).Enabled == true)

			model:SetAttribute("IsTelegraphing", false)
			task.wait()
			assertTest("TelegraphLight deactivates when IsTelegraphing is false", light ~= nil and (light :: PointLight).Enabled == false)
		end
		model:Destroy()
	end

	-- 3. EnemyService Spawning & Initial State
	local spawnPos = Vector3.new(50, 0, GameConfig.Arena.PlayPlaneZ)
	local turretModel, spawnErr = EnemyService.SpawnEnemy(EnemyConfig.Archetypes.TurretShooter, spawnPos)
	assertTest("Spawn TurretShooter succeeds without error", turretModel ~= nil and spawnErr == nil)
	assertTest("TurretShooter is parented to ActiveEnemies", turretModel ~= nil and turretModel.Parent and (turretModel.Parent.Name == "ActiveEnemies" or turretModel.Parent.Name == "Enemies"))

	local enemyId = turretModel and turretModel:GetAttribute("EnemyId") :: string
	local record = enemyId and EnemyService.GetActiveEnemy(enemyId)
	assertTest("EnemyService registers active TurretShooter record", record ~= nil)
	assertTest("Initial CurrentHealth is 55", record ~= nil and record.currentHealth == 55)
	assertTest("Initial IsTelegraphing attribute is false", turretModel ~= nil and turretModel:GetAttribute("IsTelegraphing") == false)
	assertTest("Initial TargetUserId attribute is 0", turretModel ~= nil and turretModel:GetAttribute("TargetUserId") == 0)

	-- 4. Target Selection (No targets available)
	EnemyService.StepEnemySimulation(0.1)
	assertTest("TurretShooter does not target when no player planes exist", turretModel ~= nil and turretModel:GetAttribute("TargetUserId") == 0)
	assertTest("TurretShooter does not telegraph without target", turretModel ~= nil and turretModel:GetAttribute("IsTelegraphing") == false)

	-- 5. Target Selection (Living player plane present)
	local mockPlane = Instance.new("Model")
	mockPlane.Name = "Plane_9999"
	local mockRoot = Instance.new("Part")
	mockRoot.Name = "RootPart"
	mockRoot.Size = Vector3.new(4, 2, 2)
	mockRoot.Position = Vector3.new(-20, 5, GameConfig.Arena.PlayPlaneZ)
	mockRoot.Anchored = true
	mockRoot.CanCollide = false
	mockRoot.CanQuery = true
	mockRoot.Parent = mockPlane
	mockPlane.PrimaryPart = mockRoot
	mockPlane:SetAttribute("OwnerUserId", 9999)
	mockPlane:SetAttribute("Health", 100)
	mockPlane:SetAttribute("MaxHealth", 100)
	mockPlane.Parent = activePlanes

	EnemyService.StepEnemySimulation(0.1)
	assertTest("TurretShooter selects active player plane as target", turretModel ~= nil and turretModel:GetAttribute("TargetUserId") == 9999)
	assertTest("TurretShooter sets TelegraphTargetX attribute", turretModel ~= nil and turretModel:GetAttribute("TelegraphTargetX") ~= nil)

	-- 6. Attack Cadence & Telegraph Timing
	-- Cooldown started at 2.0s; after 0.1s step with target, cooldown is ~1.9s (not telegraphing)
	assertTest("TurretShooter is not telegraphing at 1.9s remaining cooldown", turretModel ~= nil and turretModel:GetAttribute("IsTelegraphing") == false)

	-- Advance by 1.45s (remaining cooldown: ~0.45s <= 0.5s TELEGRAPH_WINDOW)
	EnemyService.StepEnemySimulation(1.45)
	assertTest("TurretShooter enters telegraph phase 0.5s before firing", turretModel ~= nil and turretModel:GetAttribute("IsTelegraphing") == true)

	-- 7. Authoritative Firing & Telegraph Reset
	local projectilesFolder = Workspace:FindFirstChild("Projectiles")
	local projCountBefore = projectilesFolder and #projectilesFolder:GetChildren() or 0

	-- Advance past 0.45s to trigger shot
	EnemyService.StepEnemySimulation(0.55)
	local projCountAfter = projectilesFolder and #projectilesFolder:GetChildren() or 0
	assertTest("TurretShooter fires an authoritative projectile when cooldown expires", projCountAfter > projCountBefore)
	assertTest("IsTelegraphing resets to false after firing", turretModel ~= nil and turretModel:GetAttribute("IsTelegraphing") == false)

	-- Verify projectile attributes
	local spawnedProj = projectilesFolder and projectilesFolder:GetChildren()[#projectilesFolder:GetChildren()]
	assertTest("Spawned projectile has Faction = 'Enemy'", spawnedProj ~= nil and spawnedProj:GetAttribute("Faction") == "Enemy")
	assertTest("Spawned projectile has BaseDamage = 15", spawnedProj ~= nil and spawnedProj:GetAttribute("BaseDamage") == 15)

	-- 8. Enemy Projectile Simulation & Player Plane Damage
	-- Spawn an authoritative enemy projectile moving directly towards the player plane
	local enemyWeapon = {
		id = "TestTurretShot",
		name = "Test Turret Shot",
		weaponType = "Standard",
		baseDamage = 15,
		fireRate = 2.0,
		projectileSpeed = 60,
		projectileRadius = 0.8,
		lifetime = 5.0,
		cooldown = 2.0,
		bulletColor = Color3.fromRGB(255, 50, 50),
	}
	local aimedProj = ProjectileService.SpawnProjectile(0, Vector3.new(-15, 5, GameConfig.Arena.PlayPlaneZ), Vector2.new(-1, 0), enemyWeapon :: any, "Enemy")

	local hitObserved = false
	local hitFaction: string? = nil
	local hitDamage = 0
	local hitCleanup = ProjectileService.RegisterHitCallback(function(hit)
		hitObserved = true
		hitFaction = hit.faction
		hitDamage = hit.damage
	end)

	ProjectileService.StepSimulation(0.1)
	assertTest("ProjectileService hit callback triggered on player plane collision", hitObserved == true)
	assertTest("Hit result reports Faction = 'Enemy'", hitFaction == "Enemy")
	assertTest("Hit result reports 15 damage", hitDamage == 15)

	local playerHpAfter = mockPlane:GetAttribute("Health") :: number
	assertTest("Player plane health is reduced from 100 to 85", playerHpAfter == 85)

	if hitCleanup then
		hitCleanup()
	end

	-- 9. Target Despawn Handling (Player plane destroyed / disconnected)
	mockPlane:Destroy()
	EnemyService.StepEnemySimulation(0.1)
	assertTest("TurretShooter clears target when player plane despawns", turretModel ~= nil and turretModel:GetAttribute("TargetUserId") == 0)
	assertTest("TurretShooter clears telegraph when player plane despawns", turretModel ~= nil and turretModel:GetAttribute("IsTelegraphing") == false)

	-- 10. Turret Defeat & Cleanup
	if enemyId then
		local hitValid, wasDefeated = EnemyService.ApplyDamage(enemyId, 55, nil)
		assertTest("Applying 55 damage to TurretShooter returns wasDefeated = true", hitValid == true and wasDefeated == true)
		assertTest("TurretShooter model is despawned from ActiveEnemies", turretModel == nil or turretModel.Parent == nil)
		assertTest("Active enemy count returns to 0", EnemyService.GetActiveEnemyCount() == 0)
	end

	-- Final teardown
	EnemyService._Teardown()
	ProjectileService._Teardown()
	if activePlanes then
		activePlanes:ClearAllChildren()
	end

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return TurretShooterTests
