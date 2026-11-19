--[[--
Picture-settings benchmark: times how fast key presses on a test page show up, per picture-setting
combination.

The user opens the test page (tools/bench-page.html) full screen on the PC and gives it the
keyboard focus. The incremental requests cover the whole screen, so any other change on it (a
clock, a blinking caret) counts as the page responding: the page must fill the screen. Each Page
Down (`KEY_NEXT`) moves the page one step through `SCRIPT`, a fixed order of 15 steps, 3 of each
category in `CATEGORIES`: `photo` (a new photo in a large area), `text` (new text everywhere),
`scroll` (the page moves up), `small` (a small area changes) and `flip` (the colours invert,
everything changes). Home (`KEY_RESET`) goes back to step 0.

Each combination gets its own fresh @{vncoxide.session} (a copy of the profile with the combination's
picture fields, `shared = true` like every session), so a live session of the same profile is never
disturbed and no setting is ever written. The whole list runs `PASSES` (2) times: pass 1 in list
order, pass 2 in reverse order, so warm-up and order effects even out; every run of a combination
reconnects. One run at a time:

1. **connect**, then the session is attached to a minimal sink of its own (no viewer) with normal
   incremental updates, exactly as in the viewer; the session's own input priority (it holds the
   update request for `Session.INPUT_QUIET` after a key) stays, as it is part of what the user
   feels.
2. **reset**: Home (down and up), then `RESET_SETTLE` seconds of quiet after the last update (or
   after the key when none arrives: the page may already be at step 0).
3. **steps**: for each step of `SCRIPT`, its progress is reported on one tick and the key goes out
   on a later one (so the e-ink refresh of the progress dialog is not timed). `t0` is the moment
   the key-down is sent (@{vncoxide.session:send_key} flushes it). Every update drawn after it
   records `t_last`; the step is complete once no update request is held and `QUIET` seconds have
   passed since `t_last` (and since the held request was released) with no further update:
   `elapsed = t_last - t0`. A change the server sends in several FramebufferUpdates is therefore
   one step, timed to its last piece. While a step is in flight the session polls every
   `POLL_INTERVAL` (5 ms) instead of its usual 50 ms, so updates are read when they arrive.

No update within `STEP_TIMEOUT` of `t0`: on the first step of a run the page is not reacting (not
focused, wrong window, the test page not open), so the whole run stops (`on_done` gets the stop
`{ reason = "no_response", error }`); on a later step that run fails ("no update within 5 s after
step k"). A step (or the reset) still receiving updates `STEP_TIMEOUT` after its key fails the run
too ("screen did not settle ...").

Every received rect is marked dirty by the session and drawn with @{Remote:draw_to} into one
off-screen BlitBuffer of the viewer's canvas size and type (allocated once per benchmark), with the
viewer's view, scaling and dither flag (`canvas.dither`), like the viewer would; so decode and draw
are paid on every update. A DesktopSize fails the run ("screen size changed").

Scores (@{Benchmark._score}) over the samples of both passes: per category the median step time in
ms (`cat_ms`), so a single slow step (Wi-Fi jitter) does not decide; `round_s`, the sum of the 5
category medians in seconds (one round of 5 steps); `bytes`, the mean bytes received per round of
5 steps.
@{Benchmark._rank} turns them into `speed_pct` (100 = the fastest) and a rank, with ties.

For the whole run, every attached session in `opts.sessions` (the plugin's live connections, the
open viewer's included) is detached, so its polling, decoding and drawing does not compete with the
measurement; the ones detached are attached again, to the same app, when the run finishes, is
cancelled or ends in an error (`attach` requests a full update, which resynchronises them). The
benchmark's own sessions run without decode workers, in-process.

A combination that fails before its handshake completes (connection refused, timeout, auth or
security failure, Wi-Fi not coming up) ends the whole run at once: the other combinations would
fail the same way. `on_done` then gets the rows so far (that combination's failed) and the stop
`{ reason = "connect", error }`. A failure after connecting (a rejected format, an error mid-run)
only fails that run, and the run goes on. A combination whose run failed in either pass is a
failed row, with the first failure as its error: "failed in pass N: <reason>".

Everything is driven from `UIManager` tasks (the session's own poll plus a benchmark tick) and the
clock is `Session._now`, so tests can run it on a fake clock. The handshake itself is the session's
synchronous one.

`cancel()` tears the current session down and frees the buffer; `on_done` is then never called. It
may be called from anywhere, `on_progress` included: the run checks after every progress report.

An unexpected Lua error inside the run (a tick, `start()`, the connect callback, the draw) fails the
current run with the error message, tears it down, and the run goes on.

@module vncoxide.benchmark
]]

local BB = require("ffi/blitbuffer")
local Session = require("vncoxide/session")
local logger = require("logger")

local UIManager = require("ui/uimanager")

local Benchmark = {}
Benchmark.__index = Benchmark

--- The test page's steps, in order (tools/bench-page.html): one category id per Page Down.
Benchmark.SCRIPT = { "photo", "text", "scroll", "small", "flip", "text", "small", "photo",
                     "flip", "scroll", "small", "flip", "scroll", "photo", "text" }
--- The step categories, in the order the results show them.
Benchmark.CATEGORIES = { "photo", "text", "scroll", "small", "flip" }
-- Times the whole list runs: pass 1 in list order, pass 2 in reverse order (and so on, alternating).
Benchmark.PASSES = 2
-- Seconds to wait for the first update after a step's key before the step counts as failed.
Benchmark.STEP_TIMEOUT = 5
-- Seconds without a further update after which a step is complete.
Benchmark.QUIET = 0.15
-- Seconds of quiet after the reset (Home) before the first step.
Benchmark.RESET_SETTLE = 0.5
-- A row is tied with its group's leader when its speed is at least this share of the leader's.
Benchmark.TIE = 0.95
-- Keysyms: Page Down (XK_Next) moves the test page one step on, Home resets it to step 0.
Benchmark.KEY_NEXT = 0xff56
Benchmark.KEY_RESET = 0xff50
-- Seconds between the session's poll ticks while a step is in flight (instead of
-- `Session.POLL_INTERVAL`), so its updates are read, and timed, as soon as they arrive.
Benchmark.POLL_INTERVAL = 0.005
-- Seconds between benchmark ticks (step completion, deadlines, failures, the next combination).
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

-- Picture class for ordering tied rows: 1 lossless (no JPEG, 16 bits or more), 2 JPEG, 3 8-bit.
local function picture_class(combo)
    if not combo then return 1 end
    if (tonumber(combo.color_depth) or 24) < 16 then return 3 end
    if combo.jpeg_quality then return 2 end
    return 1
end

-- Step times below this (ms) count as this, so a ratio never divides by zero.
local MIN_MS = 0.001

--[[--
Sets `speed_pct` and `rank` on every row and returns them sorted.

`speed_pct`: per category the fastest scored row's `cat_ms` over the row's own, the geometric mean
of those over the categories, × 100 (100 = the fastest). Rows are grouped from the fastest down: a
row is tied with its group's leader when its `speed_pct` is at least `TIE` × the leader's; tied rows
share the leader's rank (competition ranking: 1, 1, 3, ...). Within a group lossless rows come
before JPEG ones, then 8-bit ones; then fewer `bytes` first; then the faster. Failed rows (`ok`
false) come last, in their original order, with `rank` and `speed_pct` nil.
--- @tparam table rows
--- @treturn table a new, sorted list
]]
function Benchmark._rank(rows)
    local cats = Benchmark.CATEGORIES
    local best = {}
    for _, r in ipairs(rows) do
        if r.ok then
            for _, c in ipairs(cats) do
                local v = math.max(r.cat_ms[c] or 0, MIN_MS)
                if not best[c] or v < best[c] then best[c] = v end
            end
        end
    end
    local scored, failed = {}, {}
    for i, r in ipairs(rows) do
        if r.ok then
            local sum = 0
            for _, c in ipairs(cats) do
                sum = sum + math.log(best[c] / math.max(r.cat_ms[c] or 0, MIN_MS))
            end
            r.speed_pct = math.exp(sum / #cats) * 100
            scored[#scored + 1] = { r = r, i = i }
        else
            r.speed_pct, r.rank = nil, nil
            failed[#failed + 1] = r
        end
    end
    table.sort(scored, function(a, b)
        if a.r.speed_pct ~= b.r.speed_pct then return a.r.speed_pct > b.r.speed_pct end
        return a.i < b.i
    end)
    local out = {}
    local k = 1
    while k <= #scored do
        local leader = scored[k].r
        local group = {}
        while k <= #scored and scored[k].r.speed_pct >= leader.speed_pct * Benchmark.TIE do
            group[#group + 1] = scored[k]
            k = k + 1
        end
        table.sort(group, function(a, b)
            local ca, cb = picture_class(a.r.combination), picture_class(b.r.combination)
            if ca ~= cb then return ca < cb end
            local ba, bb = a.r.bytes or 0, b.r.bytes or 0
            if ba ~= bb then return ba < bb end
            if a.r.speed_pct ~= b.r.speed_pct then return a.r.speed_pct > b.r.speed_pct end
            return a.i < b.i
        end)
        local rank = #out + 1
        for _, e in ipairs(group) do
            e.r.rank = rank
            out[#out + 1] = e.r
        end
    end
    for _, r in ipairs(failed) do out[#out + 1] = r end
    return out
end

--[[--
Creates a benchmark; nothing happens until @{Benchmark:start}.

--- @tparam table opts
--- @tparam table opts.profile connection profile (copied per combination, never modified)
--- @tparam[opt] table opts.combinations defaults to `COMBINATIONS`
--- @tparam table opts.canvas `{ w, h, bb_type, view_mode = "fit"|scale, scaling = "smooth"|"sharp",
---   dither }`, `dither` as the viewer passes it to @{Remote:draw_to}
--- @tparam[opt] function opts.on_progress `(i, n, label, phase, pass, passes, step, steps)`: run `i`
---   of `n` (every combination once per pass), phase `"connect"|"reset"|"steps"`, pass `pass` of
---   `passes`; for `"steps"`, step `step` of `steps` (reported once per step, before its key)
--- @tparam[opt] table opts.sessions sessions (any keys) to detach while the run lasts
--- @tparam[opt] function opts.on_done `(results, stop)`, ranked (see @{Benchmark._rank}); each row is
---   `{ combination, ok, error, cat_ms, round_s, speed_pct, rank, bytes }` (see @{Benchmark._score}),
---   one per combination that ran. `stop` is nil, or `{ reason = "connect"|"no_response", error }`
---   when the run stopped early: a combination could not connect, or the first step of a run got
---   no update within `STEP_TIMEOUT`.
--- @tparam[opt] table opts.network_mgr passed to every session (tests)
]]
function Benchmark.new(opts)
    assert(type(opts) == "table" and type(opts.profile) == "table", "Benchmark.new: opts.profile is required")
    local canvas = opts.canvas
    assert(type(canvas) == "table" and canvas.w > 0 and canvas.h > 0, "Benchmark.new: opts.canvas is required")
    local self = setmetatable({
        profile = opts.profile,
        combinations = opts.combinations or Benchmark.COMBINATIONS,
        canvas = canvas,
        on_progress = opts.on_progress,
        on_done = opts.on_done,
        network_mgr = opts.network_mgr,
        sessions = opts.sessions,
        detached = {},   -- session -> its app, for the sessions this run detached
        order = nil,     -- the runs: `{ ci, pass }`, combination index and pass
        aggs = {},       -- per combination index: `{ samples = {}, error }` over its runs
        index = 0,       -- the current run in `order`
        session = nil,
        run = nil,       -- the current run's state
        bb = nil,
        stopped = false,
        _wifi_net = nil, -- set when a session turned Wi-Fi on: turned off once, at the end
    }, Benchmark)
    local order, n = {}, #self.combinations
    for pass = 1, Benchmark.PASSES do
        for k = 1, n do
            order[#order + 1] = { ci = pass % 2 == 1 and k or n + 1 - k, pass = pass }
        end
    end
    self.order = order
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
Calls `fn(self)`; an error ends the current run as failed (recorded once, with the message),
tears its session down and moves on to the next one. Errors while doing that are handled the
same way, so the loop always ends: every turn advances the run index.
]]
function Benchmark:_guarded(fn)
    local ok, err = pcall(fn, self)
    while not ok and not self.stopped do
        logger.warn("vncoxide: benchmark error:", err)
        local entry = self.order[self.index]
        if not entry then
            -- the error came from finishing: stop, but still hand over what was collected
            pcall(self._stop, self)
            pcall(self._reattach_sessions, self)
            self.stopped = true
            self:_report()
            return
        end
        self:_fail(entry, err)
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
        if not ok then logger.warn("vncoxide: benchmark could not re-attach a session:", e) end
    end
end

function Benchmark:_progress(phase, step)
    if self.on_progress then
        local entry = self.order[self.index]
        local ok, e = pcall(self.on_progress, self.index, #self.order, self.combinations[entry.ci].label, phase,
            entry.pass, Benchmark.PASSES, step, step and #Benchmark.SCRIPT or nil)
        if not ok then logger.warn("vncoxide: benchmark on_progress failed:", e) end
    end
end

--- The measurements of the combination run by `entry` (created on first use).
function Benchmark:_agg(entry)
    local agg = self.aggs[entry.ci]
    if not agg then
        agg = { samples = {} }
        self.aggs[entry.ci] = agg
    end
    return agg
end

--- Records that the run `entry` failed; a combination keeps its first failure.
function Benchmark:_fail(entry, err)
    local agg = self:_agg(entry)
    if entry.failed then return end
    entry.failed = true
    err = tostring(err)
    logger.info("vncoxide: benchmark:", self.combinations[entry.ci].label, "failed in pass", entry.pass .. ":", err)
    agg.error = agg.error or string.format("failed in pass %d: %s", entry.pass, err)
end

--- Starts the next run, or finishes.
function Benchmark:_next()
    self.index = self.index + 1
    local entry = self.order[self.index]
    if not entry then return self:_finish() end
    local combo = self.combinations[entry.ci]
    self:_agg(entry)

    local profile = {}
    for k, v in pairs(self.profile) do profile[k] = v end
    profile.color_depth, profile.enable_tight = combo.color_depth, combo.enable_tight
    profile.jpeg_quality, profile.compress_level = combo.jpeg_quality, combo.compress_level

    -- `samples`: one `{ cat, elapsed, bytes }` per completed step; `step`: the current step's
    -- index in `SCRIPT`; `wait`: the reset or step being timed (see @{Benchmark:_wait})
    local run = { entry = entry, combination = combo, phase = "connect", samples = {}, step = 0 }
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
            logger.warn("vncoxide: benchmark connect callback failed:", e)
            if self.run == run then run.err = run.err or tostring(e) end
        end
    end)
end

--- The current combination's session is connected: attach it and reset the test page.
function Benchmark:_on_connected(run, session)
    self:_apply_view()
    run.phase = "reset"
    self:_progress("reset")
    if self.stopped or self.run ~= run then return end
    -- normal incremental updates, as in the viewer; attach sends a whole-screen request
    session:attach({
        on_framebuffer_dirty = function() self:_on_dirty(run) end,
        on_remote_resized = function()
            if self.run == run then run.err = run.err or "screen size changed" end
        end,
        on_bell = function() end,
    })
    self:_press(run, Benchmark.KEY_RESET)
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

--[[--
Sends `keysym` (down, then up) and starts timing from the key-down: `run.wait` =
`{ t0, t_last, bytes, unheld }`. The session flushes each key at once and polls fast meanwhile.
]]
function Benchmark:_press(run, keysym)
    local s = self.session
    run.wait = { t0 = Session._now(), bytes = 0 }
    s.poll_interval = Benchmark.POLL_INTERVAL
    s:send_key(keysym, true)
    s:send_key(keysym, false)
    s:poll_soon()
end

function Benchmark:_on_update(run, tm)
    local w = run.wait
    -- an empty update changes nothing on screen
    if not w or tm.px <= 0 then return end
    w.bytes = w.bytes + tm.bytes
    -- timed once drawn (the session hands the rects over later in the same poll tick)
    w.received = true
end

--- The session's sink: draws, and records when an update of the current wait was drawn.
function Benchmark:_on_dirty(run)
    if self.run ~= run then return end
    -- an error here would escape into the session's poll task: the tick fails the combination
    local ok, e = pcall(self._draw, self, run)
    if not ok then
        logger.warn("vncoxide: benchmark draw failed:", e)
        run.err = run.err or tostring(e)
    end
end

function Benchmark:_draw(run)
    local remote = self.session and self.session:get_remote()
    if not remote then return end
    local c = self.canvas
    remote:draw_to(self.bb, 0, 0, c.w, c.h, c.dither or false)
    local w = run.wait
    if w and w.received then
        w.received = nil
        w.t_last = Session._now()
    end
end

--[[--
Whether the current wait is over: no update request is held by the session (its input priority
holds the request after a key; while held the server cannot send more), no update is being
received, and `quiet` seconds have passed since the last drawn update, since the request was
released, and since the key.
]]
function Benchmark:_settled(run, quiet, now)
    local w = run.wait
    local s = self.session
    local proto = s and s.proto
    if proto and proto.update_pending then
        w.unheld = nil
        return false
    end
    -- (a large update still arriving: its end is the step's last piece)
    if s and s.in_update then return false end
    w.unheld = w.unheld or now
    return now - math.max(w.t0, w.t_last or w.t0, w.unheld) >= quiet
end

--- Advances the run (guarded, see @{Benchmark:_guarded}) and schedules the next tick.
function Benchmark:_tick()
    if self.stopped then return end
    self:_guarded(self._advance)
    if not self.stopped then UIManager:scheduleIn(Benchmark.TICK, self._tick_fn) end
end

--- Reports step `k`'s progress; its key goes out on a later tick, after the dialog's refresh.
function Benchmark:_announce_step(run, k)
    run.step = k
    run.wait = nil
    run.key_due = true
    self.session.poll_interval = nil
    self:_progress("steps", k)
end

--- Stops the whole run early: `reason` and `err` go to `on_done` as the stop.
function Benchmark:_stop_early(run, reason, err)
    logger.info("vncoxide: benchmark:", run.combination.label, "stopping (" .. reason .. "):", err)
    self:_fail(run.entry, err)
    self:_stop()
    self:_report({ reason = reason, error = err })
end

--- Failures, the reset, step keys and their completion, the next run.
function Benchmark:_advance()
    local run = self.run
    local now = Session._now()
    if run.connect_failed then
        self:_stop_early(run, "connect", tostring(run.err))
    elseif run.err then
        self:_end_run(run.err)
    elseif run.phase == "reset" and run.wait then
        if self:_settled(run, Benchmark.RESET_SETTLE, now) then
            run.phase = "steps"
            self:_announce_step(run, 1)
        elseif now - run.wait.t0 > Benchmark.STEP_TIMEOUT then
            self:_end_run(string.format("screen did not settle within %g s after the reset", Benchmark.STEP_TIMEOUT))
        end
    elseif run.phase == "steps" then
        local k, w = run.step, run.wait
        if run.key_due then
            run.key_due = nil
            self:_press(run, Benchmark.KEY_NEXT)
        elseif not w.t_last then
            if now - w.t0 > Benchmark.STEP_TIMEOUT then
                local err = string.format("no update within %g s after step %d", Benchmark.STEP_TIMEOUT, k)
                if k == 1 then
                    self:_stop_early(run, "no_response", err)
                else
                    self:_end_run(err)
                end
            end
        elseif self:_settled(run, Benchmark.QUIET, now) then
            run.samples[#run.samples + 1] = { cat = Benchmark.SCRIPT[k], elapsed = w.t_last - w.t0, bytes = w.bytes }
            if k < #Benchmark.SCRIPT then
                self:_announce_step(run, k + 1)
            else
                self:_collect(run)
                self:_end_run()
            end
        elseif now - w.t0 > Benchmark.STEP_TIMEOUT then
            self:_end_run(string.format("screen did not settle within %g s after step %d", Benchmark.STEP_TIMEOUT, k))
        end
    end
end

--- The median of a list of numbers (the mean of the middle two for an even count); 0 when empty.
local function median(values)
    local n = #values
    if n == 0 then return 0 end
    table.sort(values)
    if n % 2 == 1 then return values[(n + 1) / 2] end
    return (values[n / 2] + values[n / 2 + 1]) / 2
end

--[[--
A combination's scored row from its step samples over every pass (each `{ cat, elapsed, bytes }`,
`elapsed` in seconds).

`cat_ms` holds, per category of `CATEGORIES`, the median step time in ms; `round_s` is the sum of
the category medians in seconds (one round of 5 steps); `bytes` is the mean bytes received per
round of 5 steps.
--- @treturn table `{ combination, ok = true, cat_ms, round_s, bytes }`
]]
function Benchmark._score(combination, samples)
    local per = {}
    local total_bytes = 0
    for _, smp in ipairs(samples) do
        local list = per[smp.cat]
        if not list then
            list = {}
            per[smp.cat] = list
        end
        list[#list + 1] = smp.elapsed
        total_bytes = total_bytes + (smp.bytes or 0)
    end
    local cat_ms, sum = {}, 0
    for _, c in ipairs(Benchmark.CATEGORIES) do
        cat_ms[c] = median(per[c] or {}) * 1000
        sum = sum + cat_ms[c]
    end
    local rounds = #samples / #Benchmark.CATEGORIES
    return {
        combination = combination,
        ok = true,
        cat_ms = cat_ms,
        round_s = sum / 1000,
        bytes = rounds > 0 and total_bytes / rounds or 0,
    }
end

--- A completed run: its samples join the combination's.
function Benchmark:_collect(run)
    local agg = self:_agg(run.entry)
    for _, smp in ipairs(run.samples) do agg.samples[#agg.samples + 1] = smp end
end

--- Ends the current run (failed with `err`, if given) and starts the next one.
function Benchmark:_end_run(err)
    if err then self:_fail(self.run.entry, err) end
    self:_close_session()
    self:_next()
end

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

--- One row per combination that ran, in list order: failed, or scored over all its samples.
function Benchmark:_rows()
    local rows = {}
    for ci, combo in ipairs(self.combinations) do
        local agg = self.aggs[ci]
        if agg then
            local row
            if agg.error then
                row = { combination = combo, ok = false, error = agg.error }
            elseif #agg.samples == 0 then
                -- defensive: a combination with no completed run and no failure has nothing to score
                row = { combination = combo, ok = false, error = "not measured" }
            else
                local ok, r = pcall(Benchmark._score, combo, agg.samples)
                row = ok and r or { combination = combo, ok = false, error = tostring(r) }
            end
            rows[#rows + 1] = row
        end
    end
    return rows
end

--- Calls `on_done` with the ranked results (and the stop, if the run stopped early), at most once.
function Benchmark:_report(stop)
    if self._reported or not self.on_done then return end
    self._reported = true
    local ok, e = pcall(function()
        return self.on_done(Benchmark._rank(self:_rows()), stop)
    end)
    if not ok then logger.warn("vncoxide: benchmark on_done failed:", e) end
end

return Benchmark
