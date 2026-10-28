--!strict
--[[
	LightingConfig.luau
	Authoritative claymation lighting presets, atmosphere, post-processing,
	and material conventions for CLAYSTRIKE.
	Task: CLAY-029 (Clay Material & Lighting Preset)

	Standardizes surface appearance and scene lighting:
	- Warm claymation studio lighting with defined key and fill shifts.
	- Atmospheric depth haze separating gameplay 2.5D plane from background layers.
	- ColorCorrection tuned for punchy readability without blinding saturation.
	- Bloom threshold strictly bounded to luminous projectiles/muzzles (<= 0.4 max intensity).
	- Clay material helper for parts ensuring matte, tactile SmoothPlastic surfaces.
]]

local LightingConfig = {}

-- Canonical Claymation Lighting Preset
LightingConfig.Preset = {
	Brightness = 2.2,
	ClockTime = 14.5, -- 2:30 PM warm key sunlight
	GeographicLatitude = 35,
	Ambient = Color3.fromRGB(85, 80, 95), -- Cool ambient fill
	OutdoorAmbient = Color3.fromRGB(115, 105, 95), -- Warm ground bounce
	ColorShift_Top = Color3.fromRGB(255, 248, 235), -- Warm sun key
	ColorShift_Bottom = Color3.fromRGB(85, 80, 95), -- Soft shadow fill
	GlobalShadows = true,
	ShadowSoftness = 0.2, -- Crisp stop-motion clay shadows
	EnvironmentDiffuseScale = 0.45,
	EnvironmentSpecularScale = 0.20, -- Low specularity to preserve matte clay texture
}

-- Atmosphere Depth Haze Preset
LightingConfig.AtmospherePreset = {
	Density = 0.28,
	Offset = 0.25,
	Haze = 0.8,
	Color = Color3.fromRGB(190, 180, 195),
	Decay = Color3.fromRGB(105, 95, 115),
	Glare = 0, -- Zero blinding glare in side-scroller view
}

-- Color Grading Preset
LightingConfig.ColorCorrectionPreset = {
	Brightness = 0.04,
	Contrast = 0.12, -- High readability for small bullets against scenery
	Saturation = 0.10, -- Vibrant earthy tones
	TintColor = Color3.fromRGB(255, 252, 248), -- Gentle warm glaze
}

-- High-vis Bloom Bounds
LightingConfig.BloomPreset = {
	Intensity = 0.35, -- Strictly <= 0.4 MaxBloomIntensity from StyleGuide
	Size = 16,
	Threshold = 1.25, -- Only bright bullets/muzzles bloom, clay remains matte
}

-- Depth of Field Preset (Subtle focus on PlayPlaneZ)
LightingConfig.DepthOfFieldPreset = {
	FocusDistance = 80,
	InFocusRadius = 25,
	NearIntensity = 0.1,
	FarIntensity = 0.35,
}

--[[
	Calculates the relative luminance of a Color3 according to WCAG sRGB specification.
]]
function LightingConfig.GetRelativeLuminance(color: Color3): number
	local function channelLum(val: number): number
		if val <= 0.03928 then
			return val / 12.92
		else
			return ((val + 0.055) / 1.055) ^ 2.4
		end
	end
	return 0.2126 * channelLum(color.R) + 0.7152 * channelLum(color.G) + 0.0722 * channelLum(color.B)
end

--[[
	Calculates the contrast ratio between two colors (ranging from 1.0 to 21.0).
]]
function LightingConfig.GetContrastRatio(c1: Color3, c2: Color3): number
	local l1 = LightingConfig.GetRelativeLuminance(c1)
	local l2 = LightingConfig.GetRelativeLuminance(c2)
	local lighter = math.max(l1, l2)
	local darker = math.min(l1, l2)
	return (lighter + 0.05) / (darker + 0.05)
end

--[[
	Applies the canonical clay material properties to a BasePart.
]]
function LightingConfig.ApplyClayMaterial(part: BasePart, color: Color3?)
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CastShadow = true
	if color then
		part.Color = color
	end
end

--[[
	Configures Lighting and creates/updates post-processing effects.
	Idempotent: updates existing instances without duplicating them.
]]
function LightingConfig.ApplyLighting(lightingService: Lighting): {
	atmosphere: Atmosphere,
	colorCorrection: ColorCorrectionEffect,
	bloom: BloomEffect,
}
	-- 1. Lighting service core properties
	lightingService.Brightness = LightingConfig.Preset.Brightness
	lightingService.ClockTime = LightingConfig.Preset.ClockTime
	lightingService.GeographicLatitude = LightingConfig.Preset.GeographicLatitude
	lightingService.Ambient = LightingConfig.Preset.Ambient
	lightingService.OutdoorAmbient = LightingConfig.Preset.OutdoorAmbient
	lightingService.ColorShift_Top = LightingConfig.Preset.ColorShift_Top
	lightingService.ColorShift_Bottom = LightingConfig.Preset.ColorShift_Bottom
	lightingService.GlobalShadows = LightingConfig.Preset.GlobalShadows
	lightingService.ShadowSoftness = LightingConfig.Preset.ShadowSoftness
	lightingService.EnvironmentDiffuseScale = LightingConfig.Preset.EnvironmentDiffuseScale
	lightingService.EnvironmentSpecularScale = LightingConfig.Preset.EnvironmentSpecularScale

	-- 2. Atmosphere
	local atmosphere = lightingService:FindFirstChildOfClass("Atmosphere")
	if not atmosphere then
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Name = "Atmosphere"
		atmosphere.Parent = lightingService
	end
	atmosphere.Density = LightingConfig.AtmospherePreset.Density
	atmosphere.Offset = LightingConfig.AtmospherePreset.Offset
	atmosphere.Haze = LightingConfig.AtmospherePreset.Haze
	atmosphere.Color = LightingConfig.AtmospherePreset.Color
	atmosphere.Decay = LightingConfig.AtmospherePreset.Decay
	atmosphere.Glare = LightingConfig.AtmospherePreset.Glare

	-- 3. ColorCorrectionEffect
	local colorCorrection = lightingService:FindFirstChildOfClass("ColorCorrectionEffect")
	if not colorCorrection then
		colorCorrection = Instance.new("ColorCorrectionEffect")
		colorCorrection.Name = "ClayColorCorrection"
		colorCorrection.Parent = lightingService
	end
	colorCorrection.Brightness = LightingConfig.ColorCorrectionPreset.Brightness
	colorCorrection.Contrast = LightingConfig.ColorCorrectionPreset.Contrast
	colorCorrection.Saturation = LightingConfig.ColorCorrectionPreset.Saturation
	colorCorrection.TintColor = LightingConfig.ColorCorrectionPreset.TintColor
	colorCorrection.Enabled = true

	-- 4. BloomEffect (reuse existing Bloom and clamp strictly to StyleGuide limits)
	local bloom = lightingService:FindFirstChildOfClass("BloomEffect")
	if not bloom then
		bloom = Instance.new("BloomEffect")
		bloom.Name = "Bloom"
		bloom.Parent = lightingService
	end
	bloom.Intensity = LightingConfig.BloomPreset.Intensity
	bloom.Size = LightingConfig.BloomPreset.Size
	bloom.Threshold = LightingConfig.BloomPreset.Threshold
	bloom.Enabled = true

	-- Clean up duplicate BloomEffects if any exist
	for _, child in ipairs(lightingService:GetChildren()) do
		if child:IsA("BloomEffect") and child ~= bloom then
			child:Destroy()
		end
	end

	return {
		atmosphere = atmosphere,
		colorCorrection = colorCorrection,
		bloom = bloom,
	}
end

--[[
	Validates that the active Lighting and post-processing match the style rules.
]]
function LightingConfig.ValidateLighting(lightingService: Lighting): (boolean, { string })
	local errors: { string } = {}

	if lightingService.Brightness < 1.5 or lightingService.Brightness > 3.0 then
		table.insert(errors, string.format("Lighting.Brightness %.2f out of bounds [1.5, 3.0]", lightingService.Brightness))
	end

	if not lightingService.GlobalShadows then
		table.insert(errors, "Lighting.GlobalShadows must be enabled for clay depth")
	end

	local cc = lightingService:FindFirstChildOfClass("ColorCorrectionEffect")
	if not cc or not cc.Enabled then
		table.insert(errors, "ColorCorrectionEffect missing or disabled")
	end

	local bloom = lightingService:FindFirstChildOfClass("BloomEffect")
	if bloom and bloom.Enabled then
		if bloom.Intensity > 0.40 then
			table.insert(errors, string.format("BloomEffect intensity %.2f exceeds StyleGuide limit (0.40)", bloom.Intensity))
		end
		if bloom.Threshold < 1.0 then
			table.insert(errors, string.format("BloomEffect threshold %.2f too low; must be >= 1.0 to avoid washing out clay", bloom.Threshold))
		end
	end

	return (#errors == 0), errors
end

return LightingConfig
