--!strict
--[[
	DifficultyConfig.luau
	Authoritative configuration and mathematical scaling curves for co-op multiplayer difficulty.
	Task: CLAY-024 (Co-op Difficulty Scaling)

	DESIGN PRINCIPLES:
	1. Explicit Non-Linear Curves: Avoid blind linear multipliers that turn enemies into bullet sponges.
	2. Solo Play Viability: 1-player baseline is strictly 1.0x so single-player remains balanced and beatable.
	3. Visual Readability: 4-player spawn count is capped at 1.75x to prevent screen clutter, while health scales to 2.0x.
	4. Checkpoint Sampling: Player count is sampled at wave start checkpoints to guarantee deterministic mid-wave combat.
	5. Bounded Clamping: Player count is authoritatively clamped between 1 and 4.
]]

export type ScalingFactors = {
	playerCount: number,
	healthMult: number,
	spawnCountMult: number,
	bossHealthMult: number,
	rewardBudgetMult: number,
}

local DifficultyConfig = {}

-- Authored difficulty scaling table for 1 to 4 co-op players
local SCALING_TABLE: { [number]: ScalingFactors } = {
	[1] = {
		playerCount = 1,
		healthMult = 1.0,
		spawnCountMult = 1.0,
		bossHealthMult = 1.0,
		rewardBudgetMult = 1.0,
	},
	[2] = {
		playerCount = 2,
		healthMult = 1.35,
		spawnCountMult = 1.25,
		bossHealthMult = 1.40,
		rewardBudgetMult = 1.5,
	},
	[3] = {
		playerCount = 3,
		healthMult = 1.70,
		spawnCountMult = 1.50,
		bossHealthMult = 1.80,
		rewardBudgetMult = 2.0,
	},
	[4] = {
		playerCount = 4,
		healthMult = 2.00,
		spawnCountMult = 1.75,
		bossHealthMult = 2.20,
		rewardBudgetMult = 2.5,
	},
}

--[[
	Returns the scaling factors for the specified player count.
	Clamps player count between 1 and 4.
]]
function DifficultyConfig.GetScaling(playerCount: number): ScalingFactors
	local clamped = math.clamp(math.floor(playerCount), 1, 4)
	return SCALING_TABLE[clamped]
end

--[[
	Calculates scaled enemy health based on active player count.
	Guarantees positive integer health.
]]
function DifficultyConfig.CalculateHealth(baseHealth: number, playerCount: number, isBoss: boolean?): number
	local scaling = DifficultyConfig.GetScaling(playerCount)
	local mult = if isBoss == true then scaling.bossHealthMult else scaling.healthMult
	return math.max(1, math.round(baseHealth * mult))
end

--[[
	Calculates scaled wave enemy spawn count based on active player count.
	Guarantees at least 1 enemy per spawn entry.
]]
function DifficultyConfig.CalculateSpawnCount(baseCount: number, playerCount: number): number
	if baseCount <= 0 then
		return 0
	end
	local scaling = DifficultyConfig.GetScaling(playerCount)
	return math.max(1, math.round(baseCount * scaling.spawnCountMult))
end

--[[
	Calculates scaled score rewards for defeated enemies based on co-op multiplier.
]]
function DifficultyConfig.CalculateReward(baseReward: number, playerCount: number): number
	if baseReward <= 0 then
		return 0
	end
	local scaling = DifficultyConfig.GetScaling(playerCount)
	return math.max(1, math.round(baseReward * scaling.rewardBudgetMult))
end

return DifficultyConfig
