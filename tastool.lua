--[[
TAS Lite v0.7 (Roblox, LocalScript/executor)
- Stable record/playback timing
- Freeze/seek with safe frame indexing
- Checkpoints + append recording mode
- Save/load JSON (backward compatible with v0.1/v0.2 frames)
- On-screen log + record freeze/trim indicators
- Playback mode: ghost (exact) or physics (with collisions)

Hotkeys:
F8  - start/stop record
F10 - start/stop playback
F6  - save replay to file
F7  - load replay from file
E   - freeze/unfreeze (during record/playback)
F   - previous frame (when frozen, record/playback)
G   - next frame (when frozen, record/playback)
R/T - hold to seek backward/forward (auto-freezes if needed)
U   - toggle status UI
C   - set quick checkpoint (record/playback)
V   - goto quick checkpoint (record/playback)
Slash (/) - focus command bar
]]

local CONFIG = {
	ROUND_DIGITS = 3,
	DEFAULT_FRAME_DT = 1 / 60,
	SEEK_SPEED = 1, -- frames per render step while holding R/T
	PLAYBACK_SPEED = 1, -- realtime multiplier
	PLAYBACK_MODE = "physics", -- "ghost" | "physics"
	PHYSICS_LERP_DISTANCE = 1.5,
	PHYSICS_SNAP_DISTANCE = 8,
	PHYSICS_LERP_ALPHA = 0.35,
	LOG_LINES = 8,
	FOLDER = "TASLite",
	FILE_NAME = "Replay.json",
}

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local mode = "idle" -- idle | record | play
local frozen = false
local seekDir = 0 -- -1 / 0 / 1
local frames = {}
local playIndex = 1
local heldKeys = {}
local uiVisible = true
local seekSpeed = CONFIG.SEEK_SPEED
local recordMode = "replace" -- replace | append
local checkpoints = {}
local QUICK_CP_NAME = "quick"

local playbackSpeed = CONFIG.PLAYBACK_SPEED
local playbackMode = CONFIG.PLAYBACK_MODE
local playbackAccumulator = 0
local lastTrimmedCount = 0
local logLines = {}
local logLabel

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
		camera.CameraType = Enum.CameraType.Scriptable
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
		}
	end

	hum.WalkSpeed = 0
	hum.JumpPower = 0
	hum.AutoRotate = false
	if playbackMode == "ghost" then
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
			cam = rawFrame.cam,
			fov = tonumber(rawFrame.fov) or 70,
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

	local _, hrp = humanoidAndRoot()
	if not hrp then
		return false
	end

	local rootCF = tableToCf(frame.root)
	local camCF = tableToCf(frame.cam)
	if not rootCF or not camCF then
		return false
	end

	if playbackMode == "ghost" then
		hrp.CFrame = rootCF
		hrp.AssemblyLinearVelocity = tableToV3(frame.vel)
	else
		local targetVel = tableToV3(frame.vel)
		hrp.AssemblyLinearVelocity = targetVel
		local dist = (hrp.Position - rootCF.Position).Magnitude
		if dist > CONFIG.PHYSICS_SNAP_DISTANCE then
			hrp.CFrame = rootCF
		elseif dist > CONFIG.PHYSICS_LERP_DISTANCE then
			hrp.CFrame = hrp.CFrame:Lerp(rootCF, CONFIG.PHYSICS_LERP_ALPHA)
		end
	end
	camera.CFrame = camCF
	camera.FieldOfView = tonumber(frame.fov) or 70
	return true
end

local function statusText()
	local recordFreezeText = (mode == "record" and frozen and "ON") or "OFF"
	return string.format(
		"Mode: %s | Frozen: %s | RecFreeze: %s | Frame: %d/%d | Trimmed: %d | RecordMode: %s | PlaybackMode: %s | SeekSpeed: %.2f | PlaySpeed: %.2f\nF8 Rec  F10 Play  F6 Save  F7 Load  E Freeze  F/G Step  R/T Seek  C/V Checkpoint  / Command  U UI",
		mode,
		tostring(frozen),
		recordFreezeText,
		playIndex,
		#frames,
		lastTrimmedCount,
		recordMode,
		playbackMode,
		seekSpeed,
		playbackSpeed
	)
end

-- UI
local gui = Instance.new("ScreenGui")
gui.Name = "TASLiteUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false

local label = Instance.new("TextLabel")
label.Size = UDim2.fromOffset(760, 120)
label.Position = UDim2.fromOffset(12, 12)
label.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
label.BackgroundTransparency = 0.25
label.TextColor3 = Color3.fromRGB(255, 255, 255)
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextYAlignment = Enum.TextYAlignment.Top
label.Font = Enum.Font.Code
label.TextSize = 16
label.Text = ""
label.Parent = gui

local commandBar = Instance.new("TextBox")
commandBar.Size = UDim2.fromOffset(760, 30)
commandBar.Position = UDim2.fromOffset(12, 138)
commandBar.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
commandBar.BackgroundTransparency = 0.25
commandBar.TextColor3 = Color3.fromRGB(255, 255, 255)
commandBar.TextXAlignment = Enum.TextXAlignment.Left
commandBar.Font = Enum.Font.Code
commandBar.PlaceholderText = "help | erase | setspeed <n> | playspeed <n> | recordmode <replace|append> | cp ..."
commandBar.TextSize = 16
commandBar.ClearTextOnFocus = false
commandBar.Text = ""
commandBar.Parent = gui

logLabel = Instance.new("TextLabel")
logLabel.Size = UDim2.fromOffset(760, 170)
logLabel.Position = UDim2.fromOffset(12, 174)
logLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
logLabel.BackgroundTransparency = 0.35
logLabel.TextColor3 = Color3.fromRGB(175, 255, 175)
logLabel.TextXAlignment = Enum.TextXAlignment.Left
logLabel.TextYAlignment = Enum.TextYAlignment.Top
logLabel.Font = Enum.Font.Code
logLabel.TextSize = 14
logLabel.TextWrapped = false
logLabel.Text = ""
logLabel.Parent = gui

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

local function updateUI()
	label.Text = statusText()
	gui.Enabled = uiVisible
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

local function captureFrame(dt)
	local _, hrp = humanoidAndRoot()
	if not hrp then
		return
	end

	local frame = {
		dt = round(math.max(1 / 1000, dt or CONFIG.DEFAULT_FRAME_DT), 5),
		root = roundArray(cfToTable(hrp.CFrame), CONFIG.ROUND_DIGITS),
		vel = roundArray(v3ToTable(hrp.AssemblyLinearVelocity), CONFIG.ROUND_DIGITS),
		cam = roundArray(cfToTable(camera.CFrame), CONFIG.ROUND_DIGITS),
		fov = round(camera.FieldOfView, CONFIG.ROUND_DIGITS),
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
end

local function startRecord()
	mode = "record"
	setFrozen(false)
	seekDir = 0
	playbackAccumulator = 0
	clearPlaybackLock()
	clearRecordFreezeLock()
	setCameraPlaybackMode(false)

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
	setCameraPlaybackMode(true)
	applyPlaybackLock()
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
	clearPlaybackLock()
	setCameraPlaybackMode(false)
	log("Playback stopped")
end

local function saveReplay()
	ensureFolder()
	local payload = {
		version = "0.7",
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
	log("playbackmode <ghost|physics>")
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
		return
	end

	if cmd == "playbackmode" then
		local newMode = string.lower(args[2] or "")
		if newMode ~= "ghost" and newMode ~= "physics" then
			log("Usage: playbackmode <ghost|physics>")
			return
		end
		playbackMode = newMode
		if mode == "play" then
			applyPlaybackLock()
		end
		log("Playback mode set to " .. playbackMode)
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
		heldKeys[input.KeyCode.Name] = true
	end

	if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.Slash then
		commandBar:CaptureFocus()
	end

	if UIS:GetFocusedTextBox() then
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
	elseif kc == Enum.KeyCode.R then
		if mode == "play" or mode == "record" then
			if not frozen then
				setFrozen(true)
			end
			seekDir = -1
		end
	elseif kc == Enum.KeyCode.T then
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
	end

	if input.KeyCode == Enum.KeyCode.R and seekDir == -1 then
		seekDir = 0
	elseif input.KeyCode == Enum.KeyCode.T and seekDir == 1 then
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
			captureFrame(dt)
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
			while playbackAccumulator >= 0 do
				local frame = frames[playIndex]
				if not frame then
					stopPlay()
					break
				end
				local frameDt = math.max(tonumber(frame.dt) or CONFIG.DEFAULT_FRAME_DT, 1 / 1000)
				if playbackAccumulator < frameDt then
					break
				end

				local ok = applyFrame(playIndex)
				if not ok then
					stopPlay()
					break
				end

				playbackAccumulator = playbackAccumulator - frameDt
				playIndex = playIndex + 1
				if playIndex > #frames then
					stopPlay()
					break
				end
			end
		end
	end

	updateUI()
end)

player.CharacterAdded:Connect(function()
	if mode == "play" then
		task.wait(0.2)
		applyPlaybackLock()
	end
end)

log("Loaded v0.7. PlaceId: " .. tostring(game.PlaceId))
log("Playback mode: " .. playbackMode .. " (use 'playbackmode ghost|physics')")
log("Playback hotkey moved to F10")
log("Type '/' to open command bar, then use 'help'")
updateUI()
