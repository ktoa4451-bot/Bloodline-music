--[[
    ╔══════════════════════════════════════════╗
    ║      BLOODLINE MUSIC v3.0                ║
    ║      ЧАСТЬ 1/2: Ядро + GUI               ║
    ║      Spotify-style • 2026 API            ║
    ╚══════════════════════════════════════════╝
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local LP = Players.LocalPlayer
if not LP then
    repeat task.wait(0.1) until Players.LocalPlayer
    LP = Players.LocalPlayer
end

local PlayerGui = LP:FindFirstChild("PlayerGui") or LP:WaitForChild("PlayerGui", 10)
if not PlayerGui then warn("[Bloodline] PlayerGui не найден") return end

-- Чистим старую версию
if getgenv().BloodlineMusicGui then
    pcall(function() getgenv().BloodlineMusicGui:Destroy() end)
end
if getgenv().BloodlineMusicConns then
    for _, c in pairs(getgenv().BloodlineMusicConns) do
        pcall(function() c:Disconnect() end)
    end
end
getgenv().BloodlineMusicConns = {}

-- Проверка File API
local HAS_FILE_API = false
pcall(function()
    HAS_FILE_API = (typeof(writefile) == "function" and typeof(readfile) == "function")
end)

-- ============ ПАЛИТРА (Spotify style) ============
local COLORS = {
    bg = Color3.fromRGB(18, 18, 18),
    panel = Color3.fromRGB(24, 24, 24),
    card = Color3.fromRGB(30, 30, 30),
    cardHover = Color3.fromRGB(40, 40, 40),
    text = Color3.fromRGB(255, 255, 255),
    textDim = Color3.fromRGB(179, 179, 179),
    textMuted = Color3.fromRGB(120, 120, 120),
    accent = Color3.fromRGB(30, 215, 96),
    accentDark = Color3.fromRGB(20, 160, 70),
    playbar = Color3.fromRGB(24, 24, 24),
    border = Color3.fromRGB(45, 45, 45),
    sidebar = Color3.fromRGB(0, 0, 0),
}
getgenv().BloodlineMusicColors = COLORS

-- ============ СОСТОЯНИЕ ============
getgenv().BloodlineMusicState = getgenv().BloodlineMusicState or {
    playlist = {},
    history = {},
    favorites = {},
    currentIndex = 0,
    currentTrack = nil,
    loop = "none",       -- "none" | "one" | "all"
    shuffle = false,
    volume = 3,
    playing = false,
    eq = { bass = 0, mid = 0, treble = 0 },
}
local State = getgenv().BloodlineMusicState

-- ============ СОХРАНЕНИЕ ============
local function LoadSaved()
    if not HAS_FILE_API then return end
    pcall(function()
        if isfolder and isfolder("BloodlineMusic") then
            if isfile("BloodlineMusic/playlist.json") then
                State.playlist = HttpService:JSONDecode(readfile("BloodlineMusic/playlist.json"))
            end
            if isfile("BloodlineMusic/history.json") then
                State.history = HttpService:JSONDecode(readfile("BloodlineMusic/history.json"))
            end
            if isfile("BloodlineMusic/favorites.json") then
                State.favorites = HttpService:JSONDecode(readfile("BloodlineMusic/favorites.json"))
            end
        end
    end)
end

local function SaveAll()
    if not HAS_FILE_API then return end
    pcall(function()
        if not isfolder("BloodlineMusic") then makefolder("BloodlineMusic") end
        writefile("BloodlineMusic/playlist.json", HttpService:JSONEncode(State.playlist))
        writefile("BloodlineMusic/history.json", HttpService:JSONEncode(State.history))
        writefile("BloodlineMusic/favorites.json", HttpService:JSONEncode(State.favorites))
    end)
end
getgenv().BloodlineMusicSaveAll = SaveAll

LoadSaved()

-- ============ GUI ============
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "BloodlineMusic"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.IgnoreGuiInset = true
ScreenGui.DisplayOrder = 999
pcall(function() ScreenGui.Parent = PlayerGui end)
getgenv().BloodlineMusicGui = ScreenGui

-- Главное окно
local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 900, 0, 560)
MainFrame.Position = UDim2.new(0.5, -450, 0.5, -280)
MainFrame.BackgroundColor3 = COLORS.bg
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.ZIndex = 2
MainFrame.Parent = ScreenGui

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 10)
MainCorner.Parent = MainFrame

local MainStroke = Instance.new("UIStroke")
MainStroke.Color = COLORS.border
MainStroke.Thickness = 1
MainStroke.Parent = MainFrame

-- ============ САЙДБАР ============
local Sidebar = Instance.new("Frame")
Sidebar.Name = "Sidebar"
Sidebar.Size = UDim2.new(0, 200, 1, -90)
Sidebar.Position = UDim2.new(0, 0, 0, 0)
Sidebar.BackgroundColor3 = COLORS.sidebar
Sidebar.BorderSizePixel = 0
Sidebar.ZIndex = 3
Sidebar.Parent = MainFrame
local SidebarC = Instance.new("UICorner")
SidebarC.CornerRadius = UDim.new(0, 10)
SidebarC.Parent = Sidebar

local LogoRow = Instance.new("Frame")
LogoRow.Size = UDim2.new(1, -20, 0, 60)
LogoRow.Position = UDim2.new(0, 10, 0, 10)
LogoRow.BackgroundTransparency = 1
LogoRow.ZIndex = 4
LogoRow.Parent = Sidebar

local LogoIcon = Instance.new("TextLabel")
LogoIcon.Size = UDim2.new(0, 40, 0, 40)
LogoIcon.Position = UDim2.new(0, 8, 0, 10)
LogoIcon.BackgroundTransparency = 1
LogoIcon.Text = "🎵"
LogoIcon.TextSize = 26
LogoIcon.Font = Enum.Font.GothamBold
LogoIcon.ZIndex = 5
LogoIcon.Parent = LogoRow

local LogoText = Instance.new("TextLabel")
LogoText.Size = UDim2.new(1, -60, 0, 40)
LogoText.Position = UDim2.new(0, 55, 0, 10)
LogoText.BackgroundTransparency = 1
LogoText.Text = "Bloodline"
LogoText.TextColor3 = COLORS.text
LogoText.TextSize = 18
LogoText.Font = Enum.Font.GothamBold
LogoText.TextXAlignment = Enum.TextXAlignment.Left
LogoText.ZIndex = 5
LogoText.Parent = LogoRow

local SideMenu = Instance.new("Frame")
SideMenu.Size = UDim2.new(1, -20, 0, 260)
SideMenu.Position = UDim2.new(0, 10, 0, 75)
SideMenu.BackgroundTransparency = 1
SideMenu.ZIndex = 4
SideMenu.Parent = Sidebar

local SideMenuLayout = Instance.new("UIListLayout")
SideMenuLayout.Padding = UDim.new(0, 4)
SideMenuLayout.SortOrder = Enum.SortOrder.LayoutOrder
SideMenuLayout.Parent = SideMenu

local function CreateSidebarItem(text, icon)
    local Btn = Instance.new("TextButton")
    Btn.Size = UDim2.new(1, 0, 0, 40)
    Btn.BackgroundColor3 = COLORS.panel
    Btn.BackgroundTransparency = 1
    Btn.Text = ""
    Btn.AutoButtonColor = false
    Btn.ZIndex = 5
    Btn.Parent = SideMenu
    local C = Instance.new("UICorner")
    C.CornerRadius = UDim.new(0, 6)
    C.Parent = Btn

    local Ico = Instance.new("TextLabel")
    Ico.Size = UDim2.new(0, 30, 1, 0)
    Ico.Position = UDim2.new(0, 8, 0, 0)
    Ico.BackgroundTransparency = 1
    Ico.Text = icon
    Ico.TextSize = 16
    Ico.Font = Enum.Font.GothamBold
    Ico.TextXAlignment = Enum.TextXAlignment.Center
    Ico.ZIndex = 6
    Ico.Parent = Btn

    local Lbl = Instance.new("TextLabel")
    Lbl.Size = UDim2.new(1, -45, 1, 0)
    Lbl.Position = UDim2.new(0, 42, 0, 0)
    Lbl.BackgroundTransparency = 1
    Lbl.Text = text
    Lbl.TextColor3 = COLORS.textDim
    Lbl.TextSize = 13
    Lbl.Font = Enum.Font.GothamMedium
    Lbl.TextXAlignment = Enum.TextXAlignment.Left
    Lbl.ZIndex = 6
    Lbl.Parent = Btn

    Btn.MouseEnter:Connect(function()
        pcall(function()
            TweenService:Create(Btn, TweenInfo.new(0.15), {BackgroundTransparency = 0.7}):Play()
        end)
    end)
    Btn.MouseLeave:Connect(function()
        pcall(function()
            TweenService:Create(Btn, TweenInfo.new(0.15), {BackgroundTransparency = 1}):Play()
        end)
    end)
    return Btn
end

-- ============ ГЛАВНАЯ ОБЛАСТЬ ============
local ContentArea = Instance.new("Frame")
ContentArea.Name = "ContentArea"
ContentArea.Size = UDim2.new(1, -210, 1, -90)
ContentArea.Position = UDim2.new(0, 210, 0, 0)
ContentArea.BackgroundColor3 = COLORS.panel
ContentArea.BorderSizePixel = 0
ContentArea.ClipsDescendants = true
ContentArea.ZIndex = 3
ContentArea.Parent = MainFrame
local ContentAreaC = Instance.new("UICorner")
ContentAreaC.CornerRadius = UDim.new(0, 10)
ContentAreaC.Parent = ContentArea

local ContentHeader = Instance.new("Frame")
ContentHeader.Size = UDim2.new(1, 0, 0, 60)
ContentHeader.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
ContentHeader.BorderSizePixel = 0
ContentHeader.ZIndex = 4
ContentHeader.Parent = ContentArea
local ContentHeaderC = Instance.new("UICorner")
ContentHeaderC.CornerRadius = UDim.new(0, 10)
ContentHeaderC.Parent = ContentHeader
local ContentHeaderMask = Instance.new("Frame")
ContentHeaderMask.Size = UDim2.new(1, 0, 0, 20)
ContentHeaderMask.Position = UDim2.new(0, 0, 1, -20)
ContentHeaderMask.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
ContentHeaderMask.BorderSizePixel = 0
ContentHeaderMask.ZIndex = 4
ContentHeaderMask.Parent = ContentHeader

local ContentTitle = Instance.new("TextLabel")
ContentTitle.Size = UDim2.new(1, -20, 1, 0)
ContentTitle.Position = UDim2.new(0, 20, 0, 0)
ContentTitle.BackgroundTransparency = 1
ContentTitle.Text = "🏠 Главная"
ContentTitle.TextColor3 = COLORS.text
ContentTitle.TextSize = 18
ContentTitle.Font = Enum.Font.GothamBold
ContentTitle.TextXAlignment = Enum.TextXAlignment.Left
ContentTitle.ZIndex = 5
ContentTitle.Parent = ContentHeader

-- Страницы
local pages = {}

local function CreatePage(name)
    local Page = Instance.new("ScrollingFrame")
    Page.Name = name
    Page.Size = UDim2.new(1, -20, 1, -80)
    Page.Position = UDim2.new(0, 10, 0, 70)
    Page.BackgroundTransparency = 1
    Page.BorderSizePixel = 0
    Page.ScrollBarThickness = 4
    Page.ScrollBarImageColor3 = COLORS.textMuted
    Page.CanvasSize = UDim2.new(0, 0, 0, 0)
    Page.Visible = false
    Page.ZIndex = 4
    Page.Parent = ContentArea

    local L = Instance.new("UIListLayout")
    L.Padding = UDim.new(0, 6)
    L.SortOrder = Enum.SortOrder.LayoutOrder
    L.Parent = Page
    L:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        Page.CanvasSize = UDim2.new(0, 0, 0, L.AbsoluteContentSize.Y + 20)
    end)

    return Page
end

local PageHome = CreatePage("Home")
local PagePlaylist = CreatePage("Playlist")
local PageHistory = CreatePage("History")
local PageFavorites = CreatePage("Favorites")
local PageEQ = CreatePage("EQ")
local PageSettings = CreatePage("Settings")

local allPages = {PageHome, PagePlaylist, PageHistory, PageFavorites, PageEQ, PageSettings}

local function SwitchPage(idx, title)
    for i, p in ipairs(allPages) do
        p.Visible = (i == idx)
    end
    ContentTitle.Text = title or ("🎵 " .. allPages[idx].Name)
end

local SideHome = CreateSidebarItem("Главная", "🏠")
local SidePlaylist = CreateSidebarItem("Плейлист", "📋")
local SideHistory = CreateSidebarItem("История", "🕐")
local SideFavorites = CreateSidebarItem("Избранное", "⭐")
local SideEQ = CreateSidebarItem("Эквалайзер", "🎛")
local SideSettings = CreateSidebarItem("Настройки", "⚙")

SideHome.MouseButton1Click:Connect(function() SwitchPage(1, "🏠 Главная") end)
SidePlaylist.MouseButton1Click:Connect(function() SwitchPage(2, "📋 Плейлист") end)
SideHistory.MouseButton1Click:Connect(function() SwitchPage(3, "🕐 История") end)
SideFavorites.MouseButton1Click:Connect(function() SwitchPage(4, "⭐ Избранное") end)
SideEQ.MouseButton1Click:Connect(function() SwitchPage(5, "🎛 Эквалайзер") end)
SideSettings.MouseButton1Click:Connect(function() SwitchPage(6, "⚙ Настройки") end)

-- ============ НИЖНЯЯ ПАНЕЛЬ (плеер) ============
local PlayerBar = Instance.new("Frame")
PlayerBar.Name = "PlayerBar"
PlayerBar.Size = UDim2.new(1, -20, 0, 80)
PlayerBar.Position = UDim2.new(0, 10, 1, -85)
PlayerBar.BackgroundColor3 = COLORS.playbar
PlayerBar.BorderSizePixel = 0
PlayerBar.ZIndex = 5
PlayerBar.Parent = MainFrame
local PlayerBarC = Instance.new("UICorner")
PlayerBarC.CornerRadius = UDim.new(0, 8)
PlayerBarC.Parent = PlayerBar

-- Инфо о треке (слева)
local TrackInfo = Instance.new("Frame")
TrackInfo.Size = UDim2.new(0, 250, 1, -20)
TrackInfo.Position = UDim2.new(0, 10, 0, 10)
TrackInfo.BackgroundTransparency = 1
TrackInfo.ZIndex = 6
TrackInfo.Parent = PlayerBar

local TrackCover = Instance.new("Frame")
TrackCover.Size = UDim2.new(0, 60, 0, 60)
TrackCover.Position = UDim2.new(0, 0, 0, 0)
TrackCover.BackgroundColor3 = COLORS.card
TrackCover.BorderSizePixel = 0
TrackCover.ZIndex = 7
TrackCover.Parent = TrackInfo
local TrackCoverC = Instance.new("UICorner")
TrackCoverC.CornerRadius = UDim.new(0, 6)
TrackCoverC.Parent = TrackCover

local TrackCoverIcon = Instance.new("TextLabel")
TrackCoverIcon.Size = UDim2.new(1, 0, 1, 0)
TrackCoverIcon.BackgroundTransparency = 1
TrackCoverIcon.Text = "🎵"
TrackCoverIcon.TextSize = 30
TrackCoverIcon.Font = Enum.Font.GothamBold
TrackCoverIcon.TextColor3 = COLORS.accent
TrackCoverIcon.ZIndex = 8
TrackCoverIcon.Parent = TrackCover

local TrackName = Instance.new("TextLabel")
TrackName.Size = UDim2.new(1, -75, 0, 22)
TrackName.Position = UDim2.new(0, 70, 0, 8)
TrackName.BackgroundTransparency = 1
TrackName.Text = "Ничего не играет"
TrackName.TextColor3 = COLORS.text
TrackName.TextSize = 13
TrackName.Font = Enum.Font.GothamBold
TrackName.TextXAlignment = Enum.TextXAlignment.Left
TrackName.TextTruncate = Enum.TextTruncate.AtEnd
TrackName.ZIndex = 6
TrackName.Parent = TrackInfo

local TrackArtist = Instance.new("TextLabel")
TrackArtist.Size = UDim2.new(1, -75, 0, 18)
TrackArtist.Position = UDim2.new(0, 70, 0, 32)
TrackArtist.BackgroundTransparency = 1
TrackArtist.Text = "Bloodline Radio"
TrackArtist.TextColor3 = COLORS.textDim
TrackArtist.TextSize = 11
TrackArtist.Font = Enum.Font.Gotham
TrackArtist.TextXAlignment = Enum.TextXAlignment.Left
TrackArtist.TextTruncate = Enum.TextTruncate.AtEnd
TrackArtist.ZIndex = 6
TrackArtist.Parent = TrackInfo

-- Управление (центр)
local Controls = Instance.new("Frame")
Controls.Size = UDim2.new(0, 300, 1, -20)
Controls.Position = UDim2.new(0.5, -150, 0, 10)
Controls.BackgroundTransparency = 1
Controls.ZIndex = 6
Controls.Parent = PlayerBar

local ControlsLayout = Instance.new("UIListLayout")
ControlsLayout.FillDirection = Enum.FillDirection.Horizontal
ControlsLayout.Padding = UDim.new(0, 8)
ControlsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
ControlsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
ControlsLayout.Parent = Controls

local function MakeControlBtn(text, size, color, callback)
    local Btn = Instance.new("TextButton")
    Btn.Size = UDim2.new(0, size, 0, size)
    Btn.BackgroundColor3 = color or COLORS.card
    Btn.Text = text
    Btn.TextColor3 = COLORS.text
    Btn.TextSize = 16
    Btn.Font = Enum.Font.GothamBold
    Btn.AutoButtonColor = false
    Btn.ZIndex = 7
    Btn.Parent = Controls
    local C = Instance.new("UICorner")
    C.CornerRadius = UDim.new(1, 0)
    C.Parent = Btn
    Btn.MouseButton1Click:Connect(function()
        if callback then pcall(callback) end
    end)
    return Btn
end

local ShuffleBtn = MakeControlBtn("🔀", 36, COLORS.card)
local PrevBtn = MakeControlBtn("⏮", 40, COLORS.card)
local PlayBtn = MakeControlBtn("▶", 50, COLORS.accent)
PlayBtn.TextColor3 = Color3.fromRGB(0, 0, 0)
local NextBtn = MakeControlBtn("⏭", 40, COLORS.card)
local LoopBtn = MakeControlBtn("🔁", 36, COLORS.card)

-- Громкость (справа)
local VolumeArea = Instance.new("Frame")
VolumeArea.Size = UDim2.new(0, 200, 1, -20)
VolumeArea.Position = UDim2.new(1, -210, 0, 10)
VolumeArea.BackgroundTransparency = 1
VolumeArea.ZIndex = 6
VolumeArea.Parent = PlayerBar

local VolIcon = Instance.new("TextLabel")
VolIcon.Size = UDim2.new(0, 25, 1, 0)
VolIcon.BackgroundTransparency = 1
VolIcon.Text = "🔊"
VolIcon.TextSize = 16
VolIcon.Font = Enum.Font.GothamBold
VolIcon.ZIndex = 7
VolIcon.Parent = VolumeArea

local VolBar = Instance.new("Frame")
VolBar.Size = UDim2.new(1, -35, 0, 6)
VolBar.Position = UDim2.new(0, 30, 0.5, -3)
VolBar.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
VolBar.BorderSizePixel = 0
VolBar.ZIndex = 7
VolBar.Parent = VolumeArea
local VBC = Instance.new("UICorner")
VBC.CornerRadius = UDim.new(1, 0)
VBC.Parent = VolBar

local VolFill = Instance.new("Frame")
VolFill.Size = UDim2.new(State.volume / 10, 0, 1, 0)
VolFill.BackgroundColor3 = COLORS.accent
VolFill.BorderSizePixel = 0
VolFill.ZIndex = 8
VolFill.Parent = VolBar
local VFC = Instance.new("UICorner")
VFC.CornerRadius = UDim.new(1, 0)
VFC.Parent = VolFill

local volDragging = false
VolBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        volDragging = true
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        volDragging = false
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if volDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local m = UserInputService:GetMouseLocation()
        local bp = VolBar.AbsolutePosition
        local bs = VolBar.AbsoluteSize
        local rel = math.clamp((m.X - bp.X) / bs.X, 0, 1)
        VolFill.Size = UDim2.new(rel, 0, 1, 0)
        State.volume = rel * 10
        if getgenv().BloodlineCurrentSound then
            pcall(function() getgenv().BloodlineCurrentSound.Volume = State.volume end)
        end
    end
end)

-- ============ СОХРАНЯЕМ ССЫЛКИ ДЛЯ ЧАСТИ 2 ============
getgenv().BloodlineMusicBase = {
    ScreenGui = ScreenGui,
    MainFrame = MainFrame,
    Sidebar = Sidebar,
    ContentArea = ContentArea,
    ContentTitle = ContentTitle,
    PlayerBar = PlayerBar,
    TrackCover = TrackCover,
    TrackCoverIcon = TrackCoverIcon,
    TrackName = TrackName,
    TrackArtist = TrackArtist,
    PlayBtn = PlayBtn,
    PrevBtn = PrevBtn,
    NextBtn = NextBtn,
    ShuffleBtn = ShuffleBtn,
    LoopBtn = LoopBtn,
    VolFill = VolFill,
    VolBar = VolBar,
    Pages = allPages,
    PageHome = PageHome,
    PagePlaylist = PagePlaylist,
    PageHistory = PageHistory,
    PageFavorites = PageFavorites,
    PageEQ = PageEQ,
    PageSettings = PageSettings,
    SwitchPage = SwitchPage,
    Colors = COLORS,
    State = State,
    HasFileAPI = HAS_FILE_API,
    LP = LP,
    Players = Players,
    RunService = RunService,
    UserInputService = UserInputService,
    TweenService = TweenService,
    Workspace = Workspace,
    HttpService = HttpService,
    SaveAll = SaveAll,
}

-- Хоткей F3
table.insert(getgenv().BloodlineMusicConns, UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.F3 then
        MainFrame.Visible = not MainFrame.Visible
    end
end))

pcall(function()
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = "🎵 Bloodline Music",
        Text = "✅ Часть 1/2 загружена",
        Duration = 3
    })
end)

print("✅ [Bloodline Music v3.0] Часть 1/2 — Ядро + GUI + Плеер-бар")

--[[
    ╔══════════════════════════════════════════╗
    ║      BLOODLINE MUSIC v3.0                ║
    ║      ЧАСТЬ 2/2: Логика + Эквалайзер      ║
    ╚══════════════════════════════════════════╝
]]

local B = getgenv().BloodlineMusicBase
if not B then warn("❌ Сначала запусти Часть 1!") return end

local State = B.State
local COLORS = B.Colors
local LP = B.LP
local Players = B.Players
local Workspace = B.Workspace
local TweenService = B.TweenService
local RunService = B.RunService
local HttpService = B.HttpService
local SaveAll = B.SaveAll

local PageHome = B.PageHome
local PagePlaylist = B.PagePlaylist
local PageHistory = B.PageHistory
local PageFavorites = B.PageFavorites
local PageEQ = B.PageEQ
local PageSettings = B.PageSettings

-- ============ ПАПКА ДЛЯ ЗВУКОВ ============
local musicFolder = Workspace:FindFirstChild("BloodlineMusic")
if not musicFolder then
    musicFolder = Instance.new("Folder")
    musicFolder.Name = "BloodlineMusic"
    musicFolder.Parent = Workspace
end

-- ============ УТИЛИТЫ ============
local function NormalizeId(input)
    input = tostring(input):gsub("%s", "")
    if input == "" then return nil end
    if input:match("^%d+$") then return "rbxassetid://" .. input end
    if input:match("rbxassetid://") then return input end
    if input:match("^https?://") then
        local id = input:match("(%d+)")
        if id then return "rbxassetid://" .. id end
    end
    return "rbxassetid://" .. input
end

-- Проверка доступности ID (через ContentProvider)
local function IsIdAccessible(id)
    local ok, result = pcall(function()
        return game:GetService("ContentProvider"):PreloadAsync({id})
    end)
    return ok
end

-- ============ ВОСПРОИЗВЕДЕНИЕ ============
local currentSound = nil
getgenv().BloodlineCurrentSound = nil

local function UpdatePlayerUI()
    if State.currentTrack then
        B.TrackName.Text = State.currentTrack.name or State.currentTrack.id or "Без названия"
        B.TrackArtist.Text = "Bloodline Music"
    else
        B.TrackName.Text = "Ничего не играет"
        B.TrackArtist.Text = "Bloodline Music"
    end
    B.PlayBtn.Text = State.playing and "⏸" or "▶"
end

local function PlayTrack(track)
    if not track or not track.id then return end

    -- Стоп предыдущего
    if currentSound then
        pcall(function() currentSound:Stop(); currentSound:Destroy() end)
        currentSound = nil
        getgenv().BloodlineCurrentSound = nil
    end

    local id = NormalizeId(track.id)
    if not id then return end

    pcall(function()
        local sound = Instance.new("Sound")
        sound.Name = "BloodlineTrack_" .. LP.Name
        sound.SoundId = id
        sound.Volume = State.volume
        sound.Looped = (State.loop == "one")

        -- 2026 API: огромный радиус для слышимости всеми
        sound.RollOffMode = Enum.RollOffMode.Inverse
        sound.RollOffMaxDistance = 100000
        sound.RollOffMinDistance = 1

        sound.Parent = musicFolder
        sound:Play()
        currentSound = sound
        getgenv().BloodlineCurrentSound = sound

        State.currentTrack = track
        State.playing = true

        -- В историю
        table.insert(State.history, 1, track)
        if #State.history > 50 then
            State.history = {unpack(State.history, 1, 50)}
        end
        SaveAll()

        UpdatePlayerUI()
        RefreshHistory()

        -- Автопереход
        sound.Ended:Connect(function()
            if State.loop == "one" then
                PlayTrack(track)
            elseif State.loop == "all" then
                local nextIdx = State.currentIndex % math.max(1, #State.playlist) + 1
                State.currentIndex = nextIdx
                if State.playlist[nextIdx] then PlayTrack(State.playlist[nextIdx]) end
            elseif State.shuffle and #State.playlist > 0 then
                local idx = math.random(1, #State.playlist)
                State.currentIndex = idx
                PlayTrack(State.playlist[idx])
            else
                State.playing = false
                UpdatePlayerUI()
            end
        end)
    end)
end

-- ============ КНОПКИ ПЛЕЕРА ============
B.PlayBtn.MouseButton1Click:Connect(function()
    if State.playing then
        if currentSound then pcall(function() currentSound:Pause() end) end
        State.playing = false
        UpdatePlayerUI()
    else
        if currentSound and currentSound.IsPaused then
            pcall(function() currentSound:Resume() end)
            State.playing = true
        elseif State.currentTrack then
            PlayTrack(State.currentTrack)
        elseif #State.playlist > 0 then
            State.currentIndex = 1
            PlayTrack(State.playlist[1])
        end
        UpdatePlayerUI()
    end
end)

B.PrevBtn.MouseButton1Click:Connect(function()
    if #State.playlist == 0 then return end
    State.currentIndex = math.max(1, State.currentIndex - 1)
    PlayTrack(State.playlist[State.currentIndex])
end)

B.NextBtn.MouseButton1Click:Connect(function()
    if #State.playlist == 0 then return end
    if State.shuffle then
        State.currentIndex = math.random(1, #State.playlist)
    else
        State.currentIndex = math.min(#State.playlist, State.currentIndex + 1)
    end
    PlayTrack(State.playlist[State.currentIndex])
end)

B.ShuffleBtn.MouseButton1Click:Connect(function()
    State.shuffle = not State.shuffle
    B.ShuffleBtn.TextColor3 = State.shuffle and COLORS.accent or COLORS.text
end)

B.LoopBtn.MouseButton1Click:Connect(function()
    if State.loop == "none" then
        State.loop = "all"
        B.LoopBtn.Text = "🔁"
        B.LoopBtn.TextColor3 = COLORS.accent
    elseif State.loop == "all" then
        State.loop = "one"
        B.LoopBtn.Text = "🔂"
        B.LoopBtn.TextColor3 = COLORS.accent
    else
        State.loop = "none"
        B.LoopBtn.Text = "🔁"
        B.LoopBtn.TextColor3 = COLORS.text
    end
end)

-- ============ КОМПОНЕНТЫ ДЛЯ СТРАНИЦ ============
local function CreateCard(parent)
    local Frame = Instance.new("Frame")
    Frame.Size = UDim2.new(1, 0, 0, 56)
    Frame.BackgroundColor3 = COLORS.card
    Frame.BorderSizePixel = 0
    Frame.ZIndex = 5
    Frame.Parent = parent
    local C = Instance.new("UICorner")
    C.CornerRadius = UDim.new(0, 8)
    C.Parent = Frame
    return Frame
end

local function CreateSmallBtn(parent, text, color, size, callback)
    local Btn = Instance.new("TextButton")
    Btn.Size = size or UDim2.new(0, 34, 0, 34)
    Btn.BackgroundColor3 = color or COLORS.card
    Btn.Text = text
    Btn.TextColor3 = COLORS.text
    Btn.TextSize = 14
    Btn.Font = Enum.Font.GothamBold
    Btn.AutoButtonColor = false
    Btn.ZIndex = 7
    Btn.Parent = parent
    local C = Instance.new("UICorner")
    C.CornerRadius = UDim.new(0, 6)
    C.Parent = Btn
    Btn.MouseButton1Click:Connect(callback)
    return Btn
end

-- ============ СТРАНИЦА: HOME ============
local function RefreshHome()
    for _, c in ipairs(PageHome:GetChildren()) do
        if c:IsA("Frame") or c:IsA("TextButton") or c:IsA("TextLabel") then
            pcall(function() c:Destroy() end)
        end
    end

    local H1 = Instance.new("TextLabel")
    H1.Size = UDim2.new(1, 0, 0, 26)
    H1.BackgroundTransparency = 1
    H1.Text = "➕ Добавить трек"
    H1.TextColor3 = COLORS.text
    H1.TextSize = 14
    H1.Font = Enum.Font.GothamBold
    H1.TextXAlignment = Enum.TextXAlignment.Left
    H1.ZIndex = 5
    H1.Parent = PageHome

    local InputRow = Instance.new("Frame")
    InputRow.Size = UDim2.new(1, 0, 0, 44)
    InputRow.BackgroundColor3 = COLORS.card
    InputRow.BorderSizePixel = 0
    InputRow.ZIndex = 5
    InputRow.Parent = PageHome
    local IRC = Instance.new("UICorner")
    IRC.CornerRadius = UDim.new(0, 8)
    IRC.Parent = InputRow

    local IdInput = Instance.new("TextBox")
    IdInput.Size = UDim2.new(0.55, -10, 1, -8)
    IdInput.Position = UDim2.new(0, 10, 0, 4)
    IdInput.BackgroundTransparency = 1
    IdInput.Text = ""
    IdInput.PlaceholderText = "ID музыки (напр. 1837879082)"
    IdInput.PlaceholderColor3 = COLORS.textMuted
    IdInput.TextColor3 = COLORS.text
    IdInput.TextSize = 12
    IdInput.Font = Enum.Font.Gotham
    IdInput.TextXAlignment = Enum.TextXAlignment.Left
    IdInput.ClearTextOnFocus = false
    IdInput.ZIndex = 6
    IdInput.Parent = InputRow

    local NameInput = Instance.new("TextBox")
    NameInput.Size = UDim2.new(0.45, -20, 1, -8)
    NameInput.Position = UDim2.new(0.55, 0, 0, 4)
    NameInput.BackgroundTransparency = 1
    NameInput.Text = ""
    NameInput.PlaceholderText = "Название (опц.)"
    NameInput.PlaceholderColor3 = COLORS.textMuted
    NameInput.TextColor3 = COLORS.text
    NameInput.TextSize = 12
    NameInput.Font = Enum.Font.Gotham
    NameInput.TextXAlignment = Enum.TextXAlignment.Left
    NameInput.ClearTextOnFocus = false
    NameInput.ZIndex = 6
    NameInput.Parent = InputRow

    local BtnRow = Instance.new("Frame")
    BtnRow.Size = UDim2.new(1, 0, 0, 44)
    BtnRow.BackgroundTransparency = 1
    BtnRow.ZIndex = 5
    BtnRow.Parent = PageHome

    local BRL = Instance.new("UIListLayout")
    BRL.FillDirection = Enum.FillDirection.Horizontal
    BRL.Padding = UDim.new(0, 8)
    BRL.Parent = BtnRow

    local function MakeBtn(text, color, callback)
        local Btn = Instance.new("TextButton")
        Btn.Size = UDim2.new(0, 160, 1, 0)
        Btn.BackgroundColor3 = color
        Btn.Text = text
        Btn.TextColor3 = (color == COLORS.accent) and Color3.fromRGB(0, 0, 0) or COLORS.text
        Btn.TextSize = 12
        Btn.Font = Enum.Font.GothamBold
        Btn.AutoButtonColor = false
        Btn.ZIndex = 6
        Btn.Parent = BtnRow
        local C = Instance.new("UICorner")
        C.CornerRadius = UDim.new(0, 8)
        C.Parent = Btn
        Btn.MouseButton1Click:Connect(callback)
        return Btn
    end

    MakeBtn("▶ СРАЗУ ИГРАТЬ", COLORS.accent, function()
        if IdInput.Text == "" then return end
        local id = NormalizeId(IdInput.Text)
        local track = {id = id, name = NameInput.Text ~= "" and NameInput.Text or ("Трек " .. (#State.playlist + 1))}
        table.insert(State.playlist, track)
        State.currentIndex = #State.playlist
        SaveAll()
        PlayTrack(track)
        RefreshPlaylist()
        IdInput.Text = ""
        NameInput.Text = ""
    end)

    MakeBtn("➕ В ПЛЕЙЛИСТ", COLORS.card, function()
        if IdInput.Text == "" then return end
        local id = NormalizeId(IdInput.Text)
        local track = {id = id, name = NameInput.Text ~= "" and NameInput.Text or ("Трек " .. (#State.playlist + 1))}
        table.insert(State.playlist, track)
        SaveAll()
        RefreshPlaylist()
        IdInput.Text = ""
        NameInput.Text = ""
    end)

    -- Быстрые пресеты
    local Q1 = Instance.new("TextLabel")
    Q1.Size = UDim2.new(1, 0, 0, 26)
    Q1.BackgroundTransparency = 1
    Q1.Text = "⚡ Быстрые пресеты"
    Q1.TextColor3 = COLORS.text
    Q1.TextSize = 14
    Q1.Font = Enum.Font.GothamBold
    Q1.TextXAlignment = Enum.TextXAlignment.Left
    Q1.ZIndex = 5
    Q1.Parent = PageHome

    local PRESETS = {
        {name = "🎵 Roblox Classic", id = "1837879082"},
        {name = "🎵 Victory", id = "1837840462"},
        {name = "🎵 Sad", id = "1837879217"},
        {name = "🎵 Battle", id = "1841644829"},
    }

    for _, p in ipairs(PRESETS) do
        local Card = CreateCard(PageHome)
        local Lbl = Instance.new("TextLabel")
        Lbl.Size = UDim2.new(1, -150, 1, 0)
        Lbl.Position = UDim2.new(0, 12, 0, 0)
        Lbl.BackgroundTransparency = 1
        Lbl.Text = p.name
        Lbl.TextColor3 = COLORS.text
        Lbl.TextSize = 13
        Lbl.Font = Enum.Font.GothamBold
        Lbl.TextXAlignment = Enum.TextXAlignment.Left
        Lbl.ZIndex = 6
        Lbl.Parent = Card

        CreateSmallBtn(Card, "▶", COLORS.accent, UDim2.new(0, 40, 0, 34), function()
            local track = {id = NormalizeId(p.id), name = p.name}
            table.insert(State.playlist, track)
            State.currentIndex = #State.playlist
            SaveAll()
            PlayTrack(track)
            RefreshPlaylist()
        end).Position = UDim2.new(1, -50, 0.5, -17)
    end
end

-- ============ СТРАНИЦА: PLAYLIST ============
local function RefreshPlaylist()
    for _, c in ipairs(PagePlaylist:GetChildren()) do
        if c:IsA("Frame") or c:IsA("TextButton") or c:IsA("TextLabel") then
            pcall(function() c:Destroy() end)
        end
    end

    if #State.playlist == 0 then
        local Empty = Instance.new("TextLabel")
        Empty.Size = UDim2.new(1, 0, 0, 60)
        Empty.BackgroundTransparency = 1
        Empty.Text = "📋 Плейлист пуст\nДобавь треки во вкладке «Главная»"
        Empty.TextColor3 = COLORS.textMuted
        Empty.TextSize = 13
        Empty.Font = Enum.Font.Gotham
        Empty.ZIndex = 5
        Empty.Parent = PagePlaylist
        return
    end

    for i, track in ipairs(State.playlist) do
        local Card = CreateCard(PagePlaylist)
        Card.Name = "Track_" .. i

        local Num = Instance.new("TextLabel")
        Num.Size = UDim2.new(0, 30, 1, 0)
        Num.Position = UDim2.new(0, 6, 0, 0)
        Num.BackgroundTransparency = 1
        Num.Text = tostring(i)
        Num.TextColor3 = COLORS.textMuted
        Num.TextSize = 13
        Num.Font = Enum.Font.GothamBold
        Num.ZIndex = 6
        Num.Parent = Card

        local Info = Instance.new("TextLabel")
        Info.Size = UDim2.new(1, -180, 1, 0)
        Info.Position = UDim2.new(0, 42, 0, 0)
        Info.BackgroundTransparency = 1
        Info.Text = track.name or ("Трек " .. i)
        Info.TextColor3 = COLORS.text
        Info.TextSize = 13
        Info.Font = Enum.Font.GothamBold
        Info.TextXAlignment = Enum.TextXAlignment.Left
        Info.TextTruncate = Enum.TextTruncate.AtEnd
        Info.ZIndex = 6
        Info.Parent = Card

        -- Кнопки справа
        local FavBtn = CreateSmallBtn(Card, "⭐", COLORS.card, UDim2.new(0, 34, 0, 34), function()
            -- Добавляем/убираем из избранного
            local found = false
            for fi, f in ipairs(State.favorites) do
                if f.id == track.id then
                    table.remove(State.favorites, fi)
                    found = true
                    break
                end
            end
            if not found then
                table.insert(State.favorites, track)
            end
            SaveAll()
            RefreshFavorites()
        end)
        FavBtn.Position = UDim2.new(1, -120, 0.5, -17)

        local PlayBtn2 = CreateSmallBtn(Card, "▶", COLORS.accent, UDim2.new(0, 40, 0, 34), function()
            State.currentIndex = i
            PlayTrack(track)
        end)
        PlayBtn2.Position = UDim2.new(1, -80, 0.5, -17)

        local DelBtn = CreateSmallBtn(Card, "🗑", Color3.fromRGB(220, 60, 60), UDim2.new(0, 34, 0, 34), function()
            table.remove(State.playlist, i)
            SaveAll()
            RefreshPlaylist()
        end)
        DelBtn.Position = UDim2.new(1, -36, 0.5, -17)
    end
end

-- ============ СТРАНИЦА: HISTORY ============
local function RefreshHistory()
    for _, c in ipairs(PageHistory:GetChildren()) do
        if c:IsA("Frame") or c:IsA("TextButton") or c:IsA("TextLabel") then
            pcall(function() c:Destroy() end)
        end
    end

    if #State.history == 0 then
        local Empty = Instance.new("TextLabel")
        Empty.Size = UDim2.new(1, 0, 0, 60)
        Empty.BackgroundTransparency = 1
        Empty.Text = "🕐 История пуста\nВключи любой трек — он появится здесь"
        Empty.TextColor3 = COLORS.textMuted
        Empty.TextSize = 13
        Empty.Font = Enum.Font.Gotham
        Empty.ZIndex = 5
        Empty.Parent = PageHistory
        return
    end

    for i, track in ipairs(State.history) do
        local Card = CreateCard(PageHistory)
        local Info = Instance.new("TextLabel")
        Info.Size = UDim2.new(1, -70, 1, 0)
        Info.Position = UDim2.new(0, 14, 0, 0)
        Info.BackgroundTransparency = 1
        Info.Text = track.name or track.id or "Без названия"
        Info.TextColor3 = COLORS.text
        Info.TextSize = 13
        Info.Font = Enum.Font.GothamBold
        Info.TextXAlignment = Enum.TextXAlignment.Left
        Info.TextTruncate = Enum.TextTruncate.AtEnd
        Info.ZIndex = 6
        Info.Parent = Card

        local PlayBtn2 = CreateSmallBtn(Card, "▶", COLORS.accent, UDim2.new(0, 40, 0, 34), function()
            PlayTrack(track)
        end)
        PlayBtn2.Position = UDim2.new(1, -50, 0.5, -17)
    end
end

-- ============ СТРАНИЦА: FAVORITES ============
local function RefreshFavorites()
    for _, c in ipairs(PageFavorites:GetChildren()) do
        if c:IsA("Frame") or c:IsA("TextButton") or c:IsA("TextLabel") then
            pcall(function() c:Destroy() end)
        end
    end

    if #State.favorites == 0 then
        local Empty = Instance.new("TextLabel")
        Empty.Size = UDim2.new(1, 0, 0, 60)
        Empty.BackgroundTransparency = 1
        Empty.Text = "⭐ Избранное пусто\nНажми ⭐ у трека в плейлисте"
        Empty.TextColor3 = COLORS.textMuted
        Empty.TextSize = 13
        Empty.Font = Enum.Font.Gotham
        Empty.ZIndex = 5
        Empty.Parent = PageFavorites
        return
    end

    for i, track in ipairs(State.favorites) do
        local Card = CreateCard(PageFavorites)
        local Info = Instance.new("TextLabel")
        Info.Size = UDim2.new(1, -120, 1, 0)
        Info.Position = UDim2.new(0, 14, 0, 0)
        Info.BackgroundTransparency = 1
        Info.Text = track.name or track.id or "—"
        Info.TextColor3 = COLORS.text
        Info.TextSize = 13
        Info.Font = Enum.Font.GothamBold
        Info.TextXAlignment = Enum.TextXAlignment.Left
        Info.ZIndex = 6
        Info.Parent = Card

        local PlayBtn2 = CreateSmallBtn(Card, "▶", COLORS.accent, UDim2.new(0, 40, 0, 34), function()
            PlayTrack(track)
        end)
        PlayBtn2.Position = UDim2.new(1, -80, 0.5, -17)

        local DelBtn = CreateSmallBtn(Card, "🗑", Color3.fromRGB(220, 60, 60), UDim2.new(0, 34, 0, 34), function()
            table.remove(State.favorites, i)
            SaveAll()
            RefreshFavorites()
        end)
        DelBtn.Position = UDim2.new(1, -36, 0.5, -17)
    end
end

-- ============ СТРАНИЦА: EQ (эквалайзер) ============
local function MakeEQSlider(parent, name, default, callback)
    local Card = CreateCard(parent)
    Card.Size = UDim2.new(1, 0, 0, 64)

    local Lbl = Instance.new("TextLabel")
    Lbl.Size = UDim2.new(1, -100, 0, 20)
    Lbl.Position = UDim2.new(0, 14, 0, 6)
    Lbl.BackgroundTransparency = 1
    Lbl.Text = name
    Lbl.TextColor3 = COLORS.text
    Lbl.TextSize = 13
    Lbl.Font = Enum.Font.GothamBold
    Lbl.TextXAlignment = Enum.TextXAlignment.Left
    Lbl.ZIndex = 6
    Lbl.Parent = Card

    local Val = Instance.new("TextLabel")
    Val.Size = UDim2.new(0, 50, 0, 20)
    Val.Position = UDim2.new(1, -60, 0, 6)
    Val.BackgroundTransparency = 1
    Val.Text = tostring(default)
    Val.TextColor3 = COLORS.accent
    Val.TextSize = 12
    Val.Font = Enum.Font.GothamBold
    Val.TextXAlignment = Enum.TextXAlignment.Right
    Val.ZIndex = 6
    Val.Parent = Card

    local Bar = Instance.new("Frame")
    Bar.Size = UDim2.new(1, -28, 0, 8)
    Bar.Position = UDim2.new(0, 14, 0, 40)
    Bar.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    Bar.BorderSizePixel = 0
    Bar.ZIndex = 6
    Bar.Parent = Card
    local BC = Instance.new("UICorner")
    BC.CornerRadius = UDim.new(1, 0)
    BC.Parent = Bar

    -- 0 в центре = 50%
    local Fill = Instance.new("Frame")
    Fill.Size = UDim2.new(0.5 + default / 10, 0, 1, 0)
    Fill.BackgroundColor3 = COLORS.accent
    Fill.BorderSizePixel = 0
    Fill.ZIndex = 7
    Fill.Parent = Bar
    local FC = Instance.new("UICorner")
    FC.CornerRadius = UDim.new(1, 0)
    FC.Parent = Fill

    local dragging = false
    Bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
        end
    end)
    B.UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    B.UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local m = B.UserInputService:GetMouseLocation()
            local bp = Bar.AbsolutePosition
            local bs = Bar.AbsoluteSize
            local rel = math.clamp((m.X - bp.X) / bs.X, 0, 1)
            Fill.Size = UDim2.new(rel, 0, 1, 0)
            local v = math.floor((rel - 0.5) * 10)
            Val.Text = tostring(v)
            if callback then callback(v) end
        end
    end)
end

local function RefreshEQ()
    for _, c in ipairs(PageEQ:GetChildren()) do
        if c:IsA("Frame") then
            pcall(function() c:Destroy() end)
        end
    end

    local Info = Instance.new("TextLabel")
    Info.Size = UDim2.new(1, 0, 0, 40)
    Info.BackgroundTransparency = 1
    Info.Text = "🎛 Эквалайзер\nРаботает через изменение высоты тона трека"
    Info.TextColor3 = COLORS.textDim
    Info.TextSize = 12
    Info.Font = Enum.Font.Gotham
    Info.TextXAlignment = Enum.TextXAlignment.Left
    Info.ZIndex = 5
    Info.Parent = PageEQ

    MakeEQSlider(PageEQ, "🔊 Bass (низкие)", State.eq.bass, function(v)
        State.eq.bass = v
        if currentSound then
            pcall(function()
                currentSound.PlaybackSpeed = 1 + (v * 0.02)
            end)
        end
    end)

    MakeEQSlider(PageEQ, "🎵 Mid (средние)", State.eq.mid, function(v)
        State.eq.mid = v
    end)

    MakeEQSlider(PageEQ, "🎶 Treble (высокие)", State.eq.treble, function(v)
        State.eq.treble = v
        if currentSound then
            pcall(function()
                currentSound.PlaybackSpeed = 1 + (v * 0.01)
            end)
        end
    end)
end

-- ============ СТРАНИЦА: SETTINGS ============
local function RefreshSettings()
    for _, c in ipairs(PageSettings:GetChildren()) do
        if c:IsA("Frame") or c:IsA("TextButton") or c:IsA("TextLabel") then
            pcall(function() c:Destroy() end)
        end
    end

    local H = Instance.new("TextLabel")
    H.Size = UDim2.new(1, 0, 0, 26)
    H.BackgroundTransparency = 1
    H.Text = "⚙ Настройки"
    H.TextColor3 = COLORS.text
    H.TextSize = 14
    H.Font = Enum.Font.GothamBold
    H.TextXAlignment = Enum.TextXAlignment.Left
    H.ZIndex = 5
    H.Parent = PageSettings

    local InfoCard = CreateCard(PageSettings)
    InfoCard.Size = UDim2.new(1, 0, 0, 120)
    local IL = Instance.new("TextLabel")
    IL.Size = UDim2.new(1, -20, 1, -16)
    IL.Position = UDim2.new(0, 12, 0, 8)
    IL.BackgroundTransparency = 1
    IL.Text = string.format(
        "🎵 Bloodline Music v3.0\n\n📋 Треков в плейлисте: %d\n⭐ В избранном: %d\n🕐 История: %d\n💾 File API: %s",
        #State.playlist, #State.favorites, #State.history,
        B.HasFileAPI and "OK" or "НЕТ"
    )
    IL.TextColor3 = COLORS.text
    IL.TextSize = 12
    IL.Font = Enum.Font.Gotham
    IL.TextXAlignment = Enum.TextXAlignment.Left
    IL.TextYAlignment = Enum.TextYAlignment.Top
    IL.ZIndex = 6
    IL.Parent = InfoCard

    -- Кнопки
    local BtnRow = Instance.new("Frame")
    BtnRow.Size = UDim2.new(1, 0, 0, 44)
    BtnRow.BackgroundTransparency = 1
    BtnRow.ZIndex = 5
    BtnRow.Parent = PageSettings

    local BRL = Instance.new("UIListLayout")
    BRL.FillDirection = Enum.FillDirection.Horizontal
    BRL.Padding = UDim.new(0, 8)
    BRL.Parent = BtnRow

    local function MakeBtn(text, color, callback)
        local Btn = Instance.new("TextButton")
        Btn.Size = UDim2.new(0, 150, 1, 0)
        Btn.BackgroundColor3 = color
        Btn.Text = text
        Btn.TextColor3 = COLORS.text
        Btn.TextSize = 12
        Btn.Font = Enum.Font.GothamBold
        Btn.AutoButtonColor = false
        Btn.ZIndex = 6
        Btn.Parent = BtnRow
        local C = Instance.new("UICorner")
        C.CornerRadius = UDim.new(0, 8)
        C.Parent = Btn
        Btn.MouseButton1Click:Connect(callback)
        return Btn
    end

    MakeBtn("🗑 Очистить плейлист", Color3.fromRGB(220, 60, 60), function()
        State.playlist = {}
        State.currentIndex = 0
        SaveAll()
        RefreshPlaylist()
        RefreshSettings()
    end)

    MakeBtn("🗑 Очистить историю", Color3.fromRGB(200, 100, 60), function()
        State.history = {}
        SaveAll()
        RefreshHistory()
        RefreshSettings()
    end)

    MakeBtn("💾 Сохранить всё", COLORS.accent, function()
        SaveAll()
    end)
end

-- ============ ИНИЦИАЛИЗАЦИЯ СТРАНИЦ ============
RefreshHome()
RefreshPlaylist()
RefreshHistory()
RefreshFavorites()
RefreshEQ()
RefreshSettings()

-- ============ ХОТКЕИ ============
table.insert(getgenv().BloodlineMusicConns, B.UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.Delete then
        pcall(function()
            if getgenv().BloodlineCurrentSound then
                getgenv().BloodlineCurrentSound:Stop()
                getgenv().BloodlineCurrentSound:Destroy()
                getgenv().BloodlineCurrentSound = nil
            end
            B.ScreenGui:Destroy()
            getgenv().BloodlineMusicGui = nil
            getgenv().BloodlineMusicBase = nil
        end)
    end
end))

-- Уведомление
pcall(function()
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = "🎵 Bloodline Music v3.0",
        Text = "✅ Загружено! F3 — открыть/закрыть",
        Duration = 5
    })
end)

print([[
╔══════════════════════════════════════════╗
║   🎵 BLOODLINE MUSIC v3.0 ЗАГРУЖЕН! 🎵   ║
║   ─────────────────────────────          ║
║   F3 — открыть/закрыть плеер             ║
║   Delete — выгрузить                     ║
║   ─────────────────────────────          ║
║   File API: ]] .. (B.HasFileAPI and "OK" or "НЕТ") .. [[
║   Треков: ]] .. #State.playlist .. [[   Избранных: ]] .. #State.favorites .. [[
╚══════════════════════════════════════════╝
]])
    
    
