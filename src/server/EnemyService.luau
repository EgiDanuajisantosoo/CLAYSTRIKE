--!strict
--[[
	EnemyService.luau
	Authoritative server lifecycle manager for spawning, tracking, and cleaning up enemies.
	Task: CLAY-016 (Enemy Spawn Factory & Cleanup)

	RESPONSIBILITIES:
	- Authoritative spawning of enemies from EnemyConfig definitions.
	- Strict registration of spawned enemies in Workspace.ActiveEnemies.
	- Real-time tracking of active enemy records (health, archetype, position, lifecycle).
	- Deterministic cleanup and despawning on defeat, arena exit, or wave reset.
	- Zero orphaned instances or memory leaks.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
if (EnemyConfig :: any).Archetypes == nil then
	EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"):Clone())
end

local EnemyFactory = require(script.Parent:WaitForChild("EnemyFactory"))

export type ActiveEnemy = {
	id: string,
	archetypeId: string,
	model: Model,
	primaryPart: BasePart,
	currentHealth: number,
	maxHealth: number,
	scoreValue: number,
	spawnTime: number,
	isAlive: boolean,
	definition: EnemyConfig.EnemyDefinition,
}

local EnemyService = {}

local activeEnemies: { [string]: ActiveEnemy } = {}
local isInitialized = false
local spawnCounter = 0
local activeFolder: Folder? = nil

-- Helper to retrieve or create the authoritative ActiveEnemies container in Workspace
local function getActiveEnemiesFolder(): Folder
	local existingActive = Workspace:FindFirstChild("ActiveEnemies")
	if existingActive and existingActive:IsA("Folder") then
		activeFolder = existingActive
		return existingActive
	end

	local existingEnemies = Workspace:FindFirstChild("Enemies")
	if existingEnemies and existingEnemies:IsA("Folder") then
		activeFolder = existingEnemies
		return existingEnemies
	end

	local folder = Instance.new("Folder")
	folder.Name = "ActiveEnemies"
	folder.Parent = Workspace
	activeFolder = folder
	return folder
end

--[[
	Spawns an authoritative enemy of the specified archetype at spawnPosition.
	Returns (model, errorMessage).
]]
function EnemyService.SpawnEnemy(archetypeId: string, spawnPosition: Vector3): (Model?, string?)
	local def = EnemyConfig.GetEnemy(archetypeId)
	if not def then
		return nil, string.format("Unknown archetype ID: '%s'", tostring(archetypeId))
	end

	local container = getActiveEnemiesFolder()
	spawnCounter += 1
	local enemyId = string.format("Enemy_%s_%d", archetypeId, spawnCounter)

	-- 1. Create model via EnemyFactory
	local model = EnemyFactory.CreateEnemyModel(def)
	model.Name = enemyId

	local primary = model.PrimaryPart
	if not primary then
		model:Destroy()
		return nil, "Enemy model lacks a PrimaryPart"
	end

	-- 2. Position model
	model:PivotTo(CFrame.new(spawnPosition))

	-- 3. Set authoritative attributes
	model:SetAttribute("EnemyId", enemyId)
	model:SetAttribute("ArchetypeId", archetypeId)
	model:SetAttribute("MaxHealth", def.maxHealth)
	model:SetAttribute("CurrentHealth", def.maxHealth)
	model:SetAttribute("ScoreValue", def.scoreValue)
	model:SetAttribute("SpawnTime", os.clock())
	model:SetAttribute("IsAlive", true)
	model:SetAttribute("MovementType", def.movementType)
	model:SetAttribute("Speed", def.speed)

	-- Parent into authoritative container
	model.Parent = container

	-- 4. Register active record
	local record: ActiveEnemy = {
		id = enemyId,
		archetypeId = archetypeId,
		model = model,
		primaryPart = primary,
		currentHealth = def.maxHealth,
		maxHealth = def.maxHealth,
		scoreValue = def.scoreValue,
		spawnTime = os.clock(),
		isAlive = true,
		definition = def,
	}

	activeEnemies[enemyId] = record
	return model, nil
end

--[[
	Despawns a single active enemy by ID, cleaning up its model and tracking state.
	Returns true if enemy was found and despawned.
]]
function EnemyService.DespawnEnemy(enemyId: string): boolean
	local record = activeEnemies[enemyId]
	if not record then
		return false
	end

	record.isAlive = false
	activeEnemies[enemyId] = nil

	if record.model and record.model.Parent then
		record.model:Destroy()
	end

	return true
end

--[[
	Returns the ActiveEnemy record for the given ID, or nil if not active.
]]
function EnemyService.GetActiveEnemy(enemyId: string): ActiveEnemy?
	return activeEnemies[enemyId]
end

--[[
	Returns total active enemies currently registered.
]]
function EnemyService.GetActiveEnemyCount(): number
	local count = 0
	for _, _ in pairs(activeEnemies) do
		count += 1
	end
	return count
end

--[[
	Returns a copy of the dictionary of all active enemies.
]]
function EnemyService.GetAllActiveEnemies(): { [string]: ActiveEnemy }
	local copy: { [string]: ActiveEnemy } = {}
	for id, record in pairs(activeEnemies) do
		copy[id] = record
	end
	return copy
end

--[[
	Cleans up all active enemies in the arena (used on wave completion or mission reset).
	Returns count of enemies cleaned up.
]]
function EnemyService.CleanupAll(): number
	local count = 0
	for id, _ in pairs(activeEnemies) do
		EnemyService.DespawnEnemy(id)
		count += 1
	end

	local container = getActiveEnemiesFolder()
	container:ClearAllChildren()

	return count
end

--[[
	Initializes EnemyService. Idempotent.
]]
function EnemyService.Initialize()
	if isInitialized then
		return
	end
	isInitialized = true

	getActiveEnemiesFolder()
	print("[EnemyService] Authoritative enemy lifecycle service initialized.")
end

--[[
	Returns true if EnemyService is currently initialized.
]]
function EnemyService.IsInitialized(): boolean
	return isInitialized
end

--[[
	Cleans up all active enemies, resets spawn counter, and clears tracking.
]]
function EnemyService._Teardown()
	EnemyService.CleanupAll()
	activeEnemies = {}
	spawnCounter = 0
	isInitialized = false
end

return EnemyService
