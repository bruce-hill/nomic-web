-- A pure-Lua port of Lua 5.1's string pattern matching (lstrlib.c).
--
-- The C matcher can backtrack for an exponentially long time and the
-- sandbox's instruction-count hook never fires inside C code, so a malicious
-- pattern could hang the server. Running the matcher as Lua code means every
-- step counts against the sandbox's instruction budget.
local byte, sub, char, format = string.byte, string.sub, string.char, string.format
local c_find, c_gsub = string.find, string.gsub
local concat = table.concat

local P = {}
-- Charges extra cost (in units of VM instructions) against the sandbox
-- budget. The sandbox replaces this.
P.charge = function(n) end

local ESC = 37 -- '%'
local CAP_UNFINISHED, CAP_POSITION = -1, -2
local MAXCAPTURES = 32
local B = {}
for _, c in ipairs({"(", ")", "[", "]", "^", "$", "*", "+", "-", "?", ".", "b", "f", "0", "1", "9"}) do
    B[c] = byte(c)
end

local class_tables = {}
for _, cl in ipairs({"a", "c", "d", "l", "p", "s", "u", "w", "x"}) do
    local t = {}
    for c = 0, 255 do t[c] = c_find(char(c), "%" .. cl) ~= nil end
    class_tables[byte(cl)] = t
end
do
    local t = {}
    for c = 0, 255 do t[c] = (c == 0) end
    class_tables[byte("z")] = t
end

local function match_class(c, cl)
    local t = class_tables[cl]
    if t then return t[c] end
    if cl >= 65 and cl <= 90 then -- uppercase class = complement
        t = class_tables[cl + 32]
        if t then return not t[c] end
    end
    return cl == c
end

local function match_bracket_class(ms, c, p, ec)
    local pat = ms.pat
    local sig = true
    if byte(pat, p + 1) == B["^"] then
        sig = false
        p = p + 1
    end
    p = p + 1
    while p < ec do
        local pc = byte(pat, p)
        if pc == ESC then
            p = p + 1
            if match_class(c, byte(pat, p)) then return sig end
        elseif byte(pat, p + 1) == B["-"] and p + 2 < ec then
            p = p + 2
            if pc <= c and c <= byte(pat, p) then return sig end
        elseif pc == c then
            return sig
        end
        p = p + 1
    end
    return not sig
end

local function class_end(ms, p)
    local pat, plen = ms.pat, ms.plen
    local c = byte(pat, p)
    p = p + 1
    if c == ESC then
        if p > plen then error("malformed pattern (ends with '%')", 0) end
        return p + 1
    elseif c == B["["] then
        if byte(pat, p) == B["^"] then p = p + 1 end
        repeat -- look for a ']'
            if p > plen then error("malformed pattern (missing ']')", 0) end
            local cc = byte(pat, p)
            p = p + 1
            if cc == ESC and p <= plen then p = p + 1 end
        until byte(pat, p) == B["]"]
        return p + 1
    end
    return p
end

local function single_match(ms, s, p, ep)
    if s > ms.srclen then return false end
    local c = byte(ms.src, s)
    local pc = byte(ms.pat, p)
    if pc == B["."] then return true
    elseif pc == ESC then return match_class(c, byte(ms.pat, p + 1))
    elseif pc == B["["] then return match_bracket_class(ms, c, p, ep - 1)
    else return pc == c
    end
end

local do_match

local function match_balance(ms, s, p)
    if p + 1 > ms.plen then error("unbalanced pattern", 0) end
    local src = ms.src
    local b, e = byte(ms.pat, p, p + 1)
    if s > ms.srclen or byte(src, s) ~= b then return nil end
    local cont = 1
    s = s + 1
    while s <= ms.srclen do
        local c = byte(src, s)
        if c == e then
            cont = cont - 1
            if cont == 0 then return s + 1 end
        elseif c == b then
            cont = cont + 1
        end
        s = s + 1
    end
    return nil
end

local function max_expand(ms, s, p, ep)
    local i = 0
    while single_match(ms, s + i, p, ep) do i = i + 1 end
    while i >= 0 do
        local res = do_match(ms, s + i, ep + 1)
        if res then return res end
        i = i - 1
    end
    return nil
end

local function min_expand(ms, s, p, ep)
    while true do
        local res = do_match(ms, s, ep + 1)
        if res then return res
        elseif single_match(ms, s, p, ep) then s = s + 1
        else return nil
        end
    end
end

local function start_capture(ms, s, p, what)
    local level = ms.level + 1
    if level > MAXCAPTURES then error("too many captures", 0) end
    ms.cinit[level], ms.clen[level] = s, what
    ms.level = level
    local res = do_match(ms, s, p)
    if not res then ms.level = ms.level - 1 end
    return res
end

local function end_capture(ms, s, p)
    local l
    for i = ms.level, 1, -1 do
        if ms.clen[i] == CAP_UNFINISHED then l = i; break end
    end
    if not l then error("invalid pattern capture", 0) end
    ms.clen[l] = s - ms.cinit[l]
    local res = do_match(ms, s, p)
    if not res then ms.clen[l] = CAP_UNFINISHED end
    return res
end

local function match_capture(ms, s, l)
    l = l - B["0"]
    if l < 1 or l > ms.level or ms.clen[l] == CAP_UNFINISHED then
        error("invalid capture index", 0)
    end
    local init, len = ms.cinit[l], ms.clen[l]
    if ms.srclen - s + 1 >= len and sub(ms.src, init, init + len - 1) == sub(ms.src, s, s + len - 1) then
        return s + len
    end
    return nil
end

do_match = function(ms, s, p)
    local pat, plen = ms.pat, ms.plen
    while true do
        if p > plen then return s end
        local pc = byte(pat, p)
        if pc == B["("] then
            if byte(pat, p + 1) == B[")"] then
                return start_capture(ms, s, p + 2, CAP_POSITION)
            end
            return start_capture(ms, s, p + 1, CAP_UNFINISHED)
        elseif pc == B[")"] then
            return end_capture(ms, s, p + 1)
        elseif pc == ESC and byte(pat, p + 1) == B.b then
            s = match_balance(ms, s, p + 2)
            if not s then return nil end
            p = p + 4
        elseif pc == ESC and byte(pat, p + 1) == B.f then
            p = p + 2
            if byte(pat, p) ~= B["["] then error("missing '[' after '%f' in pattern", 0) end
            local ep = class_end(ms, p)
            local prev = s == 1 and 0 or byte(ms.src, s - 1)
            local cur = s <= ms.srclen and byte(ms.src, s) or 0
            if match_bracket_class(ms, prev, p, ep - 1) or not match_bracket_class(ms, cur, p, ep - 1) then
                return nil
            end
            p = ep
        elseif pc == ESC and (byte(pat, p + 1) or 0) >= B["0"] and (byte(pat, p + 1) or 0) <= B["9"] then
            s = match_capture(ms, s, byte(pat, p + 1))
            if not s then return nil end
            p = p + 2
        elseif pc == B["$"] and p == plen then
            return s == ms.srclen + 1 and s or nil
        else
            local ep = class_end(ms, p)
            local m = single_match(ms, s, p, ep)
            local epc = byte(pat, ep)
            if epc == B["?"] then
                if m then
                    local res = do_match(ms, s + 1, ep + 1)
                    if res then return res end
                end
                p = ep + 1
            elseif epc == B["*"] then
                return max_expand(ms, s, p, ep)
            elseif epc == B["+"] then
                return m and max_expand(ms, s + 1, p, ep) or nil
            elseif epc == B["-"] then
                return min_expand(ms, s, p, ep)
            else
                if not m then return nil end
                s, p = s + 1, ep
            end
        end
    end
end

local function new_state(s, p)
    return {src = s, srclen = #s, pat = p, plen = #p, level = 0, cinit = {}, clen = {}}
end

local function get_capture(ms, i, s, e)
    if i > ms.level then
        if i == 1 then return sub(ms.src, s, e - 1) end
        error("invalid capture index", 0)
    end
    local l = ms.clen[i]
    if l == CAP_UNFINISHED then error("unfinished capture", 0) end
    if l == CAP_POSITION then return ms.cinit[i] end
    return sub(ms.src, ms.cinit[i], ms.cinit[i] + l - 1)
end

local function push_captures(ms, s, e)
    local n = (ms.level == 0 and s) and 1 or ms.level
    local caps = {}
    for i = 1, n do caps[i] = get_capture(ms, i, s, e) end
    return unpack(caps, 1, n)
end

local function check_string(v, n, fname)
    if type(v) == "string" then return v end
    if type(v) == "number" then return tostring(v) end
    error(format("bad argument #%d to '%s' (string expected, got %s)", n, fname, type(v)), 3)
end

local function check_int(v, default, n, fname)
    if v == nil then return default end
    local x = tonumber(v)
    if not x then
        error(format("bad argument #%d to '%s' (number expected, got %s)", n, fname, type(v)), 3)
    end
    return x >= 0 and math.floor(x) or math.ceil(x)
end

local function find_aux(is_find, s, p, init, plain)
    local fname = is_find and "find" or "match"
    s = check_string(s, 1, fname)
    p = check_string(p, 2, fname)
    init = check_int(init, 1, 3, fname)
    if init < 0 then init = #s + init + 1 end
    if init < 1 then init = 1 end
    if init > #s + 1 then init = #s + 1 end
    if is_find and (plain or not c_find(p, "[%^%$%*%+%?%.%(%[%%%-]")) then
        -- Plain substring search is O(#s * #p) in the worst case
        P.charge((#s - init + 1) / 32 * math.max(1, #p / 32))
        return c_find(s, p, init, true)
    end
    local ms = new_state(s, p)
    local anchor = byte(p, 1) == B["^"]
    local pstart = anchor and 2 or 1
    local s1 = init
    repeat
        ms.level = 0
        local e = do_match(ms, s1, pstart)
        if e then
            if is_find then
                return s1, e - 1, push_captures(ms, nil, 0)
            end
            return push_captures(ms, s1, e)
        end
        s1 = s1 + 1
    until anchor or s1 > ms.srclen + 1
    return nil
end

function P.find(s, p, init, plain)
    return find_aux(true, s, p, init, plain)
end

function P.match(s, p, init)
    return find_aux(false, s, p, init)
end

function P.gmatch(s, p)
    s = check_string(s, 1, "gmatch")
    p = check_string(p, 2, "gmatch")
    local ms = new_state(s, p)
    local pos = 1
    return function()
        while pos <= ms.srclen + 1 do
            ms.level = 0
            local start = pos
            local e = do_match(ms, start, 1)
            if e then
                pos = (e == start) and e + 1 or e
                return push_captures(ms, start, e)
            end
            pos = pos + 1
        end
        return nil
    end
end

local function add_value(ms, out, s, e, repl, tr)
    local value
    if tr == "function" then
        value = repl(push_captures(ms, s, e))
    elseif tr == "table" then
        value = repl[get_capture(ms, 1, s, e)]
    else
        value = c_gsub(repl, "%%(.)", function(d)
            local n = byte(d) - B["0"]
            if n == 0 then return sub(ms.src, s, e - 1) end
            if n >= 1 and n <= 9 then return tostring(get_capture(ms, n, s, e)) end
            return d
        end)
    end
    if not value then
        value = sub(ms.src, s, e - 1)
    elseif type(value) ~= "string" and type(value) ~= "number" then
        error("invalid replacement value (a " .. type(value) .. ")", 0)
    end
    out[#out + 1] = tostring(value)
end

function P.gsub(s, p, repl, max_n)
    s = check_string(s, 1, "gsub")
    p = check_string(p, 2, "gsub")
    local tr = type(repl)
    if tr == "number" then repl, tr = tostring(repl), "string" end
    if tr ~= "string" and tr ~= "table" and tr ~= "function" then
        error("bad argument #3 to 'gsub' (string/function/table expected, got " .. tr .. ")", 2)
    end
    max_n = check_int(max_n, #s + 1, 4, "gsub")
    local ms = new_state(s, p)
    local anchor = byte(p, 1) == B["^"]
    local pstart = anchor and 2 or 1
    local src, n, out = 1, 0, {}
    while n < max_n do
        ms.level = 0
        local e = do_match(ms, src, pstart)
        if e then
            n = n + 1
            add_value(ms, out, src, e, repl, tr)
        end
        if e and e > src then
            src = e
        elseif src <= ms.srclen then
            out[#out + 1] = sub(s, src, src)
            src = src + 1
        else
            break
        end
        if anchor then break end
    end
    out[#out + 1] = sub(s, src)
    local result = concat(out)
    P.charge(#result / 32)
    return result, n
end

return P
