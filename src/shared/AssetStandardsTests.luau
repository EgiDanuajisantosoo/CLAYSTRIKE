--!strict
--[[
	AssetStandardsTests.luau
	Authoritative unit test harness for Asset Import & Performance Standards.
	Task: CLAY-048 (Asset Import & Performance Standards)

	TEST SUITE:
	1. Budget Schema Completeness: Budgets defined for all asset categories.
	2. Production Player Aircraft Compliance: Validates against PlayerAircraft standards (0 errors).
	3. Production StraightFlyer Compliance: Validates against StraightFlyer standards (0 errors).
	4. Production Pursuer Compliance: Validates against Pursuer standards (0 errors).
	5. Production TurretShooter Compliance: Validates against TurretShooter standards (0 errors).
	6. Failure Detection - Missing PrimaryPart: Rejects model without PrimaryPart.
	7. Failure Detection - Illegal Collisions: Rejects visual part with CanCollide=true.
	8. Failure Detection - Missing Attachment: Rejects model missing required Muzzle/Center.
	9. Failure Detection - Over Budget: Rejects model exceeding max part count.
	10. Auto-Sanitization: SanitizeModel fixes collisions and missing welds on un-sanitized models.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local AssetStandards = require(SharedFolder:WaitForChild("AssetStandards"))
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
if (EnemyConfig :: any).Archetypes == nil then
	EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"):Clone())
end

local Services = ServerScriptService:WaitForChild("Services")
local AircraftFactory = require(Services:WaitForChild("AircraftFactory"))
local EnemyFactory = require(Services:WaitForChild("EnemyFactory"))

local AssetStandardsTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function AssetStandardsTests.RunTests(): {
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
			warn(string.format("[AssetStandardsTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- 1. Budget Schema Completeness
	assertTest("PlayerAircraft budget defined", AssetStandards.Budgets["PlayerAircraft"] ~= nil)
	assertTest("StraightFlyer budget defined", AssetStandards.Budgets["StraightFlyer"] ~= nil)
	assertTest("Pursuer budget defined", AssetStandards.Budgets["Pursuer"] ~= nil)
	assertTest("TurretShooter budget defined", AssetStandards.Budgets["TurretShooter"] ~= nil)

	-- 2. Production Player Aircraft Compliance
	local playerPlane = AircraftFactory.CreatePlayerAircraft(12345, Vector3.new(0, 0, 0))
	playerPlane.Parent = Workspace
	local planeValid, planeErrs = AssetStandards.ValidateModel(playerPlane, "PlayerAircraft")
	assertTest(string.format("Production Player Aircraft passes standards validation (%s)", table.concat(planeErrs, "; ")), planeValid == true)
	playerPlane:Destroy()

	-- 3. Production StraightFlyer Compliance
	local flyerDef = EnemyConfig.GetEnemy(EnemyConfig.Archetypes.StraightFlyer) :: EnemyConfig.EnemyDefinition
	local flyer = EnemyFactory.CreateEnemyModel(flyerDef)
	flyer.Parent = Workspace
	local flyerValid, flyerErrs = AssetStandards.ValidateModel(flyer, "StraightFlyer")
	assertTest(string.format("Production StraightFlyer passes standards validation (%s)", table.concat(flyerErrs, "; ")), flyerValid == true)
	flyer:Destroy()

	-- 4. Production Pursuer Compliance
	local pursuerDef = EnemyConfig.GetEnemy(EnemyConfig.Archetypes.Pursuer) :: EnemyConfig.EnemyDefinition
	local pursuer = EnemyFactory.CreateEnemyModel(pursuerDef)
	pursuer.Parent = Workspace
	local pursuerValid, pursuerErrs = AssetStandards.ValidateModel(pursuer, "Pursuer")
	assertTest(string.format("Production Pursuer passes standards validation (%s)", table.concat(pursuerErrs, "; ")), pursuerValid == true)
	pursuer:Destroy()

	-- 5. Production TurretShooter Compliance
	local turretDef = EnemyConfig.GetEnemy(EnemyConfig.Archetypes.TurretShooter) :: EnemyConfig.EnemyDefinition
	local turret = EnemyFactory.CreateEnemyModel(turretDef)
	turret.Parent = Workspace
	local turretValid, turretErrs = AssetStandards.ValidateModel(turret, "TurretShooter")
	assertTest(string.format("Production TurretShooter passes standards validation (%s)", table.concat(turretErrs, "; ")), turretValid == true)
	turret:Destroy()

	-- 6. Failure Detection: Missing PrimaryPart
	local badModel1 = Instance.new("Model")
	badModel1.Name = "BadModel1"
	local bPart = Instance.new("Part")
	bPart.Name = "RootPart"
	bPart.Parent = badModel1
	-- Deliberately omit badModel1.PrimaryPart
	local valid1, errs1 = AssetStandards.ValidateModel(badModel1, "PlayerAircraft")
	assertTest("Rejects model with missing PrimaryPart", valid1 == false and #errs1 > 0)
	badModel1:Destroy()

	-- 7. Failure Detection: Illegal Collisions
	local badModel2 = Instance.new("Model")
	local root2 = Instance.new("Part")
	root2.Name = "RootPart"
	root2.CanCollide = false
	root2.CanTouch = false
	root2.CanQuery = true
	root2.Anchored = true
	root2.Parent = badModel2
	badModel2.PrimaryPart = root2

	local illegalVisual = Instance.new("Part")
	illegalVisual.Name = "Wing"
	illegalVisual.CanCollide = true -- ILLEGAL!
	illegalVisual.Parent = badModel2
	local w2 = Instance.new("WeldConstraint")
	w2.Part0 = root2
	w2.Part1 = illegalVisual
	w2.Parent = root2

	local valid2, _ = AssetStandards.ValidateModel(badModel2, "PlayerAircraft")
	assertTest("Rejects visual part with CanCollide=true", valid2 == false)
	badModel2:Destroy()

	-- 8. Failure Detection: Missing Required Attachment
	local badModel3 = Instance.new("Model")
	local root3 = Instance.new("Part")
	root3.Name = "RootPart"
	root3.CanCollide = false
	root3.CanTouch = false
	root3.CanQuery = true
	root3.Anchored = true
	root3.Parent = badModel3
	badModel3.PrimaryPart = root3
	-- Deliberately omit required "Center", "Muzzle", "Exhaust" attachments
	local valid3, _ = AssetStandards.ValidateModel(badModel3, "PlayerAircraft")
	assertTest("Rejects model with missing required attachments", valid3 == false)
	badModel3:Destroy()

	-- 9. Failure Detection: Over Budget
	local badModel4 = Instance.new("Model")
	local root4 = Instance.new("Part")
	root4.Name = "HitProxy"
	root4.CanCollide = false
	root4.CanTouch = false
	root4.CanQuery = true
	root4.Anchored = true
	root4.Parent = badModel4
	badModel4.PrimaryPart = root4
	local centerAtt = Instance.new("Attachment")
	centerAtt.Name = "Center"
	centerAtt.Parent = root4

	-- Add 15 parts to a StraightFlyer (limit is 8)
	for i = 1, 15 do
		local p = Instance.new("Part")
		p.Name = "Part" .. i
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.Anchored = true
		p.Parent = badModel4
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root4
		weld.Part1 = p
		weld.Parent = root4
	end
	local valid4, _ = AssetStandards.ValidateModel(badModel4, "StraightFlyer")
	assertTest("Rejects model with 16 parts exceeding StraightFlyer budget (8)", valid4 == false)
	badModel4:Destroy()

	-- 10. Auto-Sanitization
	local rawModel = Instance.new("Model")
	local rawRoot = Instance.new("Part")
	rawRoot.Name = "HitProxy"
	rawRoot.CanCollide = true -- Needs fixing
	rawRoot.CanTouch = true -- Needs fixing
	rawRoot.CanQuery = false -- Needs fixing
	rawRoot.Anchored = false -- Needs fixing
	rawRoot.Parent = rawModel

	local rawWing = Instance.new("Part")
	rawWing.Name = "RawWing"
	rawWing.CanCollide = true -- Needs fixing
	rawWing.CanTouch = true -- Needs fixing
	rawWing.CanQuery = true -- Needs fixing
	rawWing.Parent = rawModel
	-- Missing weld between rawRoot and rawWing

	local rawCenter = Instance.new("Attachment")
	rawCenter.Name = "Center"
	rawCenter.Parent = rawRoot

	local sanSuccess, _ = AssetStandards.SanitizeModel(rawModel, "StraightFlyer")
	assertTest("SanitizeModel successfully repairs raw model collisions and welds", sanSuccess == true)
	assertTest("Sanitized PrimaryPart has CanCollide=false", rawRoot.CanCollide == false)
	assertTest("Sanitized PrimaryPart has CanQuery=true", rawRoot.CanQuery == true)
	assertTest("Sanitized visual wing has CanCollide=false", rawWing.CanCollide == false)
	rawModel:Destroy()

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return AssetStandardsTests
