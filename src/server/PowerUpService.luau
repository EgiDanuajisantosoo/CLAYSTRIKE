--!strict
--[[
	PowerUpService.luau
	Authoritative server manager for collectible power-ups, proximity pickups, and temporary combat buffs.
	Task: CLAY-014 (Power-Up Drop & Pickup Rules)

	SECURITY & AUTHORITY:
	1. Complete Server Authority: Pickups and buffs are fully simulated, validated, and expired on the server.
	2. Proximity Validation: Collection requires player aircraft distance <= 6.0 studs. Remote/distant claims rejected.
	3. Atomic Collection: Pickups cannot be collected twice; racing attempts resolve deterministically.
	4. Deterministic Expiration: Buffs expire reliably based on server os.clock() and reset weapons to baseline.
	5. Boundary & Lifetime Safety: Uncollected pickups despawn cleanly without leaking instances.
]]

local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(SharedFolder:WaitForChild("GameConfig"))
local PowerUpConfig = require(SharedFolder:WaitForChild("PowerUpConfig"))

export type ActiveBuff = {
	powerUpType: PowerUpConfig.PowerUpType,
	startTime: number,
	expiresAt: number,
}

export type TrackedPickup = {
	id: string,
	powerUpType: PowerUpConfig.PowerUpType,
	model: Model,
	position: Vector3,
	spawnTime: number,
	expiresAt: number,
	isCollected: boolean,
}

export type BuffChangedCallback = (userId: number, buffType: string?, remaining: number) -> ()
export type PickupCollectedCallback = (userId: number, powerUpType: string, position: Vector3) -> ()

local PowerUpService = {}

local activePickups: { [string]: TrackedPickup } = {}
local pickupOrder: { string } = {}
local playerBuffs: { [number]: ActiveBuff } = {}
local buffCallbacks: { BuffChangedCallback } = {}
local pickupCallbacks: { PickupCollectedCallback } = {}

local isInitialized = false
local heartbeatConn: RBXScriptConnection? = nil
local playerRemovingConn: RBXScriptConnection? = nil
local nextPickupId = 1

-- Helper to retrieve or create the authoritative Pickups folder in Workspace
local function getPickupsFolder(): Folder
	local existing = Workspace:FindFirstChild("Pickups")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Pickups"
	folder.Parent = Workspace
	return folder
end

--[[
	Resolves active player aircraft models from Workspace.ActivePlanes.
]]
local function getPlayerPlanes(): { [number]: Model }
	local activePlanes = Workspace:FindFirstChild("ActivePlanes")
	if not activePlanes then
		return {}
	end

	local planes: { [number]: Model } = {}
	for _, child in ipairs(activePlanes:GetChildren()) do
		if child:IsA("Model") and child.PrimaryPart then
			local ownerId = child:GetAttribute("OwnerUserId") :: number?
			if not ownerId then
				local num = tonumber(string.match(child.Name, "%d+"))
				if num then
					ownerId = num
				end
			end
			if ownerId then
				planes[ownerId] = child
			end
		end
	end
	return planes
end

--[[
	Despawns an uncollected pickup instance and frees its tracking record.
]]
local function despawnPickup(pickupId: string)
	local pickup = activePickups[pickupId]
	if not pickup then
		return
	end

	activePickups[pickupId] = nil
	local idx = table.find(pickupOrder, pickupId)
	if idx then
		table.remove(pickupOrder, idx)
	end

	if pickup.model and pickup.model.Parent then
		pickup.model:Destroy()
	end
end

--[[
	Enforces maximum active pickups limit in the arena by despawning the oldest uncollected pickup.
]]
local function enforceActiveLimit()
	while #pickupOrder > PowerUpConfig.MAX_ACTIVE_PICKUPS do
		local oldestId = pickupOrder[1]
		if oldestId then
			despawnPickup(oldestId)
		else
			break
		end
	end
end

--[[
	Creates a stylized clay collectible pickup model in the 2.5D play plane.
]]
local function createPickupModel(id: string, def: PowerUpConfig.PowerUpDefinition, pos: Vector3): Model
	local model = Instance.new("Model")
	model.Name = string.format("Pickup_%s", id)

	local root = Instance.new("Part")
	root.Name = "RootPart"
	root.Size = Vector3.new(1.8, 1.8, 1.8)
	root.Position = pos
	root.Shape = Enum.PartType.Ball
	root.Material = Enum.Material.Neon
	root.Color = def.color
	root.Anchored = true
	root.CanCollide = false
	root.CanTouch = false
	root.CanQuery = false
	root.CastShadow = false
	root.Parent = model
	model.PrimaryPart = root

	-- Outer decorative clay shell ring
	local shell = Instance.new("Part")
	shell.Name = "ClayShell"
	shell.Size = Vector3.new(2.2, 0.4, 2.2)
	shell.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(45))
	shell.Shape = Enum.PartType.Cylinder
	shell.Material = Enum.Material.SmoothPlastic
	shell.Color = Color3.fromRGB(240, 230, 210)
	shell.Anchored = true
	shell.CanCollide = false
	shell.CanTouch = false
	shell.CanQuery = false
	shell.CastShadow = false
	shell.Parent = model

	local light = Instance.new("PointLight")
	light.Range = 8
	light.Brightness = 2.0
	light.Color = def.color
	light.Shadows = false
	light.Parent = root

	-- Authoritative metadata tags
	model:SetAttribute("PickupId", id)
	model:SetAttribute("PowerUpType", def.id)
	model:SetAttribute("SpawnTime", os.clock())
	model:SetAttribute("ExpiresAt", os.clock() + PowerUpConfig.DEFAULT_LIFETIME)
	model:SetAttribute("IsCollected", false)

	return model
end

--[[
	Spawns an authoritative pickup collectible at the specified position.
	If powerUpType is omitted, selects randomly according to drop weights.
]]
function PowerUpService.SpawnPickup(powerUpType: string?, position: Vector3): Model?
	local def = if powerUpType then PowerUpConfig.GetPowerUp(powerUpType) else PowerUpConfig.SelectRandomPowerUp()
	if not def then
		return nil
	end

	local container = getPickupsFolder()
	local pId = string.format("PU_%d", nextPickupId)
	nextPickupId += 1

	-- Clamp position strictly to 2.5D combat arena boundaries
	local arena = GameConfig.Arena
	local clampedX = math.clamp(position.X, arena.MinX + 5, arena.MaxX - 5)
	local clampedY = math.clamp(position.Y, arena.MinY + 5, arena.MaxY - 5)
	local clampedPos = Vector3.new(clampedX, clampedY, arena.PlayPlaneZ)

	local model = createPickupModel(pId, def, clampedPos)
	model.Parent = container

	local now = os.clock()
	local record: TrackedPickup = {
		id = pId,
		powerUpType = def.id,
		model = model,
		position = clampedPos,
		spawnTime = now,
		expiresAt = now + PowerUpConfig.DEFAULT_LIFETIME,
		isCollected = false,
	}

	activePickups[pId] = record
	table.insert(pickupOrder, pId)
	enforceActiveLimit()

	return model
end

--[[
	Authoritatively attempts to collect a pickup for a player.
	Enforces proximity (<= PICKUP_RADIUS), atomic once-only collection, and buff activation.
	Returns (success: boolean, errorReason: string?).
]]
function PowerUpService.CollectPickup(userId: number, pickupId: string): (boolean, string?)
	local pickup = activePickups[pickupId]
	if not pickup then
		return false, "PickupNotFound"
	end

	if pickup.isCollected then
		return false, "AlreadyCollected"
	end

	local planes = getPlayerPlanes()
	local playerPlane = planes[userId]
	if not playerPlane or not playerPlane.PrimaryPart then
		return false, "NoActiveAircraft"
	end

	local planePos = playerPlane.PrimaryPart.Position
	local dist = (Vector2.new(planePos.X, planePos.Y) - Vector2.new(pickup.position.X, pickup.position.Y)).Magnitude

	if dist > PowerUpConfig.PICKUP_RADIUS then
		return false, "OutOfRange"
	end

	-- Atomic collection commit
	pickup.isCollected = true
	if pickup.model and pickup.model.Parent then
		pickup.model:SetAttribute("IsCollected", true)
	end

	local def = PowerUpConfig.GetPowerUp(pickup.powerUpType)
	local duration = if def then def.duration else 8.0
	local now = os.clock()

	-- Grant temporary server-owned combat buff
	local buff: ActiveBuff = {
		powerUpType = pickup.powerUpType,
		startTime = now,
		expiresAt = now + duration,
	}
	playerBuffs[userId] = buff

	-- Replicate buff state on player aircraft attributes
	playerPlane:SetAttribute("ActiveBuff", pickup.powerUpType)
	playerPlane:SetAttribute("BuffExpiresAt", buff.expiresAt)

	-- Dispatch callbacks
	for _, cb in ipairs(pickupCallbacks) do
		task.spawn(cb, userId, pickup.powerUpType, pickup.position)
	end
	for _, cb in ipairs(buffCallbacks) do
		task.spawn(cb, userId, pickup.powerUpType, duration)
	end

	-- Despawn pickup instance cleanly
	despawnPickup(pickupId)

	print(string.format("[PowerUpService] Player %d collected '%s' power-up (Duration: %.1fs).", userId, pickup.powerUpType, duration))
	return true, nil
end

--[[
	Returns the currently active buff and remaining duration for a player.
]]
function PowerUpService.GetActiveBuff(userId: number): (PowerUpConfig.PowerUpType?, number?)
	local buff = playerBuffs[userId]
	if not buff then
		return nil, nil
	end

	local now = os.clock()
	if now >= buff.expiresAt then
		-- Expired: clean up record
		playerBuffs[userId] = nil
		local planes = getPlayerPlanes()
		local plane = planes[userId]
		if plane then
			plane:SetAttribute("ActiveBuff", nil)
			plane:SetAttribute("BuffExpiresAt", 0)
		end
		for _, cb in ipairs(buffCallbacks) do
			task.spawn(cb, userId, nil, 0)
		end
		return nil, nil
	end

	return buff.powerUpType, buff.expiresAt - now
end

--[[
	Calculates the effective cooldown for a player factoring in active power-up buffs.
]]
function PowerUpService.GetEffectiveCooldown(userId: number, baseCooldown: number): number
	local activeType, _ = PowerUpService.GetActiveBuff(userId)
	if not activeType then
		return baseCooldown
	end

	local def = PowerUpConfig.GetPowerUp(activeType)
	if def and def.cooldownMultiplier then
		return baseCooldown * def.cooldownMultiplier
	end

	return baseCooldown
end

--[[
	Calculates the effective damage for a projectile factoring in active power-up buffs.
]]
function PowerUpService.GetEffectiveDamage(userId: number, baseDamage: number): number
	local activeType, _ = PowerUpService.GetActiveBuff(userId)
	if not activeType then
		return baseDamage
	end

	local def = PowerUpConfig.GetPowerUp(activeType)
	if def and def.damageAdditive then
		return baseDamage + def.damageAdditive
	end

	return baseDamage
end

--[[
	Clears any active buff for a player (e.g. upon death or disconnect) and reverts weapon to baseline.
]]
function PowerUpService.ClearPlayerBuff(userId: number)
	if playerBuffs[userId] then
		playerBuffs[userId] = nil
		local planes = getPlayerPlanes()
		local plane = planes[userId]
		if plane then
			plane:SetAttribute("ActiveBuff", nil)
			plane:SetAttribute("BuffExpiresAt", 0)
		end
		for _, cb in ipairs(buffCallbacks) do
			task.spawn(cb, userId, nil, 0)
		end
	end
end

--[[
	Steps the simulation of pickups and active buffs.
	Checks proximity collection for all active planes, culls expired pickups, and expires buffs.
]]
function PowerUpService.StepSimulation()
	local now = os.clock()
	local planes = getPlayerPlanes()

	-- 1. Check proximity collection against active planes
	local pickupIds = table.clone(pickupOrder)
	for _, pId in ipairs(pickupIds) do
		local pickup = activePickups[pId]
		if not pickup or pickup.isCollected then
			continue
		end

		-- Check if pickup has expired uncollected
		if now >= pickup.expiresAt then
			despawnPickup(pId)
			continue
		end

		-- Check proximity against every active plane
		for userId, plane in pairs(planes) do
			if plane.PrimaryPart then
				local planePos = plane.PrimaryPart.Position
				local dist = (Vector2.new(planePos.X, planePos.Y) - Vector2.new(pickup.position.X, pickup.position.Y)).Magnitude
				if dist <= PowerUpConfig.PICKUP_RADIUS then
					PowerUpService.CollectPickup(userId, pId)
					break
				end
			end
		end
	end

	-- 2. Check and expire active buffs
	local userIdsWithBuffs = {}
	for uId in pairs(playerBuffs) do
		table.insert(userIdsWithBuffs, uId)
	end

	for _, uId in ipairs(userIdsWithBuffs) do
		local buff = playerBuffs[uId]
		if buff and now >= buff.expiresAt then
			playerBuffs[uId] = nil
			local plane = planes[uId]
			if plane then
				plane:SetAttribute("ActiveBuff", nil)
				plane:SetAttribute("BuffExpiresAt", 0)
			end
			for _, cb in ipairs(buffCallbacks) do
				task.spawn(cb, uId, nil, 0)
			end
			print(string.format("[PowerUpService] Buff '%s' expired for player %d. Weapon returned to baseline.", buff.powerUpType, uId))
		end
	end
end

--[[
	Registers a callback when a powerup is collected.
]]
function PowerUpService.OnPickupCollected(callback: PickupCollectedCallback): () -> ()
	table.insert(pickupCallbacks, callback)
	return function()
		local idx = table.find(pickupCallbacks, callback)
		if idx then
			table.remove(pickupCallbacks, idx)
		end
	end
end

--[[
	Registers a callback when a player's buff state changes (activation, expiration, or clear).
]]
function PowerUpService.OnBuffChanged(callback: BuffChangedCallback): () -> ()
	table.insert(buffCallbacks, callback)
	return function()
		local idx = table.find(buffCallbacks, callback)
		if idx then
			table.remove(buffCallbacks, idx)
		end
	end
end

--[[
	Returns total uncollected pickups currently active in the arena.
]]
function PowerUpService.GetActivePickupCount(): number
	return #pickupOrder
end

--[[
	Initializes PowerUpService, connects Heartbeat loop and player lifecycle hooks. Idempotent.
]]
function PowerUpService.Initialize()
	if isInitialized then
		return
	end
	isInitialized = true

	getPickupsFolder()

	heartbeatConn = RunService.Heartbeat:Connect(function()
		PowerUpService.StepSimulation()
	end)

	playerRemovingConn = Players.PlayerRemoving:Connect(function(player: Player)
		PowerUpService.ClearPlayerBuff(player.UserId)
	end)

	print("[PowerUpService] Authoritative power-up and collectible service initialized.")
end

--[[
	Returns true if PowerUpService is initialized.
]]
function PowerUpService.IsInitialized(): boolean
	return isInitialized
end

--[[
	Tears down PowerUpService, cleans connections, active pickups, and buffs.
]]
function PowerUpService._Teardown()
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	if playerRemovingConn then
		playerRemovingConn:Disconnect()
		playerRemovingConn = nil
	end

	for id in pairs(activePickups) do
		despawnPickup(id)
	end

	activePickups = {}
	pickupOrder = {}
	playerBuffs = {}
	buffCallbacks = {}
	pickupCallbacks = {}
	isInitialized = false
	nextPickupId = 1

	local folder = Workspace:FindFirstChild("Pickups")
	if folder then
		folder:ClearAllChildren()
	end
end

return PowerUpService
