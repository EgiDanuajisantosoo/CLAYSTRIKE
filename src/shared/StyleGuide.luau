--!strict
--[[
	StyleGuide.luau
	Authoritative visual style guide constants and validation schemas for CLAYSTRIKE.
	Task: CLAY-026 (Visual Style Guide — Hybrid Clay + Modern VFX)

	Provides canonical color palettes, material presets, lighting defaults,
	and programmatic validation rules for models and particle effects.
]]

export type ColorPalette = {
	Player1: Color3,
	Player2: Color3,
	Player3: Color3,
	Player4: Color3,
	PlayerStandardBullet: Color3,
	PlayerSpreadBullet: Color3,
	EnemyCommonHull: Color3,
	EnemyAccentHull: Color3,
	EnemyArmoredHull: Color3,
	EnemyBullet: Color3,
	BackgroundNear: Color3,
	BackgroundMid: Color3,
	BackgroundFar: Color3,
}

export type VFXLimits = {
	MaxMuzzleFlashDuration: number,
	MaxImpactSparksDuration: number,
	MaxExplosionBurstDuration: number,
	MaxResidualSmokeDuration: number,
	MaxTrailLengthStuds: number,
	MaxBloomIntensity: number,
}

export type ArchetypeDimensions = {
	MinLength: number,
	MaxLength: number,
	MinWingspan: number,
	MaxWingspan: number,
}

local StyleGuide = {}

-- Canonical Color Palettes
StyleGuide.Colors = {
	-- Co-op Players 1 to 4
	Player1 = Color3.fromRGB(215, 60, 50), -- Crimson Clay
	Player2 = Color3.fromRGB(45, 120, 215), -- Cobalt Clay
	Player3 = Color3.fromRGB(225, 170, 40), -- Ochre Amber
	Player4 = Color3.fromRGB(50, 185, 110), -- Jade Mint

	-- Player Weapon Projectiles
	PlayerStandardBullet = Color3.fromRGB(255, 235, 75), -- High-vis Lemon Gold
	PlayerSpreadBullet = Color3.fromRGB(80, 225, 255), -- Electric Cyan

	-- Enemies
	EnemyCommonHull = Color3.fromRGB(110, 65, 95), -- Rust Purple
	EnemyAccentHull = Color3.fromRGB(95, 110, 65), -- Olive Clay
	EnemyArmoredHull = Color3.fromRGB(50, 45, 55), -- Slate Obsidian
	EnemyBullet = Color3.fromRGB(255, 60, 90), -- High-vis Warning Coral

	-- Environment Layers
	BackgroundNear = Color3.fromRGB(180, 160, 145), -- Warm Sand
	BackgroundMid = Color3.fromRGB(120, 100, 90), -- Earth Umber
	BackgroundFar = Color3.fromRGB(80, 70, 75), -- Dusty Lavender
} :: ColorPalette

-- Material Presets
StyleGuide.Materials = {
	ClayPrimary = Enum.Material.SmoothPlastic,
	ClayRoughness = 0.65,
	ClayMetalness = 0.05,
}

-- VFX Constraints to guarantee combat clarity and prevent bullet obscuration
StyleGuide.VFX = {
	MaxMuzzleFlashDuration = 0.08,
	MaxImpactSparksDuration = 0.25,
	MaxExplosionBurstDuration = 0.40,
	MaxResidualSmokeDuration = 0.60,
	MaxTrailLengthStuds = 8.0,
	MaxBloomIntensity = 0.4,
} :: VFXLimits

-- Model Dimension Envelopes (in studs)
StyleGuide.Dimensions = {
	PlayerAircraft = {
		MinLength = 10,
		MaxLength = 14,
		MinWingspan = 8,
		MaxWingspan = 12,
	} :: ArchetypeDimensions,
	EnemyStraightFlyer = {
		MinLength = 6,
		MaxLength = 8,
		MinWingspan = 5,
		MaxWingspan = 7,
	} :: ArchetypeDimensions,
	EnemyPursuer = {
		MinLength = 8,
		MaxLength = 10,
		MinWingspan = 7,
		MaxWingspan = 9,
	} :: ArchetypeDimensions,
	EnemyTurretShooter = {
		MinLength = 10,
		MaxLength = 12,
		MinWingspan = 10,
		MaxWingspan = 12,
	} :: ArchetypeDimensions,
}

-- Lighting Preset
StyleGuide.Lighting = {
	Ambient = Color3.fromRGB(80, 80, 95),
	OutdoorAmbient = Color3.fromRGB(100, 95, 90),
	Brightness = 2.0,
	ClockTime = 14.5,
	GlobalShadows = true,
}

--[[
	Validates that a particle emitter conforms to readability duration constraints.
]]
function StyleGuide.ValidateParticleLifetime(emitter: ParticleEmitter, category: string): (boolean, string?)
	local maxAllowed = StyleGuide.VFX.MaxExplosionBurstDuration
	if category == "MuzzleFlash" then
		maxAllowed = StyleGuide.VFX.MaxMuzzleFlashDuration
	elseif category == "Impact" then
		maxAllowed = StyleGuide.VFX.MaxImpactSparksDuration
	elseif category == "Smoke" then
		maxAllowed = StyleGuide.VFX.MaxResidualSmokeDuration
	end

	local maxLifetime = emitter.Lifetime.Max
	if maxLifetime > maxAllowed then
		return false, string.format("Particle lifetime %.2fs exceeds maximum allowed %.2fs for %s", maxLifetime, maxAllowed, category)
	end
	return true, nil
end

return StyleGuide
