-- Checks that the pure-Lua pattern matcher behaves exactly like LuaJIT's C one
package.path = "lib/?.lua;" .. package.path
local P = require("patterns")
local ws = require("websocket")
local json = require("json")

assert(ws.accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "websocket accept key")
assert(json.encode({text = "a\"\n\255\1"}) == '{"text":"a\\"\\n\239\191\189\\u0001"}', "json encoding")

local function results(...)
    local t = {n = select("#", ...), ...}
    for i = 1, t.n do t[i] = tostring(t[i]) end
    -- Error messages may differ in the "file:line:" location they start with
    if t[1] == "false" then t[2] = string.gsub(t[2], "^[^:]+:%d+: ", "") end
    return table.concat(t, ",", 1, t.n)
end

local cases = {
    {"hello world", "o", 1}, {"hello world", "(o)(r)"}, {"hello world", "%w+"}, {"  trim  ", "^%s*(.-)%s*$"},
    {"key = value", "(%w+)%s*=%s*(%w+)"}, {"THE (quick) fox", "%((%a+)%)"}, {"f(a(b)c)d", "%b()"},
    {"THE (quick) fox", "%f[%a]%a+"}, {"abcabc", "(abc)%1"}, {"hello", "()ll()"}, {"x=1, y=2", "[^,]+"},
    {"aaa", "a-b"}, {"aaab", "a-b"}, {"test123", "[%a_][%w_]*$"}, {"a.b", "%."}, {"abc", "[a-b]+"},
    {"]x", "[]]"}, {"a-z", "[a%-z]+"}, {"hello", "l+", -3}, {"hello", "xyz"}, {"", ".*"}, {"abc", "^b"},
    {"hello", "", 10}, {"a+b", "+", 1, true}, {"äbc", "[\128-\255]+"},
    {"abc", "%"}, {"abc", "[a"}, {"abc", "(a"}, {"abc", "a)"}, {"abc", "%1"}, {"abc", "%b"},
}
local replacements = {"<%0>", "%1", {hello = "X", o = "O"}, function(x) return x == "l" and "L" or nil end}

local failures = 0
local function compare(what, c_fn, lua_fn, ...)
    local expected, got = results(pcall(c_fn, ...)), results(pcall(lua_fn, ...))
    if expected ~= got then
        failures = failures + 1
        print(string.format("FAIL %s(%s): expected %s, got %s", what, results(...), expected, got))
    end
end

for _, c in ipairs(cases) do
    compare("find", string.find, P.find, unpack(c, 1, 4))
    compare("match", string.match, P.match, c[1], c[2], c[3])
    local function all_matches(gmatch)
        return function(s, p)
            local out = {}
            for x, y in gmatch(s, p) do out[#out + 1] = tostring(x) .. ":" .. tostring(y) end
            return table.concat(out, "|")
        end
    end
    compare("gmatch", all_matches(string.gmatch), all_matches(P.gmatch), c[1], c[2])
    for _, r in ipairs(replacements) do
        compare("gsub", string.gsub, P.gsub, c[1], c[2], r)
    end
    compare("gsub", string.gsub, P.gsub, c[1], c[2], "#", 1)
end

if failures > 0 then
    print(failures .. " pattern test(s) failed")
    os.exit(1)
end
print("patterns: ok")
