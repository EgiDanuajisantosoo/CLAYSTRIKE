--!strict
--[[
	PursuerTests.luau
	Comprehensive unit tests for Enemy Archetype B (Pursuer).
	Task: CLAY-018 (Enemy Archetype B — Pursuer)

	COVERS:
	1. Archetype schema and configuration validation.
	2. Procedural placeholder model structure, HitProxy, and VisualWings.
	3. Strict 2.5D combat plane Z-axis constraint.
	4. Target acquisition for single and multiplayer (1-4 players).
	5. Bounded turn rate and dodgability verification.
	6. Retargeting on player death, despawn, or session disconnect.
	7. Arena edge culling and deterministic cleanup.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
if (EnemyConfig :: any).Archetypes == nil then
	EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"):Clone())
end

local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
if (GameConfig :: any).CONTRACT_VERSION == nil then
	GameConfig = require(SharedFolder:WaitForChild("GameConfig"):Clone())
end

local Services = ServerScriptService:WaitForChild("Services")
local EnemyFactory = require(Services:WaitForChild("EnemyFactory"))
local EnemyService = require(Services:WaitForChild("EnemyService"))
local SessionService = require(Services:WaitForChild("SessionService"))

local PursuerTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

-- Helper to create mock player aircraft in Workspace.ActivePlanes
local function createTestPlayerPlane(userId: number, pos: Vector3, health: number?): Model
	local planesFolder = Workspace:FindFirstChild("ActivePlanes")
	if not planesFolder then
		planesFolder = Instance.new("Folder")
		planesFolder.Name = "ActivePlanes"
		planesFolder.Parent = Workspace
	end

	local plane = Instance.new("Model")
	plane.Name = string.format("Plane_%d", userId)
	plane:SetAttribute("OwnerUserId", userId)
	plane:SetAttribute("Health", health or 100)

	local part = Instance.new("Part")
	part.Name = "HitProxy"
	part.Size = Vector3.new(4, 2, 2)
	part.Position = pos
	part.Anchored = true
	part.CanCollide = false
	part.Parent = plane
	plane.PrimaryPart = part

	plane.Parent = planesFolder
	return plane
end

function PursuerTests.RunTests(): {
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
			warn(string.format("[PursuerTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Teardown services for clean baseline
	EnemyService._Teardown()
	SessionService._Teardown()
	EnemyService.Initialize()
	SessionService.Initialize()

	-- Clean ActivePlanes
	local activePlanes = Workspace:FindFirstChild("ActivePlanes")
	if not activePlanes then
		activePlanes = Instance.new("Folder")
		activePlanes.Name = "ActivePlanes"
		activePlanes.Parent = Workspace
	else
		activePlanes:ClearAllChildren()
	end

	-- 1. EnemyConfig Schema Validation
	assertTest("EnemyConfig has Pursuer archetype", EnemyConfig.Archetypes.Pursuer == "Pursuer")
	local pursuerDef = EnemyConfig.GetEnemy("Pursuer")
	assertTest("Pursuer definition retrieved successfully", pursuerDef ~= nil)
	assertTest("Pursuer movementType is 'Pursuit'", pursuerDef ~= nil and pursuerDef.movementType == "Pursuit")
	assertTest("Pursuer speed is 14 studs/s", pursuerDef ~= nil and pursuerDef.speed == 14)
	assertTest("Pursuer verticalSpeed is 10 studs/s", pursuerDef ~= nil and pursuerDef.verticalSpeed == 10)
	assertTest("Pursuer maxHealth is 35", pursuerDef ~= nil and pursuerDef.maxHealth == 35)
	assertTest("Pursuer scoreValue is 250", pursuerDef ~= nil and pursuerDef.scoreValue == 250)
	assertTest("Pursuer canShoot is false", pursuerDef ~= nil and pursuerDef.firingPattern ~= nil and pursuerDef.firingPattern.canShoot == false)

	local validDef, defErr = EnemyConfig.ValidateDefinition(pursuerDef)
	assertTest("Pursuer definition passes schema validation", validDef == true and defErr == nil)

	-- 2. Procedural Placeholder Factory
	local placeholder = EnemyFactory.CreateProceduralPlaceholder(pursuerDef :: any)
	assertTest("Procedural placeholder created", placeholder ~= nil and placeholder:IsA("Model"))
	assertTest("PrimaryPart is HitProxy", placeholder.PrimaryPart ~= nil and placeholder.PrimaryPart.Name == "HitProxy")
	assertTest("HitProxy CanQuery is true (swept raycasts)", placeholder.PrimaryPart ~= nil and placeholder.PrimaryPart.CanQuery == true)
	assertTest("HitProxy CanCollide is false", placeholder.PrimaryPart ~= nil and placeholder.PrimaryPart.CanCollide == false)
	assertTest("HitProxy matches terracotta color", placeholder.PrimaryPart ~= nil and placeholder.PrimaryPart.Color == pursuerDef.clayColor)
	assertTest("VisualWings present on Pursuer", placeholder:FindFirstChild("VisualWings") ~= nil)
	assertTest("VisualNose present on Pursuer", placeholder:FindFirstChild("VisualNose") ~= nil)
	placeholder:Destroy()

	-- 3. Spawn Pursuer via EnemyService
	local arena = GameConfig.Arena
	local spawnPos = Vector3.new(arena.MaxX, 15, arena.PlayPlaneZ)
	local pursuerModel, spawnErr = EnemyService.SpawnEnemy("Pursuer", spawnPos)
	assertTest("Pursuer spawned without error", pursuerModel ~= nil and spawnErr == nil)
	assertTest("Active enemy count is 1", EnemyService.GetActiveEnemyCount() == 1)

	local enemyId = pursuerModel and pursuerModel.Name or ""
	local enemyRecord = EnemyService.GetActiveEnemy(enemyId)
	assertTest("EnemyRecord tracked in EnemyService", enemyRecord ~= nil)
	assertTest("Initial heading points left (-1, 0)", enemyRecord ~= nil and enemyRecord.heading ~= nil and enemyRecord.heading.X == -1 and enemyRecord.heading.Y == 0)

	-- 4. Strict 2.5D Constraint
	assertTest("Spawn position Z is PlayPlaneZ", enemyRecord ~= nil and enemyRecord.primaryPart.Position.Z == arena.PlayPlaneZ)

	-- Step simulation without targets
	EnemyService.StepEnemySimulation(0.1)
	assertTest("Position Z remains exactly PlayPlaneZ after simulation step",
		enemyRecord ~= nil and math.abs(enemyRecord.primaryPart.Position.Z - arena.PlayPlaneZ) < 0.001)

	-- 5. Target Acquisition (Single Player)
	local p1Plane = createTestPlayerPlane(1001, Vector3.new(0, 25, arena.PlayPlaneZ), 100)
	EnemyService.StepEnemySimulation(0.1)

	assertTest("Pursuer acquires TargetUserId 1001",
		enemyRecord ~= nil and enemyRecord.targetUserId == 1001)
	assertTest("Model attribute TargetUserId matches 1001",
		pursuerModel ~= nil and pursuerModel:GetAttribute("TargetUserId") == 1001)

	-- 6. Steering Direction & Bounded Turn Rate
	-- Target is at Y = 25 (above Pursuer at Y ~ 15), so heading Y should turn upward (> 0)
	assertTest("Pursuer turns upward toward target (heading.Y > 0)",
		enemyRecord ~= nil and enemyRecord.heading ~= nil and enemyRecord.heading.Y > 0)

	-- Check turn rate bounds: MAX_TURN_RATE = 80 deg/s = ~1.396 rad/s
	-- In dt = 0.05s, max angle turn is ~0.0698 rad (~4 degrees)
	local headingBefore = enemyRecord.heading
	local angleBefore = math.atan2(headingBefore.Y, headingBefore.X)
	local testDt = 0.05
	EnemyService.StepEnemySimulation(testDt)
	local headingAfter = enemyRecord.heading
	local angleAfter = math.atan2(headingAfter.Y, headingAfter.X)
	local turnDelta = math.abs((angleAfter - angleBefore + math.pi) % (2 * math.pi) - math.pi)
	local maxTurnExpected = math.rad(80) * testDt + 0.001
	assertTest("Steering turn rate is strictly bounded (does not snap instantly)",
		turnDelta <= maxTurnExpected)

	-- 7. Dodgability Verification
	-- If player moves vertically to Y = 0 (far below), Pursuer cannot instantly match Y
	p1Plane.PrimaryPart.Position = Vector3.new(0, -10, arena.PlayPlaneZ)
	EnemyService.StepEnemySimulation(0.1)
	-- Pursuer should still be high up (Y > 5), not snapped to -10
	assertTest("Pursuer vertical position is smooth and dodgable (not snapped)",
		enemyRecord.primaryPart.Position.Y > 5)

	-- 8. Multi-player Nearest Target Selection (1 to 4 players)
	-- Player 1 at X = 0, Y = -10 (dist ~60)
	-- Player 2 at X = 40, Y = 12 (dist ~20 from pursuer at ~58)
	-- Player 3 at X = -20, Y = 30
	-- Player 4 at X = -40, Y = -20
	local p2Plane = createTestPlayerPlane(1002, Vector3.new(40, 12, arena.PlayPlaneZ), 100)
	local p3Plane = createTestPlayerPlane(1003, Vector3.new(-20, 30, arena.PlayPlaneZ), 100)
	local p4Plane = createTestPlayerPlane(1004, Vector3.new(-40, -20, arena.PlayPlaneZ), 100)

	EnemyService.StepEnemySimulation(0.1)
	assertTest("Pursuer selects nearest player (Player 1002)",
		enemyRecord ~= nil and enemyRecord.targetUserId == 1002)

	-- 9. Retargeting on Player Death
	-- Player 2 dies (Health = 0)
	p2Plane:SetAttribute("Health", 0)
	EnemyService.StepEnemySimulation(0.1)
	-- Should switch to next nearest living player (Player 1001 or 1003)
	assertTest("Pursuer retargets when current target dies (drops 1002)",
		enemyRecord ~= nil and enemyRecord.targetUserId ~= 1002 and enemyRecord.targetUserId ~= nil)

	-- 10. Retargeting on Player Despawn / Removal
	p1Plane:Destroy()
	p3Plane:Destroy()
	EnemyService.StepEnemySimulation(0.1)
	-- Only Player 1004 remains living
	assertTest("Pursuer retargets to remaining living player (Player 1004)",
		enemyRecord ~= nil and enemyRecord.targetUserId == 1004)

	-- 11. Target Disconnect / Session Inactivity
	-- Destroy manual test plane and test session-managed downed lifecycle
	p4Plane:Destroy()
	local mockPlayer4 = {
		Name = "PilotDelta",
		UserId = 1004,
		ClassName = "Player",
		IsA = function(self: any, cls: string) return cls == "Player" or cls == "Instance" end,
	}
	SessionService.AddPlayer((mockPlayer4 :: any) :: Player)
	SessionService.SetPlayerState(1004, "Downed")

	EnemyService.StepEnemySimulation(0.1)
	assertTest("Downed/Disconnected players are not targeted (targetUserId is 0/nil)",
		enemyRecord.targetUserId == nil or enemyRecord.targetUserId == 0)

	-- 12. Arena Edge Culling
	-- Position pursuer past left edge (cullMinX = arena.MinX - 15 = -80 - 15 = -95)
	enemyRecord.model:PivotTo(CFrame.new(Vector3.new(arena.MinX - 25, 0, arena.PlayPlaneZ)))
	EnemyService.StepEnemySimulation(0.1)
	assertTest("Pursuer culled and despawned beyond arena edge",
		EnemyService.GetActiveEnemy(enemyId) == nil)
	assertTest("Active enemy count is 0 after culling",
		EnemyService.GetActiveEnemyCount() == 0)

	-- Teardown
	EnemyService._Teardown()
	SessionService._Teardown()
	activePlanes:ClearAllChildren()

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return PursuerTests
