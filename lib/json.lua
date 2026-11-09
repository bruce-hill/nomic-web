-- JSON encoding for messages to the browser. Output is forced to valid UTF-8
-- because browsers drop WebSocket connections that receive invalid UTF-8 in
-- text frames, and cjson passes invalid bytes straight through.
local cjson = require("cjson").new()
cjson.encode_empty_table_as_object(false)
cjson.encode_invalid_numbers("null")

local json = {}

local REPLACEMENT = "\239\191\189" -- U+FFFD

function json.utf8_sanitize(s)
    local out, start = {}, 1
    while true do
        local len, bad = utf8.len(s, start)
        if len then break end
        out[#out + 1] = string.sub(s, start, bad - 1)
        out[#out + 1] = REPLACEMENT
        start = bad + 1
    end
    out[#out + 1] = string.sub(s, start)
    return table.concat(out)
end

function json.encode(v)
    return json.utf8_sanitize(cjson.encode(v))
end

return json
