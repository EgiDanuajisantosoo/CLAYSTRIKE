--!strict
--[[
	ServerBootstrap.server.luau
	Authoritative server entry point for CLAYSTRIKE.
	Verifies Explorer baseline, validates network contracts, and initializes security boundaries.
	Task: CLAY-001 / CLAY-002

	HALT-ON-FAILURE POLICY:
	If baseline validation or contract unit tests fail, server initialization halts immediately
	with an explicit error, preventing insecure or broken network listener startup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Architecture = require(SharedFolder:WaitForChild("Architecture"))
local ContractTests = require(SharedFolder:WaitForChild("ContractTests"))
local RemoteManager = require(script.Parent:WaitForChild("RemoteManager"))
local AircraftTests = require(script.Parent:WaitForChild("AircraftTests"))
local AircraftService = require(script.Parent:WaitForChild("AircraftService"))
local MovementTests = require(script.Parent:WaitForChild("MovementTests"))
local MovementService = require(script.Parent:WaitForChild("MovementService"))
local ArenaTests = require(script.Parent:WaitForChild("ArenaTests"))
local ArenaService = require(script.Parent:WaitForChild("ArenaService"))
local WeaponTests = require(SharedFolder:WaitForChild("WeaponTests"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))
local WeaponServiceTests = require(script.Parent:WaitForChild("WeaponServiceTests"))
local ProjectileService = require(script.Parent:WaitForChild("ProjectileService"))
local ProjectileSimulationTests = require(script.Parent:WaitForChild("ProjectileSimulationTests"))
local EnemyTests = require(SharedFolder:WaitForChild("EnemyTests"))
local EnemyService = require(script.Parent:WaitForChild("EnemyService"))
local EnemyServiceTests = require(script.Parent:WaitForChild("EnemyServiceTests"))
local StraightFlyerTests = require(script.Parent:WaitForChild("StraightFlyerTests"))

-- 1. Validate baseline structure
local baselineSuccess, missing = Architecture.ValidateServerBaseline()
if not baselineSuccess then
	error(string.format(
		"[CLAYSTRIKE - ServerBootstrap] CRITICAL: Missing required baseline folders:\n  - %s\nHalting server initialization.",
		table.concat(missing, "\n  - ")
	))
end
print("[CLAYSTRIKE - ServerBootstrap] Server and Shared Explorer baseline validated successfully.")

-- 2. Execute isolated contract validation tests
local testSummary = ContractTests.RunTests()
if testSummary.failed > 0 then
	error(string.format(
		"[CLAYSTRIKE - ServerBootstrap] CRITICAL: %d/%d contract validation tests FAILED. Halting network initialization.",
		testSummary.failed,
		testSummary.total
	))
end
print(string.format("[CLAYSTRIKE - ContractTests] %d/%d isolated contract validation tests PASSED.", testSummary.passed, testSummary.total))

-- 3. Execute aircraft model factory and lifecycle unit tests
local aircraftSummary = AircraftTests.RunTests()
if aircraftSummary.failed > 0 then
	error(string.format(
		"[CLAYSTRIKE - ServerBootstrap] CRITICAL: %d/%d aircraft factory tests FAILED. Halting server initialization.",
		aircraftSummary.failed,
		aircraftSummary.total
	))
end
print(string.format("[CLAYSTRIKE - AircraftTests] %d/%d aircraft factory tests PASSED.", aircraftSummary.passed, aircraftSummary.total))

-- 4. Execute movement service unit tests
local movementSummary = MovementTests.RunTests()
if movementSummary.failed > 0 then
	error(string.format(
		"[CLAYSTRIKE - ServerBootstrap] CRITICAL: %d/%d movement tests FAILED. Halting server initialization.",
		movementSummary.failed,
		movementSummary.total
	))
end
print(string.format("[CLAYSTRIKE - MovementTests] %d/%d movement tests PASSED.", movementSummary.passed, movementSummary.total))

-- 5. Execute arena boundary unit tests
local arenaSummary = ArenaTests.RunTests()
if arenaSummary.failed > 0 then
	error(string.format(
		"[CLAYSTRIKE - ServerBootstrap] CRITICAL: %d/%d arena tests FAILED. Halting server initialization.",
		arenaSummary.failed,
		arenaSummary.total
	))
end
print(string.format("[CLAYSTRIKE - ArenaTests] %d/%d arena boundary tests PASSED.", arenaSummary.passed, arenaSummary.total))

-- 6. Execute weapon data definition unit tests
local weaponSummary = WeaponTests.RunTests()
if weaponSummary.failed > 0 then
	error(string.format(
		"[CLAYSTRIKE - ServerBootstrap] CRITICAL: %d/%d weapon configuration tests FAILED. Halting server initialization.",
		weaponSummary.failed,
		weaponSummary.total
	))
end
print(string.format("[CLAYSTRIKE - WeaponTests] %d/%d weapon configuration tests PASSED.", weaponSummary.passed, weaponSummary.total))

-- 7. Execute enemy data definition schema unit tests
local enemySummary = EnemyTests.RunTests()
if enemySummary.failed > 0 then
	error(string.format(
		"[CLAYSTRIKE - ServerBootstrap] CRITICAL: %d/%d enemy definition schema tests FAILED. Halting server initialization.",
		enemySummary.failed,
		enemySummary.total
	))
end
print(string.format("[CLAYSTRIKE - EnemyTests] %d/%d enemy definition schema tests PASSED.", enemySummary.passed, enemySummary.total))

-- 8. Execute weapon service combat cadence unit tests
local weaponServiceSummary = WeaponServiceTests.RunTests(WeaponService)
if weaponServiceSummary.failed > 0 then
	error(string.format(
		"[CLAYSTRIKE - ServerBootstrap] CRITICAL: %d/%d weapon service tests FAILED. Halting server initialization.",
		weaponServiceSummary.failed,
		weaponServiceSummary.total
	))
end
print(string.format("[CLAYSTRIKE - WeaponServiceTests] %d/%d weapon service tests PASSED.", weaponServiceSummary.passed, weaponServiceSummary.total))

-- 8. Execute server projectile simulation & anti-tunneling hit tests
local projectileSummary = ProjectileSimulationTests.RunTests(ProjectileService)
if projectileSummary.failed > 0 then
	error(string.format(
		"[CLAYSTRIKE - ServerBootstrap] CRITICAL: %d/%d projectile simulation tests FAILED. Halting server initialization.",
		projectileSummary.failed,
		projectileSummary.total
	))
end
print(string.format("[CLAYSTRIKE - ProjectileSimulationTests] %d/%d projectile simulation tests PASSED.", projectileSummary.passed, projectileSummary.total))

-- 9. Execute enemy lifecycle & spawn factory unit tests
local enemyServiceSummary = EnemyServiceTests.RunTests(EnemyService)
if enemyServiceSummary.failed > 0 then
	error(string.format(
		"[CLAYSTRIKE - ServerBootstrap] CRITICAL: %d/%d enemy service tests FAILED. Halting server initialization.",
		enemyServiceSummary.failed,
		enemyServiceSummary.total
	))
end
print(string.format("[CLAYSTRIKE - EnemyServiceTests] %d/%d enemy service tests PASSED.", enemyServiceSummary.passed, enemyServiceSummary.total))

-- 10. Execute Enemy Archetype A (StraightFlyer) movement simulation tests
local straightFlyerSummary = StraightFlyerTests.RunTests(EnemyService)
if straightFlyerSummary.failed > 0 then
	error(string.format(
		"[CLAYSTRIKE - ServerBootstrap] CRITICAL: %d/%d StraightFlyer simulation tests FAILED. Halting server initialization.",
		straightFlyerSummary.failed,
		straightFlyerSummary.total
	))
end
print(string.format("[CLAYSTRIKE - StraightFlyerTests] %d/%d StraightFlyer simulation tests PASSED.", straightFlyerSummary.passed, straightFlyerSummary.total))

-- 11. Initialize authoritative arena boundaries
ArenaService.Initialize()

-- 11. Initialize authoritative network remotes & security boundaries
RemoteManager.Initialize()

-- 12. Initialize authoritative aircraft lifecycle service
AircraftService.Initialize()

-- 13. Initialize authoritative movement simulation service
MovementService.Initialize()

-- 14. Initialize authoritative projectile simulation service
ProjectileService.Initialize()

-- 15. Initialize authoritative combat weapon service
WeaponService.Initialize()

-- 16. Initialize authoritative enemy lifecycle service
EnemyService.Initialize()


