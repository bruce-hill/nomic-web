-- WebSocket (RFC 6455) handshake and framing.
local sha1 = require("sha1")
local base64 = require("base64")
local byte, char, sub = string.byte, string.char, string.sub

local ws = {
    TEXT = 1, BINARY = 2, CONTINUATION = 0, CLOSE = 8, PING = 9, PONG = 10,
}

function ws.accept_key(key)
    return base64.encode((sha1.binary(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")))
end

-- Try to decode one frame from `buf` starting at `pos`.
-- Returns frame, next_pos when a full frame is available; nil when more data
-- is needed; or false, error_message on a protocol violation.
function ws.decode(buf, pos, max_size)
    local avail = #buf - pos + 1
    if avail < 2 then return nil end
    local b1, b2 = byte(buf, pos, pos + 1)
    local frame = {fin = b1 & 0x80 ~= 0, opcode = b1 & 0x0f}
    if b1 & 0x70 ~= 0 then return false, "reserved bits set" end
    if b2 & 0x80 == 0 then return false, "client frames must be masked" end
    local len, hdr = b2 & 0x7f, 2
    if len == 126 then
        if avail < 4 then return nil end
        local x, y = byte(buf, pos + 2, pos + 3)
        len, hdr = x * 256 + y, 4
    elseif len == 127 then
        if avail < 10 then return nil end
        len = 0
        for i = 2, 9 do len = len * 256 + byte(buf, pos + i) end
        hdr = 10
    end
    if len < 0 or len > max_size then return false, "frame too large" end
    if avail < hdr + 4 + len then return nil end
    local mstart = pos + hdr
    local m = {byte(buf, mstart, mstart + 3)}
    local data = {}
    for i = 0, len - 1 do
        data[i + 1] = char(byte(buf, mstart + 4 + i) ~ m[i % 4 + 1])
    end
    frame.payload = table.concat(data)
    return frame, mstart + 4 + len
end

function ws.encode(opcode, payload)
    local len = #payload
    local head
    if len < 126 then
        head = char(0x80 | opcode, len)
    elseif len < 65536 then
        head = char(0x80 | opcode, 126, len >> 8, len & 255)
    else
        head = char(0x80 | opcode, 127, 0, 0, 0, 0, (len >> 24) & 255,
                    (len >> 16) & 255, (len >> 8) & 255, len & 255)
    end
    return head .. payload
end

return ws
