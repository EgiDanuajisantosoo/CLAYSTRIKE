--!strict
--[[
	MissionStateConfig.luau
	Canonical mission lifecycle states, validation rules, and transition constraints.
	Task: CLAY-025 (Mission State Machine & Join/Leave Handling)

	LIFECYCLE FLOW:
	Lobby -> Starting -> InProgress -> Boss (optional) -> Success / Failed -> Reset -> Lobby
]]

export type MissionState = "Lobby" | "Starting" | "InProgress" | "Boss" | "Success" | "Failed" | "Reset"

local MissionStateConfig = {}

MissionStateConfig.States = {
	Lobby = "Lobby" :: MissionState,
	Starting = "Starting" :: MissionState,
	InProgress = "InProgress" :: MissionState,
	Boss = "Boss" :: MissionState,
	Success = "Success" :: MissionState,
	Failed = "Failed" :: MissionState,
	Reset = "Reset" :: MissionState,
}

local VALID_STATES: { [string]: boolean } = {
	Lobby = true,
	Starting = true,
	InProgress = true,
	Boss = true,
	Success = true,
	Failed = true,
	Reset = true,
}

-- Strict whitelist of allowed forward transitions
local ALLOWED_TRANSITIONS: { [string]: { [string]: boolean } } = {
	Lobby = {
		Starting = true,
		Reset = true,
	},
	Starting = {
		InProgress = true,
		Failed = true,
		Reset = true,
	},
	InProgress = {
		Boss = true,
		Success = true,
		Failed = true,
		Reset = true,
	},
	Boss = {
		Success = true,
		Failed = true,
		Reset = true,
	},
	Success = {
		Reset = true,
	},
	Failed = {
		Reset = true,
	},
	Reset = {
		Lobby = true,
	},
}

MissionStateConfig.COUNTDOWN_DURATION = 3.0 -- Default countdown before launching from Starting into InProgress
MissionStateConfig.RESULTS_DURATION = 5.0 -- Duration to display mission results before auto-returning to Lobby

--[[
	Returns true if the given state string is a valid MissionState.
]]
function MissionStateConfig.IsValidState(state: string): boolean
	return VALID_STATES[state] == true
end

--[[
	Returns true if transitioning from `fromState` to `toState` is permitted.
]]
function MissionStateConfig.CanTransition(fromState: MissionState, toState: MissionState): boolean
	local allowed = ALLOWED_TRANSITIONS[fromState]
	return allowed ~= nil and allowed[toState] == true
end

return MissionStateConfig
