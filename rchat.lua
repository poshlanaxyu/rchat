script_name("RdugChat")
script_version("2301202602")

local se = require 'lib.samp.events'

local socket = require 'socket'
local cjson = require 'cjson' -- Стандартная библиотека MoonLoader

local encoding = require("encoding")
encoding.default = 'CP1251'
u8 = encoding.UTF8

-- НАСТРОЙКИ
local HOST = "103.54.19.207"
local PORT = 18310
local RECONNECT_DELAY = 1.0 -- Секунд между попытками переподключения
local HEARTBEAT_INTERVAL = 1.0 -- Секунд между пингами

-- Переменные состояния
local client = nil
local is_connected = false
local last_reconnect_attempt = 0
local last_heartbeat = 0

function getAllSampPlayers()
    players = {}
    for i = 0, sampGetMaxPlayerId() do
        if sampIsPlayerConnected(i) or i == myId then
            players[i] = sampGetPlayerNickname(i)
        end
    end
    return players
end

function setPlayerColor(id, col)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt16(bs, id)
    raknetBitStreamWriteInt32(bs, col)
    raknetEmulRpcReceiveBitStream(72, bs)
    raknetDeleteBitStream(bs)
end


function argb_to_rgba(argb)
    local a = bit.band(bit.rshift(argb, 24), 0xFF)
    local r = bit.band(bit.rshift(argb, 16), 0xFF)
    local g = bit.band(bit.rshift(argb, 8), 0xFF)
    local b = bit.band(argb, 0xFF)

    return bit.bor(
        bit.lshift(r, 24),
        bit.lshift(g, 16),
        bit.lshift(b, 8),
        a
    )
end

local attackers = {}

function se.onPlayerDeath(player_id)
    for k,v in pairs(attackers) do
        if player_id == v then
            local color = sampGetPlayerColor(player_id)
            send_attacker(player_id, sampGetPlayerNickname(player_id), true, string.format('%06X', bit.band(color, 0xFFFFFF)))
            break
        end
    end
end

function se.onPlayerQuit(player_id, reason)
	for k,v in pairs(attackers) do
        if player_id == v then
            local color = sampGetPlayerColor(player_id)
            send_attacker(player_id, sampGetPlayerNickname(player_id), true, string.format('%06X', bit.band(color, 0xFFFFFF)))
            break
        end
    end
end

function attacker_mark(id)
    lua_thread.create(function()
        local create_time = os.clock()
        local player_id = id
        local orig_color = argb_to_rgba(sampGetPlayerColor(player_id))
        local is_done = false
        while (os.clock() - create_time) < 120 and not is_done do
            wait(0)
            setPlayerColor(player_id, 0xFF0000FF)
            wait(300)
            setPlayerColor(player_id, orig_color)
            wait(300)
            is_done = true
            for k, v in pairs(attackers) do
                if v == player_id then
                    is_done = false
                end
            end
        end
    end)
end

local last_attacker = ""
local last_attacker_time = 0

function se.onShowTextDraw(id, data)
    text = data["text"]
    
    if text:find("HA ‹AC HAЊA‡ …‚POK ~r~") then
        local attacker_name = text:gsub(".*HA ‹AC HAЊA‡ …‚POK ~r~",""):gsub("~w~.~n~.*","")
        local attacker_id = -1
        for id, name in pairs(getAllSampPlayers()) do
            if string.lower(name):find(string.lower(attacker_name)) then
                attacker_id = id
                attacker_name = name
            end
        end
        if attacker_id ~= -1 then
            if attacker_name ~= last_attacker or os.clock() - last_attacker_time > 30 then
                last_attacker = attacker_name
                last_attacker_time = os.clock()
                local color = sampGetPlayerColor(attacker_id)
                send_attacker(attacker_id, attacker_name, false, string.format('%06X', bit.band(color, 0xFFFFFF)))
                cmd_send_chat("{FF6666}!!! Оборона по {" .. string.format('%06X', bit.band(color, 0xFFFFFF)) .. "}" .. attacker_name .. " [" ..  attacker_id .. "]")
            end
        end
    end
end

function main()
    if not isSampLoaded() then return end
    while not isSampAvailable() do wait(100) end

    sampAddChatMessage("RdugChat: /u [текст].", 0xAAAAAA)
    sampRegisterChatCommand("u", cmd_send_chat)
    sampRegisterChatCommand("ulist", cmd_list_online)

    -- Первая попытка подключения
    connect_to_server()

    while true do
        wait(300)
        local current_time = os.clock()

        if is_connected and client then
            ------------------------------------------------
            -- 1. ЧТЕНИЕ ДАННЫХ
            ------------------------------------------------
            local line, err = client:receive('*l')
            if line then
                -- Пришла строка, пробуем распарсить JSON
                local status, msg = pcall(cjson.decode, line)
                if status then
                    handle_packet(msg) -- Обработка пакета
                else
                    print("Error decoding JSON: " .. line)
                end
            elseif err == "closed" then
                print("Связь разорвана сервером.")
                disconnect()
            end

            ------------------------------------------------
            -- 2. HEARTBEAT (Проверка жизни)
            ------------------------------------------------
            -- Если мы ничего не шлем, TCP может не заметить обрыв.
            -- Шлем пинг, чтобы убедиться, что труба целая.
            if current_time - last_heartbeat > HEARTBEAT_INTERVAL then
                local success = send_json({type = "ping"}, true) -- true = скрытая отправка (без логов ошибок в чат)
                if not success then
                    disconnect() -- Если не смогли отправить пинг - значит дисконнект
                end
                last_heartbeat = current_time
            end

        else
            ------------------------------------------------
            -- 3. ЛОГИКА ПЕРЕПОДКЛЮЧЕНИЯ
            ------------------------------------------------
            if current_time - last_reconnect_attempt > RECONNECT_DELAY then
                last_reconnect_attempt = current_time
                connect_to_server()
            end
        end
    end
end

-- Обработка входящих пакетов
function handle_packet(msg)
    if msg.type == "chat" then
        -- Обычное сообщение чата
        -- msg.data содержит: nick, id, text
        local hexColor = msg.color or 0xfbec5d
        msg.text = u8:decode(msg.text)
        -- Формируем строку
        local text = string.format("%s[%s]: %s", msg.nick, msg.id, msg.text)
        sampAddChatMessage(text, hexColor)
    
    elseif msg.type == "online" then
        sampAddChatMessage("Члены подвального чата онлайн, всего {D8A903}" .. #msg.clients .. "{FFFFFF} человек:", 0xFFFFFF)
        for i, v in ipairs(msg.clients) do
            local afk = ""
            if sampIsPlayerPaused(v.id) then
                afk = " {34C924}< AFK >"
            end
            sampAddChatMessage(string.format("Ник: {abcdef}%s - %s {ffffff}Ранг:{fbec5d} %s%s", v.nick, v.id, u8:decode(v.rank), afk), 0xFFFFFF)
        end

    elseif msg.type == "attacker" then
        if msg.is_done then
            for i, v in ipairs(attackers) do
                if v == msg.id then
                    table.remove(attackers, i)
                end
            end
        else
            table.insert(attackers, msg.id)
            attacker_mark(msg.id)
        end
        
    elseif msg.type == "system" then
        -- Системное сообщение от сервера
        msg.text = u8:decode(msg.text)
        sampAddChatMessage(msg.text, 0xfbec5d)
    end
    -- Пакеты типа "ping" можно игнорировать, они нужны только для поддержания TCP
end

function cmd_send_chat(arg)
    if #arg == 0 then sampAddChatMessage("Используйте: /u [текст]", -1) return end
    if not is_connected then sampAddChatMessage("Нет соединения! Ждите...", 0xFF0000) return end

    local myName = sampGetPlayerNickname(select(2, sampGetPlayerIdByCharHandle(PLAYER_PED)))
    local myId = select(2, sampGetPlayerIdByCharHandle(PLAYER_PED))

    -- Формируем пакет
    local packet = {
        type = "chat",
        nick = myName,
        id = myId,
        text = arg
    }
    
    -- Отправляем JSON
    send_json(packet)
end

function cmd_send_login(arg)
    local myName = sampGetPlayerNickname(select(2, sampGetPlayerIdByCharHandle(PLAYER_PED)))
    local myId = select(2, sampGetPlayerIdByCharHandle(PLAYER_PED))

    -- Формируем пакет
    local packet = {
        type = "login",
        nick = myName,
        id = myId,
        version = thisScript().version
    }
    
    -- Отправляем JSON
    send_json(packet)
end

function cmd_list_online(arg)
    -- Формируем пакет
    local packet = {
        type = "online"
    }
    
    -- Отправляем JSON
    send_json(packet)
end

function send_attacker(player_id, player_nick, is_done, color)
    local packet = {
        type = "attacker",
        nick = player_nick,
        id = player_id,
        is_done = is_done,
        color = color
    }
    
    -- Отправляем JSON
    send_json(packet)
end

-- Функция-обертка для отправки JSON
function send_json(table_data, silent)
    if not client or not is_connected then return false end
    
    local status, json_str = pcall(cjson.encode, table_data)
    if not status then print("JSON Encode Error"); return false end
    
    -- ВАЖНО: Добавляем \n в конце, иначе receive('*l') на сервере не сработает
    local final_data = json_str .. "\n"
    
    -- send возвращает nil, если есть ошибка + текст ошибки
    local bytes_sent, err = client:send(final_data)
    
    if not bytes_sent then
        if not silent then 
            sampAddChatMessage("Ошибка отправки: " .. tostring(err), 0xFF0000) 
        end
        return false -- Вернем false, чтобы вызывающий код знал об ошибке
    end
    
    return true
end

function connect_to_server()
    if client then client:close() end -- Закрываем старый хвост, если был
    
    client = socket.tcp()
    client:settimeout(0.2) -- Таймаут на само подключение
    
    local res, err = client:connect(HOST, PORT)
    if res then
        sampAddChatMessage("RdugChat: Подключено!", 0x00FF00)
        client:settimeout(0) -- Неблокирующий режим для работы
        is_connected = true
        last_heartbeat = os.clock()
        cmd_send_login()
    else
        -- Не спамим в чат ошибками каждую секунду, пишем только в консоль SF
        print("Connection failed: " .. tostring(err))
        is_connected = false
    end
end

function disconnect()
    if is_connected then
        sampAddChatMessage("RdugChat: Потеря соединения...", 0xFF0000)
    end
    is_connected = false
    if client then 
        client:close()
        client = nil
    end
end

function onScriptTerminate(scr, quit)
    if scr == thisScript() and client then client:close() end
end