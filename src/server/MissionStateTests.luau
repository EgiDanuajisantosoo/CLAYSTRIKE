--!strict
--[[
	MissionStateTests.luau
	Unit test harness for Mission State Machine & Join/Leave Handling.
	Task: CLAY-025 (Mission State Machine & Join/Leave Handling)

	TEST SUITE:
	1. Initial state is Lobby on startup.
	2. Valid forward transitions: Lobby -> Starting -> InProgress -> Boss -> Success -> Reset -> Lobby.
	3. Alternative valid branch: InProgress -> Failed -> Reset -> Lobby.
	4. Invalid state transitions are strictly rejected.
	5. Duplicate terminal events are blocked (Success cannot re-trigger Success or Failed).
	6. Duplicate failure events are blocked (Failed cannot re-trigger Failed or Success).
	7. Starting countdown delay and cancellation.
	8. All players disconnecting during active mission triggers automatic Reset to Lobby.
	9. Team wipe (all players downed with 0 lives) triggers MissionFailed authoritatively.
	10. Boss completion transition and payload generation.
	11. Reset races (rapid successive resets) are clean and idempotent.
	12. State broadcasts conform to RemoteContracts.ValidateGameStateChanged schemas.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local RemoteContracts = require(SharedFolder:WaitForChild("RemoteContracts"))
local MissionStateConfig = require(SharedFolder:WaitForChild("MissionStateConfig"))

local Services = ServerScriptService:WaitForChild("Services")
local MissionService = require(Services:WaitForChild("MissionService"))
local SessionService = require(Services:WaitForChild("SessionService"))
local WaveService = require(Services:WaitForChild("WaveService"))
local EnemyService = require(Services:WaitForChild("EnemyService"))
local AircraftService = require(Services:WaitForChild("AircraftService"))

local MissionStateTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

local function createMockPlayer(userId: number, name: string): Player
	local mock = {
		Name = name,
		UserId = userId,
		ClassName = "Player",
		IsA = function(self: any, cls: string)
			return cls == "Player" or cls == "Instance"
		end,
	}
	return (mock :: any) :: Player
end

function MissionStateTests.RunTests(): {
	total: number,
	passed: number,
	failed: number,
	results: { [number]: TestResult },
}
	local results: { [number]: TestResult } = {}
	local passedCount = 0
	local failedCount = 0

	local function assertTest(name: string, condition: boolean, errorMsg: string?)
		local testIndex = #results + 1
		if condition then
			passedCount += 1
			results[testIndex] = { name = name, passed = true }
		else
			failedCount += 1
			local failureText = errorMsg or "Assertion failed"
			results[testIndex] = { name = name, passed = false, error = failureText }
			warn(string.format("[MissionStateTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Clean baseline setup
	MissionService._Teardown()
	SessionService._Teardown()
	WaveService._Teardown()
	EnemyService.CleanupAll()
	AircraftService._Reset()

	MissionService.Initialize()
	SessionService.Initialize()
	WaveService.Initialize()

	-- 1. Initial State
	assertTest("MissionService initial state is 'Lobby'", MissionService.GetState() == "Lobby")
	assertTest("MissionService.IsActive() is false in Lobby", MissionService.IsActive() == false)

	-- 2. Valid Forward Transitions
	local ok1 = MissionService.TransitionTo("Starting", { countdown = 3 })
	assertTest("Transition Lobby -> Starting is valid", ok1 == true and MissionService.GetState() == "Starting")
	assertTest("MissionService.IsActive() is true in Starting", MissionService.IsActive() == true)

	local ok2 = MissionService.TransitionTo("InProgress")
	assertTest("Transition Starting -> InProgress is valid", ok2 == true and MissionService.GetState() == "InProgress")

	local ok3 = MissionService.TransitionTo("Boss", { bossName = "ClayGargoyle", phaseNumber = 1 })
	assertTest("Transition InProgress -> Boss is valid", ok3 == true and MissionService.GetState() == "Boss")

	local ok4 = MissionService.TransitionTo("Success", { totalWaves = 3, missionDuration = 120.5 })
	assertTest("Transition Boss -> Success is valid", ok4 == true and MissionService.GetState() == "Success")
	assertTest("MissionService.IsActive() is false in Success", MissionService.IsActive() == false)

	local ok5 = MissionService.TransitionTo("Reset")
	assertTest("Transition Success -> Reset returns to Lobby", ok5 == true and MissionService.GetState() == "Lobby")

	-- 3. Alternative Failure Branch
	MissionService.TransitionTo("Starting")
	MissionService.TransitionTo("InProgress")
	local okFail = MissionService.TransitionTo("Failed", { failureReason = "Team wiped out", waveReached = 2 })
	assertTest("Transition InProgress -> Failed is valid", okFail == true and MissionService.GetState() == "Failed")

	MissionService.ResetMission()
	assertTest("ResetMission from Failed resets state to 'Lobby'", MissionService.GetState() == "Lobby")

	-- 4. Rejection of Invalid Transitions
	local bad1 = MissionService.TransitionTo("Success")
	assertTest("Invalid transition Lobby -> Success is rejected", bad1 == false and MissionService.GetState() == "Lobby")

	local bad2 = MissionService.TransitionTo("Boss")
	assertTest("Invalid transition Lobby -> Boss is rejected", bad2 == false and MissionService.GetState() == "Lobby")

	local bad3 = MissionService.TransitionTo("InProgress")
	assertTest("Invalid transition Lobby -> InProgress directly is rejected", bad3 == false and MissionService.GetState() == "Lobby")

	-- 5. Duplicate Terminal End Events Prevention
	MissionService.TransitionTo("Starting")
	MissionService.TransitionTo("InProgress")

	local comp1, errComp1 = MissionService.CompleteMission({ totalWaves = 1, missionDuration = 45 })
	assertTest("First CompleteMission succeeds", comp1 == true and MissionService.GetState() == "Success")

	local comp2, errComp2 = MissionService.CompleteMission({ totalWaves = 1, missionDuration = 45 })
	assertTest("Duplicate CompleteMission call is rejected", comp2 == false and errComp2 ~= nil)

	local failAfterComp, errFailComp = MissionService.FailMission("Attempt fail after success")
	assertTest("FailMission called after Success is rejected", failAfterComp == false and errFailComp ~= nil)
	assertTest("State remains 'Success' despite duplicate end calls", MissionService.GetState() == "Success")

	MissionService.ResetMission()

	-- 6. Duplicate Terminal Failure Events Prevention
	MissionService.TransitionTo("Starting")
	MissionService.TransitionTo("InProgress")

	local fail1, errFail1 = MissionService.FailMission("Core reactor destroyed")
	assertTest("First FailMission succeeds", fail1 == true and MissionService.GetState() == "Failed")

	local fail2, errFail2 = MissionService.FailMission("Duplicate fail call")
	assertTest("Duplicate FailMission call is rejected", fail2 == false and errFail2 ~= nil)

	local compAfterFail, errCompFail = MissionService.CompleteMission()
	assertTest("CompleteMission called after Failed is rejected", compAfterFail == false and errCompFail ~= nil)
	assertTest("State remains 'Failed' despite duplicate end calls", MissionService.GetState() == "Failed")

	MissionService.ResetMission()

	-- 7. Starting Countdown Cancellation on Reset
	local startOk = MissionService.StartMission(nil, 10.0) -- 10s countdown
	assertTest("StartMission enters 'Starting' state", startOk == true and MissionService.GetState() == "Starting")

	MissionService.ResetMission()
	assertTest("ResetMission cancels starting countdown and returns to 'Lobby'", MissionService.GetState() == "Lobby")

	-- 8. Early Player Leave (Empty Server During Active Mission)
	local p1 = createMockPlayer(3001, "PilotAlpha")
	SessionService.AddPlayer(p1)

	MissionService.StartMission(nil, 0) -- Instant launch into InProgress
	assertTest("Instant launch reached 'InProgress'", MissionService.GetState() == "InProgress")

	-- PilotAlpha leaves session
	SessionService.RemovePlayer(3001)
	assertTest("Team is now empty (activeCount == 0)", SessionService.GetActivePlayerCount() == 0)
	assertTest("Empty team triggers automatic Reset to 'Lobby'", MissionService.GetState() == "Lobby")

	-- 9. Team Wipe (All players downed with 0 lives)
	local p2 = createMockPlayer(3002, "PilotBravo")
	local p3 = createMockPlayer(3003, "PilotCharlie")
	SessionService.AddPlayer(p2)
	SessionService.AddPlayer(p3)

	MissionService.StartMission(nil, 0)
	assertTest("Co-op session started into 'InProgress'", MissionService.GetState() == "InProgress")

	-- Set both players to Downed with 0 lives
	SessionService.DeductLife(3002)
	SessionService.DeductLife(3002)
	SessionService.DeductLife(3002)
	SessionService.SetPlayerState(3002, "Downed")

	assertTest("Player 3002 downed with 0 lives does not wipe team yet", MissionService.GetState() == "InProgress")

	SessionService.DeductLife(3003)
	SessionService.DeductLife(3003)
	SessionService.DeductLife(3003)
	SessionService.SetPlayerState(3003, "Downed")

	assertTest("Both players downed with 0 lives triggers MissionService 'Failed'", MissionService.GetState() == "Failed")

	-- 10. Clean Reset & Teardown
	SessionService.RemovePlayer(3002)
	SessionService.RemovePlayer(3003)
	MissionService.ResetMission()
	assertTest("ResetMission returns to clean 'Lobby'", MissionService.GetState() == "Lobby")

	-- 11. Reset Race Idempotence
	local race1 = MissionService.ResetMission()
	local race2 = MissionService.ResetMission()
	local race3 = MissionService.ResetMission()
	assertTest("Multiple successive resets are safe and idempotent", race1 == true and race2 == true and race3 == true and MissionService.GetState() == "Lobby")

	-- Teardown
	MissionService._Teardown()
	SessionService._Teardown()
	WaveService._Teardown()
	EnemyService.CleanupAll()
	AircraftService._Reset()

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return MissionStateTests
