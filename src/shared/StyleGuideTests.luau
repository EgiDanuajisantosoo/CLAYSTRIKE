--!strict
--[[
	StyleGuideTests.luau
	Unit test harness for visual style guide standards, color palettes, and VFX limits.
	Task: CLAY-026 (Visual Style Guide)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local sharedStyleGuide = SharedFolder:WaitForChild("StyleGuide")
local StyleGuide = require(sharedStyleGuide)
if (StyleGuide :: any).Colors == nil then
	StyleGuide = require(sharedStyleGuide:Clone())
end

local StyleGuideTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function StyleGuideTests.RunTests(): {
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
			warn(string.format("[StyleGuideTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- 1. Palette completeness and uniqueness
	assertTest("Player1 color is defined", StyleGuide.Colors.Player1 ~= nil)
	assertTest("Player2 color is defined", StyleGuide.Colors.Player2 ~= nil)
	assertTest("Player3 color is defined", StyleGuide.Colors.Player3 ~= nil)
	assertTest("Player4 color is defined", StyleGuide.Colors.Player4 ~= nil)
	assertTest("PlayerStandardBullet is defined", StyleGuide.Colors.PlayerStandardBullet ~= nil)
	assertTest("PlayerSpreadBullet is defined", StyleGuide.Colors.PlayerSpreadBullet ~= nil)
	assertTest("EnemyBullet is defined", StyleGuide.Colors.EnemyBullet ~= nil)

	-- Distinct contrast: player bullet vs enemy bullet
	assertTest("Player standard bullet differs from enemy bullet", StyleGuide.Colors.PlayerStandardBullet ~= StyleGuide.Colors.EnemyBullet)

	-- 2. Material preset constraints
	assertTest("ClayPrimary material is SmoothPlastic", StyleGuide.Materials.ClayPrimary == Enum.Material.SmoothPlastic)
	assertTest("ClayRoughness >= 0.6", StyleGuide.Materials.ClayRoughness >= 0.6)
	assertTest("ClayMetalness <= 0.1", StyleGuide.Materials.ClayMetalness <= 0.1)

	-- 3. VFX duration caps
	assertTest("MaxMuzzleFlashDuration <= 0.1s", StyleGuide.VFX.MaxMuzzleFlashDuration <= 0.1)
	assertTest("MaxImpactSparksDuration <= 0.3s", StyleGuide.VFX.MaxImpactSparksDuration <= 0.3)
	assertTest("MaxExplosionBurstDuration <= 0.5s", StyleGuide.VFX.MaxExplosionBurstDuration <= 0.5)
	assertTest("MaxTrailLengthStuds <= 10 studs", StyleGuide.VFX.MaxTrailLengthStuds <= 10.0)

	-- 4. Particle lifetime validator function
	local emitter = Instance.new("ParticleEmitter")
	emitter.Lifetime = NumberRange.new(0.05, 0.07)
	local valid, _ = StyleGuide.ValidateParticleLifetime(emitter, "MuzzleFlash")
	assertTest("Conforming muzzle flash emitter passes validation", valid == true)

	emitter.Lifetime = NumberRange.new(0.2, 0.5)
	local invalid, err = StyleGuide.ValidateParticleLifetime(emitter, "MuzzleFlash")
	assertTest("Over-length muzzle flash fails validation", invalid == false and err ~= nil)
	emitter:Destroy()

	-- 5. Dimensions envelope check
	local playerDim = StyleGuide.Dimensions.PlayerAircraft
	assertTest("PlayerAircraft MinLength < MaxLength", playerDim.MinLength < playerDim.MaxLength)
	assertTest("PlayerAircraft MinWingspan < MaxWingspan", playerDim.MinWingspan < playerDim.MaxWingspan)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return StyleGuideTests
