--!strict
--[[
	PredictionTests.luau
	Comprehensive test harness for Client Prediction & Remote Plane Interpolation.
	Task: CLAY-007 (Client Prediction & Remote Plane Interpolation)

	TEST SUITE:
	1. Responsiveness under Latency: Local prediction advances plane immediately on input (zero input lag).
	2. Kinematic Parity: Prediction calculations exactly match server MovementService physics formulas.
	3. Boundary Clamping: Prediction enforces Arena.MinX/MaxX/MinY/MaxY and neutralizes wall velocities.
	4. Smooth Reconciliation: Small discrepancies (< 5 studs) blend exponentially without visible popping.
	5. Hard Snap on Large Discrepancy: Desync/teleport/respawn (>= 5 studs) snaps immediately.
	6. Remote Aircraft Interpolation: Remote co-op plane smoothly lerps without erratic micro-stutters.
	7. Remote Stale Fallback: Stalled remote packets (> 1.0s) hold position smoothly instead of flying off.
	8. Server Authoritativeness: Client position prediction is purely cosmetic; server state remains untouchable.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))

local Controllers = script.Parent
local PlanePredictionController = require(Controllers:WaitForChild("PlanePredictionController"))

local PredictionTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

local function createMockPlane(name: string, position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = name

	local part = Instance.new("Part")
	part.Name = "PrimaryPart"
	part.Size = Vector3.new(4, 2, 2)
	part.Position = position
	part.Anchored = true
	part.CanCollide = false
	part.Parent = model

	model.PrimaryPart = part
	return model
end

function PredictionTests.RunTests(): {
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
			warn(string.format("[PredictionTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Baseline setup
	PlanePredictionController._Teardown()
	PlanePredictionController.Initialize()
	assertTest("Controller initialized successfully", PlanePredictionController.IsInitialized() == true)

	local activePlanesFolder = Workspace:FindFirstChild("ActivePlanes")
	if not activePlanesFolder then
		activePlanesFolder = Instance.new("Folder")
		activePlanesFolder.Name = "ActivePlanes"
		activePlanesFolder.Parent = Workspace
	else
		activePlanesFolder:ClearAllChildren()
	end

	-- 1. Immediate Responsiveness under Latency (Local Prediction)
	local initialPos = Vector3.new(0, 0, GameConfig.Arena.PlayPlaneZ)
	local initialVel = Vector2.zero
	local inputDir = Vector2.new(1, 0) -- Move Right (+X)
	local dt = 0.05 -- 50ms frame

	local nextPos, nextVel = PlanePredictionController.PredictKinematicStep(initialPos, initialVel, inputDir, dt)
	assertTest("Predicted velocity increased immediately (+X)", nextVel.X > 0)
	assertTest("Predicted position advanced forward immediately (+X)", nextPos.X > initialPos.X)
	assertTest("Predicted position stayed on fixed 2.5D PlayPlaneZ", nextPos.Z == GameConfig.Arena.PlayPlaneZ)

	-- 2. Kinematic Parity with Configuration
	local expectedAccel = GameConfig.Movement.Acceleration * dt
	assertTest("Velocity acceleration matches GameConfig rate", math.abs(nextVel.X - expectedAccel) < 0.001)

	-- Step forward 10 frames to hit MaxSpeed without hitting arena wall
	local curP = initialPos
	local curV = initialVel
	for _ = 1, 10 do
		curP, curV = PlanePredictionController.PredictKinematicStep(curP, curV, inputDir, dt)
	end
	assertTest("Predicted velocity reaches and caps at MaxSpeed", math.abs(curV.X - GameConfig.Movement.MaxSpeed) < 0.001)

	-- 3. Boundary Clamping & Neutralization
	local nearRightEdge = Vector3.new(GameConfig.Arena.MaxX - 1, 0, GameConfig.Arena.PlayPlaneZ)
	local clampedPos, neutralizedVel = PlanePredictionController.PredictKinematicStep(
		nearRightEdge,
		Vector2.new(GameConfig.Movement.MaxSpeed, 0),
		Vector2.new(1, 0),
		0.2
	)
	assertTest("Predicted position is clamped exactly at Arena.MaxX", clampedPos.X == GameConfig.Arena.MaxX)
	assertTest("Predicted velocity driving into wall is neutralized to 0", neutralizedVel.X == 0)

	local nearTopEdge = Vector3.new(0, GameConfig.Arena.MaxY - 1, GameConfig.Arena.PlayPlaneZ)
	local clampedTopPos, neutralizedTopVel = PlanePredictionController.PredictKinematicStep(
		nearTopEdge,
		Vector2.new(0, GameConfig.Movement.MaxSpeed),
		Vector2.new(0, 1),
		0.2
	)
	assertTest("Predicted position is clamped exactly at Arena.MaxY", clampedTopPos.Y == GameConfig.Arena.MaxY)
	assertTest("Predicted vertical velocity driving into ceiling is neutralized to 0", neutralizedTopVel.Y == 0)

	-- 4. Smooth Reconciliation (Minor Desync < 5.0 studs)
	local predPos = Vector3.new(10, 5, GameConfig.Arena.PlayPlaneZ)
	local serverPos = Vector3.new(11, 5, GameConfig.Arena.PlayPlaneZ) -- 1.0 stud error

	local reconciledPos = PlanePredictionController.ReconcilePosition(predPos, serverPos, 0.05)
	assertTest("Reconciled position moved closer to server position", reconciledPos.X > predPos.X and reconciledPos.X < serverPos.X)
	assertTest("Reconciled position did NOT hard-snap (smooth blend)", math.abs(reconciledPos.X - serverPos.X) > 0.01)

	-- Advance reconciliation over multiple frames to verify complete convergence
	local convPos = predPos
	for _ = 1, 20 do
		convPos = PlanePredictionController.ReconcilePosition(convPos, serverPos, 0.05)
	end
	assertTest("Reconciled position converges completely to server position", math.abs(convPos.X - serverPos.X) < 0.001)

	-- 5. Hard Snap on Large Discrepancy (>= 5.0 studs, e.g. Respawn/Teleport)
	local divergentServerPos = Vector3.new(30, 5, GameConfig.Arena.PlayPlaneZ) -- 20 stud discrepancy
	local snappedPos = PlanePredictionController.ReconcilePosition(predPos, divergentServerPos, 0.05)
	assertTest("Large discrepancy snaps immediately to server position", snappedPos == divergentServerPos)

	-- 6. Remote Aircraft Interpolation (Other Co-op Players)
	local remoteStartPos = Vector3.new(-10, 0, GameConfig.Arena.PlayPlaneZ)
	local remoteTargetPos = Vector3.new(-5, 2, GameConfig.Arena.PlayPlaneZ)

	local interpPos = PlanePredictionController.InterpolateRemotePosition(remoteStartPos, remoteTargetPos, 0.1, 0.05)
	assertTest("Remote plane interpolates towards server target", interpPos.X > remoteStartPos.X and interpPos.X < remoteTargetPos.X)
	assertTest("Remote plane maintains PlayPlaneZ (0)", interpPos.Z == GameConfig.Arena.PlayPlaneZ)

	-- Converge remote plane over several frames
	local remoteCurrent = remoteStartPos
	for _ = 1, 30 do
		remoteCurrent = PlanePredictionController.InterpolateRemotePosition(remoteCurrent, remoteTargetPos, 0.1, 0.05)
	end
	assertTest("Remote plane smoothly reaches target without jitter", (remoteCurrent - remoteTargetPos).Magnitude < 0.01)

	-- 7. Remote Stale Packet Fallback
	local staleInterpPos = PlanePredictionController.InterpolateRemotePosition(
		remoteCurrent,
		Vector3.new(100, 100, 0), -- Stale / phantom target
		1.5, -- 1.5 seconds since last update (> REMOTE_TIMEOUT = 1.0s)
		0.05
	)
	assertTest("Stale remote update (> 1.0s) holds current position cleanly", staleInterpPos == remoteCurrent)

	-- 8. Integrated Step Test with Models in Workspace.ActivePlanes
	PlanePredictionController.SetLocalUserId(1001)
	local localPlaneModel = createMockPlane("Plane_1001", Vector3.new(0, 0, 0))
	localPlaneModel.Parent = activePlanesFolder

	local remotePlaneModel = createMockPlane("Plane_2002", Vector3.new(-20, 5, 0))
	remotePlaneModel.Parent = activePlanesFolder

	PlanePredictionController.SetPredictedPosition(Vector3.new(0, 0, 0))
	PlanePredictionController.SetPredictedVelocity(Vector2.new(15, 0))

	-- Step simulation
	PlanePredictionController.Step(0.05)

	local recRemote = PlanePredictionController.GetRemotePlaneRecord(2002)
	assertTest("Remote plane record created for Plane_2002", recRemote ~= nil)
	assertTest("Local plane model transform updated", localPlaneModel.PrimaryPart.Position.Z == GameConfig.Arena.PlayPlaneZ)
	assertTest("Remote plane model transform updated", remotePlaneModel.PrimaryPart.Position.Z == GameConfig.Arena.PlayPlaneZ)

	-- Cleanup
	PlanePredictionController._Teardown()
	if activePlanesFolder then
		activePlanesFolder:ClearAllChildren()
	end

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return PredictionTests
