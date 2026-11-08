-- Just enough JSON encoding to send messages to the browser. Strings are
-- forced to valid UTF-8 because browsers drop WebSocket connections that
-- receive invalid UTF-8 in text frames.
local byte, sub, find, gsub, format = string.byte, string.sub, string.find, string.gsub, string.format
local concat = table.concat

local json = {}

local REPLACEMENT = "\239\191\189" -- U+FFFD

function json.utf8_sanitize(s)
    if not find(s, "[\128-\255]") then return s end
    local out, start, i, n = {}, 1, 1, #s
    while i <= n do
        local c = byte(s, i)
        local len
        if c < 0x80 then len = 1
        elseif c >= 0xC2 and c <= 0xDF then len = 2
        elseif c >= 0xE0 and c <= 0xEF then len = 3
        elseif c >= 0xF0 and c <= 0xF4 then len = 4
        end
        local ok = len ~= nil and i + len - 1 <= n
        if ok and len > 1 then
            for j = i + 1, i + len - 1 do
                local cc = byte(s, j)
                if cc < 0x80 or cc > 0xBF then ok = false; break end
            end
            local c2 = byte(s, i + 1)
            if ok and ((c == 0xE0 and c2 < 0xA0) or (c == 0xED and c2 > 0x9F)
                       or (c == 0xF0 and c2 < 0x90) or (c == 0xF4 and c2 > 0x8F)) then
                ok = false -- overlong encodings, surrogates, > U+10FFFF
            end
        end
        if ok then
            i = i + len
        else
            out[#out + 1] = sub(s, start, i - 1)
            out[#out + 1] = REPLACEMENT
            i = i + 1
            start = i
        end
    end
    out[#out + 1] = sub(s, start)
    return concat(out)
end

local escapes = {['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"}
local function escape_char(c)
    return escapes[c] or format("\\u%04x", byte(c))
end

local function encode(v)
    local t = type(v)
    if t == "string" then
        return '"' .. gsub(json.utf8_sanitize(v), '[%c"\\]', escape_char) .. '"'
    elseif t == "number" then
        return (v ~= v or v == math.huge or v == -math.huge) and "null" or format("%.14g", v)
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "nil" then
        return "null"
    elseif t == "table" then
        local parts = {}
        if #v > 0 or next(v) == nil then
            for i = 1, #v do parts[i] = encode(v[i]) end
            return "[" .. concat(parts, ",") .. "]"
        end
        for k, x in pairs(v) do
            parts[#parts + 1] = encode(tostring(k)) .. ":" .. encode(x)
        end
        return "{" .. concat(parts, ",") .. "}"
    end
    error("can't encode " .. t .. " as JSON")
end
json.encode = encode

return json
