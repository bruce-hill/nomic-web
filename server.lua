#!/usr/bin/env lua
-- A multiplayer game of Nomic: players connect over WebSockets and send Nomsu
-- code, and the rules of the game (which are also Nomsu code) decide what it does.
--
-- Usage: lua server.lua [--host 127.0.0.1] [--port 8080] [--history history.lua]
--
-- Everything that happens in the game is appended to the history file and replayed
-- on startup. Delete it to start a fresh game.
local dir = string.match(arg[0], "^(.*/)") or "./"
package.path = dir .. "lib/?.lua;" .. package.path

local net = require("net")
local ws = require("websocket")
local json = require("json")
local Game = require("nomic")
local store = require("store")

local config = {
    host = "127.0.0.1",
    port = 8080,
    history_file = dir .. "history.lua",
    max_message = 64 * 1024,       -- largest code submission accepted, in bytes
    max_output = 64 * 1024,        -- longest single message sent to a client
    max_outbuf = 4 * 1024 * 1024,  -- drop clients that fall this far behind
    process_memory_limit = 1024 * 1024 * 1024,
}

do
    local i = 1
    while i <= #arg do
        local flag, value = arg[i], arg[i + 1]
        if flag == "--host" then config.host = value
        elseif flag == "--port" then config.port = assert(tonumber(value), "--port needs a number")
        elseif flag == "--history" then config.history_file = value
        else
            io.stderr:write("usage: lua server.lua [--host HOST] [--port PORT] [--history FILE]\n")
            os.exit(1)
        end
        i = i + 2
    end
end

local function log(...)
    io.stderr:write(os.date("[%H:%M:%S] "), table.concat({...}, " "), "\n")
end

local conns = {}         -- fd -> connection
local by_name = {}       -- username -> connection
local user_order = {}    -- usernames in join order

local function queue(conn, data)
    if conn.dead then return false end
    if conn.outsize + #data > config.max_outbuf then
        conn.dead = true
        return false
    end
    conn.out[#conn.out + 1] = data
    conn.outsize = conn.outsize + #data
    return true
end

local function queue_json(conn, value)
    return queue(conn, ws.encode(ws.TEXT, json.encode(value)))
end

local function send_close(conn, code, reason)
    local payload = string.char(math.floor(code / 256), code % 256) .. (reason or "")
    queue(conn, ws.encode(ws.CLOSE, payload))
    conn.state = "closing"
end

local function broadcast_users()
    for _, name in ipairs(user_order) do
        queue_json(by_name[name], {type = "users", users = user_order})
    end
end

-- Sends a message to one player
local function send(name, text, kind)
    local conn = by_name[name]
    if not conn or conn.state ~= "ws" then return false end
    if #text > config.max_output then
        text = string.sub(text, 1, config.max_output) .. "\n... (truncated)"
    end
    return queue_json(conn, {type = "message", kind = kind, text = text})
end

-- Entries are saved with a "--" line after each, which can't appear inside a quoted
-- string in the saved data (newlines in strings are written with a backslash)
local function save_entry(entry)
    local f, err = io.open(config.history_file, "ab")
    if f then
        local _
        _, err = f:write(store.serialize(entry), "\n--\n")
        f:close()
    end
    if err then log("saving the game failed:", err) end
end

local function load_entries()
    local entries = {}
    local f = io.open(config.history_file, "rb")
    if f then
        for text in string.gmatch(f:read("*a"), "(.-)\n%-%-\n") do
            entries[#entries + 1] = store.deserialize(text)
        end
        f:close()
    end
    return entries
end

local game = nil

local function valid_name(name)
    return name and #name >= 1 and #name <= 20 and string.match(name, "^[%w_-]+$")
end

local function url_decode(s)
    s = string.gsub(s, "+", " ")
    return (string.gsub(s, "%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function http_response(conn, status, content_type, body)
    queue(conn, "HTTP/1.1 " .. status .. "\r\nContent-Type: " .. content_type
        .. "\r\nContent-Length: " .. #body .. "\r\nConnection: close\r\n\r\n" .. body)
    conn.state = "closing"
end

local function handle_http(conn)
    local head_end = string.find(conn.inbuf, "\r\n\r\n", 1, true)
    if not head_end then
        if #conn.inbuf > 16384 then conn.dead = true end
        return
    end
    local head = string.sub(conn.inbuf, 1, head_end - 1)
    conn.inbuf = string.sub(conn.inbuf, head_end + 4)
    local method, target = string.match(head, "^(%u+) (%S+) HTTP/1%.[01]")
    local headers = {}
    for line in string.gmatch(head, "\r\n([^\r\n]*)") do
        local k, v = string.match(line, "^([^:]+):%s*(.-)%s*$")
        if k then headers[string.lower(k)] = v end
    end
    if not method then
        return http_response(conn, "400 Bad Request", "text/plain", "Bad request\n")
    end
    local path, query = string.match(target, "^([^?]*)%??(.*)$")
    if method ~= "GET" then
        return http_response(conn, "405 Method Not Allowed", "text/plain", "Method not allowed\n")
    end

    if path == "/" or path == "/index.html" then
        local f = io.open(dir .. "public/index.html", "rb")
        if not f then
            return http_response(conn, "500 Internal Server Error", "text/plain", "Missing public/index.html\n")
        end
        local body = f:read("*a")
        f:close()
        return http_response(conn, "200 OK", "text/html; charset=utf-8", body)
    elseif path ~= "/ws" then
        return http_response(conn, "404 Not Found", "text/plain", "Not found\n")
    end

    local key = headers["sec-websocket-key"]
    if string.lower(headers["upgrade"] or "") ~= "websocket" or not key then
        return http_response(conn, "400 Bad Request", "text/plain", "Expected a WebSocket upgrade\n")
    end
    queue(conn, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        .. "Sec-WebSocket-Accept: " .. ws.accept_key(key) .. "\r\n\r\n")
    conn.state = "ws"

    local name
    for k, v in string.gmatch(query, "([^&=]+)=([^&]*)") do
        if k == "name" then name = url_decode(v) end
    end
    local problem
    if not valid_name(name) then
        problem = "Usernames must be 1-20 letters, digits, '_' or '-'"
    elseif by_name[name] then
        problem = "The name '" .. name .. "' is already taken"
    end
    if problem then
        queue_json(conn, {type = "rejected", text = problem})
        return send_close(conn, 1008, "invalid username")
    end

    conn.name = name
    by_name[name] = conn
    user_order[#user_order + 1] = name
    log(name, "connected")
    queue_json(conn, {type = "welcome", name = name})
    broadcast_users()
    queue_json(conn, {type = "rules", rules = game:rules()})
    for _, text in ipairs(game.recent) do send(name, text, "announce") end
    game:join(name, function(text, kind) send(name, text, kind) end)
end

local function handle_message(conn, text)
    game:submit(conn.name, text, function(reply, kind) send(conn.name, reply, kind) end)
end

local function handle_ws(conn)
    local pos = 1
    while conn.state == "ws" and not conn.dead do
        local frame, next_pos = ws.decode(conn.inbuf, pos, config.max_message)
        if frame == nil then break end
        if frame == false then
            send_close(conn, 1002, next_pos)
            break
        end
        pos = next_pos
        local op = frame.opcode
        if op == ws.TEXT or op == ws.BINARY then
            if conn.fragments then send_close(conn, 1002, "expected continuation frame"); break end
            if frame.fin then
                handle_message(conn, frame.payload)
            else
                conn.fragments, conn.fragsize = {frame.payload}, #frame.payload
            end
        elseif op == ws.CONTINUATION then
            if not conn.fragments then send_close(conn, 1002, "unexpected continuation frame"); break end
            conn.fragments[#conn.fragments + 1] = frame.payload
            conn.fragsize = conn.fragsize + #frame.payload
            if conn.fragsize > config.max_message then send_close(conn, 1009, "message too large"); break end
            if frame.fin then
                local text = table.concat(conn.fragments)
                conn.fragments = nil
                handle_message(conn, text)
            end
        elseif op == ws.CLOSE then
            queue(conn, ws.encode(ws.CLOSE, string.sub(frame.payload, 1, 2)))
            conn.state = "closing"
        elseif op == ws.PING then
            queue(conn, ws.encode(ws.PONG, frame.payload))
        elseif op ~= ws.PONG then
            send_close(conn, 1002, "unknown opcode")
        end
    end
    conn.inbuf = string.sub(conn.inbuf, pos)
end

local function flush(conn)
    if conn.outsize == 0 or conn.dead then return end
    local data = table.concat(conn.out)
    local sent = net.send(conn.fd, data)
    if not sent then
        conn.dead = true
        return
    end
    local rest = string.sub(data, sent + 1)
    conn.out = rest ~= "" and {rest} or {}
    conn.outsize = #rest
end

local function disconnect(conn)
    net.close(conn.fd)
    conns[conn.fd] = nil
    local name = conn.name
    if name and by_name[name] == conn then
        by_name[name] = nil
        for i, n in ipairs(user_order) do
            if n == name then table.remove(user_order, i); break end
        end
        log(name, "disconnected")
        broadcast_users()
    end
end

-- Startup
net.limit_memory(config.process_memory_limit)
local listener = net.listen(config.host, config.port)
do
    local entries = load_entries()
    game = Game.new({
        entries = entries,
        announce = function(text)
            for _, name in ipairs(user_order) do send(name, text, "announce") end
        end,
        record = save_entry,
        rules_changed = function(rules)
            for _, name in ipairs(user_order) do
                queue_json(by_name[name], {type = "rules", rules = rules})
            end
        end,
    })
    if #entries > 0 then log("replayed", #entries, "events from", config.history_file) end
end
log("listening on http://" .. config.host .. ":" .. config.port .. "/")

while true do
    local entries = {{fd = listener, events = net.POLLIN}}
    local list = {}
    for _, conn in pairs(conns) do
        list[#list + 1] = conn
        entries[#entries + 1] = {fd = conn.fd, conn = conn,
            events = conn.outsize > 0 and (net.POLLIN + net.POLLOUT) or net.POLLIN}
    end
    net.poll(entries, 1000)

    if entries[1].revents ~= 0 then
        while true do
            local fd = net.accept(listener)
            if not fd then break end
            conns[fd] = {fd = fd, state = "http", inbuf = "", out = {}, outsize = 0}
        end
    end

    for i = 2, #entries do
        local e = entries[i]
        local conn = e.conn
        if e.revents ~= 0 and not conn.dead and conn.state ~= "closing" then
            local data = net.recv(conn.fd)
            while data and data ~= "" do
                conn.inbuf = conn.inbuf .. data
                if #conn.inbuf > config.max_message * 2 + 16384 then break end
                data = net.recv(conn.fd)
            end
            if not data then conn.dead = true end
            local ok, err = pcall(function()
                if conn.state == "http" then handle_http(conn) end
                if conn.state == "ws" then handle_ws(conn) end
            end)
            if not ok then
                log("internal error:", tostring(err))
                conn.dead = true
            end
        end
    end

    for _, conn in ipairs(list) do
        flush(conn)
        if conn.dead or (conn.state == "closing" and conn.outsize == 0) then
            local ok2, err2 = pcall(disconnect, conn)
            if not ok2 then log("internal error in disconnect:", tostring(err2)) end
        end
    end
end
