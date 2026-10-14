--[[
	SPOTIFY-ПЛЕЕР v3 — ВСЁ В ОДНОМ СКРИПТЕ

	УСТАНОВКА:
	  1. ServerScriptService → новый Script (обычный Script, не LocalScript)
	  2. Вставь сюда весь этот код
	  3. Старые SpotifyPlayer_Client / SpotifyPlayer_Server удали, если они есть
	  4. Для теста в Studio: Game Settings > Security > "Enable Studio Access to API Services"

	КАК ЭТО РАБОТАЕТ:
	  Серверная ветка (сохранение, топ-чарт) запускается на сервере и выдаёт каждому игроку
	  свою копию этого же скрипта в режиме Client. Клиентская ветка рисует плеер.

	ЗАПАСНОЙ ВАРИАНТ (если копия на клиенте не запускается):
	  поставь AUTO_CLONE = false и вставь ТОТ ЖЕ код ещё и в LocalScript
	  (StarterPlayer > StarterPlayerScripts).
]]

local AUTO_CLONE = true

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local function cutText(s, n)
	if type(s) ~= "string" or not utf8.len(s) then return "" end
	local o = utf8.offset(s, n + 1)
	if o then return s:sub(1, o - 1) end
	return s
end

------------------------------------------------------------------------
-- ░░░░░░░░░░░░░░░░░░░░░░  СЕРВЕРНАЯ ЧАСТЬ  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░
------------------------------------------------------------------------
if RunService:IsServer() then
	local DataStoreService = game:GetService("DataStoreService")

	local MAX_PLAYLISTS, MAX_TRACKS = 20, 300
	local store = DataStoreService:GetDataStore("SpotifyPlayer_v1")
	local topStore = DataStoreService:GetOrderedDataStore("SpotifyPlayer_TopPlays_v1")

	local folder = Instance.new("Folder")
	folder.Name = "SpotifyPlayerRemotes"
	local function makeRemote(class, name)
		local r = Instance.new(class)
		r.Name = name
		r.Parent = folder
		return r
	end
	local remLoad = makeRemote("RemoteFunction", "Load")
	local remSave = makeRemote("RemoteEvent", "Save")
	local remPlayed = makeRemote("RemoteEvent", "Played")
	local remTop = makeRemote("RemoteFunction", "GetTop")
	folder.Parent = ReplicatedStorage

	-- Проверка данных от клиента ------------------------------------
	local function cleanText(v, max)
		if type(v) ~= "string" then return nil end
		v = v:gsub("%c", "")
		if not utf8.len(v) then return nil end
		v = cutText(v, max)
		if v == "" then return nil end
		return v
	end

	local function validId(id)
		return id and id >= 1 and id % 1 == 0 and id < 2 ^ 50
	end

	local function cleanTracks(list)
		local out = {}
		if type(list) ~= "table" then return out end
		for _, t in ipairs(list) do
			if #out >= MAX_TRACKS then break end
			if type(t) == "table" then
				local id = tonumber(t.id)
				if validId(id) then
					out[#out + 1] = { id = id, title = cleanText(t.title, 60), artist = cleanText(t.artist, 40) }
				end
			end
		end
		return out
	end

	local function num(v, min, max, default)
		v = tonumber(v)
		if not v or v ~= v then return default end
		return math.clamp(v, min, max)
	end

	local function cleanBinds(b)
		local out, n = {}, 0
		if type(b) ~= "table" then return out end
		for action, key in pairs(b) do
			if n >= 40 then break end
			if type(action) == "string" and #action <= 16 and type(key) == "string" and #key <= 24 then
				local ok = key == "None" or pcall(function() return Enum.KeyCode[key] end)
				if ok then
					out[action] = key
					n += 1
				end
			end
		end
		return out
	end

	local function cleanMarkers(m)
		local out, tracks = {}, 0
		if type(m) ~= "table" then return out end
		for k, list in pairs(m) do
			local id = tonumber(k)
			if validId(id) and type(list) == "table" and tracks < 150 then
				local arr = {}
				for _, s in ipairs(list) do
					s = tonumber(s)
					if s and s >= 0 and s < 36000 and #arr < 20 then
						arr[#arr + 1] = math.floor(s * 10) / 10
					end
				end
				if #arr > 0 then
					table.sort(arr)
					out[tostring(id)] = arr
					tracks += 1
				end
			end
		end
		return out
	end

	local function sanitize(d)
		if type(d) ~= "table" then return nil end
		local out = {
			playlists = {}, liked = {}, volume = 0.5, bass = 0, reverb = false, last = 1,
			theme = "dark", crossfade = 0, binds = {}, markers = {},
		}
		if type(d.playlists) == "table" then
			for _, p in ipairs(d.playlists) do
				if #out.playlists >= MAX_PLAYLISTS then break end
				if type(p) == "table" then
					out.playlists[#out.playlists + 1] = {
						name = cleanText(p.name, 24) or "Плейлист",
						tracks = cleanTracks(p.tracks),
					}
				end
			end
		end
		if #out.playlists == 0 then
			out.playlists[1] = { name = "Мой плейлист", tracks = {} }
		end
		out.liked = cleanTracks(d.liked)
		out.volume = num(d.volume, 0, 1, 0.5)
		out.bass = num(d.bass, 0, 1, 0)
		out.reverb = d.reverb == true
		out.last = math.clamp(math.floor(num(d.last, 1, 1000, 1)), 1, #out.playlists)
		out.theme = d.theme == "light" and "light" or "dark"
		out.crossfade = math.floor(num(d.crossfade, 0, 12, 0))
		out.binds = cleanBinds(d.binds)
		out.markers = cleanMarkers(d.markers)
		return out
	end

	-- Загрузка / сохранение ------------------------------------------
	local loadedOk, pending, lastRecv = {}, {}, {}
	local function keyFor(plr) return "u_" .. plr.UserId end

	remLoad.OnServerInvoke = function(plr)
		local success, data
		for _ = 1, 3 do
			success, data = pcall(function() return store:GetAsync(keyFor(plr)) end)
			if success then break end
			task.wait(1.5)
		end
		if success then
			loadedOk[plr] = true
			return { ok = true, data = sanitize(data) }
		end
		return { ok = false }
	end

	remSave.OnServerEvent:Connect(function(plr, payload)
		if not loadedOk[plr] then return end
		local now = os.clock()
		if lastRecv[plr] and now - lastRecv[plr] < 0.5 then return end
		lastRecv[plr] = now
		local clean = sanitize(payload)
		if clean then pending[plr] = clean end
	end)

	local function flush(plr)
		local data = pending[plr]
		if not data or not loadedOk[plr] then return end
		pending[plr] = nil
		local ok, err = pcall(function() store:SetAsync(keyFor(plr), data) end)
		if not ok then
			warn("[SpotifyPlayer] Не удалось сохранить:", err)
			if not pending[plr] then pending[plr] = data end
		end
	end

	task.spawn(function()
		while true do
			task.wait(30)
			local list = {}
			for plr in pairs(pending) do list[#list + 1] = plr end
			for _, plr in ipairs(list) do flush(plr) end
		end
	end)

	-- Топ чарт ---------------------------------------------------------
	local pendingPlays, lastAny, lastById = {}, {}, {}

	remPlayed.OnServerEvent:Connect(function(plr, id)
		id = tonumber(id)
		if not validId(id) then return end
		local now = os.clock()
		if lastAny[plr] and now - lastAny[plr] < 3 then return end
		local byId = lastById[plr]
		if not byId then
			byId = {}
			lastById[plr] = byId
		end
		if byId[id] and now - byId[id] < 90 then return end
		lastAny[plr] = now
		byId[id] = now
		pendingPlays[id] = (pendingPlays[id] or 0) + 1
	end)

	Players.PlayerRemoving:Connect(function(plr)
		flush(plr)
		pending[plr], loadedOk[plr], lastRecv[plr] = nil, nil, nil
		lastAny[plr], lastById[plr] = nil, nil
	end)

	local function flushTop()
		local batch = {}
		for id, count in pairs(pendingPlays) do
			batch[#batch + 1] = { id, count }
			if #batch >= 25 then break end
		end
		for _, item in ipairs(batch) do
			local id, count = item[1], item[2]
			pendingPlays[id] = nil
			local ok = pcall(function() topStore:IncrementAsync(tostring(id), count) end)
			if not ok then pendingPlays[id] = (pendingPlays[id] or 0) + count end
			task.wait(0.3)
		end
	end

	task.spawn(function()
		while true do
			task.wait(60)
			flushTop()
		end
	end)

	local meta = {}
	local function getMeta(id)
		if meta[id] then return meta[id] end
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(id, Enum.InfoType.Asset)
		end)
		if ok and info then
			if info.AssetTypeId ~= 3 then return nil end -- только аудио
			meta[id] = {
				title = cleanText(tostring(info.Name), 60) or ("Трек " .. id),
				artist = cleanText(info.Creator and tostring(info.Creator.Name) or "—", 40) or "—",
			}
			return meta[id]
		end
		return nil
	end

	local topCache, topAt = {}, -1e9
	remTop.OnServerInvoke = function()
		if os.clock() - topAt < 60 then return topCache end
		topAt = os.clock()
		local ok, page = pcall(function()
			return topStore:GetSortedAsync(false, 25):GetCurrentPage()
		end)
		if ok then
			local list = {}
			for _, e in ipairs(page) do
				local id = tonumber(e.key)
				local m = id and getMeta(id)
				if m then
					list[#list + 1] = { id = id, title = m.title, artist = m.artist, plays = e.value }
				end
				if #list >= 20 then break end
			end
			topCache = list
		else
			topAt = os.clock() - 50
		end
		return topCache
	end

	game:BindToClose(function()
		for _, plr in ipairs(Players:GetPlayers()) do flush(plr) end
		flushTop()
	end)

	-- Выдаём клиентскую копию скрипта каждому игроку ------------------
	if AUTO_CLONE then
		local function give(plr)
			local pg = plr:WaitForChild("PlayerGui")
			if pg:FindFirstChild("SpotifyPlayerClient") then return end
			local c = script:Clone()
			c.Name = "SpotifyPlayerClient"
			c.RunContext = Enum.RunContext.Client
			c.Parent = pg
		end
		Players.PlayerAdded:Connect(function(p) task.spawn(give, p) end)
		for _, p in ipairs(Players:GetPlayers()) do task.spawn(give, p) end
	end
	return
end

------------------------------------------------------------------------
-- ░░░░░░░░░░░░░░░░░░░░░░  КЛИЕНТСКАЯ ЧАСТЬ  ░░░░░░░░░░░░░░░░░░░░░░░░░░░
------------------------------------------------------------------------
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
if playerGui:FindFirstChild("SpotifyPlayer") then return end

local remLoad, remSave, remPlayed, remTop

------------------------------------------------------------
-- ТЕМЫ
------------------------------------------------------------
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

------------------------------------------------------------
-- ХЕЛПЕРЫ
-- В new()/label(): bg="роль" и tc="роль" — цвета, которые меняются вместе с темой
------------------------------------------------------------
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

-- нижний регистр для кириллицы и латиницы (сортировка и поиск)
local function lowerU(s)
	if type(s) ~= "string" or not utf8.len(s) then return "" end
	local out = {}
	for _, cp in utf8.codes(s) do
		local c = cp
		if c >= 0x410 and c <= 0x42F then
			c += 32
		elseif c == 0x401 then
			c = 0x451
		elseif c >= 0x41 and c <= 0x5A then
			c += 32
		end
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
	volume = 0.5, bass = 0, reverb = false, last = 1,
	theme = "dark", crossfade = 0, binds = {}, markers = {},
}

local view = { kind = "pl", index = 1 } -- pl | liked | top | search
local prevView
local searchList, searchQuery = {}, ""
local topList, topState = {}, "idle"
local sortMode = "manual"
local loaded, saveToken = false, 0

-- Горячие клавиши
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
local KEYNAMES = {
	Period = ".", Comma = ",", Equals = "=", Minus = "-", RightBracket = "]",
	LeftBracket = "[", Slash = "/", Backquote = "`", Semicolon = ";", Quote = "'",
}
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
local function keyLabel(id)
	local k = keyOf(id)
	if not k then return "—" end
	return KEYNAMES[k.Name] or k.Name
end

-- forward declarations
local renderList, renderSidebar, renderBanner, updateNowPlaying, updatePlayState
local setView, playFromList, nextTrack, prevTrack, togglePlay, fetchTop
local toggleLike, refreshTexts, closePopups, markDirty, notify, updateHearts
local openMenu, openAddMenu, openTrackMenu, setMode, rebuildMarkers, addMarker
local setVolume, applyTheme, runAction, refreshKeys, setSpeed
local uiMode, lastShown = "hidden", "full"
local markerLen = 0

local function currentList()
	if view.kind == "liked" then return state.liked end
	if view.kind == "top" then return topList end
	if view.kind == "search" then return searchList end
	return state.playlists[view.index].tracks
end

local function isLiked(id)
	for _, t in ipairs(state.liked) do
		if t.id == id then return true end
	end
	return false
end

-- Сортировка (только отображение)
local SORTS = { "manual", "title", "artist", "newest" }
local SORT_NAMES = { manual = "Мой порядок", title = "Название А–Я", artist = "Исполнитель А–Я", newest = "Сначала новые" }

local function displayList()
	local list = currentList()
	if view.kind == "top" or view.kind == "search" or sortMode == "manual" then return list end
	local items = {}
	for i, t in ipairs(list) do
		items[i] = { t = t, i = i, k = lowerU(sortMode == "title" and (t.title or "") or (t.artist or "")) }
	end
	if sortMode == "newest" then
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
	scan(topList)
	return out
end

------------------------------------------------------------
-- ЗВУК: SoundGroup + эквалайзер (бас) + реверб + кроссфейд
------------------------------------------------------------
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

local speed = 1
local sound, current
local queue, qi = {}, 0
local shuffle, repeatMode = false, 0
local playToken, failStreak, xfFired = 0, 0, -1
local badIds = {}

------------------------------------------------------------
-- GUI: КОРЕНЬ
------------------------------------------------------------
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

-- Toast
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
function notify(msg)
	toastToken += 1
	local my = toastToken
	toastLbl.Text = msg
	tween(toast, 0.35, { Position = UDim2.new(0.5, 0, 0, 20) }, Enum.EasingStyle.Back)
	task.delay(2.4, function()
		if my == toastToken then tween(toast, 0.25, { Position = UDim2.new(0.5, 0, 0, -70) }) end
	end)
end

------------------------------------------------------------
-- САЙДБАР
------------------------------------------------------------
local sidebar = new("Frame", {
	Size = UDim2.new(0, SIDE_W, 1, -BAR_H), bg = "side", BorderSizePixel = 0, Parent = main,
})
label({
	Text = "♪", Font = FONT_X, TextSize = 26, tc = "green",
	Position = UDim2.fromOffset(20, 40), Size = UDim2.fromOffset(26, 30), Parent = sidebar,
})
label({
	Text = "Музыка", Font = FONT_X, TextSize = 22,
	Position = UDim2.fromOffset(50, 40), Size = UDim2.new(1, -60, 0, 30), Parent = sidebar,
})

local function sideButton(parent, y, icon, text)
	local props = {
		Text = "", Size = UDim2.new(1, -16, 0, 38), bg = "elev", BackgroundTransparency = 1,
		AutoButtonColor = false, Parent = parent,
	}
	if y then props.Position = UDim2.fromOffset(8, y) end
	local b = new("TextButton", props)
	corner(b, 8)
	local ic = label({
		Text = icon, Font = FONT_B, TextSize = 18, tc = "sub", TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(6, 0), Size = UDim2.fromOffset(30, 38), Parent = b,
	})
	local tx = label({
		Text = text, Font = FONT_B, TextSize = 14, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd,
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
	Text = "ПЛЕЙЛИСТЫ", Font = FONT_B, TextSize = 12, tc = "sub",
	Position = UDim2.fromOffset(20, 190), Size = UDim2.fromOffset(120, 24), Parent = sidebar,
})
local plAddBtn = new("TextButton", {
	Text = "+", Font = FONT_B, TextSize = 22, tc = "sub", BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 188), Size = UDim2.fromOffset(28, 28), Parent = sidebar,
})
bouncy(plAddBtn, 1.15)

local plNameBox = new("TextBox", {
	PlaceholderText = "Название и Enter", PlaceholderColor3 = rgb(140, 140, 150), Text = "",
	ClearTextOnFocus = false, Font = FONT, TextSize = 13, tc = "text",
	TextXAlignment = Enum.TextXAlignment.Left, bg = "elev", Visible = false,
	Position = UDim2.fromOffset(10, 218), Size = UDim2.new(1, -20, 0, 30), Parent = sidebar,
})
corner(plNameBox, 15)
new("UIPadding", { PaddingLeft = UDim.new(0, 12), Parent = plNameBox })

local plScroll = new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = C.elev2,
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = sidebar,
})
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = plScroll })

local function layoutSidebar()
	local y = plNameBox.Visible and 254 or 220
	plScroll.Position = UDim2.fromOffset(8, y)
	plScroll.Size = UDim2.new(1, -16, 1, -(y + 52))
end
layoutSidebar()

-- нижние кнопки сайдбара
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

------------------------------------------------------------
-- ОСНОВНАЯ ОБЛАСТЬ
------------------------------------------------------------
local content = new("Frame", {
	Position = UDim2.fromOffset(SIDE_W, 0), Size = UDim2.new(0, CONTENT_W, 1, -BAR_H),
	bg = "bg", BorderSizePixel = 0, Parent = main,
})

local banner = new("Frame", {
	Size = UDim2.new(1, 0, 0, 130), BackgroundColor3 = rgb(60, 40, 120), BorderSizePixel = 0, Parent = content,
})
local bannerFade = new("Frame", { Size = UDim2.fromScale(1, 1), bg = "bg", BorderSizePixel = 0, Parent = banner })
new("UIGradient", {
	Rotation = 90,
	Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) }),
	Parent = bannerFade,
})

local bannerCover = new("Frame", {
	Position = UDim2.fromOffset(28, 34), Size = UDim2.fromOffset(84, 84),
	BackgroundColor3 = rgb(255, 255, 255), BorderSizePixel = 0, Parent = banner,
})
corner(bannerCover, 8)
local bannerCoverGrad = new("UIGradient", {
	Color = ColorSequence.new(rgb(30, 215, 96), rgb(60, 40, 120)), Rotation = 45, Parent = bannerCover,
})
local bannerCoverScale = new("UIScale", { Parent = bannerCover })
local bannerIcon = label({
	Text = "♪", Font = FONT_X, TextSize = 40, TextColor3 = rgb(255, 255, 255),
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
	Text = "", TextSize = 13, tc = "sub",
	Position = UDim2.fromOffset(128, 98), Size = UDim2.fromOffset(330, 18), Parent = banner,
})

local VIS_BARS = 16
local visBox = new("Frame", {
	Position = UDim2.fromOffset(CONTENT_W - 28 - VIS_BARS * 9, 40),
	Size = UDim2.fromOffset(VIS_BARS * 9, 74), BackgroundTransparency = 1, Parent = banner,
})
local bars = {}
for i = 1, VIS_BARS do
	local b = new("Frame", {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, (i - 1) * 9, 1, 0), Size = UDim2.fromOffset(6, 4),
		BackgroundColor3 = C.green, BackgroundTransparency = 0.15, BorderSizePixel = 0, Parent = visBox,
	})
	corner(b, 3)
	bars[i] = b
end

-- Тулбар
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
	Text = "⇅ " .. SORT_NAMES.manual, Font = FONT_B, TextSize = 12, tc = "text", bg = "elev",
	Position = UDim2.fromOffset(84, 10), Size = UDim2.fromOffset(128, 32), AutoButtonColor = false, Parent = toolbar,
})
corner(sortBtn, 16)
bouncy(sortBtn, 1.04)

local searchRow = new("Frame", {
	Position = UDim2.fromOffset(220, 10), Size = UDim2.fromOffset(184, 32), bg = "elev", Parent = toolbar,
})
corner(searchRow, 16)
label({
	Text = "🔍", TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center,
	Position = UDim2.fromOffset(4, 0), Size = UDim2.fromOffset(26, 32), Parent = searchRow,
})
local searchBox = new("TextBox", {
	PlaceholderText = "Поиск по трекам", PlaceholderColor3 = rgb(140, 140, 150), Text = "",
	ClearTextOnFocus = false, Font = FONT, TextSize = 13, tc = "text",
	TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1,
	Position = UDim2.fromOffset(30, 0), Size = UDim2.new(1, -58, 1, 0), Parent = searchRow,
})
local searchClear = new("TextButton", {
	Text = "✕", Font = FONT_B, TextSize = 12, tc = "sub", BackgroundTransparency = 1, Visible = false,
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(22, 22), Parent = searchRow,
})

local topHint = label({
	Text = "Чарт игроков · раз в минуту", TextSize = 12, tc = "sub", TextXAlignment = Enum.TextXAlignment.Right,
	Visible = false, Position = UDim2.new(1, -208, 0, 0), Size = UDim2.fromOffset(180, 52), Parent = toolbar,
})
local addRow = new("Frame", {
	Position = UDim2.new(1, -228, 0, 10), Size = UDim2.fromOffset(200, 32), bg = "elev", Parent = toolbar,
})
corner(addRow, 16)
local addBox = new("TextBox", {
	PlaceholderText = "Добавить по ID", PlaceholderColor3 = rgb(140, 140, 150), Text = "",
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

label({
	Text = "#", Font = FONT_B, TextSize = 12, tc = "sub", TextXAlignment = Enum.TextXAlignment.Center,
	Position = UDim2.fromOffset(12, 182), Size = UDim2.fromOffset(40, 22), Parent = content,
})
label({
	Text = "НАЗВАНИЕ", Font = FONT_B, TextSize = 12, tc = "sub",
	Position = UDim2.fromOffset(102, 182), Size = UDim2.fromOffset(200, 22), Parent = content,
})
new("Frame", {
	Position = UDim2.fromOffset(12, 204), Size = UDim2.new(1, -24, 0, 1), bg = "elev", BorderSizePixel = 0, Parent = content,
})

local listWrap = new("CanvasGroup", {
	Position = UDim2.fromOffset(12, 208), Size = UDim2.new(1, -24, 1, -208), BackgroundTransparency = 1, Parent = content,
})
local scroll = new("ScrollingFrame", {
	Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
	ScrollBarThickness = 4, ScrollBarImageColor3 = C.elev2,
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = listWrap,
})
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = scroll })
new("UIPadding", { PaddingTop = UDim.new(0, 4), Parent = scroll })
local emptyLbl = label({
	Text = "", TextSize = 14, tc = "sub", TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center,
	Visible = false, Position = UDim2.fromOffset(40, 50), Size = UDim2.new(1, -80, 0, 60), Parent = listWrap,
})

------------------------------------------------------------
-- НИЖНЯЯ ПАНЕЛЬ
------------------------------------------------------------
local bar = new("Frame", {
	Position = UDim2.new(0, 0, 1, -BAR_H), Size = UDim2.new(1, 0, 0, BAR_H), bg = "panel", BorderSizePixel = 0, Parent = main,
})
new("Frame", { Size = UDim2.new(1, 0, 0, 1), bg = "elev", BorderSizePixel = 0, Parent = bar })

local barCover = new("Frame", {
	Position = UDim2.fromOffset(16, 18), Size = UDim2.fromOffset(60, 60),
	BackgroundColor3 = rgb(255, 255, 255), BorderSizePixel = 0, Parent = bar,
})
corner(barCover, 6)
local barCoverGrad = new("UIGradient", {
	Color = ColorSequence.new(rgb(120, 120, 130), rgb(70, 70, 80)), Rotation = 45, Parent = barCover,
})
local barCoverScale = new("UIScale", { Parent = barCover })
label({
	Text = "♪", Font = FONT_B, TextSize = 26, TextColor3 = rgb(255, 255, 255),
	TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = barCover,
})
local barTitle = label({
	Text = "Ничего не играет", Font = FONT_B, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(88, 26), Size = UDim2.fromOffset(126, 20), Parent = bar,
})
local barArtist = label({
	Text = "Выбери трек", TextSize = 12, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(88, 47), Size = UDim2.fromOffset(126, 16), Parent = bar,
})
local barHeart = new("TextButton", {
	Text = "♥", Font = FONT_B, TextSize = 20, tc = "elev2", BackgroundTransparency = 1,
	Position = UDim2.fromOffset(220, 31), Size = UDim2.fromOffset(30, 34), Parent = bar,
})
bouncy(barHeart, 1.15)

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
prevBtn.TextColor3 = C.text
nextBtn.TextColor3 = C.text
themed[#themed + 1] = { prevBtn, "TextColor3", "text" }
themed[#themed + 1] = { nextBtn, "TextColor3", "text" }

-- Слайдер: opts = {onHover, onLeave, onRight, onWheel}
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
		fill.BackgroundColor3 = C.green
		knob.Visible = true
	end)
	hit.MouseLeave:Connect(function()
		if not dragging then
			fill.BackgroundColor3 = C.text
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
			fill.BackgroundColor3 = C.green
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
			fill.BackgroundColor3 = C.text
			knob.Visible = false
		end
	end)
	return {
		Set = function(a) if not dragging then fill.Size = UDim2.fromScale(a, 1) end end,
		IsDragging = function() return dragging end,
	}
end

local curTime = label({
	Text = "0:00", TextSize = 11, tc = "sub", TextXAlignment = Enum.TextXAlignment.Right,
	Position = UDim2.fromOffset(0, 48), Size = UDim2.fromOffset(36, 16), Parent = center,
})
local totTime = label({
	Text = "0:00", TextSize = 11, tc = "sub",
	Position = UDim2.fromOffset(294, 48), Size = UDim2.fromOffset(36, 16), Parent = center,
})

-- подсказка времени над прогрессом
local tip = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromOffset(42, 46), Size = UDim2.fromOffset(52, 18),
	bg = "elev", Visible = false, ZIndex = 10, Parent = center,
})
corner(tip, 9)
local tipLbl = label({
	Text = "0:00", Font = FONT_B, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Center,
	Size = UDim2.fromScale(1, 1), ZIndex = 11, Parent = tip,
})
local function showTip(a, text)
	tip.Position = UDim2.fromOffset(42 + a * 246, 46)
	tipLbl.Text = text
	tip.Visible = true
end

local progress
progress = makeSlider(center, UDim2.fromOffset(42, 55), UDim2.fromOffset(246, 4), 0, function(a)
	if sound and sound.TimeLength > 0 then
		sound.TimePosition = a * sound.TimeLength
		curTime.Text = formatTime(sound.TimePosition)
	end
end, {
	onHover = function(a)
		if sound and sound.TimeLength > 0 then showTip(a, formatTime(a * sound.TimeLength)) end
	end,
	onLeave = function() tip.Visible = false end,
	onRight = function(a)
		if sound and sound.TimeLength > 0 then addMarker(a * sound.TimeLength) end
	end,
})

local markerLayer = new("Frame", {
	Position = UDim2.fromOffset(42, 49), Size = UDim2.fromOffset(246, 16),
	BackgroundTransparency = 1, ZIndex = 6, Parent = center,
})
local markerBtns = {}

-- Справа: громкость и звук
local right = new("Frame", {
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16, 0.5, 0),
	Size = UDim2.fromOffset(222, 40), BackgroundTransparency = 1, Parent = bar,
})
label({
	Text = "🔊", TextSize = 15, TextXAlignment = Enum.TextXAlignment.Center,
	Size = UDim2.fromOffset(22, 40), Parent = right,
})
local volume
volume = makeSlider(right, UDim2.fromOffset(28, 18), UDim2.fromOffset(100, 4), state.volume, function(a)
	state.volume = a
	applyAudio()
	markDirty()
end, { onWheel = function(z) setVolume(state.volume + z * 0.05) end })
local eqBtn = new("TextButton", {
	Text = "Звук ⚙", Font = FONT_B, TextSize = 13, tc = "text", bg = "elev",
	Position = UDim2.fromOffset(142, 5), Size = UDim2.fromOffset(80, 30), AutoButtonColor = false, Parent = right,
})
corner(eqBtn, 15)
bouncy(eqBtn, 1.06)

------------------------------------------------------------
-- ПОПАПЫ
------------------------------------------------------------
local blocker = new("TextButton", {
	Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 40, Parent = main,
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

-- универсальное меню (ПКМ, "добавить в плейлист", подтверждения)
local menu = new("CanvasGroup", {
	Size = UDim2.fromOffset(230, 200), bg = "elev", Visible = false, ZIndex = 50, Parent = main,
})
corner(menu, 10)
local menuTitle = label({
	Text = "", Font = FONT_B, TextSize = 13, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(14, 8), Size = UDim2.new(1, -28, 0, 22), Parent = menu,
})
local menuList = new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
	Position = UDim2.fromOffset(6, 34), Size = UDim2.new(1, -12, 1, -40),
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = menu,
})
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = menuList })

-- попап звука
local eqPopup = new("CanvasGroup", {
	AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -BAR_H - 8),
	Size = UDim2.fromOffset(290, 364), bg = "elev", Visible = false, ZIndex = 50, Parent = main,
})
corner(eqPopup, 12)
label({
	Text = "Звук и эффекты", Font = FONT_B, TextSize = 16,
	Position = UDim2.fromOffset(20, 14), Size = UDim2.new(1, -40, 0, 22), Parent = eqPopup,
})
local function popLabel(text, y)
	return label({
		Text = text, TextSize = 13, tc = "sub",
		Position = UDim2.fromOffset(20, y), Size = UDim2.fromOffset(160, 18), Parent = eqPopup,
	})
end
local function popValue(y)
	return label({
		Text = "", Font = FONT_B, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromOffset(190, y), Size = UDim2.fromOffset(80, 18), Parent = eqPopup,
	})
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
	tween(b, 0.15, { BackgroundColor3 = on and C.green or C.chip })
	b.TextColor3 = on and C.ink or C.text
end

local speedChips = {}
for i, s in ipairs({ { 0.8, "0.8×" }, { 1, "1×" }, { 1.25, "1.25×" } }) do
	speedChips[i] = { btn = chip(eqPopup, s[2], 20 + (i - 1) * 86, 178, 78), value = s[1] }
end
local function refreshSpeedChips()
	for _, c in ipairs(speedChips) do chipActive(c.btn, c.value == speed) end
end
function setSpeed(v)
	speed = v
	if sound then sound.PlaybackSpeed = v end
	refreshSpeedChips()
end
for _, c in ipairs(speedChips) do
	c.btn.Activated:Connect(function() setSpeed(c.value) end)
end

local sw = new("TextButton", {
	Text = "", bg = "chip", Position = UDim2.fromOffset(226, 223), Size = UDim2.fromOffset(44, 22),
	AutoButtonColor = false, Parent = eqPopup,
})
corner(sw, 11)
local swKnob = new("Frame", {
	AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), Size = UDim2.fromOffset(16, 16),
	BackgroundColor3 = rgb(255, 255, 255), BorderSizePixel = 0, Parent = sw,
})
corner(swKnob, 8)

local bassSlider, xfSlider
local function setBass(a, fromSlider)
	state.bass = a
	applyAudio()
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
	applyAudio()
	local t = instant and 0 or 0.2
	tween(sw, t, { BackgroundColor3 = v and C.green or C.chip })
	tween(swKnob, t, { Position = v and UDim2.new(1, -19, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) }, Enum.EasingStyle.Back)
	markDirty()
end
bassSlider = makeSlider(eqPopup, UDim2.fromOffset(20, 78), UDim2.fromOffset(250, 6), state.bass, function(a)
	setBass(a, true)
end)
xfSlider = makeSlider(eqPopup, UDim2.fromOffset(20, 130), UDim2.fromOffset(250, 6), state.crossfade / 12, function(a)
	setCrossfade(a * 12, true)
end)
sw.Activated:Connect(function() setReverb(not state.reverb) end)

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
		notify("Пресет: " .. p[1])
	end)
end

-- попап горячих клавиш
local keysPopup = new("CanvasGroup", {
	AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(400, 470), bg = "elev", Visible = false, ZIndex = 50, Parent = main,
})
corner(keysPopup, 14)
label({
	Text = "Горячие клавиши", Font = FONT_B, TextSize = 17,
	Position = UDim2.fromOffset(20, 14), Size = UDim2.new(1, -40, 0, 24), Parent = keysPopup,
})
label({
	Text = "Нажми на кнопку справа и затем на новую клавишу (Backspace — снять, Esc — отмена).\nМышь: ПКМ по треку — меню · ПКМ по полосе — маркер · колесо над громкостью.",
	TextSize = 11, tc = "sub", TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
	Position = UDim2.fromOffset(20, 40), Size = UDim2.new(1, -40, 0, 44), Parent = keysPopup,
})
local keysList = new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
	Position = UDim2.fromOffset(12, 90), Size = UDim2.new(1, -24, 1, -142),
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = keysPopup,
})
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = keysList })
local keysReset = chip(keysPopup, "Сбросить всё", 20, 428, 120)
local keysClose = chip(keysPopup, "Закрыть", 280, 428, 100)

local listening
function refreshKeys()
	for _, c in ipairs(keysList:GetChildren()) do
		if c:IsA("Frame") then c:Destroy() end
	end
	for i, a in ipairs(ACTIONS) do
		local row = new("Frame", { Size = UDim2.new(1, -8, 0, 32), BackgroundTransparency = 1, LayoutOrder = i, Parent = keysList })
		label({ Text = a.name, TextSize = 13, Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -120, 1, 0), Parent = row })
		local waiting = listening == a.id
		local kb = new("TextButton", {
			Text = waiting and "нажми…" or keyLabel(a.id), Font = FONT_B, TextSize = 12,
			TextColor3 = waiting and C.ink or C.text, BackgroundColor3 = waiting and C.green or C.chip,
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
keysReset.Activated:Connect(function()
	state.binds = {}
	listening = nil
	refreshKeys()
	markDirty()
	notify("Клавиши сброшены")
end)

function closePopups()
	hidePopup(eqPopup)
	hidePopup(menu)
	hidePopup(keysPopup)
	blocker.Visible = false
	listening = nil
end
keysClose.Activated:Connect(closePopups)
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
keysBtn.Activated:Connect(function()
	closePopups()
	refreshKeys()
	showPopup(keysPopup)
	blocker.Visible = true
end)

------------------------------------------------------------
-- ВЕРХНЯЯ ПОЛОСА, КНОПКА-ТОГГЛ, МИНИ-РЕЖИМ
------------------------------------------------------------
local dragHandle = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, ZIndex = 5, Parent = main })
do
	local dragging, dragStart, startPos
	dragHandle.InputBegan:Connect(function(input)
		if isPointer(input) then
			dragging, dragStart, startPos = true, input.Position, root.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and isMove(input) then
			local d = (input.Position - dragStart) / uiScale.Scale
			root.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if isPointer(input) then dragging = false end
	end)
end

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

-- мини-плеер
local miniRoot = new("CanvasGroup", {
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -74), Size = UDim2.fromOffset(360, 76),
	bg = "panel", Visible = false, Parent = gui,
})
corner(miniRoot, 14)
local miniScale = new("UIScale", { Parent = miniRoot })
local miniCover = new("Frame", {
	Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(54, 54),
	BackgroundColor3 = rgb(255, 255, 255), BorderSizePixel = 0, Parent = miniRoot,
})
corner(miniCover, 8)
local miniCoverGrad = new("UIGradient", {
	Color = ColorSequence.new(rgb(120, 120, 130), rgb(70, 70, 80)), Rotation = 45, Parent = miniCover,
})
local miniCoverScale = new("UIScale", { Parent = miniCover })
label({
	Text = "♪", Font = FONT_B, TextSize = 22, TextColor3 = rgb(255, 255, 255),
	TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = miniCover,
})
local miniTitle = label({
	Text = "Ничего не играет", Font = FONT_B, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(74, 16), Size = UDim2.fromOffset(126, 20), Parent = miniRoot,
})
local miniArtist = label({
	Text = "", TextSize = 12, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(74, 38), Size = UDim2.fromOffset(126, 16), Parent = miniRoot,
})
local miniDrag = new("Frame", { Size = UDim2.fromOffset(204, 76), BackgroundTransparency = 1, Parent = miniRoot })
local function miniBtnMake(text, x, size, circle)
	local b = new("TextButton", {
		Text = text, Font = FONT_B, TextSize = size, tc = circle and "bg" or "text",
		BackgroundTransparency = circle and 0 or 1, bg = circle and "text" or nil,
		Position = UDim2.fromOffset(x, circle and 19 or 22), Size = UDim2.fromOffset(circle and 38 or 30, circle and 38 or 32),
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
miniExpand.TextColor3 = C.sub
themed[#themed + 1] = { miniExpand, "TextColor3", "sub" }
local miniTrack = new("Frame", {
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 3), bg = "elev", BorderSizePixel = 0, Parent = miniRoot,
})
local miniFill = new("Frame", { Size = UDim2.fromScale(0, 1), bg = "green", BorderSizePixel = 0, Parent = miniTrack })

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

function setMode(m)
	if m == uiMode then return end
	local old = uiMode
	uiMode = m
	if m ~= "hidden" then lastShown = m end
	closePopups()

	if old == "full" then
		local tw = tween(main, 0.2, { Position = UDim2.fromOffset(0, 18), GroupTransparency = 1 })
		tw.Completed:Connect(function()
			if uiMode ~= "full" then main.Visible = false end
		end)
	elseif old == "mini" then
		local tw = tween(miniRoot, 0.2, { GroupTransparency = 1 })
		tw.Completed:Connect(function()
			if uiMode ~= "mini" then miniRoot.Visible = false end
		end)
	end

	if m == "full" then
		main.Visible = true
		main.Position = UDim2.fromOffset(0, 28)
		main.GroupTransparency = 1
		tween(main, 0.4, { Position = UDim2.fromOffset(0, 0), GroupTransparency = 0 }, Enum.EasingStyle.Quint)
	elseif m == "mini" then
		miniRoot.Visible = true
		miniRoot.GroupTransparency = 1
		miniScale.Scale = 0.9
		tween(miniRoot, 0.3, { GroupTransparency = 0 })
		tween(miniScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
	end
end

------------------------------------------------------------
-- СОХРАНЕНИЕ
------------------------------------------------------------
local function pushSave()
	if not (loaded and remSave) then return end
	remSave:FireServer({
		playlists = state.playlists, liked = state.liked, volume = state.volume, bass = state.bass,
		reverb = state.reverb, last = state.last, theme = state.theme, crossfade = state.crossfade,
		binds = state.binds, markers = state.markers,
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
-- МЕТАДАННЫЕ ТРЕКОВ
------------------------------------------------------------
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

------------------------------------------------------------
-- МАРКЕРЫ НА ПРОГРЕСС-БАРЕ
------------------------------------------------------------
local function markersFor(track, create)
	local key = tostring(track.id)
	local list = state.markers[key]
	if not list and create then
		list = {}
		state.markers[key] = list
	end
	return list
end

function rebuildMarkers()
	for _, b in ipairs(markerBtns) do b:Destroy() end
	markerBtns = {}
	if not current or not sound or sound.TimeLength <= 0 then return end
	local list = markersFor(current, false)
	if not list then return end
	local len = sound.TimeLength
	for i, sec in ipairs(list) do
		local a = math.clamp(sec / len, 0, 1)
		local b = new("TextButton", {
			Text = "", BackgroundColor3 = C.marker, AnchorPoint = Vector2.new(0.5, 0.5),
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
			markerLen = -1
			markDirty()
			notify("Маркер удалён")
		end)
		b.MouseEnter:Connect(function() showTip(a, "⚑ " .. formatTime(sec)) end)
		b.MouseLeave:Connect(function() tip.Visible = false end)
		markerBtns[#markerBtns + 1] = b
	end
end

function addMarker(sec)
	if not (current and sound and sound.TimeLength > 0) then
		notify("Сначала включи трек")
		return
	end
	sec = sec or sound.TimePosition
	sec = math.floor(sec * 10) / 10
	local list = markersFor(current, true)
	if #list >= 20 then
		notify("Максимум 20 маркеров на трек")
		return
	end
	table.insert(list, sec)
	table.sort(list)
	markerLen = -1
	markDirty()
	notify("⚑ Маркер " .. formatTime(sec) .. " (ПКМ по маркеру — удалить)")
end

------------------------------------------------------------
-- ВОСПРОИЗВЕДЕНИЕ (+ кроссфейд)
------------------------------------------------------------
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
	s.SoundGroup = group
	s.PlaybackSpeed = speed
	s.Looped = (repeatMode == 2)
	s.Volume = fadeSec > 0 and 0 or 1
	s.Parent = SoundService
	sound = s
	markerLen = -1

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
		if s == sound and my == playToken then nextTrack(true, false) end
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
				if my == playToken then nextTrack(true, false) end
			end
		end
	end)
end

function playFromList(list, i)
	queue = {}
	for k, t in ipairs(list) do queue[k] = t end
	failStreak = 0
	playAt(i, math.min(state.crossfade, 0.8))
end

-- auto: следующий трек сам; early: запуск за N секунд до конца (кроссфейд)
function nextTrack(auto, early)
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
	if target then playAt(target, fadeSec) end
end

function prevTrack()
	if #queue == 0 then return end
	if sound and sound.TimePosition > 3 then
		sound.TimePosition = 0
		return
	end
	local c = qi - 1
	if c < 1 then c = #queue end
	playAt(c, math.min(state.crossfade, 0.8))
end

function togglePlay()
	if not sound then
		local list = displayList()
		if #list > 0 then playFromList(list, shuffle and math.random(#list) or 1) end
	elseif sound.IsPlaying then
		sound:Pause()
	else
		sound:Play()
	end
end

function setVolume(a)
	state.volume = math.clamp(a, 0, 1)
	applyAudio()
	volume.Set(state.volume)
	markDirty()
end

------------------------------------------------------------
-- ОБНОВЛЕНИЕ ИНТЕРФЕЙСА
------------------------------------------------------------
local rows, sideBtns = {}, {}

local function refreshRowStates()
	for i, r in ipairs(rows) do
		local active = current ~= nil and r.track.id == current.id
		local bad = badIds[r.track.id]
		r.title.TextColor3 = bad and C.red or (active and C.green or C.text)
		r.num.TextColor3 = active and C.green or C.sub
		r.num.Text = (active and sound and sound.IsPlaying) and "♪" or tostring(i)
	end
end

function updateHearts()
	for _, r in ipairs(rows) do
		r.heart.TextColor3 = isLiked(r.track.id) and C.green or C.elev2
	end
	barHeart.TextColor3 = (current and isLiked(current.id)) and C.green or C.elev2
end

function updatePlayState()
	local playing = sound ~= nil and sound.IsPlaying
	local g = playing and "II" or "▶"
	playBtn.Text, bigPlay.Text, miniPlay.Text = g, g, g
	refreshRowStates()
end

function updateNowPlaying()
	local t = current
	if t then
		barTitle.Text = t.title or "Загрузка…"
		barArtist.Text = t.artist or ""
		local cs = ColorSequence.new(accent(t.id, 0.95), accent(t.id, 0.45))
		barCoverGrad.Color = cs
		miniCoverGrad.Color = cs
	else
		barTitle.Text = "Ничего не играет"
		barArtist.Text = "Выбери трек"
		local cs = ColorSequence.new(rgb(120, 120, 130), rgb(70, 70, 80))
		barCoverGrad.Color = cs
		miniCoverGrad.Color = cs
	end
	miniTitle.Text = barTitle.Text
	miniArtist.Text = barArtist.Text
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
		miniTitle.Text, miniArtist.Text = barTitle.Text, barArtist.Text
	end
end

function renderBanner()
	local title, kind, icon, h
	if view.kind == "liked" then
		title, kind, icon, h = "Любимое", "ПЛЕЙЛИСТ", "♥", 0.72
	elseif view.kind == "top" then
		title, kind, icon, h = "Топ чарт", "ПОПУЛЯРНОЕ СРЕДИ ИГРОКОВ", "🔥", 0.02
	elseif view.kind == "search" then
		title, kind, icon, h = "Поиск", "РЕЗУЛЬТАТЫ ПО ВСЕЙ БИБЛИОТЕКЕ", "🔍", 0.55
	else
		local p = state.playlists[view.index]
		title, kind, icon, h = p.name, "ПЛЕЙЛИСТ", "♪", hueFor(p.name)
	end
	bannerTitle.Text = title
	bannerKind.Text = kind
	bannerIcon.Text = icon
	bannerSub.Text = (view.kind == "top" and topState == "loading") and "Загрузка…" or pluralTracks(#currentList())
	tween(banner, 0.5, { BackgroundColor3 = accentH(h, C.bannerV, C.bannerS) })
	bannerCoverGrad.Color = ColorSequence.new(accentH(h, 0.95), accentH(h, 0.45))
	local editable = view.kind == "pl" or view.kind == "liked"
	addRow.Visible = editable
	sortBtn.Visible = editable
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

function openAddMenu(track, at)
	local items = {}
	for i, p in ipairs(state.playlists) do
		items[#items + 1] = { text = p.name, fn = function() addToPlaylist(i, track) end }
	end
	openMenu("Добавить в плейлист", items, at)
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
	renderList()
	renderBanner()
end

-- Контекстное меню трека (ПКМ)
function openTrackMenu(track, list, idx)
	local at = pointer()
	local items = {
		{ text = "▶  Играть", fn = function() playFromList(list, idx) end },
		{
			text = "⏭  Играть следующим",
			fn = function()
				if #queue == 0 then
					playFromList({ track }, 1)
				else
					table.insert(queue, qi + 1, track)
					notify("Будет играть следующим")
				end
			end,
		},
		{
			text = isLiked(track.id) and "♥  Убрать из любимого" or "♥  В любимое",
			fn = function() toggleLike(track) end,
		},
		{ text = "＋  В плейлист…", fn = function() openAddMenu(track, at) end },
	}
	if view.kind == "pl" or view.kind == "liked" then
		items[#items + 1] = { text = "✕  Убрать из списка", color = C.red, fn = function() removeFromView(track) end }
	end
	items[#items + 1] = { text = "ⓘ  Показать ID", fn = function() notify("ID аудио: " .. track.id) end }
	openMenu(track.title or "Трек", items, at)
end

------------------------------------------------------------
-- DRAG & DROP (мышь)
------------------------------------------------------------
local cand, drag, dropFlag = nil, nil, false

local function resetDropHighlights()
	for _, sb in ipairs(sideBtns) do
		sb.btn.BackgroundTransparency = sb.active and 0 or 1
	end
	navLiked.BackgroundTransparency = view.kind == "liked" and 0 or 1
end

local function startDrag(track)
	local ghost = new("Frame", {
		Size = UDim2.fromOffset(230, 38), BackgroundColor3 = C.elev, ZIndex = 200, Parent = gui,
	})
	corner(ghost, 8)
	new("UIScale", { Scale = uiScale.Scale, Parent = ghost })
	new("UIStroke", { Color = C.green, Thickness = 1.5, Parent = ghost })
	label({
		Text = "♪  " .. (track.title or "Трек"), Font = FONT_B, TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = C.text, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -20, 1, 0), ZIndex = 201, Parent = ghost,
	})
	local line = new("Frame", {
		BackgroundColor3 = C.green, BorderSizePixel = 0, Visible = false, ZIndex = 150, Parent = gui,
	})
	drag = { track = track, ghost = ghost, line = line }
end

local function updateDrag()
	local p = pointer()
	drag.ghost.Position = UDim2.fromOffset(p.X + 14, p.Y + 10)
	drag.target = nil
	drag.line.Visible = false
	resetDropHighlights()

	for i, sb in ipairs(sideBtns) do
		if inside(sb.btn, p) then
			drag.target = { kind = "pl", index = i }
			sb.btn.BackgroundTransparency = 0.3
			return
		end
	end
	if inside(navLiked, p) then
		drag.target = { kind = "liked" }
		navLiked.BackgroundTransparency = 0.3
		return
	end
	if (view.kind == "pl" or view.kind == "liked") and sortMode == "manual" and inside(listWrap, p) then
		local idx = #rows + 1
		for i, r in ipairs(rows) do
			local a, s = r.button.AbsolutePosition, r.button.AbsoluteSize
			if p.Y < a.Y + s.Y / 2 then
				idx = i
				break
			end
		end
		drag.target = { kind = "reorder", index = idx }
		local y
		if idx <= #rows then
			y = rows[idx].button.AbsolutePosition.Y
		elseif #rows > 0 then
			local lr = rows[#rows].button
			y = lr.AbsolutePosition.Y + lr.AbsoluteSize.Y
		else
			y = listWrap.AbsolutePosition.Y
		end
		drag.line.Position = UDim2.fromOffset(listWrap.AbsolutePosition.X + 10, y - 1)
		drag.line.Size = UDim2.fromOffset(listWrap.AbsoluteSize.X - 20, 2)
		drag.line.Visible = true
	end
end

local function finishDrag()
	local d = drag
	drag = nil
	d.ghost:Destroy()
	d.line:Destroy()
	resetDropHighlights()
	dropFlag = true
	task.delay(0.2, function() dropFlag = false end)

	local t = d.target
	if not t then return end
	if t.kind == "pl" then
		addToPlaylist(t.index, d.track)
	elseif t.kind == "liked" then
		if isLiked(d.track.id) then
			notify("Уже в любимом")
		else
			toggleLike(d.track)
		end
	elseif t.kind == "reorder" then
		local list = currentList()
		local from
		for i, tk in ipairs(list) do
			if tk == d.track then
				from = i
				break
			end
		end
		if from then
			local to = t.index
			table.remove(list, from)
			if to > from then to -= 1 end
			table.insert(list, to, d.track)
			markDirty()
			renderList()
		end
	end
end

UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
	if cand and not drag and (pointer() - cand.startPos).Magnitude > 8 then
		startDrag(cand.track)
	end
	if drag then updateDrag() end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		cand = nil
		if drag then finishDrag() end
	end
end)

------------------------------------------------------------
-- МЕНЮ
------------------------------------------------------------
function openMenu(title, items, at)
	closePopups()
	for _, c in ipairs(menuList:GetChildren()) do
		if c:IsA("TextButton") then c:Destroy() end
	end
	local hasTitle = title ~= nil and title ~= ""
	menuTitle.Visible = hasTitle
	menuTitle.Text = title or ""
	menuList.Position = UDim2.fromOffset(6, hasTitle and 34 or 6)
	for i, it in ipairs(items) do
		local b = new("TextButton", {
			Text = "  " .. it.text, Font = FONT, TextSize = 14, TextColor3 = it.color or C.text,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
			BackgroundColor3 = C.chip, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32),
			AutoButtonColor = false, LayoutOrder = i, Parent = menuList,
		})
		corner(b, 6)
		b.MouseEnter:Connect(function() tween(b, 0.1, { BackgroundTransparency = 0 }) end)
		b.MouseLeave:Connect(function() tween(b, 0.1, { BackgroundTransparency = 1 }) end)
		b.Activated:Connect(function()
			closePopups()
			it.fn()
		end)
	end
	local h = math.min(320, (hasTitle and 40 or 12) + #items * 32)
	menu.Size = UDim2.fromOffset(230, h)
	local rel = (at - main.AbsolutePosition) / uiScale.Scale
	menu.Position = UDim2.fromOffset(
		math.clamp(rel.X, 6, W - 236),
		math.clamp(rel.Y, 40, H - BAR_H - h - 4)
	)
	blocker.Visible = true
	showPopup(menu)
end

------------------------------------------------------------
-- СПИСОК ТРЕКОВ
------------------------------------------------------------
function renderList()
	for _, r in ipairs(rows) do r.button:Destroy() end
	rows = {}
	if view.kind == "search" then searchList = buildSearch(searchQuery) end
	local list = displayList()

	emptyLbl.Visible = false
	if view.kind == "top" and topState == "loading" then
		emptyLbl.Text = "Загрузка чарта…"
		emptyLbl.Visible = true
	elseif #list == 0 then
		if view.kind == "top" then
			emptyLbl.Text = "Чарт пока пуст. Слушай музыку — треки появятся здесь."
		elseif view.kind == "search" then
			emptyLbl.Text = "Ничего не найдено. Ищу по названию, исполнителю и ID."
		else
			emptyLbl.Text = "Здесь пока пусто. Добавь трек по ID или через «+» у любого трека."
		end
		emptyLbl.Visible = true
	end

	for i, track in ipairs(list) do
		local btn = new("TextButton", {
			Text = "", Size = UDim2.new(1, -8, 0, 52), BackgroundColor3 = C.hover, BackgroundTransparency = 1,
			AutoButtonColor = false, LayoutOrder = i, Parent = scroll,
		})
		corner(btn, 8)
		local num = label({
			Text = tostring(i), TextColor3 = C.sub, TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.fromOffset(40, 52), Parent = btn,
		})
		local mini = new("Frame", {
			Position = UDim2.fromOffset(46, 9), Size = UDim2.fromOffset(34, 34),
			BackgroundColor3 = rgb(255, 255, 255), BorderSizePixel = 0, Parent = btn,
		})
		corner(mini, 5)
		new("UIGradient", {
			Color = ColorSequence.new(accent(track.id, 0.95), accent(track.id, 0.45)), Rotation = 45, Parent = mini,
		})
		label({
			Text = "♪", Font = FONT_B, TextSize = 16, TextColor3 = rgb(255, 255, 255),
			TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = mini,
		})
		local title = label({
			Text = track.title or "Загрузка…", Font = FONT_B, TextSize = 14, TextColor3 = C.text,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(90, 8), Size = UDim2.new(1, -230, 0, 20), Parent = btn,
		})
		local artist = label({
			Text = track.artist or "", TextSize = 12, TextColor3 = C.sub, TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(90, 28), Size = UDim2.new(1, -230, 0, 16), Parent = btn,
		})

		local function iconBtn(text, x, color)
			local b = new("TextButton", {
				Text = text, Font = FONT_B, TextSize = 18, TextColor3 = color or C.elev2, BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, x, 0.5, 0), Size = UDim2.fromOffset(30, 30), Parent = btn,
			})
			bouncy(b, 1.15)
			return b
		end
		local heart = iconBtn("♥", -86)
		local addB = iconBtn("+", -50, C.sub)
		heart.Activated:Connect(function()
			toggleLike(track)
			pop(heart)
		end)
		addB.Activated:Connect(function()
			openAddMenu(track, addB.AbsolutePosition + Vector2.new(-200, 28))
		end)

		if view.kind == "top" then
			label({
				Text = tostring(track.plays or 0) .. " ▶", Font = FONT_B, TextSize = 12, TextColor3 = C.sub,
				TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(40, 20), Parent = btn,
			})
		elseif view.kind == "pl" or view.kind == "liked" then
			local rm = iconBtn("✕", -14, C.sub)
			rm.Activated:Connect(function() removeFromView(track) end)
		end

		btn.MouseEnter:Connect(function() tween(btn, 0.12, { BackgroundTransparency = 0 }) end)
		btn.MouseLeave:Connect(function() tween(btn, 0.12, { BackgroundTransparency = 1 }) end)
		btn.Activated:Connect(function()
			if dropFlag or drag then return end
			playFromList(list, i)
		end)
		btn.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				cand = { track = track, startPos = pointer() }
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				openTrackMenu(track, list, i)
			end
		end)

		rows[i] = { button = btn, track = track, num = num, title = title, artist = artist, heart = heart }
	end
	updateHearts()
	refreshRowStates()
end

------------------------------------------------------------
-- САЙДБАР: плейлисты
------------------------------------------------------------
local armedDelete, renameIndex

local function deletePlaylist(i)
	if #state.playlists <= 1 then
		notify("Нельзя удалить единственный плейлист")
		return
	end
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
end

local function startRename(i)
	renameIndex = i
	plNameBox.Text = state.playlists[i].name
	plNameBox.Visible = true
	layoutSidebar()
	plNameBox:CaptureFocus()
end

local function openPlaylistMenu(i)
	local at = pointer()
	local p = state.playlists[i]
	openMenu(p.name, {
		{
			text = "▶  Играть",
			fn = function()
				if #p.tracks > 0 then playFromList(p.tracks, 1) end
			end,
		},
		{ text = "✎  Переименовать", fn = function() startRename(i) end },
		{
			text = "✕  Удалить…", color = C.red,
			fn = function()
				openMenu("Удалить «" .. p.name .. "»?", {
					{ text = "Да, удалить", color = C.red, fn = function() deletePlaylist(i) end },
					{ text = "Отмена", fn = function() end },
				}, at)
			end,
		},
	}, at)
end

function renderSidebar()
	local function setNav(btn, ic, tx, active)
		btn.BackgroundTransparency = active and 0 or 1
		tx.TextColor3 = active and C.text or C.sub
		ic.TextColor3 = active and C.green or C.sub
	end
	setNav(navLiked, navLikedIc, navLikedTx, view.kind == "liked")
	setNav(navTop, navTopIc, navTopTx, view.kind == "top")

	for _, c in ipairs(plScroll:GetChildren()) do
		if c:IsA("GuiButton") then c:Destroy() end
	end
	sideBtns = {}
	for i, p in ipairs(state.playlists) do
		local active = view.kind == "pl" and view.index == i
		local b, ic, tx = sideButton(plScroll, nil, "♪", p.name)
		b.LayoutOrder = i
		b.Size = UDim2.new(1, -6, 0, 38)
		b.BackgroundColor3 = C.elev
		tx.TextColor3 = active and C.text or C.sub
		ic.TextColor3 = active and C.green or C.sub
		b.BackgroundTransparency = active and 0 or 1
		sideBtns[i] = { btn = b, active = active }
		b.Activated:Connect(function()
			state.last = i
			markDirty()
			setView({ kind = "pl", index = i })
		end)
		b.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton2 then openPlaylistMenu(i) end
		end)
		if #state.playlists > 1 then
			tx.Size = UDim2.new(1, -86, 1, 0)
			local del = new("TextButton", {
				Text = armedDelete == i and "Точно?" or "✕", Font = FONT_B, TextSize = 12,
				TextColor3 = armedDelete == i and C.red or C.sub, BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(46, 26), Parent = b,
			})
			del.Activated:Connect(function()
				if armedDelete == i then
					armedDelete = nil
					deletePlaylist(i)
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

local suppressSearch = false
function setView(v)
	view = v
	closePopups()
	if v.kind ~= "search" and searchBox.Text ~= "" then
		suppressSearch = true
		searchBox.Text = ""
		suppressSearch = false
		searchClear.Visible = false
		prevView = nil
	end
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
-- ТЕМА
------------------------------------------------------------
function applyTheme(name, instant)
	C = THEMES[name] or THEMES.dark
	state.theme = (C == THEMES.light) and "light" or "dark"
	local alive = {}
	for _, e in ipairs(themed) do
		if e[1].Parent then
			alive[#alive + 1] = e
			if instant then
				e[1][e[2]] = C[e[3]]
			else
				tween(e[1], 0.25, { [e[2]] = C[e[3]] })
			end
		end
	end
	themed = alive
	plScroll.ScrollBarImageColor3 = C.elev2
	scroll.ScrollBarImageColor3 = C.elev2
	for _, b in ipairs(bars) do b.BackgroundColor3 = C.green end
	shuffleBtn.TextColor3 = shuffle and C.green or C.sub
	repeatBtn.TextColor3 = repeatMode > 0 and C.green or C.sub
	themeBtn.Text = state.theme == "dark" and "☀" or "☾"
	setReverb(state.reverb, true)
	refreshSpeedChips()
	closePopups()
	renderSidebar()
	renderBanner()
	renderList()
	updateNowPlaying()
	markerLen = -1
end

------------------------------------------------------------
-- СОБЫТИЯ UI
------------------------------------------------------------
navLiked.Activated:Connect(function() setView({ kind = "liked" }) end)
navTop.Activated:Connect(function() setView({ kind = "top" }) end)

plAddBtn.Activated:Connect(function()
	renameIndex = nil
	plNameBox.Text = ""
	plNameBox.Visible = not plNameBox.Visible
	layoutSidebar()
	if plNameBox.Visible then plNameBox:CaptureFocus() end
end)
plNameBox.FocusLost:Connect(function(enter)
	local name = plNameBox.Text:match("^%s*(.-)%s*$")
	if enter and name ~= "" then
		if renameIndex and state.playlists[renameIndex] then
			state.playlists[renameIndex].name = cutText(name, 24)
			markDirty()
			notify("Переименовано")
			renderSidebar()
			if view.kind == "pl" and view.index == renameIndex then renderBanner() end
		elseif not renameIndex then
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
	end
	renameIndex = nil
	plNameBox.Text = ""
	plNameBox.Visible = false
	layoutSidebar()
end)

sortBtn.Activated:Connect(function()
	local idx = table.find(SORTS, sortMode) or 1
	sortMode = SORTS[idx % #SORTS + 1]
	sortBtn.Text = "⇅ " .. SORT_NAMES[sortMode]
	renderList()
	if sortMode ~= "manual" then notify("Сортировка: " .. SORT_NAMES[sortMode] .. " (перетаскивание порядка выключено)") end
end)

-- Поиск
searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	if suppressSearch then return end
	local q = searchBox.Text
	searchClear.Visible = q ~= ""
	if q == "" then
		if view.kind == "search" then
			local v = prevView or { kind = "pl", index = state.last }
			prevView = nil
			setView(v)
		end
	else
		if view.kind ~= "search" then prevView = view end
		view = { kind = "search" }
		searchQuery = q
		renderSidebar()
		renderBanner()
		renderList()
	end
end)
searchClear.Activated:Connect(function() searchBox.Text = "" end)

-- Добавление по ID
local function addTrackFromBox()
	local id = tonumber(addBox.Text:match("%d+") or "")
	addBox.Text = ""
	if not id or id < 1 or id >= 1e15 then
		notify("Введи числовой ID аудио")
		return
	end
	if not (view.kind == "pl" or view.kind == "liked") then return end
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
	task.defer(function() scroll.CanvasPosition = Vector2.new(0, math.huge) end)
end
addBtn.Activated:Connect(addTrackFromBox)
addBox.FocusLost:Connect(function(enter)
	if enter then addTrackFromBox() end
end)

playBtn.Activated:Connect(togglePlay)
miniPlay.Activated:Connect(togglePlay)
bigPlay.Activated:Connect(function()
	local list = displayList()
	if sound and current and #list > 0 then
		for _, t in ipairs(list) do
			if t.id == current.id then
				togglePlay()
				return
			end
		end
	end
	if #list > 0 then playFromList(list, shuffle and math.random(#list) or 1) end
end)
local function skipNext() failStreak = 0; nextTrack(false, false) end
local function skipPrev() failStreak = 0; prevTrack() end
nextBtn.Activated:Connect(skipNext)
miniNext.Activated:Connect(skipNext)
prevBtn.Activated:Connect(skipPrev)
miniPrev.Activated:Connect(skipPrev)

local function toggleShuffle()
	shuffle = not shuffle
	shuffleBtn.TextColor3 = shuffle and C.green or C.sub
	notify(shuffle and "Перемешивание включено" or "Перемешивание выключено")
end
shuffleBtn.Activated:Connect(toggleShuffle)
repeatBtn.Activated:Connect(function()
	repeatMode = (repeatMode + 1) % 3
	repeatBtn.Text = repeatMode == 2 and "↻¹" or "↻"
	repeatBtn.TextColor3 = repeatMode > 0 and C.green or C.sub
	if sound then sound.Looped = (repeatMode == 2) end
end)
markBtn.Activated:Connect(function() addMarker() end)

barHeart.Activated:Connect(function()
	if current then
		toggleLike(current)
		pop(barHeart)
	end
end)

closeBtn.Activated:Connect(function() setMode("hidden") end)
toggleBtn.Activated:Connect(function() setMode(uiMode == "hidden" and lastShown or "hidden") end)
miniBtn.Activated:Connect(function() setMode("mini") end)
miniExpand.Activated:Connect(function() setMode("full") end)
themeBtn.Activated:Connect(function() applyTheme(state.theme == "dark" and "light" or "dark"); markDirty() end)

-- Горячие клавиши
function runAction(id)
	if id == "toggle" then
		setMode(uiMode == "hidden" and lastShown or "hidden")
	elseif id == "mini" then
		setMode(uiMode == "mini" and "full" or "mini")
	elseif id == "play" then
		togglePlay()
	elseif id == "next" then
		skipNext()
	elseif id == "prev" then
		skipPrev()
	elseif id == "volup" then
		setVolume(state.volume + 0.05)
	elseif id == "voldown" then
		setVolume(state.volume - 0.05)
	elseif id == "seekf" then
		if sound and sound.TimeLength > 0 then sound.TimePosition = math.min(sound.TimeLength - 0.5, sound.TimePosition + 10) end
	elseif id == "seekb" then
		if sound then sound.TimePosition = math.max(0, sound.TimePosition - 10) end
	elseif id == "like" then
		if current then toggleLike(current) end
	elseif id == "shuffle" then
		toggleShuffle()
	elseif id == "marker" then
		addMarker()
	elseif id == "theme" then
		applyTheme(state.theme == "dark" and "light" or "dark")
		markDirty()
	elseif id == "search" then
		if uiMode ~= "full" then setMode("full") end
		task.defer(function()
			searchBox:CaptureFocus()
			task.wait()
			searchBox.Text = ""
		end)
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if listening then
		if input.UserInputType == Enum.UserInputType.Keyboard then
			local id = listening
			listening = nil
			if input.KeyCode == Enum.KeyCode.Escape then
				-- отмена
			elseif input.KeyCode == Enum.KeyCode.Backspace then
				state.binds[id] = "None"
			else
				for _, a in ipairs(ACTIONS) do
					if a.id ~= id and keyOf(a.id) == input.KeyCode then state.binds[a.id] = "None" end
				end
				state.binds[id] = input.KeyCode.Name
			end
			refreshKeys()
			markDirty()
		end
		return
	end
	if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	for _, a in ipairs(ACTIONS) do
		if keyOf(a.id) == input.KeyCode then
			runAction(a.id)
			return
		end
	end
end)

------------------------------------------------------------
-- АНИМАЦИЯ КАЖДЫЙ КАДР
------------------------------------------------------------
local smooth = 0
RunService.RenderStepped:Connect(function(dt)
	if uiMode == "hidden" then return end

	local playing = sound ~= nil and sound.IsPlaying
	local loud = playing and math.clamp(sound.PlaybackLoudness / 350, 0, 1) or 0
	smooth += (loud - smooth) * math.min(1, dt * 12)

	-- кроссфейд: запускаем следующий трек за N секунд до конца
	if playing and state.crossfade > 0 and repeatMode ~= 2 and xfFired ~= playToken
		and sound.TimeLength > state.crossfade * 2
		and sound.TimeLength - sound.TimePosition <= state.crossfade then
		xfFired = playToken
		nextTrack(true, true)
	end

	if sound and sound.TimeLength ~= markerLen then
		markerLen = sound.TimeLength
		rebuildMarkers()
	end

	if uiMode == "full" then
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
	else
		miniCoverScale.Scale = 1 + smooth * 0.08
		if playing then miniCoverGrad.Rotation = (miniCoverGrad.Rotation + dt * 40) % 360 end
	end

	if sound and sound.TimeLength > 0 then
		local a = sound.TimePosition / sound.TimeLength
		if not progress.IsDragging() then
			progress.Set(a)
			curTime.Text = formatTime(sound.TimePosition)
		end
		totTime.Text = formatTime(sound.TimeLength)
		miniFill.Size = UDim2.fromScale(math.clamp(a, 0, 1), 1)
	else
		progress.Set(0)
		curTime.Text = "0:00"
		totTime.Text = "0:00"
		miniFill.Size = UDim2.fromScale(0, 1)
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
	state.crossfade = tonumber(d.crossfade) or 0
	if type(d.binds) == "table" then state.binds = d.binds end
	if type(d.markers) == "table" then state.markers = d.markers end
	if not state.playlists[state.last] then state.last = 1 end
	view = { kind = "pl", index = state.last }

	volume.Set(state.volume)
	bassSlider.Set(state.bass)
	bassVal.Text = math.floor(state.bass * 100 + 0.5) .. "%"
	setCrossfade(state.crossfade)
	applyAudio()
	applyTheme(d.theme == "light" and "light" or "dark", true)
end

task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("SpotifyPlayerRemotes", 10)
	if not remotes then
		notify("Сохранение выключено: серверная часть не найдена")
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
			markDirty() -- первый вход: сохраняем стартовый плейлист
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
setCrossfade(state.crossfade)
refreshSpeedChips()
themeBtn.Text = "☀"
renderSidebar()
renderBanner()
renderList()
setMode("full")
hydrateTitles()
