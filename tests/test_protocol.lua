-- Checks JSON encoding and WebSocket framing
package.path = "lib/?.lua;" .. package.path
local ws = require("websocket")
local json = require("json")

assert(ws.accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "websocket accept key")
assert(json.encode({text = "a\"\n\255\1"}) == '{"text":"a\\"\\n\239\191\189\\u0001"}', "json encoding")
assert(json.encode({rules = {}}) == '{"rules":[]}', "empty tables are arrays")
assert(json.utf8_sanitize("ok\237\160\128é\226") == "ok\239\191\189\239\191\189\239\191\189é\239\191\189", "surrogates and truncated sequences")
do
    local frame, next_pos = ws.decode("\129\133\1\2\3\4" .. "i`ol\110", 1, 1024)
    assert(frame and frame.payload == "hblho" and frame.fin and next_pos == 12, "unmasking a frame")
    local bad, why = ws.decode("\129\255\255\255\255\255\255\255\255\255" .. string.rep("\0", 16), 1, 1024)
    assert(bad == false and why == "frame too large", "64-bit lengths that overflow are rejected")
end

print("protocol: ok")
