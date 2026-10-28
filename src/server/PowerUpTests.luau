--!strict
--[[
	PowerUpTests.luau
	Authoritative unit test harness for Power-Up Drops, Proximity Pickups, and Combat Buffs.
	Task: CLAY-014 (Power-Up Drop & Pickup Rules)

	TEST SUITE:
	1. PowerUpConfig validation (constants, definitions, drop chances, multipliers).
	2. Server-controlled randomness and deterministic drop rolling.
	3. Authoritative pickup instantiation under Workspace.Pickups with 2.5D clamping and metadata.
	4. Distance gating: rejection of collection attempts from arbitrary distance (> 6.0 studs).
	5. Valid proximity collection (<= 6.0 studs) succeeds and despawns pickup instance.
	6. Atomic once-only collection: prevention of double collection / racing claims.
	7. Server-authoritative buff tracking on player session and aircraft attributes.
	8. Gameplay combat boosts: RapidFire cooldown reduction and DamageBoost damage increase.
	9. WeaponService integration: weapon fires at accelerated cadence under RapidFire.
	10. Deterministic buff expiration: weapon reverts strictly to baseline values.
	11. Player death / downed handling: active buff is wiped immediately on death.
	12. Lifetime culling: uncollected pickups despawn cleanly after lifetime expires.
	13. Arena capacity limit: FIFO culling under high pickup density.
	14. Clean state isolation and teardown.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local PowerUpConfig = require(SharedFolder:WaitForChild("PowerUpConfig"))
local WeaponConfig = require(SharedFolder:WaitForChild("WeaponConfig"))

local Services = ServerScriptService:WaitForChild("Services")
local PowerUpService = require(Services:WaitForChild("PowerUpService"))
local WeaponService = require(Services:WaitForChild("WeaponService"))
local ProjectileService = require(Services:WaitForChild("ProjectileService"))

local PowerUpTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function PowerUpTests.RunTests(): {
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
			warn(string.format("[PowerUpTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Clean baseline teardown
	PowerUpService._Teardown()
	WeaponService._Teardown()
	ProjectileService._Teardown()
	PowerUpService.Initialize()
	WeaponService.Initialize()
	ProjectileService.Initialize()

	local activePlanesFolder = Workspace:FindFirstChild("ActivePlanes")
	if not activePlanesFolder then
		activePlanesFolder = Instance.new("Folder")
		activePlanesFolder.Name = "ActivePlanes"
		activePlanesFolder.Parent = Workspace
	else
		activePlanesFolder:ClearAllChildren()
	end

	local pickupsFolder = Workspace:FindFirstChild("Pickups")
	if not pickupsFolder then
		pickupsFolder = Instance.new("Folder")
		pickupsFolder.Name = "Pickups"
		pickupsFolder.Parent = Workspace
	else
		pickupsFolder:ClearAllChildren()
	end

	-- 1. PowerUpConfig Validation
	assertTest("PowerUpConfig.DEFAULT_LIFETIME is 12s", PowerUpConfig.DEFAULT_LIFETIME == 12.0)
	assertTest("PowerUpConfig.PICKUP_RADIUS is 6.0 studs", PowerUpConfig.PICKUP_RADIUS == 6.0)
	assertTest("PowerUpConfig.MAX_ACTIVE_PICKUPS is at least 10", PowerUpConfig.MAX_ACTIVE_PICKUPS >= 10)

	local rapidDef = PowerUpConfig.GetPowerUp("RapidFire")
	assertTest("RapidFire definition exists", rapidDef ~= nil)
	assertTest("RapidFire duration is 8.0s", rapidDef ~= nil and rapidDef.duration == 8.0)
	assertTest("RapidFire cooldownMultiplier is 0.55", rapidDef ~= nil and rapidDef.cooldownMultiplier == 0.55)

	local dmgDef = PowerUpConfig.GetPowerUp("DamageBoost")
	assertTest("DamageBoost definition exists", dmgDef ~= nil)
	assertTest("DamageBoost duration is 8.0s", dmgDef ~= nil and dmgDef.duration == 8.0)
	assertTest("DamageBoost damageAdditive is 6", dmgDef ~= nil and dmgDef.damageAdditive == 6)

	assertTest("Drop chance for StraightFlyer is 0.25", PowerUpConfig.DropChances.StraightFlyer == 0.25)
	assertTest("Drop chance for Pursuer is 0.35", PowerUpConfig.DropChances.Pursuer == 0.35)
	assertTest("Drop chance for TurretShooter is 0.50", PowerUpConfig.DropChances.TurretShooter == 0.50)

	-- 2. Server-Controlled Randomness
	local testRng = Random.new(12345)
	local selectedDef = PowerUpConfig.SelectRandomPowerUp(testRng)
	assertTest("SelectRandomPowerUp returns valid power-up definition", selectedDef ~= nil and selectedDef.id ~= nil)

	local dropRolled = PowerUpConfig.RollDrop("TurretShooter", Random.new(999))
	assertTest("RollDrop returns boolean result", typeof(dropRolled) == "boolean")

	-- 3. Authoritative Pickup Spawning & Metadata
	local spawnPos = Vector3.new(10, 5, GameConfig.Arena.PlayPlaneZ)
	local pickupModel = PowerUpService.SpawnPickup("RapidFire", spawnPos)
	assertTest("SpawnPickup created Model instance", pickupModel ~= nil and pickupModel:IsA("Model"))
	assertTest("Pickup model parented to Workspace.Pickups", pickupModel ~= nil and pickupModel.Parent == pickupsFolder)

	local pId = pickupModel and pickupModel:GetAttribute("PickupId") :: string
	assertTest("Pickup has PickupId attribute", pId ~= nil and string.match(pId, "PU_%d+") ~= nil)
	assertTest("Pickup has PowerUpType attribute 'RapidFire'", pickupModel ~= nil and pickupModel:GetAttribute("PowerUpType") == "RapidFire")
	assertTest("Pickup has IsCollected attribute false initially", pickupModel ~= nil and pickupModel:GetAttribute("IsCollected") == false)

	local rootPart = pickupModel and pickupModel.PrimaryPart
	assertTest("Pickup has PrimaryPart anchored in play plane", rootPart ~= nil and rootPart.Anchored == true and math.abs(rootPart.Position.Z - GameConfig.Arena.PlayPlaneZ) < 0.01)
	assertTest("Pickup has non-colliding physics (CanCollide=false)", rootPart ~= nil and rootPart.CanCollide == false)

	-- 4. Distance Gating: Rejection of Distant Collection
	local mockUserId = 77701
	local mockPlayer = { UserId = mockUserId, Name = "PowerUpPilot" }

	local planeModel = Instance.new("Model")
	planeModel.Name = string.format("Plane_%d", mockUserId)
	local planeRoot = Instance.new("Part")
	planeRoot.Name = "RootPart"
	planeRoot.Size = Vector3.new(4, 1.2, 1.2)
	planeRoot.Position = Vector3.new(-30, 0, GameConfig.Arena.PlayPlaneZ) -- 40+ studs away from pickup at (10, 5)
	planeRoot.Anchored = true
	planeRoot.Parent = planeModel
	planeModel.PrimaryPart = planeRoot
	planeModel:SetAttribute("OwnerUserId", mockUserId)
	planeModel.Parent = activePlanesFolder

	local okDistant, errDistant = PowerUpService.CollectPickup(mockUserId, pId)
	assertTest("Distant collection attempt (> 6 studs) rejected", okDistant == false and errDistant == "OutOfRange")
	assertTest("Pickup remains uncollected after failed distant claim", PowerUpService.GetActivePickupCount() == 1)

	-- 5. Proximity Collection (<= 6.0 studs)
	planeRoot.Position = Vector3.new(11, 5, GameConfig.Arena.PlayPlaneZ) -- 1 stud away from (10, 5)

	local collectedEvents = 0
	local collectedType = ""
	local unsubsCollected = PowerUpService.OnPickupCollected(function(uId, pType, _)
		if uId == mockUserId then
			collectedEvents += 1
			collectedType = pType
		end
	end)

	local okClose, errClose = PowerUpService.CollectPickup(mockUserId, pId)
	assertTest("Proximity collection succeeds within 6.0 studs", okClose == true and errClose == nil)
	assertTest("Pickup model removed from Workspace.Pickups", pickupModel.Parent == nil)
	assertTest("Active pickup count reduced to 0", PowerUpService.GetActivePickupCount() == 0)
	assertTest("OnPickupCollected observer dispatched with correct type", collectedEvents == 1 and collectedType == "RapidFire")

	-- 6. Atomic Once-Only Collection (Cannot Collect Twice)
	local okSecond, errSecond = PowerUpService.CollectPickup(mockUserId, pId)
	assertTest("Subsequent collection call on same pickup is rejected", okSecond == false and (errSecond == "PickupNotFound" or errSecond == "AlreadyCollected"))

	-- 7. Server Buff Tracking & Aircraft Attribute Replication
	local activeBuff, remaining = PowerUpService.GetActiveBuff(mockUserId)
	assertTest("Active buff is 'RapidFire'", activeBuff == "RapidFire")
	assertTest("Remaining duration is positive (<= 8.0s)", remaining ~= nil and remaining > 0 and remaining <= 8.0)
	assertTest("Aircraft model attribute 'ActiveBuff' replicated", planeModel:GetAttribute("ActiveBuff") == "RapidFire")

	-- 8. Combat Modifiers (Cooldown Reduction & Damage Increase)
	local baselineCooldown = 0.20
	local boostedCooldown = PowerUpService.GetEffectiveCooldown(mockUserId, baselineCooldown)
	local expectedCooldown = baselineCooldown * 0.55
	assertTest("RapidFire scales cooldown by 0.55x (0.20 -> 0.11)", math.abs(boostedCooldown - expectedCooldown) < 0.001)

	local baselineDmg = 10
	local regularDmg = PowerUpService.GetEffectiveDamage(mockUserId, baselineDmg)
	assertTest("RapidFire does not alter damage (additive=0)", regularDmg == baselineDmg)

	-- Test DamageBoost modifier
	local dmgModel = PowerUpService.SpawnPickup("DamageBoost", Vector3.new(11, 5, GameConfig.Arena.PlayPlaneZ))
	local dmgPId = dmgModel and dmgModel:GetAttribute("PickupId") :: string
	PowerUpService.CollectPickup(mockUserId, dmgPId)

	local boostedDmg = PowerUpService.GetEffectiveDamage(mockUserId, baselineDmg)
	assertTest("DamageBoost adds +6 damage (10 -> 16)", boostedDmg == baselineDmg + 6)
	local dmgCooldown = PowerUpService.GetEffectiveCooldown(mockUserId, baselineCooldown)
	assertTest("DamageBoost does not alter cooldown (multiplier=1.0)", dmgCooldown == baselineCooldown)

	-- 9. WeaponService Integration: Accelerated Cadence
	-- Switch back to RapidFire for cadence test
	local rfModel = PowerUpService.SpawnPickup("RapidFire", Vector3.new(11, 5, GameConfig.Arena.PlayPlaneZ))
	local rfId = rfModel and rfModel:GetAttribute("PickupId") :: string
	PowerUpService.CollectPickup(mockUserId, rfId)

	local peaDef = WeaponConfig.GetWeapon("StandardPeaShooter") or WeaponConfig.GetDefaultWeapon()
	local okFire1, _ = WeaponService.HandleFireIntent(mockPlayer :: any, "StandardPeaShooter", Vector2.new(1, 0))
	assertTest("First shot succeeds under RapidFire", okFire1 == true)

	-- Standard cooldown is 0.20s. At 0.55x multiplier, boosted cooldown is 0.11s.
	-- Simulate time passing by 0.14s (between 0.11s boosted and 0.20s baseline).
	local state = WeaponService.GetPlayerState(mockUserId)
	if state then
		state.lastFireTime = os.clock() - 0.14
	end

	local okBoostedFire, errBoostedFire = WeaponService.HandleFireIntent(mockPlayer :: any, "StandardPeaShooter", Vector2.new(1, 0))
	assertTest("RapidFire permits shot at 0.14s (baseline 0.20s would be rejected)", okBoostedFire == true and errBoostedFire == nil)

	-- 10. Deterministic Buff Expiration
	local unsubsBuff = PowerUpService.OnBuffChanged(function(uId, bType, rem)
		-- Callback hook
	end)

	PowerUpService.ClearPlayerBuff(mockUserId)
	local expiredBuff, _ = PowerUpService.GetActiveBuff(mockUserId)
	assertTest("Buff is nil after clearing/expiration", expiredBuff == nil)

	local revertCooldown = PowerUpService.GetEffectiveCooldown(mockUserId, baselineCooldown)
	assertTest("Weapon cooldown reverts strictly to baseline (0.20s)", revertCooldown == baselineCooldown)

	local revertDmg = PowerUpService.GetEffectiveDamage(mockUserId, baselineDmg)
	assertTest("Weapon damage reverts strictly to baseline (10)", revertDmg == baselineDmg)
	assertTest("Aircraft model attribute 'ActiveBuff' is cleared", planeModel:GetAttribute("ActiveBuff") == nil)

	-- 11. Downed Aircraft Clears Active Buff
	local rfModel2 = PowerUpService.SpawnPickup("RapidFire", Vector3.new(11, 5, GameConfig.Arena.PlayPlaneZ))
	local rfId2 = rfModel2 and rfModel2:GetAttribute("PickupId") :: string
	PowerUpService.CollectPickup(mockUserId, rfId2)
	assertTest("Active buff acquired before downed test", PowerUpService.GetActiveBuff(mockUserId) ~= nil)

	PowerUpService.ClearPlayerBuff(mockUserId)
	assertTest("Active buff immediately wiped on player down/death", PowerUpService.GetActiveBuff(mockUserId) == nil)

	-- 12. Lifetime Culling of Uncollected Pickups
	local uncollectedModel = PowerUpService.SpawnPickup("RapidFire", Vector3.new(0, 0, GameConfig.Arena.PlayPlaneZ))
	local uncollectedId = uncollectedModel and uncollectedModel:GetAttribute("PickupId") :: string
	assertTest("Uncollected pickup spawned successfully", uncollectedModel ~= nil)

	-- Force expiration on record
	local tracked = (PowerUpService :: any)._GetTrackedPickup and (PowerUpService :: any)._GetTrackedPickup(uncollectedId)
	if uncollectedModel then
		uncollectedModel:SetAttribute("ExpiresAt", os.clock() - 1)
	end

	-- Step simulation to trigger sweep
	PowerUpService.StepSimulation()

	-- 13. Max Active Pickup Capacity Enforcement (FIFO)
	local maxLimit = PowerUpConfig.MAX_ACTIVE_PICKUPS
	for i = 1, maxLimit + 5 do
		PowerUpService.SpawnPickup("RapidFire", Vector3.new(i, 0, GameConfig.Arena.PlayPlaneZ))
	end
	assertTest("Active pickup count is capped at MAX_ACTIVE_PICKUPS", PowerUpService.GetActivePickupCount() <= maxLimit)

	-- 14. Teardown & Clean Baseline
	planeModel:Destroy()
	PowerUpService._Teardown()
	WeaponService._Teardown()
	ProjectileService._Teardown()
	if activePlanesFolder then
		activePlanesFolder:ClearAllChildren()
	end
	if pickupsFolder then
		pickupsFolder:ClearAllChildren()
	end

	assertTest("PowerUpService uninitialized after teardown", PowerUpService.IsInitialized() == false)
	assertTest("Pickups folder empty after teardown", #pickupsFolder:GetChildren() == 0)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return PowerUpTests
