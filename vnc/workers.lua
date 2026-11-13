--[[--
The decode worker and the scale worker: a session's per-pixel work in two forked processes.

After the RFB handshake the UI process forks (see @{vnc.worker}) a **decode worker**, which
inherits the socket and the protocol state and decodes updates into the remote plane, and a
**scale worker**, which scales the visible part of the plane into a canvas. Plane and canvas are
`MAP_SHARED` memory (@{vnc.sharedmem}); the pipes carry only small messages:

- UI → decode: `K <keysym> <0|1>`, `P <x> <y> <mask>`, `V <x> <y> <w> <h>` | `V -`, `F`,
  `N <what>`, `T <len>` + bytes (cut text), `S` (detached: stop reading), `R` (attached:
  resume), `Q`.
- decode → UI: `H <pid>`, `Z <w> <h>` (desktop resized; exits after), `B` (bell), `E <message>`
  (error; exits after).
- decode → scale: `D <x> <y> <w> <h> [...]` (plane rects fully written).
- UI → scale: `G <id> <scale> <view_x> <view_y> <cw> <ch> <btype> <dither 0|1> <mode
  smooth|sharp> <contrast> <invert 0|1>` (the view; latest wins), `Q`.
- scale → UI: `H <pid>`, `C <id> full` | `C <id> <x> <y> <w> <h> [...]` (canvas rects of view
  `<id>` written), `E <message>` (a render failed; exits after).

The decode worker never touches Wi-Fi, the screen or UIManager's loop: a failure only sends `E`.

@module vnc.workers
]]

local ffi = require("ffi")
local Renderer = require("vnc/renderer")
local Session = require("vnc/session")
local SharedMem = require("vnc/sharedmem")
local Worker = require("vnc/worker")
local logger = require("logger")
require("ffi/posix_h") -- pipe, poll, close, _exit
local C = ffi.C

local Workers = {
    -- CPU seconds one decode tick may take (Session.MAX_CPU_PER_TICK in the decode worker).
    DECODE_CPU_PER_TICK = 0.05,
    -- More rects than this waiting for the scale worker recompute the whole canvas instead.
    MAX_STALE_RECTS = 1024,
    -- Seconds between the UI process' poll ticks of the workers' messages while attached.
    UI_POLL = 0.01,
}

--- Bytes of the shared canvas: any canvas up to the screen, of any type up to 4 bytes per pixel,
--- in either rotation. A module field so tests (which have no device) can substitute it.
function Workers.canvas_bytes()
    local Screen = require("device").screen
    return Screen:getWidth() * Screen:getHeight() * 4
end

local function poll_fds(pfd, n, timeout_ms)
    for i = 0, n - 1 do pfd[i].revents = 0 end
    local r
    repeat
        r = C.poll(pfd, n, timeout_ms)
    until r >= 0 or ffi.errno() ~= C.EINTR
    return r
end

-- "D"/"C" message: `head` then the rects' x y w h.
local function rects_line(head, rects)
    local parts = { head }
    for _, r in ipairs(rects) do
        parts[#parts + 1] = string.format("%d %d %d %d", r.x, r.y, r.w, r.h)
    end
    return table.concat(parts, " ")
end

-- ------------------------------------------------------------------ decode worker

--- Applies the UI's commands through the session's own methods; returns the new reading flag
--- (`S` clears it, `R` sets it).
local function apply_commands(session, lines, reading)
    local i = 1
    while i <= #lines do
        local l = lines[i]
        local op = l:sub(1, 1)
        if op == "K" then
            local k, d = l:match("^K (%d+) ([01])$")
            if k then session:send_key(tonumber(k), d == "1") end
        elseif op == "P" then
            local x, y, m = l:match("^P (%-?%d+) (%-?%d+) (%d+)$")
            if x then session:send_pointer(tonumber(x), tonumber(y), tonumber(m)) end
        elseif op == "V" then
            if l == "V -" then
                session:set_view_area(nil)
            else
                local x, y, w, h = l:match("^V (%-?%d+) (%-?%d+) (%d+) (%d+)$")
                if x then
                    session:set_view_area({ x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) })
                end
            end
        elseif l == "F" then
            session:request_full_update()
            session:_flush_now()
        elseif op == "N" then
            session:note_input(l:match("^N (.+)$"))
        elseif op == "T" then
            i = i + 1 -- the payload follows its header
            session:send_cut_text(lines[i] or "")
        elseif l == "S" then
            reading = false
            session.attached = false
        elseif l == "R" then
            reading = true
            session.attached = true
        end
        if session.state ~= "connected" then return reading end -- (a send failed: E went out)
        i = i + 1
    end
    return reading
end

--[[--
The decode worker's main function: `session` is this process' copy of the UI's session, `dfd`
the write end of the pipe to the scale worker.
]]
local function decode_main(ctx, session, dfd)
    Session.MAX_CPU_PER_TICK = Workers.DECODE_CPU_PER_TICK
    -- Never touch Wi-Fi or the UI from here: a failure only reports `E` (the UI process fails
    -- its own session and restores Wi-Fi), the app's callbacks become messages.
    session.wifi_was_on = nil
    session.keep_wifi = true
    session.plugin = nil
    session._network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() end }
    session._connect_cb = nil
    session.on_update = nil
    session.on_state = function(state, err)
        if state == "error" then ctx.send("E " .. tostring(err):gsub("\n", " ")) end
    end
    -- The plane is the UI's: a new desktop size cannot be written here. Report it and exit before
    -- anything of the new size is decoded (the UI reconnects).
    if session.remote then session.remote.resize = function() end end
    session.app = {
        on_remote_resized = function(_, w, h)
            ctx.send(string.format("Z %d %d", w, h))
            C._exit(0)
        end,
        on_bell = function() ctx.send("B") end,
        on_framebuffer_dirty = function() end,
    }

    local reading = session.attached and true or false
    local pfd = ffi.new("struct pollfd[2]")
    pfd[0].fd, pfd[0].events = ctx.read_fd, C.POLLIN
    pfd[1].fd, pfd[1].events = session.fd, C.POLLIN
    local busy = false
    while true do
        local ms
        if not reading then
            ms = -1
        elseif busy then
            ms = 0
        elseif session.in_update or session:_holding() then
            ms = math.floor(Session.POLL_INTERVAL_BUSY * 1000 + 0.5)
        else
            ms = math.floor(Session.POLL_INTERVAL * 1000 + 0.5)
        end
        poll_fds(pfd, reading and 2 or 1, ms)
        if pfd[0].revents ~= 0 then
            local lines = ctx.recv(0)
            if not lines then return end -- Q, or the UI is gone
            reading = apply_commands(session, lines, reading)
            if session.state ~= "connected" then return end
        end
        if reading then
            local status, rects = session:_service()
            if status == "error" or status == "failed" then return end
            if status == "done" then
                ctx.send("E connection ended by the server")
                return
            end
            if rects then
                Worker.write_all(dfd, rects_line("D", rects) .. "\n")
            end
            busy = status == "busy"
        else
            busy = false
        end
    end
end

-- ------------------------------------------------------------------ scale worker

-- Parses a `G` line into a view, or nil.
local function parse_view(l)
    local id, s, vx, vy, cw, ch, bt, di, mode, con, inv = l:match(
        "^G (%d+) (%S+) (%S+) (%S+) (%d+) (%d+) (%d+) ([01]) (%a+) (%S+) ([01])$")
    if not id then return nil end
    return {
        id = id, scale = tonumber(s), x = tonumber(vx), y = tonumber(vy),
        cw = tonumber(cw), ch = tonumber(ch), btype = tonumber(bt), dither = di == "1",
        mode = mode, contrast = tonumber(con), invert = inv == "1",
    }
end

--[[--
The scale worker's main function: `dfd` is the read end of the pipe from the decode worker,
`plane` the shared plane, `canvas_mem` the shared canvas memory.
]]
local function scale_main(ctx, dfd, plane, canvas_mem)
    local renderer = Renderer.new{ canvas_mem = canvas_mem }
    local dreader = Worker.Reader.new()
    local pfd = ffi.new("struct pollfd[2]")
    pfd[0].fd, pfd[0].events = ctx.read_fd, C.POLLIN
    pfd[1].fd, pfd[1].events = dfd, C.POLLIN
    local view, new_view = nil, false
    local stale, all_stale = {}, false
    local contrast, invert = 1, false
    local rview = { x = 0, y = 0, scale = 1 }
    while true do
        poll_fds(pfd, 2, -1)
        if pfd[0].revents ~= 0 then
            -- Everything pending, not just one read's worth: the latest view wins.
            local lines = ctx.recv(0)
            while lines and lines[1] do
                for i = #lines, 1, -1 do
                    local v = lines[i]:sub(1, 2) == "G " and parse_view(lines[i])
                    if v then
                        view, new_view = v, true
                        break
                    end
                end
                lines = ctx.recv(0)
            end
            if not lines then break end
        end
        if pfd[1].revents ~= 0 then
            local data = Worker.read_some(dfd, Worker.READ_CHUNK)
            if not data or data == "" then break end -- the decode worker is gone
            dreader:feed(data)
            for _, l in ipairs(dreader:take()) do
                if not all_stale then
                    for x, y, w, h in l:gmatch("(%d+) (%d+) (%d+) (%d+)") do
                        if #stale >= Workers.MAX_STALE_RECTS then
                            all_stale, stale = true, {}
                            break
                        end
                        stale[#stale + 1] = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }
                    end
                end
            end
        end
        if view and (new_view or all_stale or stale[1]) then
            if view.contrast ~= contrast or view.invert ~= invert then
                contrast, invert = view.contrast, view.invert
                renderer:set_tone(contrast, invert)
                all_stale = true
            end
            rview.x, rview.y, rview.scale = view.x, view.y, view.scale
            local ok, res = pcall(renderer.render, renderer, plane, rview, view.mode, view.cw, view.ch,
                view.btype, view.dither, stale[1] and stale or nil, all_stale)
            if not ok then
                ctx.send("E render failed: " .. tostring(res):gsub("\n", " "))
                break
            end
            if new_view or res == "full" then
                ctx.send("C " .. view.id .. " full")
            elseif res then
                ctx.send(rects_line("C " .. view.id, res))
            end
            new_view, all_stale = false, false
            if stale[1] then stale = {} end
        end
    end
    renderer:free()
end

-- ------------------------------------------------------------------ UI side

local Link = {}
Link.__index = Link

local function detach_link(self)
    local s = self.session
    if s.workers == self then s.workers = nil end
    if s.remote and s.remote.worker_link == self then s.remote.worker_link = nil end
end

--[[--
Stops both workers (never blocks) and frees the UI's mapping of the canvas memory (a worker
still finishing keeps its own). Clears `session.workers` and `session.remote.worker_link`.
]]
function Link:stop()
    if self.stopped then return end
    self.stopped = true
    self.decode:stop()
    self.scale:stop()
    detach_link(self)
    SharedMem.free(self.canvas_mem.ptr, self.canvas_mem.bytes)
end

--[[--
Never blocks. Drains both workers: `B` rings the app's bell; `E` (from either worker), or either
worker's end closing, stops the link and fails the session (`_fail`: state "error", Wi-Fi restored by the UI
process); `Z` stops the link (the decode worker exits after it). Returns the scale worker's `C`
lines and a `Z` line, in arrival order, for the caller.
]]
function Link:poll()
    local out = {}
    if self.stopped then return out end
    local session = self.session
    local err, gone, resized
    local lines, eof = self.decode:poll()
    for _, l in ipairs(lines) do
        local op = l:sub(1, 1)
        if op == "B" then
            if session.app and session.app.on_bell then session.app:on_bell() end
        elseif op == "E" then
            err = l:sub(3)
        elseif op == "Z" then
            resized = l
        end
    end
    gone = eof
    lines, eof = self.scale:poll()
    for _, l in ipairs(lines) do
        if l:sub(1, 2) == "C " then
            out[#out + 1] = l
        elseif l:sub(1, 1) == "E" and not err then
            err = l:sub(3)
        end
    end
    gone = gone or eof
    if resized then
        self:stop()
        out[#out + 1] = resized
    elseif err or gone then
        self:stop()
        session:_fail(err or "worker process exited")
    end
    return out
end

local function close_pipe(fds)
    if fds[0] >= 0 then C.close(fds[0]); fds[0] = -1 end
    if fds[1] >= 0 then C.close(fds[1]); fds[1] = -1 end
end

--[[--
Forks the scale worker and the decode worker for a session that just completed its handshake
(its remote plane must be shared: `Remote.new(w, h, {shared = true})`). On success the UI
process gives up its copy of the connection (the socket descriptor is closed without a shutdown,
the protocol state freed), keeps the plane and the "connected" state, and sets
`session.workers` and `session.remote.worker_link` to the link.
--- @treturn table|nil link `{decode, scale, canvas_mem = {ptr, bytes}}`, or nil and an error
---   (nothing changed then: the session carries on in-process)
]]
function Workers.start(session)
    local remote, sock, fd = session.remote, session.sock, session.fd
    if not (remote and remote.shared and remote.plane and sock and fd and session.proto) then
        return nil, "the session is not connected with a shared plane"
    end
    if not sock.setfd then return nil, "this LuaSocket cannot release a descriptor (no setfd)" end
    local okb, bytes = pcall(Workers.canvas_bytes)
    if not okb then return nil, "no canvas size: " .. tostring(bytes) end
    local oka, ptr = pcall(SharedMem.alloc, bytes)
    if not oka then return nil, tostring(ptr) end
    local canvas_mem = { ptr = ptr, bytes = bytes }
    local fds = ffi.new("int[2]", -1, -1)
    if C.pipe(fds) ~= 0 then
        SharedMem.free(ptr, bytes)
        return nil, "pipe failed: " .. ffi.string(C.strerror(ffi.errno()))
    end
    local rd, wr = fds[0], fds[1]
    local plane = remote.plane

    -- The scale worker first: it never sees the socket, so failing on the decode worker leaves
    -- the connection untouched.
    local scale, err = Worker.spawn("scale", function(ctx)
        scale_main(ctx, rd, plane, canvas_mem)
    end, { rd })
    if not scale then
        close_pipe(fds)
        SharedMem.free(ptr, bytes)
        return nil, "scale worker: " .. tostring(err)
    end
    local decode
    decode, err = Worker.spawn("decode", function(ctx)
        decode_main(ctx, session, wr)
    end, { fd, wr })
    if not decode then
        scale:stop()
        close_pipe(fds)
        SharedMem.free(ptr, bytes)
        return nil, "decode worker: " .. tostring(err)
    end
    -- Only the workers hold the pipe between them: either one dying is seen by the other.
    close_pipe(fds)

    local link = setmetatable({ session = session, decode = decode, scale = scale,
        canvas_mem = canvas_mem }, Link)
    -- The connection is the decode worker's now. LuaSocket's close (and its __gc) close the
    -- descriptor it holds, so it is set to -1 first; the descriptor is closed here without a
    -- shutdown, which would end the connection for the worker too.
    sock:setfd(-1)
    sock:close()
    C.close(fd)
    session.sock, session.fd = nil, nil
    session.proto:free()
    session.proto = nil
    session:_rx_free()
    session.tx, session.need, session.done = {}, nil, false
    session.in_update, session.tm, session.dirty = false, nil, nil
    session.workers = link
    remote.worker_link = link
    logger.info("vnc: decoding in worker processes")
    return link
end

return Workers
