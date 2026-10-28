--!strict
--[[
	AircraftFactory.luau
	Authoritative clay-inspired player aircraft builder for CLAYSTRIKE.
	Task: CLAY-003, CLAY-027 (Create Original Player Aircraft Model)

	Constructs a distinctive, optimized clay-inspired aircraft model:
	- Readable silhouette with sculpted clay fuselage, rounded nosecone, and gull-wings.
	- Facing forward along +X with clean pivot orientation.
	- Built-in animation hooks: Muzzle (+X nose), Exhaust (-X tail) with particle emitter, and Center.
	- Collision proxy simplified: RootPart is the only collision query part; visual render geometry is non-colliding.
	- Part budget: 8 parts (ultra lightweight, 0 mesh lag, highly scalable for 1-4 player co-op).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))

local AircraftFactory = {}

export type AircraftConfig = {
	aircraftType: string?,
	health: number?,
	maxHealth: number?,
	color: Color3?,
	accentColor: Color3?,
}

-- Authentic Claymation Color Palette (Warm Terracotta & Baked Ochre)
local DEFAULT_BODY_COLOR = Color3.fromRGB(210, 88, 52) -- Terracotta Clay Orange
local DEFAULT_ACCENT_COLOR = Color3.fromRGB(145, 52, 30) -- Dark Baked Ochre
local COCKPIT_ENAMEL_COLOR = Color3.fromRGB(225, 238, 252) -- Baked Glazed White/Cyan Enamel
local DEFAULT_SPAWN_POSITION = Vector3.new(-50, 0, GameConfig.Arena.PlayPlaneZ)

--[[
	Creates a stylized clay part welded to rootPart using WeldConstraint.
	All decorative visual parts have CanCollide=false and CanTouch=false to keep physics ultra-cheap.
]]
local function createWeldPart(
	name: string,
	size: Vector3,
	relativeOffset: CFrame,
	color: Color3,
	shape: Enum.PartType?,
	rootPart: BasePart,
	parentModel: Model
): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	if shape then
		part.Shape = shape
	end
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = true
	part.Anchored = true
	part.CFrame = rootPart.CFrame * relativeOffset
	part.Parent = parentModel

	local weld = Instance.new("WeldConstraint")
	weld.Name = name .. "Weld"
	weld.Part0 = rootPart
	weld.Part1 = part
	weld.Parent = rootPart

	return part
end

--[[
	Constructs the original production clay-inspired aircraft Model for a player.
	@param userId The numeric UserId of the owning player.
	@param initialPosition Optional spawn position (defaults to arena entry point at Z = 0).
	@param customConfig Optional configuration overrides.
	@return A fully assembled Model with PrimaryPart, attachments, and metadata attributes.
]]
function AircraftFactory.CreatePlayerAircraft(
	userId: number,
	initialPosition: Vector3?,
	customConfig: AircraftConfig?
): Model
	assert(typeof(userId) == "number", "AircraftFactory: userId must be a number.")

	local config = customConfig or {}
	local bodyColor = config.color or DEFAULT_BODY_COLOR
	local accentColor = config.accentColor or DEFAULT_ACCENT_COLOR
	local spawnPos = initialPosition or DEFAULT_SPAWN_POSITION

	-- Enforce 2.5D PlayPlaneZ coordinate strictly
	local planePos = Vector3.new(spawnPos.X, spawnPos.Y, GameConfig.Arena.PlayPlaneZ)

	local model = Instance.new("Model")
	model.Name = string.format("Plane_%d", userId)

	-- 1. Fuselage (PrimaryPart / RootPart) - Collision & Authority Proxy
	-- Oriented facing forward along +X in 2.5D side-scroller view, up is +Y
	local rootPart = Instance.new("Part")
	rootPart.Name = "RootPart"
	rootPart.Size = Vector3.new(4.2, 1.2, 1.2)
	rootPart.Color = bodyColor
	rootPart.Material = Enum.Material.SmoothPlastic
	rootPart.TopSurface = Enum.SurfaceType.Smooth
	rootPart.BottomSurface = Enum.SurfaceType.Smooth
	rootPart.CanCollide = false
	rootPart.CanTouch = false
	rootPart.CanQuery = true -- Permitted for sweeps and hit detection
	rootPart.CastShadow = true
	rootPart.Anchored = true
	rootPart.CFrame = CFrame.lookAt(planePos, planePos + Vector3.new(1, 0, 0), Vector3.new(0, 1, 0))
	rootPart.Parent = model

	model.PrimaryPart = rootPart

	-- 2. Sculpted Clay Nosecone (Rounded aerodynamic dome facing +X)
	createWeldPart(
		"Nosecone",
		Vector3.new(1.3, 1.2, 1.2),
		CFrame.new(2.1, 0, 0),
		accentColor,
		Enum.PartType.Ball,
		rootPart,
		model
	)

	-- 3. Glazed Clay Canopy (Cockpit enclosure)
	createWeldPart(
		"CockpitCanopy",
		Vector3.new(1.5, 0.65, 0.85),
		CFrame.new(0.5, 0.65, 0),
		COCKPIT_ENAMEL_COLOR,
		Enum.PartType.Block,
		rootPart,
		model
	)

	-- 4. Main Gull-Wings (Wide profile along Z axis for distinctive 2.5D silhouette)
	createWeldPart(
		"MainWings",
		Vector3.new(1.8, 0.25, 5.4),
		CFrame.new(0.2, -0.05, 0),
		bodyColor,
		Enum.PartType.Block,
		rootPart,
		model
	)

	-- 5. Left Wingtip Clay Thumb-Cap
	createWeldPart(
		"LeftWingtip",
		Vector3.new(0.4, 0.35, 0.35),
		CFrame.new(0.2, 0.05, 2.7) * CFrame.Angles(0, 0, math.rad(90)),
		accentColor,
		Enum.PartType.Cylinder,
		rootPart,
		model
	)

	-- 6. Right Wingtip Clay Thumb-Cap
	createWeldPart(
		"RightWingtip",
		Vector3.new(0.4, 0.35, 0.35),
		CFrame.new(0.2, 0.05, -2.7) * CFrame.Angles(0, 0, math.rad(90)),
		accentColor,
		Enum.PartType.Cylinder,
		rootPart,
		model
	)

	-- 7. Vertical Sculpted Clay Rudder / Tailfin
	createWeldPart(
		"TailFin",
		Vector3.new(1.2, 1.5, 0.25),
		CFrame.new(-1.5, 0.85, 0),
		accentColor,
		Enum.PartType.Block,
		rootPart,
		model
	)

	-- 8. Horizontal Tail Stabilizers
	createWeldPart(
		"TailStabilizer",
		Vector3.new(0.9, 0.2, 2.2),
		CFrame.new(-1.6, 0.15, 0),
		accentColor,
		Enum.PartType.Block,
		rootPart,
		model
	)

	-- 9. Engine Exhaust Cowling Ring
	createWeldPart(
		"EngineCowling",
		Vector3.new(0.4, 1.0, 1.0),
		CFrame.new(-2.1, 0, 0) * CFrame.Angles(0, 0, math.rad(90)),
		accentColor,
		Enum.PartType.Cylinder,
		rootPart,
		model
	)

	-- 10. Animation & Combat Attachments
	-- Muzzle: Projectile firing origin at forward nose tip (+X)
	local muzzleAttachment = Instance.new("Attachment")
	muzzleAttachment.Name = "Muzzle"
	muzzleAttachment.CFrame = CFrame.new(2.5, 0, 0)
	muzzleAttachment.Parent = rootPart

	-- Exhaust: Engine trail / puff emitter origin at tail (-X)
	local exhaustAttachment = Instance.new("Attachment")
	exhaustAttachment.Name = "Exhaust"
	exhaustAttachment.CFrame = CFrame.new(-2.3, 0, 0)
	exhaustAttachment.Parent = rootPart

	-- Center: Model centroid pivot
	local centerAttachment = Instance.new("Attachment")
	centerAttachment.Name = "Center"
	centerAttachment.CFrame = CFrame.new(0, 0, 0)
	centerAttachment.Parent = rootPart

	-- Gentle clay engine puff emitter
	local exhaustPuff = Instance.new("ParticleEmitter")
	exhaustPuff.Name = "EngineExhaust"
	exhaustPuff.Rate = 10
	exhaustPuff.Lifetime = NumberRange.new(0.2, 0.35)
	exhaustPuff.Speed = NumberRange.new(4, 7)
	exhaustPuff.EmissionDirection = Enum.NormalId.Left -- Emits backward along -X
	exhaustPuff.SpreadAngle = Vector2.new(10, 10)
	exhaustPuff.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.5, 0.6),
		NumberSequenceKeypoint.new(1, 0.1),
	})
	exhaustPuff.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.7, 0.5),
		NumberSequenceKeypoint.new(1, 1.0),
	})
	exhaustPuff.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 210, 140)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 190, 180)),
	})
	exhaustPuff.Enabled = true
	exhaustPuff.Parent = exhaustAttachment

	-- 11. Stable Model Attributes
	local maxHealth = config.maxHealth or 100
	local health = config.health or maxHealth
	local aircraftType = config.aircraftType or "ClayFalcon"

	model:SetAttribute("OwnerUserId", userId)
	model:SetAttribute("AircraftType", aircraftType)
	model:SetAttribute("Health", health)
	model:SetAttribute("MaxHealth", maxHealth)
	model:SetAttribute("Invulnerable", false)
	model:SetAttribute("InvulnerableUntil", 0)
	model:SetAttribute("State", "Active")
	model:SetAttribute("BankTilt", 0)

	return model
end

--[[
	Backward-compatible factory alias for placeholder plane creation.
]]
function AircraftFactory.CreatePlaceholderPlane(
	userId: number,
	initialPosition: Vector3?,
	customConfig: AircraftConfig?
): Model
	return AircraftFactory.CreatePlayerAircraft(userId, initialPosition, customConfig)
end

return AircraftFactory
