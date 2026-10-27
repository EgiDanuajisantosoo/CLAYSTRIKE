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
	InputTimeout: number,
	InputSamplingRate: number,
}

export type RateLimitRule = {
	maxPerSecond: number,
	burstAllowance: number,
}

export type CameraConfig = {
	FieldOfView: number,
	Distance: number,
	FollowSmoothness: number,
	LookAheadX: number,
	MinX: number,
	MaxX: number,
	MinY: number,
	MaxY: number,
}

export type ParallaxLayerConfig = {
	name: string,
	zOffset: number,
	speedMultiplier: number,
	tileWidth: number,
	color: Color3,
}

export type BackgroundConfig = {
	BaseScrollSpeed: number,
	Layers: { ParallaxLayerConfig },
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
	InputTimeout = 0.25,
	InputSamplingRate = 25,
} :: MovementConfig

-- 2.5D Side-scrolling camera parameters
GameConfig.Camera = {
	FieldOfView = 65,
	Distance = 70,
	FollowSmoothness = 8,
	LookAheadX = 8,
	MinX = -55,
	MaxX = 55,
	MinY = -25,
	MaxY = 25,
} :: CameraConfig

-- 2.5D Parallax scrolling background configuration
GameConfig.Background = {
	BaseScrollSpeed = 24,
	Layers = {
		{
			name = "NearClouds",
			zOffset = -25,
			speedMultiplier = 1.0,
			tileWidth = 140,
			color = Color3.fromRGB(180, 160, 145),
		},
		{
			name = "MidMountains",
			zOffset = -60,
			speedMultiplier = 0.5,
			tileWidth = 180,
			color = Color3.fromRGB(120, 100, 90),
		},
		{
			name = "FarSkyline",
			zOffset = -110,
			speedMultiplier = 0.2,
			tileWidth = 240,
			color = Color3.fromRGB(80, 70, 75),
		},
	},
} :: BackgroundConfig

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
