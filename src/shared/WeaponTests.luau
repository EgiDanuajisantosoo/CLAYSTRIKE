--!strict
--[[
	WeaponTests.luau
	Unit test harness for data-driven weapon configurations.
	Task: CLAY-009 (Weapon Data Definitions)

	Validates:
	1. Both MVP weapons (StandardPeaShooter and SpreadShot) are defined and structured.
	2. Value ranges: fireRate, cooldown, damage, projectileSpeed, lifetime, spreadAngles.
	3. Allowed game states are populated and match GameConfig.GameStates.
	4. Schema validator correctly detects missing fields, non-positive numbers, and bad types.
	5. Safe fallback default weapon handling.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local sharedWeaponConfig = SharedFolder:WaitForChild("WeaponConfig")
local WeaponConfig = require(sharedWeaponConfig)
if (WeaponConfig :: any).Weapons == nil then
	WeaponConfig = require(sharedWeaponConfig:Clone())
end

local WeaponTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function WeaponTests.RunTests(): {
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
			warn(string.format("[WeaponTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- 1. Validate All Registered Weapons
	local allValid, errors = WeaponConfig.ValidateAll()
	assertTest("WeaponConfig.ValidateAll() passes with 0 errors", allValid == true, table.concat(errors, "; "))

	-- 2. Standard Pea Shooter Verification
	local standard = WeaponConfig.GetWeapon("StandardPeaShooter")
	assertTest("StandardPeaShooter is registered", standard ~= nil)
	if standard then
		assertTest("StandardPeaShooter has single forward shot angle {0}", #standard.spreadAngles == 1 and standard.spreadAngles[1] == 0)
		assertTest("StandardPeaShooter cooldown is positive", standard.cooldown > 0)
		assertTest("StandardPeaShooter damage is positive", standard.baseDamage > 0)
		assertTest("StandardPeaShooter projectile speed > 100 studs/s", standard.projectileSpeed > 100)
		assertTest("StandardPeaShooter has valid bulletColor", typeof(standard.bulletColor) == "Color3")
	end

	-- 3. Spread Shot Verification
	local spread = WeaponConfig.GetWeapon("SpreadShot")
	assertTest("SpreadShot is registered", spread ~= nil)
	if spread then
		assertTest("SpreadShot has 3 spread angles", #spread.spreadAngles == 3)
		assertTest("SpreadShot cooldown > standard cooldown", standard ~= nil and spread.cooldown > standard.cooldown)
		assertTest("SpreadShot has positive baseDamage", spread.baseDamage > 0)
		assertTest("SpreadShot projectile speed is positive", spread.projectileSpeed > 0)
		assertTest("SpreadShot has valid bulletColor", typeof(spread.bulletColor) == "Color3")
	end

	-- 4. Default Weapon Handling
	local defaultWep = WeaponConfig.GetDefaultWeapon()
	assertTest("WeaponConfig.GetDefaultWeapon() returns valid definition", defaultWep ~= nil and defaultWep.id == WeaponConfig.DEFAULT_WEAPON_ID)
	assertTest("WeaponConfig.GetWeapon('NonExistentWeapon') returns nil safely", WeaponConfig.GetWeapon("NonExistentWeapon") == nil)

	-- 5. Validator Robustness / Bad Input Rejection
	local badIdDef = table.clone(defaultWep)
	badIdDef.id = ""
	local okBadId, _ = WeaponConfig.ValidateDefinition(badIdDef)
	assertTest("Validator rejects empty id", okBadId == false)

	local badCooldownDef = table.clone(defaultWep)
	badCooldownDef.cooldown = -0.5
	local okBadCooldown, _ = WeaponConfig.ValidateDefinition(badCooldownDef)
	assertTest("Validator rejects negative cooldown", okBadCooldown == false)

	local badDamageDef = table.clone(defaultWep)
	badDamageDef.baseDamage = 0
	local okBadDamage, _ = WeaponConfig.ValidateDefinition(badDamageDef)
	assertTest("Validator rejects zero baseDamage", okBadDamage == false)

	local badSpeedDef = table.clone(defaultWep)
	badSpeedDef.projectileSpeed = -10
	local okBadSpeed, _ = WeaponConfig.ValidateDefinition(badSpeedDef)
	assertTest("Validator rejects negative projectileSpeed", okBadSpeed == false)

	local badSpreadDef = table.clone(defaultWep)
	badSpreadDef.spreadAngles = {}
	local okBadSpread, _ = WeaponConfig.ValidateDefinition(badSpreadDef)
	assertTest("Validator rejects empty spreadAngles array", okBadSpread == false)

	local nonTableDef: any = "NotATable"
	local okNonTable, _ = WeaponConfig.ValidateDefinition(nonTableDef)
	assertTest("Validator rejects non-table definition", okNonTable == false)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return WeaponTests
