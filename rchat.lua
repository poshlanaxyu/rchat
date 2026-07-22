script_name("RdugChat")
script_version("2207202601")
script_properties("work-in-pause")

-- БИБЛИОТЕКИ
local se = require 'lib.samp.events'
local socket = require 'socket'
local cjson = require 'cjson'
local encoding = require("encoding")
local raknet = require 'samp.raknet'
local lmemory, memory = pcall(require, 'memory')
encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- КОНФИГУРАЦИЯ
local CFG = {
    HOST = "chat.rdug.bet",
    PORT = 18310,
    SECRET_KEY = "TEMPKEY1488228_PATOM_POMENYAEM",
    GPS_INTERVAL = 0.1,    
    PING_INTERVAL = 1.0,   
    RECONNECT_DELAY = 1.0,
    WLOW_INTERVAL = 10.0,
    DEBUG = false,
    RECEIVE_CHUNK = 4096,
    RECEIVE_CHUNKS_PER_TICK = 32,
    RECEIVE_PACKETS_PER_TICK = 64,
    MAX_RX_BUFFER = 262144,
    MAP_PING_DEFAULT_DURATION = 30,
    MAP_PING_MAX_DURATION = 300,
    MAP_PING_BLINK_TIME = 6,
    MAP_PING_BLINK_INTERVAL = 350,
    MAP_PING_SPRITE = 19,
    MAP_PING_SCALE = 3,
    MAP_PING_COLOR = 0xFFDD00FF
}

-- СОСТОЯНИЕ
local State = {
    tcp = nil,
    connected = false,
    rx_buffer = "",
    last_ping = 0,
    last_gps = 0,
    last_wlow = 0,
    last_reconnect = 0,
    gps_enabled = true,
    gps_send = false,
    gps_store = {},    
    map_pings = {},
    attackers = {},   
    is_z = false,
    send_wlow = false,
    fraps_mode = false,
    player_sync = false,
    ulists = false
}

function EXPORTS.getState() return State end

-- === КРИПТОГРАФИЯ (RC4 + Base64) ===

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
function enc_base64(data)
    return ((data:gsub('.', function(x) 
        local r,b='',x:byte()
        for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
        return r;
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c=0
        for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
        return b64chars:sub(c+1,c+1)
    end)..({ '', '==', '=' })[#data%3+1])
end

function dec_base64(data)
    data = string.gsub(data, '[^'..b64chars..'=]', '')
    return (data:gsub('.', function(x)
        if (x == '=') then return '' end
        local r,f='',b64chars:find(x)-1
        for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
        return r;
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if (#x ~= 8) then return '' end
        local c=0
        for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
        return string.char(c)
    end))
end

function rc4(key, data)
    local S = {}
    for i = 0, 255 do S[i] = i end
    local j = 0
    for i = 0, 255 do
        j = (j + S[i] + string.byte(key, (i % #key) + 1)) % 256
        S[i], S[j] = S[j], S[i]
    end
    local i, j = 0, 0
    local res = {}
    for k = 1, #data do
        i = (i + 1) % 256
        j = (j + S[i]) % 256
        S[i], S[j] = S[j], S[i]
        local byte = string.byte(data, k)
        local K = S[(S[i] + S[j]) % 256]
        table.insert(res, string.char(bit.bxor(byte, K)))
    end
    return table.concat(res)
end

-- === УТИЛИТЫ ===

local Utils = {}

function Utils.isPauseActive()
    if type(isPauseMenuActive) == "function" then return isPauseMenuActive() end
    if type(isGamePaused) == "function" then return isGamePaused() end
    return false
end

function Utils.generateUUID()
    math.randomseed(os.time() + os.clock() * 1000)
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function (c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end

function Utils.cc()
    memory.fill(sampGetChatInfoPtr() + 306, 0x0, 25200)
    memory.write(sampGetChatInfoPtr() + 306, 25562, 4, 0x0)
    memory.write(sampGetChatInfoPtr() + 0x63DA, 1, 1)
end

function Utils.getUUID()
    local path = getWorkingDirectory() .. "\\config\\uuid.json"
    if not doesDirectoryExist(getWorkingDirectory() .. "\\config") then
        createDirectory(getWorkingDirectory() .. "\\config")
    end
    if doesFileExist(path) then
        local f = io.open(path, "r")
        if f then
            local content = f:read("*a")
            f:close()
            local status, data = pcall(cjson.decode, content)
            if status and data.uuid then return data.uuid end
        end
    end
    local new_uuid = Utils.generateUUID()
    local f = io.open(path, "w")
    if f then
        f:write(cjson.encode({uuid = new_uuid}))
        f:close()
    end
    return new_uuid
end

function Utils.getPlayerId() return select(2, sampGetPlayerIdByCharHandle(PLAYER_PED)) end
function Utils.getPlayerNick() return sampGetPlayerNickname(Utils.getPlayerId()) end
function Utils.argb_to_rgba(argb) return bit.bor(bit.lshift(bit.band(bit.rshift(argb, 16), 0xFF), 24), bit.lshift(bit.band(bit.rshift(argb, 8), 0xFF), 16), bit.lshift(bit.band(argb, 0xFF), 8), bit.band(bit.rshift(argb, 24), 0xFF)) end
function Utils.hex_color(int_color) return string.format('%06X', bit.band(int_color, 0xFFFFFF)) end
function Utils.getMapMarkerCoordinates()
    if type(getTargetBlipCoordinates) ~= "function" then return false end

    local found, x, y, z = getTargetBlipCoordinates()
    if found == true and x and y then return true, x, y, z or 0 end
    if type(found) == "number" and type(x) == "number" then return true, found, x, y or 0 end

    return false
end

function Utils.getAllSampPlayers()
    players = {}
    for i = 0, sampGetMaxPlayerId() do
        if sampIsPlayerConnected(i) or i == myId then
            players[i] = sampGetPlayerNickname(i)
        end
    end
    return players
end
function Utils.sendUpdateScoresPings()
    local bs = raknetNewBitStream()
    raknetSendRpc(raknet.RPC.UPDATESCORESPINGSIPS, bs)
    raknetDeleteBitStream(bs)
end

-- === СЕТЬ ===

local Network = {}

function Network.resolveHost()
    if not socket.dns then return CFG.HOST end

    local err = nil
    if socket.dns.getaddrinfo then
        local addrinfo, getaddrinfo_err = socket.dns.getaddrinfo(CFG.HOST)
        err = getaddrinfo_err
        if addrinfo then
            for _, alt in ipairs(addrinfo) do
                if alt.family == "inet" and alt.addr then
                    return alt.addr
                end
            end
        end
    end

    if socket.dns.toip then
        local ip, toip_err = socket.dns.toip(CFG.HOST)
        if ip then return ip end
        err = err or toip_err
    end

    return CFG.HOST, err
end

function Network.connect()
    if State.tcp then State.tcp:close() end
    State.connected = false
    State.rx_buffer = ""

    local host, resolve_err = Network.resolveHost()
    if CFG.DEBUG and resolve_err then
        print("DNS warning for " .. CFG.HOST .. ": " .. tostring(resolve_err))
    end

    State.tcp = socket.tcp()
    State.tcp:settimeout(0.2)
    
    local res, err = State.tcp:connect(host, CFG.PORT)
    if res then
        State.tcp:settimeout(0) 
        State.connected = true
        sampAddChatMessage("RdugChat: Подключено!", 0x00FF00)
        if not CFG.DEBUG then
            Network.send("login", {
                version = thisScript().version,
                nick = Utils.getPlayerNick(),
                id = Utils.getPlayerId(),
                uuid = Utils.getUUID(),
            })
        end
    else
        print("Connection failed to " .. tostring(host) .. ":" .. tostring(CFG.PORT) .. ": " .. tostring(err))
        State.tcp:close()
        State.tcp = nil
    end
end

function Network.disconnect()
    if State.connected then sampAddChatMessage("RdugChat: Потеря соединения...", 0xFF0000) end
    State.connected = false
    State.rx_buffer = ""
    State.player_sync = false
    if State.tcp then State.tcp:close() end
    State.tcp = nil
    GameLogic.clearGPS()
    GameLogic.clearMapPings()
end

function Network.send(type, data)
    if not State.connected or not State.tcp then return end
    data = data or {}
    data.type = type
    
    local status, json_str = pcall(cjson.encode, data)
    if not status then return end
    
    local encrypted = rc4(CFG.SECRET_KEY, json_str)
    local b64 = enc_base64(encrypted)
    
    local _, err = State.tcp:send(b64 .. "\n")
    if err then
        if err == "closed" or err == "broken pipe" then Network.disconnect() end
    end
end

function Network.processLine(line)
    line = line:gsub("\r$", "")
    if line == "" then return end

    local encrypted = dec_base64(line)
    local json_str = rc4(CFG.SECRET_KEY, encrypted)

    local status, msg = pcall(cjson.decode, json_str)
    if status and type(msg) == "table" then PacketHandlers.dispatch(msg) end
end

function Network.receive()
    if not State.connected or not State.tcp then return end

    local chunks_read = 0
    local packets_processed = 0

    while chunks_read < CFG.RECEIVE_CHUNKS_PER_TICK and packets_processed < CFG.RECEIVE_PACKETS_PER_TICK do
        local chunk, err, partial = State.tcp:receive(CFG.RECEIVE_CHUNK)
        local data = chunk or partial

        if data and #data > 0 then
            chunks_read = chunks_read + 1
            State.rx_buffer = State.rx_buffer .. data

            if #State.rx_buffer > CFG.MAX_RX_BUFFER then
                Network.disconnect()
                return
            end

            while packets_processed < CFG.RECEIVE_PACKETS_PER_TICK do
                local newline_pos = State.rx_buffer:find("\n", 1, true)
                if not newline_pos then break end

                local line = State.rx_buffer:sub(1, newline_pos - 1)
                State.rx_buffer = State.rx_buffer:sub(newline_pos + 1)
                packets_processed = packets_processed + 1
                Network.processLine(line)
            end
        end

        if err == "closed" then
            Network.disconnect()
            break
        end

        if not chunk then
            break
        end
    end
end

-- === ОБРАБОТЧИКИ ПАКЕТОВ ===

PacketHandlers = {}
function PacketHandlers.dispatch(msg) if PacketHandlers[msg.type] then PacketHandlers[msg.type](msg) end end

PacketHandlers['system'] = function(msg) 
    if State.fraps_mode then return end
    sampAddChatMessage(u8:decode(msg.text), 0xfbec5d) 
end

PacketHandlers['chat'] = function(msg)
    local hexColor = msg.color or 0xfbec5d
    if State.fraps_mode then return end
    sampAddChatMessage(u8:decode(msg.text), hexColor)
end

PacketHandlers['online'] = function(msg)
    sampAddChatMessage("Члены подвального чата онлайн, всего {D8A903}" .. #msg.clients .. "{FFFFFF} человек:", 0xFFFFFF)
    for _, v in ipairs(msg.clients) do
        local afk = ""
        local wlow = ""
        local lics = ""
        local room_info = ""
        if sampIsPlayerPaused(v.id) then afk = " {34C924}< AFK >" end
        if v.wlow.us > 0 or v.wlow.af > 0 or v.wlow.rc > 0 or v.wlow.int > 0 then wlow = string.format(" {FF2222}В РОЗЫСКЕ:", v.wlow.us) end
        for st, wlow_num in pairs(v.wlow) do
            if wlow_num > 0 then
                wlow = wlow .. string.format(" %s: %d", string.upper(st), wlow_num)
            end
        end

        for lic, lic_val in pairs(v.stats.lics) do
            if lic_val then
                if lics == "" then
                    lics = string.upper(lic)
                else
                    lics = string.format("%s, %s", lics, string.upper(lic))
                end
            end
        end
        if State.ulists and (msg.access_level or 1) > 1 then
            room_info = string.format(" {AAAAAA}ROOM:%s LVL:%s", v.room or 1, v.access_level or 1)
        end
        sampAddChatMessage(string.format("Ник: {abcdef}%s - %s {ffffff}Ранг:{fbec5d} %s%s%s%s", v.nick, v.id, u8:decode(v.rank), afk, wlow, room_info), 0xFFFFFF)
        if v.stats.level > 0 and State.ulists then
            sampAddChatMessage(string.format("    Уровень: {fbec5d}%s {FFFFFF}Лицензии: {fbec5d}%s",v.stats.level, lics), 0xFFFFFF)
        end
    end
end

PacketHandlers['admins'] = function(msg)
    sampAddChatMessage("Админы онлайн, всего {D8A903}" .. #msg.admins .. "{FFFFFF} пидорасов:", 0xFFFFFF)
    for _, v in ipairs(msg.admins) do
        sampAddChatMessage(string.format("[%s] {FFFFFF}%s", v.id, v.nick), 0xfbec5d)
    end
end

PacketHandlers['gps'] = function(msg)
    if not State.gps_enabled then return end
    for _, data in ipairs(msg.data) do GameLogic.updateBlip(data) end
end

PacketHandlers['map_ping_clear'] = function(msg)
    GameLogic.clearMapPings()
end

PacketHandlers['map_ping'] = function(msg)
    if not State.fraps_mode and msg.text then sampAddChatMessage(u8:decode(msg.text), 0xfbec5d) end
    GameLogic.addMapPing(msg)
end

PacketHandlers['attacker'] = function(msg)
    if State.attackers[msg.id] == nil then
        if not msg.is_done then
            State.attackers[msg.id] = { nick = msg.nick, time = os.time() + 120 }
            lua_thread.create(GameLogic.flashPlayer, msg.id)
        end
    else
        if msg.is_done then
            State.attackers[msg.id] = nil
        else
            State.attackers[msg.id] = { nick = msg.nick, time = os.time() + 120 }
        end
    end
end

-- === ИГРОВАЯ ЛОГИКА ===

GameLogic = {}
function GameLogic.updateBlip(data)
    local pid = data.id
    if not pid then return end -- FIX CRASH
    if pid == Utils.getPlayerId() then return end
    
    if data.disabled then
        if State.gps_store[pid] then removeBlip(State.gps_store[pid].blip); State.gps_store[pid] = nil end
        return
    end
    if State.gps_store[pid] then
        setBlipCoordinates(State.gps_store[pid].blip, data.x, data.y, data.z)
        changeBlipColour(State.gps_store[pid].blip, data.color or 0xFFFFFF)
        State.gps_store[pid].pos = { x = data.x, y = data.y, z = data.z }
    else
        local blip = addSpriteBlipForCoord(data.x, data.y, data.z, 0)
        changeBlipScale(blip, 2)
        changeBlipColour(blip, data.color or 0xFFFFFF)
        State.gps_store[pid] = { blip = blip, pos = { x = data.x, y = data.y, z = data.z } }
    end
end
function GameLogic.clearGPS()
    for id, entry in pairs(State.gps_store) do removeBlip(entry.blip) end
    State.gps_store = {}
end

function GameLogic.createMapPingBlip(entry)
    local blip = addSpriteBlipForCoord(entry.x, entry.y, entry.z, CFG.MAP_PING_SPRITE)
    changeBlipScale(blip, CFG.MAP_PING_SCALE)
    changeBlipColour(blip, CFG.MAP_PING_COLOR)
    return blip
end

function GameLogic.removeMapPing(id)
    local entry = State.map_pings[id]
    if not entry then return end
    if entry.blip then removeBlip(entry.blip) end
    State.map_pings[id] = nil
end

function GameLogic.clearMapPings()
    local ids = {}
    for id, _ in pairs(State.map_pings) do table.insert(ids, id) end
    for _, id in ipairs(ids) do GameLogic.removeMapPing(id) end
end

function GameLogic.flashMapPing(id)
    while State.map_pings[id] do
        local entry = State.map_pings[id]
        local now = os.clock()
        if now >= entry.expires_at then break end

        if now < entry.blink_until then
            if entry.blip then
                removeBlip(entry.blip)
                entry.blip = nil
            else
                entry.blip = GameLogic.createMapPingBlip(entry)
            end
            wait(CFG.MAP_PING_BLINK_INTERVAL)
        else
            if not entry.blip then entry.blip = GameLogic.createMapPingBlip(entry) end
            wait(250)
        end
    end

    GameLogic.removeMapPing(id)
end

function GameLogic.addMapPing(msg)
    local x = tonumber(msg.x)
    local y = tonumber(msg.y)
    local z = tonumber(msg.z) or 0
    if not x or not y then return end

    local duration = tonumber(msg.duration) or CFG.MAP_PING_DEFAULT_DURATION
    duration = math.max(1, math.min(math.floor(duration), CFG.MAP_PING_MAX_DURATION))

    local id = tostring(msg.ping_id or ((msg.nick or "ping") .. ":" .. tostring(os.clock())))
    GameLogic.clearMapPings()

    local now = os.clock()
    State.map_pings[id] = {
        x = x,
        y = y,
        z = z,
        expires_at = now + duration,
        blink_until = now + math.min(CFG.MAP_PING_BLINK_TIME, duration),
        blip = nil
    }
    State.map_pings[id].blip = GameLogic.createMapPingBlip(State.map_pings[id])
    lua_thread.create(GameLogic.flashMapPing, id)
end

function GameLogic.flashPlayer(id)
    local start = os.clock()
    local orig_color = Utils.argb_to_rgba(sampGetPlayerColor(id))
    while State.attackers[id] and (os.clock() - start < 120) do
        Network.setPlayerColor(id, 0xFF0000FF)
        wait(300)
        Network.setPlayerColor(id, orig_color)
        wait(300)
    end
    Network.setPlayerColor(id, orig_color)
end

function Network.setPlayerColor(id, col)
    local bs = raknetNewBitStream(); raknetBitStreamWriteInt16(bs, id); raknetBitStreamWriteInt32(bs, col)
    raknetEmulRpcReceiveBitStream(72, bs); raknetDeleteBitStream(bs)
end

function se.onServerMessage(color, message)
	if message:find("{FF4500} начал ваше задержание.") or message:find("{FF4500} начала ваше задержание.") then
		State.is_z = true
		Network.send("chat", { text = u8(message), nick = Utils.getPlayerNick(), id = Utils.getPlayerId() })
	end

	if message:find("{FF4500} остановила ваше задержание.") or message:find("{FF4500} остановил ваше задержание.") or message:find("Вас не успели задержать сотрудники ПО. В ближайшие {33aa33}") then
		State.is_z = false
		Network.send("chat", { text = u8(message), nick = Utils.getPlayerNick(), id = Utils.getPlayerId() })
	end

    if State.send_wlow and message:find("Вы не находитесь в розыске.") then
        Network.send("wlow", { us = 0, af = 0, rc = 0, int = 0 })
        State.send_wlow = false
        return false
    end

    if (State.send_wlow or State.send_stats) and message:find("Unknown command.") then
        return false
    end
end

-- === SAMP EVENTS ===
function se.onPlayerQuit(id)
    if State.gps_store[id] then removeBlip(State.gps_store[id].blip); State.gps_store[id] = nil end
    if State.attackers[id] ~= nil then
        local color = sampGetPlayerColor(id)
        Network.send("attacker", { id = id, nick = sampGetPlayerNickname(id), color = Utils.hex_color(color), is_done = true })
    end
end

function se.onPlayerDeath(id)
    if id == Utils.getPlayerId() then
        State.attackers = {} 
        State.is_z = false
        return true
    end

    if State.attackers[id] ~= nil then
        local color = sampGetPlayerColor(id)
        Network.send("attacker", { id = id, nick = sampGetPlayerNickname(id), color = Utils.hex_color(color), is_done = true })
    end
end

function se.onShowTextDraw(id, data)
    -- Ignore Z
	local ignore_colors = {-14869219, 1711276160, 1724658432, 1721303040, 1728013824, 1711276287, 1714631679}
	if State.is_z then
		for k, v in pairs(ignore_colors) do
			if data.boxColor == v and data.backgroundColor == -16777216 then
				return false
			end
		end
	end

    if data.text:find("HA ‹AC HAЊA‡ …‚POK ~r~") then

        local attacker_name = data.text:gsub(".*HA ‹AC HAЊA‡ …‚POK ~r~",""):gsub("~w~.~n~.*","")
        for id, name in pairs(Utils.getAllSampPlayers()) do
            if string.lower(name):find(string.lower(attacker_name)) then
                if not State.attackers[id] then
                    local color = sampGetPlayerColor(id)
                    State.attackers[id] = { nick = name, time = os.time() + 120 }
                    lua_thread.create(GameLogic.flashPlayer, id)
                    Network.send("attacker", { id = id, nick = name, color = Utils.hex_color(color), is_done = false })
                    Network.send("chat", { text = u8("{FF6666}!!! Оборона по {"..Utils.hex_color(color).."}"..name.." ["..id.."]"), nick = Utils.getPlayerNick(), id = Utils.getPlayerId() })
                end
            end
        end
    end
end

function se.onShowDialog(id, style, title, btn1, btn2, text)
    if State.send_wlow and title:find("Архив розыска") then
        Network.send("wlow", { us = 0, af = 0, rc = 0, int = 0 })
        State.send_wlow = false
		sampSendDialogResponse(id, 1, -1, -1)
		return false
    end

	if State.send_wlow and title:find("{34C924}Информация о вашем розыске") then
        local stars_us = 0
        local stars_af = 0
        local stars_rc = 0
        local stars_int = 0

        for country, count in text:gmatch("Розыск по (%u+) %- (%d+)") do
            local amount = tonumber(count)
            
            if country == "US" then
                stars_us = stars_us + amount
            elseif country == "AF" then
                stars_af = stars_af + amount
            elseif country == "RC" then
                stars_rc = stars_rc + amount
            end
        end

        for count in text:gmatch("Международный розыск %- (%d+)") do
            stars_int = stars_int + tonumber(count)
        end

        Network.send("wlow", { us = stars_us, af = stars_af, rc = stars_rc, int = stars_int })
        State.send_wlow = false
		sampSendDialogResponse(id, 1, -1, -1)
		return false
	end

    if State.send_stats and title:find("Ваши документы") then
        local stats = {
            lics = {
                car = false,
                gun = false,
                air = false,
                boat = false
            },
            level = sampGetPlayerScore(select(2, sampGetPlayerIdByCharHandle(PLAYER_PED)))
        }

        if text:find("Водительское") then
            stats.lics.car = true
        end
        if text:find("Лицензия на оружие") then
            stats.lics.gun = true
        end
        if text:find("Лицензия пилота") then
            stats.lics.air = true
        end
        if text:find("катером") then
            stats.lics.boat = true
        end

        Network.send("stats", stats)
        State.send_stats = false

        sampSendDialogResponse(id, 1, -1, -1)
        return false
    end
end

-- === MAIN ===
function main()
    if not isSampLoaded() then return end
    while not isSampAvailable() do wait(100) end
    
    sampAddChatMessage("RdugChat: /u [текст].", 0xAAAAAA)
    
    sampRegisterChatCommand("u", function(arg)
        if #arg > 0 then
            Network.send("chat", { text = u8(arg), nick = Utils.getPlayerNick(), id = Utils.getPlayerId() }) else sampAddChatMessage("Используйте: /u [текст]", -1)
        end
    end)
    sampRegisterChatCommand("ugps", function() 
        State.gps_enabled = not State.gps_enabled
        if not State.gps_enabled then GameLogic.clearGPS() end
        sampAddChatMessage(State.gps_enabled and "[РДУГ] {FFFFFF}GPS включен!" or "[РДУГ] {FFFFFF}GPS отключен!", 0xfbec5d)
    end)
    sampRegisterChatCommand("ulist", function() State.ulists = false Network.send("online", { all = false }) end)
    sampRegisterChatCommand("ulists", function() State.ulists = true Network.send("online", { all = true }) end)
    sampRegisterChatCommand("uroom", function(arg)
        local room = arg:match("^(%d+)$")
        if room then
            Network.send("room", { room = tonumber(room) })
        end
    end)
    sampRegisterChatCommand("uping", function(arg)
        local clean_arg = tostring(arg or ""):match("^%s*(.-)%s*$")
        local duration = CFG.MAP_PING_DEFAULT_DURATION

        if clean_arg ~= "" then
            duration = tonumber(clean_arg)
            if not duration then
                sampAddChatMessage("Используйте: /uping [секунды]", -1)
                return
            end
            duration = math.floor(duration)
        end

        if duration < 1 or duration > CFG.MAP_PING_MAX_DURATION then
            sampAddChatMessage("Время метки: 1-" .. CFG.MAP_PING_MAX_DURATION .. " секунд.", -1)
            return
        end

        local ok, x, y, z = Utils.getMapMarkerCoordinates()
        if not ok then
            sampAddChatMessage("Поставьте метку на карте ПКМ и используйте /uping [секунды]", -1)
            return
        end

        Network.send("map_ping", { x = x, y = y, z = z or 0, duration = duration })
    end)

    sampRegisterChatCommand("admins", function() Network.send("admins") end)
    sampRegisterChatCommand("uadmins", function() Network.send("admins") end)
    
    sampRegisterChatCommand("urank", function(arg)
        local id, rank = arg:match("(%d+)%s+(.+)")
        if id and rank then
            Network.send("admin_cmd", { cmd = "urank", target = id, value = u8(rank) })
        else
            sampAddChatMessage("Используйте: /urank [id] [rank]", -1)
        end
    end)

    sampRegisterChatCommand("ulevel", function(arg)
        local id, level = arg:match("(%S+)%s+(%d+)")
        if id and level then
            Network.send("admin_cmd", { cmd = "ulevel", target = id, value = tonumber(level) })
        else
            sampAddChatMessage("Используйте: /ulevel [id/full_name/uuid] [level]", -1)
        end
    end)

    sampRegisterChatCommand("uban", function(arg)
        if #arg > 0 then
            Network.send("admin_cmd", { cmd = "uban", target = arg })
        else
            sampAddChatMessage("Используйте: /uban [id/full_name/uuid]", -1)
        end
    end)

    sampRegisterChatCommand("ufind", function(arg)
        local id = tonumber(arg)
        if id then
            Network.send("find", { id = id })
        else
            sampAddChatMessage("Используйте: /ufind [id]", -1)
        end
    end)

    sampRegisterChatCommand("unban", function(arg)
        if #arg > 0 then
            Network.send("admin_cmd", { cmd = "unban", target = arg })
        else
            sampAddChatMessage("Используйте: /unban [id/full_name/uuid]", -1)
        end
    end)

    sampRegisterChatCommand("ufraps", function() 
        State.fraps_mode = not State.fraps_mode
        if State.fraps_mode then
            Network.send("chat", { text = u8("{FFFFFF}Fraps on"), nick = Utils.getPlayerNick(), id = Utils.getPlayerId() })
            Utils.cc()
        else
            Network.send("chat", { text = u8("{FFFFFF}Fraps off"), nick = Utils.getPlayerNick(), id = Utils.getPlayerId() })
            sampAddChatMessage("[РДУГ] {FFFFFF}Фрапсмод отключен!", 0xfbec5d)
        end
    end)

    sampRegisterChatCommand("fraps", function() 
        State.fraps_mode = not State.fraps_mode
        if State.fraps_mode then
            Network.send("chat", { text = u8("{FFFFFF}Fraps on"), nick = Utils.getPlayerNick(), id = Utils.getPlayerId() })
            Utils.cc()
        else
            Network.send("chat", { text = u8("{FFFFFF}Fraps off"), nick = Utils.getPlayerNick(), id = Utils.getPlayerId() })
            sampAddChatMessage("[РДУГ] {FFFFFF}Фрапсмод отключен!", 0xfbec5d)
        end
    end)
    
    Network.connect()
    while true do
        wait(0)
        local now = os.clock()
        if State.connected then
            Network.receive()
            if now - State.last_ping > CFG.PING_INTERVAL then Network.send("ping", {id = Utils.getPlayerId(), nick = Utils.getPlayerNick()}); State.last_ping = now end

            if not Utils.isPauseActive() then
                if now - State.last_wlow > CFG.WLOW_INTERVAL then
                    if not sampIsDialogActive() then
                        State.send_wlow = true
                        sampSendChat("/wlow")
                        State.last_wlow = now
                    end
                end
                if now - State.last_gps > CFG.GPS_INTERVAL then
                    for id, _ in pairs(State.gps_store) do
                        if not sampIsPlayerConnected(id) then
                            removeBlip(State.gps_store[id].blip)
                            State.gps_store[id] = nil
                        end
                    end
                    local x, y, z = getCharCoordinates(PLAYER_PED)
                    if getActiveInterior() == 0 and State.gps_send then
                        Network.send("gps", { x=x, y=y, z=z, color=Utils.argb_to_rgba(sampGetPlayerColor(Utils.getPlayerId())), disabled=isPlayerDead(PLAYER_PED) })
                    end
                    State.last_gps = now
                end
            end
        else
            if now - State.last_reconnect > CFG.RECONNECT_DELAY then Network.connect(); State.last_reconnect = now end
        end
    end
end
function onScriptTerminate(scr, quit) if scr == thisScript() then if State.tcp then State.tcp:close() end; GameLogic.clearGPS(); GameLogic.clearMapPings() end end

-- function se.onSendSpawn()
--     if not State.send_stats then
--         Utils.sendUpdateScoresPings()
--         State.send_stats = true
--         if not sampIsDialogActive() then
--             sampSendChat("/mypass")
--         end
--     end
--     State.gps_send = true
-- end

function se.onSendPlayerSync(data)
    State.gps_send = true
    if not State.player_sync and State.connected  then
        State.player_sync = true
        if not State.send_stats then
            State.send_stats = true
            Utils.sendUpdateScoresPings()
            if not sampIsDialogActive() then
                sampSendChat("/mypass")
            end
        end
    end
end

function se.onSendVehicleSync(data)
    State.gps_send = true
    if not State.player_sync and State.connected  then
        State.player_sync = true
        if not State.send_stats then
            State.send_stats = true
            Utils.sendUpdateScoresPings()
            if not sampIsDialogActive() then
                sampSendChat("/mypass")
            end
        end
    end
end

function se.onSendPassengerSync(data)
    State.gps_send = true
    if not State.player_sync and State.connected  then
        State.player_sync = true
        if not State.send_stats then
            State.send_stats = true
            Utils.sendUpdateScoresPings()
            if not sampIsDialogActive() then
                sampSendChat("/mypass")
            end
        end
    end
end