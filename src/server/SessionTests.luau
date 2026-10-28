--!strict
--[[
	SessionTests.luau
	Comprehensive unit tests for Co-op Player State & Team Session.
	Task: CLAY-022 (Co-op Player State & Team Session)
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local SessionConfig = require(SharedFolder:WaitForChild("SessionConfig"))
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))

local Services = ServerScriptService:WaitForChild("Services")
local SessionService = require(Services:WaitForChild("SessionService"))
local AircraftService = require(Services:WaitForChild("AircraftService"))
local WaveService = require(Services:WaitForChild("WaveService"))

local SessionTests = {}

export type TestResult = {
	name: string,
	passed: boolean,
	error: string?,
}

-- Mock Player Factory
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

function SessionTests.RunTests(): {
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
			warn(string.format("[SessionTests FAIL] Test %d: %s - %s", testIndex, name, failureText))
		end
	end

	-- Teardown for clean baseline
	SessionService._Teardown()
	AircraftService._Reset()
	WaveService._Teardown()
	WaveService.Initialize()

	-- 1. SessionConfig Schema Validation
	assertTest("SessionConfig.MAX_TEAM_SIZE is 4", SessionConfig.MAX_TEAM_SIZE == 4)
	assertTest("SessionConfig.DEFAULT_LIVES is 3", SessionConfig.DEFAULT_LIVES == 3)
	assertTest("Valid states recognized",
		SessionConfig.IsValidState("Joining") and
		SessionConfig.IsValidState("Active") and
		SessionConfig.IsValidState("Downed") and
		SessionConfig.IsValidState("Respawning") and
		SessionConfig.IsValidState("Disconnected"))
	assertTest("Invalid state rejected", SessionConfig.IsValidState("InvincibleGodMode") == false)

	-- 2. State Transition Rules
	assertTest("Can transition Joining -> Active", SessionConfig.CanTransition("Joining", "Active") == true)
	assertTest("Can transition Active -> Downed", SessionConfig.CanTransition("Active", "Downed") == true)
	assertTest("Can transition Downed -> Respawning", SessionConfig.CanTransition("Downed", "Respawning") == true)
	assertTest("Can transition Respawning -> Active", SessionConfig.CanTransition("Respawning", "Active") == true)
	assertTest("Can transition Active -> Disconnected", SessionConfig.CanTransition("Active", "Disconnected") == true)
	assertTest("Illegal transition Downed -> Active rejected", SessionConfig.CanTransition("Downed", "Active") == false)
	assertTest("Illegal transition Disconnected -> Active rejected", SessionConfig.CanTransition("Disconnected", "Active") == false)

	-- 3. Player Record Validation
	local validRecord: SessionConfig.PlayerSessionRecord = {
		userId = 1001,
		username = "PilotAlpha",
		state = "Active",
		score = 500,
		lives = 3,
		joinTime = os.clock(),
		planeModel = nil,
	}
	local recOk, recErr = SessionConfig.ValidatePlayerRecord(validRecord)
	assertTest("Valid player record passes validation", recOk == true and recErr == nil)

	local invalidRecord = table.clone(validRecord)
	invalidRecord.userId = -5
	local badIdOk, _ = SessionConfig.ValidatePlayerRecord(invalidRecord)
	assertTest("Reject record with negative userId", badIdOk == false)

	-- 4. SessionService Initialization & Initial State
	SessionService.Initialize()
	assertTest("SessionService is initialized", SessionService.IsInitialized() == true)
	assertTest("Initial active player count is 0", SessionService.GetActivePlayerCount() == 0)

	local teamFolder = ReplicatedStorage:FindFirstChild("TeamState")
	assertTest("TeamState folder created in ReplicatedStorage", teamFolder ~= nil and teamFolder:IsA("Folder"))

	-- 5. Add Player 1 (Solo join)
	local p1 = createMockPlayer(1001, "PilotAlpha")
	local p1JoinOk, p1JoinErr = SessionService.AddPlayer(p1)
	assertTest("AddPlayer for Player 1 succeeds", p1JoinOk == true and p1JoinErr == nil)
	assertTest("Active player count is now 1", SessionService.GetActivePlayerCount() == 1)
	assertTest("Player 1 state is Active", SessionService.GetPlayerState(1001) == "Active")

	local p1Folder = teamFolder and teamFolder:FindFirstChild("Player_1001")
	assertTest("Replicated Player_1001 folder exists", p1Folder ~= nil)
	assertTest("Replicated UserId attribute is 1001", p1Folder ~= nil and p1Folder:GetAttribute("UserId") == 1001)
	assertTest("Replicated State attribute is 'Active'", p1Folder ~= nil and p1Folder:GetAttribute("State") == "Active")
	assertTest("Replicated Score attribute is 0", p1Folder ~= nil and p1Folder:GetAttribute("Score") == 0)
	assertTest("Replicated Lives attribute is 3", p1Folder ~= nil and p1Folder:GetAttribute("Lives") == 3)

	-- 6. Player Plane Association
	local planesFolder = Workspace:FindFirstChild("ActivePlanes")
	local p1Plane = planesFolder and planesFolder:FindFirstChild("Plane_1001")
	assertTest("Authoritative aircraft spawned for Player 1", p1Plane ~= nil and p1Plane:IsA("Model"))

	-- 7. Multi-player Co-op (Add Players 2, 3, 4)
	local p2 = createMockPlayer(1002, "PilotBravo")
	local p3 = createMockPlayer(1003, "PilotCharlie")
	local p4 = createMockPlayer(1004, "PilotDelta")

	local p2Ok, _ = SessionService.AddPlayer(p2)
	local p3Ok, _ = SessionService.AddPlayer(p3)
	local p4Ok, _ = SessionService.AddPlayer(p4)
	assertTest("Player 2, 3, 4 join successfully", p2Ok == true and p3Ok == true and p4Ok == true)
	assertTest("Active player count reaches MAX_TEAM_SIZE (4)", SessionService.GetActivePlayerCount() == 4)

	-- 8. Capacity Enforcement (Player 5 rejected)
	local p5 = createMockPlayer(1005, "PilotEcho")
	local p5Ok, p5Err = SessionService.AddPlayer(p5)
	assertTest("Player 5 rejected when team is full", p5Ok == false and string.find(p5Err or "", "full") ~= nil)
	assertTest("Active player count remains 4", SessionService.GetActivePlayerCount() == 4)

	-- 9. Authoritative Score & Lives Management
	local scoreAfter = SessionService.AddScore(1001, 250)
	assertTest("AddScore increases Player 1 score to 250", scoreAfter == 250)
	assertTest("Replicated Score attribute updated to 250", p1Folder ~= nil and p1Folder:GetAttribute("Score") == 250)

	local livesAfter = SessionService.DeductLife(1001)
	assertTest("DeductLife decreases Player 1 lives to 2", livesAfter == 2)
	assertTest("Replicated Lives attribute updated to 2", p1Folder ~= nil and p1Folder:GetAttribute("Lives") == 2)

	-- 10. Lifecycle State Transitions (Active -> Downed -> Respawning -> Active)
	local downOk = SessionService.SetPlayerState(1001, "Downed")
	assertTest("Transition Player 1 to Downed succeeds", downOk == true)
	assertTest("Replicated state is Downed", p1Folder ~= nil and p1Folder:GetAttribute("State") == "Downed")

	local respawnOk = SessionService.SetPlayerState(1001, "Respawning")
	assertTest("Transition Player 1 to Respawning succeeds", respawnOk == true)
	assertTest("Replicated state is Respawning", p1Folder ~= nil and p1Folder:GetAttribute("State") == "Respawning")

	local activeAgainOk = SessionService.SetPlayerState(1001, "Active")
	assertTest("Transition Player 1 back to Active succeeds", activeAgainOk == true)
	assertTest("Replicated state is Active", p1Folder ~= nil and p1Folder:GetAttribute("State") == "Active")

	-- 11. Mid-Mission Player Removal (Leave does not break progression)
	-- Start a wave to verify wave progression integrity
	WaveService.Step(2.5) -- Step past intermission into Spawning
	local waveNumBefore = WaveService.GetCurrentWaveNumber()

	-- Player 2 leaves
	local p2Removed = SessionService.RemovePlayer(1002)
	assertTest("Player 2 removed successfully", p2Removed == true)
	assertTest("Active player count drops to 3", SessionService.GetActivePlayerCount() == 3)
	assertTest("Player_1002 replication folder removed", teamFolder:FindFirstChild("Player_1002") == nil)
	assertTest("Player 2 plane despawned from ActivePlanes", planesFolder:FindFirstChild("Plane_1002") == nil)

	-- Advance wave step: wave continues cleanly without crashing
	local stepOk = pcall(function()
		WaveService.Step(0.5)
	end)
	assertTest("Wave simulation continues unaffected by player disconnect", stepOk == true)

	-- Player 3 and 4 leave
	SessionService.RemovePlayer(1003)
	SessionService.RemovePlayer(1004)
	assertTest("Active player count is 1 (Player 1 remaining)", SessionService.GetActivePlayerCount() == 1)

	-- 12. Complete Team Departure (All players leave resets mission)
	SessionService.RemovePlayer(1001)
	assertTest("Active player count is now 0", SessionService.GetActivePlayerCount() == 0)
	assertTest("Mission resets to Idle when all players depart", WaveService.GetState() == "Idle")

	-- Final cleanup
	SessionService._Teardown()
	AircraftService._Reset()
	WaveService._Teardown()
	assertTest("TeamState container cleared on teardown", teamFolder == nil or #teamFolder:GetChildren() == 0)

	return {
		total = passedCount + failedCount,
		passed = passedCount,
		failed = failedCount,
		results = results,
	}
end

return SessionTests
