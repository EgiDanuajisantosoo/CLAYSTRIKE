--!strict
--[[
	AircraftFactory.luau
	Authoritative procedural placeholder aircraft builder for CLAYSTRIKE.
	Task: CLAY-003 (Create Placeholder Aircraft Model Factory)

	Constructs a structured Model containing PrimaryPart, fuselage, wings, tail,
	attachments (Muzzle, Exhaust), and stable attributes needed for camera targeting,
	combat origin deriving, and authoritative movement.
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

-- Default placeholder aesthetic palette (Terracotta claymation style)
local DEFAULT_BODY_COLOR = Color3.fromRGB(194, 88, 58)
local DEFAULT_ACCENT_COLOR = Color3.fromRGB(140, 52, 32)
local DEFAULT_SPAWN_POSITION = Vector3.new(-50, 0, GameConfig.Arena.PlayPlaneZ)

--[[
	Creates a part welded to rootPart using WeldConstraint.
]]
local function createWeldPart(
	name: string,
	size: Vector3,
	relativeOffset: CFrame,
	color: Color3,
	rootPart: BasePart,
	parentModel: Model
): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = true
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
	Constructs a placeholder aircraft Model for a player.
	@param userId The numeric UserId of the owning player.
	@param initialPosition Optional spawn position (defaults to arena entry point at Z = 0).
	@param customConfig Optional configuration overrides.
	@return A fully assembled Model with PrimaryPart, attachments, and metadata attributes.
]]
function AircraftFactory.CreatePlaceholderPlane(
	userId: number,
	initialPosition: Vector3?,
	customConfig: AircraftConfig?
): Model
	assert(typeof(userId) == "number", "AircraftFactory: userId must be a number.")

	local config = customConfig or {}
	local bodyColor = config.color or DEFAULT_BODY_COLOR
	local accentColor = config.accentColor or DEFAULT_ACCENT_COLOR
	local spawnPos = initialPosition or DEFAULT_SPAWN_POSITION

	-- Enforce 2.5D PlayPlaneZ coordinate
	local planePos = Vector3.new(spawnPos.X, spawnPos.Y, GameConfig.Arena.PlayPlaneZ)

	local model = Instance.new("Model")
	model.Name = string.format("Plane_%d", userId)

	-- 1. Fuselage (PrimaryPart / RootPart)
	-- Facing +X (forward in side-scroller), up is +Y
	local rootPart = Instance.new("Part")
	rootPart.Name = "RootPart"
	rootPart.Size = Vector3.new(4.0, 1.2, 1.2)
	rootPart.Color = bodyColor
	rootPart.Material = Enum.Material.SmoothPlastic
	rootPart.TopSurface = Enum.SurfaceType.Smooth
	rootPart.BottomSurface = Enum.SurfaceType.Smooth
	rootPart.CanCollide = false
	rootPart.CanTouch = false
	rootPart.CanQuery = true
	rootPart.CastShadow = true
	rootPart.Anchored = true
	rootPart.CFrame = CFrame.lookAt(planePos, planePos + Vector3.new(1, 0, 0), Vector3.new(0, 1, 0))
	rootPart.Parent = model

	model.PrimaryPart = rootPart

	-- 2. Main Wings (spread along Z axis)
	createWeldPart(
		"Wings",
		Vector3.new(1.6, 0.2, 5.0),
		CFrame.new(0.2, 0, 0),
		accentColor,
		rootPart,
		model
	)

	-- 3. Vertical Tail Fin (top back)
	createWeldPart(
		"TailFin",
		Vector3.new(1.0, 1.4, 0.2),
		CFrame.new(-1.4, 0.8, 0),
		accentColor,
		rootPart,
		model
	)

	-- 4. Horizontal Tail Wings (stabilizers)
	createWeldPart(
		"TailWing",
		Vector3.new(0.8, 0.15, 2.0),
		CFrame.new(-1.5, 0.1, 0),
		accentColor,
		rootPart,
		model
	)

	-- 5. Cockpit Canopy Placeholder
	createWeldPart(
		"Cockpit",
		Vector3.new(1.4, 0.5, 0.8),
		CFrame.new(0.6, 0.65, 0),
		Color3.fromRGB(220, 230, 242),
		rootPart,
		model
	)

	-- 6. Attachments
	-- Muzzle: Projectile firing origin at nose (+X)
	local muzzleAttachment = Instance.new("Attachment")
	muzzleAttachment.Name = "Muzzle"
	muzzleAttachment.CFrame = CFrame.new(2.1, 0, 0)
	muzzleAttachment.Parent = rootPart

	-- Exhaust: Engine trail / puff emitter origin at tail (-X)
	local exhaustAttachment = Instance.new("Attachment")
	exhaustAttachment.Name = "Exhaust"
	exhaustAttachment.CFrame = CFrame.new(-2.1, 0, 0)
	exhaustAttachment.Parent = rootPart

	-- 7. Stable Model Attributes
	local maxHealth = config.maxHealth or 100
	local health = config.health or maxHealth
	local aircraftType = config.aircraftType or "StandardFighter"

	model:SetAttribute("OwnerUserId", userId)
	model:SetAttribute("AircraftType", aircraftType)
	model:SetAttribute("Health", health)
	model:SetAttribute("MaxHealth", maxHealth)
	model:SetAttribute("Invulnerable", false)
	model:SetAttribute("InvulnerableUntil", 0)
	model:SetAttribute("State", "Active")

	return model
end

return AircraftFactory
