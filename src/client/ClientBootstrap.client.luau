--!strict
--[[
	ClientBootstrap.client.luau
	Client presentation entry point for CLAYSTRIKE.
	Verifies client-accessible shared folders and local PlayerScripts.Controllers container upon player join.
	Task: CLAY-001 (Project Setup & Explorer Baseline)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Architecture = require(SharedFolder:WaitForChild("Architecture"))

local success, missing = Architecture.ValidateClientBaseline()

if not success then
	warn(string.format("[CLAYSTRIKE - Client] Missing required baseline folders:\n  - %s", table.concat(missing, "\n  - ")))
else
	print("[CLAYSTRIKE - ClientBootstrap] Client and Shared Explorer baseline validated successfully.")
end
