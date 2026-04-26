--[[
TAS Lite v0.9.0-rewrite (Roblox, LocalScript/executor)

Hotkeys:
F8  - start/stop record
F10 - start/stop playback
F6  - save replay
F7  - load replay
E   - freeze/unfreeze
F   - previous frame when frozen
G   - next frame when frozen
T/Y - hold seek backward/forward with auto-freeze
C   - set quick checkpoint
V   - goto quick checkpoint
U   - toggle UI
F2  - force hide/show UI
Slash (/) - focus command bar
]]

local VERSION = "TAS Lite v0.9.0-rewrite (Roblox, LocalScript/executor)"
local RUNTIME_KEY = "TASLiteRuntime_v090_Rewrite"

local TIMELINE_FPS = 60
local timelineStep = 1 / TIMELINE_FPS
local RECORD_MAX_STEPS_PER_RENDER = 12
local PLAYBACK_MAX_STEPS_PER_RENDER = 24
local PLAYBACK_MAX_ACCUMULATOR = 0.35
local PLAYBACK_SPEED = 1

local FRAMEBLEND_POSITION_ALPHA = 0.6
local FRAMEBLEND_ROTATION_ALPHA = 0.45
local FRAMEBLEND_SNAP_DISTANCE = 10
local FRAMEBLEND_VELOCITY_BLEND = 0.45
local FRAMEBLEND_ANGULAR_BLEND = 0.4

local SMOOTH_POSITION_ALPHA = 0.28
local SMOOTH_ROTATION_ALPHA = 0.22
local SMOOTH_VELOCITY_BLEND = 0.25
local SMOOTH_ANGULAR_BLEND = 0.22
local CAMERA_SMOOTH_RATE = 18

local SAVE_FOLDER = "TASLite"
local SAVE_FILE = tostring(game.PlaceId) .. "_Replay.json"
local SAVE_PATH = SAVE_FOLDER .. "/" .. SAVE_FILE

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")
local VirtualInputManager
pcall(function()
	VirtualInputManager = game:GetService("VirtualInputManager")
end)

local oldRuntime = rawget(_G, RUNTIME_KEY)
if type(oldRuntime) == "table" and type(oldRuntime.cleanup) == "function" then
	pcall(oldRuntime.cleanup)
end

local runtime = {
	connections = {},
	gui = nil,
	cleaning = false,
}
_G[RUNTIME_KEY] = runtime

local function connect(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(runtime.connections, connection)
	return connection
end

local function disconnectAll()
	for i = #runtime.connections, 1, -1 do
		local connection = runtime.connections[i]
		runtime.connections[i] = nil
		if connection then
			pcall(function()
				connection:Disconnect()
			end)
		end
	end
end

local localPlayer = Players.LocalPlayer
if not localPlayer then
	warn("[TAS Lite] LocalPlayer is missing")
	return
end

local camera = workspace.CurrentCamera
if not camera then
	repeat
		RunService.RenderStepped:Wait()
		camera = workspace.CurrentCamera
	until camera
end

local startCameraType = camera.CameraType
local startCameraSubject = camera.CameraSubject
local startMouseBehavior = UserInputService.MouseBehavior

local mode = "idle"
local frames = {}
local playIndex = 1
local recordAccumulator = 0
local playbackAccumulator = 0
local frozen = false
local seekDir = 0
local uiVisible = true
local forceHidden = false
local recordMode = "replace"
local playbackMode = "frameblend"
local cameraMode = "smooth"
local playbackSpeed = PLAYBACK_SPEED
local seekSpeed = 1
local blendScale = 1
local recordNoCollision = false
local shiftLockState = (startMouseBehavior == Enum.MouseBehavior.LockCenter)
local checkpoints = {}
local quickCheckpointName = "quick"
local logLines = {}
local language = "ru"
local savedTouch = {}
local lastAppliedFrame = nil
local recordBranchPending = false
local playbackShiftOverride = nil
local lastPlaybackHumanoidState = nil
local recordInputState = {
	keys = {},
	mouse = {},
}
local playbackInputState = {
	keys = {},
	mouse = {},
}
local humanoidAutoRotateState = {}
local playbackAnimationTracks = {}
local captureAnimations

local gui
local rootFrame
local statusLabel
local commandBox
local logLabel
local progressFill
local settingsFrame
local langButton
local playbackButton
local cameraButton
local recordModeButton
local nocollisionButton
local speedButton
local freezeButton
local shiftBadge
local loadingFrame

local text = {
	ru = {
		title = "TAS Lite",
		command = "команда: help | playspeed 1 | playbackmode frameblend | lang en",
		loaded = "Скрипт загружен",
		ready = "Готово",
		record_started = "Запись начата",
		record_stopped = "Запись остановлена",
		play_started = "Playback начат",
		play_stopped = "Playback остановлен",
		no_frames = "Нет кадров",
		saved = "Replay сохранен",
		loaded_replay = "Replay загружен",
		load_failed = "Не удалось загрузить replay",
		save_failed = "Не удалось сохранить replay",
		erased = "Replay очищен",
		frozen = "Freeze",
		lang = "Язык",
	},
	en = {
		title = "TAS Lite",
		command = "command: help | playspeed 1 | playbackmode frameblend | lang ru",
		loaded = "Script loaded",
		ready = "Ready",
		record_started = "Recording started",
		record_stopped = "Recording stopped",
		play_started = "Playback started",
		play_stopped = "Playback stopped",
		no_frames = "No frames",
		saved = "Replay saved",
		loaded_replay = "Replay loaded",
		load_failed = "Failed to load replay",
		save_failed = "Failed to save replay",
		erased = "Replay erased",
		frozen = "Freeze",
		lang = "Lang",
	},
}

local function tr(key)
	local pack = text[language] or text.ru
	return pack[key] or text.ru[key] or tostring(key)
end

local function clamp(n, a, b)
	if n < a then
		return a
	end
	if n > b then
		return b
	end
	return n
end

local function round(n)
	return math.floor(n * 10000 + 0.5) / 10000
end

local function finite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function vecToTable(v)
	if typeof(v) ~= "Vector3" then
		return { 0, 0, 0 }
	end
	return { round(v.X), round(v.Y), round(v.Z) }
end

local function tableToVec(t)
	if type(t) ~= "table" then
		return Vector3.zero
	end
	local x = tonumber(t[1]) or tonumber(t.x) or 0
	local y = tonumber(t[2]) or tonumber(t.y) or 0
	local z = tonumber(t[3]) or tonumber(t.z) or 0
	return Vector3.new(x, y, z)
end

local function cfToTable(cf)
	if typeof(cf) ~= "CFrame" then
		return nil
	end
	local values = { cf:GetComponents() }
	for i = 1, #values do
		values[i] = round(values[i])
	end
	return values
end

local function tableToCf(t)
	if type(t) ~= "table" then
		return nil
	end
	local values = {}
	for i = 1, 12 do
		local n = tonumber(t[i])
		if not finite(n) then
			return nil
		end
		values[i] = n
	end
	return CFrame.new(table.unpack(values))
end

local function getCharacterParts()
	local character = localPlayer.Character
	if not character then
		return nil, nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		root = character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")
	end
	return character, humanoid, root
end

local function getUiParent()
	if type(gethui) == "function" then
		local ok, result = pcall(gethui)
		if ok and result then
			return result
		end
	end
	return CoreGui
end

local function log(message)
	local line = tostring(message)
	print("[TAS Lite] " .. line)
	table.insert(logLines, os.date("%H:%M:%S") .. "  " .. line)
	while #logLines > 9 do
		table.remove(logLines, 1)
	end
	if logLabel then
		logLabel.Text = table.concat(logLines, "\n")
	end
end

local function safeNew(className, props, parent)
	local inst = Instance.new(className)
	for key, value in pairs(props or {}) do
		pcall(function()
			inst[key] = value
		end)
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function setCorner(inst, radius)
	safeNew("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, inst)
end

local function setStroke(inst, color, thickness, transparency)
	safeNew("UIStroke", {
		Color = color or Color3.fromRGB(90, 140, 220),
		Thickness = thickness or 1,
		Transparency = transparency or 0.25,
	}, inst)
end

local function makeButton(parent, textValue, size)
	local button = safeNew("TextButton", {
		Size = size or UDim2.fromOffset(104, 30),
		BackgroundColor3 = Color3.fromRGB(42, 55, 78),
		BorderSizePixel = 0,
		Text = textValue,
		TextColor3 = Color3.fromRGB(238, 244, 255),
		Font = Enum.Font.GothamSemibold,
		TextSize = 12,
		AutoButtonColor = true,
	}, parent)
	setCorner(button, 7)
	return button
end

local function buildGui()
	gui = safeNew("ScreenGui", {
		Name = "TASLiteUI",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
	}, nil)
	runtime.gui = gui

	rootFrame = safeNew("Frame", {
		Size = UDim2.fromOffset(720, 360),
		Position = UDim2.fromOffset(18, 18),
		BackgroundColor3 = Color3.fromRGB(17, 22, 31),
		BorderSizePixel = 0,
		ClipsDescendants = true,
	}, gui)
	setCorner(rootFrame, 10)
	setStroke(rootFrame, Color3.fromRGB(105, 157, 235), 1, 0.35)

	local header = safeNew("Frame", {
		Size = UDim2.new(1, 0, 0, 42),
		BackgroundColor3 = Color3.fromRGB(33, 50, 78),
		BorderSizePixel = 0,
	}, rootFrame)
	setCorner(header, 10)

	safeNew("TextLabel", {
		Size = UDim2.new(1, -220, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		BackgroundTransparency = 1,
		Text = "TAS Lite v0.9.0",
		TextColor3 = Color3.fromRGB(245, 249, 255),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamBold,
		TextSize = 18,
	}, header)

	shiftBadge = safeNew("TextLabel", {
		Size = UDim2.fromOffset(132, 24),
		Position = UDim2.new(1, -142, 0, 9),
		BackgroundColor3 = Color3.fromRGB(95, 60, 60),
		BorderSizePixel = 0,
		Text = "ShiftLock: OFF",
		TextColor3 = Color3.fromRGB(255, 230, 230),
		Font = Enum.Font.GothamSemibold,
		TextSize = 12,
	}, header)
	setCorner(shiftBadge, 7)

	statusLabel = safeNew("TextLabel", {
		Size = UDim2.new(1, -20, 0, 86),
		Position = UDim2.fromOffset(10, 52),
		BackgroundColor3 = Color3.fromRGB(24, 32, 45),
		BorderSizePixel = 0,
		Text = "",
		TextColor3 = Color3.fromRGB(231, 239, 255),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Font = Enum.Font.Code,
		TextSize = 14,
		TextWrapped = true,
	}, rootFrame)
	setCorner(statusLabel, 8)

	local progressBack = safeNew("Frame", {
		Size = UDim2.new(1, -20, 0, 8),
		Position = UDim2.fromOffset(10, 144),
		BackgroundColor3 = Color3.fromRGB(38, 48, 65),
		BorderSizePixel = 0,
	}, rootFrame)
	setCorner(progressBack, 4)
	progressFill = safeNew("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Color3.fromRGB(105, 195, 255),
		BorderSizePixel = 0,
	}, progressBack)
	setCorner(progressFill, 4)

	commandBox = safeNew("TextBox", {
		Size = UDim2.new(1, -20, 0, 32),
		Position = UDim2.fromOffset(10, 160),
		BackgroundColor3 = Color3.fromRGB(20, 27, 38),
		BorderSizePixel = 0,
		Text = "",
		PlaceholderText = tr("command"),
		TextColor3 = Color3.fromRGB(245, 248, 255),
		PlaceholderColor3 = Color3.fromRGB(145, 160, 184),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.Code,
		TextSize = 14,
		ClearTextOnFocus = false,
	}, rootFrame)
	setCorner(commandBox, 8)

	settingsFrame = safeNew("Frame", {
		Size = UDim2.new(1, -20, 0, 34),
		Position = UDim2.fromOffset(10, 202),
		BackgroundTransparency = 1,
	}, rootFrame)
	local layout = safeNew("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, settingsFrame)
	layout.Parent = settingsFrame

	freezeButton = makeButton(settingsFrame, "Freeze")
	playbackButton = makeButton(settingsFrame, "Mode")
	cameraButton = makeButton(settingsFrame, "Camera")
	recordModeButton = makeButton(settingsFrame, "Record")
	nocollisionButton = makeButton(settingsFrame, "CanTouch")
	speedButton = makeButton(settingsFrame, "Speed")
	langButton = makeButton(settingsFrame, "Lang")

	logLabel = safeNew("TextLabel", {
		Size = UDim2.new(1, -20, 1, -248),
		Position = UDim2.fromOffset(10, 242),
		BackgroundColor3 = Color3.fromRGB(13, 18, 26),
		BorderSizePixel = 0,
		Text = "",
		TextColor3 = Color3.fromRGB(186, 238, 206),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Font = Enum.Font.Code,
		TextSize = 13,
		TextWrapped = false,
	}, rootFrame)
	setCorner(logLabel, 8)

	loadingFrame = safeNew("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(8, 12, 18),
		BorderSizePixel = 0,
	}, gui)
	local loadingTitle = safeNew("TextLabel", {
		Size = UDim2.fromOffset(420, 40),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.46),
		BackgroundTransparency = 1,
		Text = "TAS Lite",
		TextColor3 = Color3.fromRGB(242, 247, 255),
		Font = Enum.Font.GothamBold,
		TextSize = 28,
	}, loadingFrame)
	local loadingLine = safeNew("Frame", {
		Size = UDim2.fromOffset(0, 5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.54),
		BackgroundColor3 = Color3.fromRGB(90, 185, 255),
		BorderSizePixel = 0,
	}, loadingFrame)
	setCorner(loadingLine, 3)
	pcall(function()
		TweenService:Create(loadingLine, TweenInfo.new(0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.fromOffset(360, 5),
		}):Play()
		TweenService:Create(loadingTitle, TweenInfo.new(0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			TextTransparency = 0,
		}):Play()
	end)
	task.delay(0.8, function()
		if loadingFrame and loadingFrame.Parent then
			pcall(function()
				TweenService:Create(loadingFrame, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
			end)
			task.wait(0.28)
			if loadingFrame and loadingFrame.Parent then
				loadingFrame:Destroy()
			end
		end
	end)

	gui.Parent = getUiParent()
end

local function updateGuiButtons()
	if not rootFrame then
		return
	end
	freezeButton.Text = "Freeze: " .. (frozen and "ON" or "OFF")
	playbackButton.Text = "Play: " .. playbackMode
	cameraButton.Text = "Cam: " .. cameraMode
	recordModeButton.Text = "Rec: " .. recordMode
	nocollisionButton.Text = "Touch: " .. (recordNoCollision and "OFF" or "ON")
	speedButton.Text = string.format("Speed: %.2f", playbackSpeed)
	langButton.Text = tr("lang") .. ": " .. string.upper(language)
	commandBox.PlaceholderText = tr("command")

	local shiftText = shiftLockState and "ON" or "OFF"
	shiftBadge.Text = "ShiftLock: " .. shiftText
	shiftBadge.BackgroundColor3 = shiftLockState and Color3.fromRGB(48, 110, 78) or Color3.fromRGB(95, 60, 60)
	shiftBadge.TextColor3 = shiftLockState and Color3.fromRGB(220, 255, 234) or Color3.fromRGB(255, 230, 230)
end

local function statusText()
	local percent = 0
	if #frames > 0 then
		percent = playIndex / #frames
	end
	return string.format(
		"Mode: %s | Frozen: %s | Frame: %d/%d | TimelineFPS: %d | RecordMode: %s | PlaybackMode: %s | CameraMode: %s\nPlaySpeed: %.2f | SeekSpeed: %.2f | Blend: %.2f | ShiftLock: %s | Checkpoints: %d | File: %s",
		mode,
		tostring(frozen),
		playIndex,
		#frames,
		TIMELINE_FPS,
		recordMode,
		playbackMode,
		cameraMode,
		playbackSpeed,
		seekSpeed,
		blendScale,
		shiftLockState and "ON" or "OFF",
		(function()
			local n = 0
			for _ in pairs(checkpoints) do
				n += 1
			end
			return n
		end)(),
		SAVE_PATH
	), percent
end

local function updateUi()
	if gui then
		gui.Enabled = uiVisible and not forceHidden
	end
	if statusLabel then
		local s, p = statusText()
		statusLabel.Text = s
		progressFill.Size = UDim2.fromScale(clamp(p, 0, 1), 1)
	end
	updateGuiButtons()
end

local function normalizePlaybackMode(value)
	local v = string.lower(tostring(value or "frameblend"))
	if v == "physics" then
		return "frameblend"
	end
	if v == "ghost" or v == "frameblend" or v == "smooth" then
		return v
	end
	return "frameblend"
end

local function normalizeCameraMode(value)
	local v = string.lower(tostring(value or "smooth"))
	if v == "exact" or v == "smooth" then
		return v
	end
	return "smooth"
end

local function setShiftLock(enabled)
	shiftLockState = enabled and true or false
	pcall(function()
		UserInputService.MouseBehavior = shiftLockState and Enum.MouseBehavior.LockCenter or Enum.MouseBehavior.Default
	end)
end

local function captureShiftLock()
	return shiftLockState
end

local toolHotkeys = {
	F8 = true,
	F10 = true,
	F6 = true,
	F7 = true,
	E = true,
	F = true,
	G = true,
	T = true,
	Y = true,
	C = true,
	V = true,
	U = true,
	F2 = true,
	Slash = true,
}

local function shouldRecordKey(keyCode)
	if keyCode == Enum.KeyCode.Unknown then
		return false
	end
	return not toolHotkeys[keyCode.Name]
end

local function copyInputState()
	local copy = {
		keys = {},
		mouse = {},
	}
	for name, down in pairs(recordInputState.keys) do
		if down then
			copy.keys[name] = true
		end
	end
	for name, down in pairs(recordInputState.mouse) do
		if down then
			copy.mouse[name] = true
		end
	end
	return copy
end

local function releasePlaybackInputs()
	if not VirtualInputManager then
		playbackInputState = { keys = {}, mouse = {} }
		return
	end
	for name, down in pairs(playbackInputState.keys) do
		if down then
			local keyCode = Enum.KeyCode[name]
			if keyCode then
				pcall(function()
					VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
				end)
			end
		end
	end
	for name, down in pairs(playbackInputState.mouse) do
		if down then
			local button = name == "MouseButton2" and 1 or 0
			pcall(function()
				VirtualInputManager:SendMouseButtonEvent(0, 0, button, false, game, 0)
			end)
		end
	end
	playbackInputState = { keys = {}, mouse = {} }
end

local function restoreHumanoidAutoRotate()
	for humanoid, value in pairs(humanoidAutoRotateState) do
		if humanoid and humanoid.Parent then
			pcall(function()
				humanoid.AutoRotate = value
			end)
		end
		humanoidAutoRotateState[humanoid] = nil
	end
end

local function applyVirtualInputs(inputData)
	if not VirtualInputManager then
		return
	end
	inputData = type(inputData) == "table" and inputData or {}
	local keys = type(inputData.keys) == "table" and inputData.keys or {}
	local mouse = type(inputData.mouse) == "table" and inputData.mouse or {}

	local seenKeys = {}
	for name, down in pairs(keys) do
		seenKeys[name] = true
		if down and not playbackInputState.keys[name] then
			local keyCode = Enum.KeyCode[name]
			if keyCode then
				pcall(function()
					VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
				end)
			end
			playbackInputState.keys[name] = true
		end
	end
	for name, down in pairs(playbackInputState.keys) do
		if down and not seenKeys[name] then
			local keyCode = Enum.KeyCode[name]
			if keyCode then
				pcall(function()
					VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
				end)
			end
			playbackInputState.keys[name] = nil
		end
	end

	local seenMouse = {}
	for name, down in pairs(mouse) do
		seenMouse[name] = true
		if down and not playbackInputState.mouse[name] then
			local button = name == "MouseButton2" and 1 or 0
			pcall(function()
				VirtualInputManager:SendMouseButtonEvent(0, 0, button, true, game, 0)
			end)
			playbackInputState.mouse[name] = true
		end
	end
	for name, down in pairs(playbackInputState.mouse) do
		if down and not seenMouse[name] then
			local button = name == "MouseButton2" and 1 or 0
			pcall(function()
				VirtualInputManager:SendMouseButtonEvent(0, 0, button, false, game, 0)
			end)
			playbackInputState.mouse[name] = nil
		end
	end
end

local function toggleShiftLockManual()
	if mode == "play" then
		local base = playbackShiftOverride
		if base == nil and frames[playIndex] then
			base = frames[playIndex].shiftlock == true
		end
		playbackShiftOverride = not (base == true)
		setShiftLock(playbackShiftOverride)
	else
		setShiftLock(not shiftLockState)
	end
end

local function setCharacterTouch(enabled)
	local character = localPlayer.Character
	if not character then
		return
	end
	for _, inst in ipairs(character:GetDescendants()) do
		if inst:IsA("BasePart") then
			if savedTouch[inst] == nil then
				savedTouch[inst] = inst.CanTouch
			end
			pcall(function()
				inst.CanTouch = enabled
			end)
		end
	end
end

local function applyRecordNoCollision()
	if recordNoCollision then
		setCharacterTouch(false)
	end
end

local function restoreTouch()
	for part, value in pairs(savedTouch) do
		if part and part.Parent then
			pcall(function()
				part.CanTouch = value
			end)
		end
	end
	savedTouch = {}
end

local function captureFrame()
	local character, humanoid, root = getCharacterParts()
	if not root then
		return nil
	end
	local frame = {
		t = round(#frames * timelineStep),
		cf = cfToTable(root.CFrame),
		vel = vecToTable(root.AssemblyLinearVelocity),
		ang = vecToTable(root.AssemblyAngularVelocity),
		cam = cfToTable(camera.CFrame),
		shiftlock = captureShiftLock(),
		inputs = copyInputState(),
		health = humanoid and round(humanoid.Health) or nil,
		state = humanoid and humanoid:GetState().Name or nil,
		animations = captureAnimations(humanoid),
	}
	if humanoid then
		frame.move = vecToTable(humanoid.MoveDirection)
		frame.jump = humanoid.Jump == true
		frame.sit = humanoid.Sit == true
	end
	return frame
end

local function humanoidStateFromString(value)
	if type(value) ~= "string" then
		return nil
	end
	local name = value:match("([^%.]+)$") or value
	local ok, enumValue = pcall(function()
		return Enum.HumanoidStateType[name]
	end)
	if ok then
		return enumValue
	end
	return nil
end

captureAnimations = function(humanoid)
	local result = {}
	if not humanoid then
		return result
	end
	local ok, tracks = pcall(function()
		return humanoid:GetPlayingAnimationTracks()
	end)
	if not ok or type(tracks) ~= "table" then
		return result
	end
	for _, track in ipairs(tracks) do
		local animationId = nil
		pcall(function()
			if track.Animation then
				animationId = track.Animation.AnimationId
			end
		end)
		if type(animationId) == "string" and animationId ~= "" then
			local item = {
				id = animationId,
				time = 0,
				speed = 1,
				weight = 1,
				priority = nil,
				looped = false,
			}
			pcall(function()
				item.time = round(track.TimePosition or 0)
			end)
			pcall(function()
				item.speed = round(track.Speed or 1)
			end)
			pcall(function()
				item.weight = round(track.WeightCurrent or 1)
			end)
			pcall(function()
				item.priority = track.Priority and track.Priority.Name or nil
			end)
			pcall(function()
				item.looped = track.Looped == true
			end)
			table.insert(result, item)
		end
	end
	return result
end

local function clearPlaybackAnimations(fadeTime)
	for id, track in pairs(playbackAnimationTracks) do
		if track then
			pcall(function()
				track:Stop(fadeTime or 0.08)
			end)
		end
		playbackAnimationTracks[id] = nil
	end
end

local function applyRecordedAnimations(humanoid, frame, frozenPreview)
	if not humanoid or type(frame) ~= "table" then
		return
	end
	local animations = type(frame.animations) == "table" and frame.animations or {}
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		pcall(function()
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end)
	end
	if not animator then
		return
	end

	local active = {}
	for _, item in ipairs(animations) do
		local id = tostring(item.id or "")
		if id ~= "" then
			active[id] = true
			local track = playbackAnimationTracks[id]
			if not track then
				local animation = Instance.new("Animation")
				animation.AnimationId = id
				local ok, loaded = pcall(function()
					return animator:LoadAnimation(animation)
				end)
				animation:Destroy()
				if ok and loaded then
					track = loaded
					playbackAnimationTracks[id] = track
					pcall(function()
						if item.priority and Enum.AnimationPriority[item.priority] then
							track.Priority = Enum.AnimationPriority[item.priority]
						end
					end)
				end
			end
			if track then
				pcall(function()
					if not track.IsPlaying then
						track:Play(0.05, clamp(tonumber(item.weight) or 1, 0, 1), frozenPreview and 0 or (tonumber(item.speed) or 1))
					end
					track.TimePosition = math.max(0, tonumber(item.time) or 0)
					track:AdjustWeight(clamp(tonumber(item.weight) or 1, 0, 1), 0.03)
					track:AdjustSpeed(frozenPreview and 0 or (tonumber(item.speed) or 1))
				end)
			end
		end
	end
	pcall(function()
		for _, liveTrack in ipairs(humanoid:GetPlayingAnimationTracks()) do
			local liveId = ""
			pcall(function()
				if liveTrack.Animation then
					liveId = liveTrack.Animation.AnimationId
				end
			end)
			if liveId ~= "" and not active[liveId] and not playbackAnimationTracks[liveId] then
				liveTrack:Stop(0.05)
			end
		end
	end)
	for id, track in pairs(playbackAnimationTracks) do
		if not active[id] then
			pcall(function()
				track:Stop(0.08)
			end)
			playbackAnimationTracks[id] = nil
		end
	end
end

local function sanitizeFrame(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local cf = tableToCf(raw.cf or raw.cframe or raw.root)
	if not cf then
		return nil
	end
	local cam = tableToCf(raw.cam or raw.camera) or camera.CFrame
	return {
		t = tonumber(raw.t) or 0,
		cf = cfToTable(cf),
		vel = vecToTable(tableToVec(raw.vel or raw.velocity)),
		ang = vecToTable(tableToVec(raw.ang or raw.angular)),
		cam = cfToTable(cam),
		shiftlock = raw.shiftlock == true,
		inputs = type(raw.inputs) == "table" and raw.inputs or { keys = {}, mouse = {} },
		health = tonumber(raw.health),
		state = raw.state,
		animations = type(raw.animations) == "table" and raw.animations or {},
		move = vecToTable(tableToVec(raw.move)),
		jump = raw.jump == true,
		sit = raw.sit == true,
	}
end

local function interpolateFrame(a, b, alpha)
	if type(a) ~= "table" or type(b) ~= "table" then
		return a
	end
	alpha = clamp(tonumber(alpha) or 0, 0, 1)
	local acf = tableToCf(a.cf)
	local bcf = tableToCf(b.cf)
	local acam = tableToCf(a.cam)
	local bcam = tableToCf(b.cam)
	local blended = {}
	for k, v in pairs(a) do
		blended[k] = v
	end
	if acf and bcf then
		blended.cf = cfToTable(acf:Lerp(bcf, alpha))
	end
	if acam and bcam then
		blended.cam = cfToTable(acam:Lerp(bcam, alpha))
	end
	blended.vel = vecToTable(tableToVec(a.vel):Lerp(tableToVec(b.vel), alpha))
	blended.ang = vecToTable(tableToVec(a.ang):Lerp(tableToVec(b.ang), alpha))
	blended.move = vecToTable(tableToVec(a.move):Lerp(tableToVec(b.move), alpha))
	if alpha >= 0.5 then
		blended.shiftlock = b.shiftlock == true
		blended.inputs = b.inputs
		blended.jump = b.jump == true
		blended.sit = b.sit == true
		blended.state = b.state
		blended.animations = b.animations
	end
	return blended
end

local function addFrame()
	local frame = captureFrame()
	if frame then
		table.insert(frames, frame)
		playIndex = #frames
		return true
	end
	return false
end

local function applyCamera(frame, dt)
	local target = tableToCf(frame.cam)
	if not target then
		return
	end
	pcall(function()
		camera.CameraType = Enum.CameraType.Scriptable
		if cameraMode == "exact" or frozen then
			camera.CFrame = target
		else
			local alpha = 1 - math.exp(-CAMERA_SMOOTH_RATE * (dt or timelineStep))
			camera.CFrame = camera.CFrame:Lerp(target, clamp(alpha, 0, 1))
		end
	end)
end

local function applyRootExact(root, frame)
	local cf = tableToCf(frame.cf)
	if not cf then
		return
	end
	root.CFrame = cf
	root.AssemblyLinearVelocity = tableToVec(frame.vel)
	root.AssemblyAngularVelocity = tableToVec(frame.ang)
end

local function lerpRotation(fromCf, toCf, alpha)
	local pos = fromCf.Position:Lerp(toCf.Position, alpha)
	local rot = fromCf.Rotation:Lerp(toCf.Rotation, alpha)
	return CFrame.new(pos) * rot
end

local function applyRootBlended(root, frame, modeName)
	local target = tableToCf(frame.cf)
	if not target then
		return
	end
	local current = root.CFrame
	local distance = (current.Position - target.Position).Magnitude
	if distance >= FRAMEBLEND_SNAP_DISTANCE then
		applyRootExact(root, frame)
		return
	end
	if modeName == "frameblend" then
		root.CFrame = target
		root.AssemblyLinearVelocity = root.AssemblyLinearVelocity:Lerp(tableToVec(frame.vel), clamp(FRAMEBLEND_VELOCITY_BLEND * blendScale, 0.01, 1))
		root.AssemblyAngularVelocity = root.AssemblyAngularVelocity:Lerp(tableToVec(frame.ang), clamp(FRAMEBLEND_ANGULAR_BLEND * blendScale, 0.01, 1))
		return
	end

	local positionAlpha = FRAMEBLEND_POSITION_ALPHA
	local rotationAlpha = FRAMEBLEND_ROTATION_ALPHA
	local velocityAlpha = FRAMEBLEND_VELOCITY_BLEND
	local angularAlpha = FRAMEBLEND_ANGULAR_BLEND
	if modeName == "smooth" then
		positionAlpha = SMOOTH_POSITION_ALPHA
		rotationAlpha = SMOOTH_ROTATION_ALPHA
		velocityAlpha = SMOOTH_VELOCITY_BLEND
		angularAlpha = SMOOTH_ANGULAR_BLEND
	end
	positionAlpha = clamp(positionAlpha * blendScale, 0.01, 1)
	rotationAlpha = clamp(rotationAlpha * blendScale, 0.01, 1)
	velocityAlpha = clamp(velocityAlpha * blendScale, 0.01, 1)
	angularAlpha = clamp(angularAlpha * blendScale, 0.01, 1)

	local blendedPos = current.Position:Lerp(target.Position, positionAlpha)
	local blendedRot = current.Rotation:Lerp(target.Rotation, rotationAlpha)
	root.CFrame = CFrame.new(blendedPos) * blendedRot
	root.AssemblyLinearVelocity = root.AssemblyLinearVelocity:Lerp(tableToVec(frame.vel), velocityAlpha)
	root.AssemblyAngularVelocity = root.AssemblyAngularVelocity:Lerp(tableToVec(frame.ang), angularAlpha)
end

local function applyFrameData(frame, index, dt)
	if not frame then
		return
	end
	local _, humanoid, root = getCharacterParts()
	if not root then
		return
	end
	if index then
		playIndex = clamp(math.floor(index), 1, math.max(#frames, 1))
	end
	local effectiveMode = normalizePlaybackMode(playbackMode)
	local frameShiftLock = frame.shiftlock == true
	if mode == "play" and playbackShiftOverride ~= nil then
		frameShiftLock = playbackShiftOverride == true
	end
	if mode == "play" then
		applyVirtualInputs(frame.inputs)
	end
	setShiftLock(frameShiftLock)
	if humanoid then
		pcall(function()
			if mode == "play" or frozen then
				if humanoidAutoRotateState[humanoid] == nil then
					humanoidAutoRotateState[humanoid] = humanoid.AutoRotate
				end
				humanoid.AutoRotate = false
			end
			humanoid.Sit = frame.sit == true
			humanoid.Jump = frame.jump == true
			humanoid:Move(tableToVec(frame.move), false)
			local state = humanoidStateFromString(frame.state)
			if state and state ~= Enum.HumanoidStateType.Dead and state ~= lastPlaybackHumanoidState then
				humanoid:ChangeState(state)
				lastPlaybackHumanoidState = state
			end
		end)
		if mode == "play" or frozen then
			applyRecordedAnimations(humanoid, frame, frozen)
		end
	end
	if frozen or effectiveMode == "ghost" then
		applyRootExact(root, frame)
	else
		applyRootBlended(root, frame, effectiveMode)
	end
	applyCamera(frame, dt)
	lastAppliedFrame = frame
end

local function applyFrame(index, dt)
	index = clamp(math.floor(index), 1, math.max(#frames, 1))
	applyFrameData(frames[index], index, dt)
end

local function stopRecord()
	if mode ~= "record" then
		return
	end
	mode = "idle"
	frozen = false
	restoreTouch()
	log(tr("record_stopped") .. " (" .. tostring(#frames) .. " frames)")
end

local function startRecord()
	if mode == "play" then
		mode = "idle"
	end
	if recordMode == "replace" then
		frames = {}
		playIndex = 1
	end
	recordBranchPending = false
	recordInputState = { keys = {}, mouse = {} }
	mode = "record"
	frozen = false
	recordAccumulator = 0
	applyRecordNoCollision()
	addFrame()
	log(tr("record_started") .. " [" .. recordMode .. "]")
end

local function stopPlayback()
	if mode ~= "play" then
		return
	end
	mode = "idle"
	frozen = false
	playbackShiftOverride = nil
	lastPlaybackHumanoidState = nil
	releasePlaybackInputs()
	clearPlaybackAnimations(0.08)
	restoreHumanoidAutoRotate()
	pcall(function()
		camera.CameraType = startCameraType
		camera.CameraSubject = startCameraSubject
	end)
	log(tr("play_stopped"))
end

local function startPlayback()
	if #frames <= 0 then
		log(tr("no_frames"))
		return
	end
	if mode == "record" then
		stopRecord()
	end
	mode = "play"
	frozen = false
	playbackShiftOverride = nil
	lastPlaybackHumanoidState = nil
	releasePlaybackInputs()
	playIndex = 1
	playbackAccumulator = 0
	cameraMode = normalizeCameraMode(cameraMode)
	playbackMode = normalizePlaybackMode(playbackMode)
	applyFrame(1, timelineStep)
	log(tr("play_started") .. " [" .. playbackMode .. "]")
end

local function toggleRecord()
	if mode == "record" then
		stopRecord()
	else
		startRecord()
	end
end

local function togglePlayback()
	if mode == "play" then
		stopPlayback()
	else
		startPlayback()
	end
end

local function setFrozen(value)
	if mode == "record" and frozen and not value and recordBranchPending then
		for i = #frames, playIndex + 1, -1 do
			frames[i] = nil
		end
		recordAccumulator = 0
		recordBranchPending = false
		log("Record branch trimmed to frame " .. tostring(playIndex))
	end
	frozen = value and true or false
	if mode == "record" and not frozen then
		clearPlaybackAnimations(0.08)
		restoreHumanoidAutoRotate()
		pcall(function()
			camera.CameraType = startCameraType
			camera.CameraSubject = startCameraSubject
		end)
	end
	log(tr("frozen") .. ": " .. (frozen and "ON" or "OFF"))
end

local function stepFrame(delta)
	if mode ~= "play" and mode ~= "record" then
		return
	end
	if not frozen then
		setFrozen(true)
	end
	if mode == "play" then
		applyFrame(clamp(playIndex + delta, 1, #frames), timelineStep)
	elseif mode == "record" then
		playIndex = clamp(playIndex + delta, 1, #frames)
		if frames[playIndex] then
			applyFrame(playIndex, timelineStep)
			recordBranchPending = true
		end
	end
end

local function setCheckpoint(name, index)
	name = tostring(name or quickCheckpointName)
	index = clamp(tonumber(index) or playIndex or #frames, 1, math.max(#frames, 1))
	checkpoints[name] = index
	log("Checkpoint set: " .. name .. " -> " .. tostring(index))
end

local function gotoCheckpoint(name)
	name = tostring(name or quickCheckpointName)
	local index = checkpoints[name]
	if not index then
		log("No checkpoint: " .. name)
		return
	end
	playIndex = clamp(index, 1, math.max(#frames, 1))
	if #frames > 0 then
		applyFrame(playIndex, timelineStep)
		if mode == "record" then
			recordBranchPending = true
		end
	end
	log("Checkpoint goto: " .. name .. " -> " .. tostring(playIndex))
end

local function ensureFolder()
	if type(isfolder) == "function" and type(makefolder) == "function" then
		if not isfolder(SAVE_FOLDER) then
			makefolder(SAVE_FOLDER)
		end
	end
end

local function saveReplay()
	if type(writefile) ~= "function" then
		log(tr("save_failed") .. ": writefile unavailable")
		return
	end
	local payload = {
		version = VERSION,
		timeline_fps = TIMELINE_FPS,
		place_id = game.PlaceId,
		created_at = os.time(),
		playback_mode = playbackMode,
		camera_mode = cameraMode,
		record_mode = recordMode,
		checkpoints = checkpoints,
		frames = frames,
	}
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if not ok then
		log(tr("save_failed") .. ": JSONEncode")
		return
	end
	local writeOk, err = pcall(function()
		ensureFolder()
		writefile(SAVE_PATH, encoded)
	end)
	if writeOk then
		log(tr("saved") .. ": " .. SAVE_PATH)
	else
		log(tr("save_failed") .. ": " .. tostring(err))
	end
end

local function loadReplay()
	if type(isfile) ~= "function" or type(readfile) ~= "function" then
		log(tr("load_failed") .. ": readfile unavailable")
		return
	end
	if not isfile(SAVE_PATH) then
		log(tr("load_failed") .. ": " .. SAVE_PATH)
		return
	end
	local okRead, raw = pcall(function()
		return readfile(SAVE_PATH)
	end)
	if not okRead then
		log(tr("load_failed") .. ": readfile")
		return
	end
	local okJson, data = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not okJson or type(data) ~= "table" then
		log(tr("load_failed") .. ": JSONDecode")
		return
	end
	local loadedFrames = {}
	for _, rawFrame in ipairs(type(data.frames) == "table" and data.frames or {}) do
		local frame = sanitizeFrame(rawFrame)
		if frame then
			table.insert(loadedFrames, frame)
		end
	end
	frames = loadedFrames
	checkpoints = {}
	if type(data.checkpoints) == "table" then
		for name, index in pairs(data.checkpoints) do
			local n = tonumber(index)
			if n and n >= 1 and n <= #frames then
				checkpoints[tostring(name)] = math.floor(n)
			end
		end
	end
	playbackMode = normalizePlaybackMode(data.playback_mode or playbackMode)
	cameraMode = normalizeCameraMode(data.camera_mode or cameraMode)
	playIndex = clamp(1, 1, math.max(#frames, 1))
	log(tr("loaded_replay") .. ": " .. tostring(#frames) .. " frames")
end

local function eraseReplay()
	stopRecord()
	stopPlayback()
	frames = {}
	playIndex = 1
	checkpoints = {}
	log(tr("erased"))
end

local function splitCommand(raw)
	local args = {}
	for token in string.gmatch(tostring(raw or ""), "%S+") do
		table.insert(args, token)
	end
	return args
end

local function showHelp()
	log("help")
	log("erase | status | clearlog")
	log("setspeed <number> | playspeed <number> | blend <0.05..1>")
	log("playbackmode <ghost|frameblend|smooth|physics>")
	log("cameramode <exact|smooth>")
	log("recordmode <replace|append>")
	log("recordnocollision <on|off>")
	log("lang/language <ru|en>")
	log("cp set <name> [frame] | cp goto <name> | cp list | cp del <name>")
end

local function runCommand(raw)
	local args = splitCommand(raw)
	local cmd = string.lower(args[1] or "")
	if cmd == "" then
		return
	end
	if cmd == "help" then
		showHelp()
	elseif cmd == "erase" then
		eraseReplay()
	elseif cmd == "status" then
		log(statusText())
	elseif cmd == "clearlog" then
		logLines = {}
		logLabel.Text = ""
	elseif cmd == "setspeed" then
		local n = tonumber(args[2])
		if n and n > 0 then
			seekSpeed = n
			log("SeekSpeed: " .. tostring(seekSpeed))
		else
			log("Usage: setspeed <number>")
		end
	elseif cmd == "playspeed" then
		local n = tonumber(args[2])
		if n and n > 0 then
			playbackSpeed = n
			log("PlaySpeed: " .. tostring(playbackSpeed))
		else
			log("Usage: playspeed <number>")
		end
	elseif cmd == "blend" then
		local n = tonumber(args[2])
		if n and n >= 0.05 and n <= 1 then
			blendScale = n
			log("Blend: " .. tostring(blendScale))
		else
			log("Usage: blend <0.05..1>")
		end
	elseif cmd == "playbackmode" then
		local rawMode = string.lower(args[2] or "")
		if rawMode == "ghost" or rawMode == "frameblend" or rawMode == "smooth" or rawMode == "physics" then
			playbackMode = normalizePlaybackMode(rawMode)
			log("PlaybackMode: " .. playbackMode)
		else
			log("Usage: playbackmode <ghost|frameblend|smooth>")
		end
	elseif cmd == "cameramode" then
		local rawMode = string.lower(args[2] or "")
		if rawMode == "exact" or rawMode == "smooth" then
			cameraMode = normalizeCameraMode(rawMode)
			log("CameraMode: " .. cameraMode)
		else
			log("Usage: cameramode <exact|smooth>")
		end
	elseif cmd == "recordmode" then
		local rawMode = string.lower(args[2] or "")
		if rawMode == "replace" or rawMode == "append" then
			recordMode = rawMode
			log("RecordMode: " .. recordMode)
		else
			log("Usage: recordmode <replace|append>")
		end
	elseif cmd == "recordnocollision" then
		local rawMode = string.lower(args[2] or "")
		if rawMode == "on" or rawMode == "off" then
			recordNoCollision = rawMode == "on"
			if recordNoCollision then
				applyRecordNoCollision()
			else
				restoreTouch()
			end
			log("RecordNoCollision: " .. rawMode)
		else
			log("Usage: recordnocollision <on|off>")
		end
	elseif cmd == "lang" or cmd == "language" then
		local rawMode = string.lower(args[2] or "")
		if rawMode == "ru" or rawMode == "en" then
			language = rawMode
			log("Language: " .. language)
		else
			log("Usage: lang <ru|en>")
		end
	elseif cmd == "cp" then
		local sub = string.lower(args[2] or "")
		if sub == "set" then
			setCheckpoint(args[3] or quickCheckpointName, args[4])
		elseif sub == "goto" then
			gotoCheckpoint(args[3] or quickCheckpointName)
		elseif sub == "list" then
			for name, index in pairs(checkpoints) do
				log("CP " .. tostring(name) .. " = " .. tostring(index))
			end
		elseif sub == "del" then
			local name = tostring(args[3] or quickCheckpointName)
			checkpoints[name] = nil
			log("CP deleted: " .. name)
		else
			log("Usage: cp set/goto/list/del")
		end
	else
		log("Unknown command: " .. cmd)
	end
	updateUi()
end

buildGui()

connect(freezeButton.MouseButton1Click, function()
	setFrozen(not frozen)
end)
connect(playbackButton.MouseButton1Click, function()
	if playbackMode == "ghost" then
		playbackMode = "frameblend"
	elseif playbackMode == "frameblend" then
		playbackMode = "smooth"
	else
		playbackMode = "ghost"
	end
	log("PlaybackMode: " .. playbackMode)
	updateUi()
end)
connect(cameraButton.MouseButton1Click, function()
	cameraMode = cameraMode == "exact" and "smooth" or "exact"
	log("CameraMode: " .. cameraMode)
	updateUi()
end)
connect(recordModeButton.MouseButton1Click, function()
	recordMode = recordMode == "replace" and "append" or "replace"
	log("RecordMode: " .. recordMode)
	updateUi()
end)
connect(nocollisionButton.MouseButton1Click, function()
	recordNoCollision = not recordNoCollision
	if recordNoCollision then
		applyRecordNoCollision()
	else
		restoreTouch()
	end
	log("RecordNoCollision: " .. (recordNoCollision and "on" or "off"))
	updateUi()
end)
connect(speedButton.MouseButton1Click, function()
	playbackSpeed += 0.25
	if playbackSpeed > 3 then
		playbackSpeed = 0.5
	end
	updateUi()
end)
connect(langButton.MouseButton1Click, function()
	language = language == "ru" and "en" or "ru"
	log("Language: " .. language)
	updateUi()
end)
connect(commandBox.FocusLost, function(enterPressed)
	if enterPressed then
		runCommand(commandBox.Text)
	end
	commandBox.Text = ""
	updateUi()
end)

connect(UserInputService.InputBegan, function(input, gameProcessed)
	local focused = UserInputService:GetFocusedTextBox()
	if mode == "record" and not focused then
		if input.UserInputType == Enum.UserInputType.Keyboard and shouldRecordKey(input.KeyCode) then
			recordInputState.keys[input.KeyCode.Name] = true
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			recordInputState.mouse.MouseButton1 = true
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			recordInputState.mouse.MouseButton2 = true
		end
	end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	if input.KeyCode == Enum.KeyCode.Slash then
		task.defer(function()
			commandBox:CaptureFocus()
		end)
		return
	end
	if focused then
		return
	end
	if input.KeyCode == Enum.KeyCode.F8 then
		toggleRecord()
	elseif input.KeyCode == Enum.KeyCode.F10 then
		togglePlayback()
	elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		toggleShiftLockManual()
	elseif input.KeyCode == Enum.KeyCode.F6 then
		saveReplay()
	elseif input.KeyCode == Enum.KeyCode.F7 then
		loadReplay()
	elseif input.KeyCode == Enum.KeyCode.E then
		setFrozen(not frozen)
	elseif input.KeyCode == Enum.KeyCode.F then
		stepFrame(-1)
	elseif input.KeyCode == Enum.KeyCode.G then
		stepFrame(1)
	elseif input.KeyCode == Enum.KeyCode.T then
		seekDir = -1
		if (mode == "play" or mode == "record") and not frozen then
			setFrozen(true)
		end
	elseif input.KeyCode == Enum.KeyCode.Y then
		seekDir = 1
		if (mode == "play" or mode == "record") and not frozen then
			setFrozen(true)
		end
	elseif input.KeyCode == Enum.KeyCode.C then
		setCheckpoint(quickCheckpointName, playIndex)
	elseif input.KeyCode == Enum.KeyCode.V then
		gotoCheckpoint(quickCheckpointName)
	elseif input.KeyCode == Enum.KeyCode.U then
		uiVisible = not uiVisible
	elseif input.KeyCode == Enum.KeyCode.F2 then
		forceHidden = not forceHidden
	end
	updateUi()
end)

connect(UserInputService.InputEnded, function(input)
	local focused = UserInputService:GetFocusedTextBox()
	if mode == "record" and not focused then
		if input.UserInputType == Enum.UserInputType.Keyboard and shouldRecordKey(input.KeyCode) then
			recordInputState.keys[input.KeyCode.Name] = nil
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			recordInputState.mouse.MouseButton1 = nil
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			recordInputState.mouse.MouseButton2 = nil
		end
	end
	if input.UserInputType == Enum.UserInputType.Keyboard then
		if input.KeyCode == Enum.KeyCode.T and seekDir == -1 then
			seekDir = 0
		elseif input.KeyCode == Enum.KeyCode.Y and seekDir == 1 then
			seekDir = 0
		end
	end
end)

connect(localPlayer.CharacterAdded, function()
	task.wait(0.4)
	if mode == "record" then
		applyRecordNoCollision()
	end
end)

connect(RunService.RenderStepped, function(dt)
	if runtime.cleaning then
		return
	end

	if seekDir ~= 0 and frozen and #frames > 0 then
		local step = math.max(1, math.floor(seekSpeed))
		applyFrame(clamp(playIndex + seekDir * step, 1, #frames), dt)
		if mode == "record" then
			recordBranchPending = true
		end
	end

	if mode == "record" then
		if frozen then
			if #frames > 0 then
				applyFrame(playIndex, dt)
			end
			updateUi()
			return
		end
		recordAccumulator += clamp(dt, 0, 0.25)
		local steps = 0
		while recordAccumulator >= timelineStep and steps < RECORD_MAX_STEPS_PER_RENDER do
			addFrame()
			recordAccumulator -= timelineStep
			steps += 1
		end
		applyRecordNoCollision()
	elseif mode == "play" then
		if frozen then
			applyFrame(playIndex, dt)
			updateUi()
			return
		end
		playbackAccumulator += clamp(dt * playbackSpeed, 0, PLAYBACK_MAX_ACCUMULATOR)
		if playbackAccumulator > PLAYBACK_MAX_ACCUMULATOR then
			playbackAccumulator = PLAYBACK_MAX_ACCUMULATOR
		end
		local steps = 0
		while playbackAccumulator >= timelineStep and steps < PLAYBACK_MAX_STEPS_PER_RENDER do
			if playIndex >= #frames then
				stopPlayback()
				break
			end
			playIndex += 1
			playbackAccumulator -= timelineStep
			steps += 1
		end
		if mode == "play" then
			local renderFrame = frames[playIndex]
			if playbackMode ~= "ghost" and frames[playIndex + 1] then
				renderFrame = interpolateFrame(frames[playIndex], frames[playIndex + 1], playbackAccumulator / timelineStep)
			end
			applyFrameData(renderFrame, playIndex, dt)
		end
	else
		captureShiftLock()
	end

	updateUi()
end)

runtime.cleanup = function()
	if runtime.cleaning then
		return
	end
	runtime.cleaning = true
	pcall(stopRecord)
	pcall(stopPlayback)
	pcall(releasePlaybackInputs)
	pcall(clearPlaybackAnimations)
	pcall(restoreHumanoidAutoRotate)
	pcall(restoreTouch)
	pcall(function()
		UserInputService.MouseBehavior = startMouseBehavior
	end)
	pcall(function()
		camera.CameraType = startCameraType
		camera.CameraSubject = startCameraSubject
	end)
	disconnectAll()
	if runtime.gui and runtime.gui.Parent then
		pcall(function()
			runtime.gui:Destroy()
		end)
	end
	if rawget(_G, RUNTIME_KEY) == runtime then
		_G[RUNTIME_KEY] = nil
	end
end

log(VERSION)
log(tr("loaded") .. ". F8 Rec, F10 Play, F6 Save, F7 Load, / Command")
updateUi()
