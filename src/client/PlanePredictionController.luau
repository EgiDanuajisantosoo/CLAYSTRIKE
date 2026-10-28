--!strict
--[[
	PlanePredictionController.luau
	Client-side prediction, reconciliation, and remote aircraft interpolation for CLAYSTRIKE.
	Task: CLAY-007 (Client Prediction & Remote Plane Interpolation)

	RESPONSIBILITIES:
	1. Local Client Prediction:
	   - Simulates local aircraft movement immediately from player input intent using identical
	     kinematics as MovementService (Acceleration, Deceleration, MaxSpeed, Arena bounds).
	   - Eliminates perceived control latency (zero input lag) under moderate to high ping.
	2. Smooth Reconciliation:
	   - Reconciles predicted position against authoritative server updates replicated via ActivePlanes.
	   - Smooth exponential decay blending for minor discrepancies (< SNAP_THRESHOLD = 5.0 studs).
	   - Immediate hard snap for teleports, respawns, or large divergent errors (>= SNAP_THRESHOLD).
	3. Remote Plane Interpolation:
	   - Tracks co-op teammates' aircraft transforms replicated in Workspace.ActivePlanes.
	   - Smoothly interpolates positions and orientations (REMOTE_LERP_SPEED = 20.0), eliminating network jitter.
	   - Graceful fallback: holds position smoothly if remote packets stall (> REMOTE_TIMEOUT = 1.0s).
	4. Strict Server Authoritativeness:
	   - Client never sends position coordinates to server; only inputs (moveDirection).
	   - Server remains authoritative for collisions, damage, boundaries, and canonical coordinates.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local sharedGameConfig = SharedFolder:WaitForChild("GameConfig")
local GameConfig = require(sharedGameConfig)
if (GameConfig :: any).CONTRACT_VERSION == nil then
	GameConfig = require(sharedGameConfig:Clone())
end

local MovementController = require(script.Parent:WaitForChild("MovementController"))

export type RemotePlaneRecord = {
	model: Model,
	primaryPart: BasePart,
	currentRenderPos: Vector3,
	targetServerPos: Vector3,
	lastUpdateTime: number,
}

local PlanePredictionController = {}

-- Tunable configuration constants
PlanePredictionController.SNAP_THRESHOLD = 5.0 -- Studs error threshold before hard snap
PlanePredictionController.RECONCILIATION_SPEED = 15.0 -- Exponential decay rate for local reconciliation
PlanePredictionController.REMOTE_LERP_SPEED = 20.0 -- Exponential lerp rate for remote planes
PlanePredictionController.REMOTE_TIMEOUT = 1.0 -- Seconds before considering remote update stale

-- Runtime state
local isInitialized = false
local renderConn: RBXScriptConnection? = nil
local activeFolder: Folder? = nil

-- Local prediction state
local localUserId = 0
local predictedVelocity = Vector2.zero
local predictedPosition = Vector3.new(0, 0, GameConfig.Arena.PlayPlaneZ)
local isLocalPositionInitialized = false

-- Remote aircraft tracking state
local remotePlanes: { [number]: RemotePlaneRecord } = {}

-- Helper to retrieve ActivePlanes folder in Workspace
local function getActivePlanesFolder(): Folder?
	if activeFolder and activeFolder.Parent == Workspace then
		return activeFolder
	end
	local folder = Workspace:FindFirstChild("ActivePlanes")
	if folder and folder:IsA("Folder") then
		activeFolder = folder
		return folder
	end
	return nil
end

--[[
	Pure kinematic step function (matching server MovementService).
	Computes new velocity and position given current state, input, and delta time.
]]
function PlanePredictionController.PredictKinematicStep(
	currentPos: Vector3,
	currentVel: Vector2,
	inputDir: Vector2,
	dt: number
): (Vector3, Vector2)
	local targetVel = inputDir * GameConfig.Movement.MaxSpeed

	-- Step velocity
	local diff = targetVel - currentVel
	local isAccelerating = targetVel.Magnitude > 0 and (currentVel:Dot(targetVel) >= 0)
	local rate = if isAccelerating then GameConfig.Movement.Acceleration else GameConfig.Movement.Deceleration
	local maxStep = rate * dt

	local newVel: Vector2
	if diff.Magnitude <= maxStep then
		newVel = targetVel
	else
		newVel = currentVel + diff.Unit * maxStep
	end

	-- Integrate position
	local newX = currentPos.X + newVel.X * dt
	local newY = currentPos.Y + newVel.Y * dt

	-- Boundary clamping
	local clampedX = math.clamp(newX, GameConfig.Arena.MinX, GameConfig.Arena.MaxX)
	local clampedY = math.clamp(newY, GameConfig.Arena.MinY, GameConfig.Arena.MaxY)

	-- Neutralize edge velocity
	local finalVelX = newVel.X
	local finalVelY = newVel.Y
	if (clampedX <= GameConfig.Arena.MinX and finalVelX < 0) or (clampedX >= GameConfig.Arena.MaxX and finalVelX > 0) then
		finalVelX = 0
	end
	if (clampedY <= GameConfig.Arena.MinY and finalVelY < 0) or (clampedY >= GameConfig.Arena.MaxY and finalVelY > 0) then
		finalVelY = 0
	end

	local finalPos = Vector3.new(clampedX, clampedY, GameConfig.Arena.PlayPlaneZ)
	return finalPos, Vector2.new(finalVelX, finalVelY)
end

--[[
	Pure reconciliation function.
	Smooths predicted position towards server authoritative position without popping.
]]
function PlanePredictionController.ReconcilePosition(
	predictedPos: Vector3,
	serverPos: Vector3,
	dt: number
): Vector3
	local errorOffset = serverPos - predictedPos
	local errorMagnitude = errorOffset.Magnitude

	if errorMagnitude >= PlanePredictionController.SNAP_THRESHOLD then
		-- Hard snap on large discrepancy (respawn, teleport, major desync)
		return serverPos
	elseif errorMagnitude > 0.001 then
		-- Smooth exponential convergence
		local blendFactor = 1 - math.exp(-PlanePredictionController.RECONCILIATION_SPEED * dt)
		return predictedPos + (errorOffset * blendFactor)
	else
		return predictedPos
	end
end

--[[
	Pure remote plane interpolation step.
	Interpolates current rendered position towards latest target server position.
]]
function PlanePredictionController.InterpolateRemotePosition(
	currentPos: Vector3,
	targetPos: Vector3,
	timeSinceLastUpdate: number,
	dt: number
): Vector3
	if timeSinceLastUpdate > PlanePredictionController.REMOTE_TIMEOUT then
		-- Delayed/stale fallback: hold current position cleanly
		return currentPos
	end

	local blendFactor = 1 - math.exp(-PlanePredictionController.REMOTE_LERP_SPEED * dt)
	return currentPos:Lerp(targetPos, blendFactor)
end

--[[
	Main simulation step invoked on RenderStepped.
	Updates local prediction, reconciliation, and all remote aircraft interpolation.
]]
function PlanePredictionController.Step(dt: number)
	if dt <= 0 then
		return
	end

	local folder = getActivePlanesFolder()
	if not folder then
		return
	end

	local now = os.clock()

	-- 1. Locate local player's aircraft model
	local localPlaneName = string.format("Plane_%d", localUserId)
	local localPlane = folder:FindFirstChild(localPlaneName)

	if localPlane and localPlane:IsA("Model") and localPlane.PrimaryPart then
		local primary = localPlane.PrimaryPart
		local serverPos = primary.Position

		if not isLocalPositionInitialized then
			predictedPosition = serverPos
			predictedVelocity = Vector2.zero
			isLocalPositionInitialized = true
		end

		-- Sample current raw input
		local inputDir = MovementController.SampleRawInput()

		-- Predict forward locally
		local nextPredictedPos, nextVel = PlanePredictionController.PredictKinematicStep(
			predictedPosition,
			predictedVelocity,
			inputDir,
			dt
		)
		predictedVelocity = nextVel

		-- Reconcile against replicated server position
		predictedPosition = PlanePredictionController.ReconcilePosition(nextPredictedPos, serverPos, dt)

		-- Calculate subtle clay banking tilt based on vertical movement velocity (+/- 12 degrees)
		local maxTiltRad = math.rad(12)
		local targetTilt = math.clamp(predictedVelocity.Y / GameConfig.Movement.MaxSpeed, -1, 1) * maxTiltRad
		local currentTilt = localPlane:GetAttribute("BankTilt") :: number? or 0
		local nextTilt = currentTilt + (targetTilt - currentTilt) * (1 - math.exp(-12 * dt))
		localPlane:SetAttribute("BankTilt", nextTilt)

		-- Apply visual transform (+X forward facing, with banking tilt around Z flight axis)
		local lookTarget = predictedPosition + Vector3.new(1, 0, 0)
		local baseCf = CFrame.lookAt(predictedPosition, lookTarget, Vector3.new(0, 1, 0))
		local bankedCf = baseCf * CFrame.Angles(0, 0, nextTilt)
		localPlane:PivotTo(bankedCf)
	else
		isLocalPositionInitialized = false
	end

	-- 2. Process remote aircraft interpolation
	local activeRemoteIds: { [number]: boolean } = {}

	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") and child.PrimaryPart and child.Name ~= localPlaneName then
			local numStr = string.match(child.Name, "Plane_(%d+)")
			if numStr then
				local remoteUserId = tonumber(numStr) :: number
				activeRemoteIds[remoteUserId] = true

				local serverTarget = child.PrimaryPart.Position
				local record = remotePlanes[remoteUserId]

				if not record or record.model ~= child then
					record = {
						model = child,
						primaryPart = child.PrimaryPart,
						currentRenderPos = serverTarget,
						targetServerPos = serverTarget,
						lastUpdateTime = now,
					}
					remotePlanes[remoteUserId] = record
				else
					if (serverTarget - record.targetServerPos).Magnitude > 0.001 then
						record.targetServerPos = serverTarget
						record.lastUpdateTime = now
					end
				end

				-- Interpolate
				local timeSinceUpdate = now - record.lastUpdateTime
				local newRenderPos = PlanePredictionController.InterpolateRemotePosition(
					record.currentRenderPos,
					record.targetServerPos,
					timeSinceUpdate,
					dt
				)
				record.currentRenderPos = newRenderPos

				-- Apply visual transform (+X forward facing)
				local lookTarget = newRenderPos + Vector3.new(1, 0, 0)
				local cf = CFrame.lookAt(newRenderPos, lookTarget, Vector3.new(0, 1, 0))
				child:PivotTo(cf)
			end
		end
	end

	-- Clean up despawned remote plane records
	for uId, _ in pairs(remotePlanes) do
		if not activeRemoteIds[uId] then
			remotePlanes[uId] = nil
		end
	end
end

--[[
	Initializes PlanePredictionController and binds to RunService.PreRender (or RenderStepped).
	Idempotent.
]]
function PlanePredictionController.Initialize()
	if isInitialized then
		return
	end
	isInitialized = true

	local localPlayer = Players.LocalPlayer
	if localPlayer then
		localUserId = localPlayer.UserId
	end

	if RunService:IsClient() then
		renderConn = RunService.PreRender:Connect(function(dt: number)
			PlanePredictionController.Step(dt)
		end)
	end

	print("[PlanePredictionController] Client prediction and remote interpolation initialized.")
end

--[[
	Returns true if PlanePredictionController is initialized.
]]
function PlanePredictionController.IsInitialized(): boolean
	return isInitialized
end

--[[
	Test/State inspection helpers
]]
function PlanePredictionController.GetPredictedPosition(): Vector3
	return predictedPosition
end

function PlanePredictionController.GetPredictedVelocity(): Vector2
	return predictedVelocity
end

function PlanePredictionController.SetPredictedPosition(pos: Vector3)
	predictedPosition = pos
	isLocalPositionInitialized = true
end

function PlanePredictionController.SetPredictedVelocity(vel: Vector2)
	predictedVelocity = vel
end

function PlanePredictionController.GetRemotePlaneRecord(userId: number): RemotePlaneRecord?
	return remotePlanes[userId]
end

function PlanePredictionController.SetLocalUserId(userId: number)
	localUserId = userId
end

--[[
	Tears down controller, cleans up connections and tracking state.
]]
function PlanePredictionController._Teardown()
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end

	remotePlanes = {}
	predictedVelocity = Vector2.zero
	predictedPosition = Vector3.new(0, 0, GameConfig.Arena.PlayPlaneZ)
	isLocalPositionInitialized = false
	isInitialized = false
	activeFolder = nil
end

return PlanePredictionController
