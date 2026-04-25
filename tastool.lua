--[[
TAS Lite v0.9.0-rewrite (Roblox, LocalScript/executor)
- Stable record/playback timing
- Fixed 60 FPS record/playback timeline
- Virtual input playback (keyboard + mouse buttons)
- Freeze/seek with safe frame indexing
- Checkpoints + append recording mode
- Save/load JSON (backward compatible with v0.1/v0.2 frames)
- On-screen log + record freeze/trim indicators
- Animated loading overlay + refreshed GUI
- Settings panel toggle via `+` button
- Playback modes: ghost, frameblend, smooth
- physics is accepted as a frameblend alias

Hotkeys:
F8  - start/stop record
F10 - start/stop playback
F6  - save replay to file
F7  - load replay from file
E   - freeze/unfreeze (during record/playback)
F   - previous frame (when frozen, record/playback)
G   - next frame (when frozen, record/playback)
T/Y - hold to seek backward/forward (auto-freezes if needed)
U   - toggle status UI
F2  - force hide/show GUI
C   - set quick checkpoint (record/playback)
V   - goto quick checkpoint (record/playback)
Slash (/) - focus command bar
]]

local CONFIG = {
	ROUND_DIGITS = 4,
	TIMELINE_FPS = 60,
	DEFAULT_FRAME_DT = 1 / 60,
	VIRTUAL_INPUT_PLAYBACK = true,
	RECORD_NO_COLLISION = false, -- Keep touch/collision triggers active while recording.
	RECORD_MAX_STEPS_PER_RENDER = 12, -- cap catch-up work during lag spikes
	SEEK_SPEED = 1, -- frames per render step while holding T/Y
	PLAYBACK_SPEED = 1, -- realtime multiplier
	PLAYBACK_MAX_ACCUMULATOR = 0.35, -- seconds; drops excessive backlog to avoid slow-motion replay
	PLAYBACK_MAX_STEPS_PER_RENDER = 24, -- max simulated replay steps per render frame
	PLAYBACK_MODE = "frameblend", -- "ghost" | "frameblend" | "smooth"; "physics" aliases to frameblend.
	CAMERA_MODE = "smooth", -- "exact" | "smooth" for playback camera turns
	CAMERA_SMOOTH_RATE = 22, -- higher = snappier, lower = smoother
	FRAMEBLEND_POSITION_ALPHA = 0.6,
	FRAMEBLEND_ROTATION_ALPHA = 0.45,
	FRAMEBLEND_SNAP_DISTANCE = 10,
	FRAMEBLEND_VELOCITY_BLEND = 0.45,
	FRAMEBLEND_ANGULAR_BLEND = 0.4,
	SMOOTH_POSITION_ALPHA = 0.32,
	SMOOTH_ROTATION_ALPHA = 0.26,
	SMOOTH_VELOCITY_BLEND = 0.28,
	SMOOTH_ANGULAR_BLEND = 0.24,
	OVERLAY_MOUSE_RADIUS = 58,
	OVERLAY_MOUSE_SENSITIVITY = 420,
	OVERLAY_MOUSE_DEADZONE = 0.75,
	OVERLAY_MOUSE_TARGET_SMOOTH = 18,
	OVERLAY_MOUSE_SPRING = 145,
	OVERLAY_MOUSE_DAMPING = 14,
	OVERLAY_MOUSE_IDLE_RETURN = 0.88,
	LOG_LINES = 8,
	FOLDER = "TASLite",
	FILE_NAME = "Replay.json",
}

local TIMELINE_FPS = 60
local RECORD_MAX_STEPS_PER_RENDER = 12
local PLAYBACK_MAX_STEPS_PER_RENDER = 24
local PLAYBACK_MAX_ACCUMULATOR = 0.35
local PLAYBACK_SPEED = 1
local FRAMEBLEND_POSITION_ALPHA = 0.6
local FRAMEBLEND_ROTATION_ALPHA = 0.45
local FRAMEBLEND_SNAP_DISTANCE = 10
local FRAMEBLEND_VELOCITY_BLEND = 0.45
local FRAMEBLEND_ANGULAR_BLEND = 0.4
local CAMERA_SMOOTH_RATE = CONFIG.CAMERA_SMOOTH_RATE

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")

local RUNTIME_KEY = "TASLiteRuntime"
do
	local prev = rawget(_G, RUNTIME_KEY)
	if type(prev) == "table" and type(prev.cleanup) == "function" then
		pcall(prev.cleanup)
	end
end

local runtime = {
	connections = {},
	destroyed = false,
}
_G[RUNTIME_KEY] = runtime

local function bindConnection(conn)
	table.insert(runtime.connections, conn)
	return conn
end

local function connect(signal, fn)
	return bindConnection(signal:Connect(fn))
end

local function disconnectAllConnections()
	for i = #runtime.connections, 1, -1 do
		local conn = runtime.connections[i]
		runtime.connections[i] = nil
		if conn then
			pcall(function()
				conn:Disconnect()
			end)
		end
	end
end

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local isTouchDevice = UIS.TouchEnabled and not UIS.MouseEnabled
local startupCameraType = camera.CameraType
local startupCameraCFrame = camera.CFrame
local startupMouseBehavior = UIS.MouseBehavior
local startupShiftLockState = (UIS.MouseBehavior == Enum.MouseBehavior.LockCenter)

local mode = "idle" -- idle | record | play
local frozen = false
local seekDir = 0 -- -1 / 0 / 1
local frames = {}
local playIndex = 1
local heldKeys = {}
local uiVisible = true
local forceHideUI = false
local seekSpeed = CONFIG.SEEK_SPEED
local recordMode = "replace" -- replace | append
local checkpoints = {}
local QUICK_CP_NAME = "quick"

local playbackSpeed = PLAYBACK_SPEED
local function normalizePlaybackModeName(value)
	local name = string.lower(tostring(value or "frameblend"))
	if name == "physics" then
		return "frameblend", true
	end
	if name == "ghost" or name == "frameblend" or name == "smooth" then
		return name, false
	end
	return "frameblend", false
end

local playbackMode = normalizePlaybackModeName(CONFIG.PLAYBACK_MODE)
local cameraMode = CONFIG.CAMERA_MODE
local blendAlphaScale = 1
local playbackAccumulator = 0
local recordAccumulator = 0
local lastPlaybackClock = 0
local lastRecordClock = 0
local lastTrimmedCount = 0
local logLines = {}
local logLabel
local shiftLockState = false
local mainFrame
local timelineStep = 1 / TIMELINE_FPS
local virtualInputPlaybackEnabled = CONFIG.VIRTUAL_INPUT_PLAYBACK
local recordNoCollisionEnabled = CONFIG.RECORD_NO_COLLISION
local virtualPressed = {}
local lastRecordedShiftLockState = nil
local settingsFrame
local settingsInputsBtn
local settingsPlaybackModeBtn
local settingsRecordNoColBtn
local settingsRecordModeBtn
local settingsPlaySpeedBtn
local settingsOverlayBtn
local settingsCameraModeBtn
local inputOverlayFrame
local inputOverlayLabel
local shiftLockIndicator
local settingsToggleBtn
local adminToggleBtn
local adminPanel
local adminCommandBox
local adminStatusLabel
local adminCommandList
local adminListLayout
local adminOpen = false
local settingsOpen = false
local inputKeyCaps = {}
local mouseLeftCap
local mouseRightCap
local mouseDot
local updatePlaybackInputOverlay
local updateUI
local inputOverlayEnabled = true
local lastOverlayCamLocalCF = nil
local lastShiftIndicatorState = nil
local overlayMouseState = {
	x = 0,
	y = 0,
	vx = 0,
	vy = 0,
	tx = 0,
	ty = 0,
	lastUpdate = 0,
}
local cameraSmoothState = {
	lastUpdate = 0,
}
local lastAppliedHumanoidState = nil
local lastPhysicsJumpHeld = false
local commandHistory = {}
local commandHistoryCursor = 0
local COMMAND_HISTORY_LIMIT = 40
local adminCommands = {}
local adminAliases = {}
local adminCommandOrder = {}
local adminSavedPositions = {}
local adminPreviousPosition = nil
local runAdminCommand
local refreshAdminPanel
local populateAdminPanel
local updateAdminRuntime
local clearAdminRuntime
local adminState = {
	noclip = false,
	fly = false,
	flySpeed = 70,
	infJump = false,
	god = false,
	esp = false,
	names = false,
	fullbright = false,
	trails = false,
	xray = false,
	spin = false,
	spinSpeed = 120,
	spectating = nil,
	restore = {
		walkSpeed = nil,
		jumpPower = nil,
		jumpHeight = nil,
		hipHeight = nil,
		gravity = workspace.Gravity,
		fov = camera.FieldOfView,
		cameraSubject = camera.CameraSubject,
		cameraType = camera.CameraType,
		lighting = nil,
	},
	noclipParts = {},
	espObjects = {},
	nameObjects = {},
	trailObjects = {},
	xrayParts = {},
	floatPad = nil,
	forceField = nil,
}

local VIRTUAL_INPUT_BLACKLIST = {
	F2 = true,
	F6 = true,
	F7 = true,
	F8 = true,
	F10 = true,
	U = true,
	E = true,
	F = true,
	G = true,
	T = true,
	Y = true,
	C = true,
	V = true,
	Slash = true,
}

local playbackState = {
	active = false,
	humanoid = nil,
	hrp = nil,
	saved = nil,
}

local recordNoCollisionState = {
	active = false,
	partTouch = {},
}

local function isMouseLockCenter()
	return UIS.MouseBehavior == Enum.MouseBehavior.LockCenter
end

local function isShiftLockActive()
	return shiftLockState == true
end

local function setShiftLockState(enabled, forceApply)
	local newState = (enabled == true)
	local changed = (shiftLockState ~= newState)
	shiftLockState = newState
	if isTouchDevice then
		return
	end

	local desired = shiftLockState and Enum.MouseBehavior.LockCenter or Enum.MouseBehavior.Default
	if changed then
		pcall(function()
			ContextActionService:CallFunction("MouseLockSwitchAction", Enum.UserInputState.Begin, game)
		end)
	end
	if forceApply or UIS.MouseBehavior ~= desired then
		UIS.MouseBehavior = desired
	end
end

local function handleShiftLockKey()
	if isTouchDevice then
		return
	end

	setShiftLockState(not shiftLockState, true)
	if updateUI then
		updateUI()
	end
end

local function shouldReplayDriveCamera()
	-- On touch devices in blended modes, keep camera user-driven for natural control.
	if (playbackMode == "frameblend" or playbackMode == "smooth") and isTouchDevice and not frozen then
		return false
	end
	return true
end

local recordFreezeState = {
	active = false,
	hrp = nil,
	anchored = nil,
}

local function redrawLogLabel()
	if not logLabel then
		return
	end
	logLabel.Text = table.concat(logLines, "\n")
end

local function clearLog()
	logLines = {}
	redrawLogLabel()
end

local function log(msg)
	local line = tostring(msg)
	print("[TAS Lite] " .. line)
	table.insert(logLines, line)
	while #logLines > CONFIG.LOG_LINES do
		table.remove(logLines, 1)
	end
	redrawLogLabel()
end

local function round(n, digits)
	local m = 10 ^ (digits or 0)
	return math.floor(n * m + 0.5) / m
end

local function isFiniteNumber(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function toFiniteNumber(value, fallback)
	local n = tonumber(value)
	if isFiniteNumber(n) then
		return n
	end
	return fallback
end

local function sanitizeCFrameTable(raw)
	if type(raw) ~= "table" or #raw < 12 then
		return nil
	end
	local out = table.create(12)
	for i = 1, 12 do
		local n = toFiniteNumber(raw[i], nil)
		if not n then
			return nil
		end
		out[i] = n
	end
	return out
end

local function sanitizeV3Table(raw, fallback)
	if type(raw) ~= "table" or #raw < 3 then
		return fallback or { 0, 0, 0 }
	end
	local x = toFiniteNumber(raw[1], nil)
	local y = toFiniteNumber(raw[2], nil)
	local z = toFiniteNumber(raw[3], nil)
	if not x or not y or not z then
		return fallback or { 0, 0, 0 }
	end
	return { x, y, z }
end

local function sanitizeFrameKeys(rawKeys)
	if type(rawKeys) ~= "table" then
		return {}
	end
	local out = {}
	local seen = {}
	local maxKeys = 64
	for _, keyName in ipairs(rawKeys) do
		if #out >= maxKeys then
			break
		end
		if type(keyName) == "string" and #keyName > 0 and #keyName <= 32 and not seen[keyName] then
			seen[keyName] = true
			table.insert(out, keyName)
		end
	end
	return out
end

local function sanitizeCheckpoints(rawCheckpoints, frameCount)
	if type(rawCheckpoints) ~= "table" or frameCount <= 0 then
		return {}, 0
	end
	local out = {}
	local dropped = 0
	for name, idx in pairs(rawCheckpoints) do
		local okName = (type(name) == "string" and #name > 0 and #name <= 64)
		local n = tonumber(idx)
		if okName and isFiniteNumber(n) then
			local clamped = math.clamp(math.floor(n + 0.5), 1, frameCount)
			out[name] = clamped
		else
			dropped = dropped + 1
		end
	end
	return out, dropped
end

local function roundArray(arr, digits)
	local out = table.create(#arr)
	for i, v in ipairs(arr) do
		out[i] = round(v, digits)
	end
	return out
end

local function cfToTable(cf)
	return { cf:GetComponents() }
end

local function tableToCf(t)
	local clean = sanitizeCFrameTable(t)
	if not clean then
		return nil
	end
	return CFrame.new(unpack(clean))
end

local function v3ToTable(v)
	return { v.X, v.Y, v.Z }
end

local function tableToV3(t)
	local clean = sanitizeV3Table(t, { 0, 0, 0 })
	return Vector3.new(clean[1], clean[2], clean[3])
end

local function pressedMapFromFrame(frame)
	local pressed = {}
	if type(frame) == "table" and type(frame.keys) == "table" then
		for _, keyName in ipairs(frame.keys) do
			if type(keyName) == "string" then
				pressed[keyName] = true
			end
		end
	end
	return pressed
end

local function movementFromPressedMap(pressed, basisCF)
	local moveRight = 0
	local moveForward = 0
	if pressed.W or pressed.Up then
		moveForward = moveForward + 1
	end
	if pressed.S or pressed.Down then
		moveForward = moveForward - 1
	end
	if pressed.A or pressed.Left then
		moveRight = moveRight - 1
	end
	if pressed.D or pressed.Right then
		moveRight = moveRight + 1
	end

	if moveRight == 0 and moveForward == 0 then
		return Vector3.zero
	end

	local forward = Vector3.new(0, 0, -1)
	local right = Vector3.new(1, 0, 0)
	if basisCF then
		local flatForward = Vector3.new(basisCF.LookVector.X, 0, basisCF.LookVector.Z)
		if flatForward.Magnitude > 0.0001 then
			forward = flatForward.Unit
		end

		local flatRight = Vector3.new(basisCF.RightVector.X, 0, basisCF.RightVector.Z)
		if flatRight.Magnitude > 0.0001 then
			right = flatRight.Unit
		end
	end

	local worldMove = (right * moveRight) + (forward * moveForward)
	if worldMove.Magnitude > 1 then
		worldMove = worldMove.Unit
	end
	return worldMove
end

local function movementFromVelocity(vel)
	local planar = Vector3.new(vel.X, 0, vel.Z)
	local mag = planar.Magnitude
	if mag <= 0.05 then
		return Vector3.zero
	end
	return planar / mag
end

local function clampVectorMagnitude(v, maxMagnitude)
	local mag = v.Magnitude
	if mag <= maxMagnitude or mag <= 0 then
		return v
	end
	return v.Unit * maxMagnitude
end

local function keysSnapshot()
	local out = {}
	for key, isDown in pairs(heldKeys) do
		if isDown then
			table.insert(out, key)
		end
	end
	table.sort(out)
	return out
end

local function shouldCaptureVirtualKey(keyName)
	return not VIRTUAL_INPUT_BLACKLIST[keyName]
end

local function keyNameToVirtualKeyCode(keyName)
	if type(keyName) ~= "string" then
		return nil
	end
	if #keyName == 1 then
		local byte = string.byte(string.upper(keyName))
		if byte and byte >= 65 and byte <= 90 then
			return byte
		end
		if byte and byte >= 48 and byte <= 57 then
			return byte
		end
	end

	local map = {
		Space = 0x20,
		LeftShift = 0x10,
		RightShift = 0x10,
		LeftControl = 0x11,
		RightControl = 0x11,
		Tab = 0x09,
		Enter = 0x0D,
		Backspace = 0x08,
		Up = 0x26,
		Down = 0x28,
		Left = 0x25,
		Right = 0x27,
	}
	return map[keyName]
end

local function sendVirtualInputState(keyName, isDown, forceSend)
	if (not forceSend) and (not virtualInputPlaybackEnabled) then
		return
	end

	if keyName == "MouseButton1" then
		local mousePos = UIS:GetMouseLocation()
		pcall(function()
			VirtualInputManager:SendMouseButtonEvent(mousePos.X, mousePos.Y, 0, isDown, game, 0)
		end)
		if isDown and mouse1press then
			pcall(mouse1press)
		elseif (not isDown) and mouse1release then
			pcall(mouse1release)
		end
		return
	end

	if keyName == "MouseButton2" then
		local mousePos = UIS:GetMouseLocation()
		pcall(function()
			VirtualInputManager:SendMouseButtonEvent(mousePos.X, mousePos.Y, 1, isDown, game, 0)
		end)
		if isDown and mouse2press then
			pcall(mouse2press)
		elseif (not isDown) and mouse2release then
			pcall(mouse2release)
		end
		return
	end

	local keyEnum = Enum.KeyCode[keyName]
	if keyEnum then
		pcall(function()
			VirtualInputManager:SendKeyEvent(isDown, keyEnum, false, game)
		end)
	end

	local vkey = keyNameToVirtualKeyCode(keyName)
	if vkey then
		if isDown and keypress then
			pcall(keypress, vkey)
		elseif (not isDown) and keyrelease then
			pcall(keyrelease, vkey)
		end
	end
end

local function releaseAllVirtualInputs()
	for keyName, isPressed in pairs(virtualPressed) do
		if isPressed then
			sendVirtualInputState(keyName, false, true)
		end
	end
	virtualPressed = {}
end

local function syncVirtualInputsToFrame(frame)
	if not virtualInputPlaybackEnabled then
		return
	end

	local desired = {}
	local keys = frame and frame.keys or {}
	for _, keyName in ipairs(keys) do
		if type(keyName) == "string" and shouldCaptureVirtualKey(keyName) then
			desired[keyName] = true
			if not virtualPressed[keyName] then
				sendVirtualInputState(keyName, true)
				virtualPressed[keyName] = true
			end
		end
	end

	for keyName, isPressed in pairs(virtualPressed) do
		if isPressed and not desired[keyName] then
			sendVirtualInputState(keyName, false)
			virtualPressed[keyName] = nil
		end
	end
end

local function char()
	return player.Character
end

local function humanoidAndRoot()
	local c = char()
	if not c then
		return nil, nil
	end
	local hum = c:FindFirstChildOfClass("Humanoid")
	local hrp = c:FindFirstChild("HumanoidRootPart")
	return hum, hrp
end

local function ensureFolder()
	if not isfolder(CONFIG.FOLDER) then
		makefolder(CONFIG.FOLDER)
	end
end

local replayPath = CONFIG.FOLDER .. "/" .. tostring(game.PlaceId) .. "_" .. CONFIG.FILE_NAME

local function clampIndex(idx)
	if #frames == 0 then
		return 1
	end
	local n = math.floor((idx or 1) + 0.5)
	return math.clamp(n, 1, #frames)
end

local function setCameraPlaybackMode(enabled)
	if enabled then
		if shouldReplayDriveCamera() then
			camera.CameraType = Enum.CameraType.Scriptable
		else
			camera.CameraType = Enum.CameraType.Custom
		end
	else
		camera.CameraType = Enum.CameraType.Custom
	end
end

local function resetCameraSmoothingClock()
	cameraSmoothState.lastUpdate = tick()
end

local function smoothCameraTo(targetCF)
	local now = tick()
	local dt
	if cameraSmoothState.lastUpdate > 0 then
		dt = math.clamp(now - cameraSmoothState.lastUpdate, 1 / 240, 0.06)
	else
		dt = 1 / 60
	end
	cameraSmoothState.lastUpdate = now
	local alpha = 1 - math.exp(-CAMERA_SMOOTH_RATE * dt)
	camera.CFrame = camera.CFrame:Lerp(targetCF, alpha)
end

local function applyPlaybackLock()
	local hum, hrp = humanoidAndRoot()
	if not hum or not hrp then
		return false
	end

	if not playbackState.active then
		playbackState.active = true
		playbackState.humanoid = hum
		playbackState.hrp = hrp
		playbackState.saved = {
			WalkSpeed = hum.WalkSpeed,
			JumpPower = hum.JumpPower,
			AutoRotate = hum.AutoRotate,
			Anchored = hrp.Anchored,
			MouseBehavior = UIS.MouseBehavior,
			ShiftLockState = shiftLockState,
		}
	end

	if (playbackMode == "smooth" or playbackMode == "frameblend") and not frozen then
		hum.WalkSpeed = playbackState.saved.WalkSpeed
		hum.JumpPower = playbackState.saved.JumpPower
		hum.AutoRotate = false
	else
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.AutoRotate = false
	end
	if frozen or playbackMode == "ghost" then
		hrp.Anchored = true
	else
		hrp.Anchored = false
	end
	return true
end

local function clearPlaybackLock()
	if not playbackState.active then
		return
	end

	local hum = playbackState.humanoid
	local hrp = playbackState.hrp
	local saved = playbackState.saved

	if hum and hum.Parent and saved then
		hum.WalkSpeed = saved.WalkSpeed
		hum.JumpPower = saved.JumpPower
		hum.AutoRotate = saved.AutoRotate
	end
	if hrp and hrp.Parent and saved then
		hrp.Anchored = saved.Anchored
	end
	if saved and saved.MouseBehavior then
		UIS.MouseBehavior = saved.MouseBehavior
	end
	shiftLockState = (saved and saved.ShiftLockState == true) or false
	if not isTouchDevice then
		setShiftLockState(shiftLockState, true)
	end

	playbackState.active = false
	playbackState.humanoid = nil
	playbackState.hrp = nil
	playbackState.saved = nil
end

local function applyRecordFreezeLock()
	local _, hrp = humanoidAndRoot()
	if not hrp then
		return false
	end

	if not recordFreezeState.active then
		recordFreezeState.active = true
		recordFreezeState.hrp = hrp
		recordFreezeState.anchored = hrp.Anchored
	end

	hrp.Anchored = true
	return true
end

local function clearRecordFreezeLock()
	if not recordFreezeState.active then
		return
	end

	local hrp = recordFreezeState.hrp
	if hrp and hrp.Parent then
		hrp.Anchored = recordFreezeState.anchored == true
	end

	recordFreezeState.active = false
	recordFreezeState.hrp = nil
	recordFreezeState.anchored = nil
end

local function applyRecordNoCollision()
	if not recordNoCollisionEnabled then
		return
	end

	local c = player.Character
	if not c then
		return
	end

	recordNoCollisionState.active = true
	for _, inst in ipairs(c:GetDescendants()) do
		if inst:IsA("BasePart") then
			-- Keep real collisions for natural movement/animations; disable touch triggers while recording.
			if recordNoCollisionState.partTouch[inst] == nil then
				recordNoCollisionState.partTouch[inst] = inst.CanTouch
			end
			inst.CanTouch = false
		end
	end
end

local function clearRecordNoCollision()
	if not recordNoCollisionState.active then
		return
	end

	for part, oldValue in pairs(recordNoCollisionState.partTouch) do
		if part and part.Parent then
			part.CanTouch = (oldValue == true)
		end
	end

	recordNoCollisionState.partTouch = {}
	recordNoCollisionState.active = false
end

local function normalizeFrame(rawFrame)
	if type(rawFrame) ~= "table" then
		return nil
	end

	-- v0.1/v0.2 compatibility (root/vel/cam/fov keys)
	if rawFrame.root and rawFrame.cam then
		local root = sanitizeCFrameTable(rawFrame.root)
		local cam = sanitizeCFrameTable(rawFrame.cam)
		if not root or not cam then
			return nil
		end

		local dt = toFiniteNumber(rawFrame.dt, CONFIG.DEFAULT_FRAME_DT)
		dt = math.clamp(dt, 1 / 1000, 1)
		local fov = math.clamp(toFiniteNumber(rawFrame.fov, 70), 1, 120)
		local hstate = type(rawFrame.hstate) == "string" and rawFrame.hstate or nil
		return {
			dt = dt,
			root = root,
			vel = sanitizeV3Table(rawFrame.vel, { 0, 0, 0 }),
			rotvel = sanitizeV3Table(rawFrame.rotvel, { 0, 0, 0 }),
			cam = cam,
			cam_local = sanitizeCFrameTable(rawFrame.cam_local),
			fov = fov,
			hstate = hstate,
			shiftlock = (rawFrame.shiftlock == true),
			keys = sanitizeFrameKeys(rawFrame.keys),
		}
	end

	return nil
end

local function normalizeFrames(rawFrames)
	if type(rawFrames) ~= "table" then
		return {}, 0
	end
	local out = {}
	local dropped = 0
	for _, frame in ipairs(rawFrames) do
		local n = normalizeFrame(frame)
		if n then
			table.insert(out, n)
		else
			dropped = dropped + 1
		end
	end
	return out, dropped
end

local function rotationOnly(cf)
	return cf - cf.Position
end

local function blendedRootCFrame(currentCF, targetCF, positionAlpha, rotationAlpha)
	local pos = currentCF.Position:Lerp(targetCF.Position, math.clamp(positionAlpha, 0, 1))
	local rot = rotationOnly(currentCF):Lerp(rotationOnly(targetCF), math.clamp(rotationAlpha, 0, 1))
	return CFrame.new(pos) * rot
end

local function scaledBlendAlpha(baseAlpha)
	return math.clamp((tonumber(baseAlpha) or 1) * blendAlphaScale, 0.001, 1)
end

local function applyFrame(i)
	local frame = frames[i]
	if not frame then
		return false
	end

	local hum, hrp = humanoidAndRoot()
	if not hrp or not hum then
		return false
	end

	local rootCF = tableToCf(frame.root)
	local camCF = tableToCf(frame.cam)
	if not rootCF or not camCF then
		return false
	end

	local activePlaybackMode = normalizePlaybackModeName(playbackMode)
	playbackMode = activePlaybackMode

	local shouldForceHumanoidState = (mode == "play")
	if shouldForceHumanoidState and type(frame.hstate) == "string" and frame.hstate ~= lastAppliedHumanoidState then
		local stateEnum = Enum.HumanoidStateType[frame.hstate]
		if stateEnum then
			pcall(function()
				hum:ChangeState(stateEnum)
			end)
			lastAppliedHumanoidState = frame.hstate
		end
	end

	if mode == "play" then
		local frameShiftLock = (frame.shiftlock == true)
		setShiftLockState(frameShiftLock, false)
	end

	local targetVel = tableToV3(frame.vel)
	local targetRotVel = tableToV3(frame.rotvel)

	if activePlaybackMode == "ghost" or frozen then
		hrp.CFrame = rootCF
		hrp.AssemblyLinearVelocity = targetVel
		hrp.AssemblyAngularVelocity = targetRotVel
		lastPhysicsJumpHeld = false
	elseif activePlaybackMode == "frameblend" then
		local posError = rootCF.Position - hrp.Position
		local dist = posError.Magnitude
		lastPhysicsJumpHeld = false

		if dist > FRAMEBLEND_SNAP_DISTANCE then
			hrp.CFrame = rootCF
			hrp.AssemblyLinearVelocity = targetVel
			hrp.AssemblyAngularVelocity = targetRotVel
		else
			hrp.CFrame = blendedRootCFrame(
				hrp.CFrame,
				rootCF,
				scaledBlendAlpha(FRAMEBLEND_POSITION_ALPHA),
				scaledBlendAlpha(FRAMEBLEND_ROTATION_ALPHA)
			)
			hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity:Lerp(targetVel, scaledBlendAlpha(FRAMEBLEND_VELOCITY_BLEND))
			hrp.AssemblyAngularVelocity = hrp.AssemblyAngularVelocity:Lerp(targetRotVel, scaledBlendAlpha(FRAMEBLEND_ANGULAR_BLEND))
		end
	else
		local posError = rootCF.Position - hrp.Position
		local dist = posError.Magnitude
		lastPhysicsJumpHeld = false

		if dist > FRAMEBLEND_SNAP_DISTANCE then
			hrp.CFrame = rootCF
			hrp.AssemblyLinearVelocity = targetVel
			hrp.AssemblyAngularVelocity = targetRotVel
		else
			hrp.CFrame = blendedRootCFrame(
				hrp.CFrame,
				rootCF,
				scaledBlendAlpha(CONFIG.SMOOTH_POSITION_ALPHA),
				scaledBlendAlpha(CONFIG.SMOOTH_ROTATION_ALPHA)
			)
			hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity:Lerp(targetVel, scaledBlendAlpha(CONFIG.SMOOTH_VELOCITY_BLEND))
			hrp.AssemblyAngularVelocity = hrp.AssemblyAngularVelocity:Lerp(targetRotVel, scaledBlendAlpha(CONFIG.SMOOTH_ANGULAR_BLEND))
		end
	end
	if shouldReplayDriveCamera() then
		if cameraMode == "smooth" and not frozen then
			smoothCameraTo(camCF)
		else
			camera.CFrame = camCF
		end
	end
	camera.FieldOfView = tonumber(frame.fov) or 70
	if mode == "play" and not frozen then
		syncVirtualInputsToFrame(frame)
	elseif mode == "play" and frozen then
		releaseAllVirtualInputs()
	end
	if mode == "play" then
		updatePlaybackInputOverlay(frame)
	end
	return true
end

local function setCapActive(capData, active)
	if not capData then
		return
	end
	if active then
		capData.frame.BackgroundColor3 = Color3.fromRGB(245, 245, 245)
		capData.label.TextColor3 = Color3.fromRGB(12, 12, 12)
	else
		capData.frame.BackgroundColor3 = Color3.fromRGB(24, 30, 41)
		capData.label.TextColor3 = Color3.fromRGB(245, 245, 245)
	end
end

local function resetOverlayMouseMotion()
	overlayMouseState.x = 0
	overlayMouseState.y = 0
	overlayMouseState.vx = 0
	overlayMouseState.vy = 0
	overlayMouseState.tx = 0
	overlayMouseState.ty = 0
	overlayMouseState.lastUpdate = tick()
end

local function stepOverlayMouseMotion(targetX, targetY)
	local now = tick()
	local dt
	if overlayMouseState.lastUpdate > 0 then
		dt = math.clamp(now - overlayMouseState.lastUpdate, 1 / 240, 0.06)
	else
		dt = 1 / 60
	end
	overlayMouseState.lastUpdate = now

	local targetLerp = math.clamp(dt * CONFIG.OVERLAY_MOUSE_TARGET_SMOOTH, 0, 1)
	overlayMouseState.tx = overlayMouseState.tx + (targetX - overlayMouseState.tx) * targetLerp
	overlayMouseState.ty = overlayMouseState.ty + (targetY - overlayMouseState.ty) * targetLerp

	local ax = (overlayMouseState.tx - overlayMouseState.x) * CONFIG.OVERLAY_MOUSE_SPRING
	local ay = (overlayMouseState.ty - overlayMouseState.y) * CONFIG.OVERLAY_MOUSE_SPRING
	local damping = math.exp(-CONFIG.OVERLAY_MOUSE_DAMPING * dt)

	overlayMouseState.vx = (overlayMouseState.vx + ax * dt) * damping
	overlayMouseState.vy = (overlayMouseState.vy + ay * dt) * damping

	overlayMouseState.x = overlayMouseState.x + overlayMouseState.vx * dt
	overlayMouseState.y = overlayMouseState.y + overlayMouseState.vy * dt

	if math.abs(targetX) < CONFIG.OVERLAY_MOUSE_DEADZONE and math.abs(targetY) < CONFIG.OVERLAY_MOUSE_DEADZONE then
		overlayMouseState.x = overlayMouseState.x * CONFIG.OVERLAY_MOUSE_IDLE_RETURN
		overlayMouseState.y = overlayMouseState.y * CONFIG.OVERLAY_MOUSE_IDLE_RETURN
	end

	local radius = CONFIG.OVERLAY_MOUSE_RADIUS
	local magnitude = math.sqrt((overlayMouseState.x * overlayMouseState.x) + (overlayMouseState.y * overlayMouseState.y))
	if magnitude > radius and magnitude > 0 then
		local scale = radius / magnitude
		overlayMouseState.x = overlayMouseState.x * scale
		overlayMouseState.y = overlayMouseState.y * scale
		overlayMouseState.vx = overlayMouseState.vx * 0.55
		overlayMouseState.vy = overlayMouseState.vy * 0.55
	end

	local speed = math.sqrt((overlayMouseState.vx * overlayMouseState.vx) + (overlayMouseState.vy * overlayMouseState.vy))
	return overlayMouseState.x, overlayMouseState.y, speed
end

updatePlaybackInputOverlay = function(frame)
	if not inputOverlayFrame then
		return
	end

	if mode ~= "play" or type(frame) ~= "table" or not inputOverlayEnabled then
		inputOverlayFrame.Visible = false
		lastOverlayCamLocalCF = nil
		resetOverlayMouseMotion()
		if mouseDot then
			mouseDot.Position = UDim2.fromOffset(94, 87)
			mouseDot.BackgroundColor3 = Color3.fromRGB(255, 40, 40)
			mouseDot.Size = UDim2.fromOffset(18, 18)
		end
		return
	end

	local pressed = {}
	for _, keyName in ipairs(frame.keys or {}) do
		if type(keyName) == "string" then
			pressed[keyName] = true
		end
	end

	setCapActive(inputKeyCaps.Up, pressed.LeftShift or pressed.RightShift)
	setCapActive(inputKeyCaps.W, pressed.W)
	setCapActive(inputKeyCaps.A, pressed.A)
	setCapActive(inputKeyCaps.S, pressed.S)
	setCapActive(inputKeyCaps.D, pressed.D)
	setCapActive(inputKeyCaps.Space, pressed.Space)

	local lmb = pressed.MouseButton1
	local rmb = pressed.MouseButton2
	setCapActive(mouseLeftCap, lmb)
	setCapActive(mouseRightCap, rmb)

	local camLocalCF = tableToCf(frame.cam_local) or tableToCf(frame.cam)
	if mouseDot then
		local centerX, centerY = 94, 87
		local targetX, targetY = 0, 0
		local moving = false

		if camLocalCF and lastOverlayCamLocalCF then
			local delta = lastOverlayCamLocalCF:ToObjectSpace(camLocalCF)
			local pitch, yaw = delta:ToOrientation()
			targetX = math.clamp(yaw * CONFIG.OVERLAY_MOUSE_SENSITIVITY, -CONFIG.OVERLAY_MOUSE_RADIUS, CONFIG.OVERLAY_MOUSE_RADIUS)
			targetY = math.clamp(-pitch * CONFIG.OVERLAY_MOUSE_SENSITIVITY, -CONFIG.OVERLAY_MOUSE_RADIUS, CONFIG.OVERLAY_MOUSE_RADIUS)
			moving = (math.abs(targetX) + math.abs(targetY)) > CONFIG.OVERLAY_MOUSE_DEADZONE
		end

		local smoothedX, smoothedY, speed = stepOverlayMouseMotion(targetX, targetY)
		local pulse = math.clamp(speed / 80, 0, 1)
		local dotSize = math.floor(18 + (6 * pulse))
		local dotX = centerX + smoothedX
		local dotY = centerY + smoothedY

		mouseDot.Size = UDim2.fromOffset(dotSize, dotSize)
		mouseDot.Position = UDim2.fromOffset(dotX, dotY)
		mouseDot.BackgroundColor3 = moving and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(255, 40, 40)
	end
	lastOverlayCamLocalCF = camLocalCF

	inputOverlayFrame.Visible = true
end

local function refreshSettingsUI()
	if settingsInputsBtn then
		settingsInputsBtn.Text = "Inputs: " .. (virtualInputPlaybackEnabled and "ON" or "OFF")
		settingsInputsBtn.BackgroundColor3 = virtualInputPlaybackEnabled and Color3.fromRGB(51, 96, 78) or Color3.fromRGB(92, 67, 67)
	end
	if settingsPlaybackModeBtn then
		settingsPlaybackModeBtn.Text = "Playback: " .. tostring(playbackMode)
	end
	if settingsCameraModeBtn then
		settingsCameraModeBtn.Text = "Camera: " .. tostring(cameraMode)
	end
	if settingsRecordNoColBtn then
		settingsRecordNoColBtn.Text = "RecNoCol: " .. (recordNoCollisionEnabled and "ON" or "OFF")
		settingsRecordNoColBtn.BackgroundColor3 = recordNoCollisionEnabled and Color3.fromRGB(98, 86, 56) or Color3.fromRGB(68, 93, 124)
	end
	if settingsRecordModeBtn then
		settingsRecordModeBtn.Text = "RecMode: " .. tostring(recordMode)
	end
	if settingsPlaySpeedBtn then
		settingsPlaySpeedBtn.Text = string.format("PlaySpeed: %.2f", playbackSpeed)
	end
	if settingsOverlayBtn then
		settingsOverlayBtn.Text = "Overlay: " .. (inputOverlayEnabled and "ON" or "OFF")
		settingsOverlayBtn.BackgroundColor3 = inputOverlayEnabled and Color3.fromRGB(72, 105, 146) or Color3.fromRGB(90, 67, 67)
	end
end

local function applySettingsVisibility()
	if not settingsFrame or not logLabel or not settingsToggleBtn then
		return
	end

	settingsFrame.Visible = settingsOpen
	settingsToggleBtn.Text = settingsOpen and "-" or "+"
	if settingsOpen then
		logLabel.Position = UDim2.fromOffset(10, 224)
		logLabel.Size = UDim2.new(1, -20, 1, -228)
	else
		logLabel.Position = UDim2.fromOffset(10, 186)
		logLabel.Size = UDim2.new(1, -20, 1, -190)
	end
end

local function statusText()
	local recordFreezeText = (mode == "record" and frozen and "ON") or "OFF"
	local shiftStateText = isShiftLockActive() and "ON" or "OFF"
	return string.format(
		"Mode: %s | Frozen: %s | RecFreeze: %s | ShiftLock: %s | Frame: %d/%d | Trimmed: %d | RecordMode: %s | PlaybackMode: %s | CameraMode: %s | TimelineFPS: %d | Inputs: %s | SeekSpeed: %.2f | PlaySpeed: %.2f | Blend: %.2f\nF8 Rec  F10 Play  F6 Save  F7 Load  E Freeze  F/G Step  T/Y Seek  C/V Checkpoint  / Command  U UI  F2 Hide",
		mode,
		tostring(frozen),
		recordFreezeText,
		shiftStateText,
		playIndex,
		#frames,
		lastTrimmedCount,
		recordMode,
		playbackMode,
		cameraMode,
		TIMELINE_FPS,
		virtualInputPlaybackEnabled and "ON" or "OFF",
		seekSpeed,
		playbackSpeed,
		blendAlphaScale
	)
end

-- UI
local gui = Instance.new("ScreenGui")
gui.Name = "TASLiteUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.fromOffset(780, 410)
mainFrame.Position = UDim2.fromOffset(16, 12)
mainFrame.BackgroundColor3 = Color3.fromRGB(24, 29, 38)
mainFrame.BorderSizePixel = 0
mainFrame.ClipsDescendants = true
mainFrame.Parent = gui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 12)
mainCorner.Parent = mainFrame

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Color3.fromRGB(126, 164, 225)
mainStroke.Thickness = 1.2
mainStroke.Transparency = 0.28
mainStroke.Parent = mainFrame

local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 36)
topBar.BackgroundColor3 = Color3.fromRGB(43, 57, 79)
topBar.BorderSizePixel = 0
topBar.Parent = mainFrame

local topGrad = Instance.new("UIGradient")
topGrad.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(132, 170, 233)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(76, 112, 178)),
})
topGrad.Rotation = 12
topGrad.Parent = topBar

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -12, 1, 0)
titleLabel.Position = UDim2.fromOffset(10, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.TextColor3 = Color3.fromRGB(238, 245, 255)
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 15
titleLabel.Text = "TAS Lite  v0.9.0-rewrite"
titleLabel.Parent = topBar

shiftLockIndicator = Instance.new("TextLabel")
shiftLockIndicator.Size = UDim2.fromOffset(140, 22)
shiftLockIndicator.Position = UDim2.new(1, -150, 0, 7)
shiftLockIndicator.BackgroundColor3 = Color3.fromRGB(90, 63, 63)
shiftLockIndicator.BackgroundTransparency = 0.15
shiftLockIndicator.BorderSizePixel = 0
shiftLockIndicator.TextColor3 = Color3.fromRGB(255, 236, 236)
shiftLockIndicator.Font = Enum.Font.GothamSemibold
shiftLockIndicator.TextSize = 12
shiftLockIndicator.Text = "ShiftLock REC: OFF"
shiftLockIndicator.Parent = topBar

local shiftCorner = Instance.new("UICorner")
shiftCorner.CornerRadius = UDim.new(0, 6)
shiftCorner.Parent = shiftLockIndicator

settingsToggleBtn = Instance.new("TextButton")
settingsToggleBtn.Size = UDim2.fromOffset(28, 22)
settingsToggleBtn.Position = UDim2.new(1, -184, 0, 7)
settingsToggleBtn.BackgroundColor3 = Color3.fromRGB(78, 114, 172)
settingsToggleBtn.BackgroundTransparency = 0.2
settingsToggleBtn.BorderSizePixel = 0
settingsToggleBtn.TextColor3 = Color3.fromRGB(225, 236, 255)
settingsToggleBtn.Font = Enum.Font.GothamBold
settingsToggleBtn.TextSize = 16
settingsToggleBtn.Text = "+"
settingsToggleBtn.Parent = topBar

local settingsToggleCorner = Instance.new("UICorner")
settingsToggleCorner.CornerRadius = UDim.new(0, 8)
settingsToggleCorner.Parent = settingsToggleBtn

adminToggleBtn = Instance.new("TextButton")
adminToggleBtn.Size = UDim2.fromOffset(58, 22)
adminToggleBtn.Position = UDim2.new(1, -248, 0, 7)
adminToggleBtn.BackgroundColor3 = Color3.fromRGB(56, 91, 120)
adminToggleBtn.BackgroundTransparency = 0.16
adminToggleBtn.BorderSizePixel = 0
adminToggleBtn.TextColor3 = Color3.fromRGB(228, 241, 255)
adminToggleBtn.Font = Enum.Font.GothamBold
adminToggleBtn.TextSize = 12
adminToggleBtn.Text = "Admin"
adminToggleBtn.Parent = topBar

local adminToggleCorner = Instance.new("UICorner")
adminToggleCorner.CornerRadius = UDim.new(0, 8)
adminToggleCorner.Parent = adminToggleBtn

local label = Instance.new("TextLabel")
label.Size = UDim2.new(1, -20, 0, 96)
label.Position = UDim2.fromOffset(10, 44)
label.BackgroundColor3 = Color3.fromRGB(31, 38, 50)
label.BackgroundTransparency = 0.12
label.BorderSizePixel = 0
label.TextColor3 = Color3.fromRGB(235, 241, 251)
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextYAlignment = Enum.TextYAlignment.Top
label.Font = Enum.Font.Code
label.TextSize = 15
label.Text = ""
label.Parent = mainFrame

local labelCorner = Instance.new("UICorner")
labelCorner.CornerRadius = UDim.new(0, 8)
labelCorner.Parent = label

local commandBar = Instance.new("TextBox")
commandBar.Size = UDim2.new(1, -20, 0, 30)
commandBar.Position = UDim2.fromOffset(10, 148)
commandBar.BackgroundColor3 = Color3.fromRGB(26, 33, 45)
commandBar.BackgroundTransparency = 0.08
commandBar.TextColor3 = Color3.fromRGB(238, 244, 255)
commandBar.BorderSizePixel = 0
commandBar.TextXAlignment = Enum.TextXAlignment.Left
commandBar.Font = Enum.Font.Code
commandBar.PlaceholderText = "help | playspeed 1 | blend 0.6 | playbackmode frameblend"
commandBar.TextSize = 15
commandBar.ClearTextOnFocus = false
commandBar.Text = ""
commandBar.Parent = mainFrame

local commandCorner = Instance.new("UICorner")
commandCorner.CornerRadius = UDim.new(0, 8)
commandCorner.Parent = commandBar

settingsFrame = Instance.new("Frame")
settingsFrame.Size = UDim2.new(1, -20, 0, 32)
settingsFrame.Position = UDim2.fromOffset(10, 186)
settingsFrame.BackgroundTransparency = 1
settingsFrame.Parent = mainFrame
settingsFrame.Visible = false

local settingsLayout = Instance.new("UIListLayout")
settingsLayout.FillDirection = Enum.FillDirection.Horizontal
settingsLayout.Padding = UDim.new(0, 8)
settingsLayout.SortOrder = Enum.SortOrder.LayoutOrder
settingsLayout.Parent = settingsFrame

local function makeSettingButton()
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.fromOffset(100, 32)
	btn.BackgroundColor3 = Color3.fromRGB(45, 58, 79)
	btn.BorderSizePixel = 0
	btn.TextColor3 = Color3.fromRGB(230, 238, 255)
	btn.Font = Enum.Font.GothamSemibold
	btn.TextSize = 12
	btn.AutoButtonColor = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = btn
	return btn
end

settingsInputsBtn = makeSettingButton()
settingsInputsBtn.Parent = settingsFrame
settingsOverlayBtn = makeSettingButton()
settingsOverlayBtn.Parent = settingsFrame
settingsPlaybackModeBtn = makeSettingButton()
settingsPlaybackModeBtn.Parent = settingsFrame
settingsCameraModeBtn = makeSettingButton()
settingsCameraModeBtn.Parent = settingsFrame
settingsRecordNoColBtn = makeSettingButton()
settingsRecordNoColBtn.Parent = settingsFrame
settingsRecordModeBtn = makeSettingButton()
settingsRecordModeBtn.Parent = settingsFrame
settingsPlaySpeedBtn = makeSettingButton()
settingsPlaySpeedBtn.Parent = settingsFrame

logLabel = Instance.new("TextLabel")
logLabel.Size = UDim2.new(1, -20, 1, -190)
logLabel.Position = UDim2.fromOffset(10, 186)
logLabel.BackgroundColor3 = Color3.fromRGB(23, 29, 40)
logLabel.BackgroundTransparency = 0.12
logLabel.TextColor3 = Color3.fromRGB(190, 244, 213)
logLabel.TextXAlignment = Enum.TextXAlignment.Left
logLabel.TextYAlignment = Enum.TextYAlignment.Top
logLabel.Font = Enum.Font.Code
logLabel.TextSize = 13
logLabel.BorderSizePixel = 0
logLabel.TextWrapped = false
logLabel.Text = ""
logLabel.Parent = mainFrame

local logCorner = Instance.new("UICorner")
logCorner.CornerRadius = UDim.new(0, 8)
logCorner.Parent = logLabel

adminPanel = Instance.new("Frame")
adminPanel.Name = "AdminPanel"
adminPanel.Size = UDim2.fromOffset(520, 520)
adminPanel.Position = UDim2.fromOffset(812, 12)
adminPanel.BackgroundColor3 = Color3.fromRGB(18, 24, 34)
adminPanel.BackgroundTransparency = 0.04
adminPanel.BorderSizePixel = 0
adminPanel.Visible = false
adminPanel.Parent = gui

local adminPanelCorner = Instance.new("UICorner")
adminPanelCorner.CornerRadius = UDim.new(0, 8)
adminPanelCorner.Parent = adminPanel

local adminPanelStroke = Instance.new("UIStroke")
adminPanelStroke.Color = Color3.fromRGB(105, 167, 214)
adminPanelStroke.Transparency = 0.32
adminPanelStroke.Thickness = 1.2
adminPanelStroke.Parent = adminPanel

local adminHeader = Instance.new("Frame")
adminHeader.Size = UDim2.new(1, 0, 0, 38)
adminHeader.BackgroundColor3 = Color3.fromRGB(41, 65, 90)
adminHeader.BorderSizePixel = 0
adminHeader.Parent = adminPanel

local adminHeaderCorner = Instance.new("UICorner")
adminHeaderCorner.CornerRadius = UDim.new(0, 8)
adminHeaderCorner.Parent = adminHeader

local adminTitle = Instance.new("TextLabel")
adminTitle.Size = UDim2.new(1, -96, 1, 0)
adminTitle.Position = UDim2.fromOffset(12, 0)
adminTitle.BackgroundTransparency = 1
adminTitle.Text = "Local Admin Panel"
adminTitle.TextColor3 = Color3.fromRGB(235, 245, 255)
adminTitle.Font = Enum.Font.GothamBold
adminTitle.TextSize = 15
adminTitle.TextXAlignment = Enum.TextXAlignment.Left
adminTitle.Parent = adminHeader

local adminCloseBtn = Instance.new("TextButton")
adminCloseBtn.Size = UDim2.fromOffset(28, 24)
adminCloseBtn.Position = UDim2.new(1, -36, 0, 7)
adminCloseBtn.BackgroundColor3 = Color3.fromRGB(101, 61, 68)
adminCloseBtn.BorderSizePixel = 0
adminCloseBtn.Text = "X"
adminCloseBtn.TextColor3 = Color3.fromRGB(255, 235, 238)
adminCloseBtn.Font = Enum.Font.GothamBold
adminCloseBtn.TextSize = 12
adminCloseBtn.Parent = adminHeader

local adminCloseCorner = Instance.new("UICorner")
adminCloseCorner.CornerRadius = UDim.new(0, 6)
adminCloseCorner.Parent = adminCloseBtn

adminStatusLabel = Instance.new("TextLabel")
adminStatusLabel.Size = UDim2.new(1, -20, 0, 52)
adminStatusLabel.Position = UDim2.fromOffset(10, 48)
adminStatusLabel.BackgroundColor3 = Color3.fromRGB(25, 33, 46)
adminStatusLabel.BackgroundTransparency = 0.08
adminStatusLabel.BorderSizePixel = 0
adminStatusLabel.Text = ""
adminStatusLabel.TextColor3 = Color3.fromRGB(213, 231, 248)
adminStatusLabel.Font = Enum.Font.Code
adminStatusLabel.TextSize = 12
adminStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
adminStatusLabel.TextYAlignment = Enum.TextYAlignment.Top
adminStatusLabel.Parent = adminPanel

local adminStatusCorner = Instance.new("UICorner")
adminStatusCorner.CornerRadius = UDim.new(0, 6)
adminStatusCorner.Parent = adminStatusLabel

adminCommandBox = Instance.new("TextBox")
adminCommandBox.Size = UDim2.new(1, -20, 0, 30)
adminCommandBox.Position = UDim2.fromOffset(10, 108)
adminCommandBox.BackgroundColor3 = Color3.fromRGB(28, 38, 52)
adminCommandBox.BorderSizePixel = 0
adminCommandBox.TextColor3 = Color3.fromRGB(238, 246, 255)
adminCommandBox.PlaceholderText = "admin command, e.g. fly on | ws 32 | tpforward 20"
adminCommandBox.Text = ""
adminCommandBox.ClearTextOnFocus = false
adminCommandBox.Font = Enum.Font.Code
adminCommandBox.TextSize = 14
adminCommandBox.TextXAlignment = Enum.TextXAlignment.Left
adminCommandBox.Parent = adminPanel

local adminCommandCorner = Instance.new("UICorner")
adminCommandCorner.CornerRadius = UDim.new(0, 6)
adminCommandCorner.Parent = adminCommandBox

adminCommandList = Instance.new("ScrollingFrame")
adminCommandList.Size = UDim2.new(1, -20, 1, -152)
adminCommandList.Position = UDim2.fromOffset(10, 146)
adminCommandList.BackgroundColor3 = Color3.fromRGB(15, 20, 29)
adminCommandList.BackgroundTransparency = 0.08
adminCommandList.BorderSizePixel = 0
adminCommandList.ScrollBarThickness = 8
adminCommandList.CanvasSize = UDim2.fromOffset(0, 0)
adminCommandList.Parent = adminPanel

local adminListCorner = Instance.new("UICorner")
adminListCorner.CornerRadius = UDim.new(0, 6)
adminListCorner.Parent = adminCommandList

adminListLayout = Instance.new("UIListLayout")
adminListLayout.SortOrder = Enum.SortOrder.LayoutOrder
adminListLayout.Padding = UDim.new(0, 6)
adminListLayout.Parent = adminCommandList

local adminListPadding = Instance.new("UIPadding")
adminListPadding.PaddingTop = UDim.new(0, 8)
adminListPadding.PaddingBottom = UDim.new(0, 8)
adminListPadding.PaddingLeft = UDim.new(0, 8)
adminListPadding.PaddingRight = UDim.new(0, 8)
adminListPadding.Parent = adminCommandList

inputOverlayFrame = Instance.new("Frame")
inputOverlayFrame.Size = UDim2.fromOffset(430, 190)
inputOverlayFrame.AnchorPoint = Vector2.new(1, 1)
inputOverlayFrame.Position = UDim2.new(1, -16, 1, -16)
inputOverlayFrame.BackgroundColor3 = Color3.fromRGB(16, 21, 30)
inputOverlayFrame.BackgroundTransparency = 0.12
inputOverlayFrame.BorderSizePixel = 0
inputOverlayFrame.Visible = false
inputOverlayFrame.ZIndex = 15
inputOverlayFrame.Parent = gui

local inputOverlayCorner = Instance.new("UICorner")
inputOverlayCorner.CornerRadius = UDim.new(0, 12)
inputOverlayCorner.Parent = inputOverlayFrame

local inputOverlayStroke = Instance.new("UIStroke")
inputOverlayStroke.Color = Color3.fromRGB(183, 205, 241)
inputOverlayStroke.Transparency = 0.65
inputOverlayStroke.Thickness = 1.2
inputOverlayStroke.Parent = inputOverlayFrame

local keyboardHolder = Instance.new("Frame")
keyboardHolder.Size = UDim2.fromOffset(205, 174)
keyboardHolder.Position = UDim2.fromOffset(8, 8)
keyboardHolder.BackgroundTransparency = 1
keyboardHolder.Parent = inputOverlayFrame

local function createInputCap(name, text, size, pos)
	local cap = Instance.new("Frame")
	cap.Name = "Cap_" .. name
	cap.Size = size
	cap.Position = pos
	cap.BackgroundColor3 = Color3.fromRGB(24, 30, 41)
	cap.BackgroundTransparency = 0
	cap.BorderSizePixel = 0
	cap.Parent = keyboardHolder

	local capCorner = Instance.new("UICorner")
	capCorner.CornerRadius = UDim.new(0, 10)
	capCorner.Parent = cap

	local capText = Instance.new("TextLabel")
	capText.Size = UDim2.fromScale(1, 1)
	capText.BackgroundTransparency = 1
	capText.Text = text
	capText.TextColor3 = Color3.fromRGB(245, 245, 245)
	capText.Font = Enum.Font.GothamBold
	capText.TextSize = 24
	capText.Parent = cap

	inputKeyCaps[name] = {
		frame = cap,
		label = capText,
	}
end

createInputCap("Up", "^", UDim2.fromOffset(54, 50), UDim2.fromOffset(16, 4))
createInputCap("W", "W", UDim2.fromOffset(54, 50), UDim2.fromOffset(78, 4))
createInputCap("A", "A", UDim2.fromOffset(54, 50), UDim2.fromOffset(16, 58))
createInputCap("S", "S", UDim2.fromOffset(54, 50), UDim2.fromOffset(78, 58))
createInputCap("D", "D", UDim2.fromOffset(54, 50), UDim2.fromOffset(140, 58))
createInputCap("Space", "_____ ", UDim2.fromOffset(160, 50), UDim2.fromOffset(16, 114))

local mouseHolder = Instance.new("Frame")
mouseHolder.Size = UDim2.fromOffset(190, 174)
mouseHolder.Position = UDim2.fromOffset(228, 8)
mouseHolder.BackgroundTransparency = 1
mouseHolder.Parent = inputOverlayFrame

local mouseCircle = Instance.new("Frame")
mouseCircle.Size = UDim2.fromOffset(172, 172)
mouseCircle.Position = UDim2.fromOffset(8, 1)
mouseCircle.BackgroundColor3 = Color3.fromRGB(24, 30, 41)
mouseCircle.BorderSizePixel = 0
mouseCircle.Parent = mouseHolder

local mouseCircleCorner = Instance.new("UICorner")
mouseCircleCorner.CornerRadius = UDim.new(1, 0)
mouseCircleCorner.Parent = mouseCircle

local mouseCircleStroke = Instance.new("UIStroke")
mouseCircleStroke.Color = Color3.fromRGB(240, 240, 240)
mouseCircleStroke.Transparency = 0.85
mouseCircleStroke.Thickness = 1.2
mouseCircleStroke.Parent = mouseCircle

local function createMouseButtonCap(name, text, size, pos)
	local cap = Instance.new("Frame")
	cap.Name = "MouseCap_" .. name
	cap.Size = size
	cap.Position = pos
	cap.BackgroundColor3 = Color3.fromRGB(8, 8, 8)
	cap.BackgroundTransparency = 0.02
	cap.BorderSizePixel = 0
	cap.Parent = mouseHolder

	local capCorner = Instance.new("UICorner")
	capCorner.CornerRadius = UDim.new(0, 8)
	capCorner.Parent = cap

	local capLabel = Instance.new("TextLabel")
	capLabel.Size = UDim2.fromScale(1, 1)
	capLabel.BackgroundTransparency = 1
	capLabel.Text = text
	capLabel.TextColor3 = Color3.fromRGB(245, 245, 245)
	capLabel.Font = Enum.Font.GothamBold
	capLabel.TextSize = 12
	capLabel.Parent = cap

	return {
		frame = cap,
		label = capLabel,
	}
end

mouseLeftCap = createMouseButtonCap("Left", "LMB", UDim2.fromOffset(58, 24), UDim2.fromOffset(12, 146))
mouseRightCap = createMouseButtonCap("Right", "RMB", UDim2.fromOffset(58, 24), UDim2.fromOffset(120, 146))

mouseDot = Instance.new("Frame")
mouseDot.Size = UDim2.fromOffset(18, 18)
mouseDot.AnchorPoint = Vector2.new(0.5, 0.5)
mouseDot.Position = UDim2.fromOffset(94, 87)
mouseDot.BackgroundColor3 = Color3.fromRGB(255, 40, 40)
mouseDot.BorderSizePixel = 0
mouseDot.Parent = mouseHolder

local mouseDotCorner = Instance.new("UICorner")
mouseDotCorner.CornerRadius = UDim.new(1, 0)
mouseDotCorner.Parent = mouseDot

inputOverlayLabel = Instance.new("TextLabel")
inputOverlayLabel.Size = UDim2.new(1, -12, 0, 18)
inputOverlayLabel.Position = UDim2.fromOffset(8, 4)
inputOverlayLabel.BackgroundTransparency = 1
inputOverlayLabel.TextXAlignment = Enum.TextXAlignment.Left
inputOverlayLabel.TextYAlignment = Enum.TextYAlignment.Top
inputOverlayLabel.Font = Enum.Font.GothamSemibold
inputOverlayLabel.TextSize = 11
inputOverlayLabel.TextColor3 = Color3.fromRGB(208, 220, 242)
inputOverlayLabel.Text = "Playback Input Overlay"
inputOverlayLabel.Parent = inputOverlayFrame

for _, overlayGui in ipairs(inputOverlayFrame:GetDescendants()) do
	if overlayGui:IsA("GuiObject") then
		overlayGui.ZIndex = 16
	end
end
inputOverlayFrame.ZIndex = 15

local loadingOverlay = Instance.new("Frame")
loadingOverlay.Size = UDim2.fromScale(1, 1)
loadingOverlay.BackgroundColor3 = Color3.fromRGB(14, 18, 25)
loadingOverlay.BackgroundTransparency = 0.08
loadingOverlay.BorderSizePixel = 0
loadingOverlay.ZIndex = 100
loadingOverlay.Parent = gui

local loadingPanel = Instance.new("Frame")
loadingPanel.Size = UDim2.fromOffset(440, 150)
loadingPanel.AnchorPoint = Vector2.new(0.5, 0.5)
loadingPanel.Position = UDim2.fromScale(0.5, 0.5)
loadingPanel.BackgroundColor3 = Color3.fromRGB(28, 36, 50)
loadingPanel.BorderSizePixel = 0
loadingPanel.ZIndex = 101
loadingPanel.Parent = loadingOverlay

local loadCorner = Instance.new("UICorner")
loadCorner.CornerRadius = UDim.new(0, 8)
loadCorner.Parent = loadingPanel

local loadStroke = Instance.new("UIStroke")
loadStroke.Color = Color3.fromRGB(129, 166, 230)
loadStroke.Thickness = 1.5
loadStroke.Parent = loadingPanel

local loadTitle = Instance.new("TextLabel")
loadTitle.Size = UDim2.new(1, -24, 0, 38)
loadTitle.Position = UDim2.fromOffset(12, 10)
loadTitle.BackgroundTransparency = 1
loadTitle.Text = "Initializing TAS Tool"
loadTitle.TextColor3 = Color3.fromRGB(230, 238, 255)
loadTitle.Font = Enum.Font.GothamBold
loadTitle.TextSize = 20
loadTitle.TextXAlignment = Enum.TextXAlignment.Left
loadTitle.ZIndex = 101
loadTitle.Parent = loadingPanel

local loadHint = Instance.new("TextLabel")
loadHint.Size = UDim2.new(1, -24, 0, 22)
loadHint.Position = UDim2.fromOffset(12, 52)
loadHint.BackgroundTransparency = 1
loadHint.Text = "Preparing timeline..."
loadHint.TextColor3 = Color3.fromRGB(187, 206, 236)
loadHint.Font = Enum.Font.Gotham
loadHint.TextSize = 14
loadHint.TextXAlignment = Enum.TextXAlignment.Left
loadHint.ZIndex = 101
loadHint.Parent = loadingPanel

local loadPercent = Instance.new("TextLabel")
loadPercent.Size = UDim2.fromOffset(56, 22)
loadPercent.Position = UDim2.new(1, -68, 0, 52)
loadPercent.BackgroundTransparency = 1
loadPercent.Text = "0%"
loadPercent.TextColor3 = Color3.fromRGB(201, 219, 248)
loadPercent.Font = Enum.Font.GothamSemibold
loadPercent.TextSize = 14
loadPercent.TextXAlignment = Enum.TextXAlignment.Right
loadPercent.ZIndex = 101
loadPercent.Parent = loadingPanel

local loadTrack = Instance.new("Frame")
loadTrack.Size = UDim2.new(1, -24, 0, 14)
loadTrack.Position = UDim2.fromOffset(12, 94)
loadTrack.BackgroundColor3 = Color3.fromRGB(58, 70, 92)
loadTrack.BorderSizePixel = 0
loadTrack.ZIndex = 101
loadTrack.Parent = loadingPanel

local loadTrackCorner = Instance.new("UICorner")
loadTrackCorner.CornerRadius = UDim.new(0, 7)
loadTrackCorner.Parent = loadTrack

local loadFill = Instance.new("Frame")
loadFill.Size = UDim2.fromScale(0, 1)
loadFill.BackgroundColor3 = Color3.fromRGB(139, 201, 255)
loadFill.BorderSizePixel = 0
loadFill.ZIndex = 102
loadFill.Parent = loadTrack

local loadFillCorner = Instance.new("UICorner")
loadFillCorner.CornerRadius = UDim.new(0, 7)
loadFillCorner.Parent = loadFill

local function playIntroAnimation()
	mainFrame.Position = UDim2.fromOffset(16, -360)
	mainFrame.BackgroundTransparency = 0.35
	mainFrame.Rotation = -2
	local hints = {
		"Preparing timeline...",
		"Configuring playback core...",
		"Syncing interface...",
		"Almost ready...",
	}

	local fillTween = TweenService:Create(
		loadFill,
		TweenInfo.new(1.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.fromScale(1, 1) }
	)
	fillTween:Play()

	local startTick = tick()
	while fillTween.PlaybackState == Enum.PlaybackState.Playing do
		local progress = math.clamp((tick() - startTick) / 1.05, 0, 1)
		local idx = math.clamp(math.floor(progress * #hints) + 1, 1, #hints)
		loadHint.Text = hints[idx]
		loadPercent.Text = tostring(math.floor(progress * 100)) .. "%"
		task.wait(0.03)
	end
	loadPercent.Text = "100%"

	local panelTween = TweenService:Create(
		mainFrame,
		TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.fromOffset(16, 12), BackgroundTransparency = 0, Rotation = 0 }
	)
	panelTween:Play()

	local overlayFade = TweenService:Create(
		loadingOverlay,
		TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	overlayFade:Play()
	overlayFade.Completed:Wait()
	loadingOverlay:Destroy()
end

local function cyclePlaybackMode()
	local nextMode = playbackMode
	if playbackMode == "ghost" then
		nextMode = "frameblend"
	elseif playbackMode == "frameblend" then
		nextMode = "smooth"
	else
		nextMode = "ghost"
	end
	playbackMode = nextMode
	if mode == "play" then
		setCameraPlaybackMode(true)
		resetCameraSmoothingClock()
		applyPlaybackLock()
	end
	log("Playback mode set to " .. playbackMode)
	refreshSettingsUI()
end

local function cycleCameraMode()
	if cameraMode == "exact" then
		cameraMode = "smooth"
	else
		cameraMode = "exact"
	end
	if mode == "play" then
		resetCameraSmoothingClock()
	end
	log("Camera mode set to " .. cameraMode)
	refreshSettingsUI()
end

local function cycleRecordMode()
	if recordMode == "replace" then
		recordMode = "append"
	else
		recordMode = "replace"
	end
	log("Record mode set to " .. recordMode)
	refreshSettingsUI()
end

connect(settingsInputsBtn.MouseButton1Click, function()
	virtualInputPlaybackEnabled = not virtualInputPlaybackEnabled
	if not virtualInputPlaybackEnabled then
		releaseAllVirtualInputs()
	end
	log("Virtual input playback set to " .. (virtualInputPlaybackEnabled and "on" or "off"))
	refreshSettingsUI()
end)

connect(settingsOverlayBtn.MouseButton1Click, function()
	inputOverlayEnabled = not inputOverlayEnabled
	if not inputOverlayEnabled then
		updatePlaybackInputOverlay(nil)
	end
	log("Input overlay set to " .. (inputOverlayEnabled and "on" or "off"))
	refreshSettingsUI()
end)

connect(settingsPlaybackModeBtn.MouseButton1Click, cyclePlaybackMode)
connect(settingsCameraModeBtn.MouseButton1Click, cycleCameraMode)

connect(settingsRecordNoColBtn.MouseButton1Click, function()
	recordNoCollisionEnabled = not recordNoCollisionEnabled
	if not recordNoCollisionEnabled then
		clearRecordNoCollision()
	elseif mode == "record" then
		applyRecordNoCollision()
	end
	log("Record no-collision set to " .. (recordNoCollisionEnabled and "on" or "off"))
	refreshSettingsUI()
end)

connect(settingsRecordModeBtn.MouseButton1Click, cycleRecordMode)

connect(settingsPlaySpeedBtn.MouseButton1Click, function()
	local nextSpeed = playbackSpeed + 0.25
	if nextSpeed > 2 then
		nextSpeed = 0.5
	end
	playbackSpeed = nextSpeed
	log("Playback speed set to " .. string.format("%.2f", playbackSpeed))
	refreshSettingsUI()
end)

connect(settingsToggleBtn.MouseButton1Click, function()
	settingsOpen = not settingsOpen
	applySettingsVisibility()
end)

local function getUIParent()
	if gethui then
		local ok, h = pcall(gethui)
		if ok and h then
			return h
		end
	end
	return game:GetService("CoreGui")
end

gui.Parent = getUIParent()
playIntroAnimation()
applySettingsVisibility()
refreshSettingsUI()

updateUI = function()
	local newStatusText = statusText()
	if label.Text ~= newStatusText then
		label.Text = newStatusText
	end
	if shiftLockIndicator then
		local shiftOn = isShiftLockActive()
		if lastShiftIndicatorState == nil or shiftOn ~= lastShiftIndicatorState then
			shiftLockIndicator.Text = "ShiftLock REC: " .. (shiftOn and "ON" or "OFF")
			if shiftOn then
				shiftLockIndicator.BackgroundColor3 = Color3.fromRGB(52, 112, 82)
				shiftLockIndicator.TextColor3 = Color3.fromRGB(210, 255, 231)
			else
				shiftLockIndicator.BackgroundColor3 = Color3.fromRGB(90, 63, 63)
				shiftLockIndicator.TextColor3 = Color3.fromRGB(255, 226, 226)
			end
			lastShiftIndicatorState = shiftOn
		end
	end
	if inputOverlayFrame then
		local shouldShowOverlay = (mode == "play" and inputOverlayEnabled)
		if inputOverlayFrame.Visible ~= shouldShowOverlay then
			inputOverlayFrame.Visible = shouldShowOverlay
		end
	end
	local shouldEnableGui = (uiVisible and not forceHideUI)
	if gui.Enabled ~= shouldEnableGui then
		gui.Enabled = shouldEnableGui
	end
end

local function getCurrentFrameIndex()
	if #frames == 0 then
		return 0
	end
	if mode == "play" then
		return clampIndex(playIndex)
	end
	return #frames
end

local function setCheckpoint(name, index)
	name = tostring(name or QUICK_CP_NAME)
	if #name > 64 then
		name = string.sub(name, 1, 64)
	end
	local resolved = index and clampIndex(index) or getCurrentFrameIndex()
	if resolved < 1 or resolved > #frames then
		log("Cannot set checkpoint '" .. name .. "': invalid frame")
		return false
	end
	checkpoints[name] = resolved
	log("Checkpoint '" .. name .. "' = frame " .. tostring(resolved))
	return true
end

local function gotoCheckpoint(name)
	name = tostring(name or QUICK_CP_NAME)
	local idxRaw = checkpoints[name]
	if idxRaw == nil then
		log("Checkpoint '" .. name .. "' not found")
		return false
	end
	local idx = tonumber(idxRaw)
	if not isFiniteNumber(idx) then
		checkpoints[name] = nil
		log("Checkpoint '" .. name .. "' is invalid and was removed")
		return false
	end
	playIndex = clampIndex(idx)
	applyFrame(playIndex)
	log("Goto checkpoint '" .. name .. "' -> frame " .. tostring(playIndex))
	return true
end

local function captureFrame(captureDt)
	local hum, hrp = humanoidAndRoot()
	if not hrp or not hum then
		return
	end

	local shiftNow = isShiftLockActive()
	local nextFrameIndex = #frames + 1
	if lastRecordedShiftLockState ~= nil and shiftNow ~= lastRecordedShiftLockState then
		log("ShiftLock " .. (shiftNow and "ON" or "OFF") .. " @ frame " .. tostring(nextFrameIndex))
	end
	lastRecordedShiftLockState = shiftNow

	local frame = {
		dt = round(math.max(1 / 1000, captureDt or timelineStep), 5),
		root = roundArray(cfToTable(hrp.CFrame), CONFIG.ROUND_DIGITS),
		vel = roundArray(v3ToTable(hrp.AssemblyLinearVelocity), CONFIG.ROUND_DIGITS),
		rotvel = roundArray(v3ToTable(hrp.AssemblyAngularVelocity), CONFIG.ROUND_DIGITS),
		cam = roundArray(cfToTable(camera.CFrame), CONFIG.ROUND_DIGITS),
		-- Relative camera offset improves blended camera/player alignment.
		cam_local = roundArray(cfToTable(hrp.CFrame:ToObjectSpace(camera.CFrame)), CONFIG.ROUND_DIGITS),
		fov = round(camera.FieldOfView, CONFIG.ROUND_DIGITS),
		hstate = hum:GetState().Name,
		shiftlock = shiftNow,
		keys = keysSnapshot(),
	}
	table.insert(frames, frame)
	playIndex = #frames
end

local function trimFutureFrames()
	local current = clampIndex(playIndex)
	if current >= #frames then
		lastTrimmedCount = 0
		return 0
	end
	local trimmed = #frames - current
	for i = #frames, current + 1, -1 do
		frames[i] = nil
	end
	lastTrimmedCount = trimmed
	log("Trimmed " .. tostring(trimmed) .. " frame(s), now at frame " .. tostring(current))
	return trimmed
end

local function setFrozen(newFrozen)
	if frozen == newFrozen then
		return
	end

	if mode == "record" then
		if newFrozen then
			if #frames > 0 then
				playIndex = clampIndex(playIndex)
			else
				playIndex = 1
			end
			recordAccumulator = 0
			applyRecordFreezeLock()
		else
			trimFutureFrames()
			clearRecordFreezeLock()
			recordAccumulator = 0
			lastRecordClock = tick()
			local hum, hrp = humanoidAndRoot()
			if hrp then
				-- Safety unstick: explicitly release anchor and resume gravity state.
				hrp.Anchored = false
			end
			if hum then
				hum:ChangeState(Enum.HumanoidStateType.Freefall)
			end
			playIndex = #frames
		end
	end

	frozen = newFrozen

	if mode == "play" then
		setCameraPlaybackMode(true)
		resetCameraSmoothingClock()
		applyPlaybackLock()
	end
end

local function startRecord()
	mode = "record"
	setFrozen(false)
	seekDir = 0
	playbackAccumulator = 0
	recordAccumulator = timelineStep
	lastRecordClock = tick()
	lastPlaybackClock = 0
	releaseAllVirtualInputs()
	updatePlaybackInputOverlay(nil)
	clearPlaybackLock()
	clearRecordFreezeLock()
	clearRecordNoCollision()
	setCameraPlaybackMode(false)
	applyRecordNoCollision()
	shiftLockState = isMouseLockCenter()
	lastRecordedShiftLockState = shiftLockState
	lastAppliedHumanoidState = nil
	lastPhysicsJumpHeld = false

	if recordMode == "replace" then
		frames = {}
		checkpoints = {}
		playIndex = 1
		lastTrimmedCount = 0
	else
		playIndex = math.max(1, #frames)
	end

	log("Recording started (" .. recordMode .. ")")
end

local function stopRecord()
	if mode ~= "record" then
		return
	end
	setFrozen(false)
	clearRecordFreezeLock()
	clearRecordNoCollision()
	recordAccumulator = 0
	lastRecordClock = 0
	lastRecordedShiftLockState = nil
	lastAppliedHumanoidState = nil
	lastPhysicsJumpHeld = false
	updatePlaybackInputOverlay(nil)
	mode = "idle"
	log("Recording stopped. Frames: " .. tostring(#frames))
end

local function startPlay()
	if #frames == 0 then
		log("No frames loaded/recorded")
		return
	end
	mode = "play"
	setFrozen(false)
	seekDir = 0
	playIndex = 1
	lastTrimmedCount = 0
	playbackAccumulator = timelineStep
	recordAccumulator = 0
	lastPlaybackClock = tick()
	lastRecordClock = 0
	lastAppliedHumanoidState = nil
	lastPhysicsJumpHeld = false
	releaseAllVirtualInputs()
	updatePlaybackInputOverlay(nil)
	clearRecordNoCollision()
	setCameraPlaybackMode(true)
	resetCameraSmoothingClock()
	applyPlaybackLock()
	local warmupApplied = applyFrame(playIndex)
	if warmupApplied then
		playIndex = math.min(playIndex + 1, #frames + 1)
	else
		playIndex = 1
	end
	log("Playback started")
end

local function stopPlay()
	if mode ~= "play" then
		return
	end
	mode = "idle"
	setFrozen(false)
	seekDir = 0
	playbackAccumulator = 0
	recordAccumulator = 0
	lastPlaybackClock = 0
	lastRecordClock = 0
	lastAppliedHumanoidState = nil
	lastPhysicsJumpHeld = false
	releaseAllVirtualInputs()
	updatePlaybackInputOverlay(nil)
	clearPlaybackLock()
	setCameraPlaybackMode(false)
	resetCameraSmoothingClock()
	log("Playback stopped")
end

local function saveReplay()
	ensureFolder()
	local payload = {
		version = "0.9.0-rewrite",
		placeId = game.PlaceId,
		savedAtUnix = os.time(),
		frames = frames,
		checkpoints = checkpoints,
	}
	writefile(replayPath, HttpService:JSONEncode(payload))
	log("Saved: " .. replayPath .. " | Frames: " .. tostring(#frames))
end

local function loadReplay()
	if mode == "play" then
		stopPlay()
	elseif mode == "record" then
		stopRecord()
	end

	if not isfile(replayPath) then
		log("Replay file not found: " .. replayPath)
		return
	end

	local ok, data = pcall(function()
		return HttpService:JSONDecode(readfile(replayPath))
	end)
	if not ok or type(data) ~= "table" then
		log("Invalid replay JSON")
		return
	end

	local normalized, droppedFrames = normalizeFrames(data.frames)
	if #normalized == 0 then
		log("Replay loaded but no valid frames found")
		return
	end

	frames = normalized
	local loadedCheckpoints, droppedCheckpoints = sanitizeCheckpoints(data.checkpoints, #frames)
	checkpoints = loadedCheckpoints
	playIndex = 1
	lastTrimmedCount = 0
	lastAppliedHumanoidState = nil
	lastPhysicsJumpHeld = false
	log("Loaded replay. Frames: " .. tostring(#frames))
	if droppedFrames > 0 then
		log("Dropped invalid frames: " .. tostring(droppedFrames))
	end
	if droppedCheckpoints > 0 then
		log("Dropped invalid checkpoints: " .. tostring(droppedCheckpoints))
	end
end

local function eraseReplay()
	frames = {}
	checkpoints = {}
	playIndex = 1
	setFrozen(false)
	seekDir = 0
	mode = "idle"
	playbackAccumulator = 0
	lastAppliedHumanoidState = nil
	lastPhysicsJumpHeld = false
	clearPlaybackLock()
	clearRecordFreezeLock()
	clearRecordNoCollision()
	setCameraPlaybackMode(false)
	saveReplay()
	log("Replay erased")
end

local function runSelfCheck()
	local frameCount = #frames
	if frameCount == 0 then
		log("Selfcheck: no frames loaded/recorded")
		return
	end

	local badRoot = 0
	local badCam = 0
	local badVel = 0
	local badRotVel = 0
	local badDt = 0
	local badFov = 0
	local badKeys = 0
	for _, frame in ipairs(frames) do
		if not tableToCf(frame.root) then
			badRoot = badRoot + 1
		end
		if not tableToCf(frame.cam) then
			badCam = badCam + 1
		end
		if type(frame.vel) ~= "table" or #frame.vel < 3 then
			badVel = badVel + 1
		end
		if type(frame.rotvel) ~= "table" or #frame.rotvel < 3 then
			badRotVel = badRotVel + 1
		end
		local dt = tonumber(frame.dt)
		if (not isFiniteNumber(dt)) or dt <= 0 or dt > 1 then
			badDt = badDt + 1
		end
		local fov = tonumber(frame.fov)
		if (not isFiniteNumber(fov)) or fov < 1 or fov > 120 then
			badFov = badFov + 1
		end
		if type(frame.keys) ~= "table" then
			badKeys = badKeys + 1
		end
	end

	local _, droppedCheckpoints = sanitizeCheckpoints(checkpoints, frameCount)
	log(string.format(
		"Selfcheck: frames=%d | badRoot=%d badCam=%d badVel=%d badRotVel=%d badDt=%d badFov=%d badKeys=%d badCp=%d",
		frameCount,
		badRoot,
		badCam,
		badVel,
		badRotVel,
		badDt,
		badFov,
		badKeys,
		droppedCheckpoints
	))
end

local function parseCommandArgs(raw)
	local out = {}
	local current = {}
	local inQuote = false
	local quoteChar = nil
	local escaped = false
	local text = tostring(raw or "")

	for i = 1, #text do
		local ch = string.sub(text, i, i)
		if escaped then
			table.insert(current, ch)
			escaped = false
		elseif ch == "\\" then
			escaped = true
		elseif inQuote then
			if ch == quoteChar then
				inQuote = false
				quoteChar = nil
			else
				table.insert(current, ch)
			end
		elseif ch == "\"" or ch == "'" then
			inQuote = true
			quoteChar = ch
		elseif string.match(ch, "%s") then
			if #current > 0 then
				table.insert(out, table.concat(current))
				current = {}
			end
		else
			table.insert(current, ch)
		end
	end

	if escaped then
		table.insert(current, "\\")
	end
	if #current > 0 then
		table.insert(out, table.concat(current))
	end
	return out
end

local function pushCommandHistory(raw)
	local item = tostring(raw or "")
	item = string.gsub(item, "^%s*(.-)%s*$", "%1")
	if item == "" then
		return
	end
	if commandHistory[#commandHistory] == item then
		commandHistoryCursor = #commandHistory + 1
		return
	end
	table.insert(commandHistory, item)
	while #commandHistory > COMMAND_HISTORY_LIMIT do
		table.remove(commandHistory, 1)
	end
	commandHistoryCursor = #commandHistory + 1
end

local function recallCommandHistory(delta)
	if #commandHistory == 0 then
		return ""
	end
	if commandHistoryCursor < 1 then
		commandHistoryCursor = #commandHistory + 1
	end
	commandHistoryCursor = math.clamp(commandHistoryCursor + delta, 1, #commandHistory + 1)
	if commandHistoryCursor > #commandHistory then
		return ""
	end
	return commandHistory[commandHistoryCursor]
end

local function frameDistance(a, b)
	local cfA = a and tableToCf(a.root)
	local cfB = b and tableToCf(b.root)
	if not cfA or not cfB then
		return 0
	end
	return (cfB.Position - cfA.Position).Magnitude
end

local function buildReplayStats()
	local stats = {
		frames = #frames,
		duration = #frames * timelineStep,
		distance = 0,
		shiftLockOn = 0,
		shiftLockTransitions = 0,
		keySamples = 0,
		uniqueKeys = {},
		minFov = nil,
		maxFov = nil,
		maxSpeed = 0,
		badFrames = 0,
	}

	local lastShift = nil
	for i, frame in ipairs(frames) do
		local normalized = normalizeFrame(frame)
		if not normalized then
			stats.badFrames = stats.badFrames + 1
		end

		if i > 1 then
			stats.distance = stats.distance + frameDistance(frames[i - 1], frame)
		end

		local shiftOn = frame.shiftlock == true
		if shiftOn then
			stats.shiftLockOn = stats.shiftLockOn + 1
		end
		if lastShift ~= nil and lastShift ~= shiftOn then
			stats.shiftLockTransitions = stats.shiftLockTransitions + 1
		end
		lastShift = shiftOn

		if type(frame.keys) == "table" then
			stats.keySamples = stats.keySamples + #frame.keys
			for _, keyName in ipairs(frame.keys) do
				if type(keyName) == "string" then
					stats.uniqueKeys[keyName] = true
				end
			end
		end

		local fov = tonumber(frame.fov)
		if isFiniteNumber(fov) then
			stats.minFov = stats.minFov and math.min(stats.minFov, fov) or fov
			stats.maxFov = stats.maxFov and math.max(stats.maxFov, fov) or fov
		end

		local vel = tableToV3(frame.vel)
		stats.maxSpeed = math.max(stats.maxSpeed, vel.Magnitude)
	end

	local uniqueCount = 0
	for _ in pairs(stats.uniqueKeys) do
		uniqueCount = uniqueCount + 1
	end
	stats.uniqueKeyCount = uniqueCount
	stats.avgKeySamples = stats.frames > 0 and (stats.keySamples / stats.frames) or 0
	stats.minFov = stats.minFov or 0
	stats.maxFov = stats.maxFov or 0
	return stats
end

local function logReplayStats()
	local stats = buildReplayStats()
	log(string.format(
		"Stats: frames=%d duration=%.2fs distance=%.2f maxSpeed=%.2f badFrames=%d",
		stats.frames,
		stats.duration,
		stats.distance,
		stats.maxSpeed,
		stats.badFrames
	))
	log(string.format(
		"Stats: shiftLockOn=%d transitions=%d uniqueKeys=%d avgKeys=%.2f fov=%.1f..%.1f checkpoints=%d",
		stats.shiftLockOn,
		stats.shiftLockTransitions,
		stats.uniqueKeyCount,
		stats.avgKeySamples,
		stats.minFov,
		stats.maxFov,
		(function()
			local count = 0
			for _ in pairs(checkpoints) do
				count = count + 1
			end
			return count
		end)()
	))
end

local function apiAvailable(name)
	local env
	pcall(function()
		env = getfenv()
	end)
	if type(env) == "table" and type(env[name]) == "function" then
		return true
	end
	if getgenv then
		local ok, genv = pcall(getgenv)
		if ok and type(genv) == "table" and type(genv[name]) == "function" then
			return true
		end
	end
	return type(_G[name]) == "function"
end

local function runDiagnostics()
	local checks = {
		{ "HttpService", HttpService ~= nil },
		{ "UserInputService", UIS ~= nil },
		{ "RunService", RunService ~= nil },
		{ "VirtualInputManager", VirtualInputManager ~= nil },
		{ "isfile", apiAvailable("isfile") },
		{ "readfile", apiAvailable("readfile") },
		{ "writefile", apiAvailable("writefile") },
		{ "isfolder", apiAvailable("isfolder") },
		{ "makefolder", apiAvailable("makefolder") },
		{ "runtime singleton", rawget(_G, RUNTIME_KEY) == runtime },
		{ "ui alive", gui ~= nil and gui.Parent ~= nil },
		{ "timeline 60fps", TIMELINE_FPS == 60 and math.abs(timelineStep - (1 / 60)) < 0.000001 },
		{ "playback mode valid", playbackMode == "ghost" or playbackMode == "frameblend" or playbackMode == "smooth" },
		{ "camera mode valid", cameraMode == "exact" or cameraMode == "smooth" },
	}

	local passed = 0
	for _, check in ipairs(checks) do
		if check[2] then
			passed = passed + 1
		else
			log("Diagnostic failed: " .. tostring(check[1]))
		end
	end
	log("Diagnostics: " .. tostring(passed) .. "/" .. tostring(#checks) .. " passed")
	if #frames > 0 then
		runSelfCheck()
		logReplayStats()
	end
end

local function setAdminOpen(open)
	adminOpen = open == true
	if adminPanel then
		adminPanel.Visible = adminOpen
	end
	if adminToggleBtn then
		adminToggleBtn.BackgroundColor3 = adminOpen and Color3.fromRGB(72, 121, 87) or Color3.fromRGB(56, 91, 120)
	end
	if refreshAdminPanel then
		refreshAdminPanel()
	end
end

local function adminSaveHumanoidDefaults(hum)
	if not hum then
		return
	end
	adminState.restore.walkSpeed = adminState.restore.walkSpeed or hum.WalkSpeed
	adminState.restore.jumpPower = adminState.restore.jumpPower or hum.JumpPower
	adminState.restore.jumpHeight = adminState.restore.jumpHeight or hum.JumpHeight
	adminState.restore.hipHeight = adminState.restore.hipHeight or hum.HipHeight
end

local function adminCaptureLighting()
	if adminState.restore.lighting then
		return
	end
	adminState.restore.lighting = {
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		Brightness = Lighting.Brightness,
		ClockTime = Lighting.ClockTime,
		FogEnd = Lighting.FogEnd,
		FogStart = Lighting.FogStart,
		GlobalShadows = Lighting.GlobalShadows,
		ExposureCompensation = Lighting.ExposureCompensation,
	}
end

local function adminRestoreLighting()
	local saved = adminState.restore.lighting
	if not saved then
		return
	end
	for prop, value in pairs(saved) do
		pcall(function()
			Lighting[prop] = value
		end)
	end
	adminState.fullbright = false
end

local function adminNotify(text)
	log("[Admin] " .. tostring(text))
	pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = "TAS Lite Admin",
			Text = tostring(text),
			Duration = 3,
		})
	end)
end

local function adminCharacterParts()
	local c = char()
	local parts = {}
	if not c then
		return parts
	end
	for _, inst in ipairs(c:GetDescendants()) do
		if inst:IsA("BasePart") then
			table.insert(parts, inst)
		end
	end
	return parts
end

local function adminSetNoclip(enabled)
	adminState.noclip = enabled == true
	if adminState.noclip then
		for _, part in ipairs(adminCharacterParts()) do
			if adminState.noclipParts[part] == nil then
				adminState.noclipParts[part] = part.CanCollide
			end
			part.CanCollide = false
		end
	else
		for part, oldValue in pairs(adminState.noclipParts) do
			if part and part.Parent then
				part.CanCollide = oldValue == true
			end
		end
		adminState.noclipParts = {}
	end
end

local function adminSetFly(enabled)
	adminState.fly = enabled == true
	local hum, hrp = humanoidAndRoot()
	if hum then
		adminSaveHumanoidDefaults(hum)
		hum.PlatformStand = adminState.fly
		hum.AutoRotate = not adminState.fly
	end
	if hrp and not adminState.fly then
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
	end
end

local function adminSetGod(enabled)
	adminState.god = enabled == true
	local hum = humanoidAndRoot()
	if hum then
		adminSaveHumanoidDefaults(hum)
		if adminState.god then
			hum.MaxHealth = math.max(hum.MaxHealth, 1000000)
			hum.Health = hum.MaxHealth
			if not adminState.forceField then
				local ff = Instance.new("ForceField")
				ff.Name = "TASLiteLocalAdminForceField"
				ff.Visible = false
				ff.Parent = char()
				adminState.forceField = ff
			end
		else
			if adminState.forceField then
				adminState.forceField:Destroy()
				adminState.forceField = nil
			end
			if hum.MaxHealth > 10000 then
				hum.MaxHealth = 100
				hum.Health = math.min(hum.Health, hum.MaxHealth)
			end
		end
	end
end

local function adminSetFullbright(enabled)
	adminCaptureLighting()
	adminState.fullbright = enabled == true
	if adminState.fullbright then
		Lighting.Ambient = Color3.fromRGB(255, 255, 255)
		Lighting.OutdoorAmbient = Color3.fromRGB(255, 255, 255)
		Lighting.Brightness = 3
		Lighting.ClockTime = 12
		Lighting.FogEnd = 100000
		Lighting.FogStart = 0
		Lighting.GlobalShadows = false
		Lighting.ExposureCompensation = 0
	else
		adminRestoreLighting()
	end
end

local function adminClearEsp()
	for _, obj in pairs(adminState.espObjects) do
		if obj then
			obj:Destroy()
		end
	end
	adminState.espObjects = {}
end

local function adminClearNames()
	for _, obj in pairs(adminState.nameObjects) do
		if obj then
			obj:Destroy()
		end
	end
	adminState.nameObjects = {}
end

local function adminSetEsp(enabled)
	adminState.esp = enabled == true
	if not adminState.esp then
		adminClearEsp()
	end
end

local function adminSetNames(enabled)
	adminState.names = enabled == true
	if not adminState.names then
		adminClearNames()
	end
end

local function adminRefreshEsp()
	if not adminState.esp then
		return
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= player and plr.Character then
			local existing = adminState.espObjects[plr]
			if not existing or existing.Parent ~= plr.Character then
				if existing then
					existing:Destroy()
				end
				local h = Instance.new("Highlight")
				h.Name = "TASLiteAdminHighlight"
				h.FillColor = Color3.fromRGB(68, 190, 255)
				h.OutlineColor = Color3.fromRGB(255, 255, 255)
				h.FillTransparency = 0.72
				h.OutlineTransparency = 0.08
				h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				h.Parent = plr.Character
				adminState.espObjects[plr] = h
			end
		end
	end
	for plr, obj in pairs(adminState.espObjects) do
		if (not plr.Parent) or (not plr.Character) or obj.Parent ~= plr.Character then
			if obj then
				obj:Destroy()
			end
			adminState.espObjects[plr] = nil
		end
	end
end

local function adminRefreshNames()
	if not adminState.names then
		return
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= player and plr.Character then
			local head = plr.Character:FindFirstChild("Head")
			if head then
				local existing = adminState.nameObjects[plr]
				if not existing or existing.Parent ~= head then
					if existing then
						existing:Destroy()
					end
					local bill = Instance.new("BillboardGui")
					bill.Name = "TASLiteAdminName"
					bill.AlwaysOnTop = true
					bill.Size = UDim2.fromOffset(180, 32)
					bill.StudsOffset = Vector3.new(0, 2.8, 0)
					bill.Parent = head

					local txt = Instance.new("TextLabel")
					txt.Size = UDim2.fromScale(1, 1)
					txt.BackgroundTransparency = 1
					txt.Text = plr.DisplayName .. " @" .. plr.Name
					txt.TextColor3 = Color3.fromRGB(255, 255, 255)
					txt.TextStrokeTransparency = 0.25
					txt.Font = Enum.Font.GothamBold
					txt.TextSize = 13
					txt.Parent = bill
					adminState.nameObjects[plr] = bill
				end
			end
		end
	end
	for plr, obj in pairs(adminState.nameObjects) do
		if (not plr.Parent) or (not obj.Parent) then
			if obj then
				obj:Destroy()
			end
			adminState.nameObjects[plr] = nil
		end
	end
end

local function adminCreateTrail()
	local _, hrp = humanoidAndRoot()
	if not hrp or adminState.trailObjects.trail then
		return
	end
	local a0 = Instance.new("Attachment")
	a0.Name = "TASLiteTrailA0"
	a0.Position = Vector3.new(0, 1.5, 0)
	a0.Parent = hrp
	local a1 = Instance.new("Attachment")
	a1.Name = "TASLiteTrailA1"
	a1.Position = Vector3.new(0, -1.5, 0)
	a1.Parent = hrp
	local trail = Instance.new("Trail")
	trail.Name = "TASLiteAdminTrail"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 1.2
	trail.MinLength = 0.05
	trail.LightEmission = 0.65
	trail.Color = ColorSequence.new(Color3.fromRGB(80, 190, 255), Color3.fromRGB(190, 255, 220))
	trail.Transparency = NumberSequence.new(0.12, 1)
	trail.Parent = hrp
	adminState.trailObjects = { a0 = a0, a1 = a1, trail = trail }
end

local function adminClearTrail()
	for _, obj in pairs(adminState.trailObjects) do
		if obj then
			obj:Destroy()
		end
	end
	adminState.trailObjects = {}
end

local function adminSetTrails(enabled)
	adminState.trails = enabled == true
	if adminState.trails then
		adminCreateTrail()
	else
		adminClearTrail()
	end
end

local function adminSetXray(enabled)
	adminState.xray = enabled == true
	if adminState.xray then
		local c = char()
		local count = 0
		for _, inst in ipairs(workspace:GetDescendants()) do
			if count >= 1600 then
				break
			end
			if inst:IsA("BasePart") and (not c or not inst:IsDescendantOf(c)) and inst.Transparency < 0.65 then
				if adminState.xrayParts[inst] == nil then
					adminState.xrayParts[inst] = inst.Transparency
				end
				inst.Transparency = 0.65
				count = count + 1
			end
		end
	else
		for part, oldTransparency in pairs(adminState.xrayParts) do
			if part and part.Parent then
				part.Transparency = oldTransparency
			end
		end
		adminState.xrayParts = {}
	end
end

local function adminSetFloatPad(enabled)
	if enabled then
		local _, hrp = humanoidAndRoot()
		if not hrp then
			return false
		end
		if adminState.floatPad and adminState.floatPad.Parent then
			adminState.floatPad:Destroy()
		end
		local pad = Instance.new("Part")
		pad.Name = "TASLiteAdminFloatPad"
		pad.Size = Vector3.new(8, 0.5, 8)
		pad.Anchored = true
		pad.CanCollide = true
		pad.CanTouch = false
		pad.Material = Enum.Material.Neon
		pad.Color = Color3.fromRGB(78, 181, 255)
		pad.Transparency = 0.18
		pad.CFrame = CFrame.new(hrp.Position - Vector3.new(0, 3.4, 0))
		pad.Parent = workspace
		adminState.floatPad = pad
		return true
	end
	if adminState.floatPad then
		adminState.floatPad:Destroy()
		adminState.floatPad = nil
	end
	return true
end

local function adminParseColor(args, startIndex)
	local r = tonumber(args[startIndex])
	local g = tonumber(args[startIndex + 1])
	local b = tonumber(args[startIndex + 2])
	if not r or not g or not b then
		return nil
	end
	if r > 1 or g > 1 or b > 1 then
		r = r / 255
		g = g / 255
		b = b / 255
	end
	return Color3.new(math.clamp(r, 0, 1), math.clamp(g, 0, 1), math.clamp(b, 0, 1))
end

local function adminStorePreviousPosition()
	local _, hrp = humanoidAndRoot()
	if hrp then
		adminPreviousPosition = hrp.CFrame
	end
end

local function adminTeleportTo(cf)
	local _, hrp = humanoidAndRoot()
	if not hrp or not cf then
		return false
	end
	adminStorePreviousPosition()
	hrp.CFrame = cf
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	return true
end

local function adminFindPlayer(query)
	local needle = string.lower(tostring(query or ""))
	if needle == "" or needle == "self" or needle == "me" then
		return player
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		local name = string.lower(plr.Name)
		local display = string.lower(plr.DisplayName)
		if string.sub(name, 1, #needle) == needle or string.sub(display, 1, #needle) == needle then
			return plr
		end
	end
	return nil
end

local function adminGetPlayerRoot(plr)
	if not plr or not plr.Character then
		return nil
	end
	return plr.Character:FindFirstChild("HumanoidRootPart")
end

local function adminSetHumanoidNumber(prop, value, minValue, maxValue)
	local hum = humanoidAndRoot()
	if not hum then
		return false, "no humanoid"
	end
	adminSaveHumanoidDefaults(hum)
	local n = tonumber(value)
	if not n then
		return false, "invalid number"
	end
	if minValue then
		n = math.max(minValue, n)
	end
	if maxValue then
		n = math.min(maxValue, n)
	end
	hum[prop] = n
	return true, n
end

local function adminBoolArg(value, current)
	local v = string.lower(tostring(value or "toggle"))
	if v == "on" or v == "true" or v == "1" or v == "yes" then
		return true
	end
	if v == "off" or v == "false" or v == "0" or v == "no" then
		return false
	end
	return not current
end

local function adminCommandStatusText()
	local hum, hrp = humanoidAndRoot()
	local posText = "no root"
	if hrp then
		local p = hrp.Position
		posText = string.format("%.1f %.1f %.1f", p.X, p.Y, p.Z)
	end
	local humText = "no humanoid"
	if hum then
		humText = string.format("WS %.1f JP %.1f HP %.0f/%.0f", hum.WalkSpeed, hum.JumpPower, hum.Health, hum.MaxHealth)
	end
	return string.format(
		"%s | Pos %s\nnoclip=%s fly=%s god=%s infjump=%s esp=%s names=%s fullbright=%s",
		humText,
		posText,
		tostring(adminState.noclip),
		tostring(adminState.fly),
		tostring(adminState.god),
		tostring(adminState.infJump),
		tostring(adminState.esp),
		tostring(adminState.names),
		tostring(adminState.fullbright)
	)
end

refreshAdminPanel = function()
	if adminStatusLabel then
		adminStatusLabel.Text = adminCommandStatusText()
	end
	if adminCommandList and adminListLayout then
		adminCommandList.CanvasSize = UDim2.fromOffset(0, adminListLayout.AbsoluteContentSize.Y + 16)
	end
end

local function registerAdminCommand(def)
	if type(def) ~= "table" or type(def.name) ~= "string" or type(def.run) ~= "function" then
		return
	end
	def.category = def.category or "General"
	def.usage = def.usage or def.name
	def.description = def.description or ""
	adminCommands[def.name] = def
	table.insert(adminCommandOrder, def.name)
	adminAliases[def.name] = def.name
	if type(def.aliases) == "table" then
		for _, alias in ipairs(def.aliases) do
			if type(alias) == "string" and alias ~= "" then
				adminAliases[alias] = def.name
			end
		end
	end
end

local function adminUsage(name)
	local resolved = adminAliases[string.lower(tostring(name or ""))]
	local def = resolved and adminCommands[resolved]
	if def then
		adminNotify("Usage: " .. def.usage)
	end
end

local function adminCommandNamesByCategory()
	local categories = {}
	for _, name in ipairs(adminCommandOrder) do
		local def = adminCommands[name]
		if def then
			categories[def.category] = categories[def.category] or {}
			table.insert(categories[def.category], def)
		end
	end
	return categories
end

local function adminListCommands(categoryFilter)
	local filter = string.lower(tostring(categoryFilter or ""))
	local count = 0
	local categories = adminCommandNamesByCategory()
	for category, defs in pairs(categories) do
		if filter == "" or string.find(string.lower(category), filter, 1, true) then
			table.sort(defs, function(a, b)
				return a.name < b.name
			end)
			local names = {}
			for _, def in ipairs(defs) do
				table.insert(names, def.name)
				count = count + 1
			end
			log("[Admin] " .. category .. ": " .. table.concat(names, ", "))
		end
	end
	adminNotify("Listed " .. tostring(count) .. " admin command(s)")
end

runAdminCommand = function(raw)
	local trimmed = string.gsub(tostring(raw or ""), "^%s*(.-)%s*$", "%1")
	if trimmed == "" then
		return false
	end
	local args = parseCommandArgs(trimmed)
	local cmd = string.lower(args[1] or "")
	local resolved = adminAliases[cmd]
	if not resolved then
		adminNotify("Unknown admin command: " .. tostring(cmd))
		return false
	end
	local def = adminCommands[resolved]
	local ok, result = pcall(def.run, args)
	if not ok then
		adminNotify("Command failed: " .. tostring(result))
		return false
	end
	if result ~= nil and result ~= false then
		adminNotify(result)
	end
	refreshAdminPanel()
	return true
end

registerAdminCommand({
	name = "help",
	aliases = { "cmds", "commands" },
	category = "General",
	usage = "help [category]",
	description = "List admin commands.",
	run = function(args)
		adminListCommands(args[2])
		return false
	end,
})

registerAdminCommand({
	name = "panel",
	aliases = { "adminpanel" },
	category = "General",
	usage = "panel [on|off]",
	description = "Toggle the admin panel.",
	run = function(args)
		setAdminOpen(adminBoolArg(args[2], adminOpen))
		return "Admin panel " .. (adminOpen and "open" or "closed")
	end,
})

registerAdminCommand({
	name = "status",
	category = "General",
	usage = "status",
	description = "Show local admin state.",
	run = function()
		log("[Admin] " .. string.gsub(adminCommandStatusText(), "\n", " | "))
		return false
	end,
})

registerAdminCommand({
	name = "resetadmin",
	aliases = { "adminreset" },
	category = "General",
	usage = "resetadmin",
	description = "Disable active admin toggles and restore defaults.",
	run = function()
		if clearAdminRuntime then
			clearAdminRuntime()
		end
		return "Admin state reset"
	end,
})

registerAdminCommand({
	name = "ws",
	aliases = { "walkspeed", "speed" },
	category = "Humanoid",
	usage = "ws <number>",
	description = "Set local WalkSpeed.",
	run = function(args)
		local ok, value = adminSetHumanoidNumber("WalkSpeed", args[2], 0, 500)
		if not ok then
			return "Usage: ws <number>"
		end
		return "WalkSpeed = " .. tostring(value)
	end,
})

registerAdminCommand({
	name = "jp",
	aliases = { "jumppower" },
	category = "Humanoid",
	usage = "jp <number>",
	description = "Set local JumpPower.",
	run = function(args)
		local ok, value = adminSetHumanoidNumber("JumpPower", args[2], 0, 500)
		if not ok then
			return "Usage: jp <number>"
		end
		return "JumpPower = " .. tostring(value)
	end,
})

registerAdminCommand({
	name = "jh",
	aliases = { "jumpheight" },
	category = "Humanoid",
	usage = "jh <number>",
	description = "Set local JumpHeight.",
	run = function(args)
		local ok, value = adminSetHumanoidNumber("JumpHeight", args[2], 0, 500)
		if not ok then
			return "Usage: jh <number>"
		end
		return "JumpHeight = " .. tostring(value)
	end,
})

registerAdminCommand({
	name = "hipheight",
	aliases = { "hip" },
	category = "Humanoid",
	usage = "hipheight <number>",
	description = "Set Humanoid.HipHeight.",
	run = function(args)
		local ok, value = adminSetHumanoidNumber("HipHeight", args[2], -10, 100)
		if not ok then
			return "Usage: hipheight <number>"
		end
		return "HipHeight = " .. tostring(value)
	end,
})

registerAdminCommand({
	name = "normal",
	aliases = { "restorehumanoid" },
	category = "Humanoid",
	usage = "normal",
	description = "Restore saved humanoid movement values.",
	run = function()
		local hum = humanoidAndRoot()
		if not hum then
			return "No humanoid"
		end
		if adminState.restore.walkSpeed then
			hum.WalkSpeed = adminState.restore.walkSpeed
		end
		if adminState.restore.jumpPower then
			hum.JumpPower = adminState.restore.jumpPower
		end
		if adminState.restore.jumpHeight then
			hum.JumpHeight = adminState.restore.jumpHeight
		end
		if adminState.restore.hipHeight then
			hum.HipHeight = adminState.restore.hipHeight
		end
		hum.PlatformStand = false
		hum.Sit = false
		return "Humanoid values restored"
	end,
})

registerAdminCommand({
	name = "jump",
	category = "Humanoid",
	usage = "jump",
	description = "Force a local jump.",
	run = function()
		local hum = humanoidAndRoot()
		if hum then
			hum.Jump = true
			hum:ChangeState(Enum.HumanoidStateType.Jumping)
			return "Jump"
		end
		return "No humanoid"
	end,
})

registerAdminCommand({
	name = "sit",
	category = "Humanoid",
	usage = "sit",
	description = "Sit your character.",
	run = function()
		local hum = humanoidAndRoot()
		if hum then
			hum.Sit = true
			return "Sit"
		end
		return "No humanoid"
	end,
})

registerAdminCommand({
	name = "unsit",
	aliases = { "stand" },
	category = "Humanoid",
	usage = "unsit",
	description = "Stand up.",
	run = function()
		local hum = humanoidAndRoot()
		if hum then
			hum.Sit = false
			hum.PlatformStand = false
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
			return "Unsit"
		end
		return "No humanoid"
	end,
})

registerAdminCommand({
	name = "platformstand",
	aliases = { "platform" },
	category = "Humanoid",
	usage = "platformstand [on|off]",
	description = "Toggle Humanoid.PlatformStand.",
	run = function(args)
		local hum = humanoidAndRoot()
		if not hum then
			return "No humanoid"
		end
		hum.PlatformStand = adminBoolArg(args[2], hum.PlatformStand)
		return "PlatformStand = " .. tostring(hum.PlatformStand)
	end,
})

registerAdminCommand({
	name = "heal",
	category = "Humanoid",
	usage = "heal [amount]",
	description = "Heal locally.",
	run = function(args)
		local hum = humanoidAndRoot()
		if not hum then
			return "No humanoid"
		end
		local amount = tonumber(args[2])
		if amount then
			hum.Health = math.min(hum.MaxHealth, hum.Health + amount)
		else
			hum.Health = hum.MaxHealth
		end
		return "Health = " .. tostring(math.floor(hum.Health))
	end,
})

registerAdminCommand({
	name = "damage",
	category = "Humanoid",
	usage = "damage <amount>",
	description = "Apply local humanoid damage.",
	run = function(args)
		local hum = humanoidAndRoot()
		local amount = tonumber(args[2])
		if not hum or not amount then
			return "Usage: damage <amount>"
		end
		hum:TakeDamage(amount)
		return "Damage = " .. tostring(amount)
	end,
})

registerAdminCommand({
	name = "god",
	category = "Humanoid",
	usage = "god [on|off]",
	description = "Toggle local god mode/forcefield.",
	run = function(args)
		adminSetGod(adminBoolArg(args[2], adminState.god))
		return "God = " .. tostring(adminState.god)
	end,
})

registerAdminCommand({
	name = "infjump",
	aliases = { "ij" },
	category = "Humanoid",
	usage = "infjump [on|off]",
	description = "Toggle infinite jump.",
	run = function(args)
		adminState.infJump = adminBoolArg(args[2], adminState.infJump)
		return "InfJump = " .. tostring(adminState.infJump)
	end,
})

registerAdminCommand({
	name = "reset",
	aliases = { "kill" },
	category = "Humanoid",
	usage = "reset",
	description = "Reset your character locally.",
	run = function()
		local c = char()
		if c then
			c:BreakJoints()
			return "Character reset"
		end
		return "No character"
	end,
})

registerAdminCommand({
	name = "respawn",
	category = "Humanoid",
	usage = "respawn",
	description = "Try LocalPlayer:LoadCharacter().",
	run = function()
		local ok, err = pcall(function()
			player:LoadCharacter()
		end)
		return ok and "Respawn requested" or ("Respawn failed: " .. tostring(err))
	end,
})

registerAdminCommand({
	name = "noclip",
	aliases = { "nc" },
	category = "Movement",
	usage = "noclip [on|off]",
	description = "Toggle CanCollide off on your character.",
	run = function(args)
		adminSetNoclip(adminBoolArg(args[2], adminState.noclip))
		return "Noclip = " .. tostring(adminState.noclip)
	end,
})

registerAdminCommand({
	name = "clip",
	category = "Movement",
	usage = "clip",
	description = "Disable noclip.",
	run = function()
		adminSetNoclip(false)
		return "Noclip = false"
	end,
})

registerAdminCommand({
	name = "fly",
	category = "Movement",
	usage = "fly [on|off]",
	description = "Toggle local camera-relative fly.",
	run = function(args)
		adminSetFly(adminBoolArg(args[2], adminState.fly))
		return "Fly = " .. tostring(adminState.fly)
	end,
})

registerAdminCommand({
	name = "flyspeed",
	aliases = { "fs" },
	category = "Movement",
	usage = "flyspeed <number>",
	description = "Set fly speed.",
	run = function(args)
		local n = tonumber(args[2])
		if not n then
			return "Usage: flyspeed <number>"
		end
		adminState.flySpeed = math.clamp(n, 1, 500)
		return "FlySpeed = " .. tostring(adminState.flySpeed)
	end,
})

registerAdminCommand({
	name = "anchor",
	category = "Movement",
	usage = "anchor [on|off]",
	description = "Anchor HumanoidRootPart.",
	run = function(args)
		local _, hrp = humanoidAndRoot()
		if not hrp then
			return "No root"
		end
		hrp.Anchored = adminBoolArg(args[2], hrp.Anchored)
		return "Anchored = " .. tostring(hrp.Anchored)
	end,
})

registerAdminCommand({
	name = "unanchor",
	category = "Movement",
	usage = "unanchor",
	description = "Unanchor HumanoidRootPart.",
	run = function()
		local _, hrp = humanoidAndRoot()
		if hrp then
			hrp.Anchored = false
			return "Unanchored"
		end
		return "No root"
	end,
})

registerAdminCommand({
	name = "freezechar",
	aliases = { "freezeplayer" },
	category = "Movement",
	usage = "freezechar",
	description = "Anchor and zero velocity.",
	run = function()
		local _, hrp = humanoidAndRoot()
		if hrp then
			hrp.Anchored = true
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
			return "Character frozen"
		end
		return "No root"
	end,
})

registerAdminCommand({
	name = "thaw",
	aliases = { "unfreezechar" },
	category = "Movement",
	usage = "thaw",
	description = "Unanchor after freezechar.",
	run = function()
		local _, hrp = humanoidAndRoot()
		if hrp then
			hrp.Anchored = false
			return "Character thawed"
		end
		return "No root"
	end,
})

registerAdminCommand({
	name = "velocity",
	aliases = { "vel" },
	category = "Movement",
	usage = "velocity <x> <y> <z>",
	description = "Set root linear velocity.",
	run = function(args)
		local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
		local _, hrp = humanoidAndRoot()
		if not hrp or not x or not y or not z then
			return "Usage: velocity <x> <y> <z>"
		end
		hrp.AssemblyLinearVelocity = Vector3.new(x, y, z)
		return "Velocity set"
	end,
})

registerAdminCommand({
	name = "zerovel",
	aliases = { "stopvel" },
	category = "Movement",
	usage = "zerovel",
	description = "Zero root linear/angular velocity.",
	run = function()
		local _, hrp = humanoidAndRoot()
		if not hrp then
			return "No root"
		end
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
		return "Velocity cleared"
	end,
})

registerAdminCommand({
	name = "launch",
	category = "Movement",
	usage = "launch <up> [forward]",
	description = "Launch upward/forward.",
	run = function(args)
		local up = tonumber(args[2])
		local forward = tonumber(args[3]) or 0
		local _, hrp = humanoidAndRoot()
		if not hrp or not up then
			return "Usage: launch <up> [forward]"
		end
		hrp.AssemblyLinearVelocity = (hrp.CFrame.LookVector * forward) + Vector3.new(0, up, 0)
		return "Launch"
	end,
})

registerAdminCommand({
	name = "spin",
	category = "Movement",
	usage = "spin [on|off]",
	description = "Toggle local character spin.",
	run = function(args)
		adminState.spin = adminBoolArg(args[2], adminState.spin)
		return "Spin = " .. tostring(adminState.spin)
	end,
})

registerAdminCommand({
	name = "spinspeed",
	category = "Movement",
	usage = "spinspeed <deg/sec>",
	description = "Set spin speed in degrees/sec.",
	run = function(args)
		local n = tonumber(args[2])
		if not n then
			return "Usage: spinspeed <deg/sec>"
		end
		adminState.spinSpeed = math.clamp(n, -1440, 1440)
		return "SpinSpeed = " .. tostring(adminState.spinSpeed)
	end,
})

registerAdminCommand({
	name = "floatpad",
	aliases = { "pad" },
	category = "Movement",
	usage = "floatpad [on|off]",
	description = "Create/remove an anchored pad under you.",
	run = function(args)
		local want = adminBoolArg(args[2], adminState.floatPad ~= nil)
		local ok = adminSetFloatPad(want)
		return ok and ("FloatPad = " .. tostring(want)) or "No root"
	end,
})

registerAdminCommand({
	name = "movepad",
	category = "Movement",
	usage = "movepad",
	description = "Move floatpad under current position.",
	run = function()
		if not adminState.floatPad then
			return "No floatpad"
		end
		local _, hrp = humanoidAndRoot()
		if not hrp then
			return "No root"
		end
		adminState.floatPad.CFrame = CFrame.new(hrp.Position - Vector3.new(0, 3.4, 0))
		return "FloatPad moved"
	end,
})

registerAdminCommand({
	name = "tp",
	aliases = { "teleport" },
	category = "Teleport",
	usage = "tp <x> <y> <z> | tp <player>",
	description = "Teleport to coordinates or player.",
	run = function(args)
		local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
		if x and y and z then
			return adminTeleportTo(CFrame.new(x, y, z)) and "Teleported" or "No root"
		end
		local target = adminFindPlayer(args[2])
		local targetRoot = adminGetPlayerRoot(target)
		if targetRoot then
			return adminTeleportTo(targetRoot.CFrame + Vector3.new(0, 3, 0)) and ("Teleported to " .. target.Name) or "No root"
		end
		return "Usage: tp <x> <y> <z> | tp <player>"
	end,
})

registerAdminCommand({
	name = "tpforward",
	aliases = { "forward" },
	category = "Teleport",
	usage = "tpforward <studs>",
	description = "Teleport forward.",
	run = function(args)
		local distance = tonumber(args[2]) or 10
		local _, hrp = humanoidAndRoot()
		if not hrp then
			return "No root"
		end
		return adminTeleportTo(hrp.CFrame + (hrp.CFrame.LookVector * distance)) and "Teleported forward" or "No root"
	end,
})

registerAdminCommand({
	name = "tpup",
	aliases = { "up" },
	category = "Teleport",
	usage = "tpup <studs>",
	description = "Teleport upward.",
	run = function(args)
		local distance = tonumber(args[2]) or 10
		local _, hrp = humanoidAndRoot()
		if not hrp then
			return "No root"
		end
		return adminTeleportTo(hrp.CFrame + Vector3.new(0, distance, 0)) and "Teleported up" or "No root"
	end,
})

registerAdminCommand({
	name = "tpdown",
	aliases = { "down" },
	category = "Teleport",
	usage = "tpdown <studs>",
	description = "Teleport downward.",
	run = function(args)
		local distance = tonumber(args[2]) or 10
		local _, hrp = humanoidAndRoot()
		if not hrp then
			return "No root"
		end
		return adminTeleportTo(hrp.CFrame - Vector3.new(0, distance, 0)) and "Teleported down" or "No root"
	end,
})

registerAdminCommand({
	name = "height",
	aliases = { "sety" },
	category = "Teleport",
	usage = "height <y>",
	description = "Keep X/Z and set Y position.",
	run = function(args)
		local y = tonumber(args[2])
		local _, hrp = humanoidAndRoot()
		if not hrp or not y then
			return "Usage: height <y>"
		end
		local p = hrp.Position
		return adminTeleportTo(CFrame.new(p.X, y, p.Z) * (hrp.CFrame - hrp.Position)) and "Height set" or "No root"
	end,
})

registerAdminCommand({
	name = "ground",
	aliases = { "toground" },
	category = "Teleport",
	usage = "ground",
	description = "Raycast down and teleport to ground.",
	run = function()
		local c = char()
		local _, hrp = humanoidAndRoot()
		if not c or not hrp then
			return "No root"
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude or Enum.RaycastFilterType.Blacklist
		params.FilterDescendantsInstances = { c }
		local result = workspace:Raycast(hrp.Position, Vector3.new(0, -1000, 0), params)
		if not result then
			return "No ground hit"
		end
		local target = CFrame.new(result.Position + Vector3.new(0, 3, 0)) * (hrp.CFrame - hrp.Position)
		return adminTeleportTo(target) and "Teleported to ground" or "No root"
	end,
})

registerAdminCommand({
	name = "face",
	aliases = { "yaw" },
	category = "Teleport",
	usage = "face <degrees>",
	description = "Rotate character to yaw degrees.",
	run = function(args)
		local yaw = tonumber(args[2])
		local _, hrp = humanoidAndRoot()
		if not hrp or not yaw then
			return "Usage: face <degrees>"
		end
		local p = hrp.Position
		hrp.CFrame = CFrame.new(p) * CFrame.Angles(0, math.rad(yaw), 0)
		return "Yaw = " .. tostring(yaw)
	end,
})

registerAdminCommand({
	name = "turn",
	aliases = { "rotate" },
	category = "Teleport",
	usage = "turn <degrees>",
	description = "Rotate character relative to current yaw.",
	run = function(args)
		local yaw = tonumber(args[2])
		local _, hrp = humanoidAndRoot()
		if not hrp or not yaw then
			return "Usage: turn <degrees>"
		end
		hrp.CFrame = hrp.CFrame * CFrame.Angles(0, math.rad(yaw), 0)
		return "Turned " .. tostring(yaw)
	end,
})

registerAdminCommand({
	name = "back",
	category = "Teleport",
	usage = "back",
	description = "Return to previous admin teleport location.",
	run = function()
		if adminPreviousPosition then
			local target = adminPreviousPosition
			adminPreviousPosition = nil
			return adminTeleportTo(target) and "Returned" or "No root"
		end
		return "No previous position"
	end,
})

registerAdminCommand({
	name = "savepos",
	aliases = { "markpos" },
	category = "Teleport",
	usage = "savepos <name>",
	description = "Save current CFrame.",
	run = function(args)
		local name = args[2] or "default"
		local _, hrp = humanoidAndRoot()
		if not hrp then
			return "No root"
		end
		adminSavedPositions[name] = hrp.CFrame
		return "Saved position " .. name
	end,
})

registerAdminCommand({
	name = "loadpos",
	aliases = { "gotopos" },
	category = "Teleport",
	usage = "loadpos <name>",
	description = "Teleport to saved CFrame.",
	run = function(args)
		local name = args[2] or "default"
		local cf = adminSavedPositions[name]
		if not cf then
			return "Saved position not found: " .. name
		end
		return adminTeleportTo(cf) and ("Loaded position " .. name) or "No root"
	end,
})

registerAdminCommand({
	name = "delpos",
	category = "Teleport",
	usage = "delpos <name>",
	description = "Delete saved position.",
	run = function(args)
		local name = args[2] or "default"
		adminSavedPositions[name] = nil
		return "Deleted position " .. name
	end,
})

registerAdminCommand({
	name = "listpos",
	category = "Teleport",
	usage = "listpos",
	description = "List saved positions.",
	run = function()
		local names = {}
		for name in pairs(adminSavedPositions) do
			table.insert(names, name)
		end
		table.sort(names)
		log("[Admin] saved positions: " .. (#names > 0 and table.concat(names, ", ") or "none"))
		return false
	end,
})

registerAdminCommand({
	name = "pos",
	aliases = { "whereami" },
	category = "Teleport",
	usage = "pos",
	description = "Print current position.",
	run = function()
		local _, hrp = humanoidAndRoot()
		if not hrp then
			return "No root"
		end
		local p = hrp.Position
		log(string.format("[Admin] Position: %.3f %.3f %.3f", p.X, p.Y, p.Z))
		if setclipboard then
			pcall(setclipboard, string.format("%.3f %.3f %.3f", p.X, p.Y, p.Z))
		end
		return false
	end,
})

registerAdminCommand({
	name = "gravity",
	aliases = { "grav" },
	category = "World",
	usage = "gravity <number>",
	description = "Set Workspace.Gravity.",
	run = function(args)
		local n = tonumber(args[2])
		if not n then
			return "Usage: gravity <number>"
		end
		workspace.Gravity = math.clamp(n, -500, 1000)
		return "Gravity = " .. tostring(workspace.Gravity)
	end,
})

registerAdminCommand({
	name = "resetgravity",
	aliases = { "gravreset" },
	category = "World",
	usage = "resetgravity",
	description = "Restore startup gravity.",
	run = function()
		workspace.Gravity = adminState.restore.gravity or 196.2
		return "Gravity restored"
	end,
})

registerAdminCommand({
	name = "fullbright",
	aliases = { "fb" },
	category = "World",
	usage = "fullbright [on|off]",
	description = "Toggle bright local lighting.",
	run = function(args)
		adminSetFullbright(adminBoolArg(args[2], adminState.fullbright))
		return "Fullbright = " .. tostring(adminState.fullbright)
	end,
})

registerAdminCommand({
	name = "clocktime",
	aliases = { "time" },
	category = "World",
	usage = "clocktime <0..24>",
	description = "Set Lighting.ClockTime.",
	run = function(args)
		adminCaptureLighting()
		local n = tonumber(args[2])
		if not n then
			return "Usage: clocktime <0..24>"
		end
		Lighting.ClockTime = math.clamp(n, 0, 24)
		return "ClockTime = " .. tostring(Lighting.ClockTime)
	end,
})

registerAdminCommand({
	name = "brightness",
	category = "World",
	usage = "brightness <number>",
	description = "Set Lighting.Brightness.",
	run = function(args)
		adminCaptureLighting()
		local n = tonumber(args[2])
		if not n then
			return "Usage: brightness <number>"
		end
		Lighting.Brightness = math.clamp(n, 0, 20)
		return "Brightness = " .. tostring(Lighting.Brightness)
	end,
})

registerAdminCommand({
	name = "exposure",
	category = "World",
	usage = "exposure <number>",
	description = "Set Lighting.ExposureCompensation.",
	run = function(args)
		adminCaptureLighting()
		local n = tonumber(args[2])
		if not n then
			return "Usage: exposure <number>"
		end
		Lighting.ExposureCompensation = math.clamp(n, -5, 5)
		return "Exposure = " .. tostring(Lighting.ExposureCompensation)
	end,
})

registerAdminCommand({
	name = "ambient",
	category = "World",
	usage = "ambient <r> <g> <b>",
	description = "Set Lighting.Ambient.",
	run = function(args)
		adminCaptureLighting()
		local color = adminParseColor(args, 2)
		if not color then
			return "Usage: ambient <r> <g> <b>"
		end
		Lighting.Ambient = color
		return "Ambient set"
	end,
})

registerAdminCommand({
	name = "outdoorambient",
	aliases = { "oambient" },
	category = "World",
	usage = "outdoorambient <r> <g> <b>",
	description = "Set Lighting.OutdoorAmbient.",
	run = function(args)
		adminCaptureLighting()
		local color = adminParseColor(args, 2)
		if not color then
			return "Usage: outdoorambient <r> <g> <b>"
		end
		Lighting.OutdoorAmbient = color
		return "OutdoorAmbient set"
	end,
})

registerAdminCommand({
	name = "shadows",
	category = "World",
	usage = "shadows [on|off]",
	description = "Toggle Lighting.GlobalShadows.",
	run = function(args)
		adminCaptureLighting()
		Lighting.GlobalShadows = adminBoolArg(args[2], Lighting.GlobalShadows)
		return "GlobalShadows = " .. tostring(Lighting.GlobalShadows)
	end,
})

registerAdminCommand({
	name = "fog",
	category = "World",
	usage = "fog <end> [start]",
	description = "Set local fog distances.",
	run = function(args)
		adminCaptureLighting()
		local fogEnd = tonumber(args[2])
		local fogStart = tonumber(args[3]) or Lighting.FogStart
		if not fogEnd then
			return "Usage: fog <end> [start]"
		end
		Lighting.FogEnd = math.max(0, fogEnd)
		Lighting.FogStart = math.max(0, fogStart)
		return "Fog = " .. tostring(Lighting.FogStart) .. ".." .. tostring(Lighting.FogEnd)
	end,
})

registerAdminCommand({
	name = "nofog",
	category = "World",
	usage = "nofog",
	description = "Remove local fog.",
	run = function()
		adminCaptureLighting()
		Lighting.FogStart = 0
		Lighting.FogEnd = 100000
		return "Fog removed"
	end,
})

registerAdminCommand({
	name = "resetlighting",
	aliases = { "lightreset" },
	category = "World",
	usage = "resetlighting",
	description = "Restore saved lighting.",
	run = function()
		adminRestoreLighting()
		return "Lighting restored"
	end,
})

registerAdminCommand({
	name = "fov",
	category = "Camera",
	usage = "fov <number>",
	description = "Set camera FieldOfView.",
	run = function(args)
		local n = tonumber(args[2])
		if not n then
			return "Usage: fov <number>"
		end
		camera.FieldOfView = math.clamp(n, 1, 120)
		return "FOV = " .. tostring(camera.FieldOfView)
	end,
})

registerAdminCommand({
	name = "resetfov",
	category = "Camera",
	usage = "resetfov",
	description = "Restore startup FOV.",
	run = function()
		camera.FieldOfView = adminState.restore.fov or 70
		return "FOV restored"
	end,
})

registerAdminCommand({
	name = "camreset",
	aliases = { "resetcam" },
	category = "Camera",
	usage = "camreset",
	description = "Restore camera to character.",
	run = function()
		local hum = humanoidAndRoot()
		camera.CameraType = Enum.CameraType.Custom
		if hum then
			camera.CameraSubject = hum
		end
		adminState.spectating = nil
		return "Camera reset"
	end,
})

registerAdminCommand({
	name = "spectate",
	aliases = { "spec" },
	category = "Camera",
	usage = "spectate <player|self>",
	description = "Set CameraSubject to a player humanoid.",
	run = function(args)
		local target = adminFindPlayer(args[2])
		if not target or not target.Character then
			return "Usage: spectate <player|self>"
		end
		local hum = target.Character:FindFirstChildOfClass("Humanoid")
		if not hum then
			return "Target has no humanoid"
		end
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = hum
		adminState.spectating = target
		return "Spectating " .. target.Name
	end,
})

registerAdminCommand({
	name = "unspectate",
	aliases = { "unsp" },
	category = "Camera",
	usage = "unspectate",
	description = "Return camera to self.",
	run = function()
		local hum = humanoidAndRoot()
		if hum then
			camera.CameraSubject = hum
		end
		camera.CameraType = Enum.CameraType.Custom
		adminState.spectating = nil
		return "Stopped spectating"
	end,
})

registerAdminCommand({
	name = "lookat",
	category = "Camera",
	usage = "lookat <player>",
	description = "Aim camera at a player once.",
	run = function(args)
		local target = adminFindPlayer(args[2])
		local targetRoot = adminGetPlayerRoot(target)
		if not targetRoot then
			return "Usage: lookat <player>"
		end
		camera.CFrame = CFrame.lookAt(camera.CFrame.Position, targetRoot.Position)
		return "Camera looking at " .. target.Name
	end,
})

registerAdminCommand({
	name = "esp",
	category = "Visual",
	usage = "esp [on|off]",
	description = "Toggle player highlights.",
	run = function(args)
		adminSetEsp(adminBoolArg(args[2], adminState.esp))
		return "ESP = " .. tostring(adminState.esp)
	end,
})

registerAdminCommand({
	name = "names",
	aliases = { "nametags" },
	category = "Visual",
	usage = "names [on|off]",
	description = "Toggle player name billboards.",
	run = function(args)
		adminSetNames(adminBoolArg(args[2], adminState.names))
		return "Names = " .. tostring(adminState.names)
	end,
})

registerAdminCommand({
	name = "trails",
	aliases = { "trail" },
	category = "Visual",
	usage = "trails [on|off]",
	description = "Toggle local movement trail.",
	run = function(args)
		adminSetTrails(adminBoolArg(args[2], adminState.trails))
		return "Trails = " .. tostring(adminState.trails)
	end,
})

registerAdminCommand({
	name = "xray",
	category = "Visual",
	usage = "xray [on|off]",
	description = "Make many world parts semi-transparent locally.",
	run = function(args)
		adminSetXray(adminBoolArg(args[2], adminState.xray))
		return "XRay = " .. tostring(adminState.xray)
	end,
})

registerAdminCommand({
	name = "clearvisuals",
	category = "Visual",
	usage = "clearvisuals",
	description = "Disable ESP, names, trails.",
	run = function()
		adminSetEsp(false)
		adminSetNames(false)
		adminSetTrails(false)
		adminSetXray(false)
		return "Visual admin features cleared"
	end,
})

registerAdminCommand({
	name = "players",
	aliases = { "plist" },
	category = "Utility",
	usage = "players",
	description = "List players.",
	run = function()
		local names = {}
		for _, plr in ipairs(Players:GetPlayers()) do
			table.insert(names, plr.Name)
		end
		table.sort(names)
		log("[Admin] players: " .. table.concat(names, ", "))
		return false
	end,
})

registerAdminCommand({
	name = "copypos",
	category = "Utility",
	usage = "copypos",
	description = "Copy current position to clipboard if supported.",
	run = function()
		local _, hrp = humanoidAndRoot()
		if not hrp then
			return "No root"
		end
		local p = hrp.Position
		local text = string.format("%.3f, %.3f, %.3f", p.X, p.Y, p.Z)
		if setclipboard then
			pcall(setclipboard, text)
			return "Copied position"
		end
		log("[Admin] clipboard unavailable, pos: " .. text)
		return false
	end,
})

registerAdminCommand({
	name = "notify",
	category = "Utility",
	usage = "notify <text>",
	description = "Show a local notification.",
	run = function(args)
		table.remove(args, 1)
		local text = table.concat(args, " ")
		if text == "" then
			return "Usage: notify <text>"
		end
		adminNotify(text)
		return false
	end,
})

updateAdminRuntime = function(dt)
	if adminState.noclip then
		for _, part in ipairs(adminCharacterParts()) do
			if adminState.noclipParts[part] == nil then
				adminState.noclipParts[part] = part.CanCollide
			end
			part.CanCollide = false
		end
	end

	if adminState.fly then
		local hum, hrp = humanoidAndRoot()
		if hum and hrp then
			hum.PlatformStand = true
			hum.AutoRotate = false
			local camCF = camera.CFrame
			local move = Vector3.zero
			if UIS:IsKeyDown(Enum.KeyCode.W) then
				move = move + camCF.LookVector
			end
			if UIS:IsKeyDown(Enum.KeyCode.S) then
				move = move - camCF.LookVector
			end
			if UIS:IsKeyDown(Enum.KeyCode.D) then
				move = move + camCF.RightVector
			end
			if UIS:IsKeyDown(Enum.KeyCode.A) then
				move = move - camCF.RightVector
			end
			if UIS:IsKeyDown(Enum.KeyCode.Space) then
				move = move + Vector3.new(0, 1, 0)
			end
			if UIS:IsKeyDown(Enum.KeyCode.LeftControl) or UIS:IsKeyDown(Enum.KeyCode.RightControl) then
				move = move - Vector3.new(0, 1, 0)
			end
			if move.Magnitude > 0 then
				move = move.Unit * adminState.flySpeed
			end
			hrp.AssemblyLinearVelocity = move
			hrp.AssemblyAngularVelocity = Vector3.zero
			hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + camCF.LookVector)
		end
	end

	if adminState.god then
		local hum = humanoidAndRoot()
		if hum then
			if hum.MaxHealth < 1000000 then
				hum.MaxHealth = 1000000
			end
			if hum.Health < hum.MaxHealth then
				hum.Health = hum.MaxHealth
			end
		end
	end

	if adminState.trails and not adminState.trailObjects.trail then
		adminCreateTrail()
	end

	if adminState.spin then
		local _, hrp = humanoidAndRoot()
		if hrp then
			hrp.CFrame = hrp.CFrame * CFrame.Angles(0, math.rad(adminState.spinSpeed) * (tonumber(dt) or 0), 0)
		end
	end

	adminRefreshEsp()
	adminRefreshNames()
	refreshAdminPanel()
end

clearAdminRuntime = function()
	adminSetFly(false)
	adminSetNoclip(false)
	adminSetGod(false)
	adminSetEsp(false)
	adminSetNames(false)
	adminSetTrails(false)
	adminSetXray(false)
	adminSetFullbright(false)
	adminState.infJump = false
	adminState.spin = false
	adminState.spectating = nil
	adminSetFloatPad(false)
	camera.CameraType = adminState.restore.cameraType or Enum.CameraType.Custom
	if adminState.restore.cameraSubject then
		camera.CameraSubject = adminState.restore.cameraSubject
	else
		local hum = humanoidAndRoot()
		if hum then
			camera.CameraSubject = hum
		end
	end
	camera.FieldOfView = adminState.restore.fov or camera.FieldOfView
	workspace.Gravity = adminState.restore.gravity or workspace.Gravity
end

populateAdminPanel = function()
	if not adminCommandList then
		return
	end
	for _, child in ipairs(adminCommandList:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local categories = adminCommandNamesByCategory()
	local categoryNames = {}
	for category in pairs(categories) do
		table.insert(categoryNames, category)
	end
	table.sort(categoryNames)

	local layoutOrder = 0
	for _, category in ipairs(categoryNames) do
		layoutOrder = layoutOrder + 1
		local header = Instance.new("TextLabel")
		header.Size = UDim2.new(1, -8, 0, 24)
		header.BackgroundTransparency = 1
		header.Text = category
		header.TextColor3 = Color3.fromRGB(159, 209, 255)
		header.Font = Enum.Font.GothamBold
		header.TextSize = 13
		header.TextXAlignment = Enum.TextXAlignment.Left
		header.LayoutOrder = layoutOrder
		header.Parent = adminCommandList

		local defs = categories[category]
		table.sort(defs, function(a, b)
			return a.name < b.name
		end)
		for _, def in ipairs(defs) do
			layoutOrder = layoutOrder + 1
			local btn = Instance.new("TextButton")
			btn.Size = UDim2.new(1, -8, 0, 42)
			btn.BackgroundColor3 = Color3.fromRGB(29, 39, 54)
			btn.BorderSizePixel = 0
			btn.Text = def.name .. "  -  " .. def.description .. "\n" .. def.usage
			btn.TextColor3 = Color3.fromRGB(230, 240, 248)
			btn.Font = Enum.Font.Code
			btn.TextSize = 12
			btn.TextXAlignment = Enum.TextXAlignment.Left
			btn.TextYAlignment = Enum.TextYAlignment.Center
			btn.AutoButtonColor = true
			btn.LayoutOrder = layoutOrder
			btn.Parent = adminCommandList

			local btnCorner = Instance.new("UICorner")
			btnCorner.CornerRadius = UDim.new(0, 6)
			btnCorner.Parent = btn

			connect(btn.MouseButton1Click, function()
				if adminCommandBox then
					adminCommandBox.Text = def.usage
					adminCommandBox:CaptureFocus()
					adminCommandBox.CursorPosition = #adminCommandBox.Text + 1
				end
				adminUsage(def.name)
			end)
		end
	end

	refreshAdminPanel()
end

populateAdminPanel()

connect(adminToggleBtn.MouseButton1Click, function()
	setAdminOpen(not adminOpen)
end)

connect(adminCloseBtn.MouseButton1Click, function()
	setAdminOpen(false)
end)

connect(adminCommandBox.FocusLost, function(enterPressed)
	if enterPressed then
		runAdminCommand(adminCommandBox.Text)
		adminCommandBox.Text = ""
	end
end)

connect(UIS.JumpRequest, function()
	if not adminState.infJump then
		return
	end
	local hum = humanoidAndRoot()
	if hum then
		hum.Jump = true
		hum:ChangeState(Enum.HumanoidStateType.Jumping)
	end
end)

local function commandHelp()
	log("Commands:")
	log("help")
	log("erase")
	log("setspeed <number>")
	log("playspeed <number>")
	log("blend <0.05..1>")
	log("inputs <on|off>")
	log("overlay <on|off>")
	log("recordnocollision <on|off>")
	log("playbackmode <ghost|frameblend|smooth> (physics aliases to frameblend)")
	log("cameramode <exact|smooth>")
	log("recordmode <replace|append>")
	log("status")
	log("selfcheck")
	log("diagnostics")
	log("stats")
	log("admin [command] / admin panel / direct admin commands like fly, noclip, ws")
	log("clearlog")
	log("cp set <name> [frame]")
	log("cp goto <name>")
	log("cp list")
	log("cp del <name>")
end

local function runCommand(raw)
	local trimmed = string.gsub(raw, "^%s*(.-)%s*$", "%1")
	if trimmed == "" then
		return
	end

	pushCommandHistory(trimmed)
	local args = parseCommandArgs(trimmed)
	local cmd = string.lower(args[1] or "")

	if cmd == "help" then
		commandHelp()
		return
	end

	if cmd == "erase" then
		eraseReplay()
		return
	end

	if cmd == "setspeed" then
		local newSpeed = tonumber(args[2])
		if not newSpeed or newSpeed <= 0 then
			log("Usage: setspeed <number > 0>")
			return
		end
		seekSpeed = newSpeed
		log("Seek speed set to " .. tostring(seekSpeed))
		return
	end

	if cmd == "playspeed" then
		local newSpeed = tonumber(args[2])
		if not newSpeed or newSpeed <= 0 then
			log("Usage: playspeed <number > 0>")
			return
		end
		playbackSpeed = newSpeed
		log("Playback speed set to " .. tostring(playbackSpeed))
		refreshSettingsUI()
		return
	end

	if cmd == "blend" then
		local newBlend = tonumber(args[2])
		if not newBlend or newBlend < 0.05 or newBlend > 1 then
			log("Usage: blend <0.05..1>")
			return
		end
		blendAlphaScale = newBlend
		log("Blend scale set to " .. string.format("%.2f", blendAlphaScale))
		return
	end

	if cmd == "inputs" then
		local modeArg = string.lower(args[2] or "")
		if modeArg ~= "on" and modeArg ~= "off" then
			log("Usage: inputs <on|off>")
			return
		end
		virtualInputPlaybackEnabled = (modeArg == "on")
		if not virtualInputPlaybackEnabled then
			releaseAllVirtualInputs()
		end
		log("Virtual input playback set to " .. modeArg)
		refreshSettingsUI()
		return
	end

	if cmd == "overlay" then
		local modeArg = string.lower(args[2] or "")
		if modeArg ~= "on" and modeArg ~= "off" then
			log("Usage: overlay <on|off>")
			return
		end
		inputOverlayEnabled = (modeArg == "on")
		if not inputOverlayEnabled then
			updatePlaybackInputOverlay(nil)
		end
		log("Input overlay set to " .. modeArg)
		refreshSettingsUI()
		return
	end

	if cmd == "recordnocollision" then
		local modeArg = string.lower(args[2] or "")
		if modeArg ~= "on" and modeArg ~= "off" then
			log("Usage: recordnocollision <on|off>")
			return
		end
		recordNoCollisionEnabled = (modeArg == "on")
		if not recordNoCollisionEnabled then
			clearRecordNoCollision()
		elseif mode == "record" then
			applyRecordNoCollision()
		end
		log("Record no-collision set to " .. modeArg)
		refreshSettingsUI()
		return
	end

	if cmd == "playbackmode" then
		local newModeRaw = string.lower(args[2] or "")
		local newMode, aliased = normalizePlaybackModeName(newModeRaw)
		if newModeRaw ~= "ghost" and newModeRaw ~= "frameblend" and newModeRaw ~= "smooth" and newModeRaw ~= "physics" then
			log("Usage: playbackmode <ghost|frameblend|smooth>")
			return
		end
		playbackMode = newMode
		if mode == "play" then
			setCameraPlaybackMode(true)
			resetCameraSmoothingClock()
			applyPlaybackLock()
		end
		log("Playback mode set to " .. playbackMode .. (aliased and " (physics alias)" or ""))
		refreshSettingsUI()
		return
	end

	if cmd == "cameramode" then
		local newMode = string.lower(args[2] or "")
		if newMode ~= "exact" and newMode ~= "smooth" then
			log("Usage: cameramode <exact|smooth>")
			return
		end
		cameraMode = newMode
		if mode == "play" then
			resetCameraSmoothingClock()
		end
		log("Camera mode set to " .. cameraMode)
		refreshSettingsUI()
		return
	end

	if cmd == "recordmode" then
		local newMode = string.lower(args[2] or "")
		if newMode ~= "replace" and newMode ~= "append" then
			log("Usage: recordmode <replace|append>")
			return
		end
		recordMode = newMode
		log("Record mode set to " .. recordMode)
		refreshSettingsUI()
		return
	end

	if cmd == "status" then
		log(statusText())
		return
	end

	if cmd == "selfcheck" then
		runSelfCheck()
		return
	end

	if cmd == "diagnostics" then
		runDiagnostics()
		return
	end

	if cmd == "stats" then
		logReplayStats()
		return
	end

	if cmd == "admin" then
		if not args[2] then
			setAdminOpen(not adminOpen)
			log("Admin panel " .. (adminOpen and "opened" or "closed"))
			return
		end
		table.remove(args, 1)
		runAdminCommand(table.concat(args, " "))
		return
	end

	if adminAliases[cmd] then
		runAdminCommand(trimmed)
		return
	end

	if cmd == "clearlog" then
		clearLog()
		log("On-screen log cleared")
		return
	end

	if cmd == "cp" then
		local action = string.lower(args[2] or "")
		if action == "set" then
			local name = args[3] or QUICK_CP_NAME
			local frameNumber = tonumber(args[4])
			setCheckpoint(name, frameNumber)
			return
		end
		if action == "goto" then
			local name = args[3] or QUICK_CP_NAME
			gotoCheckpoint(name)
			return
		end
		if action == "list" then
			local found = false
			for name, idx in pairs(checkpoints) do
				found = true
				log("cp " .. tostring(name) .. " = " .. tostring(idx))
			end
			if not found then
				log("No checkpoints")
			end
			return
		end
		if action == "del" then
			local name = args[3]
			if not name then
				log("Usage: cp del <name>")
				return
			end
			checkpoints[name] = nil
			log("Checkpoint '" .. name .. "' deleted")
			return
		end
		log("Usage: cp <set|goto|list|del> ...")
		return
	end

	log("Unknown command: " .. cmd .. " (use 'help')")
end

connect(UIS.InputBegan, function(input, gp)
	if input.UserInputType == Enum.UserInputType.Keyboard then
		local keyName = input.KeyCode.Name
		if shouldCaptureVirtualKey(keyName) then
			heldKeys[keyName] = true
		end
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		heldKeys.MouseButton1 = true
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		heldKeys.MouseButton2 = true
	end

	if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.F2 then
		forceHideUI = not forceHideUI
		if forceHideUI and commandBar:IsFocused() then
			commandBar:ReleaseFocus()
		end
		updateUI()
		return
	end

	if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.Slash then
		commandBar:CaptureFocus()
	end

	if UIS:GetFocusedTextBox() then
		if commandBar:IsFocused() and input.UserInputType == Enum.UserInputType.Keyboard then
			if input.KeyCode == Enum.KeyCode.Up then
				commandBar.Text = recallCommandHistory(-1)
				commandBar.CursorPosition = #commandBar.Text + 1
				updateUI()
				return
			elseif input.KeyCode == Enum.KeyCode.Down then
				commandBar.Text = recallCommandHistory(1)
				commandBar.CursorPosition = #commandBar.Text + 1
				updateUI()
				return
			end
		end
		if input.UserInputType == Enum.UserInputType.Keyboard then
			heldKeys[input.KeyCode.Name] = nil
		end
		updateUI()
		return
	end

	if input.UserInputType == Enum.UserInputType.Keyboard then
		local kcShift = input.KeyCode
		if kcShift == Enum.KeyCode.LeftShift or kcShift == Enum.KeyCode.RightShift then
			handleShiftLockKey()
		end
	end

	if gp then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	local kc = input.KeyCode

	if kc == Enum.KeyCode.F8 then
		if mode == "record" then
			stopRecord()
		else
			startRecord()
		end
	elseif kc == Enum.KeyCode.F10 then
		if mode == "play" then
			stopPlay()
		else
			startPlay()
		end
	elseif kc == Enum.KeyCode.F6 then
		saveReplay()
	elseif kc == Enum.KeyCode.F7 then
		loadReplay()
	elseif kc == Enum.KeyCode.U then
		uiVisible = not uiVisible
	elseif kc == Enum.KeyCode.E then
		if mode == "play" or mode == "record" then
			setFrozen(not frozen)
		end
	elseif kc == Enum.KeyCode.F then
		if (mode == "play" or mode == "record") and frozen then
			playIndex = clampIndex(playIndex - 1)
			applyFrame(playIndex)
		end
	elseif kc == Enum.KeyCode.G then
		if (mode == "play" or mode == "record") and frozen then
			playIndex = clampIndex(playIndex + 1)
			applyFrame(playIndex)
		end
	elseif kc == Enum.KeyCode.T then
		if mode == "play" or mode == "record" then
			if not frozen then
				setFrozen(true)
			end
			seekDir = -1
		end
	elseif kc == Enum.KeyCode.Y then
		if mode == "play" or mode == "record" then
			if not frozen then
				setFrozen(true)
			end
			seekDir = 1
		end
	elseif kc == Enum.KeyCode.C then
		setCheckpoint(QUICK_CP_NAME)
	elseif kc == Enum.KeyCode.V then
		gotoCheckpoint(QUICK_CP_NAME)
	end

	updateUI()
end)

connect(UIS.InputEnded, function(input)
	if input.UserInputType == Enum.UserInputType.Keyboard then
		heldKeys[input.KeyCode.Name] = nil
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		heldKeys.MouseButton1 = nil
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		heldKeys.MouseButton2 = nil
	end

	if input.KeyCode == Enum.KeyCode.T and seekDir == -1 then
		seekDir = 0
	elseif input.KeyCode == Enum.KeyCode.Y and seekDir == 1 then
		seekDir = 0
	end
end)

connect(commandBar.FocusLost, function(enterPressed)
	if enterPressed then
		runCommand(commandBar.Text)
	end
	commandBar.Text = ""
	updateUI()
end)

connect(RunService.RenderStepped, function(dt)
	local nowClock = tick()
	if updateAdminRuntime then
		updateAdminRuntime(dt)
	end
	local clockDtRecord = 0
	local clockDtPlay = 0
	if lastRecordClock > 0 then
		clockDtRecord = math.max(0, nowClock - lastRecordClock)
	end
	if lastPlaybackClock > 0 then
		clockDtPlay = math.max(0, nowClock - lastPlaybackClock)
	end

	local dtSafe = tonumber(dt) or 0
	if dtSafe < 0 then
		dtSafe = 0
	end

	if mode == "record" then
		lastRecordClock = nowClock
		lastPlaybackClock = 0
		applyRecordNoCollision()
		if frozen then
			applyRecordFreezeLock()
			if #frames > 0 then
				if seekDir ~= 0 then
					playIndex = clampIndex(playIndex + seekDir * seekSpeed)
				else
					playIndex = clampIndex(playIndex)
				end
				applyFrame(playIndex)
			end
		else
			clearRecordFreezeLock()
			local recordDelta = clockDtRecord > 0 and clockDtRecord or dtSafe
			recordAccumulator = recordAccumulator + recordDelta
			if recordAccumulator > PLAYBACK_MAX_ACCUMULATOR then
				recordAccumulator = PLAYBACK_MAX_ACCUMULATOR
			end

			local recordSteps = 0
			while recordAccumulator >= timelineStep and recordSteps < RECORD_MAX_STEPS_PER_RENDER do
				captureFrame(timelineStep)
				recordAccumulator = recordAccumulator - timelineStep
				recordSteps = recordSteps + 1
			end
		end
	elseif mode == "play" then
		lastPlaybackClock = nowClock
		lastRecordClock = 0
		if #frames == 0 then
			stopPlay()
			updateUI()
			return
		end

		if not applyPlaybackLock() then
			updateUI()
			return
		end

		if frozen then
			if seekDir ~= 0 then
				playIndex = clampIndex(playIndex + seekDir * seekSpeed)
			else
				playIndex = clampIndex(playIndex)
			end
			applyFrame(playIndex)
		else
			local playDelta = clockDtPlay > 0 and clockDtPlay or dtSafe
			playbackAccumulator = playbackAccumulator + (playDelta * playbackSpeed)
			if playbackAccumulator > PLAYBACK_MAX_ACCUMULATOR then
				playbackAccumulator = PLAYBACK_MAX_ACCUMULATOR
			end

			local steps = 0
			local appliedAny = false
			while steps < PLAYBACK_MAX_STEPS_PER_RENDER do
				local frame = frames[playIndex]
				if not frame then
					stopPlay()
					break
				end
				if playbackAccumulator < timelineStep then
					break
				end

				local ok = applyFrame(playIndex)
				if not ok then
					stopPlay()
					break
				end
				appliedAny = true

				playbackAccumulator = playbackAccumulator - timelineStep
				playIndex = playIndex + 1
				steps = steps + 1
				if playIndex > #frames then
					stopPlay()
					break
				end
			end

			-- If we had a large lag spike, skip excess backlog to keep real-time speed.
			if mode == "play" and steps >= PLAYBACK_MAX_STEPS_PER_RENDER and playbackAccumulator > 0 then
				local extraSkip = math.floor(playbackAccumulator / timelineStep)
				if extraSkip > 0 then
					playIndex = math.min(playIndex + extraSkip, #frames + 1)
					playbackAccumulator = playbackAccumulator - (extraSkip * timelineStep)
				end
			end

			if mode == "play" and (not appliedAny) and playIndex > #frames then
				stopPlay()
			end
		end
	else
		lastPlaybackClock = 0
		lastRecordClock = 0
	end

	updateUI()
end)

connect(player.CharacterAdded, function()
	if mode == "record" then
		task.wait(0.05)
		applyRecordNoCollision()
	end
	if mode == "play" then
		task.wait(0.2)
		applyPlaybackLock()
	end
	task.wait(0.1)
	if adminState.noclip then
		adminSetNoclip(true)
	end
	if adminState.god then
		adminSetGod(true)
	end
	if adminState.trails then
		adminClearTrail()
		adminCreateTrail()
	end
end)

runtime.cleanup = function()
	if runtime.destroyed then
		return
	end
	runtime.destroyed = true

	pcall(function()
		mode = "idle"
		frozen = false
		seekDir = 0
	end)
	pcall(releaseAllVirtualInputs)
	pcall(function()
		if updatePlaybackInputOverlay then
			updatePlaybackInputOverlay(nil)
		end
	end)
	pcall(clearPlaybackLock)
	pcall(clearRecordFreezeLock)
	pcall(clearRecordNoCollision)
	pcall(function()
		if clearAdminRuntime then
			clearAdminRuntime()
		end
	end)
	pcall(function()
		setCameraPlaybackMode(false)
		camera.CameraType = startupCameraType or Enum.CameraType.Custom
		camera.CFrame = startupCameraCFrame or camera.CFrame
		if not isTouchDevice then
			UIS.MouseBehavior = startupMouseBehavior or Enum.MouseBehavior.Default
			shiftLockState = (startupShiftLockState == true)
		end
	end)
	pcall(disconnectAllConnections)
	pcall(function()
		if gui and gui.Parent then
			gui:Destroy()
		end
	end)
	if rawget(_G, RUNTIME_KEY) == runtime then
		_G[RUNTIME_KEY] = nil
	end
end

shiftLockState = isMouseLockCenter()

log("Loaded v0.9.0-rewrite. PlaceId: " .. tostring(game.PlaceId))
log("Playback mode: " .. playbackMode .. " (use 'playbackmode ghost|frameblend|smooth'; physics is an alias)")
log("Camera mode: " .. cameraMode .. " (use 'cameramode exact|smooth')")
log("Timeline FPS locked: " .. tostring(TIMELINE_FPS))
log("Virtual input playback: " .. (virtualInputPlaybackEnabled and "on" or "off") .. " (use 'inputs on|off')")
log("Record no-collision: " .. (recordNoCollisionEnabled and "on" or "off") .. " (use 'recordnocollision on|off')")
log("Playback hotkey moved to F10")
log("Admin panel ready: " .. tostring(#adminCommandOrder) .. " commands (button: Admin, command: admin)")
log("Press F2 to force hide/show GUI")
log("Type '/' to open command bar, then use 'help'")
updateUI()

