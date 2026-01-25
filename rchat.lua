script_name("RdugChat")
script_version("2501202608")

-- БИБЛИОТЕКИ
local se = require 'lib.samp.events'
local socket = require 'socket'
local cjson = require 'cjson'
local encoding = require("encoding")
encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- КОНФИГУРАЦИЯ
local CFG = {
    HOST = "103.54.19.207",
    PORT = 18310,
    SECRET_KEY = "TEMPKEY1488228_PATOM_POMENYAEM",
    GPS_INTERVAL = 0.1,    
    PING_INTERVAL = 1.0,   
    RECONNECT_DELAY = 1.0,
    WLOW_INTERVAL = 10.0,
    DEBUG = false
}

-- СОСТОЯНИЕ
local State = {
    tcp = nil,
    connected = false,
    last_ping = 0,
    last_gps = 0,
    last_wlow = 0,
    last_reconnect = 0,
    gps_enabled = true,
    gps_store = {},    
    attackers = {},   
    is_z = false,
    send_wlow = false
}

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
function Utils.getPlayerId() return select(2, sampGetPlayerIdByCharHandle(PLAYER_PED)) end
function Utils.getPlayerNick() return sampGetPlayerNickname(Utils.getPlayerId()) end
function Utils.argb_to_rgba(argb) return bit.bor(bit.lshift(bit.band(bit.rshift(argb, 16), 0xFF), 24), bit.lshift(bit.band(bit.rshift(argb, 8), 0xFF), 16), bit.lshift(bit.band(argb, 0xFF), 8), bit.band(bit.rshift(argb, 24), 0xFF)) end
function Utils.hex_color(int_color) return string.format('%06X', bit.band(int_color, 0xFFFFFF)) end
function Utils.getAllSampPlayers()
    players = {}
    for i = 0, sampGetMaxPlayerId() do
        if sampIsPlayerConnected(i) or i == myId then
            players[i] = sampGetPlayerNickname(i)
        end
    end
    return players
end
-- === СЕТЬ ===

local Network = {}

function Network.connect()
    if State.tcp then State.tcp:close() end
    State.tcp = socket.tcp()
    State.tcp:settimeout(0.2)
    
    local res, err = State.tcp:connect(CFG.HOST, CFG.PORT)
    if res then
        State.tcp:settimeout(0) 
        State.connected = true
        sampAddChatMessage("RdugChat: Подключено!", 0x00FF00) -- ОРИГИНАЛ
        if not CFG.DEBUG then
            Network.send("login", {
                version = thisScript().version,
                nick = Utils.getPlayerNick(),
                id = Utils.getPlayerId(),
            })
        end
    else
        print("Connection failed: " .. tostring(err))
    end
end

function Network.disconnect()
    if State.connected then sampAddChatMessage("RdugChat: Потеря соединения...", 0xFF0000) end -- ОРИГИНАЛ
    State.connected = false
    if State.tcp then State.tcp:close() end
    State.tcp = nil
    GameLogic.clearGPS()
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

function Network.receive()
    if not State.connected or not State.tcp then return end
    while true do
        local line, err = State.tcp:receive('*l')
        if not line then
            if err == "closed" then Network.disconnect() end
            break
        end
        
        local encrypted = dec_base64(line)
        local json_str = rc4(CFG.SECRET_KEY, encrypted)
        
        local status, msg = pcall(cjson.decode, json_str)
        if status then PacketHandlers.dispatch(msg) end
    end
end

-- === ОБРАБОТЧИКИ ПАКЕТОВ ===

PacketHandlers = {}
function PacketHandlers.dispatch(msg) if PacketHandlers[msg.type] then PacketHandlers[msg.type](msg) end end

PacketHandlers['system'] = function(msg) 
    -- ОРИГИНАЛ: 0xfbec5d (желтоватый), а не серый
    sampAddChatMessage(u8:decode(msg.text), 0xfbec5d) 
end

PacketHandlers['chat'] = function(msg)
    -- ОРИГИНАЛ: 0xfbec5d по дефолту
    local hexColor = msg.color or 0xfbec5d
    sampAddChatMessage(string.format("%s[%s]: %s", msg.nick, msg.id, u8:decode(msg.text)), hexColor)
end

PacketHandlers['online'] = function(msg)
    -- ОРИГИНАЛ
    sampAddChatMessage("Члены подвального чата онлайн, всего {D8A903}" .. #msg.clients .. "{FFFFFF} человек:", 0xFFFFFF)
    for _, v in ipairs(msg.clients) do
        local afk = ""
        local wlow = ""
        if sampIsPlayerPaused(v.id) then afk = " {34C924}< AFK >" end
        if v.wlow.us > 0 or v.wlow.af > 0 or v.wlow.rc > 0 or v.wlow.int > 0 then wlow = string.format(" {FF2222}В РОЗЫСКЕ:", v.wlow.us) end
        for st, wlow_num in pairs(v.wlow) do
            if wlow_num > 0 then
                wlow = wlow .. string.format(" %s: %d", string.upper(st), wlow_num)
            end
        end
        sampAddChatMessage(string.format("Ник: {abcdef}%s - %s {ffffff}Ранг:{fbec5d} %s%s%s", v.nick, v.id, u8:decode(v.rank), afk, wlow), 0xFFFFFF)
    end
end

PacketHandlers['gps'] = function(msg)
    if not State.gps_enabled then return end
    for _, data in ipairs(msg.data) do GameLogic.updateBlip(data) end
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
    else
        local blip = addSpriteBlipForCoord(data.x, data.y, data.z, 0)
        changeBlipScale(blip, 2)
        changeBlipColour(blip, data.color or 0xFFFFFF)
        State.gps_store[pid] = { blip = blip }
    end
end
function GameLogic.clearGPS()
    for id, entry in pairs(State.gps_store) do removeBlip(entry.blip) end
    State.gps_store = {}
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

    -- ОРИГИНАЛЬНАЯ СТРОКА ДЛЯ ТРИНИТИ
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
end

-- === MAIN ===
function main()
    if not isSampLoaded() then return end
    while not isSampAvailable() do wait(100) end
    
    sampAddChatMessage("RdugChat: /u [текст].", 0xAAAAAA) -- ОРИГИНАЛ
    
    sampRegisterChatCommand("u", function(arg)
        if #arg > 0 then
            Network.send("chat", { text = u8(arg), nick = Utils.getPlayerNick(), id = Utils.getPlayerId() }) else sampAddChatMessage("Используйте: /u [текст]", -1)
        end
    end)
    sampRegisterChatCommand("ugps", function() 
        State.gps_enabled = not State.gps_enabled
        if not State.gps_enabled then GameLogic.clearGPS() end
        -- ОРИГИНАЛ
        sampAddChatMessage(State.gps_enabled and "[РДУГ] {FFFFFF}GPS включен!" or "[РДУГ] {FFFFFF}GPS отключен!", 0xfbec5d) 
    end)
    sampRegisterChatCommand("ulist", function() Network.send("online") end)
    
    Network.connect()
    while true do
        wait(0)
        local now = os.clock()
        if State.connected then
            Network.receive()
            if now - State.last_ping > CFG.PING_INTERVAL then Network.send("ping"); State.last_ping = now end
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
                if getActiveInterior() == 0 then
                    Network.send("gps", { x=x, y=y, z=z, color=Utils.argb_to_rgba(sampGetPlayerColor(Utils.getPlayerId())), disabled=isPlayerDead(PLAYER_PED) })
                else
                    GameLogic.clearGPS()
                end
                State.last_gps = now
            end
        else
            if now - State.last_reconnect > CFG.RECONNECT_DELAY then Network.connect(); State.last_reconnect = now end
        end
    end
end
function onScriptTerminate(scr, quit) if scr == thisScript() then if State.tcp then State.tcp:close() end; GameLogic.clearGPS() end end