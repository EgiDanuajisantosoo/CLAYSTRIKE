--!strict
--[[
	CLAYSTRIKE Architecture Baseline
	Source of truth for service folders, script roles, and naming conventions.
	Task: CLAY-001 (Project Setup & Explorer Baseline)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

export type FolderContract = {
	name: string,
	parent: Instance,
}

local Architecture = {}

-- Replicated folders that both server and client interact with
Architecture.SharedFolders = {
	Shared = { name = "Shared", parent = ReplicatedStorage },
	Remotes = { name = "Remotes", parent = ReplicatedStorage },
	Assets = { name = "Assets", parent = ReplicatedStorage },
	CombatArena = { name = "CombatArena", parent = Workspace },
	ActivePlanes = { name = "ActivePlanes", parent = Workspace },
	Projectiles = { name = "Projectiles", parent = Workspace },
	Enemies = { name = "Enemies", parent = Workspace },
}

-- Authoritative server-only folders and StarterPlayer template container
Architecture.ServerFolders = {
	Services = { name = "Services", parent = ServerScriptService },
	EnemyTemplates = { name = "EnemyTemplates", parent = ServerStorage },
	StarterControllers = { name = "Controllers", parent = StarterPlayer:WaitForChild("StarterPlayerScripts") },
}

local function checkFolders(folderContracts: { [string]: FolderContract }, missing: { string })
	for _, contract in pairs(folderContracts) do
		local found = contract.parent:FindFirstChild(contract.name)
		if not found or not found:IsA("Folder") then
			table.insert(missing, string.format("%s.%s", contract.parent.Name, contract.name))
		end
	end
end

--[[
	Authoritative server baseline check.
	Validates all shared runtime folders, server services, and the StarterPlayer container.
]]
function Architecture.ValidateServerBaseline(): (boolean, { string })
	assert(RunService:IsServer(), "ValidateServerBaseline can only be executed on the server.")
	local missing: { string } = {}

	checkFolders(Architecture.SharedFolders, missing)
	checkFolders(Architecture.ServerFolders, missing)

	return #missing == 0, missing
end

--[[
	Client-side baseline check.
	Validates replicated shared folders and the local PlayerScripts.Controllers runtime container.
]]
function Architecture.ValidateClientBaseline(): (boolean, { string })
	assert(RunService:IsClient(), "ValidateClientBaseline can only be executed on the client.")
	local missing: { string } = {}

	checkFolders(Architecture.SharedFolders, missing)

	-- Verify active client controller folder in the local player's PlayerScripts
	local localPlayer = Players.LocalPlayer
	if localPlayer then
		local playerScripts = localPlayer:WaitForChild("PlayerScripts", 5)
		if playerScripts then
			local controllers = playerScripts:FindFirstChild("Controllers")
			if not controllers or not controllers:IsA("Folder") then
				table.insert(missing, "LocalPlayer.PlayerScripts.Controllers")
			end
		else
			table.insert(missing, "LocalPlayer.PlayerScripts")
		end
	else
		table.insert(missing, "Players.LocalPlayer")
	end

	return #missing == 0, missing
end

return Architecture
