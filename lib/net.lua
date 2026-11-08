-- Minimal non-blocking TCP networking for Linux, built on LuaJIT's FFI so the
-- server has no dependencies beyond LuaJIT itself.
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
typedef uint32_t socklen_t;
struct sockaddr_in { uint16_t sin_family; uint16_t sin_port; uint32_t sin_addr; uint8_t sin_zero[8]; };
struct pollfd { int fd; short events; short revents; };
struct timespec { long tv_sec; long tv_nsec; };
struct rlimit { uint64_t rlim_cur; uint64_t rlim_max; };
int socket(int domain, int type, int protocol);
int setsockopt(int fd, int level, int optname, const void *optval, socklen_t optlen);
int bind(int fd, const struct sockaddr_in *addr, socklen_t len);
int listen(int fd, int backlog);
int accept4(int fd, void *addr, socklen_t *len, int flags);
long recv(int fd, void *buf, size_t n, int flags);
long send(int fd, const void *buf, size_t n, int flags);
int close(int fd);
int poll(struct pollfd *fds, unsigned long nfds, int timeout);
int inet_pton(int af, const char *src, void *dst);
uint16_t htons(uint16_t hostshort);
char *strerror(int errnum);
int clock_gettime(int clk, struct timespec *tp);
int setrlimit(int resource, const struct rlimit *rlim);
]]

local C = ffi.C
local AF_INET, SOCK_STREAM, SOCK_NONBLOCK, SOCK_CLOEXEC = 2, 1, 2048, 524288
local SOL_SOCKET, SO_REUSEADDR = 1, 2
local MSG_NOSIGNAL = 0x4000
local EAGAIN, EINTR = 11, 4
local CLOCK_MONOTONIC = 1
local RLIMIT_AS = 9

local net = {
    POLLIN = 0x1, POLLOUT = 0x4, POLLERR = 0x8, POLLHUP = 0x10,
}

local function errmsg()
    return ffi.string(C.strerror(ffi.errno()))
end

function net.listen(host, port)
    if host == "localhost" then host = "127.0.0.1" end
    local fd = C.socket(AF_INET, bit.bor(SOCK_STREAM, SOCK_NONBLOCK, SOCK_CLOEXEC), 0)
    if fd < 0 then error("socket: " .. errmsg()) end
    local one = ffi.new("int[1]", 1)
    C.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, one, ffi.sizeof("int"))
    local addr = ffi.new("struct sockaddr_in")
    addr.sin_family = AF_INET
    addr.sin_port = C.htons(port)
    local ip = ffi.new("uint32_t[1]")
    if C.inet_pton(AF_INET, host, ip) ~= 1 then
        error("invalid IPv4 address: " .. host)
    end
    addr.sin_addr = ip[0]
    if C.bind(fd, addr, ffi.sizeof(addr)) < 0 then error("bind: " .. errmsg()) end
    if C.listen(fd, 128) < 0 then error("listen: " .. errmsg()) end
    return fd
end

-- Returns a new non-blocking client fd, or nil when no connection is pending.
function net.accept(fd)
    local client = C.accept4(fd, nil, nil, bit.bor(SOCK_NONBLOCK, SOCK_CLOEXEC))
    if client < 0 then return nil end
    return client
end

local recv_buf_size = 65536
local recv_buf = ffi.new("uint8_t[?]", recv_buf_size)

-- Returns data, "" when nothing is available yet, or nil on EOF/error.
function net.recv(fd)
    while true do
        local n = C.recv(fd, recv_buf, recv_buf_size, 0)
        if n > 0 then return ffi.string(recv_buf, n) end
        if n == 0 then return nil end
        local e = ffi.errno()
        if e == EAGAIN then return "" end
        if e ~= EINTR then return nil end
    end
end

-- Returns the number of bytes sent (possibly 0), or nil on error.
function net.send(fd, data)
    while true do
        local n = C.send(fd, data, #data, MSG_NOSIGNAL)
        if n >= 0 then return tonumber(n) end
        local e = ffi.errno()
        if e == EAGAIN then return 0 end
        if e ~= EINTR then return nil end
    end
end

function net.close(fd)
    C.close(fd)
end

-- Polls a list of {fd=, events=} entries, filling in each entry's `revents`.
function net.poll(entries, timeout_ms)
    local n = #entries
    local fds = ffi.new("struct pollfd[?]", n)
    for i, e in ipairs(entries) do
        fds[i - 1].fd = e.fd
        fds[i - 1].events = e.events
    end
    local r = C.poll(fds, n, timeout_ms)
    for i, e in ipairs(entries) do
        e.revents = r > 0 and fds[i - 1].revents or 0
    end
end

local ts = ffi.new("struct timespec")
-- Monotonic time in seconds
function net.now()
    C.clock_gettime(CLOCK_MONOTONIC, ts)
    return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9
end

-- Cap the process's address space so runaway allocations fail with a Lua
-- "not enough memory" error instead of taking down the machine.
function net.limit_memory(bytes)
    local lim = ffi.new("struct rlimit", bytes, bytes)
    return C.setrlimit(RLIMIT_AS, lim) == 0
end

return net
