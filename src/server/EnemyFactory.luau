--!strict
--[[
	EnemyFactory.luau
	Authoritative server model factory for enemy archetypes in CLAYSTRIKE.
	Task: CLAY-016 (Enemy Spawn Factory & Cleanup)

	Creates or clones enemy models conforming to the StyleGuide:
	- PrimaryPart centered and named "HitProxy".
	- Non-colliding physics (CanCollide = false, CanTouch = false, CanQuery = true for raycasts).
	- Visual claymation appearance using Color3 and SmoothPlastic/Clay material.
	- Falls back gracefully to procedurally generated clay placeholders if ServerStorage template is absent.
]]

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
if (EnemyConfig :: any).Archetypes == nil then
	EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"):Clone())
end

local EnemyFactory = {}

-- Helper to retrieve ServerStorage.EnemyTemplates folder
local function getTemplatesFolder(): Folder?
	local folder = ServerStorage:FindFirstChild("EnemyTemplates")
	if folder and folder:IsA("Folder") then
		return folder
	end
	return nil
end

--[[
	Creates a placeholder model for an enemy archetype matching the exact contract.
]]
function EnemyFactory.CreateProceduralPlaceholder(def: EnemyConfig.EnemyDefinition): Model
	local model = Instance.new("Model")
	model.Name = string.format("Placeholder_%s", def.id)

	-- 1. Primary HitProxy Part (authoritative collision & raycast receiver)
	local proxy = Instance.new("Part")
	proxy.Name = "HitProxy"
	proxy.Size = def.collisionSize
	proxy.Position = Vector3.zero
	proxy.Material = Enum.Material.SmoothPlastic
	proxy.Color = def.clayColor
	proxy.Anchored = true
	proxy.CanCollide = false
	proxy.CanTouch = false
	proxy.CanQuery = true -- Authoritative swept raycasts hit this proxy
	proxy.CastShadow = true
	proxy.Parent = model

	model.PrimaryPart = proxy

	-- 2. Visual nose / forward marker to show orientation (+X forward)
	local nose = Instance.new("Part")
	nose.Name = "VisualNose"
	nose.Size = Vector3.new(def.collisionSize.X * 0.35, def.collisionSize.Y * 0.45, def.collisionSize.Z * 0.45)
	nose.Position = Vector3.new(-def.collisionSize.X * 0.45, 0, 0) -- Pointing left towards player
	nose.Material = Enum.Material.SmoothPlastic
	nose.Color = Color3.fromRGB(45, 45, 50) -- Dark clay accent
	nose.Anchored = true
	nose.CanCollide = false
	nose.CanTouch = false
	nose.CanQuery = false
	nose.CastShadow = false
	nose.Parent = model

	-- 3. Turret shooter specific aimed cannon and telegraph indicator
	if def.id == EnemyConfig.Archetypes.TurretShooter then
		local cannon = Instance.new("Part")
		cannon.Name = "VisualTurret"
		cannon.Size = Vector3.new(def.collisionSize.X * 0.45, def.collisionSize.Y * 0.25, def.collisionSize.Z * 0.25)
		cannon.Position = Vector3.new(-def.collisionSize.X * 0.55, 0, 0)
		cannon.Material = Enum.Material.SmoothPlastic
		cannon.Color = Color3.fromRGB(35, 35, 40)
		cannon.Anchored = true
		cannon.CanCollide = false
		cannon.CanTouch = false
		cannon.CanQuery = false
		cannon.CastShadow = false
		cannon.Parent = model

		local muzzle = Instance.new("Attachment")
		muzzle.Name = "MuzzleAttachment"
		muzzle.Position = Vector3.new(-cannon.Size.X * 0.5, 0, 0)
		muzzle.Parent = cannon

		local telegraphLight = Instance.new("PointLight")
		telegraphLight.Name = "TelegraphLight"
		telegraphLight.Color = Color3.fromRGB(255, 60, 40)
		telegraphLight.Range = 14
		telegraphLight.Brightness = 0
		telegraphLight.Enabled = false
		telegraphLight.Parent = cannon

		model:GetAttributeChangedSignal("IsTelegraphing"):Connect(function()
			local isTele = model:GetAttribute("IsTelegraphing") == true
			telegraphLight.Enabled = isTele
		end)
	end

	-- 4. Pursuer specific interceptor wings
	if def.id == EnemyConfig.Archetypes.Pursuer then
		local wings = Instance.new("Part")
		wings.Name = "VisualWings"
		wings.Size = Vector3.new(def.collisionSize.X * 0.5, def.collisionSize.Y * 0.15, def.collisionSize.Z * 1.8)
		wings.Position = Vector3.new(0, 0, 0)
		wings.Material = Enum.Material.SmoothPlastic
		wings.Color = Color3.fromRGB(155, 55, 35)
		wings.Anchored = true
		wings.CanCollide = false
		wings.CanTouch = false
		wings.CanQuery = false
		wings.CastShadow = false
		wings.Parent = model
	end

	return model
end

--[[
	Produces an enemy model instance for the given archetype definition.
	Checks ServerStorage.EnemyTemplates first; if not found, generates a procedural placeholder.
]]
function EnemyFactory.CreateEnemyModel(def: EnemyConfig.EnemyDefinition): Model
	local templates = getTemplatesFolder()
	if templates then
		local template = templates:FindFirstChild(def.templateName)
		if template and template:IsA("Model") and template.PrimaryPart then
			local cloned = template:Clone()
			cloned.Name = def.id
			return cloned
		end
	end

	-- Fallback to procedural clay placeholder
	local placeholder = EnemyFactory.CreateProceduralPlaceholder(def)
	placeholder.Name = def.id
	return placeholder
end

return EnemyFactory
