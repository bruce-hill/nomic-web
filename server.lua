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

local http_server = require("http.server")
local http_headers = require("http.headers")
local http_util = require("http.util")
local websocket = require("http.websocket")
local condition = require("cqueues.condition")
local json = require("json")
local Game = require("nomic")
local store = require("store")

local config = {
    host="127.0.0.1",
    port=8080,
    history_file=dir.."history.lua",
    max_message=64 * 1024,  -- largest code submission accepted, in bytes
    max_output=64 * 1024,   -- longest single message sent to a client
    send_timeout=10,        -- drop clients that stop reading for this many seconds
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

local by_name = {}       -- username -> connection
local user_order = {}    -- usernames in join order

-- Messages are queued and written by each connection's own coroutine, so that
-- game code never waits on a slow client.
local function queue_json(conn, value)
    conn.out[#conn.out + 1] = json.encode(value)
    conn.wake:signal()
end

local function write_messages(conn)
    while true do
        local text = table.remove(conn.out, 1)
        if text then
            if not conn.ws:send(text, "text", config.send_timeout) then break end
        elseif conn.closed then
            return
        else
            conn.wake:wait()
        end
    end
    -- The client isn't reading. Shutting down the socket ends its read loop.
    if conn.ws.readyState < 3 then conn.ws.socket:shutdown("rw") end
end

local function broadcast(value)
    for _, name in ipairs(user_order) do queue_json(by_name[name], value) end
end

-- Sends a message to one player
local function send(name, text, kind)
    local conn = by_name[name]
    if not conn then return false end
    if #text > config.max_output then
        text = string.sub(text, 1, config.max_output) .. "\n... (truncated)"
    end
    queue_json(conn, {type="message", kind=kind, text=text})
    return true
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

local function valid_name(name)
    return name and #name >= 1 and #name <= 20 and string.match(name, "^[%w_-]+$")
end

local game = nil

local function respond(stream, status, content_type, body)
    local headers = http_headers.new()
    headers:append(":status", status)
    headers:append("content-type", content_type)
    stream:write_headers(headers, false)
    stream:write_chunk(body, true)
end

local function play(server, ws, name)
    local conn = {ws=ws, name=name, out={}, wake=condition.new()}
    by_name[name] = conn
    user_order[#user_order + 1] = name
    server.cq:wrap(write_messages, conn)
    log(name, "connected")
    queue_json(conn, {type="welcome", name=name})
    broadcast({type="users", users=user_order})
    queue_json(conn, {type="rules", rules=game:rules()})
    for _, text in ipairs(game.recent) do send(name, text, "announce") end
    game:join(name, function(text, kind) send(name, text, kind) end)

    for text in ws:each() do
        if #text > config.max_message then break end
        local ok, err = pcall(game.submit, game, name, text, function(reply, kind) send(name, reply, kind) end)
        if not ok then log("internal error:", tostring(err)) end
    end

    by_name[name] = nil
    for i, n in ipairs(user_order) do
        if n == name then table.remove(user_order, i); break end
    end
    conn.closed = true
    conn.wake:signal()
    ws:close()
    log(name, "disconnected")
    broadcast({type="users", users=user_order})
end

local function on_stream(server, stream)
    local request = stream:get_headers()
    if not request then return end
    if request:get(":method") ~= "GET" then
        return respond(stream, "405", "text/plain", "Method not allowed\n")
    end
    local path, query = string.match(request:get(":path"), "^([^?]*)%??(.*)$")

    if path == "/" or path == "/index.html" then
        local f = io.open(dir .. "public/index.html", "rb")
        if not f then return respond(stream, "500", "text/plain", "Missing public/index.html\n") end
        local body = f:read("*a")
        f:close()
        return respond(stream, "200", "text/html; charset=utf-8", body)
    elseif path ~= "/ws" then
        return respond(stream, "404", "text/plain", "Not found\n")
    end

    local ws = websocket.new_from_stream(stream, request)
    if not ws then return respond(stream, "400", "text/plain", "Expected a WebSocket upgrade\n") end
    assert(ws:accept())

    local name
    for k, v in http_util.query_args(query) do
        if k == "name" then name = v end
    end
    local problem
    if not valid_name(name) then
        problem = "Usernames must be 1-20 letters, digits, '_' or '-'"
    elseif by_name[name] then
        problem = "The name '" .. name .. "' is already taken"
    end
    if problem then
        ws:send(json.encode({type="rejected", text=problem}), "text", config.send_timeout)
        ws:close(1008, "invalid username")
        return
    end
    play(server, ws, name)
end

local entries = load_entries()
game = Game.new({
    entries=entries,
    announce=function(text)
        for _, name in ipairs(user_order) do send(name, text, "announce") end
    end,
    record=save_entry,
    rules_changed=function(rules) broadcast({type="rules", rules=rules}) end,
})
if #entries > 0 then log("replayed", #entries, "events from", config.history_file) end

local server = http_server.listen({
    host=config.host,
    port=config.port,
    tls=false,
    version=1.1,
    reuseaddr=true,
    onstream=on_stream,
    onerror=function(_, _, op, err) log("http error:", tostring(op), tostring(err)) end,
})
assert(server:listen())
log("listening on http://" .. config.host .. ":" .. config.port .. "/")
assert(server:loop())
