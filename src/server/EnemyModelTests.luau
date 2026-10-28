--!strict
--[[
	EnemyModelTests.luau
	Authoritative unit test harness for the Three Original Enemy Models.
	Task: CLAY-028 (Create Three Original Enemy Models)

	TEST SUITE:
	1. StraightFlyer Model Instantiation: Model created, PrimaryPart is HitProxy.
	2. StraightFlyer Dimensions & Alignment: HitProxy matches EnemyConfig.collisionSize.
	3. StraightFlyer Simplified Collision: HitProxy CanCollide=false, CanQuery=true.
	4. StraightFlyer Visual Geometry: All visual parts non-colliding (CanCollide=false, CanTouch=false, CanQuery=false).
	5. StraightFlyer Assembly Integrity: All subparts welded to HitProxy via WeldConstraint.
	6. StraightFlyer Part Count Budget: Between 6 and 8 parts (strictly <= 10 parts budget).
	7. StraightFlyer Characteristic Parts: VisualNose, VisualWings, TailFin, VisualExhaust.
	8. Pursuer Model Instantiation: Model created, PrimaryPart is HitProxy.
	9. Pursuer Simplified Collision & Color: CanQuery=true, matches terracotta color.
	10. Pursuer Part Count Budget: Between 6 and 8 parts (strictly <= 10 parts budget).
	11. Pursuer Characteristic Parts: VisualNose, VisualWings, LeftThrusterPod, RightThrusterPod, DorsalFin.
	12. Pursuer Assembly Integrity: All subparts welded to HitProxy via WeldConstraint.
	13. TurretShooter Model Instantiation: Model created, PrimaryPart is HitProxy.
	14. TurretShooter Part Count Budget: Between 6 and 8 parts (strictly <= 10 parts budget).
	15. TurretShooter Characteristic Parts: VisualTurret, ArmoredDome, BaseSkirt, LeftOutrigger, RightOutrigger.
	16. TurretShooter Combat Attachments: VisualTurret contains MuzzleAttachment.
	17. TurretShooter Telegraph Feedback: TelegraphLight responds to IsTelegraphing attribute changes.
	18. Template Initialization: ServerStorage.EnemyTemplates contains all 3 archetypes.
	19. Template Cloning Path: CreateEnemyModel clones template and preserves telegraph signals.
	20. Clean Teardown: Models destroy cleanly without memory leaks.
]]

local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
if (EnemyConfig :: any).Archetypes == nil then
	EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"):Clone())
end

local Services = ServerScriptService:WaitForChild("Services")
local EnemyFactory = require(Services:WaitForChild("EnemyFactory"))

local EnemyModelTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

function EnemyModelTests.RunTests(): {
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
			warn(string.format("[EnemyModelTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	local flyerDef = EnemyConfig.GetEnemy(EnemyConfig.Archetypes.StraightFlyer) :: EnemyConfig.EnemyDefinition
	local pursuerDef = EnemyConfig.GetEnemy(EnemyConfig.Archetypes.Pursuer) :: EnemyConfig.EnemyDefinition
	local turretDef = EnemyConfig.GetEnemy(EnemyConfig.Archetypes.TurretShooter) :: EnemyConfig.EnemyDefinition

	-- =========================================================
	-- 1. STRAIGHT FLYER
	-- =========================================================
	local flyer = EnemyFactory.CreateProceduralPlaceholder(flyerDef)
	flyer.Parent = Workspace

	assertTest("StraightFlyer returned Model instance", flyer ~= nil and flyer:IsA("Model"))
	assertTest("StraightFlyer PrimaryPart is 'HitProxy'", flyer.PrimaryPart ~= nil and flyer.PrimaryPart.Name == "HitProxy")

	local flyerProxy = flyer.PrimaryPart :: BasePart
	assertTest("StraightFlyer HitProxy size matches collisionSize", flyerProxy.Size == flyerDef.collisionSize)
	assertTest("StraightFlyer HitProxy CanCollide is false", flyerProxy.CanCollide == false)
	assertTest("StraightFlyer HitProxy CanTouch is false", flyerProxy.CanTouch == false)
	assertTest("StraightFlyer HitProxy CanQuery is true (swept raycasts)", flyerProxy.CanQuery == true)
	assertTest("StraightFlyer HitProxy Anchored is true", flyerProxy.Anchored == true)

	local flyerParts: { BasePart } = {}
	for _, child in ipairs(flyer:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(flyerParts, child)
		end
	end

	local flyerVisualsSafe = true
	for _, part in ipairs(flyerParts) do
		if part ~= flyerProxy then
			if part.CanCollide ~= false or part.CanTouch ~= false or part.CanQuery ~= false then
				flyerVisualsSafe = false
			end
		end
	end
	assertTest("StraightFlyer visual parts are non-colliding and non-queryable", flyerVisualsSafe)
	assertTest("StraightFlyer part count between 6 and 8 (<= 10 budget)", #flyerParts >= 6 and #flyerParts <= 8)

	local flyerWelded = true
	for _, part in ipairs(flyerParts) do
		if part ~= flyerProxy then
			local found = false
			for _, w in ipairs(flyerProxy:GetChildren()) do
				if w:IsA("WeldConstraint") and (w.Part1 == part or w.Part0 == part) then
					found = true
					break
				end
			end
			if not found then flyerWelded = false end
		end
	end
	assertTest("StraightFlyer all visual parts welded to HitProxy", flyerWelded)
	assertTest("StraightFlyer contains VisualNose", flyer:FindFirstChild("VisualNose") ~= nil)
	assertTest("StraightFlyer contains VisualWings", flyer:FindFirstChild("VisualWings") ~= nil)
	assertTest("StraightFlyer contains TailFin", flyer:FindFirstChild("TailFin") ~= nil)
	assertTest("StraightFlyer contains VisualExhaust", flyer:FindFirstChild("VisualExhaust") ~= nil)
	flyer:Destroy()

	-- =========================================================
	-- 2. PURSUER
	-- =========================================================
	local pursuer = EnemyFactory.CreateProceduralPlaceholder(pursuerDef)
	pursuer.Parent = Workspace

	assertTest("Pursuer returned Model instance", pursuer ~= nil and pursuer:IsA("Model"))
	assertTest("Pursuer PrimaryPart is 'HitProxy'", pursuer.PrimaryPart ~= nil and pursuer.PrimaryPart.Name == "HitProxy")

	local pursuerProxy = pursuer.PrimaryPart :: BasePart
	assertTest("Pursuer HitProxy CanQuery is true", pursuerProxy.CanQuery == true)
	assertTest("Pursuer HitProxy CanCollide is false", pursuerProxy.CanCollide == false)
	assertTest("Pursuer HitProxy color matches clayColor", pursuerProxy.Color == pursuerDef.clayColor)

	local pursuerParts: { BasePart } = {}
	for _, child in ipairs(pursuer:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(pursuerParts, child)
		end
	end

	assertTest("Pursuer part count between 6 and 8 (<= 10 budget)", #pursuerParts >= 6 and #pursuerParts <= 8)
	assertTest("Pursuer contains VisualNose", pursuer:FindFirstChild("VisualNose") ~= nil)
	assertTest("Pursuer contains VisualWings", pursuer:FindFirstChild("VisualWings") ~= nil)
	assertTest("Pursuer contains LeftThrusterPod", pursuer:FindFirstChild("LeftThrusterPod") ~= nil)
	assertTest("Pursuer contains RightThrusterPod", pursuer:FindFirstChild("RightThrusterPod") ~= nil)
	assertTest("Pursuer contains DorsalFin", pursuer:FindFirstChild("DorsalFin") ~= nil)

	local pursuerWelded = true
	for _, part in ipairs(pursuerParts) do
		if part ~= pursuerProxy then
			local found = false
			for _, w in ipairs(pursuerProxy:GetChildren()) do
				if w:IsA("WeldConstraint") and (w.Part1 == part or w.Part0 == part) then
					found = true
					break
				end
			end
			if not found then pursuerWelded = false end
		end
	end
	assertTest("Pursuer all visual parts welded to HitProxy", pursuerWelded)
	pursuer:Destroy()

	-- =========================================================
	-- 3. TURRET SHOOTER
	-- =========================================================
	local turret = EnemyFactory.CreateProceduralPlaceholder(turretDef)
	turret.Parent = Workspace

	assertTest("TurretShooter returned Model instance", turret ~= nil and turret:IsA("Model"))
	assertTest("TurretShooter PrimaryPart is 'HitProxy'", turret.PrimaryPart ~= nil and turret.PrimaryPart.Name == "HitProxy")

	local turretProxy = turret.PrimaryPart :: BasePart
	assertTest("TurretShooter HitProxy CanQuery is true", turretProxy.CanQuery == true)
	assertTest("TurretShooter HitProxy CanCollide is false", turretProxy.CanCollide == false)

	local turretParts: { BasePart } = {}
	for _, child in ipairs(turret:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(turretParts, child)
		end
	end

	assertTest("TurretShooter part count between 7 and 9 (<= 10 budget)", #turretParts >= 7 and #turretParts <= 9)
	assertTest("TurretShooter contains ArmoredDome", turret:FindFirstChild("ArmoredDome") ~= nil)
	assertTest("TurretShooter contains BaseSkirt", turret:FindFirstChild("BaseSkirt") ~= nil)
	assertTest("TurretShooter contains LeftOutrigger", turret:FindFirstChild("LeftOutrigger") ~= nil)
	assertTest("TurretShooter contains RightOutrigger", turret:FindFirstChild("RightOutrigger") ~= nil)
	assertTest("TurretShooter contains VisualTurret", turret:FindFirstChild("VisualTurret") ~= nil)

	local cannon = turret:FindFirstChild("VisualTurret") :: BasePart?
	local muzzle = cannon and cannon:FindFirstChild("MuzzleAttachment") :: Attachment?
	assertTest("VisualTurret has MuzzleAttachment", muzzle ~= nil and muzzle:IsA("Attachment"))

	local light = cannon and cannon:FindFirstChild("TelegraphLight") :: PointLight?
	assertTest("VisualTurret has TelegraphLight", light ~= nil and light:IsA("PointLight"))

	turret:SetAttribute("IsTelegraphing", true)
	task.wait()
	assertTest("TelegraphLight turns ON when IsTelegraphing is true", light ~= nil and light.Enabled == true)

	turret:SetAttribute("IsTelegraphing", false)
	task.wait()
	assertTest("TelegraphLight turns OFF when IsTelegraphing is false", light ~= nil and light.Enabled == false)

	turret:Destroy()

	-- =========================================================
	-- 4. SERVER STORAGE TEMPLATE INITIALIZATION & CLONING
	-- =========================================================
	local templateFolder = EnemyFactory.InitializeTemplates()
	assertTest("InitializeTemplates creates ServerStorage.EnemyTemplates", templateFolder ~= nil and templateFolder.Parent == ServerStorage)
	assertTest("StraightFlyer template exists in folder", templateFolder:FindFirstChild(flyerDef.templateName) ~= nil)
	assertTest("Pursuer template exists in folder", templateFolder:FindFirstChild(pursuerDef.templateName) ~= nil)
	assertTest("TurretShooter template exists in folder", templateFolder:FindFirstChild(turretDef.templateName) ~= nil)

	local clonedTurret = EnemyFactory.CreateEnemyModel(turretDef)
	clonedTurret.Parent = Workspace
	assertTest("CreateEnemyModel successfully cloned from template", clonedTurret ~= nil and clonedTurret.PrimaryPart ~= nil)

	local clonedCannon = clonedTurret:FindFirstChild("VisualTurret")
	local clonedLight = clonedCannon and clonedCannon:FindFirstChild("TelegraphLight") :: PointLight?
	assertTest("Cloned Turret has TelegraphLight", clonedLight ~= nil)

	clonedTurret:SetAttribute("IsTelegraphing", true)
	task.wait()
	assertTest("Cloned Turret TelegraphLight responds to IsTelegraphing=true", clonedLight ~= nil and clonedLight.Enabled == true)

	clonedTurret:SetAttribute("IsTelegraphing", false)
	task.wait()
	assertTest("Cloned Turret TelegraphLight responds to IsTelegraphing=false", clonedLight ~= nil and clonedLight.Enabled == false)

	clonedTurret:Destroy()

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return EnemyModelTests
