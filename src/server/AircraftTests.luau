--!strict
--[[
	AircraftTests.luau
	Authoritative unit test harness for AircraftFactory and AircraftService lifecycle.
	Task: CLAY-003 (Create Placeholder Aircraft Model Factory)
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))

local AircraftFactory = require(script.Parent:WaitForChild("AircraftFactory"))
local AircraftService = require(script.Parent:WaitForChild("AircraftService"))

local AircraftTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	message: string?,
}

function AircraftTests.RunTests(): { total: number, passed: number, failed: number, results: { TestResult } }
	local results: { TestResult } = {}
	local passedCount = 0
	local failedCount = 0

	local function assertTest(name: string, condition: boolean, detail: string?)
		if condition then
			passedCount += 1
			table.insert(results, { name = name, passed = true })
		else
			failedCount += 1
			table.insert(results, { name = name, passed = false, message = detail })
		end
	end

	local activePlanesFolder = Workspace:WaitForChild("ActivePlanes") :: Folder
	local testUserId = 999001

	-- Setup: Clean up any pre-existing test instances to ensure test isolation
	for _, child in ipairs(activePlanesFolder:GetChildren()) do
		if child:GetAttribute("OwnerUserId") == testUserId then
			child:Destroy()
		end
	end

	-- Test 1: AircraftFactory produces a Model
	local plane = AircraftFactory.CreatePlaceholderPlane(testUserId)
	assertTest("AircraftFactory creates a valid Model instance", plane:IsA("Model"))
	assertTest("Aircraft Model is named Plane_<UserId>", plane.Name == string.format("Plane_%d", testUserId))

	-- Test 2: PrimaryPart exists, is Anchored, and non-colliding
	local primaryPart = plane.PrimaryPart
	assertTest("Aircraft Model has a valid PrimaryPart named RootPart", primaryPart ~= nil and primaryPart.Name == "RootPart")
	if primaryPart then
		assertTest("PrimaryPart is Anchored", primaryPart.Anchored == true)
		assertTest("PrimaryPart CanCollide is false", primaryPart.CanCollide == false)
		assertTest(
			"Aircraft is positioned strictly at PlayPlaneZ = 0",
			math.abs(primaryPart.Position.Z - GameConfig.Arena.PlayPlaneZ) < 0.001
		)
		-- Forward direction is +X
		local lookVector = primaryPart.CFrame.LookVector
		local facingPositiveX = lookVector:FuzzyEq(Vector3.new(1, 0, 0), 0.05)
		assertTest("Aircraft is oriented facing positive X (forward in 2.5D arena)", facingPositiveX)
	end

	-- Test 3: Essential structural parts exist
	local wings = plane:FindFirstChild("Wings")
	local tailFin = plane:FindFirstChild("TailFin")
	local tailWing = plane:FindFirstChild("TailWing")
	local cockpit = plane:FindFirstChild("Cockpit")
	assertTest("Aircraft includes Wings part", wings ~= nil and wings:IsA("BasePart"))
	assertTest("Aircraft includes TailFin part", tailFin ~= nil and tailFin:IsA("BasePart"))
	assertTest("Aircraft includes TailWing part", tailWing ~= nil and tailWing:IsA("BasePart"))
	assertTest("Aircraft includes Cockpit part", cockpit ~= nil and cockpit:IsA("BasePart"))

	-- Test 4: Essential attachments exist
	if primaryPart then
		local muzzle = primaryPart:FindFirstChild("Muzzle")
		local exhaust = primaryPart:FindFirstChild("Exhaust")
		assertTest("Aircraft has Muzzle attachment inside PrimaryPart", muzzle ~= nil and muzzle:IsA("Attachment"))
		assertTest("Aircraft has Exhaust attachment inside PrimaryPart", exhaust ~= nil and exhaust:IsA("Attachment"))
	end

	-- Test 5: Attributes are properly set
	assertTest("Model has OwnerUserId attribute matching UserId", plane:GetAttribute("OwnerUserId") == testUserId)
	assertTest("Model has AircraftType attribute", plane:GetAttribute("AircraftType") == "StandardFighter")
	assertTest("Model has Health attribute equal to 100", plane:GetAttribute("Health") == 100)
	assertTest("Model has MaxHealth attribute equal to 100", plane:GetAttribute("MaxHealth") == 100)

	-- Test 6: Lifecycle in Workspace.ActivePlanes
	plane.Parent = activePlanesFolder
	assertTest("Plane can be parented to Workspace.ActivePlanes", plane.Parent == activePlanesFolder)
	plane:Destroy()
	assertTest("Destroying plane removes it from Workspace.ActivePlanes", activePlanesFolder:FindFirstChild(string.format("Plane_%d", testUserId)) == nil)

	-- Test 7: AircraftService despawn orphan cleanup
	local orphanPlane = AircraftFactory.CreatePlaceholderPlane(testUserId)
	orphanPlane.Parent = activePlanesFolder
	AircraftService.DespawnPlaneForPlayer(testUserId)
	local remaining = activePlanesFolder:FindFirstChild(string.format("Plane_%d", testUserId))
	assertTest("DespawnPlaneForPlayer leaves zero orphaned models for UserId", remaining == nil)

	-- Multi-player Lifecycle Integration Tests
	local mockPlayer1 = { UserId = 888001, Name = "PilotAlpha" }
	local mockPlayer2 = { UserId = 888002, Name = "PilotBravo" }

	-- Clean up any pre-existing test instances for mocks
	AircraftService.DespawnPlaneForPlayer(mockPlayer1.UserId)
	AircraftService.DespawnPlaneForPlayer(mockPlayer2.UserId)

	-- Test 8: Concurrent multi-player spawn creates distinct planes
	local p1Plane = AircraftService.SpawnPlaneForPlayer(mockPlayer1)
	local p2Plane = AircraftService.SpawnPlaneForPlayer(mockPlayer2)
	assertTest("Player 1 gets plane parented to ActivePlanes", p1Plane.Parent == activePlanesFolder)
	assertTest("Player 2 gets plane parented to ActivePlanes", p2Plane.Parent == activePlanesFolder)
	assertTest("Planes for different players are distinct instances", p1Plane ~= p2Plane)
	assertTest("Player 1 plane OwnerUserId is 888001", p1Plane:GetAttribute("OwnerUserId") == 888001)
	assertTest("Player 2 plane OwnerUserId is 888002", p2Plane:GetAttribute("OwnerUserId") == 888002)

	-- Test 9: Idempotency (re-spawning player does not create duplicate planes)
	local duplicateP1 = AircraftService.SpawnPlaneForPlayer(mockPlayer1)
	assertTest("SpawnPlaneForPlayer is idempotent and returns existing plane", duplicateP1 == p1Plane)

	-- Test 10: Player 1 leaves, Player 2 plane remains unaffected
	AircraftService.DespawnPlaneForPlayer(mockPlayer1)
	assertTest("Player 1 plane is removed from ActivePlanes on leave", activePlanesFolder:FindFirstChild("Plane_888001") == nil)
	assertTest("Player 1 plane reference is destroyed", p1Plane.Parent == nil)
	assertTest("Player 2 plane remains intact in ActivePlanes", activePlanesFolder:FindFirstChild("Plane_888002") == p2Plane)
	assertTest("GetPlaneForPlayer(mockPlayer1) returns nil", AircraftService.GetPlaneForPlayer(mockPlayer1) == nil)
	assertTest("GetPlaneForPlayer(mockPlayer2) returns p2Plane", AircraftService.GetPlaneForPlayer(mockPlayer2) == p2Plane)

	-- Test 11: Player 2 leaves, leaving ActivePlanes with zero orphaned test models
	AircraftService.DespawnPlaneForPlayer(mockPlayer2)
	assertTest("Player 2 plane is removed from ActivePlanes on leave", activePlanesFolder:FindFirstChild("Plane_888002") == nil)
	assertTest("Player 2 plane reference is destroyed", p2Plane.Parent == nil)
	assertTest("GetPlaneForPlayer(mockPlayer2) returns nil", AircraftService.GetPlaneForPlayer(mockPlayer2) == nil)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return AircraftTests
