--!strict
--[[
	ProjectileService.luau
	Authoritative server projectile simulation, anti-tunneling swept raycasts, and hit detection.
	Task: CLAY-011 (Server Projectile Simulation & Hit Detection)

	AUTHORITY & ANTI-CHEAT:
	1. Complete Server Simulation: All projectile positions and velocities are strictly stepped on the server.
	2. Swept Raycasting: Prevents fast projectiles (speed >= 120 studs/s) from tunneling through thin targets.
	3. Friendly Fire Filtering: Player planes, shooter's own aircraft, and irrelevant geometry are excluded.
	4. Lifetime & Boundary Culling: Projectiles exceeding lifetime or exiting the combat arena are destroyed.
	5. Active Count Limiter: Hard-capped to prevent projectile spam or memory unboundedness.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local sharedGameConfig = SharedFolder:WaitForChild("GameConfig")
local GameConfig = require(sharedGameConfig)
if (GameConfig :: any).CONTRACT_VERSION == nil then
	GameConfig = require(sharedGameConfig:Clone())
end

local sharedWeaponConfig = SharedFolder:WaitForChild("WeaponConfig")
local WeaponConfig = require(sharedWeaponConfig)
if (WeaponConfig :: any).Weapons == nil then
	WeaponConfig = require(sharedWeaponConfig:Clone())
end

export type Projectile = {
	id: number,
	instance: BasePart,
	position: Vector3,
	direction: Vector3,
	speed: number,
	radius: number,
	baseDamage: number,
	ownerUserId: number,
	spawnTime: number,
	lifetime: number,
	elapsedTime: number,
}

export type HitResult = {
	projectileId: number,
	hitInstance: Instance,
	hitPosition: Vector3,
	hitNormal: Vector3,
	damage: number,
	ownerUserId: number,
}

export type HitCallback = (hit: HitResult) -> ()

local ProjectileService = {}

local activeProjectiles: { [number]: Projectile } = {}
local projectileOrder: { number } = {}
local hitCallbacks: { HitCallback } = {}

local heartbeatConn: RBXScriptConnection? = nil
local isInitialized = false
local nextProjectileId = 1
local maxActiveProjectiles = 250
local ARENA_BUFFER = 15

-- Helper to retrieve or create the authoritative Projectiles folder in Workspace
local function getProjectilesFolder(): Folder
	local existing = Workspace:FindFirstChild("Projectiles")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Projectiles"
	folder.Parent = Workspace
	return folder
end

--[[
	Resolves enemy targets container in Workspace.
]]
local function getEnemiesFolder(): Folder?
	local enemies = Workspace:FindFirstChild("Enemies")
	if enemies and enemies:IsA("Folder") then
		return enemies
	end
	local activeEnemies = Workspace:FindFirstChild("ActiveEnemies")
	if activeEnemies and activeEnemies:IsA("Folder") then
		return activeEnemies
	end
	return nil
end

--[[
	Despawns a projectile and frees tracking resources.
]]
local function despawnProjectile(id: number)
	local proj = activeProjectiles[id]
	if not proj then
		return
	end

	activeProjectiles[id] = nil

	-- Remove from order tracking
	local orderIdx = table.find(projectileOrder, id)
	if orderIdx then
		table.remove(projectileOrder, orderIdx)
	end

	if proj.instance and proj.instance.Parent then
		proj.instance:Destroy()
	end
end

--[[
	Enforces maximum active projectile cap by culling oldest projectiles (FIFO).
]]
local function enforceActiveLimit()
	while #projectileOrder > maxActiveProjectiles do
		local oldestId = projectileOrder[1]
		if oldestId then
			despawnProjectile(oldestId)
		else
			break
		end
	end
end

--[[
	Spawns an authoritative projectile simulated by ProjectileService.
]]
function ProjectileService.SpawnProjectile(
	ownerUserId: number,
	origin: Vector3,
	aimDirection: Vector2,
	weaponDef: WeaponConfig.WeaponDefinition
): BasePart
	local container = getProjectilesFolder()
	local projId = nextProjectileId
	nextProjectileId += 1

	local normAim = if aimDirection.Magnitude > 0.001 then aimDirection.Unit else Vector2.new(1, 0)
	local dir3D = Vector3.new(normAim.X, normAim.Y, 0)

	local part = Instance.new("Part")
	part.Name = string.format("Proj_%d_%d", ownerUserId, projId)
	part.Size = Vector3.new(weaponDef.projectileRadius * 2, weaponDef.projectileRadius * 1.5, weaponDef.projectileRadius * 1.5)
	part.Position = origin
	part.Material = Enum.Material.SmoothPlastic
	part.Color = weaponDef.bulletColor
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false

	part:SetAttribute("ProjectileId", projId)
	part:SetAttribute("OwnerUserId", ownerUserId)
	part:SetAttribute("BaseDamage", weaponDef.baseDamage)
	part:SetAttribute("ProjectileSpeed", weaponDef.projectileSpeed)
	part:SetAttribute("SpawnTime", os.clock())
	part:SetAttribute("Lifetime", weaponDef.lifetime)
	part:SetAttribute("DirectionX", normAim.X)
	part:SetAttribute("DirectionY", normAim.Y)

	part.Parent = container

	local projData: Projectile = {
		id = projId,
		instance = part,
		position = origin,
		direction = dir3D,
		speed = weaponDef.projectileSpeed,
		radius = weaponDef.projectileRadius,
		baseDamage = weaponDef.baseDamage,
		ownerUserId = ownerUserId,
		spawnTime = os.clock(),
		lifetime = weaponDef.lifetime,
		elapsedTime = 0,
	}

	activeProjectiles[projId] = projData
	table.insert(projectileOrder, projId)
	enforceActiveLimit()

	return part
end

--[[
	Steps the simulation of all active projectiles by dt.
	Handles anti-tunneling swept raycasts, hit detection, lifetime culling, and boundary clipping.
]]
function ProjectileService.StepSimulation(dt: number)
	if dt <= 0 then
		return
	end

	local arena = GameConfig.Arena
	local enemiesFolder = getEnemiesFolder()

	-- Set up raycast query parameters
	local raycastParams = RaycastParams.new()
	raycastParams.IgnoreWater = true

	if enemiesFolder and #enemiesFolder:GetChildren() > 0 then
		-- Preferred path: only test against enemies container
		raycastParams.FilterType = Enum.RaycastFilterType.Include
		raycastParams.FilterDescendantsInstances = { enemiesFolder }
	else
		-- Fallback: Exclude projectiles and player aircraft
		raycastParams.FilterType = Enum.RaycastFilterType.Exclude
		local exclusions: { Instance } = { getProjectilesFolder() }
		local activePlanes = Workspace:FindFirstChild("ActivePlanes")
		if activePlanes then
			table.insert(exclusions, activePlanes)
		end
		raycastParams.FilterDescendantsInstances = exclusions
	end

	-- Collect keys so modification during iteration is safe
	local idsToStep = {}
	for id, _ in pairs(activeProjectiles) do
		table.insert(idsToStep, id)
	end

	for _, id in ipairs(idsToStep) do
		local proj = activeProjectiles[id]
		if not proj then
			continue
		end

		proj.elapsedTime += dt

		-- 1. Lifetime expiration check
		if proj.elapsedTime >= proj.lifetime then
			despawnProjectile(id)
			continue
		end

		-- 2. Swept motion vector calculation
		local stepDistance = proj.speed * dt
		local stepVector = proj.direction * stepDistance
		local targetPos = proj.position + stepVector

		-- 3. Anti-tunneling swept raycast
		local rayResult = Workspace:Raycast(proj.position, stepVector, raycastParams)
		if rayResult and rayResult.Instance then
			local hitInstance = rayResult.Instance
			local hitNormal = rayResult.Normal
			local hitPos = rayResult.Position

			-- Notify hit observers
			local hitPayload: HitResult = {
				projectileId = proj.id,
				hitInstance = hitInstance,
				hitPosition = hitPos,
				hitNormal = hitNormal,
				damage = proj.baseDamage,
				ownerUserId = proj.ownerUserId,
			}

			for _, cb in ipairs(hitCallbacks) do
				task.spawn(cb, hitPayload)
			end

			-- Projectile consumed on hit
			despawnProjectile(id)
			continue
		end

		-- 4. Arena boundary clipping check
		if targetPos.X < (arena.MinX - ARENA_BUFFER)
			or targetPos.X > (arena.MaxX + ARENA_BUFFER)
			or targetPos.Y < (arena.MinY - ARENA_BUFFER)
			or targetPos.Y > (arena.MaxY + ARENA_BUFFER)
		then
			despawnProjectile(id)
			continue
		end

		-- 5. Commit new position
		proj.position = targetPos
		if proj.instance and proj.instance.Parent then
			proj.instance.Position = targetPos
		end
	end
end

--[[
	Registers a callback invoked whenever an authoritative projectile hits a target.
]]
function ProjectileService.RegisterHitCallback(callback: HitCallback)
	table.insert(hitCallbacks, callback)
end

--[[
	Returns total active projectiles currently tracked.
]]
function ProjectileService.GetActiveProjectileCount(): number
	return #projectileOrder
end

--[[
	Returns dictionary of active projectiles (read-only snapshot).
]]
function ProjectileService.GetActiveProjectiles(): { [number]: Projectile }
	return activeProjectiles
end

--[[
	Sets the maximum active projectile limit.
]]
function ProjectileService.SetMaxActiveProjectiles(limit: number)
	if limit > 0 then
		maxActiveProjectiles = limit
		enforceActiveLimit()
	end
end

--[[
	Returns the current max active projectile limit.
]]
function ProjectileService.GetMaxActiveProjectiles(): number
	return maxActiveProjectiles
end

--[[
	Initializes ProjectileService and connects simulation loop. Idempotent.
]]
function ProjectileService.Initialize()
	if isInitialized then
		return
	end
	isInitialized = true

	getProjectilesFolder()

	heartbeatConn = RunService.Heartbeat:Connect(function(dt: number)
		ProjectileService.StepSimulation(dt)
	end)

	print("[ProjectileService] Server projectile simulation service initialized.")
end

--[[
	Returns true if ProjectileService is currently initialized.
]]
function ProjectileService.IsInitialized(): boolean
	return isInitialized
end

--[[
	Cleans up all active projectiles, disconnects loop, and clears callbacks.
]]
function ProjectileService._Teardown()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end

	for id, _ in pairs(activeProjectiles) do
		despawnProjectile(id)
	end

	activeProjectiles = {}
	projectileOrder = {}
	hitCallbacks = {}
	isInitialized = false
	nextProjectileId = 1
	maxActiveProjectiles = 250

	local folder = Workspace:FindFirstChild("Projectiles")
	if folder then
		folder:ClearAllChildren()
	end
end

return ProjectileService
