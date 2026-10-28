--!strict
--[[
	SpreadWeaponTests.luau
	Authoritative unit test harness for Spread Weapon Pattern, symmetric fans, and projectile validation.
	Task: CLAY-013 (Spread Weapon Pattern)

	TEST SUITE:
	1. SpreadShot configuration verification (id, baseDamage=8, speed=110, cooldown=0.4, 3 angles).
	2. Symmetrical spread angle calculation helper validation (1, 3, 4, 5 fans).
	3. Rejection of spread fire without active aircraft.
	4. Authoritative spread fan spawning: exactly 3 projectiles instantiated in Workspace.Projectiles.
	5. Projectile attributes & metadata validation (OwnerUserId, Faction, BaseDamage, Lifetime).
	6. Trigonometric fan trajectory divergence along +X with +/-15° angles.
	7. Server cooldown enforcement (rapid second fire within 0.4s rejected).
	8. Independent raycast hit validation & authoritative damage (8 damage per spread projectile).
	9. Capacity limit enforcement (FIFO culling under high volume fire).
	10. Clean state isolation and teardown without orphaned parts.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local WeaponConfig = require(SharedFolder:WaitForChild("WeaponConfig"))

local Services = ServerScriptService:WaitForChild("Services")
local WeaponService = require(Services:WaitForChild("WeaponService"))
local ProjectileService = require(Services:WaitForChild("ProjectileService"))
local EnemyService = require(Services:WaitForChild("EnemyService"))

local SpreadWeaponTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function SpreadWeaponTests.RunTests(): {
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
			warn(string.format("[SpreadWeaponTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Teardown clean baseline
	WeaponService._Teardown()
	ProjectileService._Teardown()
	EnemyService._Teardown()
	WeaponService.Initialize()
	ProjectileService.Initialize()
	EnemyService.Initialize()

	-- 1. SpreadShot Configuration Verification
	local spreadDef = WeaponConfig.GetWeapon("SpreadShot")
	assertTest("SpreadShot definition exists", spreadDef ~= nil)
	assertTest("SpreadShot displayName is 'Spread Clay Cannon'", spreadDef ~= nil and spreadDef.displayName == "Spread Clay Cannon")
	assertTest("SpreadShot baseDamage is 8", spreadDef ~= nil and spreadDef.baseDamage == 8)
	assertTest("SpreadShot projectileSpeed is 110", spreadDef ~= nil and spreadDef.projectileSpeed == 110)
	assertTest("SpreadShot cooldown is 0.4s (2.5 fireRate)", spreadDef ~= nil and spreadDef.cooldown == 0.4 and spreadDef.fireRate == 2.5)
	assertTest("SpreadShot has exactly 3 spread angles", spreadDef ~= nil and #spreadDef.spreadAngles == 3)
	assertTest("SpreadShot spreadAngles are {-15, 0, 15}", spreadDef ~= nil and spreadDef.spreadAngles[1] == -15 and spreadDef.spreadAngles[2] == 0 and spreadDef.spreadAngles[3] == 15)

	-- 2. Symmetrical Spread Angle Calculation Helper
	local singleAngle = WeaponConfig.CalculateSpreadAngles(1, 15)
	assertTest("CalculateSpreadAngles(1) produces {0}", #singleAngle == 1 and singleAngle[1] == 0)

	local threeFan = WeaponConfig.CalculateSpreadAngles(3, 15)
	assertTest("CalculateSpreadAngles(3, 15) produces {-15, 0, 15}", #threeFan == 3 and threeFan[1] == -15 and threeFan[2] == 0 and threeFan[3] == 15)

	local fiveFan = WeaponConfig.CalculateSpreadAngles(5, 10)
	assertTest("CalculateSpreadAngles(5, 10) produces 5 symmetric angles", #fiveFan == 5 and fiveFan[1] == -20 and fiveFan[2] == -10 and fiveFan[3] == 0 and fiveFan[4] == 10 and fiveFan[5] == 20)

	local fourFan = WeaponConfig.CalculateSpreadAngles(4, 10)
	assertTest("CalculateSpreadAngles(4, 10) produces 4 symmetric split angles", #fourFan == 4 and fourFan[1] == -15 and fourFan[2] == -5 and fourFan[3] == 5 and fourFan[4] == 15)

	-- 3. Rejection of Spread Fire Without Active Aircraft
	local mockPlayer = {
		UserId = 888801,
		Name = "SpreadTestPilot",
	}
	local okNoPlane, errNoPlane = WeaponService.HandleFireIntent(mockPlayer :: any, "SpreadShot", Vector2.new(1, 0))
	assertTest("Spread fire without active plane is rejected", okNoPlane == false and errNoPlane == "NoActiveAircraft")

	-- 4. Authoritative Spread Fan Spawning
	local activePlanesFolder = Workspace:FindFirstChild("ActivePlanes")
	if not activePlanesFolder then
		activePlanesFolder = Instance.new("Folder")
		activePlanesFolder.Name = "ActivePlanes"
		activePlanesFolder.Parent = Workspace
	end

	local planeModel = Instance.new("Model")
	planeModel.Name = string.format("Plane_%d", mockPlayer.UserId)
	local rootPart = Instance.new("Part")
	rootPart.Name = "RootPart"
	rootPart.Size = Vector3.new(4, 1.2, 1.2)
	rootPart.Position = Vector3.new(-20, 0, GameConfig.Arena.PlayPlaneZ)
	rootPart.Anchored = true
	rootPart.Parent = planeModel
	planeModel.PrimaryPart = rootPart
	planeModel.Parent = activePlanesFolder

	local projFolder = Workspace:FindFirstChild("Projectiles")
	if projFolder then
		projFolder:ClearAllChildren()
	end

	local okFirst, errFirst = WeaponService.HandleFireIntent(mockPlayer :: any, "SpreadShot", Vector2.new(1, 0))
	assertTest("SpreadShot fire succeeds with active plane", okFirst == true and errFirst == nil)

	local projs = if projFolder then projFolder:GetChildren() else {}
	assertTest("SpreadShot spawned exactly 3 projectiles in Workspace.Projectiles", #projs == 3)

	-- 5. Projectile Attributes & Metadata Validation
	local centerFound = false
	local topFound = false
	local bottomFound = false

	for _, p in ipairs(projs) do
		local part = p :: BasePart
		assertTest("Spread projectile is anchored", part.Anchored == true)
		assertTest("Spread projectile has non-colliding physics (CanCollide=false)", part.CanCollide == false)
		assertTest("Spread projectile has OwnerUserId = 888801", part:GetAttribute("OwnerUserId") == 888801)
		assertTest("Spread projectile has Faction = 'Player'", part:GetAttribute("Faction") == "Player")
		assertTest("Spread projectile has BaseDamage = 8", part:GetAttribute("BaseDamage") == 8)
		assertTest("Spread projectile has ProjectileSpeed = 110", part:GetAttribute("ProjectileSpeed") == 110)

		local dirY = part:GetAttribute("DirectionY") :: number? or 0
		if math.abs(dirY) < 0.001 then
			centerFound = true
		elseif dirY > 0.1 then
			topFound = true
		elseif dirY < -0.1 then
			bottomFound = true
		end
	end

	assertTest("Spread fan contains center straight projectile (0°)", centerFound == true)
	assertTest("Spread fan contains upper angled projectile (+15°)", topFound == true)
	assertTest("Spread fan contains lower angled projectile (-15°)", bottomFound == true)

	-- 6. Server Cooldown Enforcement (0.4s)
	local okRapid, errRapid = WeaponService.HandleFireIntent(mockPlayer :: any, "SpreadShot", Vector2.new(1, 0))
	assertTest("Immediate second spread fire is rejected by cooldown", okRapid == false and errRapid == "CooldownActive")

	-- 7. Trajectory Divergence in Simulation
	-- Step simulation forward and check that top and bottom diverge vertically
	local projsBefore = ProjectileService.GetActiveProjectiles()
	ProjectileService.StepSimulation(0.2) -- Move forward by ~22 studs

	local topY: number? = nil
	local centerY: number? = nil
	local bottomY: number? = nil

	for _, proj in pairs(projsBefore) do
		if proj.direction.Y > 0.1 then
			topY = proj.position.Y
		elseif math.abs(proj.direction.Y) < 0.01 then
			centerY = proj.position.Y
		elseif proj.direction.Y < -0.1 then
			bottomY = proj.position.Y
		end
	end

	assertTest("Top projectile diverged upward (Y > centerY)", topY ~= nil and centerY ~= nil and topY > centerY)
	assertTest("Bottom projectile diverged downward (Y < centerY)", bottomY ~= nil and centerY ~= nil and bottomY < centerY)

	-- 8. Independent Hit Detection & Damage
	-- Spawn an authoritative enemy in front of the center projectile
	local enemySpawnPos = Vector3.new(15, 0, GameConfig.Arena.PlayPlaneZ)
	local enemyModel = EnemyService.SpawnEnemy("StraightFlyer", enemySpawnPos, 50, 100)
	assertTest("Test enemy spawned for spread hit validation", enemyModel ~= nil)

	local enemyId = enemyModel and enemyModel:GetAttribute("EnemyId") :: string
	local initialEnemyHp = enemyModel and enemyModel:GetAttribute("CurrentHealth") :: number

	-- Advance simulation until center projectile contacts enemy
	for _ = 1, 10 do
		ProjectileService.StepSimulation(0.05)
	end

	local finalEnemyHp = enemyModel and enemyModel:GetAttribute("CurrentHealth") :: number
	assertTest("Enemy received authoritative damage from spread projectile", finalEnemyHp ~= nil and finalEnemyHp < initialEnemyHp)
	assertTest("Enemy took exact 8 damage from center spread projectile (50 -> 42)", finalEnemyHp == 42)

	-- 9. Capacity Limit Enforcement
	-- Rapidly spawn projectiles to verify that maxActiveProjectiles is respected
	local maxLimit = ProjectileService.GetMaxActiveProjectiles()
	for _ = 1, 100 do
		ProjectileService.SpawnProjectile(888801, Vector3.new(0, 0, 0), Vector2.new(1, 0), spreadDef)
	end
	assertTest("Active projectile count does not exceed max limit", ProjectileService.GetActiveProjectileCount() <= maxLimit)

	-- 10. Teardown & Clean State
	planeModel:Destroy()
	EnemyService.CleanupAll()
	ProjectileService._Teardown()
	WeaponService._Teardown()
	if projFolder then
		projFolder:ClearAllChildren()
	end

	assertTest("WeaponService is uninitialized after teardown", WeaponService.IsInitialized() == false)
	assertTest("ProjectileService is uninitialized after teardown", ProjectileService.IsInitialized() == false)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return SpreadWeaponTests
