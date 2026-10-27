--!strict
--[[
	GameConfig.luau
	Centralized source of truth for arena bounds, movement parameters, game states, and network policies.
	Task: CLAY-002 (Define Remote Contracts & Shared Config)
]]

export type ArenaBounds = {
	MinX: number,
	MaxX: number,
	MinY: number,
	MaxY: number,
	PlayPlaneZ: number,
}

export type MovementConfig = {
	MaxSpeed: number,
	Acceleration: number,
	Deceleration: number,
}

export type RateLimitRule = {
	maxPerSecond: number,
	burstAllowance: number,
}

local GameConfig = {}

-- Contract versioning policy. Mismatches are rejected by the server validator.
GameConfig.CONTRACT_VERSION = "1.0.0"

-- 2.5D Play-plane configuration and boundary bounds
GameConfig.Arena = {
	MinX = -80,
	MaxX = 80,
	MinY = -40,
	MaxY = 40,
	PlayPlaneZ = 0,
} :: ArenaBounds

-- Player aircraft movement characteristics (authoritative speed ceilings)
GameConfig.Movement = {
	MaxSpeed = 50,
	Acceleration = 120,
	Deceleration = 160,
} :: MovementConfig

-- Canonical session game states replicated to all clients
GameConfig.GameStates = {
	Lobby = "Lobby",
	WaveActive = "WaveActive",
	Intermission = "Intermission",
	BossPhase = "BossPhase",
	MissionSuccess = "MissionSuccess",
	MissionFailed = "MissionFailed",
}

-- Network request rate limits per player (server enforced via RateLimiter)
GameConfig.NetworkRateLimits = {
	MovePlane = {
		maxPerSecond = 30,
		burstAllowance = 5,
	} :: RateLimitRule,
	FireWeapon = {
		maxPerSecond = 12,
		burstAllowance = 3,
	} :: RateLimitRule,
}

return GameConfig
