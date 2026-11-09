-- A game of Nomic, played with Nomsu.
--
-- Almost everything about the game is defined by its rules, which are Nomsu code that
-- players can change. This file is only a small kernel, which gives the rules a few
-- things that can't be done in a sandbox:
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
local nomsu = require("nomsu_library")
local Limits = require("nomsu_limits")
local store = require("store")
local Buffer = require("buffer")

local NOMSU_LIB = "/usr/local/share/nomsu/8.0.0/lib"
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
            say "Nothing handles \"\($event.request.type)\" requests."]],
    [[
### Rule 2: anyone who connects becomes a player
on (join) from $player:
    if ($game.players has $player): return
    $game.players.(#$game.players + 1) = $player
    say "\$player joined the game."]],
    [[
### Rule 3: any player can propose a change to the rules, and it's enacted right away,
### unless its code has an error
on (submit proposal $code) from $player:
    $problem = (try enacting $code)
    if $problem:
        say "\$player's proposal was rejected, since it has a problem: \$problem"
        return
    say "\$player enacted:\n    \($code, with "\n" -> "\n    ")"
    enact $code]],
    [[
### Rule 4: players can talk to each other
on (tell everyone $message) from $player:
    say "\$player says: \$message"]],
    [[
### Rule 5: how to play
public:
    (help) means:
        say "Your code runs in your own copy of the game. Only requests affect the real game:\n  tell everyone \"hello\"\n  propose:\n      on (wave at $other) from $player:\n          say \"\\$player waves at \\$other\"\nTo look around, use say:\n  say $game.players\n  say (current rules)"]],
}

-- Nomsu's error messages show the code where the error happened. Just keep the message.
local function short(err)
    if type(err) == "table" and err.limit then
        return "That went over the " .. tostring(err.limit) .. " limit."
    end
    err = string.gsub(tostring(err), "\027%[[%d;]*m", "")
    return string.match(err, "%^+%s*\n%s*([^\n]-)%s*\n") or string.match(err, "[^\n]*")
end

local Sandbox = {}
Sandbox.__index = Sandbox

-- Make a blank sandbox with the kernel's functions.
-- opts (all optional):
--   output: fn(text), called with what the code says
--   send: fn(request), called with the requests that the code sends
--   trial: fn(code), returns the problem with some code, or nil. Without this, the
--          sandbox can't start any new trials.
function Sandbox.new(opts)
    local self = setmetatable({
        replaying=false,
        trial=opts.trial,
        rules={table.unpack(initial_rules)},
        output=opts.output,
    }, Sandbox)
    self.nomsu = nomsu.new{
        output=function(text)
            self:on_output(text)
        end,
        environment={
            send=function(request)
                if opts.send and not self.replaying then
                    opts.send(nomsu.plain_copy(request))
                end
            end,
            enact=function(code) self:enact(code) end,
            try_enacting=function(code) return self:try_enacting(code) end,
            current_rules=function() return table.concat(self.rules, "\n\n") end,
        },
        loader=nomsu.chain_loaders(nomsu.table_loader{kernel=kernel},
            nomsu.file_loader({NOMSU_LIB})),
        limits=REPLAYED_LIMITS,
        random_seed=1,
    }
    assert(self.nomsu:run("use \"kernel\""))
    self.nomsu:pledge{"stdio"}
    return self
end

function Sandbox:on_output(text)
    if self.output and not self.replaying then
        self.output(text)
    end
end

function Sandbox:enact(code)
    local ok, err = self.nomsu:run(code)
    if not ok then error(err, 0) end
    local number = #self.rules + 1
    self.rules[number] = "### Rule " .. number .. ": enacted during the game\n" .. code
end

-- While replaying, this gives the same results it gave the first time
function Sandbox:try_enacting(code)
    self.tries = self.tries + 1
    if self.tries > MAX_TRIES then error("That's too many tries at enacting.", 0) end
    if self.replaying then return table.remove(self.recorded, 1) or nil end
    if not self.trial then error("A copy of the game can't try enacting anything.", 0) end
    local problem = self.trial(code)
    if self.recorded then table.insert(self.recorded, problem or false) end
    return problem
end

function Sandbox:run(code)
    self.tries = 0
    local ok, a, b = pcall(self.nomsu.run, self.nomsu, code)
    if not ok then return false, a end
    return a, b
end

-- Run something from the game's history
function Sandbox:apply(entry)
    self.recorded = entry.recorded
    if self.replaying and entry.recorded then self.recorded = {table.unpack(entry.recorded)} end
    local ok, err
    if entry.code then
        ok, err = self:run(entry.code)
    else
        local runtime = self.nomsu.environment.RUNTIME_ENV
        runtime.event = {player=entry.player, request=nomsu.plain_copy(entry.request)}
        ok, err = self:run("handle $event")
        runtime.event = nil
    end
    self.recorded = nil
    return ok, err
end

-- Run the game's history again, with the output hidden and requests dropped
function Sandbox:replay(history)
    self.replaying = true
    for _, entry in ipairs(history) do self:apply(entry) end
    self.replaying = false
end

local Game = {}
Game.__index = Game

-- A throwaway copy of the game, made by running its history again. opts are Sandbox.new's.
function Game:copy(opts)
    local sandbox = Sandbox.new(opts)
    sandbox:replay(self.history)
    sandbox.nomsu.limits = LIVE_LIMITS
    return sandbox
end

-- Try running some code in a copy of the game, and return the problem with it (or nil
-- if there isn't one). Building the copy is the kernel's work, so it doesn't count
-- against the limits.
function Game:trial(code)
    return Limits.run_unlimited(function()
        local ok, err = self:copy{}:run(code)
        if not ok then return short(err) end
    end)
end

function Game:remember(text)
    self.recent[#self.recent + 1] = text
    if #self.recent > MAX_RECENT then table.remove(self.recent, 1) end
end

-- opts:
--   entries: what happened in earlier sessions (the entries passed to record)
--   announce: fn(text), called with what the game says to everyone
--   record: fn(entry), called with each new entry, which must be saved to replay later
--   rules_changed: fn(rules), called with the list of rules when one is enacted
function Game.new(opts)
    local self = setmetatable({}, Game)
    self.history, self.recent, self.joined = {}, {}, {}
    self.announce, self.record, self.rules_changed = opts.announce, opts.record, opts.rules_changed
    for _, rule in ipairs(initial_rules) do table.insert(self.history, {code=rule}) end
    for _, entry in ipairs(opts.entries or {}) do
        table.insert(self.history, entry)
        if entry.request.type == "join" then self.joined[entry.player] = true end
        if entry.said then self:remember(entry.said) end
    end
    self.buf = Buffer.new()
    self.game = Sandbox.new{
        output=function(text) self.buf:write(text) end,
        trial=function(code) return self:trial(code) end,
    }
    self.game:replay(self.history)
    return self
end

-- The game handles a request. Problems are reported with reply(text, "error").
function Game:handle(player, request, reply)
    local ok, text = pcall(store.serialize, request)
    if not ok or #text > MAX_REQUEST then
        return reply("That request can't be sent: " .. (ok and "it's too big" or text), "error")
    end
    local entry = {player=player, request=request, recorded={}}
    local rule_count = #self.game.rules
    local run_ok, err = self.game:apply(entry)
    local said = self.buf:flush()
    if said ~= "" then entry.said = said end
    table.insert(self.history, entry)
    self.record(entry)
    if entry.said then
        self:remember(said)
        self.announce(said)
    end
    if #self.game.rules ~= rule_count then self.rules_changed(self.game.rules) end
    if not run_ok then reply("The game had an error: " .. short(err), "error") end
end

-- The rules in force, as a list of code, in the order they took effect
function Game:rules()
    return self.game.rules
end

-- A player joins the game, if they haven't already
function Game:join(player, reply)
    if self.joined[player] then return end
    self.joined[player] = true
    self:handle(player, {type="join", args={}}, reply)
end

-- A player submits some code, which runs in their own sandbox and reports back with
-- reply(text, kind). Then the game handles the requests they sent.
function Game:submit(player, code, reply)
    local buf = Buffer.new()
    local requests = {}
    local sandbox = self:copy{
        output=function(text) buf:write(text) end,
        send=function(request)
            if #requests >= MAX_REQUESTS then error("That's too many requests at once.", 0) end
            requests[#requests + 1] = request
        end,
        trial=function(trial_code) return self:trial(trial_code) end,
    }
    local ok, err = sandbox:run(code)
    local output = buf:flush()
    if output ~= "" then reply(output, "result") end
    if not ok then reply(short(err), "error") end
    for _, request in ipairs(requests) do
        self:handle(player, request, reply)
    end
end

return Game
