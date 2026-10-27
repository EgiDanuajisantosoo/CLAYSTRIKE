--!strict
--[[
	WeaponConfig.luau
	Authoritative data-driven definitions for CLAYSTRIKE weapons.
	Task: CLAY-009 (Weapon Data Definitions)

	Defines standard and spread weapons with cooldowns, projectile speeds, lifetimes,
	base damage, spread angle patterns, projectile dimensions, and allowed owner states.
	Validates configuration at server startup with safe fallback defaults.

	SECURITY & AUTHORITY BOUNDARY:
	The server is strictly authoritative over weapon cooldowns, hit validation, damage,
	and state changes. Client reads these definitions for prediction, audio/visual cues,
	and HUD rendering only. Client cannot override server cooldown or damage values.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local sharedGameConfig = SharedFolder:WaitForChild("GameConfig")
local GameConfig = require(sharedGameConfig)
if (GameConfig :: any).GameStates == nil then
	GameConfig = require(sharedGameConfig:Clone())
end

local sharedStyleGuide = SharedFolder:FindFirstChild("StyleGuide")
local StyleGuide = if sharedStyleGuide then require(sharedStyleGuide) else nil

export type WeaponDefinition = {
	id: string,
	displayName: string,
	fireRate: number, -- Theoretical shots per second
	cooldown: number, -- Minimum interval in seconds between shots
	baseDamage: number, -- Reference damage value (Server authoritatively applies this)
	projectileSpeed: number, -- Studs per second
	projectileRadius: number, -- Collision sphere radius in studs
	spreadAngles: { number }, -- In degrees relative to aim vector (e.g. {0} or {-15, 0, 15})
	lifetime: number, -- Max projectile lifetime in seconds
	allowedOwnerStates: { string }, -- Session states where weapon firing is permitted
	bulletColor: Color3, -- Visual particle / mesh color
}

local WeaponConfig = {}

local bulletColorStandard = if StyleGuide
	then StyleGuide.Colors.PlayerStandardBullet
	else Color3.fromRGB(255, 235, 75)

local bulletColorSpread = if StyleGuide
	then StyleGuide.Colors.PlayerSpreadBullet
	else Color3.fromRGB(80, 225, 255)

WeaponConfig.Weapons = {
	StandardPeaShooter = {
		id = "StandardPeaShooter",
		displayName = "Pea Shooter",
		fireRate = 5,
		cooldown = 0.2,
		baseDamage = 10,
		projectileSpeed = 140,
		projectileRadius = 0.6,
		spreadAngles = { 0 },
		lifetime = 3.0,
		allowedOwnerStates = {
			GameConfig.GameStates.WaveActive,
			GameConfig.GameStates.BossPhase,
		},
		bulletColor = bulletColorStandard,
	} :: WeaponDefinition,

	SpreadShot = {
		id = "SpreadShot",
		displayName = "Spread Clay Cannon",
		fireRate = 2.5,
		cooldown = 0.4,
		baseDamage = 8,
		projectileSpeed = 110,
		projectileRadius = 0.5,
		spreadAngles = { -15, 0, 15 },
		lifetime = 2.5,
		allowedOwnerStates = {
			GameConfig.GameStates.WaveActive,
			GameConfig.GameStates.BossPhase,
		},
		bulletColor = bulletColorSpread,
	} :: WeaponDefinition,
}

-- Default fallback weapon if requested weapon ID is missing or invalid
WeaponConfig.DEFAULT_WEAPON_ID = "StandardPeaShooter"

--[[
	Returns the default weapon definition.
]]
function WeaponConfig.GetDefaultWeapon(): WeaponDefinition
	return WeaponConfig.Weapons[WeaponConfig.DEFAULT_WEAPON_ID]
end

--[[
	Retrieves a weapon definition by ID safely. Returns nil if not found.
]]
function WeaponConfig.GetWeapon(weaponId: string): WeaponDefinition?
	return WeaponConfig.Weapons[weaponId]
end

--[[
	Validates a single weapon definition schema and value ranges.
	Returns (isValid, errorMessage).
]]
function WeaponConfig.ValidateDefinition(def: any): (boolean, string?)
	if type(def) ~= "table" then
		return false, "Weapon definition must be a table."
	end
	if type(def.id) ~= "string" or #def.id == 0 then
		return false, "Weapon id must be a non-empty string."
	end
	if type(def.displayName) ~= "string" or #def.displayName == 0 then
		return false, "Weapon displayName must be a non-empty string."
	end
	if type(def.cooldown) ~= "number" or def.cooldown <= 0 then
		return false, "Weapon cooldown must be a positive number."
	end
	if type(def.fireRate) ~= "number" or def.fireRate <= 0 then
		return false, "Weapon fireRate must be a positive number."
	end
	if type(def.baseDamage) ~= "number" or def.baseDamage <= 0 then
		return false, "Weapon baseDamage must be a positive number."
	end
	if type(def.projectileSpeed) ~= "number" or def.projectileSpeed <= 0 then
		return false, "Weapon projectileSpeed must be a positive number."
	end
	if type(def.projectileRadius) ~= "number" or def.projectileRadius <= 0 then
		return false, "Weapon projectileRadius must be a positive number."
	end
	if type(def.lifetime) ~= "number" or def.lifetime <= 0 then
		return false, "Weapon lifetime must be a positive number."
	end
	if type(def.spreadAngles) ~= "table" or #def.spreadAngles == 0 then
		return false, "Weapon spreadAngles must be a non-empty array of angles."
	end
	for i, angle in ipairs(def.spreadAngles) do
		if type(angle) ~= "number" then
			return false, string.format("spreadAngles[%d] must be a number.", i)
		end
	end
	if type(def.allowedOwnerStates) ~= "table" or #def.allowedOwnerStates == 0 then
		return false, "Weapon allowedOwnerStates must be a non-empty array of game state strings."
	end
	if typeof(def.bulletColor) ~= "Color3" then
		return false, "Weapon bulletColor must be a Color3."
	end

	return true, nil
end

--[[
	Validates all registered weapon definitions.
	Returns (allValid, errorList).
]]
function WeaponConfig.ValidateAll(): (boolean, { string })
	local errors: { string } = {}
	for id, def in pairs(WeaponConfig.Weapons) do
		local ok, err = WeaponConfig.ValidateDefinition(def)
		if not ok then
			table.insert(errors, string.format("Weapon '%s': %s", id, err or "Validation failed"))
		end
	end

	-- Also verify default weapon exists
	if not WeaponConfig.Weapons[WeaponConfig.DEFAULT_WEAPON_ID] then
		table.insert(errors, string.format("Default weapon '%s' is not defined in WeaponConfig.Weapons.", WeaponConfig.DEFAULT_WEAPON_ID))
	end

	return (#errors == 0), errors
end

return WeaponConfig
