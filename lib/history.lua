-- The file where the game's history is saved, so it can be replayed on startup.
--
-- Entries are saved with a "--" line after each, which can't appear inside a quoted
-- string in the saved data (newlines in strings are written with a backslash). So the
-- file is always some complete entries, each followed by "\n--\n", and if a write was
-- cut short (by a crash, or a full disk), some text after the last separator.
--
-- An append that fails might have written part of an entry, and appending after that
-- would glue the next entry onto it, or nothing, and appending after that would leave a
-- gap in the history. So after any failure, the next save writes the whole
-- history to a new file and renames it over the old one.
local store = require("store")

local SEPARATOR = "\n--\n"
local SEPARATOR_PATTERN = "\n%-%-\n"

local History = {}
History.__index = History

-- Returns the history file and the entries saved in it. If the file ends with part of
-- an entry, that part is dropped, and also returned as the third value.
function History.open(path)
    local self = setmetatable({path=path, broken=false}, History)
    local entries = {}
    local f = io.open(path, "rb")
    if not f then return self, entries end
    local text = f:read("a")
    f:close()
    local finished = 0
    for entry, after in string.gmatch(text, "(.-)" .. SEPARATOR_PATTERN .. "()") do
        entries[#entries + 1] = store.deserialize(entry)
        finished = after - 1
    end
    local partial = string.sub(text, finished + 1)
    if partial ~= "" then
        -- The write might have only missed (part of) the separator
        local ok, entry = pcall(store.deserialize, (string.gsub(partial, "\n%-?%-?$", "")))
        if ok then
            entries[#entries + 1] = entry
            partial = nil
        end
        -- Start a fresh file, so the next entry isn't appended to the partial one
        self.broken = true
        assert(self:rewrite(entries))
        return self, entries, partial
    end
    return self, entries
end

local function write_all(f, entries)
    for _, entry in ipairs(entries) do
        local ok, err = f:write(store.serialize(entry), SEPARATOR)
        if not ok then return nil, err end
    end
    return true
end

-- Replaces the file with one that has exactly these entries
function History:rewrite(entries)
    local temp = self.path .. ".tmp"
    local f, err = io.open(temp, "wb")
    if not f then return nil, err end
    local ok, write_err = write_all(f, entries)
    local closed, close_err = f:close()
    if ok and closed then ok, err = os.rename(temp, self.path) end
    if not (ok and closed) then
        os.remove(temp)
        return nil, write_err or close_err or err
    end
    self.broken = false
    return true
end

-- Saves an entry. `entries` is the whole history, ending with this entry, which is
-- saved instead if an earlier save failed.
function History:append(entry, entries)
    if self.broken then return self:rewrite(entries) end
    local f, err = io.open(self.path, "ab")
    if not f then
        -- The file is missing this entry now, so it has to be rewritten too
        self.broken = true
        return nil, err
    end
    local ok, write_err = f:write(store.serialize(entry), SEPARATOR)
    -- Buffered writes can fail when the file is closed
    local closed, close_err = f:close()
    if not (ok and closed) then
        self.broken = true
        return nil, write_err or close_err
    end
    return true
end

return History
