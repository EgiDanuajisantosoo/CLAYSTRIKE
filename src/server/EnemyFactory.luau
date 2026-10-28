--!strict
--[[
	EnemyFactory.luau
	Authoritative server model factory for enemy archetypes in CLAYSTRIKE.
	Task: CLAY-016 (Enemy Spawn Factory & Cleanup), CLAY-028 (Three Original Enemy Models)

	Constructs distinctive, production-grade clay-inspired enemy models conforming to the StyleGuide:
	1. StraightFlyer ("Clay Drone"):
	   - Warm mustard clay dart drone with sculpted nose, delta glider wings, wingtip beads, tailfin, thruster rim.
	2. Pursuer ("Clay Interceptor"):
	   - Terracotta predatory wedge with aggressive faceted snout, forward-swept wings, twin thruster pods, dorsal fin.
	3. TurretShooter ("Clay Gunship"):
	   - Heavy sage olive armored dome with reinforced skirt, heavy cannon barrel, MuzzleAttachment, TelegraphLight,
	     twin side stabilizer pods, and glazed amber sensor bead.

	All models adhere to strict performance and physics contracts:
	- PrimaryPart is centered and named "HitProxy".
	- HitProxy: CanCollide = false, CanTouch = false, CanQuery = true (for swept raycasts & hit validation).
	- All visual parts: CanCollide = false, CanTouch = false, CanQuery = false, CastShadow = true.
	- Rigidly attached via WeldConstraint to HitProxy.
	- Part budget: 6–8 parts per model (strictly <= 10 parts, zero lag in multiplayer swarms).
	- Direction: Facing -X (flying left towards player aircraft).
]]

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
if (EnemyConfig :: any).Archetypes == nil then
	EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"):Clone())
end

local EnemyFactory = {}

-- Helper to retrieve or create ServerStorage.EnemyTemplates folder
local function getTemplatesFolder(autoCreate: boolean?): Folder?
	local folder = ServerStorage:FindFirstChild("EnemyTemplates")
	if folder and folder:IsA("Folder") then
		return folder
	end
	if autoCreate then
		local newFolder = Instance.new("Folder")
		newFolder.Name = "EnemyTemplates"
		newFolder.Parent = ServerStorage
		return newFolder
	end
	return nil
end

-- Helper to construct a stylized clay part welded to rootPart
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
	Constructs the rich production clay StraightFlyer ("Clay Drone") model.
	Warm Mustard Clay dart drone with rounded nose, delta wings, wingtip caps, and tail fin.
]]
local function buildStraightFlyerModel(def: EnemyConfig.EnemyDefinition): Model
	local model = Instance.new("Model")
	model.Name = string.format("Placeholder_%s", def.id)

	local proxy = Instance.new("Part")
	proxy.Name = "HitProxy"
	proxy.Size = def.collisionSize
	proxy.Position = Vector3.zero
	proxy.Material = Enum.Material.SmoothPlastic
	proxy.Color = def.clayColor
	proxy.Anchored = true
	proxy.CanCollide = false
	proxy.CanTouch = false
	proxy.CanQuery = true
	proxy.CastShadow = true
	proxy.Parent = model
	model.PrimaryPart = proxy

	local accentColor = Color3.fromRGB(160, 110, 25) -- Dark baked mustard
	local beadColor = Color3.fromRGB(60, 50, 45) -- Dark earthy clay bead

	-- 1. Sculpted clay nosecone pointing forward (-X)
	createWeldPart(
		"VisualNose",
		Vector3.new(1.1, 1.0, 1.0),
		CFrame.new(-def.collisionSize.X * 0.45, 0, 0),
		accentColor,
		Enum.PartType.Ball,
		proxy,
		model
	)

	-- 2. Wide delta glider wings along Z
	createWeldPart(
		"VisualWings",
		Vector3.new(1.4, 0.22, 4.4),
		CFrame.new(0.1, 0, 0),
		def.clayColor,
		Enum.PartType.Block,
		proxy,
		model
	)

	-- 3. Left wingtip clay bead
	createWeldPart(
		"LeftWingtipBead",
		Vector3.new(0.35, 0.35, 0.35),
		CFrame.new(0.1, 0.05, 2.2),
		beadColor,
		Enum.PartType.Ball,
		proxy,
		model
	)

	-- 4. Right wingtip clay bead
	createWeldPart(
		"RightWingtipBead",
		Vector3.new(0.35, 0.35, 0.35),
		CFrame.new(0.1, 0.05, -2.2),
		beadColor,
		Enum.PartType.Ball,
		proxy,
		model
	)

	-- 5. Vertical tail fin (+Y)
	createWeldPart(
		"TailFin",
		Vector3.new(0.8, 1.1, 0.2),
		CFrame.new(def.collisionSize.X * 0.4, 0.7, 0),
		accentColor,
		Enum.PartType.Block,
		proxy,
		model
	)

	-- 6. Rear thruster exhaust rim (+X)
	createWeldPart(
		"VisualExhaust",
		Vector3.new(0.35, 0.8, 0.8),
		CFrame.new(def.collisionSize.X * 0.45, 0, 0) * CFrame.Angles(0, 0, math.rad(90)),
		beadColor,
		Enum.PartType.Cylinder,
		proxy,
		model
	)

	-- Center Attachment
	local center = Instance.new("Attachment")
	center.Name = "Center"
	center.CFrame = CFrame.new(0, 0, 0)
	center.Parent = proxy

	return model
end

--[[
	Constructs the rich production clay Pursuer ("Clay Interceptor") model.
	Terracotta predatory wedge with faceted aggressive snout, swept wings, dual thrusters, and dorsal crest.
]]
local function buildPursuerModel(def: EnemyConfig.EnemyDefinition): Model
	local model = Instance.new("Model")
	model.Name = string.format("Placeholder_%s", def.id)

	local proxy = Instance.new("Part")
	proxy.Name = "HitProxy"
	proxy.Size = def.collisionSize
	proxy.Position = Vector3.zero
	proxy.Material = Enum.Material.SmoothPlastic
	proxy.Color = def.clayColor
	proxy.Anchored = true
	proxy.CanCollide = false
	proxy.CanTouch = false
	proxy.CanQuery = true
	proxy.CastShadow = true
	proxy.Parent = model
	model.PrimaryPart = proxy

	local accentColor = Color3.fromRGB(130, 40, 25) -- Deep terracotta ochre
	local thrusterColor = Color3.fromRGB(65, 30, 25) -- Dark baked clay

	-- 1. Aggressive predatory snout pointing forward (-X)
	createWeldPart(
		"VisualNose",
		Vector3.new(1.3, 0.9, 0.9),
		CFrame.new(-def.collisionSize.X * 0.48, -0.05, 0),
		accentColor,
		Enum.PartType.Ball,
		proxy,
		model
	)

	-- 2. Swept interceptor wings along Z
	createWeldPart(
		"VisualWings",
		Vector3.new(1.7, 0.25, 4.8),
		CFrame.new(0.1, -0.05, 0),
		def.clayColor,
		Enum.PartType.Block,
		proxy,
		model
	)

	-- 3. Left booster thruster pod (+Z)
	createWeldPart(
		"LeftThrusterPod",
		Vector3.new(1.2, 0.6, 0.6),
		CFrame.new(def.collisionSize.X * 0.25, 0.1, 1.3),
		thrusterColor,
		Enum.PartType.Block,
		proxy,
		model
	)

	-- 4. Right booster thruster pod (-Z)
	createWeldPart(
		"RightThrusterPod",
		Vector3.new(1.2, 0.6, 0.6),
		CFrame.new(def.collisionSize.X * 0.25, 0.1, -1.3),
		thrusterColor,
		Enum.PartType.Block,
		proxy,
		model
	)

	-- 5. Dorsal predatory shark fin (+Y)
	createWeldPart(
		"DorsalFin",
		Vector3.new(1.1, 1.2, 0.22),
		CFrame.new(-0.2, 0.9, 0),
		accentColor,
		Enum.PartType.Block,
		proxy,
		model
	)

	-- 6. Ventral intake keel (-Y)
	createWeldPart(
		"VentralKeel",
		Vector3.new(1.4, 0.4, 0.4),
		CFrame.new(-0.1, -0.7, 0),
		accentColor,
		Enum.PartType.Block,
		proxy,
		model
	)

	-- Center Attachment
	local center = Instance.new("Attachment")
	center.Name = "Center"
	center.CFrame = CFrame.new(0, 0, 0)
	center.Parent = proxy

	return model
end

--[[
	Constructs the rich production clay TurretShooter ("Clay Gunship") model.
	Heavy Sage Olive armored dome with reinforced skirt, heavy cannon barrel, MuzzleAttachment,
	TelegraphLight, and dual stabilizer armor outriggers.
]]
local function buildTurretShooterModel(def: EnemyConfig.EnemyDefinition): Model
	local model = Instance.new("Model")
	model.Name = string.format("Placeholder_%s", def.id)

	local proxy = Instance.new("Part")
	proxy.Name = "HitProxy"
	proxy.Size = def.collisionSize
	proxy.Position = Vector3.zero
	proxy.Material = Enum.Material.SmoothPlastic
	proxy.Color = def.clayColor
	proxy.Anchored = true
	proxy.CanCollide = false
	proxy.CanTouch = false
	proxy.CanQuery = true
	proxy.CastShadow = true
	proxy.Parent = model
	model.PrimaryPart = proxy

	local armoredColor = Color3.fromRGB(45, 65, 40) -- Dark forest slate
	local cannonColor = Color3.fromRGB(35, 45, 35) -- Heavy obsidian clay
	local amberColor = Color3.fromRGB(230, 150, 40) -- Glazed amber sensor bead

	-- 1. Forward rounded nosecone / visor (-X)
	createWeldPart(
		"VisualNose",
		Vector3.new(1.2, 1.4, 1.4),
		CFrame.new(-def.collisionSize.X * 0.42, 0, 0),
		armoredColor,
		Enum.PartType.Ball,
		proxy,
		model
	)

	-- 2. Heavy armored upper dome
	createWeldPart(
		"ArmoredDome",
		Vector3.new(2.8, 1.6, 2.8),
		CFrame.new(0, 0.7, 0),
		def.clayColor,
		Enum.PartType.Block,
		proxy,
		model
	)

	-- 3. Base armored skirt ring
	createWeldPart(
		"BaseSkirt",
		Vector3.new(3.6, 0.4, 3.6),
		CFrame.new(0, -0.8, 0),
		armoredColor,
		Enum.PartType.Block,
		proxy,
		model
	)

	-- 4. Left stabilizer outrigger pod (+Z)
	createWeldPart(
		"LeftOutrigger",
		Vector3.new(2.0, 0.8, 0.9),
		CFrame.new(0, -0.2, 1.8),
		def.clayColor,
		Enum.PartType.Block,
		proxy,
		model
	)

	-- 5. Right stabilizer outrigger pod (-Z)
	createWeldPart(
		"RightOutrigger",
		Vector3.new(2.0, 0.8, 0.9),
		CFrame.new(0, -0.2, -1.8),
		def.clayColor,
		Enum.PartType.Block,
		proxy,
		model
	)

	-- 6. Top glazed amber sensor bead
	createWeldPart(
		"SensorBead",
		Vector3.new(0.65, 0.65, 0.65),
		CFrame.new(-0.2, 1.65, 0),
		amberColor,
		Enum.PartType.Ball,
		proxy,
		model
	)

	-- 7. Heavy cannon turret barrel pointing forward (-X)
	local cannon = createWeldPart(
		"VisualTurret",
		Vector3.new(def.collisionSize.X * 0.45, def.collisionSize.Y * 0.25, def.collisionSize.Z * 0.25),
		CFrame.new(-def.collisionSize.X * 0.55, 0, 0),
		cannonColor,
		Enum.PartType.Block,
		proxy,
		model
	)

	-- MuzzleAttachment on cannon barrel tip (-X)
	local muzzle = Instance.new("Attachment")
	muzzle.Name = "MuzzleAttachment"
	muzzle.Position = Vector3.new(-cannon.Size.X * 0.5, 0, 0)
	muzzle.Parent = cannon

	-- Telegraph warning light inside cannon
	local telegraphLight = Instance.new("PointLight")
	telegraphLight.Name = "TelegraphLight"
	telegraphLight.Color = Color3.fromRGB(255, 60, 40)
	telegraphLight.Range = 14
	telegraphLight.Brightness = 2.5
	telegraphLight.Enabled = false
	telegraphLight.Parent = cannon

	-- Reactive telegraph attribute listener
	model:GetAttributeChangedSignal("IsTelegraphing"):Connect(function()
		local isTele = model:GetAttribute("IsTelegraphing") == true
		telegraphLight.Enabled = isTele
	end)

	-- Center Attachment
	local center = Instance.new("Attachment")
	center.Name = "Center"
	center.CFrame = CFrame.new(0, 0, 0)
	center.Parent = proxy

	return model
end

--[[
	Creates a placeholder/production model for an enemy archetype matching the exact contract.
]]
function EnemyFactory.CreateProceduralPlaceholder(def: EnemyConfig.EnemyDefinition): Model
	if def.id == EnemyConfig.Archetypes.StraightFlyer then
		return buildStraightFlyerModel(def)
	elseif def.id == EnemyConfig.Archetypes.Pursuer then
		return buildPursuerModel(def)
	elseif def.id == EnemyConfig.Archetypes.TurretShooter then
		return buildTurretShooterModel(def)
	else
		-- Generic fallback
		return buildStraightFlyerModel(def)
	end
end

--[[
	Initializes ServerStorage.EnemyTemplates folder with pre-built production templates.
]]
function EnemyFactory.InitializeTemplates(): Folder
	local folder = getTemplatesFolder(true) :: Folder
	for _, id in ipairs(EnemyConfig.GetEnemyIds()) do
		local def = EnemyConfig.GetEnemy(id)
		if def and not folder:FindFirstChild(def.templateName) then
			local template = EnemyFactory.CreateProceduralPlaceholder(def)
			template.Name = def.templateName
			template.Parent = folder
		end
	end
	return folder
end

--[[
	Produces an enemy model instance for the given archetype definition.
	Checks ServerStorage.EnemyTemplates first; if not found, generates a procedural model.
]]
function EnemyFactory.CreateEnemyModel(def: EnemyConfig.EnemyDefinition): Model
	local templates = getTemplatesFolder(false)
	if templates then
		local template = templates:FindFirstChild(def.templateName)
		if template and template:IsA("Model") and template.PrimaryPart then
			local cloned = template:Clone()
			cloned.Name = def.id

			-- Rebind telegraph light if this is a TurretShooter clone
			if def.id == EnemyConfig.Archetypes.TurretShooter then
				local cannon = cloned:FindFirstChild("VisualTurret")
				local light = cannon and cannon:FindFirstChild("TelegraphLight") :: PointLight?
				if light then
					cloned:GetAttributeChangedSignal("IsTelegraphing"):Connect(function()
						light.Enabled = (cloned:GetAttribute("IsTelegraphing") == true)
					end)
				end
			end

			return cloned
		end
	end

	-- Fallback to procedural clay model
	local placeholder = EnemyFactory.CreateProceduralPlaceholder(def)
	placeholder.Name = def.id
	return placeholder
end

return EnemyFactory
