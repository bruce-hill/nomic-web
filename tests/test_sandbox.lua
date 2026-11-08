-- Checks that the sandbox contains escape attempts and enforces its limits
package.path = "lib/?.lua;" .. package.path
local net = require("net")
net.limit_memory(1024 * 1024 * 1024)
local Sandbox = require("sandbox")

local saved, messages, timers, saved_state = {}, {}, {}, nil
local pending
local host = {
    send = function(user, text, kind)
        messages[#messages + 1] = user .. "|" .. kind .. "|" .. text
        return true
    end,
    users = function() return {"alice", "bob"} end,
    schedule = function(_, fn) pending[#pending + 1] = fn; return true end,
    begin = function() pending = {} end,
    finish = function(ok)
        if ok then for _, fn in ipairs(pending) do timers[#timers + 1] = fn end end
    end,
    savepoint = function() return #pending end,
    rollback_to = function(n) for i = #pending, n + 1, -1 do pending[i] = nil end end,
    persisted = function(code, author) saved[#saved + 1] = author .. ": " .. code end,
    save_state = function(text) saved_state = text end,
}
local sb = Sandbox.new({host = host})

local failures = 0
-- expect: true for success, or a substring of the expected error message
local function check(code, expect, value)
    local fn, err = sb:compile(code, "=test")
    local ok, result
    if fn then
        ok, result = sb:run("alice", fn)
    else
        ok, result = false, err
    end
    local passed
    if expect == true then
        passed = ok and (value == nil or result == value)
    else
        passed = not ok and string.find(tostring(result), expect, 1, true) ~= nil
    end
    if not passed then
        failures = failures + 1
        print(string.format("FAIL %s\n  got: %s %s", code, tostring(ok), tostring(result)))
    end
end

local LIMIT = "instruction limit exceeded"
check("while true do end", LIMIT)
check("local function f() while true do end end; while true do pcall(f) end", LIMIT)
check("while true do coroutine.resume(coroutine.create(function() while true do end end)) end", LIMIT)
check("coroutine.wrap(function() while true do end end)()", LIMIT)
check("return string.rep('a', 1e9)", "too large")
check("return ('a'):rep(1e9)", "too large")
check("local s = ('a'):rep(1e6); while true do s = s .. s end", "memory limit exceeded")
check("return (('a'):rep(100000)):find(('.-'):rep(20) .. 'b')", LIMIT)
check("return string.find(('a'):rep(30), ('a?'):rep(30) .. ('a'):rep(30))", LIMIT)
check("local t = {}; for i = 1, 1e9 do t[i] = ('x'):rep(1000) .. i end", LIMIT)
check("local t = {} for i = 1, 1000 do t[i] = i end return unpack(t, 1, 1e8)", LIMIT)
check("error(setmetatable({}, {__tostring = function() while true do end end}))", "error object of type table")

check("return getmetatable('')", true, false)
check("return io or os.execute or require or debug or jit or ffi or getfenv or setfenv or dofile or loadfile or newproxy or string.dump", true, nil)
check("string.rep = nil", "read-only")
check("setmetatable(_G, nil)", "protected metatable")
check("return load('\\27LJ')", true, nil)
check("error('boom')", "test:1: boom")

local function expect(cond, what)
    if not cond then
        failures = failures + 1
        print("FAIL " .. what)
    end
end

-- Player input can't change the world or reach the rule capabilities
local READONLY = "only the rules can change the world"
check("x = 5", READONLY)
check("function f() end", READONLY)
check("_G.x = 5", READONLY)
check("rawset(_G, 'x', 5); return x", true, nil)
check("load('x = 5')()", READONLY)
check("local x = 5; return x", true, 5)
check("return persist == nil and state == nil and atomic == nil", true, true)

-- Rule code gets the capabilities. This test rule leaks them as globals so
-- the checks below can use them directly.
local ok, err = sb:apply("alice", [[
    local persist, state, atomic = ...
    P, S, A = persist, state, atomic
    state.list = state.list or {}
    local list = state.list
    function add(v) list[#list + 1] = v end
    function count() return #state.list end
]])
expect(ok, "applying a rule: " .. tostring(err))
expect(#saved == 0 and #messages == 0, "apply() doesn't record or announce")

-- persist() applies, rolls back on failure, and refuses to nest
check("P[[ x = 5; function greet() return 'hi ' .. me() end ]]", true)
check("return x, greet()", true, 5)
check("P([[ function whoami() return me() end ]], 'bob'); return whoami()", true, "alice")
check("P[[ who_wrote = me() ]]; return who_wrote", true, "alice")
check("P([[ who_wrote = me() ]], 'bob'); return who_wrote", true, "bob")
check("P[[ function inc() x = x + 1 end ]]; inc(); inc(); return x", true, 7)
check("P[[ y = 1; error('nope') ]]", "nope")
check("return y", true, nil)
check("P[[ z = 1; while true do end ]]", LIMIT)
check("return z", true, nil)
check("P[[ local persist = ...; persist'w = 1' ]]", "inside persisted code")
check("P('x = ')", "unexpected symbol")
check("return x", true, 7)
check("P([[ x = 1 ]], {})", "author must be a string")
expect(#saved == 5 and saved[2] == "bob:  function whoami() return me() end ", "saved rule changes: " .. table.concat(saved, " | "))

-- Successful rule changes are announced to everyone, with what changed
messages = {}
check("P[[ x = nil; greet = function() end; q = 1 ]]", true)
local announcement = "Rule change by alice took effect (added q; changed greet; removed x):\nx = nil; greet = function() end; q = 1"
expect(messages[1] == "alice|persist|" .. announcement and messages[2] == "bob|persist|" .. announcement
    and #messages == 2, "persist announcement: " .. table.concat(messages, " || "))
messages = {}
check("P[[ error('no') ]]", "no")
expect(#messages == 0, "failed rule changes aren't announced")

-- State is committed when a run succeeds and rolled back when it fails
saved_state = nil
check("S.score = 10", true)
expect(saved_state and saved_state:find("score = 10", 1, true), "state saved after change: " .. tostring(saved_state))
saved_state = nil
check("return S.score", true, 10)
expect(saved_state == nil, "unchanged state isn't saved again")
check("S.score = 20; error('oops')", "oops")
check("return S.score", true, 10)
check("S.score = 30; while true do end", LIMIT)
check("return S.score", true, 10)
check("S.score = 40; pcall(function() while true do end end)", LIMIT)
check("return S.score", true, 10)
check("S.f = function() end", "state.f is a function")
check("return S.f", true, nil)
check("S.a = {}; S.b = S.a", "state.b is the same table as state.a")
check("return S.a", true, nil)
check("S.nested = {deep = {['key with spaces'] = {1, 2, true}}}", true)
check("return S.nested.deep['key with spaces'][3]", true, true)

-- Rule code holding a reference into state keeps working after a rollback
check("add('a')", true)
check("add('b'); error('undo')", "undo")
check("return count()", true, 1)
check("add('c'); return count()", true, 2)

-- Timers only start if the run that scheduled them succeeds
timers = {}
check("after(1, function() end); error('no')", "no")
check("after(1, function() end)", true)
expect(#timers == 1, "timers from failed runs are dropped (" .. #timers .. " timers)")

-- atomic() undoes state changes and timers when its function fails
timers = {}
check("local ok = pcall(A, function() S.score = 99; after(1, function() end); error('x') end); return ok", true, false)
check("return S.score", true, 10)
expect(#timers == 0, "atomic() drops timers from its failed function")
check("return A(function(a, b) S.score = a + b; return S.score end, 2, 3)", true, 5)
check("S.score = 10", true)

-- Restarting: the saved state wins over what replayed rule code sets up, but
-- keys only created during setup are kept
local text = saved_state
local restarted = Sandbox.new({host = host})
restarted:start(text, function()
    assert(restarted:apply(nil, "local persist, state = ...; S2 = state; state.score = 0; state.fresh = 'new'"))
end)
local ok2, score, fresh = restarted:run("alice", restarted:compile("return S2.score, S2.fresh, #S2.list", "=test"))
expect(ok2 and score == 10 and fresh == "new", "state after restart: " .. tostring(score) .. ", " .. tostring(fresh))
sb = restarted

if failures > 0 then
    print(failures .. " sandbox test(s) failed")
    os.exit(1)
end
print("sandbox: ok")
