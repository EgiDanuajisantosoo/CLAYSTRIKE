--!strict
--[[
	ArenaTests.luau
	Unit test harness for ArenaService and playfield boundaries.
	Task: CLAY-008 (Arena Bounds & Scrolling Playfield)

	Validates:
	1. Visual boundary parts match GameConfig.Arena clamp values precisely.
	2. Visual boundary parts are Anchored = true, CanCollide = false, CanTouch = false.
	3. Visual boundary indicators have no physics or collision interference.
	4. ArenaService.Initialize() is idempotent and _Teardown() is clean.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))

local ArenaTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function ArenaTests.RunTests(arenaServiceModule: any?): {
	total: number,
	passed: number,
	failed: number,
	results: { [number]: TestResult },
}
	local ArenaService = arenaServiceModule
	if not ArenaService then
		local ServerScriptService = game:GetService("ServerScriptService")
		local servicesFolder = ServerScriptService:WaitForChild("Services")
		ArenaService = require(servicesFolder:WaitForChild("ArenaService"))
	end

	local results: { [number]: TestResult } = {}
	local passedCount = 0
	local failedCount = 0

	local function assertTest(name: string, condition: boolean, errorMsg: string?)
		local testIndex = #results + 1
		if condition then
			passedCount += 1
			results[testIndex] = { name = name, passed = true }
		else
			failedCount += 1
			local failureText = errorMsg or "Assertion failed"
			results[testIndex] = { name = name, passed = false, error = failureText }
			warn(string.format("[ArenaTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- 1. GameConfig.Arena schema validation
	assertTest("GameConfig.Arena exists", GameConfig.Arena ~= nil)
	assertTest("Arena MinX is -80", GameConfig.Arena.MinX == -80)
	assertTest("Arena MaxX is 80", GameConfig.Arena.MaxX == 80)
	assertTest("Arena MinY is -40", GameConfig.Arena.MinY == -40)
	assertTest("Arena MaxY is 40", GameConfig.Arena.MaxY == 40)
	assertTest("Arena PlayPlaneZ is 0", GameConfig.Arena.PlayPlaneZ == 0)

	-- 2. Build visual boundaries
	ArenaService._Teardown()
	ArenaService.BuildVisualBoundaries()

	local combatArena = Workspace:FindFirstChild("CombatArena")
	assertTest("Workspace.CombatArena folder exists", combatArena ~= nil)

	local boundsModel = combatArena and combatArena:FindFirstChild("VisualBounds")
	assertTest("VisualBounds model created inside CombatArena", boundsModel ~= nil)

	local boundaries = ArenaService.GetBoundaries()
	assertTest("TopBorder exists", boundaries["TopBorder"] ~= nil)
	assertTest("BottomBorder exists", boundaries["BottomBorder"] ~= nil)
	assertTest("LeftBorder exists", boundaries["LeftBorder"] ~= nil)
	assertTest("RightBorder exists", boundaries["RightBorder"] ~= nil)

	-- 3. Boundary placement and dimensions match clamp values
	local top = boundaries["TopBorder"]
	local bottom = boundaries["BottomBorder"]
	local left = boundaries["LeftBorder"]
	local right = boundaries["RightBorder"]

	if top then
		assertTest("TopBorder Y position matches MaxY (40)", math.abs(top.Position.Y - GameConfig.Arena.MaxY) < 0.001)
		assertTest("TopBorder Z position matches PlayPlaneZ (0)", math.abs(top.Position.Z - GameConfig.Arena.PlayPlaneZ) < 0.001)
		assertTest("TopBorder width spans full X range (160 studs)", math.abs(top.Size.X - (GameConfig.Arena.MaxX - GameConfig.Arena.MinX)) < 0.001)
	end

	if bottom then
		assertTest("BottomBorder Y position matches MinY (-40)", math.abs(bottom.Position.Y - GameConfig.Arena.MinY) < 0.001)
		assertTest("BottomBorder Z position matches PlayPlaneZ (0)", math.abs(bottom.Position.Z - GameConfig.Arena.PlayPlaneZ) < 0.001)
		assertTest("BottomBorder width spans full X range (160 studs)", math.abs(bottom.Size.X - (GameConfig.Arena.MaxX - GameConfig.Arena.MinX)) < 0.001)
	end

	if left then
		assertTest("LeftBorder X position matches MinX (-80)", math.abs(left.Position.X - GameConfig.Arena.MinX) < 0.001)
		assertTest("LeftBorder Z position matches PlayPlaneZ (0)", math.abs(left.Position.Z - GameConfig.Arena.PlayPlaneZ) < 0.001)
		assertTest("LeftBorder height spans full Y range (80 studs)", math.abs(left.Size.Y - (GameConfig.Arena.MaxY - GameConfig.Arena.MinY)) < 0.001)
	end

	if right then
		assertTest("RightBorder X position matches MaxX (80)", math.abs(right.Position.X - GameConfig.Arena.MaxX) < 0.001)
		assertTest("RightBorder Z position matches PlayPlaneZ (0)", math.abs(right.Position.Z - GameConfig.Arena.PlayPlaneZ) < 0.001)
		assertTest("RightBorder height spans full Y range (80 studs)", math.abs(right.Size.Y - (GameConfig.Arena.MaxY - GameConfig.Arena.MinY)) < 0.001)
	end

	-- 4. Rigorous non-collision checks
	for name, part in pairs(boundaries) do
		assertTest(string.format("%s is Anchored", name), part.Anchored == true)
		assertTest(string.format("%s has CanCollide = false", name), part.CanCollide == false)
		assertTest(string.format("%s has CanTouch = false", name), part.CanTouch == false)
		assertTest(string.format("%s has CanQuery = false", name), part.CanQuery == false)
	end

	-- 5. Corner indicators
	assertTest("Corner_TopLeft is present", boundaries["Corner_TopLeft"] ~= nil)
	assertTest("Corner_TopRight is present", boundaries["Corner_TopRight"] ~= nil)
	assertTest("Corner_BottomLeft is present", boundaries["Corner_BottomLeft"] ~= nil)
	assertTest("Corner_BottomRight is present", boundaries["Corner_BottomRight"] ~= nil)

	-- 6. Idempotency and teardown
	ArenaService.Initialize()
	assertTest("ArenaService initializes successfully", ArenaService.IsInitialized() == true)
	ArenaService.Initialize()
	assertTest("Duplicate ArenaService.Initialize() is idempotent", ArenaService.IsInitialized() == true)

	ArenaService._Teardown()
	assertTest("ArenaService._Teardown() marks uninitialized", ArenaService.IsInitialized() == false)
	assertTest("VisualBounds removed from CombatArena after teardown", combatArena and combatArena:FindFirstChild("VisualBounds") == nil)

	-- Rebuild for production state
	ArenaService.Initialize()

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return ArenaTests
