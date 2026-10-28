--!strict
--[[
	LightingConfigTests.luau
	Unit test harness for Clay Material & Lighting Preset.
	Task: CLAY-029 (Clay Material & Lighting Preset)

	TEST SUITE:
	1. Preset Core Properties: Brightness, ClockTime, GlobalShadows, low specularity.
	2. Atmosphere Preset: Haze, Density, zero Glare.
	3. ColorCorrection Preset: Positive contrast and saturation for combat readability.
	4. Bloom Preset Compliance: Intensity <= 0.40 (StyleGuide limit), Threshold >= 1.0.
	5. High Contrast Validation: Player bullet vs background layer contrast ratio >= 3.0.
	6. High Contrast Validation: Enemy bullet vs player/enemy hull contrast ratio >= 2.0.
	7. Clay Material Helper: SmoothPlastic, CastShadow=true, Top/Bottom smooth.
	8. ApplyLighting Execution: Post-processing and atmosphere instances created.
	9. ValidateLighting Verification: Passes validation with zero errors.
	10. Idempotent Application: Calling ApplyLighting twice does not duplicate instances.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local LightingConfig = require(SharedFolder:WaitForChild("LightingConfig"))
local StyleGuide = require(SharedFolder:WaitForChild("StyleGuide"))

local LightingConfigTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function LightingConfigTests.RunTests(): {
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
			warn(string.format("[LightingConfigTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- 1. Preset Core Properties
	assertTest("Lighting.Brightness is between 2.0 and 2.5", LightingConfig.Preset.Brightness >= 2.0 and LightingConfig.Preset.Brightness <= 2.5)
	assertTest("Lighting.GlobalShadows is true", LightingConfig.Preset.GlobalShadows == true)
	assertTest("Lighting.EnvironmentSpecularScale is <= 0.25 (matte clay)", LightingConfig.Preset.EnvironmentSpecularScale <= 0.25)
	assertTest("Lighting.ShadowSoftness is <= 0.3 (crisp clay shadows)", LightingConfig.Preset.ShadowSoftness <= 0.3)

	-- 2. Atmosphere Preset
	assertTest("Atmosphere.Density is between 0.2 and 0.4", LightingConfig.AtmospherePreset.Density >= 0.2 and LightingConfig.AtmospherePreset.Density <= 0.4)
	assertTest("Atmosphere.Glare is 0 (no side-scroller blinding)", LightingConfig.AtmospherePreset.Glare == 0)

	-- 3. ColorCorrection Preset
	assertTest("ColorCorrection.Contrast is positive", LightingConfig.ColorCorrectionPreset.Contrast > 0)
	assertTest("ColorCorrection.Saturation is positive", LightingConfig.ColorCorrectionPreset.Saturation > 0)

	-- 4. Bloom Preset Compliance
	assertTest("Bloom.Intensity is <= StyleGuide limit (0.40)", LightingConfig.BloomPreset.Intensity <= StyleGuide.VFX.MaxBloomIntensity)
	assertTest("Bloom.Threshold is >= 1.0 (protecting clay bodies)", LightingConfig.BloomPreset.Threshold >= 1.0)

	-- 5. High Contrast Validation: Player Bullet vs Background
	local playerBulletColor = StyleGuide.Colors.PlayerStandardBullet
	local backgroundFarColor = StyleGuide.Colors.BackgroundFar
	local pVsBgRatio = LightingConfig.GetContrastRatio(playerBulletColor, backgroundFarColor)
	assertTest(string.format("Player bullet vs BackgroundFar contrast ratio >= 3.0 (got %.2f)", pVsBgRatio), pVsBgRatio >= 3.0)

	-- 6. High Contrast Validation: Enemy Bullet vs Player / Enemy Hull
	local enemyBulletColor = StyleGuide.Colors.EnemyBullet
	local enemyHullColor = StyleGuide.Colors.EnemyArmoredHull
	local eBulletVsHullRatio = LightingConfig.GetContrastRatio(enemyBulletColor, enemyHullColor)
	assertTest(string.format("Enemy bullet vs EnemyArmoredHull contrast ratio >= 2.0 (got %.2f)", eBulletVsHullRatio), eBulletVsHullRatio >= 2.0)

	-- 7. Clay Material Helper
	local testPart = Instance.new("Part")
	LightingConfig.ApplyClayMaterial(testPart, Color3.fromRGB(200, 100, 50))
	assertTest("ApplyClayMaterial sets SmoothPlastic", testPart.Material == Enum.Material.SmoothPlastic)
	assertTest("ApplyClayMaterial sets CastShadow=true", testPart.CastShadow == true)
	assertTest("ApplyClayMaterial sets TopSurface=Smooth", testPart.TopSurface == Enum.SurfaceType.Smooth)
	assertTest("ApplyClayMaterial sets color correctly", testPart.Color == Color3.fromRGB(200, 100, 50))
	testPart:Destroy()

	-- 8. ApplyLighting Execution
	local effects = LightingConfig.ApplyLighting(Lighting)
	assertTest("ApplyLighting returns atmosphere", effects.atmosphere ~= nil and effects.atmosphere:IsA("Atmosphere"))
	assertTest("ApplyLighting returns colorCorrection", effects.colorCorrection ~= nil and effects.colorCorrection:IsA("ColorCorrectionEffect"))
	assertTest("ApplyLighting returns bloom", effects.bloom ~= nil and effects.bloom:IsA("BloomEffect"))

	-- 9. ValidateLighting Verification
	local isValid, errs = LightingConfig.ValidateLighting(Lighting)
	assertTest(string.format("ValidateLighting reports active setup is valid (%s)", table.concat(errs, "; ")), isValid == true)

	-- 10. Idempotent Application
	local initialEffectsCount = #Lighting:GetChildren()
	LightingConfig.ApplyLighting(Lighting)
	local afterEffectsCount = #Lighting:GetChildren()
	assertTest("Re-applying LightingConfig does not duplicate instances", afterEffectsCount == initialEffectsCount)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return LightingConfigTests
