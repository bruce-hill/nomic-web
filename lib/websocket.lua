-- WebSocket (RFC 6455) handshake and framing, including the SHA-1 and base64
-- needed for the handshake.
local bit = require("bit")
local ffi = require("ffi")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol, tobit = bit.lshift, bit.rshift, bit.rol, bit.tobit
local byte, char, sub, rep = string.byte, string.char, string.sub, string.rep

local ws = {
    TEXT = 1, BINARY = 2, CONTINUATION = 0, CLOSE = 8, PING = 9, PONG = 10,
}

local function sha1(msg)
    local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
    local bits = #msg * 8
    msg = msg .. "\128" .. rep("\0", (55 - #msg) % 64)
        .. "\0\0\0\0" .. char(band(rshift(bits, 24), 255), band(rshift(bits, 16), 255),
                              band(rshift(bits, 8), 255), band(bits, 255))
    local w = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            local a, b, c, d = byte(msg, chunk + i * 4, chunk + i * 4 + 3)
            w[i] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
        end
        for i = 16, 79 do
            w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
        end
        local a, b, c, d, e = h0, h1, h2, h3, h4
        for i = 0, 79 do
            local f, k
            if i < 20 then
                f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
            elseif i < 40 then
                f, k = bxor(b, c, d), 0x6ED9EBA1
            elseif i < 60 then
                f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
            else
                f, k = bxor(b, c, d), 0xCA62C1D6
            end
            local temp = tobit(rol(a, 5) + f + e + k + w[i])
            e, d, c, b, a = d, c, rol(b, 30), a, temp
        end
        h0, h1, h2, h3, h4 = tobit(h0 + a), tobit(h1 + b), tobit(h2 + c), tobit(h3 + d), tobit(h4 + e)
    end
    local out = {}
    for _, h in ipairs({h0, h1, h2, h3, h4}) do
        out[#out + 1] = char(band(rshift(h, 24), 255), band(rshift(h, 16), 255),
                             band(rshift(h, 8), 255), band(h, 255))
    end
    return table.concat(out)
end

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = byte(s, i, i + 2)
        local n = lshift(a, 16) + lshift(b or 0, 8) + (c or 0)
        local idx = {rshift(n, 18), band(rshift(n, 12), 63), band(rshift(n, 6), 63), band(n, 63)}
        local chunk = ""
        for j = 1, 4 do chunk = chunk .. sub(b64chars, idx[j] + 1, idx[j] + 1) end
        if not b then chunk = sub(chunk, 1, 2) .. "=="
        elseif not c then chunk = sub(chunk, 1, 3) .. "=" end
        out[#out + 1] = chunk
    end
    return table.concat(out)
end

function ws.accept_key(key)
    return base64(sha1(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
end

-- Try to decode one frame from `buf` starting at `pos`.
-- Returns frame, next_pos when a full frame is available; nil when more data
-- is needed; or false, error_message on a protocol violation.
function ws.decode(buf, pos, max_size)
    local avail = #buf - pos + 1
    if avail < 2 then return nil end
    local b1, b2 = byte(buf, pos, pos + 1)
    local frame = {fin = band(b1, 0x80) ~= 0, opcode = band(b1, 0x0f)}
    if band(b1, 0x70) ~= 0 then return false, "reserved bits set" end
    if band(b2, 0x80) == 0 then return false, "client frames must be masked" end
    local len, hdr = band(b2, 0x7f), 2
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
    if len > max_size then return false, "frame too large" end
    if avail < hdr + 4 + len then return nil end
    local mstart = pos + hdr
    local m = {byte(buf, mstart, mstart + 3)}
    local data = ffi.new("uint8_t[?]", len)
    ffi.copy(data, sub(buf, mstart + 4, mstart + 3 + len), len)
    for i = 0, len - 1 do
        data[i] = bxor(data[i], m[i % 4 + 1])
    end
    frame.payload = ffi.string(data, len)
    return frame, mstart + 4 + len
end

function ws.encode(opcode, payload)
    local len = #payload
    local head
    if len < 126 then
        head = char(bor(0x80, opcode), len)
    elseif len < 65536 then
        head = char(bor(0x80, opcode), 126, rshift(len, 8), band(len, 255))
    else
        head = char(bor(0x80, opcode), 127, 0, 0, 0, 0, band(rshift(len, 24), 255),
                    band(rshift(len, 16), 255), band(rshift(len, 8), 255), band(len, 255))
    end
    return head .. payload
end

return ws
