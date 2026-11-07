#!/usr/bin/env luajit
--[[--
Standalone test harness for the vnc protocol layer.

Starts `tools/mock_vnc_server.py` (one instance per case, on an ephemeral port) and drives
@{vnc.protocol} against it over a real socket, plus a few in-memory byte-stream cases. The last
two checks drive @{vnc.session}'s own transport (queue flush and read buffering) rather than the
protocol directly.

Run with KOReader's own LuaJIT from the KOReader root:

  cd /usr/lib/koreader
  PLUGIN=~/.config/koreader/plugins/vnc.koplugin
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

local Des = require("vnc/des")
local Encodings = require("vnc/encodings")
local Keysyms = require("vnc/keysyms")
local PxFmt = require("vnc/pxfmt")
local Protocol = require("vnc/protocol")

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
    table.insert(cmd, "--once")
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
Drives @{vnc.protocol} against a real socket until `want_updates` updates have been
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
Loads @{vnc.session} for the transport-level checks. The session requires `ui/uimanager` for
its poll task, which drags in the whole widget stack; the harness has none, so stand one in
that only provides the two scheduling calls the session makes. It is installed lazily so the
protocol-only checks keep running without it.
]]
local function load_session()
    package.preload["ui/uimanager"] = package.preload["ui/uimanager"] or function()
        return { scheduleIn = function() end, unschedule = function() end }
    end
    return require("vnc/session")
end

-- ---------------------------------------------------------------- checks

local failures = 0
local function check(name, fn)
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
    local Scaler = require("vnc/scaler")
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

local function main()
    scaler_checks()

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
                if not log_has(log, "INPUT SetEncodings 7,16,15,5,1,2,0,-223,-239,-27,-247") then
                    return nil, "SetEncodings mismatch:\n" .. (read_file(log) or "")
                end
                return true
            end,
        })
    end)

    check("encodings_tight_no_zlib_with_explicit_filter", function()
        -- libvncserver at compression level 0 sends mono/indexed rects as control 0x0E: "no zlib"
        -- plus an explicit (palette) filter; small data comes inline, larger with a compact length
        local Util = require("vnc/util")
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

    check("rich_cursor_shape_is_parsed", function()
        -- RichCursor (-239): hotspot in x, y; w x h PIXELs, then the 1-bit mask, MSB first
        local Protocol = require("vnc/protocol")
        local Util = require("vnc/util")
        local got
        local p = Protocol.new{ io = { read = function() error("no reads expected") end, write = function() end },
            callbacks = { on_cursor = function(...) got = { ... } end } }
        local px = "\255\0\0\0" .. "\0\255\0\0" .. "\0\0\255\0" .. "\9\9\9\0" -- 2x2, 32 bpp
        local hdr = string.char(0, 1, 0, 0, 0, 2, 0, 2) .. string.char(0xFF, 0xFF, 0xFF, 0x11) -- hotspot 1,0; -239
        local r = Util.mem_reader(hdr .. px .. "\128\064")
        p:_rect(r)
        if not got then return nil, "no on_cursor" end
        if r:remaining() ~= 0 then return nil, "left " .. r:remaining() .. " bytes" end
        local hx, hy, w, h, rgb, mask = unpack(got)
        if not (hx == 1 and hy == 0 and w == 2 and h == 2) then return nil, "geometry" end
        if rgb ~= "\255\0\0\0\255\0\0\0\255\9\9\9" or mask ~= "\128\064" then return nil, "pixels or mask" end
        -- an empty cursor hides it and carries no data
        got = nil
        p:_rect(Util.mem_reader(string.char(0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x11)))
        if not (got and got[3] == 0 and got[4] == 0) then return nil, "empty cursor" end
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
        local w = require("vnc/util").writer()
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

    -- 11. A server message that arrives split across TCP segments: the transport keeps the
    -- partial reads and resumes, and the protocol decodes the message once the rest arrives.
    -- (The mock writes every message in small chunks, with a pause between them, so the reads
    -- between the chunks really do time out.)
    check("session_split_server_message", function()
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
        s:connect(function(ok, err) connected, cerr = ok, err end)
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
    end)

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
        s:connect(function(ok, err) connected, cerr = ok, err end)
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
        s:connect(function(ok, err) connected, cerr = ok, err end)
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
        local Util = require("vnc/util")
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
        s:connect(function(ok, err) connected, cerr = ok, err end)
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
        s:connect(function(ok, err) connected, cerr = ok, err end)
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

    -- 18-22. The picture-settings benchmark (vnc/benchmark.lua) against the real mock, on a fake
    -- clock: a stand-in UIManager runs scheduled tasks in time order and advances the clock to
    -- each task's due time, sleeping a little real time per task so the mock can answer.
    local function bench_env()
        local Session = load_session()
        local UIManager = require("ui/uimanager")
        local Benchmark = require("vnc/benchmark")
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
    -- Starts a mock that serves several connections in a row (the benchmark reconnects).
    local function start_multi(o)
        local port = free_port()
        local log = string.format("%s/%s.log", TMP, o.name)
        os.remove(log)
        local cmd = string.format("python3 %s --port %d --encoding %s --pattern gradient --width 200 --height 150 --log %s%s",
            MOCK, port, o.encoding or "raw", log, (o.repaint and (" --repaint " .. o.repaint) or "") .. (o.extra or ""))
        local h = assert(io.popen(cmd .. " > " .. log .. ".stdout 2>&1 & echo $!", "r"))
        local pid = (h:read("*l") or ""):gsub("%s", "")
        h:close()
        if not wait_for_log(log, "LISTENING", 10) then error("mock did not start: " .. log) end
        return pid, port, log
    end

    -- Records every session the benchmark creates.
    local function track_sessions()
        local Session = require("vnc/session")
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
        local Benchmark = require("vnc/benchmark")
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
        if Benchmark.FULL_SAMPLES ~= 3 or Benchmark.TILES ~= 16 then
            return nil, "FULL_SAMPLES / TILES"
        end
        if Benchmark.LIVE_SECONDS ~= nil or Benchmark.STILL_MIN_PX_PER_S ~= nil then
            return nil, "the live phase and the still detection are gone"
        end
        return true
    end)

    check("benchmark_sort_order", function()
        local Benchmark = require("vnc/benchmark")
        local rows = {
            { ok = false, error = "x", tag = "fail" },
            { ok = true, tile_px_per_s = 10, full_px_per_s = 99999, tag = "slow" },
            { ok = true, tile_px_per_s = 50, full_px_per_s = 1, tag = "fast" },
            { ok = true, tile_px_per_s = 10, full_px_per_s = 5, tag = "slow2" },
        }
        local s = Benchmark._sort(rows)
        local got = {}
        for i, r in ipairs(s) do got[i] = r.tag end
        got = table.concat(got, ",")
        if got ~= "fast,slow,slow2,fail" then return nil, "order " .. got end
        return true
    end)

    -- The FramebufferUpdateRequest lines of the mock's log, one list per connection.
    local function requests_per_connection(log)
        local conns = {}
        for line in (read_file(log) or ""):gmatch("[^\n]+") do
            if line:find("CONNECT", 1, true) and not line:find("DISCONNECT", 1, true) then
                conns[#conns + 1] = {}
            else
                local inc, x, y, w, h = line:match("FramebufferUpdateRequest incremental=(%d) x=(%d+) y=(%d+) w=(%d+) h=(%d+)")
                if inc and #conns > 0 then
                    local c = conns[#conns]
                    c[#c + 1] = string.format("%s %s,%s %sx%s", inc, x, y, w, h)
                end
            end
        end
        return conns
    end

    -- Still screen (the mock never repaints): every combination is scored from forced requests,
    -- with the same pixel counts per phase; 3 whole-screen requests, then the 16 tiles of a 4x4
    -- grid, all non-incremental, one at a time; drawn into a 2x canvas with sharp scaling.
    check("benchmark_scores_still_screen", function()
        local env = bench_env()
        local Remote = require("vnc/framebuffer")
        local pid, port, log = start_multi{ name = "bench_still" }
        local real_draw, draws = Remote.draw_to, {}
        Remote.draw_to = function(self, bb, ...)
            local dither = select(5, ...)
            draws[#draws + 1] = { scaling = self.scaling, scale = self:get_scale(), w = bb:getWidth(),
                                  h = bb:getHeight(), bb = bb, dither = dither }
            return real_draw(self, bb, ...)
        end
        local results, progress = nil, {}
        local b = env.Benchmark.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "bench" },
            combinations = combos(env.Benchmark, "24-bit, Tight off", "8-bit, Tight off", "24-bit, Tight, compr. 2"),
            canvas = { w = 400, h = 300, bb_type = BB.TYPE_BB8, view_mode = "fit", scaling = "sharp", dither = true },
            network_mgr = NET,
            on_progress = function(i, n, label, phase) progress[#progress + 1] = i .. "/" .. n .. " " .. phase end,
            on_done = function(r) results = r end,
        }
        b:start()
        local finished = env.run(function() return results ~= nil end)
        Remote.draw_to = real_draw
        env.restore()
        stop_mock(pid)
        if not finished then return nil, "benchmark never finished" end
        if #results ~= 3 then return nil, "expected 3 results, got " .. #results end
        for _, r in ipairs(results) do
            local l = r.combination.label
            if not r.ok then return nil, l .. " failed: " .. tostring(r.error) end
            if r.still ~= nil then return nil, "no still flag any more" end
            if not (r.tile_px_per_s > 0 and r.full_px_per_s > 0 and r.tile_ms and r.full_ms
                    and r.full_bytes and r.full_bytes > 0) then
                return nil, "missing figures for " .. l
            end
            -- two passes; the warm-up full frame of each is not counted: 2 of the 3, twice
            if r.full.n ~= 4 or r.full.px ~= 4 * 200 * 150 then
                return nil, string.format("%s: full phase %d frames, %d px", l, r.full.n, r.full.px)
            end
            if r.tiles.n ~= 32 or r.tiles.px ~= 2 * 200 * 150 then
                return nil, string.format("%s: tiles phase %d tiles, %d px", l, r.tiles.n, r.tiles.px)
            end
            if not (r.full.draw_ms > 0 and r.tiles.draw_ms > 0) then return nil, l .. ": draw time not counted" end
            if not (r.full.bytes > 0 and r.tiles.bytes > 0 and r.full.decode_ms >= 0 and r.tiles.decode_ms >= 0) then
                return nil, l .. ": bytes / decode time missing"
            end
            -- medians (benchmark_scoring_medians) lie within the samples' range
            if not (r.tile_ms > 0 and r.full_ms > 0 and r.tile_ms <= r.tiles.elapsed * 1000
                    and r.full_ms <= r.full.elapsed * 1000) then
                return nil, l .. ": scores do not follow from the samples"
            end
        end
        for i = 2, #results do
            if results[i - 1].tile_px_per_s < results[i].tile_px_per_s then return nil, "not sorted by tile_px_per_s" end
        end
        -- the reply to a request is read as soon as it arrives, not on the session's next 50 ms poll
        local poll_ms = env.Session.POLL_INTERVAL * 1000
        for _, r in ipairs(results) do
            if not (r.tile_ms < poll_ms and r.full_ms < poll_ms) then
                return nil, string.format("%s: %.1f ms/tile, full %.1f ms: a poll interval is in every sample",
                    r.combination.label, r.tile_ms, r.full_ms)
            end
        end
        -- the requests, per connection
        local conns = requests_per_connection(log)
        if #conns ~= 6 then return nil, "expected 6 connections (3 combinations, 2 passes), got " .. #conns end
        local want = { "0 0,0 200x150", "0 0,0 200x150", "0 0,0 200x150" }
        local xs, ys = { 0, 50, 100, 150, 200 }, { 0, 37, 75, 112, 150 }
        for r = 1, 4 do
            for c = 1, 4 do
                want[#want + 1] = string.format("0 %d,%d %dx%d", xs[c], ys[r], xs[c + 1] - xs[c], ys[r + 1] - ys[r])
            end
        end
        for i, got in ipairs(conns) do
            local a, w = table.concat(got, ";"), table.concat(want, ";")
            if a ~= w then return nil, string.format("connection %d requests:\n%s\nwant:\n%s", i, a, w) end
        end
        if #draws == 0 then return nil, "never drawn" end
        local bb1 = draws[1].bb
        for _, d in ipairs(draws) do
            if d.scaling ~= "sharp" or d.scale ~= 2 or d.w ~= 400 or d.h ~= 300 then
                return nil, string.format("draw %s scale %s %dx%d", d.scaling, d.scale, d.w, d.h)
            end
            if d.bb ~= bb1 then return nil, "the off-screen buffer must be allocated once per run" end
            if d.dither ~= true then return nil, "the canvas dither flag must be passed to draw_to" end
        end
        if #draws < 6 * (3 + 16) then return nil, "every received update must be drawn, got " .. #draws end
        local p = table.concat(progress, ",")
        if not p:find("1/6 full", 1, true) or not p:find("6/6 tiles", 1, true) or p:find("live", 1, true) then
            return nil, "progress " .. p
        end
        return true
    end)

    -- A combination the server refuses (Tight off against a Tight-only mock) fails and the run
    -- continues; the scored one ranks first.
    check("benchmark_failed_combination", function()
        local env = bench_env()
        local pid, port, log = start_multi{ name = "bench_failed", encoding = "tight" }
        local results, run_err
        local b = env.Benchmark.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "bench" },
            combinations = combos(env.Benchmark, "24-bit, Tight off", "24-bit, Tight, compr. 2"),
            canvas = { w = 200, h = 150, bb_type = BB.TYPE_BB8, view_mode = 1, scaling = "smooth" },
            network_mgr = NET,
            on_done = function(r, e) results, run_err = r, e end,
        }
        b:start()
        local finished = env.run(function() return results ~= nil end)
        env.restore()
        stop_mock(pid)
        if not finished then return nil, "benchmark never finished" end
        if #results ~= 2 then return nil, "expected 2 results" end
        local r1, r2 = results[1], results[2]
        if not (r1.ok and r1.combination.label == "24-bit, Tight, compr. 2") then
            return nil, string.format("first row: ok=%s err=%s", tostring(r1.ok), tostring(r1.error))
        end
        if not (r1.full_ms and r1.full_ms >= 0 and r1.tile_px_per_s > 0) then return nil, "figures missing" end
        -- the Tight mock answers every tile with the whole screen: only the requested area counts
        if r1.tiles.px ~= 2 * 200 * 150 or r1.full.px ~= 4 * 200 * 150 then
            return nil, string.format("pixels not capped at the requested areas: tiles %d, full %d", r1.tiles.px, r1.full.px)
        end
        if r2.ok ~= false or type(r2.error) ~= "string" or r2.error == "" then
            return nil, "the refused combination must fail with a reason"
        end
        if log_count(log, "AUTH ok") ~= 4 then return nil, "expected 4 connections (2 passes)" end
        if r2.error:sub(1, 18) ~= "failed in pass 1: " then return nil, "row error " .. r2.error end
        if run_err ~= nil then return nil, "a failure after connecting must not end the run: " .. tostring(run_err) end
        return true
    end)

    -- A DesktopSize mid-run (on the 5th request, a tile) fails the combination, which then asks
    -- for nothing more; the run goes on.
    check("benchmark_resize_fails_the_combination", function()
        local env = bench_env()
        local pid, port, log = start_multi{ name = "bench_resize", extra = " --resize-after 5" }
        local results
        local b = env.Benchmark.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "bench" },
            combinations = combos(env.Benchmark, "24-bit, Tight off", "8-bit, Tight off"),
            canvas = { w = 200, h = 150, bb_type = BB.TYPE_BB8 },
            network_mgr = NET,
            on_done = function(r) results = r end,
        }
        b:start()
        local finished = env.run(function() return results ~= nil end)
        env.restore()
        stop_mock(pid)
        if not finished then return nil, "benchmark never finished" end
        if #results ~= 2 then return nil, "expected 2 results, got " .. #results end
        -- the mock resizes on every connection's 5th request
        for _, r in ipairs(results) do
            if r.ok ~= false or r.error ~= "failed in pass 1: screen size changed" then
                return nil, r.combination.label .. ": ok=" .. tostring(r.ok) .. " error=" .. tostring(r.error)
            end
        end
        -- no tile is requested after the resize: only the session's own whole-screen request
        for i, reqs in ipairs(requests_per_connection(log)) do
            local after = 0
            for j = 6, #reqs do after = after + 1 end
            if #reqs < 6 or reqs[6] ~= "0 0,0 232x166" or after ~= 1 then
                return nil, string.format("connection %d requests: %s", i, table.concat(reqs, ";"))
            end
        end
        return true
    end)

    -- Tiles below 1 px are not requested; the rest cover the framebuffer exactly.
    check("benchmark_tiles_skip_empty", function()
        local Benchmark = require("vnc/benchmark")
        for _, sz in ipairs{ { 3, 2 }, { 200, 150 }, { 1, 1 } } do
            local area = 0
            for _, t in ipairs(Benchmark._tiles(sz[1], sz[2], 16)) do
                if t.w < 1 or t.h < 1 then return nil, string.format("%dx%d: empty tile requested", sz[1], sz[2]) end
                area = area + t.w * t.h
            end
            if area ~= sz[1] * sz[2] then return nil, string.format("%dx%d: tiles cover %d px", sz[1], sz[2], area) end
        end
        return true
    end)

    -- Lengths and sizes on the wire are the server's to choose. The client must not allocate on
    -- their say-so: a desktop name, a reason or a cut text over 1 MiB fails the connection, and so
    -- does a framebuffer that is empty or would take more than 256 MiB as a plane - with an error
    -- that says so, before anything is read or allocated.
    do
        local Util = require("vnc/util")
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
        if s:get_state() ~= "error" then
            return nil, "the current attempt's callback must dial, state " .. tostring(s:get_state())
        end
        s:disconnect()
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
        local ok, err = pcall(s.connect, s, function() end)
        socket.tcp = real_tcp
        if not ok then return nil, err end
        if s:get_state() ~= "error" then return nil, "the connect must fail, state " .. tostring(s:get_state()) end
        if closed ~= 1 then return nil, "the refused socket must be closed once, closed " .. closed .. " time(s)" end
        return true
    end)

    -- A failure before the handshake completes (refused, auth, Wi-Fi) ends the whole run at once:
    -- one session, one failed row, and on_done gets the error.
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
            local results, err, calls = nil, nil, 0
            local b = env.Benchmark.new{
                profile = { host = "127.0.0.1", port = c.port, password = c.password or "", name = "bench" },
                combinations = combos(env.Benchmark, "24-bit, Tight off", "8-bit, Tight off"),
                canvas = { w = 100, h = 100, bb_type = BB.TYPE_BB8 },
                network_mgr = c.net,
                on_done = function(r, e) calls = calls + 1; results, err = r, e end,
            }
            b:start()
            local finished = env.run(function() return results ~= nil end)
            env.run(nil, 200)
            untrack()
            env.restore()
            if not finished then problem = c.what .. ": never finished"
            elseif type(err) ~= "string" or err == "" then problem = c.what .. ": on_done got no error"
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

    -- Cancel mid-tiles: the session is torn down, nothing of the benchmark stays scheduled, on_done
    -- never fires, and an attached bystander session (the viewer's) keeps its poll task.
    check("benchmark_cancel_mid_tiles", function()
        local env = bench_env()
        local Session = require("vnc/session")
        local pid, port = start_multi{ name = "bench_cancel" }
        local bpid, bport = start_mock{ name = "bench_bystander", encoding = "raw", pattern = "gradient" }
        local by = Session.new{ profile = { host = "127.0.0.1", port = bport, password = "", name = "by" },
                                network_mgr = NET }
        by:connect(function() end)
        by:attach({ on_framebuffer_dirty = function() end, on_remote_resized = function() end,
                    on_bell = function() end })
        local done_called, tiles = false, false
        local b = env.Benchmark.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "bench" },
            combinations = combos(env.Benchmark, "24-bit, Tight off", "8-bit, Tight off"),
            canvas = { w = 200, h = 150, bb_type = BB.TYPE_BB8 },
            network_mgr = NET,
            on_progress = function(_, _, _, phase) if phase == "tiles" then tiles = true end end,
            on_done = function() done_called = true end,
        }
        b:start()
        local reached = env.run(function() return tiles end)
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
        if not reached then return nil, "tiles phase never reached" end
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
        for _, at in ipairs{ "connect", "full", "tiles" } do
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
        local Session = require("vnc/session")
        local pid, port = start_multi{ name = "bench_detach" }
        local bpid, bport = start_mock{ name = "bench_detach_by", encoding = "raw", pattern = "gradient" }
        local problem
        for _, ending in ipairs{ "done", "cancel" } do
            local env = bench_env()
            local by = Session.new{ profile = { host = "127.0.0.1", port = bport, password = "", name = "by" },
                                    network_mgr = NET }
            local idle = Session.new{ profile = { host = "127.0.0.1", port = bport, password = "", name = "idle" },
                                      network_mgr = NET }
            by:connect(function() end)
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
                    if phase == "tiles" then
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
            by:disconnect()
            env.restore()
            if seen_attached == nil then problem = ending .. ": tiles phase never reached"
            elseif seen_attached or seen_task then problem = ending .. ": the attached session was not detached during the run"
            elseif not back then problem = ending .. ": the session was not attached again (tasks " .. tasks .. ")"
            elseif not idle_ok then problem = ending .. ": a session that was not attached got attached" end
            if problem then break end
        end
        stop_mock(pid)
        stop_mock(bpid)
        if problem then return nil, problem end
        return true
    end)

    -- The "tiles" progress (an e-ink refresh of the dialog title) is reported before the first
    -- tile is requested, and that request goes out on a later tick.
    check("benchmark_tiles_start_after_progress", function()
        local Session = require("vnc/session")
        local pid, port = start_multi{ name = "bench_window" }
        local env = bench_env()
        local t_report, reqs_at_report, results, b
        local real_req, reqs = Protocol.request_update, 0
        Protocol.request_update = function(...) reqs = reqs + 1; return real_req(...) end
        b = env.Benchmark.new{
            profile = { host = "127.0.0.1", port = port, password = "", name = "bench" },
            combinations = combos(env.Benchmark, "24-bit, Tight off"),
            canvas = { w = 200, h = 150, bb_type = BB.TYPE_BB8 },
            network_mgr = NET,
            on_progress = function(_, _, _, phase)
                -- the first run's (every run reports its own)
                if phase == "tiles" and not t_report then
                    t_report = Session._now()
                    reqs_at_report = reqs
                end
            end,
            on_done = function(r) results = r end,
        }
        b:start()
        env.run(function() return t_report ~= nil end)
        local unchanged = (reqs_at_report == reqs)
        env.run(function() return results ~= nil or (b.run and b.run.t_tiles) end)
        local t_tiles = b.run and b.run.t_tiles
        env.run(function() return results ~= nil end)
        Protocol.request_update = real_req
        env.restore()
        stop_mock(pid)
        if not t_report then return nil, "tiles never reported" end
        if reqs_at_report ~= 3 then
            return nil, "requests before the tiles progress: " .. tostring(reqs_at_report)
        end
        if not unchanged then return nil, "a tile was requested in the tick that reported the progress" end
        if not t_tiles or t_tiles <= t_report then return nil, "the first tile must be requested on a later tick" end
        if not (results and results[1] and results[1].ok) then return nil, "run did not score" end
        return true
    end)

    -- Scores are medians over every sample of both passes, so one slow outlier (a Wi-Fi hiccup)
    -- does not move them the way a mean would; the full frame's bytes stay a mean.
    check("benchmark_scoring_medians", function()
        local Benchmark = require("vnc/benchmark")
        if Benchmark.PASSES ~= 2 then return nil, "PASSES " .. tostring(Benchmark.PASSES) end
        local function smp(px, elapsed, bytes)
            return { px = px, elapsed = elapsed, bytes = bytes or 10, decode = 0.001, draw = 0.002 }
        end
        local combo = Benchmark.COMBINATIONS[1]
        -- tiles: elapsed median 0.011 (the mean, 0.1086, is skewed by the 0.5 s outlier);
        -- px/s per sample 10000, 8333, 9091, 200, 20000: median 9091 = 100 / 0.011
        local tiles = { smp(100, 0.010), smp(100, 0.012), smp(100, 0.011), smp(100, 0.500), smp(200, 0.010) }
        -- full frames (counted ones): an even count, median (0.110 + 0.120) / 2
        local full = { smp(30000, 0.100, 1000), smp(30000, 0.120, 3000), smp(30000, 0.110, 2000),
                       smp(30000, 2.000, 2000) }
        local r = Benchmark._score(combo, full, tiles)
        local function near(a, b) return math.abs(a - b) < 1e-6 * math.max(1, math.abs(b)) end
        if not (r.ok == true and r.combination == combo) then return nil, "row not ok" end
        if not near(r.tile_ms, 11) then return nil, "tile_ms " .. r.tile_ms end
        if not near(r.tile_px_per_s, 100 / 0.011) then return nil, "tile_px_per_s " .. r.tile_px_per_s end
        if not near(r.full_ms, 115) then return nil, "full_ms " .. r.full_ms end
        if not near(r.full_px_per_s, 30000 / 0.115) then return nil, "full_px_per_s " .. r.full_px_per_s end
        if not near(r.full_bytes, 2000) then return nil, "full_bytes (mean) " .. r.full_bytes end
        if not (r.full.n == 4 and r.full.px == 120000 and r.full.bytes == 8000 and near(r.full.elapsed, 2.33)) then
            return nil, "full totals"
        end
        if not (r.tiles.n == 5 and r.tiles.px == 600 and near(r.tiles.elapsed, 0.543) and near(r.tiles.draw_ms, 10)
                and near(r.tiles.decode_ms, 5)) then
            return nil, "tiles totals"
        end
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
            if not r.ok or r.tiles.n ~= 32 or r.full.n ~= 4 then
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
            on_progress = function(_, _, _, phase, pass) if pass == 2 and phase == "tiles" then b:cancel() end end,
            on_done = function() done_called = true end,
        }
        b:start()
        env.run(nil, 4000)
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
        s:connect(function(ok, err) connected, cerr = ok, err end)
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

    check("remote_visible_rect_fit_and_zoomed", function()
        local Remote = require("vnc/framebuffer")
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

    check("session_fit_requests_whole_framebuffer", function()
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
    end)

    check("session_zoomed_requests_visible_area", function()
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
    end)

    check("session_pan_requests_newly_visible_area", function()
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
    end)

    -- Not attached (the viewer is closed): the newly visible area is only queued; attach's
    -- whole-screen request covers it.
    check("session_view_area_queued_while_detached", function()
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
    end)

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

    stop_all_mocks()
    if failures > 0 then
        print(string.format("%d check(s) failed", failures))
        os.exit(1)
    end
    print("all checks passed")
    os.exit(0)
end

main()
