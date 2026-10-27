--!strict
--[[
	ClientBootstrap.client.luau
	Client presentation entry point for CLAYSTRIKE.
	Verifies client baseline and subscribes to shared network contracts.
	Task: CLAY-001 / CLAY-002
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Architecture = require(SharedFolder:WaitForChild("Architecture"))
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local WeaponConfig = require(SharedFolder:WaitForChild("WeaponConfig"))
local RemoteContracts = require(SharedFolder:WaitForChild("RemoteContracts"))

-- 1. Validate client-accessible baseline
local baselineSuccess, missing = Architecture.ValidateClientBaseline()
if not baselineSuccess then
	warn(string.format("[CLAYSTRIKE - Client] Missing required baseline folders:\n  - %s", table.concat(missing, "\n  - ")))
else
	print("[CLAYSTRIKE - ClientBootstrap] Client and Shared Explorer baseline validated successfully.")
end

-- 2. Verify accessible network contracts
local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local movePlaneRemote = remotesFolder:WaitForChild(RemoteContracts.RemoteNames.MovePlane, 5)
local fireWeaponRemote = remotesFolder:WaitForChild(RemoteContracts.RemoteNames.FireWeapon, 5)
local gameStateRemote = remotesFolder:WaitForChild(RemoteContracts.RemoteNames.GameStateChanged, 5)

if movePlaneRemote and fireWeaponRemote and gameStateRemote then
	print(string.format("[CLAYSTRIKE - ClientBootstrap] Network contracts verified (v%s). Ready for client controller binding.", GameConfig.CONTRACT_VERSION))
else
	warn("[CLAYSTRIKE - ClientBootstrap] One or more RemoteEvents missing from ReplicatedStorage.Remotes.")
end
