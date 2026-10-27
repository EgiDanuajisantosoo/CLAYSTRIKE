--!strict
--[[
	MovementController.luau
	Client input controller and network throttler for 2.5D plane movement.
	Task: CLAY-004 (Implement Server-Validated 2.5D Movement)

	Samples WASD and Arrow key inputs, normalizes diagonal vectors, and transmits
	rate-bounded directional intent packets (20–25 Hz) to the server.
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local RemoteContracts = require(SharedFolder:WaitForChild("RemoteContracts"))

local MovementController = {}

local movePlaneRemote: RemoteEvent? = nil
local isInitialized = false

local lastSentTime = 0
local lastSentDirection = Vector2.zero
local SEND_INTERVAL = 1 / GameConfig.Movement.InputSamplingRate -- 1 / 25 = 0.04s

--[[
	Samples active keyboard input for 2.5D plane movement.
	X: Left (-1) / Right (+1)
	Y: Down (-1) / Up (+1)
]]
function MovementController.SampleRawInput(): Vector2
	local moveX = 0
	local moveY = 0

	if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then
		moveX -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then
		moveX += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up) then
		moveY += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down) then
		moveY -= 1
	end

	local raw = Vector2.new(moveX, moveY)
	-- Normalize diagonal input so diagonal movement is not faster than axial
	if raw.Magnitude > 1.0 then
		return raw.Unit
	end
	return raw
end

--[[
	Heartbeat tick loop: transmits directional intent at bounded 25 Hz rate.
]]
local function onHeartbeat()
	if not movePlaneRemote then
		return
	end

	local now = os.clock()
	if now - lastSentTime < SEND_INTERVAL then
		return
	end

	local currentDirection = MovementController.SampleRawInput()

	-- Only transmit if actively moving OR if sending the final zero vector to stop
	local isMoving = currentDirection.Magnitude > 0
	local wasMoving = lastSentDirection.Magnitude > 0

	if isMoving or wasMoving then
		local payload = {
			contractVersion = GameConfig.CONTRACT_VERSION,
			clientTimestamp = now,
			moveDirection = currentDirection,
		}

		movePlaneRemote:FireServer(payload)
		lastSentTime = now
		lastSentDirection = currentDirection
	end
end

--[[
	Initializes the movement controller.
	Resolves RemoteEvent and binds to RunService.Heartbeat. Idempotent.
]]
function MovementController.Initialize()
	if isInitialized then
		warn("[MovementController] Initialize() already called; skipping duplicate setup.")
		return
	end

	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
	local remoteInstance = remotesFolder:WaitForChild(RemoteContracts.RemoteNames.MovePlane, 5)
	if not remoteInstance or not remoteInstance:IsA("RemoteEvent") then
		error("[MovementController] Failed to resolve MovePlane RemoteEvent.")
	end

	movePlaneRemote = remoteInstance :: RemoteEvent
	isInitialized = true

	RunService.Heartbeat:Connect(onHeartbeat)
	print("[MovementController] Movement controller initialized. Sampling input at 25 Hz.")
end

--[[
	Test/query helper to check current sampled direction.
]]
function MovementController.GetCurrentInput(): Vector2
	return MovementController.SampleRawInput()
end

return MovementController
