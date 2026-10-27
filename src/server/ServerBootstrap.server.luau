--!strict
--[[
	ServerBootstrap.server.luau
	Authoritative server entry point for CLAYSTRIKE.
	Verifies Explorer baseline, validates network contracts, and initializes security boundaries.
	Task: CLAY-001 / CLAY-002

	HALT-ON-FAILURE POLICY:
	If baseline validation or contract unit tests fail, server initialization halts immediately
	with an explicit error, preventing insecure or broken network listener startup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Architecture = require(SharedFolder:WaitForChild("Architecture"))
local ContractTests = require(SharedFolder:WaitForChild("ContractTests"))
local RemoteManager = require(script.Parent:WaitForChild("RemoteManager"))

-- 1. Validate baseline structure
local baselineSuccess, missing = Architecture.ValidateServerBaseline()
if not baselineSuccess then
	error(string.format(
		"[CLAYSTRIKE - ServerBootstrap] CRITICAL: Missing required baseline folders:\n  - %s\nHalting server initialization.",
		table.concat(missing, "\n  - ")
	))
end
print("[CLAYSTRIKE - ServerBootstrap] Server and Shared Explorer baseline validated successfully.")

-- 2. Execute isolated contract validation tests
local testSummary = ContractTests.RunTests()
if testSummary.failed > 0 then
	error(string.format(
		"[CLAYSTRIKE - ServerBootstrap] CRITICAL: %d/%d contract validation tests FAILED. Halting network initialization.",
		testSummary.failed,
		testSummary.total
	))
end
print(string.format("[CLAYSTRIKE - ContractTests] %d/%d isolated contract validation tests PASSED.", testSummary.passed, testSummary.total))

-- 3. Initialize authoritative network remotes & security boundaries
RemoteManager.Initialize()
