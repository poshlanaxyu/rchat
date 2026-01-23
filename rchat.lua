script_name("RdugChat")
script_version("2301202605")

-- ¡»¡À»Œ“≈ »
local se = require 'lib.samp.events'
local socket = require 'socket'
local cjson = require 'cjson'
local encoding = require("encoding")
encoding.default = 'CP1251'
local u8 = encoding.UTF8

--  ŒÕ‘»√”–¿÷»ﬂ
local CFG = {
    HOST = "127.0.0.1", -- “‚ÓÈ IP
    PORT = 18310,
    SECRET_KEY = "14londonpidor88", -- “ÓÚ ÊÂ ÍÎ˛˜, ˜ÚÓ Ì‡ ÒÂ‚ÂÂ
    GPS_INTERVAL = 0.2,    
    PING_INTERVAL = 2.0,   
    RECONNECT_DELAY = 3.0,
    DEBUG = false
}

-- —Œ—“ŒﬂÕ»≈
local State = {
    tcp = nil,
    connected = false,
    last_ping = 0,
    last_gps = 0,
    last_reconnect = 0,
    gps_enabled = true,
    gps_store = {},    
    attackers = {},   
}

-- ===  –»œ“Œ√–¿‘»ﬂ (RC4 + Base64) ===

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

-- === ”“»À»“€ ===

local Utils = {}
function Utils.getPlayerId() return select(2, sampGetPlayerIdByCharHandle(PLAYER_PED)) end
function Utils.getPlayerNick() return sampGetPlayerNickname(Utils.getPlayerId()) end
function Utils.argb_to_rgba(argb) return bit.bor(bit.lshift(bit.band(bit.rshift(argb, 16), 0xFF), 24), bit.lshift(bit.band(bit.rshift(argb, 8), 0xFF), 16), bit.lshift(bit.band(argb, 0xFF), 8), bit.band(bit.rshift(argb, 24), 0xFF)) end
function Utils.hex_color(int_color) return string.format('%06X', bit.band(int_color, 0xFFFFFF)) end

-- === —≈“‹ ===

local Network = {}

function Network.connect()
    if State.tcp then State.tcp:close() end
    State.tcp = socket.tcp()
    State.tcp:settimeout(0.1)
    
    local res, err = State.tcp:connect(CFG.HOST, CFG.PORT)
    if res then
        State.tcp:settimeout(0) 
        State.connected = true
        sampAddChatMessage("[RDUG] {00FF00}œÓ‰ÍÎ˛˜ÂÌÓ Í ÒÂ‚ÂÛ!", -1)
        Network.send("login", {
            version = thisScript().version,
            nick = Utils.getPlayerNick(),
            id = Utils.getPlayerId(),
            rank = "User"
        })
    end
end

function Network.disconnect()
    if State.connected then sampAddChatMessage("[RDUG] {FF0000}—ÓÂ‰ËÌÂÌËÂ ‡ÁÓ‚‡ÌÓ.", -1) end
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
    
    -- ÿËÙÓ‚‡ÌËÂ
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
        
        -- –‡Ò¯ËÙÓ‚Í‡
        local encrypted = dec_base64(line)
        local json_str = rc4(CFG.SECRET_KEY, encrypted)
        
        local status, msg = pcall(cjson.decode, json_str)
        if status then PacketHandlers.dispatch(msg) end
    end
end

-- === Œ¡–¿¡Œ“◊» » œ¿ ≈“Œ¬ ===

PacketHandlers = {}
function PacketHandlers.dispatch(msg) if PacketHandlers[msg.type] then PacketHandlers[msg.type](msg) end end

PacketHandlers['system'] = function(msg) sampAddChatMessage("[SERVER] " .. u8:decode(msg.text), 0xAAAAAA) end
PacketHandlers['chat'] = function(msg)
    local color = msg.color or 0xFBEC5D
    sampAddChatMessage(string.format("%s[%d]: %s", msg.nick, msg.id, u8:decode(msg.text)), color)
end
PacketHandlers['online'] = function(msg)
    sampAddChatMessage("--- RDUG Online: " .. #msg.clients .. " ---", 0x33CCFF)
    for _, client in ipairs(msg.clients) do
        local paused = sampIsPlayerPaused(client.id) and " {FF0000}[AFK]" or ""
        sampAddChatMessage(string.format("- %s [%d] %s", client.nick, client.id, paused), 0xFFFFFF)
    end
end
PacketHandlers['gps'] = function(msg)
    if not State.gps_enabled then return end
    for _, data in ipairs(msg.data) do GameLogic.updateBlip(data) end
end
PacketHandlers['attacker'] = function(msg)
    if msg.is_done then
        State.attackers[msg.id] = nil
    else
        State.attackers[msg.id] = { nick = msg.nick, time = os.time() + 120 }
        lua_thread.create(GameLogic.flashPlayer, msg.id)
    end
end

-- === »√–Œ¬¿ﬂ ÀŒ√» ¿ ===

GameLogic = {}
function GameLogic.updateBlip(data)
    local pid = data.id
    if data.disabled then
        if State.gps_store[pid] then removeBlip(State.gps_store[pid].blip); State.gps_store[pid] = nil end
        return
    end
    if State.gps_store[pid] then
        setBlipCoordinates(State.gps_store[pid].blip, data.x, data.y, data.z)
    else
        local blip = addSpriteBlipForCoord(data.x, data.y, data.z, 0)
        changeBlipScale(blip, 2)
        changeBlipColour(blip, data.color)
        State.gps_store[pid] = { blip = blip }
    end
end
function GameLogic.clearGPS()
    for id, entry in pairs(State.gps_store) do removeBlip(entry.blip) end
    State.gps_store = {}
end
function GameLogic.flashPlayer(id)
    local start = os.clock()
    local handle_found, handle = sampGetCharHandleBySampPlayerId(id)
    if not handle_found then return end
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

-- === SAMP EVENTS ===
function se.onPlayerQuit(id)
    if State.gps_store[id] then removeBlip(State.gps_store[id].blip); State.gps_store[id] = nil end
    State.attackers[id] = nil
end
function se.onShowTextDraw(id, data)
    if data.text:find("HA ãAC HAåAá ÖÇPOK ~r~") then
        local raw_name = data.text:match("HA ãAC HAåAá ÖÇPOK ~r~([^~]+)")
        if raw_name then
            for i = 0, 1000 do
                if sampIsPlayerConnected(i) then
                    local name = sampGetPlayerNickname(i)
                    if name:find(raw_name) then
                        local color = sampGetPlayerColor(i)
                        Network.send("attacker", { id = i, nick = name, color = Utils.hex_color(color), is_done = false })
                        Network.send("chat", { text = "{FF6666}!!! Œ·ÓÓÌ‡ ÔÓ {"..Utils.hex_color(color).."}"..name.." ["..i.."]" })
                        break
                    end
                end
            end
        end
    end
end

-- === MAIN ===
function main()
    if not isSampLoaded() then return end
    while not isSampAvailable() do wait(100) end
    
    sampRegisterChatCommand("u", function(arg) if #arg > 0 then Network.send("chat", { text = arg }) end end)
    sampRegisterChatCommand("ugps", function() State.gps_enabled = not State.gps_enabled; if not State.gps_enabled then GameLogic.clearGPS() end; sampAddChatMessage(State.gps_enabled and "GPS ON" or "GPS OFF", -1) end)
    sampRegisterChatCommand("ulist", function() Network.send("online") end)
    
    Network.connect()
    while true do
        wait(0)
        local now = os.clock()
        if State.connected then
            Network.receive()
            if now - State.last_ping > CFG.PING_INTERVAL then Network.send("ping"); State.last_ping = now end
            if now - State.last_gps > CFG.GPS_INTERVAL then
                local res, x, y, z = getCharCoordinates(PLAYER_PED)
                if res and getActiveInterior() == 0 then
                    Network.send("gps", { x=x, y=y, z=z, color=Utils.argb_to_rgba(sampGetPlayerColor(Utils.getPlayerId())), disabled=isPlayerDead(PLAYER_PED) })
                end
                State.last_gps = now
            end
        else
            if now - State.last_reconnect > CFG.RECONNECT_DELAY then Network.connect(); State.last_reconnect = now end
        end
    end
end
function onScriptTerminate(scr, quit) if scr == thisScript() then if State.tcp then State.tcp:close() end; GameLogic.clearGPS() end end