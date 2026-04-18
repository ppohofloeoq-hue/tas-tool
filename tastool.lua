--[[
TAS Lite v0.2 (Roblox, LocalScript/executor)
- Record / Playback / Freeze / Seek
- Save / Load replay as JSON file
- Command bar: help, erase, setspeed, recordmode, cp
- Checkpoints + append recording mode
- No anticheat bypasses

Hotkeys:
F8  - start/stop record
F9  - start/stop playback
F6  - save replay to file
F7  - load replay from file
E   - freeze/unfreeze (during playback)
F   - previous frame (when frozen)
G   - next frame (when frozen)
R/T - hold to seek backward/forward (when frozen)
U   - toggle status UI
C   - set quick checkpoint
V   - goto quick checkpoint
Slash (/) - focus command bar
]]

local CONFIG = {
	ROUND_DIGITS = 3,
	SEEK_SPEED = 1, -- frames per render step while holding R/T
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
local applyFrame

local function char()
	return player.Character or player.CharacterAdded:Wait()
end

local function humanoidRootPart()
	local c = char()
	return c and c:FindFirstChild("HumanoidRootPart")
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
	return CFrame.new(unpack(t))
end

local function v3ToTable(v)
	return { v.X, v.Y, v.Z }
end

local function tableToV3(t)
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

local function ensureFolder()
	if not isfolder(CONFIG.FOLDER) then
		makefolder(CONFIG.FOLDER)
	end
end

local replayPath = CONFIG.FOLDER .. "/" .. tostring(game.PlaceId) .. "_" .. CONFIG.FILE_NAME

-- UI
local gui = Instance.new("ScreenGui")
gui.Name = "TASLiteUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false

local label = Instance.new("TextLabel")
label.Size = UDim2.fromOffset(620, 100)
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
commandBar.Size = UDim2.fromOffset(620, 30)
commandBar.Position = UDim2.fromOffset(12, 120)
commandBar.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
commandBar.BackgroundTransparency = 0.25
commandBar.TextColor3 = Color3.fromRGB(255, 255, 255)
commandBar.TextXAlignment = Enum.TextXAlignment.Left
commandBar.Font = Enum.Font.Code
commandBar.PlaceholderText = "Command: help | erase | setspeed <number> | recordmode <replace|append> | cp <set|goto|list> ..."
commandBar.TextSize = 16
commandBar.ClearTextOnFocus = false
commandBar.Text = ""
commandBar.Parent = gui

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

local function setCameraPlaybackMode(enabled)
	if enabled then
		camera.CameraType = Enum.CameraType.Scriptable
	else
		camera.CameraType = Enum.CameraType.Custom
	end
end

local function statusText()
	return string.format(
		"Mode: %s | Frozen: %s | Frame: %d/%d | RecordMode: %s | SeekSpeed: %.2f\nF8 Rec  F9 Play  F6 Save  F7 Load  E Freeze  F/G Step  R/T Seek  C/V Checkpoint  / Command  U UI",
		mode,
		tostring(frozen),
		playIndex,
		#frames,
		recordMode,
		seekSpeed
	)
end

local function log(msg)
	print("[TAS Lite] " .. msg)
end

local function updateUI()
	label.Text = statusText()
	gui.Enabled = uiVisible
end

local function getCurrentFrameIndex()
	if #frames == 0 then
		return 0
	end
	if mode == "play" then
		return math.clamp(playIndex, 1, #frames)
	end
	return #frames
end

local function setCheckpoint(name, index)
	name = tostring(name or QUICK_CP_NAME)
	local resolved = index or getCurrentFrameIndex()
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
	if idx < 1 or idx > #frames then
		log("Checkpoint '" .. name .. "' points outside replay")
		return false
	end
	playIndex = idx
	applyFrame(playIndex)
	log("Goto checkpoint '" .. name .. "' -> frame " .. tostring(playIndex))
	return true
end

local function captureFrame()
	local hrp = humanoidRootPart()
	if not hrp then
		return
	end

	local frame = {
		root = roundArray(cfToTable(hrp.CFrame), CONFIG.ROUND_DIGITS),
		vel = roundArray(v3ToTable(hrp.AssemblyLinearVelocity), CONFIG.ROUND_DIGITS),
		cam = roundArray(cfToTable(camera.CFrame), CONFIG.ROUND_DIGITS),
		fov = round(camera.FieldOfView, CONFIG.ROUND_DIGITS),
		keys = keysSnapshot(),
	}
	table.insert(frames, frame)
	playIndex = #frames
end

applyFrame = function(i)
	local frame = frames[i]
	if not frame then
		return false
	end

	local hrp = humanoidRootPart()
	if not hrp then
		return false
	end

	hrp.CFrame = tableToCf(frame.root)
	hrp.AssemblyLinearVelocity = tableToV3(frame.vel)

	camera.CFrame = tableToCf(frame.cam)
	camera.FieldOfView = frame.fov

	return true
end

local function startRecord()
	mode = "record"
	frozen = false
	seekDir = 0
	if recordMode == "replace" then
		frames = {}
		playIndex = 1
	else
		playIndex = math.max(1, #frames)
	end
	setCameraPlaybackMode(false)
	log("Recording started (" .. recordMode .. ")")
end

local function stopRecord()
	if mode == "record" then
		mode = "idle"
		log("Recording stopped. Frames: " .. tostring(#frames))
	end
end

local function startPlay()
	if #frames == 0 then
		log("No frames loaded/recorded")
		return
	end
	mode = "play"
	frozen = false
	seekDir = 0
	playIndex = 1
	setCameraPlaybackMode(true)
	log("Playback started")
end

local function stopPlay()
	if mode == "play" then
		mode = "idle"
		frozen = false
		seekDir = 0
		setCameraPlaybackMode(false)
		log("Playback stopped")
	end
end

local function saveReplay()
	ensureFolder()
	local payload = {
		version = "0.2",
		placeId = game.PlaceId,
		savedAtUnix = os.time(),
		frames = frames,
		checkpoints = checkpoints,
	}
	local json = HttpService:JSONEncode(payload)
	writefile(replayPath, json)
	log("Saved: " .. replayPath .. " | Frames: " .. tostring(#frames))
end

local function loadReplay()
	if not isfile(replayPath) then
		log("Replay file not found: " .. replayPath)
		return
	end
	local raw = readfile(replayPath)
	local ok, data = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok or type(data) ~= "table" or type(data.frames) ~= "table" then
		log("Invalid replay JSON")
		return
	end
	frames = data.frames
	checkpoints = type(data.checkpoints) == "table" and data.checkpoints or {}
	playIndex = 1
	log("Loaded replay. Frames: " .. tostring(#frames) .. " | Checkpoints: " .. tostring((function()
		local count = 0
		for _ in pairs(checkpoints) do
			count = count + 1
		end
		return count
	end)()))
end

local function eraseReplay()
	frames = {}
	checkpoints = {}
	playIndex = 1
	frozen = false
	seekDir = 0
	mode = "idle"
	setCameraPlaybackMode(false)
	saveReplay()
	log("Replay erased")
end

local function commandHelp()
	log("Commands:")
	log("help")
	log("erase")
	log("setspeed <number>")
	log("recordmode <replace|append>")
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
		local key = input.KeyCode.Name
		heldKeys[key] = true
	end

	if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.Slash then
		commandBar:CaptureFocus()
	end

	local focused = UIS:GetFocusedTextBox()
	if focused and focused ~= nil then
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
	elseif kc == Enum.KeyCode.F9 then
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
		if mode == "play" then
			frozen = not frozen
		end
	elseif kc == Enum.KeyCode.F then
		if mode == "play" and frozen then
			playIndex = math.max(1, playIndex - 1)
			applyFrame(playIndex)
		end
	elseif kc == Enum.KeyCode.G then
		if mode == "play" and frozen then
			playIndex = math.min(#frames, playIndex + 1)
			applyFrame(playIndex)
		end
	elseif kc == Enum.KeyCode.R then
		if mode == "play" and frozen then
			seekDir = -1
		end
	elseif kc == Enum.KeyCode.T then
		if mode == "play" and frozen then
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
		local key = input.KeyCode.Name
		heldKeys[key] = nil
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

RunService.RenderStepped:Connect(function()
	if mode == "record" then
		captureFrame()
	elseif mode == "play" then
		if frozen then
			if seekDir ~= 0 then
				playIndex = math.clamp(playIndex + seekDir * seekSpeed, 1, #frames)
				applyFrame(playIndex)
			else
				applyFrame(playIndex)
			end
		else
			local ok = applyFrame(playIndex)
			if ok then
				playIndex += 1
				if playIndex > #frames then
					stopPlay()
				end
			else
				stopPlay()
			end
		end
	end

	updateUI()
end)

log("Loaded. PlaceId: " .. tostring(game.PlaceId))
log("Type '/' to open command bar, then use 'help'")
updateUI()
