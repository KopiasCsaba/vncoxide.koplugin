#!/usr/bin/env luajit
--[[--
Standalone test harness for the vnc protocol layer.

Starts `tools/mock_vnc_server.py` (one instance per case, on an ephemeral port) and drives
@{vncoxide.protocol} against it over a real socket, plus a few in-memory byte-stream cases. The last
two checks drive @{vncoxide.session}'s own transport (queue flush and read buffering) rather than the
protocol directly.

Run with KOReader's own LuaJIT from the KOReader root:

  cd /usr/lib/koreader
  PLUGIN=~/.config/koreader/plugins/vncoxide.koplugin
  LUA_PATH="$PLUGIN/?.lua;./common/?.lua;./common/?/init.lua;;" \
  LUA_CPATH="./common/?.so;;" \
  ./luajit "$PLUGIN/tools/proto_smoke.lua" --tmp /tmp/vncv_smoke
]]

-- KOReader environment: package.path for common/ + frontend/, and ffi.loadlib. The harness is
-- meant to be run from the KOReader root; fall back to adding the paths by hand.
if not pcall(dofile, "setupkoenv.lua") then
    package.path = "./common/?.lua;./frontend/?.lua;" .. package.path
    package.cpath = "./common/?.so;" .. package.cpath
    require("ffi/loadlib")
end

local bit = require("bit")
local ffi = require("ffi")
local socket = require("socket")

local BB = require("ffi/blitbuffer")

local Des = require("vncoxide/des")
local Encodings = require("vncoxide/encodings")
local Keysyms = require("vncoxide/keysyms")
local PxFmt = require("vncoxide/pxfmt")
local Protocol = require("vncoxide/protocol")

local bxor = bit.bxor

local TMP = "/tmp/vncv_smoke"
for i, a in ipairs(arg or {}) do
    -- Both spellings: `--tmp=<path>` and `--tmp <path>` (the documented command uses the latter,
    -- which an `=`-only parser silently ignored, leaving the mock's logs in the built-in path).
    local v = a:match("^%-%-tmp=(.+)$") or (a == "--tmp" and (arg or {})[i + 1] or nil)
    if v then TMP = v end
end
local tools_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local MOCK = tools_dir .. "/mock_vnc_server.py"

os.execute("mkdir -p " .. TMP)

-- ---------------------------------------------------------------- utilities

local function read_file(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local s = fh:read("*a")
    fh:close()
    return s
end

local function log_has(path, needle)
    local s = read_file(path)
    return s ~= nil and s:find(needle, 1, true) ~= nil
end

local function log_count(path, needle)
    local s = read_file(path)
    if not s then return 0 end
    local n, pos = 0, 1
    while true do
        local i = s:find(needle, pos, true)
        if not i then return n end
        n = n + 1
        pos = i + #needle
    end
end

local function wait_for_log(path, needle, timeout)
    local deadline = os.time() + (timeout or 5)
    repeat
        if log_has(path, needle) then return true end
        os.execute("sleep 0.05")
    until os.time() > deadline
    return false
end

local function free_port()
    local s = assert(socket.tcp())
    assert(s:bind("127.0.0.1", 0))
    local _, port = s:getsockname()
    s:close()
    return tonumber(port)
end

-- pids of started mocks that were not stopped yet; swept after every check and at exit
local LIVE_MOCKS = {}

--[[--
Starts the mock server; returns its pid, the port and the log path.
]]
local function start_mock(opts)
    local port = free_port()
    local log = string.format("%s/%s.log", TMP, opts.name)
    os.remove(log)
    os.remove(log .. ".stdout")
    local cmd = {
        "python3", MOCK,
        "--port", tostring(port),
        "--encoding", opts.encoding,
        "--pattern", opts.pattern,
        "--width", tostring(opts.width or 200),
        "--height", tostring(opts.height or 150),
        "--log", log,
    }
    if opts.security then table.insert(cmd, "--security"); table.insert(cmd, opts.security) end
    if opts.password then table.insert(cmd, "--password"); table.insert(cmd, opts.password) end
    if opts.repaint then table.insert(cmd, "--repaint"); table.insert(cmd, tostring(opts.repaint)) end
    if opts.resize_after then table.insert(cmd, "--resize-after"); table.insert(cmd, tostring(opts.resize_after)) end
    if opts.split then table.insert(cmd, "--split"); table.insert(cmd, tostring(opts.split)) end
    if opts.resize_once then table.insert(cmd, "--resize-once") end
    if opts.resize_same then table.insert(cmd, "--resize-same") end
    if opts.alt_pattern then table.insert(cmd, "--alt-pattern"); table.insert(cmd, opts.alt_pattern) end
    if opts.input_during_send then table.insert(cmd, "--input-during-send") end
    -- (`persist`: it serves later connections too, e.g. a reconnect)
    if not opts.persist then table.insert(cmd, "--once") end
    local full = table.concat(cmd, " ") .. " > " .. log .. ".stdout 2>&1 & echo $!"
    local h = assert(io.popen(full, "r"))
    local pid = (h:read("*l") or ""):gsub("%s", "")
    h:close()
    LIVE_MOCKS[pid] = true
    if not wait_for_log(log, "LISTENING", 10) then
        os.execute("kill -9 " .. pid .. " 2>/dev/null"); LIVE_MOCKS[pid] = nil
        error(string.format("mock server did not start (pid %s, log %s): %s",
            pid, log, read_file(log .. ".stdout") or "(no output)"))
    end
    return pid, port, log
end

local function stop_mock(pid)
    if pid and pid ~= "" then
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
        LIVE_MOCKS[pid] = nil
    end
end

-- Kills every mock still registered (a case that failed before its own stop_mock).
local function stop_all_mocks()
    for pid in pairs(LIVE_MOCKS) do stop_mock(pid) end
end

-- ---------------------------------------------------------------- synthetic framebuffer

local function pattern_pixel(pattern, x, y, fw, fh)
    if pattern == "gradient" then
        return x % 256, y % 256, bxor(x, y) % 256
    elseif pattern == "quadrants" then
        local left, top = x < math.floor(fw / 2), y < math.floor(fh / 2)
        if top then
            return left and 255 or 0, left and 0 or 255, 0
        end
        return left and 0 or 255, left and 0 or 255, left and 255 or 255
    elseif pattern == "checker" then
        local c = ((math.floor(x / 32) + math.floor(y / 32)) % 2 == 0) and 255 or 0
        return c, c, c
    end
    error("unknown pattern " .. tostring(pattern))
end

--- Compares the whole plane against `expect(x, y) -> r, g, b`.
local function check_plane(plane, fw, fh, expect)
    local base = ffi.cast("uint8_t*", plane.data)
    local stride = plane.stride
    for y = 0, fh - 1 do
        local row = base + y * stride
        for x = 0, fw - 1 do
            local er, eg, eb = expect(x, y)
            if er ~= nil then
                local p = row + x * 3
                if p[0] ~= er or p[1] ~= eg or p[2] ~= eb then
                    return nil, string.format("pixel (%d,%d) is (%d,%d,%d), expected (%d,%d,%d)",
                        x, y, p[0], p[1], p[2], er, eg, eb)
                end
            end
        end
    end
    return true
end

local function expect_pattern(pattern, fw, fh)
    return function(x, y) return pattern_pixel(pattern, x, y, fw, fh) end
end

-- What a pattern channel looks like after the mock quantizes it to `max`
-- (`(v * max + 127) // 255`, PixelCodec.value) and the client expands it back
-- (`floor(q * 255 / max + 0.5)`).
local function requantize(v, max)
    if max == 255 then return v end
    local q = math.floor((v * max + 127) / 255)
    return math.floor(q * 255 / max + 0.5)
end

--- `expect`-style builder: the pattern as seen through the low-depth pixel format `fmt`.
local function expect_quantized(fmt, base)
    base = base or expect_pattern
    return function(pattern, fw, fh)
        local inner = base(pattern, fw, fh)
        return function(x, y)
            local r, g, b = inner(x, y)
            if r == nil then return nil end
            return requantize(r, fmt.red_max), requantize(g, fmt.green_max),
                requantize(b, fmt.blue_max)
        end
    end
end

-- ---------------------------------------------------------------- driver

--[[--
Drives @{vncoxide.protocol} against a real socket until `want_updates` updates have been
seen, or `body` signals a stop.

`o` fields: name, port, password, encodings, want_updates, body, stop_after_body,
on_connected, on_rect, on_resize, on_bell, on_cut_text, on_update, timeout.
]]
local function run_case(o)
    local sock = assert(socket.tcp())
    sock:settimeout(3)
    local ok, err = sock:connect("127.0.0.1", o.port)
    if not ok then return nil, "connect: " .. tostring(err), nil end
    sock:settimeout(3)
    sock:setoption("tcp-nodelay", true)

    local ctx = {
        updates = 0, rects = 0, resizes = {}, bells = 0, cuts = {},
        plane = nil, connected = false, body_run = false, stop = false,
        fw = nil, fh = nil, name = nil,
    }
    local tx = {}
    local function flush()
        if #tx == 0 then return true end
        local out = table.concat(tx, "", 1, #tx)
        for i = 1, #tx do tx[i] = nil end
        local i = 1
        while i <= #out do
            local last, serr = sock:send(out, i)
            if not last then return nil, "send: " .. tostring(serr) end
            i = last + 1
        end
        return true
    end

    local proto
    proto = Protocol.new{
        io = {
            write = function(s) tx[#tx + 1] = s end,
            read = function(n) return coroutine.yield("need", n) end,
        },
        host = "127.0.0.1",
        port = o.port,
        password = o.password,
        encodings = o.encodings,
        pixel_format = o.pixel_format,
        shared = true,
        get_plane = function() return ctx.plane end,
        callbacks = {
            on_connected = function(name, w, h)
                ctx.name, ctx.fw, ctx.fh = name, w, h
                ctx.connected = true
                if o.on_connected then return o.on_connected(ctx, name, w, h) end
            end,
            on_rect = function(x, y, w, h, enc)
                ctx.rects = ctx.rects + 1
                if o.on_rect then return o.on_rect(ctx, x, y, w, h, enc) end
            end,
            on_desktop_resize = function(w, h)
                ctx.fw, ctx.fh = w, h
                ctx.resizes[#ctx.resizes + 1] = { w = w, h = h }
                if o.on_resize then return o.on_resize(ctx, w, h, proto) end
            end,
            on_bell = function()
                ctx.bells = ctx.bells + 1
                if o.on_bell then return o.on_bell(ctx) end
            end,
            on_cut_text = function(text)
                ctx.cuts[#ctx.cuts + 1] = text
                if o.on_cut_text then return o.on_cut_text(ctx, text) end
            end,
            on_update_done = function()
                ctx.updates = ctx.updates + 1
                if o.on_update then
                    local oku, erru = o.on_update(ctx)
                    if erru ~= nil or oku == false then
                        return nil, erru or "on_update callback failed"
                    end
                end
                if o.want_updates and ctx.updates >= o.want_updates then ctx.stop = true end
            end,
        },
    }

    local data = nil
    while true do
        local a, b = proto:step(data)
        local fok, ferr = flush()
        if not fok then sock:close(); proto:free(); return nil, ferr, ctx end
        if a == "need" then
            if ctx.connected and not ctx.body_run then
                ctx.body_run = true
                if o.body then
                    local okb, errb = o.body(proto, ctx)
                    if errb ~= nil or okb == false then
                        sock:close(); proto:free()
                        return nil, errb or "body failed", ctx
                    end
                end
                local fok2, ferr2 = flush()
                if not fok2 then sock:close(); proto:free(); return nil, ferr2, ctx end
                if o.stop_after_body then ctx.stop = true end
            end
            if ctx.stop then break end
            local chunk, rerr = sock:receive(b)
            if not chunk then
                sock:close(); proto:free()
                return nil, string.format("receive(%d): %s", b, tostring(rerr)), ctx
            end
            data = chunk
        elseif a == "done" then
            break
        else
            sock:close()
            proto:free()
            return nil, tostring(b), ctx
        end
    end
    sock:close()
    proto:free()
    return true, nil, ctx
end

--- Drives the protocol against an in-memory byte string (no socket, no mock).
local function run_mem(bytes, o)
    o = o or {}
    local pos = 1
    local proto = Protocol.new{
        io = {
            write = function() end,
            read = function(n) return coroutine.yield("need", n) end,
        },
        host = "mem",
        port = 0,
        password = o.password,
        encodings = o.encodings or Encodings.ORDER_DEFAULT,
        get_plane = function() return o.plane end,
        callbacks = o.callbacks or {},
    }
    local data = nil
    for _ = 1, 1000 do
        local a, b = proto:step(data)
        if a == "need" then
            data = bytes:sub(pos, pos + b - 1)
            pos = pos + b
            if #data < b then
                proto:free()
                return nil, string.format("feed exhausted: wanted %d, had %d", b, #data)
            end
        elseif a == "done" then
            proto:free()
            return true
        else
            proto:free()
            return nil, tostring(b)
        end
    end
    proto:free()
    return nil, "protocol did not terminate"
end

--[[--
Loads @{vncoxide.session} for the transport-level checks. The session requires `ui/uimanager` for
its poll task, which drags in the whole widget stack; the harness has none, so stand one in
that only provides the two scheduling calls the session makes. It is installed lazily so the
protocol-only checks keep running without it.
]]
local function load_session()
    package.preload["ui/uimanager"] = package.preload["ui/uimanager"] or function()
        return { scheduleIn = function() end, unschedule = function() end }
    end
    return require("vncoxide/session")
end

--[[--
Connects `s` the way the UI loop would, but without one: the stub UIManager runs no tasks, so the
connect ticks (the TCP connect, then the handshake) are driven here until the attempt is over.
]]
local function connect_sync(s, cb)
    s:connect(cb)
    local deadline = socket.gettime() + 30
    while s._phase and socket.gettime() < deadline do
        s:_connect_tick()
        socket.sleep(0.002)
    end
end

-- ---------------------------------------------------------------- the session as the workers' proxy
-- A UIManager on the real clock that runs due tasks (the session's poll task, a worker
-- handle's delayed kill), and every link Workers.start makes, for the cleanup.
local function proxy_env()
    load_session()
    local UIManager = require("ui/uimanager")
    local Workers = require("vncoxide/workers")
    local real_si, real_un, real_start = UIManager.scheduleIn, UIManager.unschedule, Workers.start
    local env = { tasks = {}, links = {} }
    UIManager.scheduleIn = function(_, delay, fn, ...)
        env.tasks[#env.tasks + 1] = { t = socket.gettime() + delay, d = delay, fn = fn, args = { ... }, n = select("#", ...) }
    end
    UIManager.unschedule = function(_, fn)
        for i = #env.tasks, 1, -1 do
            if env.tasks[i].fn == fn then table.remove(env.tasks, i) end
        end
    end
    Workers.start = function(session)
        local link, err, lost = real_start(session)
        if link then env.links[#env.links + 1] = link end
        return link, err, lost
    end
    --- Runs the due tasks once.
    function env.step()
        local now, due = socket.gettime(), {}
        for i = #env.tasks, 1, -1 do
            if env.tasks[i].t <= now then due[#due + 1] = table.remove(env.tasks, i) end
        end
        for i = #due, 1, -1 do due[i].fn(unpack(due[i].args, 1, due[i].n)) end
    end
    --- Runs tasks until `cond()` holds (true) or `timeout` seconds passed (false).
    function env.run_until(cond, timeout)
        local deadline = socket.gettime() + timeout
        repeat
            env.step()
            if cond() then return true end
            socket.sleep(0.003)
        until socket.gettime() > deadline
        return cond() and true or false
    end
    --- Restores the scheduler and makes sure no worker of any link outlives the check.
    function env.finish()
        UIManager.scheduleIn, UIManager.unschedule, Workers.start = real_si, real_un, real_start
        for _, link in ipairs(env.links) do
            pcall(link.stop, link)
            for _, h in ipairs({ link.decode, link.scale }) do
                local deadline = socket.gettime() + 2
                while not h.pid and h.read_fd and socket.gettime() < deadline do
                    h.eof = false
                    h:poll()
                    socket.sleep(0.01)
                end
                if h.pid then
                    ffi.C.kill(h.pid, 9)
                    while ffi.C.kill(h.pid, 0) == 0 and socket.gettime() < deadline do socket.sleep(0.01) end
                end
            end
        end
        env.tasks = {}
    end
    return env
end
-- The app side of a session: records what the session hands it.
local function proxy_app()
    local app = { dirty = {}, resized = 0, bells = 0 }
    function app.on_framebuffer_dirty_canvas(_, rects) app.dirty[#app.dirty + 1] = rects end
    function app.on_framebuffer_dirty() error("in worker mode the app gets canvas rects") end
    function app.on_remote_resized() app.resized = app.resized + 1 end
    function app.on_bell() app.bells = app.bells + 1 end
    return app
end
local function pattern_plane(pattern, W, H)
    local plane = BB.new(W, H, BB.TYPE_BBRGB24)
    for y = 0, H - 1 do
        for x = 0, W - 1 do
            plane:setPixel(x, y, BB.ColorRGB24(pattern_pixel(pattern, x, y, W, H)))
        end
    end
    return plane
end
--[[--
A paint target for `remote` (BB8, the size of its canvas) and a function that tells whether
the target, painted now, shows `pattern` as the remote's current view scales it (nil when it
does, else the first mismatching probe).
]]
local function canvas_probe(remote, cw, ch)
    local Scaler = require("vncoxide/scaler")
    local target = BB.new(cw, ch, BB.TYPE_BB8)
    local cache = {}
    return target, function(pattern)
        local W, H = remote:get_size()
        local view = remote:_render_view()
        local key = string.format("%s %d %d %.17g %.17g %.17g", pattern, W, H, view.scale, view.x, view.y)
        local exp = cache[key]
        if not exp then
            local plane = pattern_plane(pattern, W, H)
            exp = BB.new(cw, ch, BB.TYPE_BB8)
            Scaler.render(exp, plane, view, { x = 0, y = 0, w = cw, h = ch }, remote.scaling)
            plane:free()
            cache[key] = exp
        end
        remote:draw_to(target, 0, 0, cw, ch, false)
        for i = 0, 4 do
            for j = 0, 4 do
                local x, y = math.floor((cw - 1) * (2 * i + 1) / 10), math.floor((ch - 1) * (2 * j + 1) / 10)
                local a, e = target:getPixel(x, y):getColor8().a, exp:getPixel(x, y):getColor8().a
                if a ~= e then return string.format("(%d,%d) is %d, expected %d", x, y, a, e) end
            end
        end
        return nil
    end
end
-- Waits until the paint target shows `pattern` (the session's poll running meanwhile).
local function wait_canvas(env, shows, pattern, timeout)
    local bad
    env.run_until(function()
        bad = shows(pattern)
        return bad == nil
    end, timeout)
    return bad
end
local function proxy_session(env, name, mock, network_mgr)
    local Session = load_session()
    require("vncoxide/workers").canvas_bytes = function() return 400 * 400 * 4 end
    mock.name = name
    local pid, port, log = start_mock(mock)
    local states = {}
    local s = Session.new{
        profile = { host = "127.0.0.1", port = port, password = "", name = name },
        worker_processes = true,
        network_mgr = network_mgr or { isWifiOn = function() return true end, turnOffWifi = function() end },
        on_state = function(st) states[#states + 1] = st end,
    }
    local connected, cerr
    s:connect(function(ok, err) connected, cerr = ok, err end)
    env.run_until(function() return connected ~= nil end, 10)
    if connected == nil then
        error(string.format("the connect did not finish (state %s, phase %s, states %s)",
            tostring(s.state), tostring(s._phase), table.concat(states, ",")))
    end
    if not connected then error("connect failed: " .. tostring(cerr)) end
    if not s.workers then error("no workers started") end
    return s, pid, log, states
end

-- ---------------------------------------------------------------- checks

local failures = 0
-- `--only <lua pattern>` (or `--only=<pattern>`): run only the checks whose name matches.
local ONLY
for i, a in ipairs(arg or {}) do
    local v = a:match("^%-%-only=(.+)$") or (a == "--only" and (arg or {})[i + 1] or nil)
    if v then ONLY = v end
end
local function check(name, fn)
    if ONLY and not name:find(ONLY) then return end
    local ok, res, err = pcall(fn)
    stop_all_mocks()
    if ok and res then
        print("ok - " .. name)
    else
        failures = failures + 1
        if not ok then
            print(string.format("FAIL: %s: %s", name, tostring(res)))
        else
            print(string.format("FAIL: %s: %s", name, tostring(err)))
        end
    end
end

--[[--
A live-connection session check in both modes: `name` in-process, `name_workers` with
`worker_processes` (the session as the workers' proxy). Checks that inspect the in-process
session's internals (`session.proto`, `tx`, the receive buffer, `_pump`) are in-process only:
session_send_partial_progress, session_send_partial_end_to_end (the UI's socket buffer),
session_modifier_release_after_input_waits_a_gap, session_holds_update_request_during_input,
session_requests_update_at_once_without_input, protocol_release_update_noop, the update timing
checks (`on_update`), session_attach_after_held_request_owes_nothing,
session_does_not_log_the_server_clipboard, session_forced_area_waits_while_held and the
session_rx_* checks; the connect-phase checks run before any worker exists, and the benchmark
always runs in-process.
]]
local function both_modes(name, in_process, workers)
    check(name, in_process)
    check(name .. "_workers", workers)
end

--- Runs one encoding end-to-end against the mock and compares every pixel.
local function encoding_case(name, encoding, pattern, expect, opts)
    opts = opts or {}
    local pid, port, log = start_mock{
        name = name, encoding = encoding, pattern = pattern,
        width = opts.width or 200, height = opts.height or 150,
        repaint = opts.repaint, resize_after = opts.resize_after,
    }
    local ok, err, ctx
    local ok2, err2 = pcall(function()
        ok, err, ctx = run_case{
            name = name, port = port,
            encodings = opts.encodings or Encodings.order(opts.enable_tight),
            pixel_format = opts.pixel_format,
            want_updates = opts.want_updates or 1,
            on_connected = function(c, _, w, h)
                c.plane = BB.new(w, h, BB.TYPE_BBRGB24)
            end,
            on_resize = opts.on_resize,
            on_update = opts.on_update,
            body = function(proto, c)
                proto:request_update(0, 0, 0, c.fw, c.fh)
                if opts.after_request then opts.after_request(proto, c) end
                return true
            end,
        }
    end)
    stop_mock(pid)
    if not ok2 then return nil, err2 end
    if not ok then return nil, err end
    if opts.verify_log then
        local vok, verr = opts.verify_log(log, ctx)
        if not vok then return nil, verr end
    end
    if opts.check ~= false then
        local cok, cerr = check_plane(ctx.plane, ctx.fw, ctx.fh, expect(pattern, ctx.fw, ctx.fh))
        if not cok then
            return nil, string.format("%s: %s", encoding, cerr)
        end
    end
    if opts.post then return opts.post(ctx, log) end
    return true
end

-- ---------------------------------------------------------------- scaler

local floor, ceil = math.floor, math.ceil

local function scaler_plane(w, h)
    local p = BB.new(w, h, BB.TYPE_BBRGB24)
    local d = ffi.cast("uint8_t*", p.data)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local o = y * p.stride + x * 3
            d[o] = (x * 37 + y * 101 + (x * y) % 13 * 17) % 256
            d[o + 1] = (x * 11 + y * 59 + 90) % 256
            d[o + 2] = (x * y * 7 + 200) % 256
        end
    end
    return p
end

local function bb_fill(bb, v)
    ffi.fill(ffi.cast("uint8_t*", bb.data), bb.stride * bb:getHeight(), v)
end

local SC_BPP = { [BB.TYPE_BB8] = 1, [BB.TYPE_BBRGB24] = 3, [BB.TYPE_BBRGB32] = 4 }

--- First differing pixel of two same-sized buffers, or nil.
local function bb_diff(a, b)
    local pa, pb = ffi.cast("uint8_t*", a.data), ffi.cast("uint8_t*", b.data)
    local bpp = SC_BPP[a:getType()]
    for y = 0, a:getHeight() - 1 do
        for x = 0, a:getWidth() - 1 do
            for k = 0, bpp - 1 do
                if pa[y * a.stride + x * bpp + k] ~= pb[y * b.stride + x * bpp + k] then
                    return x, y
                end
            end
        end
    end
end

--- All differing pixels as a list of {x, y}.
local function bb_diffs(a, b)
    local pa, pb = ffi.cast("uint8_t*", a.data), ffi.cast("uint8_t*", b.data)
    local bpp, out = SC_BPP[a:getType()], {}
    for y = 0, a:getHeight() - 1 do
        for x = 0, a:getWidth() - 1 do
            for k = 0, bpp - 1 do
                if pa[y * a.stride + x * bpp + k] ~= pb[y * b.stride + x * bpp + k] then
                    out[#out + 1] = { x, y }
                    break
                end
            end
        end
    end
    return out
end

local SC_SCALES = { 0.3, 0.5, 0.75, 1, 1.37, 2, 2.5 }
local SC_MODES = { "smooth", "sharp" }
local SC_TYPES = { { "BB8", BB.TYPE_BB8 }, { "RGB32", BB.TYPE_BBRGB32 }, { "RGB24", BB.TYPE_BBRGB24 } }
-- views showing black margins (negative offsets, plane edge inside the canvas) and plain ones
local SC_VIEWS = { { x = -3.3, y = 2.6 }, { x = 5.25, y = -1.5 }, { x = 0, y = 0 }, { x = 7, y = 3 } }

local function scaler_checks()
    local Scaler = require("vncoxide/scaler")
    local PW, PH, CW, CH = 37, 29, 64, 48
    local plane = scaler_plane(PW, PH)

    for _, s in ipairs(SC_SCALES) do
        for _, mode in ipairs(SC_MODES) do
            for _, t in ipairs(SC_TYPES) do
                check(string.format("scaler_partial_eq_full_%s_%s_%s", mode, s, t[1]), function()
                    local A, B = BB.new(CW, CH, t[2]), BB.new(CW, CH, t[2])
                    for vi, v in ipairs(SC_VIEWS) do
                        local view = { x = v.x, y = v.y, scale = s }
                        bb_fill(A, 0x5A); bb_fill(B, 0xA5)
                        Scaler.render(A, plane, view, { x = 0, y = 0, w = CW, h = CH }, mode)
                        local xs, ys = { 0, 13, 41, CW }, { 0, 7, 30, CH }
                        for i = 1, 3 do
                            for j = 1, 3 do
                                Scaler.render(B, plane, view, { x = xs[i], y = ys[j],
                                    w = xs[i + 1] - xs[i], h = ys[j + 1] - ys[j] }, mode)
                            end
                        end
                        for _, r in ipairs({ { x = 0, y = 0, w = 1, h = CH }, { x = CW - 1, y = 0, w = 1, h = CH },
                                { x = 5, y = CH - 1, w = 7, h = 1 }, { x = 0, y = 0, w = CW, h = 1 },
                                { x = 17, y = 11, w = 3, h = 2 }, { x = CW - 9, y = CH - 5, w = 9, h = 5 } }) do
                            Scaler.render(B, plane, view, r, mode)
                        end
                        local x, y = bb_diff(A, B)
                        if x then
                            A:free(); B:free()
                            return nil, string.format("view %d differs at %d,%d", vi, x, y)
                        end
                        -- a lone rect writes only inside itself
                        bb_fill(B, 0xA5)
                        Scaler.render(B, plane, view, { x = 20, y = 9, w = 11, h = 6 }, mode)
                        local pb, bpp = ffi.cast("uint8_t*", B.data), SC_BPP[t[2]]
                        for yy = 0, CH - 1 do
                            for xx = 0, CW - 1 do
                                local inside = xx >= 20 and xx < 31 and yy >= 9 and yy < 15
                                if not inside and pb[yy * B.stride + xx * bpp] ~= 0xA5 then
                                    A:free(); B:free()
                                    return nil, string.format("view %d wrote outside at %d,%d", vi, xx, yy)
                                end
                            end
                        end
                    end
                    A:free(); B:free()
                    return true
                end)
            end
        end
    end

    check("scaler_sharp_2x_blocks", function()
        local A = BB.new(CW, CH, BB.TYPE_BBRGB32)
        Scaler.render(A, plane, { x = 0, y = 0, scale = 2 }, { x = 0, y = 0, w = CW, h = CH }, "sharp")
        for y = 0, CH - 1 do
            for x = 0, CW - 1 do
                local c, p = A:getPixel(x, y), plane:getPixel(floor(x / 2), floor(y / 2))
                if c:getR() ~= p:getR() or c:getG() ~= p:getG() or c:getB() ~= p:getB() then
                    A:free(); return nil, string.format("pixel %d,%d", x, y)
                end
            end
        end
        A:free(); return true
    end)

    check("scaler_smooth_1x_is_source", function()
        local A, G = BB.new(PW, PH, BB.TYPE_BBRGB24), BB.new(PW, PH, BB.TYPE_BB8)
        local full = { x = 0, y = 0, w = PW, h = PH }
        Scaler.render(A, plane, { x = 0, y = 0, scale = 1 }, full, "smooth")
        Scaler.render(G, plane, { x = 0, y = 0, scale = 1 }, full, "smooth")
        for y = 0, PH - 1 do
            for x = 0, PW - 1 do
                local c, p = A:getPixel(x, y), plane:getPixel(x, y)
                local grey = floor((p:getR() * 77 + p:getG() * 150 + p:getB() * 29) / 256)
                if c:getR() ~= p:getR() or c:getG() ~= p:getG() or c:getB() ~= p:getB()
                        or G:getPixel(x, y):getColor8().a ~= grey then
                    A:free(); G:free(); return nil, string.format("pixel %d,%d", x, y)
                end
            end
        end
        A:free(); G:free(); return true
    end)

    check("scaler_outside_plane_black", function()
        local A = BB.new(CW, CH, BB.TYPE_BB8)
        bb_fill(A, 0x77)
        Scaler.render(A, plane, { x = -10, y = -4, scale = 1 }, { x = 0, y = 0, w = CW, h = CH }, "smooth")
        local ok = A:getPixel(9, 20):getColor8().a == 0 and A:getPixel(5, 3):getColor8().a == 0
            and A:getPixel(10 + PW, 10):getColor8().a == 0 and A:getPixel(10, 4 + PH):getColor8().a == 0
        A:free()
        return ok, "expected black outside the plane"
    end)

    -- smooth values: a flat plane stays flat (bilinear up, box down), and halving averages 2x2 blocks
    for _, s in ipairs({ 0.75, 2.5 }) do
        for _, t in ipairs(SC_TYPES) do
            check(string.format("scaler_smooth_uniform_stays_uniform_%s_%s", s, t[1]), function()
                local p = BB.new(PW, PH, BB.TYPE_BBRGB24)
                local d = ffi.cast("uint8_t*", p.data)
                for y = 0, PH - 1 do
                    for x = 0, PW - 1 do
                        local o = y * p.stride + x * 3
                        d[o], d[o + 1], d[o + 2] = 200, 120, 40
                    end
                end
                local A = BB.new(CW, CH, t[2])
                local view = { x = 1.3, y = 0.6, scale = s }
                Scaler.render(A, p, view, { x = 0, y = 0, w = CW, h = CH }, "smooth")
                local grey = floor((200 * 77 + 120 * 150 + 40 * 29) / 256)
                local bad
                for y = 0, CH - 1 do
                    for x = 0, CW - 1 do
                        local u, w = view.x + (x + 0.5) / s, view.y + (y + 0.5) / s
                        if u >= 0 and u < PW and w >= 0 and w < PH then
                            local c = A:getPixel(x, y)
                            if t[2] == BB.TYPE_BB8 then
                                if c:getColor8().a ~= grey then bad = bad or { x, y } end
                            else
                                c = c:getColorRGB32()
                                if c.r ~= 200 or c.g ~= 120 or c.b ~= 40 then bad = bad or { x, y } end
                            end
                        end
                    end
                end
                A:free(); p:free()
                if bad then return nil, string.format("pixel %d,%d is not the plane's colour", bad[1], bad[2]) end
                return true
            end)
        end
    end

    for _, t in ipairs(SC_TYPES) do
        check("scaler_smooth_half_is_the_rounded_2x2_mean_" .. t[1], function()
            -- the RGB channels are averaged (rounding halves up); BB8 averages the grey values
            -- (77r + 150g + 29b) and floors the result, i.e. the grey of the exact mean
            local W, H = floor(PW / 2), floor(PH / 2)
            local A = BB.new(W, H, t[2])
            Scaler.render(A, plane, { x = 0, y = 0, scale = 0.5 }, { x = 0, y = 0, w = W, h = H }, "smooth")
            for y = 0, H - 1 do
                for x = 0, W - 1 do
                    local sum = { 0, 0, 0 }
                    for k = 0, 3 do
                        local q = plane:getPixel(2 * x + k % 2, 2 * y + floor(k / 2))
                        sum[1], sum[2], sum[3] = sum[1] + q:getR(), sum[2] + q:getG(), sum[3] + q:getB()
                    end
                    local r, g, b = floor((sum[1] + 2) / 4), floor((sum[2] + 2) / 4), floor((sum[3] + 2) / 4)
                    local c, ok = A:getPixel(x, y)
                    if t[2] == BB.TYPE_BB8 then
                        ok = c:getColor8().a == floor((sum[1] * 77 + sum[2] * 150 + sum[3] * 29) / 1024)
                    else
                        c = c:getColorRGB32()
                        ok = c.r == r and c.g == g and c.b == b
                    end
                    if not ok then
                        A:free(); return nil, string.format("pixel %d,%d", x, y)
                    end
                end
            end
            A:free(); return true
        end)
    end

    -- brute force: every canvas pixel that changes when one source pixel changes lies in dst_rect_for
    for _, s in ipairs(SC_SCALES) do
        for _, mode in ipairs(SC_MODES) do
            check(string.format("scaler_dst_rect_for_%s_%s", mode, s), function()
                local A, B = BB.new(CW, CH, BB.TYPE_BB8), BB.new(CW, CH, BB.TYPE_BB8)
                local full = { x = 0, y = 0, w = CW, h = CH }
                for _, v in ipairs(SC_VIEWS) do
                    local view = { x = v.x, y = v.y, scale = s }
                    for _, sp in ipairs({ { 0, 0 }, { 12, 9 }, { PW - 1, PH - 1 }, { 0, PH - 1 }, { 20, 0 } }) do
                        local p = scaler_plane(PW, PH)
                        Scaler.render(A, p, view, full, mode)
                        p:setPixel(sp[1], sp[2], BB.ColorRGB24(255, 255, 255))
                        Scaler.render(B, p, view, full, mode)
                        p:setPixel(sp[1], sp[2], BB.ColorRGB24(0, 0, 0))
                        local B2 = BB.new(CW, CH, BB.TYPE_BB8)
                        Scaler.render(B2, p, view, full, mode)
                        p:free()
                        local r = Scaler.dst_rect_for({ x = sp[1], y = sp[2], w = 1, h = 1 }, view, CW, CH, mode)
                        for _, d in ipairs(bb_diffs(A, B)) do
                            if not r or d[1] < r.x or d[1] >= r.x + r.w or d[2] < r.y or d[2] >= r.y + r.h then
                                return nil, string.format("view %.2f,%.2f src %d,%d: %d,%d outside", v.x, v.y,
                                    sp[1], sp[2], d[1], d[2])
                            end
                        end
                        for _, d in ipairs(bb_diffs(A, B2)) do
                            if not r or d[1] < r.x or d[1] >= r.x + r.w or d[2] < r.y or d[2] >= r.y + r.h then
                                return nil, string.format("view %.2f,%.2f src %d,%d: %d,%d outside (black)", v.x, v.y,
                                    sp[1], sp[2], d[1], d[2])
                            end
                        end
                        B2:free()
                        -- not absurdly generous: a source pixel covers about s canvas pixels
                        local lim = ceil(s) + 4
                        if r and (r.w > lim or r.h > lim) then
                            return nil, string.format("rect %dx%d too large", r.w, r.h)
                        end
                    end
                end
                A:free(); B:free()
                return true
            end)
        end
    end
end

--[[--
The contrast tone curve: folded into the scaler's per-pixel conversion, it must give exactly the
picture of a plane whose pixels went through the curve first (per channel into RGB, on the grey
value into BB8), in every mode, scale, destination type and view, for any partition into rects.
]]
local function contrast_checks()
    local Scaler = require("vncoxide/scaler")
    local PW, PH, CW, CH = 37, 29, 64, 48

    check("contrast_lut_curve", function()
        if Scaler.contrast_lut(1) ~= nil then return nil, "neutral must be no curve at all" end
        for _, f in ipairs({ 0.5, 1.25, 3 }) do
            local lut = Scaler.contrast_lut(f)
            for x = 0, 255 do
                local want = math.max(0, math.min(255, math.floor(127.5 + f * (x - 127.5) + 0.5)))
                if lut.g[x] ~= want or lut.w[x] ~= want * 256 then
                    return nil, string.format("f=%s x=%d: %d/%d, want %d", f, x, lut.g[x], lut.w[x], want)
                end
                if x > 0 and lut.g[x] < lut.g[x - 1] then return nil, "not monotonic" end
            end
        end
        local hi = Scaler.contrast_lut(3)
        if hi.g[40] ~= 0 or hi.g[215] ~= 255 then return nil, "a strong curve clips at both ends" end
        return true
    end)

    local plane = scaler_plane(PW, PH)
    for _, f in ipairs({ 0.5, 2 }) do
        local lut = Scaler.contrast_lut(f)
        -- the same plane with the curve applied beforehand: per channel, and as grey
        local per_channel, as_grey = BB.new(PW, PH, BB.TYPE_BBRGB24), BB.new(PW, PH, BB.TYPE_BBRGB24)
        local sp = ffi.cast("uint8_t*", plane.data)
        local cp, gp = ffi.cast("uint8_t*", per_channel.data), ffi.cast("uint8_t*", as_grey.data)
        for y = 0, PH - 1 do
            for x = 0, PW - 1 do
                local o = y * plane.stride + x * 3
                local r, g, b = sp[o], sp[o + 1], sp[o + 2]
                cp[o], cp[o + 1], cp[o + 2] = lut.g[r], lut.g[g], lut.g[b]
                local v = lut.g[bit.rshift(r * 77 + g * 150 + b * 29, 8)]
                gp[o], gp[o + 1], gp[o + 2] = v, v, v
            end
        end
        for _, s in ipairs(SC_SCALES) do
            for _, mode in ipairs(SC_MODES) do
                for _, t in ipairs(SC_TYPES) do
                    check(string.format("scaler_contrast_%s_%s_%s_%s", f, mode, s, t[1]), function()
                        local ref_plane = t[2] == BB.TYPE_BB8 and as_grey or per_channel
                        local A, B = BB.new(CW, CH, t[2]), BB.new(CW, CH, t[2])
                        local full = { x = 0, y = 0, w = CW, h = CH }
                        for vi, v in ipairs(SC_VIEWS) do
                            local view = { x = v.x, y = v.y, scale = s }
                            bb_fill(A, 0x5A); bb_fill(B, 0xA5)
                            Scaler.render(A, ref_plane, view, full, mode)
                            local xs, ys = { 0, 13, 41, CW }, { 0, 7, 30, CH }
                            for i = 1, 3 do
                                for j = 1, 3 do
                                    Scaler.render(B, plane, view, { x = xs[i], y = ys[j],
                                        w = xs[i + 1] - xs[i], h = ys[j + 1] - ys[j] }, mode, lut)
                                end
                            end
                            local x, y = bb_diff(A, B)
                            if x then
                                A:free(); B:free()
                                return nil, string.format("view %d differs at %d,%d", vi, x, y)
                            end
                        end
                        A:free(); B:free()
                        return true
                    end)
                end
            end
        end
        per_channel:free(); as_grey:free()
    end

    check("remote_contrast_repaints_without_an_update", function()
        local Remote = require("vncoxide/framebuffer")
        local r = Remote.new(PW, PH)
        r.plane:blitFrom(plane, 0, 0, 0, 0, PW, PH)
        r:mark_dirty()
        local out = BB.new(CW, CH, BB.TYPE_BB8)
        r:fit_view(CW, CH)
        r:draw_to(out, 0, 0, CW, CH)
        if r:set_contrast(1) then return nil, "neutral again changes nothing" end
        r:draw_to(out, 0, 0, CW, CH)
        if r.last_recomputed_px ~= 0 then return nil, "nothing to recompute" end
        if not r:set_contrast(2) or r.contrast ~= 2 then return nil, "a new level is taken" end
        r:draw_to(out, 0, 0, CW, CH)
        if r.last_recomputed_px ~= CW * CH then
            return nil, "the whole canvas is redrawn from the plane, got " .. r.last_recomputed_px
        end
        local ref = BB.new(CW, CH, BB.TYPE_BB8)
        Scaler.render(ref, r.plane, r:_render_view(), { x = 0, y = 0, w = CW, h = CH }, r.scaling,
            Scaler.contrast_lut(2))
        if bb_diff(ref, out) then return nil, "drawn with the curve" end
        r:set_contrast(1)
        r:draw_to(out, 0, 0, CW, CH)
        Scaler.render(ref, r.plane, r:_render_view(), { x = 0, y = 0, w = CW, h = CH }, r.scaling)
        if r.renderer._lut ~= nil or bb_diff(ref, out) then return nil, "back to neutral: the plain picture" end
        out:free(); ref:free(); r:free()
        return true
    end)
    plane:free()
end

local function main()
    scaler_checks()
    contrast_checks()

    -- 1. DES against FIPS/NIST vectors (independent of the mock).
    check("des_vectors", function()
        local function hex2s(h)
            local t = {}
            for i = 1, #h, 2 do t[#t + 1] = string.char(tonumber(h:sub(i, i + 1), 16)) end
            return table.concat(t)
        end
        local function s2hex(s)
            return (s:gsub(".", function(c) return string.format("%02X", c:byte()) end))
        end
        local cases = {
            { "0101010101010101", "8000000000000000", "95F8A5E5DD31D900" },
            { "133457799BBCDFF1", "0123456789ABCDEF", "85E813540F0AB405" },
            { "0101010101010101", "0000000000000000", "8CA64DE9C1B123A7" },
            { "0E329232EA6D0D73", "8787878787878787", "0000000000000000" },
            { "FFFFFFFFFFFFFFFF", "FFFFFFFFFFFFFFFF", "7359B2163E4EDC58" },
        }
        for _, c in ipairs(cases) do
            local got = s2hex(Des.ecb_encrypt_block(hex2s(c[1]), hex2s(c[2])))
            if got ~= c[3] then
                return nil, string.format("DES(%s,%s)=%s want %s", c[1], c[2], got, c[3])
            end
        end
        return true
    end)

    -- 2. VNC Authentication bit reversal.
    check("bit_reverse", function()
        if Des.reverse_bits(0x01) ~= 0x80 then return nil, "reverse_bits(0x01) ~= 0x80" end
        if Des.reverse_bits(0xA5) ~= 0xA5 then return nil, "reverse_bits(0xA5) ~= 0xA5" end
        if Des.reverse_bits(0x00) ~= 0x00 then return nil, "reverse_bits(0x00) ~= 0" end
        return true
    end)

    -- 3. The pixel format we send must hit the wire in the documented byte order, and the
    --    encoding list must be the documented negotiation order.
    check("pxfmt_wire", function()
        local pid, port, log = start_mock{ name = "pxfmt", encoding = "raw", pattern = "gradient" }
        local ok, err = pcall(function()
            local r, e = run_case{
                port = port, want_updates = 1,
                on_connected = function(c, _, w, h) c.plane = BB.new(w, h, BB.TYPE_BBRGB24) end,
                body = function(proto, c) proto:request_update(0, 0, 0, c.fw, c.fh) end,
            }
            if not r then error(e) end
        end)
        stop_mock(pid)
        if not ok then return nil, err end
        if not wait_for_log(log, "INPUT SetPixelFormat bpp=32 red_shift=0 green_shift=8 blue_shift=16", 5) then
            return nil, "pixel format was not reported as bpp=32/LSB/shift 0,8,16:\n" .. (read_file(log) or "")
        end
        if not log_has(log, "INPUT SetEncodings 16,15,5,1,2,0,-223") then
            return nil, "SetEncodings order mismatch:\n" .. (read_file(log) or "")
        end
        return true
    end)

    -- 4. Security negotiation.
    check("handshake_none", function()
        local pid, port, log = start_mock{ name = "auth_none", encoding = "raw", pattern = "gradient", security = "none" }
        local ok, err = pcall(function()
            local r, e = run_case{
                port = port, want_updates = 1,
                on_connected = function(c, _, w, h) c.plane = BB.new(w, h, BB.TYPE_BBRGB24) end,
                body = function(proto, c) proto:request_update(0, 0, 0, c.fw, c.fh) end,
            }
            if not r then error(e) end
        end)
        stop_mock(pid)
        if not ok then return nil, err end
        if not wait_for_log(log, "AUTH ok", 5) then return nil, "no AUTH ok in mock log" end
        return true
    end)

    check("handshake_vnc", function()
        local pid, port, log = start_mock{
            name = "auth_vnc", encoding = "raw", pattern = "gradient",
            security = "vnc", password = "s3cret",
        }
        local ok, err = pcall(function()
            local r, e = run_case{
                port = port, password = "s3cret", want_updates = 1,
                on_connected = function(c, _, w, h) c.plane = BB.new(w, h, BB.TYPE_BBRGB24) end,
                body = function(proto, c) proto:request_update(0, 0, 0, c.fw, c.fh) end,
            }
            if not r then error(e) end
        end)
        stop_mock(pid)
        if not ok then return nil, err end
        if not wait_for_log(log, "AUTH ok", 5) then
            return nil, "VNC authentication was rejected (our DES does not match OpenSSL):\n" .. (read_file(log) or "")
        end
        return true
    end)

    check("handshake_vnc_wrong_password", function()
        local pid, port, log = start_mock{
            name = "auth_bad", encoding = "raw", pattern = "gradient",
            security = "vnc", password = "s3cret",
        }
        local ok, err = run_case{
            port = port, password = "wrong", want_updates = 1,
            on_connected = function(c, _, w, h) c.plane = BB.new(w, h, BB.TYPE_BBRGB24) end,
            body = function(proto, c) proto:request_update(0, 0, 0, c.fw, c.fh) end,
        }
        stop_mock(pid)
        if ok then return nil, "wrong password was accepted" end
        if not tostring(err):find("Authentication failure", 1, true) then
            return nil, "error does not mention the server's reason: " .. tostring(err)
        end
        return true
    end)

    check("handshake_vnc_without_password_says_so", function()
        -- x11vnc -rfbauth offers only VNC Authentication: a profile without a password used to be
        -- told "server offers no supported security type (offered: 2)"
        local pid, port = start_mock{
            name = "auth_nopw", encoding = "raw", pattern = "gradient",
            security = "vnc-only", password = "s3cret",
        }
        local ok, err = run_case{
            port = port, password = nil, want_updates = 1,
            on_connected = function(c, _, w, h) c.plane = BB.new(w, h, BB.TYPE_BBRGB24) end,
            body = function(proto, c) proto:request_update(0, 0, 0, c.fw, c.fh) end,
        }
        stop_mock(pid)
        if ok then return nil, "connected without a password" end
        if not tostring(err):find("password", 1, true) then
            return nil, "error does not say a password is needed: " .. tostring(err)
        end
        return true
    end)

    -- 5. Every encoding, pixel exact against the synthetic pattern.
    check("encodings_raw", function()
        return encoding_case("enc_raw", "raw", "gradient", expect_pattern)
    end)

    check("encodings_rre", function()
        return encoding_case("enc_rre", "rre", "gradient", expect_pattern)
    end)

    check("encodings_hextile", function()
        return encoding_case("enc_hextile", "hextile", "gradient", expect_pattern)
    end)

    check("encodings_hextile_quads", function()
        -- The quadrants pattern makes the Hextile background/foreground carry paths and the
        -- one-colour-per-tile cases fire as well.
        return encoding_case("enc_hextile_quads", "hextile", "quadrants", expect_pattern)
    end)

    check("encodings_trle", function()
        return encoding_case("enc_trle", "trle", "gradient", expect_pattern)
    end)

    check("encodings_trle_palette", function()
        -- 4 colours: exercises solid tiles, packed palettes (1/2/4 bit), palette reuse
        -- (127/129) and palette RLE (130+).
        return encoding_case("enc_trle_pal", "trle", "quadrants", expect_pattern)
    end)

    check("encodings_zrle", function()
        return encoding_case("enc_zrle", "zrle", "gradient", expect_pattern)
    end)

    check("encodings_zrle_palette", function()
        return encoding_case("enc_zrle_pal", "zrle", "quadrants", expect_pattern)
    end)

    -- The zlib streams take a pointer and a length: the decoders hand them memory straight out of
    -- the receive buffer, which is not a string and not cut to the payload.
    check("zstream_takes_pointer_and_length", function()
        local ZStream = require("vncoxide/zstream")
        local plain = ("pointer and length, "):rep(40)
        local src = ffi.new("uint8_t[?]", #plain + 8, 0xEE) -- junk around the input
        ffi.copy(src + 3, plain, #plain)
        local d = ZStream.new_deflate()
        local z = assert(d:deflate(src + 3, #plain))
        d:free()
        local buf = ffi.new("uint8_t[?]", #z + 16, 0xEE)
        ffi.copy(buf + 5, z, #z)
        local i = ZStream.new()
        local p, n = i:inflate_ptr(buf + 5, #z)
        if not p or ffi.string(p, n) ~= plain then return nil, "round trip: " .. tostring(n) end
        p, n = i:inflate_ptr(nil, 0) -- a bare drain
        if not p or n ~= 0 then return nil, "drain produced " .. tostring(n) end
        i:free()
        i = ZStream.new()
        p, n = i:inflate_ptr(buf + 5, #z, 10)
        i:free()
        if p or not tostring(n):match("exceeds") then return nil, "limit not enforced: " .. tostring(n) end
        return true
    end)

    -- Inflated ZRLE data that ends before its tiles do fails the rect with a message about the
    -- data (it used to read "encodings.lua:444: transport returned 21 bytes, wanted 32").
    check("zrle_short_inflated_data_reads_as_a_data_error", function()
        local ZStream = require("vncoxide/zstream")
        local Util = require("vncoxide/util")
        local d = ZStream.new_deflate()
        local z = assert(d:deflate("\0\1\2\3", 4)) -- a raw tile, 16 pixels short
        d:free()
        local plane = BB.new(4, 4, BB.TYPE_BBRGB24)
        local streams = Encodings.new_streams()
        local ok, err = pcall(Encodings.decode, { x = 0, y = 0, w = 4, h = 4, encoding = Encodings.ZRLE,
            r = Util.mem_reader(Util.writer():u32(#z):raw(z):tostring()), plane = plane,
            vp = plane:viewport(0, 0, 4, 4), streams = streams, fmt = PxFmt.for_depth(24) })
        Encodings.free_streams(streams)
        plane:free()
        if ok then return nil, "short data decoded" end
        err = tostring(err)
        if err:find("%.lua:%d") or err:find("transport", 1, true) then return nil, "unclear error: " .. err end
        if not err:find("data ends early", 1, true) then return nil, "unexpected error: " .. err end
        return true
    end)

    -- ZRLE and Tight (zlib and JPEG) payloads are consumed with reader:ptr, never as a string.
    check("zrle_and_tight_payloads_never_become_strings", function()
        local ZStream = require("vncoxide/zstream")
        local Util = require("vncoxide/util")
        local function deflated(raw)
            local d = ZStream.new_deflate()
            local z = assert(d:deflate(raw, #raw))
            d:free()
            return z
        end
        local function compact(len)
            if len < 128 then return string.char(len) end
            return string.char(bit.bor(bit.band(len, 127), 128), bit.rshift(len, 7))
        end
        local f = assert(io.open(tools_dir .. "/tight_jpeg.b64"))
        local b64 = f:read("*a"):gsub("#[^\n]*\n", ""):gsub("%s", "")
        f:close()
        local jpeg = require("ffi/sha2").base64_to_bin(b64)
        local zrle = deflated(string.char(1, 10, 20, 30)) -- one solid tile
        local copy = deflated(("\100\150\200"):rep(16))
        local cases = {
            { "ZRLE", Encodings.ZRLE, 4, 4, Util.writer():u32(#zrle):raw(zrle):tostring(), { 10, 20, 30 } },
            { "Tight zlib", Encodings.TIGHT, 4, 4, "\0" .. compact(#copy) .. copy, { 100, 150, 200 } },
            { "Tight JPEG", Encodings.TIGHT, 32, 32, "\144" .. compact(#jpeg) .. jpeg, { 199, 40, 120 } },
        }
        for _, c in ipairs(cases) do
            local plane = BB.new(c[3], c[4], BB.TYPE_BBRGB24)
            local r = Util.mem_reader(c[5])
            r.bytes = function() error("reader:bytes() on the " .. c[1] .. " payload") end
            local streams = Encodings.new_streams()
            local ok, err = Encodings.decode{ x = 0, y = 0, w = c[3], h = c[4], encoding = c[2], r = r,
                plane = plane, vp = plane:viewport(0, 0, c[3], c[4]), streams = streams,
                fmt = PxFmt.for_depth(24) }
            Encodings.free_streams(streams)
            if not ok then return nil, c[1] .. ": " .. tostring(err) end
            local px = ffi.cast("uint8_t*", plane.data)
            for k = 1, 3 do
                if math.abs(px[k - 1] - c[6][k]) > 2 then
                    return nil, string.format("%s: channel %d is %d, want %d", c[1], k, px[k - 1], c[6][k])
                end
            end
            if r:remaining() ~= 0 then return nil, c[1] .. ": " .. r:remaining() .. " bytes left" end
        end
        return true
    end)

    check("encodings_copyrect", function()
        -- The mock fills the left part as Raw, then CopyRect-shifts it right by 64 pixels
        -- with an overlapping source. Expected image: pattern(x, y) for x < 64, else
        -- pattern(x - 64, y).
        local function expect(pat, fw, fh)
            return function(x, y)
                if x < 64 then return pattern_pixel(pat, x, y, fw, fh) end
                return pattern_pixel(pat, x - 64, y, fw, fh)
            end
        end
        return encoding_case("enc_copyrect", "copyrect", "gradient", expect)
    end)

    check("encodings_tight", function()
        local jx, jy, jw, jh = 8, 8, 32, 32
        local jr, jg, jb = 199, 40, 120
        local function expect(pat, fw, fh)
            return function(x, y)
                if x >= jx and x < jx + jw and y >= jy and y < jy + jh then return nil end
                return pattern_pixel(pat, x, y, fw, fh)
            end
        end
        return encoding_case("enc_tight", "tight", "gradient", expect, {
            enable_tight = true,
            post = function(ctx)
                -- The JPEG rect is lossy: check it only loosely.
                local base = ffi.cast("uint8_t*", ctx.plane.data)
                for y = jy, jy + jh - 1 do
                    for x = jx, jx + jw - 1 do
                        local p = base + y * ctx.plane.stride + x * 3
                        if math.abs(p[0] - jr) > 8 or math.abs(p[1] - jg) > 8 or math.abs(p[2] - jb) > 8 then
                            return nil, string.format(
                                "JPEG rect pixel (%d,%d) is (%d,%d,%d), expected ~(%d,%d,%d)",
                                x, y, p[0], p[1], p[2], jr, jg, jb)
                        end
                    end
                end
                return true
            end,
        })
    end)

    check("encodings_order_quality", function()
        local function same(a, b)
            if #a ~= #b then return false end
            for i = 1, #a do if a[i] ~= b[i] then return false end end
            return true
        end
        local t = Encodings.order(true, { jpeg_quality = 5, compress_level = 9 })
        if t[#t] ~= -247 or t[#t - 1] ~= -27 then
            return nil, "tight order does not end with -27,-247"
        end
        if not same(Encodings.order(false, { jpeg_quality = 5 }), Encodings.ORDER_DEFAULT) then
            return nil, "non-tight order must equal ORDER_DEFAULT"
        end
        if not same(Encodings.order(true), Encodings.ORDER_TIGHT) then
            return nil, "order(true) must equal ORDER_TIGHT"
        end
        if not same(Encodings.order(true, { jpeg_quality = false, compress_level = false }),
                    Encodings.ORDER_TIGHT) then
            return nil, "false options must add nothing"
        end
        if Encodings.order(true) == Encodings.ORDER_TIGHT then
            return nil, "order must return a fresh table"
        end
        return true
    end)

    check("encodings_quality_wire", function()
        return encoding_case("enc_quality", "tight", "gradient", function() return nil end, {
            encodings = Encodings.order(true, { jpeg_quality = 5, compress_level = 9 }),
            check = false,
            verify_log = function(log)
                if not log_has(log, "INPUT SetEncodings 7,16,15,5,1,2,0,-223,-27,-247") then
                    return nil, "SetEncodings mismatch:\n" .. (read_file(log) or "")
                end
                return true
            end,
        })
    end)

    -- Decoder edge and error paths: packed palette tiles, Hextile/RRE malformed or cut streams.
    local function decode_raw(enc, w, h, data, depth, wrap)
        local Util = require("vncoxide/util")
        local plane = BB.new(w, h, BB.TYPE_BBRGB24)
        local streams = Encodings.new_streams()
        local ok, res = pcall(Encodings.decode, { x = 0, y = 0, w = w, h = h, encoding = enc,
            r = Util.mem_reader(wrap and wrap(data) or data), plane = plane,
            vp = plane:viewport(0, 0, w, h), streams = streams, fmt = PxFmt.for_depth(depth or 24) })
        Encodings.free_streams(streams)
        return ok and res or nil, plane
    end

    local function packed_palette_case(enc, wrap)
        math.randomseed(7)
        for _ = 1, 300 do
            local w, h, ps = math.random(1, 16), math.random(1, 16), math.random(2, 16)
            local bpp = ps == 2 and 1 or (ps <= 4 and 2 or 4)
            local rb = bit.rshift(w * bpp + 7, 3)
            local pal, t = {}, { string.char(ps) }
            for i = 0, ps - 1 do
                pal[i] = { math.random(0, 255), math.random(0, 255), math.random(0, 255) }
                t[#t + 1] = string.char(pal[i][1], pal[i][2], pal[i][3])
            end
            local inject = math.random() < 0.3 and ps < bit.lshift(1, bpp)
            local idx, expbad = {}, false
            for y = 0, h - 1 do
                local bytes = {}
                for b = 0, rb - 1 do bytes[b] = 0 end
                idx[y] = {}
                for x = 0, w - 1 do
                    local v = math.random(0, ps - 1)
                    if inject and math.random() < 0.05 then
                        v = math.random(ps, bit.lshift(1, bpp) - 1)
                        expbad = true
                    end
                    idx[y][x] = v
                    local bp = x * bpp
                    local bi = bit.rshift(bp, 3)
                    bytes[bi] = bit.bor(bytes[bi], bit.lshift(v, 8 - bpp - bit.band(bp, 7)))
                end
                local used = w * bpp % 8 -- random padding bits must be ignored
                if used > 0 then
                    bytes[rb - 1] = bit.bor(bytes[rb - 1], bit.band(math.random(0, 255), bit.lshift(1, 8 - used) - 1))
                end
                for b = 0, rb - 1 do t[#t + 1] = string.char(bytes[b]) end
            end
            local ok, plane = decode_raw(enc, w, h, table.concat(t), 24, wrap)
            local what = string.format("%dx%d palette %d", w, h, ps)
            if expbad then
                plane:free()
                if ok then return nil, "bad palette index accepted: " .. what end
            else
                if not ok then plane:free(); return nil, "valid tile rejected: " .. what end
                for y = 0, h - 1 do
                    for x = 0, w - 1 do
                        local c, p = pal[idx[y][x]], plane:getPixel(x, y)
                        if p:getR() ~= c[1] or p:getG() ~= c[2] or p:getB() ~= c[3] then
                            plane:free(); return nil, string.format("%s: pixel %d,%d wrong", what, x, y)
                        end
                    end
                end
                plane:free()
            end
        end
        return true
    end

    check("encodings_trle_packed_palette_tiles", function()
        return packed_palette_case(Encodings.TRLE)
    end)

    check("encodings_zrle_packed_palette_tiles", function()
        local ZStream = require("vncoxide/zstream")
        local Util = require("vncoxide/util")
        return packed_palette_case(Encodings.ZRLE, function(data)
            local d = ZStream.new_deflate()
            local z = assert(d:deflate(data, #data))
            d:free()
            return Util.writer():u32(#z):raw(z):tostring()
        end)
    end)

    check("encodings_hextile_malformed_tiles_error", function()
        local p = "\7\7\7\7"
        for name, data in pairs({
            ["no background"] = string.char(0x08) .. string.char(0),
            ["fg with coloured"] = string.char(2 + 4 + 8 + 16) .. p .. p .. string.char(1) .. p .. "\0\0",
            ["subrect without fg"] = string.char(2 + 8) .. p .. string.char(1, 0),
        }) do
            local ok, plane = decode_raw(Encodings.HEXTILE, 16, 16, data)
            plane:free()
            if ok then return nil, name .. " accepted" end
        end
        return true
    end)

    check("encodings_hextile_and_rre_cut_streams_error", function()
        local Util = require("vncoxide/util")
        for _, d in ipairs({ 8, 16, 24 }) do
            local nb = d == 24 and 4 or d / 8
            local px = string.rep("\7", nb)
            -- 20x20 = 4 tiles: bg+fg+2 subrects; bg+coloured(3); carried bg with count 0; bg only
            local hx = string.char(2 + 4 + 8) .. px .. px .. string.char(2, 0x00, 0xFF, 0x34, 0x21)
                .. string.char(2 + 8 + 16) .. px .. string.char(3) .. px .. string.char(0x11, 0x22)
                .. px .. string.char(0xFF, 0xFF) .. px .. string.char(0xE0, 0x0F)
                .. string.char(8 + 16) .. string.char(0)
                .. string.char(2) .. px
            local ok, plane = decode_raw(Encodings.HEXTILE, 20, 20, hx, d)
            plane:free()
            if not ok then return nil, d .. " bpp: full hextile stream rejected" end
            local rre = Util.writer():u32(3):tostring() .. string.rep("\1", nb)
            for _ = 1, 3 do rre = rre .. string.rep("\2", nb) .. string.char(0, 1, 0, 2, 0xFF, 0xFF, 0, 3) end
            ok, plane = decode_raw(Encodings.RRE, 20, 20, rre, d)
            plane:free()
            if not ok then return nil, d .. " bpp: full RRE stream rejected" end
            for k = 0, #hx - 1 do
                ok, plane = decode_raw(Encodings.HEXTILE, 20, 20, hx:sub(1, k), d)
                plane:free()
                if ok then return nil, string.format("hextile %d bpp cut at %d decoded", d, k) end
            end
            for k = 0, #rre - 1 do
                ok, plane = decode_raw(Encodings.RRE, 20, 20, rre:sub(1, k), d)
                plane:free()
                if ok then return nil, string.format("RRE %d bpp cut at %d decoded", d, k) end
            end
        end
        return true
    end)

    check("encodings_tight_no_zlib_with_explicit_filter", function()
        -- libvncserver at compression level 0 sends mono/indexed rects as control 0x0E: "no zlib"
        -- plus an explicit (palette) filter; small data comes inline, larger with a compact length
        local Util = require("vncoxide/util")
        local pal = "\255\0\0" .. "\0\0\255" -- red, blue (24-bit TPIXELs)
        for _, c in ipairs({
            { w = 8, h = 2, data = "\240\015", bits = "\240\015" },     -- 2 bytes: inline
            { w = 16, h = 8, data = "\016" .. string.rep("\240\015", 8),  -- 16 bytes: length 16
              bits = string.rep("\240\015", 8) },
        }) do
            local plane = BB.new(c.w, c.h, BB.TYPE_BBRGB24)
            local bytes = "\224\001\001" .. pal .. c.data -- 0xE0, filter 1, 2 colours
            local r = Util.mem_reader(bytes)
            local ok, err = Encodings.decode({ x = 0, y = 0, w = c.w, h = c.h, encoding = Encodings.TIGHT,
                r = r, plane = plane, vp = plane:viewport(0, 0, c.w, c.h), streams = Encodings.new_streams() })
            if not ok then plane:free(); return nil, err end
            if r:remaining() ~= 0 then plane:free(); return nil, "left " .. r:remaining() .. " bytes unread" end
            for y = 0, c.h - 1 do
                for x = 0, c.w - 1 do
                    local p = plane:getPixel(x, y)
                    -- a set bit is palette entry 1 (blue); rows are padded to whole bytes
                    local byte = c.bits:byte(y * math.ceil(c.w / 8) + math.floor(x / 8) + 1)
                    local red = math.floor(byte / 2 ^ (7 - x % 8)) % 2 == 0
                    if (red and (p:getR() ~= 255 or p:getB() ~= 0)) or (not red and (p:getR() ~= 0 or p:getB() ~= 255)) then
                        plane:free(); return nil, string.format("%dx%d: pixel %d,%d wrong", c.w, c.h, x, y)
                    end
                end
            end
            plane:free()
        end
        return true
    end)

    check("encodings_tight_quads", function()
        -- Quadrants: triggers the Tight fill subencoding and the 1-bit palette path.
        return encoding_case("enc_tight_quads", "tight", "quadrants", expect_pattern, {
            enable_tight = true,
            check = false,
            post = function(ctx)
                -- The JPEG rect is overwritten last, so just check that the JPEG rect matches
                -- loosely and everything else matches exactly.
                local base = ffi.cast("uint8_t*", ctx.plane.data)
                for y = 0, ctx.fh - 1 do
                    for x = 0, ctx.fw - 1 do
                        local p = base + y * ctx.plane.stride + x * 3
                        if x >= 8 and x < 40 and y >= 8 and y < 40 then
                            if math.abs(p[0] - 199) > 8 or math.abs(p[1] - 40) > 8 or math.abs(p[2] - 120) > 8 then
                                return nil, string.format("JPEG rect pixel (%d,%d) is (%d,%d,%d)", x, y, p[0], p[1], p[2])
                            end
                        else
                            local er, eg, eb = pattern_pixel("quadrants", x, y, ctx.fw, ctx.fh)
                            if p[0] ~= er or p[1] ~= eg or p[2] ~= eb then
                                return nil, string.format("pixel (%d,%d) is (%d,%d,%d), expected (%d,%d,%d)",
                                    x, y, p[0], p[1], p[2], er, eg, eb)
                            end
                        end
                    end
                end
                return true
            end,
        })
    end)

    check("encodings_mixed", function()
        return encoding_case("enc_mixed", "mixed", "gradient", expect_pattern)
    end)

    -- 5b. The same encodings at the 16- and 8-bit client pixel formats. The mock skips the
    --     Tight JPEG rect below 32 bpp (servers only send JPEG at 32 bpp), so Tight is pixel
    --     exact here.
    local function copyrect_expect(pat, fw, fh)
        return function(x, y)
            if x < 64 then return pattern_pixel(pat, x, y, fw, fh) end
            return pattern_pixel(pat, x - 64, y, fw, fh)
        end
    end
    check("pxfmt_for_depth", function()
        local f24, unk = PxFmt.for_depth(24), PxFmt.for_depth(12)
        for k, v in pairs(PxFmt.PIXEL_FORMAT) do
            if f24[k] ~= v or unk[k] ~= v then
                return nil, string.format("%s: depth 24 %s, unknown depth %s, want %s",
                    k, tostring(f24[k]), tostring(unk[k]), tostring(v))
            end
        end
        if f24.bytes ~= 4 or f24.cbytes ~= 3 then return nil, "depth 24 sizes" end
        if f24 == PxFmt.for_depth(24) then return nil, "for_depth must return a fresh table" end
        local f16, f8 = PxFmt.for_depth(16), PxFmt.for_depth(8)
        if f16.bytes ~= 2 or f16.cbytes ~= 2 or f8.bytes ~= 1 or f8.cbytes ~= 1 then
            return nil, "16/8-bit sizes"
        end
        -- RGB565 LE 0xF81F = pure red + pure blue; BGR233 0xC7 = red 7, green 0, blue 3.
        local r, g, b = PxFmt.unpack(f16, "\x1F\xF8", 0, 2)
        if r ~= 255 or g ~= 0 or b ~= 255 then return nil, string.format("565: %d,%d,%d", r, g, b) end
        r, g, b = PxFmt.unpack(f8, "x\xC7", 1, 1)
        if r ~= 255 or g ~= 0 or b ~= 255 then return nil, string.format("233: %d,%d,%d", r, g, b) end
        return true
    end)
    for _, depth in ipairs({ 16, 8 }) do
        local fmt = PxFmt.for_depth(depth)
        check("pxfmt_wire_" .. depth, function()
            local want = ({
                [16] = "INPUT SetPixelFormat bpp=16 red_shift=11 green_shift=5 blue_shift=0",
                [8] = "INPUT SetPixelFormat bpp=8 red_shift=0 green_shift=3 blue_shift=6",
            })[depth]
            return encoding_case("pxfmt_" .. depth, "raw", "gradient", expect_quantized(fmt), {
                pixel_format = fmt,
                verify_log = function(log)
                    if not wait_for_log(log, want, 5) then
                        return nil, "missing " .. want .. ":\n" .. (read_file(log) or "")
                    end
                    return true
                end,
            })
        end)
        local cases = {
            { "raw", "raw", "gradient" },
            { "copyrect", "copyrect", "gradient", copyrect_expect },
            { "rre", "rre", "gradient" },
            { "hextile", "hextile", "gradient" },
            { "hextile_quads", "hextile", "quadrants" },
            { "trle", "trle", "gradient" },
            { "trle_pal", "trle", "quadrants" },
            { "zrle", "zrle", "gradient" },
            { "zrle_pal", "zrle", "quadrants" },
            { "tight", "tight", "gradient", nil, true },
            { "tight_quads", "tight", "quadrants", nil, true },
            { "mixed", "mixed", "gradient", nil, true },
        }
        for _, c in ipairs(cases) do
            local name = string.format("enc_%s_%d", c[1], depth)
            check(name, function()
                return encoding_case(name, c[2], c[3], expect_quantized(fmt, c[4]), {
                    pixel_format = fmt, enable_tight = c[5],
                })
            end)
        end
    end

    -- 6. ZRLE stream continuity: many successive rectangles through one zlib stream.
    check("zrle_stream_continuity", function()
        local pattern = "gradient"
        local ok, err = encoding_case("zrle_cont", "zrle", pattern, expect_pattern, {
            width = 160, height = 120, repaint = 0.05, want_updates = 6,
            -- Validate every intermediate state, not just the last one: each update must
            -- leave the whole plane equal to the pattern (the mock repaints correct pixels).
            on_update = function(ctx)
                return check_plane(ctx.plane, ctx.fw, ctx.fh, expect_pattern(pattern, ctx.fw, ctx.fh))
            end,
            post = function(ctx)
                if ctx.updates < 6 then
                    return nil, string.format("only %d updates seen, wanted >= 6", ctx.updates)
                end
                if ctx.rects < 6 then
                    return nil, string.format("only %d rects decoded, wanted >= 6", ctx.rects)
                end
                return true
            end,
        })
        return ok, err
    end)

    -- 7. DesktopSize: the plane is reallocated and a non-incremental request follows.
    check("desktop_resize", function()
        local nw, nh = 200 + 32, 150 + 16
        local ok, err = encoding_case("resize", "raw", "gradient", expect_pattern, {
            resize_after = 1, want_updates = 2,
            on_resize = function(ctx, w, h, proto)
                -- What the session will do: reallocate the plane and resynchronise with a
                -- non-incremental request for the whole new area.
                if ctx.plane then ctx.plane:free() end
                ctx.plane = BB.new(w, h, BB.TYPE_BBRGB24)
                proto:request_update(0, 0, 0, w, h)
            end,
            after_request = nil,
            post = function(ctx, log)
                if #ctx.resizes ~= 1 or ctx.resizes[1].w ~= nw or ctx.resizes[1].h ~= nh then
                    local parts = {}
                    for _, r in ipairs(ctx.resizes) do
                        parts[#parts + 1] = string.format("%dx%d", r.w, r.h)
                    end
                    return nil, string.format("resize callbacks: [%s]", table.concat(parts, ", "))
                end
                local needle = string.format("INPUT FramebufferUpdateRequest incremental=0 x=0 y=0 w=%d h=%d", nw, nh)
                if not wait_for_log(log, needle, 5) then
                    return nil, "no non-incremental full request for the new size (" .. needle .. ")"
                end
                return true
            end,
        })
        return ok, err
    end)

    -- 8. Client input messages reach the server byte-for-byte.
    check("input_messages", function()
        local pid, port, log = start_mock{ name = "input", encoding = "raw", pattern = "gradient" }
        local ok, err = run_case{
            port = port, want_updates = 0, stop_after_body = true,
            on_connected = function(c, _, w, h) c.plane = BB.new(w, h, BB.TYPE_BBRGB24) end,
            body = function(proto)
                proto:send_pointer(300, 200, 1)
                proto:send_key(Keysyms.special.Press, true)
                proto:send_key(Keysyms.special.Press, false)
                -- URI/Dispatcher callers hand us strings: "0" must be a release, not a press
                proto:send_key(Keysyms.special.Press, "1")
                proto:send_key(Keysyms.special.Press, "0")
                proto:send_key(Keysyms.special.Press, 0)
                proto:send_cut_text("hello")
                return true
            end,
        }
        if not ok then stop_mock(pid); return nil, err end
        local want = {
            "INPUT PointerEvent mask=1 x=300 y=200",
            "INPUT KeyEvent down=1 keysym=0xff0d",
            "INPUT KeyEvent down=0 keysym=0xff0d",
            "INPUT ClientCutText len=5",
        }
        for _, needle in ipairs(want) do
            if not wait_for_log(log, needle, 5) then
                stop_mock(pid)
                return nil, "missing log line " .. needle .. "\n" .. (read_file(log) or "")
            end
        end
        stop_mock(pid)
        -- down: true, "1"; up: false, "0", 0
        local downs = log_count(log, "INPUT KeyEvent down=1 keysym=0xff0d")
        local ups = log_count(log, "INPUT KeyEvent down=0 keysym=0xff0d")
        if downs ~= 2 or ups ~= 3 then
            return nil, string.format(
                "key press/release counts: %d down, %d up (wanted 2/3); '0' must not mean down",
                downs, ups)
        end
        return true
    end)

    -- 9. A rectangle with an encoding we never advertised is fatal, with the encoding number.
    check("unsupported_encoding", function()
        local w = require("vncoxide/util").writer()
        w:raw("RFB 003.008\n")
        w:u8(1); w:u8(1)                          -- one security type: None
        w:u32(0)                                  -- SecurityResult: OK
        w:u16(8); w:u16(8)                        -- ServerInit
        local pf = PxFmt.PIXEL_FORMAT
        w:u8(pf.bits_per_pixel); w:u8(pf.depth); w:u8(pf.big_endian); w:u8(pf.true_colour)
        w:u16(pf.red_max); w:u16(pf.green_max); w:u16(pf.blue_max)
        w:u8(pf.red_shift); w:u8(pf.green_shift); w:u8(pf.blue_shift)
        w:u8(0); w:u8(0); w:u8(0)
        w:u32(0)
        w:u8(0); w:u8(0); w:u16(1)                -- FramebufferUpdate, 1 rect
        w:u16(0); w:u16(0); w:u16(4); w:u16(4); w:u32(6) -- encoding 6
        local plane = BB.new(8, 8, BB.TYPE_BBRGB24)
        local ok, err = run_mem(w:tostring(), {
            plane = plane,
            callbacks = { on_connected = function() end },
        })
        plane:free()
        if ok then return nil, "encoding 6 was accepted" end
        if err ~= "unsupported encoding 6" then
            return nil, "error was " .. tostring(err) .. ", wanted \"unsupported encoding 6\""
        end
        return true
    end)

    -- 10. A client message that a timed-out `send` only partly wrote: LuaSocket reports the
    -- bytes it did put on the wire as the *third* return value, so a queue that ignores it
    -- re-sends them on the next attempt, duplicating the prefix of every message.
    check("session_send_partial_progress", function()
        local Session = load_session()
        -- A socket that behaves like LuaSocket's: it writes what its buffer has room for and
        -- then reports `nil, "timeout", last_index_written`.
        local sock = { sent = "", room = 7 }
        function sock:send(data, i)
            i = i or 1
            if self.room <= 0 then return nil, "timeout", i - 1 end
            local n = math.min(self.room, #data - i + 1)
            self.sent = self.sent .. data:sub(i, i + n - 1)
            self.room = self.room - n
            local last = i + n - 1
            if self.room > 0 then return last end
            return nil, "timeout", last
        end

        local s = setmetatable({ tx = { "AAAAABBBBB", "CC" }, sock = sock }, Session)
        local ok, err = s:_flush_tx()
        if not ok then return nil, "flush failed: " .. tostring(err) end
        if s.tx[1] ~= "BBB" or #s.tx ~= 2 then
            return nil, string.format(
                "after a partial send the queue is {%s, ...} (%d frames), wanted {\"BBB\", \"CC\"}",
                tostring(s.tx[1]), #s.tx)
        end
        while #s.tx > 0 do
            sock.room = 7
            local ok2, err2 = s:_flush_tx()
            if not ok2 then return nil, "drain failed: " .. tostring(err2) end
        end
        if sock.sent ~= "AAAAABBBBBCC" then
            return nil, string.format("wire carried %q, wanted every byte exactly once (%q)",
                sock.sent, "AAAAABBBBBCC")
        end
        return true
    end)

    -- (worker mode: the decode worker decodes the split stream into the shared plane)
    local function split_workers()
        local env = proxy_env()
        local s, mpid
        local ok, err = pcall(function()
            local W, H = 32, 24
            s, mpid = proxy_session(env, "split_w", { encoding = "raw", pattern = "gradient",
                width = W, height = H, split = 16 })
            local remote = s:get_remote()
            local target = BB.new(W, H, BB.TYPE_BB8)
            remote:draw_to(target, 0, 0, W, H, false)
            local app = proxy_app()
            s:attach(app)
            local bad
            local done = env.run_until(function()
                local good, why = check_plane(remote:get_plane(), W, H, expect_pattern("gradient", W, H))
                bad = why
                return good and app.dirty[1] ~= nil
            end, 20)
            target:free()
            if not done then
                error(bad or "rectangle decoded but the app was not told the canvas changed")
            end
        end)
        if s then s:disconnect() end
        env.finish()
        stop_mock(mpid)
        if not ok then return nil, err end
        return true
    end

    -- A connect tick whose pump runs out of budget (bytes, CPU or steps) in the very step that
    -- completes the handshake: the session is "connected" then, and the attempt must still finish
    -- (the callback, the workers) instead of stalling in the handshake phase with no tick left.
    -- One step per pump makes that happen on every step; a slow device gets there by the CPU budget.
    both_modes("session_connect_finishes_when_the_budget_ends_with_the_handshake", function()
        local Session = load_session()
        local pid, port = start_mock{ name = "budget_hs", encoding = "raw", pattern = "gradient",
            width = 32, height = 24 }
        local s = Session.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "budget_hs" },
            network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() end },
        }
        local real_steps = Session.MAX_STEPS_PER_TICK
        Session.MAX_STEPS_PER_TICK = 1
        local connected, cerr
        local pok, perr = pcall(connect_sync, s, function(ok, err) connected, cerr = ok, err end)
        Session.MAX_STEPS_PER_TICK = real_steps
        local ok, err = true, nil
        if not pok then
            ok, err = nil, perr
        elseif connected == nil then
            ok, err = nil, string.format("the connect callback never ran (state %s, phase %s)",
                tostring(s.state), tostring(s._phase))
        elseif not connected then
            ok, err = nil, "connect failed: " .. tostring(cerr)
        end
        s:disconnect()
        stop_mock(pid)
        return ok, err
    end, function()
        local Session = load_session()
        local env = proxy_env()
        local s, mpid
        local real_steps = Session.MAX_STEPS_PER_TICK
        Session.MAX_STEPS_PER_TICK = 1
        local ok, err = pcall(function()
            s, mpid = proxy_session(env, "budget_hs_w", { encoding = "raw", pattern = "gradient",
                width = 32, height = 24 })
        end)
        Session.MAX_STEPS_PER_TICK = real_steps
        if s then s:disconnect() end
        env.finish()
        stop_mock(mpid)
        if not ok then return nil, err end
        return true
    end)

    -- 11. A server message that arrives split across TCP segments: the transport keeps the
    -- partial reads and resumes, and the protocol decodes the message once the rest arrives.
    -- (The mock writes every message in small chunks, with a pause between them, so the reads
    -- between the chunks really do time out.)
    both_modes("session_split_server_message", function()
        local Session = load_session()
        local W, H = 32, 24
        local pid, port = start_mock{
            name = "split", encoding = "raw", pattern = "gradient",
            width = W, height = H, split = 16,
        }
        local s = Session.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "split" },
            network_mgr = {
                isWifiOn = function() return true end,
                turnOffWifi = function() end,
            },
        }
        local connected, cerr
        connect_sync(s, function(ok, err) connected, cerr = ok, err end)
        if not connected then
            stop_mock(pid)
            return nil, "connect failed: " .. tostring(cerr)
        end

        local dirty_seen = false
        s.app = {
            on_framebuffer_dirty = function() dirty_seen = true end,
            on_remote_resized = function() end,
            on_bell = function() end,
        }
        s:request_full_update()
        s:_flush_now()

        local deadline = os.time() + 20
        local stopped = false
        while not s.dirty and os.time() < deadline do
            if s:_pump() == "error" then
                stopped = true
                break
            end
            socket.sleep(0.01)
        end
        local ok, err = true, nil
        if stopped then
            ok, err = nil, "pump failed: " .. tostring(s:get_error())
        elseif not s.dirty then
            ok, err = nil, "no rectangle decoded from the split update"
        else
            local cok, cerr2 = check_plane(s.remote:get_plane(), W, H, expect_pattern("gradient", W, H))
            if not cok then ok, err = nil, cerr2 end
        end
        if ok then
            -- What the poll task does with the accumulated rect; the UI is the consumer.
            s.attached = true
            s:_poll()
            s.attached = false
            if not dirty_seen then
                ok, err = nil, "rectangle decoded but the app was not told it is dirty"
            end
        end
        s:disconnect()
        stop_mock(pid)
        return ok, err
    end, split_workers)

    -- 12. The same partial write over a real socket: a message larger than the send buffer,
    -- flushed in one go, must not be duplicated. SO_SNDBUF is shrunk so the write really is
    -- split; if it cannot be shrunk the check fails instead of passing vacuously.
    check("session_send_partial_end_to_end", function()
        local Session = load_session()
        ffi.cdef[[
            int setsockopt(int fd, int level, int optname, const void *optval, unsigned int optlen);
            int getsockopt(int fd, int level, int optname, void *optval, unsigned int *optlen);
        ]]
        local SOL_SOCKET, SO_SNDBUF = 1, 7 -- Linux socket ABI
        local payload = 200000
        local pid, port, log = start_mock{
            name = "bigsend", encoding = "raw", pattern = "gradient", width = 32, height = 24,
        }
        local s = Session.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "bigsend" },
            network_mgr = {
                isWifiOn = function() return true end,
                turnOffWifi = function() end,
            },
        }
        local connected, cerr
        connect_sync(s, function(ok, err) connected, cerr = ok, err end)
        if not connected then
            stop_mock(pid)
            return nil, "connect failed: " .. tostring(cerr)
        end

        local function done(ok, err)
            s:disconnect()
            stop_mock(pid)
            return ok, err
        end

        local fd = s.sock:getfd()
        local want = ffi.new("int[1]", 4096)
        if ffi.C.setsockopt(fd, SOL_SOCKET, SO_SNDBUF, want, 4) ~= 0 then
            return done(nil, "could not shrink SO_SNDBUF")
        end
        local got, gotlen = ffi.new("int[1]"), ffi.new("unsigned int[1]", 4)
        ffi.C.getsockopt(fd, SOL_SOCKET, SO_SNDBUF, got, gotlen)
        if got[0] >= payload then
            return done(nil, string.format(
                "send buffer is %d bytes, too large to force a partial send", got[0]))
        end

        s:send_cut_text(string.rep("Z", payload))
        local deadline = os.time() + 20
        while #s.tx > 0 and os.time() < deadline do
            s:_flush_now()
            socket.sleep(0.005)
        end
        if s:get_state() == "error" then
            return done(nil, "session failed: " .. tostring(s:get_error()))
        end
        if #s.tx > 0 then
            return done(nil, string.format(
                "queue never drained (%d bytes left) - the timed-out send's progress was lost",
                #s.tx[1]))
        end

        s:send_pointer(7, 9, 1)
        local ok, err = nil, "the mock never saw the pointer event"
        for _ = 1, 200 do
            s:_flush_now()
            if log_has(log, "INPUT PointerEvent mask=1 x=7 y=9") then ok, err = true, nil break end
            socket.sleep(0.02)
        end
        if ok and not log_has(log, string.format("INPUT ClientCutText len=%d", payload)) then
            ok, err = nil, "the mock never saw the cut text"
        end
        if ok and log_has(log, "ERROR") then
            ok, err = nil, "the mock read the client stream out of frame"
        end
        return done(ok, err)
    end)

    -- A combo sent in one burst (the Send keys panel's Alt+Tab) left openbox's window switcher open
    -- behind a real x11vnc: the Alt release reached the X server before the WM had grabbed the
    -- keyboard for the Tab. A modifier release right after another input event waits
    -- MODIFIER_RELEASE_GAP; nothing else waits.
    check("session_modifier_release_after_input_waits_a_gap", function()
        local Session = load_session()
        local real_now, real_sleep, clock = Session._now, Session._sleep, 100
        local sent, slept = {}, {}
        Session._now = function() return clock end
        Session._sleep = function(d) slept[#slept + 1] = d; clock = clock + d end
        local s = Session.new{ profile = { host = "h", port = 1, name = "gap" },
            network_mgr = { isWifiOn = function() return true end } }
        s._phase = nil
        s.proto = {
            send_key = function(_, k, d) sent[#sent + 1] = { t = clock, what = (d and "+" or "-") .. string.format("%X", k) } end,
            send_pointer = function(_, x, y, m) sent[#sent + 1] = { t = clock, what = "p" .. m } end,
        }
        local function restore() Session._now, Session._sleep = real_now, real_sleep end
        local ok, err = pcall(function()
            -- Alt+Tab in one burst
            s:send_key(0xFFE9, true); s:send_key(0xFF09, true); s:send_key(0xFF09, false); s:send_key(0xFFE9, false)
            assert(#slept == 1, "one gap expected, got " .. #slept)
            assert(sent[4].what == "-FFE9" and sent[4].t - sent[3].t >= Session.MODIFIER_RELEASE_GAP,
                "the Alt release must come MODIFIER_RELEASE_GAP after the Tab release")
            -- plain typing and a modifier released long after: no gap
            sent, slept = {}, {}
            s:send_key(0x61, true); s:send_key(0x61, false)
            s:send_key(0xFFE1, true); clock = clock + 1; s:send_key(0xFFE1, false)
            assert(#slept == 0, "no gap for plain keys or a late release, got " .. #slept)
            -- Shift+click: the Shift release after the button release waits too
            s:send_key(0xFFE1, true); s:send_pointer(5, 5, 1); s:send_pointer(5, 5, 0); s:send_key(0xFFE1, false)
            assert(#slept == 1, "Shift after a click must wait, got " .. #slept)
        end)
        restore()
        if not ok then return nil, tostring(err) end
        return true
    end)

    -- A held key's repeats (the on-screen Backspace's) are not typing: they do not hold the update
    -- request, or the screen would stay still for the whole hold and jump at the lift. The first
    -- press holds it as usual. Worker mode: the UI marks them "r" on the K line, the decode worker
    -- passes that on.
    check("session_key_repeats_do_not_hold_the_update_request", function()
        local Session = load_session()
        local real_now, clock = Session._now, 100
        Session._now = function() return clock end
        local s = Session.new{ profile = { host = "h", port = 1, name = "rep" },
            network_mgr = { isWifiOn = function() return true end } }
        s._phase = nil
        s.proto = { send_key = function() end, send_pointer = function() end }
        local ok, err = pcall(function()
            s:send_key(0xFF08, true, true); s:send_key(0xFF08, false, true)
            assert(not s:_holding(), "a repeat alone must not hold the request")
            s:send_key(0xFF08, true); s:send_key(0xFF08, false)
            assert(s:_holding(), "a press holds it")
            clock = clock + Session.INPUT_QUIET + 0.01
            s:send_key(0xFF08, true, true); s:send_key(0xFF08, false, true)
            assert(not s:_holding(), "repeats after the press do not extend the hold")
            -- worker mode: the UI's lines and the decode worker's reading of them
            local lines = {}
            local ui = Session.new{ profile = { host = "h", port = 1, name = "rep2" },
                network_mgr = { isWifiOn = function() return true end } }
            ui.workers = { decode = { send = function(_, l) lines[#lines + 1] = l end } }
            ui:send_key(0xFF08, true, true); ui:send_key(0xFF08, false, true); ui:send_key(0x61, true)
            ui.workers = nil
            assert(table.concat(lines, "|") == "K 65288 1 r|K 65288 0 r|K 97 1",
                "the K lines, got " .. table.concat(lines, "|"))
            local got = {}
            local fake = { state = "connected",
                send_key = function(_, k, d, r) got[#got + 1] = string.format("%d %s %s", k, tostring(d), tostring(r)) end }
            require("vncoxide/workers")._apply_commands({}, fake, lines, true)
            assert(table.concat(got, "|") == "65288 true true|65288 false true|97 true false",
                "the decode worker's calls, got " .. table.concat(got, "|"))
        end)
        Session._now = real_now
        if not ok then return nil, tostring(err) end
        return true
    end)

    -- 13/14. Input priority: while keys are being pressed the incremental update request that
    -- normally follows every FramebufferUpdate is held, so the server does not start the next
    -- redraw behind a burst of key presses. Exactly one request goes out once input has been
    -- quiet for INPUT_QUIET and a poll ran. Without input the request follows at once.
    local function hold_case(name, with_input)
        local Session = load_session()
        local W, H = 32, 24
        local pid, port, log = start_mock{
            name = name, encoding = "raw", pattern = "gradient", width = W, height = H,
        }
        local real_now, clock = Session._now, 100
        Session._now = function() return clock end
        local s = Session.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = name },
            network_mgr = {
                isWifiOn = function() return true end,
                turnOffWifi = function() end,
            },
        }
        local function done(ok, err)
            Session._now = real_now
            s:disconnect()
            stop_mock(pid)
            return ok, err
        end
        local connected, cerr
        connect_sync(s, function(ok, err) connected, cerr = ok, err end)
        if not connected then return done(nil, "connect failed: " .. tostring(cerr)) end
        s.app = {
            on_framebuffer_dirty = function() end,
            on_remote_resized = function() end,
            on_bell = function() end,
        }
        local INC = "INPUT FramebufferUpdateRequest incremental=1"
        local function settle_count()
            -- give the mock time to log anything that was sent
            socket.sleep(0.2)
            return log_count(log, INC)
        end
        if with_input then s:note_input() end
        s:request_full_update()
        s:_flush_now()
        local deadline = os.time() + 20
        while not s.dirty and os.time() < deadline do
            if s:_pump() == "error" then return done(nil, "pump failed: " .. tostring(s:get_error())) end
            socket.sleep(0.01)
        end
        if not s.dirty then return done(nil, "the FramebufferUpdate was not decoded") end
        for _ = 1, 5 do s:_pump() end

        if not with_input then
            if not wait_for_log(log, INC, 5) then
                return done(nil, "without input the incremental request must follow the update")
            end
            local n = settle_count()
            if n ~= 1 then return done(nil, "expected exactly one incremental request, got " .. n) end
            return done(true)
        end

        local n = settle_count()
        if n ~= 0 then return done(nil, "the request must be held during input, got " .. n) end
        s.attached = true
        clock = 100 + Session.INPUT_QUIET / 2
        s:_poll()
        n = settle_count()
        if n ~= 0 then return done(nil, "the request must stay held inside INPUT_QUIET, got " .. n) end
        clock = 100 + Session.INPUT_QUIET + 0.01
        s:_poll()
        if not wait_for_log(log, INC, 5) then
            return done(nil, "the held request must go out once input has been quiet")
        end
        s:_poll()
        s:_poll()
        n = settle_count()
        s.attached = false
        if n ~= 1 then return done(nil, "expected exactly one released request, got " .. n) end
        return done(true)
    end
    check("session_holds_update_request_during_input", function()
        return hold_case("hold_input", true)
    end)
    check("session_requests_update_at_once_without_input", function()
        return hold_case("hold_none", false)
    end)

    -- 15. The protocol alone: release_update is a no-op without a held request.
    check("protocol_release_update_noop", function()
        local out = {}
        local proto = Protocol.new{ io = { write = function(s) out[#out + 1] = s end, read = function() end } }
        proto:release_update()
        local n = #out
        proto.width, proto.height, proto.update_pending = 10, 20, true
        proto:release_update()
        proto:release_update()
        proto:free()
        if n ~= 0 then return nil, "release without a held request must send nothing" end
        if #out ~= 1 or out[1] ~= "\3\1\0\0\0\0\0\10\0\20" then
            return nil, "release must send exactly one incremental request for the whole area"
        end
        return true
    end)

    -- 16. Timing trace: a decoded update logs rects/bytes/decode/wall, only while debug logging
    -- is on.
    local function timing_case(name, timing_on)
        local Session = load_session()
        local logger = require("logger")
        local Util = require("vncoxide/util")
        local pid, port = start_mock{
            name = name, encoding = "raw", pattern = "gradient", width = 32, height = 24,
        }
        local real_dbg, real_on = logger.dbg, Util.timing_enabled
        local lines = {}
        logger.dbg = function(...)
            lines[#lines + 1] = table.concat({ ... }, " ")
        end
        Util.timing_enabled = function() return timing_on end
        local s = Session.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = name },
            network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() end },
        }
        local function done(ok, err)
            logger.dbg, Util.timing_enabled = real_dbg, real_on
            s:disconnect()
            stop_mock(pid)
            return ok, err
        end
        local connected, cerr
        connect_sync(s, function(ok, err) connected, cerr = ok, err end)
        if not connected then return done(nil, "connect failed: " .. tostring(cerr)) end
        s.app = { on_framebuffer_dirty = function() end, on_remote_resized = function() end,
                  on_bell = function() end }
        s:request_full_update()
        s:_flush_now()
        local deadline = os.time() + 20
        while not s.dirty and os.time() < deadline do
            if s:_pump() == "error" then return done(nil, "pump failed") end
            socket.sleep(0.01)
        end
        if not s.dirty then return done(nil, "the FramebufferUpdate was not decoded") end
        for _ = 1, 5 do s:_pump() end
        local found
        for _, l in ipairs(lines) do
            if l:find("^vnc%-timing: update rects=%d+ bytes=%d+ decode_ms=%d+%.%d wall_ms=%d+%.%d$") then
                found = l
            end
        end
        if timing_on and not found then return done(nil, "no update line in: " .. table.concat(lines, " | ")) end
        if timing_on and tonumber(found:match("bytes=(%d+)")) < 32 * 24 * 3 then
            return done(nil, "implausible byte count: " .. found)
        end
        if not timing_on then
            for _, l in ipairs(lines) do
                if l:find("vnc-timing:", 1, true) then return done(nil, "timing line while off: " .. l) end
            end
        end
        return done(true)
    end
    check("session_logs_update_timing", function() return timing_case("timing_on", true) end)
    check("session_update_timing_silent_when_off", function() return timing_case("timing_off", false) end)

    -- 17. A request held during input, then detach + attach: attach sends a full request and
    -- clears the owed one, so nothing more is owed after the quiet period.
    check("session_attach_after_held_request_owes_nothing", function()
        local Session = load_session()
        local pid, port, log = start_mock{
            name = "hold_attach", encoding = "raw", pattern = "gradient", width = 32, height = 24,
        }
        local real_now, clock = Session._now, 100
        Session._now = function() return clock end
        local s = Session.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "hold_attach" },
            network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() end },
        }
        local function done(ok, err)
            Session._now = real_now
            s:disconnect()
            stop_mock(pid)
            return ok, err
        end
        local connected, cerr
        connect_sync(s, function(ok, err) connected, cerr = ok, err end)
        if not connected then return done(nil, "connect failed: " .. tostring(cerr)) end
        local app = { on_framebuffer_dirty = function() end, on_remote_resized = function() end,
                      on_bell = function() end }
        s.app = app
        s:note_input()
        s:request_full_update()
        s:_flush_now()
        local deadline = os.time() + 20
        while not s.dirty and os.time() < deadline do
            if s:_pump() == "error" then return done(nil, "pump failed") end
            socket.sleep(0.01)
        end
        if not s.dirty then return done(nil, "the FramebufferUpdate was not decoded") end
        for _ = 1, 5 do s:_pump() end
        if not s.proto.update_pending then return done(nil, "the request should be held") end
        s:detach()
        s:attach(app)
        if s.proto.update_pending then return done(nil, "attach must clear the owed request") end
        if not wait_for_log(log, "INPUT FramebufferUpdateRequest incremental=0", 5) then
            return done(nil, "attach must send a full (non-incremental) request")
        end
        socket.sleep(0.2)
        local inc_before = log_count(log, "INPUT FramebufferUpdateRequest incremental=1")
        clock = 100 + Session.INPUT_QUIET + 0.1
        for _ = 1, 3 do s:_poll(); socket.sleep(0.05) end
        local inc_after = log_count(log, "INPUT FramebufferUpdateRequest incremental=1")
        s.attached = false
        -- the full request's own answer may legitimately trigger one incremental follow-up
        if inc_after - inc_before > 1 then
            return done(nil, "no extra incremental request is owed, got " .. (inc_after - inc_before))
        end
        if s.proto.update_pending then return done(nil, "nothing may be owed after the quiet period") end
        return done(true)
    end)

    -- 18-22. The picture-settings benchmark (vncoxide/benchmark.lua) against the real mock, on a fake
    -- clock: a stand-in UIManager runs scheduled tasks in time order and advances the clock to
    -- each task's due time, sleeping a little real time per task so the mock can answer.
    local function bench_env()
        local Session = load_session()
        local UIManager = require("ui/uimanager")
        local Benchmark = require("vncoxide/benchmark")
        local real_now, real_si, real_un = Session._now, UIManager.scheduleIn, UIManager.unschedule
        local clock, tasks = 100, {}
        Session._now = function() return clock end
        UIManager.scheduleIn = function(_, delay, fn, ...)
            tasks[#tasks + 1] = { t = clock + delay, fn = fn, args = { ... }, n = select("#", ...) }
        end
        UIManager.unschedule = function(_, fn)
            for i = #tasks, 1, -1 do
                if tasks[i].fn == fn then table.remove(tasks, i) end
            end
        end
        local env = { Benchmark = Benchmark, Session = Session, tasks = tasks }
        -- Runs tasks until `stop()` or no task is left (or a step cap); true when stop() held.
        function env.run(stop, max_steps)
            for _ = 1, max_steps or 20000 do
                if stop and stop() then return true end
                if #tasks == 0 then return stop == nil end
                local best = 1
                for i = 2, #tasks do
                    if tasks[i].t < tasks[best].t then best = i end
                end
                local task = table.remove(tasks, best)
                clock = math.max(clock, task.t)
                task.fn(unpack(task.args, 1, task.n))
                socket.sleep(0.002)
            end
            return false
        end
        function env.restore()
            Session._now, UIManager.scheduleIn, UIManager.unschedule = real_now, real_si, real_un
        end
        return env
    end
    local NET = { isWifiOn = function() return true end, turnOffWifi = function() end }
    local function combos(Benchmark, ...)
        local list = {}
        for _, label in ipairs{ ... } do
            for _, c in ipairs(Benchmark.COMBINATIONS) do
                if c.label == label then list[#list + 1] = c end
            end
        end
        return list
    end
    -- Starts a mock that serves several connections in a row (the benchmark reconnects); it
    -- simulates the test page (--bench-page) unless `o.plain`.
    local function start_multi(o)
        local port = free_port()
        local log = string.format("%s/%s.log", TMP, o.name)
        os.remove(log)
        local cmd = string.format("python3 %s --port %d --encoding %s --pattern gradient --width 200 --height 150 --log %s%s",
            MOCK, port, o.encoding or "raw", log, (o.repaint and (" --repaint " .. o.repaint) or "")
            .. (o.plain and "" or " --bench-page") .. (o.extra or ""))
        local h = assert(io.popen(cmd .. " > " .. log .. ".stdout 2>&1 & echo $!", "r"))
        local pid = (h:read("*l") or ""):gsub("%s", "")
        h:close()
        if not wait_for_log(log, "LISTENING", 10) then error("mock did not start: " .. log) end
        return pid, port, log
    end

    -- Records every session the benchmark creates.
    local function track_sessions()
        local Session = require("vncoxide/session")
        local real_new, list = Session.new, {}
        Session.new = function(o)
            local s = real_new(o)
            list[#list + 1] = s
            return s
        end
        return list, function() Session.new = real_new end
    end
    local function all_torn_down(list)
        for i, s in ipairs(list) do
            if s:get_state() ~= "disconnected" or s.sock or s.remote or s:is_attached() then
                return false, string.format("session %d left %s (sock=%s attached=%s)", i,
                    tostring(s:get_state()), tostring(s.sock ~= nil), tostring(s:is_attached()))
            end
        end
        return true
    end

    check("benchmark_combination_list", function()
        local Benchmark = require("vncoxide/benchmark")
        local C = Benchmark.COMBINATIONS
        if #C ~= 11 then return nil, "expected 11 combinations, got " .. #C end
        local want = {
            "24-bit, Tight off", "24-bit, Tight, compr. 1", "24-bit, Tight, compr. 2",
            "16-bit, Tight off", "16-bit, Tight, compr. 1", "16-bit, Tight, compr. 2",
            "8-bit, Tight off", "8-bit, Tight, compr. 1", "8-bit, Tight, compr. 2",
            "24-bit, Tight, compr. 2, JPEG 8", "24-bit, Tight, compr. 2, JPEG 4",
        }
        for i, l in ipairs(want) do
            if C[i].label ~= l then return nil, string.format("#%d: %q, want %q", i, tostring(C[i].label), l) end
        end
        local j4 = C[11]
        if not (j4.color_depth == 24 and j4.enable_tight == true and j4.compress_level == 2 and j4.jpeg_quality == 4) then
            return nil, "JPEG 4 combination fields wrong"
        end
        local off = C[4]
        if not (off.color_depth == 16 and off.enable_tight == false and off.jpeg_quality == false
                and off.compress_level == false) then
            return nil, "Tight-off combination fields wrong"
        end
        return true
    end)

    -- The test page's script (as tools/bench-page.html and the mock's --bench-page) and the
    -- engine's constants; the still-screen phases are gone.
    check("benchmark_script_and_constants", function()
        local Benchmark = require("vncoxide/benchmark")
        local S = Benchmark.SCRIPT
        if type(S) ~= "table" or #S ~= 15 then return nil, "SCRIPT must hold 15 steps" end
        local cats = table.concat(Benchmark.CATEGORIES or {}, ",")
        if cats ~= "photo,text,scroll,small,flip" then return nil, "CATEGORIES " .. cats end
        local count = {}
        for _, c in ipairs(S) do count[c] = (count[c] or 0) + 1 end
        for _, c in ipairs(Benchmark.CATEGORIES) do
            if count[c] ~= 3 then return nil, c .. " appears " .. tostring(count[c]) .. " times" end
            count[c] = nil
        end
        if next(count) then return nil, "unknown category " .. next(count) end
        if S[1] ~= "photo" or S[15] ~= "text" then return nil, "first/last step " .. S[1] .. "/" .. S[15] end
        local want = { PASSES = 2, STEP_TIMEOUT = 5, QUIET = 0.15, RESET_SETTLE = 0.5, TIE = 0.95,
                       KEY_NEXT = 0xff56, KEY_RESET = 0xff50 }
        for k, v in pairs(want) do
            if Benchmark[k] ~= v then return nil, k .. " = " .. tostring(Benchmark[k]) end
        end
        if Benchmark.FULL_SAMPLES ~= nil or Benchmark.TILES ~= nil or Benchmark._tiles ~= nil
                or Benchmark._sort ~= nil then
            return nil, "FULL_SAMPLES / TILES / _tiles / _sort are gone"
        end
        return true
    end)

    -- _rank: speed vs the fastest per category (geometric mean), ties within 95% of the group's
    -- leader share its rank (1, 1, 3), ordered lossless < JPEG < 8-bit, then by bytes.
    check("benchmark_rank_order_and_ties", function()
        local Benchmark = require("vncoxide/benchmark")
        local C = Benchmark.COMBINATIONS
        local function row(tag, combo, ms, bytes)
            local cat_ms = {}
            for _, c in ipairs(Benchmark.CATEGORIES) do cat_ms[c] = type(ms) == "table" and ms[c] or ms end
            return { tag = tag, combination = combo, ok = true, cat_ms = cat_ms, bytes = bytes or 0 }
        end
        local function near(a, b) return a and math.abs(a - b) < 1e-6 end
        local function tags(list, field)
            local out = {}
            for i, r in ipairs(list) do out[i] = tostring(r[field or "tag"]) end
            return table.concat(out, ",")
        end
        -- speeds and competition ranking
        local fast, slow, close = row("fast", C[1], 100), row("slow", C[2], 200), row("close", C[3], 100 / 0.96)
        local photo = row("photo", C[4], { photo = 200, text = 100, scroll = 100, small = 100, flip = 100 })
        local fail = { tag = "fail", combination = C[5], ok = false, error = "x" }
        local s = Benchmark._rank{ fail, slow, close, fast }
        if tags(s) ~= "fast,close,slow,fail" then return nil, "order " .. tags(s) end
        if tags(s, "rank") ~= "1,1,3,nil" then return nil, "ranks " .. tags(s, "rank") end
        if not (near(fast.speed_pct, 100) and near(slow.speed_pct, 50) and near(close.speed_pct, 96)) then
            return nil, string.format("speeds %s %s %s", tostring(fast.speed_pct), tostring(slow.speed_pct),
                tostring(close.speed_pct))
        end
        if fail.speed_pct ~= nil or fail.rank ~= nil then return nil, "a failed row has no speed or rank" end
        Benchmark._rank{ fast, photo }
        if not near(photo.speed_pct, 100 * 0.5 ^ (1 / 5)) then return nil, "geometric mean " .. tostring(photo.speed_pct) end
        -- within a tie: lossless (fewer bytes first), then JPEG, then 8-bit
        local jpeg = row("jpeg", C[10], 100, 10)
        local lossless = row("lossless", C[1], 100 / 0.96, 5000)
        local lossless2 = row("lossless2", C[5], 100 / 0.98, 3000)
        local eight = row("eight", C[7], 100 / 0.97, 1)
        local far = row("far", C[2], 200, 1)
        s = Benchmark._rank{ eight, jpeg, fail, far, lossless, lossless2 }
        if tags(s) ~= "lossless2,lossless,jpeg,eight,far,fail" then return nil, "tie order " .. tags(s) end
        if tags(s, "rank") ~= "1,1,1,1,5,nil" then return nil, "tie ranks " .. tags(s, "rank") end
        return true
    end)

    -- Runs a benchmark against the --bench-page mock on the fake clock; returns the results, the
    -- stop, the progress lines, the samples handed to _score per combination and the mock log.
    local function bench_run(o)
        local env = bench_env()
        local list, untrack = track_sessions()
        local pid, port, log = start_multi{ name = o.name, extra = o.extra, plain = o.plain, encoding = o.encoding }
        local Benchmark = env.Benchmark
        local real_score, scored = Benchmark._score, {}
        Benchmark._score = function(combo, samples)
            scored[combo.label] = #samples
            return real_score(combo, samples)
        end
        local results, stop, calls, progress = nil, nil, 0, {}
        local b = Benchmark.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "bench" },
            combinations = combos(Benchmark, unpack(o.labels)),
            canvas = o.canvas or { w = 200, h = 150, bb_type = BB.TYPE_BB8 },
            network_mgr = NET,
            on_progress = function(i, n, label, phase, pass, passes, step, steps)
                progress[#progress + 1] = { i = i, n = n, label = label, phase = phase, pass = pass,
                    passes = passes, step = step, steps = steps, t = env.Session._now() }
                if o.on_progress then o.on_progress(b, phase, step, pass) end
            end,
            on_done = function(r, st) calls = calls + 1; results, stop = r, st end,
        }
        b:start()
        local finished = env.run(function() return results ~= nil end, 40000)
        env.run(nil, 200)
        Benchmark._score = real_score
        local left = #env.tasks
        untrack()
        env.restore()
        stop_mock(pid)
        for _, s2 in ipairs(list) do if s2:get_state() ~= "disconnected" then s2:disconnect() end end
        return { finished = finished, results = results, stop = stop, calls = calls, progress = progress,
                 scored = scored, log = log, sessions = list, left = left, b = b }
    end
    local function bench_lines(log)
        local steps, homes = 0, 0
        for line in (read_file(log) or ""):gmatch("[^\n]+") do
            local k = line:match("BENCH step=(%d+)")
            if k == "0" then homes = homes + 1 elseif k then steps = steps + 1 end
        end
        return steps, homes
    end

    -- Two combinations, two passes: each run resets the page (Home) and times the 15 Page Down
    -- steps; every row has the 5 category medians and the round time; every update is drawn into
    -- the one off-screen buffer with the viewer's scaling and dither flag.
    check("benchmark_key_steps_scored", function()
        local Remote = require("vncoxide/framebuffer")
        local real_draw, draws = Remote.draw_to, {}
        Remote.draw_to = function(self, bb, ...)
            draws[#draws + 1] = { scaling = self.scaling, scale = self:get_scale(), w = bb:getWidth(),
                                  h = bb:getHeight(), bb = bb, dither = select(5, ...) }
            return real_draw(self, bb, ...)
        end
        local ok, r = pcall(bench_run, { name = "bench_keys", labels = { "24-bit, Tight off", "8-bit, Tight off" },
            canvas = { w = 400, h = 300, bb_type = BB.TYPE_BB8, view_mode = "fit", scaling = "sharp", dither = true } })
        Remote.draw_to = real_draw
        if not ok then return nil, r end
        if not r.finished then return nil, "benchmark never finished" end
        if r.stop ~= nil then return nil, "unexpected stop " .. tostring(r.stop.reason) .. ": " .. tostring(r.stop.error) end
        if #r.results ~= 2 then return nil, "expected 2 rows, got " .. #r.results end
        local hold_ms = require("vncoxide/session").INPUT_QUIET * 1000
        for _, row in ipairs(r.results) do
            local l = row.combination.label
            if not row.ok then return nil, l .. " failed: " .. tostring(row.error) end
            local sum = 0
            for _, c in ipairs(r.b.CATEGORIES) do
                local v = row.cat_ms[c]
                if not (v and v > 0) then return nil, l .. ": no time for " .. c end
                -- the session's input hold (INPUT_QUIET after a key) is over before the next
                -- key, so it is not in the step time (on the fake clock a full raw frame takes a
                -- few 5 ms polls to read)
                if v >= hold_ms then return nil, string.format("%s: %s %.1f ms", l, c, v) end
                sum = sum + v
            end
            if math.abs(row.round_s - sum / 1000) > 1e-9 then return nil, l .. ": round_s " .. row.round_s end
            if not (row.bytes and row.bytes > 0) then return nil, l .. ": bytes" end
            if not (row.rank and row.speed_pct and row.speed_pct > 0 and row.speed_pct <= 100 + 1e-9) then
                return nil, l .. ": not ranked"
            end
            if r.scored[l] ~= 30 then return nil, l .. ": " .. tostring(r.scored[l]) .. " samples, want 2 x 15" end
        end
        local steps, homes = bench_lines(r.log)
        if steps ~= 2 * 2 * 15 or homes ~= 4 then return nil, string.format("mock saw %d steps, %d resets", steps, homes) end
        if log_count(r.log, "keysym=0xff56") ~= 2 * 60 then return nil, "Page Down must go down and up" end
        local p = {}
        for _, e in ipairs(r.progress) do
            p[#p + 1] = string.format("%d/%d %s %d/%d%s", e.i, e.n, e.phase, e.pass, e.passes,
                e.step and string.format(" %d/%d", e.step, e.steps) or "")
        end
        p = table.concat(p, ";")
        for _, want in ipairs{ "1/4 connect 1/2;1/4 reset 1/2;1/4 steps 1/2 1/15;1/4 steps 1/2 2/15",
                               "4/4 steps 2/2 15/15" } do
            if not p:find(want, 1, true) then return nil, "progress lacks " .. want .. ": " .. p:sub(1, 300) end
        end
        if #draws == 0 then return nil, "never drawn" end
        for _, d in ipairs(draws) do
            if d.scaling ~= "sharp" or d.scale ~= 2 or d.w ~= 400 or d.h ~= 300 then
                return nil, string.format("draw %s scale %s %dx%d", d.scaling, d.scale, d.w, d.h)
            end
            if d.bb ~= draws[1].bb then return nil, "the off-screen buffer must be allocated once" end
            if d.dither ~= true then return nil, "the canvas dither flag must be passed to draw_to" end
        end
        if #draws < 4 * 16 then return nil, "every update must be drawn, got " .. #draws end
        local torn, why = all_torn_down(r.sessions)
        if not torn then return nil, why end
        if r.left ~= 0 then return nil, "tasks still scheduled" end
        return true
    end)

    -- A step's update that arrives in pieces (the mock writes it in 50000-byte chunks with a
    -- pause between them: a full 24-bit frame takes 3) is still one step, timed to its end.
    check("benchmark_key_split_update_is_one_step", function()
        local r = bench_run{ name = "bench_split", extra = " --split 50000", labels = { "24-bit, Tight off" } }
        if not r.finished then return nil, "benchmark never finished" end
        local row = r.results[1]
        if not (row and row.ok) then return nil, "row failed: " .. tostring(row and row.error) end
        if r.scored["24-bit, Tight off"] ~= 2 * 15 then
            return nil, tostring(r.scored["24-bit, Tight off"]) .. " samples, want one per step (30)"
        end
        return true
    end)

    -- The page is already at step 0 when Home goes out (the mock sends no update): the reset
    -- still ends after the settle time, and the steps start.
    check("benchmark_key_reset_without_change", function()
        local r = bench_run{ name = "bench_reset", labels = { "24-bit, Tight off" } }
        if not r.finished then return nil, "benchmark never finished" end
        if log_count(r.log, "BENCH step=0 region=none") < 1 then return nil, "Home changed the page" end
        local t_reset, t_step
        for _, e in ipairs(r.progress) do
            if e.i == 1 and e.phase == "reset" then t_reset = e.t end
            if e.i == 1 and e.phase == "steps" and e.step == 1 then t_step = e.t end
        end
        if not (t_reset and t_step) then return nil, "the first run never reached its steps" end
        local d = t_step - t_reset
        if d < r.b.RESET_SETTLE or d >= r.b.STEP_TIMEOUT then return nil, string.format("reset took %.2f s", d) end
        if not (r.results[1] and r.results[1].ok) then return nil, "row failed: " .. tostring(r.results[1].error) end
        return true
    end)

    -- Keys change nothing (the page is not focused; a mock without --bench-page): the first step
    -- gets no update within STEP_TIMEOUT, and the whole run stops with a "no_response" stop.
    check("benchmark_key_no_response_stops", function()
        local r = bench_run{ name = "bench_noresp", plain = true, labels = { "24-bit, Tight off", "8-bit, Tight off" } }
        if not r.finished then return nil, "benchmark never finished" end
        local st = r.stop
        if not (st and st.reason == "no_response" and type(st.error) == "string" and st.error ~= "") then
            return nil, "stop " .. tostring(st and st.reason)
        end
        if r.calls ~= 1 then return nil, "on_done called " .. r.calls .. " times" end
        if #r.sessions ~= 1 then return nil, #r.sessions .. " sessions created, only the first run may be tried" end
        if #r.results ~= 1 or r.results[1].ok or r.results[1].error ~= "failed in pass 1: " .. st.error then
            return nil, "expected the one failed row carrying the error"
        end
        local t_step
        for _, e in ipairs(r.progress) do if e.phase == "steps" and e.step == 1 then t_step = e.t end end
        if not t_step then return nil, "step 1 never started" end
        if r.left ~= 0 then return nil, "tasks still scheduled" end
        local torn, why = all_torn_down(r.sessions)
        if not torn then return nil, why end
        return true
    end)

    -- A combination the server refuses (Tight off against a Tight-only mock) fails and the run
    -- continues; the scored one ranks first.
    check("benchmark_failed_combination", function()
        local r = bench_run{ name = "bench_failed", encoding = "tight",
                             labels = { "24-bit, Tight off", "24-bit, Tight, compr. 2" } }
        if not r.finished then return nil, "benchmark never finished" end
        if #r.results ~= 2 then return nil, "expected 2 results" end
        local r1, r2 = r.results[1], r.results[2]
        if not (r1.ok and r1.combination.label == "24-bit, Tight, compr. 2" and r1.rank == 1) then
            return nil, string.format("first row: ok=%s err=%s", tostring(r1.ok), tostring(r1.error))
        end
        if r2.ok ~= false or type(r2.error) ~= "string" or r2.rank ~= nil then
            return nil, "the refused combination must fail with a reason"
        end
        if r2.error:sub(1, 18) ~= "failed in pass 1: " then return nil, "row error " .. r2.error end
        if log_count(r.log, "AUTH ok") ~= 4 then return nil, "expected 4 connections (2 passes)" end
        if r.stop ~= nil then return nil, "a failure after connecting must not end the run" end
        return true
    end)

    -- A DesktopSize mid-run (on the 5th request, during the steps) fails the run; the run goes on.
    check("benchmark_resize_fails_the_combination", function()
        local r = bench_run{ name = "bench_resize", extra = " --resize-after 5",
                             labels = { "24-bit, Tight off", "8-bit, Tight off" } }
        if not r.finished then return nil, "benchmark never finished" end
        if #r.results ~= 2 then return nil, "expected 2 results, got " .. #r.results end
        for _, row in ipairs(r.results) do
            if row.ok ~= false or row.error ~= "failed in pass 1: screen size changed" then
                return nil, row.combination.label .. ": ok=" .. tostring(row.ok) .. " error=" .. tostring(row.error)
            end
        end
        if r.stop ~= nil then return nil, "a resize must not stop the whole run" end
        return true
    end)

    -- Lengths and sizes on the wire are the server's to choose. The client must not allocate on
    -- their say-so: a desktop name, a reason or a cut text over 1 MiB fails the connection, and so
    -- does a framebuffer that is empty or would take more than 256 MiB as a plane - with an error
    -- that says so, before anything is read or allocated.
    do
        local Util = require("vncoxide/util")
        --- Drives a fresh Protocol over `script` (the server's bytes); returns the error it stopped
        --- with, what it was waiting for when the script ran out, and the sizes it reported.
        local function run_script(script, callbacks)
            local proto = Protocol.new{ io = { write = function() end }, host = "test", port = 0,
                callbacks = callbacks, get_plane = function() return nil end }
            local pos, kind, arg = 1, proto:step(nil)
            while kind == "need" do
                if pos + arg - 1 > #script then return nil, arg end
                local data = script:sub(pos, pos + arg - 1)
                pos = pos + arg
                kind, arg = proto:step(data)
            end
            return kind == nil and tostring(arg) or nil, nil
        end
        local function server_init(w, h, name_len, name)
            return Util.writer():raw("RFB 003.008\n"):u8(1):u8(1):u32(0):u16(w):u16(h)
                :raw(string.rep("\0", 16)):u32(name_len):raw(name or ""):tostring()
        end
        local BIG = 0x7FFFFFFF
        local cases = {
            { "a huge desktop name", server_init(4, 4, BIG), "name" },
            { "a zero-width framebuffer", server_init(0, 4, 1, "x"), "framebuffer" },
            { "a framebuffer over the cap", server_init(65535, 65535, 1, "x"), "framebuffer" },
            { "a huge refusal reason", Util.writer():raw("RFB 003.008\n"):u8(0):u32(BIG):tostring(), "reason" },
            { "a huge 3.3 refusal reason", Util.writer():raw("RFB 003.003\n"):u32(0):u32(BIG):tostring(), "reason" },
            { "a huge failure reason", Util.writer():raw("RFB 003.008\n"):u8(1):u8(1):u32(1):u32(BIG):tostring(), "reason" },
            { "a huge cut text", server_init(4, 4, 1, "x") .. Util.writer():u8(3):raw("\0\0\0"):u32(BIG):tostring(), "cut text" },
            { "a DesktopSize over the cap", server_init(4, 4, 1, "x") .. Util.writer():u8(0):u8(0):u16(1)
                :u16(0):u16(0):u16(65535):u16(65535):u32(-223 % 4294967296):tostring(), "framebuffer" },
            { "an empty DesktopSize", server_init(4, 4, 1, "x") .. Util.writer():u8(0):u8(0):u16(1)
                :u16(0):u16(0):u16(0):u16(8):u32(-223 % 4294967296):tostring(), "framebuffer" },
        }
        for _, case in ipairs(cases) do
            check("protocol_rejects_" .. case[1]:gsub("^an? ", ""):gsub("[^%w]+", "_"), function()
                local resized
                local err, waiting = run_script(case[2], { on_desktop_resize = function(w, h) resized = { w, h } end })
                if resized then return nil, "the resize was reported: " .. resized[1] .. "x" .. resized[2] end
                if not err then return nil, "not rejected (waiting for " .. tostring(waiting) .. " bytes)" end
                if not err:find(case[3], 1, true) then return nil, "unclear error: " .. err end
                return true
            end)
        end
        check("protocol_accepts_a_sane_handshake_and_cut_text", function()
            local got, size
            local err, waiting = run_script(server_init(640, 480, 4, "test")
                .. Util.writer():u8(3):raw("\0\0\0"):u32(5):raw("hello"):tostring(),
                { on_connected = function(_, w, h) size = { w, h } end, on_cut_text = function(t) got = t end })
            if err then return nil, err end
            if not (size and size[1] == 640 and size[2] == 480) then return nil, "no on_connected" end
            if got ~= "hello" then return nil, "cut text not delivered" end
            return waiting == 1, "should be waiting for the next message"
        end)
        -- RealVNC announces 4.1 or 5.0: those speak 3.8, which is what the client answers (it
        -- used to fall back to 3.3, and with it to the 3.3 security handshake).
        check("protocol_answers_a_later_major_version_with_3_8", function()
            for _i, announced in ipairs{ "RFB 004.001\n", "RFB 005.000\n" } do
                local sent, size = {}, nil
                local proto = Protocol.new{ io = { write = function(d) sent[#sent + 1] = d end }, host = "test",
                    port = 0, callbacks = { on_connected = function(_, w, h) size = { w, h } end },
                    get_plane = function() return nil end }
                local script = announced .. server_init(8, 6, 1, "x"):sub(13)
                local pos, kind, arg = 1, proto:step(nil)
                while kind == "need" and pos + arg - 1 <= #script do
                    local data = script:sub(pos, pos + arg - 1)
                    pos = pos + arg
                    kind, arg = proto:step(data)
                end
                if sent[1] ~= "RFB 003.008\n" then
                    return nil, announced:sub(1, 11) .. " answered with " .. tostring(sent[1])
                end
                if not (size and size[1] == 8 and size[2] == 6) then
                    return nil, announced:sub(1, 11) .. ": no 3.8 handshake (" .. tostring(kind) .. " " .. tostring(arg) .. ")"
                end
            end
            return true
        end)
    end

    -- NetworkMgr calls back once Wi-Fi is up - possibly long after the attempt it was armed for
    -- has been given up (the Wi-Fi watchdog failed it, or the user disconnected) or replaced by a
    -- newer one. Such a late callback must not dial: it would open a socket nothing owns, or put
    -- its socket and protocol under the newer attempt.
    check("session_ignores_a_late_wifi_callback", function()
        local Session = load_session()
        local pending = {}
        local net = {
            isWifiOn = function() return false end,
            turnOnWifiAndWaitForConnection = function(_, cb) pending[#pending + 1] = cb end,
            turnOffWifi = function() end,
        }
        local port = free_port()
        local s = Session.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "late_wifi" },
            network_mgr = net,
        }
        local results = {}
        s:connect(function(ok, err) results[#results + 1] = { ok, err } end)
        s:disconnect()
        pending[1]()
        if s:get_state() ~= "disconnected" or s.sock then
            return nil, "a callback after a disconnect dialled anyway (state " .. tostring(s:get_state()) .. ")"
        end
        s:connect(function(ok, err) results[#results + 1] = { ok, err } end)
        pending[1]()                                    -- the first attempt's, again
        if s:get_state() ~= "connecting" or s.sock then
            return nil, "the first attempt's callback took over the second (state " .. tostring(s:get_state()) .. ")"
        end
        pending[2]()                                    -- the current one dials (and is refused)
        while s._phase == "dial" do s:_connect_tick(); socket.sleep(0.002) end
        if s:get_state() ~= "error" then
            return nil, "the current attempt's callback must dial, state " .. tostring(s:get_state())
        end
        s:disconnect()
        return true
    end)

    -- Attaching a session that is not connected (the benchmark re-attaches whatever it detached,
    -- also one that dropped meanwhile) registers no poll: it used to, and the poll crashed on the
    -- protocol the drop had freed.
    check("session_attach_needs_a_connection", function()
        local Session = load_session()
        local s = Session.new{ profile = { host = "127.0.0.1", port = 1, password = "", name = "dropped" },
                               network_mgr = { isWifiOn = function() return true end } }
        s.state = "error"
        s:attach({ on_framebuffer_dirty = function() end })
        if s:is_attached() then return nil, "a dropped session must not attach" end
        local ok, err = pcall(s._poll, s)
        if not ok then return nil, "a stray poll must not raise: " .. tostring(err) end
        ok, err = pcall(s._pump, s)
        if not ok or err ~= "error" then return nil, "a pump without a protocol: " .. tostring(err) end
        return true
    end)

    -- The server's clipboard is logged by its length, never its text (it may hold a password).
    check("session_does_not_log_the_server_clipboard", function()
        local Session = load_session()
        local logger = require("logger")
        local pid, port = start_mock{ name = "cut_text_log", encoding = "raw", pattern = "gradient", width = 32, height = 24 }
        local s = Session.new{ profile = { host = "127.0.0.1", port = port, password = "", name = "cut" },
                               network_mgr = NET }
        local connected
        connect_sync(s, function(ok) connected = ok end)
        local lines, real_dbg = {}, logger.dbg
        logger.dbg = function(...) lines[#lines + 1] = table.concat({ ... }, " ") end
        local ok, err = pcall(function() s.proto.callbacks.on_cut_text("hunter2-secret") end)
        logger.dbg = real_dbg
        s:disconnect()
        stop_mock(pid)
        if not connected then return nil, "connect failed" end
        if not ok then return nil, tostring(err) end
        local all = table.concat(lines, "\n")
        if all:find("hunter2", 1, true) then return nil, "the clipboard text was logged: " .. all end
        if not all:find("14", 1, true) then return nil, "its length should be logged: " .. all end
        return true
    end)

    -- A refused connect closes the socket it opened (it used to be left to the garbage collector).
    check("session_closes_the_socket_of_a_failed_connect", function()
        local Session = load_session()
        local socket = require("socket")
        local port = free_port()
        local real_tcp, closed = socket.tcp, 0
        socket.tcp = function()
            local sock = real_tcp()
            return setmetatable({ close = function() closed = closed + 1 return sock:close() end }, {
                __index = function(_, k)
                    local v = sock[k]
                    if type(v) == "function" then return function(_, ...) return v(sock, ...) end end
                    return v
                end,
            })
        end
        local s = Session.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "refused" },
            network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() end },
        }
        local ok, err = pcall(connect_sync, s, function() end)
        socket.tcp = real_tcp
        if not ok then return nil, err end
        if s:get_state() ~= "error" then return nil, "the connect must fail, state " .. tostring(s:get_state()) end
        if closed ~= 1 then return nil, "the refused socket must be closed once, closed " .. closed .. " time(s)" end
        return true
    end)

    -- A failure before the handshake completes (refused, auth, Wi-Fi) ends the whole run at once:
    -- one session, one failed row, and on_done gets the stop { reason = "connect", error }.
    check("benchmark_stops_on_connect_failure", function()
        local apid, aport = start_multi{ name = "bench_auth", extra = " --security vnc --password secret" }
        local cases = {
            { what = "refused", port = free_port(), net = NET },
            { what = "auth", port = aport, password = "wrong", net = NET },
            { what = "wifi", port = free_port(), net = { isWifiOn = function() return false end,
                turnOnWifiAndWaitForConnection = function() return false end, turnOffWifi = function() end } },
        }
        local problem
        for _, c in ipairs(cases) do
            local env = bench_env()
            local list, untrack = track_sessions()
            local results, err, stop, calls = nil, nil, nil, 0
            local b = env.Benchmark.new{
                profile = { host = "127.0.0.1", port = c.port, password = c.password or "", name = "bench" },
                combinations = combos(env.Benchmark, "24-bit, Tight off", "8-bit, Tight off"),
                canvas = { w = 100, h = 100, bb_type = BB.TYPE_BB8 },
                network_mgr = c.net,
                on_done = function(r, st) calls = calls + 1; results, stop, err = r, st, st and st.error end,
            }
            b:start()
            local finished = env.run(function() return results ~= nil end)
            env.run(nil, 200)
            untrack()
            env.restore()
            if not finished then problem = c.what .. ": never finished"
            elseif not stop or stop.reason ~= "connect" or type(err) ~= "string" or err == "" then
                problem = c.what .. ": on_done got no connect stop"
            elseif calls ~= 1 then problem = c.what .. ": on_done called " .. calls .. " times"
            elseif #list ~= 1 then problem = c.what .. ": " .. #list .. " sessions created, the run must stop"
            elseif #results ~= 1 or results[1].ok or results[1].error ~= "failed in pass 1: " .. err then
                problem = c.what .. ": expected the one failed row carrying the error"
            elseif #env.tasks ~= 0 then problem = c.what .. ": tasks still scheduled" end
            for _, s2 in ipairs(list) do if s2:get_state() ~= "disconnected" then s2:disconnect() end end
            if problem then break end
        end
        stop_mock(apid)
        if problem then return nil, problem end
        return true
    end)

    -- Cancel mid-steps: the session is torn down, nothing of the benchmark stays scheduled, on_done
    -- never fires, and an attached bystander session (the viewer's) keeps its poll task.
    check("benchmark_cancel_mid_steps", function()
        local env = bench_env()
        local Session = require("vncoxide/session")
        local pid, port = start_multi{ name = "bench_cancel" }
        local bpid, bport = start_mock{ name = "bench_bystander", encoding = "raw", pattern = "gradient" }
        local by = Session.new{ profile = { host = "127.0.0.1", port = bport, password = "", name = "by" },
                                network_mgr = NET }
        connect_sync(by, function() end)
        by:attach({ on_framebuffer_dirty = function() end, on_remote_resized = function() end,
                    on_bell = function() end })
        local done_called, mid = false, false
        local b = env.Benchmark.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "bench" },
            combinations = combos(env.Benchmark, "24-bit, Tight off", "8-bit, Tight off"),
            canvas = { w = 200, h = 150, bb_type = BB.TYPE_BB8 },
            network_mgr = NET,
            on_progress = function(_, _, _, phase, _, _, step) if phase == "steps" and step == 3 then mid = true end end,
            on_done = function() done_called = true end,
        }
        b:start()
        local reached = env.run(function() return mid end)
        local s = b.session
        if reached then env.run(nil, 10) end
        b:cancel()
        env.run(nil, 200)
        local others = 0
        for _, t in ipairs(env.tasks) do
            if t.fn ~= by._poll_task then others = others + 1 end
        end
        local by_alive = by:is_attached() and #env.tasks - others == 1
        by:disconnect()
        env.restore()
        stop_mock(pid)
        stop_mock(bpid)
        if not reached then return nil, "step 3 never reached" end
        if not by_alive then return nil, "the bystander session lost its poll task" end
        if not s or s:get_state() ~= "disconnected" or s.sock or s.remote then
            return nil, "session not torn down"
        end
        if b.session then return nil, "benchmark still holds a session" end
        if others ~= 0 then return nil, "benchmark tasks still scheduled after cancel" end
        if done_called then return nil, "on_done must not be called on cancel" end
        return true
    end)

    -- cancel() from inside on_progress, in each phase that is followed by more work: nothing
    -- stays connected, attached or scheduled, and on_done never fires.
    check("benchmark_cancel_from_on_progress", function()
        local pid, port = start_multi{ name = "bench_reentrant" }
        local problem
        for _, at in ipairs{ "connect", "reset", "steps" } do
            local env = bench_env()
            local list, untrack = track_sessions()
            local done_called, b = false, nil
            b = env.Benchmark.new{
                profile = { host = "127.0.0.1", port = port, password = "", name = "bench" },
                combinations = combos(env.Benchmark, "24-bit, Tight off", "8-bit, Tight off"),
                canvas = { w = 200, h = 150, bb_type = BB.TYPE_BB8 },
                network_mgr = NET,
                on_progress = function(_, _, _, phase) if phase == at then b:cancel() end end,
                on_done = function() done_called = true end,
            }
            b:start()
            env.run(nil, 2000)
            local left = #env.tasks
            untrack()
            env.restore()
            local ok, why = all_torn_down(list)
            if #list ~= 1 then problem = string.format("%s: %d sessions created", at, #list)
            elseif not ok then problem = at .. ": " .. why
            elseif left ~= 0 then problem = at .. ": tasks still scheduled"
            elseif done_called then problem = at .. ": on_done called"
            elseif b.session or b.bb then problem = at .. ": session or buffer kept" end
            for _, s in ipairs(list) do if s:get_state() ~= "disconnected" then s:disconnect() end end
            if problem then break end
        end
        stop_mock(pid)
        if problem then return nil, problem end
        return true
    end)

    -- An unexpected Lua error inside the run (in start()'s first combination, in the connect
    -- callback, and in a tick)
    -- ends that combination as failed with the message and tears it down; the run goes on.
    check("benchmark_unexpected_error_fails_the_combination", function()
        local pid, port = start_multi{ name = "bench_error" }
        local problem
        for _, where in ipairs{ "start", "connect", "tick" } do
            local env = bench_env()
            local list, untrack = track_sessions()
            local results
            local b = env.Benchmark.new{
                profile = { host = "127.0.0.1", port = port, password = "", name = "bench" },
                combinations = combos(env.Benchmark, "24-bit, Tight off", "8-bit, Tight off"),
                canvas = { w = 200, h = 150, bb_type = BB.TYPE_BB8 },
                network_mgr = NET,
                on_done = function(r) results = r end,
            }
            local method = ({ start = "_progress", connect = "_apply_view", tick = "_collect" })[where]
            local real, fired = env.Benchmark[method], false
            b[method] = function(...)
                if not fired then
                    fired = true
                    error("boom in " .. method)
                end
                return real(...)
            end
            local ok_start, start_err = pcall(b.start, b)
            local finished = ok_start and env.run(function() return results ~= nil end)
            untrack()
            env.restore()
            local torn, why = all_torn_down(list)
            if not ok_start then problem = where .. ": start raised " .. tostring(start_err)
            elseif not finished then problem = where .. ": never finished"
            elseif #results ~= 2 then problem = where .. ": expected 2 rows, got " .. #results
            elseif not results[1].ok or results[1].combination.label ~= "8-bit, Tight off" then
                problem = where .. ": the other combination must still be scored"
            elseif results[2].ok ~= false or not tostring(results[2].error):find("boom in " .. method, 1, true) then
                problem = where .. ": failed row error " .. tostring(results[2].error)
            elseif #list ~= 4 or not torn then problem = where .. ": " .. tostring(why or (#list .. " sessions")) end
            for _, s in ipairs(list) do if s:get_state() ~= "disconnected" then s:disconnect() end end
            if problem then break end
        end
        stop_mock(pid)
        if problem then return nil, problem end
        return true
    end)

    -- An unexpected error while finishing, with no combination left, still hands over the results.
    check("benchmark_error_in_finish_still_reports", function()
        local pid, port = start_multi{ name = "bench_finish" }
        local env = bench_env()
        local results, calls = nil, 0
        local b = env.Benchmark.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "bench" },
            combinations = combos(env.Benchmark, "24-bit, Tight off"),
            canvas = { w = 200, h = 150, bb_type = BB.TYPE_BB8 },
            network_mgr = NET,
            on_done = function(r) calls = calls + 1; results = r end,
        }
        local real, fired = b._stop, false
        b._stop = function(...)
            if not fired then fired = true; error("boom in _stop") end
            return real(...)
        end
        local ok_start, start_err = pcall(b.start, b)
        local finished = ok_start and env.run(function() return results ~= nil end)
        env.restore()
        stop_mock(pid)
        if not ok_start then return nil, "start raised " .. tostring(start_err) end
        if not finished then return nil, "on_done never called" end
        if calls ~= 1 or #results ~= 1 then return nil, "calls=" .. calls .. " rows=" .. #results end
        return true
    end)

    -- Every attached session of the plugin (the viewer's) is detached for the run, so it does not
    -- compete with the measurement, and attached again with its app after done and after cancel.
    check("benchmark_detaches_live_sessions", function()
        local Session = require("vncoxide/session")
        local pid, port = start_multi{ name = "bench_detach" }
        local problem
        for _, ending in ipairs{ "done", "cancel" } do
            -- (a mock serves one connection: each ending gets its own)
            local bpid, bport = start_mock{ name = "bench_detach_by_" .. ending, encoding = "raw", pattern = "gradient" }
            local env = bench_env()
            local by = Session.new{ profile = { host = "127.0.0.1", port = bport, password = "", name = "by" },
                                    network_mgr = NET }
            local idle = Session.new{ profile = { host = "127.0.0.1", port = bport, password = "", name = "idle" },
                                      network_mgr = NET }
            connect_sync(by, function() end)
            local app = { on_framebuffer_dirty = function() end, on_remote_resized = function() end,
                          on_bell = function() end }
            by:attach(app)
            local seen_attached, seen_task, results, b = nil, nil, nil, nil
            b = env.Benchmark.new{
                profile = { host = "127.0.0.1", port = port, password = "", name = "bench" },
                combinations = combos(env.Benchmark, "24-bit, Tight off"),
                canvas = { w = 200, h = 150, bb_type = BB.TYPE_BB8 },
                network_mgr = NET,
                sessions = { by = by, idle = idle },
                on_progress = function(_, _, _, phase)
                    if phase == "steps" then
                        seen_attached = by:is_attached()
                        seen_task = false
                        for _, t in ipairs(env.tasks) do if t.fn == by._poll_task then seen_task = true end end
                        if ending == "cancel" then b:cancel() end
                    end
                end,
                on_done = function(r) results = r end,
            }
            b:start()
            env.run(function() return results ~= nil or b.stopped end)
            local tasks = 0
            for _, t in ipairs(env.tasks) do if t.fn == by._poll_task then tasks = tasks + 1 end end
            local back = by:is_attached() and by.app == app and tasks == 1
            local idle_ok = not idle:is_attached()
            local live = by:is_connected()
            by:disconnect()
            env.restore()
            stop_mock(bpid)
            if not live then problem = ending .. ": the attached session dropped: " .. tostring(by:get_error()) end
            if problem then
            elseif seen_attached == nil then problem = ending .. ": steps never reached"
            elseif seen_attached or seen_task then problem = ending .. ": the attached session was not detached during the run"
            elseif not back then problem = ending .. ": the session was not attached again (tasks " .. tasks .. ")"
            elseif not idle_ok then problem = ending .. ": a session that was not attached got attached" end
            if problem then break end
        end
        stop_mock(pid)
        if problem then return nil, problem end
        return true
    end)

    -- Each step's progress (an e-ink refresh of the dialog) is reported before its key, and the
    -- key goes out on a later tick; the key-down is what the step is timed from.
    check("benchmark_step_key_after_progress", function()
        local Session = require("vncoxide/session")
        local pid, port = start_multi{ name = "bench_window" }
        local env = bench_env()
        local reported, keys, bad, results = {}, {}, nil, nil
        local real_key = Protocol.send_key
        Protocol.send_key = function(self, keysym, down)
            if keysym == 0xff56 and down then
                keys[#keys + 1] = Session._now()
                local k = #keys
                if not reported[k] or reported[k] >= keys[k] then bad = bad or k end
            end
            return real_key(self, keysym, down)
        end
        local b = env.Benchmark.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "bench" },
            combinations = combos(env.Benchmark, "24-bit, Tight off"),
            canvas = { w = 200, h = 150, bb_type = BB.TYPE_BB8 },
            network_mgr = NET,
            on_progress = function(_, _, _, phase)
                if phase == "steps" then reported[#reported + 1] = Session._now() end
            end,
            on_done = function(r) results = r end,
        }
        b:start()
        env.run(function() return results ~= nil end, 40000)
        Protocol.send_key = real_key
        env.restore()
        stop_mock(pid)
        if not (results and results[1] and results[1].ok) then return nil, "run did not score" end
        if #keys ~= 30 or #reported ~= 30 then return nil, string.format("%d keys, %d step reports", #keys, #reported) end
        if bad then return nil, "step " .. bad .. "'s key went out in the tick that reported it (or before)" end
        return true
    end)

    -- Scores: per category the median step time over every sample of both passes (one slow
    -- outlier does not move it), the round time is their sum, bytes the mean per round.
    check("benchmark_score_medians", function()
        local Benchmark = require("vncoxide/benchmark")
        local combo = Benchmark.COMBINATIONS[1]
        local samples = {}
        local function add(cat, elapsed, bytes) samples[#samples + 1] = { cat = cat, elapsed = elapsed, bytes = bytes } end
        -- photo with an outlier: (0.011 + 0.012) / 2; text: (0.020 + 0.030) / 2; flip: 0.2
        for _, e in ipairs{ 0.010, 0.012, 0.011, 0.500, 0.009, 0.013 } do add("photo", e, 100) end
        for _, e in ipairs{ 0.010, 0.020, 0.030, 2.000, 0.040, 0.005 } do add("text", e, 100) end
        for _ = 1, 6 do add("scroll", 0.050, 100) end
        for _ = 1, 6 do add("small", 0.004, 100) end
        for _, e in ipairs{ 0.1, 0.1, 0.2, 0.2, 0.2, 0.9 } do add("flip", e, 100) end
        local r = Benchmark._score(combo, samples)
        local function near(a, b) return math.abs(a - b) < 1e-9 end
        if not (r.ok == true and r.combination == combo) then return nil, "row not ok" end
        local want = { photo = 11.5, text = 25, scroll = 50, small = 4, flip = 200 }
        for c, v in pairs(want) do
            if not near(r.cat_ms[c], v) then return nil, c .. " " .. tostring(r.cat_ms[c]) .. ", want " .. v end
        end
        if not near(r.round_s, (11.5 + 25 + 50 + 4 + 200) / 1000) then return nil, "round_s " .. r.round_s end
        -- 30 samples = 2 rounds of 15 steps, 100 bytes each
        if not near(r.bytes, 1500) then return nil, "bytes per round " .. r.bytes end
        if r.tile_px_per_s ~= nil or r.full_px_per_s ~= nil then return nil, "the pixel rates are gone" end
        return true
    end)

    -- Two passes: every combination in list order, then in reverse order, each on its own
    -- connection; the progress carries the run, the total and the pass.
    check("benchmark_two_passes_opposite_order", function()
        local pid, port = start_multi{ name = "bench_passes" }
        local env = bench_env()
        local list, untrack = track_sessions()
        local results, progress = nil, {}
        local b = env.Benchmark.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "bench" },
            combinations = combos(env.Benchmark, "24-bit, Tight off", "8-bit, Tight off"),
            canvas = { w = 200, h = 150, bb_type = BB.TYPE_BB8 },
            network_mgr = NET,
            on_progress = function(i, n, label, phase, pass, passes)
                if phase == "connect" then
                    progress[#progress + 1] = string.format("%s/%s %s/%s %s", i, n, tostring(pass), tostring(passes), label)
                end
            end,
            on_done = function(r) results = r end,
        }
        b:start()
        local finished = env.run(function() return results ~= nil end)
        untrack()
        env.restore()
        stop_mock(pid)
        if not finished then return nil, "benchmark never finished" end
        local depths = {}
        for i, s2 in ipairs(list) do depths[i] = s2.profile.color_depth end
        depths = table.concat(depths, ",")
        if depths ~= "24,8,8,24" then return nil, "session order " .. depths end
        local p = table.concat(progress, ";")
        local want = "1/4 1/2 24-bit, Tight off;2/4 1/2 8-bit, Tight off;3/4 2/2 8-bit, Tight off;4/4 2/2 24-bit, Tight off"
        if p ~= want then return nil, "progress " .. p end
        if #results ~= 2 then return nil, "expected one row per combination, got " .. #results end
        for _, r in ipairs(results) do
            if not r.ok or not r.cat_ms then
                return nil, r.combination.label .. ": not scored over both passes"
            end
        end
        local torn, why = all_torn_down(list)
        if not torn then return nil, why end
        return true
    end)

    -- A combination that fails only in pass 2 is a failed row ("failed in pass 2: ..."), ranked
    -- after the scored one; the run goes on and on_done gets no connect error.
    check("benchmark_failure_in_pass_2", function()
        local pid, port = start_multi{ name = "bench_pass2" }
        local env = bench_env()
        local list, untrack = track_sessions()
        local results, run_err, arm = nil, nil, false
        local b = env.Benchmark.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "bench" },
            combinations = combos(env.Benchmark, "24-bit, Tight off", "8-bit, Tight off"),
            canvas = { w = 200, h = 150, bb_type = BB.TYPE_BB8 },
            network_mgr = NET,
            on_progress = function(_, _, label, phase, pass)
                if phase == "connect" then arm = (pass == 2 and label == "24-bit, Tight off") end
            end,
            on_done = function(r, e) results, run_err = r, e end,
        }
        local real = env.Benchmark._apply_view
        b._apply_view = function(...)
            if arm then arm = false; error("boom in pass 2") end
            return real(...)
        end
        b:start()
        local finished = env.run(function() return results ~= nil end)
        untrack()
        env.restore()
        stop_mock(pid)
        if not finished then return nil, "benchmark never finished" end
        if run_err ~= nil then return nil, "connect error " .. tostring(run_err) end
        if #results ~= 2 or #list ~= 4 then return nil, string.format("%d rows, %d sessions", #results, #list) end
        local r1, r2 = results[1], results[2]
        if not (r1.ok and r1.combination.label == "8-bit, Tight off") then return nil, "first row must be the scored one" end
        if r2.ok ~= false or r2.combination.label ~= "24-bit, Tight off"
                or not tostring(r2.error):find("^failed in pass 2: .*boom in pass 2") then
            return nil, "failed row: " .. tostring(r2.error)
        end
        local torn, why = all_torn_down(list)
        if not torn then return nil, why end
        return true
    end)

    -- cancel() during pass 2 stops cleanly: nothing connected, attached or scheduled, no on_done.
    check("benchmark_cancel_during_pass_2", function()
        local pid, port = start_multi{ name = "bench_cancel2" }
        local env = bench_env()
        local list, untrack = track_sessions()
        local done_called, b = false, nil
        b = env.Benchmark.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "bench" },
            combinations = combos(env.Benchmark, "24-bit, Tight off", "8-bit, Tight off"),
            canvas = { w = 200, h = 150, bb_type = BB.TYPE_BB8 },
            network_mgr = NET,
            on_progress = function(_, _, _, phase, pass) if pass == 2 and phase == "steps" then b:cancel() end end,
            on_done = function() done_called = true end,
        }
        b:start()
        env.run(nil, 40000)
        local left = #env.tasks
        untrack()
        env.restore()
        stop_mock(pid)
        local torn, why = all_torn_down(list)
        if #list ~= 3 then return nil, #list .. " sessions created (want 3: cancelled in pass 2's first run)" end
        if not torn then return nil, why end
        if left ~= 0 then return nil, "tasks still scheduled" end
        if done_called then return nil, "on_done called" end
        if b.session or b.bb then return nil, "session or buffer kept" end
        return true
    end)

    -- 23-26. Visible-area requests: at fit every request is the whole framebuffer (byte for
    -- byte as before); zoomed in, the incremental requests carry the visible rect plus the
    -- margin, and the mock only sends changes inside it; panning sends one non-incremental
    -- request for the newly visible part, which then shows the server's pixels.
    local function view_session(name, opts)
        local Session = load_session()
        local W, H = 160, 120
        local pid, port, log = start_mock{
            name = name, encoding = "raw", pattern = "gradient", width = W, height = H,
            repaint = opts.repaint,
        }
        local s = Session.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = name },
            network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() end },
        }
        local env = { s = s, log = log, W = W, H = H, wire = {} }
        function env.done(ok, err)
            s:disconnect()
            stop_mock(pid)
            return ok, err
        end
        function env.pump_until(cond, what)
            local deadline = os.time() + 10
            while not cond() do
                if s:_pump() == "error" then error("pump failed: " .. tostring(s:get_error())) end
                if os.time() > deadline then error("timed out waiting for " .. what) end
                socket.sleep(0.01)
            end
        end
        function env.requests()
            local out = {}
            for _, m in ipairs(env.wire) do
                if m:byte(1) == 3 and #m == 10 then out[#out + 1] = m end
            end
            return out
        end
        local connected, cerr
        connect_sync(s, function(ok, err) connected, cerr = ok, err end)
        if not connected then env.done(); error("connect failed: " .. tostring(cerr)) end
        local write = s.proto.io.write
        s.proto.io.write = function(m) env.wire[#env.wire + 1] = m; return write(m) end
        s.app = { on_framebuffer_dirty = function() end, on_remote_resized = function() end,
                  on_bell = function() end }
        return env
    end
    local function req_bytes(inc, x, y, w, h)
        return string.char(3, inc) .. string.char(math.floor(x / 256), x % 256, math.floor(y / 256), y % 256,
            math.floor(w / 256), w % 256, math.floor(h / 256), h % 256)
    end
    local function first_update(env)
        env.s:request_full_update()
        env.s:_flush_now()
        env.pump_until(function() return env.s.dirty ~= nil end, "the first update")
        env.s.dirty = nil
        for _ = 1, 5 do env.s:_pump() end
    end
    -- Zooms the view to the top-left quarter of the 160x120 remote (canvas 160x120, scale 2).
    local function zoom_quarter(remote)
        remote:set_canvas(160, 120)
        remote:set_scale(2)
        remote.view_x, remote.view_y = 0, 0
        remote:set_canvas(160, 120)
    end

    -- Worker mode: the same session behind the workers; the requests are read from the mock's log.
    local function view_workers(name, opts, body)
        return function()
            local env = proxy_env()
            local v, s, mpid = { env = env, W = 160, H = 120, app = proxy_app() }, nil, nil
            local ok, err = pcall(function()
                s, mpid, v.log = proxy_session(env, name, { encoding = "raw", pattern = "gradient",
                    width = v.W, height = v.H, repaint = opts.repaint })
                v.s = s
                function v.requests()
                    local out = {}
                    for inc, x, y, w, h in (read_file(v.log) or ""):gmatch(
                            "FramebufferUpdateRequest incremental=(%d) x=(%d+) y=(%d+) w=(%d+) h=(%d+)") do
                        out[#out + 1] = req_bytes(tonumber(inc), tonumber(x), tonumber(y), tonumber(w), tonumber(h))
                    end
                    return out
                end
                function v.wait(cond, what)
                    if not env.run_until(cond, 10) then error("timed out waiting for " .. what) end
                end
                function v.idle(t) env.run_until(function() return false end, t) end
                body(v, s, s:get_remote())
            end)
            if s then s:disconnect() end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end
    end
    -- attach: the full request, then (once it is decoded) the first incremental one
    local function attach_first_update(v)
        local before = #v.requests()
        v.s:attach(v.app)
        v.wait(function() return #v.requests() >= before + 2 end, "the first update")
    end

    check("remote_visible_rect_fit_and_zoomed", function()
        local Remote = require("vncoxide/framebuffer")
        local r = Remote.new(160, 120)
        r:fit_view(320, 200)
        local a = r:visible_remote_rect()
        if not (a.x == 0 and a.y == 0 and a.w == 160 and a.h == 120) then
            r:free(); return nil, string.format("fit: got %d,%d %dx%d", a.x, a.y, a.w, a.h)
        end
        zoom_quarter(r)
        a = r:visible_remote_rect(0.25)
        local b = r:visible_remote_rect(0)
        r:free()
        if not (a.x == 0 and a.y == 0 and a.w == 100 and a.h == 75) then
            return nil, string.format("quarter + margin: got %d,%d %dx%d", a.x, a.y, a.w, a.h)
        end
        if not (b.x == 0 and b.y == 0 and b.w == 80 and b.h == 60) then
            return nil, string.format("quarter without margin: got %d,%d %dx%d", b.x, b.y, b.w, b.h)
        end
        return true
    end)

    both_modes("session_fit_requests_whole_framebuffer", function()
        local env = view_session("view_fit", {})
        local ok, err = pcall(function()
            local s, remote = env.s, env.s:get_remote()
            remote:fit_view(320, 200)
            s:set_view_area(remote:visible_remote_rect(s.REQUEST_MARGIN))
            if #env.requests() ~= 0 then error("a fit view must not send anything by itself") end
            first_update(env)
            local reqs = env.requests()
            if #reqs ~= 2 then error("expected the full request and one incremental, got " .. #reqs) end
            if reqs[1] ~= req_bytes(0, 0, 0, 160, 120) then error("full request bytes changed") end
            if reqs[2] ~= req_bytes(1, 0, 0, 160, 120) then error("incremental request is not the whole framebuffer") end
        end)
        return env.done(ok, err)
    end, view_workers("view_fit_w", {}, function(v, s, remote)
        remote:fit_view(320, 200)
        s:set_view_area(remote:visible_remote_rect(s.REQUEST_MARGIN))
        v.idle(0.2)
        if #v.requests() ~= 0 then error("a fit view must not send anything by itself") end
        attach_first_update(v)
        v.idle(0.2)
        local reqs = v.requests()
        if #reqs ~= 2 then error("expected the full request and one incremental, got " .. #reqs) end
        if reqs[1] ~= req_bytes(0, 0, 0, 160, 120) then error("full request bytes changed") end
        if reqs[2] ~= req_bytes(1, 0, 0, 160, 120) then error("incremental request is not the whole framebuffer") end
    end))

    both_modes("session_zoomed_requests_visible_area", function()
        local env = view_session("view_zoom", { repaint = 0.02 })
        local ok, err = pcall(function()
            local s, remote = env.s, env.s:get_remote()
            zoom_quarter(remote)
            s:set_view_area(remote:visible_remote_rect(s.REQUEST_MARGIN))
            if #env.requests() ~= 0 then error("zooming in needs no forced request, got " .. #env.requests()) end
            first_update(env)
            local n = 0
            env.pump_until(function()
                n = log_count(env.log, "REPAINT x=")
                return n >= 6
            end, "six repaints")
            local reqs = env.requests()
            if reqs[1] ~= req_bytes(0, 0, 0, 160, 120) then error("request_full_update must stay whole-framebuffer") end
            for i = 2, #reqs do
                if reqs[i] ~= req_bytes(1, 0, 0, 100, 75) then
                    error(string.format("request %d is not the incremental visible area + margin", i))
                end
            end
            -- (d) the mock honours the requested rect: every change it sent lies inside it
            local clipped = false
            for x, y, w, h in (read_file(env.log) or ""):gmatch("REPAINT x=(%d+) y=(%d+) w=(%d+) h=(%d+)") do
                x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
                if x + w > 100 or y + h > 75 then
                    error(string.format("change outside the requested rect: %d,%d %dx%d", x, y, w, h))
                end
                if w < 40 or h < 40 then clipped = true end
            end
            if not clipped then error("no repaint was clipped to the requested rect") end
        end)
        return env.done(ok, err)
    end, view_workers("view_zoom_w", { repaint = 0.02 }, function(v, s, remote)
        zoom_quarter(remote)
        s:set_view_area(remote:visible_remote_rect(s.REQUEST_MARGIN))
        v.idle(0.2)
        if #v.requests() ~= 0 then error("zooming in needs no forced request, got " .. #v.requests()) end
        attach_first_update(v)
        v.wait(function() return log_count(v.log, "REPAINT x=") >= 6 end, "six repaints")
        local reqs = v.requests()
        if reqs[1] ~= req_bytes(0, 0, 0, 160, 120) then error("the attach's full request must stay whole-framebuffer") end
        for i = 2, #reqs do
            if reqs[i] ~= req_bytes(1, 0, 0, 100, 75) then
                error(string.format("request %d is not the incremental visible area + margin", i))
            end
        end
        local clipped = false
        for x, y, w, h in (read_file(v.log) or ""):gmatch("REPAINT x=(%d+) y=(%d+) w=(%d+) h=(%d+)") do
            x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
            if x + w > 100 or y + h > 75 then
                error(string.format("change outside the requested rect: %d,%d %dx%d", x, y, w, h))
            end
            if w < 40 or h < 40 then clipped = true end
        end
        if not clipped then error("no repaint was clipped to the requested rect") end
    end))

    both_modes("session_pan_requests_newly_visible_area", function()
        local env = view_session("view_pan", {})
        local ok, err = pcall(function()
            local s, remote = env.s, env.s:get_remote()
            zoom_quarter(remote)
            s:set_view_area(remote:visible_remote_rect(s.REQUEST_MARGIN))
            first_update(env)
            -- stale pixels where the view is about to go: only the forced request can fix them
            local plane = remote:get_plane()
            plane:paintRect(60, 45, 100, 75, BB.COLOR_BLACK)
            if not check_plane(plane, 160, 120, function(x, y)
                if x == 159 and y == 119 then return 0, 0, 0 end
            end) then error("the stale area was not blanked") end
            local before = #env.requests()
            remote.view_x, remote.view_y = 80, 60
            remote:set_canvas(160, 120)
            local area = remote:visible_remote_rect(s.REQUEST_MARGIN)
            if not (area.x == 60 and area.y == 45 and area.w == 100 and area.h == 75) then
                error(string.format("bottom-right area: got %d,%d %dx%d", area.x, area.y, area.w, area.h))
            end
            s.attached = true -- as the viewer's session is
            local tx_before = #s.tx
            s:set_view_area(area)
            s:set_view_area(area) -- unchanged: nothing more
            local reqs = env.requests()
            if #reqs ~= before + 1 or reqs[#reqs] ~= req_bytes(0, 60, 45, 100, 75) then
                error("expected exactly one non-incremental request for the newly visible area")
            end
            -- written, not flushed: the next poll (its _pump) sends it
            if #s.tx ~= tx_before + 1 or s.tx[#s.tx] ~= req_bytes(0, 60, 45, 100, 75) then
                error("set_view_area must leave the request queued for the next poll, not flush it")
            end
            env.pump_until(function() return s.dirty ~= nil end, "the forced update")
            for _ = 1, 5 do s:_pump() end
            local cok, cerr = check_plane(remote:get_plane(), 160, 120, function(x, y)
                if x >= 60 and y >= 45 then return pattern_pixel("gradient", x, y, 160, 120) end
            end)
            if not cok then error(cerr) end
            reqs = env.requests()
            if reqs[#reqs] ~= req_bytes(1, 60, 45, 100, 75) then
                error("the follow-up incremental request must carry the new area")
            end
        end)
        return env.done(ok, err)
    end, view_workers("view_pan_w", {}, function(v, s, remote)
        zoom_quarter(remote)
        s:set_view_area(remote:visible_remote_rect(s.REQUEST_MARGIN))
        attach_first_update(v)
        v.idle(0.1)
        -- stale pixels where the view is about to go (the plane is shared with the decode worker)
        remote:get_plane():paintRect(60, 45, 100, 75, BB.COLOR_BLACK)
        local before = #v.requests()
        remote.view_x, remote.view_y = 80, 60
        remote:set_canvas(160, 120)
        local area = remote:visible_remote_rect(s.REQUEST_MARGIN)
        s:set_view_area(area)
        s:set_view_area(area) -- unchanged: nothing more
        v.wait(function() return #v.requests() >= before + 2 end, "the forced update and the next request")
        v.idle(0.2)
        local reqs = v.requests()
        if #reqs ~= before + 2 or reqs[before + 1] ~= req_bytes(0, 60, 45, 100, 75) then
            error("expected exactly one non-incremental request for the newly visible area")
        end
        if reqs[before + 2] ~= req_bytes(1, 60, 45, 100, 75) then
            error("the follow-up incremental request must carry the new area")
        end
        local cok, cerr = check_plane(remote:get_plane(), 160, 120, function(x, y)
            if x >= 60 and y >= 45 then return pattern_pixel("gradient", x, y, 160, 120) end
        end)
        if not cok then error(cerr) end
    end))

    -- Not attached (the viewer is closed): the newly visible area is only queued; attach's
    -- whole-screen request covers it.
    both_modes("session_view_area_queued_while_detached", function()
        local env = view_session("view_detached", {})
        local ok, err = pcall(function()
            local s, remote = env.s, env.s:get_remote()
            zoom_quarter(remote)
            s:set_view_area(remote:visible_remote_rect(s.REQUEST_MARGIN))
            first_update(env)
            local before = #env.requests()
            remote.view_x, remote.view_y = 80, 60
            remote:set_canvas(160, 120)
            s:set_view_area(remote:visible_remote_rect(s.REQUEST_MARGIN))
            if #env.requests() ~= before then error("nothing may be sent while detached") end
            if not s.forced then error("the newly visible area must stay owed") end
            s:attach(s.app)
            s:detach()
            local reqs = env.requests()
            if #reqs ~= before + 1 or reqs[#reqs] ~= req_bytes(0, 0, 0, 160, 120) then
                error("attach must send exactly its whole-screen request")
            end
            if s.forced then error("the whole-screen request covers the owed area") end
        end)
        return env.done(ok, err)
    end, view_workers("view_detached_w", {}, function(v, s, remote)
        zoom_quarter(remote)
        s:set_view_area(remote:visible_remote_rect(s.REQUEST_MARGIN))
        attach_first_update(v)
        s:detach()
        v.idle(0.1)
        local before = #v.requests()
        remote.view_x, remote.view_y = 80, 60
        remote:set_canvas(160, 120)
        s:set_view_area(remote:visible_remote_rect(s.REQUEST_MARGIN))
        v.idle(0.3)
        if #v.requests() ~= before then error("nothing may be sent while detached") end
        s:attach(v.app)
        v.wait(function() return #v.requests() >= before + 1 end, "the attach's request")
        v.idle(0.3)
        local reqs = v.requests()
        if reqs[before + 1] ~= req_bytes(0, 0, 0, 160, 120) then
            error("attach must send exactly its whole-screen request")
        end
        for i = before + 2, #reqs do
            if reqs[i]:byte(2) == 0 then error("the whole-screen request covers the owed area") end
        end
    end))

    -- The same with the decode worker taking attach's messages one at a time (a slow device
    -- can wake between two pipe writes): the area owed while detached must still be covered by
    -- the whole-screen request, not go out on its own first.
    check("session_view_area_queued_while_detached_workers_one_message_per_wakeup", view_workers(
        "view_detached_w1", {}, function(v, s, remote)
        zoom_quarter(remote)
        s:set_view_area(remote:visible_remote_rect(s.REQUEST_MARGIN))
        attach_first_update(v)
        s:detach()
        v.idle(0.1)
        local before = #v.requests()
        remote.view_x, remote.view_y = 80, 60
        remote:set_canvas(160, 120)
        s:set_view_area(remote:visible_remote_rect(s.REQUEST_MARGIN))
        v.idle(0.3)
        local decode = s.workers.decode
        local real_send = decode.send
        decode.send = function(h, ...)
            local r = real_send(h, ...)
            socket.sleep(0.3) -- the worker handles this message before the next is written
            return r
        end
        local ok, err = pcall(s.attach, s, v.app)
        decode.send = nil
        if not ok then error(err) end
        v.wait(function() return #v.requests() >= before + 1 end, "the attach's request")
        v.idle(0.3)
        local reqs = v.requests()
        if reqs[before + 1] ~= req_bytes(0, 0, 0, 160, 120) then
            error("attach must send exactly its whole-screen request")
        end
        for i = before + 2, #reqs do
            if reqs[i]:byte(2) == 0 then error("the whole-screen request covers the owed area") end
        end
    end))

    check("session_forced_area_waits_while_held", function()
        local env = view_session("view_hold", {})
        local Session = load_session()
        local real_now, clock = Session._now, 100
        Session._now = function() return clock end
        local ok, err = pcall(function()
            local s, remote = env.s, env.s:get_remote()
            zoom_quarter(remote)
            s:set_view_area(remote:visible_remote_rect(s.REQUEST_MARGIN))
            s:note_input()
            first_update(env)
            if not s.proto.update_pending then error("the incremental request should be held") end
            local before = #env.requests()
            remote.view_x, remote.view_y = 80, 60
            remote:set_canvas(160, 120)
            s.attached = true -- held by input, not by being detached
            s:set_view_area(remote:visible_remote_rect(s.REQUEST_MARGIN))
            if #env.requests() ~= before then error("nothing may be sent while input holds requests") end
            clock = 100 + Session.INPUT_QUIET + 0.1
            s:_poll()
            s.attached = false
            local reqs = env.requests()
            -- the owed incremental and the forced one merge into one non-incremental request
            if #reqs ~= before + 1 or reqs[#reqs] ~= req_bytes(0, 60, 45, 100, 75) then
                error("expected one non-incremental request of the union once quiet")
            end
            if s.proto.update_pending then error("the merged request settles the owed one") end
        end)
        Session._now = real_now
        return env.done(ok, err)
    end)

    check("protocol_request_area_provider", function()
        local out = {}
        local proto = Protocol.new{ io = { write = function(s) out[#out + 1] = s end, read = function() end },
            request_area = function() return 1, 2, 3, 4 end }
        proto.width, proto.height, proto.update_pending = 10, 20, true
        proto:release_update()
        proto:free()
        if #out ~= 1 or out[1] ~= "\3\1\0\1\0\2\0\3\0\4" then
            return nil, "release must request the provider's area"
        end
        return true
    end)

    -- ------------------------------------------------------------ connect never blocks the UI

    -- A stand-in UIManager on a fake clock (like the benchmark's): runs scheduled tasks in time
    -- order and moves the clock to each one's due time. `at(t, fn)` runs fn once the clock reaches t.
    local function clock_env()
        local Session = load_session()
        local UIManager = require("ui/uimanager")
        local real_now, real_si, real_un = Session._now, UIManager.scheduleIn, UIManager.unschedule
        local env = { clock = 100, tasks = {}, Session = Session }
        Session._now = function() return env.clock end
        UIManager.scheduleIn = function(_, delay, fn, ...)
            env.tasks[#env.tasks + 1] = { t = env.clock + delay, fn = fn, args = { ... }, n = select("#", ...) }
        end
        UIManager.unschedule = function(_, fn)
            for i = #env.tasks, 1, -1 do
                if env.tasks[i].fn == fn then table.remove(env.tasks, i) end
            end
        end
        function env.run(stop, max_steps)
            for _ = 1, max_steps or 5000 do
                if stop and stop() then return true end
                if #env.tasks == 0 then return false end
                local best = 1
                for i = 2, #env.tasks do
                    if env.tasks[i].t < env.tasks[best].t then best = i end
                end
                local task = table.remove(env.tasks, best)
                env.clock = math.max(env.clock, task.t)
                task.fn(unpack(task.args, 1, task.n))
                socket.sleep(0.001)
            end
            return false
        end
        function env.restore()
            Session._now, UIManager.scheduleIn, UIManager.unschedule = real_now, real_si, real_un
        end
        return env
    end

    -- Times every connect tick against a peer that never answers: connect() and each tick must
    -- return at once, and the attempt must end (once) by itself after its deadline.
    local function time_a_dead_attempt(host, port, what)
        local Session = load_session()
        local saved = { Session.CONNECT_TIMEOUT, Session.HANDSHAKE_TIMEOUT, Session.HANDSHAKE_SOCKET_TIMEOUT }
        Session.CONNECT_TIMEOUT, Session.HANDSHAKE_TIMEOUT, Session.HANDSHAKE_SOCKET_TIMEOUT = 0.5, 1, 0.3
        local s = Session.new{
            profile = { host = host, port = port, password = "", name = what },
            network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() end },
        }
        local calls, err = 0, nil
        local t0 = socket.gettime()
        s:connect(function(ok, e) calls = calls + 1; if not ok then err = e end end)
        local longest = socket.gettime() - t0
        local deadline = t0 + 10
        while s._phase and socket.gettime() < deadline do
            local t = socket.gettime()
            s:_connect_tick()
            longest = math.max(longest, socket.gettime() - t)
            socket.sleep(0.01)
        end
        local total = socket.gettime() - t0
        Session.CONNECT_TIMEOUT, Session.HANDSHAKE_TIMEOUT, Session.HANDSHAKE_SOCKET_TIMEOUT = unpack(saved)
        if s:get_state() == "connecting" then s:disconnect() end
        if longest > 0.1 then
            return nil, string.format("%s: the UI thread was held %.2f s in one go", what, longest)
        end
        if calls ~= 1 or not err then
            return nil, string.format("%s: callback ran %d time(s), err %s", what, calls, tostring(err))
        end
        if total > 3 then return nil, string.format("%s: took %.1f s to give up", what, total) end
        return true, err
    end

    -- A blackholed address (no SYN-ACK, no ICMP): the TCP connect used to block for its 5 s timeout
    -- (and the reconnect box's Retry froze the UI for that long).
    check("session_tcp_connect_never_blocks_the_ui_thread", function()
        local ok, err = time_a_dead_attempt("10.255.255.1", 5900, "blackhole")
        if not ok then return nil, err end
        if not (err:find("could not connect", 1, true) or err:find("unreachable", 1, true)) then
            return nil, "unclear error: " .. err
        end
        return true
    end)

    -- A server that accepts but never speaks: the handshake used to spin the UI thread for 20 s.
    check("session_handshake_never_blocks_the_ui_thread", function()
        local listener = assert(socket.bind("127.0.0.1", 0))
        local _, port = listener:getsockname()
        local ok, err = time_a_dead_attempt("127.0.0.1", tonumber(port), "silent")
        listener:close()
        if not ok then return nil, err end
        if not err:find("timed out during the RFB handshake", 1, true) then return nil, "unclear error: " .. err end
        return true
    end)

    -- A closed port still fails with the refusal, through the ticks.
    check("session_refused_connect_reports_the_refusal", function()
        local Session = load_session()
        local s = Session.new{
            profile = { host = "127.0.0.1", port = free_port(), password = "", name = "refused2" },
            network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() end },
        }
        local calls, err = 0, nil
        connect_sync(s, function(ok, e) calls = calls + 1; err = e end)
        if s:get_state() ~= "error" or calls ~= 1 then
            return nil, "state " .. tostring(s:get_state()) .. ", " .. calls .. " callback(s)"
        end
        if not tostring(err):find("connection refused", 1, true) then return nil, "unclear error: " .. tostring(err) end
        return s.sock == nil, "the socket is dropped"
    end)

    -- PocketBook's isWifiOn is QueryNetwork's NET_CONNECTED, which can hold with no route (KOReader's
    -- own PocketBook NetworkMgr:init waits for the route separately). Dialling then only fails, and
    -- every retry dials into the same dead network: such a link is brought up like a missing one.
    check("session_brings_up_a_wifi_link_that_has_no_route", function()
        local Session = load_session()
        local ons, offs = 0, 0
        local net = {
            isWifiOn = function() return true end,
            isConnected = function() return false end,
            turnOnWifiAndWaitForConnection = function() ons = ons + 1; return {} end,
            turnOffWifi = function() offs = offs + 1 end,
        }
        local s = Session.new{ profile = { host = "127.0.0.1", port = free_port(), password = "", name = "noroute" },
            network_mgr = net }
        s:connect(function() end)
        local state, sock = s:get_state(), s.sock
        s:disconnect()
        if ons ~= 1 then return nil, "Wi-Fi was not brought up (" .. ons .. " request(s)), state " .. tostring(state) end
        if sock then return nil, "it dialled into a network without a route" end
        if offs ~= 0 then return nil, "Wi-Fi it did not turn on must not be turned off" end
        return true
    end)

    -- NetworkMgr answers EBUSY (no return value, and no callback ever) while an earlier attempt of
    -- its own is pending; that one may well bring the link up. The attempt used to sit out the whole
    -- 30 s Wi-Fi timeout regardless: it now dials as soon as the link is up.
    check("session_dials_once_the_link_is_up_even_without_a_wifi_callback", function()
        local env = clock_env()
        local Session = env.Session
        local up_at = env.clock + 3
        local function up() return env.clock >= up_at end
        local net = {
            isWifiOn = function() return up() end,
            isConnected = function() return up() end,
            turnOnWifiAndWaitForConnection = function() return nil end, -- EBUSY
            turnOffWifi = function() end,
        }
        local s = Session.new{ profile = { host = "127.0.0.1", port = free_port(), password = "", name = "ebusy" },
            network_mgr = net }
        local err, calls = nil, 0
        local t0 = env.clock
        s:connect(function(ok, e) calls = calls + 1; err = e end)
        env.run(function() return calls > 0 end)
        local took = env.clock - t0
        env.restore()
        if calls ~= 1 then return nil, "the attempt never ended (" .. calls .. " callbacks)" end
        if not tostring(err):find("could not connect", 1, true) then
            return nil, string.format("it did not dial once the link was up (after %.1f s): %s", took, tostring(err))
        end
        if took > 5 then return nil, string.format("it dialled %.1f s after the start, the link was up at 3 s", took) end
        return true
    end)

    -- The link comes up before NetworkMgr's connectivity check calls back: the session dials on its
    -- own, and the late callback must not dial a second time.
    check("session_ignores_the_wifi_callback_once_it_dialled", function()
        local env = clock_env()
        local Session = env.Session
        local listener = assert(socket.bind("127.0.0.1", 0)) -- accepts, never speaks
        local _, port = listener:getsockname()
        local up_at, cb = env.clock + 2, nil
        local function up() return env.clock >= up_at end
        local net = {
            isWifiOn = function() return up() end,
            isConnected = function() return up() end,
            turnOnWifiAndWaitForConnection = function(_, f) cb = f; return {} end,
            turnOffWifi = function() end,
        }
        local s = Session.new{ profile = { host = "127.0.0.1", port = tonumber(port), password = "", name = "late2" },
            network_mgr = net }
        s:connect(function() end)
        env.run(function() return s.sock ~= nil end)
        local sock = s.sock
        if cb then cb() end
        local same = s.sock == sock
        s:disconnect()
        env.restore()
        listener:close()
        if not sock then return nil, "it never dialled" end
        if not same then return nil, "the late Wi-Fi callback dialled again" end
        return true
    end)

    -- Wi-Fi going away under a live connection (KOReader turns it off on suspend) reports nothing:
    -- the socket just goes quiet. TCP keepalive makes the kernel notice and fail the receive.
    check("session_turns_on_tcp_keepalive", function()
        local Session = load_session()
        local listener = assert(socket.bind("127.0.0.1", 0))
        local _, port = listener:getsockname()
        local real_tcp, opts = socket.tcp, {}
        socket.tcp = function()
            local sock = real_tcp()
            return setmetatable({
                setoption = function(_, k, v) opts[k] = v; return sock:setoption(k, v) end,
            }, {
                __index = function(_, k)
                    local v = sock[k]
                    if type(v) == "function" then return function(_, ...) return v(sock, ...) end end
                    return v
                end,
            })
        end
        local s = Session.new{ profile = { host = "127.0.0.1", port = tonumber(port), password = "", name = "ka" },
            network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() end } }
        local ok, err = pcall(s.connect, s, function() end)
        socket.tcp = real_tcp
        s:disconnect()
        listener:close()
        if not ok then return nil, err end
        if opts.keepalive ~= true then return nil, "keepalive is off" end
        if not (opts["tcp-keepidle"] and opts["tcp-keepidle"] <= 60) then
            return nil, "the idle time before the first probe is the kernel's (2 h): " .. tostring(opts["tcp-keepidle"])
        end
        return true
    end)

    -- The protocol object exists from the dial on, but nothing may be queued before the handshake
    -- is over (input or a picture request from a timer of the viewer's would go out in the middle
    -- of the handshake, or on a socket that is not connected yet).
    check("session_sends_nothing_before_the_handshake_is_over", function()
        local Session = load_session()
        local listener = assert(socket.bind("127.0.0.1", 0)) -- accepts, never speaks
        local _, port = listener:getsockname()
        local s = Session.new{ profile = { host = "127.0.0.1", port = tonumber(port), password = "", name = "early" },
            network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() end } }
        s.remote = require("vncoxide/framebuffer").new(8, 8) -- the previous connection's picture, kept for the reconnect
        s:connect(function() end)
        local written, write = 0, s.proto.io.write
        s.proto.io.write = function(m) written = written + 1; return write(m) end
        local phases = {}
        for _ = 1, 3 do
            phases[#phases + 1] = tostring(s._phase)
            s:send_pointer(1, 1, 1); s:send_key(0x61, true); s:send_cut_text("x"); s:request_full_update()
            s:_connect_tick()
            socket.sleep(0.01)
        end
        local queued, state = written, s:get_state()
        s:disconnect()
        listener:close()
        if queued ~= 0 then
            return nil, string.format("%d message(s) queued in phases %s", queued, table.concat(phases, ","))
        end
        return state == "connecting", "state " .. tostring(state)
    end)

    -- A drop that a listener answers by retrying (the viewer's reconnect box sets retry mode from
    -- its error handler) keeps Wi-Fi on: it used to be turned off first, and the very next attempt
    -- had to bring it up again.
    check("session_drop_keeps_wifi_for_a_listener_that_retries", function()
        local Session = load_session()
        local offs = 0
        local s
        s = Session.new{
            profile = { host = "127.0.0.1", port = 1, password = "", name = "drop" },
            network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() offs = offs + 1 end },
            on_state = function(state) if state == "error" then s:set_keep_wifi(true) end end,
        }
        s.state, s.wifi_was_on = "connected", false -- connected over Wi-Fi it turned on
        s:_fail("connection closed by server")
        if offs ~= 0 then return nil, "the drop turned Wi-Fi off before the retry loop could keep it" end
        s:set_keep_wifi(false)
        if offs ~= 1 then return nil, "the loop ending must hand the duty back, offs " .. offs end
        -- without a listener that retries, a drop still restores Wi-Fi at once
        local t = Session.new{
            profile = { host = "127.0.0.1", port = 1, password = "", name = "drop2" },
            network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() offs = offs + 1 end },
        }
        t.state, t.wifi_was_on = "connected", false
        t:_fail("x")
        if offs ~= 2 then return nil, "a plain drop must restore Wi-Fi" end
        return true
    end)

    -- ------------------------------------------------------------ receive path (FFI recv)
    -- The session receives into one byte buffer with `recv`. These checks run it against a Lua
    -- loopback peer that writes a scripted server stream in chosen pieces, pumping the session
    -- after each piece, and compare what it decoded with a run that got the stream in one piece.
    do
        local Util = require("vncoxide/util")
        local W, H = 64, 48
        local function rnd_bytes(n, seed)
            math.randomseed(seed)
            local t = {}
            for i = 1, n do t[i] = string.char(math.random(0, 255)) end
            return table.concat(t)
        end
        local function rect(w, x, y, rw, rh, enc)
            return w:u16(x):u16(y):u16(rw):u16(rh):u32(enc % 4294967296)
        end
        --- The server's bytes: a security-None 3.8 handshake, then updates exercising every kind
        --- of read (u8/u16/u32 fields, row pointers, CopyRect, RRE, Bell, cut text).
        local function script(cut)
            local w = Util.writer():raw("RFB 003.008\n"):u8(1):u8(1):u32(0)
                :u16(W):u16(H):raw(string.rep("\0", 16)):u32(6):raw("rxtest")
            -- update 1: the whole screen as Raw
            w:u8(0):u8(0):u16(1)
            rect(w, 0, 0, W, H, 0):raw(rnd_bytes(W * H * 4, 7))
            -- a Bell and a cut text between updates
            w:u8(2):u8(3):raw("\0\0\0"):u32(#cut):raw(cut)
            -- update 2: RRE with subrects, a CopyRect and a small Raw
            w:u8(0):u8(0):u16(3)
            rect(w, 8, 8, 32, 24, 2):u32(3):raw("\1\2\3\0")
            for k = 0, 2 do w:raw(string.char(40 * k, 255 - k, 9 * k, 0)):u16(k * 3):u16(k * 2):u16(7):u16(5) end
            rect(w, 40, 30, 16, 12, 1):u16(0):u16(0)
            rect(w, 1, 40, 9, 7, 0):raw(rnd_bytes(9 * 7 * 4, 11))
            return w:tostring()
        end

        --- A session connected to a loopback peer; returns the session, the peer and what it saw.
        local function rig(Session)
            local listener = assert(socket.bind("127.0.0.1", 0))
            local _, port = listener:getsockname()
            local seen = { bells = 0, cuts = {}, updates = 0 }
            local s = Session.new{
                profile = { host = "127.0.0.1", port = tonumber(port), password = "", name = "rx" },
                network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() end },
                on_update = function() seen.updates = seen.updates + 1 end,
            }
            -- record the largest the receive buffer got
            local reserve = Session._rx_reserve
            s._rx_reserve = function(self, n)
                local a, b = reserve(self, n)
                self._rx_cap_max = math.max(self._rx_cap_max or 0, self.rcap or 0)
                return a, b
            end
            s:connect(function() end)
            listener:settimeout(5)
            local peer = assert(listener:accept())
            listener:close()
            peer:settimeout(0)
            s.app = { on_framebuffer_dirty = function() end, on_remote_resized = function() end,
                on_bell = function() seen.bells = seen.bells + 1 end }
            return s, peer, seen
        end
        --- Pumps until the session has taken everything it was sent (or failed).
        local function drive(s, peer, final)
            for _ = 1, 100000 do
                peer:receive(65536) -- drop the client's messages, so its sends never block
                local st
                if s._phase then
                    s:_connect_tick()
                    st = s._phase and "again" or (s.sock and "busy" or "error")
                else
                    st = s.sock and s:_pump() or "error"
                end
                if st == "error" or st == "done" then return st end
                if st == "again" then
                    local r = socket.select({ s.sock }, nil, final and 0.2 or 0)
                    if not (r and r[1]) then return st end
                end
            end
            return "stuck"
        end
        local function hook_cut(s, seen)
            if s.proto and not s._cut_hooked then
                s._cut_hooked = true
                s.proto.callbacks.on_cut_text = function(t) seen.cuts[#seen.cuts + 1] = t end
            end
        end
        --- Runs the stream split at `cuts` (sorted byte offsets); returns plane bytes and `seen`.
        local function run_split(stream, splits, keep_open)
            local Session = load_session()
            local s, peer, seen = rig(Session)
            hook_cut(s, seen)
            local pos, again_mid = 1, 0
            for _, at in ipairs(splits) do
                if at > pos then
                    assert(peer:send(stream:sub(pos, at - 1)))
                    pos = at
                    local st = drive(s, peer)
                    if st == "error" then break end
                    if st == "again" then again_mid = again_mid + 1 end
                end
            end
            if s.sock and pos <= #stream then
                peer:settimeout(5)
                assert(peer:send(stream:sub(pos)))
                peer:settimeout(0)
                drive(s, peer, true)
            end
            local plane = s.remote and ffi.string(s.remote:get_plane().data, W * H * 3)
            local res = { plane = plane, seen = seen, err = s:get_error(), state = s:get_state(),
                again_mid = again_mid, rcap_max = s._rx_cap_max, rcap = s.rcap, sess = s, peer = peer }
            if not keep_open then peer:close() end
            return res
        end
        local function same(a, b)
            if a.err or b.err then return nil, "errors: " .. tostring(a.err) .. " / " .. tostring(b.err) end
            if not a.plane or a.plane ~= b.plane then return nil, "planes differ" end
            if a.seen.bells ~= b.seen.bells then return nil, "bells " .. a.seen.bells .. " vs " .. b.seen.bells end
            if a.seen.updates ~= b.seen.updates then return nil, "updates " .. a.seen.updates .. " vs " .. b.seen.updates end
            if #a.seen.cuts ~= #b.seen.cuts then return nil, "cut texts " .. #a.seen.cuts .. " vs " .. #b.seen.cuts end
            for i = 1, #a.seen.cuts do
                if a.seen.cuts[i] ~= b.seen.cuts[i] then return nil, "cut text " .. i .. " differs" end
            end
            return true
        end
        local stream = script("hello, clipboard")
        local ref
        check("session_rx_whole_stream", function()
            ref = run_split(stream, {})
            if ref.err then return nil, ref.err end
            if ref.seen.updates ~= 2 then return nil, "updates decoded: " .. ref.seen.updates end
            if ref.seen.bells ~= 1 or ref.seen.cuts[1] ~= "hello, clipboard" then return nil, "bell/cut text lost" end
            return true
        end)
        check("session_rx_random_splits_are_byte_identical", function()
            if not ref then return nil, "no reference run" end
            for seed = 1, 6 do
                math.randomseed(seed * 7919)
                local splits = {}
                for i = 1, 40 do splits[i] = math.random(2, #stream) end
                table.sort(splits)
                local got = run_split(stream, splits)
                local ok, err = same(got, ref)
                if not ok then return nil, "seed " .. seed .. ": " .. err end
            end
            return true
        end)
        check("session_rx_one_byte_splits_are_byte_identical", function()
            if not ref then return nil, "no reference run" end
            local splits = {}
            for i = 2, #stream do splits[#splits + 1] = i end
            local got = run_split(stream, splits)
            local ok, err = same(got, ref)
            if not ok then return nil, err end
            -- every byte up to the end of the stream left a field incomplete, so most pumps ended
            -- in "again" (EAGAIN) rather than an error
            if got.again_mid < #stream / 2 then return nil, "too few EAGAIN pauses: " .. got.again_mid end
            return true
        end)
        check("session_rx_again_mid_field_keeps_the_connection", function()
            -- ServerInit's name length is a u32 at offset 12+2+4+20 = 38: stop two bytes into it
            local got = run_split(stream:sub(1, 40), { 41 }, true)
            if got.err or got.state ~= "connecting" then
                return nil, "half a u32 must just wait: " .. tostring(got.state) .. " " .. tostring(got.err)
            end
            local s = got.sess
            s:_connect_tick()
            if s:get_state() ~= "connecting" then return nil, "a pump with no data failed it" end
            s:disconnect()
            got.peer:close()
            return true
        end)
        for _, how in ipairs({ "fin", "rst" }) do
        check("session_rx_close_mid_update_fails_as_closed_by_server_" .. how, function()
            local Session = load_session()
            local s, peer = rig(Session)
            -- (a zero linger time makes close() reset the connection, as a killed server does)
            if how == "rst" then assert(peer:setoption("linger", { on = true, timeout = 0 })) end
            -- the handshake and half of the first update's pixels
            assert(peer:send(stream:sub(1, 1000)))
            drive(s, peer, true)
            if s:get_state() ~= "connected" then return nil, "not connected: " .. tostring(s:get_error()) end
            if not s.in_update then return nil, "the update should be half received" end
            peer:close()
            local st
            for _ = 1, 50 do
                st = s:_pump()
                if st == "error" then break end
                socket.select(nil, nil, 0.01)
            end
            if st ~= "error" then return nil, "pump after close: " .. tostring(st) end
            if s:get_error() ~= "connection closed by server" then return nil, "error: " .. tostring(s:get_error()) end
            if s.rbuf ~= nil or s.rcap ~= 0 then return nil, "receive buffer not freed on teardown" end
            return true
        end)
        end
        check("session_rx_large_read_grows_then_shrinks_the_buffer", function()
            local Session = load_session()
            local big = rnd_bytes(Session.RX_BUFFER * 5 + 123, 5)
            local s2 = script(big)
            local r1 = run_split(s2, {})
            if r1.err then return nil, r1.err end
            if r1.seen.cuts[1] ~= big then return nil, "the large cut text arrived changed" end
            math.randomseed(4242)
            local splits = {}
            for i = 1, 300 do splits[i] = math.random(2, #s2) end
            table.sort(splits)
            local r2 = run_split(s2, splits)
            local ok, err = same(r2, r1)
            if not ok then return nil, "split run: " .. err end
            if not (r2.rcap_max and r2.rcap_max >= #big) then
                return nil, "the buffer never grew to the large read: " .. tostring(r2.rcap_max)
            end
            if r2.rcap ~= Session.RX_BUFFER then
                return nil, "the buffer did not shrink back after the large read: " .. tostring(r2.rcap)
            end
            r2.sess:disconnect()
            r1.sess:disconnect()
            return true
        end)
        check("session_rx_rejects_a_read_over_the_cap", function()
            local Session = load_session()
            local saved, saved_buf = Session.MAX_RX_BUFFER, Session.RX_BUFFER
            Session.MAX_RX_BUFFER, Session.RX_BUFFER = 4096, 1024
            local r = run_split(script(rnd_bytes(5000, 3)), {})
            Session.MAX_RX_BUFFER, Session.RX_BUFFER = saved, saved_buf
            if r.state ~= "error" or not tostring(r.err):find("4096", 1, true) then
                return nil, "state " .. tostring(r.state) .. " err " .. tostring(r.err)
            end
            return true
        end)
        check("shared_memory_is_shared_across_fork", function()
            local SharedMem = require("vncoxide/sharedmem")
            local ffiutil = require("ffi/util")
            local bytes = 64 * 32 * 3
            local ptr = SharedMem.alloc(bytes)
            local bb = SharedMem.bb(ptr, 64, 32, BB.TYPE_BBRGB24)
            bb:fill(BB.COLOR_BLACK)
            local pid = ffiutil.runInSubProcess(function()
                bb:setPixel(5, 7, BB.ColorRGB24(1, 2, 3))
                return 0
            end)
            ffiutil.isSubProcessDone(pid, true)
            local c = bb:getPixel(5, 7):getColorRGB24()
            local ok = c.r == 1 and c.g == 2 and c.b == 3
            SharedMem.free(ptr, bytes)
            if not ok then return nil, string.format("got %d,%d,%d", c.r, c.g, c.b) end
            return true
        end)
    end

    -- Worker processes (vncoxide/worker.lua): forked over a line protocol, descriptor hygiene, nice.
    do
        local ESRCH = 3
        local function alive(pid)
            if ffi.C.kill(pid, 0) == 0 then return true end
            return ffi.errno() ~= ESRCH
        end
        local function wait_gone(pid, timeout)
            local deadline = socket.gettime() + timeout
            while socket.gettime() < deadline do
                if not alive(pid) then return true end
                socket.sleep(0.01)
            end
            return not alive(pid)
        end
        -- Collects polled messages until `want(msgs)` holds or `timeout` passes.
        local function poll_until(w, want, timeout, msgs)
            msgs = msgs or {}
            local deadline = socket.gettime() + timeout
            repeat
                local lines, eof = w:poll()
                for _, l in ipairs(lines) do msgs[#msgs + 1] = l end
                if want(msgs) then return msgs end
                if eof then break end
                socket.sleep(0.005)
            until socket.gettime() > deadline
            return msgs
        end
        local function has_hello(msgs) return msgs[1] ~= nil end
        -- Echoes every message (a payload message with its payload); "FD" answers its pipe fds.
        local function echo_main(ctx)
            while true do
                local lines = ctx.recv(1)
                if not lines then return end
                local i = 1
                while i <= #lines do
                    local l = lines[i]
                    if l == "FD" then
                        ctx.send(string.format("FD %d %d", ctx.read_fd, ctx.write_fd))
                    elseif l:match("^T ") then
                        i = i + 1
                        if not lines[i] then error("a payload header came without its payload") end
                        ctx.send(l, lines[i])
                    else
                        ctx.send(l)
                    end
                    i = i + 1
                end
            end
        end
        -- Stops `w` with the SIGKILL task run at once, so no worker outlives its check.
        local function kill_worker(w)
            load_session()
            local UIManager = require("ui/uimanager")
            local real_si = UIManager.scheduleIn
            local tasks = {}
            UIManager.scheduleIn = function(_, _, fn, ...) tasks[#tasks + 1] = { fn, ... } end
            pcall(w.stop, w)
            UIManager.scheduleIn = real_si
            for _, t in ipairs(tasks) do t[1](unpack(t, 2)) end
            if w.pid then wait_gone(w.pid, 2) end
        end
        local function spawn_echo(keep_fds)
            local Worker = require("vncoxide/worker")
            local w, err = Worker.spawn("echo", echo_main, keep_fds)
            if not w then error("spawn failed: " .. tostring(err)) end
            return w, Worker
        end

        -- stop() with the plugin's scheduler on the real clock; returns the scheduled tasks.
        local function stop_on_real_clock(w)
            load_session()
            local UIManager = require("ui/uimanager")
            local real_si = UIManager.scheduleIn
            local tasks = {}
            UIManager.scheduleIn = function(_, delay, fn, ...)
                tasks[#tasks + 1] = { t = socket.gettime() + delay, fn = fn, args = { ... } }
            end
            local ok, err = pcall(w.stop, w)
            UIManager.scheduleIn = real_si
            if not ok then error(err) end
            return tasks
        end
        -- Runs due tasks until `pid` is gone or `deadline`; true when gone.
        local function run_tasks_until_gone(tasks, pid, deadline)
            while socket.gettime() < deadline do
                for i = #tasks, 1, -1 do
                    if tasks[i].t <= socket.gettime() then
                        local task = table.remove(tasks, i)
                        task.fn(unpack(task.args))
                    end
                end
                if not alive(pid) then return true end
                socket.sleep(0.01)
            end
            return not alive(pid)
        end
        -- Bytes 0-255 repeated (newlines included) up to `n`.
        local function big_payload(n)
            local t = {}
            for i = 0, 255 do t[#t + 1] = string.char(i) end
            local block = table.concat(t)
            return block:rep(math.ceil(n / 256)):sub(1, n)
        end

        check("worker_codec_holds_a_header_until_its_payload", function()
            local Worker = require("vncoxide/worker")
            local stream = "H 12\nT 5\na\nb cX 1 2\nT 0\nT 3\nT 1Y\nQ\n"
            local want = { "H 12", "T 5", "a\nb c", "X 1 2", "T 0", "", "T 3", "T 1", "Y", "Q" }
            local r = Worker.Reader.new()
            local got = {}
            for i = 1, #stream do
                r:feed(stream:sub(i, i))
                local out = r:take()
                local j = 1
                while j <= #out do
                    got[#got + 1] = out[j]
                    if out[j]:match("^T %d+$") then
                        if out[j + 1] == nil then
                            return nil, "header " .. out[j] .. " returned without its payload"
                        end
                        got[#got + 1] = out[j + 1]
                        j = j + 1
                    end
                    j = j + 1
                end
            end
            if table.concat(got, "|") ~= table.concat(want, "|") then
                return nil, "got " .. table.concat(got, "|")
            end
            if not r.quit then return nil, "Q not seen" end
            -- A payload spanning reads: nothing until all of it arrived.
            r = Worker.Reader.new()
            r:feed("T 3\nab")
            if #r:take() ~= 0 then return nil, "partial payload delivered" end
            r:feed("cX\n")
            local out = r:take()
            if table.concat(out, "|") ~= "T 3|abc|X" then return nil, "split: " .. table.concat(out, "|") end
            return true
        end)

        check("worker_large_payloads_round_trip", function()
            local w = spawn_echo()
            local ok, res, err = pcall(function()
                poll_until(w, has_hello, 2)
                if not w.pid then return nil, "no hello" end
                local payload = big_payload(200 * 1024 + 7)
                local t0 = socket.gettime()
                w:send("T " .. #payload, payload)
                w:send("X 9")
                local dt = socket.gettime() - t0
                if dt > 0.1 then return nil, string.format("send blocked %.3f s", dt) end
                local msgs = poll_until(w, function(m) return #m >= 3 end, 5, {})
                if msgs[1] ~= "T " .. #payload or msgs[2] ~= payload or msgs[3] ~= "X 9" then
                    return nil, string.format("got %d messages, first %s, payload %s", #msgs,
                        tostring(msgs[1]), tostring(msgs[2] == payload))
                end
                return true
            end)
            kill_worker(w)
            if not ok then return nil, res end
            return res, err
        end)

        check("worker_send_never_blocks_the_ui", function()
            local Worker = require("vncoxide/worker")
            -- Reads nothing for 0.5 s, then answers each payload with its length.
            local w = assert(Worker.spawn("slow", function(ctx)
                socket.sleep(0.5)
                while true do
                    local lines = ctx.recv(1)
                    if not lines then return end
                    for i, l in ipairs(lines) do
                        if l:match("^T %d+$") then ctx.send("LEN " .. #lines[i + 1]) end
                    end
                end
            end))
            local ok, res, err = pcall(function()
                poll_until(w, has_hello, 2)
                if not w.pid then return nil, "no hello" end
                local n = 300 * 1024
                local t0 = socket.gettime()
                w:send("T " .. n, big_payload(n))
                local dt = socket.gettime() - t0
                if dt > 0.1 then return nil, string.format("send blocked %.3f s", dt) end
                if w:pending() == 0 then return nil, "nothing queued: the pipe took 300 KiB?" end
                local msgs = poll_until(w, function(m) return m[1] ~= nil end, 5, {})
                if msgs[1] ~= "LEN " .. n then return nil, "answer " .. tostring(msgs[1]) end
                if w:pending() ~= 0 then return nil, "still queued " .. w:pending() end
                return true
            end)
            kill_worker(w)
            if not ok then return nil, res end
            return res, err
        end)

        check("stop_never_blocks_on_a_full_pipe", function()
            local Worker = require("vncoxide/worker")
            Worker._test_ignore_quit = true
            local w = assert(Worker.spawn("deaf", function()
                while true do socket.sleep(1) end
            end))
            Worker._test_ignore_quit = nil
            poll_until(w, has_hello, 2)
            local pid = w.pid
            if not pid then kill_worker(w); return nil, "no hello" end
            w:send("T " .. 1024 * 1024, big_payload(1024 * 1024))
            local t0 = socket.gettime()
            local tasks = stop_on_real_clock(w)
            local dt = socket.gettime() - t0
            local gone = run_tasks_until_gone(tasks, pid, t0 + Worker.KILL_AFTER + 1)
            if not gone then ffi.C.kill(pid, 9); wait_gone(pid, 2) end
            if dt > 0.1 then return nil, string.format("stop blocked %.3f s", dt) end
            if #tasks > 0 and not gone then return nil, "kill never ran" end
            if not gone then return nil, "worker still running after KILL_AFTER + 1 s" end
            return true
        end)

        check("worker_round_trip", function()
            local w = spawn_echo()
            local ok, res, err = pcall(function()
                local msgs = poll_until(w, has_hello, 2)
                local pid = tonumber((msgs[1] or ""):match("^H (%d+)$"))
                if not pid then return nil, "first message: " .. tostring(msgs[1]) end
                if w.pid ~= pid or not alive(pid) then return nil, "pid " .. pid .. " not live / not w.pid" end
                local t0 = socket.gettime()
                w:send("X 1 2")
                w:send("T 5", "a\nb c")
                msgs = poll_until(w, function(m) return #m >= 3 end, 1, {})
                if socket.gettime() - t0 > 1 then return nil, "echo took over 1 s" end
                if msgs[1] ~= "X 1 2" or msgs[2] ~= "T 5" or msgs[3] ~= "a\nb c" then
                    return nil, "echoed: " .. table.concat(msgs, "|")
                end
                return true
            end)
            kill_worker(w)
            if not ok then return nil, res end
            return res, err
        end)

        check("workers_exit_when_the_ui_pipe_closes", function()
            local w = spawn_echo()
            local msgs = poll_until(w, has_hello, 2)
            local pid = w.pid
            if not pid then kill_worker(w); return nil, "no hello: " .. tostring(msgs[1]) end
            ffi.C.close(w.write_fd)
            ffi.C.close(w.read_fd)
            local gone = wait_gone(pid, 2)
            if not gone then ffi.C.kill(pid, 9); wait_gone(pid, 2); return nil, "worker still running" end
            return true
        end)

        check("hangup_kills_a_stuck_worker", function()
            local Worker = require("vncoxide/worker")
            Worker._test_ignore_quit = true
            local w = spawn_echo()
            Worker._test_ignore_quit = nil
            poll_until(w, has_hello, 2)
            local pid = w.pid
            if not pid then kill_worker(w); return nil, "no hello" end
            local t0 = socket.gettime()
            local tasks = stop_on_real_clock(w)
            local still_after_quit = (function()
                socket.sleep(0.3)
                return alive(pid)
            end)()
            local gone = run_tasks_until_gone(tasks, pid, t0 + Worker.KILL_AFTER + 1)
            if not gone then ffi.C.kill(pid, 9); wait_gone(pid, 2) end
            if not still_after_quit then return nil, "the stuck worker obeyed Q (test hook not honoured)" end
            if not gone then return nil, "worker still running after KILL_AFTER + 1 s" end
            return true
        end)

        check("workers_keep_only_their_own_descriptors", function()
            local lfs = require("libs/libkoreader-lfs")
            local listener = assert(socket.bind("127.0.0.1", 0))
            local p = ffi.new("int[2]")
            assert(ffi.C.pipe(p) == 0)
            local keep = p[0]
            local w = spawn_echo({ keep })
            local ok, res, err = pcall(function()
                poll_until(w, has_hello, 2)
                if not w.pid then return nil, "no hello" end
                w:send("FD")
                local msgs = poll_until(w, function(m) return #m >= 1 end, 2, {})
                local r, wr = (msgs[1] or ""):match("^FD (%d+) (%d+)$")
                if not r then return nil, "FD answer: " .. tostring(msgs[1]) end
                local expect = { [tonumber(r)] = true, [tonumber(wr)] = true, [keep] = true }
                for fd = 0, 2 do
                    if lfs.attributes("/proc/self/fd/" .. fd) then expect[fd] = true end
                end
                local got = {}
                for e in lfs.dir("/proc/" .. w.pid .. "/fd") do
                    if e ~= "." and e ~= ".." then got[tonumber(e)] = true end
                end
                local function keys(t)
                    local k = {}
                    for fd in pairs(t) do k[#k + 1] = fd end
                    table.sort(k)
                    return table.concat(k, ",")
                end
                if keys(got) ~= keys(expect) then
                    return nil, "worker fds " .. keys(got) .. ", expected " .. keys(expect)
                        .. " (listener fd " .. tostring(listener:getfd()) .. ")"
                end
                return true
            end)
            kill_worker(w)
            listener:close()
            ffi.C.close(p[0])
            ffi.C.close(p[1])
            if not ok then return nil, res end
            return res, err
        end)

        check("workers_run_at_lower_priority", function()
            local w, Worker = spawn_echo()
            poll_until(w, has_hello, 2)
            local stat = w.pid and read_file("/proc/" .. w.pid .. "/stat")
            kill_worker(w)
            if not stat then return nil, "no worker stat" end
            -- Fields after the parenthesised command: state is field 3, nice is field 19.
            local rest = stat:match("%) (.*)$")
            local f = {}
            for x in rest:gmatch("%S+") do f[#f + 1] = x end
            local nice = tonumber(f[17])
            if nice ~= Worker.NICE or Worker.NICE ~= 5 then
                return nil, "nice " .. tostring(nice) .. ", NICE " .. tostring(Worker.NICE)
            end
            return true
        end)

        -- The UI's pipe ends are close-on-exec: a program the UI process runs does not keep them.
        check("worker_pipe_ends_are_close_on_exec", function()
            local w = spawn_echo()
            local bad
            for _, fd in ipairs({ w.read_fd, w.write_fd }) do
                local info = read_file("/proc/self/fdinfo/" .. fd) or ""
                local flags = tonumber(info:match("flags:%s*(%d+)") or "", 8)
                -- O_CLOEXEC as fdinfo shows it (octal 02000000)
                if not flags or bit.band(flags, 0x80000) == 0 then
                    bad = string.format("fd %d flags %s", fd, tostring(info:match("flags:%s*(%d+)")))
                end
            end
            poll_until(w, has_hello, 2)
            kill_worker(w)
            if bad then return nil, bad end
            return true
        end)

        -- The renderer over caller-given memory: what canvas() returns is what that memory holds.
        check("renderer_dithered_output_is_in_canvas_mem", function()
            local Renderer = require("vncoxide/renderer")
            local SharedMem = require("vncoxide/sharedmem")
            local W, H = 64, 48
            local plane = BB.new(W, H, BB.TYPE_BBRGB24)
            for y = 0, H - 1 do
                for x = 0, W - 1 do plane:setPixel(x, y, BB.ColorRGB24(x * 3, y * 5, 77)) end
            end
            local bytes = W * H
            local ptr = SharedMem.alloc(bytes)
            local r = Renderer.new{ canvas_mem = { ptr = ptr, bytes = bytes } }
            local mem = SharedMem.bb(ptr, W, H, BB.TYPE_BB8)
            local view = { x = 0, y = 0, scale = 1 }
            local err
            for _, dither in ipairs({ true, false, true }) do
                r:render(plane, view, "smooth", W, H, BB.TYPE_BB8, dither, nil, false)
                local out = r:canvas()
                for y = 0, H - 1 do
                    for x = 0, W - 1 do
                        if not err and out:getPixel(x, y):getColor8().a ~= mem:getPixel(x, y):getColor8().a then
                            err = string.format("dither=%s: (%d,%d) differs from the canvas memory", tostring(dither), x, y)
                        end
                    end
                end
            end
            r:free()
            SharedMem.free(ptr, bytes)
            plane:free()
            if err then return nil, err end
            return true
        end)

        check("renderer_reports_no_change_as_nil", function()
            local Renderer = require("vncoxide/renderer")
            local plane = BB.new(64, 48, BB.TYPE_BBRGB24)
            local r = Renderer.new()
            local view = { x = 0, y = 0, scale = 1 }
            r:render(plane, view, "smooth", 32, 24, BB.TYPE_BB8, false, nil, false)
            -- a stale rect outside the canvas changes nothing
            local res = r:render(plane, view, "smooth", 32, 24, BB.TYPE_BB8, false, { { x = 50, y = 40, w = 4, h = 4 } }, false)
            r:free()
            plane:free()
            if res ~= nil then return nil, "render returned " .. tostring(res) .. (type(res) == "table" and (" of " .. #res) or "") end
            return true
        end)

        -- Decode and scale workers (vncoxide/workers.lua) behind a live session, over the mock.
        local function worker_session(name, mock, workers_on)
            local Session = load_session()
            local Workers = require("vncoxide/workers")
            -- (no device screen here: any canvas up to 400x400 at 4 bytes per pixel)
            Workers.canvas_bytes = function() return 400 * 400 * 4 end
            mock.name = name
            local pid, port, log = start_mock(mock)
            local states = {}
            local s = Session.new{
                profile = { host = "127.0.0.1", port = port, password = "", name = name },
                worker_processes = workers_on ~= false,
                network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() end },
                on_state = function(st) states[#states + 1] = st end,
            }
            local connected, cerr
            connect_sync(s, function(ok, err) connected, cerr = ok, err end)
            if not connected then error("connect failed: " .. tostring(cerr)) end
            -- the UI's dropped socket object must not close or shut down the workers' connection
            collectgarbage("collect")
            return s, states, pid, log
        end
        -- Waits for both workers' hello (their pids).
        local function link_pids(link)
            poll_until(link.decode, function() return link.decode.pid end, 3)
            poll_until(link.scale, function() return link.scale.pid end, 3)
            return link.decode.pid, link.scale.pid
        end
        -- Stops the workers and makes sure neither outlives the check.
        local function end_link(s)
            local link = s.workers
            if not link then return end
            local pids = { link.decode.pid, link.scale.pid }
            kill_worker(link.decode)
            kill_worker(link.scale)
            pcall(link.stop, link)
            for _, p in ipairs(pids) do
                if p then ffi.C.kill(p, 9); wait_gone(p, 2) end
            end
        end
        -- Collects `C` messages of the scale worker until `want(c)` holds for one (or `timeout`).
        local function wait_c(link, want, timeout, seen)
            seen = seen or {}
            local deadline = socket.gettime() + timeout
            repeat
                local lines = link.scale:poll()
                for _, l in ipairs(lines) do
                    if l:match("^C ") then
                        seen[#seen + 1] = l
                        if want(l) then return l, seen end
                    end
                end
                socket.sleep(0.005)
            until socket.gettime() > deadline
            return nil, seen
        end
        local function g_line(id, scale, cw, ch)
            return string.format("G %d %s 0 0 %d %d %d 0 smooth 1 0", id, tostring(scale), cw, ch, BB.TYPE_BB8)
        end

        check("workers_decode_and_scale_into_shared_memory", function()
            local Scaler = require("vncoxide/scaler")
            local SharedMem = require("vncoxide/sharedmem")
            local W, H = 200, 150
            local s, _, mpid = worker_session("wk_quads", { encoding = "raw", pattern = "quadrants", width = W, height = H })
            local link = s.workers
            local ok, err = pcall(function()
                if not link then error("no workers started") end
                if s.sock ~= nil then error("the UI process still holds the socket") end
                if s.remote.worker_link ~= link then error("remote.worker_link not set") end
                local _, spid = link_pids(link)
                if not spid then error("no hello from the workers") end
                local cw, ch = W / 2, H / 2
                link.scale:send(g_line(1, 0.5, cw, ch))
                link.decode:send("R")
                link.decode:send("F")
                if not wait_c(link, function(l) return l == "C 1 full" end, 5) then error("no C 1 full") end
                -- the expected canvas: the pattern scaled in this process
                local plane = BB.new(W, H, BB.TYPE_BBRGB24)
                for y = 0, H - 1 do
                    for x = 0, W - 1 do
                        plane:setPixel(x, y, BB.ColorRGB24(pattern_pixel("quadrants", x, y, W, H)))
                    end
                end
                local exp = BB.new(cw, ch, BB.TYPE_BB8)
                Scaler.render(exp, plane, { x = 0, y = 0, scale = 0.5 }, { x = 0, y = 0, w = cw, h = ch }, "smooth")
                local got = SharedMem.bb(link.canvas_mem.ptr, cw, ch, BB.TYPE_BB8)
                local probes = { { 25, 18 }, { 75, 18 }, { 25, 56 }, { 75, 56 } }
                local function mismatch()
                    for _, p in ipairs(probes) do
                        local a, e = got:getPixel(p[1], p[2]):getColor8().a, exp:getPixel(p[1], p[2]):getColor8().a
                        if a ~= e then return string.format("(%d,%d) is %d, expected %d", p[1], p[2], a, e) end
                    end
                end
                -- (the full update's rects follow the first render)
                local deadline, bad = socket.gettime() + 5, nil
                repeat
                    link.scale:poll()
                    bad = mismatch()
                    if not bad then break end
                    socket.sleep(0.01)
                until socket.gettime() > deadline
                plane:free()
                exp:free()
                if bad then error("canvas " .. bad) end
            end)
            end_link(s)
            s:disconnect()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        check("latest_view_wins", function()
            local s, _, mpid = worker_session("wk_latest", { encoding = "raw", pattern = "quadrants" })
            local link = s.workers
            local ok, err = pcall(function()
                if not link then error("no workers started") end
                link_pids(link)
                local g = {}
                for i = 1, 10 do g[i] = g_line(i, 0.25 + i * 0.05, 100, 75) end
                link.scale:send(table.concat(g, "\n")) -- ten G messages in one write
                local last, seen = wait_c(link, function(l) return l == "C 10 full" end, 5)
                if not last then error("no C 10 full: " .. table.concat(seen, " | ")) end
                wait_c(link, function() return false end, 0.3, seen)
                local fulls = 0
                for _, l in ipairs(seen) do if l:match(" full$") then fulls = fulls + 1 end end
                if fulls ~= 1 then error("C full messages: " .. table.concat(seen, " | ")) end
            end)
            end_link(s)
            s:disconnect()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- A `G` without the screen's rotation and inversion (the format before them) still parses
        -- and renders the plain canvas; with them the shared memory holds the canvas in that
        -- physical layout; a malformed tail is no view at all.
        check("g_view_rotation_tail_is_optional", function()
            local Scaler = require("vncoxide/scaler")
            local SharedMem = require("vncoxide/sharedmem")
            local W, H = 200, 150
            local s, _, mpid = worker_session("wk_gtail", { encoding = "raw", pattern = "gradient", width = W, height = H })
            local link = s.workers
            local ok, err = pcall(function()
                if not link then error("no workers started") end
                link_pids(link)
                local cw, ch = 100, 75
                local plane = BB.new(W, H, BB.TYPE_BBRGB24)
                for y = 0, H - 1 do
                    for x = 0, W - 1 do
                        plane:setPixel(x, y, BB.ColorRGB24(pattern_pixel("gradient", x, y, W, H)))
                    end
                end
                local exp = BB.new(cw, ch, BB.TYPE_BB8)
                Scaler.render(exp, plane, { x = 0, y = 0, scale = 0.5 }, { x = 0, y = 0, w = cw, h = ch }, "smooth")
                plane:free()
                -- the canvas memory read as `w` x `h` (unrotated) against `want`
                local function differs(want, w, h)
                    local got = SharedMem.bb(link.canvas_mem.ptr, w, h, BB.TYPE_BB8)
                    for y = 0, h - 1 do
                        for x = 0, w - 1 do
                            local a, e = got:getPixel(x, y):getColor8().a, want:getPixel(x, y):getColor8().a
                            if a ~= e then return string.format("(%d,%d) is %d, expected %d", x, y, a, e) end
                        end
                    end
                end
                local function settled(want, w, h)
                    local deadline, bad = socket.gettime() + 5, nil
                    repeat
                        link.scale:poll()
                        bad = differs(want, w, h)
                        if not bad then return end
                        socket.sleep(0.01)
                    until socket.gettime() > deadline
                    return bad
                end
                -- the old format
                link.scale:send(g_line(1, 0.5, cw, ch))
                link.decode:send("R")
                link.decode:send("F")
                if not wait_c(link, function(l) return l == "C 1 full" end, 5) then error("no C 1 full") end
                local bad = settled(exp, cw, ch)
                if bad then error("old-format view: canvas " .. bad) end
                -- rotated and inverted: the screen's physical rows
                local phys = BB.new(ch, cw, BB.TYPE_BB8)
                phys:setRotation(1)
                phys:invertblitFrom(exp, 0, 0, 0, 0, cw, ch)
                phys:setRotation(0)
                link.scale:send(g_line(2, 0.5, cw, ch) .. " 1 1")
                if not wait_c(link, function(l) return l == "C 2 full" end, 5) then error("no C 2 full") end
                bad = differs(phys, ch, cw)
                phys:free()
                if bad then error("view with rotation 1, inverted: canvas " .. bad) end
                -- malformed tails: ignored
                for _, tail in ipairs({ " 4 0", " 1 2", " 1", " 1 1 0" }) do
                    link.scale:send(g_line(3, 0.5, cw, ch) .. tail)
                end
                local c3, seen = wait_c(link, function(l) return l:match("^C 3") end, 0.4)
                if c3 then error("a malformed tail was rendered: " .. table.concat(seen, " | ")) end
                -- the old format again: back to the plain layout
                link.scale:send(g_line(4, 0.5, cw, ch))
                if not wait_c(link, function(l) return l == "C 4 full" end, 5) then error("no C 4 full") end
                bad = differs(exp, cw, ch)
                exp:free()
                if bad then error("old-format view after a rotated one: canvas " .. bad) end
            end)
            end_link(s)
            s:disconnect()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- The scale worker drains every pending message before it renders, not one read's worth.
        check("latest_view_wins_across_reads", function()
            local Worker = require("vncoxide/worker")
            local chunk = Worker.READ_CHUNK
            Worker.READ_CHUNK = 64 -- (the workers inherit it: a G line or so per read)
            local ok0, s, _, mpid = pcall(worker_session, "wk_latest_reads", { encoding = "raw", pattern = "quadrants" })
            Worker.READ_CHUNK = chunk
            if not ok0 then return nil, s end
            local link = s.workers
            local ok, err = pcall(function()
                if not link then error("no workers started") end
                link_pids(link)
                local g = {}
                for i = 1, 10 do g[i] = g_line(i, 0.25 + i * 0.05, 100, 75) end
                link.scale:send(table.concat(g, "\n")) -- one write, many reads
                local last, seen = wait_c(link, function(l) return l == "C 10 full" end, 5)
                if not last then error("no C 10 full: " .. table.concat(seen, " | ")) end
                wait_c(link, function() return false end, 0.3, seen)
                if #seen ~= 1 then error("rendered views: " .. table.concat(seen, " | ")) end
            end)
            end_link(s)
            s:disconnect()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- A bare `E` (no text) still fails the session with a message.
        check("bare_worker_error_says_the_worker_exited", function()
            local s, _, mpid = worker_session("wk_bare_e", { encoding = "raw", pattern = "quadrants" })
            local link = s.workers
            local ok, err = pcall(function()
                if not link then error("no workers started") end
                link_pids(link)
                local real = link.decode.poll
                link.decode.poll = function(h) local _ = real(h); return { "E" }, false end
                link:poll()
                link.decode.poll = real
                if s:get_state() ~= "error" then error("state " .. tostring(s:get_state())) end
                if s:get_error() ~= "worker process exited" then error("error " .. string.format("%q", tostring(s:get_error()))) end
            end)
            for _, p in ipairs({ link and link.decode.pid, link and link.scale.pid }) do
                if p then ffi.C.kill(p, 9); wait_gone(p, 2) end
            end
            end_link(s)
            s:disconnect()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- A render that fails in the scale worker reaches the session as its error.
        check("scale_render_error_is_a_session_error", function()
            local s, states, mpid = worker_session("wk_render_err", { encoding = "raw", pattern = "quadrants" })
            local link = s.workers
            local ok, err = pcall(function()
                if not link then error("no workers started") end
                link_pids(link)
                -- a canvas larger than the shared canvas memory: the renderer refuses it
                link.scale:send(string.format("G 1 1 0 0 2000 2000 %d 0 smooth 1 0", BB.TYPE_BBRGB32))
                local deadline = socket.gettime() + 3
                while s:get_state() ~= "error" and socket.gettime() < deadline do
                    link:poll()
                    socket.sleep(0.01)
                end
                if s:get_state() ~= "error" then error("state " .. tostring(s:get_state())) end
                if not tostring(s:get_error()):find("render failed", 1, true) then
                    error("the error is not the scale worker's: " .. tostring(s:get_error()))
                end
                local errors = 0
                for _, st in ipairs(states) do if st == "error" then errors = errors + 1 end end
                if errors ~= 1 then error("on_state('error') " .. errors .. " times") end
            end)
            for _, p in ipairs({ link and link.decode.pid, link and link.scale.pid }) do
                if p then ffi.C.kill(p, 9); wait_gone(p, 2) end
            end
            end_link(s)
            s:disconnect()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        check("decode_rects_reach_the_canvas", function()
            local Scaler = require("vncoxide/scaler")
            -- An 80x80 desktop: the mock's 40x40 repaint box at (0, 0) is exactly its top-left quadrant.
            local s, _, mpid = worker_session("wk_rects", { encoding = "raw", pattern = "quadrants",
                width = 80, height = 80, repaint = 0.15 })
            local link = s.workers
            local ok, err = pcall(function()
                if not link then error("no workers started") end
                link_pids(link)
                link.scale:send(g_line(1, 0.5, 40, 40))
                link.decode:send("R")
                link.decode:send("F")
                local e = Scaler.dst_rect_for({ x = 0, y = 0, w = 40, h = 40 }, { x = 0, y = 0, scale = 0.5 }, 40, 40, "smooth")
                local want = string.format("C 1 %d %d %d %d", e.x, e.y, e.w, e.h)
                local got, seen = wait_c(link, function(l) return l == want end, 8)
                if not got then error("no '" .. want .. "' among: " .. table.concat(seen, " | ")) end
            end)
            end_link(s)
            s:disconnect()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        check("worker_death_is_a_session_error", function()
            local s, states, mpid = worker_session("wk_death", { encoding = "raw", pattern = "quadrants" })
            local link = s.workers
            local ok, err = pcall(function()
                if not link then error("no workers started") end
                local dpid, spid = link_pids(link)
                if not (dpid and spid) then error("no hello from the workers") end
                local n0 = #states
                ffi.C.kill(dpid, 9)
                local deadline = socket.gettime() + 2
                while s:get_state() ~= "error" and socket.gettime() < deadline do
                    link:poll()
                    socket.sleep(0.01)
                end
                if s:get_state() ~= "error" then error("state " .. tostring(s:get_state())) end
                local errors = 0
                for i = n0 + 1, #states do if states[i] == "error" then errors = errors + 1 end end
                if errors ~= 1 then error("on_state('error') " .. errors .. " times") end
                if s.workers ~= nil or s.remote.worker_link ~= nil then error("the link was not cleared") end
                if not wait_gone(spid, 2) then error("the scale worker is still running") end
            end)
            if s.workers == nil and link then
                for _, p in ipairs({ link.decode.pid, link.scale.pid }) do
                    if p then ffi.C.kill(p, 9); wait_gone(p, 2) end
                end
            end
            end_link(s)
            s:disconnect()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        check("workers_off_is_in_process", function()
            local s, _, mpid = worker_session("wk_off", { encoding = "raw", pattern = "quadrants" }, false)
            local ok = s.workers == nil and s.remote.worker_link == nil and s.sock ~= nil and s.proto ~= nil
            local why = string.format("workers %s, sock %s, proto %s", tostring(s.workers), tostring(s.sock), tostring(s.proto))
            end_link(s)
            s:disconnect()
            stop_mock(mpid)
            if not ok then return nil, why end
            return true
        end)

        check("detached_workers_read_nothing_and_resync_on_attach", function()
            local env = proxy_env()
            local s, mpid
            local ok, err = pcall(function()
                local log
                s, mpid, log = proxy_session(env, "wk_detach", { encoding = "raw", pattern = "quadrants",
                    alt_pattern = "checker", repaint = 0.1, persist = true })
                local remote = s:get_remote()
                local target, shows = canvas_probe(remote, 200, 150)
                local app = proxy_app()
                s:attach(app)
                -- (the scale worker writes the shared canvas before it sends its C line: the
                -- picture can show a moment before the app is told, so both are waited for)
                local bad = wait_canvas(env, shows, "quadrants", 5)
                if bad then error("attached: the canvas is not the picture: " .. bad) end
                if not env.run_until(function() return app.dirty[1] ~= nil end, 5) then
                    error("the app was not told of the new canvas")
                end
                s:detach()
                -- (a repaint decoded just before the detach may still be on its way)
                local link = s.workers
                env.run_until(function() link.scale:poll(); return false end, 0.3)
                os.execute("kill -USR1 " .. mpid)
                if not wait_for_log(log, "PATTERN checker", 5) then error("the mock did not switch") end
                -- detached: the decode worker reads nothing, so the scale worker reports nothing
                local seen = {}
                local deadline = socket.gettime() + 1
                repeat
                    env.step()
                    for _, l in ipairs((link.scale:poll())) do seen[#seen + 1] = l end
                    socket.sleep(0.01)
                until socket.gettime() > deadline
                for _, l in ipairs(seen) do
                    if l:match("^C ") then error("a C while detached: " .. l) end
                end
                local n = #app.dirty
                s:attach(app)
                bad = wait_canvas(env, shows, "checker", 5)
                if bad then error("attach did not resynchronise: " .. bad) end
                if not env.run_until(function() return #app.dirty > n end, 5) then
                    error("the app was not told of the resynchronised canvas")
                end
                target:free()
            end)
            if s then s:disconnect() end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        check("keys_reach_the_server_during_a_long_decode", function()
            local env = proxy_env()
            local s, mpid, log
            local ok, err = pcall(function()
                -- 400x300 Raw is 480 kB: in 8 kB pieces 20 ms apart it takes well over a second
                s, mpid, log = proxy_session(env, "wk_keys", { encoding = "raw", pattern = "gradient",
                    width = 400, height = 300, split = 8192, input_during_send = true })
                local remote = s:get_remote()
                local target = BB.new(100, 75, BB.TYPE_BB8)
                remote:fit_view(100, 75)
                remote:draw_to(target, 0, 0, 100, 75, false)
                s:attach(proxy_app())
                -- the update is on its way once the request is in
                if not wait_for_log(log, "INPUT FramebufferUpdateRequest incremental=0", 5) then
                    error("no full update request")
                end
                env.run_until(function() return false end, 0.2)
                local keys = { 0x61, 0x62, 0x63, 0x64, 0x65 }
                for _, k in ipairs(keys) do
                    s:send_key(k, true)
                    s:send_key(k, false)
                    env.run_until(function() return false end, 0.02)
                end
                if not env.run_until(function() return log_has(log, "UPDATE_SENT") end, 20) then
                    error("the update never finished")
                end
                local text = read_file(log) or ""
                local done_at = text:find("UPDATE_SENT", 1, true)
                local pos = 1
                for _, k in ipairs(keys) do
                    local i = text:find(string.format("INPUT KeyEvent down=1 keysym=0x%x", k), pos, true)
                    if not i then error(string.format("key 0x%x missing or out of order", k)) end
                    if i > done_at then error(string.format("key 0x%x reached the server only after the update", k)) end
                    pos = i
                end
                target:free()
            end)
            if s then s:disconnect() end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- Wi-Fi this session turned on stays its duty across the resize reconnect: a hangup
        -- afterwards turns it off, once.
        check("desktop_resize_reconnect_keeps_the_wifi_duty", function()
            local env = proxy_env()
            local s, mpid
            local offs = 0
            local ok, err = pcall(function()
                s, mpid = proxy_session(env, "wk_resize_wifi", { encoding = "raw", pattern = "quadrants",
                    resize_after = 2, resize_once = true, persist = true },
                    { isWifiOn = function() return true end, turnOffWifi = function() offs = offs + 1 end })
                s.wifi_was_on = false -- (as if this session had turned Wi-Fi on)
                local first, app = s.workers, proxy_app()
                s:attach(app)
                if not env.run_until(function()
                    return app.resized > 0 and s.workers ~= nil and s.workers ~= first
                end, 10) then
                    error("no reconnect: state " .. tostring(s:get_state()) .. " " .. tostring(s:get_error()))
                end
                if offs ~= 0 then error("the reconnect turned Wi-Fi off " .. offs .. " time(s)") end
                s:hangup()
                if offs ~= 1 then error("the hangup turned Wi-Fi off " .. offs .. " time(s), expected once") end
            end)
            if s then s:disconnect() end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            if offs ~= 1 then return nil, "turnOffWifi ran " .. offs .. " times in all" end
            return true
        end)

        check("desktop_resize_reconnects", function()
            local env = proxy_env()
            local s, mpid
            local ok, err = pcall(function()
                local log, states
                -- the second update request (the first incremental one) gets a DesktopSize: 200x150 -> 232x166
                s, mpid, log, states = proxy_session(env, "wk_resize", { encoding = "raw", pattern = "quadrants",
                    resize_after = 2, resize_once = true, persist = true })
                local remote = s:get_remote()
                local first = s.workers
                local app = proxy_app()
                local target = BB.new(200, 150, BB.TYPE_BB8)
                remote:draw_to(target, 0, 0, 200, 150, false)
                s:attach(app)
                if not env.run_until(function()
                    return app.resized > 0 and s.workers ~= nil and s.workers ~= first and s:is_attached()
                end, 10) then
                    error(string.format("no reconnect: resized %d, state %s, workers %s (%s)", app.resized,
                        tostring(s:get_state()), tostring(s.workers), tostring(s:get_error())))
                end
                local w, h = remote:get_size()
                if w ~= 232 or h ~= 166 then error(string.format("size %dx%d", w, h)) end
                if s:get_remote() ~= remote then error("the remote object was replaced") end
                local _, shows = canvas_probe(remote, 200, 150)
                local bad = wait_canvas(env, shows, "quadrants", 5)
                if bad then error("the new desktop's canvas: " .. bad) end
                env.run_until(function() return false end, 0.3)
                if app.resized ~= 1 then error("on_remote_resized fired " .. app.resized .. " times") end
                for _, st in ipairs(states) do
                    if st == "error" then error("the session failed on the way: " .. tostring(s:get_error())) end
                end
                if log_count(log, "\nCONNECT\n") ~= 2 then error("expected two connections to the mock") end
                target:free()
            end)
            if s then s:disconnect() end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- A DesktopSize of the current size is no resize: the workers carry on (no reconnect),
        -- and the full update the decode worker then requests keeps the picture right.
        check("same_size_desktop_size_keeps_the_workers", function()
            local env = proxy_env()
            local s, mpid
            local ok, err = pcall(function()
                local log, states
                s, mpid, log, states = proxy_session(env, "wk_resize_same", { encoding = "raw", pattern = "quadrants",
                    resize_after = 2, resize_same = true, persist = true })
                local remote = s:get_remote()
                local first = s.workers
                local app = proxy_app()
                local _, shows = canvas_probe(remote, 200, 150)
                s:attach(app)
                if not wait_for_log(log, "RESIZE 200 150", 5) then error("the mock sent no DesktopSize") end
                -- the full update requested after it
                if not env.run_until(function()
                    local text = read_file(log) or ""
                    local at = text:find("RESIZE 200 150", 1, true)
                    return at and text:find("incremental=0", at, true) ~= nil
                end, 5) then error("no full update request after the DesktopSize") end
                env.run_until(function() return false end, 0.5)
                local bad = wait_canvas(env, shows, "quadrants", 5)
                if bad then error("the canvas: " .. bad) end
                if s.workers ~= first then error("the workers were replaced") end
                if app.resized ~= 0 then error("on_remote_resized fired " .. app.resized .. " times") end
                if log_count(log, "\nCONNECT\n") ~= 1 then error("the session reconnected") end
                for _, st in ipairs(states) do
                    if st == "error" then error("the session failed: " .. tostring(s:get_error())) end
                end
                local w, h = remote:get_size()
                if w ~= 200 or h ~= 150 then error(string.format("size %dx%d", w, h)) end
            end)
            if s then s:disconnect() end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- A decode worker that stops reading its commands is a session error within
        -- DECODE_STALL (plus a tick), not a frozen picture.
        check("hung_decode_worker_fails_the_session", function()
            local env = proxy_env()
            local Workers = require("vncoxide/workers")
            local s, mpid, waited
            local ok, err = pcall(function()
                Workers._test_decode_stuck = true
                local ok0, s0, mpid0 = pcall(proxy_session, env, "wk_hung_decode", { encoding = "raw", pattern = "quadrants" })
                Workers._test_decode_stuck = nil
                if not ok0 then error(s0) end
                s, mpid = s0, mpid0
                s:attach(proxy_app())
                -- more than the pipe holds: the rest stays queued in the UI process
                s:send_cut_text(string.rep("x", 256 * 1024))
                if s.workers.decode:pending() == 0 then error("nothing stayed queued") end
                local t0 = socket.gettime()
                env.run_until(function() return s:get_state() == "error" end, Workers.DECODE_STALL + 3)
                waited = socket.gettime() - t0
                if s:get_state() ~= "error" then error("no session error after " .. waited .. " s") end
                if s:get_error() ~= "decode worker not responding" then error("error " .. tostring(s:get_error())) end
                if waited < Workers.DECODE_STALL then error("failed after only " .. waited .. " s") end
                if s.workers ~= nil then error("the link was not cleared") end
            end)
            Workers._test_decode_stuck = nil
            if s then s:disconnect() end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- An idle decode worker answers the UI's pings (`I`/`O`): with no input and no update at
        -- all the session stays connected well past PING_AFTER + DECODE_STALL.
        check("idle_decode_worker_answers_pings", function()
            local env = proxy_env()
            local Workers = require("vncoxide/workers")
            local s, mpid
            local ok, err = pcall(function()
                local states, _log
                s, mpid, _log, states = proxy_session(env, "wk_ping_idle", { encoding = "raw", pattern = "quadrants" })
                local link = s.workers
                local target, shows = canvas_probe(s:get_remote(), 200, 150)
                s:attach(proxy_app())
                local bad = wait_canvas(env, shows, "quadrants", 5)
                if bad then error("the canvas: " .. bad) end
                target:free()
                local t0 = socket.gettime()
                env.run_until(function() return s:get_state() ~= "connected" end, 3.5)
                if s:get_state() ~= "connected" then
                    error(string.format("state %s (%s) after %.2f s", tostring(s:get_state()),
                        tostring(s:get_error()), socket.gettime() - t0))
                end
                if s.workers ~= link then error("the link changed") end
                if (link.pong_id or 0) < 2 then error("pongs answered: " .. tostring(link.pong_id)) end
                for _, st in ipairs(states) do
                    if st == "error" then error("the session failed on the way") end
                end
            end)
            if s then s:disconnect() end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- A decode worker that hangs while the user is idle (no input, nothing queued for it):
        -- the unanswered ping fails the session within PING_AFTER + DECODE_STALL (plus ticks).
        check("decode_worker_hung_while_idle_fails_the_session", function()
            local env = proxy_env()
            local Workers = require("vncoxide/workers")
            local s, mpid
            local hang = 1.5
            local ok, err = pcall(function()
                Workers._test_decode_deaf_after = hang
                local ok0, s0, mpid0 = pcall(proxy_session, env, "wk_ping_hung", { encoding = "raw", pattern = "quadrants" })
                local hang_at = socket.gettime() + hang -- (the worker was forked before this)
                Workers._test_decode_deaf_after = nil
                if not ok0 then error(s0) end
                s, mpid = s0, mpid0
                s:attach(proxy_app())
                env.run_until(function() return s:get_state() == "error" end, hang + 5)
                local t = socket.gettime() - hang_at
                if s:get_state() ~= "error" then error(string.format("no session error %.2f s after the hang", t)) end
                if s:get_error() ~= "decode worker not responding" then error("error " .. tostring(s:get_error())) end
                if t > 3.5 then error(string.format("failed only %.2f s after the hang", t)) end
                -- (hang_at is a little after the real hang: the fork came first)
                if t < Workers.DECODE_STALL - 0.5 then error(string.format("failed %.2f s after the hang", t)) end
                if s.workers ~= nil then error("the link was not cleared") end
            end)
            Workers._test_decode_deaf_after = nil
            if s then s:disconnect() end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- A pong is no activity: while idle the poll stays at Session.POLL_INTERVAL as the pongs
        -- come in (one ping per PING_AFTER of silence).
        check("pongs_keep_the_idle_poll_interval", function()
            local env = proxy_env()
            local Workers = require("vncoxide/workers")
            local Session = load_session()
            local s, mpid
            local function next_poll()
                for _, t in ipairs(env.tasks) do
                    if t.fn == s._poll_task then return t.d end
                end
            end
            local ok, err = pcall(function()
                s, mpid = proxy_session(env, "wk_ping_interval", { encoding = "raw", pattern = "quadrants" })
                local link = s.workers
                local target, shows = canvas_probe(s:get_remote(), 200, 150)
                s:attach(proxy_app())
                local bad = wait_canvas(env, shows, "quadrants", 5)
                if bad then error("the canvas: " .. bad) end
                target:free()
                if not env.run_until(function() return next_poll() == Session.POLL_INTERVAL end, Workers.ACTIVE_FOR + 2) then
                    error("idle poll interval " .. tostring(next_poll()))
                end
                local seen, pongs, wrong = link.pong_id or 0, 0, nil
                env.run_until(function()
                    if (link.pong_id or 0) ~= seen then
                        seen, pongs = link.pong_id, pongs + 1
                        local d, i = next_poll(), link:interval()
                        if d ~= Session.POLL_INTERVAL or i ~= Session.POLL_INTERVAL then
                            wrong = string.format("after pong %d: next poll %s, interval %s", seen, tostring(d), tostring(i))
                        end
                    end
                    return wrong ~= nil
                end, 2.5)
                if wrong then error(wrong) end
                if pongs < 1 then error("no pong in 2.5 s idle") end
                if pongs > 3 then error(pongs .. " pongs in 2.5 s idle") end
            end)
            if s then s:disconnect() end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- The watchdog's verdicts on a link's state: an unanswered ping blames the decode worker,
        -- unless a G has also been unanswered for DECODE_STALL (the decode worker then likely
        -- blocks writing to a hung scale worker); a gap between ticks restarts the ping's clock.
        check("ping_watchdog_blames_the_right_worker", function()
            local env = proxy_env()
            local Workers = require("vncoxide/workers")
            local Session = load_session()
            local s, mpid
            local ok, err = pcall(function()
                s, mpid = proxy_session(env, "wk_ping_blame", { encoding = "raw", pattern = "quadrants" })
                local link = s.workers
                local now = Session._now()
                local saved = { link.view_id, link.answered_id, link.scale_since, link.ping_id, link.ping_at, link.heard_at }
                local function set(view_id, scale_since, ping_at, heard_at)
                    link.view_id, link.answered_id, link.scale_since = view_id, 0, scale_since
                    link.ping_id, link.ping_at, link.heard_at = 7, ping_at, heard_at
                end
                local res = {}
                set(nil, nil, now - 2.5, now - 3.5)
                res[1] = link:_stalled(now, false)
                set(1, now - 2.5, now - 2.5, now - 3.5)
                res[2] = link:_stalled(now, false)
                set(1, now - 0.2, now - 2.5, now - 3.5)
                res[3] = link:_stalled(now, false)
                set(nil, nil, now - 1.5, now - 2.5)
                res[4] = link:_stalled(now, false) or "nil"
                set(nil, nil, nil, now - 1.1)
                res[5] = link:_stalled(now, false) or "nil"
                local sent = link.ping_id == 8 and link.ping_at == now
                link.view_id, link.answered_id, link.scale_since, link.ping_id, link.ping_at, link.heard_at = unpack(saved, 1, 6)
                local want = { "decode worker not responding", "scale worker not responding",
                    "decode worker not responding", "nil", "nil" }
                for i = 1, 5 do
                    if res[i] ~= want[i] then error(string.format("case %d: %s", i, tostring(res[i]))) end
                end
                if not sent then error("no ping sent after PING_AFTER of silence") end
                -- a tick after a long gap: the outstanding ping's clock restarts (no failure)
                s:attach(proxy_app())
                env.run_until(function() return false end, 0.2)
                link.ping_id, link.ping_at = (link.ping_id or 0) + 100, Session._now() - 10
                link.polled_at = Session._now() - 10
                link:poll()
                if s:get_state() ~= "connected" then error("failed after a gap: " .. tostring(s:get_error())) end
                if not link.ping_at or Session._now() - link.ping_at > 0.5 then error("the ping's clock was not restarted") end
            end)
            if s then s:disconnect() end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- The in-process session (worker_processes off) has no link and no ping: idle past
        -- PING_AFTER + DECODE_STALL it stays connected, its poll at Session.POLL_INTERVAL.
        check("in_process_idle_session_has_no_ping", function()
            local env = proxy_env()
            local Session = load_session()
            local s, mpid
            local function next_poll()
                for _, t in ipairs(env.tasks) do
                    if t.fn == s._poll_task then return t.d end
                end
            end
            local ok, err = pcall(function()
                local port, log
                mpid, port, log = start_mock{ name = "wk_ping_inproc", encoding = "raw", pattern = "quadrants" }
                s = Session.new{
                    profile = { host = "127.0.0.1", port = port, password = "", name = "wk_ping_inproc" },
                    worker_processes = false,
                    network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() end },
                }
                local connected, cerr
                s:connect(function(c, e) connected, cerr = c, e end)
                env.run_until(function() return connected ~= nil end, 10)
                if not connected then error("connect failed: " .. tostring(cerr)) end
                if s.workers then error("a worker link in-process") end
                local dirty = 0
                s:attach({ on_framebuffer_dirty = function() dirty = dirty + 1 end })
                env.run_until(function() return dirty > 0 end, 5)
                if dirty == 0 then error("no update") end
                env.run_until(function() return s:get_state() ~= "connected" end, 3.5)
                if s:get_state() ~= "connected" then error("state " .. tostring(s:get_state()) .. ": " .. tostring(s:get_error())) end
                if s.workers then error("a worker link in-process") end
                if next_poll() ~= Session.POLL_INTERVAL then error("poll interval " .. tostring(next_poll())) end
                if not log_has(log, "CONNECT") then error("no connection in the mock's log") end
            end)
            if s then s:disconnect() end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- A scale worker that never answers a G is a session error after SCALE_STALL.
        check("hung_scale_worker_fails_the_session", function()
            local env = proxy_env()
            local Workers = require("vncoxide/workers")
            local stall = Workers.SCALE_STALL
            local s, mpid
            local ok, err = pcall(function()
                Workers._test_scale_stuck = true
                Workers.SCALE_STALL = 1
                local ok0, s0, mpid0 = pcall(proxy_session, env, "wk_hung_scale", { encoding = "raw", pattern = "quadrants" })
                Workers._test_scale_stuck = nil
                if not ok0 then error(s0) end
                s, mpid = s0, mpid0
                s:attach(proxy_app())
                local target = BB.new(200, 150, BB.TYPE_BB8)
                s:get_remote():draw_to(target, 0, 0, 200, 150, false) -- sends the G
                target:free()
                if not s.workers.view_id then error("no G sent") end
                local t0 = socket.gettime()
                env.run_until(function() return s:get_state() == "error" end, 4)
                local waited = socket.gettime() - t0
                if s:get_state() ~= "error" then error("no session error after " .. waited .. " s") end
                if s:get_error() ~= "scale worker not responding" then error("error " .. tostring(s:get_error())) end
                if waited < 1 then error("failed after only " .. waited .. " s") end
            end)
            Workers._test_scale_stuck = nil
            Workers.SCALE_STALL = stall
            if s then s:disconnect() end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- The scale worker's end seen in the tick that read the decode worker's pipe before its
        -- `Z` arrived: a resize, not a crash.
        check("scale_eof_before_the_decode_z_is_a_resize", function()
            local s, states, mpid = worker_session("wk_eof_z", { encoding = "raw", pattern = "quadrants" })
            local link = s.workers
            local out
            local ok, err = pcall(function()
                if not link then error("no workers started") end
                link_pids(link)
                local rd, rs = link.decode.poll, link.scale.poll
                local n = 0
                link.decode.poll = function(h)
                    n = n + 1
                    local _ = rd(h)
                    if n == 1 then return {}, false end
                    return { "Z 232 166" }, true
                end
                link.scale.poll = function(h) local _ = rs(h); return {}, true end
                local pok, res = pcall(link.poll, link)
                link.decode.poll, link.scale.poll = rd, rs
                if not pok then error(res) end
                out = res
                for _, st in ipairs(states) do
                    if st == "error" then error("reported as a failure: " .. tostring(s:get_error())) end
                end
                if out[#out] ~= "Z 232 166" then error("no Z handed on: " .. table.concat(out, " | ")) end
                if not link.stopped then error("the link was not stopped") end
            end)
            for _, p in ipairs({ link and link.decode.pid, link and link.scale.pid }) do
                if p then ffi.C.kill(p, 9); wait_gone(p, 2) end
            end
            end_link(s)
            s:disconnect()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- A step failing after both forks fails the connection (a worker may hold the socket):
        -- no in-process session on it, both workers stopped.
        check("late_worker_start_failure_fails_the_connection", function()
            local env = proxy_env()
            local Workers = require("vncoxide/workers")
            local Worker = require("vncoxide/worker")
            local Session = load_session()
            Workers.canvas_bytes = function() return 400 * 400 * 4 end
            local real_spawn = Worker.spawn
            local handles = {}
            Worker.spawn = function(...)
                local h, e = real_spawn(...)
                if h then handles[#handles + 1] = h end
                return h, e
            end
            local s, mpid
            local ok, err = pcall(function()
                local port
                mpid, port = start_mock{ name = "wk_late_fail", encoding = "raw", pattern = "quadrants" }
                local states = {}
                s = Session.new{
                    profile = { host = "127.0.0.1", port = port, password = "", name = "wk_late_fail" },
                    worker_processes = true,
                    network_mgr = { isWifiOn = function() return true end, turnOffWifi = function() end },
                    on_state = function(st) states[#states + 1] = st end,
                }
                Workers._test_fail_after_spawn = true
                local connected, cerr
                s:connect(function(c, e) connected, cerr = c, e end)
                env.run_until(function() return connected ~= nil end, 10)
                Workers._test_fail_after_spawn = nil
                if connected ~= false then error("connect reported " .. tostring(connected)) end
                if not tostring(cerr):find("test failure after the forks", 1, true) then error("error " .. tostring(cerr)) end
                if s:get_state() ~= "error" then error("state " .. tostring(s:get_state())) end
                if s.workers or s.proto or s.sock then error("the session kept a link, protocol or socket") end
                if #handles ~= 2 then error(#handles .. " workers spawned") end
                -- the stops' kill tasks run (they learn the pids if need be)
                env.run_until(function() return false end, Worker.KILL_AFTER + 0.5)
                for _, h in ipairs(handles) do
                    if not h.pid then error(h.name .. " worker: no pid learnt") end
                    if not wait_gone(h.pid, 2) then error(h.name .. " worker still running") end
                end
            end)
            Workers._test_fail_after_spawn = nil
            Worker.spawn = real_spawn
            if s then s:disconnect() end
            for _, h in ipairs(handles) do
                if h.pid then ffi.C.kill(h.pid, 9); wait_gone(h.pid, 2) end
            end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- Polling slows to Session.POLL_INTERVAL once the workers have been quiet for ACTIVE_FOR
        -- with no G unanswered; a G makes it UI_POLL again.
        check("idle_workers_poll_at_the_idle_interval", function()
            local env = proxy_env()
            local Workers = require("vncoxide/workers")
            local Session = load_session()
            local s, mpid
            local function next_poll()
                for _, t in ipairs(env.tasks) do
                    if t.fn == s._poll_task then return t.d end
                end
            end
            local ok, err = pcall(function()
                s, mpid = proxy_session(env, "wk_idle", { encoding = "raw", pattern = "quadrants" })
                local remote = s:get_remote()
                local target, shows = canvas_probe(remote, 200, 150)
                s:attach(proxy_app())
                local bad = wait_canvas(env, shows, "quadrants", 5)
                if bad then error("the canvas: " .. bad) end
                if not env.run_until(function() return next_poll() == Session.POLL_INTERVAL end, Workers.ACTIVE_FOR + 2) then
                    error("idle poll interval " .. tostring(next_poll()))
                end
                target:free()
                -- an unanswered G, or a message less than ACTIVE_FOR ago: UI_POLL
                local link = s.workers
                local id, active = link.view_id, link.active_at
                link.view_id = (link.answered_id or 0) + 1
                local with_g = link:interval()
                link.view_id = link.answered_id
                link.active_at = Session._now()
                local recent = link:interval()
                link.active_at = Session._now() - Workers.ACTIVE_FOR - 0.1
                local idle = link:interval()
                link.view_id, link.active_at = id, active
                if with_g ~= Workers.UI_POLL then error("with a G out " .. tostring(with_g)) end
                if recent ~= Workers.UI_POLL then error("after a message " .. tostring(recent)) end
                if idle ~= Session.POLL_INTERVAL then error("idle " .. tostring(idle)) end
            end)
            if s then s:disconnect() end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)

        -- The timing trace's poll gap in worker mode too.
        check("worker_mode_logs_a_poll_gap", function()
            local env = proxy_env()
            local logger = require("logger")
            local Util = require("vncoxide/util")
            local real_dbg, real_on = logger.dbg, Util.timing_enabled
            local lines = {}
            local s, mpid
            local ok, err = pcall(function()
                s, mpid = proxy_session(env, "wk_gap", { encoding = "raw", pattern = "quadrants" })
                logger.dbg = function(...)
                    local parts = {}
                    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
                    lines[#lines + 1] = table.concat(parts, " ")
                end
                Util.timing_enabled = function() return true end
                s:attach(proxy_app())
                env.run_until(function() return false end, 0.2)
                socket.sleep(0.4) -- the UI thread blocked
                env.run_until(function() return false end, 0.2)
                local gap
                for _, l in ipairs(lines) do
                    local ms = tonumber(l:match("vnc%-timing: poll gap ms=([%d.]+)"))
                    if ms and ms >= 350 then gap = ms end
                end
                if not gap then error("no poll gap line: " .. table.concat(lines, " | ")) end
            end)
            logger.dbg, Util.timing_enabled = real_dbg, real_on
            if s then s:disconnect() end
            env.finish()
            stop_mock(mpid)
            if not ok then return nil, err end
            return true
        end)
    end

    stop_all_mocks()
    if failures > 0 then
        print(string.format("%d check(s) failed", failures))
        os.exit(1)
    end
    print("all checks passed")
    os.exit(0)
end

main()
