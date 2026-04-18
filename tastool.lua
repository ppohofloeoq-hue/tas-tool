local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ContextActionService = game:GetService("ContextActionService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = Workspace.CurrentCamera

local character
local humanoid
local rootPart

local function bindCharacter(char)
	character = char
	humanoid = char:WaitForChild("Humanoid")
	rootPart = char:WaitForChild("HumanoidRootPart")
end

bindCharacter(player.Character or player.CharacterAdded:Wait())
player.CharacterAdded:Connect(bindCharacter)

local function hasCharacter()
	return character and character.Parent and humanoid and humanoid.Parent and rootPart and rootPart.Parent
end

local function clamp(n, a, b)
	return math.max(a, math.min(b, n))
end

local function deepCopy(tbl)
	local out = {}
	for k, v in pairs(tbl) do
		if type(v) == "table" then
			out[k] = deepCopy(v)
		else
			out[k] = v
		end
	end
	return out
end

local function cframeToTable(cf)
	return {cf:GetComponents()}
end

local function tableToCFrame(tbl)
	return CFrame.new(unpack(tbl))
end

local function vector3ToTable(v)
	return {v.X, v.Y, v.Z}
end

local function tableToVector3(tbl)
	if not tbl then
		return Vector3.zero
	end
	return Vector3.new(tbl[1] or 0, tbl[2] or 0, tbl[3] or 0)
end

local function vector2ToTable(v)
	return {v.X, v.Y}
end

local function getMouseBehaviorName()
	return UserInputService.MouseBehavior.Name
end

local function mouseBehaviorFromName(name)
	if name == "LockCenter" then
		return Enum.MouseBehavior.LockCenter
	elseif name == "LockCurrentPosition" then
		return Enum.MouseBehavior.LockCurrentPosition
	else
		return Enum.MouseBehavior.Default
	end
end

local function getCameraModeName()
	return player.CameraMode.Name
end

local function cameraModeFromName(name)
	if name == "LockFirstPerson" then
		return Enum.CameraMode.LockFirstPerson
	end
	return Enum.CameraMode.Classic
end

local function getHumanoidStateName()
	if not humanoid then
		return "Running"
	end
	return humanoid:GetState().Name
end

local function humanoidStateFromName(name)
	if name == "Freefall" then
		return Enum.HumanoidStateType.Freefall
	elseif name == "Jumping" then
		return Enum.HumanoidStateType.Jumping
	elseif name == "Landed" then
		return Enum.HumanoidStateType.Landed
	elseif name == "Climbing" then
		return Enum.HumanoidStateType.Climbing
	elseif name == "Swimming" then
		return Enum.HumanoidStateType.Swimming
	elseif name == "Seated" then
		return Enum.HumanoidStateType.Seated
	elseif name == "PlatformStanding" then
		return Enum.HumanoidStateType.PlatformStanding
	else
		return Enum.HumanoidStateType.Running
	end
end

local frames = {}

local state = {
	mode = "idle", -- idle, recording, replay
	frame = 1,
	uiVisible = true,
	playOneFrame = false,
	isPlaying = false,
}

local holdBack = false
local holdForward = false
local nextRepeatAt = 0

local firstRepeatDelay = 0.08
local repeatDelay = 0.035
local fastScrubStep = 1

local recordConn = nil
local replayConn = nil
local scrubConn = nil

local savedCameraType = nil
local savedCameraSubject = nil
local savedFieldOfView = nil
local savedAutoRotate = nil
local savedCameraOffset = nil
local savedMouseBehavior = nil
local savedCameraMode = nil
local savedShiftLock = nil

local currentKeysDown = {}
local currentMouseButtonsDown = {}
local currentMouseDelta = Vector2.zero
local currentMouseWheel = 0

-- =========================
-- Custom ShiftLock
-- =========================
local SHIFTLOCK_ACTION = "TAS_CustomShiftLockToggle"
local SHIFTLOCK_OFFSET = Vector3.new(1.75, 0.25, 0)
local isShiftLocked = false

local function setShiftLock(enabled)
	isShiftLocked = enabled == true

	if not hasCharacter() then
		return
	end

	if isShiftLocked then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		humanoid.CameraOffset = SHIFTLOCK_OFFSET
		humanoid.AutoRotate = true
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		humanoid.CameraOffset = Vector3.zero
	end
end

local function toggleShiftLock()
	setShiftLock(not isShiftLocked)
end

ContextActionService:BindAction(
	SHIFTLOCK_ACTION,
	function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			toggleShiftLock()
		end
		return Enum.ContextActionResult.Sink
	end,
	false,
	Enum.KeyCode.LeftShift,
	Enum.KeyCode.RightShift
)

RunService.RenderStepped:Connect(function()
	if not hasCharacter() then
		return
	end

	if isShiftLocked and state.mode ~= "replay" then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter

		local look = camera.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)

		if flatLook.Magnitude > 0.001 then
			rootPart.CFrame = CFrame.new(rootPart.Position, rootPart.Position + flatLook.Unit)
		end
	end
end)

player.CharacterAdded:Connect(function()
	task.wait(0.1)
	if isShiftLocked then
		setShiftLock(true)
	end
end)

-- =========================
-- GUI
-- =========================
local ui = Instance.new("ScreenGui")
ui.Name = "TASGui"
ui.ResetOnSpawn = false
ui.Parent = playerGui

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(560, 360)
main.Position = UDim2.fromOffset(20, 20)
main.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
main.BackgroundTransparency = 0.06
main.BorderSizePixel = 0
main.Parent = ui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 12)
mainCorner.Parent = main

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Color3.fromRGB(80, 80, 80)
mainStroke.Thickness = 1
mainStroke.Parent = main

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(12, 8)
title.Size = UDim2.new(1, -24, 0, 28)
title.Font = Enum.Font.SourceSansBold
title.TextSize = 26
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.Text = "TAS Tool v3"
title.Parent = main

local statusLabel = Instance.new("TextLabel")
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.fromOffset(12, 38)
statusLabel.Size = UDim2.new(1, -24, 0, 24)
statusLabel.Font = Enum.Font.SourceSansBold
statusLabel.TextSize = 20
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextColor3 = Color3.fromRGB(180, 255, 180)
statusLabel.Text = "Статус: ожидание"
statusLabel.Parent = main

local controlsLabel = Instance.new("TextLabel")
controlsLabel.BackgroundTransparency = 1
controlsLabel.Position = UDim2.fromOffset(12, 68)
controlsLabel.Size = UDim2.new(1, -24, 0, 200)
controlsLabel.Font = Enum.Font.SourceSans
controlsLabel.TextSize = 19
controlsLabel.TextXAlignment = Enum.TextXAlignment.Left
controlsLabel.TextYAlignment = Enum.TextYAlignment.Top
controlsLabel.TextWrapped = true
controlsLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
controlsLabel.Text =
	"Shift = кастомный shiftlock\n" ..
	"J = запись с нуля / стоп\n" ..
	"N = replay с 1 кадра\n" ..
	"E = перезаписать с текущего кадра\n" ..
	"R/T = перемотка назад / вперёд\n" ..
	"F = -1 кадр\n" ..
	"V = проиграть 1 следующий кадр\n" ..
	"L = выйти из replay\n" ..
	"Backspace = очистить запись\n" ..
	"Frame + GO = перейти на кадр"
controlsLabel.Parent = main

local infoLabel = Instance.new("TextLabel")
infoLabel.BackgroundTransparency = 1
infoLabel.Position = UDim2.fromOffset(12, 270)
infoLabel.Size = UDim2.new(1, -24, 0, 24)
infoLabel.Font = Enum.Font.SourceSans
infoLabel.TextSize = 19
infoLabel.TextXAlignment = Enum.TextXAlignment.Left
infoLabel.TextColor3 = Color3.fromRGB(255, 235, 170)
infoLabel.Text = "Кадров: 0 | Текущий: 0"
infoLabel.Parent = main

local modeInfoLabel = Instance.new("TextLabel")
modeInfoLabel.BackgroundTransparency = 1
modeInfoLabel.Position = UDim2.fromOffset(12, 294)
modeInfoLabel.Size = UDim2.new(1, -24, 0, 24)
modeInfoLabel.Font = Enum.Font.SourceSans
modeInfoLabel.TextSize = 18
modeInfoLabel.TextXAlignment = Enum.TextXAlignment.Left
modeInfoLabel.TextColor3 = Color3.fromRGB(190, 220, 255)
modeInfoLabel.Text = "Режим: idle"
modeInfoLabel.Parent = main

local shiftInfoLabel = Instance.new("TextLabel")
shiftInfoLabel.BackgroundTransparency = 1
shiftInfoLabel.Position = UDim2.fromOffset(12, 318)
shiftInfoLabel.Size = UDim2.new(1, -24, 0, 20)
shiftInfoLabel.Font = Enum.Font.SourceSans
shiftInfoLabel.TextSize = 18
shiftInfoLabel.TextXAlignment = Enum.TextXAlignment.Left
shiftInfoLabel.TextColor3 = Color3.fromRGB(180, 255, 220)
shiftInfoLabel.Text = "ShiftLock: OFF"
shiftInfoLabel.Parent = main

local frameBox = Instance.new("TextBox")
frameBox.ClearTextOnFocus = false
frameBox.PlaceholderText = "Frame"
frameBox.Size = UDim2.fromOffset(120, 32)
frameBox.Position = UDim2.fromOffset(400, 300)
frameBox.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
frameBox.TextColor3 = Color3.fromRGB(255, 255, 255)
frameBox.PlaceholderColor3 = Color3.fromRGB(160, 160, 160)
frameBox.Font = Enum.Font.SourceSans
frameBox.TextSize = 20
frameBox.Parent = main

local frameBoxCorner = Instance.new("UICorner")
frameBoxCorner.CornerRadius = UDim.new(0, 8)
frameBoxCorner.Parent = frameBox

local goButton = Instance.new("TextButton")
goButton.Size = UDim2.fromOffset(70, 32)
goButton.Position = UDim2.fromOffset(486, 300)
goButton.BackgroundColor3 = Color3.fromRGB(60, 110, 190)
goButton.TextColor3 = Color3.fromRGB(255, 255, 255)
goButton.Font = Enum.Font.SourceSansBold
goButton.TextSize = 20
goButton.Text = "GO"
goButton.Parent = main

local goCorner = Instance.new("UICorner")
goCorner.CornerRadius = UDim.new(0, 8)
goCorner.Parent = goButton

local timelineBack = Instance.new("Frame")
timelineBack.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
timelineBack.BorderSizePixel = 0
timelineBack.Position = UDim2.new(0, 12, 1, -16)
timelineBack.Size = UDim2.new(1, -24, 0, 8)
timelineBack.Parent = main

local timelineBackCorner = Instance.new("UICorner")
timelineBackCorner.CornerRadius = UDim.new(1, 0)
timelineBackCorner.Parent = timelineBack

local timelineFill = Instance.new("Frame")
timelineFill.BackgroundColor3 = Color3.fromRGB(100, 180, 255)
timelineFill.BorderSizePixel = 0
timelineFill.Size = UDim2.new(0, 0, 1, 0)
timelineFill.Parent = timelineBack

local timelineFillCorner = Instance.new("UICorner")
timelineFillCorner.CornerRadius = UDim.new(1, 0)
timelineFillCorner.Parent = timelineFill

local function setTimelineProgress(alpha)
	alpha = clamp(alpha, 0, 1)
	timelineFill.Size = UDim2.new(alpha, 0, 1, 0)
end

local function updateGui()
	local total = #frames
	local current = clamp(state.frame, 0, math.max(total, 0))

	infoLabel.Text = ("Кадров: %d | Текущий: %d"):format(total, current)
	modeInfoLabel.Text = ("Режим: %s%s"):format(
		state.mode,
		state.mode == "replay" and (state.isPlaying and " (play)" or " (freeze)") or ""
	)
	shiftInfoLabel.Text = "ShiftLock: " .. (isShiftLocked and "ON" or "OFF")

	if total <= 1 then
		setTimelineProgress(0)
	else
		setTimelineProgress((current - 1) / (total - 1))
	end

	if state.mode == "idle" then
		statusLabel.Text = "Статус: ожидание"
		statusLabel.TextColor3 = Color3.fromRGB(180, 255, 180)
	elseif state.mode == "recording" then
		statusLabel.Text = "Статус: запись"
		statusLabel.TextColor3 = Color3.fromRGB(120, 255, 120)
	elseif state.mode == "replay" then
		statusLabel.Text = state.isPlaying and "Статус: replay" or "Статус: freeze / seek"
		statusLabel.TextColor3 = Color3.fromRGB(120, 210, 255)
	end
end

local function saveEnvironment()
	if not hasCharacter() then
		return
	end

	savedCameraType = camera.CameraType
	savedCameraSubject = camera.CameraSubject
	savedFieldOfView = camera.FieldOfView
	savedAutoRotate = humanoid.AutoRotate
	savedCameraOffset = humanoid.CameraOffset
	savedMouseBehavior = UserInputService.MouseBehavior
	savedCameraMode = player.CameraMode
	savedShiftLock = isShiftLocked
end

local function restoreEnvironment()
	if savedCameraType then
		camera.CameraType = savedCameraType
	end
	if savedCameraSubject then
		camera.CameraSubject = savedCameraSubject
	end
	if savedFieldOfView then
		camera.FieldOfView = savedFieldOfView
	end
	if savedAutoRotate ~= nil and humanoid then
		humanoid.AutoRotate = savedAutoRotate
	end
	if savedCameraOffset and humanoid then
		humanoid.CameraOffset = savedCameraOffset
	end
	if savedMouseBehavior then
		UserInputService.MouseBehavior = savedMouseBehavior
	end
	if savedCameraMode then
		player.CameraMode = savedCameraMode
	end
	if savedShiftLock ~= nil then
		setShiftLock(savedShiftLock)
	end
end

local function makeInputSnapshot()
	local mouseDelta = currentMouseDelta
	if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
		mouseDelta = UserInputService:GetMouseDelta()
	end

	return {
		keysDown = deepCopy(currentKeysDown),
		mouseButtonsDown = deepCopy(currentMouseButtonsDown),
		mouseWheel = currentMouseWheel,
		mouseDelta = vector2ToTable(mouseDelta),
		mouseLocation = vector2ToTable(UserInputService:GetMouseLocation()),
		mouseBehaviorName = getMouseBehaviorName(),
		cameraModeName = getCameraModeName(),
	}
end

local function makeFrame(dt)
	return {
		dt = dt,
		rootCFrame = cframeToTable(rootPart.CFrame),
		cameraCFrame = cframeToTable(camera.CFrame),
		velocity = vector3ToTable(rootPart.AssemblyLinearVelocity),
		angularVelocity = vector3ToTable(rootPart.AssemblyAngularVelocity),
		cameraOffset = vector3ToTable(humanoid.CameraOffset),
		moveDirection = vector3ToTable(humanoid.MoveDirection),
		fieldOfView = camera.FieldOfView,
		humanoidStateName = getHumanoidStateName(),
		jump = humanoid.Jump,
		walkSpeed = humanoid.WalkSpeed,
		jumpPower = humanoid.JumpPower,
		shiftLock = isShiftLocked,
		input = makeInputSnapshot(),
	}
end

local function applyShiftLockFromFrame(frame)
	setShiftLock(frame.shiftLock == true)

	if frame.shiftLock ~= true then
		UserInputService.MouseBehavior = mouseBehaviorFromName(frame.input.mouseBehaviorName)
	end

	player.CameraMode = cameraModeFromName(frame.input.cameraModeName)
end

local function applyFrozenFrame(index)
	if not hasCharacter() then
		return
	end

	local frame = frames[index]
	if not frame then
		return
	end

	rootPart.Anchored = true
	humanoid.AutoRotate = false

	rootPart.CFrame = tableToCFrame(frame.rootCFrame)
	rootPart.AssemblyLinearVelocity = tableToVector3(frame.velocity)
	rootPart.AssemblyAngularVelocity = tableToVector3(frame.angularVelocity)

	humanoid.CameraOffset = frame.shiftLock and SHIFTLOCK_OFFSET or tableToVector3(frame.cameraOffset)
	humanoid.WalkSpeed = frame.walkSpeed or humanoid.WalkSpeed
	humanoid.JumpPower = frame.jumpPower or humanoid.JumpPower
	humanoid:ChangeState(humanoidStateFromName(frame.humanoidStateName))

	applyShiftLockFromFrame(frame)

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = tableToCFrame(frame.cameraCFrame)
	camera.FieldOfView = frame.fieldOfView

	state.frame = index
	updateGui()
end

local function stopRecording()
	if recordConn then
		recordConn:Disconnect()
		recordConn = nil
	end
	if state.mode == "recording" then
		state.mode = "idle"
	end
	updateGui()
end

local function stopReplay()
	if replayConn then
		replayConn:Disconnect()
		replayConn = nil
	end

	state.mode = "idle"
	state.isPlaying = false
	state.playOneFrame = false
	holdBack = false
	holdForward = false

	if hasCharacter() then
		rootPart.Anchored = false
	end

	restoreEnvironment()
	updateGui()
end

local function startRecordingFresh()
	if not hasCharacter() then
		return
	end

	if state.mode == "replay" then
		stopReplay()
	end

	frames = {}
	state.frame = 1
	state.mode = "recording"
	state.isPlaying = false
	state.playOneFrame = false

	if recordConn then
		recordConn:Disconnect()
	end

	recordConn = RunService.RenderStepped:Connect(function(dt)
		if state.mode ~= "recording" or not hasCharacter() then
			return
		end

		table.insert(frames, makeFrame(dt))
		state.frame = #frames
		currentMouseDelta = Vector2.zero
		currentMouseWheel = 0
		updateGui()
	end)

	updateGui()
end

local function ensureReplayMode(startFrame)
	if #frames == 0 or not hasCharacter() then
		return false
	end

	if state.mode == "recording" then
		stopRecording()
	end

	if state.mode ~= "replay" then
		saveEnvironment()
	end

	state.mode = "replay"
	state.isPlaying = false
	state.playOneFrame = false
	state.frame = clamp(startFrame or state.frame or 1, 1, #frames)

	applyFrozenFrame(state.frame)
	return true
end

local function goToFrame(index)
	if not ensureReplayMode(index) then
		return
	end
	state.frame = clamp(index, 1, #frames)
	applyFrozenFrame(state.frame)
end

local function stepFrame(delta)
	if #frames == 0 then
		return
	end
	goToFrame((state.frame or 1) + delta)
end

local function playOneNextFrame()
	if state.mode ~= "replay" then
		return
	end
	if #frames == 0 or state.frame >= #frames then
		return
	end

	state.playOneFrame = true
	state.isPlaying = true
	updateGui()
end

local function overwriteFromCurrentFrame()
	if #frames == 0 or not hasCharacter() then
		return
	end

	local overwriteIndex = clamp(state.frame, 1, #frames)
	local chosenFrame = frames[overwriteIndex]
	if not chosenFrame then
		return
	end

	if replayConn then
		replayConn:Disconnect()
		replayConn = nil
	end

	while #frames > overwriteIndex do
		table.remove(frames)
	end

	rootPart.Anchored = false
	rootPart.CFrame = tableToCFrame(chosenFrame.rootCFrame)
	rootPart.AssemblyLinearVelocity = tableToVector3(chosenFrame.velocity)
	rootPart.AssemblyAngularVelocity = tableToVector3(chosenFrame.angularVelocity)

	humanoid.AutoRotate = true
	humanoid.CameraOffset = chosenFrame.shiftLock and SHIFTLOCK_OFFSET or tableToVector3(chosenFrame.cameraOffset)
	humanoid.WalkSpeed = chosenFrame.walkSpeed or humanoid.WalkSpeed
	humanoid.JumpPower = chosenFrame.jumpPower or humanoid.JumpPower
	humanoid:ChangeState(humanoidStateFromName(chosenFrame.humanoidStateName))

	applyShiftLockFromFrame(chosenFrame)

	camera.CameraType = Enum.CameraType.Custom
	camera.CameraSubject = humanoid
	camera.FieldOfView = chosenFrame.fieldOfView

	state.mode = "recording"
	state.isPlaying = false
	state.playOneFrame = false
	holdBack = false
	holdForward = false
	state.frame = #frames

	if recordConn then
		recordConn:Disconnect()
	end

	recordConn = RunService.RenderStepped:Connect(function(dt)
		if state.mode ~= "recording" or not hasCharacter() then
			return
		end

		table.insert(frames, makeFrame(dt))
		state.frame = #frames
		currentMouseDelta = Vector2.zero
		currentMouseWheel = 0
		updateGui()
	end)

	updateGui()
end

local function startReplayFromBeginning()
	if not ensureReplayMode(1) then
		return
	end

	state.frame = 1
	state.isPlaying = true
	state.playOneFrame = false

	if replayConn then
		replayConn:Disconnect()
	end

	replayConn = RunService.RenderStepped:Connect(function()
		if state.mode ~= "replay" then
			return
		end
		if not hasCharacter() then
			return
		end
		if #frames == 0 then
			return
		end

		if not state.isPlaying then
			applyFrozenFrame(state.frame)
			return
		end

		local index = clamp(state.frame, 1, #frames)
		local frame = frames[index]
		if not frame then
			stopReplay()
			return
		end

		rootPart.Anchored = true
		humanoid.AutoRotate = false

		rootPart.CFrame = tableToCFrame(frame.rootCFrame)
		rootPart.AssemblyLinearVelocity = tableToVector3(frame.velocity)
		rootPart.AssemblyAngularVelocity = tableToVector3(frame.angularVelocity)

		humanoid.CameraOffset = frame.shiftLock and SHIFTLOCK_OFFSET or tableToVector3(frame.cameraOffset)
		humanoid.WalkSpeed = frame.walkSpeed or humanoid.WalkSpeed
		humanoid.JumpPower = frame.jumpPower or humanoid.JumpPower
		humanoid:ChangeState(humanoidStateFromName(frame.humanoidStateName))

		applyShiftLockFromFrame(frame)

		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = tableToCFrame(frame.cameraCFrame)
		camera.FieldOfView = frame.fieldOfView

		updateGui()

		if state.playOneFrame then
			state.playOneFrame = false
			state.isPlaying = false
			if index < #frames then
				state.frame = index + 1
				applyFrozenFrame(state.frame)
			end
			return
		end

		if index < #frames then
			state.frame = index + 1
		else
			state.isPlaying = false
			applyFrozenFrame(index)
		end
	end)

	updateGui()
end

local function clearRecording()
	if state.mode == "recording" then
		stopRecording()
	end
	if state.mode == "replay" then
		stopReplay()
	end

	frames = {}
	state.frame = 1
	updateGui()
end

local function parseFrameFromBox()
	local num = tonumber(frameBox.Text)
	if not num then
		return nil
	end
	return math.floor(num)
end

goButton.MouseButton1Click:Connect(function()
	local num = parseFrameFromBox()
	if not num then
		return
	end
	goToFrame(num)
end)

frameBox.FocusLost:Connect(function(enterPressed)
	if not enterPressed then
		return
	end

	local num = parseFrameFromBox()
	if not num then
		return
	end
	goToFrame(num)
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if not gameProcessed then
		if input.UserInputType == Enum.UserInputType.Keyboard then
			currentKeysDown[input.KeyCode.Name] = true
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			currentMouseButtonsDown["MouseButton1"] = true
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			currentMouseButtonsDown["MouseButton2"] = true
		end
	end

	if gameProcessed or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	local key = input.KeyCode

	if key == Enum.KeyCode.Backspace then
		clearRecording()
		return
	end

	if key == Enum.KeyCode.J then
		if state.mode == "idle" then
			startRecordingFresh()
		elseif state.mode == "recording" then
			stopRecording()
		end
		return
	end

	if key == Enum.KeyCode.N then
		startReplayFromBeginning()
		return
	end

	if key == Enum.KeyCode.E then
		overwriteFromCurrentFrame()
		return
	end

	if key == Enum.KeyCode.L then
		if state.mode == "replay" then
			stopReplay()
		end
		return
	end

	if key == Enum.KeyCode.F then
		stepFrame(-1)
		return
	end

	if key == Enum.KeyCode.V then
		playOneNextFrame()
		return
	end

	if key == Enum.KeyCode.R then
		if #frames > 0 then
			goToFrame(state.frame)
			holdBack = true
			holdForward = false
			stepFrame(-fastScrubStep)
			nextRepeatAt = os.clock() + firstRepeatDelay
		end
		return
	end

	if key == Enum.KeyCode.T then
		if #frames > 0 then
			goToFrame(state.frame)
			holdForward = true
			holdBack = false
			stepFrame(fastScrubStep)
			nextRepeatAt = os.clock() + firstRepeatDelay
		end
		return
	end
end)

UserInputService.InputChanged:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseMovement then
		local d = input.Delta
		currentMouseDelta += Vector2.new(d.X, d.Y)
	elseif input.UserInputType == Enum.UserInputType.MouseWheel then
		currentMouseWheel += input.Position.Z
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	if not gameProcessed then
		if input.UserInputType == Enum.UserInputType.Keyboard then
			currentKeysDown[input.KeyCode.Name] = nil
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			currentMouseButtonsDown["MouseButton1"] = nil
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			currentMouseButtonsDown["MouseButton2"] = nil
		end
	end

	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	local key = input.KeyCode
	if key == Enum.KeyCode.R then
		holdBack = false
	elseif key == Enum.KeyCode.T then
		holdForward = false
	end
end)

scrubConn = RunService.RenderStepped:Connect(function()
	if #frames == 0 then
		return
	end

	local now = os.clock()

	if holdBack and now >= nextRepeatAt then
		stepFrame(-fastScrubStep)
		nextRepeatAt = now + repeatDelay
	elseif holdForward and now >= nextRepeatAt then
		stepFrame(fastScrubStep)
		nextRepeatAt = now + repeatDelay
	end
end)

updateGui()
