--[[
	Spotify-style музыкальный плеер для Roblox
	Тип: LocalScript
	Куда положить: StarterPlayer > StarterPlayerScripts > (новый LocalScript)

	Управление:
	  • Клавиша M или зелёная кнопка ♪ слева внизу — показать/скрыть плеер
	  • Окно можно перетаскивать за верхнюю панель
	  • Внизу списка можно добавить трек по ID (вставь ID и нажми Enter / "+")
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local MarketplaceService = game:GetService("MarketplaceService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

------------------------------------------------------------
-- ПЛЕЙЛИСТ: замени ID на свои (только ID аудио из Toolbox/Creator Hub)
-- title и artist можно не указывать — подтянутся автоматически
------------------------------------------------------------
local PLAYLIST = {
	{ id = 1843463175, title = "Пример трека 1", artist = "Исполнитель" },
	{ id = 1837879082, title = "Пример трека 2", artist = "Исполнитель" },
	{ id = 9046863253 }, -- название возьмётся автоматически
}

------------------------------------------------------------
-- ТЕМА
------------------------------------------------------------
local BG       = Color3.fromRGB(18, 18, 18)
local PANEL    = Color3.fromRGB(24, 24, 24)
local ELEV     = Color3.fromRGB(40, 40, 40)
local ELEV2    = Color3.fromRGB(83, 83, 83)
local GREEN    = Color3.fromRGB(30, 215, 96)
local TEXT     = Color3.fromRGB(255, 255, 255)
local SUB      = Color3.fromRGB(179, 179, 179)
local FONT     = Enum.Font.GothamMedium
local FONT_B   = Enum.Font.GothamBold

------------------------------------------------------------
-- ХЕЛПЕРЫ
------------------------------------------------------------
local function new(class, props)
	local inst = Instance.new(class)
	local parent = props.Parent
	props.Parent = nil
	for k, v in pairs(props) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

local function corner(inst, radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius), Parent = inst })
end

local function label(props)
	props.BackgroundTransparency = 1
	props.Font = props.Font or FONT
	props.TextColor3 = props.TextColor3 or TEXT
	props.TextSize = props.TextSize or 14
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return new("TextLabel", props)
end

local function formatTime(s)
	s = math.max(0, math.floor(s))
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function isPointer(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function isMove(input)
	return input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch
end

------------------------------------------------------------
-- ЗВУК
------------------------------------------------------------
local sound = Instance.new("Sound")
sound.Name = "SpotifyPlayerSound"
sound.Volume = 0.5
sound.Parent = SoundService

local index = 0          -- текущий трек (0 = ничего)
local shuffle = false
local repeatMode = 0     -- 0 выкл, 1 весь плейлист, 2 один трек
local failCount = 0
local playToken = 0

------------------------------------------------------------
-- GUI
------------------------------------------------------------
local gui = new("ScreenGui", {
	Name = "SpotifyPlayer",
	ResetOnSpawn = false,
	DisplayOrder = 10,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})

local main = new("Frame", {
	Name = "Main",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(440, 580),
	BackgroundColor3 = BG,
	BorderSizePixel = 0,
	Parent = gui,
})
corner(main, 12)
new("UIStroke", { Color = ELEV, Thickness = 1, Parent = main })

local uiScale = new("UIScale", { Parent = main })
local function rescale()
	local cam = workspace.CurrentCamera
	if not cam then return end
	local v = cam.ViewportSize
	uiScale.Scale = math.clamp(math.min(v.X / 480, v.Y / 620), 0.5, 1)
end
rescale()
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
end

-- Шапка (за неё двигаем окно)
local header = new("Frame", {
	Size = UDim2.new(1, 0, 0, 48),
	BackgroundColor3 = PANEL,
	BorderSizePixel = 0,
	Parent = main,
})
corner(header, 12)
new("Frame", { -- закрываем нижние скругления шапки
	Position = UDim2.new(0, 0, 1, -12),
	Size = UDim2.new(1, 0, 0, 12),
	BackgroundColor3 = PANEL,
	BorderSizePixel = 0,
	Parent = header,
})

label({
	Text = "♪",
	Font = FONT_B,
	TextSize = 24,
	TextColor3 = GREEN,
	Position = UDim2.fromOffset(16, 0),
	Size = UDim2.fromOffset(24, 48),
	Parent = header,
})
label({
	Text = "Моя медиатека",
	Font = FONT_B,
	TextSize = 18,
	Position = UDim2.fromOffset(44, 0),
	Size = UDim2.new(1, -100, 1, 0),
	Parent = header,
})

local closeBtn = new("TextButton", {
	Text = "✕",
	Font = FONT_B,
	TextSize = 16,
	TextColor3 = SUB,
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -12, 0.5, 0),
	Size = UDim2.fromOffset(32, 32),
	Parent = header,
})

-- Перетаскивание
do
	local dragging, dragStart, startPos
	header.InputBegan:Connect(function(input)
		if isPointer(input) then
			dragging = true
			dragStart = input.Position
			startPos = main.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and isMove(input) then
			local d = (input.Position - dragStart) / uiScale.Scale
			main.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y
			)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if isPointer(input) then dragging = false end
	end)
end

-- Строка добавления трека по ID
local addRow = new("Frame", {
	Position = UDim2.fromOffset(12, 56),
	Size = UDim2.new(1, -24, 0, 32),
	BackgroundColor3 = ELEV,
	BorderSizePixel = 0,
	Parent = main,
})
corner(addRow, 16)

local addBox = new("TextBox", {
	PlaceholderText = "Вставь ID песни и нажми Enter",
	PlaceholderColor3 = SUB,
	Text = "",
	ClearTextOnFocus = false,
	Font = FONT,
	TextSize = 13,
	TextColor3 = TEXT,
	TextXAlignment = Enum.TextXAlignment.Left,
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(14, 0),
	Size = UDim2.new(1, -56, 1, 0),
	Parent = addRow,
})

local addBtn = new("TextButton", {
	Text = "+",
	Font = FONT_B,
	TextSize = 20,
	TextColor3 = BG,
	BackgroundColor3 = GREEN,
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -4, 0.5, 0),
	Size = UDim2.fromOffset(24, 24),
	AutoButtonColor = false,
	Parent = addRow,
})
corner(addBtn, 12)

-- Список треков
local listFrame = new("ScrollingFrame", {
	Position = UDim2.fromOffset(12, 96),
	Size = UDim2.new(1, -24, 0, 236),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = ELEV2,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	Parent = main,
})
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = listFrame })

-- Разделитель
new("Frame", {
	Position = UDim2.fromOffset(12, 340),
	Size = UDim2.new(1, -24, 0, 1),
	BackgroundColor3 = ELEV,
	BorderSizePixel = 0,
	Parent = main,
})

-- Обложка
local cover = new("Frame", {
	Position = UDim2.fromOffset(16, 354),
	Size = UDim2.fromOffset(80, 80),
	BackgroundColor3 = TEXT,
	BorderSizePixel = 0,
	Parent = main,
})
corner(cover, 6)
new("UIGradient", {
	Color = ColorSequence.new(Color3.fromRGB(96, 64, 200), GREEN),
	Rotation = 45,
	Parent = cover,
})
label({
	Text = "♪",
	Font = FONT_B,
	TextSize = 40,
	TextXAlignment = Enum.TextXAlignment.Center,
	Size = UDim2.fromScale(1, 1),
	Parent = cover,
})

local titleLbl = label({
	Text = "Ничего не играет",
	Font = FONT_B,
	TextSize = 18,
	TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(108, 364),
	Size = UDim2.new(1, -124, 0, 24),
	Parent = main,
})
local artistLbl = label({
	Text = "Выбери трек из списка",
	TextSize = 14,
	TextColor3 = SUB,
	TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(108, 390),
	Size = UDim2.new(1, -124, 0, 20),
	Parent = main,
})

-- Кнопки управления
local controls = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 444),
	Size = UDim2.fromOffset(300, 46),
	BackgroundTransparency = 1,
	Parent = main,
})
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 16),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = controls,
})

local function controlButton(text, order, size)
	local b = new("TextButton", {
		Text = text,
		Font = FONT_B,
		TextSize = size or 22,
		TextColor3 = SUB,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(36, 36),
		LayoutOrder = order,
		AutoButtonColor = false,
		Parent = controls,
	})
	return b
end

local shuffleBtn = controlButton("⇄", 1)
local prevBtn = controlButton("⏮", 2, 20)
local playBtn = new("TextButton", {
	Text = "▶",
	Font = FONT_B,
	TextSize = 20,
	TextColor3 = BG,
	BackgroundColor3 = TEXT,
	Size = UDim2.fromOffset(44, 44),
	LayoutOrder = 3,
	AutoButtonColor = false,
	Parent = controls,
})
corner(playBtn, 22)
local nextBtn = controlButton("⏭", 4, 20)
local repeatBtn = controlButton("↻", 5)

for _, b in ipairs({ prevBtn, nextBtn }) do
	b.TextColor3 = TEXT
end

-- Слайдер (прогресс и громкость)
local function makeSlider(parent, position, size, initial, onChanged)
	local bar = new("Frame", {
		Position = position,
		Size = size,
		BackgroundColor3 = ELEV2,
		BorderSizePixel = 0,
		Parent = parent,
	})
	corner(bar, 3)
	local fill = new("Frame", {
		Size = UDim2.fromScale(initial, 1),
		BackgroundColor3 = TEXT,
		BorderSizePixel = 0,
		Parent = bar,
	})
	corner(fill, 3)
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(12, 12),
		BackgroundColor3 = TEXT,
		Visible = false,
		Parent = fill,
	})
	corner(knob, 6)
	local hit = new("TextButton", {
		Text = "",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(1, 0, 0, 22),
		Parent = bar,
	})

	local dragging = false
	local function update(x)
		local a = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
		fill.Size = UDim2.fromScale(a, 1)
		onChanged(a)
	end
	hit.InputBegan:Connect(function(input)
		if isPointer(input) then
			dragging = true
			fill.BackgroundColor3 = GREEN
			knob.Visible = true
			update(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and isMove(input) then update(input.Position.X) end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if dragging and isPointer(input) then
			dragging = false
			fill.BackgroundColor3 = TEXT
			knob.Visible = false
		end
	end)

	return {
		Set = function(a)
			if not dragging then fill.Size = UDim2.fromScale(a, 1) end
		end,
		IsDragging = function() return dragging end,
	}
end

-- Прогресс
local curTime = label({
	Text = "0:00",
	TextSize = 12,
	TextColor3 = SUB,
	Position = UDim2.fromOffset(16, 494),
	Size = UDim2.fromOffset(40, 20),
	Parent = main,
})
local totTime = label({
	Text = "0:00",
	TextSize = 12,
	TextColor3 = SUB,
	TextXAlignment = Enum.TextXAlignment.Right,
	Position = UDim2.new(1, -56, 0, 494),
	Size = UDim2.fromOffset(40, 20),
	Parent = main,
})
local progress = makeSlider(main, UDim2.fromOffset(62, 501), UDim2.new(1, -124, 0, 6), 0, function(a)
	if sound.TimeLength > 0 then
		sound.TimePosition = a * sound.TimeLength
		curTime.Text = formatTime(sound.TimePosition)
	end
end)

-- Громкость
label({
	Text = "🔊",
	TextSize = 16,
	Position = UDim2.fromOffset(16, 526),
	Size = UDim2.fromOffset(28, 24),
	Parent = main,
})
local volume = makeSlider(main, UDim2.fromOffset(52, 536), UDim2.fromOffset(150, 6), sound.Volume, function(a)
	sound.Volume = a
end)

-- Кнопка-переключатель на экране
local toggleBtn = new("TextButton", {
	Name = "Toggle",
	Text = "♪",
	Font = FONT_B,
	TextSize = 24,
	TextColor3 = BG,
	BackgroundColor3 = GREEN,
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 16, 1, -16),
	Size = UDim2.fromOffset(44, 44),
	AutoButtonColor = false,
	Parent = gui,
})
corner(toggleBtn, 22)

------------------------------------------------------------
-- ЛОГИКА
------------------------------------------------------------
local rows = {}
local updateUI
local playTrack

local function nextTrack(auto)
	if #PLAYLIST == 0 then return end
	local n
	if shuffle and #PLAYLIST > 1 then
		repeat n = math.random(#PLAYLIST) until n ~= index
	else
		n = index + 1
		if n > #PLAYLIST then
			if repeatMode == 1 or not auto then
				n = 1
			else
				sound:Stop()
				updateUI()
				return
			end
		end
	end
	playTrack(n)
end

local function prevTrack()
	if index == 0 then playTrack(1) return end
	if sound.TimePosition > 3 then
		sound.TimePosition = 0
		return
	end
	local n = index - 1
	if n < 1 then n = #PLAYLIST end
	playTrack(n)
end

function playTrack(i)
	local track = PLAYLIST[i]
	if not track then return end
	index = i
	playToken += 1
	local my = playToken

	sound:Stop()
	sound.SoundId = "rbxassetid://" .. track.id
	sound:Play()
	updateUI()

	-- Если звук не загрузился (нет прав / удалён) — пропускаем
	task.spawn(function()
		local t0 = os.clock()
		while my == playToken and sound.TimeLength == 0 and os.clock() - t0 < 6 do
			task.wait(0.1)
		end
		if my ~= playToken then return end
		if sound.TimeLength == 0 then
			failCount += 1
			titleLbl.Text = "Недоступно: " .. tostring(track.title or track.id)
			task.wait(1.5)
			if my == playToken and failCount < #PLAYLIST then
				nextTrack(true)
			end
		else
			failCount = 0
		end
	end)
end

local function togglePlay()
	if index == 0 then
		playTrack(1)
	elseif sound.IsPlaying then
		sound:Pause()
	else
		sound:Play()
	end
end

function updateUI()
	local t = PLAYLIST[index]
	if t then
		titleLbl.Text = t.title or "Загрузка…"
		artistLbl.Text = t.artist or ""
	else
		titleLbl.Text = "Ничего не играет"
		artistLbl.Text = "Выбери трек из списка"
	end

	playBtn.Text = sound.IsPlaying and "II" or "▶"
	playBtn.TextSize = sound.IsPlaying and 18 or 20

	shuffleBtn.TextColor3 = shuffle and GREEN or SUB
	repeatBtn.TextColor3 = repeatMode > 0 and GREEN or SUB
	repeatBtn.Text = repeatMode == 2 and "↻¹" or "↻"

	for i, r in ipairs(rows) do
		local track = PLAYLIST[i]
		local active = i == index
		r.title.Text = track.title or "Загрузка…"
		r.artist.Text = track.artist or ""
		r.title.TextColor3 = active and GREEN or TEXT
		r.num.TextColor3 = active and GREEN or SUB
		r.num.Text = (active and sound.IsPlaying) and "♪" or tostring(i)
	end
end

local function refreshList()
	for _, r in ipairs(rows) do r.button:Destroy() end
	rows = {}
	for i, track in ipairs(PLAYLIST) do
		local btn = new("TextButton", {
			Text = "",
			Size = UDim2.new(1, -8, 0, 48),
			BackgroundColor3 = ELEV,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			LayoutOrder = i,
			Parent = listFrame,
		})
		corner(btn, 6)
		local num = label({
			Text = tostring(i),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = SUB,
			Position = UDim2.fromOffset(0, 0),
			Size = UDim2.fromOffset(36, 48),
			Parent = btn,
		})
		local title = label({
			Text = "",
			Font = FONT_B,
			TextSize = 14,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(44, 6),
			Size = UDim2.new(1, -52, 0, 20),
			Parent = btn,
		})
		local artist = label({
			Text = "",
			TextSize = 12,
			TextColor3 = SUB,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(44, 26),
			Size = UDim2.new(1, -52, 0, 16),
			Parent = btn,
		})

		btn.MouseEnter:Connect(function()
			TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundTransparency = 0 }):Play()
		end)
		btn.MouseLeave:Connect(function()
			TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundTransparency = 1 }):Play()
		end)
		btn.Activated:Connect(function()
			failCount = 0
			playTrack(i)
		end)

		rows[i] = { button = btn, num = num, title = title, artist = artist }
	end
	updateUI()
end

-- Подтягиваем название/автора из каталога
local function fetchInfo(track)
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(track.id, Enum.InfoType.Asset)
		end)
		if ok and info then
			track.title = track.title or info.Name
			track.artist = track.artist or (info.Creator and info.Creator.Name) or "Неизвестный исполнитель"
		else
			track.title = track.title or ("Трек " .. track.id)
			track.artist = track.artist or "—"
		end
		updateUI()
	end)
end

local function addTrackFromBox()
	local id = tonumber(addBox.Text:match("%d+"))
	addBox.Text = ""
	if not id then return end
	local track = { id = id }
	table.insert(PLAYLIST, track)
	refreshList()
	fetchInfo(track)
	task.defer(function()
		listFrame.CanvasPosition = Vector2.new(0, math.huge)
	end)
end

------------------------------------------------------------
-- СОБЫТИЯ
------------------------------------------------------------
playBtn.Activated:Connect(togglePlay)
nextBtn.Activated:Connect(function() failCount = 0; nextTrack(false) end)
prevBtn.Activated:Connect(function() failCount = 0; prevTrack() end)

shuffleBtn.Activated:Connect(function()
	shuffle = not shuffle
	updateUI()
end)
repeatBtn.Activated:Connect(function()
	repeatMode = (repeatMode + 1) % 3
	updateUI()
end)

addBtn.Activated:Connect(addTrackFromBox)
addBox.FocusLost:Connect(function(enterPressed)
	if enterPressed then addTrackFromBox() end
end)

sound:GetPropertyChangedSignal("IsPlaying"):Connect(updateUI)
sound.Ended:Connect(function()
	if repeatMode == 2 then
		sound.TimePosition = 0
		sound:Play()
	else
		nextTrack(true)
	end
end)

RunService.Heartbeat:Connect(function()
	local len = sound.TimeLength
	if len > 0 then
		if not progress.IsDragging() then
			progress.Set(sound.TimePosition / len)
			curTime.Text = formatTime(sound.TimePosition)
		end
		totTime.Text = formatTime(len)
	else
		progress.Set(0)
		curTime.Text = "0:00"
		totTime.Text = "0:00"
	end
end)

-- Показать / скрыть
local function toggleGui()
	main.Visible = not main.Visible
end
closeBtn.Activated:Connect(toggleGui)
toggleBtn.Activated:Connect(toggleGui)
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if not gameProcessed and input.KeyCode == Enum.KeyCode.M then
		toggleGui()
	end
end)

------------------------------------------------------------
-- СТАРТ
------------------------------------------------------------
refreshList()
for _, track in ipairs(PLAYLIST) do
	if not track.title or not track.artist then
		fetchInfo(track)
	end
end
