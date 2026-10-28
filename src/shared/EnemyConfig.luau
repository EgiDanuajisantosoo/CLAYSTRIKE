--!strict
--[[
	EnemyConfig.luau
	Data-driven schema and definitions for enemy archetypes in CLAYSTRIKE.
	Task: CLAY-015 (Enemy Definition Schema)

	Defines common attributes for health, movement type, speeds, firing patterns,
	collision proxy bounds, score rewards, and visual color assignments according
	to the Master Plan and StyleGuide.
]]

export type MovementType = "Straight" | "Pursuit" | "DriftAndShoot"

export type FiringPattern = {
	canShoot: boolean,
	fireRate: number,
	projectileSpeed: number,
	projectileDamage: number,
	projectileColor: Color3,
}

export type EnemyDefinition = {
	id: string,
	displayName: string,
	maxHealth: number,
	movementType: MovementType,
	speed: number,
	verticalSpeed: number?,
	collisionSize: Vector3,
	scoreValue: number,
	clayColor: Color3,
	firingPattern: FiringPattern?,
	templateName: string,
}

local EnemyConfig = {}

-- Archetype IDs
EnemyConfig.Archetypes = {
	StraightFlyer = "StraightFlyer",
	Pursuer = "Pursuer",
	TurretShooter = "TurretShooter",
}

-- Canonical enemy definitions
local ENEMY_DEFINITIONS: { [string]: EnemyDefinition } = {
	[EnemyConfig.Archetypes.StraightFlyer] = {
		id = EnemyConfig.Archetypes.StraightFlyer,
		displayName = "Clay Drone (Straight Flyer)",
		maxHealth = 20,
		movementType = "Straight",
		speed = 18,
		collisionSize = Vector3.new(3.0, 2.0, 2.0),
		scoreValue = 100,
		clayColor = Color3.fromRGB(215, 160, 45), -- Warm Mustard Clay
		templateName = "StraightFlyerTemplate",
		firingPattern = {
			canShoot = false,
			fireRate = 0,
			projectileSpeed = 0,
			projectileDamage = 0,
			projectileColor = Color3.fromRGB(0, 0, 0),
		},
	},

	[EnemyConfig.Archetypes.Pursuer] = {
		id = EnemyConfig.Archetypes.Pursuer,
		displayName = "Clay Interceptor (Pursuer)",
		maxHealth = 35,
		movementType = "Pursuit",
		speed = 14,
		verticalSpeed = 10,
		collisionSize = Vector3.new(3.5, 2.4, 2.4),
		scoreValue = 250,
		clayColor = Color3.fromRGB(195, 75, 45), -- Terracotta Clay
		templateName = "PursuerTemplate",
		firingPattern = {
			canShoot = false,
			fireRate = 0,
			projectileSpeed = 0,
			projectileDamage = 0,
			projectileColor = Color3.fromRGB(0, 0, 0),
		},
	},

	[EnemyConfig.Archetypes.TurretShooter] = {
		id = EnemyConfig.Archetypes.TurretShooter,
		displayName = "Clay Gunship (Turret Shooter)",
		maxHealth = 55,
		movementType = "DriftAndShoot",
		speed = 7,
		verticalSpeed = 4,
		collisionSize = Vector3.new(4.2, 3.0, 3.0),
		scoreValue = 400,
		clayColor = Color3.fromRGB(80, 125, 70), -- Sage Olive Clay
		templateName = "TurretShooterTemplate",
		firingPattern = {
			canShoot = true,
			fireRate = 2.0, -- Shoots every 2 seconds
			projectileSpeed = 28,
			projectileDamage = 15,
			projectileColor = Color3.fromRGB(240, 80, 40),
		},
	},
}

--[[
	Validates that an enemy definition adheres to schema requirements.
	Returns (isValid, errorMessage). Error messages clearly identify offending enemy ID and field.
]]
function EnemyConfig.ValidateDefinition(def: any): (boolean, string?)
	if type(def) ~= "table" then
		return false, "Enemy definition must be a table"
	end

	if type(def.id) ~= "string" or #def.id == 0 then
		return false, "Missing or invalid enemy 'id'"
	end
	local enemyId = def.id

	if type(def.displayName) ~= "string" or #def.displayName == 0 then
		return false, string.format("Enemy '%s': 'displayName' must be a non-empty string", enemyId)
	end

	if type(def.maxHealth) ~= "number" or def.maxHealth <= 0 or def.maxHealth ~= def.maxHealth or def.maxHealth == math.huge then
		return false, string.format("Enemy '%s': 'maxHealth' must be a positive finite number", enemyId)
	end

	local validMoveTypes = { Straight = true, Pursuit = true, DriftAndShoot = true }
	if type(def.movementType) ~= "string" or not validMoveTypes[def.movementType] then
		return false, string.format("Enemy '%s': 'movementType' must be one of: 'Straight', 'Pursuit', 'DriftAndShoot'", enemyId)
	end

	if type(def.speed) ~= "number" or def.speed <= 0 or def.speed ~= def.speed or def.speed == math.huge then
		return false, string.format("Enemy '%s': 'speed' must be a positive finite number", enemyId)
	end

	if def.verticalSpeed ~= nil then
		if type(def.verticalSpeed) ~= "number" or def.verticalSpeed < 0 or def.verticalSpeed ~= def.verticalSpeed or def.verticalSpeed == math.huge then
			return false, string.format("Enemy '%s': 'verticalSpeed' must be a non-negative finite number", enemyId)
		end
	end

	if typeof(def.collisionSize) ~= "Vector3" then
		return false, string.format("Enemy '%s': 'collisionSize' must be a Vector3", enemyId)
	end
	if def.collisionSize.X <= 0 or def.collisionSize.Y <= 0 or def.collisionSize.Z <= 0 then
		return false, string.format("Enemy '%s': 'collisionSize' axes must all be strictly positive", enemyId)
	end

	if type(def.scoreValue) ~= "number" or def.scoreValue < 0 or def.scoreValue ~= def.scoreValue or def.scoreValue == math.huge then
		return false, string.format("Enemy '%s': 'scoreValue' must be a non-negative finite number", enemyId)
	end

	if typeof(def.clayColor) ~= "Color3" then
		return false, string.format("Enemy '%s': 'clayColor' must be a Color3", enemyId)
	end

	if type(def.templateName) ~= "string" or #def.templateName == 0 then
		return false, string.format("Enemy '%s': 'templateName' must be a non-empty string", enemyId)
	end

	if def.firingPattern ~= nil then
		local fp = def.firingPattern
		if type(fp) ~= "table" then
			return false, string.format("Enemy '%s': 'firingPattern' must be a table", enemyId)
		end
		if type(fp.canShoot) ~= "boolean" then
			return false, string.format("Enemy '%s': 'firingPattern.canShoot' must be a boolean", enemyId)
		end
		if fp.canShoot then
			if type(fp.fireRate) ~= "number" or fp.fireRate <= 0 or fp.fireRate ~= fp.fireRate or fp.fireRate == math.huge then
				return false, string.format("Enemy '%s': 'firingPattern.fireRate' must be a positive finite number", enemyId)
			end
			if type(fp.projectileSpeed) ~= "number" or fp.projectileSpeed <= 0 or fp.projectileSpeed ~= fp.projectileSpeed or fp.projectileSpeed == math.huge then
				return false, string.format("Enemy '%s': 'firingPattern.projectileSpeed' must be a positive finite number", enemyId)
			end
			if type(fp.projectileDamage) ~= "number" or fp.projectileDamage <= 0 or fp.projectileDamage ~= fp.projectileDamage or fp.projectileDamage == math.huge then
				return false, string.format("Enemy '%s': 'firingPattern.projectileDamage' must be a positive finite number", enemyId)
			end
			if typeof(fp.projectileColor) ~= "Color3" then
				return false, string.format("Enemy '%s': 'firingPattern.projectileColor' must be a Color3", enemyId)
			end
		end
	end

	return true, nil
end

--[[
	Validates all registered enemy definitions.
	Returns (allValid, errorsList).
]]
function EnemyConfig.ValidateAll(): (boolean, { string })
	local errors: { string } = {}
	for id, def in pairs(ENEMY_DEFINITIONS) do
		local valid, err = EnemyConfig.ValidateDefinition(def)
		if not valid and err then
			table.insert(errors, err)
		end
	end
	return (#errors == 0), errors
end

--[[
	Returns an enemy definition by ID, or nil if not registered.
]]
function EnemyConfig.GetEnemy(id: string): EnemyDefinition?
	return ENEMY_DEFINITIONS[id]
end
EnemyConfig.GetDefinition = EnemyConfig.GetEnemy

--[[
	Returns all registered enemy definitions as a table copy.
]]
function EnemyConfig.GetAllEnemies(): { [string]: EnemyDefinition }
	local copy: { [string]: EnemyDefinition } = {}
	for id, def in pairs(ENEMY_DEFINITIONS) do
		copy[id] = def
	end
	return copy
end

--[[
	Returns a list of all registered enemy IDs.
]]
function EnemyConfig.GetEnemyIds(): { string }
	local ids: { string } = {}
	for id, _ in pairs(ENEMY_DEFINITIONS) do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

return EnemyConfig
