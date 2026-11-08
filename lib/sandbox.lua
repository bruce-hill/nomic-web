-- The sandbox that runs untrusted player code.
--
-- The game lives in one shared "world" table of globals. Player input runs in
-- a scratch environment that can read the world but not assign globals.
--
-- Only "rule code" can change the world: prelude.lua, and code adopted with
-- persist(). Rule code runs with the world as its environment and receives
-- three capabilities as its chunk arguments, which player input never gets:
--   persist(code, author)  apply code as rule code and record it for replay
--   state                  plain data that's saved to disk with the game
--   atomic(fn, ...)        undo fn's state changes and timers if it errors
-- So the rules decide how they can be changed (e.g. by vote), and that
-- procedure is itself a rule that can be changed.
--
-- Every run is a transaction for `state` and timers: they're committed when
-- the run succeeds and rolled back when it fails, so a player can't leave
-- the rules half-updated by making a rule function hit the instruction limit.
--
-- Behind the world sits a read-only "base" layer holding the safe standard
-- library and the server primitives, so they can be shadowed but not removed.
--
-- Limits: every run gets an instruction budget and a wall-clock deadline,
-- enforced by a count hook. Since hooks never fire inside C functions, C
-- library functions that could do a lot of work are either reimplemented in
-- Lua (string patterns) or charge their cost against the budget up front.
local net = require("net")
local patterns = require("patterns")
local store = require("store")

-- With the JIT on, compiled traces can run without ever calling the hook.
jit.off()
jit.flush()

local Sandbox = {}
Sandbox.__index = Sandbox

local HOOK_STEP = 100
local MAX_STRING = 16 * 1024 * 1024

local function readonly(t)
    return setmetatable({}, {
        __index = t,
        __newindex = function() error("this table is read-only", 2) end,
        __metatable = false,
    })
end

local function pack(...)
    return {n = select("#", ...), ...}
end

local function copy(t, keys)
    local c = {}
    for k in string.gmatch(keys, "%S+") do c[k] = t[k] end
    return c
end

-- opts:
--   host: {send = fn(user, text, kind) -> bool, users = fn() -> list,
--          schedule = fn(seconds, fn, user) -> bool,
--          persisted = fn(code, author), save_state = fn(text),
--          begin = fn(), finish = fn(ok),  -- bracket each run, for timers
--          savepoint = fn() -> token, rollback_to = fn(token)}
--   instruction_limit, time_limit (seconds), memory_limit (bytes)
function Sandbox.new(opts)
    local self = setmetatable({}, Sandbox)
    local host = opts.host
    local instruction_limit = opts.instruction_limit or 1000000
    local time_limit = opts.time_limit or 1.0
    local memory_limit_kb = (opts.memory_limit or 256 * 1024 * 1024) / 1024

    local budget, deadline, exhausted, running = 0, 0, nil, false
    local current_user = nil

    local function stop(why)
        exhausted = exhausted or why
        error(exhausted, 0)
    end

    local function hook()
        if exhausted then error(exhausted, 0) end
        budget = budget - HOOK_STEP
        if budget < 0 then stop("instruction limit exceeded") end
        if net.now() > deadline then stop("time limit exceeded") end
        if collectgarbage("count") > memory_limit_kb then
            collectgarbage()
            if collectgarbage("count") > memory_limit_kb then stop("memory limit exceeded") end
        end
    end

    local function charge(n)
        if not running then return end
        budget = budget - n
        if budget < 0 then stop("instruction limit exceeded") end
    end
    patterns.charge = charge

    -- Once a run has hit a limit, it must not be able to catch the error and
    -- keep going, so the error-catching functions re-raise it.
    local function check(ok, ...)
        if exhausted then error(exhausted, 0) end
        if not ok and (...) == "not enough memory" then stop("memory limit exceeded") end
        return ok, ...
    end

    local safe_string = copy(string, "byte char format len lower upper reverse sub")
    safe_string.find, safe_string.match = patterns.find, patterns.match
    safe_string.gmatch, safe_string.gsub = patterns.gmatch, patterns.gsub
    safe_string.rep = function(s, n, sep)
        local len = #tostring(s) * (tonumber(n) or 0) + #tostring(sep or "") * math.max(0, (tonumber(n) or 0) - 1)
        if len > MAX_STRING then error("string.rep result too large", 2) end
        charge(len / 32)
        return string.rep(s, n, sep)
    end
    safe_string = readonly(safe_string)
    -- Method calls on strings (("x"):rep(9)) go through the string metatable,
    -- so point it at the safe version too. Server code must therefore call
    -- string.foo(s) rather than s:foo().
    local string_mt = debug.getmetatable("")
    string_mt.__index = safe_string
    string_mt.__metatable = false

    local safe_table = copy(table, "concat maxn remove")
    safe_table.concat = function(t, sep, i, j)
        charge((j or #t) - (i or 1))
        local result = table.concat(t, sep, i, j)
        charge(#result / 32)
        return result
    end
    safe_table.insert = function(t, ...)
        if select("#", ...) == 2 then
            local pos = ...
            if type(pos) == "number" then charge(#t - pos) end
        end
        return table.insert(t, ...)
    end
    safe_table.sort = function(t, cmp)
        local n = #t
        charge(n * math.log(n + 1))
        return table.sort(t, cmp)
    end

    local safe_coroutine = copy(coroutine, "create running status wrap yield")
    safe_coroutine.resume = function(co, ...) return check(coroutine.resume(co, ...)) end

    local world = {}
    self.world = world

    -- Player input runs in a throwaway environment that reads through to the
    -- world but refuses to assign globals.
    local function scratch_env()
        return setmetatable({}, {
            __index = function(env, k)
                if k == "_G" then return env end
                return world[k]
            end,
            __newindex = function(_, k)
                error("can't set global '" .. tostring(k) .. "': only the rules can change the world (see help())", 2)
            end,
            __metatable = "the world (read-only)",
        })
    end

    -- The rules' persistent data: plain data that only rule code can reach.
    -- Every run commits it (saving it if it changed) or, if the run fails,
    -- rolls it back to the last commit.
    local state = {}
    local committed, owned = store.serialize(state)
    local saving = true

    local function rollback_state(text)
        store.restore_into(state, store.deserialize(text), owned)
        owned = select(2, store.serialize(state))
    end

    local persist, atomic
    local persisting = false

    -- Runs rule code with the world as its environment, passing it the rule
    -- capabilities (persist, state, atomic) as arguments. If it fails, the
    -- world's globals are rolled back.
    local function apply(code, name, author)
        if type(code) ~= "string" then error("persist(code): code must be a string", 3) end
        if persisting then error("persist() can't be called from inside persisted code", 3) end
        author = author or current_user
        name = name or ("=" .. tostring(author or "?") .. " (rule)")
        local fn, err = load(code, name, "t", world)
        if not fn then error(err, 0) end
        local snapshot = {}
        for k, v in pairs(world) do snapshot[k] = v end
        local caller = current_user
        persisting, current_user = true, author
        local ok, run_err = pcall(fn, persist, state, atomic)
        persisting, current_user = false, caller
        if not ok then
            -- Pause the hook: if a limit was hit, it would abort the rollback
            debug.sethook()
            for k in pairs(world) do world[k] = nil end
            for k, v in pairs(snapshot) do world[k] = v end
            debug.sethook(hook, "", HOOK_STEP)
            error(run_err, 0)
        end
        -- Report which globals the code added, changed and removed
        local diff = {added = {}, changed = {}, removed = {}}
        for k, v in pairs(world) do
            if snapshot[k] == nil then
                table.insert(diff.added, tostring(k))
            elseif not rawequal(snapshot[k], v) then
                table.insert(diff.changed, tostring(k))
            end
        end
        for k in pairs(snapshot) do
            if world[k] == nil then table.insert(diff.removed, tostring(k)) end
        end
        for _, names in pairs(diff) do table.sort(names) end
        return diff
    end

    local function describe_change(user, code, diff)
        local parts = {}
        for _, what in ipairs({"added", "changed", "removed"}) do
            if #diff[what] > 0 then
                table.insert(parts, what .. " " .. table.concat(diff[what], ", "))
            end
        end
        local summary = #parts > 0 and table.concat(parts, "; ") or "no globals changed"
        -- Trim surrounding whitespace, but keep the first line's indentation
        -- if the code starts on its own line, so multi-line code stays
        -- aligned. (Done in Lua: C patterns like "%s*$" can be quadratic.)
        local first, last = string.find(code, "%S") or 1, #code
        local line_start = first
        while line_start > 1 and string.find(string.sub(code, line_start - 1, line_start - 1), "^[ \t]") do
            line_start = line_start - 1
        end
        if line_start > 1 then first = line_start end
        while last >= first and string.find(string.sub(code, last, last), "^%s") do last = last - 1 end
        code = string.sub(code, first, last)
        return "Rule change by " .. tostring(user) .. " took effect (" .. summary .. "):\n" .. code
    end

    -- Changes the rules: runs code as rule code and records it so it's
    -- replayed on restart. Only rule code is given this function.
    persist = function(code, author)
        if author ~= nil and type(author) ~= "string" then
            error("persist(code, author): author must be a string", 2)
        end
        author = author or current_user
        local diff = apply(code, nil, author)
        host.persisted(code, author)
        local message = describe_change(author, code, diff)
        for _, user in ipairs(host.users()) do
            host.send(user, message, "persist")
        end
    end

    -- Runs fn(...); if it errors, undoes its changes to state and its timers,
    -- then re-raises. (Messages it sent and rule changes it made stay.)
    atomic = function(fn, ...)
        local snapshot = store.serialize(state)
        local savepoint = host.savepoint()
        local results = pack(pcall(fn, ...))
        if exhausted then error(exhausted, 0) end
        if not results[1] then
            rollback_state(snapshot)
            host.rollback_to(savepoint)
            error(results[2], 0)
        end
        return unpack(results, 2, results.n)
    end

    local base = {
        _VERSION = _VERSION,
        _G = world,
        assert = assert, error = error, ipairs = ipairs, next = next, pairs = pairs,
        rawequal = rawequal, rawget = rawget, rawset = rawset, select = select,
        tonumber = tonumber, tostring = tostring, type = type,
        getmetatable = getmetatable, setmetatable = setmetatable,
        unpack = function(t, i, j)
            i, j = i or 1, j or #t
            charge(j - i)
            return unpack(t, i, j)
        end,
        pcall = function(f, ...) return check(pcall(f, ...)) end,
        xpcall = function(f, handler, ...) return check(xpcall(f, handler, ...)) end,
        load = function(chunk, name)
            if type(chunk) ~= "string" then return nil, "load() only accepts strings" end
            return load(chunk, name and tostring(name) or "=(load)", "t", scratch_env())
        end,
        string = safe_string,
        table = readonly(safe_table),
        math = readonly(copy(math, "abs acos asin atan atan2 ceil cos cosh deg exp floor fmod frexp huge ldexp log log10 max min modf pi pow rad random randomseed sin sinh sqrt tan tanh")),
        bit = readonly(copy(bit, "tobit tohex bnot band bor bxor lshift rshift arshift rol ror bswap")),
        os = readonly(copy(os, "clock date difftime time")),
        coroutine = readonly(safe_coroutine),

        -- Server primitives. Everything friendlier (print, announce, say...)
        -- is defined in the world by prelude.lua so players can replace it.
        me = function() return current_user end,
        users = function() return host.users() end,
        send = function(user, text, kind)
            text = tostring(text)
            charge(#text / 32)
            return host.send(tostring(user), text, kind and tostring(kind) or "text")
        end,
        after = function(seconds, fn)
            if type(seconds) ~= "number" then error("after(seconds, fn): seconds must be a number", 2) end
            if type(fn) ~= "function" then error("after(seconds, fn): fn must be a function", 2) end
            local ok, err = host.schedule(seconds, fn, current_user)
            if not ok then error(err, 2) end
        end,
    }
    base.loadstring = base.load
    setmetatable(world, {__index = base, __metatable = "the world"})

    -- Runs fn(...) as `user` under the sandbox limits.
    -- Returns true, results... or false, error_message.
    function self.run(_, user, fn, ...)
        assert(not running, "sandbox runs can't be nested")
        budget, deadline, exhausted = instruction_limit, net.now() + time_limit, nil
        current_user, running = user, true
        host.begin()
        debug.sethook(hook, "", HOOK_STEP)
        local results = pack(xpcall(fn, function(err)
            if type(err) == "string" then return err end
            local ok, s = pcall(tostring, err)
            return ok and type(s) == "string" and s or "(error object of type " .. type(err) .. ")"
        end, ...))
        debug.sethook()
        current_user, running = nil, false
        -- Commit the rules' state, or roll it back if the run failed
        if results[1] then
            local ok, text, tables = pcall(store.serialize, state)
            if not ok then
                results = pack(false, "the rules' state was rejected: " .. text)
            else
                owned = tables
                if text ~= committed then
                    committed = text
                    if saving then host.save_state(text) end
                end
            end
        end
        if not results[1] then rollback_state(committed) end
        host.finish(results[1])
        if collectgarbage("count") > memory_limit_kb / 2 then collectgarbage() end
        return unpack(results, 1, results.n)
    end

    -- Compiles player input in a scratch environment, where it can read the
    -- world but not assign globals. Tries it as an expression first so that
    -- typing `1 + 2` shows a result, like a REPL.
    function self.compile(_, code, name)
        local env = scratch_env()
        if load("return " .. code, name, "t", env) then
            -- Evaluate the expression as a function argument rather than as
            -- a tail call, so error("x") blames the player's line, not ours.
            local fn = load("return (...)(1, " .. code .. "\n)", name, "t", env)
            if fn then return function() return fn(select) end end
            return load("return " .. code, name, "t", env)
        end
        return load(code, name, "t", env)
    end

    -- Applies rule code as `user` without recording or announcing it, for
    -- the prelude and for replaying the rule log at startup.
    function self.apply(_, user, code, name)
        return self:run(user, apply, code, name, user)
    end

    -- Starts the game: `setup` applies the prelude and replays the rule log.
    -- Replayed code may reset parts of the state (e.g. `state.points = {}`),
    -- so afterwards the saved state wins for every key it has; only keys that
    -- setup created and the save lacks are kept.
    function self.start(_, saved_text, setup)
        saving = false
        if saved_text then rollback_state(saved_text) end
        committed = store.serialize(state)
        setup()
        if saved_text then
            local merged = store.deserialize(saved_text)
            for k, v in pairs(store.deserialize(committed)) do
                if merged[k] == nil then merged[k] = v end
            end
            rollback_state(store.serialize(merged))
            committed = store.serialize(state)
        end
        saving = true
        if committed ~= saved_text then host.save_state(committed) end
    end

    return self
end

return Sandbox
