--!strict
--[[
	MovementLifecycleTests.luau
	Unit test harness for client input focus and control lifecycle.
	Task: CLAY-006 (Input Focus & Control Lifecycle)

	Validates:
	1. Neutral input guarantee when window focus is released (Alt-Tab protection).
	2. Neutral input guarantee when typing into UI text boxes (Chat / GUI protection).
	3. Instant neutral packet flush when focus is lost or typing begins while moving.
	4. Disable / enable toggle lifecycle and neutral flush on disable.
	5. Idempotent initialization without duplicate event connections.
	6. Comprehensive teardown and connection disconnection.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local sharedGameConfig = SharedFolder:WaitForChild("GameConfig")
local GameConfig = require(sharedGameConfig)
if (GameConfig :: any).CONTRACT_VERSION == nil then
	GameConfig = require(sharedGameConfig:Clone())
end

local MovementLifecycleTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function MovementLifecycleTests.RunTests(movementControllerModule: any?): {
	total: number,
	passed: number,
	failed: number,
	results: { [number]: TestResult },
}
	local MovementController = movementControllerModule
	if not MovementController then
		local StarterPlayer = game:GetService("StarterPlayer")
		local controllers = StarterPlayer.StarterPlayerScripts:WaitForChild("Controllers")
		MovementController = require(controllers:WaitForChild("MovementController"))
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
			warn(string.format("[MovementLifecycleTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes") :: Folder?
	if not remotesFolder then
		local newFolder = Instance.new("Folder")
		newFolder.Name = "Remotes"
		newFolder.Parent = ReplicatedStorage
		remotesFolder = newFolder
	end

	local createdMockRemote = false
	local existingRemote = remotesFolder:FindFirstChild("MovePlane")
	if not existingRemote then
		local mockRemote = Instance.new("RemoteEvent")
		mockRemote.Name = "MovePlane"
		mockRemote.Parent = remotesFolder
		createdMockRemote = true
	end

	-- Setup clean baseline
	MovementController._Teardown()
	assertTest("Controller starts uninitialized after teardown", MovementController.IsInitialized() == false)
	assertTest("Active connection count is 0 before initialization", MovementController._GetConnectionCount() == 0)

	-- 1. Initialize and verify connection allocation
	MovementController.Initialize()
	assertTest("Controller is initialized", MovementController.IsInitialized() == true)
	assertTest("Controller registers exactly 4 event connections", MovementController._GetConnectionCount() == 4)
	assertTest("Heartbeat connection is active", MovementController._GetHeartbeatConnection() ~= nil and MovementController._GetHeartbeatConnection().Connected == true)

	-- 2. Idempotency check: duplicate Initialize() must not add duplicate connections
	MovementController.Initialize()
	assertTest("Duplicate Initialize() preserves exactly 4 connections", MovementController._GetConnectionCount() == 4)

	-- 3. Window focus handling
	assertTest("Window focus defaults to true", MovementController.IsWindowFocused() == true)

	-- Simulate moving plane, then window focus loss
	MovementController._SetLastSentDirection(Vector2.new(1, 0))
	assertTest("Setup: plane was moving prior to focus loss", MovementController.GetLastSentDirection() == Vector2.new(1, 0))

	MovementController._SimulateWindowFocus(false)
	assertTest("Window focus reports false after simulation", MovementController.IsWindowFocused() == false)
	assertTest("SampleRawInput returns Vector2.zero when window unfocused", MovementController.SampleRawInput() == Vector2.zero)
	assertTest("Focus loss immediately flushed moving state to neutral Vector2.zero", MovementController.GetLastSentDirection() == Vector2.zero)

	-- Restore focus
	MovementController._SimulateWindowFocus(true)
	assertTest("Window focus reports true after restoration", MovementController.IsWindowFocused() == true)

	-- 4. UI / Chat TextBox focus handling
	-- Simulate moving plane, then TextBox focus (user types in chat)
	MovementController._SetLastSentDirection(Vector2.new(0, 1))
	assertTest("Setup: plane was moving prior to textbox focus", MovementController.GetLastSentDirection() == Vector2.new(0, 1))

	MovementController._SimulateTextBoxFocus(true)
	assertTest("SampleRawInput returns Vector2.zero when TextBox is focused", MovementController.SampleRawInput() == Vector2.zero)
	assertTest("TextBox focus immediately flushed moving state to neutral Vector2.zero", MovementController.GetLastSentDirection() == Vector2.zero)

	-- Release TextBox focus
	MovementController._SimulateTextBoxFocus(false)

	-- 5. Enable / Disable toggle lifecycle
	assertTest("Controller defaults to enabled", MovementController.IsEnabled() == true)

	MovementController._SetLastSentDirection(Vector2.new(-1, 0))
	MovementController.SetEnabled(false)
	assertTest("Controller reports disabled", MovementController.IsEnabled() == false)
	assertTest("SampleRawInput returns Vector2.zero when disabled", MovementController.SampleRawInput() == Vector2.zero)
	assertTest("Disabling controller immediately flushed moving state to neutral Vector2.zero", MovementController.GetLastSentDirection() == Vector2.zero)

	MovementController.SetEnabled(true)
	assertTest("Controller re-enabled successfully", MovementController.IsEnabled() == true)

	-- 6. Comprehensive Teardown
	local prevHeartbeat = MovementController._GetHeartbeatConnection()
	MovementController._Teardown()
	assertTest("Controller reports uninitialized after _Teardown()", MovementController.IsInitialized() == false)
	assertTest("Active connection count is reset to 0 after _Teardown()", MovementController._GetConnectionCount() == 0)
	assertTest("Previous heartbeat connection was cleanly disconnected", prevHeartbeat ~= nil and prevHeartbeat.Connected == false)
	assertTest("Controller is re-enabled by default for next session", MovementController.IsEnabled() == true)

	-- Reinitialize for live client usage
	MovementController.Initialize()

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return MovementLifecycleTests
