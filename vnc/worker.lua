--[[--
Forked worker processes talking to the UI process over a pair of pipes.

The protocol is one message per line, words separated by single spaces, numbers in decimal. A
payload message `T <len>` is followed by exactly `<len>` raw bytes; a reader delivers it as two
list entries, the line `"T <len>"` and then the payload string. `H <pid>` is the worker's first
message (the real pid: the worker is double-forked), `Q` asks it to quit.

A worker closes every descriptor it inherited except stdin/stdout/stderr, its two pipe ends and
the `keep_fds` it was given (sockets, display or input devices the UI process holds stay with
the UI process), and runs at nice `Worker.NICE`. It exits when the UI end of its pipe closes,
or on `Q`; `stop()` SIGKILLs it `Worker.KILL_AFTER` seconds later should it still be running.

@module vnc.worker
]]

local bit = require("bit")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
-- Loading LuaSocket ignores SIGPIPE, so a write to a dead worker's pipe fails with EPIPE
-- instead of killing the writer.
local socket = require("socket")
require("ffi/posix_h") -- pipe, read, write, close, kill, poll, getpid, setpriority, PRIO_PROCESS
local C = ffi.C

local Worker = {
    NICE = 5,
    KILL_AFTER = 2, -- seconds between stop()'s Q and a SIGKILL of a worker still running
    READ_CHUNK = 65536,
    -- Test hook: the worker ignores Q and the closed pipe, as if stuck in a long computation.
    _test_ignore_quit = false,
}

local SIGKILL = 9

-- ------------------------------------------------------------------ codec

--[[--
Splits a byte stream into messages. `feed(data)` appends what was read; complete messages
collect in `out` (a `T <len>` line, then its payload once all of it arrived); `quit` is set when
a `Q` line arrives.
]]
local Reader = {}
Reader.__index = Reader

function Reader.new()
    return setmetatable({ buf = "", need = nil, out = {}, quit = false }, Reader)
end

function Reader:feed(data)
    local buf = self.buf .. data
    local pos = 1
    while true do
        if self.need then
            if #buf - pos + 1 < self.need then break end
            self.out[#self.out + 1] = buf:sub(pos, pos + self.need - 1)
            pos = pos + self.need
            self.need = nil
        else
            local nl = buf:find("\n", pos, true)
            if not nl then break end
            local line = buf:sub(pos, nl - 1)
            pos = nl + 1
            self.out[#self.out + 1] = line
            local len = line:match("^T (%d+)$")
            if len then
                self.need = tonumber(len)
            elseif line == "Q" then
                self.quit = true
            end
        end
    end
    self.buf = buf:sub(pos)
end

--- The complete messages so far, emptying the list.
function Reader:take()
    local out = self.out
    self.out = {}
    return out
end

Worker.Reader = Reader

--- Encodes one message (and a `T` message's payload) for the wire.
function Worker.encode(line, payload)
    return line .. "\n" .. (payload or "")
end

-- ------------------------------------------------------------------ fd helpers

local function write_all(fd, data)
    local ptr = ffi.cast("const char *", data)
    local done, size = 0, #data
    while done < size do
        local n = tonumber(C.write(fd, ptr + done, size - done))
        if n < 0 then
            if ffi.errno() ~= C.EINTR then return false end
        else
            done = done + n
        end
    end
    return true
end

-- `fd` ready to read within `timeout_ms` (-1 waits); ready also on hangup.
local function readable(fd, timeout_ms)
    local pfd = ffi.new("struct pollfd[1]")
    pfd[0].fd = fd
    pfd[0].events = C.POLLIN
    local n = C.poll(pfd, 1, timeout_ms)
    return n > 0 and pfd[0].revents ~= 0
end

local read_buf
-- Reads up to `size` bytes: the string, "" at EOF, nil on error.
local function read_some(fd, size)
    if not read_buf or ffi.sizeof(read_buf) < size then
        read_buf = ffi.new("char[?]", size)
    end
    local n
    repeat
        n = tonumber(C.read(fd, read_buf, size))
    until n >= 0 or ffi.errno() ~= C.EINTR
    if n < 0 then return nil end
    return ffi.string(read_buf, n)
end

-- Closes every descriptor of this process not in `keep` (a set).
local function close_others(keep)
    local fds = {}
    for e in lfs.dir("/proc/self/fd") do
        local fd = tonumber(e)
        if fd and not keep[fd] then fds[#fds + 1] = fd end
    end
    -- The listing's own descriptor is in the list too; it is closed by now (EBADF, harmless).
    for _, fd in ipairs(fds) do C.close(fd) end
end

-- ------------------------------------------------------------------ child side

local function stuck_forever()
    while true do socket.sleep(1) end
end

local function child_main(main_fn, keep_fds, write_fd, read_fd)
    local keep = { [0] = true, [1] = true, [2] = true, [read_fd] = true, [write_fd] = true }
    for _, fd in ipairs(keep_fds or {}) do keep[fd] = true end
    close_others(keep)
    C.setpriority(C.PRIO_PROCESS, 0, Worker.NICE)

    local reader = Reader.new()
    local eof = false
    local ctx = { read_fd = read_fd, write_fd = write_fd }
    function ctx.send(line, payload)
        return write_all(write_fd, Worker.encode(line, payload))
    end
    --[[--
    The messages that arrived, waiting up to `timeout` seconds (nil: until one does) for the
    first; an empty list on timeout. nil once the UI end closed or `Q` arrived: the worker's
    main function should then return (the process exits through runInSubProcess's _exit).
    ]]
    function ctx.recv(timeout)
        while true do
            if reader.quit or eof then
                if Worker._test_ignore_quit then stuck_forever() end
                return nil
            end
            if #reader.out > 0 then return reader:take() end
            local ms = timeout and math.max(0, math.floor(timeout * 1000 + 0.5)) or -1
            if not readable(read_fd, ms) then return {} end
            local data = read_some(read_fd, Worker.READ_CHUNK)
            if not data or data == "" then
                eof = true
            else
                reader:feed(data)
                -- Messages before a Q in the same read are dropped: the worker is quitting.
                if not reader.quit and #reader.out > 0 then return reader:take() end
            end
            timeout = 0 -- the wait is over; only drain what is already there
        end
    end

    ctx.send("H " .. tonumber(C.getpid()))
    local ok, err = xpcall(main_fn, debug.traceback, ctx)
    if not ok then
        io.stderr:write("vnc worker error: ", tostring(err), "\n")
    end
    -- Returning lets runInSubProcess _exit(0) the process: no atexit handlers, no stdio flush
    -- of buffers inherited from the UI process.
end

-- ------------------------------------------------------------------ parent side

local Handle = {}
Handle.__index = Handle

--[[--
Forks a worker running `main_fn(ctx)` (see `ctx.recv` / `ctx.send`), keeping `keep_fds` open in
it. Returns the parent's handle (`w.pid` is set once `H` was polled), or nil and an error.
]]
function Worker.spawn(name, main_fn, keep_fds)
    local pid, read_fd, write_fd = ffiutil.runInSubProcess(function(_, child_write_fd, child_read_fd)
        child_main(main_fn, keep_fds, child_write_fd, child_read_fd)
    end, "bidi", true)
    if not pid then
        return nil, read_fd
    end
    -- The intermediate process of the double fork; already reaped, this returns at once.
    ffiutil.isSubProcessDone(pid, true)
    return setmetatable({
        name = name,
        read_fd = read_fd,
        write_fd = write_fd,
        reader = Reader.new(),
        eof = false,
    }, Handle)
end

--- Sends one message (and a `T` message's payload). False when the worker is gone.
function Handle:send(line, payload)
    if not self.write_fd then return false end
    return write_all(self.write_fd, Worker.encode(line, payload))
end

--[[--
Never blocks. Returns the complete messages that arrived (a list, maybe empty) and true once the
worker's end closed (it exited or died). `H <pid>` is passed on too, and sets `self.pid`.
]]
function Handle:poll()
    local fd = self.read_fd
    if not fd or self.eof then return self.reader:take(), true end
    local avail = ffiutil.getNonBlockingReadSize(fd)
    if avail and avail > 0 then
        local data = read_some(fd, avail)
        if data then self.reader:feed(data) end
    elseif readable(fd, 0) then
        -- Nothing to read yet readable: the other end closed (or FIONREAD is unsupported).
        local data = read_some(fd, Worker.READ_CHUNK)
        if not data or data == "" then
            self.eof = true
        else
            self.reader:feed(data)
        end
    end
    local lines = self.reader:take()
    if not self.pid then
        for _, l in ipairs(lines) do
            local pid = l:match("^H (%d+)$")
            if pid then
                self.pid = tonumber(pid)
                break
            end
        end
    end
    return lines, self.eof
end

local function close_fd(self, key)
    if self[key] then
        C.close(self[key])
        self[key] = nil
    end
end

--[[--
Asks the worker to quit (`Q`), closes the pipes and schedules a SIGKILL `Worker.KILL_AFTER`
seconds later, for a worker still running then. Before the worker's `H` was polled the read end
stays open until that moment, to learn the pid.
]]
function Handle:stop()
    if self.stopped then return end
    self.stopped = true
    self:send("Q")
    close_fd(self, "write_fd")
    if self.pid then close_fd(self, "read_fd") end
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(Worker.KILL_AFTER, function()
        if not self.pid and self.read_fd then
            self.eof = false
            self:poll()
        end
        close_fd(self, "read_fd")
        local pid = self.pid
        if pid and pid > 1 and C.kill(pid, 0) == 0 then
            C.kill(pid, SIGKILL)
        end
    end)
end

return Worker
