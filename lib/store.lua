-- Saving and restoring the rules' persistent `state` table. State must be
-- plain data (strings, numbers, booleans and tables of them) with no cycles,
-- shared tables or metatables, so it can be written out as a Lua literal and
-- read back exactly.
local store = {}

-- Lua can't parse table literals nested ~200 deep
local MAX_DEPTH = 100

local keywords = {}
for word in string.gmatch("and break do else elseif end false for function global goto if in local nil not or repeat return then true until while", "%S+") do
    keywords[word] = true
end

local function is_identifier(k)
    return type(k) == "string" and not keywords[k] and string.find(k, "^[%a_][%w_]*$") ~= nil
end

local function path_to(path, k)
    if is_identifier(k) then return path .. "." .. k end
    return path .. "[" .. (type(k) == "string" and string.format("%q", k) or tostring(k)) .. "]"
end

local function format_number(n)
    if math.type(n) == "integer" then return string.format("%q", n) end
    if n ~= n then return "0/0" end
    if n == math.huge then return "1/0" end
    if n == -math.huge then return "-1/0" end
    local text = string.format("%.17g", n)
    -- Keep floats like 3.0 from coming back as integers
    return string.find(text, "^-?%d+$") and text .. ".0" or text
end

local key_type_order = {boolean=1, number=2, string=3}
local function key_less(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return key_type_order[ta] < key_type_order[tb] end
    if ta == "boolean" then return not a and b end
    return a < b
end

-- Returns the state as Lua source, plus the set of tables it contains.
-- Raises an error naming the offending path if the state isn't plain data.
function store.serialize(value)
    local out, seen = {}, {}
    local function write(v, path, depth)
        local t = type(v)
        if t == "string" then
            out[#out + 1] = string.format("%q", v)
        elseif t == "number" then
            out[#out + 1] = format_number(v)
        elseif t == "boolean" then
            out[#out + 1] = tostring(v)
        elseif t == "table" then
            if seen[v] then
                error(path .. " is the same table as " .. seen[v] .. " (state can't share tables or have cycles)", 0)
            end
            if debug.getmetatable(v) ~= nil then
                error(path .. " has a metatable (state can only hold plain tables)", 0)
            end
            if depth > MAX_DEPTH then error(path .. " is nested too deeply", 0) end
            seen[v] = path
            local keys = {}
            for k in next, v do
                if not key_type_order[type(k)] then
                    error(path .. " has a " .. type(k) .. " key (keys must be strings, numbers or booleans)", 0)
                end
                keys[#keys + 1] = k
            end
            if #keys == 0 then
                out[#out + 1] = "{}"
                return
            end
            table.sort(keys, key_less)
            local indent = string.rep("  ", depth)
            out[#out + 1] = "{\n"
            for _, k in ipairs(keys) do
                out[#out + 1] = indent .. "  "
                if is_identifier(k) then
                    out[#out + 1] = k
                else
                    out[#out + 1] = "["
                    write(k, path, depth + 1)
                    out[#out + 1] = "]"
                end
                out[#out + 1] = "="
                write(rawget(v, k), path_to(path, k), depth + 1)
                out[#out + 1] = ",\n"
            end
            out[#out + 1] = indent .. "}"
        else
            error(path .. " is a " .. t .. " (state can only hold strings, numbers, booleans and tables)", 0)
        end
    end
    write(value, "state", 0)
    return table.concat(out), seen
end

function store.deserialize(text)
    local fn, err = load("return " .. text, "=state", "t", {})
    if not fn then error("corrupt state: " .. err, 0) end
    local value = fn()
    if type(value) ~= "table" then error("corrupt state: not a table", 0) end
    return value
end

-- Makes `target` match `source`, reusing nested tables listed in `owned`
-- (tables that were part of the state before) so rule code holding
-- references to them, like `local proposals = state.proposals`, stays valid.
function store.restore_into(target, source, owned, used)
    used = used or {[target]=true}
    debug.setmetatable(target, nil)
    for k in next, target do
        if rawget(source, k) == nil then rawset(target, k, nil) end
    end
    for k, v in next, source do
        local current = rawget(target, k)
        if type(v) == "table" and type(current) == "table" and owned[current] and not used[current] then
            used[current] = true
            store.restore_into(current, v, owned, used)
        else
            rawset(target, k, v)
        end
    end
end

return store
