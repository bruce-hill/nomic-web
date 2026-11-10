-- A game of Nomic, played with Nomsu.
--
-- Almost everything about the game is defined by its rules, which are Nomsu code that
-- players can change. This file is only a small kernel, which gives the rules a few
-- things that can't be done in a sandbox:
--   (print $text)          Show some text to whoever is watching this sandbox: the player
--                          whose code is running, or everyone if it's the game's sandbox.
--   (send $request)        Send a request (plain data) to the game. After the player's
--                          code finishes, the game handles it with (handle $event).
--   (enact $code)          Run some code (as text) in this sandbox.
--   (try enacting $code)   Try running some code in a copy of the game, and return the
--                          problem with it (or nil if there isn't one).
--   (current rules)        The text of the rules: the starting ones, then what was enacted.
--   propose: ...           Turn the code in the block into text, and pass it to
--                          (submit proposal $code).
--   on (action $x) from $player: ...
--                          Define (action $x), which sends a request to the game, and
--                          pass what to do about that request to
--                          (set the handler for $type to $handler).
--                          (This and propose are syntax, which sandboxed code can't
--                          define.)
--
-- The game has a persistent sandbox, which runs everything that happens in the game,
-- once. Code that a player submits runs in a sandbox of their own: a copy of the game,
-- made by running the game's history again in a new sandbox. The only way to affect the
-- game is to send requests.
--
-- Replaying history has to give the same results every time, so everything that gets
-- replayed runs with limits that don't depend on how fast the server is.
package.path = "/usr/local/share/nomsu/8.0.0/?.lua;" .. package.path
local nomsu = require("nomsu")
local Limits = require("nomsu_limits")
local NOMSU_DIRECTORY = require("nomsu_environment").NOMSU_DIRECTORY
local Text = require("text")
local store = require("store")
local Buffer = require("buffer")

local MAX_REQUEST = 64 * 1024
local MAX_REQUESTS = 16       -- requests that one submission can send
local MAX_TRIES = 2           -- times that one run can use (try enacting)
local MAX_RECENT = 100        -- announcements shown to players when they connect
local REPLAYED_LIMITS = {instructions=1e6, memory=256 * 1024}
local LIVE_LIMITS = {instructions=1e6, memory=256 * 1024, seconds=1}

-- The kernel's syntax
local kernel = [[
#!/usr/bin/env nomsu -V8.0.0
public:
    (print (*extra arguments*)) means:
        say (*extra arguments*)
    (propose $code) compiles to:
        $statements = ($code if ($code.type == "Block") else {$code})
        $text = (("\($ as nomsu)" for $ in $statements) joined with "\n")
        return (Lua "submit_proposal(\($text, as lua))")
    (on $pattern from $player $body) compiles to:
        lua> ("
            local stub = \$pattern:get_stub()
            local \$params = {\$player, unpack(\$pattern:get_args())}
            local names = {}
            for i, arg in ipairs(\$pattern:get_args()) do
                names[i] = \(nomsu environment):compile(arg):text()
            end
            local names_text = table.concat(names, ", ")
            return LuaCode(stub:as_lua_id(), " = function(", names_text, ") send({type=",
                stub:as_lua(), ", args={n=", tostring(#names), ", ", names_text, "}}) end;\\n",
                "set_the_handler_for_1_to(", stub:as_lua(), ", ",
                \(\(\$params -> \$body) as lua), ");")
        ")
]]

-- The rules the game starts with. Rules run in order, so later rules (like ones that
-- proposals add) can redefine anything that earlier rules defined.
local initial_rules = {
    [[
### Rule 1: the game's state, and how it handles requests. (on (wave at $other) from $player: ...)
### defines the action (wave at $other), which sends a request to the game, and what the
### game does when it gets that request.
public $game = {.players = {}}
public $handlers = {}
public:
    (set the handler for $type to $handler) means:
        $handlers.$type = $handler
    (handle $event) means:
        $handler = $handlers.($event.request.type)
        $args = $event.request.args
        if $handler:
            $handler $event.player (unpack $args 1 $args.n)
        ..else:
            print "Nothing handles \"\($event.request.type)\" requests."]],
    [[
### Rule 2: anyone who connects becomes a player
on (join) from $player:
    if ($game.players has $player): return
    $game.players.(#$game.players + 1) = $player
    print "\$player joined the game."]],
    [[
### Rule 3: any player can propose a change to the rules, and it's enacted right away,
### unless its code has an error
on (submit proposal $code) from $player:
    $problem = (try enacting $code)
    if $problem:
        print "\$player's proposal was rejected, since it has a problem: \$problem"
        return
    print "\$player enacted:\n    \($code, with "\n" -> "\n    ")"
    enact $code]],
    [[
### Rule 4: players can talk to each other. Printing from a handler shows it to everyone.
on (say $message) from $player:
    print "@\$player: \$message"]],
    [[
### Rule 5: how to play
public:
    (help) means:
        print "Your code runs in your own copy of the game. Only requests affect the real game:\n  say \"hello\"\n  propose:\n      on (wave at $other) from $player:\n          print \"\\$player waves at \\$other\"\nTo look around, use print, which only you can see:\n  print $game.players\n  print (current rules)"]],
}

-- Nomsu's error messages show the code where the error happened. Just keep the message.
local function short(err)
    if type(err) == "table" and err.limit then
        return "That went over the " .. tostring(err.limit) .. " limit."
    end
    err = string.gsub(tostring(err), "\027%[[%d;]*m", "")
    return string.match(err, "%^+%s*\n%s*([^\n]-)%s*\n") or string.match(err, "[^\n]*")
end

-- Sandboxed code can only reach the outside world through its effects, which are given
-- for each run:
--   print: fn(text), called with what the code prints
--   send: fn(request), called with the requests that the code sends
--   try: fn(code), returns the problem with some code, or nil
local function ignore() end

local SILENT = {print=ignore, send=ignore, try=function()
    error("A copy of the game can't try enacting anything.", 0)
end}

-- Running something from the game's history again gives the same results as the first time
local function replaying(entry)
    local tries = 0
    return {print=ignore, send=ignore, try=function()
        tries = tries + 1
        return entry.recorded[tries] or nil
    end}
end

local Sandbox = {}
Sandbox.__index = Sandbox

-- Make a sandbox with the kernel's functions and the starting rules
function Sandbox.new()
    local self = setmetatable({rules={table.unpack(initial_rules)}, effects=SILENT}, Sandbox)
    self.nomsu = nomsu.Runtime{
        print=function(text) self.effects.print(text) end,
        environment={
            send=function(request) self.effects.send(request) end,
            enact=function(code) self:enact(code) end,
            try_enacting=function(code) return self:try_enacting(code) end,
            current_rules=function() return table.concat(self.rules, "\n\n") end,
        },
        modules={kernel=kernel},
        limits=REPLAYED_LIMITS,
    }
    assert(self.nomsu:run("seed random with 1"))
    assert(self.nomsu:run("use \"kernel\""))
    self.nomsu:seal()
    for _, rule in ipairs(initial_rules) do assert(self:run(rule, SILENT)) end
    return self
end

-- How an action that's defined by some function is used, like "greet $who nicely", from
-- its stub ("greet 1 nicely") and the names of the function's parameters. Compile rules
-- get two other arguments before the action's.
local function action_pattern(stub, fn, skip)
    local names, info = {}, debug.getinfo(fn, "u")
    for i = skip + 1, info.nparams do
        local name = Text.from_lua_id(debug.getlocal(fn, i))
        names[#names + 1] = string.find(name, " ") and "$(" .. name .. ")" or "$" .. name
    end
    if info.isvararg then names[#names + 1] = "$..." end
    -- A stub leaves out the arguments at the end, so they go after its last word
    local used = 0
    local pattern = string.gsub(stub, "%f[%w]%d+%f[%W]", function(n)
        used = math.max(used, tonumber(n))
        return names[tonumber(n)] or "$"
    end)
    for i = used + 1, #names do pattern = pattern .. " " .. names[i] end
    -- Stubs have spaces around apostrophes, like "isn ' t", which aren't typed
    return (string.gsub(pattern, " ' ", "'"))
end

-- Whether a function is the game's (defined by the kernel or the rules), rather than
-- part of Nomsu, which is written in Nomsu's directory or in C
local function is_the_games(fn)
    local source = debug.getinfo(fn, "S").source
    return string.sub(source, 1, 1) == "@" and string.sub(source, 2, #NOMSU_DIRECTORY + 1) ~= NOMSU_DIRECTORY
end

-- The actions that can be used in this sandbox, sorted, as {pattern=text, game=boolean},
-- where pattern is how the action is used, like "greet $who nicely", and game is whether
-- the kernel or the rules define it (otherwise it's part of Nomsu).
function Sandbox:actions()
    local env, found, seen = self.nomsu.environment, {}, {}
    local function add(stub, fn, skip)
        if type(stub) ~= "string" or type(fn) ~= "function" or stub == "" or string.match(stub, "^[%u_ ]+$") then
            return
        end
        local pattern = action_pattern(stub, fn, skip)
        if seen[pattern] then return end
        seen[pattern] = true
        found[#found + 1] = {pattern=pattern, game=is_the_games(fn)}
    end
    for name, fn in pairs(env.RUNTIME_ENV) do
        if type(name) == "string" then add(Text.from_lua_id(name), fn, 0) end
    end
    for stub, rule in pairs(env.COMPILE_RULES) do add(stub, rule, 2) end
    table.sort(found, function(a, b) return a.pattern < b.pattern end)
    return found
end

function Sandbox:enact(code)
    local ok, err = self.nomsu:run(code)
    if not ok then error(err, 0) end
    local number = #self.rules + 1
    self.rules[number] = "### Rule " .. number .. ": enacted during the game\n" .. code
end

function Sandbox:try_enacting(code)
    self.tries = self.tries + 1
    if self.tries > MAX_TRIES then error("That's too many tries at enacting.", 0) end
    return self.effects.try(code)
end

function Sandbox:run(code, effects)
    self.effects, self.tries = effects, 0
    local ok, a, b = pcall(self.nomsu.run, self.nomsu, code)
    if not ok then return false, a end
    return a, b
end

-- The rules handle a player's request
function Sandbox:handle(entry, effects)
    local runtime = self.nomsu.environment.RUNTIME_ENV
    runtime.event = {player=entry.player, request=nomsu.plain_copy(entry.request)}
    local ok, err = self:run("handle $event", effects)
    runtime.event = nil
    return ok, err
end

function Sandbox:replay(history)
    for _, entry in ipairs(history) do self:handle(entry, replaying(entry)) end
end

local Game = {}
Game.__index = Game

-- A throwaway copy of the game, made by running its history again
function Game:fork()
    local sandbox = Sandbox.new()
    sandbox:replay(self.history)
    sandbox.nomsu.limits = LIVE_LIMITS
    return sandbox
end

-- Try running some code in a copy of the game, and return the problem with it (or nil
-- if there isn't one). Building the copy is the kernel's work, so it doesn't count
-- against the limits.
function Game:trial(code)
    return Limits.run_unlimited(function()
        local ok, err = self:fork():run(code, SILENT)
        if not ok then return short(err) end
    end)
end

-- Add something that happened to what the game knows about. This must not fail: the
-- game's sandbox has already handled the entry, so it has to be in the history too.
-- Requests can be any plain data, like a number, not just tables.
function Game:note(entry)
    table.insert(self.history, entry)
    local request = entry.request
    if type(request) == "table" and request.type == "join" then self.joined[entry.player] = true end
    if entry.said then
        self.recent[#self.recent + 1] = {seq=#self.history, text=entry.said}
        if #self.recent > MAX_RECENT then table.remove(self.recent, 1) end
    end
end

-- opts:
--   entries: what happened in earlier sessions (the entries passed to record)
--   announce: fn(text, seq), called with what the game says to everyone, and its entry's
--             position in the history (announcements in self.recent have the same seq)
--   record: fn(entry), called with each new entry, which must be saved to replay later
--   rules_changed: fn(rules), called with the list of rules when one is enacted
function Game.new(opts)
    local self = setmetatable({}, Game)
    self.history, self.recent, self.joined = {}, {}, {}
    self.announce, self.record, self.rules_changed = opts.announce, opts.record, opts.rules_changed
    for _, entry in ipairs(opts.entries or {}) do self:note(entry) end
    self.sandbox = Sandbox.new()
    self.sandbox:replay(self.history)
    return self
end

-- The game handles a request. Problems are reported with reply(text, "error").
function Game:handle(player, request, reply)
    local ok, text = pcall(store.serialize, request)
    if not ok or #text > MAX_REQUEST then
        return reply("That request can't be sent: " .. (ok and "it's too big" or text), "error")
    end
    local buf = Buffer.new()
    local recorded = {}
    local entry = {player=player, request=request, recorded=recorded}
    local rule_count = #self.sandbox.rules
    local run_ok, err = self.sandbox:handle(entry, {
        print=function(text) buf:write(text) end,
        send=ignore,
        try=function(code)
            local problem = self:trial(code)
            table.insert(recorded, problem or false)
            return problem
        end,
    })
    local said = buf:flush()
    if said ~= "" then entry.said = said end
    self:note(entry)
    self.record(entry)
    if entry.said then self.announce(said, #self.history) end
    if #self.sandbox.rules ~= rule_count then self.rules_changed(self.sandbox.rules) end
    if not run_ok then reply("The game had an error: " .. short(err), "error") end
end

-- The rules in force, as a list of code, in the order they took effect
function Game:rules()
    return self.sandbox.rules
end

-- The actions that players can use (see Sandbox:actions)
function Game:actions()
    return self.sandbox:actions()
end

-- A player joins the game, if they haven't already
function Game:join(player, reply)
    if self.joined[player] then return end
    self:handle(player, {type="join", args={}}, reply)
end

-- A player submits some code, which runs in their own sandbox and reports back with
-- reply(text, kind). Then the game handles the requests they sent.
function Game:submit(player, code, reply)
    local buf = Buffer.new()
    local requests = {}
    local ok, err = self:fork():run(code, {
        print=function(text) buf:write(text) end,
        send=function(request)
            if #requests >= MAX_REQUESTS then error("That's too many requests at once.", 0) end
            requests[#requests + 1] = nomsu.plain_copy(request)
        end,
        try=function(trial_code) return self:trial(trial_code) end,
    })
    local output = buf:flush()
    if output ~= "" then reply(output, "result") end
    if not ok then reply(short(err), "error") end
    for _, request in ipairs(requests) do
        self:handle(player, request, reply)
    end
end

return Game
