--!strict
--[[
	WeaponService.luau
	Authoritative server combat service for weapon cooldowns, firing intents, and projectile generation.
	Task: CLAY-010 (Standard Weapon Firing Loop)

	SECURITY & AUTHORITY:
	- Server strictly validates weapon cooldowns using server os.clock().
	- Client cannot accelerate fire rate or spoof damage values.
	- Projectiles are instantiated under Workspace.Projectiles with non-colliding physics tags.
]]

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local sharedWeaponConfig = SharedFolder:WaitForChild("WeaponConfig")
local WeaponConfig = require(sharedWeaponConfig)
if (WeaponConfig :: any).Weapons == nil then
	WeaponConfig = require(sharedWeaponConfig:Clone())
end

local RemoteContracts = require(SharedFolder:WaitForChild("RemoteContracts"))

local ProjectileService: any = nil

local function getProjectileService(): any?
	if ProjectileService then
		return ProjectileService
	end
	if script.Parent then
		local pMod = script.Parent:FindFirstChild("ProjectileService")
		if pMod then
			local ok, svc = pcall(require, pMod)
			if ok and svc then
				ProjectileService = svc
				return svc
			end
		end
	end
	local sss = game:GetService("ServerScriptService")
	local services = sss:FindFirstChild("Services")
	if services then
		local pMod = services:FindFirstChild("ProjectileService")
		if pMod then
			local ok, svc = pcall(require, pMod)
			if ok and svc then
				ProjectileService = svc
				return svc
			end
		end
	end
	return nil
end

local WeaponService = {}

type PlayerCombatState = {
	activeWeaponId: string,
	lastFireTime: number,
	shotCount: number,
}

local playerStates: { [number]: PlayerCombatState } = {}
local isInitialized = false
local playerRemovingConn: RBXScriptConnection? = nil
local fireWeaponRemote: RemoteEvent? = nil
local projectilesFolder: Folder? = nil
local totalServerShots = 0

-- Helper to retrieve or create the authoritative Projectiles folder in Workspace
local function getProjectilesFolder(): Folder
	local existing = Workspace:FindFirstChild("Projectiles")
	if existing and existing:IsA("Folder") then
		projectilesFolder = existing
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Projectiles"
	folder.Parent = Workspace
	projectilesFolder = folder
	return folder
end

--[[
	Initializes or retrieves the combat state for a player.
]]
local function getOrCreateState(userId: number): PlayerCombatState
	local state = playerStates[userId]
	if not state then
		state = {
			activeWeaponId = WeaponConfig.DEFAULT_WEAPON_ID,
			lastFireTime = 0,
			shotCount = 0,
		}
		playerStates[userId] = state
	end
	return state
end

--[[
	Resolves the active aircraft model for a player from Workspace.ActivePlanes.
]]
local function resolvePlayerAircraft(player: Player): Model?
	local activePlanes = Workspace:FindFirstChild("ActivePlanes")
	if not activePlanes then
		return nil
	end
	local model = activePlanes:FindFirstChild(string.format("Plane_%d", player.UserId))
		or activePlanes:FindFirstChild(tostring(player.UserId))
	if model and model:IsA("Model") and model.PrimaryPart then
		return model
	end
	return nil
end

--[[
	Spawns an authoritative projectile instance in Workspace.Projectiles.
]]
local function spawnAuthoritativeProjectile(
	player: Player,
	origin: Vector3,
	aimDirection: Vector2,
	weaponDef: WeaponConfig.WeaponDefinition
): BasePart
	totalServerShots += 1
	local projSvc = getProjectileService()
	if projSvc then
		return projSvc.SpawnProjectile(player.UserId, origin, aimDirection, weaponDef)
	end

	local container = getProjectilesFolder()

	local proj = Instance.new("Part")
	proj.Name = string.format("Proj_%d_%d", player.UserId, totalServerShots)
	proj.Size = Vector3.new(weaponDef.projectileRadius * 2, weaponDef.projectileRadius * 1.5, weaponDef.projectileRadius * 1.5)
	proj.Position = origin
	proj.Material = Enum.Material.SmoothPlastic
	proj.Color = weaponDef.bulletColor
	proj.Anchored = true
	proj.CanCollide = false
	proj.CanTouch = false
	proj.CanQuery = false
	proj.CastShadow = false

	-- Authoritative metadata tags
	proj:SetAttribute("OwnerUserId", player.UserId)
	proj:SetAttribute("BaseDamage", weaponDef.baseDamage)
	proj:SetAttribute("ProjectileSpeed", weaponDef.projectileSpeed)
	proj:SetAttribute("SpawnTime", os.clock())
	proj:SetAttribute("Lifetime", weaponDef.lifetime)
	proj:SetAttribute("DirectionX", aimDirection.X)
	proj:SetAttribute("DirectionY", aimDirection.Y)

	proj.Parent = container
	return proj
end

--[[
	Handles a validated FireWeapon request from the network boundary.
	Enforces server cooldowns, validates aircraft existence, and authoritatively spawns projectiles.
]]
function WeaponService.HandleFireIntent(player: Player, weaponId: string, aimDirection: Vector2): (boolean, string?)
	if not player or not (player :: any).UserId then
		return false, "InvalidPlayer"
	end

	local state = getOrCreateState(player.UserId)
	local weaponDef = WeaponConfig.GetWeapon(weaponId) or WeaponConfig.GetDefaultWeapon()

	-- 1. Verify player has an active aircraft alive in the arena
	local aircraft = resolvePlayerAircraft(player)
	if not aircraft or not aircraft.PrimaryPart then
		return false, "NoActiveAircraft"
	end

	-- 2. Authoritative server cooldown enforcement
	local now = os.clock()
	local timeSinceLastFire = now - state.lastFireTime
	if timeSinceLastFire < weaponDef.cooldown then
		return false, "CooldownActive"
	end

	-- Cooldown verified — commit new firing time
	state.lastFireTime = now
	state.shotCount += 1
	state.activeWeaponId = weaponDef.id

	-- 3. Calculate authoritative muzzle position from plane forward bounds
	local primary = aircraft.PrimaryPart
	local muzzleOffset = Vector3.new((primary.Size.X / 2) + 1.5, 0, 0)
	local muzzleOrigin = primary.Position + muzzleOffset

	-- 4. Spawn projectiles for each spread angle
	local normalizedAim = if aimDirection.Magnitude > 0.001 then aimDirection.Unit else Vector2.new(1, 0)
	for _, angleDeg in ipairs(weaponDef.spreadAngles) do
		local rad = math.rad(angleDeg)
		local rotatedDir = Vector2.new(
			normalizedAim.X * math.cos(rad) - normalizedAim.Y * math.sin(rad),
			normalizedAim.X * math.sin(rad) + normalizedAim.Y * math.cos(rad)
		)
		spawnAuthoritativeProjectile(player, muzzleOrigin, rotatedDir, weaponDef)
	end

	-- 5. Broadcast visual shot event to clients for muzzle flash presentation
	if fireWeaponRemote and RunService:IsRunning() then
		fireWeaponRemote:FireAllClients({
			playerId = player.UserId,
			weaponId = weaponDef.id,
			origin = muzzleOrigin,
			aimDirection = normalizedAim,
		})
	end

	return true, nil
end

--[[
	Initializes WeaponService. Idempotent.
]]
function WeaponService.Initialize()
	if isInitialized then
		return
	end
	isInitialized = true

	getProjectilesFolder()

	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
	local remote = remotesFolder:WaitForChild(RemoteContracts.RemoteNames.FireWeapon, 5)
	if remote and remote:IsA("RemoteEvent") then
		fireWeaponRemote = remote :: RemoteEvent
	end

	playerRemovingConn = Players.PlayerRemoving:Connect(function(player: Player)
		playerStates[player.UserId] = nil
	end)

	if ProjectileService then
		ProjectileService.Initialize()
	end

	print("[WeaponService] Authoritative combat weapon service initialized.")
end

--[[
	Returns true if WeaponService is currently initialized.
]]
function WeaponService.IsInitialized(): boolean
	return isInitialized
end

--[[
	Injects or sets ProjectileService for testing.
]]
function WeaponService.SetProjectileService(service: any)
	ProjectileService = service
end

--[[
	Returns the combat state for a player, or nil if uninitialized.
]]
function WeaponService.GetPlayerState(userId: number): PlayerCombatState?
	return playerStates[userId]
end

--[[
	Returns the total shots spawned by the server.
]]
function WeaponService.GetTotalServerShots(): number
	return totalServerShots
end

--[[
	Cleans up all tracked states, projectile models, and connections.
]]
function WeaponService._Teardown()
	if playerRemovingConn then
		playerRemovingConn:Disconnect()
		playerRemovingConn = nil
	end
	playerStates = {}
	totalServerShots = 0
	isInitialized = false
	fireWeaponRemote = nil

	if ProjectileService then
		ProjectileService._Teardown()
	end

	local container = Workspace:FindFirstChild("Projectiles")
	if container then
		container:ClearAllChildren()
	end
end

return WeaponService
