-- Checks that the history file survives writes that were cut short
package.path = "lib/?.lua;" .. package.path
local History = require("history")
local store = require("store")

local failures = 0
local function expect(cond, what)
    if not cond then
        failures = failures + 1
        print("FAIL " .. what)
    end
end

local path = os.tmpname()
local function contents()
    local f = assert(io.open(path, "rb"))
    local text = f:read("a")
    f:close()
    return text
end
local function overwrite(text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end
local function players(entries)
    local names = {}
    for i, entry in ipairs(entries) do names[i] = entry.player end
    return table.concat(names, " ")
end
local function entry(player) return {player=player, request={type="join", args={}}, recorded={}} end

-- A missing file is an empty history
os.remove(path)
local history, entries = History.open(path)
expect(#entries == 0, "a missing file has no entries")
local all = {}
for _, name in ipairs({"alice", "bob"}) do
    all[#all + 1] = entry(name)
    expect(history:append(all[#all], all), "appending works")
end
local _
_, entries = History.open(path)
expect(players(entries) == "alice bob", "appended entries are loaded")

-- An entry that was cut short is dropped, and the next one isn't glued onto it
local whole = contents()
overwrite(whole .. string.sub(store.serialize(entry("carol")), 1, 20))
local dropped
history, entries, dropped = History.open(path)
expect(players(entries) == "alice bob" and dropped and string.find(dropped, "carol", 1, true),
    "an unfinished entry is dropped (got " .. players(entries) .. ")")
expect(contents() == whole, "the unfinished entry is removed from the file")
all = {entry("alice"), entry("bob"), entry("dave")}
history:append(all[3], all)
_, entries = History.open(path)
expect(players(entries) == "alice bob dave", "appending after a cut-short entry works (got "
    .. players(entries) .. ")")

-- An entry missing only (part of) its separator is kept
for _, ending in ipairs({"", "\n", "\n-", "\n--"}) do
    overwrite(whole .. store.serialize(entry("erin")) .. ending)
    local _, kept, unfinished = History.open(path)
    expect(players(kept) == "alice bob erin" and not unfinished,
        "an entry without its separator " .. string.format("%q", ending) .. " is kept")
end

-- After a failed save, the next save writes the whole history
overwrite(whole)
history = History.open(path)
history.path = path .. "/not-a-file"
all = {entry("alice"), entry("bob"), entry("frank")}
expect(not history:append(all[3], all), "a failed save is reported")
history.path = path
all[4] = entry("grace")
expect(history:append(all[4], all), "saving after a failure works")
_, entries = History.open(path)
expect(players(entries) == "alice bob frank grace", "saving after a failure saves everything (got "
    .. players(entries) .. ")")

os.remove(path)
if failures > 0 then
    print(failures .. " history test(s) failed")
    os.exit(1)
end
print("history: ok")
