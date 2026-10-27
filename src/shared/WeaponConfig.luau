--!strict
--[[
	WeaponConfig.luau
	Data-driven definitions for initial CLAYSTRIKE weapons.
	Task: CLAY-002 (Define Remote Contracts & Shared Config)

	IMPORTANT SECURITY & AUTHORITY BOUNDARY:
	Values defined here (such as baseDamage and cooldown) are published for client prediction,
	audio/visual feedback, and UI HUD display. The client CANNOT dictate when or how much damage
	is dealt. The server strictly enforces weapon cooldowns, hit validation, and health deductions.
]]

export type WeaponDefinition = {
	id: string,
	displayName: string,
	fireRate: number, -- Theoretical shots per second
	cooldown: number, -- Minimum interval in seconds between shots
	baseDamage: number, -- Reference damage value (Server authoritatively applies this)
	projectileSpeed: number, -- Studs per second
	spreadAngles: { number }, -- In degrees relative to aim vector (e.g. {0} or {-15, 0, 15})
	lifetime: number, -- Max projectile lifetime in seconds
}

local WeaponConfig = {}

WeaponConfig.Weapons = {
	StandardPeaShooter = {
		id = "StandardPeaShooter",
		displayName = "Pea Shooter",
		fireRate = 5,
		cooldown = 0.2,
		baseDamage = 10,
		projectileSpeed = 140,
		spreadAngles = { 0 },
		lifetime = 3.0,
	} :: WeaponDefinition,

	SpreadShot = {
		id = "SpreadShot",
		displayName = "Spread Clay Cannon",
		fireRate = 2.5,
		cooldown = 0.4,
		baseDamage = 8,
		projectileSpeed = 110,
		spreadAngles = { -15, 0, 15 },
		lifetime = 2.5,
	} :: WeaponDefinition,
}

-- Helper to retrieve weapon definitions safely
function WeaponConfig.GetWeapon(weaponId: string): WeaponDefinition?
	return WeaponConfig.Weapons[weaponId]
end

return WeaponConfig
