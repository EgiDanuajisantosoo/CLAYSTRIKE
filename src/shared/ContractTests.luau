--!strict
--[[
	ContractTests.luau
	Isolated unit test harness for RemoteContracts validation.
	Task: CLAY-002 (Define Remote Contracts & Shared Config)

	Tests valid payloads and strictly asserts that malformed, non-finite,
	version-mismatched, and illegal-keyed payloads are safely rejected.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local RemoteContracts = require(SharedFolder:WaitForChild("RemoteContracts"))

local ContractTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	message: string?,
}

function ContractTests.RunTests(): { total: number, passed: number, failed: number, results: { TestResult } }
	local results: { TestResult } = {}
	local passedCount = 0
	local failedCount = 0

	local function assertTest(name: string, condition: boolean, detail: string?)
		if condition then
			passedCount += 1
			table.insert(results, { name = name, passed = true })
		else
			failedCount += 1
			table.insert(results, { name = name, passed = false, message = detail })
		end
	end

	-- 1. Valid MovePlane Payload
	local validMove = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 100.5,
		position = Vector2.new(10, 5),
		moveDirection = Vector2.new(1, 0),
	}
	local ok1, err1 = RemoteContracts.ValidateMovePlane(validMove)
	assertTest("Valid MovePlane payload is accepted", ok1 == true, err1)

	-- 2. Malformed MovePlane: NaN position
	local nanMove = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 100.5,
		position = Vector2.new(0 / 0, 0),
		moveDirection = Vector2.new(1, 0),
	}
	local ok2 = RemoteContracts.ValidateMovePlane(nanMove)
	assertTest("MovePlane with NaN position is rejected", ok2 == false)

	-- 3. Malformed MovePlane: math.huge (Infinity)
	local infMove = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 100.5,
		position = Vector2.new(math.huge, 0),
		moveDirection = Vector2.new(1, 0),
	}
	local ok3 = RemoteContracts.ValidateMovePlane(infMove)
	assertTest("MovePlane with Infinity position is rejected", ok3 == false)

	-- 4. Malformed MovePlane: Illegal forbidden field (damage)
	local exploitMove = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 100.5,
		position = Vector2.new(10, 5),
		moveDirection = Vector2.new(1, 0),
		damage = 9999, -- FORBIDDEN
	}
	local ok4 = RemoteContracts.ValidateMovePlane(exploitMove)
	assertTest("MovePlane with forbidden 'damage' field is rejected", ok4 == false)

	-- 5. Malformed MovePlane: Out of arena bounds
	local oobMove = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 100.5,
		position = Vector2.new(9999, 9999),
		moveDirection = Vector2.new(1, 0),
	}
	local ok5 = RemoteContracts.ValidateMovePlane(oobMove)
	assertTest("MovePlane with out-of-bounds position is rejected", ok5 == false)

	-- 6. Malformed MovePlane: Contract version mismatch
	local versionMismatchMove = {
		contractVersion = "9.9.9",
		clientTimestamp = 100.5,
		position = Vector2.new(10, 5),
		moveDirection = Vector2.new(1, 0),
	}
	local ok6 = RemoteContracts.ValidateMovePlane(versionMismatchMove)
	assertTest("MovePlane with mismatched contract version is rejected", ok6 == false)

	-- 7. Valid FireWeapon Payload
	local validFire = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 101.2,
		weaponId = "StandardPeaShooter",
		origin = Vector2.new(0, 0),
		aimDirection = Vector2.new(1, 0),
	}
	local ok7, err7 = RemoteContracts.ValidateFireWeapon(validFire)
	assertTest("Valid FireWeapon payload is accepted", ok7 == true, err7)

	-- 8. Malformed FireWeapon: Illegal forbidden field (enemyHealth)
	local exploitFire = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 101.2,
		weaponId = "StandardPeaShooter",
		origin = Vector2.new(0, 0),
		aimDirection = Vector2.new(1, 0),
		enemyHealth = 0, -- FORBIDDEN
	}
	local ok8 = RemoteContracts.ValidateFireWeapon(exploitFire)
	assertTest("FireWeapon with forbidden 'enemyHealth' field is rejected", ok8 == false)

	-- 9. Malformed FireWeapon: Unknown weaponId
	local fakeWeaponFire = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 101.2,
		weaponId = "NonExistentNuke9000",
		origin = Vector2.new(0, 0),
		aimDirection = Vector2.new(1, 0),
	}
	local ok9 = RemoteContracts.ValidateFireWeapon(fakeWeaponFire)
	assertTest("FireWeapon with unknown weaponId is rejected", ok9 == false)

	-- 10. Malformed FireWeapon: Zero aim vector
	local zeroAimFire = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 101.2,
		weaponId = "StandardPeaShooter",
		origin = Vector2.new(0, 0),
		aimDirection = Vector2.new(0, 0),
	}
	local ok10 = RemoteContracts.ValidateFireWeapon(zeroAimFire)
	assertTest("FireWeapon with zero aim vector is rejected", ok10 == false)

	-- 11. Valid GameStateChanged Payload
	local validState = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		serverTimestamp = 102.0,
		state = "WaveActive",
		details = { waveNumber = 1 },
	}
	local ok11, err11 = RemoteContracts.ValidateGameStateChanged(validState)
	assertTest("Valid GameStateChanged payload is accepted", ok11 == true, err11)

	-- 12. Malformed GameStateChanged: Invalid state enum
	local invalidState = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		serverTimestamp = 102.0,
		state = "AdminNukeAllEnemies",
	}
	local ok12 = RemoteContracts.ValidateGameStateChanged(invalidState)
	assertTest("GameStateChanged with unknown state is rejected", ok12 == false)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return ContractTests
