--!strict
--[[
	ArenaService.luau
	Authoritative arena boundary builder for CLAYSTRIKE.
	Task: CLAY-008 (Arena Bounds & Scrolling Playfield)

	Builds visual playfield boundary indicators in Workspace.CombatArena derived
	strictly from GameConfig.Arena. All borders represent the authoritative clamp
	limits of the player aircraft's center position (RootPart).
	All instances are strictly Anchored = true, CanCollide = false, CanTouch = false.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))

local ArenaService = {}

local isInitialized = false
local boundaryParts: { [string]: BasePart } = {}

local BORDER_COLOR = Color3.fromRGB(255, 175, 110)
local BORDER_THICKNESS = 0.5
local BORDER_TRANSPARENCY = 0.35
local CORNER_SIZE = 1.6

--[[
	Creates an anchored, non-colliding visual indicator part.
]]
local function createBorderPart(name: string, size: Vector3, position: Vector3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = BORDER_COLOR
	part.Transparency = BORDER_TRANSPARENCY
	part.Parent = parent
	return part
end

--[[
	Builds the visual boundary markers inside Workspace.CombatArena.
]]
function ArenaService.BuildVisualBoundaries()
	local combatArena = Workspace:FindFirstChild("CombatArena")
	if not combatArena then
		local newFolder = Instance.new("Folder")
		newFolder.Name = "CombatArena"
		newFolder.Parent = Workspace
		combatArena = newFolder
	end

	-- Clear any existing boundary model
	local existingBounds = combatArena:FindFirstChild("VisualBounds")
	if existingBounds then
		existingBounds:Destroy()
	end
	boundaryParts = {}

	local boundsModel = Instance.new("Model")
	boundsModel.Name = "VisualBounds"

	local minX = GameConfig.Arena.MinX
	local maxX = GameConfig.Arena.MaxX
	local minY = GameConfig.Arena.MinY
	local maxY = GameConfig.Arena.MaxY
	local playZ = GameConfig.Arena.PlayPlaneZ

	local width = maxX - minX
	local height = maxY - minY
	local centerX = (minX + maxX) / 2
	local centerY = (minY + maxY) / 2

	-- 1. Horizontal borders (Top and Bottom)
	boundaryParts["TopBorder"] = createBorderPart(
		"TopBorder",
		Vector3.new(width, BORDER_THICKNESS, BORDER_THICKNESS),
		Vector3.new(centerX, maxY, playZ),
		boundsModel
	)

	boundaryParts["BottomBorder"] = createBorderPart(
		"BottomBorder",
		Vector3.new(width, BORDER_THICKNESS, BORDER_THICKNESS),
		Vector3.new(centerX, minY, playZ),
		boundsModel
	)

	-- 2. Vertical borders (Left and Right)
	boundaryParts["LeftBorder"] = createBorderPart(
		"LeftBorder",
		Vector3.new(BORDER_THICKNESS, height, BORDER_THICKNESS),
		Vector3.new(minX, centerY, playZ),
		boundsModel
	)

	boundaryParts["RightBorder"] = createBorderPart(
		"RightBorder",
		Vector3.new(BORDER_THICKNESS, height, BORDER_THICKNESS),
		Vector3.new(maxX, centerY, playZ),
		boundsModel
	)

	-- 3. Corner indicators at exact clamp vertices
	local corners = {
		{ name = "Corner_TopLeft", pos = Vector3.new(minX, maxY, playZ) },
		{ name = "Corner_TopRight", pos = Vector3.new(maxX, maxY, playZ) },
		{ name = "Corner_BottomLeft", pos = Vector3.new(minX, minY, playZ) },
		{ name = "Corner_BottomRight", pos = Vector3.new(maxX, minY, playZ) },
	}

	for _, corner in ipairs(corners) do
		local cPart = createBorderPart(
			corner.name,
			Vector3.new(CORNER_SIZE, CORNER_SIZE, BORDER_THICKNESS),
			corner.pos,
			boundsModel
		)
		cPart.Transparency = 0.1
		boundaryParts[corner.name] = cPart
	end

	boundsModel.Parent = combatArena
end

--[[
	Initializes the ArenaService. Idempotent.
]]
function ArenaService.Initialize()
	if isInitialized then
		warn("[ArenaService] Initialize() already called; skipping duplicate setup.")
		return
	end
	isInitialized = true

	ArenaService.BuildVisualBoundaries()
	print(string.format(
		"[ArenaService] Arena visual boundaries initialized (X: [%d, %d], Y: [%d, %d], Z: %d).",
		GameConfig.Arena.MinX,
		GameConfig.Arena.MaxX,
		GameConfig.Arena.MinY,
		GameConfig.Arena.MaxY,
		GameConfig.Arena.PlayPlaneZ
	))
end

--[[
	Returns true if ArenaService is currently initialized.
]]
function ArenaService.IsInitialized(): boolean
	return isInitialized
end

--[[
	Returns the map of boundary parts.
]]
function ArenaService.GetBoundaries(): { [string]: BasePart }
	return boundaryParts
end

--[[
	Test helper to clean up visual boundaries and restore uninitialized state.
]]
function ArenaService._Teardown()
	local combatArena = Workspace:FindFirstChild("CombatArena")
	if combatArena then
		local boundsModel = combatArena:FindFirstChild("VisualBounds")
		if boundsModel then
			boundsModel:Destroy()
		end
	end
	boundaryParts = {}
	isInitialized = false
end

return ArenaService
