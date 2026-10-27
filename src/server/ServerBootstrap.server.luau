--!strict
--[[
	ServerBootstrap.server.luau
	Authoritative server entry point for CLAYSTRIKE.
	Verifies Explorer baseline folders before game services initialize.
	Task: CLAY-001 (Project Setup & Explorer Baseline)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Architecture = require(SharedFolder:WaitForChild("Architecture"))

local success, missing = Architecture.ValidateBaseline()

if not success then
	warn(string.format("[CLAYSTRIKE - Server] Missing required baseline folders:\n  - %s", table.concat(missing, "\n  - ")))
else
	print("[CLAYSTRIKE - ServerBootstrap] Explorer baseline validated successfully.")
end
