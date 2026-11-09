-- Minimal non-blocking TCP networking for Linux, built on luaposix.
local socket = require("posix.sys.socket")
local poll = require("posix.poll")
local fcntl = require("posix.fcntl")
local signal = require("posix.signal")
local unistd = require("posix.unistd")
local errno = require("posix.errno")
local resource = require("posix.sys.resource")
local time = require("posix.time")

local net = {
    POLLIN = 0x1, POLLOUT = 0x4, POLLERR = 0x8, POLLHUP = 0x10,
}

local revent_bits = {IN = net.POLLIN, OUT = net.POLLOUT, ERR = net.POLLERR, HUP = net.POLLHUP, NVAL = 0x20}

local function make_nonblocking(fd)
    fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.O_NONBLOCK)
    fcntl.fcntl(fd, fcntl.F_SETFD, fcntl.FD_CLOEXEC)
end

function net.listen(host, port)
    if host == "localhost" then host = "127.0.0.1" end
    -- Writing to a closed connection should be an error, not kill the server
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    local fd, err = socket.socket(socket.AF_INET, socket.SOCK_STREAM, 0)
    if not fd then error("socket: " .. err) end
    make_nonblocking(fd)
    socket.setsockopt(fd, socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    local ok
    ok, err = socket.bind(fd, {family = socket.AF_INET, addr = host, port = port})
    if not ok then error("bind: " .. err) end
    ok, err = socket.listen(fd, 128)
    if not ok then error("listen: " .. err) end
    return fd
end

-- Returns a new non-blocking client fd, or nil when no connection is pending.
function net.accept(fd)
    local client = socket.accept(fd)
    if not client then return nil end
    make_nonblocking(client)
    return client
end

local recv_buf_size = 65536

-- Returns data, "" when nothing is available yet, or nil on EOF/error.
function net.recv(fd)
    while true do
        local data, _, e = socket.recv(fd, recv_buf_size)
        if data then
            if data == "" then return nil end
            return data
        end
        if e == errno.EAGAIN then return "" end
        if e ~= errno.EINTR then return nil end
    end
end

-- Returns the number of bytes sent (possibly 0), or nil on error.
function net.send(fd, data)
    while true do
        local n, _, e = socket.send(fd, data)
        if n then return n end
        if e == errno.EAGAIN then return 0 end
        if e ~= errno.EINTR then return nil end
    end
end

function net.close(fd)
    unistd.close(fd)
end

-- Polls a list of {fd=, events=} entries, filling in each entry's `revents`.
function net.poll(entries, timeout_ms)
    local fds = {}
    for _, e in ipairs(entries) do
        fds[e.fd] = {events = {IN = e.events & net.POLLIN ~= 0, OUT = e.events & net.POLLOUT ~= 0}}
    end
    poll.poll(fds, timeout_ms)
    for _, e in ipairs(entries) do
        e.revents = 0
        for name, value in pairs(fds[e.fd].revents or {}) do
            if value then e.revents = e.revents | revent_bits[name] end
        end
    end
end

-- Monotonic time in seconds
function net.now()
    local ts = time.clock_gettime(time.CLOCK_MONOTONIC)
    return ts.tv_sec + ts.tv_nsec * 1e-9
end

-- Cap the process's address space so runaway allocations fail with a Lua
-- "not enough memory" error instead of taking down the machine.
function net.limit_memory(bytes)
    return resource.setrlimit(resource.RLIMIT_AS, {rlim_cur = bytes, rlim_max = bytes}) == 0
end

return net
