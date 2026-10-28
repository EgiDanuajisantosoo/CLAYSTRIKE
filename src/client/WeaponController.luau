--!strict
--[[
	WeaponController.luau
	Client weapon input controller and cosmetic presentation manager for CLAYSTRIKE.
	Task: CLAY-010 (Standard Weapon Firing Loop)

	Binds firing input (Spacebar / LMB / Gamepad R2), manages firing cadence,
	transmits validated fire intents to the server at configured weapon cooldown,
	and renders responsive local visual feedback upon server shot replication.
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

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

local RemoteContracts = require(SharedFolder:WaitForChild("RemoteContracts"))

local WeaponController = {}

local fireWeaponRemote: RemoteEvent? = nil
local connections: { RBXScriptConnection } = {}
local isInitialized = false
local isEnabled = true
local isFireHeld = false
local isWindowFocused = true
local activeWeaponId = WeaponConfig.DEFAULT_WEAPON_ID

local lastLocalFireTime = 0
local localShotCount = 0
local serverConfirmCount = 0

-- Mock state for deterministic unit testing
local mockFireHeld: boolean? = nil
local mockWindowFocus: boolean? = nil
local mockTextBoxFocus: boolean? = nil

--[[
	Renders a local cosmetic muzzle flash effect at the aircraft's muzzle.
	Strictly non-authoritative presentation adhering to StyleGuide VFX constraints (duration <= 0.08s).
	For SpreadShot, produces a distinct 3-point fan burst.
]]
local function playCosmeticMuzzleFlash(origin: Vector3, color: Color3, weaponId: string?)
	local vfxMod = SharedFolder:FindFirstChild("VFXConfig")
	if vfxMod then
		local ok, VFXConfig = pcall(require, vfxMod)
		if ok and VFXConfig and VFXConfig.CreateMuzzleFlash then
			VFXConfig.CreateMuzzleFlash(origin, weaponId or "StandardPeaShooter", Workspace)
			return
		end
	end

	local isSpread = (weaponId == "SpreadShot")
	local flashPart = Instance.new("Part")
	flashPart.Name = "CosmeticMuzzleFlash"
	flashPart.Size = if isSpread then Vector3.new(1.2, 1.2, 1.2) else Vector3.new(0.8, 0.8, 0.8)
	flashPart.Position = origin
	flashPart.Shape = Enum.PartType.Ball
	flashPart.Material = Enum.Material.Neon
	flashPart.Color = color
	flashPart.Anchored = true
	flashPart.CanCollide = false
	flashPart.CanTouch = false
	flashPart.CanQuery = false
	flashPart.CastShadow = false
	flashPart.Parent = Workspace

	local light = Instance.new("PointLight")
	light.Range = if isSpread then 12 else 8
	light.Brightness = if isSpread then 3.2 else 2.5
	light.Color = color
	light.Shadows = false
	light.Parent = flashPart

	-- For spread shot, spawn two smaller flanking spark bursts at +/- 15 degrees
	local sideSparks: { Part } = {}
	if isSpread then
		for _, angleDeg in ipairs({ -15, 15 }) do
			local rad = math.rad(angleDeg)
			local spark = Instance.new("Part")
			spark.Name = "SpreadCosmeticSpark"
			spark.Size = Vector3.new(0.4, 0.4, 0.4)
			spark.Shape = Enum.PartType.Ball
			spark.Material = Enum.Material.Neon
			spark.Color = color
			spark.Anchored = true
			spark.CanCollide = false
			spark.CanTouch = false
			spark.CanQuery = false
			spark.CastShadow = false

			local offset = Vector3.new(math.cos(rad) * 0.8, math.sin(rad) * 0.8, 0)
			spark.Position = origin + offset
			spark.Parent = Workspace
			table.insert(sideSparks, spark)
		end
	end

	-- Fast fade out within StyleGuide limit (0.06s)
	task.delay(0.06, function()
		if flashPart.Parent then
			flashPart:Destroy()
		end
		for _, spark in ipairs(sideSparks) do
			if spark.Parent then
				spark:Destroy()
			end
		end
	end)
end

--[[
	Transmits a fire request to the server if the local cadence gate has elapsed.
]]
local function attemptFire(now: number)
	if not fireWeaponRemote then
		return
	end

	local weaponDef = WeaponConfig.GetWeapon(activeWeaponId) or WeaponConfig.GetDefaultWeapon()
	if now - lastLocalFireTime < weaponDef.cooldown then
		return
	end

	lastLocalFireTime = now
	localShotCount += 1

	local payload = {
		contractVersion = GameConfig.CONTRACT_VERSION,
		clientTimestamp = now,
		weaponId = weaponDef.id,
		aimDirection = Vector2.new(1, 0), -- Forward aim along +X
	}

	fireWeaponRemote:FireServer(payload)
end

--[[
	Heartbeat tick loop: samples firing state and enforces cadence.
]]
local function onHeartbeat()
	if not isEnabled then
		return
	end

	-- Focus checks
	local focused = if mockWindowFocus ~= nil then mockWindowFocus else isWindowFocused
	if not focused then
		isFireHeld = false
		return
	end

	local typing = if mockTextBoxFocus ~= nil
		then mockTextBoxFocus
		else (UserInputService:GetFocusedTextBox() ~= nil)
	if typing then
		isFireHeld = false
		return
	end

	local firing = if mockFireHeld ~= nil then mockFireHeld else isFireHeld
	if firing then
		attemptFire(os.clock())
	end
end

--[[
	Checks if a given UserInput represents a fire action.
]]
local function isFireInput(input: InputObject): boolean
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		return true
	end
	if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.Return then
		return true
	end
	if input.KeyCode == Enum.KeyCode.ButtonR2 then
		return true
	end
	return false
end

--[[
	Initializes WeaponController, binds input listeners and RemoteEvent response. Idempotent.
]]
function WeaponController.Initialize()
	if isInitialized then
		warn("[WeaponController] Initialize() already called; skipping duplicate setup.")
		return
	end

	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
	local remoteInstance = remotesFolder:WaitForChild(RemoteContracts.RemoteNames.FireWeapon, 5)
	if not remoteInstance or not remoteInstance:IsA("RemoteEvent") then
		error("[WeaponController] Failed to resolve FireWeapon RemoteEvent.")
	end

	fireWeaponRemote = remoteInstance :: RemoteEvent
	isInitialized = true
	isEnabled = true
	isFireHeld = false

	-- 1. Bind Heartbeat loop for continuous firing cadence
	local hbConn = RunService.Heartbeat:Connect(onHeartbeat)
	table.insert(connections, hbConn)

	-- 2. Input began
	local inputBeganConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if isFireInput(input) then
			isFireHeld = true
		elseif input.KeyCode == Enum.KeyCode.One then
			WeaponController.SetActiveWeapon("StandardPeaShooter")
		elseif input.KeyCode == Enum.KeyCode.Two then
			WeaponController.SetActiveWeapon("SpreadShot")
		elseif input.KeyCode == Enum.KeyCode.Q or input.KeyCode == Enum.KeyCode.E then
			WeaponController.CycleWeapon()
		end
	end)
	table.insert(connections, inputBeganConn)

	-- 3. Input ended
	local inputEndedConn = UserInputService.InputEnded:Connect(function(input: InputObject)
		if isFireInput(input) then
			isFireHeld = false
		end
	end)
	table.insert(connections, inputEndedConn)

	-- 4. Window focus loss safety (Alt-Tab protection)
	local focusLostConn = UserInputService.WindowFocusReleased:Connect(function()
		isWindowFocused = false
		isFireHeld = false
	end)
	table.insert(connections, focusLostConn)

	-- 5. Window focus restored
	local focusGainedConn = UserInputService.WindowFocused:Connect(function()
		isWindowFocused = true
	end)
	table.insert(connections, focusGainedConn)

	-- 6. UI TextBox focus safety (typing into chat)
	local tbFocusConn = UserInputService.TextBoxFocused:Connect(function()
		isFireHeld = false
	end)
	table.insert(connections, tbFocusConn)

	-- 7. Server shot replication listener for cosmetic muzzle flashes
	local remoteConn = fireWeaponRemote.OnClientEvent:Connect(function(data: any)
		if type(data) == "table" and data.origin then
			serverConfirmCount += 1
			local weaponDef = WeaponConfig.GetWeapon(data.weaponId or activeWeaponId) or WeaponConfig.GetDefaultWeapon()
			playCosmeticMuzzleFlash(data.origin, weaponDef.bulletColor, weaponDef.id)
		end
	end)
	table.insert(connections, remoteConn)

	print("[WeaponController] Standard weapon controller initialized with firing loop and cosmetic feedback.")
end

--[[
	Returns true if WeaponController is currently initialized.
]]
function WeaponController.IsInitialized(): boolean
	return isInitialized
end

--[[
	Returns true if fire is currently held down.
]]
function WeaponController.IsFiring(): boolean
	if mockFireHeld ~= nil then
		return mockFireHeld
	end
	return isFireHeld
end

--[[
	Starts firing intent programmatically.
]]
function WeaponController.StartFiring()
	isFireHeld = true
end

--[[
	Stops firing intent programmatically.
]]
function WeaponController.StopFiring()
	isFireHeld = false
end

--[[
	Sets the active weapon ID.
]]
function WeaponController.SetActiveWeapon(weaponId: string)
	if WeaponConfig.GetWeapon(weaponId) then
		activeWeaponId = weaponId
	end
end

--[[
	Cycles between available player weapons (StandardPeaShooter <-> SpreadShot).
	Returns the newly activated weapon ID.
]]
function WeaponController.CycleWeapon(): string
	if activeWeaponId == "StandardPeaShooter" then
		activeWeaponId = "SpreadShot"
	else
		activeWeaponId = "StandardPeaShooter"
	end
	return activeWeaponId
end

--[[
	Returns the active weapon ID.
]]
function WeaponController.GetActiveWeapon(): string
	return activeWeaponId
end

--[[
	Returns true if the window currently has focus.
]]
function WeaponController.IsWindowFocused(): boolean
	if mockWindowFocus ~= nil then
		return mockWindowFocus
	end
	return isWindowFocused
end

--[[
	Returns the count of local fire requests attempted.
]]
function WeaponController.GetLocalShotCount(): number
	return localShotCount
end

--[[
	Returns the count of server confirmed shots received.
]]
function WeaponController.GetServerConfirmCount(): number
	return serverConfirmCount
end

--[[
	Simulates a single frame/cadence step for headless unit testing.
]]
function WeaponController.StepFiring(virtualTime: number)
	if not isEnabled then
		return
	end

	local focused = if mockWindowFocus ~= nil then mockWindowFocus else isWindowFocused
	if not focused then
		isFireHeld = false
		return
	end

	local typing = if mockTextBoxFocus ~= nil
		then mockTextBoxFocus
		else (UserInputService:GetFocusedTextBox() ~= nil)
	if typing then
		isFireHeld = false
		return
	end

	local firing = if mockFireHeld ~= nil then mockFireHeld else isFireHeld
	if firing then
		attemptFire(virtualTime)
	end
end

--[[
	Test helper to simulate fire held state.
]]
function WeaponController._SimulateFireHeld(held: boolean)
	mockFireHeld = held
end

--[[
	Test helper to simulate window focus.
]]
function WeaponController._SimulateWindowFocus(focused: boolean?)
	mockWindowFocus = focused
	if focused ~= nil then
		isWindowFocused = focused
		if not focused then
			isFireHeld = false
		end
	end
end

--[[
	Test helper to simulate text entry focus.
]]
function WeaponController._SimulateTextBoxFocus(focused: boolean)
	mockTextBoxFocus = focused
	if focused then
		isFireHeld = false
	end
end

--[[
	Test helper to inspect total active connection count.
]]
function WeaponController._GetConnectionCount(): number
	return #connections
end

--[[
	Cleans up all connections and resets controller state.
]]
function WeaponController._Teardown()
	for _, conn in ipairs(connections) do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	connections = {}
	isInitialized = false
	isEnabled = true
	isFireHeld = false
	isWindowFocused = true
	mockFireHeld = nil
	mockWindowFocus = nil
	mockTextBoxFocus = nil
	fireWeaponRemote = nil
	lastLocalFireTime = 0
	localShotCount = 0
	serverConfirmCount = 0
	activeWeaponId = WeaponConfig.DEFAULT_WEAPON_ID
end

return WeaponController
