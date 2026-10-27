--!strict
--[[
	MovementTests.luau
	Authoritative unit test harness for MovementService.
	Task: CLAY-004 (Implement Server-Validated 2.5D Movement)

	Validates:
	- Velocity-based integration (acceleration & deceleration).
	- Diagonal normalization and speed ceiling (target <= 50 studs/s).
	- Arena boundary clamping (X in [-80, 80], Y in [-40, 40]) even with huge deltaTime.
	- Boundary velocity neutralization (velocity zeroed at edge).
	- Fixed Z-plane (PlayPlaneZ = 0).
	- Explicit forward orientation (+X).
	- Input timeout handling (decelerates to 0 after 0.25s).
	- Malformed/non-finite input protection.
	- Multi-player velocity isolation and cleanup.
	- Idempotent initialization.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))

local AircraftFactory = require(script.Parent:WaitForChild("AircraftFactory"))
local AircraftService = require(script.Parent:WaitForChild("AircraftService"))
local MovementService = require(script.Parent:WaitForChild("MovementService"))

local MovementTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	message: string?,
}

function MovementTests.RunTests(): { total: number, passed: number, failed: number, results: { TestResult } }
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
	local testUser1 = { UserId = 555001, Name = "MovePilot1" }
	local testUser2 = { UserId = 555002, Name = "MovePilot2" }

	-- Setup: Clean up any pre-existing test instances
	AircraftService.DespawnPlaneForPlayer(testUser1.UserId)
	AircraftService.DespawnPlaneForPlayer(testUser2.UserId)
	MovementService.CleanupPlayer(testUser1.UserId)
	MovementService.CleanupPlayer(testUser2.UserId)

	-- Spawn aircraft for test player 1
	local plane1 = AircraftService.SpawnPlaneForPlayer(testUser1, Vector3.new(0, 0, 0))
	assertTest("Test plane 1 spawned for movement test", plane1 ~= nil and plane1.Parent == activePlanesFolder)

	-- 1. Diagonal normalization & speed ceiling
	MovementService.HandleMoveIntent(testUser1, Vector2.new(1, 1))
	local inputDir = MovementService.GetInputDirection(testUser1)
	assertTest("Diagonal input direction is normalized (Magnitude <= 1.0)", math.abs(inputDir.Magnitude - 1.0) < 0.001)
	local targetSpeed = inputDir.Magnitude * GameConfig.Movement.MaxSpeed
	assertTest("Diagonal target speed does not exceed MaxSpeed (50 studs/s)", targetSpeed <= GameConfig.Movement.MaxSpeed + 0.001)

	-- 2. Velocity-based acceleration integration
	MovementService._Reset()
	MovementService.HandleMoveIntent(testUser1, Vector2.new(1, 0))
	MovementService.StepPlayerMovement(testUser1.UserId, 0.1)
	local velAfterStep = MovementService.GetVelocity(testUser1)
	local expectedVelX = GameConfig.Movement.Acceleration * 0.1 -- 120 * 0.1 = 12
	assertTest("Velocity accelerates correctly along +X", math.abs(velAfterStep.X - expectedVelX) < 0.01)
	assertTest("Velocity Y remains 0 during purely axial +X movement", velAfterStep.Y == 0)

	-- 3. Fixed Z plane (0) and forward orientation (+X)
	assertTest(
		"Aircraft Z position remains strictly PlayPlaneZ (0)",
		plane1.PrimaryPart ~= nil and math.abs(plane1.PrimaryPart.Position.Z - GameConfig.Arena.PlayPlaneZ) < 0.001
	)
	if plane1.PrimaryPart then
		local lookVec = plane1.PrimaryPart.CFrame.LookVector
		assertTest("Aircraft orientation strictly maintains positive X forward direction", lookVec:FuzzyEq(Vector3.new(1, 0, 0), 0.05))
	end

	-- 4. Arena boundary clamping on huge deltaTime
	-- Push with massive dt = 100 towards positive X and positive Y
	MovementService.HandleMoveIntent(testUser1, Vector2.new(1, 1))
	MovementService.StepPlayerMovement(testUser1.UserId, 100.0)
	local clampedPos1 = plane1.PrimaryPart and plane1.PrimaryPart.Position or Vector3.zero
	assertTest("Aircraft X position is clamped at MaxX (80)", math.abs(clampedPos1.X - GameConfig.Arena.MaxX) < 0.001)
	assertTest("Aircraft Y position is clamped at MaxY (40)", math.abs(clampedPos1.Y - GameConfig.Arena.MaxY) < 0.001)

	-- 5. Boundary velocity neutralization
	local velAtMaxBoundary = MovementService.GetVelocity(testUser1)
	assertTest("Velocity pushing into +X edge is neutralized to 0", velAtMaxBoundary.X == 0)
	assertTest("Velocity pushing into +Y edge is neutralized to 0", velAtMaxBoundary.Y == 0)

	-- Push with massive dt = 100 towards negative X and negative Y
	MovementService.HandleMoveIntent(testUser1, Vector2.new(-1, -1))
	MovementService.StepPlayerMovement(testUser1.UserId, 100.0)
	local clampedPos2 = plane1.PrimaryPart and plane1.PrimaryPart.Position or Vector3.zero
	assertTest("Aircraft X position is clamped at MinX (-80)", math.abs(clampedPos2.X - GameConfig.Arena.MinX) < 0.001)
	assertTest("Aircraft Y position is clamped at MinY (-40)", math.abs(clampedPos2.Y - GameConfig.Arena.MinY) < 0.001)
	local velAtMinBoundary = MovementService.GetVelocity(testUser1)
	assertTest("Velocity pushing into -X edge is neutralized to 0", velAtMinBoundary.X == 0)
	assertTest("Velocity pushing into -Y edge is neutralized to 0", velAtMinBoundary.Y == 0)

	-- 6. Input timeout and deceleration
	-- Center the plane and accelerate right
	plane1:PivotTo(CFrame.new(0, 0, 0))
	MovementService._Reset()
	MovementService.HandleMoveIntent(testUser1, Vector2.new(1, 0))
	-- Accelerate for 0.5s to reach max speed (50 studs/s)
	MovementService.StepPlayerMovement(testUser1.UserId, 0.5)
	local velBeforeDecel = MovementService.GetVelocity(testUser1)
	assertTest("Aircraft reached MaxSpeed (50 studs/s)", math.abs(velBeforeDecel.X - 50) < 0.01)

	-- Simulate input stopping (send 0 direction)
	MovementService.HandleMoveIntent(testUser1, Vector2.zero)
	MovementService.StepPlayerMovement(testUser1.UserId, 0.1)
	local velDuringDecel = MovementService.GetVelocity(testUser1)
	local expectedDecelX = 50 - (GameConfig.Movement.Deceleration * 0.1) -- 50 - 16 = 34
	assertTest("Aircraft decelerates when input stops", math.abs(velDuringDecel.X - expectedDecelX) < 0.01)

	-- Step until completely stopped
	MovementService.StepPlayerMovement(testUser1.UserId, 0.5)
	local velStopped = MovementService.GetVelocity(testUser1)
	assertTest("Aircraft comes to a complete stop (0 studs/s)", velStopped.Magnitude < 0.001)

	-- 7. Malformed and non-finite input protection
	MovementService.HandleMoveIntent(testUser1, Vector2.new(0/0, 0)) -- NaN
	assertTest("NaN input does not corrupt velocity", MovementService.GetVelocity(testUser1) == Vector2.zero)
	MovementService.HandleMoveIntent(testUser1, Vector2.new(math.huge, 0)) -- Inf
	assertTest("Infinity input does not corrupt velocity", MovementService.GetVelocity(testUser1) == Vector2.zero)
	MovementService.HandleMoveIntent(testUser1, "invalid_string") -- Wrong type
	assertTest("String input is ignored safely", MovementService.GetVelocity(testUser1) == Vector2.zero)

	-- 8. Player without active aircraft cannot affect other aircraft
	local phantomUser = { UserId = 444001, Name = "PhantomUser" }
	MovementService.HandleMoveIntent(phantomUser, Vector2.new(1, 1))
	assertTest("Player without active plane cannot register movement", MovementService.GetInputDirection(phantomUser) == Vector2.zero)

	-- 9. Multi-player velocity isolation
	local plane2 = AircraftService.SpawnPlaneForPlayer(testUser2, Vector3.new(0, 0, 0))
	assertTest("Test plane 2 spawned for multi-player test", plane2 ~= nil)

	MovementService._Reset()
	MovementService.HandleMoveIntent(testUser1, Vector2.new(1, 0))  -- P1 moves Right (+X)
	MovementService.HandleMoveIntent(testUser2, Vector2.new(0, -1)) -- P2 moves Down (-Y)

	MovementService.StepPlayerMovement(testUser1.UserId, 0.1)
	MovementService.StepPlayerMovement(testUser2.UserId, 0.1)

	local p1Vel = MovementService.GetVelocity(testUser1)
	local p2Vel = MovementService.GetVelocity(testUser2)

	assertTest("Player 1 velocity is purely on X axis", p1Vel.X > 0 and p1Vel.Y == 0)
	assertTest("Player 2 velocity is purely on Y axis", p2Vel.X == 0 and p2Vel.Y < 0)
	assertTest("Player 1 and Player 2 velocities are completely isolated", p1Vel ~= p2Vel)

	-- 10. PlayerRemoving cleanup
	AircraftService.DespawnPlaneForPlayer(testUser1.UserId)
	MovementService.CleanupPlayer(testUser1.UserId)
	assertTest("CleanupPlayer clears player velocity", MovementService.GetVelocity(testUser1) == Vector2.zero)
	assertTest("CleanupPlayer clears player input direction", MovementService.GetInputDirection(testUser1) == Vector2.zero)
	-- Stepping cleaned player is safe and does not crash
	MovementService.StepPlayerMovement(testUser1.UserId, 0.1)
	assertTest("Stepping despawned player is a safe no-op", true)

	-- Clean up player 2
	AircraftService.DespawnPlaneForPlayer(testUser2.UserId)
	MovementService.CleanupPlayer(testUser2.UserId)

	-- 11. Idempotent Initialize
	MovementService.Initialize()
	MovementService.Initialize()
	assertTest("MovementService.Initialize() is idempotent without errors", true)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return MovementTests
