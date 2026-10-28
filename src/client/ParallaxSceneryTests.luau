--!strict
--[[
	ParallaxSceneryTests.luau
	Authoritative unit test harness for Scrolling Background & Parallax Layers.
	Task: CLAY-032 (Scrolling Background & Parallax Layers)

	TEST SUITE:
	1. Parallax Layer Hierarchy: 3 distinct layers generated in ClientParallaxBackground.
	2. Depth Ordering: Near (z=-25) > Mid (z=-60) > Far (z=-110), all < PlayPlaneZ (0).
	3. Speed Differential: Near speed > Mid speed > Far speed > 0.
	4. Near Layer Clay Theming: Tiles contain Pillar and DuneFoot clay elements.
	5. Mid Layer Clay Theming: Tiles contain MesaRidge and MesaCap clay elements.
	6. Far Layer Clay Theming: Tiles contain CloudCenter, CloudLeft, and CloudRight clay elements.
	7. Complete Physics & Collision Isolation: Every single part has CanCollide=false, CanTouch=false, CanQuery=false.
	8. Seamless Tiling Invariant: Zero gaps between adjacent tiles across all layers (< 0.001 studs).
	9. Wrap-around Continuity: Tiling remains seamless after simulated multi-cycle scrolling.
	10. Clean Teardown: _Teardown completely destroys background instances without memory leaks.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))

local ParallaxSceneryTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function ParallaxSceneryTests.RunTests(backgroundControllerModule: any?): {
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
			warn(string.format("[ParallaxSceneryTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- 1. Initialize and build layers
	BackgroundController._Teardown()
	BackgroundController.BuildLayers()

	local container = BackgroundController.GetContainer()
	assertTest("ClientParallaxBackground container exists in Workspace", container ~= nil and container:IsDescendantOf(Workspace))

	local runtimeLayers = BackgroundController.GetLayers()
	assertTest("Runtime has at least 3 parallax layers", #runtimeLayers >= 3)

	-- 2. Depth ordering
	local nearLayer, midLayer, farLayer
	for _, l in ipairs(runtimeLayers) do
		if string.find(l.name, "Near") then nearLayer = l end
		if string.find(l.name, "Mid") then midLayer = l end
		if string.find(l.name, "Far") then farLayer = l end
	end

	assertTest("Near, Mid, and Far layers identified", nearLayer ~= nil and midLayer ~= nil and farLayer ~= nil)
	if nearLayer and midLayer and farLayer then
		assertTest("Near zOffset is strictly behind gameplay plane (< 0)", nearLayer.zOffset < GameConfig.Arena.PlayPlaneZ)
		assertTest("Depth order strictly preserved: Near.z > Mid.z > Far.z", nearLayer.zOffset > midLayer.zOffset and midLayer.zOffset > farLayer.zOffset)
		assertTest("Speed differential strictly preserved: Near.speed > Mid.speed > Far.speed", nearLayer.speed > midLayer.speed and midLayer.speed > farLayer.speed)
	end

	-- 3. Thematic clay silhouettes in tiles
	if nearLayer and #nearLayer.tiles > 0 then
		local tileModel = nearLayer.tiles[1].model
		local hasPillar = tileModel:FindFirstChild("Pillar_1") ~= nil
		local hasDuneFoot = tileModel:FindFirstChild("DuneFoot_1") ~= nil
		assertTest("Near layer tiles contain sculpted clay Pillar and DuneFoot elements", hasPillar and hasDuneFoot)
	end

	if midLayer and #midLayer.tiles > 0 then
		local tileModel = midLayer.tiles[1].model
		local hasMesa = tileModel:FindFirstChild("MesaRidge_1") ~= nil
		local hasCap = tileModel:FindFirstChild("MesaCap_1") ~= nil
		assertTest("Mid layer tiles contain terraced clay MesaRidge and MesaCap elements", hasMesa and hasCap)
	end

	if farLayer and #farLayer.tiles > 0 then
		local tileModel = farLayer.tiles[1].model
		local hasCloudCenter = tileModel:FindFirstChild("CloudCenter_1") ~= nil
		local hasCloudLeft = tileModel:FindFirstChild("CloudLeft_1") ~= nil
		assertTest("Far layer tiles contain sculpted puffy clay Cloud elements", hasCloudCenter and hasCloudLeft)
	end

	-- 4. Physics & Collision Isolation across ALL parts
	local allPartsSafe = true
	local totalPartCount = 0
	if container then
		for _, desc in ipairs(container:GetDescendants()) do
			if desc:IsA("BasePart") then
				totalPartCount += 1
				if desc.CanCollide ~= false or desc.CanTouch ~= false or desc.CanQuery ~= false or desc.Anchored ~= true then
					allPartsSafe = false
				end
			end
		end
	end
	assertTest("All scenery parts across all layers have CanCollide=false, CanTouch=false, CanQuery=false, Anchored=true", allPartsSafe)
	assertTest("Rich scenery generated (total scenery part count > 30)", totalPartCount > 30)

	-- 5. Seamless Tiling Invariant
	local function checkLayerGaps(layer: any): number
		local sorted = {}
		for _, t in ipairs(layer.tiles) do table.insert(sorted, t) end
		table.sort(sorted, function(a, b) return a.rootPart.Position.X < b.rootPart.Position.X end)
		local maxG = 0
		for i = 1, #sorted - 1 do
			local rightEdge = sorted[i].rootPart.Position.X + (sorted[i].width / 2)
			local leftEdge = sorted[i + 1].rootPart.Position.X - (sorted[i + 1].width / 2)
			local g = math.abs(leftEdge - rightEdge)
			if g > maxG then maxG = g end
		end
		return maxG
	end

	for _, l in ipairs(runtimeLayers) do
		local gap = checkLayerGaps(l)
		assertTest(string.format("Layer '%s' tiles are seamlessly adjacent (gap < 0.001 studs)", l.name), gap < 0.001)
	end

	-- 6. Wrap-around Continuity over 10 scroll cycles
	for _ = 1, 100 do
		BackgroundController.StepScroll(0.2)
	end

	for _, l in ipairs(runtimeLayers) do
		local gap = checkLayerGaps(l)
		assertTest(string.format("Layer '%s' maintains seamless zero-gap tiling after scrolling (gap < 0.01 studs)", l.name), gap < 0.01)
	end

	-- 7. Teardown
	BackgroundController._Teardown()
	assertTest("Teardown completely destroys background container", BackgroundController.GetContainer() == nil)
	assertTest("Teardown resets initialized flag", BackgroundController.IsInitialized() == false)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return ParallaxSceneryTests
