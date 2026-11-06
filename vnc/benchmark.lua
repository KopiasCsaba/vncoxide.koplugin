--[[--
Picture-settings benchmark: measures picture-setting combinations against the live server.

Each combination gets its own fresh @{vnc.session} (a copy of the profile with the combination's
picture fields, `shared = true` like every session), so a live session of the same profile is never
disturbed and no setting is ever written. One combination runs at a time, in two phases:

1. **full**: `FULL_SAMPLES` non-incremental full-screen requests, each timed from the request to
   the end of its FramebufferUpdate (decode included, draw not). The incremental request that
   normally follows every update is held meanwhile (`Session.hold_incremental`), so the update
   timed is really the full-screen one. `full_ms` is their mean.
2. **live**: the "live" progress is reported first, and the window starts on the next tick, so
   the e-ink refresh of the progress dialog is not counted in it (updates in between are not
   counted either). Then `live_seconds` of normal incremental updates of whatever changes on the remote screen.
   Every update adds its rect area (remote pixels) and bytes; every poll tick that has changes draws
   them with @{Remote:draw_to} into one off-screen BlitBuffer of the viewer's canvas size and type
   (allocated once per run) with the viewer's view and scaling, like the viewer would. The score is
   the changed remote pixels per second of wall time, and that time includes network, decode and
   draw.

No viewer is attached: the benchmark attaches a minimal sink of its own (the app interface the
session calls), which draws into the off-screen buffer. Attaching registers the session's normal
poll task, so updates keep being requested and decoded exactly as in the viewer. The draw uses the
viewer's dither flag (`canvas.dither`).

For the whole run, every attached session in `opts.sessions` (the plugin's live connections, the
open viewer's included) is detached, so its polling, decoding and drawing does not compete with the
measurement; the ones detached are attached again, to the same app, when the run finishes, is
cancelled or ends in an error (`attach` requests a full update, which resynchronises them).

A combination that fails before its handshake completes (connection refused, timeout, auth or
security failure, Wi-Fi not coming up) ends the whole run at once: the other combinations would
fail the same way. `on_done` then gets that combination's failed row and the error as its second
argument. A failure after connecting (a rejected format, an error mid-phase) only fails that
combination, and the run goes on.

Everything is driven from `UIManager` tasks (the session's own poll plus a benchmark tick) and the
clock is `Session._now`, so tests can run it on a fake clock. The handshake itself is the session's
synchronous one.

`cancel()` tears the current session down and frees the buffer; `on_done` is then never called. It
may be called from anywhere, `on_progress` included: the run checks after every progress report.

An unexpected Lua error inside the run (a tick, `start()`, the connect callback) ends the current
combination as `ok = false` with the error message as `error`, tears it down, and the run goes on.

@module vnc.benchmark
]]

local BB = require("ffi/blitbuffer")
local Session = require("vnc/session")
local logger = require("logger")

local UIManager = require("ui/uimanager")

local Benchmark = {}
Benchmark.__index = Benchmark

-- Seconds of live updates per combination.
Benchmark.LIVE_SECONDS = 5
-- Live scores below this fraction of the remote screen's area per second (0.01 = 1 % of the screen
-- changing every second) mean the screen was still: the row is not scored.
Benchmark.STILL_MIN_PX_PER_S = 0.01
-- Full-screen samples per combination.
Benchmark.FULL_SAMPLES = 2
-- Seconds to wait for one full-screen update before the combination counts as failed.
Benchmark.FULL_TIMEOUT = 15
-- Seconds between benchmark ticks (phase deadlines, failures, the next combination).
Benchmark.TICK = 0.05

local function combination(depth, tight, compr, jpeg)
    local label = depth .. "-bit, " .. (tight and "Tight" or "Tight off")
    if compr then label = label .. ", compr. " .. compr end
    if jpeg then label = label .. ", JPEG " .. jpeg end
    return {
        color_depth = depth,
        enable_tight = tight,
        jpeg_quality = jpeg or false,
        compress_level = compr or false,
        label = label,
    }
end

--- The combinations tried by default, in order.
Benchmark.COMBINATIONS = {}
for _, depth in ipairs{ 24, 16, 8 } do
    table.insert(Benchmark.COMBINATIONS, combination(depth, false))
    table.insert(Benchmark.COMBINATIONS, combination(depth, true, 1))
    table.insert(Benchmark.COMBINATIONS, combination(depth, true, 2))
end
table.insert(Benchmark.COMBINATIONS, combination(24, true, 2, 8))
table.insert(Benchmark.COMBINATIONS, combination(24, true, 2, 4))

--[[--
Orders results: scored rows by `px_per_s` (highest first), then still rows, then failed rows; the
original order otherwise.
--- @tparam table results
--- @treturn table a new, sorted list
]]
function Benchmark._sort(results)
    local function group(r)
        if not r.ok then return 3 end
        return r.still and 2 or 1
    end
    local list = {}
    for i, r in ipairs(results) do list[i] = { r = r, i = i, g = group(r) } end
    table.sort(list, function(a, b)
        if a.g ~= b.g then return a.g < b.g end
        if a.g == 1 and a.r.px_per_s ~= b.r.px_per_s then return a.r.px_per_s > b.r.px_per_s end
        return a.i < b.i
    end)
    local out = {}
    for i, e in ipairs(list) do out[i] = e.r end
    return out
end

--[[--
Creates a benchmark; nothing happens until @{Benchmark:start}.

--- @tparam table opts
--- @tparam table opts.profile connection profile (copied per combination, never modified)
--- @tparam[opt] table opts.combinations defaults to `COMBINATIONS`
--- @tparam[opt] number opts.live_seconds defaults to `LIVE_SECONDS`
--- @tparam table opts.canvas `{ w, h, bb_type, view_mode = "fit"|scale, scaling = "smooth"|"sharp",
---   dither }`, `dither` as the viewer passes it to @{Remote:draw_to}
--- @tparam[opt] function opts.on_progress `(i, n, label, phase)`, phase `"connect"|"full"|"live"`
--- @tparam[opt] table opts.sessions sessions (any keys) to detach while the run lasts
--- @tparam[opt] function opts.on_done `(results, connect_error)`, sorted (see @{Benchmark._sort}); each row is
---   `{ combination, ok, error, px_per_s, ms_per_update, bytes_per_s, full_ms, still,
---   decode_ms, draw_ms }`. `ms_per_update` is live wall time per update; `decode_ms` and `draw_ms`
---   are the live phase's total decode and draw CPU time. `connect_error` is set when the run
---   stopped because a combination could not connect.
--- @tparam[opt] table opts.network_mgr passed to every session (tests)
]]
function Benchmark.new(opts)
    assert(type(opts) == "table" and type(opts.profile) == "table", "Benchmark.new: opts.profile is required")
    local canvas = opts.canvas
    assert(type(canvas) == "table" and canvas.w > 0 and canvas.h > 0, "Benchmark.new: opts.canvas is required")
    local self = setmetatable({
        profile = opts.profile,
        combinations = opts.combinations or Benchmark.COMBINATIONS,
        live_seconds = opts.live_seconds or Benchmark.LIVE_SECONDS,
        canvas = canvas,
        on_progress = opts.on_progress,
        on_done = opts.on_done,
        network_mgr = opts.network_mgr,
        sessions = opts.sessions,
        detached = {},   -- session -> its app, for the sessions this run detached
        results = {},
        index = 0,
        session = nil,
        run = nil,       -- the current combination's measurements
        bb = nil,
        stopped = false,
        _wifi_net = nil, -- set when a session turned Wi-Fi on: turned off once, at the end
    }, Benchmark)
    self._tick_fn = function() self:_tick() end
    return self
end

--- Starts the run.
function Benchmark:start()
    local c = self.canvas
    self.bb = BB.new(c.w, c.h, c.bb_type or BB.TYPE_BB8)
    self:_detach_sessions()
    self:_guarded(self._next)
    if not self.stopped then UIManager:scheduleIn(Benchmark.TICK, self._tick_fn) end
end

--- Stops the run: the current session is disconnected and `on_done` is not called.
function Benchmark:cancel()
    if self.stopped then return end
    self:_stop()
end

--[[--
Calls `fn(self)`; an error ends the current combination as failed (recorded once, with the
message), tears its session down and moves on to the next one. Errors while doing that are
handled the same way, so the loop always ends: every turn advances the combination index.
]]
function Benchmark:_guarded(fn)
    local ok, err = pcall(fn, self)
    while not ok and not self.stopped do
        logger.warn("vnc: benchmark error:", err)
        local combo = self.combinations[self.index]
        if not combo then
            -- the error came from finishing: stop, but still hand over what was collected
            pcall(self._stop, self)
            pcall(self._reattach_sessions, self)
            self.stopped = true
            self:_report()
            return
        end
        local last = self.results[#self.results]
        if not (last and last.combination == combo) then
            logger.info("vnc: benchmark:", combo.label, "failed:", err)
            table.insert(self.results, { combination = combo, ok = false, error = tostring(err) })
        end
        ok, err = pcall(function()
            self:_close_session()
            self:_next()
        end)
    end
end

--- Detaches every attached session of `opts.sessions`, remembering its app.
function Benchmark:_detach_sessions()
    for _, s in pairs(self.sessions or {}) do
        if s:is_attached() then
            self.detached[s] = s.app
            s:detach()
        end
    end
end

--- Attaches the sessions detached by @{Benchmark:_detach_sessions} again; each one on its own.
function Benchmark:_reattach_sessions()
    local list = self.detached
    self.detached = {}
    for s, app in pairs(list) do
        local ok, e = pcall(s.attach, s, app)
        if not ok then logger.warn("vnc: benchmark could not re-attach a session:", e) end
    end
end

function Benchmark:_progress(phase)
    if self.on_progress then
        local c = self.combinations[self.index]
        local ok, e = pcall(self.on_progress, self.index, #self.combinations, c.label, phase)
        if not ok then logger.warn("vnc: benchmark on_progress failed:", e) end
    end
end

--- Starts the next combination, or finishes.
function Benchmark:_next()
    self.index = self.index + 1
    local combo = self.combinations[self.index]
    if not combo then return self:_finish() end

    local profile = {}
    for k, v in pairs(self.profile) do profile[k] = v end
    profile.color_depth, profile.enable_tight = combo.color_depth, combo.enable_tight
    profile.jpeg_quality, profile.compress_level = combo.jpeg_quality, combo.compress_level

    local run = { combination = combo, phase = "connect", samples = {},
                  px = 0, bytes = 0, updates = 0, decode = 0, draw = 0 }
    self.run = run
    local session
    session = Session.new{
        profile = profile,
        network_mgr = self.network_mgr,
        on_state = function(state, err)
            if state == "error" and self.run == run then run.err = run.err or err or "failed" end
        end,
        on_update = function(tm) if self.run == run then self:_on_update(run, tm) end end,
    }
    self.session = session
    self:_progress("connect")
    if self.stopped then return end
    -- The session swallows errors from this callback (and may call it later, after turning Wi-Fi
    -- on), so an error here is recorded on the run, and the next tick ends the combination.
    session:connect(function(ok, err)
        if self.run ~= run then return end
        if not ok then
            run.err = run.err or err or "could not connect"
            -- before the handshake completed: the next tick ends the whole run
            run.connect_failed = true
            return
        end
        local ok2, e = pcall(self._on_connected, self, run, session)
        if not ok2 then
            logger.warn("vnc: benchmark connect callback failed:", e)
            if self.run == run then run.err = run.err or tostring(e) end
        end
    end)
end

--- The current combination's session is connected: full-screen phase.
function Benchmark:_on_connected(run, session)
    self:_apply_view()
    run.phase = "full"
    self:_progress("full")
    if self.stopped or self.run ~= run then return end
    session.hold_incremental = true
    run.t_req = Session._now()
    session:attach({
        on_framebuffer_dirty = function() self:_draw(run) end,
        on_remote_resized = function() self:_apply_view() end,
        on_bell = function() end,
    })
end

--- Hands the viewer's scaling and view to the current session's remote.
function Benchmark:_apply_view()
    local remote = self.session and self.session:get_remote()
    if not remote then return end
    local c = self.canvas
    remote:set_scaling(c.scaling == "sharp" and "sharp" or "smooth")
    if type(c.view_mode) == "number" then
        remote:set_canvas(c.w, c.h)
        remote:set_scale(c.view_mode)
    else
        remote:fit_view(c.w, c.h)
    end
end

function Benchmark:_on_update(run, tm)
    if run.phase == "full" then
        -- an empty update is not the full screen asked for
        if tm.px <= 0 then return end
        table.insert(run.samples, Session._now() - run.t_req)
        if #run.samples < Benchmark.FULL_SAMPLES then
            run.t_req = Session._now()
            self.session:request_full_update()
        else
            -- nothing is counted until the next tick has reported "live" and a later one opens
            -- the live window (t_live)
            run.phase = "settle"
            -- the session's next poll releases the held incremental request
            self.session.hold_incremental = false
            -- reported by the next tick: on_progress may cancel, and the session must not be
            -- disconnected from inside its own update callback
            run.live_unreported = true
        end
    elseif run.phase == "live" then
        run.px = run.px + tm.px
        run.bytes = run.bytes + tm.bytes
        run.decode = run.decode + tm.cpu
        run.updates = run.updates + 1
    end
end

function Benchmark:_draw(run)
    local remote = self.session and self.session:get_remote()
    if not remote then return end
    local c = self.canvas
    local c0 = os.clock()
    remote:draw_to(self.bb, 0, 0, c.w, c.h, c.dither or false)
    if run.phase == "live" then run.draw = run.draw + (os.clock() - c0) end
end

--- Advances the run (guarded, see @{Benchmark:_guarded}) and schedules the next tick.
function Benchmark:_tick()
    if self.stopped then return end
    self:_guarded(self._advance)
    if not self.stopped then UIManager:scheduleIn(Benchmark.TICK, self._tick_fn) end
end

--- Failures, phase deadlines, the next combination.
function Benchmark:_advance()
    local run = self.run
    local now = Session._now()
    if run.live_unreported then
        run.live_unreported = nil
        self:_progress("live")
        -- the window opens on a later tick, after the progress title's screen refresh
        return
    end
    if run.phase == "settle" then
        run.phase = "live"
        run.t_live = now
        return
    end
    if run.connect_failed then
        local result = { combination = run.combination, ok = false, error = run.err }
        logger.info("vnc: benchmark:", result.combination.label, "could not connect, stopping:", result.error)
        table.insert(self.results, result)
        self:_stop()
        self:_report(result.error)
    elseif run.err then
        self:_end_combination({ combination = run.combination, ok = false, error = run.err })
    elseif run.phase == "full" and now - run.t_req > Benchmark.FULL_TIMEOUT then
        self:_end_combination({ combination = run.combination, ok = false,
            error = string.format("no full-screen update within %d s", Benchmark.FULL_TIMEOUT) })
    elseif run.phase == "live" and now - run.t_live >= self.live_seconds then
        self:_end_combination(self:_score(run, now - run.t_live))
    end
end

function Benchmark:_score(run, elapsed)
    local w, h = self.session:get_remote():get_size()
    local full = 0
    for _, s in ipairs(run.samples) do full = full + s end
    local px_per_s = run.px / elapsed
    return {
        combination = run.combination,
        ok = true,
        px_per_s = px_per_s,
        ms_per_update = run.updates > 0 and elapsed * 1000 / run.updates or nil,
        bytes_per_s = run.bytes / elapsed,
        full_ms = full * 1000 / #run.samples,
        still = px_per_s < Benchmark.STILL_MIN_PX_PER_S * w * h,
        decode_ms = run.decode * 1000,
        draw_ms = run.draw * 1000,
    }
end

function Benchmark:_end_combination(result)
    if not result.ok then
        logger.info("vnc: benchmark:", result.combination.label, "failed:", result.error)
    end
    table.insert(self.results, result)
    self:_close_session()
    self:_next()
end

--- Disconnects the current session (freeing its remote), keeping Wi-Fi up until the end.
function Benchmark:_close_session()
    local s = self.session
    self.session, self.run = nil, nil
    if not s then return end
    if s.wifi_was_on == false then
        self._wifi_net = s:_net()
        s.wifi_was_on = nil
    end
    s:disconnect()
end

function Benchmark:_stop()
    self.stopped = true
    UIManager:unschedule(self._tick_fn)
    self:_reattach_sessions()
    self:_close_session()
    if self.bb then
        self.bb:free()
        self.bb = nil
    end
    if self._wifi_net then
        self._wifi_net:turnOffWifi()
        self._wifi_net = nil
    end
end

function Benchmark:_finish()
    self:_stop()
    self:_report()
end

--- Calls `on_done` with the sorted results (and the connect error, if any), at most once.
function Benchmark:_report(connect_error)
    if self._reported or not self.on_done then return end
    self._reported = true
    local ok, e = pcall(self.on_done, Benchmark._sort(self.results), connect_error)
    if not ok then logger.warn("vnc: benchmark on_done failed:", e) end
end

return Benchmark
