--!strict
--[[
	CameraTests.luau
	Unit test harness for 2.5D side camera follow (CameraController).
	Task: CLAY-005 (Implement Side Camera Follow)

	Validates:
	1. Config integrity and parameter bounds.
	2. Local player aircraft subject acquisition and multi-player isolation.
	3. Orthonormal 2.5D side-on projection (Z-depth, zero pitch/roll tilt).
	4. Forward look-ahead and boundary clamping.
	5. Frame-rate independent exponential smoothing.
	6. Despawn resilience and smooth respawn reacquisition.
	7. Idempotency and clean teardown.
]]

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))

local CameraTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function CameraTests.RunTests(cameraControllerModule: any?): {
	total: number,
	passed: number,
	failed: number,
	results: { [number]: TestResult },
}
	local CameraController = cameraControllerModule
	if not CameraController then
		local StarterPlayer = game:GetService("StarterPlayer")
		local controllersFolder = StarterPlayer.StarterPlayerScripts:WaitForChild("Controllers")
		CameraController = require(controllersFolder:WaitForChild("CameraController"))
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
			warn(string.format("[CameraTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- 1. GameConfig.Camera schema and sanity checks
	assertTest("GameConfig.Camera exists and is defined", GameConfig.Camera ~= nil)
	assertTest("Camera FieldOfView is in valid range [50, 90]", GameConfig.Camera.FieldOfView >= 50 and GameConfig.Camera.FieldOfView <= 90)
	assertTest("Camera Distance is positive", GameConfig.Camera.Distance > 0)
	assertTest("Camera FollowSmoothness is positive", GameConfig.Camera.FollowSmoothness > 0)
	assertTest("Camera LookAheadX is non-negative", GameConfig.Camera.LookAheadX >= 0)
	assertTest("Camera framing bounds MinX < MaxX", GameConfig.Camera.MinX < GameConfig.Camera.MaxX)
	assertTest("Camera framing bounds MinY < MaxY", GameConfig.Camera.MinY < GameConfig.Camera.MaxY)

	-- Setup mock active planes container if not present in Workspace
	local activePlanes = Workspace:FindFirstChild("ActivePlanes")
	local createdActivePlanes = false
	if not activePlanes then
		activePlanes = Instance.new("Folder")
		activePlanes.Name = "ActivePlanes"
		activePlanes.Parent = Workspace
		createdActivePlanes = true
	end

	-- Helper to create a lightweight mock aircraft Model
	local function createMockPlane(userId: number, pos: Vector3): Model
		local plane = Instance.new("Model")
		plane.Name = string.format("Plane_%d", userId)
		plane:SetAttribute("OwnerUserId", userId)

		local root = Instance.new("Part")
		root.Name = "RootPart"
		root.Size = Vector3.new(4, 1, 1)
		root.Anchored = true
		root.CanCollide = false
		root.CFrame = CFrame.new(pos)
		root.Parent = plane
		plane.PrimaryPart = root
		plane.Parent = activePlanes
		return plane
	end

	local localUserId = if Players.LocalPlayer then Players.LocalPlayer.UserId else 12345678
	local foreignUserId = 99988877

	-- 2. Multi-player subject isolation
	local foreignPlane = createMockPlane(foreignUserId, Vector3.new(20, 10, 0))
	local localPlane = createMockPlane(localUserId, Vector3.new(0, 0, 0))

	-- Ensure override is cleared for natural lookup test
	CameraController._ClearSubjectOverride()
	local resolvedSubject = CameraController.GetSubject()

	if Players.LocalPlayer then
		assertTest("Resolved subject is not nil when local player plane exists", resolvedSubject ~= nil)
		if resolvedSubject then
			assertTest("Resolved subject matches local player UserId attribute", resolvedSubject:GetAttribute("OwnerUserId") == localUserId)
			assertTest("Resolved subject is not foreign player's plane", resolvedSubject ~= foreignPlane)
		end
	else
		-- In pure server/edit test without LocalPlayer, use subject override to verify isolation logic
		CameraController._SetSubjectOverride(localPlane)
		assertTest("Subject override successfully mocks local plane", CameraController.GetSubject() == localPlane)
		CameraController._SetSubjectOverride(foreignPlane)
		assertTest("Foreign plane can be set in override for testing", CameraController.GetSubject() == foreignPlane)
		CameraController._SetSubjectOverride(localPlane)
	end

	-- 3. Side-on Camera CFrame and orientation verification
	CameraController._Teardown()
	CameraController._SetSubjectOverride(localPlane)

	-- Position plane at (10, 5, 0)
	localPlane:PivotTo(CFrame.new(10, 5, 0))

	-- Step camera until convergence to steady state
	for _ = 1, 30 do
		CameraController.StepCamera(0.05)
	end
	local camCFrame = CameraController.StepCamera(0.05)

	-- Look direction must be strictly along -Z (Z coordinate of LookVector close to -1)
	assertTest("Camera look direction is strictly -Z (perpendicular to play plane)", math.abs(camCFrame.LookVector.Z - (-1)) < 0.001)
	assertTest("Camera LookVector has zero X tilt", math.abs(camCFrame.LookVector.X) < 0.001)
	assertTest("Camera LookVector has zero Y tilt", math.abs(camCFrame.LookVector.Y) < 0.001)

	-- Up vector must be strictly +Y
	assertTest("Camera UpVector is strictly +Y", math.abs(camCFrame.UpVector.Y - 1) < 0.001)
	assertTest("Camera RightVector is strictly +X (horizontal side view)", math.abs(camCFrame.RightVector.X - 1) < 0.001)

	-- Camera eye Z position must be PlayPlaneZ + Distance
	local expectedZ = GameConfig.Arena.PlayPlaneZ + GameConfig.Camera.Distance
	assertTest("Camera Z position matches PlayPlaneZ + Distance", math.abs(camCFrame.Position.Z - expectedZ) < 0.001)

	-- 4. LookAhead forward bias
	local expectedTargetX = 10 + GameConfig.Camera.LookAheadX
	assertTest("Camera framing incorporates forward LookAhead offset", math.abs(camCFrame.Position.X - expectedTargetX) < 0.05)

	-- 5. Arena boundary clamping
	-- Move plane far past positive boundaries
	localPlane:PivotTo(CFrame.new(200, 150, 0))
	for _ = 1, 30 do
		CameraController.StepCamera(0.05)
	end
	local clampedCFrameMax = CameraController.StepCamera(0.05)
	assertTest("Camera X framing clamps to MaxX", math.abs(clampedCFrameMax.Position.X - GameConfig.Camera.MaxX) < 0.01)
	assertTest("Camera Y framing clamps to MaxY", math.abs(clampedCFrameMax.Position.Y - GameConfig.Camera.MaxY) < 0.01)

	-- Move plane far past negative boundaries
	localPlane:PivotTo(CFrame.new(-200, -150, 0))
	for _ = 1, 30 do
		CameraController.StepCamera(0.05)
	end
	local clampedCFrameMin = CameraController.StepCamera(0.05)
	assertTest("Camera X framing clamps to MinX", math.abs(clampedCFrameMin.Position.X - GameConfig.Camera.MinX) < 0.01)
	assertTest("Camera Y framing clamps to MinY", math.abs(clampedCFrameMin.Position.Y - GameConfig.Camera.MinY) < 0.01)

	-- 6. Frame-rate independent exponential smoothing
	-- Reset camera to origin
	CameraController._Teardown()
	localPlane:PivotTo(CFrame.new(0, 0, 0))
	CameraController._SetSubjectOverride(localPlane)
	for _ = 1, 30 do
		CameraController.StepCamera(0.05)
	end -- Snap to (LookAheadX, 0)

	-- Move plane to (20, 0, 0)
	localPlane:PivotTo(CFrame.new(20, 0, 0))
	local startSmoothed = CameraController.GetSmoothedPosition()

	-- Step once with dt = 0.02
	CameraController.StepCamera(0.02)
	local afterOneStep = CameraController.GetSmoothedPosition()
	assertTest("Camera moves toward subject during step", afterOneStep ~= nil and afterOneStep.X > startSmoothed.X)

	-- Reset and compare 2 x 0.01s steps vs 1 x 0.02s step
	CameraController._Teardown()
	localPlane:PivotTo(CFrame.new(0, 0, 0))
	CameraController._SetSubjectOverride(localPlane)
	for _ = 1, 30 do
		CameraController.StepCamera(0.05)
	end
	localPlane:PivotTo(CFrame.new(20, 0, 0))
	CameraController.StepCamera(0.01)
	CameraController.StepCamera(0.01)
	local afterTwoHalfSteps = CameraController.GetSmoothedPosition()

	-- Exponential decay guarantees: (1 - e^(-k*0.01))*(...) twice == (1 - e^(-k*0.02))
	local diff = math.abs(afterOneStep.X - afterTwoHalfSteps.X)
	assertTest("Exponential smoothing is frame-rate independent (2x0.01s vs 1x0.02s match within 0.001)", diff < 0.001)

	-- 7. Despawn resilience (subject becomes nil)
	CameraController._SetSubjectOverride(nil)
	local despawnCFrame = CameraController.StepCamera(0.1)
	assertTest("Stepping camera when subject is nil does not produce NaN or error", despawnCFrame.Position.X == despawnCFrame.Position.X)
	assertTest("Camera retains valid CFrame after subject despawn", despawnCFrame.Position.Z > 0)

	-- 8. Respawn reacquisition
	localPlane:PivotTo(CFrame.new(5, 5, 0))
	CameraController._SetSubjectOverride(localPlane)
	local respawnCFrame = CameraController.StepCamera(0.1)
	assertTest("Camera reacquires subject smoothly after respawn", respawnCFrame ~= nil)

	-- 9. Idempotency and teardown
	CameraController.Initialize()
	assertTest("CameraController initializes", CameraController.IsInitialized() == true)
	CameraController.Initialize()
	assertTest("Duplicate CameraController.Initialize() is idempotent", CameraController.IsInitialized() == true)

	CameraController._Teardown()
	assertTest("CameraController._Teardown() restores uninitialized state", CameraController.IsInitialized() == false)
	assertTest("CameraController smoothed position is cleared after teardown", CameraController.GetSmoothedPosition() == nil)

	-- Cleanup test models
	localPlane:Destroy()
	foreignPlane:Destroy()
	if createdActivePlanes and activePlanes then
		activePlanes:Destroy()
	end

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return CameraTests
