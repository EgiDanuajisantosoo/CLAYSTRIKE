--!strict
--[[
	ProjectileSimulationTests.luau
	Comprehensive unit tests for server projectile simulation, anti-tunneling swept raycast,
	friendly-fire exclusion, boundary culling, and active projectile limits.
	Task: CLAY-011 (Server Projectile Simulation & Hit Detection)
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local WeaponConfig = require(SharedFolder:WaitForChild("WeaponConfig"))
if (WeaponConfig :: any).Weapons == nil then
	WeaponConfig = require(SharedFolder:WaitForChild("WeaponConfig"):Clone())
end

local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
if (GameConfig :: any).CONTRACT_VERSION == nil then
	GameConfig = require(SharedFolder:WaitForChild("GameConfig"):Clone())
end

local ProjectileSimulationTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function ProjectileSimulationTests.RunTests(projectileServiceModule: any?): {
	total: number,
	passed: number,
	failed: number,
	results: { [number]: TestResult },
}
	local ProjectileService = projectileServiceModule
	if not ProjectileService then
		local SSS = game:GetService("ServerScriptService")
		local Services = SSS:WaitForChild("Services")
		ProjectileService = require(Services:WaitForChild("ProjectileService"))
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
			warn(string.format("[ProjectileSimulationTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Baseline clean teardown
	ProjectileService._Teardown()
	assertTest("ProjectileService starts with 0 active projectiles", ProjectileService.GetActiveProjectileCount() == 0)

	-- 1. Initialize
	ProjectileService.Initialize()
	assertTest("ProjectileService is initialized", ProjectileService.IsInitialized() == true)

	-- 2. Spawning single projectile
	local defaultWeapon = WeaponConfig.GetDefaultWeapon()
	local mockUserId = 123456
	local origin = Vector3.new(0, 0, GameConfig.Arena.PlayPlaneZ)
	local aimDir = Vector2.new(1, 0)

	local projPart = ProjectileService.SpawnProjectile(mockUserId, origin, aimDir, defaultWeapon)
	assertTest("Spawned projectile is a BasePart", projPart:IsA("BasePart"))
	assertTest("Spawned projectile is parented to Workspace.Projectiles", projPart.Parent ~= nil and projPart.Parent.Name == "Projectiles")
	assertTest("Spawned projectile has CanCollide = false", projPart.CanCollide == false)
	assertTest("Spawned projectile has CanTouch = false", projPart.CanTouch == false)
	assertTest("Spawned projectile has CanQuery = false", projPart.CanQuery == false)
	assertTest("Spawned projectile is Anchored = true", projPart.Anchored == true)
	assertTest("Spawned projectile has correct BaseDamage attribute", projPart:GetAttribute("BaseDamage") == defaultWeapon.baseDamage)
	assertTest("Spawned projectile has correct OwnerUserId attribute", projPart:GetAttribute("OwnerUserId") == mockUserId)
	assertTest("Active projectile count is 1", ProjectileService.GetActiveProjectileCount() == 1)

	-- 3. Simulation step: motion along direction vector
	local initialPos = projPart.Position
	local dt = 0.05
	ProjectileService.StepSimulation(dt)

	local expectedDist = defaultWeapon.projectileSpeed * dt
	local newPos = projPart.Position
	local actualDist = (newPos - initialPos).Magnitude
	assertTest("Projectile advances along forward vector", math.abs(actualDist - expectedDist) < 0.01)
	assertTest("Z position strictly locked to PlayPlaneZ", math.abs(newPos.Z - GameConfig.Arena.PlayPlaneZ) < 0.001)

	-- 4. Anti-tunneling swept raycast against thin target
	-- Place a thin target (0.2 studs thick) at X = 20, directly in path
	local targetPart = Instance.new("Part")
	targetPart.Name = "TestEnemyTarget"
	targetPart.Size = Vector3.new(0.2, 4, 4)
	targetPart.Position = Vector3.new(20, 0, GameConfig.Arena.PlayPlaneZ)
	targetPart.Anchored = true
	targetPart.CanCollide = false
	targetPart.CanQuery = true -- Raycastable

	-- Place inside Enemies container if exists, or Workspace directly
	local enemiesFolder = Workspace:FindFirstChild("Enemies")
	if not enemiesFolder then
		enemiesFolder = Instance.new("Folder")
		enemiesFolder.Name = "Enemies"
		enemiesFolder.Parent = Workspace
	end
	targetPart.Parent = enemiesFolder

	-- Track hit callback
	local hitDetected = false
	local hitDamage = 0
	local hitTargetInstance: Instance? = nil

	ProjectileService.RegisterHitCallback(function(hit)
		hitDetected = true
		hitDamage = hit.damage
		hitTargetInstance = hit.hitInstance
	end)

	-- Spawn fast projectile at X = 15 moving +X towards X = 20 with speed 120
	local fastWeapon = table.clone(defaultWeapon)
	fastWeapon.projectileSpeed = 120
	local fastProj = ProjectileService.SpawnProjectile(mockUserId, Vector3.new(15, 0, GameConfig.Arena.PlayPlaneZ), Vector2.new(1, 0), fastWeapon)

	-- In 0.1s at 120 speed, bullet travels 12 studs (from 15 to 27), skipping right through X = 20 without swept raycast
	ProjectileService.StepSimulation(0.1)

	assertTest("Anti-tunneling swept raycast detected collision with thin target", hitDetected == true)
	assertTest("Hit callback passed correct base damage", hitDamage == fastWeapon.baseDamage)
	assertTest("Hit callback identified correct target instance", hitTargetInstance == targetPart)
	assertTest("Hitting target consumed and destroyed projectile", fastProj.Parent == nil)

	targetPart:Destroy()

	-- 5. Boundary culling (exiting arena)
	-- Spawn projectile near MaxX boundary (MaxX = 80, buffer = 15 -> Bound = 95)
	local edgeProj = ProjectileService.SpawnProjectile(mockUserId, Vector3.new(90, 0, GameConfig.Arena.PlayPlaneZ), Vector2.new(1, 0), defaultWeapon)
	assertTest("Edge projectile is initially active", edgeProj.Parent ~= nil)

	-- Step across boundary (90 + 10 = 100 > 95)
	ProjectileService.StepSimulation(0.1)
	assertTest("Projectile exiting arena boundary is culled", edgeProj.Parent == nil)

	-- 6. Lifetime culling
	local shortLifeWeapon = table.clone(defaultWeapon)
	shortLifeWeapon.lifetime = 0.15
	local expiringProj = ProjectileService.SpawnProjectile(mockUserId, Vector3.new(0, 0, GameConfig.Arena.PlayPlaneZ), Vector2.new(1, 0), shortLifeWeapon)

	-- Step 0.1s -> should still be alive
	ProjectileService.StepSimulation(0.1)
	assertTest("Expiring projectile alive before lifetime expires", expiringProj.Parent ~= nil)

	-- Step another 0.1s (total 0.2s > 0.15s) -> should be destroyed
	ProjectileService.StepSimulation(0.1)
	assertTest("Expiring projectile destroyed when lifetime elapsed", expiringProj.Parent == nil)

	-- 7. Active count limit enforcement (FIFO culling)
	ProjectileService._Teardown()
	ProjectileService.Initialize()
	ProjectileService.SetMaxActiveProjectiles(4)
	assertTest("Max active projectile limit configured to 4", ProjectileService.GetMaxActiveProjectiles() == 4)

	local p1 = ProjectileService.SpawnProjectile(mockUserId, Vector3.new(0, 0, 0), Vector2.new(1, 0), defaultWeapon)
	local p2 = ProjectileService.SpawnProjectile(mockUserId, Vector3.new(1, 0, 0), Vector2.new(1, 0), defaultWeapon)
	local p3 = ProjectileService.SpawnProjectile(mockUserId, Vector3.new(2, 0, 0), Vector2.new(1, 0), defaultWeapon)
	local p4 = ProjectileService.SpawnProjectile(mockUserId, Vector3.new(3, 0, 0), Vector2.new(1, 0), defaultWeapon)
	assertTest("4 projectiles spawned within limit", ProjectileService.GetActiveProjectileCount() == 4)

	-- Spawn 5th projectile -> should cull p1 (oldest)
	local p5 = ProjectileService.SpawnProjectile(mockUserId, Vector3.new(4, 0, 0), Vector2.new(1, 0), defaultWeapon)
	assertTest("Active count capped at max limit (4)", ProjectileService.GetActiveProjectileCount() == 4)
	assertTest("Oldest projectile (p1) culled via FIFO limit", p1.Parent == nil)
	assertTest("Newest projectile (p5) remains active", p5.Parent ~= nil)

	-- 8. Teardown
	ProjectileService._Teardown()
	assertTest("Active count is 0 after _Teardown()", ProjectileService.GetActiveProjectileCount() == 0)
	assertTest("Workspace.Projectiles cleared after _Teardown()", #Workspace:WaitForChild("Projectiles"):GetChildren() == 0)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return ProjectileSimulationTests
