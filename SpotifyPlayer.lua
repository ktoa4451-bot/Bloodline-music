--[[
	SPOTIFY-ПЛЕЕР v2 — КЛИЕНТСКАЯ ЧАСТЬ
	Тип: LocalScript
	Куда: StarterPlayer > StarterPlayerScripts
	(вторым файлом нужен серверный Script в ServerScriptService: SpotifyPlayer_Server.lua)

	M — показать/скрыть плеер. Окно двигается за верхнюю полосу.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Remotes подключаются в фоне (если серверного скрипта нет — плеер работает без сохранения)
local remLoad, remSave, remPlayed, remTop

------------------------------------------------------------
-- ТЕМА И РАЗМЕРЫ
------------------------------------------------------------
local BG     = Color3.fromRGB(18, 18, 18)
local SIDE   = Color3.fromRGB(0, 0, 0)
local PANEL  = Color3.fromRGB(24, 24, 24)
local ELEV   = Color3.fromRGB(40, 40, 40)
local HOVER  = Color3.fromRGB(44, 44, 44)
local ELEV2  = Color3.fromRGB(83, 83, 83)
local GREEN  = Color3.fromRGB(30, 215, 96)
local RED    = Color3.fromRGB(240, 80, 80)
local TEXT   = Color3.fromRGB(255, 255, 255)
local SUB    = Color3.fromRGB(179, 179, 179)
local FONT   = Enum.Font.GothamMedium
local FONT_B = Enum.Font.GothamBold
local FONT_X = Enum.Font.GothamBlack

local W, H = 860, 560
local SIDE_W, BAR_H = 220, 96
local CONTENT_W = W - SIDE_W
local MAX_TRACKS, MAX_PLAYLISTS = 300, 20

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

local function corner(inst, r)
	return new("UICorner", { CornerRadius = UDim.new(0, r), Parent = inst })
end

local function label(props)
	props.BackgroundTransparency = 1
	props.Font = props.Font or FONT
	props.TextColor3 = props.TextColor3 or TEXT
	props.TextSize = props.TextSize or 14
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return new("TextLabel", props)
end

local function tween(inst, t, props, style, dir)
	local tw = TweenService:Create(
		inst,
		TweenInfo.new(t, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out),
		props
	)
	tw:Play()
	return tw
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

local function cutText(s, n)
	if not utf8.len(s) then return "" end
	local o = utf8.offset(s, n + 1)
	if o then return s:sub(1, o - 1) end
	return s
end

local function hueFor(seed)
	if type(seed) == "string" then
		local h = 0
		for i = 1, #seed do
			h = (h * 31 + seed:byte(i)) % 1000
		end
		seed = h
	end
	return (seed * 0.61803398875) % 1
end
local function accentH(h, v) return Color3.fromHSV(h, 0.6, v or 0.85) end
local function accent(seed, v) return accentH(hueFor(seed), v) end

local function pluralTracks(n)
	local a, b = n % 10, n % 100
	if a == 1 and b ~= 11 then return n .. " трек" end
	if a >= 2 and a <= 4 and (b < 12 or b > 14) then return n .. " трека" end
	return n .. " треков"
end

-- Пружинистая кнопка (нажатие/наведение)
local function bouncy(btn, hoverScale)
	local s = new("UIScale", { Parent = btn })
	btn.MouseEnter:Connect(function() tween(s, 0.12, { Scale = hoverScale or 1.06 }) end)
	btn.MouseButton1Down:Connect(function() tween(s, 0.08, { Scale = 0.9 }) end)
	local function up() tween(s, 0.3, { Scale = 1 }, Enum.EasingStyle.Back) end
	btn.MouseButton1Up:Connect(up)
	btn.MouseLeave:Connect(up)
	return s
end

local function pop(btn)
	local s = btn:FindFirstChildOfClass("UIScale")
	if s then
		s.Scale = 1.5
		tween(s, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
	end
end

------------------------------------------------------------
-- СОСТОЯНИЕ (сохраняется автоматически)
------------------------------------------------------------
local state = {
	playlists = {
		{
			name = "Мой плейлист",
			tracks = {
				-- ЗАМЕНИ на свои ID (аудио из Toolbox / Creator Hub)
				{ id = 1843463175, title = "Пример трека 1", artist = "Исполнитель" },
				{ id = 1837879082, title = "Пример трека 2", artist = "Исполнитель" },
				{ id = 9046863253 },
			},
		},
	},
	liked = {},
	volume = 0.5,
	bass = 0,
	reverb = false,
	last = 1,
}

local view = { kind = "pl", index = 1 } -- "pl" | "liked" | "top"
local topList, topState = {}, "idle"

local loaded = false
local saveToken = 0

-- forward declarations
local renderList, renderSidebar, renderBanner, updateNowPlaying, updatePlayState
local setView, playFromList, nextTrack, prevTrack, togglePlay, fetchTop
local openAddMenu, toggleLike, refreshTexts, closePopups, markDirty, notify, updateHearts

local function currentList()
	if view.kind == "liked" then
		return state.liked
	elseif view.kind == "top" then
		return topList
	end
	return state.playlists[view.index].tracks
end

local function isLiked(id)
	for _, t in ipairs(state.liked) do
		if t.id == id then return true end
	end
	return false
end

------------------------------------------------------------
-- ЗВУК: SoundGroup + эквалайзер (бас) + реверб
------------------------------------------------------------
local group = new("SoundGroup", { Name = "SpotifyBus", Volume = state.volume, Parent = SoundService })
local eq = new("EqualizerSoundEffect", { Parent = group })
local reverbFx = new("ReverbSoundEffect", {
	DecayTime = 2.8, Density = 0.9, Diffusion = 0.9,
	DryLevel = 0, WetLevel = -6, Enabled = false,
	Parent = group,
})

local function applyAudio()
	group.Volume = state.volume
	eq.LowGain = math.clamp(state.bass * 10, -80, 10)
	eq.MidGain = -state.bass * 3
	eq.HighGain = 0
	reverbFx.Enabled = state.reverb
end
applyAudio()

local speed = 1
local sound, current
local queue, qi = {}, 0
local shuffle, repeatMode = false, 0
local playToken, failStreak = 0, 0
local badIds = {}

------------------------------------------------------------
-- GUI: КОРНЕВОЕ ОКНО
------------------------------------------------------------
local gui = new("ScreenGui", {
	Name = "SpotifyPlayer",
	ResetOnSpawn = false,
	DisplayOrder = 10,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})

local root = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(W, H),
	BackgroundTransparency = 1,
	Parent = gui,
})
local uiScale = new("UIScale", { Parent = root })
local function rescale()
	local cam = workspace.CurrentCamera
	if not cam then return end
	local v = cam.ViewportSize
	uiScale.Scale = math.clamp(math.min(v.X / (W + 40), v.Y / (H + 40)), 0.45, 1)
end
rescale()
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
end

local main = new("CanvasGroup", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = BG,
	BorderSizePixel = 0,
	Parent = root,
})
corner(main, 14)

-- Уведомления (toast)
local toast = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, -70),
	Size = UDim2.fromOffset(320, 40),
	BackgroundColor3 = TEXT,
	ZIndex = 100,
	Parent = gui,
})
corner(toast, 20)
local toastLbl = label({
	Text = "", Font = FONT_B, TextSize = 14, TextColor3 = BG,
	TextXAlignment = Enum.TextXAlignment.Center,
	Size = UDim2.fromScale(1, 1), ZIndex = 101, Parent = toast,
})
local toastToken = 0
function notify(msg)
	toastToken += 1
	local my = toastToken
	toastLbl.Text = msg
	tween(toast, 0.35, { Position = UDim2.new(0.5, 0, 0, 20) }, Enum.EasingStyle.Back)
	task.delay(2.4, function()
		if my == toastToken then
			tween(toast, 0.25, { Position = UDim2.new(0.5, 0, 0, -70) })
		end
	end)
end

-- Показ/скрытие окна с анимацией
local isOpen = true
local function setOpen(v)
	isOpen = v
	if v then
		main.Visible = true
		main.Position = UDim2.fromOffset(0, 28)
		main.GroupTransparency = 1
		tween(main, 0.4, { Position = UDim2.fromOffset(0, 0), GroupTransparency = 0 }, Enum.EasingStyle.Quint)
	else
		local tw = tween(main, 0.2, { Position = UDim2.fromOffset(0, 18), GroupTransparency = 1 })
		tw.Completed:Connect(function()
			if not isOpen then main.Visible = false end
		end)
	end
end

------------------------------------------------------------
-- GUI: САЙДБАР
------------------------------------------------------------
local sidebar = new("Frame", {
	Size = UDim2.new(0, SIDE_W, 1, -BAR_H),
	BackgroundColor3 = SIDE,
	BorderSizePixel = 0,
	Parent = main,
})
label({
	Text = "♪", Font = FONT_X, TextSize = 26, TextColor3 = GREEN,
	Position = UDim2.fromOffset(20, 40), Size = UDim2.fromOffset(26, 30), Parent = sidebar,
})
label({
	Text = "Музыка", Font = FONT_X, TextSize = 22,
	Position = UDim2.fromOffset(50, 40), Size = UDim2.new(1, -60, 0, 30), Parent = sidebar,
})

local function sideButton(parent, y, icon, text)
	local props = {
		Text = "", Size = UDim2.new(1, -16, 0, 38),
		BackgroundColor3 = ELEV, BackgroundTransparency = 1,
		AutoButtonColor = false, Parent = parent,
	}
	if y then props.Position = UDim2.fromOffset(8, y) end
	local b = new("TextButton", props)
	corner(b, 8)
	local ic = label({
		Text = icon, Font = FONT_B, TextSize = 18, TextColor3 = SUB,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(6, 0), Size = UDim2.fromOffset(30, 38), Parent = b,
	})
	local tx = label({
		Text = text, Font = FONT_B, TextSize = 14, TextColor3 = SUB,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(42, 0), Size = UDim2.new(1, -50, 1, 0), Parent = b,
	})
	b.MouseEnter:Connect(function()
		if b.BackgroundTransparency > 0.9 then tween(b, 0.12, { BackgroundTransparency = 0.7 }) end
	end)
	b.MouseLeave:Connect(function()
		if b.BackgroundTransparency > 0.5 then tween(b, 0.12, { BackgroundTransparency = 1 }) end
	end)
	return b, ic, tx
end

local navLiked, navLikedIc, navLikedTx = sideButton(sidebar, 90, "♥", "Любимое")
local navTop, navTopIc, navTopTx = sideButton(sidebar, 134, "🔥", "Топ чарт")

label({
	Text = "ПЛЕЙЛИСТЫ", Font = FONT_B, TextSize = 12, TextColor3 = SUB,
	Position = UDim2.fromOffset(20, 190), Size = UDim2.fromOffset(120, 24), Parent = sidebar,
})
local plAddBtn = new("TextButton", {
	Text = "+", Font = FONT_B, TextSize = 22, TextColor3 = SUB, BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 188),
	Size = UDim2.fromOffset(28, 28), Parent = sidebar,
})
bouncy(plAddBtn, 1.15)
plAddBtn.MouseEnter:Connect(function() plAddBtn.TextColor3 = TEXT end)
plAddBtn.MouseLeave:Connect(function() plAddBtn.TextColor3 = SUB end)

local plNameBox = new("TextBox", {
	PlaceholderText = "Название и Enter", PlaceholderColor3 = SUB, Text = "",
	ClearTextOnFocus = false, Font = FONT, TextSize = 13, TextColor3 = TEXT,
	TextXAlignment = Enum.TextXAlignment.Left,
	BackgroundColor3 = ELEV, Visible = false,
	Position = UDim2.fromOffset(10, 218), Size = UDim2.new(1, -20, 0, 30), Parent = sidebar,
})
corner(plNameBox, 15)
new("UIPadding", { PaddingLeft = UDim.new(0, 12), Parent = plNameBox })

local plScroll = new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0,
	ScrollBarThickness = 3, ScrollBarImageColor3 = ELEV2,
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
	Parent = sidebar,
})
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = plScroll })

local function layoutSidebar()
	local y = plNameBox.Visible and 254 or 220
	plScroll.Position = UDim2.fromOffset(8, y)
	plScroll.Size = UDim2.new(1, -16, 1, -(y + 8))
end
layoutSidebar()

------------------------------------------------------------
-- GUI: ОСНОВНАЯ ОБЛАСТЬ (баннер, тулбар, список)
------------------------------------------------------------
local content = new("Frame", {
	Position = UDim2.fromOffset(SIDE_W, 0),
	Size = UDim2.new(0, CONTENT_W, 1, -BAR_H),
	BackgroundColor3 = BG, BorderSizePixel = 0, Parent = main,
})

local banner = new("Frame", {
	Size = UDim2.new(1, 0, 0, 130),
	BackgroundColor3 = Color3.fromRGB(60, 40, 120), BorderSizePixel = 0, Parent = content,
})
local bannerFade = new("Frame", {
	Size = UDim2.fromScale(1, 1), BackgroundColor3 = BG, BorderSizePixel = 0, Parent = banner,
})
new("UIGradient", {
	Rotation = 90,
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0),
	}),
	Parent = bannerFade,
})

local bannerCover = new("Frame", {
	Position = UDim2.fromOffset(28, 34), Size = UDim2.fromOffset(84, 84),
	BackgroundColor3 = TEXT, BorderSizePixel = 0, Parent = banner,
})
corner(bannerCover, 8)
local bannerCoverGrad = new("UIGradient", {
	Color = ColorSequence.new(GREEN, Color3.fromRGB(60, 40, 120)), Rotation = 45, Parent = bannerCover,
})
local bannerCoverScale = new("UIScale", { Parent = bannerCover })
local bannerIcon = label({
	Text = "♪", Font = FONT_X, TextSize = 40,
	TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = bannerCover,
})
local bannerKind = label({
	Text = "ПЛЕЙЛИСТ", Font = FONT_B, TextSize = 11,
	Position = UDim2.fromOffset(128, 40), Size = UDim2.fromOffset(320, 16), Parent = banner,
})
local bannerTitle = label({
	Text = "", Font = FONT_X, TextSize = 30, TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(128, 56), Size = UDim2.fromOffset(330, 40), Parent = banner,
})
local bannerSub = label({
	Text = "", TextSize = 13, TextColor3 = SUB,
	Position = UDim2.fromOffset(128, 98), Size = UDim2.fromOffset(330, 18), Parent = banner,
})

-- Визуализатор
local VIS_BARS = 16
local visBox = new("Frame", {
	Position = UDim2.fromOffset(CONTENT_W - 28 - VIS_BARS * 9, 40),
	Size = UDim2.fromOffset(VIS_BARS * 9, 74), BackgroundTransparency = 1, Parent = banner,
})
local bars = {}
for i = 1, VIS_BARS do
	local b = new("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, (i - 1) * 9, 1, 0),
		Size = UDim2.fromOffset(6, 4),
		BackgroundColor3 = GREEN, BackgroundTransparency = 0.15, BorderSizePixel = 0, Parent = visBox,
	})
	corner(b, 3)
	bars[i] = b
end

-- Тулбар
local toolbar = new("Frame", {
	Position = UDim2.fromOffset(0, 130), Size = UDim2.new(1, 0, 0, 52),
	BackgroundTransparency = 1, Parent = content,
})
local bigPlay = new("TextButton", {
	Text = "▶", Font = FONT_B, TextSize = 20, TextColor3 = BG, BackgroundColor3 = GREEN,
	Position = UDim2.fromOffset(28, 2), Size = UDim2.fromOffset(46, 46),
	AutoButtonColor = false, Parent = toolbar,
})
corner(bigPlay, 23)
bouncy(bigPlay, 1.08)

local topHint = label({
	Text = "Обновляется раз в минуту · по прослушиваниям игроков", TextSize = 12, TextColor3 = SUB,
	TextXAlignment = Enum.TextXAlignment.Right, Visible = false,
	Position = UDim2.new(1, -330, 0, 0), Size = UDim2.fromOffset(300, 50), Parent = toolbar,
})
local addRow = new("Frame", {
	Position = UDim2.new(1, -288, 0, 9), Size = UDim2.fromOffset(260, 32),
	BackgroundColor3 = ELEV, Parent = toolbar,
})
corner(addRow, 16)
local addBox = new("TextBox", {
	PlaceholderText = "Добавить трек по ID", PlaceholderColor3 = SUB, Text = "",
	ClearTextOnFocus = false, Font = FONT, TextSize = 13, TextColor3 = TEXT,
	TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1,
	Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -52, 1, 0), Parent = addRow,
})
local addBtn = new("TextButton", {
	Text = "+", Font = FONT_B, TextSize = 20, TextColor3 = BG, BackgroundColor3 = GREEN,
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0.5, 0),
	Size = UDim2.fromOffset(24, 24), AutoButtonColor = false, Parent = addRow,
})
corner(addBtn, 12)
bouncy(addBtn, 1.1)

-- Заголовок списка
label({
	Text = "#", Font = FONT_B, TextSize = 12, TextColor3 = SUB,
	TextXAlignment = Enum.TextXAlignment.Center,
	Position = UDim2.fromOffset(12, 182), Size = UDim2.fromOffset(40, 22), Parent = content,
})
label({
	Text = "НАЗВАНИЕ", Font = FONT_B, TextSize = 12, TextColor3 = SUB,
	Position = UDim2.fromOffset(102, 182), Size = UDim2.fromOffset(200, 22), Parent = content,
})
new("Frame", {
	Position = UDim2.fromOffset(12, 204), Size = UDim2.new(1, -24, 0, 1),
	BackgroundColor3 = ELEV, BorderSizePixel = 0, Parent = content,
})

local listWrap = new("CanvasGroup", {
	Position = UDim2.fromOffset(12, 208), Size = UDim2.new(1, -24, 1, -208),
	BackgroundTransparency = 1, Parent = content,
})
local scroll = new("ScrollingFrame", {
	Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
	ScrollBarThickness = 4, ScrollBarImageColor3 = ELEV2,
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = listWrap,
})
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = scroll })
new("UIPadding", { PaddingTop = UDim.new(0, 4), Parent = scroll })

local emptyLbl = label({
	Text = "", TextSize = 14, TextColor3 = SUB, TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Center, Visible = false,
	Position = UDim2.fromOffset(40, 50), Size = UDim2.new(1, -80, 0, 60), Parent = listWrap,
})

------------------------------------------------------------
-- GUI: НИЖНЯЯ ПАНЕЛЬ
------------------------------------------------------------
local bar = new("Frame", {
	Position = UDim2.new(0, 0, 1, -BAR_H), Size = UDim2.new(1, 0, 0, BAR_H),
	BackgroundColor3 = PANEL, BorderSizePixel = 0, Parent = main,
})
new("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = ELEV, BorderSizePixel = 0, Parent = bar })

local barCover = new("Frame", {
	Position = UDim2.fromOffset(16, 18), Size = UDim2.fromOffset(60, 60),
	BackgroundColor3 = TEXT, BorderSizePixel = 0, Parent = bar,
})
corner(barCover, 6)
local barCoverGrad = new("UIGradient", {
	Color = ColorSequence.new(Color3.fromRGB(70, 70, 70), Color3.fromRGB(40, 40, 40)),
	Rotation = 45, Parent = barCover,
})
local barCoverScale = new("UIScale", { Parent = barCover })
label({
	Text = "♪", Font = FONT_B, TextSize = 26,
	TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = barCover,
})
local barTitle = label({
	Text = "Ничего не играет", Font = FONT_B, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(88, 26), Size = UDim2.fromOffset(126, 20), Parent = bar,
})
local barArtist = label({
	Text = "Выбери трек", TextSize = 12, TextColor3 = SUB, TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(88, 47), Size = UDim2.fromOffset(126, 16), Parent = bar,
})
local barHeart = new("TextButton", {
	Text = "♥", Font = FONT_B, TextSize = 20, TextColor3 = ELEV2, BackgroundTransparency = 1,
	Position = UDim2.fromOffset(220, 31), Size = UDim2.fromOffset(30, 34), Parent = bar,
})
bouncy(barHeart, 1.15)

-- Центр: кнопки + прогресс
local center = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 10),
	Size = UDim2.fromOffset(330, 78), BackgroundTransparency = 1, Parent = bar,
})
local controls = new("Frame", {
	Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1, Parent = center,
})
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 14), SortOrder = Enum.SortOrder.LayoutOrder, Parent = controls,
})
local function ctrlButton(text, order, size)
	local b = new("TextButton", {
		Text = text, Font = FONT_B, TextSize = size or 20, TextColor3 = SUB,
		BackgroundTransparency = 1, Size = UDim2.fromOffset(34, 34),
		LayoutOrder = order, AutoButtonColor = false, Parent = controls,
	})
	bouncy(b, 1.12)
	return b
end
local shuffleBtn = ctrlButton("⇄", 1)
local prevBtn = ctrlButton("⏮", 2, 18)
local playBtn = new("TextButton", {
	Text = "▶", Font = FONT_B, TextSize = 18, TextColor3 = BG, BackgroundColor3 = TEXT,
	Size = UDim2.fromOffset(42, 42), LayoutOrder = 3, AutoButtonColor = false, Parent = controls,
})
corner(playBtn, 21)
bouncy(playBtn, 1.08)
local nextBtn = ctrlButton("⏭", 4, 18)
local repeatBtn = ctrlButton("↻", 5)
prevBtn.TextColor3 = TEXT
nextBtn.TextColor3 = TEXT

-- Слайдер
local function makeSlider(parent, position, size, initial, onChanged)
	local barF = new("Frame", {
		Position = position, Size = size, BackgroundColor3 = ELEV2, BorderSizePixel = 0, Parent = parent,
	})
	corner(barF, 3)
	local fill = new("Frame", {
		Size = UDim2.fromScale(initial, 1), BackgroundColor3 = TEXT, BorderSizePixel = 0, Parent = barF,
	})
	corner(fill, 3)
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(12, 12), BackgroundColor3 = TEXT, Visible = false, Parent = fill,
	})
	corner(knob, 6)
	local hit = new("TextButton", {
		Text = "", BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(1, 0, 0, 22), Parent = barF,
	})
	local dragging = false
	local function update(x)
		local a = math.clamp((x - barF.AbsolutePosition.X) / math.max(1, barF.AbsoluteSize.X), 0, 1)
		fill.Size = UDim2.fromScale(a, 1)
		onChanged(a)
	end
	hit.MouseEnter:Connect(function()
		fill.BackgroundColor3 = GREEN
		knob.Visible = true
	end)
	hit.MouseLeave:Connect(function()
		if not dragging then
			fill.BackgroundColor3 = TEXT
			knob.Visible = false
		end
	end)
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

local curTime = label({
	Text = "0:00", TextSize = 11, TextColor3 = SUB, TextXAlignment = Enum.TextXAlignment.Right,
	Position = UDim2.fromOffset(0, 48), Size = UDim2.fromOffset(36, 16), Parent = center,
})
local totTime = label({
	Text = "0:00", TextSize = 11, TextColor3 = SUB,
	Position = UDim2.fromOffset(294, 48), Size = UDim2.fromOffset(36, 16), Parent = center,
})
local progress = makeSlider(center, UDim2.fromOffset(42, 55), UDim2.fromOffset(246, 4), 0, function(a)
	if sound and sound.TimeLength > 0 then
		sound.TimePosition = a * sound.TimeLength
		curTime.Text = formatTime(sound.TimePosition)
	end
end)

-- Справа: громкость и кнопка звука
local right = new("Frame", {
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16, 0.5, 0),
	Size = UDim2.fromOffset(222, 40), BackgroundTransparency = 1, Parent = bar,
})
label({
	Text = "🔊", TextSize = 15, TextXAlignment = Enum.TextXAlignment.Center,
	Position = UDim2.fromOffset(0, 0), Size = UDim2.fromOffset(22, 40), Parent = right,
})
local volume = makeSlider(right, UDim2.fromOffset(28, 18), UDim2.fromOffset(100, 4), state.volume, function(a)
	state.volume = a
	applyAudio()
	markDirty()
end)
local eqBtn = new("TextButton", {
	Text = "Звук ⚙", Font = FONT_B, TextSize = 13, TextColor3 = TEXT, BackgroundColor3 = ELEV,
	Position = UDim2.fromOffset(142, 5), Size = UDim2.fromOffset(80, 30),
	AutoButtonColor = false, Parent = right,
})
corner(eqBtn, 15)
bouncy(eqBtn, 1.06)

------------------------------------------------------------
-- GUI: ПОПАПЫ (звук, добавить в плейлист)
------------------------------------------------------------
local blocker = new("TextButton", {
	Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
	Visible = false, ZIndex = 40, Parent = main,
})

local function showPopup(p)
	p.Visible = true
	p.GroupTransparency = 1
	tween(p, 0.2, { GroupTransparency = 0 })
end
local function hidePopup(p)
	if not p.Visible then return end
	local tw = tween(p, 0.15, { GroupTransparency = 1 })
	tw.Completed:Connect(function()
		if p.GroupTransparency >= 1 then p.Visible = false end
	end)
end

-- Меню "Добавить в плейлист"
local addMenu = new("CanvasGroup", {
	Size = UDim2.fromOffset(220, 200), BackgroundColor3 = ELEV,
	Visible = false, ZIndex = 50, Parent = main,
})
corner(addMenu, 10)
label({
	Text = "Добавить в плейлист", Font = FONT_B, TextSize = 13, TextColor3 = SUB,
	Position = UDim2.fromOffset(14, 8), Size = UDim2.new(1, -28, 0, 22), Parent = addMenu,
})
local addMenuList = new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
	Position = UDim2.fromOffset(6, 34), Size = UDim2.new(1, -12, 1, -40),
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = addMenu,
})
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = addMenuList })

-- Попап звука
local eqPopup = new("CanvasGroup", {
	AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -BAR_H - 8),
	Size = UDim2.fromOffset(290, 316), BackgroundColor3 = ELEV,
	Visible = false, ZIndex = 50, Parent = main,
})
corner(eqPopup, 12)
label({
	Text = "Звук и эффекты", Font = FONT_B, TextSize = 16,
	Position = UDim2.fromOffset(20, 14), Size = UDim2.new(1, -40, 0, 22), Parent = eqPopup,
})
label({
	Text = "Усиление баса", TextSize = 13, TextColor3 = SUB,
	Position = UDim2.fromOffset(20, 50), Size = UDim2.fromOffset(150, 18), Parent = eqPopup,
})
local bassVal = label({
	Text = "0%", Font = FONT_B, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right,
	Position = UDim2.fromOffset(190, 50), Size = UDim2.fromOffset(80, 18), Parent = eqPopup,
})

local function chip(parent, text, x, y, w)
	local b = new("TextButton", {
		Text = text, Font = FONT_B, TextSize = 12, TextColor3 = TEXT,
		BackgroundColor3 = Color3.fromRGB(62, 62, 62),
		Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, 30),
		AutoButtonColor = false, Parent = parent,
	})
	corner(b, 15)
	bouncy(b, 1.05)
	return b
end
local function chipActive(b, on)
	tween(b, 0.15, { BackgroundColor3 = on and GREEN or Color3.fromRGB(62, 62, 62) })
	b.TextColor3 = on and BG or TEXT
end

label({
	Text = "Скорость", TextSize = 13, TextColor3 = SUB,
	Position = UDim2.fromOffset(20, 106), Size = UDim2.fromOffset(150, 18), Parent = eqPopup,
})
local speedChips = {}
for i, s in ipairs({ { 0.8, "0.8×" }, { 1, "1×" }, { 1.25, "1.25×" } }) do
	local c = chip(eqPopup, s[2], 20 + (i - 1) * 86, 130, 78)
	speedChips[i] = { btn = c, value = s[1] }
end

label({
	Text = "Реверберация", TextSize = 13, TextColor3 = SUB,
	Position = UDim2.fromOffset(20, 180), Size = UDim2.fromOffset(150, 24), Parent = eqPopup,
})
local sw = new("TextButton", {
	Text = "", BackgroundColor3 = Color3.fromRGB(62, 62, 62),
	Position = UDim2.fromOffset(226, 181), Size = UDim2.fromOffset(44, 22),
	AutoButtonColor = false, Parent = eqPopup,
})
corner(sw, 11)
local swKnob = new("Frame", {
	AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0),
	Size = UDim2.fromOffset(16, 16), BackgroundColor3 = TEXT, BorderSizePixel = 0, Parent = sw,
})
corner(swKnob, 8)

label({
	Text = "Пресеты", TextSize = 13, TextColor3 = SUB,
	Position = UDim2.fromOffset(20, 220), Size = UDim2.fromOffset(150, 18), Parent = eqPopup,
})

local function refreshSpeedChips()
	for _, c in ipairs(speedChips) do chipActive(c.btn, c.value == speed) end
end

local function setSpeed(v)
	speed = v
	if sound then sound.PlaybackSpeed = v end
	refreshSpeedChips()
end

local bassSlider
local function setBass(a, fromSlider)
	state.bass = a
	applyAudio()
	bassVal.Text = math.floor(a * 100 + 0.5) .. "%"
	if not fromSlider and bassSlider then bassSlider.Set(a) end
	markDirty()
end
bassSlider = makeSlider(eqPopup, UDim2.fromOffset(20, 78), UDim2.fromOffset(250, 6), state.bass, function(a)
	setBass(a, true)
end)

local function setReverb(v, instant)
	state.reverb = v
	applyAudio()
	local t = instant and 0 or 0.2
	tween(sw, t, { BackgroundColor3 = v and GREEN or Color3.fromRGB(62, 62, 62) })
	tween(swKnob, t, { Position = v and UDim2.new(1, -19, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) }, Enum.EasingStyle.Back)
	markDirty()
end

for i, c in ipairs(speedChips) do
	c.btn.Activated:Connect(function() setSpeed(c.value) end)
end
sw.Activated:Connect(function() setReverb(not state.reverb) end)

local PRESETS = {
	{ "Обычный", 0, 1, false },
	{ "Бас", 0.6, 1, false },
	{ "Супер бас", 1, 1, false },
	{ "Slowed", 0.3, 0.85, true },
	{ "Nightcore", 0.2, 1.25, false },
}
for i, p in ipairs(PRESETS) do
	local col = (i - 1) % 3
	local rowI = math.floor((i - 1) / 3)
	local c = chip(eqPopup, p[1], 20 + col * 86, 244 + rowI * 36, 78)
	c.Activated:Connect(function()
		setBass(p[2])
		setSpeed(p[3])
		setReverb(p[4])
		notify("Пресет: " .. p[1])
	end)
end

function closePopups()
	hidePopup(eqPopup)
	hidePopup(addMenu)
	blocker.Visible = false
end
blocker.Activated:Connect(closePopups)

eqBtn.Activated:Connect(function()
	if eqPopup.Visible and eqPopup.GroupTransparency < 0.5 then
		closePopups()
	else
		closePopups()
		showPopup(eqPopup)
		blocker.Visible = true
	end
end)

------------------------------------------------------------
-- Верхняя полоса: перетаскивание и закрытие
------------------------------------------------------------
local dragHandle = new("Frame", {
	Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, ZIndex = 5, Parent = main,
})
do
	local dragging, dragStart, startPos
	dragHandle.InputBegan:Connect(function(input)
		if isPointer(input) then
			dragging = true
			dragStart = input.Position
			startPos = root.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and isMove(input) then
			local d = (input.Position - dragStart) / uiScale.Scale
			root.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y
			)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if isPointer(input) then dragging = false end
	end)
end

local closeBtn = new("TextButton", {
	Text = "✕", Font = FONT_B, TextSize = 15, TextColor3 = SUB, BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0, 18),
	Size = UDim2.fromOffset(28, 28), ZIndex = 6, Parent = main,
})
bouncy(closeBtn, 1.15)
closeBtn.MouseEnter:Connect(function() closeBtn.TextColor3 = TEXT end)
closeBtn.MouseLeave:Connect(function() closeBtn.TextColor3 = SUB end)

local toggleBtn = new("TextButton", {
	Text = "♪", Font = FONT_X, TextSize = 24, TextColor3 = BG, BackgroundColor3 = GREEN,
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -16),
	Size = UDim2.fromOffset(46, 46), AutoButtonColor = false, Parent = gui,
})
corner(toggleBtn, 23)
bouncy(toggleBtn, 1.1)

------------------------------------------------------------
-- СОХРАНЕНИЕ
------------------------------------------------------------
local function pushSave()
	if not (loaded and remSave) then return end
	remSave:FireServer({
		playlists = state.playlists,
		liked = state.liked,
		volume = state.volume,
		bass = state.bass,
		reverb = state.reverb,
		last = state.last,
	})
end

function markDirty()
	if not (loaded and remSave) then return end
	saveToken += 1
	local my = saveToken
	task.delay(2, function()
		if my == saveToken then pushSave() end
	end)
end

------------------------------------------------------------
-- МЕТАДАННЫЕ ТРЕКОВ (название / автор)
------------------------------------------------------------
local metaCache = {}
local function fetchInfo(track)
	local c = metaCache[track.id]
	if c then
		track.title = track.title or c.title
		track.artist = track.artist or c.artist
		return
	end
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(track.id, Enum.InfoType.Asset)
	end)
	if ok and info then
		metaCache[track.id] = {
			title = cutText(tostring(info.Name), 60),
			artist = cutText(info.Creator and tostring(info.Creator.Name) or "—", 40),
		}
		track.title = track.title or metaCache[track.id].title
		track.artist = track.artist or metaCache[track.id].artist
	else
		track.title = track.title or ("Трек " .. track.id)
		track.artist = track.artist or "—"
	end
end

local function hydrateTitles()
	task.spawn(function()
		local changed = false
		local function pass(list)
			for _, t in ipairs(list) do
				if not t.title or not t.artist then
					fetchInfo(t)
					changed = true
					refreshTexts()
					task.wait(0.15)
				end
			end
		end
		for _, p in ipairs(state.playlists) do pass(p.tracks) end
		pass(state.liked)
		if changed then markDirty() end
	end)
end

------------------------------------------------------------
-- ВОСПРОИЗВЕДЕНИЕ
------------------------------------------------------------
local function playAt(i)
	local track = queue[i]
	if not track then return end
	qi = i
	current = track
	playToken += 1
	local my = playToken

	-- Каждый трек = новый Sound. Так старый звук не может "вклиниться" и перелистнуть песню.
	if sound then sound:Destroy() end
	local s = Instance.new("Sound")
	s.Name = "Track"
	s.SoundId = "rbxassetid://" .. track.id
	s.SoundGroup = group
	s.PlaybackSpeed = speed
	s.Looped = (repeatMode == 2)
	s.Volume = 1
	s.Parent = SoundService
	sound = s

	s.Ended:Connect(function()
		if s == sound and my == playToken then nextTrack(true) end
	end)
	s:GetPropertyChangedSignal("IsPlaying"):Connect(function()
		if s == sound then updatePlayState() end
	end)
	s:Play()
	updateNowPlaying()

	task.spawn(function()
		local t0 = os.clock()
		while my == playToken and not s.IsLoaded and os.clock() - t0 < 8 do
			task.wait(0.1)
		end
		if my ~= playToken then return end
		if s.IsLoaded and s.TimeLength > 0 then
			failStreak = 0
			if remPlayed then remPlayed:FireServer(track.id) end
		else
			badIds[track.id] = true
			failStreak += 1
			notify("Трек недоступен (нет прав на это аудио)")
			updateNowPlaying()
			if failStreak < #queue then
				task.wait(0.8)
				if my == playToken then nextTrack(true) end
			end
		end
	end)
end

function playFromList(list, i)
	queue = {}
	for k, t in ipairs(list) do queue[k] = t end
	failStreak = 0
	playAt(i)
end

function nextTrack(auto)
	local n = #queue
	if n == 0 then return end
	local target
	if shuffle and n > 1 then
		for _ = 1, 12 do
			local c = math.random(n)
			if c ~= qi and not badIds[queue[c].id] then
				target = c
				break
			end
		end
	else
		local c = qi
		for _ = 1, n do
			c += 1
			if c > n then
				if repeatMode == 1 or not auto then
					c = 1
				else
					updatePlayState()
					return
				end
			end
			if not badIds[queue[c].id] then
				target = c
				break
			end
		end
	end
	if target then playAt(target) end
end

function prevTrack()
	if #queue == 0 then return end
	if sound and sound.TimePosition > 3 then
		sound.TimePosition = 0
		return
	end
	local c = qi - 1
	if c < 1 then c = #queue end
	playAt(c)
end

function togglePlay()
	if not sound then
		local list = currentList()
		if #list > 0 then
			playFromList(list, shuffle and math.random(#list) or 1)
		end
	elseif sound.IsPlaying then
		sound:Pause()
	else
		sound:Play()
	end
end

------------------------------------------------------------
-- ОБНОВЛЕНИЕ ИНТЕРФЕЙСА
------------------------------------------------------------
local rows = {}

local function refreshRowStates()
	for i, r in ipairs(rows) do
		local active = current ~= nil and r.track.id == current.id
		local bad = badIds[r.track.id]
		r.title.TextColor3 = bad and RED or (active and GREEN or TEXT)
		r.num.TextColor3 = active and GREEN or SUB
		r.num.Text = (active and sound and sound.IsPlaying) and "♪" or tostring(i)
	end
end

function updateHearts()
	for _, r in ipairs(rows) do
		r.heart.TextColor3 = isLiked(r.track.id) and GREEN or ELEV2
	end
	barHeart.TextColor3 = (current and isLiked(current.id)) and GREEN or ELEV2
end

function updatePlayState()
	local playing = sound ~= nil and sound.IsPlaying
	playBtn.Text = playing and "II" or "▶"
	bigPlay.Text = playing and "II" or "▶"
	refreshRowStates()
end

function updateNowPlaying()
	local t = current
	if t then
		barTitle.Text = t.title or "Загрузка…"
		barArtist.Text = t.artist or ""
		barCoverGrad.Color = ColorSequence.new(accent(t.id, 0.95), accent(t.id, 0.45))
	else
		barTitle.Text = "Ничего не играет"
		barArtist.Text = "Выбери трек"
		barCoverGrad.Color = ColorSequence.new(Color3.fromRGB(70, 70, 70), Color3.fromRGB(40, 40, 40))
	end
	updateHearts()
	updatePlayState()
end

function refreshTexts()
	for _, r in ipairs(rows) do
		r.title.Text = r.track.title or "Загрузка…"
		r.artist.Text = r.track.artist or ""
	end
	if current then
		barTitle.Text = current.title or "Загрузка…"
		barArtist.Text = current.artist or ""
	end
end

function renderBanner()
	local title, kind, icon, h
	if view.kind == "liked" then
		title, kind, icon, h = "Любимое", "ПЛЕЙЛИСТ", "♥", 0.72
	elseif view.kind == "top" then
		title, kind, icon, h = "Топ чарт", "ПОПУЛЯРНОЕ СРЕДИ ИГРОКОВ", "🔥", 0.02
	else
		local p = state.playlists[view.index]
		title, kind, icon, h = p.name, "ПЛЕЙЛИСТ", "♪", hueFor(p.name)
	end
	bannerTitle.Text = title
	bannerKind.Text = kind
	bannerIcon.Text = icon
	bannerSub.Text = (view.kind == "top" and topState == "loading") and "Загрузка…" or pluralTracks(#currentList())
	tween(banner, 0.5, { BackgroundColor3 = accentH(h, 0.6) })
	bannerCoverGrad.Color = ColorSequence.new(accentH(h, 0.95), accentH(h, 0.45))
	addRow.Visible = view.kind ~= "top"
	topHint.Visible = view.kind == "top"
end

local function addToPlaylist(i, track)
	local p = state.playlists[i]
	if not p then return end
	for _, t in ipairs(p.tracks) do
		if t.id == track.id then
			notify("Уже есть в «" .. p.name .. "»")
			return
		end
	end
	if #p.tracks >= MAX_TRACKS then
		notify("Плейлист заполнен")
		return
	end
	table.insert(p.tracks, { id = track.id, title = track.title, artist = track.artist })
	notify("Добавлено в «" .. p.name .. "»")
	markDirty()
	if view.kind == "pl" and view.index == i then
		renderList()
		renderBanner()
	end
end

function openAddMenu(track, anchor)
	closePopups()
	for _, c in ipairs(addMenuList:GetChildren()) do
		if c:IsA("TextButton") then c:Destroy() end
	end
	for i, p in ipairs(state.playlists) do
		local b = new("TextButton", {
			Text = "  " .. p.name, Font = FONT, TextSize = 14, TextColor3 = TEXT,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
			BackgroundColor3 = Color3.fromRGB(62, 62, 62), BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 34), AutoButtonColor = false, LayoutOrder = i, Parent = addMenuList,
		})
		corner(b, 6)
		b.MouseEnter:Connect(function() tween(b, 0.1, { BackgroundTransparency = 0 }) end)
		b.MouseLeave:Connect(function() tween(b, 0.1, { BackgroundTransparency = 1 }) end)
		b.Activated:Connect(function()
			addToPlaylist(i, track)
			closePopups()
		end)
	end
	local h = math.min(260, 44 + #state.playlists * 34)
	addMenu.Size = UDim2.fromOffset(220, h)
	local rel = (anchor.AbsolutePosition - main.AbsolutePosition) / uiScale.Scale
	local x = math.clamp(rel.X - 180, 8, W - 228)
	local y = math.clamp(rel.Y + 28, 40, H - BAR_H - h - 4)
	addMenu.Position = UDim2.fromOffset(x, y)
	blocker.Visible = true
	showPopup(addMenu)
end

function toggleLike(track)
	for i, t in ipairs(state.liked) do
		if t.id == track.id then
			table.remove(state.liked, i)
			updateHearts()
			if view.kind == "liked" then
				renderList()
				renderBanner()
			end
			markDirty()
			notify("Убрано из любимого")
			return
		end
	end
	if #state.liked >= MAX_TRACKS then
		notify("В любимом слишком много треков")
		return
	end
	table.insert(state.liked, { id = track.id, title = track.title, artist = track.artist })
	updateHearts()
	if view.kind == "liked" then
		renderList()
		renderBanner()
	end
	markDirty()
	notify("Добавлено в любимое ♥")
end

local function removeFromView(i)
	if view.kind == "pl" then
		table.remove(state.playlists[view.index].tracks, i)
	elseif view.kind == "liked" then
		table.remove(state.liked, i)
	else
		return
	end
	markDirty()
	renderList()
	renderBanner()
end

function renderList()
	for _, r in ipairs(rows) do r.button:Destroy() end
	rows = {}
	local list = currentList()

	emptyLbl.Visible = false
	if view.kind == "top" and topState == "loading" then
		emptyLbl.Text = "Загрузка чарта…"
		emptyLbl.Visible = true
	elseif #list == 0 then
		if view.kind == "top" then
			emptyLbl.Text = "Чарт пока пуст. Слушай музыку — треки появятся здесь."
		else
			emptyLbl.Text = "Здесь пока пусто. Добавь трек по ID или через «+» у любого трека."
		end
		emptyLbl.Visible = true
	end

	for i, track in ipairs(list) do
		local btn = new("TextButton", {
			Text = "", Size = UDim2.new(1, -8, 0, 52),
			BackgroundColor3 = HOVER, BackgroundTransparency = 1,
			AutoButtonColor = false, LayoutOrder = i, Parent = scroll,
		})
		corner(btn, 8)
		local num = label({
			Text = tostring(i), TextColor3 = SUB, TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.fromOffset(40, 52), Parent = btn,
		})
		local mini = new("Frame", {
			Position = UDim2.fromOffset(46, 9), Size = UDim2.fromOffset(34, 34),
			BackgroundColor3 = TEXT, BorderSizePixel = 0, Parent = btn,
		})
		corner(mini, 5)
		new("UIGradient", {
			Color = ColorSequence.new(accent(track.id, 0.95), accent(track.id, 0.45)),
			Rotation = 45, Parent = mini,
		})
		label({
			Text = "♪", Font = FONT_B, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.fromScale(1, 1), Parent = mini,
		})
		local title = label({
			Text = track.title or "Загрузка…", Font = FONT_B, TextSize = 14,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(90, 8), Size = UDim2.new(1, -230, 0, 20), Parent = btn,
		})
		local artist = label({
			Text = track.artist or "", TextSize = 12, TextColor3 = SUB,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(90, 28), Size = UDim2.new(1, -230, 0, 16), Parent = btn,
		})

		local function iconBtn(text, x, color)
			local b = new("TextButton", {
				Text = text, Font = FONT_B, TextSize = 18, TextColor3 = color or ELEV2,
				BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, x, 0.5, 0), Size = UDim2.fromOffset(30, 30), Parent = btn,
			})
			bouncy(b, 1.15)
			return b
		end
		local heart = iconBtn("♥", -86)
		local addB = iconBtn("+", -50, SUB)
		heart.Activated:Connect(function()
			toggleLike(track)
			pop(heart)
		end)
		addB.Activated:Connect(function() openAddMenu(track, addB) end)

		if view.kind == "top" then
			label({
				Text = tostring(track.plays or 0) .. " ▶", Font = FONT_B, TextSize = 12, TextColor3 = SUB,
				TextXAlignment = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0),
				Size = UDim2.fromOffset(40, 20), Parent = btn,
			})
		else
			local rm = iconBtn("✕", -14, SUB)
			rm.Activated:Connect(function() removeFromView(i) end)
		end

		btn.MouseEnter:Connect(function() tween(btn, 0.12, { BackgroundTransparency = 0 }) end)
		btn.MouseLeave:Connect(function() tween(btn, 0.12, { BackgroundTransparency = 1 }) end)
		btn.Activated:Connect(function() playFromList(list, i) end)

		rows[i] = { button = btn, track = track, num = num, title = title, artist = artist, heart = heart }
	end
	updateHearts()
	refreshRowStates()
end

local armedDelete
function renderSidebar()
	local function setNav(btn, ic, tx, active)
		btn.BackgroundTransparency = active and 0 or 1
		tx.TextColor3 = active and TEXT or SUB
		ic.TextColor3 = active and GREEN or SUB
	end
	setNav(navLiked, navLikedIc, navLikedTx, view.kind == "liked")
	setNav(navTop, navTopIc, navTopTx, view.kind == "top")

	for _, c in ipairs(plScroll:GetChildren()) do
		if c:IsA("GuiButton") then c:Destroy() end
	end
	for i, p in ipairs(state.playlists) do
		local active = view.kind == "pl" and view.index == i
		local b, ic, tx = sideButton(plScroll, nil, "♪", p.name)
		b.LayoutOrder = i
		b.Size = UDim2.new(1, -6, 0, 38)
		setNav(b, ic, tx, active)
		b.Activated:Connect(function()
			state.last = i
			markDirty()
			setView({ kind = "pl", index = i })
		end)
		if #state.playlists > 1 then
			tx.Size = UDim2.new(1, -86, 1, 0)
			local del = new("TextButton", {
				Text = armedDelete == i and "Точно?" or "✕", Font = FONT_B, TextSize = 12,
				TextColor3 = armedDelete == i and RED or SUB, BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0),
				Size = UDim2.fromOffset(46, 26), Parent = b,
			})
			del.Activated:Connect(function()
				if armedDelete == i then
					armedDelete = nil
					table.remove(state.playlists, i)
					if view.kind == "pl" then
						if view.index == i then
							view.index = 1
						elseif view.index > i then
							view.index -= 1
						end
						state.last = view.index
					end
					markDirty()
					notify("Плейлист удалён")
					setView(view)
				else
					armedDelete = i
					renderSidebar()
					task.delay(2.5, function()
						if armedDelete == i then
							armedDelete = nil
							renderSidebar()
						end
					end)
				end
			end)
		end
	end
end

function setView(v)
	view = v
	closePopups()
	renderSidebar()
	renderBanner()
	renderList()
	listWrap.GroupTransparency = 1
	listWrap.Position = UDim2.fromOffset(12, 218)
	tween(listWrap, 0.3, { GroupTransparency = 0, Position = UDim2.fromOffset(12, 208) }, Enum.EasingStyle.Quint)
	if v.kind == "top" then fetchTop() end
end

function fetchTop()
	if not remTop then
		topState = "done"
		renderList()
		renderBanner()
		return
	end
	topState = "loading"
	renderList()
	renderBanner()
	task.spawn(function()
		local ok, res = pcall(function() return remTop:InvokeServer() end)
		local out = {}
		if ok and type(res) == "table" then
			for _, t in ipairs(res) do
				if type(t) == "table" and tonumber(t.id) then
					out[#out + 1] = { id = t.id, title = t.title, artist = t.artist, plays = t.plays }
				end
			end
		end
		topList = out
		topState = "done"
		if view.kind == "top" then
			renderList()
			renderBanner()
		end
	end)
end

------------------------------------------------------------
-- СОБЫТИЯ UI
------------------------------------------------------------
navLiked.Activated:Connect(function() setView({ kind = "liked" }) end)
navTop.Activated:Connect(function() setView({ kind = "top" }) end)

plAddBtn.Activated:Connect(function()
	plNameBox.Visible = not plNameBox.Visible
	layoutSidebar()
	if plNameBox.Visible then plNameBox:CaptureFocus() end
end)
plNameBox.FocusLost:Connect(function(enter)
	local name = plNameBox.Text:match("^%s*(.-)%s*$")
	if enter and name ~= "" then
		if #state.playlists >= MAX_PLAYLISTS then
			notify("Максимум плейлистов: " .. MAX_PLAYLISTS)
		else
			table.insert(state.playlists, { name = cutText(name, 24), tracks = {} })
			state.last = #state.playlists
			markDirty()
			setView({ kind = "pl", index = #state.playlists })
			notify("Плейлист создан")
		end
	end
	plNameBox.Text = ""
	plNameBox.Visible = false
	layoutSidebar()
end)

local function addTrackFromBox()
	local id = tonumber(addBox.Text:match("%d+") or "")
	addBox.Text = ""
	if not id or id < 1 or id >= 1e15 then
		notify("Введи числовой ID аудио")
		return
	end
	local list = currentList()
	for _, t in ipairs(list) do
		if t.id == id then
			notify("Этот трек уже здесь")
			return
		end
	end
	if #list >= MAX_TRACKS then
		notify("Список заполнен")
		return
	end
	local track = { id = id }
	table.insert(list, track)
	renderList()
	renderBanner()
	markDirty()
	task.spawn(function()
		fetchInfo(track)
		refreshTexts()
		markDirty()
	end)
	task.defer(function()
		scroll.CanvasPosition = Vector2.new(0, math.huge)
	end)
end
addBtn.Activated:Connect(addTrackFromBox)
addBox.FocusLost:Connect(function(enter)
	if enter then addTrackFromBox() end
end)

playBtn.Activated:Connect(togglePlay)
bigPlay.Activated:Connect(function()
	-- большая кнопка: если играет этот же список — пауза, иначе запуск списка
	local list = currentList()
	if sound and current and #list > 0 then
		for _, t in ipairs(list) do
			if t.id == current.id then
				togglePlay()
				return
			end
		end
	end
	if #list > 0 then
		playFromList(list, shuffle and math.random(#list) or 1)
	end
end)
nextBtn.Activated:Connect(function() failStreak = 0; nextTrack(false) end)
prevBtn.Activated:Connect(function() failStreak = 0; prevTrack() end)

shuffleBtn.Activated:Connect(function()
	shuffle = not shuffle
	shuffleBtn.TextColor3 = shuffle and GREEN or SUB
end)
repeatBtn.Activated:Connect(function()
	repeatMode = (repeatMode + 1) % 3
	repeatBtn.Text = repeatMode == 2 and "↻¹" or "↻"
	repeatBtn.TextColor3 = repeatMode > 0 and GREEN or SUB
	if sound then sound.Looped = (repeatMode == 2) end
end)

barHeart.Activated:Connect(function()
	if current then
		toggleLike(current)
		pop(barHeart)
	end
end)

closeBtn.Activated:Connect(function() setOpen(false) end)
toggleBtn.Activated:Connect(function() setOpen(not isOpen) end)
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.M then
		setOpen(not isOpen)
	end
end)

------------------------------------------------------------
-- АНИМАЦИЯ КАЖДЫЙ КАДР: прогресс, визуализатор, пульс обложки
------------------------------------------------------------
local smooth = 0
RunService.RenderStepped:Connect(function(dt)
	if not main.Visible then return end

	local playing = sound ~= nil and sound.IsPlaying
	local loud = playing and math.clamp(sound.PlaybackLoudness / 350, 0, 1) or 0
	smooth += (loud - smooth) * math.min(1, dt * 12)

	local t = os.clock()
	for i, b in ipairs(bars) do
		local wob = 0.55 + 0.45 * math.sin(t * (3 + i * 0.37) + i)
		local targetH = 4 + smooth * 70 * wob
		local cur = b.Size.Y.Offset
		b.Size = UDim2.fromOffset(6, cur + (targetH - cur) * math.min(1, dt * 18))
	end

	bannerCoverScale.Scale = 1 + smooth * 0.05
	barCoverScale.Scale = 1 + smooth * 0.09
	if playing then
		barCoverGrad.Rotation = (barCoverGrad.Rotation + dt * 40) % 360
		bannerCoverGrad.Rotation = (bannerCoverGrad.Rotation + dt * 25) % 360
	end

	if sound and sound.TimeLength > 0 then
		if not progress.IsDragging() then
			progress.Set(sound.TimePosition / sound.TimeLength)
			curTime.Text = formatTime(sound.TimePosition)
		end
		totTime.Text = formatTime(sound.TimeLength)
	else
		progress.Set(0)
		curTime.Text = "0:00"
		totTime.Text = "0:00"
	end
end)

------------------------------------------------------------
-- ЗАГРУЗКА СОХРАНЕНИЯ
------------------------------------------------------------
local function applyData(d)
	if type(d.playlists) == "table" and #d.playlists > 0 then state.playlists = d.playlists end
	if type(d.liked) == "table" then state.liked = d.liked end
	state.volume = tonumber(d.volume) or state.volume
	state.bass = tonumber(d.bass) or state.bass
	state.reverb = d.reverb == true
	state.last = tonumber(d.last) or 1
	if not state.playlists[state.last] then state.last = 1 end
	view = { kind = "pl", index = state.last }

	volume.Set(state.volume)
	bassSlider.Set(state.bass)
	bassVal.Text = math.floor(state.bass * 100 + 0.5) .. "%"
	setReverb(state.reverb, true)
	applyAudio()
end

task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("SpotifyPlayerRemotes", 10)
	if not remotes then
		notify("Сохранение выключено: нет серверного Script")
		return
	end
	remLoad = remotes:WaitForChild("Load")
	remSave = remotes:WaitForChild("Save")
	remPlayed = remotes:WaitForChild("Played")
	remTop = remotes:WaitForChild("GetTop")

	local ok, res = pcall(function() return remLoad:InvokeServer() end)
	if ok and type(res) == "table" and res.ok then
		if res.data then applyData(res.data) end
		loaded = true
		renderSidebar()
		renderBanner()
		renderList()
		hydrateTitles()
		if res.data then
			notify("Плейлисты загружены")
		else
			markDirty() -- первый вход: сразу сохраним стартовый плейлист
		end
	else
		notify("Не удалось загрузить сохранение")
	end
end)

------------------------------------------------------------
-- СТАРТ
------------------------------------------------------------
setReverb(state.reverb, true)
bassVal.Text = math.floor(state.bass * 100 + 0.5) .. "%"
refreshSpeedChips()
renderSidebar()
renderBanner()
renderList()
setOpen(true)
hydrateTitles()
