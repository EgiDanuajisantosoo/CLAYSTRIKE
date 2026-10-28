--!strict
--[[
	VFXConfig.luau
	Authoritative weapon VFX presets, projectile trails, muzzle flashes, and impact bursts.
	Task: CLAY-030 (Projectile Trail & Muzzle VFX)

	Adheres strictly to StyleGuide VFX constraints:
	- MaxMuzzleFlashDuration = 0.08s
	- MaxImpactSparksDuration = 0.25s
	- MaxTrailLengthStuds = 8.0 studs
	- Separates gameplay collision hitboxes from visual cosmetic trails.
	- 4-player co-op readability with high color contrast.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local StyleGuide = require(SharedFolder:WaitForChild("StyleGuide"))

export type TrailPreset = {
	color: ColorSequence,
	transparency: NumberSequence,
	lifetime: number,
	widthScale: NumberSequence,
	lightEmission: number,
	lightInfluence: number,
}

export type MuzzlePreset = {
	duration: number,
	color: Color3,
	radius: number,
	lightBrightness: number,
	lightRange: number,
	isFanSpread: boolean,
}

export type ImpactPreset = {
	duration: number,
	color: Color3,
	particleCount: number,
	speed: number,
	lifetime: number,
}

local VFXConfig = {}

-- Canonical Trail Presets per Weapon / Faction
VFXConfig.Trails = {
	StandardPeaShooter = {
		color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, StyleGuide.Colors.PlayerStandardBullet),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(235, 140, 30)),
		}),
		transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(0.7, 0.45),
			NumberSequenceKeypoint.new(1, 1.0),
		}),
		lifetime = 0.05, -- At speed 140, length is ~7.0 studs (<= 8.0 MaxTrailLengthStuds)
		widthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.0),
			NumberSequenceKeypoint.new(1, 0.0),
		}),
		lightEmission = 0.85,
		lightInfluence = 0.1,
	} :: TrailPreset,

	SpreadShot = {
		color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, StyleGuide.Colors.PlayerSpreadBullet),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 110, 220)),
		}),
		transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(0.65, 0.4),
			NumberSequenceKeypoint.new(1, 1.0),
		}),
		lifetime = 0.05, -- At speed 125, length is ~6.25 studs (<= 8.0 MaxTrailLengthStuds)
		widthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.85),
			NumberSequenceKeypoint.new(1, 0.0),
		}),
		lightEmission = 0.90,
		lightInfluence = 0.1,
	} :: TrailPreset,

	TurretEnemyBullet = {
		color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, StyleGuide.Colors.EnemyBullet),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(180, 30, 45)),
		}),
		transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(0.8, 0.5),
			NumberSequenceKeypoint.new(1, 1.0),
		}),
		lifetime = 0.15, -- At speed 28, length is ~4.2 studs (<= 8.0 MaxTrailLengthStuds)
		widthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.2),
			NumberSequenceKeypoint.new(1, 0.0),
		}),
		lightEmission = 0.80,
		lightInfluence = 0.15,
	} :: TrailPreset,
}

-- Canonical Muzzle Flash Presets
VFXConfig.Muzzles = {
	StandardPeaShooter = {
		duration = 0.06, -- Strictly <= 0.08s
		color = StyleGuide.Colors.PlayerStandardBullet,
		radius = 0.9,
		lightBrightness = 2.5,
		lightRange = 9,
		isFanSpread = false,
	} :: MuzzlePreset,

	SpreadShot = {
		duration = 0.06, -- Strictly <= 0.08s
		color = StyleGuide.Colors.PlayerSpreadBullet,
		radius = 1.3,
		lightBrightness = 3.2,
		lightRange = 13,
		isFanSpread = true,
	} :: MuzzlePreset,

	TurretEnemyBullet = {
		duration = 0.07, -- Strictly <= 0.08s
		color = StyleGuide.Colors.EnemyBullet,
		radius = 1.4,
		lightBrightness = 3.0,
		lightRange = 12,
		isFanSpread = false,
	} :: MuzzlePreset,
}

-- Canonical Impact Presets
VFXConfig.Impacts = {
	StandardPeaShooter = {
		duration = 0.20, -- Strictly <= 0.25s
		color = StyleGuide.Colors.PlayerStandardBullet,
		particleCount = 5,
		speed = 12,
		lifetime = 0.18,
	} :: ImpactPreset,

	SpreadShot = {
		duration = 0.18, -- Strictly <= 0.25s
		color = StyleGuide.Colors.PlayerSpreadBullet,
		particleCount = 4,
		speed = 14,
		lifetime = 0.16,
	} :: ImpactPreset,

	TurretEnemyBullet = {
		duration = 0.22, -- Strictly <= 0.25s
		color = StyleGuide.Colors.EnemyBullet,
		particleCount = 6,
		speed = 10,
		lifetime = 0.20,
	} :: ImpactPreset,
}

--[[
	Applies a cosmetic Trail to an authoritative projectile BasePart.
	Creates TrailAttachment0 and TrailAttachment1 and hooks a Trail object.
	Gameplay raycasts and hit detection ignore these completely.
]]
function VFXConfig.ApplyProjectileTrail(projectilePart: BasePart, weaponId: string, faction: string?): Trail?
	local presetKey = weaponId
	if faction == "Enemy" or weaponId == "TurretShooter" or weaponId == "EnemyTurret" then
		presetKey = "TurretEnemyBullet"
	end

	local preset = VFXConfig.Trails[presetKey] or VFXConfig.Trails["StandardPeaShooter"]
	if not preset then
		return nil
	end

	local halfY = projectilePart.Size.Y * 0.45

	local att0 = projectilePart:FindFirstChild("TrailAttachment0") :: Attachment?
	if not att0 then
		att0 = Instance.new("Attachment")
		att0.Name = "TrailAttachment0"
		att0.Position = Vector3.new(0, halfY, 0)
		att0.Parent = projectilePart
	end

	local att1 = projectilePart:FindFirstChild("TrailAttachment1") :: Attachment?
	if not att1 then
		att1 = Instance.new("Attachment")
		att1.Name = "TrailAttachment1"
		att1.Position = Vector3.new(0, -halfY, 0)
		att1.Parent = projectilePart
	end

	local trail = projectilePart:FindFirstChild("BulletTrail") :: Trail?
	if not trail then
		trail = Instance.new("Trail")
		trail.Name = "BulletTrail"
		trail.Attachment0 = att0
		trail.Attachment1 = att1
		trail.Parent = projectilePart
	end

	trail.Color = preset.color
	trail.Transparency = preset.transparency
	trail.Lifetime = preset.lifetime
	trail.WidthScale = preset.widthScale
	trail.LightEmission = preset.lightEmission
	trail.LightInfluence = preset.lightInfluence
	trail.FaceCamera = true
	trail.Enabled = true

	return trail
end

--[[
	Spawns a local cosmetic muzzle flash that auto-destroys within bounded duration.
]]
function VFXConfig.CreateMuzzleFlash(origin: Vector3, weaponId: string, parentContainer: Instance?): Part
	local preset = VFXConfig.Muzzles[weaponId] or VFXConfig.Muzzles["StandardPeaShooter"]
	local parent = parentContainer or Workspace

	local flash = Instance.new("Part")
	flash.Name = "MuzzleFlash_" .. weaponId
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(preset.radius, preset.radius, preset.radius)
	flash.Position = origin
	flash.Material = Enum.Material.Neon
	flash.Color = preset.color
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanTouch = false
	flash.CanQuery = false
	flash.CastShadow = false

	local light = Instance.new("PointLight")
	light.Color = preset.color
	light.Brightness = preset.lightBrightness
	light.Range = preset.lightRange
	light.Shadows = false
	light.Parent = flash

	flash.Parent = parent

	-- Fan spark burst for spread weapons
	if preset.isFanSpread then
		for _, angleDeg in ipairs({ -15, 15 }) do
			local rad = math.rad(angleDeg)
			local spark = Instance.new("Part")
			spark.Name = "SpreadFlankSpark"
			spark.Shape = Enum.PartType.Ball
			spark.Size = Vector3.new(0.4, 0.4, 0.4)
			spark.Material = Enum.Material.Neon
			spark.Color = preset.color
			spark.Position = origin + Vector3.new(math.cos(rad) * 0.9, math.sin(rad) * 0.9, 0)
			spark.Anchored = true
			spark.CanCollide = false
			spark.CanTouch = false
			spark.CanQuery = false
			spark.Parent = flash
		end
	end

	-- Bounded auto-cleanup
	task.delay(preset.duration, function()
		if flash.Parent then
			flash:Destroy()
		end
	end)

	return flash
end

--[[
	Spawns a local cosmetic impact micro-burst on bullet collision.
]]
function VFXConfig.CreateImpactEffect(position: Vector3, normal: Vector3, weaponId: string, parentContainer: Instance?): Part
	local preset = VFXConfig.Impacts[weaponId] or VFXConfig.Impacts["StandardPeaShooter"]
	local parent = parentContainer or Workspace

	local impactPart = Instance.new("Part")
	impactPart.Name = "ImpactBurst_" .. weaponId
	impactPart.Shape = Enum.PartType.Ball
	impactPart.Size = Vector3.new(0.6, 0.6, 0.6)
	impactPart.Position = position
	impactPart.Material = Enum.Material.Neon
	impactPart.Color = preset.color
	impactPart.Anchored = true
	impactPart.CanCollide = false
	impactPart.CanTouch = false
	impactPart.CanQuery = false
	impactPart.CastShadow = false

	-- Impact sparks emitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "ImpactSparks"
	emitter.Rate = 0 -- Burst emission only
	emitter.Lifetime = NumberRange.new(preset.lifetime * 0.7, preset.lifetime)
	emitter.Speed = NumberRange.new(preset.speed * 0.6, preset.speed)
	emitter.SpreadAngle = Vector2.new(45, 45)
	emitter.Color = ColorSequence.new(preset.color)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0.05),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1.0),
	})
	emitter.LightEmission = 0.9
	emitter.Parent = impactPart
	impactPart.Parent = parent

	emitter:Emit(preset.particleCount)

	task.delay(preset.duration, function()
		if impactPart.Parent then
			impactPart:Destroy()
		end
	end)

	return impactPart
end

--[[
	Validates that a Trail or ParticleEmitter conforms to StyleGuide constraints.
]]
function VFXConfig.ValidateVFX(instance: Instance): (boolean, string?)
	if instance:IsA("Trail") then
		local lifetime = instance.Lifetime
		-- Maximum projectile speed is 140 studs/s; trail length = speed * lifetime
		local estimatedLength = 140 * lifetime
		if estimatedLength > StyleGuide.VFX.MaxTrailLengthStuds + 0.5 then
			return false, string.format("Trail estimated length %.2f exceeds StyleGuide max %.2f studs", estimatedLength, StyleGuide.VFX.MaxTrailLengthStuds)
		end
	elseif instance:IsA("ParticleEmitter") then
		local maxLifetime = instance.Lifetime.Max
		if maxLifetime > StyleGuide.VFX.MaxExplosionBurstDuration then
			return false, string.format("ParticleEmitter lifetime %.2fs exceeds max duration %.2fs", maxLifetime, StyleGuide.VFX.MaxExplosionBurstDuration)
		end
	end
	return true, nil
end

return VFXConfig
