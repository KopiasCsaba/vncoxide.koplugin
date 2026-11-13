--[[--
VNC session: socket transport, Wi-Fi handling, attach/detach and reconnect.

A session owns one connection to one server. It drives @{vnc.protocol} from a poll
task registered with `UIManager:scheduleIn`, so the app can be closed (detached) without
dropping the connection: while detached the poll task is simply not scheduled, so nothing
is read, nothing is requested, and at most the single outstanding update request is
buffered by the kernel until we resume.

@module vnc.session
]]

local ffi = require("ffi")
require("ffi/posix_h")
local C = ffi.C
local Encodings = require("vnc/encodings")
local Protocol = require("vnc/protocol")
local PxFmt = require("vnc/pxfmt")
local Remote = require("vnc/framebuffer")
local Util = require("vnc/util")
local logger = require("logger")
local time = require("ui/time")

local UIManager = require("ui/uimanager")

-- The network manager drags in the whole widget stack; only load it when we actually need
-- Wi-Fi, so that merely loading the plugin at startup stays cheap.
local NetworkMgr

-- (required lazily: vnc/workers requires this module)
local function Workers() return require("vnc/workers") end

local Session = {}
Session.__index = Session

-- Seconds between poll ticks while attached.
Session.POLL_INTERVAL = 0.05
-- Seconds between poll ticks while an update is half received: the rest is usually on its way,
-- and a 50 ms nap per partial read would add up to a visibly late frame.
Session.POLL_INTERVAL_BUSY = 0.01
-- Bytes asked of the socket per receive once connected; whatever has arrived is taken, so one
-- receive serves many small protocol reads.
Session.RECV_CHUNK = 65536
-- The receive buffer (bytes): its usual size, and the cap on how far a single protocol read may
-- grow it (a whole ZRLE rectangle or a cut text is one read). Past the cap the connection fails
-- instead of having the device allocate whatever the server claimed; once the large read has been
-- consumed the buffer shrinks back to `RX_BUFFER`.
Session.RX_BUFFER = 2 * Session.RECV_CHUNK
Session.MAX_RX_BUFFER = 64 * 1024 * 1024
-- Protocol reads served straight from the receive buffer between two budget checks.
Session.FAST_READS = 4096
-- Caps so a single tick can never monopolise the UI thread. The CPU budget is the one that
-- matters: decoding is step-heavy (Hextile yields once per tiny read), so counting protocol
-- steps, rather than time, throttled a first frame down to a few thousand steps/second and
-- made it appear many seconds late.
Session.MAX_BYTES_PER_TICK = 1048576
Session.MAX_CPU_PER_TICK = 0.03
-- Belt and braces: a pathological peer must not spin forever inside one tick.
Session.MAX_STEPS_PER_TICK = 1000000
-- Connecting never blocks the UI thread: the socket is non-blocking from the start, and the TCP
-- connect and then the RFB handshake are driven by a task every `CONNECT_TICK` seconds. Each phase
-- has its own deadline (seconds): a blackholed address or a server that accepts but never speaks
-- ends in an error instead of a frozen screen.
Session.CONNECT_TICK = 0.05
Session.CONNECT_TIMEOUT = 10
Session.HANDSHAKE_TIMEOUT = 20
-- Turning Wi-Fi on is asynchronous, and NetworkMgr can be left with a pending attempt of its
-- own (it then just reports EBUSY and never calls us back). While waiting, the link is checked
-- every `WIFI_POLL` seconds and dialled as soon as it is up; after `WIFI_WAIT_TIMEOUT` the attempt
-- fails. Never leave the user staring at a "connecting" that cannot finish.
Session.WIFI_POLL = 1
Session.WIFI_WAIT_TIMEOUT = 30
-- TCP keepalive (seconds idle before the first probe, between probes, probes): Wi-Fi going away
-- under a live connection (KOReader turns it off on suspend) reports nothing by itself, so a quiet
-- socket would look connected forever. With these the kernel fails it within about a minute.
Session.KEEPALIVE = { idle = 30, interval = 10, count = 3 }

-- Seconds without key input before the screen update request held during a key burst is sent.
-- E-ink redraws block the UI thread, so a redraw started mid-burst delays the next key press.
Session.INPUT_QUIET = 0.3

-- Seconds between an input event and a modifier release right after it. A combo sent in one burst
-- (Send keys' Alt+Tab) can reach the X server before the window manager has grabbed the keyboard
-- for the key, which then misses the release: openbox's switcher stayed open behind x11vnc. A few
-- ms were enough there; this leaves room for Wi-Fi bunching.
Session.MODIFIER_RELEASE_GAP = 0.03
local MODIFIER_KEYSYMS = { [0xFFE1] = true, [0xFFE2] = true, [0xFFE3] = true, [0xFFE4] = true,
    [0xFFE7] = true, [0xFFE8] = true, [0xFFE9] = true, [0xFFEA] = true, [0xFFEB] = true, [0xFFEC] = true }

-- Margin around the visible area that zoomed-in requests also cover, as a fraction of the visible
-- width/height on each side: a short pan then lands on pixels that are already up to date.
Session.REQUEST_MARGIN = Remote.REQUEST_MARGIN

-- The receive path is `recv` into a C buffer, declared by KOReader's ffi/posix_h. There is no
-- second path: without these declarations the plugin cannot receive at all, so say so now.
local recv, EAGAIN, EINTR
do
    local ok, err = pcall(function()
        recv, EAGAIN, EINTR = C.recv, tonumber(C.EAGAIN), tonumber(C.EINTR)
        local _ = C.memmove, C.realloc, C.free, C.strerror
    end)
    if not ok then
        error("vnc.session: ffi/posix_h lacks recv/EAGAIN/EINTR/memmove/realloc/free: " .. tostring(err), 0)
    end
end
-- EWOULDBLOCK is EAGAIN on every platform posix_h supports (Linux, Android, macOS). posix_h has
-- no ECONNRESET: a peer that closes with unread data resets the connection, which LuaSocket also
-- reported as "closed", so it is the same "closed by server" failure.
local EWOULDBLOCK = EAGAIN
local ECONNRESET = ffi.os == "OSX" and 54 or 104
local u8p = ffi.typeof("uint8_t*")

--- Monotonic seconds; a module field so tests can substitute a clock.
function Session._now()
    return time.to_s(time.now())
end

--- Blocks for `d` seconds; a module field so tests can substitute it.
function Session._sleep(d)
    require("socket").sleep(d)
end

--- Before a modifier release: waits out MODIFIER_RELEASE_GAP since the previous input event.
function Session:_input_gap(keysym, down)
    local now = Session._now()
    if not down and MODIFIER_KEYSYMS[keysym] and self._last_input_event then
        local wait = Session.MODIFIER_RELEASE_GAP - (now - self._last_input_event)
        if wait > 0 then
            Session._sleep(wait)
            now = Session._now()
        end
    end
    self._last_input_event = now
end

--[[--
Creates a session. Nothing is opened until @{Session:connect} is called.

--- @tparam table opts
--- @tparam table opts.profile connection profile (see @{vnc.settings})
--- @tparam[opt] table opts.plugin the plugin instance
--- @tparam[opt] function opts.on_state `(state, err)` on every transition (one exception: in
---   worker mode a desktop resize reconnects, which goes connected → connecting → connected
---   without a "disconnected" in between, see `_reconnect_resized`)
--- @tparam[opt] table opts.network_mgr override the network manager (tests)
--- @tparam[opt] function opts.on_update `(tm)` after every decoded FramebufferUpdate, with
---   `tm = { px, bytes, cpu, rects, t0 }`: the summed rect area (remote pixels), the bytes read,
---   the decode CPU seconds, the rect count and the `Session._now()` it started at
--- @tparam[opt] boolean opts.worker_processes after the handshake, decode and scale in worker
---   processes (@{vnc.workers}); the plane is then in shared memory
]]
function Session.new(opts)
    assert(type(opts) == "table" and type(opts.profile) == "table", "Session.new: opts.profile is required")
    local self = setmetatable({
        profile = opts.profile,
        plugin = opts.plugin,
        on_state = opts.on_state,
        state = "disconnected",
        err = nil,
        sock = nil,
        proto = nil,
        remote = nil,
        tx = {},           -- pending outgoing bytes (array of strings)
        fd = nil,          -- the socket's descriptor, for `recv`
        -- Received bytes: one linear C buffer of `rcap` bytes (malloc'ed, nil when unconnected);
        -- the unread ones are [rhead, rtail). `_rx_reserve` moves them to the front (compaction).
        rbuf = nil,
        rcap = 0,
        rhead = 0,
        rtail = 0,
        bulk = false,      -- true once connected: receive whatever has arrived, not just what is needed
        fast_reads = 0,    -- reads the protocol may still take from the buffer without yielding
        fast_budget = 0,   -- bytes it may still take that way in this tick
        in_update = false, -- a FramebufferUpdate is being received
        need = nil,        -- bytes the protocol is waiting for
        done = false,
        attached = false,
        app = nil,
        dirty = nil,       -- accumulated dirty rects, in remote coordinates (a list of disjoint rects)
        wifi_was_on = nil, -- nil until we know
        _connect_cb = nil,
        _network_mgr = opts.network_mgr,
        on_update = opts.on_update,
        worker_processes = opts.worker_processes and true or false,
        workers = nil,     -- the worker link (@{vnc.workers}) while they run
        -- true holds the incremental request that follows every update, like key input does
        hold_incremental = false,
        -- The remote area incremental requests ask for (see `set_view_area`); nil = the whole
        -- framebuffer. `forced` is a non-incremental request for newly visible pixels that is
        -- still owed (it waits while requests are held).
        view_area = nil,
        forced = nil,
        -- Seconds between poll ticks while attached; nil = `POLL_INTERVAL`. The benchmark shortens
        -- it while a request is in flight, so the reply is read as soon as it arrives.
        poll_interval = nil,
    }, Session)
    -- The poll task, bound to this session: `UIManager:unschedule` matches the function, so the
    -- shared `Session._poll` would cancel every session's poll (e.g. a benchmark's own connection
    -- tearing down would stop the viewer's).
    self._poll_task = function() self:_poll() end
    -- The connect phases' tasks, bound the same way.
    self._connect_task = function() self:_connect_tick() end
    self._wifi_task = function() self:_wifi_tick() end
    return self
end

--- @tparam string state
--- @tparam[opt] string err
function Session:_set_state(state, err)
    self.state, self.err = state, err
    logger.dbg("vnc: session", self.profile and self.profile.name, "->", state, err or "")
    if self.on_state then
        local ok, e = pcall(self.on_state, state, err)
        if not ok then logger.warn("vnc: on_state handler failed:", e) end
    end
end

--- The network manager (lazily required, or the injected test double).
function Session:_net()
    if self._network_mgr then return self._network_mgr end
    if not NetworkMgr then NetworkMgr = require("ui/network/manager") end
    return NetworkMgr
end

--- @treturn string one of `disconnected`, `connecting`, `connected`, `error`
function Session:get_state() return self.state end
function Session:is_connected() return self.state == "connected" end
function Session:is_attached() return self.attached end
function Session:get_remote() return self.remote end
function Session:get_profile() return self.profile end

--[[--
Points the session at a (re)loaded copy of its profile. The picture settings that are read once
per connection wait for the next one.
--- @tparam table profile
]]
function Session:set_profile(profile)
    self.profile = profile
end

--- Hands the global scaling mode (the Display panel's "Sharp" scaling) to the remote, if there is one yet.
function Session:_apply_scaling()
    if self.remote then
        local settings = self.plugin and self.plugin.settings and self.plugin.settings.data.settings
        self.remote:set_scaling(settings and settings.scaling == "sharp" and "sharp" or "smooth")
    end
end
function Session:get_error() return self.err end

-- ---------------------------------------------------------------- connect

--[[--
Opens the connection: turns Wi-Fi on when needed, connects the socket and runs the RFB
handshake.

Nothing here blocks the UI thread (bar a host name lookup): the TCP connect and the handshake run
in scheduled ticks, and turning Wi-Fi on is asynchronous, so `callback(ok, err)` is normally
invoked after `connect()` returns. When it reports success the plane exists and the session is
usable. A hangup or disconnect meanwhile ends the attempt without calling it.
--- @tparam[opt] function callback `(ok, err)`, called at most once
]]
function Session:connect(callback)
    if self.state == "connecting" or self.state == "connected" then
        if callback then callback(false, "already connecting or connected") end
        return
    end
    self._connect_cb = callback
    self.err = nil
    self:_set_state("connecting")
    -- Every attempt has its own token: NetworkMgr's callback can arrive after this attempt was
    -- given up or replaced, and then it must not dial (c.f., Session:_do_connect).
    self._attempt = (self._attempt or 0) + 1
    local attempt = self._attempt

    local net = self:_net()
    local wifi_on = net:isWifiOn()
    -- While retrying (or reconnecting after a desktop resize), Wi-Fi we turned on earlier is
    -- still on: keep the duty to turn it off.
    local keeps_duty = (self.keep_wifi or self._keep_duty_once) and self.wifi_was_on == false
    self._keep_duty_once = nil
    if not keeps_duty then self.wifi_was_on = wifi_on end
    if wifi_on and self:_link_up() then
        self:_do_connect(attempt)
        return
    end
    -- Off, or on without a route (on PocketBook "on" is only QueryNetwork's NET_CONNECTED): dialling
    -- could only fail, so the link is brought up first, as NetworkMgr does for its own users.
    local status = net:turnOnWifiAndWaitForConnection(function()
        self:_do_connect(attempt)
    end)
    if status == false then
        if self._attempt == attempt and self.state == "connecting" and not self.sock then
            if not keeps_duty then self.wifi_was_on = nil end
            self:_fail("could not turn on Wi-Fi")
        end
        return
    end
    -- (it may have called back already, when the link came up meanwhile)
    if self._attempt == attempt and self.state == "connecting" and not self.sock then
        self._wifi_deadline = Session._now() + Session.WIFI_WAIT_TIMEOUT
        self._phase = "wifi"
        UIManager:scheduleIn(Session.WIFI_POLL, self._wifi_task)
    end
end

--- The remote plane's options: shared memory when the workers will write it.
function Session:_plane_opts()
    return self.worker_processes and { shared = true } or nil
end

--- @treturn boolean true when the network manager reports a usable link (Wi-Fi up with a route),
---   the test KOReader's own NetworkMgr uses before it calls anyone back
function Session:_link_up()
    local net = self:_net()
    if not net:isWifiOn() then return false end
    if net.isConnected then return net:isConnected() and true or false end
    return true
end

function Session:_finish_connect(ok, err)
    local cb = self._connect_cb
    self._connect_cb = nil
    if ok and self.worker_processes and not self.workers then
        local pok, link, werr, lost = pcall(function() return require("vnc/workers").start(self) end)
        if pok and not link and lost then
            -- (a worker may have held the socket: the connection fails, the callback hears of it)
            self._connect_cb = cb
            self:_fail(werr)
            return
        end
        if not (pok and link) then
            logger.warn("vnc: worker processes not started, decoding in-process:", pok and werr or link)
        end
    end
    if cb then
        local ok2, e = pcall(cb, ok, err)
        if not ok2 then logger.warn("vnc: connect callback failed:", e) end
    end
end

--[[--
Waiting for Wi-Fi: dials once the link is up, even if NetworkMgr never calls back (EBUSY: it was
busy with an attempt of its own, which may well bring the link up), and fails the attempt when the
link is still down after `WIFI_WAIT_TIMEOUT`.
]]
function Session:_wifi_tick()
    if self._phase ~= "wifi" or self.state ~= "connecting" then return end
    if self:_link_up() then
        logger.dbg("vnc: the Wi-Fi link is up")
        self:_do_connect(self._attempt)
        return
    end
    if Session._now() >= self._wifi_deadline then
        self:_fail(string.format("timed out after %ds waiting for Wi-Fi", Session.WIFI_WAIT_TIMEOUT))
        return
    end
    UIManager:scheduleIn(Session.WIFI_POLL, self._wifi_task)
end

--- Asks the kernel to probe an idle connection (see `KEEPALIVE`). Options this LuaSocket or kernel
--- lacks are skipped: plain keepalive still helps, only later.
local function set_keepalive(sock)
    local k = Session.KEEPALIVE
    for _, o in ipairs{ { "keepalive", true }, { "tcp-keepidle", k.idle },
                        { "tcp-keepintvl", k.interval }, { "tcp-keepcnt", k.count } } do
        local ok, res, err = pcall(sock.setoption, sock, o[1], o[2])
        if not (ok and res) then logger.dbg("vnc: socket option", o[1], "not set:", ok and err or res) end
    end
end

--- Starts dialling for attempt `attempt`, unless that attempt is no longer the one in progress (it
--- failed, was disconnected, or a newer one started since Wi-Fi was asked for) or already dialled.
function Session:_do_connect(attempt)
    if attempt ~= self._attempt or self.state ~= "connecting" or self.sock then
        logger.dbg("vnc: ignoring the Wi-Fi callback of an attempt that is over or dialled")
        return
    end
    UIManager:unschedule(self._wifi_task)
    local p = self.profile
    logger.dbg("vnc: connecting to", p.host, p.port)
    local socket = require("socket")
    local sock = socket.tcp()
    if not sock then
        return self:_fail("could not create a TCP socket")
    end
    sock:settimeout(0)
    -- (with a zero timeout this only starts the connect: "timeout" means it is on its way)
    local ok, err = sock:connect(p.host, p.port)
    if not ok and err ~= "timeout" then
        sock:close()
        self:_fail(string.format("could not connect to %s:%d (%s)", p.host, p.port, tostring(err)))
        return
    end
    sock:setoption("tcp-nodelay", true)
    set_keepalive(sock)
    local fd = sock:getfd()
    if type(fd) ~= "number" or fd < 0 then
        sock:close()
        self:_fail(string.format("LuaSocket gave no descriptor for the socket (getfd: %s)", tostring(fd)))
        return
    end
    self.sock, self.fd = sock, fd
    self:_rx_alloc(Session.RX_BUFFER)

    -- The picture settings come from the profile and are read once per connection: an edit applies
    -- on the next connection only, since a live SetPixelFormat would race updates already in flight
    -- in the old format.
    local self_ref = self
    self.proto = Protocol.new{
        io = {
            write = function(s) self_ref.tx[#self_ref.tx + 1] = s end,
            read = function(n) return self_ref:_read(n) end,
            read_ptr = function(n) return self_ref:_read_ptr(n) end,
        },
        host = p.host,
        port = p.port,
        password = p.password,
        shared = true,
        pixel_format = PxFmt.for_depth(p.color_depth),
        encodings = Encodings.order(p.enable_tight == true,
            { jpeg_quality = p.jpeg_quality, compress_level = p.compress_level }),
        get_plane = function() return self_ref.remote and self_ref.remote:get_plane() end,
        hold_updates = function() return self_ref:_holding() end,
        request_area = function() return self_ref:_request_area() end,
        callbacks = {
            on_connected = function(name, w, h)
                logger.info("vnc: connected to", name, w, h)
                -- a fresh connection starts with the whole screen; the app narrows it again
                self_ref.view_area, self_ref.forced = nil, nil
                if self_ref.remote then
                    -- reconnect / fresh size: keep the object so the app's reference stays valid
                    self_ref.remote:resize(w, h)
                else
                    self_ref.remote = Remote.new(w, h, self_ref:_plane_opts())
                end
                self_ref:_apply_scaling()
                self_ref:_set_state("connected")
            end,
            on_update_start = function()
                self_ref.in_update = true
                if Util.timing_enabled() or self_ref.on_update then
                    -- c_from: CPU clock at the start, for when it began inside a step already
                    -- running (reads served from the buffer do not yield between updates)
                    self_ref.tm = { t0 = Session._now(), cpu = 0, bytes = 1, rects = 0, px = 0,
                        c_from = os.clock() }
                end
            end,
            on_update_done = function()
                self_ref.in_update = false
                if self_ref.tm then self_ref.tm.finished = true end
            end,
            on_rect = function(x, y, w, h)
                local tm = self_ref.tm
                if tm then tm.rects, tm.px = tm.rects + 1, tm.px + w * h end
                -- One tick of rectangles is handed to the app as a set of *disjoint* rectangles:
                -- merging only the ones that touch keeps a couple of small changes far apart from
                -- turning into one huge (but mostly unchanged) refresh region.
                self_ref.dirty = Util.add_rect(self_ref.dirty or {}, { x = x, y = y, w = w, h = h })
                -- A payload larger than one poll tick is decoded across ticks, so a repaint
                -- can happen while the plane is only half written. Mark the rect stale *after*
                -- the write, or that half-written part would stay in the canvas buffer forever.
                if self_ref.remote then self_ref.remote:mark_dirty(x, y, w, h) end
            end,
            on_desktop_resize = function(w, h)
                logger.info("vnc: remote desktop resized to", w, h)
                if self_ref.remote then
                    self_ref.remote:resize(w, h)
                else
                    self_ref.remote = Remote.new(w, h, self_ref:_plane_opts())
                end
                -- the area was in the old desktop's coordinates (and the view is re-fitted)
                self_ref.view_area, self_ref.forced = nil, nil
                self_ref:_apply_scaling()
                if self_ref.app then self_ref.app:on_remote_resized(w, h) end
                -- resynchronise with a non-incremental update of the whole new area
                self_ref:request_full_update()
            end,
            on_bell = function()
                if self_ref.app then self_ref.app:on_bell() end
            end,
            on_cut_text = function(text)
                -- (its length only: a clipboard may hold passwords)
                logger.dbg("vnc: server cut text:", #text, "bytes")
            end,
        },
    }
    self.done = false
    self.need = nil
    if ok then
        self:_start_handshake()
    else
        self._phase = "dial"
        self._deadline = Session._now() + Session.CONNECT_TIMEOUT
    end
    UIManager:scheduleIn(Session.CONNECT_TICK, self._connect_task)
end

function Session:_start_handshake()
    self._phase = "handshake"
    self._deadline = Session._now() + Session.HANDSHAKE_TIMEOUT
end

--[[--
One connect tick: checks whether the TCP connect completed, or pumps the handshake (each pump is
bounded like a poll tick), and fails the attempt once the phase's deadline has passed.
]]
function Session:_connect_tick()
    local phase = self._phase
    if (phase ~= "dial" and phase ~= "handshake") or self.state ~= "connecting" then return end
    UIManager:unschedule(self._connect_task)
    local p = self.profile
    if phase == "dial" then
        local socket = require("socket")
        local _, writable = socket.select(nil, { self.sock }, 0)
        if writable and writable[1] then
            -- the outcome: a second connect reports success (or "already connected") or the error
            local ok, err = self.sock:connect(p.host, p.port)
            if not (ok or err == "already connected") then
                self:_fail(string.format("could not connect to %s:%d (%s)", p.host, p.port, tostring(err)))
                return
            end
            self:_start_handshake()
        elseif Session._now() >= self._deadline then
            self:_fail(string.format("could not connect to %s:%d (timeout)", p.host, p.port))
            return
        else
            UIManager:scheduleIn(Session.CONNECT_TICK, self._connect_task)
            return
        end
    end
    local status = self:_pump(true)
    if status == "error" then return end
    if status == "connected" then
        self._phase = nil
        self.bulk = true
        self:_finish_connect(true)
        return
    end
    if Session._now() >= self._deadline then
        self:_fail("timed out during the RFB handshake")
        return
    end
    UIManager:scheduleIn(status == "busy" and 0 or Session.CONNECT_TICK, self._connect_task)
end

-- ---------------------------------------------------------------- transport

--- Sends everything queued in `tx`, keeping any unsent tail for the next tick.
--- @treturn boolean|nil, string|nil nil plus an error only for real socket errors
function Session:_flush_tx()
    while #self.tx > 0 do
        local out = self.tx[1]
        local sent, err, last = self.sock:send(out)
        -- A timed-out send has still put the bytes up to `last` on the wire, and LuaSocket
        -- reports that progress only as its *third* return value. Keeping those bytes queued
        -- would send them again on the next attempt, and the server would read every later
        -- message from the wrong offset.
        if not sent and err == "timeout" and type(last) == "number" and last > 0 then
            sent = last
        end
        if sent == #out then
            table.remove(self.tx, 1)
        elseif sent then
            self.tx[1] = out:sub(sent + 1)
            return true
        elseif err == "timeout" then
            return true
        else
            return nil, string.format("socket send failed (%s)", tostring(err))
        end
    end
    return true
end

--- Queues are flushed right away for UI-driven input, so typing feels immediate.
function Session:_flush_now()
    if not self.sock then return end
    local ok, err = self:_flush_tx()
    if not ok then self:_fail(err) end
end

--- Resumes the protocol, remembering what it asked for.
--- @treturn boolean false when the session failed
function Session:_resume()
    local c0 = os.clock()
    local a, b = self.proto:step()
    local tm = self.tm
    if tm then
        -- A tick may end mid-update, so the CPU time of every tick that touched it is summed.
        tm.cpu = tm.cpu + (os.clock() - math.max(c0, tm.c_from or c0))
        tm.c_from = nil
        if tm.finished then
            self.tm = nil
            if Util.timing_enabled() then
                logger.dbg(string.format("vnc-timing: update rects=%d bytes=%d decode_ms=%.1f wall_ms=%.1f",
                    tm.rects, tm.bytes, tm.cpu * 1000, (Session._now() - tm.t0) * 1000))
            end
            if self.on_update then
                local ok, e = pcall(self.on_update, tm)
                if not ok then logger.warn("vnc: on_update handler failed:", e) end
            end
        end
    end
    if a == "need" then
        self.need = b
    elseif a == "done" then
        self.done = true
    else
        self:_fail(b)
        return false
    end
    return true
end

--[[--
The protocol's transport reads (they run inside the protocol coroutine).

`_read_ptr(n)` consumes `n` bytes and returns a `const uint8_t*` to them in the receive buffer
(plus the buffer, as the reader's anchor). It never returns nil: while the buffer holds the `n`
bytes they are served directly, since a coroutine switch per read is slow (LuaJIT does not
compile yields) and the decoders read a few bytes at a time. After `FAST_READS` such reads, or
when the tick's byte budget is spent, or once an update has finished, or when the bytes have not
arrived yet, it yields `("need", n)`; `_pump` resumes it only once the buffer holds them, so it
then serves them without any further check.

Pointer lifetime: the buffer is compacted, grown or shrunk (`_rx_reserve`) and freed only by
`_pump` and `_teardown_connection`, i.e. only while the coroutine is suspended in such a yield. A
pointer is therefore valid until the next read that yields, and the reader contract
(@{vnc.util.Reader:ptr}) is stricter still: valid until the next read from the reader. Every
decoder in @{vnc.encodings} uses a pointer before its next read (checked when this path was
written; no decoder holds one across reads).

`_read(n)` is the same as a Lua string, for the few text fields (versions, names, reasons, cut
text); numbers and pixels go through `_read_ptr`.
]]
function Session:_read_ptr(n)
    local head = self.rhead
    if self.fast_reads > 0 and n <= self.fast_budget and self.rtail - head >= n then
        local tm = self.tm
        if not (tm and tm.finished) then
            self.fast_reads = self.fast_reads - 1
            self.fast_budget = self.fast_budget - n
            self.rhead = head + n
            if tm then tm.bytes = tm.bytes + n end
            return self.rbuf + head, self.rbuf
        end
    end
    coroutine.yield("need", n)
    -- `_pump` resumes only once the buffer holds `n` bytes (and has charged them to its budget)
    head = self.rhead
    if self.rtail - head < n then
        error(string.format("receive buffer holds %d bytes, the read wanted %d", self.rtail - head, n), 0)
    end
    self.rhead = head + n
    if self.tm then self.tm.bytes = self.tm.bytes + n end
    return self.rbuf + head, self.rbuf
end

function Session:_read(n)
    return ffi.string(self:_read_ptr(n), n)
end

--- (Re)allocates the receive buffer to `cap` bytes, keeping its contents up to `cap`.
function Session:_rx_alloc(cap)
    local old = self.rbuf
    if old ~= nil then ffi.gc(old, nil) end
    local p = C.realloc(old, cap)
    if p == nil then
        if old ~= nil then ffi.gc(old, C.free) end
        return nil
    end
    self.rbuf, self.rcap = ffi.gc(ffi.cast(u8p, p), C.free), cap
    return true
end

--- Frees the receive buffer.
function Session:_rx_free()
    local p = self.rbuf
    if p ~= nil then
        ffi.gc(p, nil)
        C.free(p)
    end
    self.rbuf, self.rcap, self.rhead, self.rtail = nil, 0, 0, 0
end

--[[--
Makes room for a read of `need` bytes (more than the buffer holds unread): moves the unread bytes
to the front, then grows the buffer when `need` does not fit, or shrinks it back to `RX_BUFFER`
once a large read is over. Only called from `_pump`, with the coroutine suspended (see `_read_ptr`).
--- @treturn boolean|nil, string|nil nil plus an error when `need` is over `MAX_RX_BUFFER` or memory ran out
]]
function Session:_rx_reserve(need)
    if need > Session.MAX_RX_BUFFER then
        return nil, string.format("server message needs a %d-byte read (more than %d)", need, Session.MAX_RX_BUFFER)
    end
    local head, avail = self.rhead, self.rtail - self.rhead
    if head > 0 then
        if avail > 0 then C.memmove(self.rbuf, self.rbuf + head, avail) end
        self.rhead, self.rtail = 0, avail
    end
    local cap = self.rcap
    local want = cap
    if need > cap then
        want = math.min(math.max(need, 2 * cap), Session.MAX_RX_BUFFER)
    elseif cap > Session.RX_BUFFER and need <= Session.RX_BUFFER then
        want = Session.RX_BUFFER -- (avail < need, so the unread bytes fit)
    end
    if want ~= cap and not self:_rx_alloc(want) then
        return nil, string.format("out of memory for a %d-byte receive buffer", want)
    end
    return true
end

--[[--
One round of work: flush outgoing bytes, feed the protocol, collect its requests.

--- @tparam[opt] boolean stop_connected return as soon as the handshake completed
--- @treturn string `"again"` (waiting for data), `"busy"` (budget spent, more data is buffered),
---   `"done"`, `"connected"` or `"error"`
]]
function Session:_pump(stop_connected)
    if not self.proto then return "error" end -- (closed: nothing to read or write)
    local ok, err = self:_flush_tx()
    if not ok then
        self:_fail(err)
        return "error"
    end

    local budget = Session.MAX_BYTES_PER_TICK
    local cpu_deadline = os.clock() + Session.MAX_CPU_PER_TICK
    local steps = Session.MAX_STEPS_PER_TICK
    while steps > 0 do
        steps = steps - 1
        if self.done then return "done" end
        if stop_connected and self.state == "connected" then return "connected" end
        local resume = false
        local need = self.need
        if need then
            if self.rtail - self.rhead >= need then
                -- the protocol's pending read is served from the buffer once resumed
                self.need = nil
                budget = budget - need
                resume = true
            else
                local rok, rerr = self:_rx_reserve(need)
                if not rok then
                    self:_fail(rerr)
                    return "error"
                end
                local tail = self.rtail
                local want = need - tail
                if self.bulk then
                    local room = self.rcap - tail
                    if want < Session.RECV_CHUNK then want = math.min(Session.RECV_CHUNK, room) end
                end
                local got = tonumber(recv(self.fd, self.rbuf + tail, want, 0))
                if got > 0 then
                    self.rtail = tail + got
                    budget = budget - got
                else
                    local e = got < 0 and ffi.errno()
                    if e == EAGAIN or e == EWOULDBLOCK then
                        return "again"
                    elseif got == 0 or e == ECONNRESET then
                        self:_fail("connection closed by server")
                        return "error"
                    elseif e ~= EINTR then -- (interrupted: just receive again)
                        self:_fail(string.format("socket receive failed (%s)", ffi.string(C.strerror(e))))
                        return "error"
                    end
                end
            end
        else
            resume = true
        end
        if resume then
            self.fast_reads, self.fast_budget = Session.FAST_READS, budget
            local resumed = self:_resume()
            budget, self.fast_reads, self.fast_budget = self.fast_budget, 0, 0
            if not resumed then return "error" end
            local ok2, err2 = self:_flush_tx()
            if not ok2 then
                self:_fail(err2)
                return "error"
            end
        end
        -- (the step that completed the handshake may also have spent the budget: "busy" then
        -- would leave a connect tick that, seeing "connected", never finishes the attempt)
        if stop_connected and self.state == "connected" then return "connected" end
        if budget <= 0 or os.clock() >= cpu_deadline then return "busy" end
    end
    return "busy"
end

-- ---------------------------------------------------------------- lifecycle

--- Registers the poll task and resynchronises the framebuffer. No-op unless connected (a session
--- that dropped is attached again once it is back, c.f. @{vnc.reconnect}).
function Session:attach(app)
    if not self:is_connected() then return end
    self.app = app
    if self.attached then return end
    self.attached = true
    self.last_poll = nil -- the time spent detached is not a blocked poll
    local link = self.workers
    if link then
        -- the decode worker resynchronises with a full update and resumes reading. F goes
        -- first: the worker may wake between the two writes, and resumed alone it would send
        -- an area owed since the detach on its own before the full request that covers it
        self._worker_wait = Workers().UI_POLL
        UIManager:scheduleIn(self._worker_wait, self._poll_task)
        link.decode:send("F")
        link.decode:send("R")
        return
    end
    UIManager:scheduleIn(self.poll_interval or Session.POLL_INTERVAL, self._poll_task)
    -- Non-incremental full area: resynchronises after a detach, and absorbs anything the
    -- server pushed while we were not reading.
    self:request_full_update()
    self:_flush_now()
end

--- Stops the poll task, keeping the socket, the plane and Wi-Fi up.
function Session:detach()
    UIManager:unschedule(self._poll_task)
    self.attached = false
    self.app = nil
    self.dirty = nil
    -- (the decode worker stops reading the socket, as the in-process poll task would)
    if self.workers then self.workers.decode:send("S") end
end

--- One tick's work, free of UIManager and the app: pumps the connection, releases a
--- forced or held update (flushing what that sends) and takes the dirty rects.
--- Returns `status, rects`: status is `_pump`'s ("error"/"done" end the session's use; the
--- caller does the teardown), or "failed" after `_fail` ran on a flush error; `rects` is
--- the list of dirty rects or nil.
function Session:_service()
    local status = self:_pump()
    if status == "error" or status == "done" then return status end
    if self.forced and not self:_holding() then
        self:_send_forced()
        local ok, err = self:_flush_tx()
        if not ok then
            self:_fail(err)
            return "failed"
        end
    end
    if self.proto and self.proto.update_pending and not self:_holding() then
        self.proto:release_update()
        local ok, err = self:_flush_tx()
        if not ok then
            self:_fail(err)
            return "failed"
        end
    end
    local rects
    if self.dirty and self.dirty[1] then
        rects = self.dirty
        self.dirty = nil
    end
    return status, rects
end

--- The poll task (scheduled as `_poll_task`, which `UIManager:unschedule` can cancel).
function Session:_poll()
    if not self.attached then return end
    if Util.timing_enabled() then
        local now = Session._now()
        -- (in worker mode against the interval the last tick scheduled: `Link:interval`)
        local expect = self.workers and (self._worker_wait or Workers().UI_POLL) or Session.POLL_INTERVAL
        if self.last_poll and now - self.last_poll > 2 * expect then
            logger.dbg(string.format("vnc-timing: poll gap ms=%.1f", (now - self.last_poll) * 1000))
        end
        self.last_poll = now
    else
        self.last_poll = nil
    end
    if self.workers then return self:_poll_workers() end
    local status, rects = self:_service()
    if status == "error" or status == "done" then
        UIManager:unschedule(self._poll_task)
        self.attached = false
        return
    end
    if status == "failed" then return end
    if rects then
        if self.app then
            self.app:on_framebuffer_dirty(rects)
        else
            self.dirty = rects -- nobody to hand them to: keep them for the next tick
        end
    end
    -- the app callback may have rescheduled the task (see `poll_soon`): keep exactly one
    UIManager:unschedule(self._poll_task)
    if self.attached then
        local interval = self.poll_interval or Session.POLL_INTERVAL
        if status == "busy" then
            interval = 0 -- more is buffered: carry on after the UI has had its turn
        elseif self.in_update then
            interval = math.min(interval, Session.POLL_INTERVAL_BUSY)
        end
        UIManager:scheduleIn(interval, self._poll_task)
    end
end

--[[--
The poll task while the workers run (@{vnc.workers}): drains their messages. The scale worker's
canvas rects of the view the viewer last asked for (`link.view_id`, see
@{vnc.framebuffer.Remote:draw_to}) become one `app:on_framebuffer_dirty_canvas(rects)` per tick
(those of an older view are dropped: that view's paint is already superseded); `B` rings the
bell; a worker's error or end fails the session (`Link:poll`); a desktop resize reconnects.
]]
function Session:_poll_workers()
    local link = self.workers
    local out = link:poll()
    local current = link.view_id and tostring(link.view_id)
    local rects, full, rw, rh
    local geoms = link.view_geoms
    for _, l in ipairs(out) do
        if l:sub(1, 2) == "C " then
            local id, rest = l:match("^C (%d+) (.*)$")
            -- (the shared canvas now holds a render of this view's geometry, whatever its id)
            local n = tonumber(id)
            if n and geoms and geoms[n] then
                link.canvas_geom = geoms[n]
                for k in pairs(geoms) do
                    if k < n then geoms[k] = nil end
                end
            end
            if id and id == current and not full then
                if rest == "full" then
                    full = true
                else
                    for x, y, w, h in rest:gmatch("(%d+) (%d+) (%d+) (%d+)") do
                        rects = Util.add_rect(rects or {},
                            { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) })
                    end
                end
            end
        else
            local w, h = l:match("^Z (%d+) (%d+)$")
            if w then rw, rh = tonumber(w), tonumber(h) end
        end
    end
    if rw then return self:_reconnect_resized(rw, rh) end
    if self.workers ~= link then return end -- the session failed (Link:poll ran _fail)
    if full then rects = { { x = 0, y = 0, w = link.view_cw, h = link.view_ch } } end
    if rects and self.app and self.app.on_framebuffer_dirty_canvas then
        self.app:on_framebuffer_dirty_canvas(rects)
    end
    -- the app callback may have rescheduled the task (see `poll_soon`): keep exactly one
    UIManager:unschedule(self._poll_task)
    if self.attached and self.workers == link then
        self._worker_wait = link:interval()
        UIManager:scheduleIn(self._worker_wait, self._poll_task)
    end
end

--[[--
The decode worker reported a new desktop size (`Z`) and exited: the plane is the UI process'
and cannot change under the workers, so the session connects again, which brings a plane of the
new size and new workers. On success the app it showed is attached again and told of the new
size; a failure fails the session. Wi-Fi stays as it is (this session keeps any duty to turn it
off).
]]
function Session:_reconnect_resized(w, h)
    logger.info("vnc: remote desktop resized to", w, h, "- reconnecting")
    local app = self.app
    self:_teardown_connection()
    -- (the connection is gone: connect() refuses a session that is still "connected")
    self.state = "disconnected"
    self._keep_duty_once = true
    self:connect(function(ok, err)
        if not ok then
            if self.state ~= "error" then self:_fail(err) end
            return
        end
        -- (a viewer closed meanwhile detached: then there is nobody to tell)
        if app and self.app == app then
            self:attach(app)
            app:on_remote_resized(self.remote:get_size())
        end
    end)
end

--- Moves the next poll tick to `poll_interval` from now (attached sessions only).
function Session:poll_soon()
    if not self.attached then return end
    UIManager:unschedule(self._poll_task)
    local interval = self.poll_interval or Session.POLL_INTERVAL
    if self.workers then
        interval = Workers().UI_POLL
        self._worker_wait = interval
    end
    UIManager:scheduleIn(interval, self._poll_task)
end

--- Closes the socket and frees the protocol (or stops the workers), keeping the plane for display.
function Session:_teardown_connection()
    if self.workers then self.workers:stop() end
    UIManager:unschedule(self._poll_task)
    UIManager:unschedule(self._connect_task)
    UIManager:unschedule(self._wifi_task)
    self._phase = nil
    self.attached = false
    if self.sock then
        self.sock:close()
        self.sock = nil
    end
    if self.proto then
        self.proto:free()
        self.proto = nil
    end
    self.tx, self.need, self.done, self.fd = {}, nil, false, nil
    self:_rx_free()
    self.bulk, self.in_update, self.fast_reads, self.fast_budget = false, false, 0, 0
    -- An update cut short by the teardown must not leave its timing state for the next connection.
    self.tm = nil
    -- Rectangles a dead connection never got to report: a reconnect requests the whole screen again,
    -- so they would only be redundant (and they may be in the old desktop's coordinates).
    self.dirty = nil
end

--- Restores Wi-Fi if we were the ones who turned it on.
function Session:_restore_wifi()
    if self.wifi_was_on == false then
        -- Another connection still needs the Wi-Fi this one turned on: it inherits the duty, so
        -- the last connection to go turns it off.
        local heir
        local sessions = self.plugin and self.plugin.sessions
        if sessions then
            for _, s in pairs(sessions) do
                if s ~= self and (s.state == "connected" or s.state == "connecting" or s.keep_wifi) then
                    heir = s
                    break
                end
            end
        end
        if heir then
            heir.wifi_was_on = false
        else
            logger.dbg("vnc: turning Wi-Fi back off")
            self:_net():turnOffWifi()
        end
    end
    self.wifi_was_on = nil
end

--- Fails the session, keeping the app (and the last picture) alive for a reconnect.
function Session:_fail(err)
    local msg = tostring(err)
    logger.warn("vnc: session failed:", msg)
    self:_teardown_connection()
    -- Listeners hear of it before Wi-Fi is restored: one that retries (the viewer's reconnect box)
    -- turns retry mode on from here, and Wi-Fi stays on for its first attempt.
    self:_set_state("error", msg)
    if not self.keep_wifi then self:_restore_wifi() end
    self:_finish_connect(false, msg)
end

--- Retry mode: while on, a failure or hangup leaves Wi-Fi on and the duty to turn it off with this
--- session. Turning it off with no connection restores Wi-Fi (the last connection turns it off).
function Session:set_keep_wifi(on)
    on = on and true or false
    local was = self.keep_wifi
    self.keep_wifi = on
    if was and not on and (self.state == "error" or self.state == "disconnected") then
        self:_restore_wifi()
    end
end

--- Drops the connection but keeps the plane (and, in retry mode, Wi-Fi) for a reconnect.
function Session:hangup()
    self:_teardown_connection()
    if not self.keep_wifi then self:_restore_wifi() end
    self:_set_state("disconnected")
end

--- Closes the connection for good and frees the plane.
function Session:disconnect()
    self:_teardown_connection()
    self:_restore_wifi()
    if self.remote then
        self.remote:free()
        self.remote = nil
    end
    self:_set_state("disconnected")
end

-- ---------------------------------------------------------------- requests

--- @treturn boolean true once the handshake is over: before that (the protocol exists from the dial
---   on) nothing may be queued, or it would go out in the middle of the handshake
function Session:_live()
    return self.workers ~= nil or (self.proto ~= nil and self._phase == nil)
end

--- Queues a non-incremental update request for the whole framebuffer.
--- Safe to call from protocol callbacks (it never flushes).
function Session:request_full_update()
    if self.workers then
        self.workers.decode:send("F")
        return
    end
    if not self:_live() or not self.remote then return end
    local w, h = self.remote:get_size()
    self.forced = nil -- covered
    self.proto:request_update(0, 0, 0, w, h)
end

--- Bounding box of the part of rect `a` not inside rect `b` (nil when `b` covers `a`).
local function uncovered_bbox(a, b)
    local i = Util.intersect_rect(a, b)
    if not i then return a end
    local box
    if i.x > a.x then box = Util.union_rect(box, { x = a.x, y = a.y, w = i.x - a.x, h = a.h }) end
    if i.x + i.w < a.x + a.w then
        box = Util.union_rect(box, { x = i.x + i.w, y = a.y, w = a.x + a.w - i.x - i.w, h = a.h })
    end
    if i.y > a.y then box = Util.union_rect(box, { x = i.x, y = a.y, w = i.w, h = i.y - a.y }) end
    if i.y + i.h < a.y + a.h then
        box = Util.union_rect(box, { x = i.x, y = i.y + i.h, w = i.w, h = a.y + a.h - i.y - i.h })
    end
    return box
end

--- @treturn table the whole framebuffer as `{x, y, w, h}`, or nil before there is one
function Session:_whole_area()
    if self.proto and self.proto.width then
        return { x = 0, y = 0, w = self.proto.width, h = self.proto.height }
    end
    if self.remote then
        local w, h = self.remote:get_size()
        return { x = 0, y = 0, w = w, h = h }
    end
end

--- @treturn number|nil, number, number, number the area incremental requests ask for (nil: the
---   whole framebuffer, exactly as without a view area)
function Session:_request_area()
    local a, whole = self.view_area, self:_whole_area()
    if not (a and whole) then return nil end
    local c = Util.intersect_rect(a, whole)
    if not c then return nil end
    return c.x, c.y, c.w, c.h
end

--[[--
Tells the session which remote area the viewer shows (see @{vnc.framebuffer:visible_remote_rect}).

From now on the incremental requests ask for that area only, so the server sends (and we decode)
nothing that is off screen. The pixels of the new area that the previous one did not cover were
not kept up to date, so one non-incremental request for them (the bounding box of that part) is
sent, and they arrive even when they did not change.

That request is written at once (the next poll tick flushes it; this is called from the viewer's
paint, which must not do socket I/O), even though an incremental one is outstanding: a server
answers an incremental request only once something inside it changes, so on a still screen a
request queued behind it would never be sent. libvncserver folds every pending request into one
requested region (`requestedRegion`) that the next update answers, so there this does not leave a
second request behind; other servers may differ. While requests are held (`_holding`) it waits;
it then goes out with the owed incremental one as a single non-incremental request of their union.
While the session is not attached it is only owed: `attach` requests the whole screen, which
covers it.
--- @tparam table|nil rect `{x, y, w, h}` in remote coordinates; nil means the whole framebuffer
]]
function Session:set_view_area(rect)
    local link = self.workers
    if link then
        -- (the decode worker keeps the area; an unchanged one is not sent again)
        local l = rect and string.format("V %d %d %d %d", rect.x, rect.y, rect.w, rect.h) or "V -"
        if l ~= link.sent_view_area then
            link.sent_view_area = l
            link.decode:send(l)
        end
        return
    end
    local whole = self:_whole_area()
    if not whole then return end
    local new = rect and Util.intersect_rect(rect, whole) or whole
    if new.x == 0 and new.y == 0 and new.w == whole.w and new.h == whole.h then new = nil end
    local old = self.view_area and Util.intersect_rect(self.view_area, whole) or whole
    self.view_area = new
    local missing = uncovered_bbox(new or whole, old)
    if not missing then return end
    self.forced = Util.union_rect(self.forced, missing)
    if self.attached and not self:_holding() then self:_send_forced() end
end

--- Sends the owed non-incremental request for newly visible pixels (merged with an owed
--- incremental request, which it settles).
function Session:_send_forced()
    local f = self.forced
    self.forced = nil
    if not (f and self.proto) then return end
    if self.proto.update_pending then
        local x, y, w, h = self:_request_area()
        if x then f = Util.union_rect(f, { x = x, y = y, w = w, h = h }) else f = self:_whole_area() end
    end
    self.proto:request_update(0, f.x, f.y, f.w, f.h)
end

--- Records key input: screen update requests are held until input has been quiet for
--- `INPUT_QUIET` (pointer taps and drags do not count).
function Session:note_input(what)
    if self.workers then
        self.workers.decode:send("N " .. (what or "key"))
        return
    end
    self.last_input = Session._now()
    if Util.timing_enabled() then logger.dbg("vnc-timing: input", what or "key") end
end

--- @treturn boolean true while key input happened less than `INPUT_QUIET` ago
function Session:_input_recent()
    return self.last_input ~= nil and Session._now() - self.last_input < Session.INPUT_QUIET
end

--- @treturn boolean true while the incremental update request is to be held
function Session:_holding()
    return self.hold_incremental or self:_input_recent()
end

--- @tparam number x remote x
--- @tparam number y remote y
--- @tparam number mask RFB pointer button mask
function Session:send_pointer(x, y, mask)
    if self.workers then
        self.workers.decode:send(string.format("P %d %d %d", x, y, mask))
        return
    end
    if not self:_live() then return end
    self:_input_gap()
    self.proto:send_pointer(x, y, mask)
    self:_flush_now()
end

--- @tparam number keysym X11 keysym
--- @tparam boolean down
function Session:send_key(keysym, down)
    if self.workers then
        -- (the decode worker notes the input and waits out the modifier gap itself)
        self.workers.decode:send(string.format("K %d %d", keysym, down and 1 or 0))
        return
    end
    if not self:_live() then return end
    if down then self:note_input() end
    self:_input_gap(keysym, down)
    self.proto:send_key(keysym, down)
    self:_flush_now()
end

--- @tparam string text
function Session:send_cut_text(text)
    if self.workers then
        self.workers.decode:send("T " .. #text, text)
        return
    end
    if not self:_live() then return end
    self.proto:send_cut_text(text)
    self:_flush_now()
end

return Session
