local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

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

local frames = {}

local state = {
	mode = "idle", -- idle, recording, replay
	frame = 1,
	uiVisible = true,
	playOneFrame = false,
}

local recordConn = nil
local replayConn = nil
local scrubConn = nil

local holdBack = false
local holdForward = false
local nextRepeatAt = 0

local firstRepeatDelay = 0.08
local repeatDelay = 0.020
local fastScrubStep = 2

local savedCameraType = nil
local savedCameraSubject = nil
local savedFieldOfView = nil
local savedAutoRotate = nil
local savedCameraOffset = nil
local savedMouseBehavior = nil
local savedCameraMode = nil

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TASGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.new(0, 520, 0, 325)
main.Position = UDim2.new(0, 20, 0, 20)
main.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
main.BackgroundTransparency = 0.06
main.BorderSizePixel = 0
main.Parent = screenGui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 12)
mainCorner.Parent = main

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Color3.fromRGB(80, 80, 80)
mainStroke.Thickness = 1
mainStroke.Parent = main

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 12, 0, 8)
title.Size = UDim2.new(1, -24, 0, 28)
title.Font = Enum.Font.SourceSansBold
title.TextSize = 26
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.Text = "TAS Tool"
title.Parent = main

local statusLabel = Instance.new("TextLabel")
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.new(0, 12, 0, 38)
statusLabel.Size = UDim2.new(1, -24, 0, 24)
statusLabel.Font = Enum.Font.SourceSansBold
statusLabel.TextSize = 20
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextColor3 = Color3.fromRGB(180, 255, 180)
statusLabel.Text = "Статус: ожидание"
statusLabel.Parent = main

local controlsLabel = Instance.new("TextLabel")
controlsLabel.BackgroundTransparency = 1
controlsLabel.Position = UDim2.new(0, 12, 0, 68)
controlsLabel.Size = UDim2.new(1, -24, 0, 160)
controlsLabel.Font = Enum.Font.SourceSans
controlsLabel.TextSize = 19
controlsLabel.TextXAlignment = Enum.TextXAlignment.Left
controlsLabel.TextYAlignment = Enum.TextYAlignment.Top
controlsLabel.TextWrapped = true
controlsLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
controlsLabel.Text =
	"J = старт записи с нуля / стоп записи\n" ..
	"N = запуск реплея с 1 кадра\n" ..
	"E = перезаписать с текущего кадра\n" ..
	"R/T = быстро назад / вперёд\n" ..
	"F = -1 кадр\n" ..
	"V = проиграть 1 следующий кадр\n" ..
	"L = выйти из реплея\n" ..
	"Backspace = очистить запись\n" ..
	"Frame + GO = перейти на нужный кадр"
controlsLabel.Parent = main

local infoLabel = Instance.new("TextLabel")
infoLabel.BackgroundTransparency = 1
infoLabel.Position = UDim2.new(0, 12, 0, 232)
infoLabel.Size = UDim2.new(1, -24, 0, 24)
infoLabel.Font = Enum.Font.SourceSans
infoLabel.TextSize = 19
infoLabel.TextXAlignment = Enum.TextXAlignment.Left
infoLabel.TextColor3 = Color3.fromRGB(255, 235, 170)
infoLabel.Text = "Кадров: 0 | Текущий: 0"
infoLabel.Parent = main

local frameBox = Instance.new("TextBox")
frameBox.ClearTextOnFocus = false
frameBox.PlaceholderText = "Frame"
frameBox.Text = ""
frameBox.Size = UDim2.new(0, 120, 0, 32)
frameBox.Position = UDim2.new(0, 12, 0, 264)
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
goButton.Size = UDim2.new(0, 70, 0, 32)
goButton.Position = UDim2.new(0, 140, 0, 264)
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
timelineBack.Position = UDim2.new(0, 12, 1, -24)
timelineBack.Size = UDim2.new(1, -24, 0, 10)
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
	alpha = math.clamp(alpha or 0, 0, 1)
	timelineFill.Size = UDim2.new(alpha, 0, 1, 0)
end

local function updateGui()
	local total = #frames
	local current = math.clamp(state.frame, 0, math.max(total, 0))

	infoLabel.Text = ("Кадров: %d | Текущий: %d"):format(total, current)

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
		statusLabel.Text = "Статус: просмотр / перемотка"
		statusLabel.TextColor3 = Color3.fromRGB(120, 210, 255)
	end
end

local function packCFrame(cf, prefix, out)
	out[prefix .. "px"] = cf.Position.X
	out[prefix .. "py"] = cf.Position.Y
	out[prefix .. "pz"] = cf.Position.Z

	out[prefix .. "rx"] = cf.RightVector.X
	out[prefix .. "ry"] = cf.RightVector.Y
	out[prefix .. "rz"] = cf.RightVector.Z

	out[prefix .. "ux"] = cf.UpVector.X
	out[prefix .. "uy"] = cf.UpVector.Y
	out[prefix .. "uz"] = cf.UpVector.Z

	out[prefix .. "lx"] = cf.LookVector.X
	out[prefix .. "ly"] = cf.LookVector.Y
	out[prefix .. "lz"] = cf.LookVector.Z
end

local function unpackCFrame(data, prefix)
	local pos = Vector3.new(data[prefix .. "px"], data[prefix .. "py"], data[prefix .. "pz"])
	local right = Vector3.new(data[prefix .. "rx"], data[prefix .. "ry"], data[prefix .. "rz"])
	local up = Vector3.new(data[prefix .. "ux"], data[prefix .. "uy"], data[prefix .. "uz"])
	local look = Vector3.new(data[prefix .. "lx"], data[prefix .. "ly"], data[prefix .. "lz"])
	return CFrame.fromMatrix(pos, right, up, -look)
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
	else
		return Enum.CameraMode.Classic
	end
end

local function nameToHumanoidState(name)
	if name == "Running" then
		return Enum.HumanoidStateType.Running
	elseif name == "Freefall" then
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
	else
		return Enum.HumanoidStateType.Running
	end
end

local function restoreInputAndCamera()
	if savedCameraType then
		camera.CameraType = savedCameraType
	end
	if savedCameraSubject then
		camera.CameraSubject = savedCameraSubject
	end
	if savedFieldOfView then
		camera.FieldOfView = savedFieldOfView
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
end

local function applyRecordedLiveSettings(frame)
	if not hasCharacter() then
		return
	end

	camera.CameraType = Enum.CameraType.Custom
	camera.CameraSubject = humanoid
	camera.FieldOfView = frame.fov or camera.FieldOfView

	humanoid.CameraOffset = Vector3.new(
		frame.camOffsetX or 0,
		frame.camOffsetY or 0,
		frame.camOffsetZ or 0
	)

	UserInputService.MouseBehavior = mouseBehaviorFromName(frame.mouseBehaviorName)
	player.CameraMode = cameraModeFromName(frame.cameraModeName)
end

local function applyFrame(index)
	if not hasCharacter() then
		return
	end

	local frame = frames[index]
	if not frame then
		return
	end

	local rootCF = unpackCFrame(frame, "r_")
	local camCF = unpackCFrame(frame, "c_")

	rootPart.CFrame = rootCF
	rootPart.AssemblyLinearVelocity = Vector3.new(
		frame.velX or 0,
		frame.velY or 0,
		frame.velZ or 0
	)
	rootPart.AssemblyAngularVelocity = Vector3.new(
		frame.angVelX or 0,
		frame.angVelY or 0,
		frame.angVelZ or 0
	)

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = camCF
	camera.FieldOfView = frame.fov or camera.FieldOfView

	humanoid.CameraOffset = Vector3.new(
		frame.camOffsetX or 0,
		frame.camOffsetY or 0,
		frame.camOffsetZ or 0
	)

	UserInputService.MouseBehavior = mouseBehaviorFromName(frame.mouseBehaviorName)
	player.CameraMode = cameraModeFromName(frame.cameraModeName)

	humanoid.AutoRotate = false
	humanoid:ChangeState(nameToHumanoidState(frame.humanoidStateName))

	state.frame = index
	updateGui()
end

local function stopReplay()
	if replayConn then
		replayConn:Disconnect()
		replayConn = nil
	end

	holdBack = false
	holdForward = false
	state.playOneFrame = false

	if hasCharacter() then
		rootPart.Anchored = false
		humanoid.AutoRotate = savedAutoRotate ~= nil and savedAutoRotate or true
	end

	restoreInputAndCamera()

	state.mode = "idle"
	updateGui()
end

local function enterReplayMode(startFrame)
	if #frames == 0 then
		return false
	end

	if not hasCharacter() then
		return false
	end

	if state.mode == "recording" then
		if recordConn then
			recordConn:Disconnect()
			recordConn = nil
		end
	end

	if state.mode ~= "replay" then
		savedCameraType = camera.CameraType
		savedCameraSubject = camera.CameraSubject
		savedFieldOfView = camera.FieldOfView
		savedAutoRotate = humanoid.AutoRotate
		savedCameraOffset = humanoid.CameraOffset
		savedMouseBehavior = UserInputService.MouseBehavior
		savedCameraMode = player.CameraMode

		rootPart.Anchored = true
		humanoid.AutoRotate = false
		camera.CameraType = Enum.CameraType.Scriptable
	end

	state.mode = "replay"
	state.frame = math.clamp(startFrame or 1, 1, #frames)
	applyFrame(state.frame)
	return true
end

local function stopRecording()
	if recordConn then
		recordConn:Disconnect()
		recordConn = nil
	end
	state.mode = "idle"
	updateGui()
end

local function makeFrame(dt)
	local camOffset = humanoid.CameraOffset
	local vel = rootPart.AssemblyLinearVelocity
	local angVel = rootPart.AssemblyAngularVelocity

	local frame = {
		dt = dt,
		fov = camera.FieldOfView,

		camOffsetX = camOffset.X,
		camOffsetY = camOffset.Y,
		camOffsetZ = camOffset.Z,

		velX = vel.X,
		velY = vel.Y,
		velZ = vel.Z,

		angVelX = angVel.X,
		angVelY = angVel.Y,
		angVelZ = angVel.Z,

		mouseBehaviorName = getMouseBehaviorName(),
		cameraModeName = getCameraModeName(),
		humanoidStateName = humanoid:GetState().Name,
	}

	packCFrame(rootPart.CFrame, "r_", frame)
	packCFrame(camera.CFrame, "c_", frame)

	return frame
end

local function startRecordingFresh()
	if state.mode == "replay" then
		stopReplay()
	end

	if not hasCharacter() then
		return
	end

	frames = {}
	state.frame = 1
	state.mode = "recording"

	if recordConn then
		recordConn:Disconnect()
	end

	recordConn = RunService.RenderStepped:Connect(function(dt)
		if state.mode ~= "recording" then
			return
		end
		if not hasCharacter() then
			return
		end

		table.insert(frames, makeFrame(dt))
		state.frame = #frames
		updateGui()
	end)

	updateGui()
end

local function resumeLiveFromRecordedFrame(frame)
	if not hasCharacter() then
		return
	end

	local camCF = unpackCFrame(frame, "c_")
	local linearVel = Vector3.new(frame.velX or 0, frame.velY or 0, frame.velZ or 0)
	local angularVel = Vector3.new(frame.angVelX or 0, frame.angVelY or 0, frame.angVelZ or 0)

	rootPart.Anchored = false
	humanoid.AutoRotate = true

	applyRecordedLiveSettings(frame)

	task.spawn(function()
		RunService.Heartbeat:Wait()
		if not hasCharacter() or state.mode ~= "recording" then
			return
		end

		rootPart.AssemblyLinearVelocity = linearVel
		rootPart.AssemblyAngularVelocity = angularVel
		camera.CFrame = camCF
	end)
end

local function overwriteFromCurrentFrame()
	if #frames == 0 then
		return
	end
	if not hasCharacter() then
		return
	end

	local overwriteFrame = math.clamp(state.frame, 1, #frames)
	local chosenFrame = frames[overwriteFrame]
	if not chosenFrame then
		return
	end

	if not enterReplayMode(overwriteFrame) then
		return
	end

	applyFrame(overwriteFrame)

	while #frames > overwriteFrame do
		table.remove(frames)
	end

	state.mode = "recording"
	state.frame = #frames

	if recordConn then
		recordConn:Disconnect()
	end

	resumeLiveFromRecordedFrame(chosenFrame)

	recordConn = RunService.RenderStepped:Connect(function(dt)
		if state.mode ~= "recording" then
			return
		end
		if not hasCharacter() then
			return
		end

		table.insert(frames, makeFrame(dt))
		state.frame = #frames
		updateGui()
	end)

	updateGui()
end

local function startReplayFromBeginning()
	if #frames == 0 then
		return
	end

	if not enterReplayMode(1) then
		return
	end

	if replayConn then
		replayConn:Disconnect()
	end

	replayConn = RunService.RenderStepped:Connect(function()
		if state.mode ~= "replay" then
			return
		end
		if #frames == 0 then
			return
		end
		if state.frame > #frames then
			stopReplay()
			return
		end

		applyFrame(state.frame)

		if state.playOneFrame then
			state.playOneFrame = false
			if state.frame < #frames then
				state.frame += 1
				applyFrame(state.frame)
			end
			return
		end

		state.frame += 1

		if state.frame > #frames then
			state.frame = #frames
			applyFrame(state.frame)
			stopReplay()
		end
	end)

	updateGui()
end

local function goToFrame(index)
	if #frames == 0 then
		return
	end

	if not enterReplayMode(index) then
		return
	end

	state.frame = math.clamp(index, 1, #frames)
	applyFrame(state.frame)
end

local function stepFrame(delta)
	if #frames == 0 then
		return
	end

	local target = math.clamp((state.frame or 1) + delta, 1, #frames)
	goToFrame(target)
end

local function playOneNextFrame()
	if state.mode ~= "replay" then
		return
	end
	if #frames == 0 then
		return
	end
	if state.frame >= #frames then
		return
	end

	state.playOneFrame = true
end

local function startScrubLoop()
	if scrubConn then
		return
	end

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
end

startScrubLoop()

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
	if gameProcessed then
		return
	end

	if input.UserInputType ~= Enum.UserInputType.Keyboard then
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
			holdBack = true
			holdForward = false
			stepFrame(-fastScrubStep)
			nextRepeatAt = os.clock() + firstRepeatDelay
		end
		return
	end

	if key == Enum.KeyCode.T then
		if #frames > 0 then
			holdForward = true
			holdBack = false
			stepFrame(fastScrubStep)
			nextRepeatAt = os.clock() + firstRepeatDelay
		end
		return
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	local key = input.KeyCode

	if key == Enum.KeyCode.R then
		holdBack = false
		return
	end

	if key == Enum.KeyCode.T then
		holdForward = false
		return
	end
end)

updateGui()
