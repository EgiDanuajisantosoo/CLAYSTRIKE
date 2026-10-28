--!strict
--[[
	WaveConfig.luau
	Data-driven wave specifications, enemy spawn sequences, and mission configurations.
	Task: CLAY-020 (Wave Manager & Mission Wave Config)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
if (EnemyConfig :: any).Archetypes == nil then
	EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"):Clone())
end

export type SpawnEntry = {
	archetypeId: string,
	spawnY: number,
	delayAfterPrev: number, -- Delay in seconds after previous spawn in this wave
	count: number?, -- Number of enemies to spawn for this entry (default 1, allows 0)
	spawnInterval: number?, -- Interval in seconds between successive spawns if count > 1 (default 0.5)
}

export type WaveDefinition = {
	waveNumber: number,
	waveName: string,
	delayBeforeWave: number, -- Intermission delay before wave starts
	spawns: { SpawnEntry },
}

export type MissionConfig = {
	missionId: string,
	missionName: string,
	waves: { WaveDefinition },
}

local WaveConfig = {}

WaveConfig.MAX_SPAWN_COUNT = 50

-- Helper to ensure a number is strictly finite (not NaN, math.huge, or -math.huge)
local function isFiniteNumber(n: any): boolean
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Helper to ensure a number is strictly finite and non-negative (>= 0)
local function isFiniteNonNegative(n: any): boolean
	return isFiniteNumber(n) and n >= 0
end

-- Canonical MVP Mission 1 Wave Definitions
local DEFAULT_MISSION: MissionConfig = {
	missionId = "Mission_01",
	missionName = "Clay Canyon Skirmish",
	waves = {
		{
			waveNumber = 1,
			waveName = "Recon Flight",
			delayBeforeWave = 2.0,
			spawns = {
				{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 10, delayAfterPrev = 0.0 },
				{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = -10, delayAfterPrev = 1.0 },
				{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 0, delayAfterPrev = 1.0 },
			},
		},
		{
			waveNumber = 2,
			waveName = "Pincer Formation",
			delayBeforeWave = 3.0,
			spawns = {
				{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 20, delayAfterPrev = 0.0 },
				{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = -20, delayAfterPrev = 0.2 },
				{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 10, delayAfterPrev = 1.2 },
				{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = -10, delayAfterPrev = 0.2 },
			},
		},
		{
			waveNumber = 3,
			waveName = "Clay Armada",
			delayBeforeWave = 3.0,
			spawns = {
				{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 15, delayAfterPrev = 0.0 },
				{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 0, delayAfterPrev = 0.8 },
				{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = -15, delayAfterPrev = 0.8 },
				{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = 25, delayAfterPrev = 1.0 },
				{ archetypeId = EnemyConfig.Archetypes.StraightFlyer, spawnY = -25, delayAfterPrev = 0.2 },
			},
		},
	},
}

local MISSIONS: { [string]: MissionConfig } = {
	[DEFAULT_MISSION.missionId] = DEFAULT_MISSION,
}

--[[
	Returns a mission configuration by ID or nil.
]]
function WaveConfig.GetMission(missionId: string): MissionConfig?
	return MISSIONS[missionId]
end

--[[
	Returns the default MVP Level 1 mission.
]]
function WaveConfig.GetDefaultMission(): MissionConfig
	return DEFAULT_MISSION
end

--[[
	Validates a single SpawnEntry.
]]
function WaveConfig.ValidateSpawnEntry(entry: SpawnEntry): (boolean, string?)
	if typeof(entry) ~= "table" then
		return false, "SpawnEntry must be a table."
	end
	if typeof(entry.archetypeId) ~= "string" or #entry.archetypeId == 0 then
		return false, "SpawnEntry requires non-empty archetypeId string."
	end
	if EnemyConfig.GetEnemy(entry.archetypeId) == nil then
		return false, string.format("SpawnEntry references unknown archetypeId: '%s'.", entry.archetypeId)
	end
	if not isFiniteNumber(entry.spawnY) then
		return false, "SpawnEntry requires finite spawnY number."
	end
	if not isFiniteNonNegative(entry.delayAfterPrev) then
		return false, "SpawnEntry requires finite non-negative delayAfterPrev number."
	end
	if entry.count ~= nil then
		if not isFiniteNonNegative(entry.count) or math.floor(entry.count) ~= entry.count then
			return false, "SpawnEntry count must be a non-negative finite integer (>= 0)."
		end
		if entry.count > WaveConfig.MAX_SPAWN_COUNT then
			return false, string.format("SpawnEntry count (%d) exceeds MAX_SPAWN_COUNT (%d).", entry.count, WaveConfig.MAX_SPAWN_COUNT)
		end
	end
	if entry.spawnInterval ~= nil then
		if not isFiniteNonNegative(entry.spawnInterval) then
			return false, "SpawnEntry spawnInterval must be a finite non-negative number."
		end
	end
	return true, nil
end

--[[
	Validates a WaveDefinition.
]]
function WaveConfig.ValidateWave(wave: WaveDefinition): (boolean, string?)
	if typeof(wave) ~= "table" then
		return false, "WaveDefinition must be a table."
	end
	if not isFiniteNonNegative(wave.waveNumber) or wave.waveNumber < 1 or math.floor(wave.waveNumber) ~= wave.waveNumber then
		return false, "WaveDefinition requires positive finite integer waveNumber (>= 1)."
	end
	if typeof(wave.waveName) ~= "string" or #wave.waveName == 0 then
		return false, "WaveDefinition requires non-empty waveName string."
	end
	if not isFiniteNonNegative(wave.delayBeforeWave) then
		return false, "WaveDefinition requires finite non-negative delayBeforeWave number."
	end
	if typeof(wave.spawns) ~= "table" or #wave.spawns == 0 then
		return false, "WaveDefinition requires non-empty spawns array."
	end

	for i, spawnEntry in ipairs(wave.spawns) do
		local ok, err = WaveConfig.ValidateSpawnEntry(spawnEntry)
		if not ok then
			return false, string.format("Wave %d spawn entry %d invalid: %s", wave.waveNumber, i, tostring(err))
		end
	end

	return true, nil
end

--[[
	Validates an entire MissionConfig.
]]
function WaveConfig.ValidateMission(mission: MissionConfig): (boolean, string?)
	if typeof(mission) ~= "table" then
		return false, "MissionConfig must be a table."
	end
	if typeof(mission.missionId) ~= "string" or #mission.missionId == 0 then
		return false, "MissionConfig requires non-empty missionId string."
	end
	if typeof(mission.missionName) ~= "string" or #mission.missionName == 0 then
		return false, "MissionConfig requires non-empty missionName string."
	end
	if typeof(mission.waves) ~= "table" or #mission.waves == 0 then
		return false, "MissionConfig requires non-empty waves array."
	end

	for i, wave in ipairs(mission.waves) do
		if wave.waveNumber ~= i then
			return false, string.format("Wave at index %d has out-of-order waveNumber %d (expected %d).", i, wave.waveNumber, i)
		end
		local ok, err = WaveConfig.ValidateWave(wave)
		if not ok then
			return false, string.format("Mission wave %d invalid: %s", i, tostring(err))
		end
	end

	return true, nil
end

return WaveConfig
