--[[
    ╔══════════════════════════════════════════╗
    ║      SPOTIFY-ПЛЕЕР v3 — DELTA EDITION    ║
    ║      ЧАСТЬ 1/3: Ядро + GUI-каркас        ║
    ╚══════════════════════════════════════════╝
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui", 15)
if not playerGui then warn("[Spotify] PlayerGui не найден") return end

local HAS_FILE = false
pcall(function()
    HAS_FILE = (typeof(writefile) == "function" and typeof(readfile) == "function")
end)

-- ░░░░ ТЕМЫ ░░░░
local rgb = Color3.fromRGB
local THEMES = {
    dark = {
        bg = rgb(18, 18, 18), side = rgb(0, 0, 0), panel = rgb(24, 24, 24), elev = rgb(40, 40, 40),
        hover = rgb(46, 46, 46), elev2 = rgb(83, 83, 83), chip = rgb(62, 62, 62),
        text = rgb(255, 255, 255), sub = rgb(179, 179, 179), green = rgb(30, 215, 96),
        red = rgb(240, 80, 80), ink = rgb(18, 18, 18), marker = rgb(255, 196, 0),
        bannerV = 0.6, bannerS = 0.6,
    },
    light = {
        bg = rgb(250, 250, 252), side = rgb(238, 238, 243), panel = rgb(255, 255, 255), elev = rgb(230, 230, 236),
        hover = rgb(236, 236, 241), elev2 = rgb(176, 176, 188), chip = rgb(220, 220, 228),
        text = rgb(22, 22, 26), sub = rgb(100, 100, 112), green = rgb(24, 176, 80),
        red = rgb(214, 48, 48), ink = rgb(255, 255, 255), marker = rgb(230, 150, 0),
        bannerV = 0.97, bannerS = 0.4,
    },
}
local C = THEMES.dark

local FONT, FONT_B, FONT_X = Enum.Font.GothamMedium, Enum.Font.GothamBold, Enum.Font.GothamBlack
local W, H = 860, 560
local SIDE_W, BAR_H = 220, 96
local CONTENT_W = W - SIDE_W
local MAX_TRACKS, MAX_PLAYLISTS = 300, 20

-- ░░░░ ХЕЛПЕРЫ ░░░░
local themed = {}

local function new(class, props)
    local inst = Instance.new(class)
    local parent = props.Parent
    local bgRole, tcRole = props.bg, props.tc
    props.Parent, props.bg, props.tc = nil, nil, nil
    if bgRole then props.BackgroundColor3 = C[bgRole] end
    if tcRole then props.TextColor3 = C[tcRole] end
    for k, v in pairs(props) do inst[k] = v end
    if bgRole then themed[#themed + 1] = { inst, "BackgroundColor3", bgRole } end
    if tcRole then themed[#themed + 1] = { inst, "TextColor3", tcRole } end
    inst.Parent = parent
    return inst
end

local function corner(inst, r)
    return new("UICorner", { CornerRadius = UDim.new(0, r), Parent = inst })
end

local function label(props)
    props.BackgroundTransparency = 1
    props.Font = props.Font or FONT
    if not props.tc and not props.TextColor3 then props.tc = "text" end
    props.TextSize = props.TextSize or 14
    props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
    return new("TextLabel", props)
end

local function tween(inst, t, props, style, dir)
    local tw = TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
    tw:Play()
    return tw
end

local function formatTime(s)
    s = math.max(0, math.floor(s))
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function isPointer(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end
local function isMove(input)
    return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
end

local function pointer()
    return UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
end
local function inside(g, p)
    local a, s = g.AbsolutePosition, g.AbsoluteSize
    return p.X >= a.X and p.X <= a.X + s.X and p.Y >= a.Y and p.Y <= a.Y + s.Y
end

local function hueFor(seed)
    if type(seed) == "string" then
        local h = 0
        for i = 1, #seed do h = (h * 31 + seed:byte(i)) % 1000 end
        seed = h
    end
    return (seed * 0.61803398875) % 1
end
local function accentH(h, v, s) return Color3.fromHSV(h, s or 0.6, v or 0.85) end
local function accent(seed, v) return accentH(hueFor(seed), v) end

local function pluralTracks(n)
    local a, b = n % 10, n % 100
    if a == 1 and b ~= 11 then return n .. " трек" end
    if a >= 2 and a <= 4 and (b < 12 or b > 14) then return n .. " трека" end
    return n .. " треков"
end

local function cutText(s, n)
    if type(s) ~= "string" or not utf8.len(s) then return "" end
    local o = utf8.offset(s, n + 1)
    if o then return s:sub(1, o - 1) end
    return s
end

local function lowerU(s)
    if type(s) ~= "string" or not utf8.len(s) then return "" end
    local out = {}
    for _, cp in utf8.codes(s) do
        local c = cp
        if c >= 0x410 and c <= 0x42F then c += 32
        elseif c == 0x401 then c = 0x451
        elseif c >= 0x41 and c <= 0x5A then c += 32 end
        out[#out + 1] = utf8.char(c)
    end
    return table.concat(out)
end

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

-- ░░░░ СОСТОЯНИЕ ░░░░
local state = {
    playlists = {
        {
            name = "Мой плейлист",
            tracks = {
                { id = 1843463175, title = "Пример трека 1", artist = "Исполнитель" },
                { id = 1837879082, title = "Пример трека 2", artist = "Исполнитель" },
            },
        },
    },
    liked = {},
    volume = 0.5, bass = 0, reverb = false, last = 1,
    theme = "dark", crossfade = 0, binds = {}, markers = {},
}
getgenv().SpotifyState = state

local SAVE_FILE = "SpotifyPlayer_delta.json"
getgenv().SpotifySaveFile = SAVE_FILE
getgenv().SpotifyHasFile = HAS_FILE

local function loadLocal()
    if not HAS_FILE then return end
    pcall(function()
        if isfile(SAVE_FILE) then
            local data = HttpService:JSONDecode(readfile(SAVE_FILE))
            if type(data) == "table" then
                if type(data.playlists) == "table" and #data.playlists > 0 then state.playlists = data.playlists end
                if type(data.liked) == "table" then state.liked = data.liked end
                state.volume = tonumber(data.volume) or state.volume
                state.bass = tonumber(data.bass) or state.bass
                state.reverb = data.reverb == true
                state.last = tonumber(data.last) or 1
                state.theme = data.theme == "light" and "light" or "dark"
                state.crossfade = tonumber(data.crossfade) or 0
                state.binds = data.binds or {}
                state.markers = data.markers or {}
            end
        end
    end)
end
loadLocal()
C = THEMES[state.theme] or THEMES.dark

local saveToken = 0
getgenv().SpotifyMarkDirty = function()
    if not HAS_FILE then return end
    saveToken += 1
    local my = saveToken
    task.delay(2, function()
        if my == saveToken then
            pcall(function()
                writefile(SAVE_FILE, HttpService:JSONEncode({
                    playlists = state.playlists,
                    liked = state.liked,
                    volume = state.volume,
                    bass = state.bass,
                    reverb = state.reverb,
                    last = state.last,
                    theme = state.theme,
                    crossfade = state.crossfade,
                    binds = state.binds,
                    markers = state.markers,
                }))
            end)
        end
    end)
end

-- ░░░░ VIEW / SEARCH / SORT ░░░░
local view = { kind = "pl", index = 1 }
local searchList, searchQuery = {}, ""
local topList, topState = {}, "idle"
local sortMode = "manual"
getgenv().SpotifyView = function() return view end
getgenv().SpotifySearchList = function() return searchList end
getgenv().SpotifyTopList = function() return topList end
getgenv().SpotifySort = function() return sortMode end

-- ░░░░ ГОРЯЧИЕ КЛАВИШИ ░░░░
local ACTIONS = {
    { id = "toggle",  name = "Показать / скрыть плеер", def = "M" },
    { id = "mini",    name = "Мини-режим",              def = "N" },
    { id = "play",    name = "Пауза / играть",          def = "P" },
    { id = "next",    name = "Следующий трек",          def = "Period" },
    { id = "prev",    name = "Предыдущий трек",         def = "Comma" },
    { id = "volup",   name = "Громче",                  def = "Equals" },
    { id = "voldown", name = "Тише",                    def = "Minus" },
    { id = "seekf",   name = "Вперёд на 10 с",          def = "RightBracket" },
    { id = "seekb",   name = "Назад на 10 с",           def = "LeftBracket" },
    { id = "like",    name = "В любимое",               def = "H" },
    { id = "shuffle", name = "Перемешать",              def = "J" },
    { id = "marker",  name = "Поставить маркер",        def = "V" },
    { id = "theme",   name = "Светлая / тёмная тема",   def = "Y" },
    { id = "search",  name = "Поиск",                   def = "Slash" },
}
getgenv().SpotifyActions = ACTIONS

local KEYNAMES = {
    Period = ".", Comma = ",", Equals = "=", Minus = "-", RightBracket = "]",
    LeftBracket = "[", Slash = "/", Backquote = "`", Semicolon = ";", Quote = "'",
}
getgenv().SpotifyKeyNames = KEYNAMES

local function keyOf(id)
    local name = state.binds[id]
    if name == nil then
        for _, a in ipairs(ACTIONS) do
            if a.id == id then name = a.def end
        end
    end
    if not name or name == "None" then return nil end
    local ok, kc = pcall(function() return Enum.KeyCode[name] end)
    return ok and kc or nil
end
getgenv().SpotifyKeyOf = keyOf

-- forward decl
local renderList, renderSidebar, renderBanner, updateNowPlaying, updatePlayState
local setView, playFromList, nextTrack, prevTrack, togglePlay
local toggleLike, refreshTexts, closePopups, notify, updateHearts
local openMenu, openAddMenu, openTrackMenu, setMode, rebuildMarkers, addMarker
local setVolume, applyTheme, runAction, refreshKeys, setSpeed
local uiMode, lastShown = "hidden", "full"
local markerLen = 0

-- ░░░░ ССЫЛКИ ДЛЯ ЧАСТИ 2 ░░░░
getgenv().SpotifyRefs = {
    -- сервисы
    Players = Players, RunService = RunService, SoundService = SoundService,
    TweenService = TweenService, UserInputService = UserInputService,
    MarketplaceService = MarketplaceService, HttpService = HttpService, GuiService = GuiService,
    player = player, playerGui = playerGui,
    -- хелперы
    new = new, corner = corner, label = label, tween = tween,
    formatTime = formatTime, isPointer = isPointer, isMove = isMove,
    pointer = pointer, inside = inside, hueFor = hueFor,
    accentH = accentH, accent = accent, pluralTracks = pluralTracks,
    cutText = cutText, lowerU = lowerU, bouncy = bouncy, pop = pop,
    -- константы
    FONT = FONT, FONT_B = FONT_B, FONT_X = FONT_X,
    W = W, H = H, SIDE_W = SIDE_W, BAR_H = BAR_H, CONTENT_W = CONTENT_W,
    MAX_TRACKS = MAX_TRACKS, MAX_PLAYLISTS = MAX_PLAYLISTS,
    -- состояние
    state = state, view = view, sortMode = sortMode,
    currentList = nil, displayList = nil, buildSearch = nil, isLiked = nil,
    -- forward
    renderList = function() if renderList then renderList() end end,
    renderSidebar = function() if renderSidebar then renderSidebar() end end,
    renderBanner = function() if renderBanner then renderBanner() end end,
    updateNowPlaying = function() if updateNowPlaying then updateNowPlaying() end end,
    updatePlayState = function() if updatePlayState then updatePlayState() end end,
    setView = function(v) if setView then setView(v) end end,
    playFromList = function(l, i) if playFromList then playFromList(l, i) end end,
    nextTrack = function(a, e) if nextTrack then nextTrack(a, e) end end,
    prevTrack = function() if prevTrack then prevTrack() end end,
    togglePlay = function() if togglePlay then togglePlay() end end,
    toggleLike = function(t) if toggleLike then toggleLike(t) end end,
    refreshTexts = function() if refreshTexts then refreshTexts() end end,
    closePopups = function() if closePopups then closePopups() end end,
    notify = function(m) if notify then notify(m) end end,
    updateHearts = function() if updateHearts then updateHearts() end end,
    openMenu = function(t, items, at) if openMenu then openMenu(t, items, at) end end,
    openAddMenu = function(t, at) if openAddMenu then openAddMenu(t, at) end end,
    openTrackMenu = function(t, l, i) if openTrackMenu then openTrackMenu(t, l, i) end end,
    setMode = function(m) if setMode then setMode(m) end end,
    rebuildMarkers = function() if rebuildMarkers then rebuildMarkers() end end,
    addMarker = function(s) if addMarker then addMarker(s) end end,
    setVolume = function(a) if setVolume then setVolume(a) end end,
    applyTheme = function() if applyTheme then applyTheme() end end,
    runAction = function(a) if runAction then runAction(a) end end,
    refreshKeys = function() if refreshKeys then refreshKeys() end end,
    setSpeed = function(v) if setSpeed then setSpeed(v) end end,
    markDirty = getgenv().SpotifyMarkDirty,
    setRenderList = function(fn) renderList = fn end,
    setRenderSidebar = function(fn) renderSidebar = fn end,
    setRenderBanner = function(fn) renderBanner = fn end,
    setUpdateNowPlaying = function(fn) updateNowPlaying = fn end,
    setUpdatePlayState = function(fn) updatePlayState = fn end,
    setSetView = function(fn) setView = fn end,
    setPlayFromList = function(fn) playFromList = fn end,
    setNextTrack = function(fn) nextTrack = fn end,
    setPrevTrack = function(fn) prevTrack = fn end,
    setTogglePlay = function(fn) togglePlay = fn end,
    setToggleLike = function(fn) toggleLike = fn end,
    setRefreshTexts = function(fn) refreshTexts = fn end,
    setClosePopups = function(fn) closePopups = fn end,
    setNotify = function(fn) notify = fn end,
    setUpdateHearts = function(fn) updateHearts = fn end,
    setOpenMenu = function(fn) openMenu = fn end,
    setOpenAddMenu = function(fn) openAddMenu = fn end,
    setOpenTrackMenu = function(fn) openTrackMenu = fn end,
    setSetMode = function(fn) setMode = fn end,
    setRebuildMarkers = function(fn) rebuildMarkers = fn end,
    setAddMarker = function(fn) addMarker = fn end,
    setSetVolume = function(fn) setVolume = fn end,
    setApplyTheme = function(fn) applyTheme = fn end,
    setRunAction = function(fn) runAction = fn end,
    setRefreshKeys = function(fn) refreshKeys = fn end,
    setSetSpeed = function(fn) setSpeed = fn end,
    getUiMode = function() return uiMode end,
    setUiMode = function(m) uiMode = m end,
}

print("✅ [Spotify Delta] Часть 1/3 — Ядро готово")
pcall(function()
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = "🎵 Spotify Player", Text = "⏳ Часть 1/3 загружена", Duration = 2
    })
end)

--[[
    SPOTIFY-ПЛЕЕР v3 — DELTA EDITION
    ЧАСТЬ 2A: Звук + Сайдбар + Баннер + Тулбар
]]

local R = getgenv().SpotifyRefs
if not R then warn("❌ Сначала запусти Часть 1!") return end

local Players, RunService, SoundService = R.Players, R.RunService, R.SoundService
local TweenService, UserInputService = R.TweenService, R.UserInputService
local MarketplaceService, HttpService = R.MarketplaceService, R.HttpService
local player, playerGui = R.player, R.playerGui

local new, corner, label, tween = R.new, R.corner, R.label, R.tween
local formatTime, isPointer, isMove = R.formatTime, R.isPointer, R.isMove
local pointer, inside = R.pointer, R.inside
local hueFor, accentH, accent = R.hueFor, R.accentH, R.accent
local pluralTracks, cutText, lowerU = R.pluralTracks, R.cutText, R.lowerU
local bouncy, pop = R.bouncy, R.pop

local FONT, FONT_B, FONT_X = R.FONT, R.FONT_B, R.FONT_X
local W, H, SIDE_W, BAR_H, CONTENT_W = R.W, R.H, R.SIDE_W, R.BAR_H, R.CONTENT_W
local MAX_TRACKS, MAX_PLAYLISTS = R.MAX_TRACKS, R.MAX_PLAYLISTS

local state = R.state

-- ░░░░ ЗВУК ░░░░
local group = new("SoundGroup", { Name = "SpotifyBus", Volume = state.volume, Parent = SoundService })
local eq = new("EqualizerSoundEffect", { Parent = group })
local reverbFx = new("ReverbSoundEffect", {
    DecayTime = 2.8, Density = 0.9, Diffusion = 0.9, DryLevel = 0, WetLevel = -6, Enabled = false, Parent = group,
})

local function applyAudio()
    group.Volume = state.volume
    eq.LowGain = math.clamp(state.bass * 10, -80, 10)
    eq.MidGain = -state.bass * 3
    eq.HighGain = 0
    reverbFx.Enabled = state.reverb
end
applyAudio()
getgenv().SpotifyApplyAudio = applyAudio

-- ░░░░ GUI ROOT ░░░░
local gui = new("ScreenGui", {
    Name = "SpotifyPlayer", ResetOnSpawn = false, DisplayOrder = 10,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = playerGui,
})
local root = new("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(W, H), BackgroundTransparency = 1, Parent = gui,
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
    Size = UDim2.fromScale(1, 1), bg = "bg", BorderSizePixel = 0, Visible = false, Parent = root,
})
corner(main, 14)

getgenv().SpotifyGui = gui
getgenv().SpotifyMain = main
getgenv().SpotifyRoot = root
getgenv().SpotifyUIScale = uiScale

-- ░░░░ TOAST ░░░░
local toast = new("Frame", {
    AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, -70),
    Size = UDim2.fromOffset(340, 40), bg = "text", ZIndex = 100, Parent = gui,
})
corner(toast, 20)
local toastLbl = label({
    Text = "", Font = FONT_B, TextSize = 14, tc = "bg", TextXAlignment = Enum.TextXAlignment.Center,
    Size = UDim2.fromScale(1, 1), ZIndex = 101, Parent = toast,
})
local toastToken = 0
R.setNotify(function(msg)
    toastToken += 1
    local my = toastToken
    toastLbl.Text = msg
    tween(toast, 0.35, { Position = UDim2.new(0.5, 0, 0, 20) }, Enum.EasingStyle.Back)
    task.delay(2.4, function()
        if my == toastToken then tween(toast, 0.25, { Position = UDim2.new(0.5, 0, 0, -70) }) end
    end)
end)

-- ░░░░ САЙДБАР ░░░░
local sidebar = new("Frame", {
    Size = UDim2.new(0, SIDE_W, 1, -BAR_H), bg = "side", BorderSizePixel = 0, Parent = main,
})
label({ Text = "♪", Font = FONT_X, TextSize = 26, tc = "green", Position = UDim2.fromOffset(20, 40), Size = UDim2.fromOffset(26, 30), Parent = sidebar })
label({ Text = "Музыка", Font = FONT_X, TextSize = 22, Position = UDim2.fromOffset(50, 40), Size = UDim2.new(1, -60, 0, 30), Parent = sidebar })

local function sideButton(parent, y, icon, text)
    local props = { Text = "", Size = UDim2.new(1, -16, 0, 38), bg = "elev", BackgroundTransparency = 1, AutoButtonColor = false, Parent = parent }
    if y then props.Position = UDim2.fromOffset(8, y) end
    local b = new("TextButton", props)
    corner(b, 8)
    local ic = label({ Text = icon, Font = FONT_B, TextSize = 18, tc = "sub", TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(6, 0), Size = UDim2.fromOffset(30, 38), Parent = b })
    local tx = label({ Text = text, Font = FONT_B, TextSize = 14, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(42, 0), Size = UDim2.new(1, -50, 1, 0), Parent = b })
    b.MouseEnter:Connect(function() if b.BackgroundTransparency > 0.9 then tween(b, 0.12, { BackgroundTransparency = 0.7 }) end end)
    b.MouseLeave:Connect(function() if b.BackgroundTransparency > 0.5 then tween(b, 0.12, { BackgroundTransparency = 1 }) end end)
    return b, ic, tx
end

local navLiked, navLikedIc, navLikedTx = sideButton(sidebar, 90, "♥", "Любимое")
local navTop, navTopIc, navTopTx = sideButton(sidebar, 134, "🔥", "Топ чарт")
getgenv().SpotifyNavLiked = navLiked
getgenv().SpotifyNavTop = navTop
getgenv().SpotifyNavLikedTx = navLikedTx
getgenv().SpotifyNavLikedIc = navLikedIc
getgenv().SpotifyNavTopTx = navTopTx
getgenv().SpotifyNavTopIc = navTopIc

label({ Text = "ПЛЕЙЛИСТЫ", Font = FONT_B, TextSize = 12, tc = "sub", Position = UDim2.fromOffset(20, 190), Size = UDim2.fromOffset(120, 24), Parent = sidebar })

local plAddBtn = new("TextButton", {
    Text = "+", Font = FONT_B, TextSize = 22, tc = "sub", BackgroundTransparency = 1,
    AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 188), Size = UDim2.fromOffset(28, 28), Parent = sidebar,
})
bouncy(plAddBtn, 1.15)

local plNameBox = new("TextBox", {
    PlaceholderText = "Название и Enter", PlaceholderColor3 = Color3.fromRGB(140, 140, 150), Text = "",
    ClearTextOnFocus = false, Font = FONT, TextSize = 13, tc = "text",
    TextXAlignment = Enum.TextXAlignment.Left, bg = "elev", Visible = false,
    Position = UDim2.fromOffset(10, 218), Size = UDim2.new(1, -20, 0, 30), Parent = sidebar,
})
corner(plNameBox, 15)
new("UIPadding", { PaddingLeft = UDim.new(0, 12), Parent = plNameBox })

local plScroll = new("ScrollingFrame", {
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
    CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = sidebar,
})
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = plScroll })

local function layoutSidebar()
    local y = plNameBox.Visible and 254 or 220
    plScroll.Position = UDim2.fromOffset(8, y)
    plScroll.Size = UDim2.new(1, -16, 1, -(y + 52))
end
layoutSidebar()
getgenv().SpotifySidebarLayout = layoutSidebar
getgenv().SpotifyPlScroll = plScroll
getgenv().SpotifyPlNameBox = plNameBox
getgenv().SpotifyPlAddBtn = plAddBtn

local botRow = new("Frame", {
    AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -6),
    Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1, Parent = sidebar,
})
local function smallBtn(text, x)
    local b = new("TextButton", {
        Text = text, Font = FONT_B, TextSize = 16, tc = "sub", bg = "elev",
        Position = UDim2.fromOffset(x, 2), Size = UDim2.fromOffset(60, 32), AutoButtonColor = false, Parent = botRow,
    })
    corner(b, 16)
    bouncy(b, 1.06)
    return b
end
local themeBtn = smallBtn("☀", 12)
local keysBtn = smallBtn("⌨", 80)
local miniBtn = smallBtn("▭", 148)
getgenv().SpotifyThemeBtn = themeBtn
getgenv().SpotifyKeysBtn = keysBtn
getgenv().SpotifyMiniBtn = miniBtn

-- ░░░░ КОНТЕНТ (правый блок) ░░░░
local content = new("Frame", {
    Position = UDim2.fromOffset(SIDE_W, 0), Size = UDim2.new(0, CONTENT_W, 1, -BAR_H),
    bg = "bg", BorderSizePixel = 0, Parent = main,
})

-- Баннер
local banner = new("Frame", {
    Size = UDim2.new(1, 0, 0, 130), BackgroundColor3 = Color3.fromRGB(60, 40, 120), BorderSizePixel = 0, Parent = content,
})
local bannerFade = new("Frame", { Size = UDim2.fromScale(1, 1), bg = "bg", BorderSizePixel = 0, Parent = banner })
new("UIGradient", {
    Rotation = 90,
    Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) }),
    Parent = bannerFade,
})

local bannerCover = new("Frame", {
    Position = UDim2.fromOffset(28, 34), Size = UDim2.fromOffset(84, 84),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255), BorderSizePixel = 0, Parent = banner,
})
corner(bannerCover, 8)
local bannerCoverGrad = new("UIGradient", {
    Color = ColorSequence.new(Color3.fromRGB(30, 215, 96), Color3.fromRGB(60, 40, 120)), Rotation = 45, Parent = bannerCover,
})
local bannerCoverScale = new("UIScale", { Parent = bannerCover })
local bannerIcon = label({ Text = "♪", Font = FONT_X, TextSize = 40, TextColor3 = Color3.fromRGB(255, 255, 255), TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = bannerCover })
local bannerKind = label({ Text = "ПЛЕЙЛИСТ", Font = FONT_B, TextSize = 11, Position = UDim2.fromOffset(128, 40), Size = UDim2.fromOffset(320, 16), Parent = banner })
local bannerTitle = label({ Text = "", Font = FONT_X, TextSize = 30, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(128, 56), Size = UDim2.fromOffset(330, 40), Parent = banner })
local bannerSub = label({ Text = "", TextSize = 13, tc = "sub", Position = UDim2.fromOffset(128, 98), Size = UDim2.fromOffset(330, 18), Parent = banner })

getgenv().SpotifyBanner = banner
getgenv().SpotifyBannerCover = bannerCover
getgenv().SpotifyBannerCoverGrad = bannerCoverGrad
getgenv().SpotifyBannerCoverScale = bannerCoverScale
getgenv().SpotifyBannerIcon = bannerIcon
getgenv().SpotifyBannerKind = bannerKind
getgenv().SpotifyBannerTitle = bannerTitle
getgenv().SpotifyBannerSub = bannerSub

-- Визуализатор
local VIS_BARS = 16
local visBox = new("Frame", {
    Position = UDim2.fromOffset(CONTENT_W - 28 - VIS_BARS * 9, 40),
    Size = UDim2.fromOffset(VIS_BARS * 9, 74), BackgroundTransparency = 1, Parent = banner,
})
local bars = {}
for i = 1, VIS_BARS do
    local b = new("Frame", {
        AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, (i - 1) * 9, 1, 0), Size = UDim2.fromOffset(6, 4),
        BackgroundColor3 = Color3.fromRGB(30, 215, 96), BackgroundTransparency = 0.15, BorderSizePixel = 0, Parent = visBox,
    })
    corner(b, 3)
    bars[i] = b
end
getgenv().SpotifyVisBars = bars

-- ░░░░ ТУЛБАР ░░░░
local toolbar = new("Frame", {
    Position = UDim2.fromOffset(0, 130), Size = UDim2.new(1, 0, 0, 52), BackgroundTransparency = 1, Parent = content,
})

local bigPlay = new("TextButton", {
    Text = "▶", Font = FONT_B, TextSize = 20, tc = "ink", bg = "green",
    Position = UDim2.fromOffset(28, 3), Size = UDim2.fromOffset(46, 46), AutoButtonColor = false, Parent = toolbar,
})
corner(bigPlay, 23)
bouncy(bigPlay, 1.08)

local sortBtn = new("TextButton", {
    Text = "⇅ Мой порядок", Font = FONT_B, TextSize = 12, tc = "text", bg = "elev",
    Position = UDim2.fromOffset(84, 10), Size = UDim2.fromOffset(128, 32), AutoButtonColor = false, Parent = toolbar,
})
corner(sortBtn, 16)
bouncy(sortBtn, 1.04)

local searchRow = new("Frame", {
    Position = UDim2.fromOffset(220, 10), Size = UDim2.fromOffset(184, 32), bg = "elev", Parent = toolbar,
})
corner(searchRow, 16)
label({ Text = "🔍", TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(4, 0), Size = UDim2.fromOffset(26, 32), Parent = searchRow })
local searchBox = new("TextBox", {
    PlaceholderText = "Поиск по трекам", PlaceholderColor3 = Color3.fromRGB(140, 140, 150), Text = "",
    ClearTextOnFocus = false, Font = FONT, TextSize = 13, tc = "text",
    TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1,
    Position = UDim2.fromOffset(30, 0), Size = UDim2.new(1, -58, 1, 0), Parent = searchRow,
})
local searchClear = new("TextButton", {
    Text = "✕", Font = FONT_B, TextSize = 12, tc = "sub", BackgroundTransparency = 1, Visible = false,
    AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(22, 22), Parent = searchRow,
})

local topHint = label({ Text = "Чарт недоступен в Delta", TextSize = 12, tc = "sub", TextXAlignment = Enum.TextXAlignment.Right, Visible = false, Position = UDim2.new(1, -208, 0, 0), Size = UDim2.fromOffset(180, 52), Parent = toolbar })

local addRow = new("Frame", { Position = UDim2.new(1, -228, 0, 10), Size = UDim2.fromOffset(200, 32), bg = "elev", Parent = toolbar })
corner(addRow, 16)
local addBox = new("TextBox", {
    PlaceholderText = "Добавить по ID", PlaceholderColor3 = Color3.fromRGB(140, 140, 150), Text = "",
    ClearTextOnFocus = false, Font = FONT, TextSize = 13, tc = "text",
    TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1,
    Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -48, 1, 0), Parent = addRow,
})
local addBtn = new("TextButton", {
    Text = "+", Font = FONT_B, TextSize = 20, tc = "ink", bg = "green",
    AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0.5, 0), Size = UDim2.fromOffset(24, 24),
    AutoButtonColor = false, Parent = addRow,
})
corner(addBtn, 12)
bouncy(addBtn, 1.1)

-- Заголовки таблицы
label({ Text = "#", Font = FONT_B, TextSize = 12, tc = "sub", TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(12, 182), Size = UDim2.fromOffset(40, 22), Parent = content })
label({ Text = "НАЗВАНИЕ", Font = FONT_B, TextSize = 12, tc = "sub", Position = UDim2.fromOffset(102, 182), Size = UDim2.fromOffset(200, 22), Parent = content })
new("Frame", { Position = UDim2.fromOffset(12, 204), Size = UDim2.new(1, -24, 0, 1), bg = "elev", BorderSizePixel = 0, Parent = content })

-- ░░░░ ССЫЛКИ ДЛЯ ЧАСТИ 2B ░░░░
getgenv().SpotifyContent = content
getgenv().SpotifyToolbar = toolbar
getgenv().SpotifyBigPlay = bigPlay
getgenv().SpotifySortBtn = sortBtn
getgenv().SpotifySearchBox = searchBox
getgenv().SpotifySearchClear = searchClear
getgenv().SpotifyTopHint = topHint
getgenv().SpotifyAddRow = addRow
getgenv().SpotifyAddBox = addBox
getgenv().SpotifyAddBtn = addBtn

print("✅ [Spotify Delta] Часть 2A — Звук + Сайдбар + Баннер + Тулбар")
pcall(function()
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = "🎵 Spotify Player", Text = "⏳ Часть 2A загружена", Duration = 2
    })
end)

--[[
    SPOTIFY-ПЛЕЕР v3 — DELTA EDITION
    ЧАСТЬ 2B: Список + Нижняя панель + Мини-плеер
]]

local R = getgenv().SpotifyRefs
if not R then warn("❌ Сначала запусти Часть 1!") return end
if not getgenv().SpotifyMain then warn("❌ Сначала запусти Часть 2A!") return end

local Players, RunService, SoundService = R.Players, R.RunService, R.SoundService
local TweenService, UserInputService = R.TweenService, R.UserInputService
local player = R.player

local new, corner, label, tween = R.new, R.corner, R.label, R.tween
local formatTime, isPointer, isMove = R.formatTime, R.isPointer, R.isMove
local pointer, inside = R.pointer, R.inside
local hueFor, accentH, accent = R.hueFor, R.accentH, R.accent
local pluralTracks, cutText, lowerU = R.pluralTracks, R.cutText, R.lowerU
local bouncy, pop = R.bouncy, R.pop

local FONT, FONT_B, FONT_X = R.FONT, R.FONT_B, R.FONT_X
local W, H, SIDE_W, BAR_H, CONTENT_W = R.W, R.H, R.SIDE_W, R.BAR_H, R.CONTENT_W

local state = R.state
local main = getgenv().SpotifyMain
local gui = getgenv().SpotifyGui
local uiScale = getgenv().SpotifyUIScale
local content = getgenv().SpotifyContent

-- ░░░░ СПИСОК ТРЕКОВ ░░░░
local listWrap = new("CanvasGroup", {
    Position = UDim2.fromOffset(12, 208), Size = UDim2.new(1, -24, 1, -208), BackgroundTransparency = 1, Parent = content,
})
local scroll = new("ScrollingFrame", {
    Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
    ScrollBarThickness = 4, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = listWrap,
})
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = scroll })
new("UIPadding", { PaddingTop = UDim.new(0, 4), Parent = scroll })

local emptyLbl = label({
    Text = "", TextSize = 14, tc = "sub", TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center,
    Visible = false, Position = UDim2.fromOffset(40, 50), Size = UDim2.new(1, -80, 0, 60), Parent = listWrap,
})

getgenv().SpotifyListWrap = listWrap
getgenv().SpotifyScroll = scroll
getgenv().SpotifyEmptyLbl = emptyLbl

-- ░░░░ НИЖНЯЯ ПАНЕЛЬ ░░░░
local bar = new("Frame", {
    Position = UDim2.new(0, 0, 1, -BAR_H), Size = UDim2.new(1, 0, 0, BAR_H), bg = "panel", BorderSizePixel = 0, Parent = main,
})
new("Frame", { Size = UDim2.new(1, 0, 0, 1), bg = "elev", BorderSizePixel = 0, Parent = bar })

local barCover = new("Frame", {
    Position = UDim2.fromOffset(16, 18), Size = UDim2.fromOffset(60, 60),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255), BorderSizePixel = 0, Parent = bar,
})
corner(barCover, 6)
local barCoverGrad = new("UIGradient", {
    Color = ColorSequence.new(Color3.fromRGB(120, 120, 130), Color3.fromRGB(70, 70, 80)), Rotation = 45, Parent = barCover,
})
local barCoverScale = new("UIScale", { Parent = barCover })
label({ Text = "♪", Font = FONT_B, TextSize = 26, TextColor3 = Color3.fromRGB(255, 255, 255), TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = barCover })

local barTitle = label({ Text = "Ничего не играет", Font = FONT_B, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(88, 26), Size = UDim2.fromOffset(126, 20), Parent = bar })
local barArtist = label({ Text = "Выбери трек", TextSize = 12, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(88, 47), Size = UDim2.fromOffset(126, 16), Parent = bar })

local barHeart = new("TextButton", {
    Text = "♥", Font = FONT_B, TextSize = 20, tc = "elev2", BackgroundTransparency = 1,
    Position = UDim2.fromOffset(220, 31), Size = UDim2.fromOffset(30, 34), Parent = bar,
})
bouncy(barHeart, 1.15)

getgenv().SpotifyBar = bar
getgenv().SpotifyBarCover = barCover
getgenv().SpotifyBarCoverGrad = barCoverGrad
getgenv().SpotifyBarCoverScale = barCoverScale
getgenv().SpotifyBarTitle = barTitle
getgenv().SpotifyBarArtist = barArtist
getgenv().SpotifyBarHeart = barHeart

-- ░░░░ КНОПКИ УПРАВЛЕНИЯ ░░░░
local center = new("Frame", {
    AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 10),
    Size = UDim2.fromOffset(330, 78), BackgroundTransparency = 1, Parent = bar,
})
local controls = new("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1, Parent = center })
new("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center,
    VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 12),
    SortOrder = Enum.SortOrder.LayoutOrder, Parent = controls,
})

local function ctrlButton(text, order, size)
    local b = new("TextButton", {
        Text = text, Font = FONT_B, TextSize = size or 20, tc = "sub", BackgroundTransparency = 1,
        Size = UDim2.fromOffset(32, 34), LayoutOrder = order, AutoButtonColor = false, Parent = controls,
    })
    bouncy(b, 1.12)
    return b
end

local shuffleBtn = ctrlButton("⇄", 1)
local prevBtn = ctrlButton("⏮", 2, 18)

local playBtn = new("TextButton", {
    Text = "▶", Font = FONT_B, TextSize = 18, tc = "bg", bg = "text",
    Size = UDim2.fromOffset(42, 42), LayoutOrder = 3, AutoButtonColor = false, Parent = controls,
})
corner(playBtn, 21)
bouncy(playBtn, 1.08)

local nextBtn = ctrlButton("⏭", 4, 18)
local repeatBtn = ctrlButton("↻", 5)
local markBtn = ctrlButton("⚑", 6, 17)

getgenv().SpotifyPlayBtn = playBtn
getgenv().SpotifyPrevBtn = prevBtn
getgenv().SpotifyNextBtn = nextBtn
getgenv().SpotifyShuffleBtn = shuffleBtn
getgenv().SpotifyRepeatBtn = repeatBtn
getgenv().SpotifyMarkBtn = markBtn

-- ░░░░ СЛАЙДЕР (переиспользуемый) ░░░░
local function makeSlider(parent, position, size, initial, onChanged, opts)
    opts = opts or {}
    local barF = new("Frame", { Position = position, Size = size, bg = "elev2", BorderSizePixel = 0, Parent = parent })
    corner(barF, 3)
    local fill = new("Frame", { Size = UDim2.fromScale(initial, 1), bg = "text", BorderSizePixel = 0, Parent = barF })
    corner(fill, 3)
    local knob = new("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(12, 12),
        bg = "text", Visible = false, Parent = fill,
    })
    corner(knob, 6)
    local hit = new("TextButton", {
        Text = "", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 22), Parent = barF,
    })
    local dragging, hoverA = false, 0
    local function frac(x)
        return math.clamp((x - barF.AbsolutePosition.X) / math.max(1, barF.AbsoluteSize.X), 0, 1)
    end
    local function update(x)
        local a = frac(x)
        fill.Size = UDim2.fromScale(a, 1)
        onChanged(a)
    end
    hit.MouseEnter:Connect(function()
        fill.BackgroundColor3 = Color3.fromRGB(30, 215, 96)
        knob.Visible = true
    end)
    hit.MouseLeave:Connect(function()
        if not dragging then
            fill.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
            knob.Visible = false
        end
        if opts.onLeave then opts.onLeave() end
    end)
    hit.MouseMoved:Connect(function(x)
        hoverA = frac(x)
        if opts.onHover then opts.onHover(hoverA) end
    end)
    hit.MouseButton2Click:Connect(function()
        if opts.onRight then opts.onRight(hoverA) end
    end)
    hit.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseWheel and opts.onWheel then
            opts.onWheel(input.Position.Z)
        end
    end)
    hit.InputBegan:Connect(function(input)
        if isPointer(input) then
            dragging = true
            fill.BackgroundColor3 = Color3.fromRGB(30, 215, 96)
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
            fill.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
            knob.Visible = false
        end
    end)
    return {
        Set = function(a) if not dragging then fill.Size = UDim2.fromScale(a, 1) end end,
        IsDragging = function() return dragging end,
    }
end
getgenv().SpotifyMakeSlider = makeSlider

-- ░░░░ ПРОГРЕСС-БАР ░░░░
local curTime = label({ Text = "0:00", TextSize = 11, tc = "sub", TextXAlignment = Enum.TextXAlignment.Right, Position = UDim2.fromOffset(0, 48), Size = UDim2.fromOffset(36, 16), Parent = center })
local totTime = label({ Text = "0:00", TextSize = 11, tc = "sub", Position = UDim2.fromOffset(294, 48), Size = UDim2.fromOffset(36, 16), Parent = center })

local tip = new("Frame", {
    AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromOffset(42, 46), Size = UDim2.fromOffset(52, 18),
    bg = "elev", Visible = false, ZIndex = 10, Parent = center,
})
corner(tip, 9)
local tipLbl = label({ Text = "0:00", Font = FONT_B, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), ZIndex = 11, Parent = tip })
getgenv().SpotifyTip = tip
getgenv().SpotifyTipLbl = tipLbl

local progress
progress = makeSlider(center, UDim2.fromOffset(42, 55), UDim2.fromOffset(246, 4), 0, function(a)
    local s = getgenv().SpotifySound and getgenv().SpotifySound()
    if s and s.TimeLength > 0 then
        s.TimePosition = a * s.TimeLength
        curTime.Text = formatTime(s.TimePosition)
    end
end, {
    onHover = function(a)
        local s = getgenv().SpotifySound and getgenv().SpotifySound()
        if s and s.TimeLength > 0 then
            tip.Position = UDim2.fromOffset(42 + a * 246, 46)
            tipLbl.Text = formatTime(a * s.TimeLength)
            tip.Visible = true
        end
    end,
    onLeave = function() tip.Visible = false end,
    onRight = function(a)
        local len = 0
        if getgenv().SpotifySound then
            local s = getgenv().SpotifySound()
            if s then len = s.TimeLength end
        end
        if R.addMarker then R.addMarker(a * len) end
    end,
})

local markerLayer = new("Frame", {
    Position = UDim2.fromOffset(42, 49), Size = UDim2.fromOffset(246, 16),
    BackgroundTransparency = 1, ZIndex = 6, Parent = center,
})
getgenv().SpotifyProgress = progress
getgenv().SpotifyCurTime = curTime
getgenv().SpotifyTotTime = totTime
getgenv().SpotifyMarkerLayer = markerLayer

-- ░░░░ ГРОМКОСТЬ ░░░░
local right = new("Frame", {
    AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16, 0.5, 0),
    Size = UDim2.fromOffset(222, 40), BackgroundTransparency = 1, Parent = bar,
})
label({ Text = "🔊", TextSize = 15, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromOffset(22, 40), Parent = right })

local volume
volume = makeSlider(right, UDim2.fromOffset(28, 18), UDim2.fromOffset(100, 4), state.volume, function(a)
    state.volume = a
    if getgenv().SpotifyApplyAudio then getgenv().SpotifyApplyAudio() end
    if R.markDirty then R.markDirty() end
end, { onWheel = function(z)
    state.volume = math.clamp(state.volume + z * 0.05, 0, 1)
    if getgenv().SpotifyApplyAudio then getgenv().SpotifyApplyAudio() end
    volume.Set(state.volume)
    if R.markDirty then R.markDirty() end
end })

local eqBtn = new("TextButton", {
    Text = "Звук ⚙", Font = FONT_B, TextSize = 13, tc = "text", bg = "elev",
    Position = UDim2.fromOffset(142, 5), Size = UDim2.fromOffset(80, 30), AutoButtonColor = false, Parent = right,
})
corner(eqBtn, 15)
bouncy(eqBtn, 1.06)

getgenv().SpotifyVolume = volume
getgenv().SpotifyEqBtn = eqBtn

-- ░░░░ МИНИ-ПЛЕЕР ░░░░
local miniRoot = new("CanvasGroup", {
    AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -74), Size = UDim2.fromOffset(360, 76),
    bg = "panel", Visible = false, Parent = gui,
})
corner(miniRoot, 14)
local miniScale = new("UIScale", { Parent = miniRoot })

local miniCover = new("Frame", {
    Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(54, 54),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255), BorderSizePixel = 0, Parent = miniRoot,
})
corner(miniCover, 8)
local miniCoverGrad = new("UIGradient", {
    Color = ColorSequence.new(Color3.fromRGB(120, 120, 130), Color3.fromRGB(70, 70, 80)), Rotation = 45, Parent = miniCover,
})
local miniCoverScale = new("UIScale", { Parent = miniCover })
label({ Text = "♪", Font = FONT_B, TextSize = 22, TextColor3 = Color3.fromRGB(255, 255, 255), TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = miniCover })

local miniTitle = label({ Text = "Ничего не играет", Font = FONT_B, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(74, 16), Size = UDim2.fromOffset(126, 20), Parent = miniRoot })
local miniArtist = label({ Text = "", TextSize = 12, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(74, 38), Size = UDim2.fromOffset(126, 16), Parent = miniRoot })

local miniDrag = new("Frame", { Size = UDim2.fromOffset(204, 76), BackgroundTransparency = 1, Parent = miniRoot })
do
    local dragging, dragStart, startPos
    miniDrag.InputBegan:Connect(function(input)
        if isPointer(input) then
            dragging, dragStart, startPos = true, input.Position, miniRoot.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and isMove(input) then
            local d = input.Position - dragStart
            miniRoot.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if isPointer(input) then dragging = false end
    end)
end

local function miniBtnMake(text, x, size, circle)
    local b = new("TextButton", {
        Text = text, Font = FONT_B, TextSize = size,
        tc = circle and "bg" or "text",
        BackgroundTransparency = circle and 0 or 1,
        bg = circle and "text" or nil,
        Position = UDim2.fromOffset(x, circle and 19 or 22),
        Size = UDim2.fromOffset(circle and 38 or 30, circle and 38 or 32),
        AutoButtonColor = false, Parent = miniRoot,
    })
    if circle then corner(b, 19) end
    bouncy(b, 1.1)
    return b
end
local miniPrev = miniBtnMake("⏮", 206, 16)
local miniPlay = miniBtnMake("▶", 240, 16, true)
local miniNext = miniBtnMake("⏭", 284, 16)
local miniExpand = miniBtnMake("⤢", 320, 18)
miniExpand.TextColor3 = Color3.fromRGB(179, 179, 179)

local miniTrack = new("Frame", {
    AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 3),
    bg = "elev", BorderSizePixel = 0, Parent = miniRoot,
})
local miniFill = new("Frame", { Size = UDim2.fromScale(0, 1), bg = "green", BorderSizePixel = 0, Parent = miniTrack })

getgenv().SpotifyMiniRoot = miniRoot
getgenv().SpotifyMiniScale = miniScale
getgenv().SpotifyMiniCover = miniCover
getgenv().SpotifyMiniCoverGrad = miniCoverGrad
getgenv().SpotifyMiniCoverScale = miniCoverScale
getgenv().SpotifyMiniTitle = miniTitle
getgenv().SpotifyMiniArtist = miniArtist
getgenv().SpotifyMiniPlay = miniPlay
getgenv().SpotifyMiniPrev = miniPrev
getgenv().SpotifyMiniNext = miniNext
getgenv().SpotifyMiniExpand = miniExpand
getgenv().SpotifyMiniTrack = miniTrack
getgenv().SpotifyMiniFill = miniFill

-- ░░░░ КНОПКИ ЗАКРЫТИЯ / ТОГГЛ ░░░░
local closeBtn = new("TextButton", {
    Text = "✕", Font = FONT_B, TextSize = 15, tc = "sub", BackgroundTransparency = 1,
    AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0, 18), Size = UDim2.fromOffset(28, 28),
    ZIndex = 6, Parent = main,
})
bouncy(closeBtn, 1.15)

local toggleBtn = new("TextButton", {
    Text = "♪", Font = FONT_X, TextSize = 24, tc = "ink", bg = "green",
    AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -16), Size = UDim2.fromOffset(46, 46),
    AutoButtonColor = false, Parent = gui,
})
corner(toggleBtn, 23)
bouncy(toggleBtn, 1.1)

-- Верхняя полоса перетаскивания
local dragHandle = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, ZIndex = 5, Parent = main })
do
    local dragging, dragStart, startPos
    dragHandle.InputBegan:Connect(function(input)
        if isPointer(input) then
            dragging, dragStart, startPos = true, input.Position, getgenv().SpotifyRoot.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and isMove(input) then
            local d = (input.Position - dragStart) / uiScale.Scale
            getgenv().SpotifyRoot.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y
            )
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if isPointer(input) then dragging = false end
    end)
end

getgenv().SpotifyCloseBtn = closeBtn
getgenv().SpotifyToggleBtn = toggleBtn

print("✅ [Spotify Delta] Часть 2B — Список + Нижняя панель + Мини-плеер")
pcall(function()
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = "🎵 Spotify Player", Text = "✅ Часть 2B загружена", Duration = 2
    })
end)

--[[
    SPOTIFY-ПЛЕЕР v3 — DELTA EDITION
    ЧАСТЬ 3A: Рендер + Воспроизведение
]]

local R = getgenv().SpotifyRefs
if not R then warn("❌ Сначала запусти Часть 1!") return end
if not getgenv().SpotifyMain then warn("❌ Сначала запусти Часть 2A!") return end
if not getgenv().SpotifyScroll then warn("❌ Сначала запусти Часть 2B!") return end

local Players, RunService, SoundService = R.Players, R.RunService, R.SoundService
local TweenService, UserInputService = R.TweenService, R.UserInputService
local MarketplaceService = R.MarketplaceService

local new, corner, label, tween = R.new, R.corner, R.label, R.tween
local formatTime, isPointer = R.formatTime, R.isPointer
local hueFor, accentH, accent = R.hueFor, R.accentH, R.accent
local pluralTracks, lowerU = R.pluralTracks, R.lowerU
local bouncy, pop = R.bouncy, R.pop
local FONT, FONT_B, FONT_X = R.FONT, R.FONT_B, R.FONT_X
local W, H, SIDE_W, BAR_H = R.W, R.H, R.SIDE_W, R.BAR_H
local MAX_TRACKS = R.MAX_TRACKS

local state = R.state
local view = R.view

-- Ссылки из Части 2A/2B
local main = getgenv().SpotifyMain
local scroll = getgenv().SpotifyScroll
local listWrap = getgenv().SpotifyListWrap
local emptyLbl = getgenv().SpotifyEmptyLbl

local bannerTitle = getgenv().SpotifyBannerTitle
local bannerKind = getgenv().SpotifyBannerKind
local bannerSub = getgenv().SpotifyBannerSub
local bannerIcon = getgenv().SpotifyBannerIcon
local banner = getgenv().SpotifyBanner
local bannerCoverGrad = getgenv().SpotifyBannerCoverGrad

local playBtn = getgenv().SpotifyPlayBtn
local prevBtn = getgenv().SpotifyPrevBtn
local nextBtn = getgenv().SpotifyNextBtn
local shuffleBtn = getgenv().SpotifyShuffleBtn
local repeatBtn = getgenv().SpotifyRepeatBtn
local barHeart = getgenv().SpotifyBarHeart
local bigPlay = getgenv().SpotifyBigPlay
local miniPlay = getgenv().SpotifyMiniPlay
local miniPrev = getgenv().SpotifyMiniPrev
local miniNext = getgenv().SpotifyMiniNext
local miniExpand = getgenv().SpotifyMiniExpand

local barTitle = getgenv().SpotifyBarTitle
local barArtist = getgenv().SpotifyBarArtist
local barCoverGrad = getgenv().SpotifyBarCoverGrad
local miniCoverGrad = getgenv().SpotifyMiniCoverGrad
local miniTitle = getgenv().SpotifyMiniTitle
local miniArtist = getgenv().SpotifyMiniArtist

local plScroll = getgenv().SpotifyPlScroll
local navLiked = getgenv().SpotifyNavLiked
local navTop = getgenv().SpotifyNavTop
local sortBtn = getgenv().SpotifySortBtn
local addRow = getgenv().SpotifyAddRow
local topHint = getgenv().SpotifyTopHint

local markDirty = R.markDirty

-- ░░░░ ЛОГИКА СПИСКА ░░░░
local function currentList()
    if view.kind == "liked" then return state.liked end
    if view.kind == "top" then return getgenv().SpotifyTopList and getgenv().SpotifyTopList() or {} end
    if view.kind == "search" then return getgenv().SpotifySearchList and getgenv().SpotifySearchList() or {} end
    return state.playlists[view.index].tracks
end
getgenv().SpotifyCurrentList = currentList
R.currentList = currentList

local function isLiked(id)
    for _, t in ipairs(state.liked) do
        if t.id == id then return true end
    end
    return false
end
R.isLiked = isLiked

local function displayList()
    local list = currentList()
    if view.kind == "top" or view.kind == "search" or (getgenv().SpotifySort and getgenv().SpotifySort() == "manual") then
        return list
    end
    local sm = getgenv().SpotifySort and getgenv().SpotifySort() or "manual"
    local items = {}
    for i, t in ipairs(list) do
        items[i] = { t = t, i = i, k = lowerU(sm == "title" and (t.title or "") or (t.artist or "")) }
    end
    if sm == "newest" then
        table.sort(items, function(a, b) return a.i > b.i end)
    else
        table.sort(items, function(a, b)
            if a.k == b.k then return a.i < b.i end
            return a.k < b.k
        end)
    end
    local out = {}
    for i, it in ipairs(items) do out[i] = it.t end
    return out
end
R.displayList = displayList

-- ░░░░ РЕНДЕР СПИСКА ░░░░
local rows = {}
getgenv().SpotifyRows = rows

local function updateHearts()
    local current = R.current and R.current()
    for _, r in ipairs(rows) do
        r.heart.TextColor3 = isLiked(r.track.id) and Color3.fromRGB(30, 215, 96) or Color3.fromRGB(83, 83, 83)
    end
    barHeart.TextColor3 = (current and isLiked(current.id)) and Color3.fromRGB(30, 215, 96) or Color3.fromRGB(83, 83, 83)
end
R.updateHearts = updateHearts

local function refreshRowStates()
    local current = R.current and R.current()
    local sound = R.sound and R.sound()
    for i, r in ipairs(rows) do
        local active = current ~= nil and r.track.id == current.id
        r.title.TextColor3 = active and Color3.fromRGB(30, 215, 96) or Color3.fromRGB(255, 255, 255)
        r.num.TextColor3 = active and Color3.fromRGB(30, 215, 96) or Color3.fromRGB(179, 179, 179)
        r.num.Text = (active and sound and sound.IsPlaying) and "♪" or tostring(i)
    end
end
getgenv().SpotifyRefreshRowStates = refreshRowStates

local function removeFromView(track)
    local list
    if view.kind == "pl" then
        list = state.playlists[view.index].tracks
    elseif view.kind == "liked" then
        list = state.liked
    else
        return
    end
    for i, t in ipairs(list) do
        if t == track then
            table.remove(list, i)
            break
        end
    end
    markDirty()
    if R.renderList then R.renderList() end
    if R.renderBanner then R.renderBanner() end
end
R.removeFromView = removeFromView

function renderList()
    for _, r in ipairs(rows) do r.button:Destroy() end
    rows = {}
    local list = displayList()

    emptyLbl.Visible = false
    if view.kind == "top" then
        emptyLbl.Text = "Чарт недоступен в Delta (нужен сервер)"
        emptyLbl.Visible = true
    elseif #list == 0 then
        emptyLbl.Text = "Здесь пока пусто. Добавь трек по ID сверху."
        emptyLbl.Visible = true
    end

    for i, track in ipairs(list) do
        local btn = new("TextButton", {
            Text = "", Size = UDim2.new(1, -8, 0, 52),
            BackgroundColor3 = Color3.fromRGB(46, 46, 46), BackgroundTransparency = 1,
            AutoButtonColor = false, LayoutOrder = i, Parent = scroll,
        })
        corner(btn, 8)
        local num = label({ Text = tostring(i), TextColor3 = Color3.fromRGB(179, 179, 179), TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromOffset(40, 52), Parent = btn })

        local miniCover = new("Frame", {
            Position = UDim2.fromOffset(46, 9), Size = UDim2.fromOffset(34, 34),
            BackgroundColor3 = Color3.fromRGB(255, 255, 255), BorderSizePixel = 0, Parent = btn,
        })
        corner(miniCover, 5)
        new("UIGradient", {
            Color = ColorSequence.new(accent(track.id, 0.95), accent(track.id, 0.45)),
            Rotation = 45, Parent = miniCover,
        })
        label({ Text = "♪", Font = FONT_B, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = miniCover })

        local title = label({ Text = track.title or "Загрузка…", Font = FONT_B, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(90, 8), Size = UDim2.new(1, -230, 0, 20), Parent = btn })
        local artist = label({ Text = track.artist or "", TextSize = 12, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(90, 28), Size = UDim2.new(1, -230, 0, 16), Parent = btn })

        local function iconBtn(text, x, color)
            local b = new("TextButton", {
                Text = text, Font = FONT_B, TextSize = 18, TextColor3 = color or Color3.fromRGB(83, 83, 83),
                BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, x, 0.5, 0), Size = UDim2.fromOffset(30, 30), Parent = btn,
            })
            bouncy(b, 1.15)
            return b
        end
        local heart = iconBtn("♥", -86)
        local addB = iconBtn("+", -50, Color3.fromRGB(179, 179, 179))
        heart.Activated:Connect(function()
            if R.toggleLike then R.toggleLike(track) end
            pop(heart)
        end)
        addB.Activated:Connect(function()
            if R.openAddMenu then R.openAddMenu(track, addB) end
        end)

        if view.kind ~= "top" then
            local rm = iconBtn("✕", -14, Color3.fromRGB(179, 179, 179))
            rm.Activated:Connect(function() removeFromView(track) end)
        end

        btn.MouseEnter:Connect(function() tween(btn, 0.12, { BackgroundTransparency = 0 }) end)
        btn.MouseLeave:Connect(function() tween(btn, 0.12, { BackgroundTransparency = 1 }) end)
        btn.Activated:Connect(function()
            if R.playFromList then R.playFromList(list, i) end
        end)
        btn.MouseButton2Click:Connect(function()
            if R.openTrackMenu then R.openTrackMenu(track, list, i) end
        end)

        rows[i] = { button = btn, track = track, num = num, title = title, artist = artist, heart = heart }
    end
    updateHearts()
    refreshRowStates()
end
R.setRenderList(renderList)
getgenv().SpotifyRenderList = renderList

-- ░░░░ САЙДБАР ░░░░
local sideBtns = {}
getgenv().SpotifySideBtns = sideBtns

local function renderSidebar()
    navLiked.BackgroundTransparency = view.kind == "liked" and 0 or 1
    navTop.BackgroundTransparency = view.kind == "top" and 0 or 1

    local navLikedTx = getgenv().SpotifyNavLikedTx
    local navLikedIc = getgenv().SpotifyNavLikedIc
    local navTopTx = getgenv().SpotifyNavTopTx
    local navTopIc = getgenv().SpotifyNavTopIc

    if navLikedTx then navLikedTx.TextColor3 = view.kind == "liked" and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(179, 179, 179) end
    if navLikedIc then navLikedIc.TextColor3 = view.kind == "liked" and Color3.fromRGB(30, 215, 96) or Color3.fromRGB(179, 179, 179) end
    if navTopTx then navTopTx.TextColor3 = view.kind == "top" and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(179, 179, 179) end
    if navTopIc then navTopIc.TextColor3 = view.kind == "top" and Color3.fromRGB(30, 215, 96) or Color3.fromRGB(179, 179, 179) end

    for _, c in ipairs(plScroll:GetChildren()) do
        if c:IsA("GuiButton") then c:Destroy() end
    end
    sideBtns = {}
    getgenv().SpotifySideBtns = sideBtns
    for i, p in ipairs(state.playlists) do
        local active = view.kind == "pl" and view.index == i
        local b = new("TextButton", {
            Text = "", Size = UDim2.new(1, -6, 0, 38), bg = "elev",
            BackgroundTransparency = active and 0 or 1, AutoButtonColor = false, LayoutOrder = i, Parent = plScroll,
        })
        corner(b, 8)
        local ic = label({ Text = "♪", Font = FONT_B, TextSize = 16, tc = "sub", TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(6, 0), Size = UDim2.fromOffset(30, 38), Parent = b })
        local tx = label({ Text = p.name, Font = FONT_B, TextSize = 13, tc = active and "text" or "sub", TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(42, 0), Size = UDim2.new(1, -50, 1, 0), Parent = b })
        if active then ic.TextColor3 = Color3.fromRGB(30, 215, 96) end
        b.MouseEnter:Connect(function() if not active then tween(b, 0.12, { BackgroundTransparency = 0.7 }) end end)
        b.MouseLeave:Connect(function() if not active then tween(b, 0.12, { BackgroundTransparency = 1 }) end end)
        b.Activated:Connect(function()
            state.last = i
            markDirty()
            if R.setView then R.setView({ kind = "pl", index = i }) end
        end)
        if #state.playlists > 1 then
            local del = new("TextButton", {
                Text = "✕", Font = FONT_B, TextSize = 12, tc = "sub", BackgroundTransparency = 1,
                AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(46, 26), Parent = b,
            })
            del.Activated:Connect(function()
                table.remove(state.playlists, i)
                if view.kind == "pl" then
                    if view.index == i then view.index = 1
                    elseif view.index > i then view.index -= 1 end
                    state.last = view.index
                end
                markDirty()
                if R.setView then R.setView(view) end
            end)
        end
        sideBtns[i] = { btn = b, active = active }
    end
end
R.setRenderSidebar(renderSidebar)
getgenv().SpotifyRenderSidebar = renderSidebar

-- ░░░░ БАННЕР ░░░░
function renderBanner()
    local title, kind, icon, h
    if view.kind == "liked" then
        title, kind, icon, h = "Любимое", "ПЛЕЙЛИСТ", "♥", 0.72
    elseif view.kind == "top" then
        title, kind, icon, h = "Топ чарт", "НЕДОСТУПНО В DELTA", "🔥", 0.02
    elseif view.kind == "search" then
        title, kind, icon, h = "Поиск", "РЕЗУЛЬТАТЫ", "🔍", 0.55
    else
        local p = state.playlists[view.index]
        title, kind, icon, h = p.name, "ПЛЕЙЛИСТ", "♪", hueFor(p.name)
    end
    bannerTitle.Text = title
    bannerKind.Text = kind
    bannerIcon.Text = icon
    bannerSub.Text = pluralTracks(#currentList())
    tween(banner, 0.5, { BackgroundColor3 = accentH(h, 0.6, 0.6) })
    bannerCoverGrad.Color = ColorSequence.new(accentH(h, 0.95), accentH(h, 0.45))
    local editable = view.kind == "pl" or view.kind == "liked"
    addRow.Visible = editable
    sortBtn.Visible = editable
    topHint.Visible = view.kind == "top"
end
R.setRenderBanner(renderBanner)
getgenv().SpotifyRenderBanner = renderBanner

-- ░░░░ ВОСПРОИЗВЕДЕНИЕ ░░░░
local speed = 1
local sound, current
local queue, qi = {}, 0
local shuffle, repeatMode = false, 0
local playToken, failStreak = 0, 0
local badIds = {}

getgenv().SpotifySound = function() return sound end
getgenv().SpotifyCurrent = function() return current end
getgenv().SpotifyQueue = function() return queue end
getgenv().SpotifyQI = function() return qi end
getgenv().SpotifyShuffleMode = function() return shuffle end
getgenv().SpotifyRepeatMode = function() return repeatMode end
R.sound = function() return sound end
R.current = function() return current end

local function setVolume(a)
    state.volume = math.clamp(a, 0, 1)
    if getgenv().SpotifyApplyAudio then getgenv().SpotifyApplyAudio() end
    local volume = getgenv().SpotifyVolume
    if volume then volume.Set(state.volume) end
    markDirty()
end
R.setVolume = setVolume

local function setSpeed(v)
    speed = v
    if sound then sound.PlaybackSpeed = v end
end
R.setSpeed = setSpeed
getgenv().SpotifySpeed = function() return speed end

local function playAt(i, fadeSec)
    local track = queue[i]
    if not track then return end
    fadeSec = fadeSec or 0
    qi, current = i, track
    playToken += 1
    local my = playToken

    local old = sound
    local s = Instance.new("Sound")
    s.Name = "Track"
    s.SoundId = "rbxassetid://" .. track.id
    s.SoundGroup = SoundService:FindFirstChild("SpotifyBus")
    s.PlaybackSpeed = speed
    s.Looped = (repeatMode == 2)
    s.Volume = fadeSec > 0 and 0 or 1
    s.Parent = SoundService
    sound = s

    if old then
        if fadeSec > 0 and old.IsPlaying then
            local tw = tween(old, fadeSec, { Volume = 0 }, Enum.EasingStyle.Linear)
            tw.Completed:Connect(function() old:Destroy() end)
        else
            old:Destroy()
        end
    end
    if fadeSec > 0 then tween(s, fadeSec, { Volume = 1 }, Enum.EasingStyle.Linear) end

    s.Ended:Connect(function()
        if s == sound and my == playToken then
            if R.nextTrack then R.nextTrack(true, false) end
        end
    end)
    s:GetPropertyChangedSignal("IsPlaying"):Connect(function()
        if s == sound and R.updatePlayState then R.updatePlayState() end
    end)
    s:Play()
    if R.updateNowPlaying then R.updateNowPlaying() end

    task.spawn(function()
        local t0 = os.clock()
        while my == playToken and not s.IsLoaded and os.clock() - t0 < 8 do
            task.wait(0.1)
        end
        if my ~= playToken then return end
        if s.IsLoaded and s.TimeLength > 0 then
            failStreak = 0
        else
            badIds[track.id] = true
            failStreak += 1
            if R.notify then R.notify("Трек недоступен (нет прав на это аудио)") end
            if R.updateNowPlaying then R.updateNowPlaying() end
            if failStreak < #queue then
                task.wait(0.8)
                if my == playToken and R.nextTrack then R.nextTrack(true, false) end
            end
        end
    end)
end

local function playFromList(list, i)
    queue = {}
    for k, t in ipairs(list) do queue[k] = t end
    failStreak = 0
    playAt(i, math.min(state.crossfade, 0.8))
end
R.playFromList = playFromList

local function nextTrack(auto, early)
    local n = #queue
    if n == 0 then return end
    local fadeSec = early and state.crossfade or (auto and 0 or math.min(state.crossfade, 0.8))
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
                    if R.updatePlayState then R.updatePlayState() end
                    return
                end
            end
            if not badIds[queue[c].id] then
                target = c
                break
            end
        end
    end
    if target then playAt(target, fadeSec) end
end
R.nextTrack = nextTrack

local function prevTrack()
    if #queue == 0 then return end
    if sound and sound.TimePosition > 3 then
        sound.TimePosition = 0
        return
    end
    local c = qi - 1
    if c < 1 then c = #queue end
    playAt(c, math.min(state.crossfade, 0.8))
end
R.prevTrack = prevTrack

local function togglePlay()
    if not sound then
        local list = displayList()
        if #list > 0 then playFromList(list, shuffle and math.random(#list) or 1) end
    elseif sound.IsPlaying then
        sound:Pause()
    else
        sound:Play()
    end
end
R.togglePlay = togglePlay

-- Экспорт для 3B
getgenv().SpotifyPlayAt = playAt
getgenv().SpotifyPlayFromList = playFromList
getgenv().SpotifyNextTrack = nextTrack
getgenv().SpotifyPrevTrack = prevTrack
getgenv().SpotifyTogglePlay = togglePlay
getgenv().SpotifySetVolume = setVolume
getgenv().SpotifySetSpeed = setSpeed

print("✅ [Spotify Delta] Часть 3A — Рендер + Воспроизведение")
pcall(function()
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = "🎵 Spotify Player", Text = "⏳ Часть 3A загружена", Duration = 2
    })
end)

--[[
    SPOTIFY-ПЛЕЕР v3 — DELTA EDITION
    ЧАСТЬ 3B: UI обновления, view, like, метаданные, маркеры, попапы
]]

local R = getgenv().SpotifyRefs
if not R then warn("❌ Сначала запусти Часть 1!") return end
if not getgenv().SpotifyRenderList then warn("❌ Сначала запусти Часть 3A!") return end

local MarketplaceService = R.MarketplaceService
local new, corner, label, tween = R.new, R.corner, R.label, R.tween
local formatTime, isPointer = R.formatTime, R.isPointer
local pointer = R.pointer
local cutText = R.cutText
local bouncy, pop = R.bouncy, R.pop
local FONT, FONT_B, FONT_X = R.FONT, R.FONT_B, R.FONT_X
local W, H, SIDE_W, BAR_H = R.W, R.H, R.SIDE_W, R.BAR_H
local MAX_TRACKS = R.MAX_TRACKS

local state = R.state
local view = R.view

local markDirty = R.markDirty
local renderList = getgenv().SpotifyRenderList
local renderSidebar = getgenv().SpotifyRenderSidebar
local renderBanner = getgenv().SpotifyRenderBanner

-- Ссылки из 2A/2B/3A
local main = getgenv().SpotifyMain
local listWrap = getgenv().SpotifyListWrap
local rows = getgenv().SpotifyRows
local playBtn = getgenv().SpotifyPlayBtn
local bigPlay = getgenv().SpotifyBigPlay
local miniPlay = getgenv().SpotifyMiniPlay
local barTitle = getgenv().SpotifyBarTitle
local barArtist = getgenv().SpotifyBarArtist
local barCoverGrad = getgenv().SpotifyBarCoverGrad
local miniCoverGrad = getgenv().SpotifyMiniCoverGrad
local miniTitle = getgenv().SpotifyMiniTitle
local miniArtist = getgenv().SpotifyMiniArtist
local barHeart = getgenv().SpotifyBarHeart
local markerLayer = getgenv().SpotifyMarkerLayer
local searchClear = getgenv().SpotifySearchClear
local searchBox = getgenv().SpotifySearchBox

local accent = R.accent
local currentList = R.currentList
local isLiked = R.isLiked
local displayList = R.displayList
local updateHearts = R.updateHearts
local togglePlay = R.togglePlay
local playFromList = R.playFromList

-- ░░░░ ОБНОВЛЕНИЕ UI ░░░░
local function updatePlayState()
    local sound = getgenv().SpotifySound and getgenv().SpotifySound()
    local playing = sound ~= nil and sound.IsPlaying
    local g = playing and "II" or "▶"
    playBtn.Text = g
    bigPlay.Text = g
    if miniPlay then miniPlay.Text = g end
    if getgenv().SpotifyRefreshRowStates then getgenv().SpotifyRefreshRowStates() end
end
R.setUpdatePlayState(updatePlayState)
getgenv().SpotifyUpdatePlayState = updatePlayState

local function updateNowPlaying()
    local current = R.current and R.current()
    local t = current
    if t then
        barTitle.Text = t.title or "Загрузка…"
        barArtist.Text = t.artist or ""
        local cs = ColorSequence.new(accent(t.id, 0.95), accent(t.id, 0.45))
        barCoverGrad.Color = cs
        if miniCoverGrad then miniCoverGrad.Color = cs end
    else
        barTitle.Text = "Ничего не играет"
        barArtist.Text = "Выбери трек"
        local cs = ColorSequence.new(Color3.fromRGB(120, 120, 130), Color3.fromRGB(70, 70, 80))
        barCoverGrad.Color = cs
        if miniCoverGrad then miniCoverGrad.Color = cs end
    end
    if miniTitle then miniTitle.Text = barTitle.Text end
    if miniArtist then miniArtist.Text = barArtist.Text end
    updateHearts()
    updatePlayState()
end
R.setUpdateNowPlaying(updateNowPlaying)
getgenv().SpotifyUpdateNowPlaying = updateNowPlaying

local function refreshTexts()
    for _, r in ipairs(rows) do
        r.title.Text = r.track.title or "Загрузка…"
        r.artist.Text = r.track.artist or ""
    end
    local current = R.current and R.current()
    if current then
        barTitle.Text = current.title or "Загрузка…"
        barArtist.Text = current.artist or ""
        if miniTitle then miniTitle.Text = barTitle.Text end
        if miniArtist then miniArtist.Text = barArtist.Text end
    end
end
R.refreshTexts = refreshTexts
getgenv().SpotifyRefreshTexts = refreshTexts

-- ░░░░ SET VIEW ░░░░
local function setView(v)
    for k, val in pairs(v) do
        view[k] = val
    end
    if R.closePopups then R.closePopups() end
    renderSidebar()
    renderBanner()
    renderList()
    if listWrap then
        listWrap.GroupTransparency = 1
        listWrap.Position = UDim2.fromOffset(12, 218)
        tween(listWrap, 0.3, { GroupTransparency = 0, Position = UDim2.fromOffset(12, 208) }, Enum.EasingStyle.Quint)
    end
end
R.setView = setView
getgenv().SpotifySetView = setView

-- ░░░░ LIKE / UNLIKE ░░░░
local function toggleLike(track)
    for i, t in ipairs(state.liked) do
        if t.id == track.id then
            table.remove(state.liked, i)
            updateHearts()
            if view.kind == "liked" then
                renderList()
                renderBanner()
            end
            markDirty()
            if R.notify then R.notify("Убрано из любимого") end
            return
        end
    end
    if #state.liked >= MAX_TRACKS then
        if R.notify then R.notify("В любимом слишком много треков") end
        return
    end
    table.insert(state.liked, { id = track.id, title = track.title, artist = track.artist })
    updateHearts()
    if view.kind == "liked" then
        renderList()
        renderBanner()
    end
    markDirty()
    if R.notify then R.notify("Добавлено в любимое ♥") end
end
R.toggleLike = toggleLike
getgenv().SpotifyToggleLike = toggleLike

local function addToPlaylist(i, track)
    local p = state.playlists[i]
    if not p then return end
    for _, t in ipairs(p.tracks) do
        if t.id == track.id then
            if R.notify then R.notify("Уже есть в «" .. p.name .. "»") end
            return
        end
    end
    if #p.tracks >= MAX_TRACKS then
        if R.notify then R.notify("Плейлист заполнен") end
        return
    end
    table.insert(p.tracks, { id = track.id, title = track.title, artist = track.artist })
    if R.notify then R.notify("Добавлено в «" .. p.name .. "»") end
    markDirty()
    if view.kind == "pl" and view.index == i then
        renderList()
        renderBanner()
    end
end
getgenv().SpotifyAddToPlaylist = addToPlaylist

-- ░░░░ МЕТАДАННЫЕ ░░░░
local metaCache = {}
local function fetchInfo(track)
    local c = metaCache[track.id]
    if not c then
        local ok, info = pcall(function()
            return MarketplaceService:GetProductInfo(track.id, Enum.InfoType.Asset)
        end)
        if ok and info then
            c = {
                title = cutText(tostring(info.Name), 60),
                artist = cutText(info.Creator and tostring(info.Creator.Name) or "—", 40),
            }
            metaCache[track.id] = c
        else
            c = { title = "Трек " .. track.id, artist = "—" }
        end
    end
    track.title = track.title or c.title
    track.artist = track.artist or c.artist
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
getgenv().SpotifyHydrateTitles = hydrateTitles

-- ░░░░ МАРКЕРЫ ░░░░
local markerBtns = {}
getgenv().SpotifyMarkerBtns = markerBtns

local function markersFor(track, create)
    local key = tostring(track.id)
    local list = state.markers[key]
    if not list and create then
        list = {}
        state.markers[key] = list
    end
    return list
end

local function rebuildMarkers()
    for _, b in ipairs(markerBtns) do b:Destroy() end
    markerBtns = {}
    getgenv().SpotifyMarkerBtns = markerBtns
    local current = R.current and R.current()
    local sound = getgenv().SpotifySound and getgenv().SpotifySound()
    if not current or not sound or sound.TimeLength <= 0 then return end
    local list = markersFor(current, false)
    if not list then return end
    local len = sound.TimeLength
    for i, sec in ipairs(list) do
        local a = math.clamp(sec / len, 0, 1)
        local b = new("TextButton", {
            Text = "", BackgroundColor3 = Color3.fromRGB(255, 196, 0), AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(a, 0, 0.5, 0), Size = UDim2.fromOffset(6, 13),
            AutoButtonColor = false, ZIndex = 7, Parent = markerLayer,
        })
        corner(b, 2)
        b.Activated:Connect(function()
            if sound then sound.TimePosition = sec end
        end)
        b.MouseButton2Click:Connect(function()
            table.remove(list, i)
            if #list == 0 then state.markers[tostring(current.id)] = nil end
            markDirty()
            rebuildMarkers()
            if R.notify then R.notify("Маркер удалён") end
        end)
        markerBtns[#markerBtns + 1] = b
    end
end
R.rebuildMarkers = rebuildMarkers
getgenv().SpotifyRebuildMarkers = rebuildMarkers

local function addMarker(sec)
    local current = R.current and R.current()
    local sound = getgenv().SpotifySound and getgenv().SpotifySound()
    if not (current and sound and sound.TimeLength > 0) then
        if R.notify then R.notify("Сначала включи трек") end
        return
    end
    sec = sec or sound.TimePosition
    sec = math.floor(sec * 10) / 10
    local list = markersFor(current, true)
    if #list >= 20 then
        if R.notify then R.notify("Максимум 20 маркеров на трек") end
        return
    end
    table.insert(list, sec)
    table.sort(list)
    markDirty()
    rebuildMarkers()
    if R.notify then R.notify("⚑ Маркер " .. formatTime(sec)) end
end
R.addMarker = addMarker
getgenv().SpotifyAddMarker = addMarker

-- ░░░░ ПОПАПЫ ░░░░
local blocker = new("TextButton", {
    Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 40, Parent = main,
})
getgenv().SpotifyBlocker = blocker

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

local menu = new("CanvasGroup", {
    Size = UDim2.fromOffset(230, 200), bg = "elev", Visible = false, ZIndex = 50, Parent = main,
})
corner(menu, 10)
local menuTitle = label({ Text = "", Font = FONT_B, TextSize = 13, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(14, 8), Size = UDim2.new(1, -28, 0, 22), Parent = menu })
local menuList = new("ScrollingFrame", {
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
    Position = UDim2.fromOffset(6, 34), Size = UDim2.new(1, -12, 1, -40),
    CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = menu,
})
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = menuList })
getgenv().SpotifyMenu = menu
getgenv().SpotifyMenuTitle = menuTitle
getgenv().SpotifyMenuList = menuList

local function openMenu(title, items, at)
    menuTitle.Text = title
    for _, c in ipairs(menuList:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    for i, item in ipairs(items) do
        local b = new("TextButton", {
            Text = "  " .. item.text, Font = FONT, TextSize = 14, TextColor3 = item.color or Color3.fromRGB(255, 255, 255),
            TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
            BackgroundColor3 = Color3.fromRGB(62, 62, 62), BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 0, 32), AutoButtonColor = false, LayoutOrder = i, Parent = menuList,
        })
        corner(b, 6)
        b.MouseEnter:Connect(function() tween(b, 0.1, { BackgroundTransparency = 0 }) end)
        b.MouseLeave:Connect(function() tween(b, 0.1, { BackgroundTransparency = 1 }) end)
        b.Activated:Connect(function()
            if R.closePopups then R.closePopups() end
            item.fn()
        end)
    end
    local h = math.min(280, 44 + #items * 34)
    menu.Size = UDim2.fromOffset(230, h)
    local rel = (at - main.AbsolutePosition)
    local x = math.clamp(rel.X - 180, 8, W - 238)
    local y = math.clamp(rel.Y + 28, 40, H - BAR_H - h - 4)
    menu.Position = UDim2.fromOffset(x, y)
    blocker.Visible = true
    showPopup(menu)
end
R.openMenu = openMenu
getgenv().SpotifyOpenMenu = openMenu

local function openAddMenu(track, anchor)
    local items = {}
    for i, p in ipairs(state.playlists) do
        items[#items + 1] = { text = p.name, fn = function() addToPlaylist(i, track) end }
    end
    local at = pointer()
    openMenu("Добавить в плейлист", items, at)
end
R.openAddMenu = openAddMenu
getgenv().SpotifyOpenAddMenu = openAddMenu

local function openTrackMenu(track, list, idx)
    local items = {
        { text = "▶  Играть", fn = function() playFromList(list, idx) end },
        { text = "⏭  Играть следующим", fn = function()
            local queue = getgenv().SpotifyQueue and getgenv().SpotifyQueue() or {}
            local qi = getgenv().SpotifyQI and getgenv().SpotifyQI() or 0
            if #queue == 0 then playFromList({ track }, 1)
            else table.insert(queue, qi + 1, track); if R.notify then R.notify("Будет играть следующим") end end
        end },
        { text = isLiked(track.id) and "♥  Убрать из любимого" or "♥  В любимое", fn = function() toggleLike(track) end },
        { text = "＋  В плейлист…", fn = function() openAddMenu(track, nil) end },
    }
    if view.kind == "pl" or view.kind == "liked" then
        items[#items + 1] = { text = "✕  Убрать из списка", color = Color3.fromRGB(240, 80, 80), fn = function()
            if R.removeFromView then R.removeFromView(track) end
        end }
    end
    items[#items + 1] = { text = "ⓘ  ID: " .. track.id, fn = function()
        if R.notify then R.notify("ID: " .. track.id) end
    end }
    openMenu(track.title or "Трек", items, pointer())
end
R.openTrackMenu = openTrackMenu
getgenv().SpotifyOpenTrackMenu = openTrackMenu

-- closePopups
local function closePopups()
    hidePopup(eqPopupRef)
    hidePopup(keysPopupRef)
    hidePopup(menu)
    if blocker then blocker.Visible = false end
end
R.closePopups = closePopups
getgenv().SpotifyClosePopups = closePopups

blocker.Activated:Connect(closePopups)

-- ссылки на попапы (создаются в 3C)
local eqPopupRef
local keysPopupRef
getgenv().SpotifySetPopups = function(eqP, keysP)
    eqPopupRef = eqP
    keysPopupRef = keysP
end
getgenv().SpotifyShowPopup = showPopup
getgenv().SpotifyHidePopup = hidePopup
getgenv().SpotifyBlocker = blocker

print("✅ [Spotify Delta] Часть 3B — UI обновления + попапы")
pcall(function()
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = "🎵 Spotify Player", Text = "⏳ Часть 3B загружена", Duration = 2
    })
end)

--[[
    SPOTIFY-ПЛЕЕР v3 — DELTA EDITION
    ЧАСТЬ 3C-1: Настройки звука + попапы
]]

local R = getgenv().SpotifyRefs
if not R then warn("❌ Сначала запусти Часть 1!") return end
if not getgenv().SpotifyRenderList then warn("❌ Сначала запусти Часть 3A!") return end
if not getgenv().SpotifyOpenMenu then warn("❌ Сначала запусти Часть 3B!") return end

local new, corner, label, tween = R.new, R.corner, R.label, R.tween
local bouncy = R.bouncy
local FONT, FONT_B, FONT_X = R.FONT, R.FONT_B, R.FONT_X
local W, H, SIDE_W, BAR_H = R.W, R.H, R.SIDE_W, R.BAR_H

local state = R.state
local view = R.view
local markDirty = R.markDirty
local setSpeed = R.setSpeed
local closePopups = R.closePopups

local main = getgenv().SpotifyMain
local eqBtn = getgenv().SpotifyEqBtn
local keysBtn = getgenv().SpotifyKeysBtn

local ACTIONS = getgenv().SpotifyActions
local KEYNAMES = getgenv().SpotifyKeyNames
local keyOf = getgenv().SpotifyKeyOf

-- ░░░░ UI MODE ░░░░
local uiMode, lastShown = "hidden", "full"
getgenv().SpotifyUiMode = function() return uiMode end
getgenv().SpotifyLastShown = function() return lastShown end
getgenv().SpotifySetUiModeVars = function(m, l)
    uiMode = m
    lastShown = l
end

-- ░░░░ ТЕМА ░░░░
local function applyTheme()
    local THEMES = {
        dark = {
            bg = Color3.fromRGB(18, 18, 18), side = Color3.fromRGB(0, 0, 0), panel = Color3.fromRGB(24, 24, 24),
            elev = Color3.fromRGB(40, 40, 40), hover = Color3.fromRGB(46, 46, 46), elev2 = Color3.fromRGB(83, 83, 83),
            chip = Color3.fromRGB(62, 62, 62), text = Color3.fromRGB(255, 255, 255), sub = Color3.fromRGB(179, 179, 179),
            green = Color3.fromRGB(30, 215, 96), red = Color3.fromRGB(240, 80, 80), ink = Color3.fromRGB(18, 18, 18),
            marker = Color3.fromRGB(255, 196, 0),
        },
        light = {
            bg = Color3.fromRGB(250, 250, 252), side = Color3.fromRGB(238, 238, 243), panel = Color3.fromRGB(255, 255, 255),
            elev = Color3.fromRGB(230, 230, 236), hover = Color3.fromRGB(236, 236, 241), elev2 = Color3.fromRGB(176, 176, 188),
            chip = Color3.fromRGB(220, 220, 228), text = Color3.fromRGB(22, 22, 26), sub = Color3.fromRGB(100, 100, 112),
            green = Color3.fromRGB(24, 176, 80), red = Color3.fromRGB(214, 48, 48), ink = Color3.fromRGB(255, 255, 255),
            marker = Color3.fromRGB(230, 150, 0),
        },
    }
    local newC = THEMES[state.theme] or THEMES.dark
    local themed = R.themed
    if themed then
        for _, item in ipairs(themed) do
            local inst, prop, role = item[1], item[2], item[3]
            if inst and inst.Parent and newC[role] then
                inst[prop] = newC[role]
            end
        end
    end
end
R.applyTheme = applyTheme
getgenv().SpotifyApplyTheme = applyTheme

-- ░░░░ ПОПАП НАСТРОЕК ЗВУКА ░░░░
local eqPopup = new("CanvasGroup", {
    AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -BAR_H - 8),
    Size = UDim2.fromOffset(290, 364), bg = "elev", Visible = false, ZIndex = 50, Parent = main,
})
corner(eqPopup, 12)
label({ Text = "Звук и эффекты", Font = FONT_B, TextSize = 16, Position = UDim2.fromOffset(20, 14), Size = UDim2.new(1, -40, 0, 22), Parent = eqPopup })

local function popLabel(text, y)
    return label({ Text = text, TextSize = 13, tc = "sub", Position = UDim2.fromOffset(20, y), Size = UDim2.fromOffset(160, 18), Parent = eqPopup })
end
local function popValue(y)
    return label({ Text = "", Font = FONT_B, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right, Position = UDim2.fromOffset(190, y), Size = UDim2.fromOffset(80, 18), Parent = eqPopup })
end

popLabel("Усиление баса", 50)
local bassVal = popValue(50)
popLabel("Кроссфейд между треками", 102)
local xfVal = popValue(102)
popLabel("Скорость", 154)
popLabel("Реверберация", 224)
popLabel("Пресеты", 262)

local function chip(parent, text, x, y, w)
    local b = new("TextButton", {
        Text = text, Font = FONT_B, TextSize = 12, tc = "text", bg = "chip",
        Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, 30), AutoButtonColor = false, Parent = parent,
    })
    corner(b, 15)
    bouncy(b, 1.05)
    return b
end
local function chipActive(b, on)
    tween(b, 0.15, { BackgroundColor3 = on and Color3.fromRGB(30, 215, 96) or Color3.fromRGB(62, 62, 62) })
    b.TextColor3 = on and Color3.fromRGB(18, 18, 18) or Color3.fromRGB(255, 255, 255)
end

local speedChips = {}
for i, s in ipairs({ { 0.8, "0.8×" }, { 1, "1×" }, { 1.25, "1.25×" } }) do
    speedChips[i] = { btn = chip(eqPopup, s[2], 20 + (i - 1) * 86, 178, 78), value = s[1] }
end

local function refreshSpeedChips()
    local speed = getgenv().SpotifySpeed and getgenv().SpotifySpeed() or 1
    for _, c in ipairs(speedChips) do chipActive(c.btn, c.value == speed) end
end
getgenv().SpotifyRefreshSpeedChips = refreshSpeedChips

for _, c in ipairs(speedChips) do
    c.btn.Activated:Connect(function()
        setSpeed(c.value)
        refreshSpeedChips()
    end)
end

-- Реверб-переключатель
local sw = new("TextButton", {
    Text = "", bg = "chip", Position = UDim2.fromOffset(226, 223), Size = UDim2.fromOffset(44, 22),
    AutoButtonColor = false, Parent = eqPopup,
})
corner(sw, 11)
local swKnob = new("Frame", {
    AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), Size = UDim2.fromOffset(16, 16),
    BackgroundColor3 = Color3.fromRGB(255, 255, 255), BorderSizePixel = 0, Parent = sw,
})
corner(swKnob, 8)

-- Слайдеры bass / crossfade
local function setBass(a, fromSlider)
    state.bass = a
    if getgenv().SpotifyApplyAudio then getgenv().SpotifyApplyAudio() end
    bassVal.Text = math.floor(a * 100 + 0.5) .. "%"
    if not fromSlider and bassSlider then bassSlider.Set(a) end
    markDirty()
end

local function setCrossfade(sec, fromSlider)
    sec = math.clamp(math.floor(sec + 0.5), 0, 12)
    state.crossfade = sec
    xfVal.Text = sec == 0 and "Выкл" or (sec .. " с")
    if not fromSlider and xfSlider then xfSlider.Set(sec / 12) end
    markDirty()
end

local function setReverb(v, instant)
    state.reverb = v
    if getgenv().SpotifyApplyAudio then getgenv().SpotifyApplyAudio() end
    local t = instant and 0 or 0.2
    tween(sw, t, { BackgroundColor3 = v and Color3.fromRGB(30, 215, 96) or Color3.fromRGB(62, 62, 62) })
    tween(swKnob, t, { Position = v and UDim2.new(1, -19, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) }, Enum.EasingStyle.Back)
    markDirty()
end
getgenv().SpotifySetReverb = setReverb
getgenv().SpotifySetBass = setBass
getgenv().SpotifySetCrossfade = setCrossfade

local bassSlider = getgenv().SpotifyMakeSlider(eqPopup, UDim2.fromOffset(20, 78), UDim2.fromOffset(250, 6), state.bass, function(a) setBass(a, true) end)
local xfSlider = getgenv().SpotifyMakeSlider(eqPopup, UDim2.fromOffset(20, 130), UDim2.fromOffset(250, 6), state.crossfade / 12, function(a) setCrossfade(a * 12, true) end)

sw.Activated:Connect(function() setReverb(not state.reverb) end)

-- Пресеты
local PRESETS = {
    { "Обычный", 0, 1, false }, { "Бас", 0.6, 1, false }, { "Супер бас", 1, 1, false },
    { "Slowed", 0.3, 0.85, true }, { "Nightcore", 0.2, 1.25, false },
}
for i, p in ipairs(PRESETS) do
    local col, rowI = (i - 1) % 3, math.floor((i - 1) / 3)
    local c = chip(eqPopup, p[1], 20 + col * 86, 286 + rowI * 36, 78)
    c.Activated:Connect(function()
        setBass(p[2])
        setSpeed(p[3])
        setReverb(p[4])
        refreshSpeedChips()
        if R.notify then R.notify("Пресет: " .. p[1]) end
    end)
end

-- ░░░░ ПОПАП ГОРЯЧИХ КЛАВИШ ░░░░
local keysPopup = new("CanvasGroup", {
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(400, 470), bg = "elev", Visible = false, ZIndex = 50, Parent = main,
})
corner(keysPopup, 14)
label({ Text = "Горячие клавиши", Font = FONT_B, TextSize = 17, Position = UDim2.fromOffset(20, 14), Size = UDim2.new(1, -40, 0, 24), Parent = keysPopup })
label({ Text = "Нажми клавишу, потом назначь новую. Backspace — снять.", TextSize = 11, tc = "sub", TextWrapped = true, Position = UDim2.fromOffset(20, 40), Size = UDim2.new(1, -40, 0, 32), Parent = keysPopup })

local keysList = new("ScrollingFrame", {
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
    Position = UDim2.fromOffset(12, 78), Size = UDim2.new(1, -24, 1, -130),
    CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = keysPopup,
})
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = keysList })

local keysReset = chip(keysPopup, "Сбросить всё", 20, 428, 120)
local keysClose = chip(keysPopup, "Закрыть", 280, 428, 100)

-- Передаём попапы в 3B
if getgenv().SpotifySetPopups then
    getgenv().SpotifySetPopups(eqPopup, keysPopup)
end

local listening
local function refreshKeys()
    for _, c in ipairs(keysList:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    for i, a in ipairs(ACTIONS) do
        local row = new("Frame", { Size = UDim2.new(1, -8, 0, 32), BackgroundTransparency = 1, LayoutOrder = i, Parent = keysList })
        label({ Text = a.name, TextSize = 13, Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -120, 1, 0), Parent = row })
        local waiting = listening == a.id
        local k = keyOf(a.id)
        local keyText = waiting and "нажми…" or (k and (KEYNAMES[k.Name] or k.Name) or "—")
        local kb = new("TextButton", {
            Text = keyText, Font = FONT_B, TextSize = 12,
            TextColor3 = waiting and Color3.fromRGB(18, 18, 18) or Color3.fromRGB(255, 255, 255),
            BackgroundColor3 = waiting and Color3.fromRGB(30, 215, 96) or Color3.fromRGB(62, 62, 62),
            AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0.5, 0),
            Size = UDim2.fromOffset(96, 26), AutoButtonColor = false, Parent = row,
        })
        corner(kb, 13)
        kb.Activated:Connect(function()
            listening = a.id
            refreshKeys()
        end)
    end
end
R.refreshKeys = refreshKeys
getgenv().SpotifyRefreshKeys = refreshKeys
getgenv().SpotifyGetListening = function() return listening end
getgenv().SpotifySetListening = function(v) listening = v end

keysReset.Activated:Connect(function()
    state.binds = {}
    listening = nil
    refreshKeys()
    markDirty()
    if R.notify then R.notify("Клавиши сброшены") end
end)
keysClose.Activated:Connect(closePopups)

getgenv().SpotifyEqPopup = eqPopup
getgenv().SpotifyKeysPopup = keysPopup

-- ░░░░ ОТКРЫТИЕ ПОПАПОВ ░░░░
local showPopup = getgenv().SpotifyShowPopup
local blocker = getgenv().SpotifyBlocker

eqBtn.Activated:Connect(function()
    if eqPopup.Visible and eqPopup.GroupTransparency < 0.5 then
        closePopups()
    else
        closePopups()
        showPopup(eqPopup)
        blocker.Visible = true
    end
end)

keysBtn.Activated:Connect(function()
    closePopups()
    refreshKeys()
    showPopup(keysPopup)
    blocker.Visible = true
end)

print("✅ [Spotify Delta] Часть 3C-1 — Настройки звука + попапы")
pcall(function()
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = "🎵 Spotify Player", Text = "⏳ Часть 3C-1 загружена", Duration = 2
    })
end)

--[[
    SPOTIFY-ПЛЕЕР v3 — DELTA EDITION
    ЧАСТЬ 3C-2: Кнопки + финал
]]

local R = getgenv().SpotifyRefs
if not R then warn("❌ Сначала запусти Часть 1!") return end
if not getgenv().SpotifySetReverb then warn("❌ Сначала запусти Часть 3C-1!") return end

local UserInputService = R.UserInputService
local RunService = R.RunService
local MarketplaceService = R.MarketplaceService
local new, corner, label, tween = R.new, R.corner, R.label, R.tween
local bouncy = R.bouncy
local formatTime = R.formatTime
local cutText, lowerU = R.cutText, R.lowerU
local FONT, FONT_B, FONT_X = R.FONT, R.FONT_B, R.FONT_X
local W, H, SIDE_W, BAR_H = R.W, R.H, R.SIDE_W, R.BAR_H

local state = R.state
local view = R.view
local markDirty = R.markDirty
local setView = R.setView
local togglePlay = R.togglePlay
local playFromList = R.playFromList
local nextTrack = R.nextTrack
local prevTrack = R.prevTrack
local toggleLike = R.toggleLike
local addMarker = R.addMarker
local closePopups = R.closePopups

local main = getgenv().SpotifyMain
local gui = getgenv().SpotifyGui
local root = getgenv().SpotifyRoot

local ACTIONS = getgenv().SpotifyActions
local keyOf = getgenv().SpotifyKeyOf

local playBtn = getgenv().SpotifyPlayBtn
local bigPlay = getgenv().SpotifyBigPlay
local miniPlay = getgenv().SpotifyMiniPlay
local prevBtn = getgenv().SpotifyPrevBtn
local nextBtn = getgenv().SpotifyNextBtn
local miniPrev = getgenv().SpotifyMiniPrev
local miniNext = getgenv().SpotifyMiniNext
local miniExpand = getgenv().SpotifyMiniExpand
local shuffleBtn = getgenv().SpotifyShuffleBtn
local repeatBtn = getgenv().SpotifyRepeatBtn
local markBtn = getgenv().SpotifyMarkBtn
local barHeart = getgenv().SpotifyBarHeart

local closeBtn = getgenv().SpotifyCloseBtn
local toggleBtn = getgenv().SpotifyToggleBtn
local themeBtn = getgenv().SpotifyThemeBtn
local miniBtn = getgenv().SpotifyMiniBtn

local plAddBtn = getgenv().SpotifyPlAddBtn
local plNameBox = getgenv().SpotifyPlNameBox
local sidebarLayout = getgenv().SpotifySidebarLayout

local navLiked = getgenv().SpotifyNavLiked
local navTop = getgenv().SpotifyNavTop

local sortBtn = getgenv().SpotifySortBtn
local searchBox = getgenv().SpotifySearchBox
local searchClear = getgenv().SpotifySearchClear
local addBox = getgenv().SpotifyAddBox
local addBtn = getgenv().SpotifyAddBtn

local miniRoot = getgenv().SpotifyMiniRoot
local miniScale = getgenv().SpotifyMiniScale
local miniFill = getgenv().SpotifyMiniFill
local miniCoverScale = getgenv().SpotifyMiniCoverScale

local progress = getgenv().SpotifyProgress
local curTime = getgenv().SpotifyCurTime
local totTime = getgenv().SpotifyTotTime
local bars = getgenv().SpotifyVisBars
local barCoverScale = getgenv().SpotifyBarCoverScale
local bannerCoverScale = getgenv().SpotifyBannerCoverScale
local barCoverGrad = getgenv().SpotifyBarCoverGrad
local bannerCoverGrad = getgenv().SpotifyBannerCoverGrad

local setMode = R.setMode
local getUiMode = getgenv().SpotifyUiMode
local getLastShown = getgenv().SpotifyLastShown
local setUiModeVars = getgenv().SpotifySetUiModeVars
local applyTheme = R.applyTheme
local refreshSpeedChips = getgenv().SpotifyRefreshSpeedChips
local setReverb = getgenv().SpotifySetReverb

-- ░░░░ КНОПКИ УПРАВЛЕНИЯ ░░░░
playBtn.Activated:Connect(togglePlay)
bigPlay.Activated:Connect(togglePlay)
miniPlay.Activated:Connect(togglePlay)

nextBtn.Activated:Connect(function() nextTrack(false) end)
prevBtn.Activated:Connect(prevTrack)
miniNext.Activated:Connect(function() nextTrack(false) end)
miniPrev.Activated:Connect(prevTrack)

shuffleBtn.Activated:Connect(function()
    local sh = getgenv().SpotifyShuffleMode and getgenv().SpotifyShuffleMode() or false
    state.shuffle = not sh
    shuffleBtn.TextColor3 = state.shuffle and Color3.fromRGB(30, 215, 96) or Color3.fromRGB(179, 179, 179)
end)

repeatBtn.Activated:Connect(function()
    local rm = (getgenv().SpotifyRepeatMode and getgenv().SpotifyRepeatMode() or 0)
    if getgenv().SpotifySetRepeat then getgenv().SpotifySetRepeat((rm + 1) % 3) end
end)

markBtn.Activated:Connect(function() addMarker() end)

barHeart.Activated:Connect(function()
    local current = R.current and R.current()
    if current then
        toggleLike(current)
        if R.pop then R.pop(barHeart) end
    end
end)

closeBtn.Activated:Connect(function()
    local m = getUiMode()
    if m == "full" or m == "mini" then
        setMode("hidden")
    else
        setMode(getLastShown())
    end
end)

toggleBtn.Activated:Connect(function()
    if getUiMode() == "hidden" then
        setMode(getLastShown())
    else
        setMode("hidden")
    end
end)

miniExpand.Activated:Connect(function() setMode("full") end)
miniBtn.Activated:Connect(function() setMode("mini") end)

themeBtn.Activated:Connect(function()
    state.theme = state.theme == "dark" and "light" or "dark"
    applyTheme()
    markDirty()
    if R.notify then R.notify("Тема: " .. state.theme) end
end)

-- ░░░░ СОЗДАНИЕ ПЛЕЙЛИСТА ░░░░
plAddBtn.Activated:Connect(function()
    plNameBox.Visible = not plNameBox.Visible
    sidebarLayout()
    if plNameBox.Visible then plNameBox:CaptureFocus() end
end)

plNameBox.FocusLost:Connect(function(enter)
    local name = plNameBox.Text:match("^%s*(.-)%s*$")
    if enter and name ~= "" then
        if #state.playlists >= R.MAX_PLAYLISTS then
            if R.notify then R.notify("Максимум плейлистов: " .. R.MAX_PLAYLISTS) end
        else
            table.insert(state.playlists, { name = cutText(name, 24), tracks = {} })
            state.last = #state.playlists
            markDirty()
            setView({ kind = "pl", index = #state.playlists })
            if R.notify then R.notify("Плейлист создан") end
        end
    end
    plNameBox.Text = ""
    plNameBox.Visible = false
    sidebarLayout()
end)

-- ░░░░ ДОБАВЛЕНИЕ ТРЕКА ПО ID ░░░░
local function addTrackFromBox()
    local id = tonumber(addBox.Text:match("%d+") or "")
    addBox.Text = ""
    if not id or id < 1 or id >= 1e15 then
        if R.notify then R.notify("Введи числовой ID аудио") end
        return
    end
    local list = R.currentList()
    for _, t in ipairs(list) do
        if t.id == id then
            if R.notify then R.notify("Этот трек уже здесь") end
            return
        end
    end
    if #list >= R.MAX_TRACKS then
        if R.notify then R.notify("Список заполнен") end
        return
    end
    local track = { id = id }
    table.insert(list, track)
    if R.renderList then R.renderList() end
    if R.renderBanner then R.renderBanner() end
    markDirty()
    task.spawn(function()
        local ok, info = pcall(function()
            return MarketplaceService:GetProductInfo(id, Enum.InfoType.Asset)
        end)
        if ok and info then
            track.title = cutText(tostring(info.Name), 60)
            track.artist = cutText(info.Creator and tostring(info.Creator.Name) or "—", 40)
        else
            track.title = "Трек " .. id
            track.artist = "—"
        end
        if R.refreshTexts then R.refreshTexts() end
        markDirty()
    end)
    local scroll = getgenv().SpotifyScroll
    if scroll then
        task.defer(function()
            scroll.CanvasPosition = Vector2.new(0, math.huge)
        end)
    end
end
addBtn.Activated:Connect(addTrackFromBox)
addBox.FocusLost:Connect(function(enter)
    if enter then addTrackFromBox() end
end)

-- ░░░░ ПОИСК ░░░░
local function buildSearch(q)
    q = lowerU(q)
    local out, seen = {}, {}
    local function scan(list)
        for _, t in ipairs(list) do
            if not seen[t.id] then
                if lowerU(t.title or ""):find(q, 1, true)
                    or lowerU(t.artist or ""):find(q, 1, true)
                    or tostring(t.id):find(q, 1, true) then
                    seen[t.id] = true
                    out[#out + 1] = t
                end
            end
        end
    end
    scan(state.liked)
    for _, p in ipairs(state.playlists) do scan(p.tracks) end
    return out
end
R.buildSearch = buildSearch
getgenv().SpotifyBuildSearch = buildSearch

searchBox:GetPropertyChangedSignal("Text"):Connect(function()
    local q = searchBox.Text
    if q == "" then
        searchClear.Visible = false
        if view.kind == "search" then
            setView({ kind = "pl", index = state.last or 1 })
        end
    else
        searchClear.Visible = true
        local sl = buildSearch(q)
        local ref = getgenv().SpotifySearchList()
        for i = 1, #sl do
            ref[i] = sl[i]
        end
        for i = #sl + 1, #ref do ref[i] = nil end
        setView({ kind = "search" })
    end
end)

searchClear.Activated:Connect(function()
    searchBox.Text = ""
    searchClear.Visible = false
    if view.kind == "search" then
        setView({ kind = "pl", index = state.last or 1 })
    end
end)

-- ░░░░ СОРТИРОВКА ░░░░
local SORTS = { "manual", "title", "artist", "newest" }
local SORT_NAMES = { manual = "Мой порядок", title = "Название А–Я", artist = "Исполнитель А–Я", newest = "Сначала новые" }

sortBtn.Activated:Connect(function()
    local sm = getgenv().SpotifySort and getgenv().SpotifySort() or "manual"
    local idx = 1
    for i, s in ipairs(SORTS) do
        if s == sm then idx = i; break end
    end
    local nextSort = SORTS[idx % #SORTS + 1]
    if R.setSort then R.setSort(nextSort) end
    sortBtn.Text = "⇅ " .. SORT_NAMES[nextSort]
    if R.renderList then R.renderList() end
end)

-- ░░░░ НАВИГАЦИЯ ░░░░
navLiked.Activated:Connect(function() setView({ kind = "liked" }) end)
navTop.Activated:Connect(function() setView({ kind = "top" }) end)

-- ░░░░ ДЕЙСТВИЯ ГОРЯЧИХ КЛАВИШ ░░░░
local function runAction(a)
    if a == "toggle" then
        if getUiMode() == "hidden" then setMode(getLastShown()) else setMode("hidden") end
    elseif a == "mini" then
        if getUiMode() == "mini" then setMode("full") else setMode("mini") end
    elseif a == "play" then togglePlay()
    elseif a == "next" then nextTrack(false)
    elseif a == "prev" then prevTrack()
    elseif a == "volup" then
        state.volume = math.clamp(state.volume + 0.1, 0, 1)
        if getgenv().SpotifyApplyAudio then getgenv().SpotifyApplyAudio() end
        local v = getgenv().SpotifyVolume
        if v then v.Set(state.volume) end
        markDirty()
    elseif a == "voldown" then
        state.volume = math.clamp(state.volume - 0.1, 0, 1)
        if getgenv().SpotifyApplyAudio then getgenv().SpotifyApplyAudio() end
        local v = getgenv().SpotifyVolume
        if v then v.Set(state.volume) end
        markDirty()
    elseif a == "seekf" then
        local s = getgenv().SpotifySound and getgenv().SpotifySound()
        if s then s.TimePosition = math.min(s.TimeLength, s.TimePosition + 10) end
    elseif a == "seekb" then
        local s = getgenv().SpotifySound and getgenv().SpotifySound()
        if s then s.TimePosition = math.max(0, s.TimePosition - 10) end
    elseif a == "like" then
        local c = R.current and R.current()
        if c then toggleLike(c) end
    elseif a == "shuffle" then
        state.shuffle = not (getgenv().SpotifyShuffleMode and getgenv().SpotifyShuffleMode() or false)
        shuffleBtn.TextColor3 = state.shuffle and Color3.fromRGB(30, 215, 96) or Color3.fromRGB(179, 179, 179)
    elseif a == "marker" then addMarker()
    elseif a == "theme" then
        state.theme = state.theme == "dark" and "light" or "dark"
        applyTheme()
        markDirty()
        if R.notify then R.notify("Тема: " .. state.theme) end
    elseif a == "search" then
        if view.kind ~= "search" then searchBox:CaptureFocus() end
    end
end
R.runAction = runAction
getgenv().SpotifyRunAction = runAction

-- ░░░░ ОБРАБОТЧИК КЛАВИШ ░░░░
UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end

    local getListening = getgenv().SpotifyGetListening
    local setListening = getgenv().SpotifySetListening
    local listening = getListening and getListening() or nil

    if input.KeyCode == Enum.KeyCode.Escape and listening then
        setListening(nil)
        getgenv().SpotifyRefreshKeys()
        return
    end

    if listening then
        if input.KeyCode == Enum.KeyCode.Backspace then
            state.binds[listening] = "None"
        elseif input.KeyCode == Enum.KeyCode.Escape then
            setListening(nil)
            getgenv().SpotifyRefreshKeys()
            return
        else
            state.binds[listening] = input.KeyCode.Name
        end
        setListening(nil)
        getgenv().SpotifyRefreshKeys()
        markDirty()
        return
    end

    for _, a in ipairs(ACTIONS) do
        local k = keyOf(a.id)
        if k and input.KeyCode == k then
            runAction(a.id)
            break
        end
    end
end)

-- ░░░░ АНИМАЦИЯ КАЖДЫЙ КАДР ░░░░
local smooth = 0
RunService.RenderStepped:Connect(function(dt)
    if getUiMode() == "hidden" then return end
    local s = getgenv().SpotifySound and getgenv().SpotifySound()
    local playing = s ~= nil and s.IsPlaying
    local loud = playing and math.clamp(s.PlaybackLoudness / 350, 0, 1) or 0
    smooth += (loud - smooth) * math.min(1, dt * 12)

    local t = os.clock()
    for i, b in ipairs(bars) do
        local wob = 0.55 + 0.45 * math.sin(t * (3 + i * 0.37) + i)
        local targetH = 4 + smooth * 70 * wob
        local cur = b.Size.Y.Offset
        b.Size = UDim2.fromOffset(6, cur + (targetH - cur) * math.min(1, dt * 18))
    end

    if bannerCoverScale then bannerCoverScale.Scale = 1 + smooth * 0.05 end
    if barCoverScale then barCoverScale.Scale = 1 + smooth * 0.09 end
    if miniCoverScale then miniCoverScale.Scale = 1 + smooth * 0.07 end
    if playing then
        if barCoverGrad then barCoverGrad.Rotation = (barCoverGrad.Rotation + dt * 40) % 360 end
        if bannerCoverGrad then bannerCoverGrad.Rotation = (bannerCoverGrad.Rotation + dt * 25) % 360 end
    end

    if s and s.TimeLength > 0 then
        if progress and not progress.IsDragging() then
            progress.Set(s.TimePosition / s.TimeLength)
            if curTime then curTime.Text = formatTime(s.TimePosition) end
        end
        if totTime then totTime.Text = formatTime(s.TimeLength) end
        if miniFill then miniFill.Size = UDim2.fromScale(s.TimePosition / s.TimeLength, 1) end
    else
        if progress then progress.Set(0) end
        if curTime then curTime.Text = "0:00" end
        if totTime then totTime.Text = "0:00" end
        if miniFill then miniFill.Size = UDim2.fromScale(0, 1) end
    end
end)

-- ░░░░ ФИНАЛИЗАЦИЯ ░░░░
if getgenv().SpotifyApplyAudio then getgenv().SpotifyApplyAudio() end
local bassVal = getgenv().SpotifyBassVal
local xfVal = getgenv().SpotifyXfVal
if bassVal then bassVal.Text = math.floor(state.bass * 100 + 0.5) .. "%" end
if xfVal then xfVal.Text = state.crossfade == 0 and "Выкл" or (state.crossfade .. " с") end
setReverb(state.reverb, true)
refreshSpeedChips()

if getgenv().SpotifyRenderSidebar then getgenv().SpotifyRenderSidebar() end
if getgenv().SpotifyRenderBanner then getgenv().SpotifyRenderBanner() end
if getgenv().SpotifyRenderList then getgenv().SpotifyRenderList() end
if getgenv().SpotifyHydrateTitles then getgenv().SpotifyHydrateTitles() end
setMode("full")

-- Выгрузка через Delete
UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.Delete then
        pcall(function()
            local s = getgenv().SpotifySound and getgenv().SpotifySound()
            if s then s:Stop(); s:Destroy() end
            if gui then gui:Destroy() end
            getgenv().SpotifyGui = nil
            getgenv().SpotifyRefs = nil
        end)
    end
end)

pcall(function()
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = "🎵 Spotify Player v3",
        Text = "✅ Загружено! M — открыть/скрыть, N — мини",
        Duration = 5
    })
end)

print([[
╔══════════════════════════════════════════╗
║   🎵 SPOTIFY-ПЛЕЕР v3 DELTA EDITION 🎵   ║
║   ─────────────────────────────          ║
║   M — открыть/скрыть                     ║
║   N — мини-режим                         ║
║   P — пауза/играть                       ║
║   ← → — перемотка ( [ ] )                ║
║   ↑ ↓ — громкость ( = - )                ║
║   H — в любимое                          ║
║   V — маркер                             ║
║   Y — тема                               ║
║   / — поиск                              ║
║   Delete — выгрузить                     ║
╚══════════════════════════════════════════╝
]])
