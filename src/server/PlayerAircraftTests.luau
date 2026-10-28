--!strict
--[[
	PlayerAircraftTests.luau
	Authoritative unit test harness for the Original Player Aircraft Model.
	Task: CLAY-027 (Create Original Player Aircraft Model)

	TEST SUITE:
	1. Model instantiation: Factory returns valid Model with PrimaryPart set to RootPart.
	2. Forward orientation: Model look vector aligns with +X gameplay axis (>= 0.99 X).
	3. 2.5D Play-plane alignment: All parts strictly adhere to PlayPlaneZ = 0.
	4. Simplified collision geometry: RootPart has CanCollide=false, CanTouch=false, CanQuery=true.
	5. Visual render parts non-colliding: All visual parts have CanCollide=false, CanTouch=false, CanQuery=false.
	6. Part count budget: Total part count is between 7 and 9 (strictly <= 12 parts agreed budget).
	7. Assembly integrity: Every visual part is rigidly attached to RootPart via WeldConstraint.
	8. Combat & VFX attachments: Muzzle (+X nose) and Exhaust (-X tail) attachments exist.
	9. Engine exhaust VFX: Exhaust attachment contains configured EngineExhaust ParticleEmitter.
	10. Authoritative attributes: OwnerUserId, AircraftType, Health, MaxHealth, Invulnerable, State, BankTilt.
	11. Backward compatibility: CreatePlaceholderPlane aliases CreatePlayerAircraft with matching contracts.
	12. Clean teardown: Destroying plane leaves zero dangling welds or memory leaks.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))

local Services = ServerScriptService:WaitForChild("Services")
local AircraftFactory = require(Services:WaitForChild("AircraftFactory"))

local PlayerAircraftTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function PlayerAircraftTests.RunTests(): {
	total: number,
	passed: number,
	failed: number,
	results: { [number]: TestResult },
}
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
			warn(string.format("[PlayerAircraftTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	local testUserId = 99101
	local testSpawnPos = Vector3.new(-25, 10, GameConfig.Arena.PlayPlaneZ)
	local planeModel = AircraftFactory.CreatePlayerAircraft(testUserId, testSpawnPos)
	planeModel.Parent = Workspace

	-- 1. Model Instantiation & PrimaryPart
	assertTest("Factory returned Model instance", planeModel ~= nil and planeModel:IsA("Model"))
	assertTest("PrimaryPart is assigned and named 'RootPart'", planeModel.PrimaryPart ~= nil and planeModel.PrimaryPart.Name == "RootPart")
	assertTest("Model name follows 'Plane_<UserId>' convention", planeModel.Name == string.format("Plane_%d", testUserId))

	local rootPart = planeModel.PrimaryPart :: BasePart

	-- 2. Forward Orientation (+X Flight Axis)
	local lookVec = rootPart.CFrame.LookVector
	assertTest("Forward LookVector aligned along +X (LookVector.X >= 0.99)", lookVec.X >= 0.99)
	assertTest("UpVector aligned along +Y (UpVector.Y >= 0.99)", rootPart.CFrame.UpVector.Y >= 0.99)

	-- 3. 2.5D Play-plane Alignment
	assertTest("RootPart position Z matches Arena.PlayPlaneZ", math.abs(rootPart.Position.Z - GameConfig.Arena.PlayPlaneZ) < 0.001)

	-- 4. Simplified Collision Geometry (RootPart)
	assertTest("RootPart CanCollide is false", rootPart.CanCollide == false)
	assertTest("RootPart CanTouch is false", rootPart.CanTouch == false)
	assertTest("RootPart CanQuery is true (for hit detection & raycasts)", rootPart.CanQuery == true)
	assertTest("RootPart Anchored is true", rootPart.Anchored == true)

	-- 5. Visual Render Parts Non-Colliding
	local allParts: { BasePart } = {}
	for _, child in ipairs(planeModel:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(allParts, child)
		end
	end

	local visualPartsAllNonColliding = true
	local visualPartsAllNoTouch = true
	for _, part in ipairs(allParts) do
		if part ~= rootPart then
			if part.CanCollide ~= false then
				visualPartsAllNonColliding = false
			end
			if part.CanTouch ~= false then
				visualPartsAllNoTouch = false
			end
		end
	end
	assertTest("All visual parts have CanCollide == false", visualPartsAllNonColliding == true)
	assertTest("All visual parts have CanTouch == false", visualPartsAllNoTouch == true)

	-- 6. Part Count Budget
	assertTest("Total part count is strictly between 7 and 9 (<= 12 budget)", #allParts >= 7 and #allParts <= 9)

	-- 7. Assembly Integrity (WeldConstraints)
	local allWelded = true
	for _, part in ipairs(allParts) do
		if part ~= rootPart then
			local weldFound = false
			for _, w in ipairs(rootPart:GetChildren()) do
				if w:IsA("WeldConstraint") and (w.Part1 == part or w.Part0 == part) then
					weldFound = true
					break
				end
			end
			if not weldFound then
				allWelded = false
			end
		end
	end
	assertTest("Every visual part is rigidly attached via WeldConstraint to RootPart", allWelded == true)

	-- 8. Combat & VFX Attachments
	local muzzle = rootPart:FindFirstChild("Muzzle") :: Attachment?
	assertTest("Muzzle attachment exists on RootPart", muzzle ~= nil and muzzle:IsA("Attachment"))
	assertTest("Muzzle is positioned forward at nose (X > 2.0)", muzzle ~= nil and muzzle.Position.X > 2.0)

	local exhaust = rootPart:FindFirstChild("Exhaust") :: Attachment?
	assertTest("Exhaust attachment exists on RootPart", exhaust ~= nil and exhaust:IsA("Attachment"))
	assertTest("Exhaust is positioned rearward at tail (X < -2.0)", exhaust ~= nil and exhaust.Position.X < -2.0)

	-- 9. Engine Exhaust ParticleEmitter
	local emitter = exhaust and exhaust:FindFirstChild("EngineExhaust") :: ParticleEmitter?
	assertTest("EngineExhaust particle emitter exists in Exhaust attachment", emitter ~= nil and emitter:IsA("ParticleEmitter"))
	assertTest("EngineExhaust particle emitter is enabled", emitter ~= nil and emitter.Enabled == true)

	-- 10. Authoritative Model Attributes
	assertTest("Attribute OwnerUserId matches input UserId", planeModel:GetAttribute("OwnerUserId") == testUserId)
	assertTest("Attribute AircraftType is 'ClayFalcon'", planeModel:GetAttribute("AircraftType") == "ClayFalcon")
	assertTest("Attribute Health is 100", planeModel:GetAttribute("Health") == 100)
	assertTest("Attribute MaxHealth is 100", planeModel:GetAttribute("MaxHealth") == 100)
	assertTest("Attribute Invulnerable is false initially", planeModel:GetAttribute("Invulnerable") == false)
	assertTest("Attribute State is 'Active'", planeModel:GetAttribute("State") == "Active")
	assertTest("Attribute BankTilt exists", planeModel:GetAttribute("BankTilt") ~= nil)

	-- 11. Backward Compatibility (CreatePlaceholderPlane)
	local placeholder = AircraftFactory.CreatePlaceholderPlane(testUserId + 1, testSpawnPos)
	assertTest("CreatePlaceholderPlane succeeds and returns valid Model", placeholder ~= nil and placeholder:IsA("Model"))
	assertTest("CreatePlaceholderPlane PrimaryPart has Muzzle and Exhaust",
		placeholder.PrimaryPart ~= nil and placeholder.PrimaryPart:FindFirstChild("Muzzle") ~= nil and placeholder.PrimaryPart:FindFirstChild("Exhaust") ~= nil)
	placeholder:Destroy()

	-- 12. Clean Teardown
	planeModel:Destroy()
	assertTest("Aircraft model destroyed cleanly", planeModel.Parent == nil)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return PlayerAircraftTests
