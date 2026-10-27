--!strict
--[[
	MovementController.luau
	Client input controller and network throttler for 2.5D plane movement.
	Task: CLAY-004 (Implement Server-Validated 2.5D Movement) & CLAY-006 (Input Focus & Control Lifecycle)

	Samples WASD and Arrow key inputs, normalizes diagonal vectors, and transmits
	rate-bounded directional intent packets (20–25 Hz) to the server.
	Protects against stuck input when window focus is released or UI/chat text boxes are focused.
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local sharedGameConfig = SharedFolder:WaitForChild("GameConfig")
local GameConfig = require(sharedGameConfig)
if (GameConfig :: any).CONTRACT_VERSION == nil then
	GameConfig = require(sharedGameConfig:Clone())
end
local RemoteContracts = require(SharedFolder:WaitForChild("RemoteContracts"))

local MovementController = {}

local movePlaneRemote: RemoteEvent? = nil
local heartbeatConnection: RBXScriptConnection? = nil
local connections: { RBXScriptConnection } = {}
local isInitialized = false
local isEnabled = true
local isWindowFocused = true

-- Mock states for deterministic unit testing
local mockWindowFocus: boolean? = nil
local mockTextBoxFocus: boolean? = nil

local lastSentTime = 0
local lastSentDirection = Vector2.zero
local SEND_INTERVAL = 1 / GameConfig.Movement.InputSamplingRate -- 1 / 25 = 0.04s

--[[
	Transmits a neutral Vector2.zero payload immediately if the aircraft was actively moving.
	Ensures server deceleration begins without waiting for next sample period.
]]
local function flushNeutralInput()
	if not movePlaneRemote then
		return
	end

	if lastSentDirection.Magnitude > 0 then
		local now = os.clock()
		local payload = {
			contractVersion = GameConfig.CONTRACT_VERSION,
			clientTimestamp = now,
			moveDirection = Vector2.zero,
		}

		movePlaneRemote:FireServer(payload)
		lastSentTime = now
		lastSentDirection = Vector2.zero
	end
end

--[[
	Samples active keyboard input for 2.5D plane movement.
	Returns Vector2.zero if:
	- Controller is disabled
	- Window has lost focus (Alt-Tab, clicked out)
	- User is typing into a TextBox (Chat, GUI entry)
	Otherwise returns normalized (WASD / Arrow) directional vector.
]]
function MovementController.SampleRawInput(): Vector2
	if not isEnabled then
		return Vector2.zero
	end

	-- Window focus evaluation
	local effectiveFocus = if mockWindowFocus ~= nil then mockWindowFocus else isWindowFocused
	if not effectiveFocus then
		return Vector2.zero
	end

	-- UI / Chat focus evaluation
	local effectiveTyping = if mockTextBoxFocus ~= nil
		then mockTextBoxFocus
		else (UserInputService:GetFocusedTextBox() ~= nil)
	if effectiveTyping then
		return Vector2.zero
	end

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
	Resolves RemoteEvent, binds to RunService.Heartbeat, and listens to focus events. Idempotent.
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
	isEnabled = true
	isWindowFocused = true

	-- Bind Heartbeat loop
	local hb = RunService.Heartbeat:Connect(onHeartbeat)
	heartbeatConnection = hb
	table.insert(connections, hb)

	-- Bind window focus release (Alt-Tab, window unfocused)
	local focusLost = UserInputService.WindowFocusReleased:Connect(function()
		isWindowFocused = false
		flushNeutralInput()
	end)
	table.insert(connections, focusLost)

	-- Bind window focus restored
	local focusGained = UserInputService.WindowFocused:Connect(function()
		isWindowFocused = true
	end)
	table.insert(connections, focusGained)

	-- Bind UI TextBox focus (Chat or custom GUI opened)
	local tbFocus = UserInputService.TextBoxFocused:Connect(function()
		flushNeutralInput()
	end)
	table.insert(connections, tbFocus)

	print("[MovementController] Movement controller initialized with focus & lifecycle safety. Sampling at 25 Hz.")
end

--[[
	Returns true if MovementController is currently initialized.
]]
function MovementController.IsInitialized(): boolean
	return isInitialized
end

--[[
	Enables or disables movement input. Flushes neutral input if disabling while moving.
]]
function MovementController.SetEnabled(enabled: boolean)
	if isEnabled == enabled then
		return
	end
	isEnabled = enabled
	if not isEnabled then
		flushNeutralInput()
	end
end

--[[
	Returns true if movement input is currently enabled.
]]
function MovementController.IsEnabled(): boolean
	return isEnabled
end

--[[
	Returns true if the window currently has focus.
]]
function MovementController.IsWindowFocused(): boolean
	if mockWindowFocus ~= nil then
		return mockWindowFocus
	end
	return isWindowFocused
end

--[[
	Test/query helper to check current sampled direction.
]]
function MovementController.GetCurrentInput(): Vector2
	return MovementController.SampleRawInput()
end

--[[
	Test helper to inspect the last direction transmitted to the server.
]]
function MovementController.GetLastSentDirection(): Vector2
	return lastSentDirection
end

--[[
	Test helper to manually set the last sent direction (used to test flush behavior).
]]
function MovementController._SetLastSentDirection(dir: Vector2)
	lastSentDirection = dir
end

--[[
	Test helper to inspect heartbeat connection status.
]]
function MovementController._GetHeartbeatConnection(): RBXScriptConnection?
	return heartbeatConnection
end

--[[
	Test helper to inspect total active connection count.
]]
function MovementController._GetConnectionCount(): number
	return #connections
end

--[[
	Test helper to simulate window focus changes without OS-level Alt-Tab.
]]
function MovementController._SimulateWindowFocus(focused: boolean)
	mockWindowFocus = focused
	if not focused then
		flushNeutralInput()
	end
end

--[[
	Test helper to simulate UI text entry focus.
]]
function MovementController._SimulateTextBoxFocus(focused: boolean)
	mockTextBoxFocus = focused
	if focused then
		flushNeutralInput()
	end
end

--[[
	Cleans up MovementController: flushes neutral input, disconnects all event listeners.
]]
function MovementController._Teardown()
	flushNeutralInput()
	for _, conn in ipairs(connections) do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	connections = {}
	heartbeatConnection = nil
	isInitialized = false
	isEnabled = true
	isWindowFocused = true
	mockWindowFocus = nil
	mockTextBoxFocus = nil
	movePlaneRemote = nil
	lastSentTime = 0
	lastSentDirection = Vector2.zero
end

return MovementController
