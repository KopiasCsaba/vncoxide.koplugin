--[[--
VNC session: socket transport, Wi-Fi handling, attach/detach and reconnect.

A session owns one connection to one server. It drives @{vnc.protocol} from a poll
task registered with `UIManager:scheduleIn`, so the app can be closed (detached) without
dropping the connection: while detached the poll task is simply not scheduled, so nothing
is read, nothing is requested, and at most the single outstanding update request is
buffered by the kernel until we resume.

@module vnc.session
]]

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

local Session = {}
Session.__index = Session

-- Seconds between poll ticks while attached.
Session.POLL_INTERVAL = 0.05
-- Caps so a single tick can never monopolise the UI thread. The CPU budget is the one that
-- matters: decoding is step-heavy (Hextile yields once per tiny read), so counting protocol
-- steps, rather than time, throttled a first frame down to a few thousand steps/second and
-- made it appear many seconds late.
Session.MAX_BYTES_PER_TICK = 1048576
Session.MAX_CPU_PER_TICK = 0.03
-- Belt and braces: a pathological peer must not spin forever inside one tick.
Session.MAX_STEPS_PER_TICK = 1000000
-- Wall-clock budget for the synchronous part of a handshake, and the socket timeout used
-- while it runs.
Session.HANDSHAKE_TIMEOUT = 20
Session.HANDSHAKE_SOCKET_TIMEOUT = 5
-- Turning Wi-Fi on is asynchronous, and NetworkMgr can be left with a pending attempt of its
-- own (it then just reports EBUSY and never calls us back). Never leave the user staring at a
-- "connecting" that cannot finish.
Session.WIFI_WAIT_TIMEOUT = 30

-- Seconds without key input before the screen update request held during a key burst is sent.
-- E-ink redraws block the UI thread, so a redraw started mid-burst delays the next key press.
Session.INPUT_QUIET = 0.3

-- Margin around the visible area that zoomed-in requests also cover, as a fraction of the visible
-- width/height on each side: a short pan then lands on pixels that are already up to date.
Session.REQUEST_MARGIN = Remote.REQUEST_MARGIN

--- Monotonic seconds; a module field so tests can substitute a clock.
function Session._now()
    return time.to_s(time.now())
end

--[[--
Creates a session. Nothing is opened until @{Session:connect} is called.

--- @tparam table opts
--- @tparam table opts.profile connection profile (see @{vnc.settings})
--- @tparam[opt] table opts.plugin the plugin instance
--- @tparam[opt] function opts.on_state `(state, err)` on every transition
--- @tparam[opt] table opts.network_mgr override the network manager (tests)
--- @tparam[opt] function opts.on_update `(tm)` after every decoded FramebufferUpdate, with
---   `tm = { px, bytes, cpu, rects, t0 }`: the summed rect area (remote pixels), the bytes read,
---   the decode CPU seconds, the rect count and the `Session._now()` it started at
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
        rx = "",           -- received but not yet consumed bytes
        need = nil,        -- bytes the protocol is waiting for
        done = false,
        attached = false,
        app = nil,
        dirty = nil,       -- accumulated dirty rects, in remote coordinates (a list of disjoint rects)
        wifi_was_on = nil, -- nil until we know
        _connect_cb = nil,
        _network_mgr = opts.network_mgr,
        on_update = opts.on_update,
        -- true holds the incremental request that follows every update, like key input does
        hold_incremental = false,
        -- The remote area incremental requests ask for (see `set_view_area`); nil = the whole
        -- framebuffer. `forced` is a non-incremental request for newly visible pixels that is
        -- still owed (it waits while requests are held).
        view_area = nil,
        forced = nil,
    }, Session)
    -- The poll task, bound to this session: `UIManager:unschedule` matches the function, so the
    -- shared `Session._poll` would cancel every session's poll (e.g. a benchmark's own connection
    -- tearing down would stop the viewer's).
    self._poll_task = function() self:_poll() end
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

--- Hands the global scaling mode (the viewer menu's "Sharp scaling") to the remote, if there is one yet.
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

The handshake itself is driven synchronously (the socket gets a real timeout for that
phase), so when `callback` reports success the plane exists and the session is usable.
Turning Wi-Fi on is inherently asynchronous, so `callback(ok, err)` may be invoked later
than `connect()` returns.
--- @tparam[opt] function callback `(ok, err)`, called exactly once
]]
function Session:connect(callback)
    if self.state == "connecting" or self.state == "connected" then
        if callback then callback(false, "already connecting or connected") end
        return
    end
    self._connect_cb = callback
    self.err = nil
    self:_set_state("connecting")

    local wifi_on = self:_net():isWifiOn()
    self.wifi_was_on = wifi_on
    if not wifi_on then
        local status = self:_net():turnOnWifiAndWaitForConnection(function()
            self:_do_connect()
        end)
        if status == false then
            self.wifi_was_on = nil
            self:_fail("could not turn on Wi-Fi")
            return
        end
        self:_watch_wifi()
        return
    end
    self:_do_connect()
end

function Session:_finish_connect(ok, err)
    local cb = self._connect_cb
    self._connect_cb = nil
    if cb then
        local ok2, e = pcall(cb, ok, err)
        if not ok2 then logger.warn("vnc: connect callback failed:", e) end
    end
end

--- Fails the attempt if the asynchronous Wi-Fi path never calls us back.
function Session:_watch_wifi()
    self._attempt = (self._attempt or 0) + 1
    local attempt = self._attempt
    UIManager:scheduleIn(Session.WIFI_WAIT_TIMEOUT, function()
        if self._attempt == attempt and self.state == "connecting" then
            self:_fail(string.format("timed out after %ds waiting for Wi-Fi", Session.WIFI_WAIT_TIMEOUT))
        end
    end)
end

function Session:_do_connect()
    local p = self.profile
    logger.dbg("vnc: connecting to", p.host, p.port)
    local socket = require("socket")
    local sock = socket.tcp()
    if not sock then
        return self:_fail("could not create a TCP socket")
    end
    sock:settimeout(Session.HANDSHAKE_SOCKET_TIMEOUT)
    local ok, err = sock:connect(p.host, p.port)
    if not ok then
        self:_fail(string.format("could not connect to %s:%d (%s)", p.host, p.port, tostring(err)))
        return
    end
    sock:setoption("tcp-nodelay", true)
    self.sock = sock

    -- The picture settings come from the profile and are read once per connection: an edit applies
    -- on the next connection only, since a live SetPixelFormat would race updates already in flight
    -- in the old format.
    local self_ref = self
    self.proto = Protocol.new{
        io = {
            write = function(s) self_ref.tx[#self_ref.tx + 1] = s end,
            read = function(n) return coroutine.yield("need", n) end,
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
                    self_ref.remote = Remote.new(w, h)
                end
                self_ref:_apply_scaling()
                self_ref:_set_state("connected")
            end,
            on_update_start = function()
                if Util.timing_enabled() or self_ref.on_update then
                    self_ref.tm = { t0 = Session._now(), cpu = 0, bytes = 1, rects = 0, px = 0 }
                end
            end,
            on_update_done = function()
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
                    self_ref.remote = Remote.new(w, h)
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
                logger.dbg("vnc: server cut text:", text)
            end,
        },
    }
    self.done = false
    self.need = nil

    local deadline = os.time() + Session.HANDSHAKE_TIMEOUT
    while true do
        local status = self:_pump(true)
        if status == "error" then return end
        if status == "connected" then break end
        if os.time() >= deadline then
            self:_fail("timed out during the RFB handshake")
            return
        end
    end

    -- Connected: from now on the socket must never block the UI thread.
    sock:settimeout(0)
    self:_finish_connect(true)
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
function Session:_resume(data)
    local c0 = self.tm and os.clock()
    if self.tm and data then self.tm.bytes = self.tm.bytes + #data end
    local a, b = self.proto:step(data)
    local tm = self.tm
    if tm then
        -- A tick may end mid-update, so the CPU time of every tick that touched it is summed.
        tm.cpu = tm.cpu + (os.clock() - (c0 or os.clock()))
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
One round of work: flush outgoing bytes, feed the protocol, collect its requests.

--- @tparam[opt] boolean stop_connected return as soon as the handshake completed
--- @treturn string `"again"`, `"done"`, `"connected"` or `"error"`
]]
function Session:_pump(stop_connected)
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
        if self.need then
            if #self.rx >= self.need then
                local chunk = self.rx:sub(1, self.need)
                self.rx = self.rx:sub(self.need + 1)
                self.need = nil
                budget = budget - #chunk
                if not self:_resume(chunk) then return "error" end
                local ok2, err2 = self:_flush_tx()
                if not ok2 then
                    self:_fail(err2)
                    return "error"
                end
            else
                local chunk, rerr, partial = self.sock:receive(self.need - #self.rx)
                if chunk then
                    self.rx = self.rx .. chunk
                    budget = budget - #chunk
                else
                    if partial and #partial > 0 then
                        self.rx = self.rx .. partial
                        budget = budget - #partial
                    end
                    if rerr == "timeout" then
                        return "again"
                    elseif rerr == "closed" then
                        self:_fail("connection closed by server")
                        return "error"
                    else
                        self:_fail(string.format("socket receive failed (%s)", tostring(rerr)))
                        return "error"
                    end
                end
            end
        else
            if not self:_resume(nil) then return "error" end
            local ok2, err2 = self:_flush_tx()
            if not ok2 then
                self:_fail(err2)
                return "error"
            end
        end
        if budget <= 0 or os.clock() >= cpu_deadline then return "again" end
    end
    return "again"
end

-- ---------------------------------------------------------------- lifecycle

--- Registers the poll task and resynchronises the framebuffer.
function Session:attach(app)
    self.app = app
    if self.attached then return end
    self.attached = true
    self.last_poll = nil -- the time spent detached is not a blocked poll
    UIManager:scheduleIn(Session.POLL_INTERVAL, self._poll_task)
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
end

--- The poll task (scheduled as `_poll_task`, which `UIManager:unschedule` can cancel).
function Session:_poll()
    if not self.attached then return end
    if Util.timing_enabled() then
        local now = Session._now()
        if self.last_poll and now - self.last_poll > 2 * Session.POLL_INTERVAL then
            logger.dbg(string.format("vnc-timing: poll gap ms=%.1f", (now - self.last_poll) * 1000))
        end
        self.last_poll = now
    else
        self.last_poll = nil
    end
    local status = self:_pump()
    if status == "error" or status == "done" then
        UIManager:unschedule(self._poll_task)
        self.attached = false
        return
    end
    if self.forced and not self:_holding() then
        self:_send_forced()
        local ok, err = self:_flush_tx()
        if not ok then
            self:_fail(err)
            return
        end
    end
    if self.proto and self.proto.update_pending and not self:_holding() then
        self.proto:release_update()
        local ok, err = self:_flush_tx()
        if not ok then
            self:_fail(err)
            return
        end
    end
    if self.dirty and self.dirty[1] and self.app then
        local rects = self.dirty
        self.dirty = nil
        self.app:on_framebuffer_dirty(rects)
    end
    UIManager:scheduleIn(Session.POLL_INTERVAL, self._poll_task)
end

--- Closes the socket and frees the protocol, keeping the plane for display.
function Session:_teardown_connection()
    UIManager:unschedule(self._poll_task)
    self.attached = false
    if self.sock then
        self.sock:close()
        self.sock = nil
    end
    if self.proto then
        self.proto:free()
        self.proto = nil
    end
    self.tx, self.rx, self.need, self.done = {}, "", nil, false
    -- An update cut short by the teardown must not leave its timing state for the next connection.
    self.tm = nil
    -- Rectangles a dead connection never got to report: a reconnect requests the whole screen again,
    -- so they would only be redundant (and they may be in the old desktop's coordinates).
    self.dirty = nil
end

--- Restores Wi-Fi if we were the ones who turned it on.
function Session:_restore_wifi()
    if self.wifi_was_on == false then
        logger.dbg("vnc: turning Wi-Fi back off")
        self:_net():turnOffWifi()
    end
    self.wifi_was_on = nil
end

--- Fails the session, keeping the app (and the last picture) alive for a reconnect.
function Session:_fail(err)
    local msg = tostring(err)
    logger.warn("vnc: session failed:", msg)
    self:_teardown_connection()
    self:_restore_wifi()
    self:_set_state("error", msg)
    self:_finish_connect(false, msg)
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

--- Queues a non-incremental update request for the whole framebuffer.
--- Safe to call from protocol callbacks (it never flushes).
function Session:request_full_update()
    if not self.proto or not self.remote then return end
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
    if not self.proto then return end
    self.proto:send_pointer(x, y, mask)
    self:_flush_now()
end

--- @tparam number keysym X11 keysym
--- @tparam boolean down
function Session:send_key(keysym, down)
    if not self.proto then return end
    if down then self:note_input() end
    self.proto:send_key(keysym, down)
    self:_flush_now()
end

--- @tparam string text
function Session:send_cut_text(text)
    if not self.proto then return end
    self.proto:send_cut_text(text)
    self:_flush_now()
end

return Session
