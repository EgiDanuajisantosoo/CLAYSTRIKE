--!strict
--[[
	BackgroundController.luau
	Client-side parallax scrolling background controller for CLAYSTRIKE.
	Task: CLAY-008 (Arena Bounds & Scrolling Playfield)

	Generates and scrolls multi-layer background elements locally on the client.
	All objects are strictly non-colliding (CanCollide = false, CanTouch = false, CanQuery = false).
	Calculates viewport width dynamically from camera FOV and layer distance to guarantee
	seamless, gap-free looping on any screen aspect ratio.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local sharedGameConfig = SharedFolder:WaitForChild("GameConfig")
local GameConfig = require(sharedGameConfig)
if (GameConfig :: any).Background == nil then
	GameConfig = require(sharedGameConfig:Clone())
end

local BackgroundController = {}

local RENDER_STEP_NAME = "CLAYSTRIKE_BackgroundScroll"

type TileData = {
	model: Model,
	rootPart: BasePart,
	width: number,
}

export type LayerRuntime = {
	name: string,
	zOffset: number,
	speed: number,
	tileWidth: number,
	tiles: { TileData },
	totalTiledWidth: number,
	container: Model,
	wrapCount: number,
}

local isInitialized = false
local layers: { LayerRuntime } = {}
local totalWrapCount = 0
local backgroundContainer: Model? = nil
local renderStepConnection: RBXScriptConnection? = nil

--[[
	Calculates the horizontal visible span in world studs for a layer at a given Z position.
	Accounts for camera FOV, camera distance, aspect ratio, and camera X movement range.
]]
local function calculateVisibleSpanForZ(layerZ: number): number
	local camera = Workspace.CurrentCamera
	local fov = if camera then camera.FieldOfView else GameConfig.Camera.FieldOfView
	local cameraZ = if camera and camera.CFrame.Position.Z ~= 0
		then camera.CFrame.Position.Z
		else (GameConfig.Arena.PlayPlaneZ + GameConfig.Camera.Distance)
	local distance = math.abs(cameraZ - layerZ)

	-- Vertical height visible at this Z depth: 2 * distance * tan(FOV / 2)
	local radFov = math.rad(fov)
	local visibleHeight = 2 * distance * math.tan(radFov / 2)

	-- Viewport aspect ratio (width / height)
	local aspectRatio = 16 / 9 -- default fallback
	if camera and camera.ViewportSize.Y > 0 then
		aspectRatio = camera.ViewportSize.X / camera.ViewportSize.Y
	end
	-- Use a wide aspect ratio guarantee (supports ultrawide 21:9 up to 2.4 ratio)
	local safeAspect = math.max(aspectRatio, 2.4)
	local visibleWidth = visibleHeight * safeAspect

	-- Camera travels horizontally between MinX and MaxX
	local cameraTravel = math.abs(GameConfig.Camera.MaxX - GameConfig.Camera.MinX)
	local safetyBuffer = 100 -- extra safety margin

	return visibleWidth + cameraTravel + safetyBuffer
end

-- Helper to create a stylized clay scenery part welded visually to a tile
local function createSceneryPart(
	name: string,
	size: Vector3,
	offset: Vector3,
	color: Color3,
	shape: Enum.PartType?,
	model: Model,
	root: BasePart
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
	part.CastShadow = false
	part.Anchored = true
	part.CFrame = root.CFrame * CFrame.new(offset)
	part.Parent = model
	return part
end

--[[
	Constructs a visual stylized clay tile for a parallax layer with unique thematic silhouettes.
]]
local function createTile(
	layerName: string,
	tileIndex: number,
	width: number,
	height: number,
	color: Color3,
	zPos: number,
	parent: Instance
): TileData
	local model = Instance.new("Model")
	model.Name = string.format("Tile_%s_%d", layerName, tileIndex)

	local root = Instance.new("Part")
	root.Name = "BasePlane"
	root.Size = Vector3.new(width, height, 1)
	root.Position = Vector3.new(0, 0, zPos)
	root.Anchored = true
	root.CanCollide = false
	root.CanTouch = false
	root.CanQuery = false
	root.CastShadow = false
	root.Material = Enum.Material.SmoothPlastic
	root.Color = color
	root.Parent = model
	model.PrimaryPart = root

	local isNear = string.find(layerName, "Near") ~= nil
	local isMid = string.find(layerName, "Mid") ~= nil
	local isFar = string.find(layerName, "Far") ~= nil

	if isNear then
		-- 1. Near Layer: Clay Sandstone Pillars & Rolling Dunes
		local pillarCount = 3
		local step = width / (pillarCount + 1)
		local pillarHeights = { 16, 24, 18 }
		local accentSand = Color3.fromRGB(160, 140, 125)

		for p = 1, pillarCount do
			local pHeight = pillarHeights[(p % 3) + 1]
			local pX = -width / 2 + p * step
			-- Sandstone pillar column
			createSceneryPart(
				string.format("Pillar_%d", p),
				Vector3.new(step * 0.45, pHeight, 2.0),
				Vector3.new(pX, height * 0.25 + pHeight * 0.5, 0),
				color,
				Enum.PartType.Block,
				model,
				root
			)
			-- Rounded clay pillar cap
			createSceneryPart(
				string.format("PillarCap_%d", p),
				Vector3.new(step * 0.52, 2.5, 2.2),
				Vector3.new(pX, height * 0.25 + pHeight + 1.25, 0),
				accentSand,
				Enum.PartType.Block,
				model,
				root
			)
			-- Soft clay dune at the foot of each pillar
			createSceneryPart(
				string.format("DuneFoot_%d", p),
				Vector3.new(step * 0.8, 6.0, 1.8),
				Vector3.new(pX, height * 0.25 + 3.0, 0),
				accentSand,
				Enum.PartType.Ball,
				model,
				root
			)
		end

	elseif isMid then
		-- 2. Mid Layer: Terraced Clay Mountain Ridges & Plateaus
		local ridgeCount = 3
		local step = width / ridgeCount
		local ridgeHeights = { 28, 38, 32 }
		local darkUmber = Color3.fromRGB(95, 75, 65)

		for r = 1, ridgeCount do
			local rHeight = ridgeHeights[(r % 3) + 1]
			local rX = -width / 2 + (r - 0.5) * step
			-- Stepped terraced mountain body
			createSceneryPart(
				string.format("MesaRidge_%d", r),
				Vector3.new(step * 0.95, rHeight, 1.5),
				Vector3.new(rX, height * 0.25 + rHeight * 0.5, 0),
				color,
				Enum.PartType.Block,
				model,
				root
			)
			-- Terraced plateau plateau cap
			createSceneryPart(
				string.format("MesaCap_%d", r),
				Vector3.new(step * 0.85, 3.0, 1.8),
				Vector3.new(rX, height * 0.25 + rHeight + 1.5, 0),
				darkUmber,
				Enum.PartType.Block,
				model,
				root
			)
		end

	elseif isFar then
		-- 3. Far Layer: Hand-Sculpted Puffy Clay Clouds
		local cloudClusters = 3
		local step = width / cloudClusters
		local cloudColor = Color3.fromRGB(140, 130, 145) -- Soft clay cloud lavender

		for c = 1, cloudClusters do
			local cX = -width / 2 + (c - 0.5) * step
			local cY = height * 0.35
			-- Tri-lobe clay cloud puffs
			createSceneryPart(
				string.format("CloudCenter_%d", c),
				Vector3.new(16, 12, 1.2),
				Vector3.new(cX, cY, 0),
				cloudColor,
				Enum.PartType.Ball,
				model,
				root
			)
			createSceneryPart(
				string.format("CloudLeft_%d", c),
				Vector3.new(12, 9, 1.0),
				Vector3.new(cX - 8, cY - 2, 0),
				cloudColor,
				Enum.PartType.Ball,
				model,
				root
			)
			createSceneryPart(
				string.format("CloudRight_%d", c),
				Vector3.new(14, 10, 1.0),
				Vector3.new(cX + 8, cY - 1, 0),
				cloudColor,
				Enum.PartType.Ball,
				model,
				root
			)
		end
	end

	model.Parent = parent
	return {
		model = model,
		rootPart = root,
		width = width,
	}
end

--[[
	Builds the modular tiling background layers locally in Workspace.
]]
function BackgroundController.BuildLayers()
	if backgroundContainer then
		backgroundContainer:Destroy()
	end

	local container = Instance.new("Model")
	container.Name = "ClientParallaxBackground"
	container.Parent = Workspace
	backgroundContainer = container
	layers = {}
	totalWrapCount = 0

	local layerConfigs = GameConfig.Background.Layers
	local baseSpeed = GameConfig.Background.BaseScrollSpeed

	for _, cfg in ipairs(layerConfigs) do
		local layerModel = Instance.new("Model")
		layerModel.Name = "Layer_" .. cfg.name
		layerModel.Parent = container

		local requiredSpan = calculateVisibleSpanForZ(cfg.zOffset)
		local tileW = cfg.tileWidth
		-- Ensure at least 4 tiles and enough to comfortably exceed the required visible span
		local tileCount = math.max(4, math.ceil(requiredSpan / tileW) + 2)
		local totalTiledW = tileCount * tileW

		-- Calculate starting anchor so tiles are centered around arena center
		local startX = -totalTiledW / 2 + (tileW / 2)
		local layerHeight = 120

		local tiles: { TileData } = {}
		for i = 1, tileCount do
			local tile = createTile(
				cfg.name,
				i,
				tileW,
				layerHeight,
				cfg.color,
				cfg.zOffset,
				layerModel
			)
			local posX = startX + (i - 1) * tileW
			tile.rootPart.Position = Vector3.new(posX, 0, cfg.zOffset)
			-- Re-align mounds with base plane
			local rootCFrame = tile.rootPart.CFrame
			for _, child in ipairs(tile.model:GetChildren()) do
				if child:IsA("BasePart") and child ~= tile.rootPart then
					local rel = child.Position - Vector3.new(0, 0, cfg.zOffset)
					child.Position = Vector3.new(posX + rel.X, child.Position.Y, cfg.zOffset)
				end
			end
			table.insert(tiles, tile)
		end

		local layerData: LayerRuntime = {
			name = cfg.name,
			zOffset = cfg.zOffset,
			speed = baseSpeed * cfg.speedMultiplier,
			tileWidth = tileW,
			tiles = tiles,
			totalTiledWidth = totalTiledW,
			container = layerModel,
			wrapCount = 0,
		}
		table.insert(layers, layerData)
	end
end

--[[
	Single-step scrolling update.
	Moves each tile along -X by (speed * dt) and wraps tiles seamlessly
	when they scroll beyond the visible left edge of the camera viewport.
]]
function BackgroundController.StepScroll(dt: number)
	local camera = Workspace.CurrentCamera
	local camX = 0
	if camera then
		camX = camera.CFrame.Position.X
	end

	for _, layer in ipairs(layers) do
		local moveDist = layer.speed * dt
		local halfVisibleW = calculateVisibleSpanForZ(layer.zOffset) / 2
		-- Left threshold: when a tile's right edge passes beyond the visible left horizon
		local leftWrapThreshold = camX - halfVisibleW - (layer.tileWidth / 2)

		for _, tile in ipairs(layer.tiles) do
			local currentX = tile.rootPart.Position.X
			local newX = currentX - moveDist

			-- If tile scrolled fully off the left side, wrap it to the far right.
			-- Uses a while loop to handle large dt (frame spikes) deterministically without stranding tiles outside view.
			while newX < leftWrapThreshold do
				newX = newX + layer.totalTiledWidth
				layer.wrapCount += 1
				totalWrapCount += 1
			end

			local deltaX = newX - currentX
			tile.rootPart.Position = Vector3.new(newX, tile.rootPart.Position.Y, layer.zOffset)
			for _, child in ipairs(tile.model:GetChildren()) do
				if child:IsA("BasePart") and child ~= tile.rootPart then
					child.Position = child.Position + Vector3.new(deltaX, 0, 0)
				end
			end
		end
	end
end

--[[
	RenderStep loop callback.
]]
local function onRenderStep(dt: number)
	BackgroundController.StepScroll(dt)
end

--[[
	Initializes the BackgroundController. Idempotent.
]]
function BackgroundController.Initialize()
	if isInitialized then
		warn("[BackgroundController] Initialize() already called; skipping duplicate setup.")
		return
	end
	isInitialized = true

	BackgroundController.BuildLayers()

	renderStepConnection = RunService.RenderStepped:Connect(onRenderStep)
	print("[BackgroundController] Parallax scrolling background initialized with seamless camera-aware tiling.")
end

--[[
	Returns true if BackgroundController is currently initialized.
]]
function BackgroundController.IsInitialized(): boolean
	return isInitialized
end

--[[
	Returns the list of active layer runtimes.
]]
function BackgroundController.GetLayers(): { LayerRuntime }
	return layers
end

--[[
	Returns the background container model.
]]
function BackgroundController.GetContainer(): Model?
	return backgroundContainer
end

--[[
	Returns the total number of tile wrap events across all layers since initialization or build.
]]
function BackgroundController.GetTotalWrapCount(): number
	return totalWrapCount
end

--[[
	Returns the wrap count for a specific layer by name, or 0 if not found.
]]
function BackgroundController.GetLayerWrapCount(layerName: string): number
	for _, layer in ipairs(layers) do
		if layer.name == layerName then
			return layer.wrapCount
		end
	end
	return 0
end

--[[
	Test helper to clean up background models and disconnect the render loop.
]]
function BackgroundController._Teardown()
	if renderStepConnection then
		renderStepConnection:Disconnect()
		renderStepConnection = nil
	end
	if backgroundContainer then
		backgroundContainer:Destroy()
		backgroundContainer = nil
	end
	layers = {}
	totalWrapCount = 0
	isInitialized = false
end

return BackgroundController
