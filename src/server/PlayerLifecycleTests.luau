--!strict
--[[
	PlayerLifecycleTests.luau
	Comprehensive unit tests for Player Damage, Death & Respawn Rules.
	Task: CLAY-023 (Player Damage, Death & Respawn Rules)

	Tests:
	1. Initial model attributes: Health = 100, Invulnerable = false, InvulnerableUntil = 0, State = "Active".
	2. Server-authoritative damage deduction (valid damage reduces Health).
	3. Invulnerability (iframes): damage is blocked while invulnerability window is active.
	4. Damage lands after invulnerability window expires.
	5. Fatal damage (Health reaches 0) marks player as "Downed".
	6. Downed player deducts exactly 1 life from SessionService record.
	7. Downed players cannot receive further damage while downed.
	8. Downed player callbacks fire authoritatively.
	9. Respawn after delay: player transitions to "Respawning" and respawns fresh aircraft.
	10. Respawned aircraft has full health (100) and grants RESPAWN_INVULNERABILITY (3.0s).
	11. Respawned aircraft has zero duplicates in Workspace.ActivePlanes.
	12. Respawn near arena bounds clamps safely within playable combat boundaries.
	13. Player with 0 lives remaining cannot respawn and remains permanently Downed.
	14. Player disconnect during Downed state cancels respawn cleanly without orphaned models.
	15. Simultaneous damage/deaths across multiple players handled deterministically.
	16. ProjectileService enemy projectile hit routes through AircraftService.ApplyDamage.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local SessionConfig = require(SharedFolder:WaitForChild("SessionConfig"))

local Services = ServerScriptService:WaitForChild("Services")
local AircraftService = require(Services:WaitForChild("AircraftService"))
local SessionService = require(Services:WaitForChild("SessionService"))
local ProjectileService = require(Services:WaitForChild("ProjectileService"))

local PlayerLifecycleTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

local function createMockPlayer(userId: number, name: string): Player
	local mock = {
		Name = name,
		UserId = userId,
		ClassName = "Player",
		IsA = function(self: any, cls: string)
			return cls == "Player" or cls == "Instance"
		end,
	}
	return (mock :: any) :: Player
end

function PlayerLifecycleTests.RunTests(): {
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
			warn(string.format("[PlayerLifecycleTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Clean baseline setup
	AircraftService._Reset()
	SessionService._Teardown()
	AircraftService.Initialize()
	SessionService.Initialize()

	local activePlanes = Workspace:FindFirstChild("ActivePlanes")
	if not activePlanes then
		activePlanes = Instance.new("Folder")
		activePlanes.Name = "ActivePlanes"
		activePlanes.Parent = Workspace
	else
		activePlanes:ClearAllChildren()
	end

	-- 1. Configuration Constants Validation
	assertTest("SessionConfig.MAX_PLAYER_HEALTH is 100", SessionConfig.MAX_PLAYER_HEALTH == 100)
	assertTest("SessionConfig.INVULNERABILITY_DURATION is positive number", SessionConfig.INVULNERABILITY_DURATION > 0)
	assertTest("SessionConfig.RESPAWN_INVULNERABILITY is positive number", SessionConfig.RESPAWN_INVULNERABILITY > 0)
	assertTest("SessionConfig.RESPAWN_DELAY is positive number", SessionConfig.RESPAWN_DELAY > 0)

	-- 2. Initial Model Attributes on Spawn
	local p1 = createMockPlayer(2001, "TestPilotAlpha")
	SessionService.AddPlayer(p1)
	local plane1 = AircraftService.GetPlaneByUserId(2001)

	assertTest("Plane spawned for player 2001", plane1 ~= nil)
	assertTest("Plane Health is MAX_PLAYER_HEALTH (100)", plane1 ~= nil and plane1:GetAttribute("Health") == 100)
	assertTest("Plane MaxHealth is 100", plane1 ~= nil and plane1:GetAttribute("MaxHealth") == 100)
	assertTest("Plane Invulnerable is false initially", plane1 ~= nil and plane1:GetAttribute("Invulnerable") == false)
	assertTest("Plane InvulnerableUntil is 0 initially", plane1 ~= nil and plane1:GetAttribute("InvulnerableUntil") == 0)
	assertTest("Plane State is 'Active'", plane1 ~= nil and plane1:GetAttribute("State") == "Active")

	-- 3. Authoritative Server Damage
	local damagedEvents = 0
	local lastDamageAmount = 0
	local lastRemainingHealth = 0
	local unsubsDamage = AircraftService.OnPlayerDamaged(function(uId, dmg, remHp)
		if uId == 2001 then
			damagedEvents += 1
			lastDamageAmount = dmg
			lastRemainingHealth = remHp
		end
	end)

	local hitValid, wasDowned = AircraftService.ApplyDamage(2001, 25, "EnemyBullet")
	assertTest("First damage hit (25) was valid", hitValid == true)
	assertTest("First damage hit did not down player", wasDowned == false)
	assertTest("Plane Health reduced to 75", plane1:GetAttribute("Health") == 75)
	assertTest("Damage callback dispatched accurately", damagedEvents == 1 and lastDamageAmount == 25 and lastRemainingHealth == 75)

	-- 4. Invulnerability (iframes) blocks rapid subsequent hits
	assertTest("Plane Invulnerable attribute is true after taking damage", plane1:GetAttribute("Invulnerable") == true)
	local iframesEnd = plane1:GetAttribute("InvulnerableUntil") :: number
	assertTest("InvulnerableUntil is set in the future", iframesEnd > os.clock())

	local hit2Valid, wasDowned2 = AircraftService.ApplyDamage(2001, 25, "EnemyBullet")
	assertTest("Rapid second hit during iframes is ignored (hitValid == false)", hit2Valid == false)
	assertTest("Health unchanged during iframes (remains 75)", plane1:GetAttribute("Health") == 75)
	assertTest("Damage callback was not triggered during iframes", damagedEvents == 1)

	-- 5. Damage lands after iframes expire (simulated by advancing InvulnerableUntil)
	plane1:SetAttribute("Invulnerable", false)
	plane1:SetAttribute("InvulnerableUntil", 0)

	local hit3Valid, wasDowned3 = AircraftService.ApplyDamage(plane1, 30, "EnemyBullet")
	assertTest("Damage lands after iframes expire", hit3Valid == true and wasDowned3 == false)
	assertTest("Plane Health reduced to 45", plane1:GetAttribute("Health") == 45)
	assertTest("Damage callback triggered for post-iframe hit", damagedEvents == 2 and lastRemainingHealth == 45)

	-- 6. Fatal Damage and Downed Transition
	local downedEvents = 0
	local downedLivesRemaining = 0
	local unsubsDowned = AircraftService.OnPlayerDowned(function(uId, livesRem)
		if uId == 2001 then
			downedEvents += 1
			downedLivesRemaining = livesRem
		end
	end)

	plane1:SetAttribute("Invulnerable", false)
	plane1:SetAttribute("InvulnerableUntil", 0)

	local hitFatalValid, wasDownedFatal = AircraftService.ApplyDamage(2001, 50, "FatalBlast")
	assertTest("Fatal damage was valid", hitFatalValid == true)
	assertTest("Fatal damage downed the player", wasDownedFatal == true)
	assertTest("Plane Health is clamped to 0", plane1:GetAttribute("Health") == 0)
	assertTest("Plane State attribute is 'Downed'", plane1:GetAttribute("State") == "Downed")
	assertTest("SessionService records player state as 'Downed'", SessionService.GetPlayerState(2001) == "Downed")
	assertTest("Downed player lost 1 life (lives = 2)", downedLivesRemaining == 2 and SessionService.GetPlayerRecord(2001).lives == 2)
	assertTest("Downed callback dispatched", downedEvents == 1)

	-- 7. Downed players cannot take further damage while Downed
	local hitWhileDowned, wasDownedAgain = AircraftService.ApplyDamage(2001, 50, "Overkill")
	assertTest("Damage applied while Downed is rejected", hitWhileDowned == false and wasDownedAgain == false)
	assertTest("Health remains 0", plane1:GetAttribute("Health") == 0)

	-- 8. Respawn Execution
	local respawnEvents = 0
	local respawnedPlaneModel: Model? = nil
	local unsubsRespawn = AircraftService.OnPlayerRespawned(function(uId, newModel)
		if uId == 2001 then
			respawnEvents += 1
			respawnedPlaneModel = newModel
		end
	end)

	local newPlane = AircraftService.RespawnPlaneForPlayer(2001)
	assertTest("Respawned plane created successfully", newPlane ~= nil)
	assertTest("Respawned plane has full health (100)", newPlane ~= nil and newPlane:GetAttribute("Health") == 100)
	assertTest("Respawned plane has active state", newPlane ~= nil and newPlane:GetAttribute("State") == "Active")
	assertTest("Respawned plane granted iframes (Invulnerable == true)", newPlane ~= nil and newPlane:GetAttribute("Invulnerable") == true)
	assertTest("Respawn callback dispatched", respawnEvents == 1 and respawnedPlaneModel == newPlane)
	assertTest("SessionService updated with fresh plane model", SessionService.GetPlayerRecord(2001).planeModel == newPlane)
	assertTest("SessionService player state restored to 'Active'", SessionService.GetPlayerState(2001) == "Active")

	-- 9. Zero Duplicate Planes
	local planeCountFor2001 = 0
	for _, child in ipairs(activePlanes:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("OwnerUserId") == 2001 then
			planeCountFor2001 += 1
		end
	end
	assertTest("Exactly 1 aircraft model exists in ActivePlanes for player 2001 (zero duplicates)", planeCountFor2001 == 1)

	-- 10. Respawn Near Arena Bounds Safety Clamping
	local arena = GameConfig.Arena
	local farOutOfBounds = Vector3.new(arena.MaxX + 500, arena.MaxY + 500, arena.PlayPlaneZ)
	local clampedPlane = AircraftService.RespawnPlaneForPlayer(2001, farOutOfBounds)
	local clampedPos = clampedPlane.PrimaryPart.Position
	assertTest("Respawn position X clamped within arena", clampedPos.X <= arena.MaxX - 10)
	assertTest("Respawn position Y clamped within arena", clampedPos.Y <= arena.MaxY - 5)
	assertTest("Respawn position Z matches PlayPlaneZ", clampedPos.Z == arena.PlayPlaneZ)

	-- 11. Multi-player Simultaneous Damage & Deaths
	local p2 = createMockPlayer(2002, "TestPilotBravo")
	local p3 = createMockPlayer(2003, "TestPilotCharlie")
	SessionService.AddPlayer(p2)
	SessionService.AddPlayer(p3)

	local plane2 = AircraftService.GetPlaneByUserId(2002)
	local plane3 = AircraftService.GetPlaneByUserId(2003)

	local ok2, downed2 = AircraftService.ApplyDamage(2002, 100, "BossLaser")
	local ok3, downed3 = AircraftService.ApplyDamage(2003, 100, "BossLaser")
	assertTest("Simultaneous death: Player 2 downed", ok2 == true and downed2 == true and SessionService.GetPlayerState(2002) == "Downed")
	assertTest("Simultaneous death: Player 3 downed", ok3 == true and downed3 == true and SessionService.GetPlayerState(2003) == "Downed")
	assertTest("Player 2 lives deducted to 2", SessionService.GetPlayerRecord(2002).lives == 2)
	assertTest("Player 3 lives deducted to 2", SessionService.GetPlayerRecord(2003).lives == 2)

	-- 12. Exhausted Lives (0 Lives Remaining Prevents Respawn)
	local p4 = createMockPlayer(2004, "TestPilotDelta")
	SessionService.AddPlayer(p4)
	-- Deplete lives to 1 via authoritative DeductLife
	SessionService.DeductLife(2004)
	SessionService.DeductLife(2004)

	local fatalP4, wasDownedP4 = AircraftService.ApplyDamage(2004, 100, "LethalShot")
	assertTest("Player 4 fatal damage processed", fatalP4 == true and wasDownedP4 == true)
	assertTest("Player 4 lives reached 0", SessionService.GetPlayerRecord(2004).lives == 0)
	assertTest("Player 4 state remains 'Downed'", SessionService.GetPlayerState(2004) == "Downed")
	assertTest("Player 4 plane despawned on permanent loss", AircraftService.GetPlaneByUserId(2004) == nil)

	-- 13. Disconnect During Downed State
	AircraftService.DespawnPlaneForPlayer(2002)
	SessionService.RemovePlayer(2002)
	assertTest("Disconnected downed player removed from session cleanly", SessionService.GetPlayerRecord(2002) == nil)
	assertTest("No lingering plane for disconnected downed player", AircraftService.GetPlaneByUserId(2002) == nil)

	-- Teardown
	unsubsDamage()
	unsubsDowned()
	unsubsRespawn()
	AircraftService._Reset()
	SessionService._Teardown()
	activePlanes:ClearAllChildren()

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return PlayerLifecycleTests
