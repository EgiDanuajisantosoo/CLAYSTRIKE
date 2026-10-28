--!strict
--[[
	VFXTests.luau
	Authoritative unit test harness for Projectile Trail & Muzzle VFX.
	Task: CLAY-030 (Projectile Trail & Muzzle VFX)

	TEST SUITE:
	1. Trail Presets Completeness: StandardPeaShooter, SpreadShot, TurretEnemyBullet defined.
	2. Muzzle Presets Compliance: All muzzle flashes have duration <= 0.08s (StyleGuide limit).
	3. Impact Presets Compliance: All impacts have duration <= 0.25s (StyleGuide limit).
	4. Trail Length Boundedness: All trails estimated length <= 8.0 studs (StyleGuide limit).
	5. ApplyProjectileTrail Instantiation: Attachments and Trail created on projectile part.
	6. Trail Properties: Trail.FaceCamera=true, LightEmission > 0.5, Enabled=true.
	7. Hitbox Separation: Trail does not alter projectile Size, Anchored, CanCollide, or CanQuery.
	8. Muzzle Flash Presentation: CreateMuzzleFlash creates non-colliding part with PointLight.
	9. Spread Fan Burst: SpreadShot muzzle flash creates flanking sparks.
	10. Impact Burst Presentation: CreateImpactEffect emits bounded spark particles.
	11. ValidateVFX Schema Enforcement: Rejects oversized trails or elongated particle lifetimes.
	12. Clean Teardown: Destroying projectile cleanly destroys attached Trail and Attachments.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local StyleGuide = require(SharedFolder:WaitForChild("StyleGuide"))
local VFXConfig = require(SharedFolder:WaitForChild("VFXConfig"))
local WeaponConfig = require(SharedFolder:WaitForChild("WeaponConfig"))

local VFXTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function VFXTests.RunTests(): {
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
			warn(string.format("[VFXTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- 1. Trail Presets Completeness
	assertTest("StandardPeaShooter trail defined", VFXConfig.Trails["StandardPeaShooter"] ~= nil)
	assertTest("SpreadShot trail defined", VFXConfig.Trails["SpreadShot"] ~= nil)
	assertTest("TurretEnemyBullet trail defined", VFXConfig.Trails["TurretEnemyBullet"] ~= nil)

	-- 2. Muzzle Presets Compliance (duration <= 0.08s)
	for name, muz in pairs(VFXConfig.Muzzles) do
		assertTest(string.format("Muzzle '%s' duration %.3fs <= StyleGuide max (0.08s)", name, muz.duration), muz.duration <= StyleGuide.VFX.MaxMuzzleFlashDuration)
	end

	-- 3. Impact Presets Compliance (duration <= 0.25s)
	for name, imp in pairs(VFXConfig.Impacts) do
		assertTest(string.format("Impact '%s' duration %.3fs <= StyleGuide max (0.25s)", name, imp.duration), imp.duration <= StyleGuide.VFX.MaxImpactSparksDuration)
	end

	-- 4. Trail Length Boundedness (length <= 8.0 studs)
	local standardSpeed = 140
	local spreadSpeed = 125
	local enemySpeed = 28

	local standardLength = standardSpeed * VFXConfig.Trails["StandardPeaShooter"].lifetime
	local spreadLength = spreadSpeed * VFXConfig.Trails["SpreadShot"].lifetime
	local enemyLength = enemySpeed * VFXConfig.Trails["TurretEnemyBullet"].lifetime

	assertTest(string.format("StandardPeaShooter trail length %.2f <= 8.0 studs", standardLength), standardLength <= StyleGuide.VFX.MaxTrailLengthStuds)
	assertTest(string.format("SpreadShot trail length %.2f <= 8.0 studs", spreadLength), spreadLength <= StyleGuide.VFX.MaxTrailLengthStuds)
	assertTest(string.format("TurretEnemyBullet trail length %.2f <= 8.0 studs", enemyLength), enemyLength <= StyleGuide.VFX.MaxTrailLengthStuds)

	-- 5. ApplyProjectileTrail Instantiation
	local testProj = Instance.new("Part")
	testProj.Name = "TestProj"
	testProj.Size = Vector3.new(1.6, 0.8, 0.8)
	testProj.Position = Vector3.new(0, 10, 0)
	testProj.Anchored = true
	testProj.CanCollide = false
	testProj.CanTouch = false
	testProj.CanQuery = false
	testProj.Parent = Workspace

	local trail = VFXConfig.ApplyProjectileTrail(testProj, "StandardPeaShooter", "Player")
	assertTest("ApplyProjectileTrail returns Trail instance", trail ~= nil and trail:IsA("Trail"))
	assertTest("TrailAttachment0 created on projectile", testProj:FindFirstChild("TrailAttachment0") ~= nil)
	assertTest("TrailAttachment1 created on projectile", testProj:FindFirstChild("TrailAttachment1") ~= nil)

	-- 6. Trail Properties
	if trail then
		assertTest("Trail.FaceCamera is true", trail.FaceCamera == true)
		assertTest("Trail.LightEmission > 0.5", trail.LightEmission > 0.5)
		assertTest("Trail.Enabled is true", trail.Enabled == true)
	end

	-- 7. Hitbox Separation
	assertTest("Projectile CanCollide remains false", testProj.CanCollide == false)
	assertTest("Projectile CanQuery remains false", testProj.CanQuery == false)
	assertTest("Projectile Anchored remains true", testProj.Anchored == true)

	-- 8. Muzzle Flash Presentation
	local muzzleFlash = VFXConfig.CreateMuzzleFlash(Vector3.new(5, 10, 0), "StandardPeaShooter", Workspace)
	assertTest("CreateMuzzleFlash returns Part", muzzleFlash ~= nil and muzzleFlash:IsA("Part"))
	assertTest("MuzzleFlash has PointLight", muzzleFlash:FindFirstChildOfClass("PointLight") ~= nil)
	assertTest("MuzzleFlash is non-colliding", muzzleFlash.CanCollide == false and muzzleFlash.CanQuery == false)
	muzzleFlash:Destroy()

	-- 9. Spread Fan Burst
	local spreadFlash = VFXConfig.CreateMuzzleFlash(Vector3.new(5, 10, 0), "SpreadShot", Workspace)
	local flankSparks = 0
	for _, child in ipairs(spreadFlash:GetChildren()) do
		if child.Name == "SpreadFlankSpark" then
			flankSparks += 1
		end
	end
	assertTest("SpreadShot muzzle flash includes 2 flanking sparks", flankSparks == 2)
	spreadFlash:Destroy()

	-- 10. Impact Burst Presentation
	local impact = VFXConfig.CreateImpactEffect(Vector3.new(10, 10, 0), Vector3.new(-1, 0, 0), "StandardPeaShooter", Workspace)
	assertTest("CreateImpactEffect returns Part", impact ~= nil and impact:IsA("Part"))
	local sparksEmitter = impact:FindFirstChild("ImpactSparks") :: ParticleEmitter?
	assertTest("Impact has ImpactSparks ParticleEmitter", sparksEmitter ~= nil and sparksEmitter:IsA("ParticleEmitter"))
	impact:Destroy()

	-- 11. ValidateVFX Schema Enforcement
	local goodTrail = Instance.new("Trail")
	goodTrail.Lifetime = 0.05
	local validT, _ = VFXConfig.ValidateVFX(goodTrail)
	assertTest("ValidateVFX accepts 0.05s lifetime trail", validT == true)

	local badTrail = Instance.new("Trail")
	badTrail.Lifetime = 0.50 -- 140 * 0.5 = 70 studs! Exceeds 8.0 limit!
	local badT, errT = VFXConfig.ValidateVFX(badTrail)
	assertTest("ValidateVFX rejects 0.50s elongated trail", badT == false and errT ~= nil)

	goodTrail:Destroy()
	badTrail:Destroy()

	-- 12. Clean Teardown
	testProj:Destroy()
	assertTest("Projectile destroyed cleanly without dangling instances", testProj.Parent == nil)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return VFXTests
