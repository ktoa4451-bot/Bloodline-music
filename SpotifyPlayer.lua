--[[
	SPOTIFY-ПЛЕЕР v4 — ВСЁ В ОДНОМ СКРИПТЕ

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
	local remBackups = makeRemote("RemoteFunction", "Backups")
	local remSync = makeRemote("RemoteEvent", "Sync")
	local remNow = makeRemote("RemoteEvent", "NowPlaying")
	local remNowFeed = makeRemote("RemoteEvent", "NowFeed")
	local remRadio = makeRemote("RemoteEvent", "RadioAction")
	local remRadioState = makeRemote("RemoteEvent", "RadioState")
	local remPublic = makeRemote("RemoteFunction", "Public")
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

	local function validCode6(c)
		if type(c) == "string" and #c == 6 and not c:find("[^A-Z0-9]") then return c end
		return nil
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
			theme = "dark", crossfade = 0, binds = {}, markers = {}, shareNow = true,
		}
		if type(d.playlists) == "table" then
			for _, p in ipairs(d.playlists) do
				if #out.playlists >= MAX_PLAYLISTS then break end
				if type(p) == "table" then
					out.playlists[#out.playlists + 1] = {
						name = cleanText(p.name, 24) or "Плейлист",
						tracks = cleanTracks(p.tracks),
						code = validCode6(p.code),
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
		out.shareNow = d.shareNow ~= false
		out.crossfade = math.floor(num(d.crossfade, 0, 12, 0))
		out.binds = cleanBinds(d.binds)
		out.markers = cleanMarkers(d.markers)
		return out
	end

	-- Загрузка / сохранение ------------------------------------------
	local loadedOk, pending, lastRecv, lastSaved = {}, {}, {}, {}
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
			local clean = sanitize(data)
			lastSaved[plr] = clean
			return { ok = true, data = clean }
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

	-- Резервные копии (3 последние) и синхронизация между серверами -----
	local MessagingService = game:GetService("MessagingService")
	local backupStore = DataStoreService:GetDataStore("SpotifyPlayer_Backups_v1")
	local SYNC_TOPIC = "SpotifyPlayerSync_v1"
	local lastBackupAt = {}

	local function maybeBackup(plr, force)
		local prev = lastSaved[plr]
		if not prev then return end
		local now = os.time()
		if not force and lastBackupAt[plr] and now - lastBackupAt[plr] < 900 then return end
		lastBackupAt[plr] = now
		pcall(function()
			backupStore:UpdateAsync("b_" .. plr.UserId, function(old)
				old = type(old) == "table" and old or {}
				table.insert(old, 1, { t = now, data = prev })
				while #old > 3 do table.remove(old) end
				return old
			end)
		end)
	end

	local function publishSync(plr)
		task.spawn(function()
			pcall(function()
				MessagingService:PublishAsync(SYNC_TOPIC, { uid = plr.UserId, job = game.JobId })
			end)
		end)
	end

	local function flush(plr)
		local data = pending[plr]
		if not data or not loadedOk[plr] then return end
		pending[plr] = nil
		maybeBackup(plr, false) -- сохраняем прошлую версию как бэкап
		local ok, err = pcall(function() store:SetAsync(keyFor(plr), data) end)
		if ok then
			lastSaved[plr] = data
			publishSync(plr)
		else
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

	------------------------------------------------------------------
	-- v4: ЛЕНТА «ЧТО СЛУШАЮТ», РАДИО/DJ/VOTE SKIP, ПУБЛИЧНЫЕ ПЛЕЙЛИСТЫ, БЭКАПЫ
	------------------------------------------------------------------
	local SoundService = game:GetService("SoundService")
	local TextService = game:GetService("TextService")

	-- Резервные копии: список и восстановление ----------------------
	local restoreAt = {}
	remBackups.OnServerInvoke = function(plr, action, arg)
		if not loadedOk[plr] then return { ok = false } end
		local key = "b_" .. plr.UserId
		if action == "list" then
			local ok, list = pcall(function() return backupStore:GetAsync(key) end)
			if not ok then return { ok = false } end
			local out = {}
			if type(list) == "table" then
				for i, b in ipairs(list) do
					local d = type(b) == "table" and b.data
					if type(d) == "table" then
						local tracks = 0
						for _, p in ipairs(d.playlists or {}) do tracks += #(p.tracks or {}) end
						out[#out + 1] = {
							i = i, t = b.t, playlists = #(d.playlists or {}), tracks = tracks, liked = #(d.liked or {}),
						}
					end
				end
			end
			return { ok = true, list = out }
		elseif action == "restore" then
			local now = os.clock()
			if restoreAt[plr] and now - restoreAt[plr] < 10 then return { ok = false, err = "cooldown" } end
			restoreAt[plr] = now
			local idx = tonumber(arg)
			local ok, list = pcall(function() return backupStore:GetAsync(key) end)
			if not ok or type(list) ~= "table" or not idx or type(list[idx]) ~= "table" then return { ok = false } end
			local snap = sanitize(list[idx].data)
			if not snap then return { ok = false } end
			maybeBackup(plr, true) -- перед откатом сохраняем текущую версию
			pending[plr] = nil
			local wrote = pcall(function() store:SetAsync(keyFor(plr), snap) end)
			if not wrote then return { ok = false } end
			lastSaved[plr] = snap
			publishSync(plr)
			return { ok = true, data = snap }
		end
		return { ok = false }
	end

	-- Синхронизация между серверами (MessagingService) ---------------
	pcall(function()
		MessagingService:SubscribeAsync(SYNC_TOPIC, function(msg)
			local d = msg.Data
			if type(d) ~= "table" or d.job == game.JobId then return end
			local plr = Players:GetPlayerByUserId(tonumber(d.uid) or 0)
			-- если у игрока здесь есть несохранённые изменения — не затираем их
			if not plr or not loadedOk[plr] or pending[plr] then return end
			task.spawn(function()
				local ok, data = pcall(function() return store:GetAsync(keyFor(plr)) end)
				local clean = ok and sanitize(data)
				if clean and plr.Parent then
					lastSaved[plr] = clean
					remSync:FireClient(plr, clean)
				end
			end)
		end)
	end)

	-- Лента «что слушают игроки на сервере» ---------------------------
	local nowPlaying, nowDirty, nowLast = {}, false, {}
	local function nowSnapshot()
		local list = {}
		for plr, n in pairs(nowPlaying) do
			if plr.Parent then
				list[#list + 1] = { uid = plr.UserId, name = plr.DisplayName, id = n.id, title = n.title, artist = n.artist }
			end
		end
		table.sort(list, function(a, b) return a.name < b.name end)
		return list
	end

	remNow.OnServerEvent:Connect(function(plr, id)
		if id == "sync" then
			remNowFeed:FireClient(plr, nowSnapshot())
			return
		end
		local now = os.clock()
		if nowLast[plr] and now - nowLast[plr] < 1.5 then return end
		nowLast[plr] = now
		id = tonumber(id)
		if not id then
			if nowPlaying[plr] then
				nowPlaying[plr] = nil
				nowDirty = true
			end
			return
		end
		if not validId(id) then return end
		task.spawn(function()
			local m = getMeta(id) -- название берём на сервере: подделать нельзя
			if m and plr.Parent then
				nowPlaying[plr] = { id = id, title = m.title, artist = m.artist }
				nowDirty = true
			end
		end)
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			if nowDirty then
				nowDirty = false
				remNowFeed:FireAllClients(nowSnapshot())
			end
		end
	end)

	-- Радио: DJ-режим + голосование за пропуск ------------------------
	local radio = {
		dj = nil, queue = {}, idx = 0, startedAt = 0, duration = 0,
		paused = false, pausedAt = 0, votes = {}, listeners = {}, token = 0, loading = false,
	}

	local function listenerCount()
		local n = 0
		for plr in pairs(radio.listeners) do
			if plr.Parent then n += 1 end
		end
		return n
	end
	local function neededVotes()
		return math.max(1, math.floor(listenerCount() / 2) + 1)
	end
	local function voteCount()
		local n = 0
		for plr in pairs(radio.votes) do
			if radio.listeners[plr] and plr.Parent then n += 1 end
		end
		return n
	end

	local function radioPayload()
		local t = radio.queue[radio.idx]
		local upcoming = {}
		for i = radio.idx + 1, math.min(#radio.queue, radio.idx + 20) do
			local q = radio.queue[i]
			upcoming[#upcoming + 1] = { id = q.id, title = q.title, artist = q.artist }
		end
		return {
			dj = radio.dj and { uid = radio.dj.UserId, name = radio.dj.DisplayName } or nil,
			track = t and { id = t.id, title = t.title, artist = t.artist } or nil,
			startedAt = radio.startedAt, duration = radio.duration, paused = radio.paused,
			pos = radio.paused and (radio.pausedAt - radio.startedAt) or nil,
			upcoming = upcoming, listeners = listenerCount(), votes = voteCount(), needed = neededVotes(),
		}
	end

	local function pushRadio(target)
		local p = radioPayload()
		if target then
			remRadioState:FireClient(target, p)
		else
			for plr in pairs(radio.listeners) do
				if plr.Parent then remRadioState:FireClient(plr, p) end
			end
		end
	end

	local function fillMeta(q)
		if q.title then return end
		local m = getMeta(q.id)
		q.title = m and m.title or ("Трек " .. q.id)
		q.artist = m and m.artist or "—"
	end

	local startTrack
	function startTrack(i)
		radio.token += 1
		local my = radio.token
		radio.votes = {}
		local t = radio.queue[i]
		if not t then
			radio.idx, radio.startedAt, radio.duration = 0, 0, 0
			radio.paused, radio.loading = false, false
			pushRadio()
			return
		end
		radio.idx = i
		radio.loading = true
		radio.startedAt, radio.duration, radio.paused = 0, 0, false
		fillMeta(t)
		if my ~= radio.token then return end
		pushRadio() -- клиенты видят трек и «загрузка» (startedAt = 0)

		-- сервер сам узнаёт длительность и проверяет, что трек доступен
		local s = Instance.new("Sound")
		s.SoundId = "rbxassetid://" .. t.id
		s.Volume = 0
		s.Parent = SoundService
		local t0 = os.clock()
		while not s.IsLoaded and os.clock() - t0 < 8 do
			task.wait(0.1)
		end
		local len = s.IsLoaded and s.TimeLength or 0
		s:Destroy()
		if my ~= radio.token then return end
		if len <= 0 then
			startTrack(i + 1) -- недоступный трек пропускаем
			return
		end
		radio.startedAt = workspace:GetServerTimeNow()
		radio.duration = len
		radio.loading = false
		pushRadio()
	end

	local function advance()
		if radio.loading then return end
		local n = radio.idx + 1
		while radio.idx > 30 do -- чистим проигранное, чтобы очередь не росла
			table.remove(radio.queue, 1)
			radio.idx -= 1
			n -= 1
		end
		task.spawn(startTrack, n)
	end

	task.spawn(function()
		while true do
			task.wait(0.5)
			if radio.idx > 0 and not radio.loading and not radio.paused and radio.duration > 0
				and workspace:GetServerTimeNow() >= radio.startedAt + radio.duration + 0.4 then
				advance()
			end
		end
	end)

	local function cleanRadioTracks(list, max)
		local out = {}
		if type(list) ~= "table" then return out end
		for _, t in ipairs(list) do
			if #out >= max then break end
			local id = type(t) == "table" and tonumber(t.id) or tonumber(t)
			if validId(id) then out[#out + 1] = { id = id } end
		end
		return out
	end

	local radioRate = {}
	remRadio.OnServerEvent:Connect(function(plr, action, arg)
		local now = os.clock()
		if radioRate[plr] and now - radioRate[plr] < 0.3 then return end
		radioRate[plr] = now

		if action == "join" then
			radio.listeners[plr] = true
			pushRadio()
		elseif action == "leave" then
			radio.listeners[plr] = nil
			radio.votes[plr] = nil
			pushRadio()
		elseif action == "state" then
			pushRadio(plr)
		elseif action == "claim" then
			if not radio.dj then
				radio.dj = plr
				radio.listeners[plr] = true
				pushRadio()
			else
				pushRadio(plr)
			end
		elseif action == "release" then
			if radio.dj == plr then radio.dj = nil end
			pushRadio()
		elseif action == "skip" then
			if not radio.listeners[plr] or radio.idx == 0 then return end
			if radio.dj == plr then
				advance()
			else
				radio.votes[plr] = true
				if voteCount() >= neededVotes() then
					advance()
				else
					pushRadio()
				end
			end
		elseif radio.dj == plr then
			if action == "play" and type(arg) == "table" then
				local tracks = cleanRadioTracks(arg.tracks, 100)
				if #tracks == 0 then return end
				radio.queue = tracks
				radio.idx = 0
				radio.listeners[plr] = true
				task.spawn(startTrack, math.clamp(math.floor(tonumber(arg.index) or 1), 1, #tracks))
				task.spawn(function() -- названия остальных треков подтягиваем в фоне
					for _, q in ipairs(tracks) do
						fillMeta(q)
						if radio.queue ~= tracks then return end
						task.wait(0.1)
					end
					pushRadio()
				end)
			elseif action == "enqueue" then
				local add = cleanRadioTracks({ arg }, 1)
				if #add == 0 or #radio.queue >= 100 then return end
				table.insert(radio.queue, add[1])
				if radio.idx == 0 then
					task.spawn(startTrack, #radio.queue)
				else
					pushRadio()
				end
				task.spawn(function()
					fillMeta(add[1])
					pushRadio()
				end)
			elseif action == "pause" then
				if not radio.paused and radio.idx > 0 and not radio.loading then
					radio.paused = true
					radio.pausedAt = workspace:GetServerTimeNow()
					pushRadio()
				end
			elseif action == "resume" then
				if radio.paused then
					radio.startedAt += workspace:GetServerTimeNow() - radio.pausedAt
					radio.paused = false
					pushRadio()
				end
			elseif action == "stop" then
				radio.queue = {}
				task.spawn(startTrack, 1)
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(plr)
		lastSaved[plr], lastBackupAt[plr], restoreAt[plr] = nil, nil, nil
		nowLast[plr], radioRate[plr] = nil, nil
		if nowPlaying[plr] then
			nowPlaying[plr] = nil
			nowDirty = true
		end
		radio.listeners[plr], radio.votes[plr] = nil, nil
		if radio.dj == plr then radio.dj = nil end
		pushRadio()
	end)

	-- Публичные плейлисты ----------------------------------------------
	local pubStore = DataStoreService:GetDataStore("SpotifyPlayer_Public_v1")
	local pubIndex = DataStoreService:GetOrderedDataStore("SpotifyPlayer_PublicIndex_v1")
	local pubCache, pubListAt, pubListCache, pubAt = {}, -1e9, {}, {}
	local CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

	local function newCode()
		local t = {}
		for i = 1, 6 do
			local k = math.random(#CODE_CHARS)
			t[i] = CODE_CHARS:sub(k, k)
		end
		return table.concat(t)
	end

	local function getPublic(code)
		local c = pubCache[code]
		if c and os.clock() - c.at < 60 then return c.data end
		local ok, data = pcall(function() return pubStore:GetAsync("c_" .. code) end)
		if ok then
			pubCache[code] = { data = data, at = os.clock() }
			return data
		end
		return nil
	end

	local function userCodes(plr)
		local ok, list = pcall(function() return pubStore:GetAsync("p_" .. plr.UserId) end)
		if ok and type(list) == "table" then return list end
		return {}
	end

	-- название плейлиста видят все игроки, поэтому обязательно проходит фильтр Roblox
	local function filterName(plr, name)
		local ok, res = pcall(function()
			local fr = TextService:FilterStringAsync(name, plr.UserId, Enum.TextFilterContext.PublicChat)
			return fr:GetNonChatStringForBroadcastAsync()
		end)
		if ok and type(res) == "string" and res ~= "" then return res end
		return nil
	end

	local function entryOf(code, d)
		return { code = code, name = d.name, owner = d.owner, count = #d.ids, t = d.t }
	end

	remPublic.OnServerInvoke = function(plr, action, arg)
		if action == "list" then
			if os.clock() - pubListAt < 120 and #pubListCache > 0 then return { ok = true, list = pubListCache } end
			pubListAt = os.clock()
			local ok, page = pcall(function() return pubIndex:GetSortedAsync(false, 15):GetCurrentPage() end)
			if not ok then
				pubListAt = os.clock() - 100
				return { ok = true, list = pubListCache }
			end
			local out = {}
			for _, e in ipairs(page) do
				local d = getPublic(e.key)
				if d then out[#out + 1] = entryOf(e.key, d) end
			end
			pubListCache = out
			return { ok = true, list = out }

		elseif action == "mine" then
			local out = {}
			for _, c in ipairs(userCodes(plr)) do
				local d = getPublic(c)
				if d then out[#out + 1] = entryOf(c, d) end
			end
			return { ok = true, list = out }

		elseif action == "get" then
			local code = type(arg) == "string" and arg:upper() or ""
			code = code:gsub("%s", "")
			if not validCode6(code) then return { ok = false, err = "bad_code" } end
			local d = getPublic(code)
			if not d then return { ok = false, err = "not_found" } end
			return { ok = true, pl = { code = code, name = d.name, owner = d.owner, ids = d.ids } }

		elseif action == "publish" or action == "update" then
			if type(arg) ~= "table" then return { ok = false } end
			local now = os.clock()
			if pubAt[plr] and now - pubAt[plr] < 30 then return { ok = false, err = "cooldown" } end
			local ids, seen = {}, {}
			if type(arg.ids) == "table" then
				for _, v in ipairs(arg.ids) do
					v = tonumber(v)
					if validId(v) and not seen[v] and #ids < 100 then
						seen[v] = true
						ids[#ids + 1] = v
					end
				end
			end
			if #ids == 0 then return { ok = false, err = "empty" } end
			local name = filterName(plr, cleanText(arg.name, 24) or "Плейлист")
			if not name then return { ok = false, err = "filter" } end
			pubAt[plr] = now
			local data = { name = name, owner = plr.DisplayName, ownerId = plr.UserId, ids = ids, t = os.time() }
			local codes = userCodes(plr)
			local code = validCode6(arg.code)
			if code then -- обновление своего плейлиста
				if not table.find(codes, code) then return { ok = false, err = "not_owner" } end
				local wrote = pcall(function() pubStore:SetAsync("c_" .. code, data) end)
				if not wrote then return { ok = false } end
				pubCache[code] = nil
				pcall(function() pubIndex:SetAsync(code, os.time()) end)
				pubListAt = -1e9
				return { ok = true, code = code }
			end
			if #codes >= 5 then return { ok = false, err = "limit" } end
			for _ = 1, 6 do
				local c = newCode()
				local created = false
				local ok = pcall(function()
					pubStore:UpdateAsync("c_" .. c, function(old)
						created = false
						if old ~= nil then return nil end
						created = true
						return data
					end)
				end)
				if ok and created then
					code = c
					break
				end
			end
			if not code then return { ok = false } end
			pcall(function()
				pubStore:UpdateAsync("p_" .. plr.UserId, function(old)
					old = type(old) == "table" and old or {}
					table.insert(old, code)
					return old
				end)
			end)
			pcall(function() pubIndex:SetAsync(code, os.time()) end)
			pubListAt = -1e9
			return { ok = true, code = code }

		elseif action == "unpublish" then
			local code = validCode6(arg)
			if not code then return { ok = false } end
			local codes = userCodes(plr)
			local pos = table.find(codes, code)
			if not pos then return { ok = false, err = "not_owner" } end
			pcall(function() pubStore:RemoveAsync("c_" .. code) end)
			pcall(function() pubIndex:RemoveAsync(code) end)
			table.remove(codes, pos)
			pcall(function() pubStore:SetAsync("p_" .. plr.UserId, codes) end)
			pubCache[code] = nil
			pubListAt = -1e9
			return { ok = true }
		end
		return { ok = false }
	end

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
local __ok, __err = xpcall(function()
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
if playerGui:FindFirstChild("SpotifyPlayer") then return end


------------------------------------------------------------
-- ТЕМЫ
------------------------------------------------------------
rgb = Color3.fromRGB
THEMES = {
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
C = THEMES.dark

FONT, FONT_B, FONT_X = Enum.Font.GothamMedium, Enum.Font.GothamBold, Enum.Font.GothamBlack
W, H = 860, 600
SIDE_W, BAR_H = 220, 96
CONTENT_W = W - SIDE_W
MAX_TRACKS, MAX_PLAYLISTS = 300, 20

------------------------------------------------------------
-- ХЕЛПЕРЫ
-- В new()/label(): bg="роль" и tc="роль" — цвета, которые меняются вместе с темой
------------------------------------------------------------
themed = {}

function new(class, props)
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

function corner(inst, r)
	return new("UICorner", { CornerRadius = UDim.new(0, r), Parent = inst })
end

function label(props)
	props.BackgroundTransparency = 1
	props.Font = props.Font or FONT
	if not props.tc and not props.TextColor3 then props.tc = "text" end
	props.TextSize = props.TextSize or 14
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return new("TextLabel", props)
end

function tween(inst, t, props, style, dir)
	local tw = TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

function formatTime(s)
	s = math.max(0, math.floor(s))
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

function isPointer(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end
function isMove(input)
	return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
end

function pointer()
	return UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
end
function inside(g, p)
	local a, s = g.AbsolutePosition, g.AbsoluteSize
	return p.X >= a.X and p.X <= a.X + s.X and p.Y >= a.Y and p.Y <= a.Y + s.Y
end

function hueFor(seed)
	if type(seed) == "string" then
		local h = 0
		for i = 1, #seed do h = (h * 31 + seed:byte(i)) % 1000 end
		seed = h
	end
	return (seed * 0.61803398875) % 1
end
function accentH(h, v, s) return Color3.fromHSV(h, s or 0.6, v or 0.85) end
function accent(seed, v) return accentH(hueFor(seed), v) end

function pluralTracks(n)
	local a, b = n % 10, n % 100
	if a == 1 and b ~= 11 then return n .. " трек" end
	if a >= 2 and a <= 4 and (b < 12 or b > 14) then return n .. " трека" end
	return n .. " треков"
end

-- нижний регистр для кириллицы и латиницы (сортировка и поиск)
function lowerU(s)
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

function bouncy(btn, hoverScale)
	local s = new("UIScale", { Parent = btn })
	btn.MouseEnter:Connect(function() tween(s, 0.12, { Scale = hoverScale or 1.06 }) end)
	btn.MouseButton1Down:Connect(function() tween(s, 0.08, { Scale = 0.9 }) end)
	local function up() tween(s, 0.3, { Scale = 1 }, Enum.EasingStyle.Back) end
	btn.MouseButton1Up:Connect(up)
	btn.MouseLeave:Connect(up)
	return s
end

function pop(btn)
	local s = btn:FindFirstChildOfClass("UIScale")
	if s then
		s.Scale = 1.5
		tween(s, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
	end
end

------------------------------------------------------------
-- СОСТОЯНИЕ (сохраняется автоматически)
------------------------------------------------------------
state = {
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
	theme = "dark", crossfade = 0, binds = {}, markers = {}, shareNow = true,
}

view = { kind = "pl", index = 1 } -- pl | liked | top | search | radio | public | activity
extraPopups = {}
searchList, searchQuery = {}, ""
topList, topState = {}, "idle"
sortMode = "manual"
loaded, saveToken, dirtyFlag = false, 0, false

-- Горячие клавиши
ACTIONS = {
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
KEYNAMES = {
	Period = ".", Comma = ",", Equals = "=", Minus = "-", RightBracket = "]",
	LeftBracket = "[", Slash = "/", Backquote = "`", Semicolon = ";", Quote = "'",
}
function keyOf(id)
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
function keyLabel(id)
	local k = keyOf(id)
	if not k then return "—" end
	return KEYNAMES[k.Name] or k.Name
end

-- forward declarations
uiMode, lastShown = "hidden", "full"
markerLen = 0

function currentList()
	if view.kind == "liked" then return state.liked end
	if view.kind == "top" then return topList end
	if view.kind == "search" then return searchList end
	if view.kind ~= "pl" then return {} end
	return state.playlists[view.index].tracks
end

function isLiked(id)
	for _, t in ipairs(state.liked) do
		if t.id == id then return true end
	end
	return false
end

-- Сортировка (только отображение)
SORTS = { "manual", "title", "artist", "newest" }
SORT_NAMES = { manual = "Мой порядок", title = "Название А–Я", artist = "Исполнитель А–Я", newest = "Сначала новые" }

function displayList()
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

function buildSearch(q)
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
group = new("SoundGroup", { Name = "SpotifyBus", Volume = state.volume, Parent = SoundService })
eq = new("EqualizerSoundEffect", { Parent = group })
reverbFx = new("ReverbSoundEffect", {
	DecayTime = 2.8, Density = 0.9, Diffusion = 0.9, DryLevel = 0, WetLevel = -6, Enabled = false, Parent = group,
})

function applyAudio()
	group.Volume = state.volume
	eq.LowGain = math.clamp(state.bass * 10, -80, 10)
	eq.MidGain = -state.bass * 3
	eq.HighGain = 0
	reverbFx.Enabled = state.reverb
end
applyAudio()

speed = 1
queue, qi = {}, 0
shuffle, repeatMode = false, 0
playToken, failStreak, xfFired = 0, 0, -1
badIds = {}

------------------------------------------------------------
-- GUI: КОРЕНЬ
------------------------------------------------------------
gui = new("ScreenGui", {
	Name = "SpotifyPlayer", ResetOnSpawn = false, DisplayOrder = 10,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = playerGui,
})
root = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(W, H), BackgroundTransparency = 1, Parent = gui,
})
uiScale = new("UIScale", { Parent = root })
function rescale()
	local cam = workspace.CurrentCamera
	if not cam then return end
	local v = cam.ViewportSize
	uiScale.Scale = math.clamp(math.min(v.X / (W + 40), v.Y / (H + 40)), 0.45, 1)
end
rescale()
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
end

main = new("CanvasGroup", {
	Size = UDim2.fromScale(1, 1), bg = "bg", BorderSizePixel = 0, Visible = false, Parent = root,
})
corner(main, 14)

-- Toast
toast = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, -70),
	Size = UDim2.fromOffset(340, 40), bg = "text", ZIndex = 100, Parent = gui,
})
corner(toast, 20)
toastLbl = label({
	Text = "", Font = FONT_B, TextSize = 14, tc = "bg", TextXAlignment = Enum.TextXAlignment.Center,
	Size = UDim2.fromScale(1, 1), ZIndex = 101, Parent = toast,
})
toastToken = 0
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
sidebar = new("Frame", {
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

function sideButton(parent, y, icon, text)
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

navLiked, navLikedIc, navLikedTx = sideButton(sidebar, 82, "♥", "Любимое")
navTop, navTopIc, navTopTx = sideButton(sidebar, 120, "🔥", "Топ чарт")
navRadio, navRadioIc, navRadioTx = sideButton(sidebar, 158, "📻", "Радио / DJ")
navPub, navPubIc, navPubTx = sideButton(sidebar, 196, "🌐", "Публичные")
navAct, navActIc, navActTx = sideButton(sidebar, 234, "👥", "Слушают")

label({
	Text = "ПЛЕЙЛИСТЫ", Font = FONT_B, TextSize = 12, tc = "sub",
	Position = UDim2.fromOffset(20, 282), Size = UDim2.fromOffset(120, 24), Parent = sidebar,
})
plAddBtn = new("TextButton", {
	Text = "+", Font = FONT_B, TextSize = 22, tc = "sub", BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 280), Size = UDim2.fromOffset(28, 28), Parent = sidebar,
})
bouncy(plAddBtn, 1.15)

plNameBox = new("TextBox", {
	PlaceholderText = "Название и Enter", PlaceholderColor3 = rgb(140, 140, 150), Text = "",
	ClearTextOnFocus = false, Font = FONT, TextSize = 13, tc = "text",
	TextXAlignment = Enum.TextXAlignment.Left, bg = "elev", Visible = false,
	Position = UDim2.fromOffset(10, 308), Size = UDim2.new(1, -20, 0, 30), Parent = sidebar,
})
corner(plNameBox, 15)
new("UIPadding", { PaddingLeft = UDim.new(0, 12), Parent = plNameBox })

plScroll = new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = C.elev2,
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = sidebar,
})
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = plScroll })

function layoutSidebar()
	local y = plNameBox.Visible and 344 or 310
	plScroll.Position = UDim2.fromOffset(8, y)
	plScroll.Size = UDim2.new(1, -16, 1, -(y + 52))
end
layoutSidebar()

-- нижние кнопки сайдбара
botRow = new("Frame", {
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -6),
	Size = UDim2.new(1, 0, 0, 36), BackgroundTransparency = 1, Parent = sidebar,
})
function smallBtn(text, x)
	local b = new("TextButton", {
		Text = text, Font = FONT_B, TextSize = 16, tc = "sub", bg = "elev",
		Position = UDim2.fromOffset(x, 2), Size = UDim2.fromOffset(44, 32), AutoButtonColor = false, Parent = botRow,
	})
	corner(b, 16)
	bouncy(b, 1.06)
	return b
end
themeBtn = smallBtn("☀", 10)
keysBtn = smallBtn("⌨", 60)
miniBtn = smallBtn("▭", 110)
moreBtn = smallBtn("⚙", 160)

------------------------------------------------------------
-- ОСНОВНАЯ ОБЛАСТЬ
------------------------------------------------------------
content = new("Frame", {
	Position = UDim2.fromOffset(SIDE_W, 0), Size = UDim2.new(0, CONTENT_W, 1, -BAR_H),
	bg = "bg", BorderSizePixel = 0, Parent = main,
})

banner = new("Frame", {
	Size = UDim2.new(1, 0, 0, 130), BackgroundColor3 = rgb(60, 40, 120), BorderSizePixel = 0, Parent = content,
})
bannerFade = new("Frame", { Size = UDim2.fromScale(1, 1), bg = "bg", BorderSizePixel = 0, Parent = banner })
new("UIGradient", {
	Rotation = 90,
	Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) }),
	Parent = bannerFade,
})

bannerCover = new("Frame", {
	Position = UDim2.fromOffset(28, 34), Size = UDim2.fromOffset(84, 84),
	BackgroundColor3 = rgb(255, 255, 255), BorderSizePixel = 0, Parent = banner,
})
corner(bannerCover, 8)
bannerCoverGrad = new("UIGradient", {
	Color = ColorSequence.new(rgb(30, 215, 96), rgb(60, 40, 120)), Rotation = 45, Parent = bannerCover,
})
bannerCoverScale = new("UIScale", { Parent = bannerCover })
bannerIcon = label({
	Text = "♪", Font = FONT_X, TextSize = 40, TextColor3 = rgb(255, 255, 255),
	TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = bannerCover,
})
bannerKind = label({
	Text = "ПЛЕЙЛИСТ", Font = FONT_B, TextSize = 11,
	Position = UDim2.fromOffset(128, 40), Size = UDim2.fromOffset(320, 16), Parent = banner,
})
bannerTitle = label({
	Text = "", Font = FONT_X, TextSize = 30, TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(128, 56), Size = UDim2.fromOffset(330, 40), Parent = banner,
})
bannerSub = label({
	Text = "", TextSize = 13, tc = "sub",
	Position = UDim2.fromOffset(128, 98), Size = UDim2.fromOffset(330, 18), Parent = banner,
})

VIS_BARS = 16
visBox = new("Frame", {
	Position = UDim2.fromOffset(CONTENT_W - 28 - VIS_BARS * 9, 40),
	Size = UDim2.fromOffset(VIS_BARS * 9, 74), BackgroundTransparency = 1, Parent = banner,
})
bars = {}
for i = 1, VIS_BARS do
	local b = new("Frame", {
		AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, (i - 1) * 9, 1, 0), Size = UDim2.fromOffset(6, 4),
		BackgroundColor3 = C.green, BackgroundTransparency = 0.15, BorderSizePixel = 0, Parent = visBox,
	})
	corner(b, 3)
	bars[i] = b
end

-- Тулбар
toolbar = new("Frame", {
	Position = UDim2.fromOffset(0, 130), Size = UDim2.new(1, 0, 0, 52), BackgroundTransparency = 1, Parent = content,
})
bigPlay = new("TextButton", {
	Text = "▶", Font = FONT_B, TextSize = 20, tc = "ink", bg = "green",
	Position = UDim2.fromOffset(28, 3), Size = UDim2.fromOffset(46, 46), AutoButtonColor = false, Parent = toolbar,
})
corner(bigPlay, 23)
bouncy(bigPlay, 1.08)

sortBtn = new("TextButton", {
	Text = "⇅ " .. SORT_NAMES.manual, Font = FONT_B, TextSize = 12, tc = "text", bg = "elev",
	Position = UDim2.fromOffset(84, 10), Size = UDim2.fromOffset(128, 32), AutoButtonColor = false, Parent = toolbar,
})
corner(sortBtn, 16)
bouncy(sortBtn, 1.04)

searchRow = new("Frame", {
	Position = UDim2.fromOffset(220, 10), Size = UDim2.fromOffset(184, 32), bg = "elev", Parent = toolbar,
})
corner(searchRow, 16)
label({
	Text = "🔍", TextSize = 13, TextXAlignment = Enum.TextXAlignment.Center,
	Position = UDim2.fromOffset(4, 0), Size = UDim2.fromOffset(26, 32), Parent = searchRow,
})
searchBox = new("TextBox", {
	PlaceholderText = "Поиск по трекам", PlaceholderColor3 = rgb(140, 140, 150), Text = "",
	ClearTextOnFocus = false, Font = FONT, TextSize = 13, tc = "text",
	TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1,
	Position = UDim2.fromOffset(30, 0), Size = UDim2.new(1, -58, 1, 0), Parent = searchRow,
})
searchClear = new("TextButton", {
	Text = "✕", Font = FONT_B, TextSize = 12, tc = "sub", BackgroundTransparency = 1, Visible = false,
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(22, 22), Parent = searchRow,
})

topHint = label({
	Text = "Чарт игроков · раз в минуту", TextSize = 12, tc = "sub", TextXAlignment = Enum.TextXAlignment.Right,
	Visible = false, Position = UDim2.new(1, -208, 0, 0), Size = UDim2.fromOffset(180, 52), Parent = toolbar,
})
addRow = new("Frame", {
	Position = UDim2.new(1, -228, 0, 10), Size = UDim2.fromOffset(200, 32), bg = "elev", Parent = toolbar,
})
corner(addRow, 16)
addBox = new("TextBox", {
	PlaceholderText = "Добавить по ID", PlaceholderColor3 = rgb(140, 140, 150), Text = "",
	ClearTextOnFocus = false, Font = FONT, TextSize = 13, tc = "text",
	TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1,
	Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -48, 1, 0), Parent = addRow,
})
addBtn = new("TextButton", {
	Text = "+", Font = FONT_B, TextSize = 20, tc = "ink", bg = "green",
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0.5, 0), Size = UDim2.fromOffset(24, 24),
	AutoButtonColor = false, Parent = addRow,
})
corner(addBtn, 12)
bouncy(addBtn, 1.1)

hdrNum = label({
	Text = "#", Font = FONT_B, TextSize = 12, tc = "sub", TextXAlignment = Enum.TextXAlignment.Center,
	Position = UDim2.fromOffset(12, 182), Size = UDim2.fromOffset(40, 22), Parent = content,
})
hdrName = label({
	Text = "НАЗВАНИЕ", Font = FONT_B, TextSize = 12, tc = "sub",
	Position = UDim2.fromOffset(102, 182), Size = UDim2.fromOffset(200, 22), Parent = content,
})
hdrLine = new("Frame", {
	Position = UDim2.fromOffset(12, 204), Size = UDim2.new(1, -24, 0, 1), bg = "elev", BorderSizePixel = 0, Parent = content,
})

listWrap = new("CanvasGroup", {
	Position = UDim2.fromOffset(12, 208), Size = UDim2.new(1, -24, 1, -208), BackgroundTransparency = 1, Parent = content,
})
scroll = new("ScrollingFrame", {
	Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
	ScrollBarThickness = 4, ScrollBarImageColor3 = C.elev2,
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = listWrap,
})
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = scroll })
new("UIPadding", { PaddingTop = UDim.new(0, 4), Parent = scroll })
emptyLbl = label({
	Text = "", TextSize = 14, tc = "sub", TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center,
	Visible = false, Position = UDim2.fromOffset(40, 50), Size = UDim2.new(1, -80, 0, 60), Parent = listWrap,
})

------------------------------------------------------------
-- НИЖНЯЯ ПАНЕЛЬ
------------------------------------------------------------
bar = new("Frame", {
	Position = UDim2.new(0, 0, 1, -BAR_H), Size = UDim2.new(1, 0, 0, BAR_H), bg = "panel", BorderSizePixel = 0, Parent = main,
})
new("Frame", { Size = UDim2.new(1, 0, 0, 1), bg = "elev", BorderSizePixel = 0, Parent = bar })

barCover = new("Frame", {
	Position = UDim2.fromOffset(16, 18), Size = UDim2.fromOffset(60, 60),
	BackgroundColor3 = rgb(255, 255, 255), BorderSizePixel = 0, Parent = bar,
})
corner(barCover, 6)
barCoverGrad = new("UIGradient", {
	Color = ColorSequence.new(rgb(120, 120, 130), rgb(70, 70, 80)), Rotation = 45, Parent = barCover,
})
barCoverScale = new("UIScale", { Parent = barCover })
label({
	Text = "♪", Font = FONT_B, TextSize = 26, TextColor3 = rgb(255, 255, 255),
	TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = barCover,
})
barTitle = label({
	Text = "Ничего не играет", Font = FONT_B, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(88, 26), Size = UDim2.fromOffset(126, 20), Parent = bar,
})
barArtist = label({
	Text = "Выбери трек", TextSize = 12, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(88, 47), Size = UDim2.fromOffset(126, 16), Parent = bar,
})
barHeart = new("TextButton", {
	Text = "♥", Font = FONT_B, TextSize = 20, tc = "elev2", BackgroundTransparency = 1,
	Position = UDim2.fromOffset(220, 31), Size = UDim2.fromOffset(30, 34), Parent = bar,
})
bouncy(barHeart, 1.15)

center = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 10),
	Size = UDim2.fromOffset(330, 78), BackgroundTransparency = 1, Parent = bar,
})
controls = new("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1, Parent = center })
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 12),
	SortOrder = Enum.SortOrder.LayoutOrder, Parent = controls,
})
function ctrlButton(text, order, size)
	local b = new("TextButton", {
		Text = text, Font = FONT_B, TextSize = size or 20, tc = "sub", BackgroundTransparency = 1,
		Size = UDim2.fromOffset(32, 34), LayoutOrder = order, AutoButtonColor = false, Parent = controls,
	})
	bouncy(b, 1.12)
	return b
end
shuffleBtn = ctrlButton("⇄", 1)
prevBtn = ctrlButton("⏮", 2, 18)
playBtn = new("TextButton", {
	Text = "▶", Font = FONT_B, TextSize = 18, tc = "bg", bg = "text",
	Size = UDim2.fromOffset(42, 42), LayoutOrder = 3, AutoButtonColor = false, Parent = controls,
})
corner(playBtn, 21)
bouncy(playBtn, 1.08)
nextBtn = ctrlButton("⏭", 4, 18)
repeatBtn = ctrlButton("↻", 5)
markBtn = ctrlButton("⚑", 6, 17)
prevBtn.TextColor3 = C.text
nextBtn.TextColor3 = C.text
themed[#themed + 1] = { prevBtn, "TextColor3", "text" }
themed[#themed + 1] = { nextBtn, "TextColor3", "text" }

-- Слайдер: opts = {onHover, onLeave, onRight, onWheel}
function makeSlider(parent, position, size, initial, onChanged, opts)
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

curTime = label({
	Text = "0:00", TextSize = 11, tc = "sub", TextXAlignment = Enum.TextXAlignment.Right,
	Position = UDim2.fromOffset(0, 48), Size = UDim2.fromOffset(36, 16), Parent = center,
})
totTime = label({
	Text = "0:00", TextSize = 11, tc = "sub",
	Position = UDim2.fromOffset(294, 48), Size = UDim2.fromOffset(36, 16), Parent = center,
})

-- подсказка времени над прогрессом
tip = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromOffset(42, 46), Size = UDim2.fromOffset(52, 18),
	bg = "elev", Visible = false, ZIndex = 10, Parent = center,
})
corner(tip, 9)
tipLbl = label({
	Text = "0:00", Font = FONT_B, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Center,
	Size = UDim2.fromScale(1, 1), ZIndex = 11, Parent = tip,
})
function showTip(a, text)
	tip.Position = UDim2.fromOffset(42 + a * 246, 46)
	tipLbl.Text = text
	tip.Visible = true
end

progress = makeSlider(center, UDim2.fromOffset(42, 55), UDim2.fromOffset(246, 4), 0, function(a)
	if radioOn then return end
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

markerLayer = new("Frame", {
	Position = UDim2.fromOffset(42, 49), Size = UDim2.fromOffset(246, 16),
	BackgroundTransparency = 1, ZIndex = 6, Parent = center,
})
markerBtns = {}

-- Справа: громкость и звук
right = new("Frame", {
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16, 0.5, 0),
	Size = UDim2.fromOffset(222, 40), BackgroundTransparency = 1, Parent = bar,
})
label({
	Text = "🔊", TextSize = 15, TextXAlignment = Enum.TextXAlignment.Center,
	Size = UDim2.fromOffset(22, 40), Parent = right,
})
volume = makeSlider(right, UDim2.fromOffset(28, 18), UDim2.fromOffset(100, 4), state.volume, function(a)
	state.volume = a
	applyAudio()
	markDirty()
end, { onWheel = function(z) setVolume(state.volume + z * 0.05) end })
eqBtn = new("TextButton", {
	Text = "Звук ⚙", Font = FONT_B, TextSize = 13, tc = "text", bg = "elev",
	Position = UDim2.fromOffset(142, 5), Size = UDim2.fromOffset(80, 30), AutoButtonColor = false, Parent = right,
})
corner(eqBtn, 15)
bouncy(eqBtn, 1.06)

------------------------------------------------------------
-- ПОПАПЫ
------------------------------------------------------------
blocker = new("TextButton", {
	Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 40, Parent = main,
})
function showPopup(p)
	p.Visible = true
	p.GroupTransparency = 1
	tween(p, 0.2, { GroupTransparency = 0 })
end
function hidePopup(p)
	if not p.Visible then return end
	local tw = tween(p, 0.15, { GroupTransparency = 1 })
	tw.Completed:Connect(function()
		if p.GroupTransparency >= 1 then p.Visible = false end
	end)
end

-- универсальное меню (ПКМ, "добавить в плейлист", подтверждения)
menu = new("CanvasGroup", {
	Size = UDim2.fromOffset(230, 200), bg = "elev", Visible = false, ZIndex = 50, Parent = main,
})
corner(menu, 10)
menuTitle = label({
	Text = "", Font = FONT_B, TextSize = 13, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(14, 8), Size = UDim2.new(1, -28, 0, 22), Parent = menu,
})
menuList = new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
	Position = UDim2.fromOffset(6, 34), Size = UDim2.new(1, -12, 1, -40),
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = menu,
})
new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = menuList })

-- попап звука
eqPopup = new("CanvasGroup", {
	AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -BAR_H - 8),
	Size = UDim2.fromOffset(290, 364), bg = "elev", Visible = false, ZIndex = 50, Parent = main,
})
corner(eqPopup, 12)
label({
	Text = "Звук и эффекты", Font = FONT_B, TextSize = 16,
	Position = UDim2.fromOffset(20, 14), Size = UDim2.new(1, -40, 0, 22), Parent = eqPopup,
})
function popLabel(text, y)
	return label({
		Text = text, TextSize = 13, tc = "sub",
		Position = UDim2.fromOffset(20, y), Size = UDim2.fromOffset(160, 18), Parent = eqPopup,
	})
end
function popValue(y)
	return label({
		Text = "", Font = FONT_B, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.fromOffset(190, y), Size = UDim2.fromOffset(80, 18), Parent = eqPopup,
	})
end
popLabel("Усиление баса", 50)
bassVal = popValue(50)
popLabel("Кроссфейд между треками", 102)
xfVal = popValue(102)
popLabel("Скорость", 154)
popLabel("Реверберация", 224)
popLabel("Пресеты", 262)

function chip(parent, text, x, y, w)
	local b = new("TextButton", {
		Text = text, Font = FONT_B, TextSize = 12, tc = "text", bg = "chip",
		Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, 30), AutoButtonColor = false, Parent = parent,
	})
	corner(b, 15)
	bouncy(b, 1.05)
	return b
end
function chipActive(b, on)
	tween(b, 0.15, { BackgroundColor3 = on and C.green or C.chip })
	b.TextColor3 = on and C.ink or C.text
end

speedChips = {}
for i, s in ipairs({ { 0.8, "0.8×" }, { 1, "1×" }, { 1.25, "1.25×" } }) do
	speedChips[i] = { btn = chip(eqPopup, s[2], 20 + (i - 1) * 86, 178, 78), value = s[1] }
end
function refreshSpeedChips()
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

sw = new("TextButton", {
	Text = "", bg = "chip", Position = UDim2.fromOffset(226, 223), Size = UDim2.fromOffset(44, 22),
	AutoButtonColor = false, Parent = eqPopup,
})
corner(sw, 11)
swKnob = new("Frame", {
	AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), Size = UDim2.fromOffset(16, 16),
	BackgroundColor3 = rgb(255, 255, 255), BorderSizePixel = 0, Parent = sw,
})
corner(swKnob, 8)

function setBass(a, fromSlider)
	state.bass = a
	applyAudio()
	bassVal.Text = math.floor(a * 100 + 0.5) .. "%"
	if not fromSlider and bassSlider then bassSlider.Set(a) end
	markDirty()
end
function setCrossfade(sec, fromSlider)
	sec = math.clamp(math.floor(sec + 0.5), 0, 12)
	state.crossfade = sec
	xfVal.Text = sec == 0 and "Выкл" or (sec .. " с")
	if not fromSlider and xfSlider then xfSlider.Set(sec / 12) end
	markDirty()
end
function setReverb(v, instant)
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

PRESETS = {
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
keysPopup = new("CanvasGroup", {
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
keysList = new("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
	Position = UDim2.fromOffset(12, 90), Size = UDim2.new(1, -24, 1, -142),
	CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = keysPopup,
})
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = keysList })
keysReset = chip(keysPopup, "Сбросить всё", 20, 428, 120)
keysClose = chip(keysPopup, "Закрыть", 280, 428, 100)

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
	for _, p in ipairs(extraPopups) do hidePopup(p) end
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
dragHandle = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, ZIndex = 5, Parent = main })
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

closeBtn = new("TextButton", {
	Text = "✕", Font = FONT_B, TextSize = 15, tc = "sub", BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0, 18), Size = UDim2.fromOffset(28, 28),
	ZIndex = 6, Parent = main,
})
bouncy(closeBtn, 1.15)

toggleBtn = new("TextButton", {
	Text = "♪", Font = FONT_X, TextSize = 24, tc = "ink", bg = "green",
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -16), Size = UDim2.fromOffset(46, 46),
	AutoButtonColor = false, Parent = gui,
})
corner(toggleBtn, 23)
bouncy(toggleBtn, 1.1)

-- мини-плеер
miniRoot = new("CanvasGroup", {
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -74), Size = UDim2.fromOffset(360, 76),
	bg = "panel", Visible = false, Parent = gui,
})
corner(miniRoot, 14)
miniScale = new("UIScale", { Parent = miniRoot })
miniCover = new("Frame", {
	Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(54, 54),
	BackgroundColor3 = rgb(255, 255, 255), BorderSizePixel = 0, Parent = miniRoot,
})
corner(miniCover, 8)
miniCoverGrad = new("UIGradient", {
	Color = ColorSequence.new(rgb(120, 120, 130), rgb(70, 70, 80)), Rotation = 45, Parent = miniCover,
})
miniCoverScale = new("UIScale", { Parent = miniCover })
label({
	Text = "♪", Font = FONT_B, TextSize = 22, TextColor3 = rgb(255, 255, 255),
	TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.fromScale(1, 1), Parent = miniCover,
})
miniTitle = label({
	Text = "Ничего не играет", Font = FONT_B, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(74, 16), Size = UDim2.fromOffset(126, 20), Parent = miniRoot,
})
miniArtist = label({
	Text = "", TextSize = 12, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd,
	Position = UDim2.fromOffset(74, 38), Size = UDim2.fromOffset(126, 16), Parent = miniRoot,
})
miniDrag = new("Frame", { Size = UDim2.fromOffset(204, 76), BackgroundTransparency = 1, Parent = miniRoot })
function miniBtnMake(text, x, size, circle)
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
miniPrev = miniBtnMake("⏮", 206, 16)
miniPlay = miniBtnMake("▶", 240, 16, true)
miniNext = miniBtnMake("⏭", 284, 16)
miniExpand = miniBtnMake("⤢", 320, 18)
miniExpand.TextColor3 = C.sub
themed[#themed + 1] = { miniExpand, "TextColor3", "sub" }
miniTrack = new("Frame", {
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 3), bg = "elev", BorderSizePixel = 0, Parent = miniRoot,
})
miniFill = new("Frame", { Size = UDim2.fromScale(0, 1), bg = "green", BorderSizePixel = 0, Parent = miniTrack })

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
function pushSave()
	if not (loaded and remSave) then return end
	remSave:FireServer({
		playlists = state.playlists, liked = state.liked, volume = state.volume, bass = state.bass,
		reverb = state.reverb, last = state.last, theme = state.theme, crossfade = state.crossfade,
		binds = state.binds, markers = state.markers, shareNow = state.shareNow,
	})
	dirtyFlag = false
end

function markDirty()
	if not (loaded and remSave) then return end
	dirtyFlag = true
	saveToken += 1
	local my = saveToken
	task.delay(2, function()
		if my == saveToken then pushSave() end
	end)
end

------------------------------------------------------------
-- МЕТАДАННЫЕ ТРЕКОВ
------------------------------------------------------------
metaCache = {}
function fetchInfo(track)
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

function hydrateTitles()
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
function markersFor(track, create)
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
function playAt(i, fadeSec)
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
	if radioOn then radioSetOn(false) end
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
rows, sideBtns = {}, {}

function refreshRowStates()
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
	if reportNow then reportNow() end
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
	elseif view.kind == "radio" then
		title, kind, icon, h = "Радио / DJ", "ОБЩАЯ МУЗЫКА НА СЕРВЕРЕ", "📻", 0.58
	elseif view.kind == "public" then
		title, kind, icon, h = "Публичные плейлисты", "ДЕЛИМСЯ МУЗЫКОЙ", "🌐", 0.4
	elseif view.kind == "activity" then
		title, kind, icon, h = "Что слушают игроки", "ЖИВАЯ ЛЕНТА СЕРВЕРА", "👥", 0.15
	else
		local p = state.playlists[view.index]
		title, kind, icon, h = p.name, "ПЛЕЙЛИСТ", "♪", hueFor(p.name)
	end
	bannerTitle.Text = title
	bannerKind.Text = kind
	bannerIcon.Text = icon
	bannerSub.Text = bannerSubText()
	tween(banner, 0.5, { BackgroundColor3 = accentH(h, C.bannerV, C.bannerS) })
	bannerCoverGrad.Color = ColorSequence.new(accentH(h, 0.95), accentH(h, 0.45))
	local editable = view.kind == "pl" or view.kind == "liked"
	addRow.Visible = editable
	sortBtn.Visible = editable
	topHint.Visible = view.kind == "top"
end

function addToPlaylist(i, track)
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

function removeFromView(track)
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
	items[#items + 1] = { text = "📻  На радио (DJ)", fn = function() radioPlay({ track }, 1) end }
	items[#items + 1] = { text = "📻  В очередь радио", fn = function() radioEnqueue(track) end }
	items[#items + 1] = { text = "ⓘ  Показать ID", fn = function() notify("ID аудио: " .. track.id) end }
	openMenu(track.title or "Трек", items, at)
end

------------------------------------------------------------
-- DRAG & DROP (мышь)
------------------------------------------------------------
cand, drag, dropFlag = nil, nil, false

function resetDropHighlights()
	for _, sb in ipairs(sideBtns) do
		sb.btn.BackgroundTransparency = sb.active and 0 or 1
	end
	navLiked.BackgroundTransparency = view.kind == "liked" and 0 or 1
end

function startDrag(track)
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

function updateDrag()
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

function finishDrag()
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

function deletePlaylist(i)
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

function startRename(i)
	renameIndex = i
	plNameBox.Text = state.playlists[i].name
	plNameBox.Visible = true
	layoutSidebar()
	plNameBox:CaptureFocus()
end

function openPlaylistMenu(i)
	local at = pointer()
	local p = state.playlists[i]
	local items = {
		{ text = "▶  Играть", fn = function() if #p.tracks > 0 then playFromList(p.tracks, 1) end end },
		{ text = "📻  Играть на радио (DJ)", fn = function() radioPlay(p.tracks, 1) end },
		{ text = p.code and "🌐  Обновить публикацию" or "🌐  Опубликовать", fn = function() publishPlaylist(i) end },
	}
	if p.code then
		items[#items + 1] = { text = "🌐  Снять с публикации", fn = function() unpublishPlaylist(i) end }
	end
	items[#items + 1] = { text = "✎  Переименовать", fn = function() startRename(i) end }
	items[#items + 1] = {
		text = "✕  Удалить…", color = C.red,
		fn = function()
			openMenu("Удалить «" .. p.name .. "»?", {
				{ text = "Да, удалить", color = C.red, fn = function() deletePlaylist(i) end },
				{ text = "Отмена", fn = function() end },
			}, at)
		end,
	}
	openMenu(p.name, items, at)
end

function renderSidebar()
	local function setNav(btn, ic, tx, active)
		btn.BackgroundTransparency = active and 0 or 1
		tx.TextColor3 = active and C.text or C.sub
		ic.TextColor3 = active and C.green or C.sub
	end
	setNav(navLiked, navLikedIc, navLikedTx, view.kind == "liked")
	setNav(navTop, navTopIc, navTopTx, view.kind == "top")
	setNav(navRadio, navRadioIc, navRadioTx, view.kind == "radio")
	setNav(navPub, navPubIc, navPubTx, view.kind == "public")
	setNav(navAct, navActIc, navActTx, view.kind == "activity")

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

suppressSearch = false
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
	onViewChanged(v)
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
		onViewChanged(view)
	end
end)
searchClear.Activated:Connect(function() searchBox.Text = "" end)

-- Добавление по ID
function addTrackFromBox()
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
function skipNext()
	if radioOn then
		radioVoteSkip()
		return
	end
	failStreak = 0
	nextTrack(false, false)
end
function skipPrev()
	if radioOn then
		notify("В радио нельзя вернуться назад")
		return
	end
	failStreak = 0
	prevTrack()
end
nextBtn.Activated:Connect(skipNext)
miniNext.Activated:Connect(skipNext)
prevBtn.Activated:Connect(skipPrev)
miniPrev.Activated:Connect(skipPrev)

function toggleShuffle()
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
		if view.kind == "radio" or view.kind == "public" or view.kind == "activity" then
			setView({ kind = "pl", index = state.last })
		end
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
smooth = 0
RunService.RenderStepped:Connect(function(dt)
	if uiMode == "hidden" then return end

	local playing = sound ~= nil and sound.IsPlaying
	local loud = playing and math.clamp(sound.PlaybackLoudness / 350, 0, 1) or 0
	smooth += (loud - smooth) * math.min(1, dt * 12)

	-- кроссфейд: запускаем следующий трек за N секунд до конца
	if playing and not radioOn and state.crossfade > 0 and repeatMode ~= 2 and xfFired ~= playToken
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
-- v4: РАДИО/DJ, ПУБЛИЧНЫЕ ПЛЕЙЛИСТЫ, ЛЕНТА, JSON, БЭКАПЫ, СВОЯ ПЕСНЯ
-- Каждый блок в do...end, а общие функции — глобальные: так мы не упираемся
-- в лимит Luau в 200 локальных переменных на скрипт.
------------------------------------------------------------
radioOn, radioIsDJ, radioState, radioKey = false, false, nil, nil

do
	local function newPanel()
		return new("Frame", {
			Position = UDim2.fromOffset(0, 130), Size = UDim2.new(1, 0, 1, -130),
			BackgroundTransparency = 1, Visible = false, Parent = content,
		})
	end
	panelRadio, panelPublic, panelActivity = newPanel(), newPanel(), newPanel()
end

-- общие хелперы -----------------------------------------------------
function pill(parent, text, x, y, w, h, green)
	h = h or 36
	local b = new("TextButton", {
		Text = text, Font = FONT_B, TextSize = 13, tc = green and "ink" or "text", bg = green and "green" or "chip",
		Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h), AutoButtonColor = false, Parent = parent,
	})
	corner(b, h / 2)
	bouncy(b, 1.04)
	return b
end

function makeScroll(parent, x, y, w, h)
	local s = new("ScrollingFrame", {
		Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h), BackgroundTransparency = 1,
		BorderSizePixel = 0, ScrollBarThickness = 4, ScrollBarImageColor3 = C.elev2,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = parent,
	})
	new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = s })
	return s
end

function clearRows(s)
	for _, c in ipairs(s:GetChildren()) do
		if c:IsA("GuiButton") then c:Destroy() end
	end
end

-- строка списка: заголовок, подпись и кнопки справа { {"текст", fn}, ... }
function makeRow(parent, order, title, sub, btns)
	local r = new("TextButton", {
		Text = "", Size = UDim2.new(1, -8, 0, 48), BackgroundColor3 = C.hover, BackgroundTransparency = 1,
		AutoButtonColor = false, LayoutOrder = order, Parent = parent,
	})
	corner(r, 8)
	local textW = -14 - #btns * 38 - 12
	label({
		Text = title, Font = FONT_B, TextSize = 14, TextColor3 = C.text, TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(14, 6), Size = UDim2.new(1, textW, 0, 20), Parent = r,
	})
	label({
		Text = sub, TextSize = 12, TextColor3 = C.sub, TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(14, 26), Size = UDim2.new(1, textW, 0, 16), Parent = r,
	})
	for i, b in ipairs(btns) do
		local btn = new("TextButton", {
			Text = b[1], Font = FONT_B, TextSize = 16, TextColor3 = C.sub, BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8 - (#btns - i) * 38, 0.5, 0),
			Size = UDim2.fromOffset(34, 34), Parent = r,
		})
		bouncy(btn, 1.12)
		btn.Activated:Connect(b[2])
	end
	r.MouseEnter:Connect(function() tween(r, 0.12, { BackgroundTransparency = 0 }) end)
	r.MouseLeave:Connect(function() tween(r, 0.12, { BackgroundTransparency = 1 }) end)
	return r
end

function makePopup(w, h, title)
	local p = new("CanvasGroup", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(w, h),
		bg = "elev", Visible = false, ZIndex = 50, Parent = main,
	})
	corner(p, 14)
	label({
		Text = title, Font = FONT_B, TextSize = 17,
		Position = UDim2.fromOffset(20, 14), Size = UDim2.new(1, -40, 0, 24), Parent = p,
	})
	extraPopups[#extraPopups + 1] = p
	return p
end

function inputBox(parent, x, y, w, placeholder)
	local f = new("Frame", { Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, 36), bg = "bg", Parent = parent })
	corner(f, 18)
	return new("TextBox", {
		Text = "", PlaceholderText = placeholder, PlaceholderColor3 = rgb(140, 140, 150), ClearTextOnFocus = false,
		Font = FONT, TextSize = 13, tc = "text", TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -28, 1, 0), Parent = f,
	})
end

function openPopup(p)
	closePopups()
	showPopup(p)
	blocker.Visible = true
end

function cleanStr(v, n)
	if type(v) ~= "string" then return nil end
	v = v:gsub("%c", "")
	v = cutText(v, n)
	v = v:match("^%s*(.-)%s*$")
	return v ~= "" and v or nil
end

-- подтянуть названия для списка треков (без названий)
function hydrateList(tracks)
	task.spawn(function()
		for _, t in ipairs(tracks) do
			if not t.title or not t.artist then
				fetchInfo(t)
				refreshTexts()
				task.wait(0.15)
			end
		end
		markDirty()
	end)
end

------------------------------------------------------------
-- 25 + 27. РАДИО / DJ-РЕЖИМ / VOTE SKIP
------------------------------------------------------------
do
	local P = panelRadio
	local rSound
	local token = 0

	local statusLbl = label({
		Text = "", Font = FONT_B, TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(28, 16), Size = UDim2.new(1, -230, 0, 22), Parent = P,
	})
	local djBtn = pill(P, "Стать DJ", 460, 10, 152, 32, true)
	local listenBtn = pill(P, "▶  Слушать радио", 28, 54, 190, 40, true)
	local skipBtn = pill(P, "⏭  Пропуск", 226, 54, 240, 40, false)
	local pauseBtn = pill(P, "⏸  Пауза", 474, 54, 138, 40, false)

	label({
		Text = "СЕЙЧАС В ЭФИРЕ", Font = FONT_B, TextSize = 11, tc = "sub",
		Position = UDim2.fromOffset(28, 108), Size = UDim2.fromOffset(300, 16), Parent = P,
	})
	local nowTitle = label({
		Text = "—", Font = FONT_X, TextSize = 20, TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(28, 126), Size = UDim2.new(1, -56, 0, 26), Parent = P,
	})
	local nowArtist = label({
		Text = "", TextSize = 13, tc = "sub", TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(28, 154), Size = UDim2.new(1, -56, 0, 18), Parent = P,
	})
	local nowTime = label({
		Text = "", TextSize = 12, tc = "sub",
		Position = UDim2.fromOffset(28, 174), Size = UDim2.new(1, -56, 0, 16), Parent = P,
	})
	label({
		Text = "ДАЛЕЕ В ОЧЕРЕДИ", Font = FONT_B, TextSize = 11, tc = "sub",
		Position = UDim2.fromOffset(28, 200), Size = UDim2.fromOffset(300, 16), Parent = P,
	})
	local queueList = makeScroll(P, 20, 222, 600, 148)
	local emptyQ = label({
		Text = "Очередь пуста.\nDJ: ПКМ по треку или плейлисту → «На радио». Остальные голосуют за пропуск.",
		TextSize = 12, tc = "sub", TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(60, 250), Size = UDim2.new(1, -120, 0, 50), Parent = P,
	})

	function radioRender()
		local st = radioState
		local isDJ = st ~= nil and st.dj ~= nil and st.dj.uid == player.UserId
		radioIsDJ = isDJ
		if st and st.dj then
			statusLbl.Text = "DJ: " .. st.dj.name .. (isDJ and " (ты)" or "")
		else
			statusLbl.Text = "DJ не назначен — любой может стать DJ"
		end
		djBtn.Visible = isDJ or not (st and st.dj)
		djBtn.Text = isDJ and "Покинуть DJ" or "Стать DJ"
		listenBtn.Text = radioOn and "■  Выключить радио" or "▶  Слушать радио"
		if isDJ then
			skipBtn.Text = "⏭  Пропустить"
		elseif st and st.track then
			skipBtn.Text = string.format("⏭  Голос за пропуск (%d/%d)", st.votes or 0, st.needed or 1)
		else
			skipBtn.Text = "⏭  Пропуск"
		end
		pauseBtn.Visible = isDJ
		pauseBtn.Text = (st and st.paused) and "▶  Продолжить" or "⏸  Пауза"
		local tr = st and st.track
		nowTitle.Text = tr and (tr.title or ("Трек " .. tr.id)) or "Ничего не играет"
		nowArtist.Text = tr and (tr.artist or "") or ""
		clearRows(queueList)
		local up = st and st.upcoming or {}
		emptyQ.Visible = #up == 0
		for i, q in ipairs(up) do
			makeRow(queueList, i, q.title or ("Трек " .. q.id), q.artist or "", {
				{ "+", function() openAddMenu(q, pointer()) end },
			})
		end
		renderBanner()
	end

	function radioHandleState(st)
		radioState = st
		radioRender()
		if not radioOn or not st then return end
		local tr = st.track
		local key = (tr and st.startedAt > 0) and (tr.id .. ":" .. st.startedAt) or nil

		if key ~= radioKey then
			radioKey = key
			token += 1
			local my = token
			if rSound then
				rSound:Destroy()
				rSound = nil
			end
			sound = nil
			current = tr and { id = tr.id, title = tr.title, artist = tr.artist } or nil
			if not key then
				updateNowPlaying()
				return
			end
			local s = Instance.new("Sound")
			s.SoundId = "rbxassetid://" .. tr.id
			s.SoundGroup = group
			s.Volume = 1
			s.Parent = SoundService
			rSound = s
			sound = s
			s:GetPropertyChangedSignal("IsPlaying"):Connect(function()
				if s == sound then updatePlayState() end
			end)
			updateNowPlaying()
			task.spawn(function()
				local t0 = os.clock()
				while my == token and not s.IsLoaded and os.clock() - t0 < 10 do
					task.wait(0.1)
				end
				if my ~= token then return end
				if not s.IsLoaded then
					notify("Радио: трек не загрузился")
					return
				end
				local cur = radioState
				local pos = cur.paused and (cur.pos or 0) or (workspace:GetServerTimeNow() - cur.startedAt)
				s.TimePosition = math.clamp(pos, 0, math.max(0, s.TimeLength - 0.1))
				if not cur.paused then s:Play() end
			end)
		elseif rSound and rSound.IsLoaded then
			-- тот же трек: синхронизируем паузу
			if st.paused and rSound.IsPlaying then
				rSound:Pause()
				rSound.TimePosition = st.pos or rSound.TimePosition
			elseif not st.paused and not rSound.IsPlaying then
				rSound.TimePosition = math.clamp(workspace:GetServerTimeNow() - st.startedAt, 0, math.max(0, rSound.TimeLength - 0.1))
				rSound:Play()
			end
		end
	end

	function radioSetOn(v)
		if v == radioOn then return end
		if not remRadio then
			notify("Радио недоступно: нет серверной части")
			return
		end
		radioOn = v
		radioKey = nil
		token += 1
		if v then
			playToken += 1 -- гасим обычное воспроизведение
			if sound then sound:Destroy() end
			sound, current, queue, qi = nil, nil, {}, 0
			remRadio:FireServer("join")
			radioHandleState(radioState)
		else
			remRadio:FireServer("leave")
			if rSound then
				rSound:Destroy()
				rSound = nil
			end
			sound, current = nil, nil
		end
		updateNowPlaying()
		radioRender()
	end

	function radioPlay(tracks, index)
		if not remRadio then
			notify("Радио недоступно: нет серверной части")
			return
		end
		if not radioIsDJ then
			notify("Сначала стань DJ: вкладка «Радио / DJ»")
			return
		end
		local ids = {}
		for _, t in ipairs(tracks) do
			if #ids >= 100 then break end
			ids[#ids + 1] = { id = t.id }
		end
		if #ids == 0 then return end
		remRadio:FireServer("play", { tracks = ids, index = index or 1 })
		if not radioOn then radioSetOn(true) end
		notify("📻 Отправлено на радио")
	end

	function radioEnqueue(track)
		if not remRadio then
			notify("Радио недоступно: нет серверной части")
			return
		end
		if not radioIsDJ then
			notify("Сначала стань DJ: вкладка «Радио / DJ»")
			return
		end
		remRadio:FireServer("enqueue", { id = track.id })
		notify("📻 Добавлено в очередь радио")
	end

	function radioVoteSkip()
		if not remRadio then return end
		if not radioState or not radioState.track then
			notify("Радио сейчас ничего не играет")
			return
		end
		remRadio:FireServer("skip")
		if not radioIsDJ then notify("Голос за пропуск отправлен") end
	end

	djBtn.Activated:Connect(function()
		if not remRadio then
			notify("Радио недоступно: нет серверной части")
			return
		end
		if radioIsDJ then
			remRadio:FireServer("release")
		else
			remRadio:FireServer("claim")
			radioSetOn(true)
		end
	end)
	listenBtn.Activated:Connect(function() radioSetOn(not radioOn) end)
	skipBtn.Activated:Connect(function()
		if not radioOn then
			notify("Сначала включи радио")
		else
			radioVoteSkip()
		end
	end)
	pauseBtn.Activated:Connect(function()
		if remRadio then remRadio:FireServer((radioState and radioState.paused) and "resume" or "pause") end
	end)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.5 then return end
		acc = 0
		local st = radioState
		if panelRadio.Visible then
			if st and st.track and st.startedAt > 0 then
				local pos = st.paused and (st.pos or 0) or (workspace:GetServerTimeNow() - st.startedAt)
				nowTime.Text = formatTime(math.clamp(pos, 0, st.duration)) .. " / " .. formatTime(st.duration)
			else
				nowTime.Text = st and st.track and "Загрузка…" or ""
			end
		end
		-- коррекция рассинхронизации
		if radioOn and rSound and rSound.IsPlaying and st and st.startedAt > 0 and not st.paused then
			local expected = workspace:GetServerTimeNow() - st.startedAt
			if math.abs(rSound.TimePosition - expected) > 1.5 and expected < rSound.TimeLength then
				rSound.TimePosition = expected
			end
		end
	end)
end

------------------------------------------------------------
-- 26. ПУБЛИЧНЫЕ ПЛЕЙЛИСТЫ
------------------------------------------------------------
do
	local P = panelPublic
	local mode = "recent"
	local PUB_ERR = {
		cooldown = "Подожди около 30 секунд",
		limit = "Максимум 5 публичных плейлистов",
		empty = "Плейлист пуст",
		filter = "Название не прошло фильтр Roblox",
		not_owner = "Нет прав на этот код",
	}

	local codeFrame = new("Frame", { Position = UDim2.fromOffset(28, 12), Size = UDim2.fromOffset(190, 32), bg = "elev", Parent = P })
	corner(codeFrame, 16)
	local codeBox = new("TextBox", {
		Text = "", PlaceholderText = "Код (6 символов)", PlaceholderColor3 = rgb(140, 140, 150),
		ClearTextOnFocus = false, MaxTextLength = 12, Font = FONT, TextSize = 13, tc = "text",
		TextXAlignment = Enum.TextXAlignment.Left, BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -28, 1, 0), Parent = codeFrame,
	})
	local openBtn = pill(P, "Открыть", 226, 12, 100, 32, true)
	local tabRecent = pill(P, "Недавние", 392, 12, 100, 32)
	local tabMine = pill(P, "Мои", 500, 12, 112, 32)
	local listScroll = makeScroll(P, 20, 56, 600, 312)
	local info = label({
		Text = "", TextSize = 13, tc = "sub", TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(60, 120), Size = UDim2.new(1, -120, 0, 60), Parent = P,
	})

	local function tracksFromIds(ids)
		local tr = {}
		for _, id in ipairs(ids) do tr[#tr + 1] = { id = id } end
		return tr
	end

	local function fetchPublic(code, cb)
		if not remPublic then
			notify("Публичные плейлисты недоступны: нет серверной части")
			return
		end
		task.spawn(function()
			local ok, res = pcall(function() return remPublic:InvokeServer("get", code) end)
			if ok and res and res.ok then
				cb(res.pl)
			else
				notify("Плейлист не найден")
			end
		end)
	end

	local function preview(code)
		fetchPublic(code, function(pl)
			local tr = tracksFromIds(pl.ids)
			hydrateList(tr)
			playFromList(tr, 1)
			notify("▶ " .. pl.name)
		end)
	end

	local function saveToMine(code)
		fetchPublic(code, function(pl)
			if #state.playlists >= MAX_PLAYLISTS then
				notify("Максимум плейлистов: " .. MAX_PLAYLISTS)
				return
			end
			local tr = tracksFromIds(pl.ids)
			table.insert(state.playlists, { name = cutText(pl.name, 24), tracks = tr })
			hydrateList(tr)
			markDirty()
			renderSidebar()
			notify("Сохранено в твои плейлисты: " .. pl.name)
		end)
	end

	local function unpublishCode(code)
		if not remPublic then return end
		task.spawn(function()
			local ok, res = pcall(function() return remPublic:InvokeServer("unpublish", code) end)
			if ok and res and res.ok then
				for _, p in ipairs(state.playlists) do
					if p.code == code then p.code = nil end
				end
				markDirty()
				renderBanner()
				notify("Снято с публикации")
				publicRefresh()
			else
				notify("Не удалось снять с публикации")
			end
		end)
	end

	local function entryRow(i, e)
		local btns
		if mode == "mine" then
			btns = { { "▶", function() preview(e.code) end }, { "✕", function() unpublishCode(e.code) end } }
		else
			btns = { { "▶", function() preview(e.code) end }, { "＋", function() saveToMine(e.code) end } }
		end
		return makeRow(listScroll, i, e.name or "?", string.format("от %s · %d треков · код %s", e.owner or "?", e.count or 0, e.code), btns)
	end

	function publicRefresh()
		clearRows(listScroll)
		chipActive(tabRecent, mode == "recent")
		chipActive(tabMine, mode == "mine")
		if not remPublic then
			info.Text = "Нужен серверный скрипт для публичных плейлистов"
			info.Visible = true
			return
		end
		info.Text = "Загрузка…"
		info.Visible = true
		local my = mode
		task.spawn(function()
			local ok, res = pcall(function() return remPublic:InvokeServer(my == "mine" and "mine" or "list") end)
			if my ~= mode then return end
			clearRows(listScroll)
			if not (ok and res and res.ok) then
				info.Text = "Не удалось загрузить"
				return
			end
			local list = res.list or {}
			info.Visible = #list == 0
			info.Text = my == "mine" and "Ты ещё ничего не публиковал: ПКМ по плейлисту → «Опубликовать»"
				or "Пока нет публичных плейлистов"
			for i, e in ipairs(list) do entryRow(i + 1, e) end
		end)
	end

	tabRecent.Activated:Connect(function() mode = "recent"; publicRefresh() end)
	tabMine.Activated:Connect(function() mode = "mine"; publicRefresh() end)
	openBtn.Activated:Connect(function()
		local code = codeBox.Text:upper():gsub("[^A-Z0-9]", "")
		if #code ~= 6 then
			notify("Код состоит из 6 символов")
			return
		end
		fetchPublic(code, function(pl)
			info.Visible = false
			for _, c in ipairs(listScroll:GetChildren()) do
				if c:IsA("GuiButton") and c.LayoutOrder == 0 then c:Destroy() end
			end
			makeRow(listScroll, 0, "★ " .. pl.name, "найден по коду " .. code .. " · " .. #pl.ids .. " треков", {
				{ "▶", function() preview(code) end },
				{ "＋", function() saveToMine(code) end },
			})
		end)
	end)

	function publishPlaylist(i)
		local p = state.playlists[i]
		if not p or #p.tracks == 0 then
			notify("Плейлист пуст")
			return
		end
		if not remPublic then
			notify("Публикация недоступна: нет серверной части")
			return
		end
		task.spawn(function()
			local ids = {}
			for _, t in ipairs(p.tracks) do ids[#ids + 1] = t.id end
			local ok, res = pcall(function()
				return remPublic:InvokeServer(p.code and "update" or "publish", { name = p.name, ids = ids, code = p.code })
			end)
			if ok and res and res.ok then
				p.code = res.code
				markDirty()
				renderBanner()
				notify("🌐 Код плейлиста: " .. res.code)
			else
				notify(PUB_ERR[ok and res and res.err or ""] or "Не удалось опубликовать")
			end
		end)
	end

	function unpublishPlaylist(i)
		local p = state.playlists[i]
		if p and p.code then unpublishCode(p.code) end
	end
end

------------------------------------------------------------
-- 24. ЛЕНТА «ЧТО СЛУШАЮТ ИГРОКИ НА СЕРВЕРЕ»
------------------------------------------------------------
do
	local P = panelActivity
	local lastByUid, log, activeCount = {}, {}, 0
	local lastSent, sendPending = nil, false

	label({
		Text = "Показывать другим, что я слушаю", TextSize = 13,
		Position = UDim2.fromOffset(28, 18), Size = UDim2.fromOffset(280, 22), Parent = P,
	})
	local sw2 = new("TextButton", {
		Text = "", bg = "chip", Position = UDim2.fromOffset(310, 18), Size = UDim2.fromOffset(44, 22),
		AutoButtonColor = false, Parent = P,
	})
	corner(sw2, 11)
	local knob2 = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = rgb(255, 255, 255), BorderSizePixel = 0, Parent = sw2,
	})
	corner(knob2, 8)
	local countLbl = label({
		Text = "", Font = FONT_B, TextSize = 12, tc = "sub", TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -260, 0, 18), Size = UDim2.fromOffset(232, 22), Parent = P,
	})
	local feed = makeScroll(P, 20, 56, 600, 312)
	local empty = label({
		Text = "Пока никто не делится музыкой. Включи трек — и ты появишься в ленте.",
		TextSize = 13, tc = "sub", TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(60, 120), Size = UDim2.new(1, -120, 0, 60), Parent = P,
	})

	local function ago(t)
		local d = os.time() - t
		if d < 60 then return "только что" end
		if d < 3600 then return math.floor(d / 60) .. " мин назад" end
		return math.floor(d / 3600) .. " ч назад"
	end

	function updateShareSwitch(instant)
		local on = state.shareNow
		local t = instant and 0 or 0.2
		tween(sw2, t, { BackgroundColor3 = on and C.green or C.chip })
		tween(knob2, t, { Position = on and UDim2.new(1, -19, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) }, Enum.EasingStyle.Back)
	end

	function activityRender()
		if not panelActivity.Visible then return end
		clearRows(feed)
		countLbl.Text = activeCount .. " слушают сейчас"
		empty.Visible = #log == 0
		for i, e in ipairs(log) do
			local own = e.uid == player.UserId
			local tr = { id = e.id, title = e.title, artist = e.artist }
			makeRow(feed, i, e.name .. (own and " (ты)" or ""),
				"♪ " .. (e.title or "?") .. " — " .. (e.artist or "?") .. "  ·  " .. ago(e.t), {
					{ "▶", function() playFromList({ tr }, 1) end },
					{ "+", function() openAddMenu(tr, pointer()) end },
				})
		end
	end

	function activityHandle(l)
		if type(l) ~= "table" then return end
		local seen = {}
		for _, e in ipairs(l) do
			seen[e.uid] = true
			if lastByUid[e.uid] ~= e.id then
				lastByUid[e.uid] = e.id
				table.insert(log, 1, { uid = e.uid, name = e.name, id = e.id, title = e.title, artist = e.artist, t = os.time() })
				if #log > 40 then table.remove(log) end
			end
		end
		for uid in pairs(lastByUid) do
			if not seen[uid] then lastByUid[uid] = nil end
		end
		activeCount = #l
		activityRender()
	end

	-- отправляем текущий трек на сервер (с задержкой, чтобы не спамить)
	function reportNow()
		if not remNow or sendPending then return end
		sendPending = true
		task.delay(1.6, function()
			sendPending = false
			local id = (state.shareNow and current) and current.id or nil
			if id ~= lastSent then
				lastSent = id
				remNow:FireServer(id)
			end
		end)
	end

	function toggleShare()
		state.shareNow = not state.shareNow
		updateShareSwitch(false)
		markDirty()
		reportNow()
		notify(state.shareNow and "Другие видят, что ты слушаешь" or "Ты скрыл, что слушаешь")
	end
	sw2.Activated:Connect(toggleShare)
	updateShareSwitch(true)
end

------------------------------------------------------------
-- 21. ИМПОРТ / ЭКСПОРТ ПЛЕЙЛИСТОВ (JSON)
------------------------------------------------------------
do
	local HttpService = game:GetService("HttpService")
	jsonPopup = makePopup(560, 440, "Импорт / экспорт плейлистов (JSON)")
	label({
		Text = "Экспорт покажет JSON в поле ниже — скопируй его (на ПК: Ctrl+A, затем Ctrl+C). Для импорта вставь JSON и нажми «Импорт»: плейлисты добавятся к твоим. На телефоне проще делиться через публичный код 🌐.",
		TextSize = 11, tc = "sub", TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(20, 44), Size = UDim2.new(1, -40, 0, 44), Parent = jsonPopup,
	})
	local boxFrame = new("Frame", { Position = UDim2.fromOffset(20, 94), Size = UDim2.fromOffset(520, 270), bg = "bg", Parent = jsonPopup })
	corner(boxFrame, 10)
	local box = new("TextBox", {
		Text = "", PlaceholderText = "{ ... }", PlaceholderColor3 = rgb(140, 140, 150), ClearTextOnFocus = false,
		MultiLine = true, TextWrapped = true, Font = Enum.Font.Code, TextSize = 12, tc = "text",
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 8), Size = UDim2.new(1, -20, 1, -16), Parent = boxFrame,
	})
	local exportCur = pill(jsonPopup, "Экспорт: текущий", 20, 384, 150, 38)
	local exportAll = pill(jsonPopup, "Экспорт: все", 178, 384, 130, 38)
	local importBtn = pill(jsonPopup, "Импорт", 316, 384, 100, 38, true)
	local closeB = pill(jsonPopup, "Закрыть", 436, 384, 104, 38)

	local function pack(p)
		local tr = {}
		for _, t in ipairs(p.tracks) do tr[#tr + 1] = { id = t.id, title = t.title, artist = t.artist } end
		return { name = p.name, tracks = tr }
	end

	exportCur.Activated:Connect(function()
		local p
		if view.kind == "liked" then
			p = { name = "Любимое", tracks = state.liked }
		elseif view.kind == "pl" then
			p = state.playlists[view.index]
		else
			p = state.playlists[state.last]
		end
		if not p then return end
		box.Text = HttpService:JSONEncode({ app = "SpotifyPlayer", v = 1, playlists = { pack(p) } })
		notify("JSON готов — скопируй его из поля")
	end)
	exportAll.Activated:Connect(function()
		local all = {}
		for _, p in ipairs(state.playlists) do all[#all + 1] = pack(p) end
		box.Text = HttpService:JSONEncode({ app = "SpotifyPlayer", v = 1, playlists = all })
		notify("JSON готов — скопируй его из поля")
	end)

	importBtn.Activated:Connect(function()
		local ok, data = pcall(function() return HttpService:JSONDecode(box.Text) end)
		if not ok or type(data) ~= "table" then
			notify("Не удалось прочитать JSON")
			return
		end
		local lists = {}
		if type(data.playlists) == "table" then
			lists = data.playlists
		elseif type(data.tracks) == "table" then
			lists = { data }
		elseif #data > 0 then
			lists = { { name = "Импорт", tracks = data } }
		end
		local added, total = 0, 0
		for _, pl in ipairs(lists) do
			if type(pl) == "table" and #state.playlists < MAX_PLAYLISTS and type(pl.tracks) == "table" then
				local tr = {}
				for _, t in ipairs(pl.tracks) do
					local isT = type(t) == "table"
					local id = isT and tonumber(t.id) or tonumber(t)
					if id and id >= 1 and id % 1 == 0 and id < 1e15 and #tr < MAX_TRACKS then
						tr[#tr + 1] = {
							id = id,
							title = isT and cleanStr(t.title, 60) or nil,
							artist = isT and cleanStr(t.artist, 40) or nil,
						}
					end
				end
				if #tr > 0 then
					table.insert(state.playlists, { name = cleanStr(pl.name, 24) or "Импорт", tracks = tr })
					added += 1
					total += #tr
				end
			end
		end
		if added == 0 then
			notify("В JSON не найдено треков")
			return
		end
		markDirty()
		renderSidebar()
		hydrateTitles()
		notify("Импортировано: " .. added .. " плейл., " .. total .. " треков")
		closePopups()
	end)
	closeB.Activated:Connect(closePopups)
end

------------------------------------------------------------
-- 22. РЕЗЕРВНЫЕ КОПИИ (3 последние)
------------------------------------------------------------
do
	backupPopup = makePopup(460, 380, "Резервные копии (последние 3)")
	label({
		Text = "Копия делается автоматически при сохранении (не чаще раза в 15 минут). Перед восстановлением текущая версия тоже сохраняется.",
		TextSize = 11, tc = "sub", TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(20, 44), Size = UDim2.new(1, -40, 0, 34), Parent = backupPopup,
	})
	local list = makeScroll(backupPopup, 16, 86, 428, 240)
	local info = label({
		Text = "", TextSize = 13, tc = "sub", TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(40, 150), Size = UDim2.new(1, -80, 0, 40), Parent = backupPopup,
	})
	local closeB = pill(backupPopup, "Закрыть", 340, 334, 104, 34)
	closeB.Activated:Connect(closePopups)

	local function doRestore(idx)
		if not remBackups then return end
		task.spawn(function()
			local ok, res = pcall(function() return remBackups:InvokeServer("restore", idx) end)
			if ok and res and res.ok and res.data then
				applyData(res.data)
				renderSidebar()
				renderBanner()
				renderList()
				notify("Резервная копия восстановлена")
			else
				notify("Не удалось восстановить" .. ((ok and res and res.err == "cooldown") and " (подожди 10 секунд)" or ""))
			end
		end)
	end

	local function refresh()
		clearRows(list)
		if not remBackups then
			info.Text = "Нужен серверный скрипт"
			info.Visible = true
			return
		end
		info.Text = "Загрузка…"
		info.Visible = true
		task.spawn(function()
			local ok, res = pcall(function() return remBackups:InvokeServer("list") end)
			clearRows(list)
			if not (ok and res and res.ok) then
				info.Text = "Не удалось загрузить"
				return
			end
			local l = res.list or {}
			info.Visible = #l == 0
			info.Text = "Резервных копий пока нет"
			for n, b in ipairs(l) do
				local idx = b.i
				makeRow(list, n, os.date("!%d.%m %H:%M", b.t) .. " UTC",
					string.format("%d плейл. · %d треков · %d в любимом", b.playlists, b.tracks, b.liked), {
						{ "⟲", function()
							openMenu("Восстановить эту копию?", {
								{ text = "Да, восстановить", color = C.red, fn = function() doRestore(idx) end },
								{ text = "Отмена", fn = function() end },
							}, pointer())
						end },
					})
			end
		end)
	end

	function openBackups()
		openPopup(backupPopup)
		refresh()
	end
end

------------------------------------------------------------
-- 28. ДОБАВИТЬ СВОЮ ПЕСНЮ
------------------------------------------------------------
do
	songPopup = makePopup(440, 400, "Добавить свою песню")
	label({
		Text = "Загрузи аудио в Creator Hub, скопируй ID или ссылку и вставь сюда. Название и исполнителя можно задать свои.",
		TextSize = 11, tc = "sub", TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(20, 46), Size = UDim2.new(1, -40, 0, 36), Parent = songPopup,
	})
	local idBox = inputBox(songPopup, 20, 90, 400, "ID или ссылка (rbxassetid://…, create.roblox.com/…)")
	local nameBox = inputBox(songPopup, 20, 136, 400, "Название (необязательно)")
	local artistBox = inputBox(songPopup, 20, 182, 400, "Исполнитель (необязательно)")
	local status = label({
		Text = "", TextSize = 12, tc = "sub", TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(20, 228), Size = UDim2.new(1, -40, 0, 54), Parent = songPopup,
	})
	local targetLbl = label({
		Text = "", Font = FONT_B, TextSize = 12,
		Position = UDim2.fromOffset(20, 288), Size = UDim2.new(1, -40, 0, 18), Parent = songPopup,
	})
	local checkBtn = pill(songPopup, "Проверить", 20, 334, 120, 38)
	local songAdd = pill(songPopup, "Добавить", 148, 334, 120, 38, true)
	local closeB = pill(songPopup, "Закрыть", 316, 334, 104, 38)
	closeB.Activated:Connect(closePopups)

	local function extractId(text)
		local s = text or ""
		local id = s:match("rbxassetid://(%d+)") or s:match("asset/(%d+)") or s:match("library/(%d+)")
			or s:match("[?&]id=(%d+)") or s:match("(%d+)")
		id = tonumber(id)
		if id and id >= 1 and id < 1e15 then return id end
		return nil
	end

	local function fail(msg)
		status.Text = msg
		status.TextColor3 = C.red
	end

	local function check(id)
		status.Text = "Проверяю…"
		status.TextColor3 = C.sub
		local ok, info = pcall(function() return MarketplaceService:GetProductInfo(id, Enum.InfoType.Asset) end)
		if not ok or not info then
			fail("Не удалось получить информацию об ассете. Проверь ID.")
			return nil
		end
		if info.AssetTypeId ~= 3 then
			fail("Это не аудио (тип ассета " .. tostring(info.AssetTypeId) .. ").")
			return nil
		end
		status.Text = "✓ Аудио: " .. cutText(tostring(info.Name), 50) .. " — "
			.. cutText(info.Creator and tostring(info.Creator.Name) or "?", 30)
			.. ". Если трек не играет, выдай этой игре доступ к аудио в Creator Hub."
		status.TextColor3 = C.green
		nameBox.PlaceholderText = cutText(tostring(info.Name), 50)
		return info
	end

	checkBtn.Activated:Connect(function()
		local id = extractId(idBox.Text)
		if id then check(id) else fail("Не вижу ID — вставь число или ссылку.") end
	end)

	songAdd.Activated:Connect(function()
		local id = extractId(idBox.Text)
		if not id then
			fail("Не вижу ID — вставь число или ссылку.")
			return
		end
		if not check(id) then return end
		local p = state.playlists[(view.kind == "pl") and view.index or state.last]
		if not p then return end
		for _, t in ipairs(p.tracks) do
			if t.id == id then
				fail("Этот трек уже есть в плейлисте.")
				return
			end
		end
		if #p.tracks >= MAX_TRACKS then
			fail("Плейлист заполнен.")
			return
		end
		local track = { id = id, title = cleanStr(nameBox.Text, 60), artist = cleanStr(artistBox.Text, 40) }
		table.insert(p.tracks, track)
		task.spawn(function()
			fetchInfo(track) -- заполнит только то, что ты не задал сам
			refreshTexts()
			markDirty()
		end)
		markDirty()
		renderList()
		renderBanner()
		notify("🎵 Добавлено в «" .. p.name .. "»")
		idBox.Text, nameBox.Text, artistBox.Text = "", "", ""
		closePopups()
	end)

	function openSong()
		local p = state.playlists[(view.kind == "pl") and view.index or state.last]
		targetLbl.Text = "Добавится в плейлист: " .. (p and p.name or "—")
		status.Text = ""
		openPopup(songPopup)
	end
end

------------------------------------------------------------
-- КНОПКА «⚙ ЕЩЁ», НАВИГАЦИЯ, ХУКИ
------------------------------------------------------------
moreBtn.Activated:Connect(function()
	openMenu("Ещё", {
		{ text = "🎵  Добавить свою песню…", fn = function() openSong() end },
		{ text = "⇅  Импорт / экспорт JSON…", fn = function() openPopup(jsonPopup) end },
		{ text = "🛟  Резервные копии…", fn = function() openBackups() end },
		{
			text = state.shareNow and "👁  Скрыть, что я слушаю" or "👁  Показывать, что я слушаю",
			fn = function() toggleShare() end,
		},
	}, moreBtn.AbsolutePosition)
end)

navRadio.Activated:Connect(function() setView({ kind = "radio" }) end)
navPub.Activated:Connect(function() setView({ kind = "public" }) end)
navAct.Activated:Connect(function() setView({ kind = "activity" }) end)

-- какие вкладки — «панели» (скрывают тулбар и список треков)
function onViewChanged(v)
	local k = v.kind
	local isPanel = k == "radio" or k == "public" or k == "activity"
	panelRadio.Visible = k == "radio"
	panelPublic.Visible = k == "public"
	panelActivity.Visible = k == "activity"
	toolbar.Visible = not isPanel
	listWrap.Visible = not isPanel
	hdrNum.Visible = not isPanel
	hdrName.Visible = not isPanel
	hdrLine.Visible = not isPanel
	if k == "radio" then
		radioRender()
	elseif k == "public" then
		publicRefresh()
	elseif k == "activity" then
		activityRender()
	end
end

function bannerSubText()
	if view.kind == "top" and topState == "loading" then return "Загрузка…" end
	if view.kind == "radio" then return radioOn and "Ты слушаешь радио" or "Радио выключено" end
	if view.kind == "public" then return "Открывай плейлисты других игроков по коду" end
	if view.kind == "activity" then return "Обновляется в реальном времени" end
	local s = pluralTracks(#currentList())
	if view.kind == "pl" then
		local p = state.playlists[view.index]
		if p and p.code then s = s .. "  ·  публичный код " .. p.code end
	end
	return s
end

-- подключаем события от сервера (вызывается после WaitForChild всех remotes)
function connectRemotes()
	remRadioState.OnClientEvent:Connect(function(st) radioHandleState(st) end)
	remNowFeed.OnClientEvent:Connect(function(list) activityHandle(list) end)
	remSync.OnClientEvent:Connect(function(data)
		if dirtyFlag or type(data) ~= "table" then return end
		local v = view
		applyData(data)
		if v.kind ~= "pl" then view = v end
		renderSidebar()
		renderBanner()
		renderList()
		notify("Данные синхронизированы с другого сервера")
	end)
	remNow:FireServer("sync")
	remRadio:FireServer("state")
	reportNow()
end

------------------------------------------------------------
-- ЗАГРУЗКА СОХРАНЕНИЯ
------------------------------------------------------------
function applyData(d)
	if type(d.playlists) == "table" and #d.playlists > 0 then state.playlists = d.playlists end
	if type(d.liked) == "table" then state.liked = d.liked end
	state.volume = tonumber(d.volume) or state.volume
	state.bass = tonumber(d.bass) or state.bass
	state.reverb = d.reverb == true
	state.last = tonumber(d.last) or 1
	state.crossfade = tonumber(d.crossfade) or 0
	if type(d.binds) == "table" then state.binds = d.binds end
	if type(d.markers) == "table" then state.markers = d.markers end
	state.shareNow = d.shareNow ~= false
	if not state.playlists[state.last] then state.last = 1 end
	view = { kind = "pl", index = state.last }

	volume.Set(state.volume)
	bassSlider.Set(state.bass)
	bassVal.Text = math.floor(state.bass * 100 + 0.5) .. "%"
	setCrossfade(state.crossfade)
	applyAudio()
	applyTheme(d.theme == "light" and "light" or "dark", true)
	if updateShareSwitch then updateShareSwitch(true) end
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
	remBackups = remotes:WaitForChild("Backups")
	remSync = remotes:WaitForChild("Sync")
	remNow = remotes:WaitForChild("NowPlaying")
	remNowFeed = remotes:WaitForChild("NowFeed")
	remRadio = remotes:WaitForChild("RadioAction")
	remRadioState = remotes:WaitForChild("RadioState")
	remPublic = remotes:WaitForChild("Public")
	connectRemotes()

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

end, function(e)
	return tostring(e) .. "\n" .. debug.traceback()
end)
if not __ok then
	warn("[SpotifyPlayer] Ошибка запуска:", __err)
	pcall(function()
		local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
		local g = Instance.new("ScreenGui")
		g.Name = "SpotifyPlayerError"
		g.ResetOnSpawn = false
		g.DisplayOrder = 999
		local l = Instance.new("TextLabel")
		l.Size = UDim2.new(0.9, 0, 0.5, 0)
		l.Position = UDim2.new(0.05, 0, 0.05, 0)
		l.BackgroundColor3 = Color3.fromRGB(40, 0, 0)
		l.TextColor3 = Color3.fromRGB(255, 200, 200)
		l.TextWrapped = true
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.TextYAlignment = Enum.TextYAlignment.Top
		l.TextSize = 14
		l.Font = Enum.Font.Code
		l.Text = "Музыкальный плеер не запустился. Сделай скриншот этого текста:\n\n" .. tostring(__err)
		l.Parent = g
		g.Parent = pg
	end)
end
