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
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

export type FolderContract = {
	name: string,
	parent: Instance,
}

local Architecture = {}

-- Definition of all canonical baseline folders required by CLAYSTRIKE
Architecture.RequiredFolders = {
	Shared = { name = "Shared", parent = ReplicatedStorage },
	Remotes = { name = "Remotes", parent = ReplicatedStorage },
	Assets = { name = "Assets", parent = ReplicatedStorage },
	Services = { name = "Services", parent = ServerScriptService },
	EnemyTemplates = { name = "EnemyTemplates", parent = ServerStorage },
	Controllers = { name = "Controllers", parent = StarterPlayer:WaitForChild("StarterPlayerScripts") },
	CombatArena = { name = "CombatArena", parent = Workspace },
	Projectiles = { name = "Projectiles", parent = Workspace },
	Enemies = { name = "Enemies", parent = Workspace },
}

--[[
	Validates that required folders exist for the current runtime context.
	Returns (true, missingList) if all exist or lists any missing folders.
]]
function Architecture.ValidateBaseline(): (boolean, { string })
	local isServer = RunService:IsServer()
	local missing: { string } = {}

	for folderKey, contract in pairs(Architecture.RequiredFolders) do
		-- Skip ServerStorage/ServerScriptService checks if running on client (not accessible)
		if not isServer and (contract.parent == ServerStorage or contract.parent == ServerScriptService) then
			continue
		end

		local found = contract.parent:FindFirstChild(contract.name)
		if not found or not found:IsA("Folder") then
			table.insert(missing, string.format("%s.%s", contract.parent.Name, contract.name))
		end
	end

	return #missing == 0, missing
end

return Architecture
