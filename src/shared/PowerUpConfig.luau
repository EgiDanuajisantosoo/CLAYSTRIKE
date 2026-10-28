--!strict
--[[
	PowerUpConfig.luau
	Configuration for collectible power-ups, drop rates, and temporary combat buffs.
	Task: CLAY-014 (Power-Up Drop & Pickup Rules)

	Defines server-authoritative drop chances, collectible lifetimes, pickup radii,
	and gameplay modifiers for temporary combat enhancements.
]]

export type PowerUpType = "RapidFire" | "DamageBoost"

export type PowerUpDefinition = {
	id: PowerUpType,
	displayName: string,
	duration: number,
	cooldownMultiplier: number,
	damageAdditive: number,
	color: Color3,
	dropWeight: number,
}

local PowerUpConfig = {}

-- Arena & lifetime constants
PowerUpConfig.DEFAULT_LIFETIME = 12.0 -- Seconds before an uncollected pickup despawns
PowerUpConfig.PICKUP_RADIUS = 6.0 -- Maximum distance in studs for authoritative collection
PowerUpConfig.MAX_ACTIVE_PICKUPS = 12 -- Hard ceiling on simultaneous pickups to prevent clutter

-- Drop chance per enemy archetype upon defeat (0.0 to 1.0)
PowerUpConfig.DropChances = {
	StraightFlyer = 0.25,
	Pursuer = 0.35,
	TurretShooter = 0.50,
	Default = 0.30,
}

-- Definitions for available collectible buffs
PowerUpConfig.PowerUps = {
	RapidFire = {
		id = "RapidFire",
		displayName = "Rapid Clay Cannon",
		duration = 8.0,
		cooldownMultiplier = 0.55, -- 45% faster firing rate
		damageAdditive = 0,
		color = Color3.fromRGB(255, 215, 0), -- Gold / Amber
		dropWeight = 60,
	},
	DamageBoost = {
		id = "DamageBoost",
		displayName = "Clay Overcharge",
		duration = 8.0,
		cooldownMultiplier = 1.0,
		damageAdditive = 6, -- +6 damage per projectile
		color = Color3.fromRGB(255, 85, 30), -- Vivid Clay Orange
		dropWeight = 40,
	},
} :: { [PowerUpType]: PowerUpDefinition }

--[[
	Returns the PowerUpDefinition for the given id, or nil if invalid.
]]
function PowerUpConfig.GetPowerUp(id: string): PowerUpDefinition?
	return PowerUpConfig.PowerUps[id :: PowerUpType]
end

--[[
	Selects a random powerup type based on configured drop weights.
	Optionally accepts a seeded random number generator for deterministic testing.
]]
function PowerUpConfig.SelectRandomPowerUp(rng: Random?): PowerUpDefinition
	local activeRng = rng or Random.new()
	local totalWeight = 0
	for _, def in pairs(PowerUpConfig.PowerUps) do
		totalWeight += def.dropWeight
	end

	local roll = activeRng:NextNumber(0, totalWeight)
	local accumulated = 0
	for _, def in pairs(PowerUpConfig.PowerUps) do
		accumulated += def.dropWeight
		if roll <= accumulated then
			return def
		end
	end

	return PowerUpConfig.PowerUps.RapidFire
end

--[[
	Determines if an enemy drop roll succeeds given the enemy type.
]]
function PowerUpConfig.RollDrop(enemyType: string?, rng: Random?): boolean
	local chance = PowerUpConfig.DropChances[enemyType or ""] or PowerUpConfig.DropChances.Default
	local activeRng = rng or Random.new()
	return activeRng:NextNumber() <= chance
end

return PowerUpConfig
