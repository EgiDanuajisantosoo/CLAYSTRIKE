--!strict
--[[
	SessionConfig.luau
	Data definitions, valid lifecycle states, and rules for Co-op Team Sessions.
	Task: CLAY-022 (Co-op Player State & Team Session)
]]

export type PlayerLifecycleState = "Joining" | "Active" | "Downed" | "Respawning" | "Disconnected"

export type PlayerSessionRecord = {
	userId: number,
	username: string,
	state: PlayerLifecycleState,
	score: number,
	lives: number,
	joinTime: number,
	planeModel: Model?,
}

local SessionConfig = {}

SessionConfig.MAX_TEAM_SIZE = 4
SessionConfig.DEFAULT_LIVES = 3
SessionConfig.RESPAWN_DELAY = 3.0 -- Seconds before a downed player can respawn
SessionConfig.MAX_PLAYER_HEALTH = 100 -- Maximum authoritative player health
SessionConfig.INVULNERABILITY_DURATION = 1.5 -- Seconds of invulnerability (iframes) after taking damage
SessionConfig.RESPAWN_INVULNERABILITY = 3.0 -- Seconds of invulnerability granted on respawn

SessionConfig.States = {
	Joining = "Joining" :: PlayerLifecycleState,
	Active = "Active" :: PlayerLifecycleState,
	Downed = "Downed" :: PlayerLifecycleState,
	Respawning = "Respawning" :: PlayerLifecycleState,
	Disconnected = "Disconnected" :: PlayerLifecycleState,
}

local VALID_STATES: { [string]: boolean } = {
	Joining = true,
	Active = true,
	Downed = true,
	Respawning = true,
	Disconnected = true,
}

-- Valid forward transitions for player states
local ALLOWED_TRANSITIONS: { [string]: { [string]: boolean } } = {
	Joining = { Active = true, Disconnected = true },
	Active = { Downed = true, Disconnected = true },
	Downed = { Respawning = true, Disconnected = true },
	Respawning = { Active = true, Disconnected = true },
	Disconnected = { Joining = true }, -- Re-joining creates a new lifecycle
}

--[[
	Returns true if the given state string is a valid PlayerLifecycleState.
]]
function SessionConfig.IsValidState(state: string): boolean
	return VALID_STATES[state] == true
end

--[[
	Validates if a transition from fromState to toState is permitted.
]]
function SessionConfig.CanTransition(fromState: PlayerLifecycleState, toState: PlayerLifecycleState): boolean
	local allowed = ALLOWED_TRANSITIONS[fromState]
	return allowed ~= nil and allowed[toState] == true
end

--[[
	Validates a PlayerSessionRecord.
]]
function SessionConfig.ValidatePlayerRecord(record: any): (boolean, string?)
	if typeof(record) ~= "table" then
		return false, "PlayerSessionRecord must be a table."
	end
	if typeof(record.userId) ~= "number" or record.userId <= 0 or math.floor(record.userId) ~= record.userId then
		return false, "PlayerSessionRecord requires positive integer userId."
	end
	if typeof(record.username) ~= "string" or #record.username == 0 then
		return false, "PlayerSessionRecord requires non-empty username."
	end
	if not SessionConfig.IsValidState(record.state) then
		return false, string.format("Invalid player state: '%s'.", tostring(record.state))
	end
	if typeof(record.score) ~= "number" or record.score < 0 or record.score ~= record.score then
		return false, "PlayerSessionRecord requires non-negative finite score."
	end
	if typeof(record.lives) ~= "number" or record.lives < 0 or math.floor(record.lives) ~= record.lives then
		return false, "PlayerSessionRecord requires non-negative integer lives."
	end
	return true, nil
end

return SessionConfig
