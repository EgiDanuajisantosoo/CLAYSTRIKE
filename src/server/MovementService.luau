--!strict
--[[
	MovementService.luau
	Authoritative server movement service for CLAYSTRIKE.
	Task: CLAY-004 (Implement Server-Validated 2.5D Movement)

	Enforces server-authoritative velocity integration, input timeout, boundary clamping,
	neutralized edge velocity, fixed Z-axis (PlayPlaneZ = 0), and strict +X forward orientation.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local AircraftService = require(script.Parent:WaitForChild("AircraftService"))

local MovementService = {}

type InputRecord = {
	direction: Vector2,
	lastReceived: number,
}

local playerInputs: { [number]: InputRecord } = {}
local playerVelocities: { [number]: Vector2 } = {}
local heartbeatConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil
local isInitialized = false

-- Test clock override for deterministic simulation
local customClockFn: (() -> number)? = nil

local function getTime(): number
	if customClockFn then
		return customClockFn()
	end
	return os.clock()
end

-- Helper to check finite numbers
local function isFiniteNumber(val: any): boolean
	return typeof(val) == "number" and val == val and math.abs(val) ~= math.huge
end

--[[
	Updates velocity towards target velocity using acceleration or deceleration.
]]
local function stepVelocity(currentVel: Vector2, targetVel: Vector2, dt: number): Vector2
	local diff = targetVel - currentVel
	local isAccelerating = targetVel.Magnitude > 0 and (currentVel:Dot(targetVel) >= 0)
	local rate = if isAccelerating then GameConfig.Movement.Acceleration else GameConfig.Movement.Deceleration
	local maxStep = rate * dt

	if diff.Magnitude <= maxStep then
		return targetVel
	else
		return currentVel + diff.Unit * maxStep
	end
end

--[[
	Simulates a single physics step for a player's aircraft.
	Updates velocity, clamps position, neutralizes boundary velocity, and moves plane model.
]]
function MovementService.StepPlayerMovement(userId: number, dt: number)
	local plane = AircraftService.GetPlaneByUserId(userId)
	if not plane or not plane.PrimaryPart or not plane.PrimaryPart:IsDescendantOf(workspace) then
		-- Clean up state if player has no active aircraft
		playerInputs[userId] = nil
		playerVelocities[userId] = nil
		return
	end

	local primaryPart = plane.PrimaryPart
	local currentPos = primaryPart.Position
	local currentVel = playerVelocities[userId] or Vector2.zero
	local inputRecord = playerInputs[userId]

	-- Check input timeout: decay to zero if no input received within timeout window
	local targetDir = Vector2.zero
	if inputRecord then
		if (getTime() - inputRecord.lastReceived) <= GameConfig.Movement.InputTimeout then
			targetDir = inputRecord.direction
		else
			inputRecord.direction = Vector2.zero
		end
	end

	-- Compute target velocity (magnitude capped strictly at MaxSpeed)
	local targetVel = targetDir * GameConfig.Movement.MaxSpeed

	-- Step velocity with frame delta
	local newVel = stepVelocity(currentVel, targetVel, dt)

	-- Integrate position on X and Y
	local newX = currentPos.X + newVel.X * dt
	local newY = currentPos.Y + newVel.Y * dt

	-- Boundary clamping
	local clampedX = math.clamp(newX, GameConfig.Arena.MinX, GameConfig.Arena.MaxX)
	local clampedY = math.clamp(newY, GameConfig.Arena.MinY, GameConfig.Arena.MaxY)

	-- Boundary velocity neutralization: Zero out velocity component driving into clamped edge
	local finalVelX = newVel.X
	local finalVelY = newVel.Y

	if (clampedX <= GameConfig.Arena.MinX and finalVelX < 0) or (clampedX >= GameConfig.Arena.MaxX and finalVelX > 0) then
		finalVelX = 0
	end
	if (clampedY <= GameConfig.Arena.MinY and finalVelY < 0) or (clampedY >= GameConfig.Arena.MaxY and finalVelY > 0) then
		finalVelY = 0
	end

	playerVelocities[userId] = Vector2.new(finalVelX, finalVelY)

	-- Fixed Z plane (0) and fixed +X forward orientation
	local targetPos = Vector3.new(clampedX, clampedY, GameConfig.Arena.PlayPlaneZ)
	local forwardCFrame = CFrame.lookAt(targetPos, targetPos + Vector3.new(1, 0, 0), Vector3.new(0, 1, 0))

	plane:PivotTo(forwardCFrame)
end

--[[
	Heartbeat simulation loop for all active player planes.
]]
local function onHeartbeat(dt: number)
	local allPlanes = AircraftService.GetAllPlanes()
	for userId, _ in pairs(allPlanes) do
		MovementService.StepPlayerMovement(userId, dt)
	end
end

--[[
	Receives and processes validated movement intent from RemoteManager.
	Validates direction, rejects malformed inputs, and updates player's input record.
]]
function MovementService.HandleMoveIntent(player: any, moveDirection: any)
	-- 1. Validate player identity
	local userId = if typeof(player) == "number" then player else (if typeof(player) == "table" or typeof(player) == "Instance" then player.UserId else nil)
	if not userId or typeof(userId) ~= "number" then
		return
	end

	-- 2. Verify player has an active aircraft
	local plane = AircraftService.GetPlaneByUserId(userId)
	if not plane then
		return
	end

	-- 3. Validate direction vector
	if typeof(moveDirection) ~= "Vector2" then
		return
	end

	if not isFiniteNumber(moveDirection.X) or not isFiniteNumber(moveDirection.Y) then
		return
	end

	-- 4. Normalize diagonal input so magnitude never exceeds 1.0
	local mag = moveDirection.Magnitude
	local normalizedDir = Vector2.zero
	if mag > 0 then
		if mag > 1.0 then
			normalizedDir = moveDirection.Unit
		else
			normalizedDir = moveDirection
		end
	end

	-- 5. Record input with current server timestamp
	playerInputs[userId] = {
		direction = normalizedDir,
		lastReceived = getTime(),
	}
end

--[[
	Returns current velocity for a player or userId (read-only query).
]]
function MovementService.GetVelocity(playerOrUserId: any): Vector2
	local userId = if typeof(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId
	return playerVelocities[userId] or Vector2.zero
end

--[[
	Returns current target direction for a player or userId.
]]
function MovementService.GetInputDirection(playerOrUserId: any): Vector2
	local userId = if typeof(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId
	local record = playerInputs[userId]
	return record and record.direction or Vector2.zero
end

--[[
	Cleans up movement state when a player leaves.
]]
function MovementService.CleanupPlayer(playerOrUserId: any)
	local userId = if typeof(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId
	playerInputs[userId] = nil
	playerVelocities[userId] = nil
end

--[[
	Returns true if MovementService is currently initialized.
]]
function MovementService.IsInitialized(): boolean
	return isInitialized
end

--[[
	Initializes MovementService.
	Connects to RunService.Heartbeat and Players.PlayerRemoving. Idempotent.
]]
function MovementService.Initialize()
	if isInitialized then
		warn("[MovementService] Initialize() called more than once; skipping duplicate initialization.")
		return
	end
	isInitialized = true

	heartbeatConnection = RunService.Heartbeat:Connect(onHeartbeat)

	playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
		MovementService.CleanupPlayer(player.UserId)
	end)

	print("[MovementService] Movement service initialized. Listening on Heartbeat.")
end

--[[
	Test helper to reset all movement states and custom clock.
]]
function MovementService._Reset()
	playerInputs = {}
	playerVelocities = {}
	customClockFn = nil
end

--[[
	Test helper to inject custom clock function for deterministic time testing.
]]
function MovementService._SetClock(fn: (() -> number)?)
	customClockFn = fn
end

--[[
	Test helper to manually override lastReceived timestamp for a player.
]]
function MovementService._SetLastReceived(userId: number, timestamp: number)
	if playerInputs[userId] then
		playerInputs[userId].lastReceived = timestamp
	else
		playerInputs[userId] = {
			direction = Vector2.zero,
			lastReceived = timestamp,
		}
	end
end

--[[
	Test helper to inspect internal connections.
]]
function MovementService._GetConnections(): (RBXScriptConnection?, RBXScriptConnection?)
	return heartbeatConnection, playerRemovingConnection
end

--[[
	Test helper to disconnect all connections and restore uninitialized state (for isolated tests).
]]
function MovementService._Teardown()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	if playerRemovingConnection then
		playerRemovingConnection:Disconnect()
		playerRemovingConnection = nil
	end
	isInitialized = false
	playerInputs = {}
	playerVelocities = {}
	customClockFn = nil
end

return MovementService
