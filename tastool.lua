--[[
TAS Lite v0.9.0-rewrite (Roblox, LocalScript/executor)
Clean rewrite focused on stable 60 FPS record/playback.

Main ideas:
- Fixed timeline at 60 FPS for record and playback
- Playback modes:
  ghost      : exact frame teleport
  frameblend : frame teleport with partial smoothing between frames
  smooth     : softer interpolation mode
- Reliable shiftlock recording/replay
- Freeze/step/seek, checkpoints, save/load

Hotkeys:
F8  - start/stop record
F10 - start/stop playback
F6  - save replay
F7  - load replay
E   - freeze/unfreeze
F   - previous frame (frozen)
G   - next frame (frozen)
T/Y - seek backward/forward (auto-freeze)
C/V - set/goto quick checkpoint
U   - toggle UI
F2  - force hide/show UI
/   - focus command bar
]]

local CONFIG = {
	ROUND_DIGITS = 4,
	TIMELINE_FPS = 60,
	DEFAULT_FRAME_DT = 1 / 60,
	RECORD_MAX_STEPS_PER_RENDER = 12,
	PLAYBACK_MAX_STEPS_PER_RENDER = 24,
	PLAYBACK_MAX_ACCUMULATOR = 0.35,
	SEEK_SPEED = 1,
	PLAYBACK_SPEED = 1,
	PLAYBACK_MODE = "frameblend", -- ghost | frameblend | smooth | physics(alias)
	CAMERA_MODE = "exact", -- exact | smooth
	CAMERA_SMOOTH_RATE = 22,
	FRAMEBLEND_POSITION_ALPHA = 0.6, -- 0.05..1
	FRAMEBLEND_ROTATION_ALPHA = 0.45, -- 0.05..1
	FRAMEBLEND_SNAP_DISTANCE = 10,
	FRAMEBLEND_VELOCITY_BLEND = 0.45,
	FRAMEBLEND_ANGULAR_BLEND = 0.4,
	RECORD_NO_COLLISION = false,
	LOG_LINES = 8,
	FOLDER = "TASLite",
	FILE_NAME = "Replay.json",
}

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ContextActionService = game:GetService("ContextActionService")

local RUNTIME_KEY = "TASLiteRuntimeV9Rewrite"
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
local seekDir = 0
local frames = {}
local playIndex = 1
local checkpoints = {}
local QUICK_CP_NAME = "quick"
local heldKeys = {}

local uiVisible = true
local forceHideUI = false
local seekSpeed = CONFIG.SEEK_SPEED
local playbackSpeed = CONFIG.PLAYBACK_SPEED
local playbackMode = CONFIG.PLAYBACK_MODE
local cameraMode = CONFIG.CAMERA_MODE
local recordNoCollisionEnabled = CONFIG.RECORD_NO_COLLISION
local recordMode = "replace" -- replace | append

local frameBlendPositionAlpha = CONFIG.FRAMEBLEND_POSITION_ALPHA
local frameBlendRotationAlpha = CONFIG.FRAMEBLEND_ROTATION_ALPHA

local timelineStep = 1 / CONFIG.TIMELINE_FPS
local playbackAccumulator = 0
local recordAccumulator = 0
local lastPlaybackClock = 0
local lastRecordClock = 0
local lastTrimmedCount = 0

local shiftLockState = false
local lastRecordedShiftLockState = nil

local gui
local label
local commandBar
local logLabel
local logLines = {}

local playbackState = {
	active = false,
	humanoid = nil,
	hrp = nil,
	saved = nil,
}

local recordFreezeState = {
	active = false,
	hrp = nil,
	anchored = nil,
}

local recordNoCollisionState = {
	active = false,
	partTouch = {},
}

local HOTKEY_BLACKLIST = {
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

local function isFiniteNumber(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function toFiniteNumber(v, fallback)
	local n = tonumber(v)
	if isFiniteNumber(n) then
		return n
	end
	return fallback
end

local function round(n, digits)
	local m = 10 ^ (digits or 0)
	return math.floor(n * m + 0.5) / m
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

local function tableToCf(t)
	local clean = sanitizeCFrameTable(t)
	if not clean then
		return nil
	end
	return CFrame.new(unpack(clean))
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

local function v3ToTable(v)
	return { v.X, v.Y, v.Z }
end

local function tableToV3(t)
	local c = sanitizeV3Table(t, { 0, 0, 0 })
	return Vector3.new(c[1], c[2], c[3])
end

local function sanitizeFrameKeys(raw)
	if type(raw) ~= "table" then
		return {}
	end
	local out = {}
	local seen = {}
	for _, keyName in ipairs(raw) do
		if type(keyName) == "string" and #keyName > 0 and #keyName <= 32 and not seen[keyName] then
			seen[keyName] = true
			table.insert(out, keyName)
		end
	end
	return out
end

local function keysSnapshot()
	local out = {}
	for keyName, isDown in pairs(heldKeys) do
		if isDown then
			table.insert(out, keyName)
		end
	end
	table.sort(out)
	return out
end

local function shouldCaptureVirtualKey(keyName)
	return not HOTKEY_BLACKLIST[keyName]
end

local function normalizePlaybackModeValue(v)
	local m = string.lower(tostring(v or ""))
	if m == "physics" then
		return "frameblend"
	end
	if m == "ghost" or m == "frameblend" or m == "smooth" then
		return m
	end
	return "frameblend"
end

playbackMode = normalizePlaybackModeValue(playbackMode)

local function isFrameBlendMode()
	return playbackMode == "frameblend"
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

local function isMouseLockCenter()
	return UIS.MouseBehavior == Enum.MouseBehavior.LockCenter
end

local function isShiftLockActive()
	return shiftLockState == true
end

local function setShiftLockState(enabled, forceApply)
	local newState = (enabled == true)
	local changed = (newState ~= shiftLockState)
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
end

local function redrawLogLabel()
	if not logLabel then
		return
	end
	logLabel.Text = table.concat(logLines, "\n")
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

local function clearLog()
	logLines = {}
	redrawLogLabel()
end

local function clampIndex(idx)
	if #frames == 0 then
		return 1
	end
	local n = math.floor((idx or 1) + 0.5)
	return math.clamp(n, 1, #frames)
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
			out[name] = math.clamp(math.floor(n + 0.5), 1, frameCount)
		else
			dropped = dropped + 1
		end
	end
	return out, dropped
end

local function setCameraPlaybackMode(enabled)
	if enabled then
		if isTouchDevice and (isFrameBlendMode() or playbackMode == "smooth") and not frozen then
			camera.CameraType = Enum.CameraType.Custom
		else
			camera.CameraType = Enum.CameraType.Scriptable
		end
	else
		camera.CameraType = Enum.CameraType.Custom
	end
end

local cameraSmoothLast = 0
local function resetCameraSmoothingClock()
	cameraSmoothLast = tick()
end

local function smoothCameraTo(targetCF)
	local now = tick()
	local dt = 1 / 60
	if cameraSmoothLast > 0 then
		dt = math.clamp(now - cameraSmoothLast, 1 / 240, 0.06)
	end
	cameraSmoothLast = now
	local alpha = 1 - math.exp(-CONFIG.CAMERA_SMOOTH_RATE * dt)
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

	hum.WalkSpeed = 0
	hum.JumpPower = 0
	hum.AutoRotate = false
	hrp.Anchored = (frozen or playbackMode == "ghost")
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
	for part, old in pairs(recordNoCollisionState.partTouch) do
		if part and part.Parent then
			part.CanTouch = (old == true)
		end
	end
	recordNoCollisionState.partTouch = {}
	recordNoCollisionState.active = false
end

local function normalizeFrame(rawFrame)
	if type(rawFrame) ~= "table" then
		return nil
	end
	if rawFrame.root and rawFrame.cam then
		local root = sanitizeCFrameTable(rawFrame.root)
		local cam = sanitizeCFrameTable(rawFrame.cam)
		if not root or not cam then
			return nil
		end
		return {
			dt = math.clamp(toFiniteNumber(rawFrame.dt, CONFIG.DEFAULT_FRAME_DT), 1 / 1000, 1),
			root = root,
			vel = sanitizeV3Table(rawFrame.vel, { 0, 0, 0 }),
			rotvel = sanitizeV3Table(rawFrame.rotvel, { 0, 0, 0 }),
			cam = cam,
			cam_local = sanitizeCFrameTable(rawFrame.cam_local),
			fov = math.clamp(toFiniteNumber(rawFrame.fov, 70), 1, 120),
			hstate = type(rawFrame.hstate) == "string" and rawFrame.hstate or nil,
			shiftlock = rawFrame.shiftlock == true,
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
	if not hum or not hrp then
		return false
	end

	local rootCF = tableToCf(frame.root)
	local camCF = tableToCf(frame.cam)
	if not rootCF or not camCF then
		return false
	end

	if mode == "play" then
		setShiftLockState(frame.shiftlock == true, false)
	end

	local shouldApplyState = (mode == "play") and ((not isFrameBlendMode()) or frozen)
	if shouldApplyState and type(frame.hstate) == "string" then
		local stateEnum = Enum.HumanoidStateType[frame.hstate]
		if stateEnum then
			pcall(function()
				hum:ChangeState(stateEnum)
			end)
		end
	end

	if playbackMode == "ghost" or frozen then
		hrp.CFrame = rootCF
		hrp.AssemblyLinearVelocity = tableToV3(frame.vel)
		hrp.AssemblyAngularVelocity = tableToV3(frame.rotvel)
	elseif isFrameBlendMode() then
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
		hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity:Lerp(tableToV3(frame.vel), velAlpha)
		hrp.AssemblyAngularVelocity = hrp.AssemblyAngularVelocity:Lerp(tableToV3(frame.rotvel), angAlpha)
	else
		hrp.CFrame = hrp.CFrame:Lerp(rootCF, 0.2)
		hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity:Lerp(tableToV3(frame.vel), 0.3)
		hrp.AssemblyAngularVelocity = tableToV3(frame.rotvel)
	end

	if camera.CameraType == Enum.CameraType.Scriptable then
		if cameraMode == "smooth" then
			smoothCameraTo(camCF)
		else
			camera.CFrame = camCF
		end
	end
	camera.FieldOfView = toFiniteNumber(frame.fov, 70)
	return true
end

local function statusText()
	local recFreeze = (mode == "record" and frozen and "ON") or "OFF"
	return string.format(
		"Mode: %s | Frozen: %s | RecFreeze: %s | ShiftLock: %s | Frame: %d/%d | Trimmed: %d | RecordMode: %s | PlaybackMode: %s | CameraMode: %s | BlendPos: %.2f | FPS: %d | Seek: %.2f | Play: %.2f\nF8 Rec  F10 Play  F6 Save  F7 Load  E Freeze  F/G Step  T/Y Seek  C/V CP  / Command  U UI  F2 Hide",
		mode,
		tostring(frozen),
		recFreeze,
		isShiftLockActive() and "ON" or "OFF",
		playIndex,
		#frames,
		lastTrimmedCount,
		recordMode,
		playbackMode,
		cameraMode,
		frameBlendPositionAlpha,
		CONFIG.TIMELINE_FPS,
		seekSpeed,
		playbackSpeed
	)
end

local function getUIParent()
	if gethui then
		local ok, h = pcall(gethui)
		if ok and h then
			return h
		end
	end
	return game:GetService("CoreGui")
end

gui = Instance.new("ScreenGui")
gui.Name = "TASLiteUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(760, 360)
main.Position = UDim2.fromOffset(12, 12)
main.BackgroundColor3 = Color3.fromRGB(24, 29, 38)
main.BorderSizePixel = 0
main.Parent = gui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 10)
mainCorner.Parent = main

local top = Instance.new("TextLabel")
top.Size = UDim2.new(1, 0, 0, 32)
top.BackgroundColor3 = Color3.fromRGB(62, 96, 152)
top.BorderSizePixel = 0
top.Text = "TAS Tool v0.9.0-rewrite"
top.TextColor3 = Color3.fromRGB(240, 245, 255)
top.Font = Enum.Font.GothamBold
top.TextSize = 14
top.Parent = main

local topCorner = Instance.new("UICorner")
topCorner.CornerRadius = UDim.new(0, 10)
topCorner.Parent = top

label = Instance.new("TextLabel")
label.Size = UDim2.new(1, -20, 0, 96)
label.Position = UDim2.fromOffset(10, 40)
label.BackgroundColor3 = Color3.fromRGB(31, 38, 50)
label.BackgroundTransparency = 0.08
label.BorderSizePixel = 0
label.TextColor3 = Color3.fromRGB(235, 241, 251)
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextYAlignment = Enum.TextYAlignment.Top
label.Font = Enum.Font.Code
label.TextSize = 15
label.Text = ""
label.Parent = main

local labelCorner = Instance.new("UICorner")
labelCorner.CornerRadius = UDim.new(0, 8)
labelCorner.Parent = label

commandBar = Instance.new("TextBox")
commandBar.Size = UDim2.new(1, -20, 0, 30)
commandBar.Position = UDim2.fromOffset(10, 144)
commandBar.BackgroundColor3 = Color3.fromRGB(26, 33, 45)
commandBar.BackgroundTransparency = 0.08
commandBar.BorderSizePixel = 0
commandBar.TextColor3 = Color3.fromRGB(238, 244, 255)
commandBar.TextXAlignment = Enum.TextXAlignment.Left
commandBar.Font = Enum.Font.Code
commandBar.TextSize = 15
commandBar.PlaceholderText = "help | playbackmode frameblend | blend 0.6 | cameramode exact/smooth"
commandBar.ClearTextOnFocus = false
commandBar.Text = ""
commandBar.Parent = main

local cmdCorner = Instance.new("UICorner")
cmdCorner.CornerRadius = UDim.new(0, 8)
cmdCorner.Parent = commandBar

logLabel = Instance.new("TextLabel")
logLabel.Size = UDim2.new(1, -20, 1, -184)
logLabel.Position = UDim2.fromOffset(10, 180)
logLabel.BackgroundColor3 = Color3.fromRGB(23, 29, 40)
logLabel.BackgroundTransparency = 0.12
logLabel.BorderSizePixel = 0
logLabel.TextColor3 = Color3.fromRGB(190, 244, 213)
logLabel.TextXAlignment = Enum.TextXAlignment.Left
logLabel.TextYAlignment = Enum.TextYAlignment.Top
logLabel.Font = Enum.Font.Code
logLabel.TextSize = 13
logLabel.TextWrapped = false
logLabel.Text = ""
logLabel.Parent = main

local logCorner = Instance.new("UICorner")
logCorner.CornerRadius = UDim.new(0, 8)
logCorner.Parent = logLabel

gui.Parent = getUIParent()

local function updateUI()
	label.Text = statusText()
	gui.Enabled = (uiVisible and not forceHideUI)
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
		log("Checkpoint '" .. name .. "' invalid and removed")
		return false
	end
	playIndex = clampIndex(idx)
	applyFrame(playIndex)
	log("Goto checkpoint '" .. name .. "' -> frame " .. tostring(playIndex))
	return true
end

local function captureFrame(captureDt)
	local hum, hrp = humanoidAndRoot()
	if not hum or not hrp then
		return
	end

	local shiftNow = isMouseLockCenter()
	local nextFrame = #frames + 1
	if lastRecordedShiftLockState ~= nil and shiftNow ~= lastRecordedShiftLockState then
		log("ShiftLock " .. (shiftNow and "ON" or "OFF") .. " @ frame " .. tostring(nextFrame))
	end
	lastRecordedShiftLockState = shiftNow

	local frame = {
		dt = round(math.max(1 / 1000, captureDt or timelineStep), 5),
		root = roundArray(cfToTable(hrp.CFrame), CONFIG.ROUND_DIGITS),
		vel = roundArray(v3ToTable(hrp.AssemblyLinearVelocity), CONFIG.ROUND_DIGITS),
		rotvel = roundArray(v3ToTable(hrp.AssemblyAngularVelocity), CONFIG.ROUND_DIGITS),
		cam = roundArray(cfToTable(camera.CFrame), CONFIG.ROUND_DIGITS),
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
	log("Trimmed " .. tostring(trimmed) .. " frame(s)")
	return trimmed
end

local function setFrozen(newFrozen)
	if frozen == newFrozen then
		return
	end

	if mode == "record" then
		if newFrozen then
			playIndex = (#frames > 0) and clampIndex(playIndex) or 1
			recordAccumulator = 0
			applyRecordFreezeLock()
		else
			trimFutureFrames()
			clearRecordFreezeLock()
			recordAccumulator = 0
			lastRecordClock = tick()
			local hum, hrp = humanoidAndRoot()
			if hrp then
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

	clearPlaybackLock()
	clearRecordFreezeLock()
	clearRecordNoCollision()
	setCameraPlaybackMode(false)
	applyRecordNoCollision()

	shiftLockState = isMouseLockCenter()
	lastRecordedShiftLockState = shiftLockState

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

	clearRecordNoCollision()
	setCameraPlaybackMode(true)
	resetCameraSmoothingClock()
	applyPlaybackLock()
	local warmup = applyFrame(playIndex)
	if warmup then
		playIndex = math.min(playIndex + 1, #frames + 1)
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
		log("Replay loaded but no valid frames")
		return
	end

	frames = normalized
	checkpoints, _ = sanitizeCheckpoints(data.checkpoints, #frames)
	playIndex = 1
	lastTrimmedCount = 0
	log("Loaded replay. Frames: " .. tostring(#frames))
	if droppedFrames > 0 then
		log("Dropped invalid frames: " .. tostring(droppedFrames))
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
	clearPlaybackLock()
	clearRecordFreezeLock()
	clearRecordNoCollision()
	setCameraPlaybackMode(false)
	saveReplay()
	log("Replay erased")
end

local function commandHelp()
	log("Commands:")
	log("help")
	log("erase")
	log("setspeed <number>")
	log("playspeed <number>")
	log("blend <0.05..1>")
	log("playbackmode <ghost|frameblend|smooth>")
	log("cameramode <exact|smooth>")
	log("recordmode <replace|append>")
	log("recordnocollision <on|off>")
	log("status")
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
		local n = tonumber(args[2])
		if not n or n <= 0 then
			log("Usage: setspeed <number > 0>")
			return
		end
		seekSpeed = n
		log("Seek speed set to " .. tostring(seekSpeed))
		return
	end
	if cmd == "playspeed" then
		local n = tonumber(args[2])
		if not n or n <= 0 then
			log("Usage: playspeed <number > 0>")
			return
		end
		playbackSpeed = n
		log("Playback speed set to " .. tostring(playbackSpeed))
		return
	end
	if cmd == "blend" then
		local n = tonumber(args[2])
		if not n then
			log("Usage: blend <0.05..1>")
			return
		end
		frameBlendPositionAlpha = math.clamp(n, 0.05, 1)
		log("BlendPos set to " .. string.format("%.2f", frameBlendPositionAlpha))
		return
	end
	if cmd == "playbackmode" then
		local m = normalizePlaybackModeValue(args[2])
		playbackMode = m
		if mode == "play" then
			setCameraPlaybackMode(true)
			resetCameraSmoothingClock()
			applyPlaybackLock()
		end
		log("Playback mode set to " .. playbackMode)
		return
	end
	if cmd == "cameramode" then
		local m = string.lower(args[2] or "")
		if m ~= "exact" and m ~= "smooth" then
			log("Usage: cameramode <exact|smooth>")
			return
		end
		cameraMode = m
		resetCameraSmoothingClock()
		log("Camera mode set to " .. cameraMode)
		return
	end
	if cmd == "recordmode" then
		local m = string.lower(args[2] or "")
		if m ~= "replace" and m ~= "append" then
			log("Usage: recordmode <replace|append>")
			return
		end
		recordMode = m
		log("Record mode set to " .. recordMode)
		return
	end
	if cmd == "recordnocollision" then
		local m = string.lower(args[2] or "")
		if m ~= "on" and m ~= "off" then
			log("Usage: recordnocollision <on|off>")
			return
		end
		recordNoCollisionEnabled = (m == "on")
		if not recordNoCollisionEnabled then
			clearRecordNoCollision()
		elseif mode == "record" then
			applyRecordNoCollision()
		end
		log("Record no-collision set to " .. m)
		return
	end
	if cmd == "status" then
		log(statusText())
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
			setCheckpoint(args[3] or QUICK_CP_NAME, tonumber(args[4]))
			return
		end
		if action == "goto" then
			gotoCheckpoint(args[3] or QUICK_CP_NAME)
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
		if mode == "record" or mode == "play" then
			setFrozen(not frozen)
		end
	elseif kc == Enum.KeyCode.F then
		if (mode == "record" or mode == "play") and frozen then
			playIndex = clampIndex(playIndex - 1)
			applyFrame(playIndex)
		end
	elseif kc == Enum.KeyCode.G then
		if (mode == "record" or mode == "play") and frozen then
			playIndex = clampIndex(playIndex + 1)
			applyFrame(playIndex)
		end
	elseif kc == Enum.KeyCode.T then
		if mode == "record" or mode == "play" then
			if not frozen then
				setFrozen(true)
			end
			seekDir = -1
		end
	elseif kc == Enum.KeyCode.Y then
		if mode == "record" or mode == "play" then
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

			local steps = 0
			while recordAccumulator >= timelineStep and steps < CONFIG.RECORD_MAX_STEPS_PER_RENDER do
				captureFrame(timelineStep)
				recordAccumulator = recordAccumulator - timelineStep
				steps = steps + 1
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
			while steps < CONFIG.PLAYBACK_MAX_STEPS_PER_RENDER do
				if playbackAccumulator < timelineStep then
					break
				end
				local frame = frames[playIndex]
				if not frame then
					stopPlay()
					break
				end

				local ok = applyFrame(playIndex)
				if not ok then
					stopPlay()
					break
				end
				playbackAccumulator = playbackAccumulator - timelineStep
				playIndex = playIndex + 1
				steps = steps + 1
				if playIndex > #frames then
					stopPlay()
					break
				end
			end
		end
	else
		lastRecordClock = 0
		lastPlaybackClock = 0
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

log("Loaded v0.9.0-rewrite. PlaceId: " .. tostring(game.PlaceId))
log("Playback mode: " .. playbackMode .. " (playbackmode ghost|frameblend|smooth)")
log("Timeline FPS locked: " .. tostring(CONFIG.TIMELINE_FPS))
log("Type '/' for command bar and 'help'")
updateUI()
