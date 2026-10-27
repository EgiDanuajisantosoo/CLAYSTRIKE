--!strict
--[[
	WeaponServiceTests.luau
	Authoritative unit test harness for server combat weapon cadence, cooldowns, and projectile generation.
	Task: CLAY-010 (Standard Weapon Firing Loop)

	Validates:
	1. Rejection of fire requests when no aircraft exists for the player.
	2. Successful weapon fire intent and projectile instantiation when aircraft is active.
	3. Strict server cooldown enforcement: rapid fire requests within cooldown window are rejected.
	4. Firing cadence after cooldown period succeeds.
	5. Spread weapon produces multiple projectiles according to spreadAngles.
	6. Non-collision properties (CanCollide = false, CanTouch = false, CanQuery = false).
	7. Clean teardown and state isolation.
]]

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local sharedWeaponConfig = SharedFolder:WaitForChild("WeaponConfig")
local WeaponConfig = require(sharedWeaponConfig)
if (WeaponConfig :: any).Weapons == nil then
	WeaponConfig = require(sharedWeaponConfig:Clone())
end

local WeaponServiceTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function WeaponServiceTests.RunTests(weaponServiceModule: any?): {
	total: number,
	passed: number,
	failed: number,
	results: { [number]: TestResult },
}
	local WeaponService = weaponServiceModule
	if not WeaponService then
		local SSS = game:GetService("ServerScriptService")
		local Services = SSS:WaitForChild("Services")
		WeaponService = require(Services:WaitForChild("WeaponService"))
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
			warn(string.format("[WeaponServiceTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Teardown to clean baseline
	WeaponService._Teardown()
	WeaponService.Initialize()
	assertTest("WeaponService is initialized", WeaponService.IsInitialized() == true)

	-- Mock Player
	local mockUserId = 999901
	local mockPlayer = {
		UserId = mockUserId,
		Name = "MockCombatPlayer",
	}

	-- Clean up any pre-existing test plane from previous test runs
	local existingPlanes = Workspace:FindFirstChild("ActivePlanes")
	if existingPlanes then
		local stale = existingPlanes:FindFirstChild(tostring(mockUserId))
		if stale then
			stale:Destroy()
		end
	end

	-- 1. Fire intent without active aircraft must fail safely
	local okNoPlane, errNoPlane = WeaponService.HandleFireIntent(mockPlayer :: any, "StandardPeaShooter", Vector2.new(1, 0))
	assertTest("Firing without active aircraft is rejected", okNoPlane == false and errNoPlane == "NoActiveAircraft")

	-- 2. Create mock aircraft in Workspace.ActivePlanes
	local activePlanes = Workspace:FindFirstChild("ActivePlanes")
	if not activePlanes then
		activePlanes = Instance.new("Folder")
		activePlanes.Name = "ActivePlanes"
		activePlanes.Parent = Workspace
	end

	local planeModel = Instance.new("Model")
	planeModel.Name = tostring(mockUserId)
	local rootPart = Instance.new("Part")
	rootPart.Name = "RootPart"
	rootPart.Size = Vector3.new(10, 4, 3)
	rootPart.Position = Vector3.new(0, 0, 0)
	rootPart.Anchored = true
	rootPart.Parent = planeModel
	planeModel.PrimaryPart = rootPart
	planeModel.Parent = activePlanes

	-- 3. First fire intent with StandardPeaShooter must succeed
	local okFirst, errFirst = WeaponService.HandleFireIntent(mockPlayer :: any, "StandardPeaShooter", Vector2.new(1, 0))
	assertTest("First fire intent succeeds with active plane", okFirst == true and errFirst == nil)

	local playerState = WeaponService.GetPlayerState(mockUserId)
	assertTest("Player state recorded shot count = 1", playerState ~= nil and playerState.shotCount == 1)

	-- Verify projectile in Workspace.Projectiles
	local projFolder = Workspace:FindFirstChild("Projectiles")
	assertTest("Workspace.Projectiles exists", projFolder ~= nil and projFolder:IsA("Folder"))

	local projectiles = if projFolder then projFolder:GetChildren() else {}
	assertTest("At least 1 projectile spawned in Workspace.Projectiles", #projectiles >= 1)

	if #projectiles >= 1 then
		local proj = projectiles[1] :: BasePart
		assertTest("Projectile is Anchored", proj.Anchored == true)
		assertTest("Projectile CanCollide is false", proj.CanCollide == false)
		assertTest("Projectile CanTouch is false", proj.CanTouch == false)
		assertTest("Projectile CanQuery is false", proj.CanQuery == false)
		assertTest("Projectile OwnerUserId matches player", proj:GetAttribute("OwnerUserId") == mockUserId)
		assertTest("Projectile BaseDamage is 10 (StandardPeaShooter)", proj:GetAttribute("BaseDamage") == 10)
		assertTest("Projectile Speed is 140", proj:GetAttribute("ProjectileSpeed") == 140)
	end

	-- 4. Immediate second fire intent within cooldown window (0.2s) must be REJECTED by server
	local okSecond, errSecond = WeaponService.HandleFireIntent(mockPlayer :: any, "StandardPeaShooter", Vector2.new(1, 0))
	assertTest("Immediate second fire intent is rejected by server cooldown", okSecond == false and errSecond == "CooldownActive")
	assertTest("Shot count was NOT incremented on rejected attempt", playerState ~= nil and playerState.shotCount == 1)

	-- 5. Spread shot weapon produces 3 projectiles
	if projFolder then
		projFolder:ClearAllChildren()
	end
	-- Artificially advance cooldown for testing
	if playerState then
		playerState.lastFireTime = os.clock() - 1.0
	end

	local okSpread, errSpread = WeaponService.HandleFireIntent(mockPlayer :: any, "SpreadShot", Vector2.new(1, 0))
	assertTest("SpreadShot fire succeeds after cooldown elapses", okSpread == true and errSpread == nil)

	local spreadProjectiles = if projFolder then projFolder:GetChildren() else {}
	assertTest("SpreadShot spawned exactly 3 projectiles (one per spread angle)", #spreadProjectiles == 3)

	-- 6. Teardown and Cleanup
	planeModel:Destroy()
	WeaponService._Teardown()
	assertTest("WeaponService is uninitialized after teardown", WeaponService.IsInitialized() == false)
	assertTest("Player state is wiped on teardown", WeaponService.GetPlayerState(mockUserId) == nil)

	local remainingProjs = if projFolder then #projFolder:GetChildren() else 0
	assertTest("Workspace.Projectiles cleared on teardown", remainingProjs == 0)

	-- Reinitialize for live server
	WeaponService.Initialize()

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return WeaponServiceTests
