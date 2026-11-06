--[[--
Picture-settings benchmark: measures picture-setting combinations against the live server.

Each combination gets its own fresh @{vnc.session} (a copy of the profile with the combination's
picture fields, `shared = true` like every session), so a live session of the same profile is never
disturbed and no setting is ever written. The whole list runs `PASSES` (2) times: pass 1 in list
order, pass 2 in reverse order, so warm-up and order effects (the last runs tended to score best)
even out; every run of a combination reconnects. One run at a time, in two phases, on
whatever the remote screen shows; it does not need to change. Every request is non-incremental, so
the server encodes and sends the requested pixels each time even when they are identical:

1. **full**: `FULL_SAMPLES` whole-screen requests, one at a time. When more than one is taken, the
   first is a warm-up and not counted (it pays for the connection's first encoder setup, caches
   and the progress dialog's screen refresh).
2. **tiles**: the `TILES` areas of a square grid over the framebuffer (4×4 for 16), row by row,
   one at a time, all counted. The "tiles" progress is reported first, and the first tile is
   requested on the next tick, so the e-ink refresh of the progress dialog is not counted in it.

Each request is timed from the moment it is sent until its FramebufferUpdate has been decoded and
drawn. While it is in flight the session polls every `POLL_INTERVAL` (5 ms) instead of its usual
50 ms, so the reply is read when it arrives rather than on the next ordinary poll tick. A sample
counts at most the requested area's pixels, and a DesktopSize fails the combination ("screen size
changed"). Every received rect is marked dirty by the session and drawn with @{Remote:draw_to} into one
off-screen BlitBuffer of the viewer's canvas size and type (allocated once per run), with the
viewer's view, scaling and dither flag (`canvas.dither`), like the viewer would; so decode and
draw are paid on every request. Per phase the run sums the elapsed wall time, the remote pixels
received, the bytes, and the decode and draw CPU time. The incremental request that normally
follows every update is held for the whole combination (`Session.hold_incremental`), and the next
request settles it, so exactly one request is outstanding and only the requested ones are timed.

Scores (@{Benchmark._score}), over the samples of both passes, as medians so that the Wi-Fi's
round-trip jitter (a single slow request) does not decide the ranking: `tile_ms` and `full_ms`
(median time per tile / per counted full frame), `tile_px_per_s` (median of each tile's pixels /
its time) and `full_px_per_s` (a full frame's pixels / the median full-frame time). The main
score is `tile_px_per_s`, the closest to everyday small updates (see @{Benchmark._sort}).

No viewer is attached: the benchmark attaches a minimal sink of its own (the app interface the
session calls), which draws into the off-screen buffer. Attaching registers the session's normal
poll task, which reads and decodes the updates exactly as in the viewer. The session has no view
area, so its requests cover the whole framebuffer; the tiles are explicit rect requests.

For the whole run, every attached session in `opts.sessions` (the plugin's live connections, the
open viewer's included) is detached, so its polling, decoding and drawing does not compete with the
measurement; the ones detached are attached again, to the same app, when the run finishes, is
cancelled or ends in an error (`attach` requests a full update, which resynchronises them).

A combination that fails before its handshake completes (connection refused, timeout, auth or
security failure, Wi-Fi not coming up) ends the whole run at once: the other combinations would
fail the same way. `on_done` then gets the rows so far (that combination's failed) and the error
as its second argument. A failure after connecting (a rejected format, no answer within
`REQUEST_TIMEOUT`, an error mid-phase) only fails that run, and the run goes on. A combination
whose run failed in either pass is a failed row, with the first failure as its error:
"failed in pass N: <reason>".

Everything is driven from `UIManager` tasks (the session's own poll plus a benchmark tick) and the
clock is `Session._now`, so tests can run it on a fake clock. The handshake itself is the session's
synchronous one.

`cancel()` tears the current session down and frees the buffer; `on_done` is then never called. It
may be called from anywhere, `on_progress` included: the run checks after every progress report.

An unexpected Lua error inside the run (a tick, `start()`, the connect callback, the draw) fails the
current run with the error message, tears it down, and the run goes on.

@module vnc.benchmark
]]

local BB = require("ffi/blitbuffer")
local Session = require("vnc/session")
local logger = require("logger")

local UIManager = require("ui/uimanager")

local Benchmark = {}
Benchmark.__index = Benchmark

-- Times the whole list runs: pass 1 in list order, pass 2 in reverse order (and so on, alternating).
Benchmark.PASSES = 2
-- Whole-screen requests per run of a combination (the first is a warm-up when there are more).
Benchmark.FULL_SAMPLES = 3
-- Areas of the tiles phase: a square grid (16 = 4x4) over the framebuffer.
Benchmark.TILES = 16
-- Seconds to wait for the answer to one request before the run counts as failed.
Benchmark.REQUEST_TIMEOUT = 15
-- Seconds between the session's poll ticks while a request is in flight (instead of
-- `Session.POLL_INTERVAL`), so its reply is read, and timed, as soon as it arrives.
Benchmark.POLL_INTERVAL = 0.005
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
Orders results: scored rows by `tile_px_per_s` (highest first), then failed rows; the original
order otherwise.
--- @tparam table results
--- @treturn table a new, sorted list
]]
function Benchmark._sort(results)
    local list = {}
    for i, r in ipairs(results) do list[i] = { r = r, i = i, g = r.ok and 1 or 2 } end
    table.sort(list, function(a, b)
        if a.g ~= b.g then return a.g < b.g end
        local ra, rb = a.r.tile_px_per_s, b.r.tile_px_per_s
        if a.g == 1 and ra ~= rb then return ra > rb end
        return a.i < b.i
    end)
    local out = {}
    for i, e in ipairs(list) do out[i] = e.r end
    return out
end

--[[--
The tiles phase's areas: a `n`×`n` grid (`n` = the square root of `count`) over a `w`×`h`
framebuffer, row by row; the edges are rounded down, so the tiles cover it exactly. Empty tiles
(a framebuffer under `n` pixels wide or high) are left out.
--- @treturn table `{ {x, y, w, h}, ... }`
]]
function Benchmark._tiles(w, h, count)
    local n = math.floor(math.sqrt(count) + 0.5)
    local out = {}
    for r = 0, n - 1 do
        local y0, y1 = math.floor(r * h / n), math.floor((r + 1) * h / n)
        for c = 0, n - 1 do
            local x0, x1 = math.floor(c * w / n), math.floor((c + 1) * w / n)
            -- a framebuffer narrower than the grid leaves empty tiles: nothing to request
            if x1 > x0 and y1 > y0 then
                out[#out + 1] = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
            end
        end
    end
    return out
end

--[[--
Creates a benchmark; nothing happens until @{Benchmark:start}.

--- @tparam table opts
--- @tparam table opts.profile connection profile (copied per combination, never modified)
--- @tparam[opt] table opts.combinations defaults to `COMBINATIONS`
--- @tparam table opts.canvas `{ w, h, bb_type, view_mode = "fit"|scale, scaling = "smooth"|"sharp",
---   dither }`, `dither` as the viewer passes it to @{Remote:draw_to}
--- @tparam[opt] function opts.on_progress `(i, n, label, phase, pass, passes)`: run `i` of `n` (every
---   combination once per pass), phase `"connect"|"full"|"tiles"`, pass `pass` of `passes`
--- @tparam[opt] table opts.sessions sessions (any keys) to detach while the run lasts
--- @tparam[opt] function opts.on_done `(results, connect_error)`, sorted (see @{Benchmark._sort}); each row is
---   `{ combination, ok, error, tile_px_per_s, full_px_per_s, tile_ms, full_ms, full_bytes, full,
---   tiles }` (see @{Benchmark._score}), one per combination that ran. `connect_error` is set when
---   the run stopped because a combination could not connect.
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
        aggs = {},       -- per combination index: `{ full = {}, tiles = {}, error }` over its runs
        index = 0,       -- the current run in `order`
        session = nil,
        run = nil,       -- the current combination's measurements
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
        logger.warn("vnc: benchmark error:", err)
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
        if not ok then logger.warn("vnc: benchmark could not re-attach a session:", e) end
    end
end

function Benchmark:_progress(phase)
    if self.on_progress then
        local entry = self.order[self.index]
        local ok, e = pcall(self.on_progress, self.index, #self.order, self.combinations[entry.ci].label, phase,
            entry.pass, Benchmark.PASSES)
        if not ok then logger.warn("vnc: benchmark on_progress failed:", e) end
    end
end

--- The measurements of the combination run by `entry` (created on first use).
function Benchmark:_agg(entry)
    local agg = self.aggs[entry.ci]
    if not agg then
        agg = { full = {}, tiles = {} }
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
    logger.info("vnc: benchmark:", self.combinations[entry.ci].label, "failed in pass", entry.pass .. ":", err)
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

    -- `samples`: one `{ elapsed, px, bytes, decode, draw }` per answered request of each phase;
    -- `cur`: the request in flight
    local run = { entry = entry, combination = combo, phase = "connect", samples = { full = {}, tiles = {} } }
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
    -- attach sends the first whole-screen request
    self:_new_request(run)
    session:attach({
        on_framebuffer_dirty = function() self:_on_dirty(run) end,
        -- the session answers a DesktopSize with a request of its own, and the tiles no longer
        -- fit: this combination's figures are void
        on_remote_resized = function()
            if self.run == run then run.err = run.err or "screen size changed" end
        end,
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

--- Starts timing a request for `rect` (nil: the whole screen); the session polls fast meanwhile.
function Benchmark:_new_request(run, rect)
    local area
    if rect then
        area = rect.w * rect.h
    else
        local w, h = self.session:get_remote():get_size()
        area = w * h
    end
    run.cur = { t0 = Session._now(), area = area, px = 0, bytes = 0, decode = 0, draw = 0 }
    self.session.poll_interval = Benchmark.POLL_INTERVAL
end

--[[--
Sends the next request of the current phase: the whole screen (`rect` nil) or one tile. It is
flushed at once, so no poll interval is added to its time.
]]
function Benchmark:_request(run, rect)
    local s = self.session
    self:_new_request(run, rect)
    if rect then
        s.proto:request_update(0, rect.x, rect.y, rect.w, rect.h)
    else
        s:request_full_update()
    end
    s:_flush_now()
    s:poll_soon()
end

function Benchmark:_on_update(run, tm)
    local cur = run.cur
    -- an empty update is not the area asked for
    if not cur or tm.px <= 0 then return end
    -- a server that sends more than was asked for must not inflate the score
    cur.px = math.min(cur.px + tm.px, cur.area)
    cur.bytes, cur.decode = cur.bytes + tm.bytes, cur.decode + tm.cpu
    -- complete once drawn (the session hands the rects over later in the same poll tick)
    cur.received = true
end

--- The session's sink: draws, and once the answer to the current request is drawn, records it.
function Benchmark:_on_dirty(run)
    if self.run ~= run then return end
    -- an error here would escape into the session's poll task: the tick fails the combination
    local ok, e = pcall(self._draw, self, run)
    if not ok then
        logger.warn("vnc: benchmark draw failed:", e)
        run.err = run.err or tostring(e)
    end
end

function Benchmark:_draw(run)
    local remote = self.session and self.session:get_remote()
    if not remote then return end
    local c = self.canvas
    local c0 = os.clock()
    remote:draw_to(self.bb, 0, 0, c.w, c.h, c.dither or false)
    local cur = run.cur
    if not cur then return end
    cur.draw = cur.draw + (os.clock() - c0)
    if not cur.received then return end
    cur.elapsed = Session._now() - cur.t0
    run.cur = nil
    -- back to the normal poll interval until the next request
    self.session.poll_interval = nil
    -- a failed combination asks for nothing more; the next tick ends it
    if run.err then return end
    local phase = run.phase
    local list = run.samples[phase]
    list[#list + 1] = cur
    if phase == "full" then
        if #list < Benchmark.FULL_SAMPLES then
            self:_request(run)
        else
            -- reported by the next tick (on_progress may cancel, and the session must not be
            -- disconnected from inside its own callback); a later tick sends the first tile
            run.phase = "tiles_wait"
            run.tiles_unreported = true
        end
    elseif phase == "tiles" then
        if #list < #run.tiles then
            self:_request(run, run.tiles[#list + 1])
        else
            run.phase = "done"
        end
    end
end

--- Advances the run (guarded, see @{Benchmark:_guarded}) and schedules the next tick.
function Benchmark:_tick()
    if self.stopped then return end
    self:_guarded(self._advance)
    if not self.stopped then UIManager:scheduleIn(Benchmark.TICK, self._tick_fn) end
end

--- Failures, request deadlines, the tiles phase, the next run.
function Benchmark:_advance()
    local run = self.run
    local now = Session._now()
    if run.connect_failed then
        logger.info("vnc: benchmark:", run.combination.label, "could not connect, stopping:", run.err)
        self:_fail(run.entry, run.err)
        self:_stop()
        self:_report(run.err)
    elseif run.err then
        self:_end_run(run.err)
    elseif run.tiles_unreported then
        run.tiles_unreported = nil
        self:_progress("tiles")
        -- the first tile goes out on a later tick, after the progress title's screen refresh
    elseif run.phase == "tiles_wait" then
        local w, h = self.session:get_remote():get_size()
        run.tiles = Benchmark._tiles(w, h, Benchmark.TILES)
        run.phase = "tiles"
        run.t_tiles = now
        self:_request(run, run.tiles[1])
    elseif run.phase == "done" then
        self:_collect(run)
        self:_end_run()
    elseif run.cur and now - run.cur.t0 > Benchmark.REQUEST_TIMEOUT then
        self:_end_run(string.format(run.phase == "full" and "no full-screen update within %d s"
            or "no update within %d s", Benchmark.REQUEST_TIMEOUT))
    end
end

--- Sums a phase's samples.
local function totals(list)
    local t = { n = 0, px = 0, bytes = 0, elapsed = 0, decode_ms = 0, draw_ms = 0 }
    for _, smp in ipairs(list) do
        t.n = t.n + 1
        t.px, t.bytes, t.elapsed = t.px + smp.px, t.bytes + smp.bytes, t.elapsed + smp.elapsed
        t.decode_ms, t.draw_ms = t.decode_ms + smp.decode * 1000, t.draw_ms + smp.draw * 1000
    end
    return t
end

local function rate(px, elapsed) return elapsed > 0 and px / elapsed or 0 end

--- The median of a list of numbers (the mean of the middle two for an even count); 0 when empty.
local function median(values)
    local n = #values
    if n == 0 then return 0 end
    table.sort(values)
    if n % 2 == 1 then return values[(n + 1) / 2] end
    return (values[n / 2] + values[n / 2 + 1]) / 2
end

--[[--
A combination's scored row from its samples over every pass (each `{ px, bytes, elapsed, decode,
draw }`, `elapsed` and the CPU times in seconds): the counted full frames (warm-ups left out) and
every tile.

`tile_ms` is the median tile time and `tile_px_per_s` the median of each tile's pixels / time;
`full_ms` is the median full-frame time and `full_px_per_s` a full frame's mean pixels over it;
`full_bytes` is the mean bytes per full frame; `full` and `tiles` are the phase totals
`{ n, px, bytes, elapsed, decode_ms, draw_ms }` (`n` samples, `elapsed` in seconds, decode and
draw as CPU time in ms).
--- @treturn table `{ combination, ok = true, tile_px_per_s, full_px_per_s, tile_ms, full_ms,
---   full_bytes, full, tiles }`
]]
function Benchmark._score(combination, full_samples, tile_samples)
    local full, tiles = totals(full_samples), totals(tile_samples)
    local tile_t, tile_rates, full_t = {}, {}, {}
    for i, smp in ipairs(tile_samples) do
        tile_t[i] = smp.elapsed
        tile_rates[i] = rate(smp.px, smp.elapsed)
    end
    for i, smp in ipairs(full_samples) do full_t[i] = smp.elapsed end
    local full_med = median(full_t)
    return {
        combination = combination,
        ok = true,
        tile_px_per_s = median(tile_rates),
        full_px_per_s = full.n > 0 and rate(full.px / full.n, full_med) or 0,
        tile_ms = median(tile_t) * 1000,
        full_ms = full_med * 1000,
        full_bytes = full.n > 0 and full.bytes / full.n or 0,
        full = full,
        tiles = tiles,
    }
end

--- A completed run: its counted samples join the combination's (the first full frame of a run is a warm-up).
function Benchmark:_collect(run)
    local agg = self:_agg(run.entry)
    local fl = run.samples.full
    for i = (#fl > 1 and 2 or 1), #fl do agg.full[#agg.full + 1] = fl[i] end
    for _, smp in ipairs(run.samples.tiles) do agg.tiles[#agg.tiles + 1] = smp end
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
            elseif #agg.tiles == 0 or #agg.full == 0 then
                -- defensive: a combination with no completed run and no failure has nothing to score
                row = { combination = combo, ok = false, error = "not measured" }
            else
                local ok, r = pcall(Benchmark._score, combo, agg.full, agg.tiles)
                row = ok and r or { combination = combo, ok = false, error = tostring(r) }
            end
            rows[#rows + 1] = row
        end
    end
    return rows
end

--- Calls `on_done` with the sorted results (and the connect error, if any), at most once.
function Benchmark:_report(connect_error)
    if self._reported or not self.on_done then return end
    self._reported = true
    local ok, e = pcall(function()
        return self.on_done(Benchmark._sort(self:_rows()), connect_error)
    end)
    if not ok then logger.warn("vnc: benchmark on_done failed:", e) end
end

return Benchmark
