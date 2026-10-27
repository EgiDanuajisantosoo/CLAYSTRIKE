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

--[[
	Constructs a visual stylized clay tile for a parallax layer.
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

	-- Add stylized rolling clay shapes on top
	local moundCount = 3
	local moundStep = width / moundCount
	for m = 1, moundCount do
		local mound = Instance.new("Part")
		mound.Name = string.format("Mound_%d", m)
		mound.Shape = Enum.PartType.Cylinder
		mound.Size = Vector3.new(0.8, moundStep * 0.9, moundStep * 0.9)
		mound.CFrame = root.CFrame
			* CFrame.new((m - 2) * moundStep, height * 0.35, 0)
			* CFrame.Angles(0, 0, math.rad(90))
		mound.Anchored = true
		mound.CanCollide = false
		mound.CanTouch = false
		mound.CanQuery = false
		mound.CastShadow = false
		mound.Material = Enum.Material.SmoothPlastic
		mound.Color = color
		mound.Parent = model
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
