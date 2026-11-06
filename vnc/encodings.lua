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

-- Growable scratch row used to convert 4-byte wire pixels into packed RGB24.
local scratch, scratch_len = nil, 0
local function ensure_scratch(n)
    if scratch_len < n then
        scratch = ffi.new("uint8_t[?]", n)
        scratch_len = n
    end
    return scratch
end

local DEFAULT_FMT = PxFmt.for_depth(24)

--- Reads one PIXEL, returning r, g, b.
local function read_pixel(r, fmt)
    if fmt.bits_per_pixel == 32 then
        local s = r:bytes(4)
        return s:byte(1), s:byte(2), s:byte(3)
    end
    return PxFmt.unpack(fmt, r:bytes(fmt.bytes), 0, fmt.bytes)
end

--- Reads one CPIXEL/TPIXEL, returning r, g, b.
local function read_cpixel(r, fmt)
    local s = r:bytes(fmt.cbytes)
    if fmt.bits_per_pixel == 32 then
        return s:byte(1), s:byte(2), s:byte(3)
    end
    return PxFmt.unpack(fmt, s, 0, fmt.cbytes)
end

--[[--
Writes `count` wire PIXELs (`[R, G, B, X]` at 32 bpp) as packed RGB24 into `vp` at `(x, y)`.
]]
local function write_row(fmt, vp, x, y, data, count)
    local buf = ensure_scratch(count * 3)
    local src = ffi.cast("const uint8_t*", data)
    if fmt.bits_per_pixel ~= 32 then
        PxFmt.to_rgb24(fmt, src, count, buf, fmt.bytes)
    else
        for i = 0, count - 1 do
            buf[i * 3] = src[i * 4]
            buf[i * 3 + 1] = src[i * 4 + 1]
            buf[i * 3 + 2] = src[i * 4 + 2]
        end
    end
    PxFmt.write_pixel_buffer(vp, x, y, buf, count)
end

--[[--
Writes `count` packed CPIXELs/TPIXELs (`[R, G, B]` at 32 bpp) from pointer `src` into `vp` at
`(x, y)`.
]]
local function write_crow(fmt, vp, x, y, src, count)
    if fmt.bits_per_pixel == 32 then
        PxFmt.write_pixel_buffer(vp, x, y, src, count)
        return
    end
    local buf = ensure_scratch(count * 3)
    PxFmt.to_rgb24(fmt, src, count, buf, fmt.cbytes)
    PxFmt.write_pixel_buffer(vp, x, y, buf, count)
end

--- Clamps a subrect to the rect it lives in; returns nil when it is entirely outside.
local function clamp_sub(w, h, x, y, sw, sh)
    if x < 0 or y < 0 or sw <= 0 or sh <= 0 then return nil end
    if x >= w or y >= h then return nil end
    return x, y, math.min(sw, w - x), math.min(sh, h - y)
end

function Encodings.decode_raw(ctx)
    local r, vp, w, h, fmt = ctx.r, ctx.vp, ctx.w, ctx.h, ctx.fmt
    for row = 0, h - 1 do
        write_row(fmt, vp, 0, row, r:bytes(w * fmt.bytes), w)
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
    -- RFC 6143: the source is the state *before* this rectangle. BlitBuffer's blitter is a
    -- naive forward copy and corrupts overlapping self-blits (verified: shifting right by 8
    -- reproduces the already-overwritten pixels), so stage through a temporary plane.
    local overlapping = src_x < x + w and x < src_x + w and src_y < y + h and y < src_y + h
    if overlapping then
        local tmp = BB.new(w, h, BB.TYPE_BBRGB24)
        tmp:blitFrom(ctx.plane, 0, 0, src_x, src_y, w, h)
        ctx.plane:blitFrom(tmp, x, y, 0, 0, w, h)
        tmp:free()
    else
        ctx.plane:blitFrom(ctx.plane, x, y, src_x, src_y, w, h)
    end
    return true
end

function Encodings.decode_rre(ctx)
    local r, vp, w, h, fmt = ctx.r, ctx.vp, ctx.w, ctx.h, ctx.fmt
    local n = r:u32()
    local br, bg, bb = read_pixel(r, fmt)
    PxFmt.fill_rect(vp, 0, 0, w, h, br, bg, bb)
    for _ = 1, n do
        local pr, pg, pb = read_pixel(r, fmt)
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
    local bg_r, bg_g, bg_b, bg_valid
    local fg_r, fg_g, fg_b, fg_valid
    for ty = 0, h - 1, 16 do
        local th = math.min(16, h - ty)
        for tx = 0, w - 1, 16 do
            local tw = math.min(16, w - tx)
            local mask = r:u8()
            if band(mask, 1) ~= 0 then -- Raw
                for row = 0, th - 1 do
                    write_row(fmt, vp, tx, ty + row, r:bytes(tw * fmt.bytes), tw)
                end
                -- Neither colour may be carried over a raw tile.
                bg_valid, fg_valid = false, false
            else
                if band(mask, 2) ~= 0 then -- BackgroundSpecified
                    bg_r, bg_g, bg_b = read_pixel(r, fmt)
                    bg_valid = true
                elseif not bg_valid then
                    return nil, string.format("Hextile: background not specified at tile (%d,%d)", tx, ty)
                end
                if band(mask, 4) ~= 0 then -- ForegroundSpecified
                    if band(mask, 16) ~= 0 then
                        return nil, string.format("Hextile: ForegroundSpecified with SubrectsColoured at tile (%d,%d)", tx, ty)
                    end
                    fg_r, fg_g, fg_b = read_pixel(r, fmt)
                    fg_valid = true
                end
                PxFmt.fill_rect(vp, tx, ty, tw, th, bg_r, bg_g, bg_b)
                if band(mask, 8) ~= 0 then -- AnySubrects
                    local count = r:u8()
                    local coloured = band(mask, 16) ~= 0
                    for _ = 1, count do
                        local sr, sg, sb
                        if coloured then
                            sr, sg, sb = read_pixel(r, fmt)
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

-- Writes `count` copies of one colour starting at row-major tile index `start`,
-- spanning rows if needed.
local function write_tile_run(vp, dx, dy, tw, th, start, count, cr, cg, cb)
    local limit = tw * th
    if start + count > limit then
        count = limit - start
    end
    local idx = start
    while count > 0 do
        local col = idx % tw
        local n = math.min(count, tw - col)
        PxFmt.fill_rect(vp, dx + col, dy + math.floor(idx / tw), n, 1, cr, cg, cb)
        idx = idx + n
        count = count - n
    end
end

local function decode_packed_palette(vp, r, dx, dy, tw, th, pal, palette_size)
    local bpp = palette_size == 2 and 1 or (palette_size <= 4 and 2 or 4)
    local row_bytes = math.floor((tw * bpp + 7) / 8)
    local mask = lshift(1, bpp) - 1
    for row = 0, th - 1 do
        local data = r:bytes(row_bytes)
        for col = 0, tw - 1 do
            local bitpos = col * bpp
            local byte = data:byte(math.floor(bitpos / 8) + 1)
            local v = band(rshift(byte, 8 - bpp - (bitpos % 8)), mask)
            local px = pal[v + 1]
            if not px then
                return nil, string.format("TRLE: palette index %d out of range (%d entries) at tile (%d,%d) col %d",
                    v, palette_size, dx, dy, col)
            end
            PxFmt.write_pixel(vp, dx + col, dy + row, px.r, px.g, px.b)
        end
    end
    return true
end

--[[--
Decodes one TRLE-style tile at `(dx, dy)` into `vp`.

`state.palette` carries the previous tile's palette (subencodings 127/129).
]]
local function decode_tile(state, fmt, vp, r, dx, dy, tw, th)
    local sub = r:u8()
    if sub == 0 then -- raw CPIXELs
        for row = 0, th - 1 do
            local data = r:bytes(tw * fmt.cbytes)
            write_crow(fmt, vp, dx, dy + row, ffi.cast("const uint8_t*", data), tw)
        end
        return true
    elseif sub == 1 then -- solid
        local cr, cg, cb = read_cpixel(r, fmt)
        PxFmt.fill_rect(vp, dx, dy, tw, th, cr, cg, cb)
        return true
    end

    local pal, palette_size
    local rle, read_palette
    if sub >= 2 and sub <= 16 then
        palette_size = sub
        read_palette = true
    elseif sub == 127 then -- packed palette, reused
        pal, palette_size = state.palette, state.palette_size
        if not pal then return nil, "TRLE: palette reuse (127) without a previous palette" end
    elseif sub == 128 then -- plain RLE
        rle = true
    elseif sub == 129 then -- palette RLE, reused
        pal, palette_size = state.palette, state.palette_size
        if not pal then return nil, "TRLE: palette reuse (129) without a previous palette" end
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

    if read_palette then
        pal = {}
        for i = 1, palette_size do
            local pr, pg, pb = read_cpixel(r, fmt)
            pal[i] = { r = pr, g = pg, b = pb }
        end
        state.palette, state.palette_size = pal, palette_size
    end

    if not rle then
        return decode_packed_palette(vp, r, dx, dy, tw, th, pal, palette_size)
    end

    -- Run-length encoded (plain RLE or palette RLE).
    local npix = tw * th
    local done = 0
    while done < npix do
        local cr, cg, cb, length
        if sub == 128 then
            cr, cg, cb = read_cpixel(r, fmt)
            length = read_run_length(r)
        else
            local idx = r:u8()
            if idx >= 128 then
                idx = idx - 128
                length = read_run_length(r)
            else
                length = 1
            end
            local px = pal[idx + 1]
            if not px then
                return nil, string.format("TRLE: palette index %d out of range (%d entries) at tile (%d,%d)",
                    idx, palette_size, dx, dy)
            end
            cr, cg, cb = px.r, px.g, px.b
        end
        if length <= 0 or done + length > npix then
            return nil, string.format("TRLE: run of %d overflows tile (%d/%d pixels) at tile (%d,%d)",
                length, done, npix, dx, dy)
        end
        write_tile_run(vp, dx, dy, tw, th, done, length, cr, cg, cb)
        done = done + length
    end
    return true
end

local function decode_tiles(state, fmt, vp, r, w, h, tile_size)
    for ty = 0, h - 1, tile_size do
        local th = math.min(tile_size, h - ty)
        for tx = 0, w - 1, tile_size do
            local tw = math.min(tile_size, w - tx)
            local ok, err = decode_tile(state, fmt, vp, r, tx, ty, tw, th)
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

function Encodings.decode_zrle(ctx)
    local r = ctx.r
    local length = r:u32()
    local data = r:bytes(length)
    local stream = ctx.streams.zrle
    if not stream then
        stream = ZStream.new()
        ctx.streams.zrle = stream
    end
    local inflated, err = stream:inflate(data)
    if not inflated then
        return nil, string.format("ZRLE: %s while inflating %d bytes at rect (%d,%d,%d,%d)",
            err, length, ctx.x, ctx.y, ctx.w, ctx.h)
    end
    local state = ctx.streams.zrle_tiles
    if not state then
        state = {}
        ctx.streams.zrle_tiles = state
    end
    return decode_tiles(state, ctx.fmt, ctx.vp, Util.mem_reader(inflated), ctx.w, ctx.h, 64)
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
local function tight_copy(fmt, vp, data, w, h)
    local cb = fmt.cbytes
    if #data < w * h * cb then
        return nil, string.format("Tight: copy filter got %d bytes, need %d", #data, w * h * cb)
    end
    local ptr = ffi.cast("const uint8_t*", data)
    for row = 0, h - 1 do
        write_crow(fmt, vp, 0, row, ptr + row * w * cb, w)
    end
    return true
end

--- Applies the Tight palette filter.
local function tight_palette(vp, data, w, h, pal, num_colors)
    if num_colors == 2 then
        local row_bytes = math.floor((w + 7) / 8)
        if #data < row_bytes * h then
            return nil, string.format("Tight: palette(2) got %d bytes, need %d", #data, row_bytes * h)
        end
        for row = 0, h - 1 do
            local base = row * row_bytes
            for col = 0, w - 1 do
                local byte = data:byte(base + math.floor(col / 8) + 1)
                local bit = band(rshift(byte, 7 - col % 8), 1)
                local px = pal[bit + 1]
                PxFmt.write_pixel(vp, col, row, px[1], px[2], px[3])
            end
        end
    else
        if #data < w * h then
            return nil, string.format("Tight: palette(%d) got %d bytes, need %d", num_colors, #data, w * h)
        end
        for row = 0, h - 1 do
            local base = row * w
            for col = 0, w - 1 do
                local idx = data:byte(base + col + 1)
                local px = pal[idx + 1]
                if not px then
                    return nil, string.format("Tight: palette index %d out of range (%d entries)", idx, num_colors)
                end
                PxFmt.write_pixel(vp, col, row, px[1], px[2], px[3])
            end
        end
    end
    return true
end

--[[--
Applies the Tight gradient filter at 8/16 bpp (libvncclient's `FilterGradientBPP` without
cutZeros): the prediction runs on the quantized channel values, one residual PIXEL per pixel.
]]
local function tight_gradient_bpp(fmt, vp, data, w, h)
    local nb = fmt.bytes
    if #data < w * h * nb then
        return nil, string.format("Tight: gradient got %d bytes, need %d", #data, w * h * nb)
    end
    local src = ffi.cast("const uint8_t*", data)
    local maxes = { fmt.red_max, fmt.green_max, fmt.blue_max }
    local shifts = { fmt.red_shift, fmt.green_shift, fmt.blue_shift }
    local prev = ffi.new("int32_t[?]", w * 3)
    local cur = ffi.new("int32_t[?]", w * 3)
    local out = ffi.new("uint8_t[?]", w * nb)
    local big = fmt.big_endian ~= 0
    for row = 0, h - 1 do
        for col = 0, w - 1 do
            local s = src + (row * w + col) * nb
            local v = s[0]
            if nb == 2 then
                v = big and bor(lshift(s[0], 8), s[1]) or bor(lshift(s[1], 8), s[0])
            end
            local pv = 0
            for c = 0, 2 do
                local max = maxes[c + 1]
                local est = prev[c]
                if col > 0 then
                    est = prev[col * 3 + c] + cur[(col - 1) * 3 + c] - prev[(col - 1) * 3 + c]
                    if est > max then est = max elseif est < 0 then est = 0 end
                end
                local p = band(rshift(v, shifts[c + 1]) + est, max)
                cur[col * 3 + c] = p
                pv = bor(pv, lshift(p, shifts[c + 1]))
            end
            if nb == 2 then
                if big then
                    out[col * 2], out[col * 2 + 1] = rshift(pv, 8), band(pv, 0xFF)
                else
                    out[col * 2], out[col * 2 + 1] = band(pv, 0xFF), rshift(pv, 8)
                end
            else
                out[col] = pv
            end
        end
        write_crow(fmt, vp, 0, row, out, w)
        ffi.copy(prev, cur, w * 3 * 4)
    end
    return true
end

--- Applies the Tight gradient filter (24-bit "cutZeros" variant).
local function tight_gradient(vp, data, w, h)
    if #data < w * h * 3 then
        return nil, string.format("Tight: gradient got %d bytes, need %d", #data, w * h * 3)
    end
    local prev = ffi.new("uint8_t[?]", w * 3)
    local cur = ffi.new("uint8_t[?]", w * 3)
    local di = 0
    for row = 0, h - 1 do
        for c = 0, 2 do
            local v = (prev[c] + data:byte(di + 1)) % 256
            di = di + 1
            cur[c] = v
        end
        local px = { cur[0], cur[1], cur[2] }
        PxFmt.write_pixel(vp, 0, row, px[1], px[2], px[3])
        for col = 1, w - 1 do
            for c = 0, 2 do
                local est = prev[col * 3 + c] + cur[(col - 1) * 3 + c] - prev[(col - 1) * 3 + c]
                if est > 255 then est = 255 elseif est < 0 then est = 0 end
                local v = (est + data:byte(di + 1)) % 256
                di = di + 1
                cur[col * 3 + c] = v
                px[c + 1] = v
            end
            PxFmt.write_pixel(vp, col, row, px[1], px[2], px[3])
        end
        ffi.copy(prev, cur, w * 3)
    end
    return true
end

local function tight_jpeg(ctx, data)
    local ok, jpeg = pcall(require, "ffi/jpeg")
    if not ok then
        return nil, "Tight: JPEG payload but ffi/jpeg is unavailable"
    end
    local bb, w, h = jpeg.openDocumentFromMem(data, true, #data)
    if w ~= ctx.w or h ~= ctx.h then
        bb:free()
        return nil, string.format("Tight: JPEG is %dx%d, rect is %dx%d", w, h, ctx.w, ctx.h)
    end
    ctx.vp:blitFrom(bb, 0, 0, 0, 0, w, h)
    bb:free()
    return true
end

function Encodings.decode_tight(ctx)
    local r, vp, w, h, fmt = ctx.r, ctx.vp, ctx.w, ctx.h, ctx.fmt
    local ctl = r:u8()

    -- Low nibble: per-stream zlib reset flags.
    for i = 0, 3 do
        if band(ctl, lshift(1, i)) ~= 0 then
            local s = ctx.streams.tight and ctx.streams.tight[i]
            if s then s:reset() end
        end
    end
    ctl = rshift(ctl, 4)

    if ctl == Encodings.TIGHT_FILL then
        local cr, cg, cb = read_cpixel(r, fmt)
        PxFmt.fill_rect(vp, 0, 0, w, h, cr, cg, cb)
        return true
    elseif ctl == Encodings.TIGHT_JPEG then
        local len = read_compact_len(r)
        return tight_jpeg(ctx, r:bytes(len))
    elseif ctl > Encodings.TIGHT_NO_ZLIB then
        return nil, string.format("unsupported Tight subencoding 0x%02X", ctl)
    end

    local uncompressed = ctl == Encodings.TIGHT_NO_ZLIB
    local stream_id = band(ctl, 0x03)
    local filter = 0
    if not uncompressed and band(ctl, 0x04) ~= 0 then
        filter = r:u8()
    end

    local pal, num_colors, bits
    if filter == 0 then
        bits = fmt.cbytes * 8
    elseif filter == 1 then
        num_colors = r:u8() + 1
        if num_colors < 2 then
            return nil, "Tight: palette with fewer than 2 colours"
        end
        pal = {}
        for i = 1, num_colors do
            pal[i] = { read_cpixel(r, fmt) }
        end
        bits = num_colors == 2 and 1 or 8
    elseif filter == 2 then
        if w > Encodings.TIGHT_GRADIENT_MAX_WIDTH then
            return nil, string.format("Tight: gradient rect width %d exceeds %d",
                w, Encodings.TIGHT_GRADIENT_MAX_WIDTH)
        end
        bits = fmt.cbytes * 8
    else
        return nil, string.format("unsupported Tight filter %d", filter)
    end

    local row_size = math.floor((w * bits + 7) / 8)
    local raw_size = row_size * h
    local data
    if raw_size < Encodings.TIGHT_MIN_TO_COMPRESS then
        data = r:bytes(raw_size)
    else
        local len = read_compact_len(r)
        local comp = r:bytes(len)
        if uncompressed then
            data = comp
        else
            local out, err = tight_stream(ctx, stream_id):inflate(comp)
            if not out then
                return nil, string.format("Tight: %s while inflating %d bytes at rect (%d,%d,%d,%d)",
                    err, len, ctx.x, ctx.y, ctx.w, ctx.h)
            end
            data = out
        end
    end

    if filter == 0 or uncompressed then
        return tight_copy(fmt, vp, data, w, h)
    elseif filter == 1 then
        return tight_palette(vp, data, w, h, pal, num_colors)
    elseif fmt.bits_per_pixel ~= 32 then
        return tight_gradient_bpp(fmt, vp, data, w, h)
    end
    return tight_gradient(vp, data, w, h)
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
end

return Encodings
