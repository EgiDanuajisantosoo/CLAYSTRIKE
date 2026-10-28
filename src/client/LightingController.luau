--!strict
--[[
	LightingController.luau
	Client-side lighting and visual presentation controller for CLAYSTRIKE.
	Task: CLAY-029 (Clay Material & Lighting Preset)

	Applies the canonical claymation lighting preset on startup, ensuring
	consistent material readability, contrast, and atmospheric depth on client.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local LightingConfig = require(SharedFolder:WaitForChild("LightingConfig"))

local LightingController = {}
local isInitialized = false

function LightingController.Init()
	if isInitialized then
		return
	end
	isInitialized = true

	LightingConfig.ApplyLighting(Lighting)
end
LightingController.Initialize = LightingController.Init

function LightingController.IsInitialized(): boolean
	return isInitialized
end

return LightingController
