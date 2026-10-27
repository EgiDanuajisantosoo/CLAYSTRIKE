--!strict
--[[
	ContractTests.luau
	Isolated unit test harness for RemoteContracts and RateLimiter validation.
	Task: CLAY-002 (Define Remote Contracts & Shared Config)

	Tests valid payloads and strictly asserts that malformed, non-finite,
	version-mismatched, client-claimed position/origin, details schema violations,
	and unconfigured/exhausted rate limits are safely rejected.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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

	-- 1. Valid MovePlane Payload (pure intent: direction only)
	local validMove = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 100.5,
		moveDirection = Vector2.new(1, 0),
	}
	local ok1, err1 = RemoteContracts.ValidateMovePlane(validMove)
	assertTest("Valid MovePlane intent payload is accepted", ok1 == true, err1)

	-- 2. MovePlane boundary check: 1.04 is allowed (<= 1.05)
	local boundaryMove = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 100.5,
		moveDirection = Vector2.new(1.04, 0),
	}
	local ok2, err2 = RemoteContracts.ValidateMovePlane(boundaryMove)
	assertTest("MovePlane with 1.04 magnitude is accepted under 1.05 tolerance", ok2 == true, err2)

	-- 3. Malformed MovePlane: Client attempts to send position (rejected by whitelist)
	local clientPositionMove = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 100.5,
		moveDirection = Vector2.new(1, 0),
		position = Vector2.new(10, 5),
	}
	local ok3 = RemoteContracts.ValidateMovePlane(clientPositionMove)
	assertTest("MovePlane with client-provided position is rejected", ok3 == false)

	-- 4. Malformed MovePlane: NaN moveDirection
	local nanMove = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 100.5,
		moveDirection = Vector2.new(0 / 0, 0),
	}
	local ok4 = RemoteContracts.ValidateMovePlane(nanMove)
	assertTest("MovePlane with NaN moveDirection is rejected", ok4 == false)

	-- 5. Malformed MovePlane: math.huge (Infinity)
	local infMove = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 100.5,
		moveDirection = Vector2.new(math.huge, 0),
	}
	local ok5 = RemoteContracts.ValidateMovePlane(infMove)
	assertTest("MovePlane with Infinity moveDirection is rejected", ok5 == false)

	-- 6. Malformed MovePlane: Excessive direction magnitude (> 1.05)
	local excessiveMove = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 100.5,
		moveDirection = Vector2.new(1.10, 0),
	}
	local ok6 = RemoteContracts.ValidateMovePlane(excessiveMove)
	assertTest("MovePlane exceeding 1.05 magnitude is rejected", ok6 == false)

	-- 7. Malformed MovePlane: Illegal forbidden field (damage)
	local exploitMove = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 100.5,
		moveDirection = Vector2.new(1, 0),
		damage = 9999,
	}
	local ok7 = RemoteContracts.ValidateMovePlane(exploitMove)
	assertTest("MovePlane with forbidden 'damage' field is rejected", ok7 == false)

	-- 8. Malformed MovePlane: Contract version mismatch
	local versionMismatchMove = {
		contractVersion = "9.9.9",
		clientTimestamp = 100.5,
		moveDirection = Vector2.new(1, 0),
	}
	local ok8 = RemoteContracts.ValidateMovePlane(versionMismatchMove)
	assertTest("MovePlane with mismatched contract version is rejected", ok8 == false)

	-- 9. Valid FireWeapon Payload (pure intent: weaponId + aimDirection)
	local validFire = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 101.2,
		weaponId = "StandardPeaShooter",
		aimDirection = Vector2.new(1, 0),
	}
	local ok9, err9 = RemoteContracts.ValidateFireWeapon(validFire)
	assertTest("Valid FireWeapon intent payload is accepted", ok9 == true, err9)

	-- 10. FireWeapon boundary check: aimDirection magnitude up to 1.05 is allowed
	local boundaryAimFire = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 101.2,
		weaponId = "StandardPeaShooter",
		aimDirection = Vector2.new(1.04, 0),
	}
	local ok10, err10 = RemoteContracts.ValidateFireWeapon(boundaryAimFire)
	assertTest("FireWeapon with 1.04 aim magnitude is accepted under 1.05 limit", ok10 == true, err10)

	-- 11. Malformed FireWeapon: aimDirection magnitude exceeding 1.05 is rejected
	local excessiveAimFire = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 101.2,
		weaponId = "StandardPeaShooter",
		aimDirection = Vector2.new(5.0, 0),
	}
	local ok11 = RemoteContracts.ValidateFireWeapon(excessiveAimFire)
	assertTest("FireWeapon with excessive aim magnitude (> 1.05) is rejected", ok11 == false)

	-- 12. Malformed FireWeapon: Client attempts to send origin (rejected by whitelist)
	local clientOriginFire = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 101.2,
		weaponId = "StandardPeaShooter",
		origin = Vector2.new(100, 200),
		aimDirection = Vector2.new(1, 0),
	}
	local ok12 = RemoteContracts.ValidateFireWeapon(clientOriginFire)
	assertTest("FireWeapon with client-provided origin is rejected", ok12 == false)

	-- 13. Malformed FireWeapon: Illegal forbidden field (enemyHealth)
	local exploitFire = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 101.2,
		weaponId = "StandardPeaShooter",
		aimDirection = Vector2.new(1, 0),
		enemyHealth = 0,
	}
	local ok13 = RemoteContracts.ValidateFireWeapon(exploitFire)
	assertTest("FireWeapon with forbidden 'enemyHealth' field is rejected", ok13 == false)

	-- 14. Malformed FireWeapon: Unknown weaponId
	local fakeWeaponFire = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 101.2,
		weaponId = "NonExistentNuke9000",
		aimDirection = Vector2.new(1, 0),
	}
	local ok14 = RemoteContracts.ValidateFireWeapon(fakeWeaponFire)
	assertTest("FireWeapon with unknown weaponId is rejected", ok14 == false)

	-- 15. Malformed FireWeapon: Zero aim vector
	local zeroAimFire = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = 101.2,
		weaponId = "StandardPeaShooter",
		aimDirection = Vector2.new(0, 0),
	}
	local ok15 = RemoteContracts.ValidateFireWeapon(zeroAimFire)
	assertTest("FireWeapon with zero aim vector is rejected", ok15 == false)

	-- 16. Valid GameStateChanged: WaveActive with typed integer details
	local validWaveState = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		serverTimestamp = 102.0,
		state = "WaveActive",
		details = {
			waveNumber = 1,
			remainingEnemies = 10,
		},
	}
	local ok16, err16 = RemoteContracts.ValidateGameStateChanged(validWaveState)
	assertTest("Valid GameStateChanged WaveActive payload with typed details is accepted", ok16 == true, err16)

	-- 17. Malformed GameStateChanged: WaveActive with non-integer waveNumber (2.5)
	local floatWaveState = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		serverTimestamp = 102.0,
		state = "WaveActive",
		details = {
			waveNumber = 2.5, -- Non-integer
			remainingEnemies = 10,
		},
	}
	local ok17 = RemoteContracts.ValidateGameStateChanged(floatWaveState)
	assertTest("GameStateChanged WaveActive with non-integer waveNumber is rejected", ok17 == false)

	-- 18. Malformed GameStateChanged: WaveActive with negative remainingEnemies (-1)
	local negativeEnemyState = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		serverTimestamp = 102.0,
		state = "WaveActive",
		details = {
			waveNumber = 2,
			remainingEnemies = -1, -- Negative
		},
	}
	local ok18 = RemoteContracts.ValidateGameStateChanged(negativeEnemyState)
	assertTest("GameStateChanged WaveActive with negative remainingEnemies is rejected", ok18 == false)

	-- 19. Malformed GameStateChanged: WaveActive with illegal extra field in details
	local extraFieldState = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		serverTimestamp = 102.0,
		state = "WaveActive",
		details = {
			waveNumber = 2,
			remainingEnemies = 10,
			secretAdminCode = "xyz", -- FORBIDDEN
		},
	}
	local ok19 = RemoteContracts.ValidateGameStateChanged(extraFieldState)
	assertTest("GameStateChanged with illegal extra field in details is rejected", ok19 == false)

	-- 20. Malformed GameStateChanged: WaveActive missing required details table
	local missingDetailsState = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		serverTimestamp = 102.0,
		state = "WaveActive",
	}
	local ok20 = RemoteContracts.ValidateGameStateChanged(missingDetailsState)
	assertTest("GameStateChanged WaveActive missing required details table is rejected", ok20 == false)

	-- 21. Malformed GameStateChanged: Intermission missing required details table
	local missingIntermissionDetails = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		serverTimestamp = 102.0,
		state = "Intermission",
	}
	local ok21 = RemoteContracts.ValidateGameStateChanged(missingIntermissionDetails)
	assertTest("GameStateChanged Intermission missing required details table is rejected", ok21 == false)

	-- 22. Malformed GameStateChanged: Invalid state enum
	local invalidState = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		serverTimestamp = 102.0,
		state = "AdminNukeAllEnemies",
	}
	local ok22 = RemoteContracts.ValidateGameStateChanged(invalidState)
	assertTest("GameStateChanged with unknown state is rejected", ok22 == false)

	-- 23 & 24. RateLimiter Server-Side Unit Tests (Fail-Closed & Exhaustion)
	if RunService:IsServer() then
		local ServerScriptService = game:GetService("ServerScriptService")
		local servicesFolder = ServerScriptService:FindFirstChild("Services")
		assertTest("Services folder exists on server", servicesFolder ~= nil)
		local rateLimiterMod = servicesFolder and servicesFolder:FindFirstChild("RateLimiter")
		assertTest("RateLimiter module exists on server", rateLimiterMod ~= nil and rateLimiterMod:IsA("ModuleScript"))
		if rateLimiterMod and rateLimiterMod:IsA("ModuleScript") then
			local RateLimiter = require(rateLimiterMod)

			-- Test 23: Fail-closed on unconfigured remote
			local unconfOk = RateLimiter.CheckRateLimit("TestPlayer_Unit1", "UnconfiguredHackedRemote")
			assertTest("RateLimiter rejects unconfigured remote under fail-closed policy", unconfOk == false)

			-- Test 24: Rate limit exhaustion blocks requests
			RateLimiter._ResetPlayer("TestPlayer_Unit2")
			local rule = GameConfig.NetworkRateLimits.FireWeapon
			local maxCapacity = rule.maxPerSecond + rule.burstAllowance
			for _ = 1, maxCapacity do
				RateLimiter.CheckRateLimit("TestPlayer_Unit2", "FireWeapon")
			end
			local exhaustedOk = RateLimiter.CheckRateLimit("TestPlayer_Unit2", "FireWeapon")
			assertTest("RateLimiter blocks requests exceeding capacity", exhaustedOk == false)
			RateLimiter._ResetPlayer("TestPlayer_Unit2")
		end
	end

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return ContractTests
