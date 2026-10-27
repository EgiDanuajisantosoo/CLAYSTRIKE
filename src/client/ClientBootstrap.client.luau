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
local RemoteContracts = require(SharedFolder:WaitForChild("RemoteContracts"))

-- 1. Validate client-accessible baseline
local baselineSuccess, missing = Architecture.ValidateClientBaseline()
if not baselineSuccess then
	error(string.format("[CLAYSTRIKE - ClientBootstrap] CRITICAL: Missing required baseline folders:\n  - %s", table.concat(missing, "\n  - ")))
end
print("[CLAYSTRIKE - ClientBootstrap] Client and Shared Explorer baseline validated successfully.")

-- 2. Verify accessible network contracts with strict ClassName check
local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")

local function verifyClientRemote(name: string): RemoteEvent
	local obj = remotesFolder:WaitForChild(name, 5)
	if not obj then
		error(string.format("[CLAYSTRIKE - ClientBootstrap] Timeout: Remote '%s' missing from ReplicatedStorage.Remotes.", name))
	end
	if not obj:IsA("RemoteEvent") then
		error(string.format(
			"[CLAYSTRIKE - ClientBootstrap] Critical Conflict: Instance '%s' under ReplicatedStorage.Remotes is a '%s', expected 'RemoteEvent'.",
			name,
			obj.ClassName
		))
	end
	return obj :: RemoteEvent
end

local movePlaneRemote = verifyClientRemote(RemoteContracts.RemoteNames.MovePlane)
local fireWeaponRemote = verifyClientRemote(RemoteContracts.RemoteNames.FireWeapon)
local gameStateRemote = verifyClientRemote(RemoteContracts.RemoteNames.GameStateChanged)

if movePlaneRemote and fireWeaponRemote and gameStateRemote then
	print(string.format("[CLAYSTRIKE - ClientBootstrap] Network contracts verified (v%s). Ready for client controller binding.", GameConfig.CONTRACT_VERSION))
end

-- 3. Initialize client controllers
local MovementController = require(script.Parent:WaitForChild("MovementController"))
MovementController.Initialize()

local CameraController = require(script.Parent:WaitForChild("CameraController"))
CameraController.Initialize()

local BackgroundController = require(script.Parent:WaitForChild("BackgroundController"))
BackgroundController.Initialize()

