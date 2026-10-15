--[[
	SPOTIFY-ПЛЕЕР v3 — ВЕРСИЯ ДЛЯ ИНЖЕКТОРА (Delta и похожие)

	КАК ЗАПУСКАТЬ:
	  1. Открой игру в Roblox, запусти Delta
	  2. Вставь весь этот код в окно Delta и нажми Execute
	  3. Слева внизу появится зелёная кнопка ♪ (или нажми M)

	ЧТО ИЗМЕНЕНО ПО СРАВНЕНИЮ С ВЕРСИЕЙ ДЛЯ STUDIO:
	  • Серверной части нет — всё работает только на клиенте
	  • Плейлисты, маркеры и настройки сохраняются в файл
	    (папка workspace твоего инжектора) через writefile / readfile
	  • Топ чарт — личный, считается по твоим прослушиваниям
	  • Интерфейс создаётся в gethui() / CoreGui, чтобы игра его не видела
	  • Повторный запуск скрипта заменяет старый плеер (без дублей)
	  • Кнопка 💾 внизу слева: экспорт/импорт библиотеки (JSON),
	    3 резервные копии, синхронизация (файл + код для другого устройства)

	ВАЖНО:
	  • Звук играет только у тебя (другие игроки его не слышат)
	  • Аудио, на которое у игры нет прав, может не загружаться —
	    плеер сам пропустит такой трек и покажет уведомление
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService = game:GetService("HttpService")

if not game:IsLoaded() then game.Loaded:Wait() end

local U = {} -- сюда перенесены переменные интерфейса (лимит Lua: 200 локальных на файл)

local function cutText(s, n)
	if type(s) ~= "string" or not utf8.len(s) then return "" end
	local o = utf8.offset(s, n + 1)
	if o then return s:sub(1, o - 1) end
	return s
end

local MAX_PLAYLISTS, MAX_TRACKS = 20, 300

------------------------------------------------------------------------
-- ░░░░░░░░░░░░░░░░░░░░░░  СРЕДА ИНЖЕКТОРА  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
------------------------------------------------------------------------
local genv = (type(getgenv) == "function" and getgenv()) or _G

-- если плеер уже запущен — аккуратно убираем старый
if type(genv.__SpotifyPlayerUnload) == "function" then
	pcall(genv.__SpotifyPlayerUnload)
end

function U.getGuiParent()
	if type(gethui) == "function" then
		local ok, h = pcall(gethui)
		if ok and typeof(h) == "Instance" then return h end
	end
	local ok, cg = pcall(function() return game:GetService("CoreGui") end)
	if ok and cg then
		local test = Instance.new("Folder")
		local okParent = pcall(function() test.Parent = cg end)
		test:Destroy()
		if okParent then return cg end
	end
	return Players.LocalPlayer:WaitForChild("PlayerGui")
end

function U.protectGui(g)
	if type(syn) == "table" and type(syn.protect_gui) == "function" then
		pcall(syn.protect_gui, g)
	elseif type(protect_gui) == "function" then
		pcall(protect_gui, g)
	end
end

------------------------------------------------------------------------
-- ░░░░░░░░░░░░░░░░░░░░░░  ПРОВЕРКА ДАННЫХ  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
-- (раньше жила на сервере; теперь чистит данные из файла)
------------------------------------------------------------------------
local GENRES = { "Pop", "Rock", "Rap", "Lofi", "Phonk", "Anime" }

local sanitize, validId
do
	local function cleanText(v, max)
		if type(v) ~= "string" then return nil end
		v = v:gsub("%c", "")
		if not utf8.len(v) then return nil end
		v = cutText(v, max)
		if v == "" then return nil end
		return v
	end

	function validId(id)
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

	local function cleanGenres(g)
		local out, n = {}, 0
		if type(g) ~= "table" then return out end
		for k, v in pairs(g) do
			local id = tonumber(k)
			if validId(id) and type(v) == "string" and n < 600 then
				for _, name in ipairs(GENRES) do
					if v == name then
						out[tostring(id)] = v
						n += 1
						break
					end
				end
			end
		end
		return out
	end

	function sanitize(d)
		if type(d) ~= "table" then return nil end
		local out = {
			playlists = {}, liked = {}, volume = 0.5, bass = 0, reverb = false, last = 1,
			theme = "dark", crossfade = 0, binds = {}, markers = {},
			history = {}, genres = {}, radio = false,
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
		out.history = cleanTracks(d.history)
		while #out.history > 50 do table.remove(out.history) end
		out.genres = cleanGenres(d.genres)
		out.radio = d.radio == true
		return out
	end
end

------------------------------------------------------------------------
-- ░░░░░░░░░░░░░░░░░░░░░░  ЛОКАЛЬНОЕ ХРАНИЛИЩЕ  ░░░░░░░░░░░░░░░░░░░░░░░░░
------------------------------------------------------------------------
local localPlayer = Players.LocalPlayer
local HAS_FS
local storageLoad, storageSave, recordPlay, topEntries, flushPlayCounts
local backupMake, backupList, backupRead
do
local localPlayer = Players.LocalPlayer
HAS_FS = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
U.SAVE_FILE = "SpotifyPlayer_" .. localPlayer.UserId .. ".json"
U.TOP_FILE = "SpotifyPlayer_top_" .. localPlayer.UserId .. ".json"
local MEM_KEY, MEM_TOP_KEY = "__SpotifyPlayerData", "__SpotifyPlayerTop"


-- Резервные копии: 3 последние версии (файлы _backup1..3, без файлов — в памяти)
local BK_N, BK_EVERY = 3, 600
local MEM_BK = "__SpotifyPlayerBackups"
local lastBackupTs, lastSig, prevClean = 0, nil, nil

local function sigOf(d)
	if type(d) ~= "table" then return "" end
	local parts = {}
	for _, p in ipairs(d.playlists or {}) do
		local ids = {}
		for _, t in ipairs(p.tracks) do ids[#ids + 1] = t.id end
		parts[#parts + 1] = p.name .. ":" .. table.concat(ids, ",")
	end
	local liked = {}
	for _, t in ipairs(d.liked or {}) do liked[#liked + 1] = t.id end
	local g = 0
	for _ in pairs(d.genres or {}) do g += 1 end
	return table.concat(parts, "|") .. "#" .. table.concat(liked, ",") .. "#" .. g
end

local function bkFile(i) return "SpotifyPlayer_" .. localPlayer.UserId .. "_backup" .. i .. ".json" end

local function bkReadRaw(i)
	if HAS_FS then
		local okE, exists = pcall(isfile, bkFile(i))
		if not (okE and exists) then return nil end
		local ok, raw = pcall(readfile, bkFile(i))
		return ok and type(raw) == "string" and raw ~= "" and raw or nil
	end
	local mem = genv[MEM_BK]
	return type(mem) == "table" and mem[i] or nil
end

local function bkWriteRaw(i, raw)
	if HAS_FS then
		pcall(writefile, bkFile(i), raw)
	else
		genv[MEM_BK] = genv[MEM_BK] or {}
		genv[MEM_BK][i] = raw
	end
end

local function bkDecode(i)
	local raw = bkReadRaw(i)
	if not raw then return nil end
	local ok, w = pcall(function() return HttpService:JSONDecode(raw) end)
	if not ok or type(w) ~= "table" or type(w.data) ~= "table" then return nil end
	return w
end

function backupList()
	local out = {}
	for i = 1, BK_N do
		local w = bkDecode(i)
		if w then
			local d = sanitize(w.data)
			if d then
				local tracks = #d.liked
				for _, p in ipairs(d.playlists) do tracks += #p.tracks end
				out[#out + 1] = { idx = i, ts = tonumber(w.ts) or 0, playlists = #d.playlists, tracks = tracks }
			end
		end
	end
	return out
end

function backupRead(i)
	local w = bkDecode(i)
	return w and sanitize(w.data) or nil
end

-- force снимает только 10-минутное ограничение; одинаковые версии не дублируются
function backupMake(clean, force)
	if type(clean) ~= "table" then return false end
	local sig = sigOf(clean)
	if lastSig == nil then
		local top = bkDecode(1)
		lastSig = top and sigOf(sanitize(top.data)) or ""
	end
	if sig == lastSig then return false end
	if not force and os.time() - lastBackupTs < BK_EVERY then return false end
	local okEnc, dataRaw = pcall(function() return HttpService:JSONEncode(clean) end)
	if not okEnc then return false end
	for i = BK_N, 2, -1 do
		local r = bkReadRaw(i - 1)
		if r then bkWriteRaw(i, r) end
	end
	bkWriteRaw(1, '{"ts":' .. os.time() .. ',"data":' .. dataRaw .. "}")
	lastSig, lastBackupTs = sig, os.time()
	return true
end

-- возвращает ok, data, flag (data == nil — сохранения ещё нет)
function storageLoad()
	if HAS_FS then
		local okExists, exists = pcall(isfile, U.SAVE_FILE)
		if not okExists then return false end
		if not exists then return true, nil end
		local okRead, raw = pcall(readfile, U.SAVE_FILE)
		if not okRead or type(raw) ~= "string" or raw == "" then return true, nil end
		local okJson, data = pcall(function() return HttpService:JSONDecode(raw) end)
		if not okJson or type(data) ~= "table" then
			warn("[SpotifyPlayer] Файл сохранения повреждён")
			pcall(writefile, "SpotifyPlayer_" .. localPlayer.UserId .. "_corrupt.json", raw)
			local saved = backupRead(1)
			if saved then
				prevClean = saved
				return true, saved, "restored"
			end
			return true, nil, "corrupt"
		end
		local clean = sanitize(data)
		prevClean = clean
		if clean then backupMake(clean, true) end
		return true, clean
	end
	-- без файловой системы: хранилище живёт, пока открыта игра
	local mem = genv[MEM_KEY]
	if type(mem) == "string" then
		local okJson, data = pcall(function() return HttpService:JSONDecode(mem) end)
		if okJson then
			local clean = sanitize(data)
			prevClean = clean
			if clean then backupMake(clean, true) end
			return true, clean
		end
	end
	return true, nil
end

function storageSave(payload)
	local clean = sanitize(payload)
	if not clean then return false end
	local okEnc, raw = pcall(function() return HttpService:JSONEncode(clean) end)
	if not okEnc then return false end
	if prevClean then pcall(backupMake, prevClean, false) end
	if HAS_FS then
		local ok, err = pcall(writefile, U.SAVE_FILE, raw)
		if not ok then
			warn("[SpotifyPlayer] Не удалось сохранить:", err)
			return false
		end
		prevClean = clean
		return true
	end
	genv[MEM_KEY] = raw
	prevClean = clean
	return true
end

-- Личный топ чарт: id -> число прослушиваний
local playCounts, playCountsLoaded = {}, false
local lastPlayAt, topDirty = {}, false

function U.loadPlayCounts()
	if playCountsLoaded then return end
	playCountsLoaded = true
	local raw
	if HAS_FS then
		local okExists, exists = pcall(isfile, U.TOP_FILE)
		if okExists and exists then
			local okRead, r = pcall(readfile, U.TOP_FILE)
			if okRead then raw = r end
		end
	else
		raw = genv[MEM_TOP_KEY]
	end
	if type(raw) ~= "string" or raw == "" then return end
	local ok, data = pcall(function() return HttpService:JSONDecode(raw) end)
	if not ok or type(data) ~= "table" then return end
	local n = 0
	for k, v in pairs(data) do
		local id, c = tonumber(k), tonumber(v)
		if validId(id) and c and c >= 1 and n < 500 then
			playCounts[tostring(id)] = math.floor(c)
			n += 1
		end
	end
end

function flushPlayCounts()
	if not topDirty then return end
	topDirty = false
	local ok, raw = pcall(function() return HttpService:JSONEncode(playCounts) end)
	if not ok then return end
	if HAS_FS then
		local okW = pcall(writefile, U.TOP_FILE, raw)
		if not okW then topDirty = true end
	else
		genv[MEM_TOP_KEY] = raw
	end
end

function recordPlay(id)
	id = tonumber(id)
	if not validId(id) then return end
	U.loadPlayCounts()
	local now = os.clock()
	if lastPlayAt[id] and now - lastPlayAt[id] < 90 then return end
	lastPlayAt[id] = now
	local key = tostring(id)
	playCounts[key] = (playCounts[key] or 0) + 1
	topDirty = true
	task.delay(5, flushPlayCounts)
end

function topEntries(limit)
	U.loadPlayCounts()
	local arr = {}
	for k, c in pairs(playCounts) do arr[#arr + 1] = { id = tonumber(k), plays = c } end
	table.sort(arr, function(a, b)
		if a.plays == b.plays then return a.id < b.id end
		return a.plays > b.plays
	end)
	local out = {}
	for i = 1, math.min(limit or 20, #arr) do out[i] = arr[i] end
	return out
end
end

------------------------------------------------------------------------
-- ░░░░░░░░░░░░░░░░░░░░░░░░░  ПЛЕЕР  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
------------------------------------------------------------------------
local connections = {}
local function tracked(service)
	return setmetatable({}, {
		__index = function(_, k)
			local v = service[k]
			if typeof(v) == "RBXScriptSignal" then
				return {
					Connect = function(_, fn)
						local c = v:Connect(fn)
						connections[#connections + 1] = c
						return c
					end,
				}
			end
			if type(v) == "function" then
				return function(_, ...) return v(service, ...) end
			end
			return v
		end,
	})
end

local UserInputService = tracked(game:GetService("UserInputService"))
RunService = tracked(RunService)
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")

local player = localPlayer
local guiParent = U.getGuiParent()

-- убираем остатки прошлого запуска
for _, p in ipairs({ guiParent, player:FindFirstChild("PlayerGui") }) do
	if p then
		local old = p:FindFirstChild("SpotifyPlayer")
		if old then old:Destroy() end
	end
end
do
	local oldBus = SoundService:FindFirstChild("SpotifyBus")
	if oldBus then oldBus:Destroy() end
	for _, s in ipairs(SoundService:GetChildren()) do
		if s:IsA("Sound") and s.Name == "Track" then s:Destroy() end
	end
end




------------------------------------------------------------
-- ТЕМЫ
------------------------------------------------------------
U.rgb = Color3.fromRGB
U.THEMES = {
	dark = {
		bg = U.rgb(18, 18, 18), side = U.rgb(0, 0, 0), panel = U.rgb(24, 24, 24), elev = U.rgb(40, 40, 40),
		hover = U.rgb(46, 46, 46), elev2 = U.rgb(83, 83, 83), chip = U.rgb(62, 62, 62),
		text = U.rgb(255, 255, 255), sub = U.rgb(179, 179, 179), green = U.rgb(30, 215, 96),
		red = U.rgb(240, 80, 80), ink = U.rgb(18, 18, 18), marker = U.rgb(255, 196, 0),
		bannerV = 0.6, bannerS = 0.6,
	},
	light = {
		bg = U.rgb(250, 250, 252), side = U.rgb(238, 238, 243), panel = U.rgb(255, 255, 255), elev = U.rgb(230, 230, 236),
		hover = U.rgb(236, 236, 241), elev2 = U.rgb(176, 176, 188), chip = U.rgb(220, 220, 228),
		text = U.rgb(22, 22, 26), sub = U.rgb(100, 100, 112), green = U.rgb(24, 176, 80),
		red = U.rgb(214, 48, 48), ink = U.rgb(255, 255, 255), marker = U.rgb(230, 150, 0),
		bannerV = 0.97, bannerS = 0.4,
	},
}
U.C = U.THEMES.dark

local FONT, FONT_B, FONT_X = Enum.Font.GothamMedium, Enum.Font.GothamBold, Enum.Font.GothamBlack
local W, H = 860, 560
local SIDE_W, BAR_H = 220, 96
U.CONTENT_W = W - SIDE_W
local MAX_TRACKS, MAX_PLAYLISTS = 300, 20

------------------------------------------------------------
-- ХЕЛПЕРЫ
-- В new()/label(): bg="роль" и tc="роль" — цвета, которые меняются вместе с темой
------------------------------------------------------------
U.themed = {}

function U.new(class, props)
	local inst = Instance.new(class)
	local parent = props.Parent
	local bgRole, tcRole = props.bg, props.tc
	props.Parent, props.bg, props.tc = nil, nil, nil
	if bgRole then props.BackgroundColor3 = U.C[bgRole] end
	if tcRole then props.TextColor3 = U.C[tcRole] end
	for k, v in pairs(props) do inst[k] = v end
	if bgRole then U.themed[#U.themed + 1] = { inst, "BackgroundColor3", bgRole } end
	if tcRole then U.themed[#U.themed + 1] = { inst, "TextColor3", tcRole } end
	inst.Parent = parent
	return inst
end

function U.corner(inst, r)
	return U.new("UICorner", { CornerRadius = UDim.new(0, r), Parent = inst })
end

function U.label(props)
	props.BackgroundTransparency = 1
	props.Font = props.Font or FONT
	if not props.tc and not props.TextColor3 then props.tc = "text" end
	props.TextSize = props.TextSize or 14
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return U.new("TextLabel", props)
end

function U.tween(inst, t, props, style, dir)
	local tw = TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

function U.formatTime(s)
	s = math.max(0, math.floor(s))
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

function U.isPointer(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end
function U.isMove(input)
	return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
end

function U.pointer()
	return UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
end
function U.inside(g, p)
	local a, s = g.AbsolutePosition, g.AbsoluteSize
	return p.X >= a.X and p.X <= a.X + s.X and p.Y >= a.Y and p.Y <= a.Y + s.Y
end

function U.hueFor(seed)
	if type(seed) == "string" then
		local h = 0
		for i = 1, #seed do h = (h * 31 + seed:byte(i)) % 1000 end
		seed = h
	end
	return (seed * 0.61803398875) % 1
end
function U.accentH(h, v, s) return Color3.fromHSV(h, s or 0.6, v or 0.85) end
function U.accent(seed, v) return U.accentH(U.hueFor(seed), v) end

function U.pluralTracks(n)
	local a, b = n % 10, n % 100
	if a == 1 and b ~= 11 then return n .. " трек" end
	if a >= 2 and a <= 4 and (b < 12 or b > 14) then return n .. " трека" end
	return n .. " треков"
end

-- нижний регистр для кириллицы и латиницы (сортировка и поиск)
function U.lowerU(s)
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

function U.bouncy(btn, hoverScale)
	local s = U.new("UIScale", { Parent = btn })
	btn.MouseEnter:Connect(function() U.tween(s, 0.12, { Scale = hoverScale or 1.06 }) end)
	btn.MouseButton1Down:Connect(function() U.tween(s, 0.08, { Scale = 0.9 }) end)
	local function up() U.tween(s, 0.3, { Scale = 1 }, Enum.EasingStyle.Back) end
	btn.MouseButton1Up:Connect(up)
	btn.MouseLeave:Connect(up)
	return s
end

function U.pop(btn)
	local s = btn:FindFirstChildOfClass("UIScale")
	if s then
		s.Scale = 1.5
		U.tween(s, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
	end
end

------------------------------------------------------------
-- СОСТОЯНИЕ (сохраняется автоматически)
------------------------------------------------------------
U.state = {
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
	history = {}, genres = {}, radio = false,
}

U.view = { kind = "pl", index = 1 } -- pl | liked | top | search | queue | history
-- (перенесено в таблицу U): prevView
local searchList, searchQuery = {}, ""
local topList, topState = {}, "idle"
U.sortMode = "manual"
local loaded, saveToken = false, 0

-- Горячие клавиши
U.ACTIONS = {
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
U.KEYNAMES = {
	Period = ".", Comma = ",", Equals = "=", Minus = "-", RightBracket = "]",
	LeftBracket = "[", Slash = "/", Backquote = "`", Semicolon = ";", Quote = "'",
}
function U.keyOf(id)
	local name = U.state.binds[id]
	if name == nil then
		for _, a in ipairs(U.ACTIONS) do
			if a.id == id then name = a.def end
		end
	end
	if not name or name == "None" then return nil end
	local ok, kc = pcall(function() return Enum.KeyCode[name] end)
	return ok and kc or nil
end
function U.keyLabel(id)
	local k = U.keyOf(id)
	if not k then return "—" end
	return U.KEYNAMES[k.Name] or k.Name
end

-- forward declarations
-- (перенесено в таблицу U): renderList, renderSidebar, renderBanner, updateNowPlaying, updatePlayState
-- (перенесено в таблицу U): setView, playFromList, nextTrack, prevTrack, togglePlay, fetchTop
-- (перенесено в таблицу U): toggleLike, refreshTexts, closePopups, markDirty, notify, updateHearts
-- (перенесено в таблицу U): openMenu, openAddMenu, openTrackMenu, setMode, rebuildMarkers, addMarker
-- (перенесено в таблицу U): setVolume, applyTheme, runAction, refreshKeys, setSpeed
local uiMode, lastShown = "hidden", "full"
U.markerLen = 0

function U.currentList()
	if U.view.kind == "liked" then return U.state.liked end
	if U.view.kind == "top" then return topList end
	if U.view.kind == "search" then return searchList end
	if U.view.kind == "queue" then return U.queueList() end
	if U.view.kind == "history" then return U.state.history end
	return U.state.playlists[U.view.index].tracks
end

function U.isLiked(id)
	for _, t in ipairs(U.state.liked) do
		if t.id == id then return true end
	end
	return false
end

-- Сортировка (только отображение)
U.SORTS = { "manual", "title", "artist", "newest", "genre" }
U.SORT_NAMES = { manual = "Мой порядок", title = "Название А–Я", artist = "Исполнитель А–Я", newest = "Сначала новые", genre = "По жанру" }

function U.displayList()
	local list = U.currentList()
	local vk = U.view.kind
	if vk == "top" or vk == "search" or vk == "queue" or vk == "history" or U.sortMode == "manual" then return list end
	local items = {}
	for i, t in ipairs(list) do
		local key
		if U.sortMode == "title" then
			key = t.title or ""
		elseif U.sortMode == "genre" then
			key = U.genreOf(t, true) or "я"
		else
			key = t.artist or ""
		end
		items[i] = { t = t, i = i, k = U.lowerU(key) }
	end
	if U.sortMode == "newest" then
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

function U.buildSearch(q)
	q = U.lowerU(q)
	local out, seen = {}, {}
	local function scan(list)
		for _, t in ipairs(list) do
			if not seen[t.id] then
				if U.lowerU(t.title or ""):find(q, 1, true)
					or U.lowerU(t.artist or ""):find(q, 1, true)
					or U.lowerU(U.state.genres[tostring(t.id)] or ""):find(q, 1, true)
					or tostring(t.id):find(q, 1, true) then
					seen[t.id] = true
					out[#out + 1] = t
				end
			end
		end
	end
	scan(U.state.liked)
	for _, p in ipairs(U.state.playlists) do scan(p.tracks) end
	scan(U.state.history)
	scan(topList)
	return out
end

------------------------------------------------------------
-- ЗВУК: SoundGroup + эквалайзер (бас) + реверб + кроссфейд
------------------------------------------------------------
U.group = U.new("SoundGroup", { Name = "SpotifyBus", Volume = U.state.volume, Parent = SoundService })
U.eq = U.new("EqualizerSoundEffect", { Parent = U.group })
U.reverbFx = U.new("ReverbSoundEffect", {
	DecayTime = 2.8, Density = 0.9, Diffusion = 0.9, DryLevel = 0, WetLevel = -6, Enabled = false, Parent = U.group,
})

function U.applyAudio()
	U.group.Volume = U.state.volume
	U.eq.LowGain = math.clamp(U.state.bass * 10, -80, 10)
	U.eq.MidGain = -U.state.bass * 3
	U.eq.HighGain = 0
	U.reverbFx.Enabled = U.state.reverb
end
U.applyAudio()

U.speed = 1
local sound, current
local queue, qi = {}, 0
local shuffle, repeatMode = false, 0
local playToken, failStreak, xfFired = 0, 0, -1
U.badIds = {}

------------------------------------------------------------
-- GUI: КОРЕНЬ
------------------------------------------------------------
U.gui = U.new("ScreenGui", {
	Name = "SpotifyPlayer", ResetOnSpawn = false, DisplayOrder = 10,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = guiParent,
})
U.root = U.new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(W, H), BackgroundTransparency = 1, Parent = U.gui,
})
U.uiScale = U.new("UIScale", { Parent = U.root })
function U.rescale()
	local cam = workspace.CurrentCamera
	if not cam then return end
	local v = cam.ViewportSize
	U.uiScale.Scale = math.clamp(math.min(v.X / (W + 40), v.Y / (H + 40)), 0.45, 1)
end
U.rescale()
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(U.rescale)
end

U.main = U.new("CanvasGroup", {
	Size = UDim2.fromScale(1, 1), bg = "bg", BorderSizePixel = 0, Visible = false, Parent = U.root,
})
U.corner(U.main, 14)

-- Toast
U.toast = U.new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, -70),
	Size = UDim2.fromOffset(340, 40), bg = "text", ZIndex = 100, Parent = U.gui,
})
U.corner(U.toast, 20)
U.toastLbl = U.label({
	Text = "", Font = FONT_B, TextSize = 14, tc = "bg", TextXAlignment = Enum.TextXAlignment.Center,
	Size = UDim2.fromScale(1, 1), ZIndex = 101, Parent = U.toast,
})
U.toastToken = 0
function U.notify(msg)
	U.toastToken += 1
	local my = U.toastToken
	U.toastLbl.Text = msg
	U.tween(U.toast, 0.35, { Position = UDim2.new(0.5, 0, 0, 20) }, Enum.EasingStyle.Back)
	task.delay(2.4, function()
		if my == U.toastToken then U.tween(U.toast, 0.25, { Position = UDim2.new(0.5, 0, 0, -70) }) end
	end)
end

------------------------------------------------------------
-- САЙДБАР
------------------------------------------------------------
U.sidebar = U.new("Frame", {
	Size = UDim2.new(0, SIDE_W, 1, -BAR_H), bg = "side", BorderSizePixel = 0, Parent = U.main,
})
U.label({
	Text = "♪", Font = FONT_X, TextSize = 26, tc = "green",
	Position = UDim2.fromOffset(20, 40), Size = UDim2.fromOffset(26, 30), Parent = U.sidebar,
})
U.label({
	Text = "Музыка", Font = FONT_X, TextSize = 22,
	Position = UDim2.fromOffset(50, 40), Size = UDim2.new(1, -60, 0, 30), Parent = U.sidebar,
})

function U.sideButton(parent, y, icon, text)
	local props = {
		Text = "", Size = UDim2.new(1, -16, 0, 38), bg = "elev", BackgroundTransparency = 1,
		AutoButtonColor = false, Parent = parent,
	}
	if y then props.Position = UDim2.fromOffset(8, y) end
	local b = U.new("TextButton", props)
	U.corner(b, 8)
	local ic = U.label({
		Text = icon, Font = FONT_B, TextSize = 18, tc = "sub", TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(6, 0), Size = UDim2.fromOffset(30, 38), Parent = b,
	})
	local tx = U.label({
		Text = text, Font = FONT_B, TextSize = 14, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(42, 0), Size = UDim2.new(1, -50, 1, 0), Parent = b,
	})
	b.MouseEnter:Connect(function()
		if b.BackgroundTransparency > 0.9 then U.tween(b, 0.12, { BackgroundTransparency = 0.7 }) end
	end)
	b.MouseLeave:Connect(function()
		if b.BackgroundTransparency > 0.5 then U.tween(b, 0.12, { BackgroundTransparency = 1 }) end
	end)
	return b, ic, tx
end

local navLiked, navLikedIc, navLikedTx = U.sideButton(U.sidebar, 76, "♥", "Любимое")
local navTop, navTopIc, navTopTx = U.sideButton(U.sidebar, 118, "🔥", "Топ чарт")
U.navQueue, U.navQueueIc, U.navQueueTx = U.sideButton(U.sidebar, 160, "⏭", "Следующие")
U.navHistory, U.navHistoryIc, U.navHistoryTx = U.sideButton(U.sidebar, 202, "🕘", "История")

U.label({
	Text = "ПЛЕЙЛИСТЫ", Font = FONT_B, TextSize = 12, tc = "sub",
	Position = UDim2.fromOffset(20, 250), Size = UDim2.fromOffset(120, 24), Parent = U.sidebar,
})
U.plAddBtn = U.new("TextButton", {
	Text = "+", Font = FONT_B, TextSize = 22, tc = "sub", BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 248), Size = UDim2.fromOffset(28, 28), Parent = U.sidebar,
})
U.bouncy(U.plAddBtn, 1.15)

U.plNameBox = U.new("TextBox", {
	PlaceholderText = "Название и Enter", PlaceholderColor3 = U.rgb(140, 140, 150), Text = "",
	ClearTextOnFocus = false, Font = FONT, TextSize = 13, tc = "text",
	TextXAlignment = Enum.TextXAlignment.Left, bg = "elev", Visible = false,
	Position = UDim2.fromOffset(10, 278), Size = UDim2.new(1, -20, 0, 30), Parent = U.sidebar,
})
U.corner(U.plNameBox, 15)
U.new("UIPadding", { PaddingLeft = UDim.new(0, 12), Parent = U.plNameBox })

U.plScroll = U.new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = U.C.elev2,
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = U.sidebar,
})
U.new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = U.plScroll })

function U.layoutSidebar()
	local y = U.plNameBox.Visible and 314 or 280
	U.plScroll.Position = UDim2.fromOffset(8, y)
	U.plScroll.Size = UDim2.new(1, -16, 1, -(y + 52))
end
U.layoutSidebar()

-- нижние кнопки сайдбара
U.botRow = U.new("Frame", {
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -6),
	Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1, Parent = U.sidebar,
})
function U.smallBtn(text, x)
	local b = U.new("TextButton", {
		Text = text, Font = FONT_B, TextSize = 16, tc = "sub", bg = "elev",
		Position = UDim2.fromOffset(x, 2), Size = UDim2.fromOffset(46, 32), AutoButtonColor = false, Parent = U.botRow,
	})
	U.corner(b, 16)
	U.bouncy(b, 1.06)
	return b
end
U.themeBtn = U.smallBtn("🌞", 10)
U.keysBtn = U.smallBtn("⌨", 62)
U.miniBtn = U.smallBtn("Мини", 114)
U.miniBtn.TextSize = 12
U.dataBtn = U.smallBtn("💾", 166)

------------------------------------------------------------
-- ОСНОВНАЯ ОБЛАСТЬ
------------------------------------------------------------
U.content = U.new("Frame", {
	Position = UDim2.fromOffset(SIDE_W, 0), Size = UDim2.new(0, U.CONTENT_W, 1, -BAR_H),
	bg = "bg", BorderSizePixel = 0, Parent = U.main,
})

U.banner = U.new("Frame", {
	Size = UDim2.new(1, 0, 0, 130), BackgroundColor3 = U.rgb(60, 40, 120), BorderSizePixel = 0, Parent = U.content,
})
U.bannerFade = U.new("Frame", { Size = UDim2.fromScale(1, 1), bg = "bg", BorderSizePixel = 0, Parent = U.banner })
U.new("UIGradient", {
	Rotation = 90,
	Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) }),
	Parent = U.bannerFade,
})

U.bannerCover = U.new("Frame", {
	Position = UDim2.fromOffset(28, 34), Size = UDim2.fromOffset(84, 84),
	BackgroundColor3 = U.rgb(255, 255, 255), BorderSizePixel = 0, Parent = U.banner,
})
U.corner(U.bannerCover, 8)
U.bannerCoverGrad = U.new("UIGradient", {
	Color = ColorSequence.new(U.rgb(30, 215, 96), U.rgb(60, 40, 120)), Rotation = 45, Parent = U.bannerCover,
})
U.bannerCoverScale = U.new("UIScale", { Parent = U.bannerCover })
U.bannerIcon = U.label({
	Text = "♪", Font = FONT_X, TextSize = 40, TextColor3 = U.rgb(255, 255, 255),
	TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = U.bannerCover,
})
U.bannerKind = U.label({
	Text = "ПЛЕЙЛИСТ", Font = FONT_B, TextSize = 11,
	Position = UDim2.fromOffset(128, 40), Size = UDim2.fromOffset(320, 16), Parent = U.banner,
})
U.bannerTitle = U.label({
	Text = "", Font = FONT_X, TextSize = 30, TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(128, 56), Size = UDim2.fromOffset(330, 40), Parent = U.banner,
})
U.bannerSub = U.label({
	Text = "", TextSize = 13, tc = "sub",
	Position = UDim2.fromOffset(128, 98), Size = UDim2.fromOffset(330, 18), Parent = U.banner,
})

U.VIS_BARS = 16
U.visBox = U.new("Frame", {
	Position = UDim2.fromOffset(U.CONTENT_W - 28 - U.VIS_BARS * 9, 40),
	Size = UDim2.fromOffset(U.VIS_BARS * 9, 74), BackgroundTransparency = 1, Parent = U.banner,
})
U.bars = {}
for i = 1, U.VIS_BARS do
	local b = U.new("Frame", {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, (i - 1) * 9, 1, 0), Size = UDim2.fromOffset(6, 4),
		BackgroundColor3 = U.C.green, BackgroundTransparency = 0.15, BorderSizePixel = 0, Parent = U.visBox,
	})
	U.corner(b, 3)
	U.bars[i] = b
end

-- Тулбар
U.toolbar = U.new("Frame", {
	Position = UDim2.fromOffset(0, 130), Size = UDim2.new(1, 0, 0, 52), BackgroundTransparency = 1, Parent = U.content,
})
U.bigPlay = U.new("TextButton", {
	Text = "▶", Font = FONT_B, TextSize = 20, tc = "ink", bg = "green",
	Position = UDim2.fromOffset(28, 3), Size = UDim2.fromOffset(46, 46), AutoButtonColor = false, Parent = U.toolbar,
})
U.corner(U.bigPlay, 23)
U.bouncy(U.bigPlay, 1.08)

U.sortBtn = U.new("TextButton", {
	Text = "⇅ " .. U.SORT_NAMES.manual, Font = FONT_B, TextSize = 12, tc = "text", bg = "elev",
	Position = UDim2.fromOffset(84, 10), Size = UDim2.fromOffset(128, 32), AutoButtonColor = false, Parent = U.toolbar,
})
U.corner(U.sortBtn, 16)
U.bouncy(U.sortBtn, 1.04)

U.searchRow = U.new("Frame", {
	Position = UDim2.fromOffset(220, 10), Size = UDim2.fromOffset(150, 32), bg = "elev", Parent = U.toolbar,
})
U.corner(U.searchRow, 16)
U.label({
	Text = "🔍", TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center,
	Position = UDim2.fromOffset(4, 0), Size = UDim2.fromOffset(26, 32), Parent = U.searchRow,
})
U.searchBox = U.new("TextBox", {
	PlaceholderText = "Поиск по трекам", PlaceholderColor3 = U.rgb(140, 140, 150), Text = "",
	ClearTextOnFocus = false, Font = FONT, TextSize = 13, tc = "text",
	TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1,
	Position = UDim2.fromOffset(30, 0), Size = UDim2.new(1, -58, 1, 0), Parent = U.searchRow,
})
U.menuBtn = U.new("TextButton", {
	Text = "•••", Font = FONT_B, TextSize = 14, tc = "text", bg = "elev",
	Position = UDim2.fromOffset(374, 10), Size = UDim2.fromOffset(34, 32), AutoButtonColor = false, Parent = U.toolbar,
})
U.corner(U.menuBtn, 16)
U.bouncy(U.menuBtn, 1.06)
U.searchClear = U.new("TextButton", {
	Text = "×", Font = FONT_B, TextSize = 12, tc = "sub", BackgroundTransparency = 1, Visible = false,
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(22, 22), Parent = U.searchRow,
})

U.topHint = U.label({
	Text = "Чарт игроков · раз в минуту", TextSize = 12, tc = "sub", TextXAlignment = Enum.TextXAlignment.Right,
	Visible = false, Position = UDim2.new(1, -208, 0, 0), Size = UDim2.fromOffset(180, 52), Parent = U.toolbar,
})
U.addRow = U.new("Frame", {
	Position = UDim2.new(1, -228, 0, 10), Size = UDim2.fromOffset(200, 32), bg = "elev", Parent = U.toolbar,
})
U.corner(U.addRow, 16)
U.addBox = U.new("TextBox", {
	PlaceholderText = "Добавить по ID", PlaceholderColor3 = U.rgb(140, 140, 150), Text = "",
	ClearTextOnFocus = false, Font = FONT, TextSize = 13, tc = "text",
	TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1,
	Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -48, 1, 0), Parent = U.addRow,
})
U.addBtn = U.new("TextButton", {
	Text = "+", Font = FONT_B, TextSize = 20, tc = "ink", bg = "green",
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0.5, 0), Size = UDim2.fromOffset(24, 24),
	AutoButtonColor = false, Parent = U.addRow,
})
U.corner(U.addBtn, 12)
U.bouncy(U.addBtn, 1.1)

U.label({
	Text = "#", Font = FONT_B, TextSize = 12, tc = "sub", TextXAlignment = Enum.TextXAlignment.Center,
	Position = UDim2.fromOffset(12, 182), Size = UDim2.fromOffset(40, 22), Parent = U.content,
})
U.label({
	Text = "НАЗВАНИЕ", Font = FONT_B, TextSize = 12, tc = "sub",
	Position = UDim2.fromOffset(102, 182), Size = UDim2.fromOffset(200, 22), Parent = U.content,
})
U.new("Frame", {
	Position = UDim2.fromOffset(12, 204), Size = UDim2.new(1, -24, 0, 1), bg = "elev", BorderSizePixel = 0, Parent = U.content,
})

U.listWrap = U.new("CanvasGroup", {
	Position = UDim2.fromOffset(12, 208), Size = UDim2.new(1, -24, 1, -208), BackgroundTransparency = 1, Parent = U.content,
})
U.scroll = U.new("ScrollingFrame", {
	Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
	ScrollBarThickness = 4, ScrollBarImageColor3 = U.C.elev2,
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = U.listWrap,
})
U.new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = U.scroll })
U.new("UIPadding", { PaddingTop = UDim.new(0, 4), Parent = U.scroll })
U.emptyLbl = U.label({
	Text = "", TextSize = 14, tc = "sub", TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center,
	Visible = false, Position = UDim2.fromOffset(40, 50), Size = UDim2.new(1, -80, 0, 60), Parent = U.listWrap,
})

------------------------------------------------------------
-- НИЖНЯЯ ПАНЕЛЬ
------------------------------------------------------------
U.bar = U.new("Frame", {
	Position = UDim2.new(0, 0, 1, -BAR_H), Size = UDim2.new(1, 0, 0, BAR_H), bg = "panel", BorderSizePixel = 0, Parent = U.main,
})
U.new("Frame", { Size = UDim2.new(1, 0, 0, 1), bg = "elev", BorderSizePixel = 0, Parent = U.bar })

U.barCover = U.new("Frame", {
	Position = UDim2.fromOffset(16, 18), Size = UDim2.fromOffset(60, 60),
	BackgroundColor3 = U.rgb(255, 255, 255), BorderSizePixel = 0, Parent = U.bar,
})
U.corner(U.barCover, 6)
U.barCoverGrad = U.new("UIGradient", {
	Color = ColorSequence.new(U.rgb(120, 120, 130), U.rgb(70, 70, 80)), Rotation = 45, Parent = U.barCover,
})
U.barCoverScale = U.new("UIScale", { Parent = U.barCover })
U.label({
	Text = "♪", Font = FONT_B, TextSize = 26, TextColor3 = U.rgb(255, 255, 255),
	TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = U.barCover,
})
U.barTitle = U.label({
	Text = "Ничего не играет", Font = FONT_B, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(88, 26), Size = UDim2.fromOffset(126, 20), Parent = U.bar,
})
U.barArtist = U.label({
	Text = "Выбери трек", TextSize = 12, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(88, 47), Size = UDim2.fromOffset(126, 16), Parent = U.bar,
})
U.barHeart = U.new("TextButton", {
	Text = "♥", Font = FONT_B, TextSize = 20, tc = "elev2", BackgroundTransparency = 1,
	Position = UDim2.fromOffset(220, 31), Size = UDim2.fromOffset(30, 34), Parent = U.bar,
})
U.bouncy(U.barHeart, 1.15)

U.center = U.new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 10),
	Size = UDim2.fromOffset(330, 78), BackgroundTransparency = 1, Parent = U.bar,
})
U.controls = U.new("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1, Parent = U.center })
U.new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 12),
	SortOrder = Enum.SortOrder.LayoutOrder, Parent = U.controls,
})
function U.ctrlButton(text, order, size)
	local b = U.new("TextButton", {
		Text = text, Font = FONT_B, TextSize = size or 20, tc = "sub", BackgroundTransparency = 1,
		Size = UDim2.fromOffset(32, 34), LayoutOrder = order, AutoButtonColor = false, Parent = U.controls,
	})
	U.bouncy(b, 1.12)
	return b
end
U.shuffleBtn = U.ctrlButton("⇄", 1)
U.prevBtn = U.ctrlButton("⏮", 2, 18)
U.playBtn = U.new("TextButton", {
	Text = "▶", Font = FONT_B, TextSize = 18, tc = "bg", bg = "text",
	Size = UDim2.fromOffset(42, 42), LayoutOrder = 3, AutoButtonColor = false, Parent = U.controls,
})
U.corner(U.playBtn, 21)
U.bouncy(U.playBtn, 1.08)
U.nextBtn = U.ctrlButton("⏭", 4, 18)
U.repeatBtn = U.ctrlButton("🔁", 5)
U.markBtn = U.ctrlButton("🚩", 6, 17)
U.radioBtn = U.ctrlButton("📻", 7, 16)
U.corner(U.radioBtn, 8)
U.prevBtn.TextColor3 = U.C.text
U.nextBtn.TextColor3 = U.C.text
U.themed[#U.themed + 1] = { U.prevBtn, "TextColor3", "text" }
U.themed[#U.themed + 1] = { U.nextBtn, "TextColor3", "text" }

-- Слайдер: opts = {onHover, onLeave, onRight, onWheel}
function U.makeSlider(parent, position, size, initial, onChanged, opts)
	opts = opts or {}
	local barF = U.new("Frame", { Position = position, Size = size, bg = "elev2", BorderSizePixel = 0, Parent = parent })
	U.corner(barF, 3)
	local fill = U.new("Frame", { Size = UDim2.fromScale(initial, 1), bg = "text", BorderSizePixel = 0, Parent = barF })
	U.corner(fill, 3)
	local knob = U.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(12, 12),
		bg = "text", Visible = false, Parent = fill,
	})
	U.corner(knob, 6)
	local hit = U.new("TextButton", {
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
		fill.BackgroundColor3 = U.C.green
		knob.Visible = true
	end)
	hit.MouseLeave:Connect(function()
		if not dragging then
			fill.BackgroundColor3 = U.C.text
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
		if U.isPointer(input) then
			dragging = true
			fill.BackgroundColor3 = U.C.green
			knob.Visible = true
			update(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and U.isMove(input) then update(input.Position.X) end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if dragging and U.isPointer(input) then
			dragging = false
			fill.BackgroundColor3 = U.C.text
			knob.Visible = false
		end
	end)
	return {
		Set = function(a) if not dragging then fill.Size = UDim2.fromScale(a, 1) end end,
		IsDragging = function() return dragging end,
	}
end

U.curTime = U.label({
	Text = "0:00", TextSize = 11, tc = "sub", TextXAlignment = Enum.TextXAlignment.Right,
	Position = UDim2.fromOffset(0, 48), Size = UDim2.fromOffset(36, 16), Parent = U.center,
})
U.totTime = U.label({
	Text = "0:00", TextSize = 11, tc = "sub",
	Position = UDim2.fromOffset(294, 48), Size = UDim2.fromOffset(36, 16), Parent = U.center,
})

-- подсказка времени над прогрессом
U.tip = U.new("Frame", {
	AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromOffset(42, 46), Size = UDim2.fromOffset(52, 18),
	bg = "elev", Visible = false, ZIndex = 10, Parent = U.center,
})
U.corner(U.tip, 9)
U.tipLbl = U.label({
	Text = "0:00", Font = FONT_B, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Center,
	Size = UDim2.fromScale(1, 1), ZIndex = 11, Parent = U.tip,
})
function U.showTip(a, text)
	U.tip.Position = UDim2.fromOffset(42 + a * 246, 46)
	U.tipLbl.Text = text
	U.tip.Visible = true
end

-- (перенесено в таблицу U): progress
U.progress = U.makeSlider(U.center, UDim2.fromOffset(42, 55), UDim2.fromOffset(246, 4), 0, function(a)
	if sound and sound.TimeLength > 0 then
		sound.TimePosition = a * sound.TimeLength
		U.curTime.Text = U.formatTime(sound.TimePosition)
	end
end, {
	onHover = function(a)
		if sound and sound.TimeLength > 0 then U.showTip(a, U.formatTime(a * sound.TimeLength)) end
	end,
	onLeave = function() U.tip.Visible = false end,
	onRight = function(a)
		if sound and sound.TimeLength > 0 then U.addMarker(a * sound.TimeLength) end
	end,
})

U.markerLayer = U.new("Frame", {
	Position = UDim2.fromOffset(42, 49), Size = UDim2.fromOffset(246, 16),
	BackgroundTransparency = 1, ZIndex = 6, Parent = U.center,
})
U.markerBtns = {}

-- Справа: громкость и звук
U.right = U.new("Frame", {
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16, 0.5, 0),
	Size = UDim2.fromOffset(222, 40), BackgroundTransparency = 1, Parent = U.bar,
})
U.label({
	Text = "🔊", TextSize = 15, TextXAlignment = Enum.TextXAlignment.Center,
	Size = UDim2.fromOffset(22, 40), Parent = U.right,
})
local volume
volume = U.makeSlider(U.right, UDim2.fromOffset(28, 18), UDim2.fromOffset(100, 4), U.state.volume, function(a)
	U.state.volume = a
	U.applyAudio()
	U.markDirty()
end, { onWheel = function(z) U.setVolume(U.state.volume + z * 0.05) end })
U.eqBtn = U.new("TextButton", {
	Text = "Звук ⚙", Font = FONT_B, TextSize = 13, tc = "text", bg = "elev",
	Position = UDim2.fromOffset(142, 5), Size = UDim2.fromOffset(80, 30), AutoButtonColor = false, Parent = U.right,
})
U.corner(U.eqBtn, 15)
U.bouncy(U.eqBtn, 1.06)

------------------------------------------------------------
-- ПОПАПЫ
------------------------------------------------------------
U.blocker = U.new("TextButton", {
	Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 40, Parent = U.main,
})
function U.showPopup(p)
	p.Visible = true
	p.GroupTransparency = 1
	U.tween(p, 0.2, { GroupTransparency = 0 })
end
function U.hidePopup(p)
	if not p.Visible then return end
	local tw = U.tween(p, 0.15, { GroupTransparency = 1 })
	tw.Completed:Connect(function()
		if p.GroupTransparency >= 1 then p.Visible = false end
	end)
end

-- универсальное меню (ПКМ, "добавить в плейлист", подтверждения)
U.menu = U.new("CanvasGroup", {
	Size = UDim2.fromOffset(230, 200), bg = "elev", Visible = false, ZIndex = 50, Parent = U.main,
})
U.corner(U.menu, 10)
U.menuTitle = U.label({
	Text = "", Font = FONT_B, TextSize = 13, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(14, 8), Size = UDim2.new(1, -28, 0, 22), Parent = U.menu,
})
U.menuList = U.new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
	Position = UDim2.fromOffset(6, 34), Size = UDim2.new(1, -12, 1, -40),
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = U.menu,
})
U.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = U.menuList })

-- попап звука
U.eqPopup = U.new("CanvasGroup", {
	AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -BAR_H - 8),
	Size = UDim2.fromOffset(290, 364), bg = "elev", Visible = false, ZIndex = 50, Parent = U.main,
})
U.corner(U.eqPopup, 12)
U.label({
	Text = "Звук и эффекты", Font = FONT_B, TextSize = 16,
	Position = UDim2.fromOffset(20, 14), Size = UDim2.new(1, -40, 0, 22), Parent = U.eqPopup,
})
function U.popLabel(text, y)
	return U.label({
		Text = text, TextSize = 13, tc = "sub",
		Position = UDim2.fromOffset(20, y), Size = UDim2.fromOffset(160, 18), Parent = U.eqPopup,
	})
end
function U.popValue(y)
	return U.label({
		Text = "", Font = FONT_B, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromOffset(190, y), Size = UDim2.fromOffset(80, 18), Parent = U.eqPopup,
	})
end
U.popLabel("Усиление баса", 50)
U.bassVal = U.popValue(50)
U.popLabel("Кроссфейд между треками", 102)
U.xfVal = U.popValue(102)
U.popLabel("Скорость", 154)
U.popLabel("Реверберация", 224)
U.popLabel("Пресеты", 262)

local function chip(parent, text, x, y, w)
	local b = U.new("TextButton", {
		Text = text, Font = FONT_B, TextSize = 12, tc = "text", bg = "chip",
		Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, 30), AutoButtonColor = false, Parent = parent,
	})
	U.corner(b, 15)
	U.bouncy(b, 1.05)
	return b
end
function U.chipActive(b, on)
	U.tween(b, 0.15, { BackgroundColor3 = on and U.C.green or U.C.chip })
	b.TextColor3 = on and U.C.ink or U.C.text
end

U.speedChips = {}
for i, s in ipairs({ { 0.8, "0.8×" }, { 1, "1×" }, { 1.25, "1.25×" } }) do
	U.speedChips[i] = { btn = chip(U.eqPopup, s[2], 20 + (i - 1) * 86, 178, 78), value = s[1] }
end
function U.refreshSpeedChips()
	for _, c in ipairs(U.speedChips) do U.chipActive(c.btn, c.value == U.speed) end
end
function U.setSpeed(v)
	U.speed = v
	if sound then sound.PlaybackSpeed = v end
	U.refreshSpeedChips()
end
for _, c in ipairs(U.speedChips) do
	c.btn.Activated:Connect(function() U.setSpeed(c.value) end)
end

U.sw = U.new("TextButton", {
	Text = "", bg = "chip", Position = UDim2.fromOffset(226, 223), Size = UDim2.fromOffset(44, 22),
	AutoButtonColor = false, Parent = U.eqPopup,
})
U.corner(U.sw, 11)
U.swKnob = U.new("Frame", {
	AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), Size = UDim2.fromOffset(16, 16),
	BackgroundColor3 = U.rgb(255, 255, 255), BorderSizePixel = 0, Parent = U.sw,
})
U.corner(U.swKnob, 8)

-- (перенесено в таблицу U): bassSlider, xfSlider
function U.setBass(a, fromSlider)
	U.state.bass = a
	U.applyAudio()
	U.bassVal.Text = math.floor(a * 100 + 0.5) .. "%"
	if not fromSlider and U.bassSlider then U.bassSlider.Set(a) end
	U.markDirty()
end
function U.setCrossfade(sec, fromSlider)
	sec = math.clamp(math.floor(sec + 0.5), 0, 12)
	U.state.crossfade = sec
	U.xfVal.Text = sec == 0 and "Выкл" or (sec .. " с")
	if not fromSlider and U.xfSlider then U.xfSlider.Set(sec / 12) end
	U.markDirty()
end
function U.setReverb(v, instant)
	U.state.reverb = v
	U.applyAudio()
	local t = instant and 0 or 0.2
	U.tween(U.sw, t, { BackgroundColor3 = v and U.C.green or U.C.chip })
	U.tween(U.swKnob, t, { Position = v and UDim2.new(1, -19, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) }, Enum.EasingStyle.Back)
	U.markDirty()
end
U.bassSlider = U.makeSlider(U.eqPopup, UDim2.fromOffset(20, 78), UDim2.fromOffset(250, 6), U.state.bass, function(a)
	U.setBass(a, true)
end)
U.xfSlider = U.makeSlider(U.eqPopup, UDim2.fromOffset(20, 130), UDim2.fromOffset(250, 6), U.state.crossfade / 12, function(a)
	U.setCrossfade(a * 12, true)
end)
U.sw.Activated:Connect(function() U.setReverb(not U.state.reverb) end)

U.PRESETS = {
	{ "Обычный", 0, 1, false }, { "Бас", 0.6, 1, false }, { "Супер бас", 1, 1, false },
	{ "Slowed", 0.3, 0.85, true }, { "Nightcore", 0.2, 1.25, false },
}
for i, p in ipairs(U.PRESETS) do
	local col, rowI = (i - 1) % 3, math.floor((i - 1) / 3)
	local c = chip(U.eqPopup, p[1], 20 + col * 86, 286 + rowI * 36, 78)
	c.Activated:Connect(function()
		U.setBass(p[2])
		U.setSpeed(p[3])
		U.setReverb(p[4])
		U.notify("Пресет: " .. p[1])
	end)
end

-- попап горячих клавиш
U.keysPopup = U.new("CanvasGroup", {
	AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(400, 470), bg = "elev", Visible = false, ZIndex = 50, Parent = U.main,
})
U.corner(U.keysPopup, 14)
U.label({
	Text = "Горячие клавиши", Font = FONT_B, TextSize = 17,
	Position = UDim2.fromOffset(20, 14), Size = UDim2.new(1, -40, 0, 24), Parent = U.keysPopup,
})
U.label({
	Text = "Нажми на кнопку справа и затем на новую клавишу (Backspace — снять, Esc — отмена).\nМышь: ПКМ по треку — меню · ПКМ по полосе — маркер · колесо над громкостью.",
	TextSize = 11, tc = "sub", TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
	Position = UDim2.fromOffset(20, 40), Size = UDim2.new(1, -40, 0, 44), Parent = U.keysPopup,
})
U.keysList = U.new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
	Position = UDim2.fromOffset(12, 90), Size = UDim2.new(1, -24, 1, -142),
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = U.keysPopup,
})
U.new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = U.keysList })
U.keysReset = chip(U.keysPopup, "Сбросить всё", 20, 428, 120)
U.keysClose = chip(U.keysPopup, "Закрыть", 280, 428, 100)

-- (перенесено в таблицу U): listening
function U.refreshKeys()
	for _, c in ipairs(U.keysList:GetChildren()) do
		if c:IsA("Frame") then c:Destroy() end
	end
	for i, a in ipairs(U.ACTIONS) do
		local row = U.new("Frame", { Size = UDim2.new(1, -8, 0, 32), BackgroundTransparency = 1, LayoutOrder = i, Parent = U.keysList })
		U.label({ Text = a.name, TextSize = 13, Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -120, 1, 0), Parent = row })
		local waiting = U.listening == a.id
		local kb = U.new("TextButton", {
			Text = waiting and "нажми…" or U.keyLabel(a.id), Font = FONT_B, TextSize = 12,
			TextColor3 = waiting and U.C.ink or U.C.text, BackgroundColor3 = waiting and U.C.green or U.C.chip,
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0.5, 0),
			Size = UDim2.fromOffset(96, 26), AutoButtonColor = false, Parent = row,
		})
		U.corner(kb, 13)
		kb.Activated:Connect(function()
			U.listening = a.id
			U.refreshKeys()
		end)
	end
end
U.keysReset.Activated:Connect(function()
	U.state.binds = {}
	U.listening = nil
	U.refreshKeys()
	U.markDirty()
	U.notify("Клавиши сброшены")
end)

-- попап с многострочным текстом (импорт / экспорт)
U.textPopup = U.new("CanvasGroup", {
	AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(440, 340), bg = "elev", Visible = false, ZIndex = 50, Parent = U.main,
})
U.corner(U.textPopup, 14)
U.textTitle = U.label({
	Text = "", Font = FONT_B, TextSize = 17, TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(20, 14), Size = UDim2.new(1, -40, 0, 24), Parent = U.textPopup,
})
U.textHint = U.label({
	Text = "", TextSize = 12, tc = "sub", TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
	Position = UDim2.fromOffset(20, 42), Size = UDim2.new(1, -40, 0, 34), Parent = U.textPopup,
})
U.textFrame = U.new("Frame", {
	Position = UDim2.fromOffset(20, 82), Size = UDim2.new(1, -40, 1, -142), bg = "chip", Parent = U.textPopup,
})
U.corner(U.textFrame, 10)
U.textBox = U.new("TextBox", {
	Text = "", PlaceholderText = "12345678, 87654321, …", PlaceholderColor3 = U.rgb(140, 140, 150),
	MultiLine = true, TextWrapped = true, ClearTextOnFocus = false, Font = FONT, TextSize = 13, tc = "text",
	TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, BackgroundTransparency = 1,
	Position = UDim2.fromOffset(10, 8), Size = UDim2.new(1, -20, 1, -16), Parent = U.textFrame,
})
U.textOk = chip(U.textPopup, "OK", 20, 296, 170)
U.textCancel = chip(U.textPopup, "Закрыть", 320, 296, 100)

function U.closePopups()
	U.hidePopup(U.textPopup)
	U.hidePopup(U.eqPopup)
	U.hidePopup(U.menu)
	U.hidePopup(U.keysPopup)
	U.blocker.Visible = false
	U.listening = nil
end
U.keysClose.Activated:Connect(U.closePopups)
U.blocker.Activated:Connect(U.closePopups)

U.eqBtn.Activated:Connect(function()
	if U.eqPopup.Visible and U.eqPopup.GroupTransparency < 0.5 then
		U.closePopups()
	else
		U.closePopups()
		U.showPopup(U.eqPopup)
		U.blocker.Visible = true
	end
end)
U.keysBtn.Activated:Connect(function()
	U.closePopups()
	U.refreshKeys()
	U.showPopup(U.keysPopup)
	U.blocker.Visible = true
end)

------------------------------------------------------------
-- ВЕРХНЯЯ ПОЛОСА, КНОПКА-ТОГГЛ, МИНИ-РЕЖИМ
------------------------------------------------------------
U.dragHandle = U.new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, ZIndex = 5, Parent = U.main })
do
	local dragging, dragStart, startPos
	U.dragHandle.InputBegan:Connect(function(input)
		if U.isPointer(input) then
			dragging, dragStart, startPos = true, input.Position, U.root.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and U.isMove(input) then
			local d = (input.Position - dragStart) / U.uiScale.Scale
			U.root.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if U.isPointer(input) then dragging = false end
	end)
end

U.closeBtn = U.new("TextButton", {
	Text = "×", Font = FONT_B, TextSize = 15, tc = "sub", BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0, 18), Size = UDim2.fromOffset(28, 28),
	ZIndex = 6, Parent = U.main,
})
U.bouncy(U.closeBtn, 1.15)

U.toggleBtn = U.new("TextButton", {
	Text = "♪", Font = FONT_X, TextSize = 24, tc = "ink", bg = "green",
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -16), Size = UDim2.fromOffset(46, 46),
	AutoButtonColor = false, Parent = U.gui,
})
U.corner(U.toggleBtn, 23)
U.bouncy(U.toggleBtn, 1.1)

-- мини-плеер
U.miniRoot = U.new("CanvasGroup", {
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -74), Size = UDim2.fromOffset(360, 76),
	bg = "panel", Visible = false, Parent = U.gui,
})
U.corner(U.miniRoot, 14)
U.miniScale = U.new("UIScale", { Parent = U.miniRoot })
U.miniCover = U.new("Frame", {
	Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(54, 54),
	BackgroundColor3 = U.rgb(255, 255, 255), BorderSizePixel = 0, Parent = U.miniRoot,
})
U.corner(U.miniCover, 8)
U.miniCoverGrad = U.new("UIGradient", {
	Color = ColorSequence.new(U.rgb(120, 120, 130), U.rgb(70, 70, 80)), Rotation = 45, Parent = U.miniCover,
})
U.miniCoverScale = U.new("UIScale", { Parent = U.miniCover })
U.label({
	Text = "♪", Font = FONT_B, TextSize = 22, TextColor3 = U.rgb(255, 255, 255),
	TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = U.miniCover,
})
U.miniTitle = U.label({
	Text = "Ничего не играет", Font = FONT_B, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(74, 16), Size = UDim2.fromOffset(126, 20), Parent = U.miniRoot,
})
U.miniArtist = U.label({
	Text = "", TextSize = 12, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(74, 38), Size = UDim2.fromOffset(126, 16), Parent = U.miniRoot,
})
U.miniDrag = U.new("Frame", { Size = UDim2.fromOffset(204, 76), BackgroundTransparency = 1, Parent = U.miniRoot })
function U.miniBtnMake(text, x, size, circle)
	local b = U.new("TextButton", {
		Text = text, Font = FONT_B, TextSize = size, tc = circle and "bg" or "text",
		BackgroundTransparency = circle and 0 or 1, bg = circle and "text" or nil,
		Position = UDim2.fromOffset(x, circle and 19 or 22), Size = UDim2.fromOffset(circle and 38 or 30, circle and 38 or 32),
		AutoButtonColor = false, Parent = U.miniRoot,
	})
	if circle then U.corner(b, 19) end
	U.bouncy(b, 1.1)
	return b
end
U.miniPrev = U.miniBtnMake("⏮", 206, 16)
U.miniPlay = U.miniBtnMake("▶", 240, 16, true)
U.miniNext = U.miniBtnMake("⏭", 284, 16)
U.miniExpand = U.miniBtnMake("▲", 320, 18)
U.miniExpand.TextColor3 = U.C.sub
U.themed[#U.themed + 1] = { U.miniExpand, "TextColor3", "sub" }
U.miniTrack = U.new("Frame", {
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 3), bg = "elev", BorderSizePixel = 0, Parent = U.miniRoot,
})
U.miniFill = U.new("Frame", { Size = UDim2.fromScale(0, 1), bg = "green", BorderSizePixel = 0, Parent = U.miniTrack })

do
	local dragging, dragStart, startPos
	U.miniDrag.InputBegan:Connect(function(input)
		if U.isPointer(input) then
			dragging, dragStart, startPos = true, input.Position, U.miniRoot.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and U.isMove(input) then
			local d = input.Position - dragStart
			U.miniRoot.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if U.isPointer(input) then dragging = false end
	end)
end

function U.setMode(m)
	if m == uiMode then return end
	local old = uiMode
	uiMode = m
	if m ~= "hidden" then lastShown = m end
	U.closePopups()

	if old == "full" then
		local tw = U.tween(U.main, 0.2, { Position = UDim2.fromOffset(0, 18), GroupTransparency = 1 })
		tw.Completed:Connect(function()
			if uiMode ~= "full" then U.main.Visible = false end
		end)
	elseif old == "mini" then
		local tw = U.tween(U.miniRoot, 0.2, { GroupTransparency = 1 })
		tw.Completed:Connect(function()
			if uiMode ~= "mini" then U.miniRoot.Visible = false end
		end)
	end

	if m == "full" then
		U.main.Visible = true
		U.main.Position = UDim2.fromOffset(0, 28)
		U.main.GroupTransparency = 1
		U.tween(U.main, 0.4, { Position = UDim2.fromOffset(0, 0), GroupTransparency = 0 }, Enum.EasingStyle.Quint)
	elseif m == "mini" then
		U.miniRoot.Visible = true
		U.miniRoot.GroupTransparency = 1
		U.miniScale.Scale = 0.9
		U.tween(U.miniRoot, 0.3, { GroupTransparency = 0 })
		U.tween(U.miniScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
	end
end

------------------------------------------------------------
-- СОХРАНЕНИЕ
------------------------------------------------------------
function U.stateData()
	return {
		playlists = U.state.playlists, liked = U.state.liked, volume = U.state.volume, bass = U.state.bass,
		reverb = U.state.reverb, last = U.state.last, theme = U.state.theme, crossfade = U.state.crossfade,
		binds = U.state.binds, markers = U.state.markers,
		history = U.state.history, genres = U.state.genres, radio = U.state.radio,
	}
end

function U.pushSave()
	if not loaded then return end
	storageSave(U.stateData())
end

function U.markDirty()
	if not loaded then return end
	saveToken += 1
	local my = saveToken
	task.delay(2, function()
		if my == saveToken then U.pushSave() end
	end)
end

------------------------------------------------------------
-- МЕТАДАННЫЕ ТРЕКОВ
------------------------------------------------------------
U.metaCache = {}
function U.fetchInfo(track)
	local c = U.metaCache[track.id]
	if not c then
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(track.id, Enum.InfoType.Asset)
		end)
		if ok and info then
			c = {
				title = cutText(tostring(info.Name), 60),
				artist = cutText(info.Creator and tostring(info.Creator.Name) or "—", 40),
			}
			U.metaCache[track.id] = c
		else
			c = { title = "Трек " .. track.id, artist = "—" }
		end
	end
	track.title = track.title or c.title
	track.artist = track.artist or c.artist
end

function U.hydrateTitles()
	task.spawn(function()
		local changed = false
		local function pass(list)
			for _, t in ipairs(list) do
				if not t.title or not t.artist then
					U.fetchInfo(t)
					changed = true
					U.refreshTexts()
					task.wait(0.15)
				end
			end
		end
		for _, p in ipairs(U.state.playlists) do pass(p.tracks) end
		pass(U.state.liked)
		pass(U.state.history)
		if changed then U.markDirty() end
	end)
end

------------------------------------------------------------
-- МАРКЕРЫ НА ПРОГРЕСС-БАРЕ
------------------------------------------------------------
function U.markersFor(track, create)
	local key = tostring(track.id)
	local list = U.state.markers[key]
	if not list and create then
		list = {}
		U.state.markers[key] = list
	end
	return list
end

function U.rebuildMarkers()
	for _, b in ipairs(U.markerBtns) do b:Destroy() end
	U.markerBtns = {}
	if not current or not sound or sound.TimeLength <= 0 then return end
	local list = U.markersFor(current, false)
	if not list then return end
	local len = sound.TimeLength
	for i, sec in ipairs(list) do
		local a = math.clamp(sec / len, 0, 1)
		local b = U.new("TextButton", {
			Text = "", BackgroundColor3 = U.C.marker, AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(a, 0, 0.5, 0), Size = UDim2.fromOffset(6, 13),
			AutoButtonColor = false, ZIndex = 7, Parent = U.markerLayer,
		})
		U.corner(b, 2)
		b.Activated:Connect(function()
			if sound then sound.TimePosition = sec end
		end)
		b.MouseButton2Click:Connect(function()
			table.remove(list, i)
			if #list == 0 then U.state.markers[tostring(current.id)] = nil end
			U.markerLen = -1
			U.markDirty()
			U.notify("Маркер удалён")
		end)
		b.MouseEnter:Connect(function() U.showTip(a, "🚩 " .. U.formatTime(sec)) end)
		b.MouseLeave:Connect(function() U.tip.Visible = false end)
		U.markerBtns[#U.markerBtns + 1] = b
	end
end

function U.addMarker(sec)
	if not (current and sound and sound.TimeLength > 0) then
		U.notify("Сначала включи трек")
		return
	end
	sec = sec or sound.TimePosition
	sec = math.floor(sec * 10) / 10
	local list = U.markersFor(current, true)
	if #list >= 20 then
		U.notify("Максимум 20 маркеров на трек")
		return
	end
	table.insert(list, sec)
	table.sort(list)
	U.markerLen = -1
	U.markDirty()
	U.notify("🚩 Маркер " .. U.formatTime(sec) .. " (ПКМ по маркеру — удалить)")
end

------------------------------------------------------------
-- ВОСПРОИЗВЕДЕНИЕ (+ кроссфейд)
------------------------------------------------------------
function U.playAt(i, fadeSec)
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
	s.SoundGroup = U.group
	s.PlaybackSpeed = U.speed
	s.Looped = (repeatMode == 2)
	s.Volume = fadeSec > 0 and 0 or 1
	s.Parent = SoundService
	sound = s
	U.markerLen = -1

	if old then
		if fadeSec > 0 and old.IsPlaying then
			local tw = U.tween(old, fadeSec, { Volume = 0 }, Enum.EasingStyle.Linear)
			tw.Completed:Connect(function() old:Destroy() end)
		else
			old:Destroy()
		end
	end
	if fadeSec > 0 then U.tween(s, fadeSec, { Volume = 1 }, Enum.EasingStyle.Linear) end

	s.Ended:Connect(function()
		if s == sound and my == playToken then U.nextTrack(true, false) end
	end)
	s:GetPropertyChangedSignal("IsPlaying"):Connect(function()
		if s == sound then U.updatePlayState() end
	end)
	s:Play()
	U.updateNowPlaying()

	task.spawn(function()
		local t0 = os.clock()
		while my == playToken and not s.IsLoaded and os.clock() - t0 < 8 do
			task.wait(0.1)
		end
		if my ~= playToken then return end
		if s.IsLoaded and s.TimeLength > 0 then
			failStreak = 0
			recordPlay(track.id)
			U.pushHistory(track)
		else
			U.badIds[track.id] = true
			failStreak += 1
			U.notify("Трек недоступен (нет прав на это аудио)")
			U.updateNowPlaying()
			if failStreak < #queue then
				task.wait(0.8)
				if my == playToken then U.nextTrack(true, false) end
			end
		end
	end)
end

function U.playFromList(list, i)
	queue = {}
	for k, t in ipairs(list) do queue[k] = t end
	failStreak = 0
	U.playAt(i, math.min(U.state.crossfade, 0.8))
end

-- auto: следующий трек сам; early: запуск за N секунд до конца (кроссфейд)
function U.nextTrack(auto, early)
	local n = #queue
	if n == 0 then return end
	if U.state.radio and not shuffle and qi >= n then
		U.radioFill()
		n = #queue
	end
	local fadeSec = early and U.state.crossfade or (auto and 0 or math.min(U.state.crossfade, 0.8))
	local target
	if shuffle and n > 1 then
		for _ = 1, 12 do
			local c = math.random(n)
			if c ~= qi and not U.badIds[queue[c].id] then
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
					U.updatePlayState()
					return
				end
			end
			if not U.badIds[queue[c].id] then
				target = c
				break
			end
		end
	end
	if target then U.playAt(target, fadeSec) end
end

function U.prevTrack()
	if #queue == 0 then return end
	if sound and sound.TimePosition > 3 then
		sound.TimePosition = 0
		return
	end
	local c = qi - 1
	if c < 1 then c = #queue end
	U.playAt(c, math.min(U.state.crossfade, 0.8))
end

function U.togglePlay()
	if not sound then
		local list = U.displayList()
		if #list > 0 then U.playFromList(list, shuffle and math.random(#list) or 1) end
	elseif sound.IsPlaying then
		sound:Pause()
	else
		sound:Play()
	end
end

function U.setVolume(a)
	U.state.volume = math.clamp(a, 0, 1)
	U.applyAudio()
	volume.Set(U.state.volume)
	U.markDirty()
end

------------------------------------------------------------
-- ОБНОВЛЕНИЕ ИНТЕРФЕЙСА
------------------------------------------------------------
local rows, sideBtns = {}, {}

function U.refreshRowStates()
	for i, r in ipairs(rows) do
		local active = current ~= nil and r.track.id == current.id
		local bad = U.badIds[r.track.id]
		r.title.TextColor3 = bad and U.C.red or (active and U.C.green or U.C.text)
		r.num.TextColor3 = active and U.C.green or U.C.sub
		r.num.Text = (active and sound and sound.IsPlaying) and "♪" or tostring(i)
	end
end

function U.updateHearts()
	for _, r in ipairs(rows) do
		r.heart.TextColor3 = U.isLiked(r.track.id) and U.C.green or U.C.elev2
	end
	U.barHeart.TextColor3 = (current and U.isLiked(current.id)) and U.C.green or U.C.elev2
end

function U.updatePlayState()
	local playing = sound ~= nil and sound.IsPlaying
	local g = playing and "II" or "▶"
	U.playBtn.Text, U.bigPlay.Text, U.miniPlay.Text = g, g, g
	U.refreshRowStates()
end

function U.updateNowPlaying()
	local t = current
	if t then
		U.barTitle.Text = t.title or "Загрузка…"
		U.barArtist.Text = t.artist or ""
		local cs = ColorSequence.new(U.accent(t.id, 0.95), U.accent(t.id, 0.45))
		U.barCoverGrad.Color = cs
		U.miniCoverGrad.Color = cs
	else
		U.barTitle.Text = "Ничего не играет"
		U.barArtist.Text = "Выбери трек"
		local cs = ColorSequence.new(U.rgb(120, 120, 130), U.rgb(70, 70, 80))
		U.barCoverGrad.Color = cs
		U.miniCoverGrad.Color = cs
	end
	U.miniTitle.Text = U.barTitle.Text
	U.miniArtist.Text = U.barArtist.Text
	U.updateHearts()
	U.updatePlayState()
	if U.refreshRadio then U.refreshRadio() end
	if U.view.kind == "queue" then
		U.renderList()
		U.renderBanner()
	end
end

function U.refreshTexts()
	for _, r in ipairs(rows) do
		r.title.Text = r.track.title or "Загрузка…"
		r.artist.Text = U.artistText(r.track)
	end
	if current then
		U.barTitle.Text = current.title or "Загрузка…"
		U.barArtist.Text = current.artist or ""
		U.miniTitle.Text, U.miniArtist.Text = U.barTitle.Text, U.barArtist.Text
	end
end

function U.renderBanner()
	local title, kind, icon, h
	if U.view.kind == "liked" then
		title, kind, icon, h = "Любимое", "ПЛЕЙЛИСТ", "♥", 0.72
	elseif U.view.kind == "top" then
		title, kind, icon, h = "Топ чарт", "ПОПУЛЯРНОЕ СРЕДИ ИГРОКОВ", "🔥", 0.02
	elseif U.view.kind == "queue" then
		title, kind, icon, h = "Следующие", "ОЧЕРЕДЬ ВОСПРОИЗВЕДЕНИЯ", "⏭", 0.6
	elseif U.view.kind == "history" then
		title, kind, icon, h = "История", "ПОСЛЕДНИЕ ПРОСЛУШИВАНИЯ", "🕘", 0.1
	elseif U.view.kind == "search" then
		title, kind, icon, h = "Поиск", "РЕЗУЛЬТАТЫ ПО ВСЕЙ БИБЛИОТЕКЕ", "🔍", 0.55
	else
		local p = U.state.playlists[U.view.index]
		title, kind, icon, h = p.name, "ПЛЕЙЛИСТ", "♪", U.hueFor(p.name)
	end
	U.bannerTitle.Text = title
	U.bannerKind.Text = kind
	U.bannerIcon.Text = icon
	U.bannerSub.Text = (U.view.kind == "top" and topState == "loading") and "Загрузка…" or U.pluralTracks(#U.currentList())
	if U.view.kind == "queue" and U.state.radio then U.bannerSub.Text = U.bannerSub.Text .. "  ·  📻 радио" end
	U.tween(U.banner, 0.5, { BackgroundColor3 = U.accentH(h, U.C.bannerV, U.C.bannerS) })
	U.bannerCoverGrad.Color = ColorSequence.new(U.accentH(h, 0.95), U.accentH(h, 0.45))
	local editable = U.view.kind == "pl" or U.view.kind == "liked"
	U.addRow.Visible = editable
	U.sortBtn.Visible = editable
	U.topHint.Visible = U.view.kind == "top"
	U.menuBtn.Visible = editable or U.view.kind == "queue" or U.view.kind == "history"
end

function U.addToPlaylist(i, track)
	local p = U.state.playlists[i]
	if not p then return end
	for _, t in ipairs(p.tracks) do
		if t.id == track.id then
			U.notify("Уже есть в «" .. p.name .. "»")
			return
		end
	end
	if #p.tracks >= MAX_TRACKS then
		U.notify("Плейлист заполнен")
		return
	end
	table.insert(p.tracks, { id = track.id, title = track.title, artist = track.artist })
	U.notify("Добавлено в «" .. p.name .. "»")
	U.markDirty()
	if U.view.kind == "pl" and U.view.index == i then
		U.renderList()
		U.renderBanner()
	end
end

function U.openAddMenu(track, at)
	local items = {}
	for i, p in ipairs(U.state.playlists) do
		items[#items + 1] = { text = p.name, fn = function() U.addToPlaylist(i, track) end }
	end
	U.openMenu("Добавить в плейлист", items, at)
end

function U.toggleLike(track)
	for i, t in ipairs(U.state.liked) do
		if t.id == track.id then
			table.remove(U.state.liked, i)
			U.updateHearts()
			if U.view.kind == "liked" then
				U.renderList()
				U.renderBanner()
			end
			U.markDirty()
			U.notify("Убрано из любимого")
			return
		end
	end
	if #U.state.liked >= MAX_TRACKS then
		U.notify("В любимом слишком много треков")
		return
	end
	table.insert(U.state.liked, { id = track.id, title = track.title, artist = track.artist })
	U.updateHearts()
	if U.view.kind == "liked" then
		U.renderList()
		U.renderBanner()
	end
	U.markDirty()
	U.notify("Добавлено в любимое ♥")
end

function U.removeFromView(track)
	if U.view.kind == "queue" then
		for j = qi + 1, #queue do
			if queue[j] == track then
				table.remove(queue, j)
				break
			end
		end
		U.renderList()
		U.renderBanner()
		return
	end
	local list
	if U.view.kind == "pl" then
		list = U.state.playlists[U.view.index].tracks
	elseif U.view.kind == "liked" then
		list = U.state.liked
	else
		return
	end
	for i, t in ipairs(list) do
		if t == track then
			table.remove(list, i)
			break
		end
	end
	U.markDirty()
	U.renderList()
	U.renderBanner()
end

-- Контекстное меню трека (ПКМ)
function U.openTrackMenu(track, list, idx)
	local at = U.pointer()
	local items = {
		{
			text = "▶  Играть",
			fn = function()
				if U.view.kind == "queue" then
					U.playAt(qi + idx, 0)
				else
					U.playFromList(list, idx)
				end
			end,
		},
		{
			text = "⏭  Играть следующим",
			fn = function()
				if #queue == 0 then
					U.playFromList({ track }, 1)
				else
					table.insert(queue, qi + 1, track)
					U.notify("Будет играть следующим")
				end
			end,
		},
		{
			text = U.isLiked(track.id) and "♥  Убрать из любимого" or "♥  В любимое",
			fn = function() U.toggleLike(track) end,
		},
		{ text = "+  В плейлист…", fn = function() U.openAddMenu(track, at) end },
	}
	if U.view.kind == "pl" or U.view.kind == "liked" or U.view.kind == "queue" then
		items[#items + 1] = { text = "×  Убрать из списка", color = U.C.red, fn = function() U.removeFromView(track) end }
	end
	items[#items + 1] = { text = "🎼  Жанр…", fn = function() U.openGenreMenu(track, at) end }
	items[#items + 1] = { text = "📋  Копировать ID", fn = function() U.copyId(track) end }
	U.openMenu(track.title or "Трек", items, at)
end

------------------------------------------------------------
-- DRAG & DROP (мышь)
------------------------------------------------------------
local cand, drag, dropFlag = nil, nil, false

function U.resetDropHighlights()
	for _, sb in ipairs(sideBtns) do
		sb.btn.BackgroundTransparency = sb.active and 0 or 1
	end
	navLiked.BackgroundTransparency = U.view.kind == "liked" and 0 or 1
end

function U.startDrag(track)
	local ghost = U.new("Frame", {
		Size = UDim2.fromOffset(230, 38), BackgroundColor3 = U.C.elev, ZIndex = 200, Parent = U.gui,
	})
	U.corner(ghost, 8)
	U.new("UIScale", { Scale = U.uiScale.Scale, Parent = ghost })
	U.new("UIStroke", { Color = U.C.green, Thickness = 1.5, Parent = ghost })
	U.label({
		Text = "♪  " .. (track.title or "Трек"), Font = FONT_B, TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = U.C.text, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -20, 1, 0), ZIndex = 201, Parent = ghost,
	})
	local line = U.new("Frame", {
		BackgroundColor3 = U.C.green, BorderSizePixel = 0, Visible = false, ZIndex = 150, Parent = U.gui,
	})
	drag = { track = track, ghost = ghost, line = line }
end

function U.updateDrag()
	local p = U.pointer()
	drag.ghost.Position = UDim2.fromOffset(p.X + 14, p.Y + 10)
	drag.target = nil
	drag.line.Visible = false
	U.resetDropHighlights()

	for i, sb in ipairs(sideBtns) do
		if U.inside(sb.btn, p) then
			drag.target = { kind = "pl", index = i }
			sb.btn.BackgroundTransparency = 0.3
			return
		end
	end
	if U.inside(navLiked, p) then
		drag.target = { kind = "liked" }
		navLiked.BackgroundTransparency = 0.3
		return
	end
	if (U.view.kind == "pl" or U.view.kind == "liked") and U.sortMode == "manual" and U.inside(U.listWrap, p) then
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
			y = U.listWrap.AbsolutePosition.Y
		end
		drag.line.Position = UDim2.fromOffset(U.listWrap.AbsolutePosition.X + 10, y - 1)
		drag.line.Size = UDim2.fromOffset(U.listWrap.AbsoluteSize.X - 20, 2)
		drag.line.Visible = true
	end
end

function U.finishDrag()
	local d = drag
	drag = nil
	d.ghost:Destroy()
	d.line:Destroy()
	U.resetDropHighlights()
	dropFlag = true
	task.delay(0.2, function() dropFlag = false end)

	local t = d.target
	if not t then return end
	if t.kind == "pl" then
		U.addToPlaylist(t.index, d.track)
	elseif t.kind == "liked" then
		if U.isLiked(d.track.id) then
			U.notify("Уже в любимом")
		else
			U.toggleLike(d.track)
		end
	elseif t.kind == "reorder" then
		local list = U.currentList()
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
			U.markDirty()
			U.renderList()
		end
	end
end

UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
	if cand and not drag and (U.pointer() - cand.startPos).Magnitude > 8 then
		U.startDrag(cand.track)
	end
	if drag then U.updateDrag() end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		cand = nil
		if drag then U.finishDrag() end
	end
end)

------------------------------------------------------------
-- МЕНЮ
------------------------------------------------------------
function U.openMenu(title, items, at)
	U.closePopups()
	for _, c in ipairs(U.menuList:GetChildren()) do
		if c:IsA("TextButton") then c:Destroy() end
	end
	local hasTitle = title ~= nil and title ~= ""
	U.menuTitle.Visible = hasTitle
	U.menuTitle.Text = title or ""
	U.menuList.Position = UDim2.fromOffset(6, hasTitle and 34 or 6)
	for i, it in ipairs(items) do
		local b = U.new("TextButton", {
			Text = "  " .. it.text, Font = FONT, TextSize = 14, TextColor3 = it.color or U.C.text,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
			BackgroundColor3 = U.C.chip, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32),
			AutoButtonColor = false, LayoutOrder = i, Parent = U.menuList,
		})
		U.corner(b, 6)
		b.MouseEnter:Connect(function() U.tween(b, 0.1, { BackgroundTransparency = 0 }) end)
		b.MouseLeave:Connect(function() U.tween(b, 0.1, { BackgroundTransparency = 1 }) end)
		b.Activated:Connect(function()
			U.closePopups()
			it.fn()
		end)
	end
	local h = math.min(320, (hasTitle and 40 or 12) + #items * 32)
	U.menu.Size = UDim2.fromOffset(230, h)
	local rel = (at - U.main.AbsolutePosition) / U.uiScale.Scale
	U.menu.Position = UDim2.fromOffset(
		math.clamp(rel.X, 6, W - 236),
		math.clamp(rel.Y, 40, H - BAR_H - h - 4)
	)
	U.blocker.Visible = true
	U.showPopup(U.menu)
end

------------------------------------------------------------
-- СПИСОК ТРЕКОВ
------------------------------------------------------------
function U.renderList()
	for _, r in ipairs(rows) do r.button:Destroy() end
	rows = {}
	if U.view.kind == "search" then searchList = U.buildSearch(searchQuery) end
	local list = U.displayList()

	U.emptyLbl.Visible = false
	if U.view.kind == "top" and topState == "loading" then
		U.emptyLbl.Text = "Загрузка чарта…"
		U.emptyLbl.Visible = true
	elseif #list == 0 then
		if U.view.kind == "top" then
			U.emptyLbl.Text = "Чарт пока пуст. Слушай музыку — треки появятся здесь."
		elseif U.view.kind == "queue" then
			U.emptyLbl.Text = "Очередь пуста. Включи трек из плейлиста — следующие появятся здесь. Или включи радио 📻."
		elseif U.view.kind == "history" then
			U.emptyLbl.Text = "История пока пуста. Включи любой трек."
		elseif U.view.kind == "search" then
			U.emptyLbl.Text = "Ничего не найдено. Ищу по названию, исполнителю и ID."
		else
			U.emptyLbl.Text = "Здесь пока пусто. Добавь трек по ID или через «+» у любого трека."
		end
		U.emptyLbl.Visible = true
	end

	for i, track in ipairs(list) do
		local btn = U.new("TextButton", {
			Text = "", Size = UDim2.new(1, -8, 0, 52), BackgroundColor3 = U.C.hover, BackgroundTransparency = 1,
			AutoButtonColor = false, LayoutOrder = i, Parent = U.scroll,
		})
		U.corner(btn, 8)
		local num = U.label({
			Text = tostring(i), TextColor3 = U.C.sub, TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.fromOffset(40, 52), Parent = btn,
		})
		local mini = U.new("Frame", {
			Position = UDim2.fromOffset(46, 9), Size = UDim2.fromOffset(34, 34),
			BackgroundColor3 = U.rgb(255, 255, 255), BorderSizePixel = 0, Parent = btn,
		})
		U.corner(mini, 5)
		U.new("UIGradient", {
			Color = ColorSequence.new(U.accent(track.id, 0.95), U.accent(track.id, 0.45)), Rotation = 45, Parent = mini,
		})
		U.label({
			Text = "♪", Font = FONT_B, TextSize = 16, TextColor3 = U.rgb(255, 255, 255),
			TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = mini,
		})
		local title = U.label({
			Text = track.title or "Загрузка…", Font = FONT_B, TextSize = 14, TextColor3 = U.C.text,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(90, 8), Size = UDim2.new(1, -230, 0, 20), Parent = btn,
		})
		local artist = U.label({
			Text = U.artistText(track), TextSize = 12, TextColor3 = U.C.sub, TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(90, 28), Size = UDim2.new(1, -230, 0, 16), Parent = btn,
		})

		local function iconBtn(text, x, color)
			local b = U.new("TextButton", {
				Text = text, Font = FONT_B, TextSize = 18, TextColor3 = color or U.C.elev2, BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, x, 0.5, 0), Size = UDim2.fromOffset(30, 30), Parent = btn,
			})
			U.bouncy(b, 1.15)
			return b
		end
		local heart = iconBtn("♥", -86)
		local addB = iconBtn("+", -50, U.C.sub)
		heart.Activated:Connect(function()
			U.toggleLike(track)
			U.pop(heart)
		end)
		addB.Activated:Connect(function()
			U.openAddMenu(track, addB.AbsolutePosition + Vector2.new(-200, 28))
		end)

		if U.view.kind == "top" then
			U.label({
				Text = tostring(track.plays or 0) .. " ▶", Font = FONT_B, TextSize = 12, TextColor3 = U.C.sub,
				TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(40, 20), Parent = btn,
			})
		elseif U.view.kind == "pl" or U.view.kind == "liked" or U.view.kind == "queue" then
			local rm = iconBtn("×", -14, U.C.sub)
			rm.Activated:Connect(function() U.removeFromView(track) end)
		end

		btn.MouseEnter:Connect(function() U.tween(btn, 0.12, { BackgroundTransparency = 0 }) end)
		btn.MouseLeave:Connect(function() U.tween(btn, 0.12, { BackgroundTransparency = 1 }) end)
		btn.Activated:Connect(function()
			if dropFlag or drag then return end
			if U.view.kind == "queue" then
				failStreak = 0
				U.playAt(qi + i, math.min(U.state.crossfade, 0.8))
			else
				U.playFromList(list, i)
			end
		end)
		btn.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				cand = { track = track, startPos = U.pointer() }
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				U.openTrackMenu(track, list, i)
			elseif input.UserInputType == Enum.UserInputType.Touch then
				-- долгое нажатие на телефоне = меню трека (вместо ПКМ)
				local held, p0 = true, input.Position
				local c
				c = input:GetPropertyChangedSignal("UserInputState"):Connect(function()
					if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then
						held = false
						c:Disconnect()
					end
				end)
				task.delay(0.5, function()
					if held and (input.Position - p0).Magnitude < 12 then
						held = false
						dropFlag = true
						task.delay(0.35, function() dropFlag = false end)
						U.openTrackMenu(track, list, i)
					end
				end)
			end
		end)

		rows[i] = { button = btn, track = track, num = num, title = title, artist = artist, heart = heart }
	end
	U.updateHearts()
	U.refreshRowStates()
end

------------------------------------------------------------
-- САЙДБАР: плейлисты
------------------------------------------------------------
-- (перенесено в таблицу U): armedDelete, renameIndex

function U.deletePlaylist(i)
	if #U.state.playlists <= 1 then
		U.notify("Нельзя удалить единственный плейлист")
		return
	end
	table.remove(U.state.playlists, i)
	if U.view.kind == "pl" then
		if U.view.index == i then
			U.view.index = 1
		elseif U.view.index > i then
			U.view.index -= 1
		end
		U.state.last = U.view.index
	end
	U.markDirty()
	U.notify("Плейлист удалён")
	U.setView(U.view)
end

function U.startRename(i)
	U.renameIndex = i
	U.plNameBox.Text = U.state.playlists[i].name
	U.plNameBox.Visible = true
	U.layoutSidebar()
	U.plNameBox:CaptureFocus()
end

function U.openPlaylistMenu(i, at)
	at = at or U.pointer()
	local p = U.state.playlists[i]
	U.openMenu(p.name, {
		{
			text = "▶  Играть",
			fn = function()
				if #p.tracks > 0 then U.playFromList(p.tracks, 1) end
			end,
		},
		{ text = "📝  Переименовать", fn = function() U.startRename(i) end },
		{ text = "📥  Импорт ID…", fn = function() U.openImport() end },
		{ text = "📤  Экспорт…", fn = function() U.openExportMenu(p.name, p.tracks, at) end },
		{
			text = "×  Удалить…", color = U.C.red,
			fn = function()
				U.openMenu("Удалить «" .. p.name .. "»?", {
					{ text = "Да, удалить", color = U.C.red, fn = function() U.deletePlaylist(i) end },
					{ text = "Отмена", fn = function() end },
				}, at)
			end,
		},
	}, at)
end

function U.renderSidebar()
	local function setNav(btn, ic, tx, active)
		btn.BackgroundTransparency = active and 0 or 1
		tx.TextColor3 = active and U.C.text or U.C.sub
		ic.TextColor3 = active and U.C.green or U.C.sub
	end
	setNav(navLiked, navLikedIc, navLikedTx, U.view.kind == "liked")
	setNav(navTop, navTopIc, navTopTx, U.view.kind == "top")
	setNav(U.navQueue, U.navQueueIc, U.navQueueTx, U.view.kind == "queue")
	setNav(U.navHistory, U.navHistoryIc, U.navHistoryTx, U.view.kind == "history")

	for _, c in ipairs(U.plScroll:GetChildren()) do
		if c:IsA("GuiButton") then c:Destroy() end
	end
	sideBtns = {}
	for i, p in ipairs(U.state.playlists) do
		local active = U.view.kind == "pl" and U.view.index == i
		local b, ic, tx = U.sideButton(U.plScroll, nil, "♪", p.name)
		b.LayoutOrder = i
		b.Size = UDim2.new(1, -6, 0, 38)
		b.BackgroundColor3 = U.C.elev
		tx.TextColor3 = active and U.C.text or U.C.sub
		ic.TextColor3 = active and U.C.green or U.C.sub
		b.BackgroundTransparency = active and 0 or 1
		sideBtns[i] = { btn = b, active = active }
		b.Activated:Connect(function()
			U.state.last = i
			U.markDirty()
			U.setView({ kind = "pl", index = i })
		end)
		b.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton2 then U.openPlaylistMenu(i) end
		end)
		if #U.state.playlists > 1 then
			tx.Size = UDim2.new(1, -86, 1, 0)
			local del = U.new("TextButton", {
				Text = U.armedDelete == i and "Точно?" or "×", Font = FONT_B, TextSize = 12,
				TextColor3 = U.armedDelete == i and U.C.red or U.C.sub, BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(46, 26), Parent = b,
			})
			del.Activated:Connect(function()
				if U.armedDelete == i then
					U.armedDelete = nil
					U.deletePlaylist(i)
				else
					U.armedDelete = i
					U.renderSidebar()
					task.delay(2.5, function()
						if U.armedDelete == i then
							U.armedDelete = nil
							U.renderSidebar()
						end
					end)
				end
			end)
		end
	end
end

U.suppressSearch = false
function U.setView(v)
	U.view = v
	U.closePopups()
	if v.kind ~= "search" and U.searchBox.Text ~= "" then
		U.suppressSearch = true
		U.searchBox.Text = ""
		U.suppressSearch = false
		U.searchClear.Visible = false
		U.prevView = nil
	end
	U.renderSidebar()
	U.renderBanner()
	U.renderList()
	U.listWrap.GroupTransparency = 1
	U.listWrap.Position = UDim2.fromOffset(12, 218)
	U.tween(U.listWrap, 0.3, { GroupTransparency = 0, Position = UDim2.fromOffset(12, 208) }, Enum.EasingStyle.Quint)
	if v.kind == "top" then U.fetchTop() end
end

function U.fetchTop()
	topState = "loading"
	U.renderList()
	U.renderBanner()
	task.spawn(function()
		local out = {}
		for _, e in ipairs(topEntries(20)) do
			-- название берём из своих плейлистов, иначе спрашиваем у Roblox
			local known
			local function look(list)
				for _, t in ipairs(list) do
					if t.id == e.id and t.title and t.artist then known = t end
				end
			end
			look(U.state.liked)
			for _, p in ipairs(U.state.playlists) do look(p.tracks) end
			local item = { id = e.id, plays = e.plays }
			if known then
				item.title, item.artist = known.title, known.artist
			else
				U.fetchInfo(item)
			end
			out[#out + 1] = item
		end
		topList = out
		topState = "done"
		if U.view.kind == "top" then
			U.renderList()
			U.renderBanner()
		end
	end)
end

------------------------------------------------------------
-- ТЕМА
------------------------------------------------------------
function U.applyTheme(name, instant)
	U.C = U.THEMES[name] or U.THEMES.dark
	U.state.theme = (U.C == U.THEMES.light) and "light" or "dark"
	local alive = {}
	for _, e in ipairs(U.themed) do
		if e[1].Parent then
			alive[#alive + 1] = e
			if instant then
				e[1][e[2]] = U.C[e[3]]
			else
				U.tween(e[1], 0.25, { [e[2]] = U.C[e[3]] })
			end
		end
	end
	U.themed = alive
	U.plScroll.ScrollBarImageColor3 = U.C.elev2
	U.scroll.ScrollBarImageColor3 = U.C.elev2
	for _, b in ipairs(U.bars) do b.BackgroundColor3 = U.C.green end
	U.shuffleBtn.TextColor3 = shuffle and U.C.green or U.C.sub
	U.repeatBtn.TextColor3 = repeatMode > 0 and U.C.green or U.C.sub
	U.themeBtn.Text = U.state.theme == "dark" and "🌞" or "🌙"
	U.setReverb(U.state.reverb, true)
	U.refreshSpeedChips()
	U.closePopups()
	U.renderSidebar()
	U.renderBanner()
	U.renderList()
	U.updateNowPlaying()
	U.markerLen = -1
end

------------------------------------------------------------
-- СОБЫТИЯ UI
------------------------------------------------------------
navLiked.Activated:Connect(function() U.setView({ kind = "liked" }) end)
navTop.Activated:Connect(function() U.setView({ kind = "top" }) end)

U.plAddBtn.Activated:Connect(function()
	U.renameIndex = nil
	U.plNameBox.Text = ""
	U.plNameBox.Visible = not U.plNameBox.Visible
	U.layoutSidebar()
	if U.plNameBox.Visible then U.plNameBox:CaptureFocus() end
end)
U.plNameBox.FocusLost:Connect(function(enter)
	local name = U.plNameBox.Text:match("^%s*(.-)%s*$")
	if enter and name ~= "" then
		if U.renameIndex and U.state.playlists[U.renameIndex] then
			U.state.playlists[U.renameIndex].name = cutText(name, 24)
			U.markDirty()
			U.notify("Переименовано")
			U.renderSidebar()
			if U.view.kind == "pl" and U.view.index == U.renameIndex then U.renderBanner() end
		elseif not U.renameIndex then
			if #U.state.playlists >= MAX_PLAYLISTS then
				U.notify("Максимум плейлистов: " .. MAX_PLAYLISTS)
			else
				table.insert(U.state.playlists, { name = cutText(name, 24), tracks = {} })
				U.state.last = #U.state.playlists
				U.markDirty()
				U.setView({ kind = "pl", index = #U.state.playlists })
				U.notify("Плейлист создан")
			end
		end
	end
	U.renameIndex = nil
	U.plNameBox.Text = ""
	U.plNameBox.Visible = false
	U.layoutSidebar()
end)

U.sortBtn.Activated:Connect(function()
	local idx = table.find(U.SORTS, U.sortMode) or 1
	U.sortMode = U.SORTS[idx % #U.SORTS + 1]
	U.sortBtn.Text = "⇅ " .. U.SORT_NAMES[U.sortMode]
	U.renderList()
	if U.sortMode ~= "manual" then U.notify("Сортировка: " .. U.SORT_NAMES[U.sortMode] .. " (перетаскивание порядка выключено)") end
end)

-- Поиск
U.searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	if U.suppressSearch then return end
	local q = U.searchBox.Text
	U.searchClear.Visible = q ~= ""
	if q == "" then
		if U.view.kind == "search" then
			local v = U.prevView or { kind = "pl", index = U.state.last }
			U.prevView = nil
			U.setView(v)
		end
	else
		if U.view.kind ~= "search" then U.prevView = U.view end
		U.view = { kind = "search" }
		searchQuery = q
		U.renderSidebar()
		U.renderBanner()
		U.renderList()
	end
end)
U.searchClear.Activated:Connect(function() U.searchBox.Text = "" end)

-- Добавление по ID
function U.addTrackFromBox()
	local id = tonumber(U.addBox.Text:match("%d+") or "")
	U.addBox.Text = ""
	if not id or id < 1 or id >= 1e15 then
		U.notify("Введи числовой ID аудио")
		return
	end
	if not (U.view.kind == "pl" or U.view.kind == "liked") then return end
	local list = U.currentList()
	for _, t in ipairs(list) do
		if t.id == id then
			U.notify("Этот трек уже здесь")
			return
		end
	end
	if #list >= MAX_TRACKS then
		U.notify("Список заполнен")
		return
	end
	local track = { id = id }
	table.insert(list, track)
	U.renderList()
	U.renderBanner()
	U.markDirty()
	task.spawn(function()
		U.fetchInfo(track)
		U.refreshTexts()
		U.markDirty()
	end)
	task.defer(function() U.scroll.CanvasPosition = Vector2.new(0, math.huge) end)
end
U.addBtn.Activated:Connect(U.addTrackFromBox)
U.addBox.FocusLost:Connect(function(enter)
	if enter then U.addTrackFromBox() end
end)

U.playBtn.Activated:Connect(U.togglePlay)
U.miniPlay.Activated:Connect(U.togglePlay)
U.bigPlay.Activated:Connect(function()
	local list = U.displayList()
	if sound and current and #list > 0 then
		for _, t in ipairs(list) do
			if t.id == current.id then
				U.togglePlay()
				return
			end
		end
	end
	if #list > 0 then U.playFromList(list, shuffle and math.random(#list) or 1) end
end)
function U.skipNext() failStreak = 0; U.nextTrack(false, false) end
function U.skipPrev() failStreak = 0; U.prevTrack() end
U.nextBtn.Activated:Connect(U.skipNext)
U.miniNext.Activated:Connect(U.skipNext)
U.prevBtn.Activated:Connect(U.skipPrev)
U.miniPrev.Activated:Connect(U.skipPrev)

function U.toggleShuffle()
	shuffle = not shuffle
	U.shuffleBtn.TextColor3 = shuffle and U.C.green or U.C.sub
	U.notify(shuffle and "Перемешивание включено" or "Перемешивание выключено")
end
U.shuffleBtn.Activated:Connect(U.toggleShuffle)
U.repeatBtn.Activated:Connect(function()
	repeatMode = (repeatMode + 1) % 3
	U.repeatBtn.Text = repeatMode == 2 and "🔂" or "🔁"
	U.repeatBtn.TextColor3 = repeatMode > 0 and U.C.green or U.C.sub
	if sound then sound.Looped = (repeatMode == 2) end
end)
U.markBtn.Activated:Connect(function() U.addMarker() end)

U.barHeart.Activated:Connect(function()
	if current then
		U.toggleLike(current)
		U.pop(U.barHeart)
	end
end)

U.closeBtn.Activated:Connect(function() U.setMode("hidden") end)
U.toggleBtn.Activated:Connect(function() U.setMode(uiMode == "hidden" and lastShown or "hidden") end)
U.miniBtn.Activated:Connect(function() U.setMode("mini") end)
U.miniExpand.Activated:Connect(function() U.setMode("full") end)
U.themeBtn.Activated:Connect(function() U.applyTheme(U.state.theme == "dark" and "light" or "dark"); U.markDirty() end)

-- Горячие клавиши
function U.runAction(id)
	if id == "toggle" then
		U.setMode(uiMode == "hidden" and lastShown or "hidden")
	elseif id == "mini" then
		U.setMode(uiMode == "mini" and "full" or "mini")
	elseif id == "play" then
		U.togglePlay()
	elseif id == "next" then
		U.skipNext()
	elseif id == "prev" then
		U.skipPrev()
	elseif id == "volup" then
		U.setVolume(U.state.volume + 0.05)
	elseif id == "voldown" then
		U.setVolume(U.state.volume - 0.05)
	elseif id == "seekf" then
		if sound and sound.TimeLength > 0 then sound.TimePosition = math.min(sound.TimeLength - 0.5, sound.TimePosition + 10) end
	elseif id == "seekb" then
		if sound then sound.TimePosition = math.max(0, sound.TimePosition - 10) end
	elseif id == "like" then
		if current then U.toggleLike(current) end
	elseif id == "shuffle" then
		U.toggleShuffle()
	elseif id == "marker" then
		U.addMarker()
	elseif id == "theme" then
		U.applyTheme(U.state.theme == "dark" and "light" or "dark")
		U.markDirty()
	elseif id == "search" then
		if uiMode ~= "full" then U.setMode("full") end
		task.defer(function()
			U.searchBox:CaptureFocus()
			task.wait()
			U.searchBox.Text = ""
		end)
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if U.listening then
		if input.UserInputType == Enum.UserInputType.Keyboard then
			local id = U.listening
			U.listening = nil
			if input.KeyCode == Enum.KeyCode.Escape then
				-- отмена
			elseif input.KeyCode == Enum.KeyCode.Backspace then
				U.state.binds[id] = "None"
			else
				for _, a in ipairs(U.ACTIONS) do
					if a.id ~= id and U.keyOf(a.id) == input.KeyCode then U.state.binds[a.id] = "None" end
				end
				U.state.binds[id] = input.KeyCode.Name
			end
			U.refreshKeys()
			U.markDirty()
		end
		return
	end
	if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	for _, a in ipairs(U.ACTIONS) do
		if U.keyOf(a.id) == input.KeyCode then
			U.runAction(a.id)
			return
		end
	end
end)

------------------------------------------------------------
-- АНИМАЦИЯ КАЖДЫЙ КАДР
------------------------------------------------------------
U.smooth = 0
RunService.RenderStepped:Connect(function(dt)
	if uiMode == "hidden" then return end

	local playing = sound ~= nil and sound.IsPlaying
	local loud = playing and math.clamp(sound.PlaybackLoudness / 350, 0, 1) or 0
	U.smooth += (loud - U.smooth) * math.min(1, dt * 12)

	-- кроссфейд: запускаем следующий трек за N секунд до конца
	if playing and U.state.crossfade > 0 and repeatMode ~= 2 and xfFired ~= playToken
		and sound.TimeLength > U.state.crossfade * 2
		and sound.TimeLength - sound.TimePosition <= U.state.crossfade then
		xfFired = playToken
		U.nextTrack(true, true)
	end

	if sound and sound.TimeLength ~= U.markerLen then
		U.markerLen = sound.TimeLength
		U.rebuildMarkers()
	end

	if uiMode == "full" then
		local t = os.clock()
		for i, b in ipairs(U.bars) do
			local wob = 0.55 + 0.45 * math.sin(t * (3 + i * 0.37) + i)
			local targetH = 4 + U.smooth * 70 * wob
			local cur = b.Size.Y.Offset
			b.Size = UDim2.fromOffset(6, cur + (targetH - cur) * math.min(1, dt * 18))
		end
		U.bannerCoverScale.Scale = 1 + U.smooth * 0.05
		U.barCoverScale.Scale = 1 + U.smooth * 0.09
		if playing then
			U.barCoverGrad.Rotation = (U.barCoverGrad.Rotation + dt * 40) % 360
			U.bannerCoverGrad.Rotation = (U.bannerCoverGrad.Rotation + dt * 25) % 360
		end
	else
		U.miniCoverScale.Scale = 1 + U.smooth * 0.08
		if playing then U.miniCoverGrad.Rotation = (U.miniCoverGrad.Rotation + dt * 40) % 360 end
	end

	if sound and sound.TimeLength > 0 then
		local a = sound.TimePosition / sound.TimeLength
		if not U.progress.IsDragging() then
			U.progress.Set(a)
			U.curTime.Text = U.formatTime(sound.TimePosition)
		end
		U.totTime.Text = U.formatTime(sound.TimeLength)
		U.miniFill.Size = UDim2.fromScale(math.clamp(a, 0, 1), 1)
	else
		U.progress.Set(0)
		U.curTime.Text = "0:00"
		U.totTime.Text = "0:00"
		U.miniFill.Size = UDim2.fromScale(0, 1)
	end
end)

------------------------------------------------------------
-- НОВОЕ: ОЧЕРЕДЬ, ИСТОРИЯ, РАДИО, ЖАНРЫ, ИМПОРТ / ЭКСПОРТ
------------------------------------------------------------
-- подсказки для авто-определения жанра по названию (нужны только радио)
U.GENRE_HINTS = {
	{ "Phonk", { "phonk", "фонк", "memphis" } },
	{ "Lofi", { "lofi", "lo-fi", "lo fi", "лофи", "лоуфай", "chill" } },
	{ "Anime", { "anime", "аниме", "opening", "naruto", "vocaloid" } },
	{ "Rap", { "rap", "рэп", "рэпер", "hip hop", "hip-hop", "trap", "трэп", "drill" } },
	{ "Rock", { "rock", "рок", "metal", "метал", "punk", "панк" } },
	{ "Pop", { "pop", "поп" } },
}

-- жанр трека: твой тег; если тега нет и explicitOnly не задан — догадка по названию
function U.genreOf(track, explicitOnly)
	local g = U.state.genres[tostring(track.id)]
	if g or explicitOnly then return g end
	local s = U.lowerU((track.title or "") .. " " .. (track.artist or ""))
	for _, rule in ipairs(U.GENRE_HINTS) do
		for _, kw in ipairs(rule[2]) do
			if s:find(kw, 1, true) then return rule[1] end
		end
	end
	return nil
end

function U.artistText(track)
	local g = U.state.genres[tostring(track.id)]
	local a = track.artist or ""
	if g then return a .. (a ~= "" and "  ·  " or "") .. g end
	return a
end

function U.setGenre(track, g)
	U.state.genres[tostring(track.id)] = g
	U.markDirty()
	U.refreshTexts()
	U.notify(g and ("Жанр: " .. g) or "Жанр убран")
end

function U.openGenreMenu(track, at)
	local cur = U.state.genres[tostring(track.id)]
	local items = {}
	for _, g in ipairs(GENRES) do
		items[#items + 1] = { text = (cur == g and "•  " or "    ") .. g, fn = function() U.setGenre(track, g) end }
	end
	if cur then
		items[#items + 1] = { text = "×  Убрать жанр", color = U.C.red, fn = function() U.setGenre(track, nil) end }
	end
	U.openMenu("Жанр: " .. (track.title or "Трек"), items, at)
end

-- очередь: то, что будет играть дальше
function U.queueList()
	local out = {}
	for i = qi + 1, #queue do out[#out + 1] = queue[i] end
	return out
end

-- история прослушиваний (последние 50, новые сверху)
function U.pushHistory(track)
	local h = U.state.history
	if h[1] and h[1].id == track.id then return end
	for i = #h, 1, -1 do
		if h[i].id == track.id then table.remove(h, i) end
	end
	table.insert(h, 1, { id = track.id, title = track.title, artist = track.artist })
	while #h > 50 do table.remove(h) end
	U.markDirty()
	if U.view.kind == "history" then
		U.renderList()
		U.renderBanner()
	end
end

-- радио: когда очередь кончается, добавляем похожие треки из твоей библиотеки
function U.radioFill()
	local seen, pool = {}, {}
	for _, t in ipairs(queue) do seen[t.id] = true end
	local function scan(list)
		for _, t in ipairs(list) do
			if not seen[t.id] and not U.badIds[t.id] then
				seen[t.id] = true
				pool[#pool + 1] = t
			end
		end
	end
	scan(U.state.liked)
	for _, p in ipairs(U.state.playlists) do scan(p.tracks) end
	scan(U.state.history)
	scan(topList)

	local g = current and U.genreOf(current)
	local same, rest = {}, {}
	for _, t in ipairs(pool) do
		if g and U.genreOf(t) == g then
			same[#same + 1] = t
		else
			rest[#rest + 1] = t
		end
	end
	local function mix(a)
		for i = #a, 2, -1 do
			local j = math.random(i)
			a[i], a[j] = a[j], a[i]
		end
	end
	mix(same)
	mix(rest)

	local picks = {}
	for i = 1, math.min(10, #same) do picks[#picks + 1] = same[i] end
	local note
	if #picks == 0 then
		for i = 1, math.min(5, #rest) do picks[#picks + 1] = rest[i] end
		if #picks > 0 then
			note = g and ("📻 Нет других треков жанра " .. g .. ", беру случайные") or "📻 Жанр не определён, беру случайные"
		end
	else
		note = "📻 Радио: +" .. #picks .. " · " .. g
	end
	if #picks == 0 then
		U.notify("📻 Радио: в библиотеке нет новых треков")
		return false
	end
	for _, t in ipairs(picks) do queue[#queue + 1] = t end
	U.notify(note)
	return true
end

function U.refreshRadio()
	local on = U.state.radio == true
	U.radioBtn.BackgroundColor3 = U.C.green
	U.radioBtn.BackgroundTransparency = on and 0.25 or 1
	if U.view.kind == "queue" then U.renderBanner() end
end

function U.toggleRadio()
	U.state.radio = not U.state.radio
	U.refreshRadio()
	U.markDirty()
	U.notify(U.state.radio and "📻 Радио включено: когда очередь кончится, добавлю похожее по жанру" or "📻 Радио выключено")
end

-- буфер обмена (в инжекторе обычно есть setclipboard)
function U.copyText(text, okMsg)
	local fn = setclipboard or toclipboard or set_clipboard
	if type(fn) ~= "function" and type(Clipboard) == "table" then fn = Clipboard.set end
	if type(fn) == "function" then
		local ok = pcall(fn, text)
		if ok then
			U.notify(okMsg or "Скопировано")
			return true
		end
	end
	return false
end

function U.copyId(track)
	if not U.copyText(tostring(track.id), "ID скопирован: " .. track.id) then
		U.notify("ID аудио: " .. track.id)
	end
end

-- попап с текстом (импорт и экспорт)
function U.openTextPopup(title, hint, text, okText, onOk)
	U.closePopups()
	U.textTitle.Text = title
	U.textHint.Text = hint
	U.textBox.Text = text or ""
	U.textOk.Text = okText
	U.textOkFn = onOk
	U.showPopup(U.textPopup)
	U.blocker.Visible = true
end
U.textOk.Activated:Connect(function()
	local fn, txt = U.textOkFn, U.textBox.Text
	U.closePopups()
	if fn then fn(txt) end
end)
U.textCancel.Activated:Connect(U.closePopups)

-- какой список сейчас открыт: имя, треки, можно ли в него импортировать
function U.viewTracks()
	if U.view.kind == "pl" then
		local p = U.state.playlists[U.view.index]
		return p.name, p.tracks, true
	elseif U.view.kind == "liked" then
		return "Любимое", U.state.liked, true
	elseif U.view.kind == "queue" then
		return "Очередь", U.queueList(), false
	elseif U.view.kind == "history" then
		return "История", U.state.history, false
	end
end

function U.exportJson(name, tracks)
	local arr = {}
	for _, t in ipairs(tracks) do
		arr[#arr + 1] = { id = t.id, title = t.title, artist = t.artist, genre = U.state.genres[tostring(t.id)] }
	end
	return HttpService:JSONEncode({ app = "SpotifyPlayer", name = name, tracks = arr })
end

function U.exportIds(tracks)
	local ids = {}
	for _, t in ipairs(tracks) do ids[#ids + 1] = tostring(t.id) end
	return table.concat(ids, ", ")
end

function U.openExportMenu(name, tracks, at)
	if #tracks == 0 then
		U.notify("Список пуст — нечего экспортировать")
		return
	end
	local function deliver(text, what)
		if not U.copyText(text, what .. " скопирован в буфер") then
			-- буфера нет: показываем текст, его можно выделить и скопировать вручную
			U.openTextPopup("Экспорт: " .. name, "В этом инжекторе нет буфера обмена. Выдели текст и скопируй вручную.", text, "Закрыть", nil)
		end
	end
	U.openMenu("Экспорт: " .. name, {
		{ text = "📋  Копировать JSON", fn = function() deliver(U.exportJson(name, tracks), "JSON") end },
		{ text = "🔢  Копировать ID через запятую", fn = function() deliver(U.exportIds(tracks), "Список ID") end },
		{
			text = "💾  Сохранить в файл",
			fn = function()
				if not HAS_FS then
					U.notify("В этом инжекторе нет writefile")
					return
				end
				local safe = name:gsub("[^%w]+", "_")
				if safe == "" or safe:match("^_+$") then safe = "playlist" end
				local file = "SpotifyPlayer_export_" .. safe .. ".json"
				local ok = pcall(writefile, file, U.exportJson(name, tracks))
				U.notify(ok and ("Сохранено: " .. file) or "Не удалось сохранить файл")
			end,
		},
	}, at)
end

-- импорт: JSON из экспорта или просто ID через запятую / пробел / с новой строки
function U.importText(text)
	do
		local t0 = tostring(text):match("^%s*(.-)%s*$")
		if t0:sub(1, 1) == "{" then
			local okJ, dj = pcall(function() return HttpService:JSONDecode(t0) end)
			if okJ and type(dj) == "table" then
				if type(dj.data) == "table" then dj = dj.data end
				if type(dj.playlists) == "table" then
					U.importLibrary(dj, false)
					return
				end
			end
		end
	end
	local name, list, canAdd = U.viewTracks()
	if not (list and canAdd) then
		U.notify("Импорт работает в плейлистах и в «Любимом»")
		return
	end
	local trimmed = tostring(text):match("^%s*(.-)%s*$")
	local items = {}
	if trimmed:sub(1, 1) == "{" then
		local ok, data = pcall(function() return HttpService:JSONDecode(trimmed) end)
		if ok and type(data) == "table" and type(data.tracks) == "table" then
			for _, t in ipairs(data.tracks) do
				if type(t) == "table" then
					items[#items + 1] = {
						id = tonumber(t.id),
						title = type(t.title) == "string" and cutText(t.title, 60) or nil,
						artist = type(t.artist) == "string" and cutText(t.artist, 40) or nil,
						genre = t.genre,
					}
				end
			end
		end
	end
	if #items == 0 then
		for num in trimmed:gmatch("%d+") do
			if #num >= 5 and #num <= 15 then items[#items + 1] = { id = tonumber(num) } end
		end
	end
	if #items == 0 then
		U.notify("Не нашёл ID. Вставь числа через запятую")
		return
	end

	local have = {}
	for _, t in ipairs(list) do have[t.id] = true end
	local added, dup, full = 0, 0, 0
	for _, it in ipairs(items) do
		if not validId(it.id) then
			dup += 1
		elseif have[it.id] then
			dup += 1
		elseif #list >= MAX_TRACKS then
			full += 1
		else
			have[it.id] = true
			table.insert(list, { id = it.id, title = it.title, artist = it.artist })
			if type(it.genre) == "string" then
				for _, g in ipairs(GENRES) do
					if g == it.genre then U.state.genres[tostring(it.id)] = g end
				end
			end
			added += 1
		end
	end
	local msg = "Импортировано: " .. added
	if dup > 0 then msg ..= " · пропущено: " .. dup end
	if full > 0 then msg ..= " · не влезло: " .. full end
	U.notify(msg)
	U.markDirty()
	U.renderList()
	U.renderBanner()
	if added > 0 then U.hydrateTitles() end
end

function U.openImport()
	local name, _, canAdd = U.viewTracks()
	if not canAdd then
		U.notify("Открой плейлист или «Любимое», чтобы импортировать")
		return
	end
	U.openTextPopup(
		"Импорт в «" .. name .. "»",
		"Вставь ID аудио через запятую, пробел или с новой строки. Подойдёт и JSON из экспорта.",
		"", "Импортировать", U.importText
	)
end

-- меню «•••» над списком
function U.openViewMenu()
	local at = U.menuBtn.AbsolutePosition + Vector2.new(0, U.menuBtn.AbsoluteSize.Y + 4)
	local k = U.view.kind
	if k == "pl" then
		U.openPlaylistMenu(U.view.index, at)
		return
	end
	local name, tracks = U.viewTracks()
	if not tracks then return end
	local items = {}
	if k == "liked" then
		items[#items + 1] = {
			text = "▶  Играть",
			fn = function()
				if #tracks > 0 then U.playFromList(tracks, 1) end
			end,
		}
		items[#items + 1] = { text = "📥  Импорт ID…", fn = function() U.openImport() end }
	elseif k == "queue" then
		items[#items + 1] = {
			text = U.state.radio and "📻  Выключить радио" or "📻  Включить радио",
			fn = function() U.toggleRadio() end,
		}
		items[#items + 1] = {
			text = "×  Очистить очередь", color = U.C.red,
			fn = function()
				for j = #queue, qi + 1, -1 do table.remove(queue, j) end
				U.renderList()
				U.renderBanner()
				U.notify("Очередь очищена")
			end,
		}
	elseif k == "history" then
		items[#items + 1] = {
			text = "×  Очистить историю", color = U.C.red,
			fn = function()
				U.state.history = {}
				U.markDirty()
				U.renderList()
				U.renderBanner()
				U.notify("История очищена")
			end,
		}
	end
	items[#items + 1] = { text = "📤  Экспорт…", fn = function() U.openExportMenu(name, tracks, at) end }
	U.openMenu(name, items, at)
end

U.menuBtn.Activated:Connect(U.openViewMenu)
U.radioBtn.Activated:Connect(U.toggleRadio)
U.navQueue.Activated:Connect(function() U.setView({ kind = "queue" }) end)
U.navHistory.Activated:Connect(function() U.setView({ kind = "history" }) end)
U.refreshRadio()

------------------------------------------------------------
-- НОВОЕ: БИБЛИОТЕКА (JSON), РЕЗЕРВНЫЕ КОПИИ, СИНХРОНИЗАЦИЯ
------------------------------------------------------------
U.IMPORT_FILE = "SpotifyPlayer_import.json"

-- полный снимок: плейлисты, любимое, жанры, история, настройки
function U.snapshot()
	return sanitize(U.stateData())
end

function U.libraryJson()
	local ok, raw = pcall(function()
		return HttpService:JSONEncode({ app = "SpotifyPlayer", kind = "library", exported = os.time(), data = U.snapshot() })
	end)
	return ok and raw or nil
end

-- отдать текст: в буфер; нет буфера — в файл; нет файла — в окно
function U.deliverText(text, what, title)
	if U.copyText(text, what .. " скопирован в буфер") then return end
	if HAS_FS and #text > 30000 then
		local file = "SpotifyPlayer_export.json"
		if pcall(writefile, file, text) then
			U.notify("Нет буфера обмена. Сохранено в файл " .. file)
			return
		end
	end
	if #text > 30000 then
		U.notify("Слишком большой текст, а буфера и файлов нет")
		return
	end
	U.openTextPopup(title, "В этом инжекторе нет буфера обмена. Выдели текст и скопируй вручную.", text, "Закрыть", nil)
end

function U.exportLibrary(at)
	local raw = U.libraryJson()
	if not raw then
		U.notify("Не удалось собрать экспорт")
		return
	end
	local d = U.snapshot()
	local tracks = #d.liked
	for _, p in ipairs(d.playlists) do tracks += #p.tracks end
	U.openMenu("Экспорт: " .. #d.playlists .. " плейл., " .. tracks .. " треков", {
		{ text = "📋  Копировать JSON", fn = function() U.deliverText(raw, "JSON библиотеки", "Экспорт библиотеки") end },
		{
			text = "💾  Сохранить в файл",
			fn = function()
				if not HAS_FS then
					U.notify("В этом инжекторе нет writefile")
					return
				end
				local file = "SpotifyPlayer_library_" .. localPlayer.UserId .. ".json"
				local ok = pcall(writefile, file, raw)
				U.notify(ok and ("Сохранено: " .. file) or "Не удалось сохранить файл")
			end,
		},
	}, at)
end

-- сливаем / заменяем. d — уже распарсенный JSON
function U.importLibrary(d, replace)
	if type(d.tracks) == "table" and type(d.playlists) ~= "table" then
		-- JSON одного плейлиста из «Экспорт…» → отдельный плейлист
		d = { playlists = { { name = type(d.name) == "string" and d.name or "Импорт", tracks = d.tracks } } }
	end
	if type(d.playlists) ~= "table" or #d.playlists == 0 then
		U.notify("Это не код библиотеки: нет плейлистов")
		return false
	end
	local clean = sanitize(d)
	if not clean then
		U.notify("Не удалось прочитать данные")
		return false
	end
	-- страховка: текущее состояние уходит в резервную копию
	backupMake(U.snapshot(), true)

	if replace then
		U.applyData(clean)
		U.state.history = clean.history
		U.state.genres = clean.genres
		U.setView({ kind = "pl", index = U.state.last })
		U.hydrateTitles()
		U.pushSave()
		U.notify("Библиотека заменена. Старая версия — в резервных копиях")
		return true
	end

	local addedPl, addedTr, merged = 0, 0, 0
	for _, p in ipairs(clean.playlists) do
		local target
		for _, mine in ipairs(U.state.playlists) do
			if mine.name == p.name then target = mine break end
		end
		if not target then
			if #U.state.playlists >= MAX_PLAYLISTS then
				continue
			end
			target = { name = p.name, tracks = {} }
			table.insert(U.state.playlists, target)
			addedPl += 1
		else
			merged += 1
		end
		local have = {}
		for _, t in ipairs(target.tracks) do have[t.id] = true end
		for _, t in ipairs(p.tracks) do
			if not have[t.id] and #target.tracks < MAX_TRACKS then
				have[t.id] = true
				table.insert(target.tracks, { id = t.id, title = t.title, artist = t.artist })
				addedTr += 1
			end
		end
	end
	local have = {}
	for _, t in ipairs(U.state.liked) do have[t.id] = true end
	for _, t in ipairs(clean.liked) do
		if not have[t.id] and #U.state.liked < MAX_TRACKS then
			have[t.id] = true
			table.insert(U.state.liked, { id = t.id, title = t.title, artist = t.artist })
			addedTr += 1
		end
	end
	for k, g in pairs(clean.genres) do
		if not U.state.genres[k] then U.state.genres[k] = g end
	end

	U.setView(U.view)
	U.renderSidebar()
	U.markDirty()
	if addedTr > 0 then U.hydrateTitles() end
	if addedPl == 0 and addedTr == 0 then
		U.notify("Ничего нового: всё уже есть в библиотеке")
	else
		U.notify("Добавлено: плейлистов " .. addedPl .. ", треков " .. addedTr .. (merged > 0 and (" (слито с " .. merged .. " существующими)") or ""))
	end
	return true
end

function U.importLibraryText(text, replace)
	local trimmed = tostring(text):match("^%s*(.-)%s*$")
	local ok, data = pcall(function() return HttpService:JSONDecode(trimmed) end)
	if not ok or type(data) ~= "table" then
		U.notify("Это не JSON. Вставь код целиком, от { до }")
		return false
	end
	if type(data.data) == "table" then data = data.data end
	return U.importLibrary(data, replace)
end

function U.openLibraryImport()
	U.openTextPopup(
		"Импорт библиотеки",
		"Вставь JSON из «Экспорт библиотеки» (или одного плейлиста). Плейлисты с тем же названием сольются, новые добавятся.",
		"", "Добавить", function(t) U.importLibraryText(t, false) end
	)
end

function U.importFromFile()
	if not HAS_FS then
		U.notify("В этом инжекторе нет readfile")
		return
	end
	local okE, exists = pcall(isfile, U.IMPORT_FILE)
	if not (okE and exists) then
		U.notify("Положи файл " .. U.IMPORT_FILE .. " в папку workspace инжектора")
		return
	end
	local okR, raw = pcall(readfile, U.IMPORT_FILE)
	if not okR or type(raw) ~= "string" then
		U.notify("Не удалось прочитать файл")
		return
	end
	U.importLibraryText(raw, false)
end

------------------------------------------------------------
-- РЕЗЕРВНЫЕ КОПИИ (последние 3)
------------------------------------------------------------
function U.fmtTime(ts)
	local ok, s = pcall(os.date, "%d.%m %H:%M", ts)
	return ok and s or "?"
end

function U.restoreBackup(i)
	local d = backupRead(i)
	if not d then
		U.notify("Копия не читается")
		return
	end
	U.importLibrary(d, true)
end

function U.openBackupMenu(at)
	local list = backupList()
	local items = {}
	for _, b in ipairs(list) do
		items[#items + 1] = {
			text = "🗄  " .. b.idx .. " · " .. U.fmtTime(b.ts) .. " · " .. b.tracks .. " тр.",
			fn = function()
				U.openMenu("Восстановить копию " .. b.idx .. "?", {
					{ text = "Да, заменить текущую", color = U.C.red, fn = function() U.restoreBackup(b.idx) end },
					{ text = "Отмена", fn = function() end },
				}, at)
			end,
		}
	end
	items[#items + 1] = {
		text = "➕  Создать копию сейчас",
		fn = function()
			if backupMake(U.snapshot(), true) then
				U.notify("Копия создана")
			else
				U.notify("Копия не нужна: ничего не менялось")
			end
		end,
	}
	local title = #list == 0 and "Копий пока нет" or ("Резервные копии (" .. #list .. "/3)")
	U.openMenu(title, items, at)
end

------------------------------------------------------------
-- СИНХРОНИЗАЦИЯ
------------------------------------------------------------
-- Roblox не даёт клиенту писать в общее хранилище между серверами (DataStore
-- и MessagingService доступны только серверу игры). Поэтому:
--  • между серверами на одном устройстве: файл сохранения общий, он грузится
--    при каждом запуске скрипта;
--  • между устройствами: код синхронизации (копировать / вставить).
function U.pullFromFile()
	if not HAS_FS then
		U.notify("В этом инжекторе нет файлов — синхронизировать нечего")
		return
	end
	local ok, success, data = pcall(storageLoad)
	if not (ok and success and data) then
		U.notify("Файл сохранения не найден или пуст")
		return
	end
	U.importLibrary(data, false)
end

function U.openSyncMenu(at)
	U.openMenu("Синхронизация", {
		{ text = "🔄  Подтянуть из файла", fn = function() U.pullFromFile() end },
		{
			text = "📱  Код для другого устройства",
			fn = function()
				local raw = U.libraryJson()
				if raw then U.deliverText(raw, "Код синхронизации", "Код синхронизации") end
			end,
		},
		{
			text = "📲  Вставить код (заменить всё)",
			fn = function()
				U.openTextPopup(
					"Вставить код синхронизации",
					"Текущая библиотека будет ЗАМЕНЕНА. Её копия сохранится в резервных копиях.",
					"", "Заменить", function(t) U.importLibraryText(t, true) end
				)
			end,
		},
		{
			text = "ℹ  Как это работает",
			fn = function()
				U.notify("Сохранение лежит в файле " .. U.SAVE_FILE .. " — он общий для всех серверов на этом устройстве")
			end,
		},
	}, at)
end

function U.openDataMenu()
	local at = U.pointer()
	U.openMenu("Данные", {
		{ text = "📤  Экспорт библиотеки…", fn = function() U.exportLibrary(at) end },
		{ text = "📥  Импорт библиотеки…", fn = function() U.openLibraryImport() end },
		{ text = "📂  Импорт из файла", fn = function() U.importFromFile() end },
		{ text = "🔄  Синхронизация…", fn = function() U.openSyncMenu(at) end },
		{ text = "🗄  Резервные копии…", fn = function() U.openBackupMenu(at) end },
	}, at)
end
U.dataBtn.Activated:Connect(U.openDataMenu)

------------------------------------------------------------
-- ЗАГРУЗКА СОХРАНЕНИЯ
------------------------------------------------------------
function U.applyData(d)
	if type(d.playlists) == "table" and #d.playlists > 0 then U.state.playlists = d.playlists end
	if type(d.liked) == "table" then U.state.liked = d.liked end
	U.state.volume = tonumber(d.volume) or U.state.volume
	U.state.bass = tonumber(d.bass) or U.state.bass
	U.state.reverb = d.reverb == true
	U.state.last = tonumber(d.last) or 1
	U.state.crossfade = tonumber(d.crossfade) or 0
	if type(d.binds) == "table" then U.state.binds = d.binds end
	if type(d.markers) == "table" then U.state.markers = d.markers end
	if type(d.history) == "table" then U.state.history = d.history end
	if type(d.genres) == "table" then U.state.genres = d.genres end
	U.state.radio = d.radio == true
	U.refreshRadio()
	if not U.state.playlists[U.state.last] then U.state.last = 1 end
	U.view = { kind = "pl", index = U.state.last }

	volume.Set(U.state.volume)
	U.bassSlider.Set(U.state.bass)
	U.bassVal.Text = math.floor(U.state.bass * 100 + 0.5) .. "%"
	U.setCrossfade(U.state.crossfade)
	U.applyAudio()
	U.applyTheme(d.theme == "light" and "light" or "dark", true)
end

task.spawn(function()
	local ok, success, data, flag = pcall(storageLoad)
	if ok and success then
		if data then U.applyData(data) end
		loaded = true
		if not HAS_FS then
			U.notify("Твой инжектор без writefile: сохранение только до выхода из игры")
		end
		U.renderSidebar()
		U.renderBanner()
		U.renderList()
		U.hydrateTitles()
		if flag == "restored" then
			U.notify("Файл сохранения был повреждён — восстановил из резервной копии")
			U.markDirty()
		elseif flag == "corrupt" then
			U.notify("Файл сохранения повреждён, копий нет. Старый файл: _corrupt.json")
			U.markDirty()
		elseif data then
			U.notify("Плейлисты загружены")
		else
			U.markDirty() -- первый запуск: сохраняем стартовый плейлист
		end
	else
		U.notify("Не удалось загрузить сохранение")
	end
end)

------------------------------------------------------------
-- СТАРТ
------------------------------------------------------------
U.setReverb(U.state.reverb, true)
U.bassVal.Text = math.floor(U.state.bass * 100 + 0.5) .. "%"
U.setCrossfade(U.state.crossfade)
U.refreshSpeedChips()
U.themeBtn.Text = "🌞"
U.renderSidebar()
U.renderBanner()
U.renderList()
U.setMode("full")
U.hydrateTitles()

------------------------------------------------------------
-- ВЫГРУЗКА (повторный запуск скрипта заменяет плеер)
------------------------------------------------------------
genv.__SpotifyPlayerUnload = function()
	genv.__SpotifyPlayerUnload = nil
	playToken += 1
	pcall(U.pushSave)
	pcall(flushPlayCounts)
	for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
	if sound then pcall(function() sound:Destroy() end) end
	pcall(function() U.group:Destroy() end)
	pcall(function() U.gui:Destroy() end)
end


