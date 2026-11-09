-- Checks that state survives a round trip through the serializer
package.path = "lib/?.lua;" .. package.path
local store = require("store")

local failures = 0
local function expect(cond, what)
    if not cond then
        failures = failures + 1
        print("FAIL " .. what)
    end
end

local original = {
    ["end"]="keyword key", ["with space"]=1, [true]=false, [1.5]="float key",
    big=2^60, small=-0.1, inf=math.huge, ninf=-math.huge, nan=0/0,
    text="quote \" backslash \\ newline \n nul \0 high \255",
    list={1, 2, {3, {4}}},
    int=3, float=3.0, negzero=-0.0, maxint=math.maxinteger, minint=math.mininteger,
    global="reserved in some Lua 5.5 builds",
}
local text = store.serialize(original)
local copy = store.deserialize(text)
expect(copy["end"] == "keyword key" and copy["with space"] == 1 and copy[true] == false
    and copy[1.5] == "float key", "keys")
expect(copy.big == 2^60 and copy.small == -0.1 and copy.inf == math.huge and copy.ninf == -math.huge
    and copy.nan ~= copy.nan, "numbers")
expect(copy.text == original.text, "string escapes")
expect(math.type(copy.int) == "integer" and math.type(copy.float) == "float" and copy.float == 3
    and 1 / copy.negzero == -math.huge and copy.maxint == math.maxinteger and copy.minint == math.mininteger
    and copy.global == original.global, "integers and floats")
expect(copy.list[3][2][1] == 4, "nested lists")
expect(store.serialize(copy) == text, "serializing is deterministic")

local function rejects(value, message)
    local ok, err = pcall(store.serialize, value)
    expect(not ok and string.find(err, message, 1, true), "rejects " .. message .. " (got " .. tostring(err) .. ")")
end
local cycle = {}
cycle.self = cycle
rejects(cycle, "state.self is the same table as state")
rejects({f=print}, "state.f is a function")
rejects({[{}]=1}, "has a table key")
rejects({t=setmetatable({}, {})}, "state.t has a metatable")
local deep = {}
for _ = 1, 150 do deep = {deep} end
rejects(deep, "nested too deeply")

-- Restoring in place keeps nested tables that were already part of the state
local live = {a={x=1}, gone=true}
local _, owned = store.serialize(live)
local a = live.a
store.restore_into(live, store.deserialize("{a={x=2}, b=3}"), owned)
expect(live.a == a and a.x == 2 and live.b == 3 and live.gone == nil, "restore_into reuses owned tables")
-- ...but never into a table that wasn't part of the state
local foreign = {keep="me"}
live.a = foreign
store.restore_into(live, store.deserialize("{a={x=3}}"), owned)
expect(live.a ~= foreign and foreign.keep == "me" and live.a.x == 3, "restore_into leaves foreign tables alone")

if failures > 0 then
    print(failures .. " store test(s) failed")
    os.exit(1)
end
print("store: ok")
