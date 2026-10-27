--!strict
--[[
	WeaponControllerTests.luau
	Unit test harness for client weapon input, firing loop cadence, and focus safety.
	Task: CLAY-010 (Standard Weapon Firing Loop)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local sharedWeaponConfig = SharedFolder:WaitForChild("WeaponConfig")
local WeaponConfig = require(sharedWeaponConfig)
if (WeaponConfig :: any).Weapons == nil then
	WeaponConfig = require(sharedWeaponConfig:Clone())
end

local WeaponControllerTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function WeaponControllerTests.RunTests(weaponControllerModule: any?): {
	total: number,
	passed: number,
	failed: number,
	results: { [number]: TestResult },
}
	local WeaponController = weaponControllerModule
	if not WeaponController then
		local StarterPlayer = game:GetService("StarterPlayer")
		local controllers = StarterPlayer.StarterPlayerScripts:WaitForChild("Controllers")
		WeaponController = require(controllers:WaitForChild("WeaponController"))
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
			warn(string.format("[WeaponControllerTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Ensure Remotes.FireWeapon exists
	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes") :: Folder?
	if not remotesFolder then
		local newFolder = Instance.new("Folder")
		newFolder.Name = "Remotes"
		newFolder.Parent = ReplicatedStorage
		remotesFolder = newFolder
	end

	local existingRemote = remotesFolder:FindFirstChild("FireWeapon")
	if not existingRemote then
		local mockRemote = Instance.new("RemoteEvent")
		mockRemote.Name = "FireWeapon"
		mockRemote.Parent = remotesFolder
	end

	-- Clean baseline teardown
	WeaponController._Teardown()
	assertTest("WeaponController is uninitialized after teardown", WeaponController.IsInitialized() == false)
	assertTest("Connection count is 0 before initialization", WeaponController._GetConnectionCount() == 0)

	-- 1. Initialize and verify connections
	WeaponController.Initialize()
	assertTest("WeaponController is initialized", WeaponController.IsInitialized() == true)
	assertTest("WeaponController registers exactly 7 event connections", WeaponController._GetConnectionCount() == 7)

	-- 2. Idempotent initialization
	WeaponController.Initialize()
	assertTest("Duplicate Initialize() preserves exactly 7 connections", WeaponController._GetConnectionCount() == 7)

	-- 3. Holding fire cadence test (virtual time steps)
	WeaponController.StartFiring()
	assertTest("IsFiring() returns true when fire started", WeaponController.IsFiring() == true)

	-- Step at t = 100.0 (Shot 1)
	WeaponController.StepFiring(100.0)
	assertTest("First shot fired at t = 100.0 (count = 1)", WeaponController.GetLocalShotCount() == 1)

	-- Step at t = 100.05 (Cooldown 0.2s not met) -> Should not fire
	WeaponController.StepFiring(100.05)
	assertTest("Shot within cooldown (t = 100.05) was throttled by cadence gate", WeaponController.GetLocalShotCount() == 1)

	-- Step at t = 100.19 (Cooldown still not met)
	WeaponController.StepFiring(100.19)
	assertTest("Shot at t = 100.19 was throttled by cadence gate", WeaponController.GetLocalShotCount() == 1)

	-- Step at t = 100.21 (Cooldown 0.2s met) -> Shot 2
	WeaponController.StepFiring(100.21)
	assertTest("Shot fired at t = 100.21 after cooldown elapsed (count = 2)", WeaponController.GetLocalShotCount() == 2)

	-- Step at t = 100.42 -> Shot 3
	WeaponController.StepFiring(100.42)
	assertTest("Shot fired at t = 100.42 after cooldown elapsed (count = 3)", WeaponController.GetLocalShotCount() == 3)

	-- 4. Releasing fire stops new shot requests
	WeaponController.StopFiring()
	assertTest("IsFiring() returns false after fire stopped", WeaponController.IsFiring() == false)

	WeaponController.StepFiring(100.70)
	assertTest("No shot fired when fire is released (count remains 3)", WeaponController.GetLocalShotCount() == 3)

	-- 5. Window focus loss stops firing loop
	assertTest("Window focus initially reports true", WeaponController.IsWindowFocused() == true)
	WeaponController.StartFiring()
	WeaponController._SimulateWindowFocus(false)
	assertTest("Simulated window focus loss resets IsFiring() to false", WeaponController.IsFiring() == false)
	assertTest("IsWindowFocused() reports false when window focus lost", WeaponController.IsWindowFocused() == false)

	WeaponController.StepFiring(101.0)
	assertTest("No shot fired while window is unfocused (count remains 3)", WeaponController.GetLocalShotCount() == 3)
	WeaponController._SimulateWindowFocus(true)
	assertTest("IsWindowFocused() reports true after focus restored", WeaponController.IsWindowFocused() == true)
	WeaponController._SimulateWindowFocus(nil)
	assertTest("IsWindowFocused() falls back to isWindowFocused without error", WeaponController.IsWindowFocused() == true)

	-- 6. UI TextBox focus stops firing loop
	WeaponController.StartFiring()
	WeaponController._SimulateTextBoxFocus(true)
	assertTest("Simulated TextBox focus resets IsFiring() to false", WeaponController.IsFiring() == false)

	WeaponController.StepFiring(101.5)
	assertTest("No shot fired while TextBox is focused (count remains 3)", WeaponController.GetLocalShotCount() == 3)
	WeaponController._SimulateTextBoxFocus(false)

	-- 7. Teardown
	WeaponController._Teardown()
	assertTest("WeaponController is uninitialized after _Teardown()", WeaponController.IsInitialized() == false)
	assertTest("Active connections reset to 0 after _Teardown()", WeaponController._GetConnectionCount() == 0)

	-- Reinitialize for live client
	WeaponController.Initialize()

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return WeaponControllerTests
