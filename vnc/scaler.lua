--[[--
Scales the remote plane into a canvas-sized buffer, one canvas rect at a time.

Every canvas pixel is computed from its global canvas position only (never from the rect it
is drawn as part of), so any partition of the canvas into rects yields the same image as one
full-canvas call. That is what lets the caller redraw only the pixels a remote update touched.

The view is `{x = view_x, y = view_y, scale = s}` with the same meaning as in
@{vnc.framebuffer}: canvas pixel `(cx, cy)` shows the remote point
`(view_x + (cx + 0.5) / s - 0.5, view_y + (cy + 0.5) / s - 0.5)` (pixel centres).

Modes:

* `"sharp"`: nearest neighbour, `src = floor(view + (c + 0.5) / s)`.
* `"smooth"`: bilinear for `s >= 1`, area average (box filter over the footprint
  `[view + c / s, view + (c + 1) / s)`) for `s < 1`. Into `TYPE_BB8` the area average is taken
  of the grey values (one channel instead of three), so it is the floored grey of the exact
  colour mean.

At `s == 1` with an integral view offset both modes are a plain copy. Canvas pixels whose
centre lies outside the plane are black.

The source is the `TYPE_BBRGB24` plane; the destination may be `TYPE_BB8` (grey is
`(r*77 + g*150 + b*29) >> 8`), `TYPE_BBRGB24` or `TYPE_BBRGB32`, unrotated and not inverted.
The destination's pixel `(x, y)` is canvas pixel `(x, y)`.

@module vnc.scaler
]]

local ffi = require("ffi")
local BB = require("ffi/blitbuffer")

local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
-- integer shifts instead of floor(x / 2^n) on the per-pixel paths (values stay far below 2^31);
-- floor is a library call on ARM
local rshift = require("bit").rshift

local Scaler = {}

-- ---------------------------------------------------------------- per-axis tables

-- Per-axis mapping tables, cached by the parameters they depend on (one entry per slot), so
-- steady-state updates allocate nothing. Each table covers the whole axis (canvas length n);
-- [lo, hi) is the contiguous range of canvas positions whose centre lies inside the plane.
local axis_cache = {}

local function cached(slot, kind, n, v, s, len)
    local a = axis_cache[slot]
    if a and a.kind == kind and a.n == n and a.v == v and a.s == s and a.len == len then
        return a
    end
end

--- Canvas range [lo, hi) whose pixel centre lies inside [0, len).
local function valid_range(n, v, s, len)
    local lo, hi = n, 0
    for c = 0, n - 1 do
        local u = v + (c + 0.5) / s
        if u >= 0 and u < len then
            if c < lo then lo = c end
            hi = c + 1
        end
    end
    if hi <= lo then lo, hi = 0, 0 end
    return lo, hi
end

--- Nearest neighbour: idx[c] = source index.
local function axis_sharp(slot, n, v, s, len)
    local a = cached(slot, "sharp", n, v, s, len)
    if a then return a end
    local idx = ffi.new("int32_t[?]", max(n, 1))
    for c = 0, n - 1 do
        idx[c] = max(0, min(len - 1, floor(v + (c + 0.5) / s)))
    end
    local lo, hi = valid_range(n, v, s, len)
    a = { kind = "sharp", n = n, v = v, s = s, len = len, idx = idx, lo = lo, hi = hi }
    axis_cache[slot] = a
    return a
end

--- Bilinear: i0[c], i1[c] source indices, w[c] weight of i1 in 1/256.
local function axis_bilinear(slot, n, v, s, len)
    local a = cached(slot, "bilinear", n, v, s, len)
    if a then return a end
    local i0 = ffi.new("int32_t[?]", max(n, 1))
    local i1 = ffi.new("int32_t[?]", max(n, 1))
    local w = ffi.new("int32_t[?]", max(n, 1))
    for c = 0, n - 1 do
        local f = v + (c + 0.5) / s - 0.5
        local i = floor(f)
        local wt = floor((f - i) * 256)
        if i < 0 then
            i, wt = 0, 0
        elseif i >= len - 1 then
            i, wt = len - 1, 0
        end
        i0[c], i1[c], w[c] = i, min(i + 1, len - 1), wt
    end
    local lo, hi = valid_range(n, v, s, len)
    a = { kind = "bilinear", n = n, v = v, s = s, len = len, i0 = i0, i1 = i1, w = w,
          lo = lo, hi = hi }
    axis_cache[slot] = a
    return a
end

--- Box filter: canvas c averages source [first[c], first[c] + count[c]) with weights
--- wt[off[c] + k] (overlap in 1/256 of a pixel), summing to tot[c]. The weights past count[c]
--- are zero (at least 3 slots per position), and maxc is the largest count.
local function axis_box(slot, n, v, s, len)
    local a = cached(slot, "box", n, v, s, len)
    if a then return a end
    local per = ceil(1 / s) + 2
    local first = ffi.new("int32_t[?]", max(n, 1))
    local count = ffi.new("int32_t[?]", max(n, 1))
    local off = ffi.new("int32_t[?]", max(n, 1))
    local tot = ffi.new("int32_t[?]", max(n, 1))
    local wt = ffi.new("int32_t[?]", max(n * per, 1))
    local lo, hi = valid_range(n, v, s, len)
    local maxc = 0
    for c = 0, n - 1 do
        off[c] = c * per
        if c >= lo and c < hi then
            local f0 = max(0, v + c / s)
            local f1 = min(len, v + (c + 1) / s)
            local i0 = floor(f0)
            local i1 = min(len - 1, ceil(f1) - 1)
            local sum = 0
            for i = i0, i1 do
                local wi = floor((min(f1, i + 1) - max(f0, i)) * 256 + 0.5)
                wt[c * per + i - i0] = wi
                sum = sum + wi
            end
            first[c], count[c], tot[c] = i0, i1 - i0 + 1, sum
            if i1 - i0 + 1 > maxc then maxc = i1 - i0 + 1 end
        end
    end
    a = { kind = "box", n = n, v = v, s = s, len = len, first = first, count = count,
          off = off, tot = tot, wt = wt, lo = lo, hi = hi, maxc = maxc }
    axis_cache[slot] = a
    return a
end

-- ---------------------------------------------------------------- scratch rows

-- Reused scratch buffers (grown on demand, never shrunk).
local scratch = {}
local function scratch_buf(name, ctype, n)
    local b = scratch[name]
    if not b or b.n < n then
        b = { n = n, p = ffi.new(ctype .. "[?]", n) }
        scratch[name] = b
    end
    return b.p
end

-- ---------------------------------------------------------------- destination access

local BPP = { [BB.TYPE_BB8] = 1, [BB.TYPE_BBRGB24] = 3, [BB.TYPE_BBRGB32] = 4 }

local function fill_black(dp, ds, bpp, x, y, w, h)
    if w <= 0 or h <= 0 then return end
    for yy = y, y + h - 1 do
        local row = dp + yy * ds + x * bpp
        if bpp == 4 then
            for k = 0, w - 1 do
                local o = k * 4
                row[o], row[o + 1], row[o + 2], row[o + 3] = 0, 0, 0, 255
            end
        else
            ffi.fill(row, w * bpp, 0)
        end
    end
end

-- ---------------------------------------------------------------- kernels
-- Each kernel fills canvas columns [xa, xb) of rows [ya, yb), all of which are inside the plane.

local function sharp_kernel(dp, ds, bpp, sp, ss, ax, ay, xa, xb, ya, yb)
    local xi, yi = ax.idx, ay.idx
    if bpp == 1 then
        -- grey once per source pixel of the needed span, reused while the source row repeats
        local sa, sb = xi[xa], xi[xb - 1]
        local grow = scratch_buf("grey8", "uint8_t", sb + 1)
        local lastj = -1
        for y = ya, yb - 1 do
            local j = yi[y]
            if j ~= lastj then
                local r = sp + j * ss
                for i = sa, sb do
                    local o = i * 3
                    grow[i] = rshift(r[o] * 77 + r[o + 1] * 150 + r[o + 2] * 29, 8)
                end
                lastj = j
            end
            local out = dp + y * ds
            for x = xa, xb - 1 do out[x] = grow[xi[x]] end
        end
    else
        for y = ya, yb - 1 do
            local r = sp + yi[y] * ss
            local out = dp + y * ds
            for x = xa, xb - 1 do
                local o, d = xi[x] * 3, x * bpp
                out[d], out[d + 1], out[d + 2] = r[o], r[o + 1], r[o + 2]
                if bpp == 4 then out[d + 3] = 255 end
            end
        end
    end
end

--- s == 1, integral offset: straight copy (dx, dy = source - canvas offset).
local function copy_kernel(dp, ds, bpp, sp, ss, dx, dy, xa, xb, ya, yb)
    for y = ya, yb - 1 do
        local r = sp + (y + dy) * ss + (xa + dx) * 3
        local out = dp + y * ds + xa * bpp
        local n = xb - xa
        if bpp == 3 then
            ffi.copy(out, r, n * 3)
        elseif bpp == 1 then
            for k = 0, n - 1 do
                local o = k * 3
                out[k] = rshift(r[o] * 77 + r[o + 1] * 150 + r[o + 2] * 29, 8)
            end
        else
            for k = 0, n - 1 do
                local o, d = k * 3, k * 4
                out[d], out[d + 1], out[d + 2], out[d + 3] = r[o], r[o + 1], r[o + 2], 255
            end
        end
    end
end

local function grey_row(buf, r, sa, sb)
    for i = sa, sb do
        local o = i * 3
        buf[i] = r[o] * 77 + r[o + 1] * 150 + r[o + 2] * 29
    end
end

--- One source row interpolated horizontally (x256) for canvas columns [xa, xb), 3 per column.
local function hlerp_row(buf, r, xi0, xi1, xw, xa, xb)
    for x = xa, xb - 1 do
        local a, b, wx, d = xi0[x] * 3, xi1[x] * 3, xw[x], x * 3
        local p = r[a]
        buf[d] = p * 256 + (r[b] - p) * wx
        p = r[a + 1]
        buf[d + 1] = p * 256 + (r[b + 1] - p) * wx
        p = r[a + 2]
        buf[d + 2] = p * 256 + (r[b + 2] - p) * wx
    end
end

local function bilinear_kernel(dp, ds, bpp, sp, ss, ax, ay, xa, xb, ya, yb)
    local xi0, xi1, xw = ax.i0, ax.i1, ax.w
    local yi0, yi1, yw = ay.i0, ay.i1, ay.w
    if bpp == 1 then
        -- unscaled grey (x256) of the two source rows, reused while they repeat
        local sa, sb = xi0[xa], xi1[xb - 1]
        local ga = scratch_buf("greyA", "int32_t", sb + 1)
        local gb = scratch_buf("greyB", "int32_t", sb + 1)
        local ta, tb = -1, -1
        for y = ya, yb - 1 do
            local j, j1, wy = yi0[y], yi1[y], yw[y]
            if j ~= ta then
                if j == tb then
                    ga, gb, ta, tb = gb, ga, tb, ta
                else
                    grey_row(ga, sp + j * ss, sa, sb); ta = j
                end
            end
            if j1 ~= tb then grey_row(gb, sp + j1 * ss, sa, sb); tb = j1 end
            local out = dp + y * ds
            for x = xa, xb - 1 do
                local a, b, wx = xi0[x], xi1[x], xw[x]
                local g00, g10 = ga[a], gb[a]
                local top = g00 * 256 + (ga[b] - g00) * wx
                local bot = g10 * 256 + (gb[b] - g10) * wx
                -- a non-negative double stored into a uint8_t is truncated, i.e. floored
                out[x] = (top * 256 + (bot - top) * wy) / 16777216
            end
        end
    else
        -- the two source rows interpolated horizontally once, reused while they repeat (an
        -- upscale shows each source row pair in several canvas rows)
        local ha = scratch_buf("hlerpA", "int32_t", xb * 3)
        local hb = scratch_buf("hlerpB", "int32_t", xb * 3)
        local ta, tb = -1, -1
        for y = ya, yb - 1 do
            local j, j1, wy = yi0[y], yi1[y], yw[y]
            if j ~= ta then
                if j == tb then
                    ha, hb, ta, tb = hb, ha, tb, ta
                else
                    hlerp_row(ha, sp + j * ss, xi0, xi1, xw, xa, xb); ta = j
                end
            end
            if j1 ~= tb then hlerp_row(hb, sp + j1 * ss, xi0, xi1, xw, xa, xb); tb = j1 end
            local out = dp + y * ds
            for x = xa, xb - 1 do
                local c, d = x * 3, x * bpp
                local top, bot = ha[c], hb[c]
                out[d] = (top * 256 + (bot - top) * wy) / 65536
                top, bot = ha[c + 1], hb[c + 1]
                out[d + 1] = (top * 256 + (bot - top) * wy) / 65536
                top, bot = ha[c + 2], hb[c + 2]
                out[d + 2] = (top * 256 + (bot - top) * wy) / 65536
                if bpp == 4 then out[d + 3] = 255 end
            end
        end
    end
end

-- Box filter. Both passes run over whole spans with the per-pixel weights from the axis tables;
-- the horizontal pass reads a fixed three taps (the weights past a position's count are zero, and
-- the accumulators have room past the span) whenever no footprint is wider, so it has no inner
-- loop. A non-negative double stored into a uint8_t is truncated, which is the floor wanted.

--- Into TYPE_BB8: the area average of the (x256) grey values, one accumulator per column.
local function box_kernel_grey(dp, ds, sp, ss, ax, ay, xa, xb, ya, yb)
    local xf, xc, xo, xt, xwt = ax.first, ax.count, ax.off, ax.tot, ax.wt
    local yf, yc, yo, yt, ywt = ay.first, ay.count, ay.off, ay.tot, ay.wt
    local sa, sb = xf[xa], xf[xb - 1] + xc[xb - 1] - 1
    -- at most 65280 * 256 * 21 (scale 0.05) per column: fits int32
    local acc = scratch_buf("accY", "int32_t", sb + 3)
    local three = ax.maxc <= 3
    for y = ya, yb - 1 do
        -- vertical pass: weighted sum of the footprint's source rows, per source column
        local j0, oy, n = yf[y], yo[y], yc[y]
        local wy = ywt[oy]
        local r = sp + j0 * ss
        for i = sa, sb do
            local o = i * 3
            acc[i] = (r[o] * 77 + r[o + 1] * 150 + r[o + 2] * 29) * wy
        end
        for k = 1, n - 1 do
            wy = ywt[oy + k]
            r = sp + (j0 + k) * ss
            for i = sa, sb do
                local o = i * 3
                acc[i] = acc[i] + (r[o] * 77 + r[o + 1] * 150 + r[o + 2] * 29) * wy
            end
        end
        -- horizontal pass
        local ty = yt[y] * 256
        local out = dp + y * ds
        if three then
            for x = xa, xb - 1 do
                local i0, ox = xf[x], xo[x]
                out[x] = (acc[i0] * xwt[ox] + acc[i0 + 1] * xwt[ox + 1] + acc[i0 + 2] * xwt[ox + 2])
                    / (xt[x] * ty)
            end
        else
            for x = xa, xb - 1 do
                local i0, ox = xf[x], xo[x]
                local sum = 0
                for k = 0, xc[x] - 1 do
                    sum = sum + acc[i0 + k] * xwt[ox + k]
                end
                out[x] = sum / (xt[x] * ty)
            end
        end
    end
end

--- Into TYPE_BBRGB24/32: the area average of each channel, rounded half up.
local function box_kernel(dp, ds, bpp, sp, ss, ax, ay, xa, xb, ya, yb)
    if bpp == 1 then
        return box_kernel_grey(dp, ds, sp, ss, ax, ay, xa, xb, ya, yb)
    end
    local xf, xc, xo, xt, xwt = ax.first, ax.count, ax.off, ax.tot, ax.wt
    local yf, yc, yo, yt, ywt = ay.first, ay.count, ay.off, ay.tot, ay.wt
    local sa, sb = xf[xa], xf[xb - 1] + xc[xb - 1] - 1
    local ar = scratch_buf("accR", "int32_t", sb + 3)
    local ag = scratch_buf("accG", "int32_t", sb + 3)
    local ab = scratch_buf("accB", "int32_t", sb + 3)
    local three = ax.maxc <= 3
    for y = ya, yb - 1 do
        local j0, oy, n = yf[y], yo[y], yc[y]
        local wy = ywt[oy]
        local r = sp + j0 * ss
        for i = sa, sb do
            local o = i * 3
            ar[i], ag[i], ab[i] = r[o] * wy, r[o + 1] * wy, r[o + 2] * wy
        end
        for k = 1, n - 1 do
            wy = ywt[oy + k]
            r = sp + (j0 + k) * ss
            for i = sa, sb do
                local o = i * 3
                ar[i] = ar[i] + r[o] * wy
                ag[i] = ag[i] + r[o + 1] * wy
                ab[i] = ab[i] + r[o + 2] * wy
            end
        end
        local ty = yt[y]
        local out = dp + y * ds
        for x = xa, xb - 1 do
            local i0, ox = xf[x], xo[x]
            local sr, sg, sbl
            if three then
                local w0, w1, w2 = xwt[ox], xwt[ox + 1], xwt[ox + 2]
                sr = ar[i0] * w0 + ar[i0 + 1] * w1 + ar[i0 + 2] * w2
                sg = ag[i0] * w0 + ag[i0 + 1] * w1 + ag[i0 + 2] * w2
                sbl = ab[i0] * w0 + ab[i0 + 1] * w1 + ab[i0 + 2] * w2
            else
                sr, sg, sbl = 0, 0, 0
                for k = 0, xc[x] - 1 do
                    local wx = xwt[ox + k]
                    sr = sr + ar[i0 + k] * wx
                    sg = sg + ag[i0 + k] * wx
                    sbl = sbl + ab[i0 + k] * wx
                end
            end
            local t = xt[x] * ty
            local h = rshift(t, 1)
            local d = x * bpp
            out[d], out[d + 1], out[d + 2] = (sr + h) / t, (sg + h) / t, (sbl + h) / t
            if bpp == 4 then out[d + 3] = 255 end
        end
    end
end

-- ---------------------------------------------------------------- API

--[[--
Renders canvas rect `rect` of the view into `dst_bb`.

Writes exactly the pixels of `rect` (which must lie inside `dst_bb`).
--- @tparam BlitBuffer dst_bb canvas-sized `TYPE_BB8`, `TYPE_BBRGB24` or `TYPE_BBRGB32` buffer
--- @tparam BlitBuffer plane `TYPE_BBRGB24` remote plane
--- @tparam table view `{x, y, scale}`
--- @tparam table rect `{x, y, w, h}` in canvas coordinates
--- @tparam string mode `"smooth"` or `"sharp"`
]]
function Scaler.render(dst_bb, plane, view, rect, mode)
    local bpp = BPP[dst_bb:getType()]
    assert(bpp, "vnc.scaler: unsupported destination type")
    assert(dst_bb:getRotation() == 0 and dst_bb:getInverse() == 0,
        "vnc.scaler: destination must be unrotated and not inverted")
    local rx, ry, rw, rh = rect.x, rect.y, rect.w, rect.h
    if rw <= 0 or rh <= 0 then return end
    local x1, y1 = rx + rw, ry + rh
    local dp, ds = ffi.cast("uint8_t*", dst_bb.data), dst_bb.stride
    local sp, ss = ffi.cast("uint8_t*", plane.data), plane.stride
    local pw, ph = plane:getWidth(), plane:getHeight()
    local cw, ch = dst_bb:getWidth(), dst_bb:getHeight()
    local s, vx, vy = view.scale, view.x, view.y

    local kernel, ax, ay
    local copy = s == 1 and vx == floor(vx) and vy == floor(vy)
    if copy or mode == "sharp" then
        kernel, ax, ay = sharp_kernel, axis_sharp("x", cw, vx, s, pw), axis_sharp("y", ch, vy, s, ph)
    elseif s >= 1 then
        kernel, ax, ay = bilinear_kernel, axis_bilinear("x", cw, vx, s, pw),
            axis_bilinear("y", ch, vy, s, ph)
    else
        kernel, ax, ay = box_kernel, axis_box("x", cw, vx, s, pw), axis_box("y", ch, vy, s, ph)
    end

    -- inside-the-plane part of the rect; the rest is black
    local xa, xb = max(rx, ax.lo), min(x1, ax.hi)
    local ya, yb = max(ry, ay.lo), min(y1, ay.hi)
    if xa >= xb or ya >= yb then
        fill_black(dp, ds, bpp, rx, ry, rw, rh)
        return
    end
    fill_black(dp, ds, bpp, rx, ry, rw, ya - ry)
    fill_black(dp, ds, bpp, rx, yb, rw, y1 - yb)
    fill_black(dp, ds, bpp, rx, ya, xa - rx, yb - ya)
    fill_black(dp, ds, bpp, xb, ya, x1 - xb, yb - ya)

    if copy then
        copy_kernel(dp, ds, bpp, sp, ss, vx, vy, xa, xb, ya, yb)
    else
        kernel(dp, ds, bpp, sp, ss, ax, ay, xa, xb, ya, yb)
    end
end

-- Canvas interval [c0, c1] (inclusive, unclipped) whose pixels read source [r0, r1).
local function span_for(r0, r1, v, s, mode)
    if mode == "sharp" or s == 1 and v == floor(v) then
        -- floor(v + (c + 0.5) / s) in [r0, r1)
        return floor(s * (r0 - v) - 0.5), ceil(s * (r1 - v) - 0.5)
    elseif s >= 1 then
        -- bilinear reads floor(f) and floor(f) + 1, f = v + (c + 0.5) / s - 0.5, so source
        -- [r0, r1) matters for f in (r0 - 1, r1); the edge clamp (f in [-0.5, 0) reads 0,
        -- f in (len - 1, len - 0.5) reads len - 1) stays inside that interval
        return floor(s * (r0 - 1 - v + 0.5) - 0.5), ceil(s * (r1 - v + 0.5) - 0.5)
    else
        -- footprint [v + c / s, v + (c + 1) / s) meets [r0, r1)
        return floor(s * (r0 - v)) - 1, ceil(s * (r1 - v))
    end
end

--[[--
The canvas rect whose pixels depend on any pixel of `remote_rect`, clipped to the canvas.

Generous by up to a pixel on each side.
--- @tparam table remote_rect `{x, y, w, h}` in plane coordinates
--- @tparam table view `{x, y, scale}`
--- @tparam number canvas_w
--- @tparam number canvas_h
--- @tparam string mode `"smooth"` or `"sharp"`
--- @treturn table|nil `{x, y, w, h}`, or nil when empty
]]
function Scaler.dst_rect_for(remote_rect, view, canvas_w, canvas_h, mode)
    local s = view.scale
    local x0, x1 = span_for(remote_rect.x, remote_rect.x + remote_rect.w, view.x, s, mode)
    local y0, y1 = span_for(remote_rect.y, remote_rect.y + remote_rect.h, view.y, s, mode)
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(canvas_w - 1, x1), min(canvas_h - 1, y1)
    if x1 < x0 or y1 < y0 then return nil end
    return { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1 }
end

return Scaler
