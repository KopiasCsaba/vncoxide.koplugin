--[[--
RFB rectangle decoders.

Implements every encoding we advertise: Raw, CopyRect, RRE, Hextile, TRLE, ZRLE and
(opt-in) Tight, plus the DesktopSize pseudo-encoding marker. Normative reference is
RFC 6143 §7.6-7.7; Tight is not in the RFC and follows libvncclient's
`src/libvncclient/tight.c` (with noVNC's `core/decoders/tight.js` cross-checked).

Every decoder takes one `ctx` table and returns `true`, or `nil` plus an error string:

    ctx = {
      x, y, w, h,     -- rect geometry, in remote framebuffer coordinates
      r,              -- @{vnc.util|reader} positioned at the rect payload
      plane,          -- the whole remote plane (BlitBuffer, TYPE_BBRGB24)
      vp,             -- plane:viewport(x, y, w, h); decoders write rect-local coords
      streams,        -- per-connection persistent state (zlib streams, palettes)
      fmt,            -- client pixel format (@{vnc.pxfmt.for_depth}); default depth 24
    }

At 32 bpp a PIXEL is `[R, G, B, X]` and a CPIXEL/TPIXEL `[R, G, B]`; at 16/8 bpp both are
`fmt.bytes` wide and go through @{vnc.pxfmt.to_rgb24}.

@module vnc.encodings
]]

local bit = require("bit")
local ffi = require("ffi")

local BB = require("ffi/blitbuffer")
local PxFmt = require("vnc/pxfmt")
local Util = require("vnc/util")
local ZStream = require("vnc/zstream")

local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift

pcall(ffi.cdef, "void *memmove(void *dst, const void *src, size_t n);")

local Encodings = {}

Encodings.RAW           = 0
Encodings.COPYRECT      = 1
Encodings.RRE           = 2
Encodings.HEXTILE       = 5
Encodings.TIGHT         = 7
Encodings.TRLE          = 15
Encodings.ZRLE          = 16
Encodings.DESKTOP_SIZE  = -223
-- Tight pseudo-encodings: the server reads quality/level from the offset. They never
-- arrive as rects, so they stay out of SUPPORTED.
Encodings.JPEG_QUALITY_0   = -32
Encodings.COMPRESS_LEVEL_0 = -256

--- Encodings we can decode (DesktopSize is a marker handled by the protocol).
Encodings.SUPPORTED = {
    [Encodings.RAW] = true,
    [Encodings.COPYRECT] = true,
    [Encodings.RRE] = true,
    [Encodings.HEXTILE] = true,
    [Encodings.TIGHT] = true,
    [Encodings.TRLE] = true,
    [Encodings.ZRLE] = true,
}

--- Preferred encoding list, most compact first (Tight is opt-in).
Encodings.ORDER_DEFAULT = { Encodings.ZRLE, Encodings.TRLE, Encodings.HEXTILE,
                            Encodings.COPYRECT, Encodings.RRE, Encodings.RAW,
                            Encodings.DESKTOP_SIZE }
Encodings.ORDER_TIGHT = { Encodings.TIGHT, Encodings.ZRLE, Encodings.TRLE,
                          Encodings.HEXTILE, Encodings.COPYRECT, Encodings.RRE,
                          Encodings.RAW, Encodings.DESKTOP_SIZE }

--- @tparam boolean enable_tight
--- @tparam[opt] table opts {jpeg_quality = false|0..9, compress_level = false|0..9};
---   only honoured with Tight, `false`/nil leaves the server default
--- @treturn table new encoding list to send in SetEncodings
function Encodings.order(enable_tight, opts)
    local base = enable_tight and Encodings.ORDER_TIGHT or Encodings.ORDER_DEFAULT
    local list = {}
    for i = 1, #base do list[i] = base[i] end
    if enable_tight and opts then
        if type(opts.jpeg_quality) == "number" then
            list[#list + 1] = Encodings.JPEG_QUALITY_0 + opts.jpeg_quality
        end
        if type(opts.compress_level) == "number" then
            list[#list + 1] = Encodings.COMPRESS_LEVEL_0 + opts.compress_level
        end
    end
    return list
end

Encodings.TIGHT_MIN_TO_COMPRESS = 12
Encodings.TIGHT_GRADIENT_MAX_WIDTH = 4096
Encodings.TIGHT_FILL = 0x08
Encodings.TIGHT_JPEG = 0x09
Encodings.TIGHT_NO_ZLIB = 0x0A

-- Hot-path notes: every decoder works on `const uint8_t*` input (`reader:ptr(n)`) and writes
-- whole rows through the plane's data pointer. No per-pixel strings, closures, tables or
-- function calls through module tables, which is what keeps LuaJIT's traces tight.

local u8p = ffi.typeof("uint8_t*")
local const_u8p = ffi.typeof("const uint8_t*")

-- Growable scratch buffers (never shrunk), by name.
local scratch_bufs = {}
local function scratch(name, ctype, n)
    local b = scratch_bufs[name]
    if not b or b.n < n then
        b = { n = n, p = ffi.new(ctype .. "[?]", n) }
        scratch_bufs[name] = b
    end
    return b.p
end

local DEFAULT_FMT = PxFmt.for_depth(24)

--[[--
Per-format pixel conversion parameters, cached on the format table.

`rgb` is the 32 bpp format whose PIXEL `[R, G, B, X]` and CPIXEL `[R, G, B]` both start with
the three channel bytes; otherwise a wire value is looked up through per-channel tables.
]]
local function conv(fmt)
    local cv = fmt._conv
    if cv then return cv end
    cv = {
        rgb = fmt.bits_per_pixel == 32 and fmt.big_endian == 0 and fmt.red_shift == 0
            and fmt.green_shift == 8 and fmt.blue_shift == 16 and fmt.red_max == 255
            and fmt.green_max == 255 and fmt.blue_max == 255,
        bytes = fmt.bytes, cbytes = fmt.cbytes,
        big = fmt.big_endian ~= 0,
        rl = PxFmt.channel_lut(fmt.red_max), gl = PxFmt.channel_lut(fmt.green_max),
        bl = PxFmt.channel_lut(fmt.blue_max),
        rm = fmt.red_max, gm = fmt.green_max, bm = fmt.blue_max,
        rs = fmt.red_shift, gs = fmt.green_shift, bs = fmt.blue_shift,
        -- 8/16 bpp: one table maps a whole wire value to its RGB24 (3 bytes per value)
        plut = (fmt.bytes or 4) <= 2 and PxFmt.pixel_lut(fmt, fmt.bytes) or nil,
    }
    fmt._conv = cv
    return cv
end

--- The r, g, b of the `size`-byte wire pixel at `p`.
local function wire_rgb(cv, p, size)
    if cv.rgb then return p[0], p[1], p[2] end
    local v
    if size <= 2 and cv.plut then
        local q
        if size == 1 then
            q = p[0] * 3
        elseif cv.big then
            q = (p[0] * 256 + p[1]) * 3
        else
            q = (p[1] * 256 + p[0]) * 3
        end
        local lut = cv.plut
        return lut[q], lut[q + 1], lut[q + 2]
    elseif size == 1 then
        v = p[0]
    elseif size == 2 then
        if cv.big then v = bor(lshift(p[0], 8), p[1]) else v = bor(lshift(p[1], 8), p[0]) end
    else
        v = 0
        for k = 0, size - 1 do
            v = bor(v, lshift(p[cv.big and k or (size - 1 - k)], 8 * (size - 1 - k)))
        end
    end
    return cv.rl[band(rshift(v, cv.rs), cv.rm)], cv.gl[band(rshift(v, cv.gs), cv.gm)],
        cv.bl[band(rshift(v, cv.bs), cv.bm)]
end

--- Reads one PIXEL, returning r, g, b.
local function read_pixel(r, cv)
    return wire_rgb(cv, r:ptr(cv.bytes), cv.bytes)
end

--- Reads one CPIXEL/TPIXEL, returning r, g, b.
local function read_cpixel(r, cv)
    return wire_rgb(cv, r:ptr(cv.cbytes), cv.cbytes)
end

--- Base pointer and stride of a viewport (rect-local pixel (x, y) is at base + y * stride + x * 3).
local function vp_base(vp)
    return ffi.cast(u8p, vp.data), vp.stride
end

--[[--
Converts `count` wire pixels of `size` bytes at `src` to packed RGB24 at `dst`.
]]
local function to_rgb(cv, fmt, src, count, dst, size)
    if cv.rgb then
        if size == 3 then
            ffi.copy(dst, src, count * 3)
        else
            for i = 0, count - 1 do
                local s, d = i * 4, i * 3
                dst[d], dst[d + 1], dst[d + 2] = src[s], src[s + 1], src[s + 2]
            end
        end
    else
        PxFmt.to_rgb24(fmt, src, count, dst, size)
    end
end

--- Writes the `h` rows of `w` wire pixels of `size` bytes at `src` into the viewport rect at (x, y).
local function write_rows(cv, fmt, vp, x, y, w, h, src, size)
    local base, stride = vp_base(vp)
    for row = 0, h - 1 do
        to_rgb(cv, fmt, src + row * w * size, w, base + (y + row) * stride + x * 3, size)
    end
end

--- Clamps a subrect to the rect it lives in; returns nil when it is entirely outside.
local function clamp_sub(w, h, x, y, sw, sh)
    if x < 0 or y < 0 or sw <= 0 or sh <= 0 then return nil end
    if x >= w or y >= h then return nil end
    return x, y, math.min(sw, w - x), math.min(sh, h - y)
end

function Encodings.decode_raw(ctx)
    local r, vp, w, h, fmt = ctx.r, ctx.vp, ctx.w, ctx.h, ctx.fmt
    local cv = conv(fmt)
    local nb = cv.bytes
    -- one row per read: a whole rect may be megabytes
    for row = 0, h - 1 do
        write_rows(cv, fmt, vp, 0, row, w, 1, r:ptr(w * nb), nb)
    end
    return true
end

function Encodings.decode_copyrect(ctx)
    local r = ctx.r
    local src_x, src_y = r:u16(), r:u16()
    local x, y, w, h = ctx.x, ctx.y, ctx.w, ctx.h
    if src_x + w > ctx.plane.w or src_y + h > ctx.plane.h then
        return nil, string.format("CopyRect source (%d,%d,%d,%d) outside %dx%d framebuffer",
            src_x, src_y, w, h, ctx.plane.w, ctx.plane.h)
    end
    -- RFC 6143: the source is the state *before* this rectangle. Rows are copied with memmove in
    -- an order that never reads a row already overwritten (bottom-up when moving down), so
    -- overlapping copies need no temporary buffer.
    local base, stride = vp_base(ctx.plane)
    local n = w * 3
    local y0, y1, dir = 0, h - 1, 1
    if src_y < y then y0, y1, dir = h - 1, 0, -1 end
    for row = y0, y1, dir do
        ffi.C.memmove(base + (y + row) * stride + x * 3, base + (src_y + row) * stride + src_x * 3, n)
    end
    return true
end

function Encodings.decode_rre(ctx)
    local r, vp, w, h = ctx.r, ctx.vp, ctx.w, ctx.h
    local cv = conv(ctx.fmt)
    local n = r:u32()
    local br, bg, bb = read_pixel(r, cv)
    PxFmt.fill_rect(vp, 0, 0, w, h, br, bg, bb)
    for _ = 1, n do
        local pr, pg, pb = read_pixel(r, cv)
        local sx, sy, sw, sh = r:u16(), r:u16(), r:u16(), r:u16()
        local cx, cy, cw, ch = clamp_sub(w, h, sx, sy, sw, sh)
        if cx then
            PxFmt.fill_rect(vp, cx, cy, cw, ch, pr, pg, pb)
        end
    end
    return true
end

function Encodings.decode_hextile(ctx)
    local r, vp, w, h, fmt = ctx.r, ctx.vp, ctx.w, ctx.h, ctx.fmt
    local cv = conv(fmt)
    local nb = cv.bytes
    local bg_r, bg_g, bg_b, bg_valid
    local fg_r, fg_g, fg_b, fg_valid
    for ty = 0, h - 1, 16 do
        local th = math.min(16, h - ty)
        for tx = 0, w - 1, 16 do
            local tw = math.min(16, w - tx)
            local mask = r:u8()
            if band(mask, 1) ~= 0 then -- Raw
                write_rows(cv, fmt, vp, tx, ty, tw, th, r:ptr(tw * th * nb), nb)
                -- Neither colour may be carried over a raw tile.
                bg_valid, fg_valid = false, false
            else
                if band(mask, 2) ~= 0 then -- BackgroundSpecified
                    bg_r, bg_g, bg_b = read_pixel(r, cv)
                    bg_valid = true
                elseif not bg_valid then
                    return nil, string.format("Hextile: background not specified at tile (%d,%d)", tx, ty)
                end
                if band(mask, 4) ~= 0 then -- ForegroundSpecified
                    if band(mask, 16) ~= 0 then
                        return nil, string.format("Hextile: ForegroundSpecified with SubrectsColoured at tile (%d,%d)", tx, ty)
                    end
                    fg_r, fg_g, fg_b = read_pixel(r, cv)
                    fg_valid = true
                end
                PxFmt.fill_rect(vp, tx, ty, tw, th, bg_r, bg_g, bg_b)
                if band(mask, 8) ~= 0 then -- AnySubrects
                    local count = r:u8()
                    local coloured = band(mask, 16) ~= 0
                    for _ = 1, count do
                        local sr, sg, sb
                        if coloured then
                            sr, sg, sb = read_pixel(r, cv)
                        else
                            if not fg_valid then
                                return nil, string.format("Hextile: subrect without foreground at tile (%d,%d)", tx, ty)
                            end
                            sr, sg, sb = fg_r, fg_g, fg_b
                        end
                        local xy, wh = r:u8(), r:u8()
                        local sx, sy = rshift(xy, 4), band(xy, 0xF)
                        local sw, sh = rshift(wh, 4) + 1, band(wh, 0xF) + 1
                        local cx, cy, cw, ch = clamp_sub(tw, th, sx, sy, sw, sh)
                        if cx then
                            PxFmt.fill_rect(vp, tx + cx, ty + cy, cw, ch, sr, sg, sb)
                        end
                    end
                    if coloured then fg_valid = false end
                end
            end
        end
    end
    return true
end

--- Reads a TRLE/Tight run length (one or more bytes, `1 + sum`, 255 means "keep adding").
local function read_run_length(r)
    local total = 0
    while true do
        local b = r:u8()
        if b == 255 then
            total = total + 255
        else
            return total + b + 1
        end
    end
end

--[[--
Writes `n` (>= 1) copies of the RGB24 pixel `r, g, b` at byte offset `o` of `buf`.

A run is one store for a single pixel, one memset when it is grey (most of what an e-reader is
shown), and otherwise the first pixels stored one by one, then copied over in doubling blocks.
]]
local function fill_px(buf, o, n, r, g, b)
    if n == 1 then
        buf[o], buf[o + 1], buf[o + 2] = r, g, b
    elseif r == g and g == b then
        ffi.fill(buf + o, n * 3, r)
    elseif n <= 8 then
        for k = o, o + (n - 1) * 3, 3 do
            buf[k], buf[k + 1], buf[k + 2] = r, g, b
        end
    else
        for k = o, o + 21, 3 do
            buf[k], buf[k + 1], buf[k + 2] = r, g, b
        end
        local have, total = 24, n * 3
        while have < total do
            local c = total - have
            if c > have then c = have end
            ffi.copy(buf + o + have, buf + o, c)
            have = have + c
        end
    end
end
Encodings._fill_px = fill_px

-- A ZRLE tile is at most 64 x 64 pixels; TRLE's are 16 x 16.
local MAX_TILE = 64

--[[--
Decodes one TRLE-style tile at `(dx, dy)` into `vp`.

The tile is built in a packed RGB24 tile buffer, then copied into the plane row by row, so runs
and palette pixels are plain sequential byte stores. `state.pal` (`uint8_t[128 * 3]`) carries
the previous tile's palette (subencodings 127/129).
]]
local function decode_tile(state, cv, fmt, vp, r, dx, dy, tw, th)
    local cb = cv.cbytes
    local sub = r:u8()
    if sub == 0 then -- raw CPIXELs
        write_rows(cv, fmt, vp, dx, dy, tw, th, r:ptr(tw * th * cb), cb)
        return true
    elseif sub == 1 then -- solid
        local cr, cg, cbl = read_cpixel(r, cv)
        PxFmt.fill_rect(vp, dx, dy, tw, th, cr, cg, cbl)
        return true
    end

    local palette_size
    local rle, read_palette
    if sub >= 2 and sub <= 16 then
        palette_size = sub
        read_palette = true
    elseif sub == 127 then -- packed palette, reused
        palette_size = state.palette_size
        if not palette_size then return nil, "TRLE: palette reuse (127) without a previous palette" end
    elseif sub == 128 then -- plain RLE
        rle = true
    elseif sub == 129 then -- palette RLE, reused
        palette_size = state.palette_size
        if not palette_size then return nil, "TRLE: palette reuse (129) without a previous palette" end
        rle = true
    elseif sub >= 130 then
        palette_size = sub - 128
        read_palette = true
        rle = true
    else
        return nil, string.format("unsupported TRLE subencoding %d", sub)
    end

    if palette_size and palette_size < 2 then
        return nil, string.format("unsupported TRLE subencoding %d", sub)
    end

    local pal = state.pal
    if not pal then
        pal = ffi.new("uint8_t[?]", 128 * 3)
        state.pal = pal
    end
    if read_palette then
        local p = r:ptr(palette_size * cb)
        for i = 0, palette_size - 1 do
            pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2] = wire_rgb(cv, p + i * cb, cb)
        end
        state.palette_size = palette_size
    end

    -- per connection: a paused decode (a detached session) must not share it with another one
    local tb = state.tile
    if not tb then
        tb = ffi.new("uint8_t[?]", MAX_TILE * MAX_TILE * 3)
        state.tile = tb
    end
    local npix = tw * th
    if not rle then
        -- packed palette: rows of 1/2/4-bit indices, each row padded to a byte
        local bpp = palette_size == 2 and 1 or (palette_size <= 4 and 2 or 4)
        local row_bytes = rshift(tw * bpp + 7, 3)
        local mask = lshift(1, bpp) - 1
        local p = r:ptr(row_bytes * th)
        local o = 0
        for row = 0, th - 1 do
            local rp = p + row * row_bytes
            for col = 0, tw - 1 do
                local bitpos = col * bpp
                local v = band(rshift(rp[rshift(bitpos, 3)], 8 - bpp - band(bitpos, 7)), mask)
                if v >= palette_size then
                    return nil, string.format("TRLE: palette index %d out of range (%d entries) at tile (%d,%d) col %d",
                        v, palette_size, dx, dy, col)
                end
                local q = v * 3
                tb[o], tb[o + 1], tb[o + 2] = pal[q], pal[q + 1], pal[q + 2]
                o = o + 3
            end
        end
    elseif r.p then
        -- run-length encoded, straight off a memory reader (ZRLE's inflated stream): the bytes
        -- are read through a local pointer and position, with the reader's own bounds checks
        -- (and errors, via r:u8() at the end of the data) at every byte
        local rp, pos, plen = r.p, r.pos, r.len
        local plain = sub == 128
        local done = 0
        while done < npix do
            local cr, cg, cbl
            if plain then
                if pos + cb > plen then r.pos = pos; r:ptr(cb) end
                cr, cg, cbl = wire_rgb(cv, rp + pos, cb)
                pos = pos + cb
            end
            if pos >= plen then r.pos = pos; r:u8() end
            local b = rp[pos]
            pos = pos + 1
            local length = 1
            if not plain then
                if b >= 128 then
                    b = b - 128
                else
                    length = 0
                end
                if b >= palette_size then
                    r.pos = pos
                    return nil, string.format("TRLE: palette index %d out of range (%d entries) at tile (%d,%d)",
                        b, palette_size, dx, dy)
                end
                local q = b * 3
                cr, cg, cbl = pal[q], pal[q + 1], pal[q + 2]
                if length == 0 then
                    length = 1
                else
                    if pos >= plen then r.pos = pos; r:u8() end
                    b = rp[pos]
                    pos = pos + 1
                    length = 1 + b
                end
            else
                length = 1 + b
            end
            while b == 255 and length > 1 do
                if pos >= plen then r.pos = pos; r:u8() end
                b = rp[pos]
                pos = pos + 1
                length = length + b
            end
            if done + length > npix then
                r.pos = pos
                return nil, string.format("TRLE: run of %d overflows tile (%d/%d pixels) at tile (%d,%d)",
                    length, done, npix, dx, dy)
            end
            fill_px(tb, done * 3, length, cr, cg, cbl)
            done = done + length
        end
        r.pos = pos
    else
        -- run-length encoded (plain RLE or palette RLE), runs may span rows
        local done = 0
        while done < npix do
            local cr, cg, cbl, length
            if sub == 128 then
                cr, cg, cbl = read_cpixel(r, cv)
                length = read_run_length(r)
            else
                local idx = r:u8()
                if idx >= 128 then
                    idx = idx - 128
                    length = read_run_length(r)
                else
                    length = 1
                end
                if idx >= palette_size then
                    return nil, string.format("TRLE: palette index %d out of range (%d entries) at tile (%d,%d)",
                        idx, palette_size, dx, dy)
                end
                local q = idx * 3
                cr, cg, cbl = pal[q], pal[q + 1], pal[q + 2]
            end
            if done + length > npix then
                return nil, string.format("TRLE: run of %d overflows tile (%d/%d pixels) at tile (%d,%d)",
                    length, done, npix, dx, dy)
            end
            fill_px(tb, done * 3, length, cr, cg, cbl)
            done = done + length
        end
    end
    local base, stride = vp_base(vp)
    local n = tw * 3
    for row = 0, th - 1 do
        ffi.copy(base + (dy + row) * stride + dx * 3, tb + row * n, n)
    end
    return true
end

local function decode_tiles(state, fmt, vp, r, w, h, tile_size)
    local cv = conv(fmt)
    for ty = 0, h - 1, tile_size do
        local th = math.min(tile_size, h - ty)
        for tx = 0, w - 1, tile_size do
            local tw = math.min(tile_size, w - tx)
            local ok, err = decode_tile(state, cv, fmt, vp, r, tx, ty, tw, th)
            if not ok then return nil, err end
        end
    end
    return true
end

function Encodings.decode_trle(ctx)
    local state = ctx.streams.trle
    if not state then
        state = {}
        ctx.streams.trle = state
    end
    return decode_tiles(state, ctx.fmt, ctx.vp, ctx.r, ctx.w, ctx.h, 16)
end

--- The most inflated bytes a w x h ZRLE rect can legitimately take (worst case: plain RLE with
--- a one-pixel run per pixel, plus a full palette and the subencoding byte per tile).
local function zrle_limit(w, h, cb)
    local tiles = math.ceil(w / 64) * math.ceil(h / 64)
    return w * h * (cb + 1) + tiles * (1 + 127 * cb)
end

function Encodings.decode_zrle(ctx)
    local r = ctx.r
    local length = r:u32()
    -- The length is the server's to choose and is read whole before inflating: no more than the
    -- rectangle's largest tile stream (zrle_limit) can need, stored uncompressed - zlib's stored
    -- blocks cost 5 bytes per 64 KiB, a sync flush a few bytes more - so anything above that is a
    -- broken or hostile server, and the rect fails before a byte of it is read.
    local limit = zrle_limit(ctx.w, ctx.h, ctx.fmt.cbytes)
    local max_length = limit + math.floor(limit / 1024) + 1024
    if length > max_length then
        return nil, string.format("ZRLE: %d compressed bytes for a %dx%d rect (at most %d)",
            length, ctx.w, ctx.h, max_length)
    end
    local stream = ctx.streams.zrle
    if not stream then
        stream = ZStream.new()
        ctx.streams.zrle = stream
    end
    -- r:ptr, not r:bytes: zlib reads the payload where the transport holds it (no string copy).
    -- The pointer is only valid until the reader's next read and the session may move its buffer
    -- between pump steps; inflate_ptr uses it up in this call (no read, no yield in between) and
    -- the tiles are then decoded from the stream's own output buffer.
    local p, n = stream:inflate_ptr(r:ptr(length), length, limit)
    if not p then
        return nil, string.format("ZRLE: %s while inflating %d bytes at rect (%d,%d,%d,%d)",
            n, length, ctx.x, ctx.y, ctx.w, ctx.h)
    end
    local state = ctx.streams.zrle_tiles
    if not state then
        state = {}
        ctx.streams.zrle_tiles = state
    end
    return decode_tiles(state, ctx.fmt, ctx.vp, Util.ptr_reader(p, n, stream), ctx.w, ctx.h, 64)
end

--- Tight's 1..3 byte little-endian compact length.
local function read_compact_len(r)
    local b = r:u8()
    local len = band(b, 0x7F)
    if band(b, 0x80) ~= 0 then
        b = r:u8()
        len = len + lshift(band(b, 0x7F), 7)
        if band(b, 0x80) ~= 0 then
            b = r:u8()
            len = len + lshift(b, 14)
        end
    end
    return len
end

local function tight_stream(ctx, id)
    local streams = ctx.streams.tight
    if not streams then
        streams = {}
        ctx.streams.tight = streams
    end
    if not streams[id] then
        streams[id] = ZStream.new()
    end
    return streams[id]
end

--- Applies the Tight copy filter: packed TPIXEL rows.
local function tight_copy(cv, fmt, vp, data, len, w, h)
    local cb = cv.cbytes
    if len < w * h * cb then
        return nil, string.format("Tight: copy filter got %d bytes, need %d", len, w * h * cb)
    end
    write_rows(cv, fmt, vp, 0, 0, w, h, data, cb)
    return true
end

--- Applies the Tight palette filter (`pal` is packed RGB24, `num_colors` entries).
local function tight_palette(vp, data, len, w, h, pal, num_colors)
    local base, stride = vp_base(vp)
    if num_colors == 2 then
        local row_bytes = rshift(w + 7, 3)
        if len < row_bytes * h then
            return nil, string.format("Tight: palette(2) got %d bytes, need %d", len, row_bytes * h)
        end
        local r0, g0, b0, r1, g1, b1 = pal[0], pal[1], pal[2], pal[3], pal[4], pal[5]
        for row = 0, h - 1 do
            local src = data + row * row_bytes
            local out = base + row * stride
            for col = 0, w - 1 do
                local o = col * 3
                if band(rshift(src[rshift(col, 3)], 7 - band(col, 7)), 1) ~= 0 then
                    out[o], out[o + 1], out[o + 2] = r1, g1, b1
                else
                    out[o], out[o + 1], out[o + 2] = r0, g0, b0
                end
            end
        end
    else
        if len < w * h then
            return nil, string.format("Tight: palette(%d) got %d bytes, need %d", num_colors, len, w * h)
        end
        for row = 0, h - 1 do
            local src = data + row * w
            local out = base + row * stride
            for col = 0, w - 1 do
                local idx = src[col]
                if idx >= num_colors then
                    return nil, string.format("Tight: palette index %d out of range (%d entries)", idx, num_colors)
                end
                local q, o = idx * 3, col * 3
                out[o], out[o + 1], out[o + 2] = pal[q], pal[q + 1], pal[q + 2]
            end
        end
    end
    return true
end

--[[--
Applies the Tight gradient filter at 8/16 bpp (libvncclient's `FilterGradientBPP` without
cutZeros): the prediction runs on the quantized channel values, one residual PIXEL per pixel.
]]
local function tight_gradient_bpp(cv, fmt, vp, src, len, w, h)
    local nb = cv.bytes
    if len < w * h * nb then
        return nil, string.format("Tight: gradient got %d bytes, need %d", len, w * h * nb)
    end
    local rm, gm, bm = cv.rm, cv.gm, cv.bm
    local rs, gs, bs = cv.rs, cv.gs, cv.bs
    local rl, gl, bl = cv.rl, cv.gl, cv.bl
    -- quantized channel values of the row above (prev) and of this row (cur), 3 per pixel
    local prev = scratch("grad_prev", "int32_t", w * 3)
    local cur = scratch("grad_cur", "int32_t", w * 3)
    ffi.fill(prev, w * 3 * 4, 0)
    local big = cv.big
    local base, stride = vp_base(vp)
    for row = 0, h - 1 do
        local out = base + row * stride
        local sp = src + row * w * nb
        -- left and upper-left neighbours; the first column predicts from the pixel above
        local lr, lg, lb, ulr, ulg, ulb = prev[0], prev[1], prev[2], 0, 0, 0
        for col = 0, w - 1 do
            local v
            if nb == 2 then
                local s = sp + col * 2
                if big then v = bor(lshift(s[0], 8), s[1]) else v = bor(lshift(s[1], 8), s[0]) end
            else
                v = sp[col]
            end
            local o = col * 3
            local ur, ug, ub = prev[o], prev[o + 1], prev[o + 2]
            local er, eg, eb = ur, ug, ub
            if col > 0 then
                er, eg, eb = ur + lr - ulr, ug + lg - ulg, ub + lb - ulb
                if er > rm then er = rm elseif er < 0 then er = 0 end
                if eg > gm then eg = gm elseif eg < 0 then eg = 0 end
                if eb > bm then eb = bm elseif eb < 0 then eb = 0 end
            end
            local pr = band(rshift(v, rs) + er, rm)
            local pg = band(rshift(v, gs) + eg, gm)
            local pb = band(rshift(v, bs) + eb, bm)
            cur[o], cur[o + 1], cur[o + 2] = pr, pg, pb
            out[o], out[o + 1], out[o + 2] = rl[pr], gl[pg], bl[pb]
            lr, lg, lb, ulr, ulg, ulb = pr, pg, pb, ur, ug, ub
        end
        prev, cur = cur, prev
    end
    return true
end

--- Applies the Tight gradient filter (24-bit "cutZeros" variant), straight into the plane.
local function tight_gradient(vp, data, len, w, h)
    if len < w * h * 3 then
        return nil, string.format("Tight: gradient got %d bytes, need %d", len, w * h * 3)
    end
    local base, stride = vp_base(vp)
    local n = w * 3
    for row = 0, h - 1 do
        local d = data + row * n
        local cur = base + row * stride
        -- the row above as already decoded (all zero above the first row)
        local prev = row > 0 and cur - stride or nil
        for c = 0, 2 do
            cur[c] = band((prev and prev[c] or 0) + d[c], 255)
        end
        if prev then
            for o = 3, n - 1 do
                local est = prev[o] + cur[o - 3] - prev[o - 3]
                if est > 255 then est = 255 elseif est < 0 then est = 0 end
                cur[o] = band(est + d[o], 255)
            end
        else
            for o = 3, n - 1 do
                cur[o] = band(cur[o - 3] + d[o], 255)
            end
        end
    end
    return true
end

-- TurboJPEG decompressor, loaded on first use; false once it proved unavailable.
local tj

local function load_tj()
    if tj ~= nil then return tj end
    tj = false
    local ok, lib = pcall(function()
        require("ffi/turbojpeg_h")
        return ffi.loadlib("turbojpeg", "0.5.0", "turbojpeg", "0.4.0", "turbojpeg", "0.3.0", "turbojpeg")
    end)
    if ok and lib then
        local init = pcall(function() return lib.tj3Init ~= nil end) and lib.tj3Init
            or function(t) return lib.tj3InitVersion(t, lib.TURBOJPEG_VERSION_NUMBER) end
        tj = { lib = lib, init = init }
    end
    return tj
end

--[[--
Decodes a Tight JPEG rect straight into the plane (TurboJPEG writes RGB rows at the plane's
stride), with one decompressor handle per connection.
]]
local function tight_jpeg(ctx, src, len)
    local t = load_tj()
    if not t then
        return nil, "Tight: JPEG payload but TurboJPEG is unavailable"
    end
    local lib = t.lib
    local handle = ctx.streams.tj
    if not handle then
        handle = t.init(lib.TJINIT_DECOMPRESS)
        if handle == nil then return nil, "Tight: no TurboJPEG decompressor" end
        ctx.streams.tj = handle
    end
    if lib.tj3DecompressHeader(handle, src, len) < 0 then
        return nil, "Tight: unreadable JPEG header"
    end
    local w = lib.tj3Get(handle, lib.TJPARAM_JPEGWIDTH)
    local h = lib.tj3Get(handle, lib.TJPARAM_JPEGHEIGHT)
    if w ~= ctx.w or h ~= ctx.h then
        return nil, string.format("Tight: JPEG is %dx%d, rect is %dx%d", w, h, ctx.w, ctx.h)
    end
    local base, stride = vp_base(ctx.vp)
    if lib.tj3Decompress8(handle, src, len, base, stride, lib.TJPF_RGB) < 0 then
        return nil, "Tight: JPEG decoding failed"
    end
    return true
end

function Encodings.decode_tight(ctx)
    local r, vp, w, h, fmt = ctx.r, ctx.vp, ctx.w, ctx.h, ctx.fmt
    local cv = conv(fmt)
    local ctl = r:u8()

    -- Low nibble: per-stream zlib reset flags.
    for i = 0, 3 do
        if band(ctl, lshift(1, i)) ~= 0 then
            local s = ctx.streams.tight and ctx.streams.tight[i]
            if s then s:reset() end
        end
    end
    ctl = rshift(ctl, 4)

    -- The "no zlib" bits (0x0A) can be combined with an explicit filter (0x04, and a stream id
    -- in the low bits, ignored): libvncserver sends 0x0E for mono and indexed rects when the
    -- compression level is 0 (libvncclient strips them the same way).
    local uncompressed = false
    if band(ctl, Encodings.TIGHT_NO_ZLIB) == Encodings.TIGHT_NO_ZLIB then
        uncompressed = true
        ctl = band(ctl, bit.bnot(Encodings.TIGHT_NO_ZLIB))
    end

    if ctl == Encodings.TIGHT_FILL then
        local cr, cg, cbl = read_cpixel(r, cv)
        PxFmt.fill_rect(vp, 0, 0, w, h, cr, cg, cbl)
        return true
    elseif ctl == Encodings.TIGHT_JPEG then
        local len = read_compact_len(r)
        -- TurboJPEG takes pointer + length: the payload is decoded where the transport holds it
        -- (used up in this call, like the zlib input below)
        return tight_jpeg(ctx, r:ptr(len), len)
    elseif ctl > Encodings.TIGHT_JPEG then
        return nil, string.format("unsupported Tight subencoding 0x%02X",
            uncompressed and bor(ctl, Encodings.TIGHT_NO_ZLIB) or ctl)
    end

    local stream_id = band(ctl, 0x03)
    local filter = 0
    if band(ctl, 0x04) ~= 0 then
        filter = r:u8()
    end

    local cb = cv.cbytes
    local pal, num_colors, bits
    if filter == 0 then
        bits = cb * 8
    elseif filter == 1 then
        num_colors = r:u8() + 1
        if num_colors < 2 then
            return nil, "Tight: palette with fewer than 2 colours"
        end
        -- per connection, like the tile buffer: the payload read below may pause the decode
        pal = ctx.streams.tight_pal
        if not pal then
            pal = ffi.new("uint8_t[?]", 256 * 3)
            ctx.streams.tight_pal = pal
        end
        local p = r:ptr(num_colors * cb)
        for i = 0, num_colors - 1 do
            pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2] = wire_rgb(cv, p + i * cb, cb)
        end
        bits = num_colors == 2 and 1 or 8
    elseif filter == 2 then
        if w > Encodings.TIGHT_GRADIENT_MAX_WIDTH then
            return nil, string.format("Tight: gradient rect width %d exceeds %d",
                w, Encodings.TIGHT_GRADIENT_MAX_WIDTH)
        end
        bits = cb * 8
    else
        return nil, string.format("unsupported Tight filter %d", filter)
    end

    local row_size = rshift(w * bits + 7, 3)
    local raw_size = row_size * h
    local data, len
    if raw_size < Encodings.TIGHT_MIN_TO_COMPRESS then
        data, len = r:ptr(raw_size), raw_size
    else
        local clen = read_compact_len(r)
        if uncompressed then
            data, len = r:ptr(clen), clen
        else
            -- straight from the transport, used up within this call (see decode_zrle)
            local p, n = tight_stream(ctx, stream_id):inflate_ptr(r:ptr(clen), clen, raw_size)
            if not p then
                return nil, string.format("Tight: %s while inflating %d bytes at rect (%d,%d,%d,%d)",
                    n, clen, ctx.x, ctx.y, ctx.w, ctx.h)
            end
            data, len = p, n
        end
    end
    data = ffi.cast(const_u8p, data)

    if filter == 0 then
        return tight_copy(cv, fmt, vp, data, len, w, h)
    elseif filter == 1 then
        return tight_palette(vp, data, len, w, h, pal, num_colors)
    elseif fmt.bits_per_pixel ~= 32 then
        return tight_gradient_bpp(cv, fmt, vp, data, len, w, h)
    end
    return tight_gradient(vp, data, len, w, h)
end

--- Dispatches on `ctx.encoding`.
--- @treturn boolean|nil, string|nil
function Encodings.decode(ctx)
    ctx.fmt = ctx.fmt or DEFAULT_FMT
    local enc = ctx.encoding
    if enc == Encodings.RAW then
        return Encodings.decode_raw(ctx)
    elseif enc == Encodings.COPYRECT then
        return Encodings.decode_copyrect(ctx)
    elseif enc == Encodings.RRE then
        return Encodings.decode_rre(ctx)
    elseif enc == Encodings.HEXTILE then
        return Encodings.decode_hextile(ctx)
    elseif enc == Encodings.TRLE then
        return Encodings.decode_trle(ctx)
    elseif enc == Encodings.ZRLE then
        return Encodings.decode_zrle(ctx)
    elseif enc == Encodings.TIGHT then
        return Encodings.decode_tight(ctx)
    end
    return nil, string.format("unsupported encoding %d", enc)
end

--- Creates the persistent per-connection decoder state (`ctx.streams`).
function Encodings.new_streams()
    return {}
end

--- Frees the persistent decoder state (zlib streams).
function Encodings.free_streams(streams)
    if not streams then return end
    if streams.zrle then
        streams.zrle:free()
        streams.zrle = nil
    end
    if streams.tight then
        for _, s in pairs(streams.tight) do
            s:free()
        end
        streams.tight = nil
    end
    if streams.tj then
        load_tj().lib.tj3Destroy(streams.tj)
        streams.tj = nil
    end
end

return Encodings
