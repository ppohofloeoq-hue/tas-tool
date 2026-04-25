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
- Playback mode: ghost (exact) or physics (with collisions)
- Physics mode tuned for more human-like motion

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
	ROUND_DIGITS = 3,
	TIMELINE_FPS = 60,
	DEFAULT_FRAME_DT = 1 / 60,
	VIRTUAL_INPUT_PLAYBACK = true,
	RECORD_NO_COLLISION = false, -- Keep touch/collision triggers active while recording.
	RECORD_MAX_STEPS_PER_RENDER = 12, -- cap catch-up work during lag spikes
	SEEK_SPEED = 1, -- frames per render step while holding T/Y
	PLAYBACK_SPEED = 1, -- realtime multiplier
	PLAYBACK_MAX_ACCUMULATOR = 0.35, -- seconds; drops excessive backlog to avoid slow-motion replay
	PLAYBACK_MAX_STEPS_PER_RENDER = 24, -- max simulated replay steps per render frame
	PLAYBACK_MODE = "physics", -- "ghost" | "physics" | "smooth"
	PHYSICS_SNAP_DISTANCE = 10,
	PHYSICS_SOFT_PULL_DISTANCE = 1.25,
	PHYSICS_SOFT_CORRECTION_GAIN = 7.0,
	PHYSICS_MAX_CORRECTION_SPEED = 26,
	PHYSICS_VELOCITY_BLEND = 0.55,
	PHYSICS_CORRECTION_BLEND = 0.35,
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
local playbackAccumulator = 0
local recordAccumulator = 0
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
local inputOverlayFrame
local inputOverlayLabel
local shiftLockIndicator

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

local function isShiftLockActive()
	return UIS.MouseBehavior == Enum.MouseBehavior.LockCenter
end

local function callRobloxShiftLockToggle()
	pcall(function()
		ContextActionService:CallFunction("MouseLockSwitchAction", Enum.UserInputState.Begin, game)
	end)
end

local function setShiftLockState(enabled)
	shiftLockState = (enabled == true)
	if isTouchDevice then
		return
	end

	if isShiftLockActive() ~= shiftLockState then
		callRobloxShiftLockToggle()
	end
	if isShiftLockActive() ~= shiftLockState then
		UIS.MouseBehavior = shiftLockState and Enum.MouseBehavior.LockCenter or Enum.MouseBehavior.Default
	end
end

local function handleShiftLockKey()
	if isTouchDevice then
		return
	end

	local before = isShiftLockActive()
	task.defer(function()
		local after = isShiftLockActive()
		if after == before then
			setShiftLockState(not before)
		else
			shiftLockState = after
		end
	end)
end

local function shouldReplayDriveCamera()
	-- On touch devices in physics mode, keep camera user-driven for natural control.
	if (playbackMode == "physics" or playbackMode == "smooth") and isTouchDevice and not frozen then
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
	if type(t) ~= "table" or #t < 12 then
		return nil
	end
	return CFrame.new(unpack(t))
end

local function v3ToTable(v)
	return { v.X, v.Y, v.Z }
end

local function tableToV3(t)
	if type(t) ~= "table" or #t < 3 then
		return Vector3.new()
	end
	return Vector3.new(t[1], t[2], t[3])
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

local function sendVirtualInputState(keyName, isDown)
	if not virtualInputPlaybackEnabled then
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
			sendVirtualInputState(keyName, false)
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
	return player.Character or player.CharacterAdded:Wait()
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

	if playbackMode == "smooth" and not frozen then
		hum.WalkSpeed = playbackState.saved.WalkSpeed
		hum.JumpPower = playbackState.saved.JumpPower
		hum.AutoRotate = true
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
		local dt = tonumber(rawFrame.dt) or CONFIG.DEFAULT_FRAME_DT
		return {
			dt = math.max(dt, 1 / 1000),
			root = rawFrame.root,
			vel = rawFrame.vel or { 0, 0, 0 },
			rotvel = rawFrame.rotvel or { 0, 0, 0 },
			cam = rawFrame.cam,
			cam_local = rawFrame.cam_local,
			fov = tonumber(rawFrame.fov) or 70,
			hstate = rawFrame.hstate,
			shiftlock = (rawFrame.shiftlock == true),
			keys = type(rawFrame.keys) == "table" and rawFrame.keys or {},
		}
	end

	return nil
end

local function normalizeFrames(rawFrames)
	if type(rawFrames) ~= "table" then
		return {}
	end
	local out = {}
	for i, frame in ipairs(rawFrames) do
		local n = normalizeFrame(frame)
		if n then
			out[i] = n
		end
	end
	return out
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

	if type(frame.hstate) == "string" then
		local stateEnum = Enum.HumanoidStateType[frame.hstate]
		if stateEnum then
			pcall(function()
				hum:ChangeState(stateEnum)
			end)
		end
	end

	setShiftLockState(frame.shiftlock == true)

	if playbackMode == "ghost" or playbackMode == "physics" or frozen then
		hrp.CFrame = rootCF
		hrp.AssemblyLinearVelocity = tableToV3(frame.vel)
		hrp.AssemblyAngularVelocity = tableToV3(frame.rotvel)
	else
		local targetVel = tableToV3(frame.vel)
		local posError = rootCF.Position - hrp.Position
		local dist = posError.Magnitude

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
		if (playbackMode == "physics" or playbackMode == "smooth") and not frozen then
			local camLocalCF = tableToCf(frame.cam_local)
			if camLocalCF then
				camera.CFrame = hrp.CFrame * camLocalCF
			else
				camera.CFrame = camCF
			end
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
	updatePlaybackInputOverlay(frame)
	return true
end

local function updatePlaybackInputOverlay(frame)
	if not inputOverlayFrame or not inputOverlayLabel then
		return
	end

	if mode ~= "play" or type(frame) ~= "table" then
		inputOverlayFrame.Visible = false
		return
	end

	local keys = frame.keys or {}
	local text = "Inputs: -"
	if #keys > 0 then
		text = "Inputs: " .. table.concat(keys, " | ")
	end
	inputOverlayLabel.Text = text
	inputOverlayFrame.Visible = true
end

local function refreshSettingsUI()
	if settingsInputsBtn then
		settingsInputsBtn.Text = "Inputs: " .. (virtualInputPlaybackEnabled and "ON" or "OFF")
		settingsInputsBtn.BackgroundColor3 = virtualInputPlaybackEnabled and Color3.fromRGB(26, 76, 50) or Color3.fromRGB(70, 33, 33)
	end
	if settingsPlaybackModeBtn then
		settingsPlaybackModeBtn.Text = "Playback: " .. tostring(playbackMode)
	end
	if settingsRecordNoColBtn then
		settingsRecordNoColBtn.Text = "RecNoCol: " .. (recordNoCollisionEnabled and "ON" or "OFF")
		settingsRecordNoColBtn.BackgroundColor3 = recordNoCollisionEnabled and Color3.fromRGB(74, 56, 18) or Color3.fromRGB(29, 56, 84)
	end
	if settingsRecordModeBtn then
		settingsRecordModeBtn.Text = "RecMode: " .. tostring(recordMode)
	end
	if settingsPlaySpeedBtn then
		settingsPlaySpeedBtn.Text = string.format("PlaySpeed: %.2f", playbackSpeed)
	end
end

local function statusText()
	local recordFreezeText = (mode == "record" and frozen and "ON") or "OFF"
	local shiftStateText = isShiftLockActive() and "ON" or "OFF"
	return string.format(
		"Mode: %s | Frozen: %s | RecFreeze: %s | ShiftLock: %s | Frame: %d/%d | Trimmed: %d | RecordMode: %s | PlaybackMode: %s | TimelineFPS: %d | Inputs: %s | SeekSpeed: %.2f | PlaySpeed: %.2f\nF8 Rec  F10 Play  F6 Save  F7 Load  E Freeze  F/G Step  T/Y Seek  C/V Checkpoint  / Command  U UI  F2 Hide",
		mode,
		tostring(frozen),
		recordFreezeText,
		shiftStateText,
		playIndex,
		#frames,
		lastTrimmedCount,
		recordMode,
		playbackMode,
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
mainFrame.BackgroundColor3 = Color3.fromRGB(18, 22, 30)
mainFrame.BorderSizePixel = 0
mainFrame.ClipsDescendants = true
mainFrame.Parent = gui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 8)
mainCorner.Parent = mainFrame

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Color3.fromRGB(70, 120, 205)
mainStroke.Thickness = 1.5
mainStroke.Transparency = 0.15
mainStroke.Parent = mainFrame

local topBar = Instance.new("Frame")
topBar.Size = UDim2.new(1, 0, 0, 36)
topBar.BackgroundColor3 = Color3.fromRGB(24, 33, 47)
topBar.BorderSizePixel = 0
topBar.Parent = mainFrame

local topGrad = Instance.new("UIGradient")
topGrad.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(66, 112, 189)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(34, 57, 97)),
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
shiftLockIndicator.BackgroundColor3 = Color3.fromRGB(76, 40, 40)
shiftLockIndicator.BackgroundTransparency = 0.15
shiftLockIndicator.BorderSizePixel = 0
shiftLockIndicator.TextColor3 = Color3.fromRGB(255, 226, 226)
shiftLockIndicator.Font = Enum.Font.GothamSemibold
shiftLockIndicator.TextSize = 12
shiftLockIndicator.Text = "ShiftLock REC: OFF"
shiftLockIndicator.Parent = topBar

local shiftCorner = Instance.new("UICorner")
shiftCorner.CornerRadius = UDim.new(0, 6)
shiftCorner.Parent = shiftLockIndicator

local label = Instance.new("TextLabel")
label.Size = UDim2.new(1, -20, 0, 96)
label.Position = UDim2.fromOffset(10, 44)
label.BackgroundColor3 = Color3.fromRGB(14, 18, 26)
label.BackgroundTransparency = 0.08
label.BorderSizePixel = 0
label.TextColor3 = Color3.fromRGB(224, 232, 247)
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextYAlignment = Enum.TextYAlignment.Top
label.Font = Enum.Font.Code
label.TextSize = 15
label.Text = ""
label.Parent = mainFrame

local labelCorner = Instance.new("UICorner")
labelCorner.CornerRadius = UDim.new(0, 6)
labelCorner.Parent = label

local commandBar = Instance.new("TextBox")
commandBar.Size = UDim2.new(1, -20, 0, 30)
commandBar.Position = UDim2.fromOffset(10, 148)
commandBar.BackgroundColor3 = Color3.fromRGB(10, 13, 20)
commandBar.BackgroundTransparency = 0.05
commandBar.TextColor3 = Color3.fromRGB(232, 240, 255)
commandBar.BorderSizePixel = 0
commandBar.TextXAlignment = Enum.TextXAlignment.Left
commandBar.Font = Enum.Font.Code
commandBar.PlaceholderText = "help | inputs on/off | playbackmode physics/ghost/smooth | recordnocollision on/off"
commandBar.TextSize = 15
commandBar.ClearTextOnFocus = false
commandBar.Text = ""
commandBar.Parent = mainFrame

local commandCorner = Instance.new("UICorner")
commandCorner.CornerRadius = UDim.new(0, 6)
commandCorner.Parent = commandBar

settingsFrame = Instance.new("Frame")
settingsFrame.Size = UDim2.new(1, -20, 0, 32)
settingsFrame.Position = UDim2.fromOffset(10, 186)
settingsFrame.BackgroundTransparency = 1
settingsFrame.Parent = mainFrame

local settingsLayout = Instance.new("UIListLayout")
settingsLayout.FillDirection = Enum.FillDirection.Horizontal
settingsLayout.Padding = UDim.new(0, 8)
settingsLayout.SortOrder = Enum.SortOrder.LayoutOrder
settingsLayout.Parent = settingsFrame

local function makeSettingButton()
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.fromOffset(145, 32)
	btn.BackgroundColor3 = Color3.fromRGB(27, 38, 56)
	btn.BorderSizePixel = 0
	btn.TextColor3 = Color3.fromRGB(230, 238, 255)
	btn.Font = Enum.Font.GothamSemibold
	btn.TextSize = 12
	btn.AutoButtonColor = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = btn
	return btn
end

settingsInputsBtn = makeSettingButton()
settingsInputsBtn.Parent = settingsFrame
settingsPlaybackModeBtn = makeSettingButton()
settingsPlaybackModeBtn.Parent = settingsFrame
settingsRecordNoColBtn = makeSettingButton()
settingsRecordNoColBtn.Parent = settingsFrame
settingsRecordModeBtn = makeSettingButton()
settingsRecordModeBtn.Parent = settingsFrame
settingsPlaySpeedBtn = makeSettingButton()
settingsPlaySpeedBtn.Parent = settingsFrame

logLabel = Instance.new("TextLabel")
logLabel.Size = UDim2.new(1, -20, 1, -228)
logLabel.Position = UDim2.fromOffset(10, 224)
logLabel.BackgroundColor3 = Color3.fromRGB(9, 12, 18)
logLabel.BackgroundTransparency = 0.05
logLabel.TextColor3 = Color3.fromRGB(177, 255, 205)
logLabel.TextXAlignment = Enum.TextXAlignment.Left
logLabel.TextYAlignment = Enum.TextYAlignment.Top
logLabel.Font = Enum.Font.Code
logLabel.TextSize = 13
logLabel.BorderSizePixel = 0
logLabel.TextWrapped = false
logLabel.Text = ""
logLabel.Parent = mainFrame

local logCorner = Instance.new("UICorner")
logCorner.CornerRadius = UDim.new(0, 6)
logCorner.Parent = logLabel

inputOverlayFrame = Instance.new("Frame")
inputOverlayFrame.Size = UDim2.fromOffset(270, 34)
inputOverlayFrame.Position = UDim2.new(1, -280, 0, 44)
inputOverlayFrame.BackgroundColor3 = Color3.fromRGB(13, 19, 30)
inputOverlayFrame.BackgroundTransparency = 0.08
inputOverlayFrame.BorderSizePixel = 0
inputOverlayFrame.Visible = false
inputOverlayFrame.Parent = mainFrame

local inputOverlayCorner = Instance.new("UICorner")
inputOverlayCorner.CornerRadius = UDim.new(0, 6)
inputOverlayCorner.Parent = inputOverlayFrame

local inputOverlayStroke = Instance.new("UIStroke")
inputOverlayStroke.Color = Color3.fromRGB(78, 137, 222)
inputOverlayStroke.Transparency = 0.15
inputOverlayStroke.Thickness = 1
inputOverlayStroke.Parent = inputOverlayFrame

inputOverlayLabel = Instance.new("TextLabel")
inputOverlayLabel.Size = UDim2.new(1, -12, 1, 0)
inputOverlayLabel.Position = UDim2.fromOffset(8, 0)
inputOverlayLabel.BackgroundTransparency = 1
inputOverlayLabel.TextXAlignment = Enum.TextXAlignment.Left
inputOverlayLabel.TextYAlignment = Enum.TextYAlignment.Center
inputOverlayLabel.Font = Enum.Font.Code
inputOverlayLabel.TextSize = 12
inputOverlayLabel.TextColor3 = Color3.fromRGB(205, 229, 255)
inputOverlayLabel.Text = "Inputs: -"
inputOverlayLabel.Parent = inputOverlayFrame

local loadingOverlay = Instance.new("Frame")
loadingOverlay.Size = UDim2.fromScale(1, 1)
loadingOverlay.BackgroundColor3 = Color3.fromRGB(7, 10, 16)
loadingOverlay.BackgroundTransparency = 0.08
loadingOverlay.BorderSizePixel = 0
loadingOverlay.ZIndex = 100
loadingOverlay.Parent = gui

local loadingPanel = Instance.new("Frame")
loadingPanel.Size = UDim2.fromOffset(440, 150)
loadingPanel.AnchorPoint = Vector2.new(0.5, 0.5)
loadingPanel.Position = UDim2.fromScale(0.5, 0.5)
loadingPanel.BackgroundColor3 = Color3.fromRGB(17, 24, 36)
loadingPanel.BorderSizePixel = 0
loadingPanel.ZIndex = 101
loadingPanel.Parent = loadingOverlay

local loadCorner = Instance.new("UICorner")
loadCorner.CornerRadius = UDim.new(0, 8)
loadCorner.Parent = loadingPanel

local loadStroke = Instance.new("UIStroke")
loadStroke.Color = Color3.fromRGB(74, 130, 220)
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
loadHint.TextColor3 = Color3.fromRGB(165, 187, 227)
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
loadTrack.BackgroundColor3 = Color3.fromRGB(35, 44, 59)
loadTrack.BorderSizePixel = 0
loadTrack.ZIndex = 101
loadTrack.Parent = loadingPanel

local loadTrackCorner = Instance.new("UICorner")
loadTrackCorner.CornerRadius = UDim.new(0, 7)
loadTrackCorner.Parent = loadTrack

local loadFill = Instance.new("Frame")
loadFill.Size = UDim2.fromScale(0, 1)
loadFill.BackgroundColor3 = Color3.fromRGB(105, 203, 255)
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
		nextMode = "physics"
	elseif playbackMode == "physics" then
		nextMode = "smooth"
	else
		nextMode = "ghost"
	end
	playbackMode = nextMode
	if mode == "play" then
		setCameraPlaybackMode(true)
		applyPlaybackLock()
	end
	log("Playback mode set to " .. playbackMode)
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

settingsInputsBtn.MouseButton1Click:Connect(function()
	virtualInputPlaybackEnabled = not virtualInputPlaybackEnabled
	if not virtualInputPlaybackEnabled then
		releaseAllVirtualInputs()
	end
	log("Virtual input playback set to " .. (virtualInputPlaybackEnabled and "on" or "off"))
	refreshSettingsUI()
end)

settingsPlaybackModeBtn.MouseButton1Click:Connect(cyclePlaybackMode)

settingsRecordNoColBtn.MouseButton1Click:Connect(function()
	recordNoCollisionEnabled = not recordNoCollisionEnabled
	if not recordNoCollisionEnabled then
		clearRecordNoCollision()
	elseif mode == "record" then
		applyRecordNoCollision()
	end
	log("Record no-collision set to " .. (recordNoCollisionEnabled and "on" or "off"))
	refreshSettingsUI()
end)

settingsRecordModeBtn.MouseButton1Click:Connect(cycleRecordMode)

settingsPlaySpeedBtn.MouseButton1Click:Connect(function()
	local nextSpeed = playbackSpeed + 0.25
	if nextSpeed > 2 then
		nextSpeed = 0.5
	end
	playbackSpeed = nextSpeed
	log("Playback speed set to " .. string.format("%.2f", playbackSpeed))
	refreshSettingsUI()
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

local function updateUI()
	label.Text = statusText()
	if shiftLockIndicator then
		local shiftOn = isShiftLockActive()
		shiftLockIndicator.Text = "ShiftLock REC: " .. (shiftOn and "ON" or "OFF")
		if shiftOn then
			shiftLockIndicator.BackgroundColor3 = Color3.fromRGB(32, 95, 63)
			shiftLockIndicator.TextColor3 = Color3.fromRGB(210, 255, 231)
		else
			shiftLockIndicator.BackgroundColor3 = Color3.fromRGB(76, 40, 40)
			shiftLockIndicator.TextColor3 = Color3.fromRGB(255, 226, 226)
		end
	end
	if inputOverlayFrame then
		inputOverlayFrame.Visible = (mode == "play")
	end
	refreshSettingsUI()
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
	local idx = checkpoints[name]
	if not idx then
		log("Checkpoint '" .. name .. "' not found")
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
			applyRecordFreezeLock()
		else
			trimFutureFrames()
			clearRecordFreezeLock()
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
		applyPlaybackLock()
	end
end

local function startRecord()
	mode = "record"
	setFrozen(false)
	seekDir = 0
	playbackAccumulator = 0
	recordAccumulator = 0
	releaseAllVirtualInputs()
	updatePlaybackInputOverlay(nil)
	clearPlaybackLock()
	clearRecordFreezeLock()
	clearRecordNoCollision()
	setCameraPlaybackMode(false)
	applyRecordNoCollision()
	shiftLockState = isShiftLockActive()
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
	lastRecordedShiftLockState = nil
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
	playbackAccumulator = 0
	recordAccumulator = 0
	releaseAllVirtualInputs()
	updatePlaybackInputOverlay(nil)
	clearRecordNoCollision()
	setCameraPlaybackMode(true)
	applyPlaybackLock()
	applyFrame(playIndex)
	playIndex = math.min(playIndex + 1, #frames + 1)
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
	releaseAllVirtualInputs()
	updatePlaybackInputOverlay(nil)
	clearPlaybackLock()
	setCameraPlaybackMode(false)
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

	local normalized = normalizeFrames(data.frames)
	if #normalized == 0 then
		log("Replay loaded but no valid frames found")
		return
	end

	frames = normalized
	checkpoints = type(data.checkpoints) == "table" and data.checkpoints or {}
	playIndex = 1
	lastTrimmedCount = 0
	log("Loaded replay. Frames: " .. tostring(#frames))
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
	log("inputs <on|off>")
	log("recordnocollision <on|off>")
	log("playbackmode <ghost|physics|smooth>")
	log("recordmode <replace|append>")
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
		if newMode ~= "ghost" and newMode ~= "physics" and newMode ~= "smooth" then
			log("Usage: playbackmode <ghost|physics|smooth>")
			return
		end
		playbackMode = newMode
		if mode == "play" then
			setCameraPlaybackMode(true)
			applyPlaybackLock()
		end
		log("Playback mode set to " .. playbackMode)
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

UIS.InputBegan:Connect(function(input, gp)
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
	if gp then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	local kc = input.KeyCode
	if kc == Enum.KeyCode.LeftShift or kc == Enum.KeyCode.RightShift then
		handleShiftLockKey()
	end

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

UIS.InputEnded:Connect(function(input)
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

commandBar.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		runCommand(commandBar.Text)
	end
	commandBar.Text = ""
	updateUI()
end)

RunService.RenderStepped:Connect(function(dt)
	if mode == "record" then
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
			recordAccumulator = recordAccumulator + dt
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
			playbackAccumulator = playbackAccumulator + (dt * playbackSpeed)
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
	end

	updateUI()
end)

player.CharacterAdded:Connect(function()
	if mode == "record" then
		task.wait(0.05)
		applyRecordNoCollision()
	end
	if mode == "play" then
		task.wait(0.2)
		applyPlaybackLock()
	end
end)

shiftLockState = isShiftLockActive()

log("Loaded v0.9.0. PlaceId: " .. tostring(game.PlaceId))
log("Playback mode: " .. playbackMode .. " (use 'playbackmode ghost|physics|smooth')")
log("Timeline FPS locked: " .. tostring(CONFIG.TIMELINE_FPS))
log("Virtual input playback: " .. (virtualInputPlaybackEnabled and "on" or "off") .. " (use 'inputs on|off')")
log("Record no-collision: " .. (recordNoCollisionEnabled and "on" or "off") .. " (use 'recordnocollision on|off')")
log("Playback hotkey moved to F10")
log("Press F2 to force hide/show GUI")
log("Type '/' to open command bar, then use 'help'")
updateUI()
