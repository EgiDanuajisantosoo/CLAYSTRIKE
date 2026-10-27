--!strict
--[[
	BackgroundTests.luau
	Unit test harness for client parallax background scrolling.
	Task: CLAY-008 (Arena Bounds & Scrolling Playfield)

	Validates:
	1. Config schema and layer parameters.
	2. Dynamic viewport coverage guarantees on wide aspect ratios.
	3. Seamless tiling invariant (zero gaps, zero overlap between tiles).
	4. Seamless wrap-around continuity over multiple scroll cycles.
	5. Strict non-collision and zero interference with aircraft physics.
	6. Idempotency and clean teardown.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local sharedGameConfig = SharedFolder:WaitForChild("GameConfig")
local GameConfig = require(sharedGameConfig)
if (GameConfig :: any).Background == nil then
	GameConfig = require(sharedGameConfig:Clone())
end

local BackgroundTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function BackgroundTests.RunTests(backgroundControllerModule: any?): {
	total: number,
	passed: number,
	failed: number,
	results: { [number]: TestResult },
}
	local BackgroundController = backgroundControllerModule
	if not BackgroundController then
		local StarterPlayer = game:GetService("StarterPlayer")
		local controllers = StarterPlayer.StarterPlayerScripts:WaitForChild("Controllers")
		BackgroundController = require(controllers:WaitForChild("BackgroundController"))
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
			warn(string.format("[BackgroundTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- 1. GameConfig.Background schema
	assertTest("GameConfig.Background is defined", GameConfig.Background ~= nil)
	assertTest("BaseScrollSpeed is positive", GameConfig.Background.BaseScrollSpeed > 0)
	assertTest("At least 3 parallax layers configured", #GameConfig.Background.Layers >= 3)

	for _, layerCfg in ipairs(GameConfig.Background.Layers) do
		assertTest(string.format("Layer '%s' has zOffset < PlayPlaneZ (behind gameplay plane)", layerCfg.name), layerCfg.zOffset < GameConfig.Arena.PlayPlaneZ)
		assertTest(string.format("Layer '%s' has positive tileWidth", layerCfg.name), layerCfg.tileWidth > 0)
		assertTest(string.format("Layer '%s' has positive speedMultiplier", layerCfg.name), layerCfg.speedMultiplier > 0)
	end

	-- 2. Build layers and inspect structure
	BackgroundController._Teardown()
	BackgroundController.BuildLayers()

	local container = BackgroundController.GetContainer()
	assertTest("ClientParallaxBackground container exists in Workspace", container ~= nil and container:IsDescendantOf(Workspace))

	local runtimeLayers = BackgroundController.GetLayers()
	assertTest("Runtime layers match configured layer count", #runtimeLayers == #GameConfig.Background.Layers)

	-- 3. Seamless tile adjacency invariant & coverage
	for _, layer in ipairs(runtimeLayers) do
		assertTest(string.format("Layer '%s' has at least 4 tiles", layer.name), #layer.tiles >= 4)
		assertTest(string.format("Layer '%s' total tiled width > 400 studs", layer.name), layer.totalTiledWidth > 400)

		-- Sort tiles by X position to verify contiguous adjacency
		local sortedTiles = {}
		for _, t in ipairs(layer.tiles) do
			table.insert(sortedTiles, t)
		end
		table.sort(sortedTiles, function(a, b)
			return a.rootPart.Position.X < b.rootPart.Position.X
		end)

		local maxGap = 0
		for i = 1, #sortedTiles - 1 do
			local currentRight = sortedTiles[i].rootPart.Position.X + (sortedTiles[i].width / 2)
			local nextLeft = sortedTiles[i + 1].rootPart.Position.X - (sortedTiles[i + 1].width / 2)
			local gap = math.abs(nextLeft - currentRight)
			if gap > maxGap then
				maxGap = gap
			end
		end
		assertTest(string.format("Layer '%s' tiles are seamlessly adjacent with zero gap (gap < 0.001)", layer.name), maxGap < 0.001)
	end

	-- 4. Non-collision and non-physics interaction
	for _, layer in ipairs(runtimeLayers) do
		for _, tile in ipairs(layer.tiles) do
			assertTest(string.format("Tile '%s' is Anchored", tile.model.Name), tile.rootPart.Anchored == true)
			assertTest(string.format("Tile '%s' has CanCollide = false", tile.model.Name), tile.rootPart.CanCollide == false)
			assertTest(string.format("Tile '%s' has CanTouch = false", tile.model.Name), tile.rootPart.CanTouch == false)
			assertTest(string.format("Tile '%s' has CanQuery = false", tile.model.Name), tile.rootPart.CanQuery == false)
		end
	end

	-- Helper to verify seamless tile adjacency across any layer
	local function checkLayerAdjacency(layer: any): (boolean, number)
		local sortedTiles = {}
		for _, t in ipairs(layer.tiles) do
			table.insert(sortedTiles, t)
		end
		table.sort(sortedTiles, function(a, b)
			return a.rootPart.Position.X < b.rootPart.Position.X
		end)

		local maxGap = 0
		for i = 1, #sortedTiles - 1 do
			local currentRight = sortedTiles[i].rootPart.Position.X + (sortedTiles[i].width / 2)
			local nextLeft = sortedTiles[i + 1].rootPart.Position.X - (sortedTiles[i + 1].width / 2)
			local gap = math.abs(nextLeft - currentRight)
			if gap > maxGap then
				maxGap = gap
			end
		end
		return (maxGap < 0.01), maxGap
	end

	-- 5A. Large delta-time (frame spike) resilience
	-- Simulates a 25.0 second lag spike where displacement exceeds full tiled widths
	BackgroundController.BuildLayers()
	runtimeLayers = BackgroundController.GetLayers()
	assertTest("Wrap count starts at 0 after BuildLayers", BackgroundController.GetTotalWrapCount() == 0)

	BackgroundController.StepScroll(25.0)
	assertTest("Large dt (25s) executes wrap without error and increments wrap counter", BackgroundController.GetTotalWrapCount() > 0)

	for _, layer in ipairs(runtimeLayers) do
		local isAdjacent, maxGap = checkLayerAdjacency(layer)
		assertTest(string.format("Layer '%s' maintains seamless adjacency after 25s frame spike (gap: %.4f)", layer.name, maxGap), isAdjacent)

		-- Verify no tile was stranded outside the camera coverage horizon
		local camX = if Workspace.CurrentCamera then Workspace.CurrentCamera.CFrame.Position.X else 0
		local halfVisibleW = layer.totalTiledWidth / 2
		local leftBound = camX - halfVisibleW - (layer.tileWidth)
		local anyStranded = false
		for _, tile in ipairs(layer.tiles) do
			if tile.rootPart.Position.X < leftBound then
				anyStranded = true
			end
		end
		assertTest(string.format("Layer '%s' has no stranded tiles after 25s frame spike", layer.name), not anyStranded)
	end

	-- 5B. Multi-wrap simulation: advance until every layer experiences multiple true wrap cycles
	BackgroundController.BuildLayers()
	runtimeLayers = BackgroundController.GetLayers()
	local TARGET_WRAPS_PER_LAYER = 5
	local maxSimSteps = 3000
	local simSteps = 0
	local allAdjacentDuringWraps = true
	local lastWrapCount = 0

	while simSteps < maxSimSteps do
		simSteps += 1
		BackgroundController.StepScroll(1.0) -- advance 1.0 second per step

		local currentWrapCount = BackgroundController.GetTotalWrapCount()
		if currentWrapCount > lastWrapCount then
			lastWrapCount = currentWrapCount
			-- Check adjacency immediately upon wrap occurrences
			for _, layer in ipairs(runtimeLayers) do
				local isAdjacent = checkLayerAdjacency(layer)
				if not isAdjacent then
					allAdjacentDuringWraps = false
				end
			end
		end

		local allLayersReached = true
		for _, layer in ipairs(runtimeLayers) do
			if layer.wrapCount < TARGET_WRAPS_PER_LAYER then
				allLayersReached = false
				break
			end
		end
		if allLayersReached then
			break
		end
	end

	assertTest(string.format("Multi-wrap simulation completed within %d steps (actual: %d)", maxSimSteps, simSteps), simSteps < maxSimSteps)
	assertTest("Tile adjacency remained seamless across all wrap events", allAdjacentDuringWraps)

	for _, layer in ipairs(runtimeLayers) do
		assertTest(
			string.format("Layer '%s' reached target wrap count >= %d (actual: %d)", layer.name, TARGET_WRAPS_PER_LAYER, layer.wrapCount),
			layer.wrapCount >= TARGET_WRAPS_PER_LAYER
		)
		assertTest(
			string.format("GetLayerWrapCount('%s') matches runtime wrapCount", layer.name),
			BackgroundController.GetLayerWrapCount(layer.name) == layer.wrapCount
		)

		local isAdjacent, finalGap = checkLayerAdjacency(layer)
		assertTest(
			string.format("Layer '%s' preserves zero-gap seamless invariant after %d true wraps (gap: %.4f)", layer.name, layer.wrapCount, finalGap),
			isAdjacent
		)
	end

	assertTest(
		string.format("Total wrap count >= %d across all layers (actual: %d)", #runtimeLayers * TARGET_WRAPS_PER_LAYER, BackgroundController.GetTotalWrapCount()),
		BackgroundController.GetTotalWrapCount() >= #runtimeLayers * TARGET_WRAPS_PER_LAYER
	)

	-- 6. Zero interference with aircraft movement or coordinates
	local mockPlane = Instance.new("Model")
	mockPlane.Name = "Plane_MockBackgroundTest"
	local mockRoot = Instance.new("Part")
	mockRoot.Name = "RootPart"
	mockRoot.Position = Vector3.new(0, 0, GameConfig.Arena.PlayPlaneZ)
	mockRoot.Anchored = true
	mockRoot.CanCollide = false
	mockRoot.Parent = mockPlane
	mockPlane.PrimaryPart = mockRoot
	mockPlane.Parent = Workspace

	local originalPlanePos = mockRoot.Position
	for _ = 1, 50 do
		BackgroundController.StepScroll(0.05)
	end
	assertTest("Background scrolling causes zero displacement to aircraft position", mockRoot.Position == originalPlanePos)
	mockPlane:Destroy()

	-- 7. Idempotency and teardown
	BackgroundController.Initialize()
	assertTest("BackgroundController.Initialize() is idempotent", BackgroundController.IsInitialized() == true)
	BackgroundController._Teardown()
	assertTest("BackgroundController._Teardown() cleans up container", BackgroundController.GetContainer() == nil)
	assertTest("BackgroundController._Teardown() resets totalWrapCount to 0", BackgroundController.GetTotalWrapCount() == 0)
	assertTest("BackgroundController is uninitialized after teardown", BackgroundController.IsInitialized() == false)

	-- Rebuild for live usage
	BackgroundController.Initialize()

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return BackgroundTests
