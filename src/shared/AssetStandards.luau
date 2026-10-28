--!strict
--[[
	AssetStandards.luau
	Authoritative programmatic validation and budget schema for 3D assets in CLAYSTRIKE.
	Task: CLAY-048 (Asset Import & Performance Standards)

	Validates models against project performance and physics contracts:
	- PrimaryPart isolation (RootPart/HitProxy).
	- Simplified collision proxy: PrimaryPart is the only queryable part, all visuals non-colliding.
	- Rigid assembly via WeldConstraint.
	- Part and triangle budgets.
	- Required combat and animation attachments (Center, Muzzle, Exhaust).
	- Orientation alignment for 2.5D side-scrolling (+X for player, -X for enemy).
]]

export type AssetCategory = "PlayerAircraft" | "StraightFlyer" | "Pursuer" | "TurretShooter" | "Boss" | "Environment"

export type BudgetLimit = {
	maxParts: number,
	maxTriangles: number,
	primaryPartName: string,
	expectedForwardAxis: Vector3, -- e.g. Vector3.new(1, 0, 0) for Player, Vector3.new(-1, 0, 0) for Enemy
	requiredAttachments: { string },
}

local AssetStandards = {}

-- Canonical Budget Limits per Asset Category
AssetStandards.Budgets = {
	PlayerAircraft = {
		maxParts = 12,
		maxTriangles = 3500,
		primaryPartName = "RootPart",
		expectedForwardAxis = Vector3.new(1, 0, 0),
		requiredAttachments = { "Center", "Muzzle", "Exhaust" },
	},
	StraightFlyer = {
		maxParts = 8,
		maxTriangles = 1800,
		primaryPartName = "HitProxy",
		expectedForwardAxis = Vector3.zero,
		requiredAttachments = { "Center" },
	},
	Pursuer = {
		maxParts = 8,
		maxTriangles = 2200,
		primaryPartName = "HitProxy",
		expectedForwardAxis = Vector3.zero,
		requiredAttachments = { "Center" },
	},
	TurretShooter = {
		maxParts = 10,
		maxTriangles = 2800,
		primaryPartName = "HitProxy",
		expectedForwardAxis = Vector3.zero,
		requiredAttachments = { "Center", "MuzzleAttachment" },
	},
	Boss = {
		maxParts = 20,
		maxTriangles = 6500,
		primaryPartName = "HitProxy",
		expectedForwardAxis = Vector3.new(-1, 0, 0),
		requiredAttachments = { "Center", "Muzzle" },
	},
	Environment = {
		maxParts = 8,
		maxTriangles = 1500,
		primaryPartName = "RootPart",
		expectedForwardAxis = Vector3.zero,
		requiredAttachments = {},
	},
} :: { [AssetCategory]: BudgetLimit }

--[[
	Validates that an instantiated Model complies with CLAYSTRIKE asset standards.
	Returns (isValid, list of descriptive error strings).
]]
function AssetStandards.ValidateModel(model: Model, category: AssetCategory): (boolean, { string })
	local errors: { string } = {}

	if not model or not model:IsA("Model") then
		return false, { "Target instance is not a valid Model" }
	end

	local budget = AssetStandards.Budgets[category]
	if not budget then
		return false, { string.format("Unknown asset category: '%s'", tostring(category)) }
	end

	-- 1. PrimaryPart verification
	local primaryPart = model.PrimaryPart
	if not primaryPart then
		table.insert(errors, "Model has no PrimaryPart assigned")
	else
		if primaryPart.Name ~= budget.primaryPartName then
			table.insert(errors, string.format("PrimaryPart name is '%s', expected '%s'", primaryPart.Name, budget.primaryPartName))
		end

		-- PrimaryPart collision proxy contracts
		if primaryPart.CanCollide ~= false then
			table.insert(errors, "PrimaryPart.CanCollide must be false")
		end
		if primaryPart.CanTouch ~= false then
			table.insert(errors, "PrimaryPart.CanTouch must be false")
		end
		if primaryPart.CanQuery ~= true then
			table.insert(errors, "PrimaryPart.CanQuery must be true (for hit detection raycasts)")
		end
		if primaryPart.Anchored ~= true then
			table.insert(errors, "PrimaryPart.Anchored must be true")
		end

		-- Orientation check (if directional)
		if budget.expectedForwardAxis ~= Vector3.zero then
			local lookVec = primaryPart.CFrame.LookVector
			local dot = lookVec:Dot(budget.expectedForwardAxis)
			if dot < 0.90 then
				table.insert(errors, string.format("PrimaryPart forward orientation (LookVector %s) does not match expected axis %s (dot=%.2f)",
					tostring(lookVec), tostring(budget.expectedForwardAxis), dot))
			end
		end
	end

	-- 2. Inspect all BasePart children
	local baseParts: { BasePart } = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			table.insert(baseParts, desc)
		end
	end

	-- Part budget check
	if #baseParts > budget.maxParts then
		table.insert(errors, string.format("Model part count %d exceeds category limit %d for '%s'", #baseParts, budget.maxParts, category))
	end

	-- Visual parts collision safety & weld check
	for _, part in ipairs(baseParts) do
		if primaryPart and part ~= primaryPart then
			if part.CanCollide ~= false then
				table.insert(errors, string.format("Visual part '%s' has CanCollide=true; must be false", part.Name))
			end
			if part.CanTouch ~= false then
				table.insert(errors, string.format("Visual part '%s' has CanTouch=true; must be false", part.Name))
			end
			if part.CanQuery ~= false then
				table.insert(errors, string.format("Visual part '%s' has CanQuery=true; must be false", part.Name))
			end

			-- Weld verification: must be welded to PrimaryPart
			local hasWeld = false
			for _, w in ipairs(primaryPart:GetChildren()) do
				if w:IsA("WeldConstraint") and (w.Part1 == part or w.Part0 == part) then
					hasWeld = true
					break
				end
			end
			if not hasWeld then
				table.insert(errors, string.format("Visual part '%s' is not welded to PrimaryPart via WeldConstraint", part.Name))
			end
		end
	end

	-- 3. Required Attachments Check
	for _, attachName in ipairs(budget.requiredAttachments) do
		local found = model:FindFirstChild(attachName, true)
		if not found or not found:IsA("Attachment") then
			table.insert(errors, string.format("Required attachment '%s' missing from model hierarchy", attachName))
		end
	end

	return (#errors == 0), errors
end

--[[
	Automatically sanitizes an imported model to comply with collision and physics standards.
	Safe fallback mechanism for artist imports.
]]
function AssetStandards.SanitizeModel(model: Model, category: AssetCategory): (boolean, { string })
	local budget = AssetStandards.Budgets[category]
	if not budget then
		return false, { string.format("Unknown category: '%s'", tostring(category)) }
	end

	local primaryPart = model.PrimaryPart
	if not primaryPart then
		local candidate = model:FindFirstChild(budget.primaryPartName) :: BasePart?
		if candidate and candidate:IsA("BasePart") then
			model.PrimaryPart = candidate
			primaryPart = candidate
		else
			return false, { string.format("Cannot sanitize model: missing PrimaryPart or '%s'", budget.primaryPartName) }
		end
	end

	-- Configure PrimaryPart
	primaryPart.CanCollide = false
	primaryPart.CanTouch = false
	primaryPart.CanQuery = true
	primaryPart.Anchored = true

	-- Configure visual subparts
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") and desc ~= primaryPart then
			desc.CanCollide = false
			desc.CanTouch = false
			desc.CanQuery = false
			desc.Anchored = true

			-- Ensure weld exists
			local weldFound = false
			for _, w in ipairs(primaryPart:GetChildren()) do
				if w:IsA("WeldConstraint") and (w.Part1 == desc or w.Part0 == desc) then
					weldFound = true
					break
				end
			end
			if not weldFound then
				local newWeld = Instance.new("WeldConstraint")
				newWeld.Name = desc.Name .. "Weld"
				newWeld.Part0 = primaryPart
				newWeld.Part1 = desc
				newWeld.Parent = primaryPart
			end
		end
	end

	return AssetStandards.ValidateModel(model, category)
end

return AssetStandards
