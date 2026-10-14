--[[
	SPOTIFY-ПЛЕЕР — СЕРВЕРНАЯ ЧАСТЬ
	Тип: Script (обычный Script, НЕ LocalScript)
	Куда: ServerScriptService

	Делает:
	  • автосохранение плейлистов, любимого, громкости и настроек звука (DataStore)
	  • общий топ-чарт самых прослушиваемых треков (OrderedDataStore)

	Для теста в Studio включи:
	  Game Settings > Security > "Enable Studio Access to API Services"
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")

local STORE_NAME = "SpotifyPlayer_v1"
local TOP_NAME = "SpotifyPlayer_TopPlays_v1"
local MAX_PLAYLISTS = 20
local MAX_TRACKS = 300

local store = DataStoreService:GetDataStore(STORE_NAME)
local topStore = DataStoreService:GetOrderedDataStore(TOP_NAME)

------------------------------------------------------------
-- Remotes
------------------------------------------------------------
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

------------------------------------------------------------
-- Проверка данных от клиента
------------------------------------------------------------
local function cleanText(v, max)
	if type(v) ~= "string" then return nil end
	v = v:gsub("%c", "")
	if not utf8.len(v) then return nil end
	local cut = utf8.offset(v, max + 1)
	if cut then v = v:sub(1, cut - 1) end
	if v == "" then return nil end
	return v
end

local function cleanTracks(list)
	local out = {}
	if type(list) ~= "table" then return out end
	for _, t in ipairs(list) do
		if #out >= MAX_TRACKS then break end
		if type(t) == "table" then
			local id = tonumber(t.id)
			if id and id >= 1 and id % 1 == 0 and id < 2 ^ 50 then
				out[#out + 1] = {
					id = id,
					title = cleanText(t.title, 60),
					artist = cleanText(t.artist, 40),
				}
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

local function sanitize(d)
	if type(d) ~= "table" then return nil end
	local out = { playlists = {}, liked = {}, volume = 0.5, bass = 0, reverb = false, last = 1 }

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
	return out
end

------------------------------------------------------------
-- Загрузка / сохранение
------------------------------------------------------------
local loadedOk = {}   -- [player] = true, если данные успешно загружены
local pending = {}    -- [player] = данные, которые ждут записи
local lastRecv = {}   -- защита от спама

local function keyFor(plr)
	return "u_" .. plr.UserId
end

remLoad.OnServerInvoke = function(plr)
	local success, data
	for _ = 1, 3 do
		success, data = pcall(function()
			return store:GetAsync(keyFor(plr))
		end)
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
	-- не перезаписываем сохранение, пока оно не загрузилось
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
	local ok, err = pcall(function()
		store:SetAsync(keyFor(plr), data)
	end)
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

Players.PlayerRemoving:Connect(function(plr)
	flush(plr)
	pending[plr] = nil
	loadedOk[plr] = nil
	lastRecv[plr] = nil
end)

------------------------------------------------------------
-- Топ чарт
------------------------------------------------------------
local pendingPlays = {}  -- [id] = сколько прослушиваний ждёт записи
local lastAny = {}       -- [player] = время последнего засчитанного прослушивания
local lastById = {}      -- [player] = { [id] = время }

remPlayed.OnServerEvent:Connect(function(plr, id)
	id = tonumber(id)
	if not id or id < 1 or id % 1 ~= 0 or id >= 2 ^ 50 then return end

	local now = os.clock()
	if lastAny[plr] and now - lastAny[plr] < 3 then return end
	local byId = lastById[plr]
	if not byId then
		byId = {}
		lastById[plr] = byId
	end
	if byId[id] and now - byId[id] < 90 then return end -- один трек не чаще раза в 90 сек

	lastAny[plr] = now
	byId[id] = now
	pendingPlays[id] = (pendingPlays[id] or 0) + 1
end)

Players.PlayerRemoving:Connect(function(plr)
	lastAny[plr] = nil
	lastById[plr] = nil
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
		local ok = pcall(function()
			topStore:IncrementAsync(tostring(id), count)
		end)
		if not ok then
			pendingPlays[id] = (pendingPlays[id] or 0) + count
		end
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
		topAt = os.clock() - 50 -- повторим через ~10 секунд
	end
	return topCache
end

game:BindToClose(function()
	for _, plr in ipairs(Players:GetPlayers()) do
		flush(plr)
	end
	flushTop()
end)
