--!strict
--[[
	EnemyService.luau
	Authoritative server lifecycle manager for spawning, tracking, and cleaning up enemies.
	Task: CLAY-016 (Enemy Spawn Factory & Cleanup)

	RESPONSIBILITIES:
	- Authoritative spawning of enemies from EnemyConfig definitions.
	- Strict registration of spawned enemies in Workspace.ActiveEnemies.
	- Real-time tracking of active enemy records (health, archetype, position, lifecycle).
	- Deterministic cleanup and despawning on defeat, arena exit, or wave reset.
	- Zero orphaned instances or memory leaks.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"))
if (EnemyConfig :: any).Archetypes == nil then
	EnemyConfig = require(SharedFolder:WaitForChild("EnemyConfig"):Clone())
end

local EnemyFactory = require(script.Parent:WaitForChild("EnemyFactory"))
local ProjectileService = require(script.Parent:WaitForChild("ProjectileService"))

export type ActiveEnemy = {
	id: string,
	archetypeId: string,
	model: Model,
	primaryPart: BasePart,
	currentHealth: number,
	maxHealth: number,
	scoreValue: number,
	spawnTime: number,
	spawnPosition: Vector3,
	isAlive: boolean,
	definition: EnemyConfig.EnemyDefinition,
	attackCooldown: number,
	isTelegraphing: boolean,
	targetUserId: number?,
	heading: Vector2?,
}

export type DefeatCallback = (record: ActiveEnemy, attackerPlayer: Player?) -> ()
export type DamageCallback = (record: ActiveEnemy, damage: number, attackerPlayer: Player?) -> ()

local EnemyService = {}

local activeEnemies: { [string]: ActiveEnemy } = {}
local isInitialized = false
local spawnCounter = 0
local activeFolder: Folder? = nil
local heartbeatConnection: RBXScriptConnection? = nil
local defeatCallbacks: { DefeatCallback } = {}
local damageCallbacks: { DamageCallback } = {}
local hitHookCleanup: (() -> ())? = nil

-- Helper to retrieve or create the authoritative ActiveEnemies container in Workspace
local function getActiveEnemiesFolder(): Folder
	local existingActive = Workspace:FindFirstChild("ActiveEnemies")
	if existingActive and existingActive:IsA("Folder") then
		activeFolder = existingActive
		return existingActive
	end

	local existingEnemies = Workspace:FindFirstChild("Enemies")
	if existingEnemies and existingEnemies:IsA("Folder") then
		activeFolder = existingEnemies
		return existingEnemies
	end

	local folder = Instance.new("Folder")
	folder.Name = "ActiveEnemies"
	folder.Parent = Workspace
	activeFolder = folder
	return folder
end

--[[
	Spawns an authoritative enemy of the specified archetype at spawnPosition.
	Returns (model, errorMessage).
]]
function EnemyService.SpawnEnemy(archetypeId: string, spawnPosition: Vector3): (Model?, string?)
	local def = EnemyConfig.GetEnemy(archetypeId)
	if not def then
		return nil, string.format("Unknown archetype ID: '%s'", tostring(archetypeId))
	end

	local container = getActiveEnemiesFolder()
	spawnCounter += 1
	local enemyId = string.format("Enemy_%s_%d", archetypeId, spawnCounter)

	-- 1. Create model via EnemyFactory
	local model = EnemyFactory.CreateEnemyModel(def)
	model.Name = enemyId

	local primary = model.PrimaryPart
	if not primary then
		model:Destroy()
		return nil, "Enemy model lacks a PrimaryPart"
	end

	-- 2. Position model
	model:PivotTo(CFrame.new(spawnPosition))

	-- 3. Set authoritative attributes
	model:SetAttribute("EnemyId", enemyId)
	model:SetAttribute("ArchetypeId", archetypeId)
	model:SetAttribute("MaxHealth", def.maxHealth)
	model:SetAttribute("CurrentHealth", def.maxHealth)
	model:SetAttribute("ScoreValue", def.scoreValue)
	model:SetAttribute("SpawnTime", os.clock())
	model:SetAttribute("IsAlive", true)
	model:SetAttribute("MovementType", def.movementType)
	model:SetAttribute("Speed", def.speed)
	model:SetAttribute("IsTelegraphing", false)
	model:SetAttribute("TargetUserId", 0)

	-- Parent into authoritative container
	model.Parent = container

	local initCooldown = if def.firingPattern and def.firingPattern.canShoot then def.firingPattern.fireRate else 0

	-- 4. Register active record
	local record: ActiveEnemy = {
		id = enemyId,
		archetypeId = archetypeId,
		model = model,
		primaryPart = primary,
		currentHealth = def.maxHealth,
		maxHealth = def.maxHealth,
		scoreValue = def.scoreValue,
		spawnTime = os.clock(),
		spawnPosition = spawnPosition,
		isAlive = true,
		definition = def,
		attackCooldown = initCooldown,
		isTelegraphing = false,
		targetUserId = nil,
		heading = Vector2.new(-1, 0),
	}

	activeEnemies[enemyId] = record
	return model, nil
end

--[[
	Despawns a single active enemy by ID, cleaning up its model and tracking state.
	Returns true if enemy was found and despawned.
]]
function EnemyService.DespawnEnemy(enemyId: string): boolean
	local record = activeEnemies[enemyId]
	if not record then
		return false
	end

	record.isAlive = false
	activeEnemies[enemyId] = nil

	if record.model and record.model.Parent then
		record.model:Destroy()
	end

	return true
end

--[[
	Returns the ActiveEnemy record for the given ID, or nil if not active.
]]
function EnemyService.GetActiveEnemy(enemyId: string): ActiveEnemy?
	return activeEnemies[enemyId]
end

--[[
	Returns total active enemies currently registered.
]]
function EnemyService.GetActiveEnemyCount(): number
	local count = 0
	for _, _ in pairs(activeEnemies) do
		count += 1
	end
	return count
end

--[[
	Returns a copy of the dictionary of all active enemies.
]]
function EnemyService.GetAllActiveEnemies(): { [string]: ActiveEnemy }
	local copy: { [string]: ActiveEnemy } = {}
	for id, record in pairs(activeEnemies) do
		copy[id] = record
	end
	return copy
end

--[[
	Cleans up all active enemies in the arena (used on wave completion or mission reset).
	Returns count of enemies cleaned up.
]]
function EnemyService.CleanupAll(): number
	local count = 0
	for id, _ in pairs(activeEnemies) do
		EnemyService.DespawnEnemy(id)
		count += 1
	end

	local container = getActiveEnemiesFolder()
	container:ClearAllChildren()

	return count
end

-- Helper to locate the nearest valid, living active player aircraft in 2.5D space
local function findNearestLivingPlayerPlane(fromPos: Vector3): (Vector3?, number?, Model?)
	local activePlanesFolder = Workspace:FindFirstChild("ActivePlanes")
	if not activePlanesFolder then
		return nil, nil, nil
	end

	local servicesFolder = if script.Parent then script.Parent else game:GetService("ServerScriptService"):FindFirstChild("Services")
	local sessionService = nil
	if servicesFolder then
		local sMod = servicesFolder:FindFirstChild("SessionService")
		if sMod then
			pcall(function()
				sessionService = require(sMod)
			end)
		end
	end

	local targetPos: Vector3? = nil
	local targetUserId: number? = nil
	local targetModel: Model? = nil
	local shortestDistSq = math.huge

	for _, plane in ipairs(activePlanesFolder:GetChildren()) do
		if plane:IsA("Model") and plane.PrimaryPart and plane:IsDescendantOf(Workspace) then
			local health = plane:GetAttribute("Health") :: number?
			if health == nil or health > 0 then
				local ownerId = plane:GetAttribute("OwnerUserId") :: number?
				if not ownerId then
					local numStr = string.match(plane.Name, "Plane_(%d+)")
					if numStr then
						ownerId = tonumber(numStr)
					end
				end

				local planeState = plane:GetAttribute("State") :: string?
				local isPlayerValid = (planeState == nil or planeState == "Active")

				if isPlayerValid and sessionService and ownerId and sessionService.IsInitialized and sessionService.IsInitialized() then
					local pState = sessionService.GetPlayerState(ownerId)
					if pState and pState ~= "Active" then
						isPlayerValid = false
					end
				end

				if isPlayerValid then
					local pPos = plane.PrimaryPart.Position
					local dSq = (pPos.X - fromPos.X) * (pPos.X - fromPos.X) + (pPos.Y - fromPos.Y) * (pPos.Y - fromPos.Y)
					if dSq < shortestDistSq then
						shortestDistSq = dSq
						targetPos = pPos
						targetUserId = ownerId
						targetModel = plane
					end
				end
			end
		end
	end

	return targetPos, targetUserId, targetModel
end

--[[
	Authoritative enemy motion and lifecycle simulation step.
	Advances straight flyers and archetypes according to speed and arena constraints.
	Despawns enemies that leave the combat region.
]]
function EnemyService.StepEnemySimulation(dt: number)
	if dt <= 0 then
		return
	end

	local arena = GameConfig.Arena
	local cullMinX = arena.MinX - 15
	local cullMaxX = arena.MaxX + 25
	local cullMinY = arena.MinY - 20
	local cullMaxY = arena.MaxY + 20

	local toDespawn: { string } = {}

	for id, record in pairs(activeEnemies) do
		if not record.isAlive or not record.model.Parent or not record.primaryPart then
			table.insert(toDespawn, id)
			continue
		end

		local def = record.definition
		local currentPos = record.primaryPart.Position

		if def.movementType == "Straight" then
			local newX = currentPos.X - (def.speed * dt)
			local elapsed = os.clock() - record.spawnTime
			local newY = record.spawnPosition.Y
			local vSpeed = (def :: any).verticalSpeed or 0
			if vSpeed > 0 then
				newY = record.spawnPosition.Y + math.sin(elapsed * 2.0) * (vSpeed * 0.25)
			end
			local newZ = arena.PlayPlaneZ

			-- Check culling boundary (crossed left edge of arena or far out of bounds)
			if newX < cullMinX or newX > cullMaxX or newY < cullMinY or newY > cullMaxY then
				table.insert(toDespawn, id)
			else
				record.model:PivotTo(CFrame.new(Vector3.new(newX, newY, newZ)))
			end

		elseif def.movementType == "Pursuit" then
			-- Query living active player target
			local targetPos, targetUserId = findNearestLivingPlayerPlane(currentPos)
			record.targetUserId = targetUserId
			record.model:SetAttribute("TargetUserId", targetUserId or 0)

			local currentHeading = record.heading or Vector2.new(-1, 0)
			local desiredDir = currentHeading

			if targetPos then
				local toTarget = Vector2.new(targetPos.X - currentPos.X, targetPos.Y - currentPos.Y)
				if toTarget.Magnitude > 0.05 then
					desiredDir = toTarget.Unit
				end
			end

			-- Bounded turn rate (80 degrees / ~1.4 rad per sec)
			local MAX_TURN_RATE = math.rad(80)
			local currentAngle = math.atan2(currentHeading.Y, currentHeading.X)
			local desiredAngle = math.atan2(desiredDir.Y, desiredDir.X)

			local angleDiff = (desiredAngle - currentAngle)
			angleDiff = (angleDiff + math.pi) % (2 * math.pi) - math.pi

			local maxTurnThisStep = MAX_TURN_RATE * dt
			local clampedTurn = math.clamp(angleDiff, -maxTurnThisStep, maxTurnThisStep)
			local newAngle = currentAngle + clampedTurn
			local newHeading = Vector2.new(math.cos(newAngle), math.sin(newAngle))
			record.heading = newHeading

			local speed = def.speed
			local stepVelX = newHeading.X * speed
			local stepVelY = newHeading.Y * speed

			local maxV = (def :: any).verticalSpeed or 10
			stepVelY = math.clamp(stepVelY, -maxV, maxV)

			local newX = currentPos.X + (stepVelX * dt)
			local newY = currentPos.Y + (stepVelY * dt)
			local newZ = arena.PlayPlaneZ -- Strict 2.5D constraint!

			-- Check culling boundary
			if newX < cullMinX or newX > cullMaxX or newY < cullMinY or newY > cullMaxY then
				table.insert(toDespawn, id)
			else
				-- Tilt model slightly along flight path (forward in 2.5D is -X)
				local pitch = newAngle - math.pi
				pitch = (pitch + math.pi) % (2 * math.pi) - math.pi
				pitch = math.clamp(pitch, -math.rad(45), math.rad(45))
				record.model:PivotTo(CFrame.new(Vector3.new(newX, newY, newZ)) * CFrame.Angles(0, 0, pitch))
			end

			record.model:SetAttribute("HeadingX", newHeading.X)
			record.model:SetAttribute("HeadingY", newHeading.Y)

		elseif def.movementType == "DriftAndShoot" then
			local elapsed = os.clock() - record.spawnTime
			local anchorX = arena.MaxX - 25 -- Holds position at the right side of the arena

			local newX = currentPos.X
			if currentPos.X > anchorX then
				newX = math.max(anchorX, currentPos.X - (def.speed * dt))
			end

			local vSpeed = (def :: any).verticalSpeed or 4
			local newY = record.spawnPosition.Y + math.sin(elapsed * 1.5) * (vSpeed * 0.8)
			newY = math.clamp(newY, arena.MinY + 5, arena.MaxY - 5)
			local newZ = arena.PlayPlaneZ

			-- Check culling boundary
			if newX < cullMinX or newX > cullMaxX or newY < cullMinY or newY > cullMaxY then
				table.insert(toDespawn, id)
			else
				record.model:PivotTo(CFrame.new(Vector3.new(newX, newY, newZ)))
			end

			-- Target Selection: query living player aircraft via unified helper
			local targetPos, targetUserId = findNearestLivingPlayerPlane(Vector3.new(newX, newY, newZ))

			if targetPos and targetUserId then
				record.targetUserId = targetUserId
				record.model:SetAttribute("TargetUserId", targetUserId)
				record.model:SetAttribute("TelegraphTargetX", targetPos.X)
				record.model:SetAttribute("TelegraphTargetY", targetPos.Y)

				if def.firingPattern and def.firingPattern.canShoot then
					record.attackCooldown -= dt

					-- Telegraph window (0.5s before firing)
					local TELEGRAPH_WINDOW = 0.5
					if record.attackCooldown <= TELEGRAPH_WINDOW and not record.isTelegraphing then
						record.isTelegraphing = true
						record.model:SetAttribute("IsTelegraphing", true)
					end

					-- Cadence expiration: fire aimed projectile
					if record.attackCooldown <= 0 then
						local diff = Vector2.new(targetPos.X - newX, targetPos.Y - newY)
						local aimDir = if diff.Magnitude > 0.001 then diff.Unit else Vector2.new(-1, 0)

						local enemyWeaponDef = {
							id = "TurretBlaster",
							name = "Turret Blaster",
							weaponType = "Standard",
							baseDamage = def.firingPattern.projectileDamage,
							fireRate = def.firingPattern.fireRate,
							projectileSpeed = def.firingPattern.projectileSpeed,
							projectileRadius = 0.8,
							lifetime = 6.0,
							cooldown = def.firingPattern.fireRate,
							bulletColor = def.firingPattern.projectileColor,
						}

						ProjectileService.SpawnProjectile(0, Vector3.new(newX, newY, newZ), aimDir, enemyWeaponDef :: any, "Enemy")

						record.attackCooldown = def.firingPattern.fireRate
						record.isTelegraphing = false
						record.model:SetAttribute("IsTelegraphing", false)
					end
				end
			else
				-- No active targets: hold fire and clear telegraph
				if record.isTelegraphing then
					record.isTelegraphing = false
					record.model:SetAttribute("IsTelegraphing", false)
				end
				record.model:SetAttribute("TargetUserId", 0)
			end
		end
	end

	for _, id in ipairs(toDespawn) do
		EnemyService.DespawnEnemy(id)
	end
end

--[[
	Authoritatively applies damage to an active enemy.
	Enforces non-negative health clamping, one-time defeat transition, and idempotent callbacks.
	Returns (hitValid: boolean, wasDefeated: boolean).
]]
function EnemyService.ApplyDamage(enemyId: string, damage: number, attackerPlayer: Player?): (boolean, boolean)
	if damage <= 0 then
		return false, false
	end

	local record = activeEnemies[enemyId]
	if not record or not record.isAlive then
		return false, false
	end

	local newHealth = math.max(0, record.currentHealth - damage)
	record.currentHealth = newHealth

	if record.model and record.model.Parent then
		record.model:SetAttribute("CurrentHealth", newHealth)
	end

	if newHealth == 0 then
		-- Atomic one-time defeat transition
		record.isAlive = false
		if record.model and record.model.Parent then
			record.model:SetAttribute("IsAlive", false)
		end

		-- Notify defeat observers
		for _, callback in ipairs(defeatCallbacks) do
			task.spawn(callback, record, attackerPlayer)
		end

		-- Despawn enemy model and remove from active list
		EnemyService.DespawnEnemy(enemyId)

		return true, true
	else
		-- Notify damage observers
		for _, callback in ipairs(damageCallbacks) do
			task.spawn(callback, record, damage, attackerPlayer)
		end

		return true, false
	end
end

--[[
	Registers a listener for enemy defeat events. Returns an unsubscribe function.
]]
function EnemyService.OnEnemyDefeated(callback: DefeatCallback): () -> ()
	table.insert(defeatCallbacks, callback)
	return function()
		local idx = table.find(defeatCallbacks, callback)
		if idx then
			table.remove(defeatCallbacks, idx)
		end
	end
end

--[[
	Registers a listener for enemy damage events. Returns an unsubscribe function.
]]
function EnemyService.OnEnemyDamaged(callback: DamageCallback): () -> ()
	table.insert(damageCallbacks, callback)
	return function()
		local idx = table.find(damageCallbacks, callback)
		if idx then
			table.remove(damageCallbacks, idx)
		end
	end
end

--[[
	Binds ProjectileService hit events to EnemyService.ApplyDamage.
	Resolves enemy model hierarchy and triggers authoritative damage.
]]
function EnemyService.HookProjectileHits(projectileService: any): (() -> ())?
	if not projectileService or not projectileService.RegisterHitCallback then
		return nil
	end

	return projectileService.RegisterHitCallback(function(hitResult: any)
		if hitResult and hitResult.hitInstance and hitResult.hitInstance:IsA("BasePart") then
			if hitResult.faction == "Enemy" then
				return -- Enemy projectiles target player aircraft, not enemies
			end
			local model = hitResult.hitInstance:FindFirstAncestorOfClass("Model")
			if model then
				local enemyId = model:GetAttribute("EnemyId")
				if enemyId and typeof(enemyId) == "string" then
					EnemyService.ApplyDamage(enemyId, hitResult.damage, hitResult.attackerPlayer)
				end
			end
		end
	end)
end

--[[
	Initializes EnemyService. Idempotent.
]]
function EnemyService.Initialize()
	if isInitialized then
		return
	end
	isInitialized = true

	getActiveEnemiesFolder()

	if heartbeatConnection == nil and RunService:IsRunning() then
		heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
			EnemyService.StepEnemySimulation(dt)
		end)
	end

	local servicesFolder = if script.Parent then script.Parent else game:GetService("ServerScriptService"):FindFirstChild("Services")
	local ProjectileServiceModule = if servicesFolder then servicesFolder:FindFirstChild("ProjectileService") else nil
	if ProjectileServiceModule and hitHookCleanup == nil then
		local pService = require(ProjectileServiceModule)
		hitHookCleanup = EnemyService.HookProjectileHits(pService)
	end

	print("[EnemyService] Authoritative enemy lifecycle, health, and simulation service initialized.")
end

--[[
	Returns true if EnemyService is currently initialized.
]]
function EnemyService.IsInitialized(): boolean
	return isInitialized
end

--[[
	Cleans up all active enemies, disconnects simulation loop, resets spawn counter, and clears tracking.
]]
function EnemyService._Teardown()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end

	if hitHookCleanup then
		hitHookCleanup()
		hitHookCleanup = nil
	end

	defeatCallbacks = {}
	damageCallbacks = {}

	EnemyService.CleanupAll()
	activeEnemies = {}
	spawnCounter = 0
	isInitialized = false
end

return EnemyService

