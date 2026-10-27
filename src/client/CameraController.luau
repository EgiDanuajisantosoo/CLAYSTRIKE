--!strict
--[[
	CameraController.luau
	Client 2.5D side-scrolling camera controller for CLAYSTRIKE.
	Task: CLAY-005 (Implement Side Camera Follow)

	Provides a stable, frame-rate independent side-on camera looking along -Z toward
	the 2.5D play plane (Z = 0). Tracks the local player's aircraft with exponential
	smoothing and look-ahead, strictly isolates subject acquisition to the local player,
	and safely handles plane spawn/despawn transitions without visual jitter.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))

local CameraController = {}

local RENDER_STEP_NAME = "CLAYSTRIKE_SideCamera"

local isInitialized = false
local currentSmoothedPos: Vector3? = nil
local subjectOverride: Model? = nil
local isSubjectOverridden = false
local currentCameraChangedConn: RBXScriptConnection? = nil

--[[
	Resolves the active aircraft Model belonging strictly to the local player.
	Guarantees the camera never targets another player's aircraft in co-op.
]]
function CameraController.GetSubject(): Model?
	if isSubjectOverridden then
		return subjectOverride
	end

	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return nil
	end

	local activePlanesFolder = Workspace:FindFirstChild("ActivePlanes")
	if not activePlanesFolder then
		return nil
	end

	-- Look up by canonical name Plane_<UserId>
	local plane = activePlanesFolder:FindFirstChild(string.format("Plane_%d", localPlayer.UserId))
	if plane and plane:IsA("Model") and plane.PrimaryPart and plane:IsDescendantOf(Workspace) then
		-- Double-check authoritative OwnerUserId attribute
		local ownerId = plane:GetAttribute("OwnerUserId")
		if ownerId == localPlayer.UserId then
			return plane
		end
	end

	return nil
end

--[[
	Computes the target framing position based on local aircraft state or fallback center.
]]
local function computeTargetPosition(): Vector3
	local subject = CameraController.GetSubject()
	local targetX = 0
	local targetY = 0

	if subject and subject.PrimaryPart then
		local rootPos = subject.PrimaryPart.Position
		targetX = rootPos.X + GameConfig.Camera.LookAheadX
		targetY = rootPos.Y
	elseif currentSmoothedPos then
		-- When plane despawns or before spawn, hold last smoothed position (decay toward center)
		targetX = currentSmoothedPos.X
		targetY = currentSmoothedPos.Y
	end

	-- Clamp framing position to arena camera bounds
	local clampedX = math.clamp(targetX, GameConfig.Camera.MinX, GameConfig.Camera.MaxX)
	local clampedY = math.clamp(targetY, GameConfig.Camera.MinY, GameConfig.Camera.MaxY)
	local cameraZ = GameConfig.Arena.PlayPlaneZ + GameConfig.Camera.Distance

	return Vector3.new(clampedX, clampedY, cameraZ)
end

--[[
	Single-step camera update calculation.
	Uses frame-rate independent exponential decay:
	alpha = 1 - math.exp(-FollowSmoothness * dt)
	@param dt Frame delta time in seconds.
	@return The computed camera CFrame for this step.
]]
function CameraController.StepCamera(dt: number): CFrame
	local targetPos = computeTargetPosition()

	if not currentSmoothedPos then
		currentSmoothedPos = targetPos
	else
		local safeDt = math.clamp(dt, 0.001, 0.2)
		local alpha = 1 - math.exp(-GameConfig.Camera.FollowSmoothness * safeDt)
		currentSmoothedPos = currentSmoothedPos:Lerp(targetPos, alpha)
	end

	-- Perpendicular side-on orientation looking strictly down -Z toward play plane Z = 0
	local eye = currentSmoothedPos
	local lookTarget = Vector3.new(eye.X, eye.Y, GameConfig.Arena.PlayPlaneZ)
	local upVector = Vector3.new(0, 1, 0)

	local camCFrame = CFrame.lookAt(eye, lookTarget, upVector)

	local camera = Workspace.CurrentCamera
	if camera then
		if camera.CameraType ~= Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Scriptable
		end
		if camera.FieldOfView ~= GameConfig.Camera.FieldOfView then
			camera.FieldOfView = GameConfig.Camera.FieldOfView
		end
		camera.CFrame = camCFrame
		camera.Focus = CFrame.new(lookTarget)
	end

	return camCFrame
end

--[[
	RenderStep loop callback.
]]
local function onRenderStep(dt: number)
	CameraController.StepCamera(dt)
end

--[[
	Initializes the CameraController.
	Sets CameraType to Scriptable, configures FOV, and binds to RenderStep. Idempotent.
]]
function CameraController.Initialize()
	if isInitialized then
		warn("[CameraController] Initialize() called more than once; skipping duplicate setup.")
		return
	end
	isInitialized = true

	local camera = Workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = GameConfig.Camera.FieldOfView
	end

	currentCameraChangedConn = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local newCam = Workspace.CurrentCamera
		if newCam then
			newCam.CameraType = Enum.CameraType.Scriptable
			newCam.FieldOfView = GameConfig.Camera.FieldOfView
		end
	end)

	RunService:BindToRenderStep(
		RENDER_STEP_NAME,
		Enum.RenderPriority.Camera.Value,
		onRenderStep
	)

	print("[CameraController] Side-scroller camera controller initialized (Scriptable, FOV: " .. GameConfig.Camera.FieldOfView .. ").")
end

--[[
	Returns true if CameraController is currently initialized.
]]
function CameraController.IsInitialized(): boolean
	return isInitialized
end

--[[
	Returns the current smoothed camera position.
]]
function CameraController.GetSmoothedPosition(): Vector3?
	return currentSmoothedPos
end

--[[
	Test helper to override subject resolution for deterministic mocking.
]]
function CameraController._SetSubjectOverride(mockPlane: Model?)
	isSubjectOverridden = true
	subjectOverride = mockPlane
end

--[[
	Test helper to reset subject override to normal local player lookup.
]]
function CameraController._ClearSubjectOverride()
	isSubjectOverridden = false
	subjectOverride = nil
end

--[[
	Test helper to unbind render step and restore uninitialized state (for clean test isolation).
]]
function CameraController._Teardown()
	if isInitialized then
		pcall(function()
			RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		end)
	end
	if currentCameraChangedConn then
		currentCameraChangedConn:Disconnect()
		currentCameraChangedConn = nil
	end
	isInitialized = false
	currentSmoothedPos = nil
	isSubjectOverridden = false
	subjectOverride = nil
end

return CameraController
