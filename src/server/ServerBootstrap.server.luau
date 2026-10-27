--!strict
--[[
	ServerBootstrap.server.luau
	Authoritative server entry point for CLAYSTRIKE.
	Verifies Explorer baseline and initializes secure network contracts.
	Task: CLAY-001 / CLAY-002
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Architecture = require(SharedFolder:WaitForChild("Architecture"))
local ContractTests = require(SharedFolder:WaitForChild("ContractTests"))
local RemoteManager = require(script.Parent:WaitForChild("RemoteManager"))

-- 1. Validate baseline structure
local baselineSuccess, missing = Architecture.ValidateServerBaseline()
if not baselineSuccess then
	warn(string.format("[CLAYSTRIKE - Server] Missing required baseline folders:\n  - %s", table.concat(missing, "\n  - ")))
else
	print("[CLAYSTRIKE - ServerBootstrap] Server and Shared Explorer baseline validated successfully.")
end

-- 2. Execute isolated contract validation tests
local testSummary = ContractTests.RunTests()
if testSummary.failed == 0 then
	print(string.format("[CLAYSTRIKE - ContractTests] %d/%d isolated contract validation tests PASSED.", testSummary.passed, testSummary.total))
else
	warn(string.format("[CLAYSTRIKE - ContractTests] %d tests FAILED out of %d.", testSummary.failed, testSummary.total))
end

-- 3. Initialize authoritative network remotes & security boundaries
RemoteManager.Initialize()
