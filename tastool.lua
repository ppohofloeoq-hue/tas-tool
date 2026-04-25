--[[
TAS Lite v0.9.0 (Roblox, LocalScript/executor)
- Stable record/playback timing
- Fixed 60 FPS record/playback timeline
- Virtual input playback (keyboard + mouse buttons)
- Freeze/seek with safe frame indexing
- Checkpoints + append recording mode
- Save/load JSON (backward compatible with v0.1/v0.2 frames)
- On-screen log + record freeze/trim indicators
- Animated loading overlay + refreshed GUI
- Settings panel toggle via `+` button
- Playback mode: ghost (exact), frameblend (teleport + smooth), smooth
- Frameblend mode tuned for stable replay path following

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
	PLAYBACK_MODE = "frameblend", -- "ghost" | "frameblend" | "smooth" (physics is alias of frameblend)
	CAMERA_MODE = "smooth", -- "exact" | "smooth" for playback camera turns
	PHYSICS_CAMERA_SMOOTH_RATE = 22, -- higher = snappier, lower = smoother
	FRAMEBLEND_POSITION_ALPHA = 0.6, -- 0..1, higher = tighter path following
	FRAMEBLEND_ROTATION_ALPHA = 0.5, -- 0..1, higher = tighter look/rotation following
	FRAMEBLEND_SNAP_DISTANCE = 12, -- studs, hard snap if too far from target
	FRAMEBLEND_VELOCITY_BLEND = 0.45, -- smoothing for linear velocity copy
	FRAMEBLEND_ANGULAR_BLEND = 0.4, -- smoothing for angular velocity copy
	PHYSICS_HARD_SNAP_DISTANCE = 36,
	PHYSICS_SNAP_DISTANCE = 10,
	PHYSICS_SOFT_PULL_DISTANCE = 1.25,
	PHYSICS_SOFT_CORRECTION_GAIN = 7.0,
	PHYSICS_VERTICAL_CORRECTION_GAIN = 3.0,
	PHYSICS_MAX_CORRECTION_SPEED = 26,
	PHYSICS_MAX_VERTICAL_CORRECTION_SPEED = 14,
	PHYSICS_VELOCITY_BLEND = 0.55,
	PHYSICS_DYNAMIC_BLEND_GAIN = 0.02,
	PHYSICS_MIN_BLEND = 0.35,
	PHYSICS_MAX_BLEND = 0.95,
	PHYSICS_ANGULAR_BLEND = 0.35,
	PHYSICS_ORIENTATION_BLEND = 0.34,
	PHYSICS_ORIENTATION_DYNAMIC_GAIN = 0.012,
	PHYSICS_ORIENTATION_MIN_BLEND = 0.2,
	PHYSICS_ORIENTATION_MAX_BLEND = 0.72,
	PHYSICS_CORRECTION_BLEND = 0.35,
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

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local VirtualInputManager = game:GetService("VirtualInputManager")

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

local playbackSpeed = CONFIG.PLAYBACK_SPEED
local playbackMode = CONFIG.PLAYBACK_MODE
local cameraMode = CONFIG.CAMERA_MODE
local frameBlendPositionAlpha = CONFIG.FRAMEBLEND_POSITION_ALPHA
local frameBlendRotationAlpha = CONFIG.FRAMEBLEND_ROTATION_ALPHA
local playbackAccumulator = 0
local recordAccumulator = 0
local lastPlaybackClock = 0
local lastRecordClock = 0
local lastTrimmedCount = 0
local logLines = {}
local logLabel
local shiftLockState = false
local mainFrame
local timelineStep = 1 / CONFIG.TIMELINE_FPS
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

local function isFrameBlendMode()
	return playbackMode == "frameblend" or playbackMode == "physics"
end

local function normalizePlaybackModeValue(modeValue)
	local m = string.lower(tostring(modeValue or ""))
	if m == "physics" then
		return "frameblend"
	end
	if m == "ghost" or m == "frameblend" or m == "smooth" then
		return m
	end
	return "frameblend"
end

playbackMode = normalizePlaybackModeValue(playbackMode)

local function shouldReplayDriveCamera()
	-- On touch devices in frameblend/smooth mode, keep camera user-driven for natural control.
	if (isFrameBlendMode() or playbackMode == "smooth") and isTouchDevice and not frozen then
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
	local alpha = 1 - math.exp(-CONFIG.PHYSICS_CAMERA_SMOOTH_RATE * dt)
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

	if (playbackMode == "smooth" or isFrameBlendMode()) and not frozen then
		hum.WalkSpeed = playbackState.saved.WalkSpeed
		hum.JumpPower = playbackState.saved.JumpPower
		hum.AutoRotate = (playbackMode == "smooth")
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

	local shouldForceHumanoidState = (mode == "play") and ((not isFrameBlendMode()) or frozen)
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
	local pressed = pressedMapFromFrame(frame)

	if playbackMode == "ghost" or frozen then
		hrp.CFrame = rootCF
		hrp.AssemblyLinearVelocity = tableToV3(frame.vel)
		hrp.AssemblyAngularVelocity = tableToV3(frame.rotvel)
		lastPhysicsJumpHeld = false
	elseif isFrameBlendMode() then
		local targetVel = tableToV3(frame.vel)
		lastPhysicsJumpHeld = false
		local targetPos = rootCF.Position
		local currentPos = hrp.Position
		local deltaPos = targetPos - currentPos
		local dist = deltaPos.Magnitude
		local targetRot = rootCF - rootCF.Position

		if dist >= CONFIG.FRAMEBLEND_SNAP_DISTANCE then
			hrp.CFrame = rootCF
		else
			local posAlpha = math.clamp(frameBlendPositionAlpha, 0.05, 1)
			local rotAlpha = math.clamp(frameBlendRotationAlpha, 0.05, 1)
			local blendedPos = currentPos + (deltaPos * posAlpha)
			local currentRot = hrp.CFrame - currentPos
			local blendedRot = currentRot:Lerp(targetRot, rotAlpha)
			hrp.CFrame = CFrame.new(blendedPos) * (blendedRot - blendedRot.Position)
		end

		local velAlpha = math.clamp(CONFIG.FRAMEBLEND_VELOCITY_BLEND, 0.05, 1)
		local angAlpha = math.clamp(CONFIG.FRAMEBLEND_ANGULAR_BLEND, 0.05, 1)
		hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity:Lerp(targetVel, velAlpha)
		hrp.AssemblyAngularVelocity = hrp.AssemblyAngularVelocity:Lerp(tableToV3(frame.rotvel), angAlpha)
	else
		local targetVel = tableToV3(frame.vel)
		local posError = rootCF.Position - hrp.Position
		local dist = posError.Magnitude
		lastPhysicsJumpHeld = false

		if dist > CONFIG.PHYSICS_SNAP_DISTANCE then
			hrp.CFrame = rootCF
			hrp.AssemblyLinearVelocity = targetVel
			hrp.AssemblyAngularVelocity = tableToV3(frame.rotvel)
		else
			hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity:Lerp(targetVel, CONFIG.PHYSICS_VELOCITY_BLEND)
			hrp.AssemblyAngularVelocity = tableToV3(frame.rotvel)

			if dist > CONFIG.PHYSICS_SOFT_PULL_DISTANCE and dist > 0 then
				local correctionVel = posError * CONFIG.PHYSICS_SOFT_CORRECTION_GAIN
				local correctionMag = correctionVel.Magnitude
				if correctionMag > CONFIG.PHYSICS_MAX_CORRECTION_SPEED then
					correctionVel = correctionVel.Unit * CONFIG.PHYSICS_MAX_CORRECTION_SPEED
				end
				hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity:Lerp(
					hrp.AssemblyLinearVelocity + correctionVel,
					CONFIG.PHYSICS_CORRECTION_BLEND
				)
			end
		end
	end
	if shouldReplayDriveCamera() then
		if playbackMode == "smooth" and not frozen then
			local camLocalCF = tableToCf(frame.cam_local)
			if camLocalCF then
				camera.CFrame = hrp.CFrame * camLocalCF
			else
				camera.CFrame = camCF
			end
		elseif isFrameBlendMode() and not frozen then
			local targetCamCF = camCF
			if cameraMode == "exact" then
				camera.CFrame = targetCamCF
			else
				smoothCameraTo(targetCamCF)
			end
		else
			camera.CFrame = camCF
		end
	end
	camera.FieldOfView = tonumber(frame.fov) or 70
	if mode == "play" and not frozen then
		if isFrameBlendMode() then
			releaseAllVirtualInputs()
		else
			syncVirtualInputsToFrame(frame)
		end
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
		"Mode: %s | Frozen: %s | RecFreeze: %s | ShiftLock: %s | Frame: %d/%d | Trimmed: %d | RecordMode: %s | PlaybackMode: %s | CameraMode: %s | BlendPos: %.2f | TimelineFPS: %d | Inputs: %s | SeekSpeed: %.2f | PlaySpeed: %.2f\nF8 Rec  F10 Play  F6 Save  F7 Load  E Freeze  F/G Step  T/Y Seek  C/V Checkpoint  / Command  U UI  F2 Hide",
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
		frameBlendPositionAlpha,
		CONFIG.TIMELINE_FPS,
		virtualInputPlaybackEnabled and "ON" or "OFF",
		seekSpeed,
		playbackSpeed
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
titleLabel.Text = "TAS Tool  v0.9.0"
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
commandBar.PlaceholderText = "help | playbackmode frameblend | blend 0.6 | cameramode exact/smooth"
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
	elseif isFrameBlendMode() then
		nextMode = "smooth"
	else
		nextMode = "ghost"
	end
	playbackMode = normalizePlaybackModeValue(nextMode)
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
		-- Relative camera offset improves physics-mode camera/player alignment.
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
		version = "0.9.0",
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
	log("playbackmode <ghost|frameblend|smooth>")
	log("cameramode <exact|smooth>")
	log("recordmode <replace|append>")
	log("status")
	log("selfcheck")
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

	local args = string.split(trimmed, " ")
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
		if not newBlend then
			log("Usage: blend <0.05..1>")
			return
		end
		newBlend = math.clamp(newBlend, 0.05, 1)
		frameBlendPositionAlpha = newBlend
		log("Frameblend position alpha set to " .. string.format("%.2f", frameBlendPositionAlpha))
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
		local newMode = string.lower(args[2] or "")
		if newMode ~= "ghost" and newMode ~= "frameblend" and newMode ~= "physics" and newMode ~= "smooth" then
			log("Usage: playbackmode <ghost|frameblend|smooth>")
			return
		end
		playbackMode = normalizePlaybackModeValue(newMode)
		if mode == "play" then
			setCameraPlaybackMode(true)
			resetCameraSmoothingClock()
			applyPlaybackLock()
		end
		log("Playback mode set to " .. playbackMode)
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
			if recordAccumulator > CONFIG.PLAYBACK_MAX_ACCUMULATOR then
				recordAccumulator = CONFIG.PLAYBACK_MAX_ACCUMULATOR
			end

			local recordSteps = 0
			while recordAccumulator >= timelineStep and recordSteps < CONFIG.RECORD_MAX_STEPS_PER_RENDER do
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
			if playbackAccumulator > CONFIG.PLAYBACK_MAX_ACCUMULATOR then
				playbackAccumulator = CONFIG.PLAYBACK_MAX_ACCUMULATOR
			end

			local steps = 0
			local appliedAny = false
			while steps < CONFIG.PLAYBACK_MAX_STEPS_PER_RENDER do
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
			if mode == "play" and steps >= CONFIG.PLAYBACK_MAX_STEPS_PER_RENDER and playbackAccumulator > 0 then
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
		setCameraPlaybackMode(false)
		camera.CameraType = Enum.CameraType.Custom
		if not isTouchDevice then
			UIS.MouseBehavior = Enum.MouseBehavior.Default
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

log("Loaded v0.9.0. PlaceId: " .. tostring(game.PlaceId))
log("Playback mode: " .. playbackMode .. " (use 'playbackmode ghost|frameblend|smooth')")
log("Camera mode: " .. cameraMode .. " (use 'cameramode exact|smooth')")
log("Timeline FPS locked: " .. tostring(CONFIG.TIMELINE_FPS))
log("Virtual input playback: " .. (virtualInputPlaybackEnabled and "on" or "off") .. " (use 'inputs on|off')")
log("Record no-collision: " .. (recordNoCollisionEnabled and "on" or "off") .. " (use 'recordnocollision on|off')")
log("Playback hotkey moved to F10")
log("Press F2 to force hide/show GUI")
log("Type '/' to open command bar, then use 'help'")
updateUI()
