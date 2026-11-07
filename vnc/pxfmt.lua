--[[--
Client pixel format and fast pixel-write helpers.

We ask the server for 32 bpp / depth 24 / little-endian true colour with
`red_shift=0, green_shift=8, blue_shift=16`. On the wire that puts R in the lowest
address byte, so

  * a 4-byte PIXEL (Raw/Hextile/RRE/Tight fill) is `[R, G, B, X]`
  * a 3-byte CPIXEL (TRLE/ZRLE/Tight) is `[R, G, B]`

and both map **directly** onto KOReader's `TYPE_BBRGB24` (`ColorRGB24 = {r, g, b}`), with no
byte swapping anywhere.

The lower-bandwidth 16-bit (RGB565) and 8-bit (BGR233) true-colour formats from
@{PxFmt.for_depth} are expanded to RGB24 by @{PxFmt.to_rgb24}/@{PxFmt.unpack}; at those depths
PIXEL and CPIXEL/TPIXEL are both `bpp / 8` bytes (RFC 6143 §7.7.5).

@module vnc.pxfmt
]]

local ffi = require("ffi")

local PxFmt = {}

--- The 16-byte PIXEL_FORMAT we send in SetPixelFormat.
PxFmt.PIXEL_FORMAT = {
    bits_per_pixel = 32,
    depth = 24,
    big_endian = 0,
    true_colour = 1,
    red_max = 255,
    green_max = 255,
    blue_max = 255,
    red_shift = 0,
    green_shift = 8,
    blue_shift = 16,
}

PxFmt.COLOR_DEPTH = 24
PxFmt.BYTES_PER_PIXEL = 4      -- PIXEL on the wire: [R, G, B, 0]
PxFmt.BYTES_PER_CPIXEL = 3     -- CPIXEL (TRLE/ZRLE/Tight): [R, G, B]

local bit = require("bit")
local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift

--- Client pixel formats by colour depth: the 10 PIXEL_FORMAT fields plus the wire sizes of a
--- PIXEL (`bytes`) and a CPIXEL/TPIXEL (`cbytes`).
local FORMATS = {
    [16] = { bits_per_pixel = 16, depth = 16, big_endian = 0, true_colour = 1,
             red_max = 31, green_max = 63, blue_max = 31,
             red_shift = 11, green_shift = 5, blue_shift = 0, bytes = 2, cbytes = 2 },
    [8]  = { bits_per_pixel = 8, depth = 8, big_endian = 0, true_colour = 1,
             red_max = 7, green_max = 7, blue_max = 3,
             red_shift = 0, green_shift = 3, blue_shift = 6, bytes = 1, cbytes = 1 },
}

FORMATS[24] = { bytes = PxFmt.BYTES_PER_PIXEL, cbytes = PxFmt.BYTES_PER_CPIXEL }
for k, v in pairs(PxFmt.PIXEL_FORMAT) do FORMATS[24][k] = v end

--[[--
Returns a fresh client pixel format table for colour depth `depth` (24, 16 or 8; anything else
means 24).
]]
function PxFmt.for_depth(depth)
    local fmt = {}
    for k, v in pairs(FORMATS[depth] or FORMATS[24]) do fmt[k] = v end
    return fmt
end

-- Channel expansion tables: lut[v] = floor(v * 255 / max + 0.5), cached per channel maximum.
local luts = {}
local function channel_lut(max)
    local lut = luts[max]
    if not lut then
        lut = ffi.new("uint8_t[?]", max + 1)
        for v = 0, max do lut[v] = math.floor(v * 255 / max + 0.5) end
        luts[max] = lut
    end
    return lut
end
PxFmt.channel_lut = channel_lut

-- Whole-pixel tables for 1- and 2-byte wire pixels: lut[v * 3 .. v * 3 + 2] = RGB24 of wire
-- value v (in host order), cached per channel layout (at most 192 KiB for 16 bpp).
local pixel_luts = {}
local function pixel_lut(fmt, size)
    local key = table.concat({ size, fmt.red_max, fmt.green_max, fmt.blue_max,
        fmt.red_shift, fmt.green_shift, fmt.blue_shift }, ",")
    local lut = pixel_luts[key]
    if not lut then
        local n = lshift(1, 8 * size)
        lut = ffi.new("uint8_t[?]", n * 3)
        local rl, gl, bl = channel_lut(fmt.red_max), channel_lut(fmt.green_max), channel_lut(fmt.blue_max)
        for v = 0, n - 1 do
            lut[v * 3] = rl[band(rshift(v, fmt.red_shift), fmt.red_max)]
            lut[v * 3 + 1] = gl[band(rshift(v, fmt.green_shift), fmt.green_max)]
            lut[v * 3 + 2] = bl[band(rshift(v, fmt.blue_shift), fmt.blue_max)]
        end
        pixel_luts[key] = lut
    end
    return lut
end
PxFmt.pixel_lut = pixel_lut

local function is_rgb_bytes(fmt)
    return fmt.big_endian == 0 and fmt.red_shift == 0 and fmt.green_shift == 8
        and fmt.blue_shift == 16 and fmt.red_max == 255 and fmt.green_max == 255
        and fmt.blue_max == 255
end

--[[--
Converts `count` wire pixels of `src_size` bytes each (`fmt.bytes` or `fmt.cbytes`) at `src`
into packed RGB24 at `dst`.
]]
function PxFmt.to_rgb24(fmt, src, count, dst, src_size)
    if src_size >= 3 and is_rgb_bytes(fmt) then
        if src_size == 3 then
            ffi.copy(dst, src, count * 3)
        else
            for i = 0, count - 1 do
                local s, d = src + i * src_size, dst + i * 3
                d[0], d[1], d[2] = s[0], s[1], s[2]
            end
        end
        return
    end
    if src_size <= 2 then
        -- 8/16 bpp: one table lookup per pixel, the table maps every wire value to its RGB24
        local lut = pixel_lut(fmt, src_size)
        if src_size == 1 then
            for i = 0, count - 1 do
                local q, d = src[i] * 3, i * 3
                dst[d], dst[d + 1], dst[d + 2] = lut[q], lut[q + 1], lut[q + 2]
            end
        elseif fmt.big_endian ~= 0 then
            for i = 0, count - 1 do
                local s, d = i * 2, i * 3
                local q = (src[s] * 256 + src[s + 1]) * 3
                dst[d], dst[d + 1], dst[d + 2] = lut[q], lut[q + 1], lut[q + 2]
            end
        else
            for i = 0, count - 1 do
                local s, d = i * 2, i * 3
                local q = (src[s + 1] * 256 + src[s]) * 3
                dst[d], dst[d + 1], dst[d + 2] = lut[q], lut[q + 1], lut[q + 2]
            end
        end
        return
    end
    local rl, gl, bl = channel_lut(fmt.red_max), channel_lut(fmt.green_max), channel_lut(fmt.blue_max)
    local rm, gm, bm = fmt.red_max, fmt.green_max, fmt.blue_max
    local rs, gs, bs = fmt.red_shift, fmt.green_shift, fmt.blue_shift
    local big = fmt.big_endian ~= 0
    for i = 0, count - 1 do
        local s = src + i * src_size
        local v = 0
        for k = 0, src_size - 1 do
            v = bor(v, lshift(s[big and k or (src_size - 1 - k)], 8 * (src_size - 1 - k)))
        end
        local d = dst + i * 3
        d[0] = rl[band(rshift(v, rs), rm)]
        d[1] = gl[band(rshift(v, gs), gm)]
        d[2] = bl[band(rshift(v, bs), bm)]
    end
end

local unpack_buf = ffi.new("uint8_t[3]")

--[[--
Reads one `size`-byte wire pixel from string `s` at 0-based offset `off`, returning r, g, b.
]]
function PxFmt.unpack(fmt, s, off, size)
    PxFmt.to_rgb24(fmt, ffi.cast("const uint8_t*", s) + off, 1, unpack_buf, size)
    return unpack_buf[0], unpack_buf[1], unpack_buf[2]
end

local uint8_t = ffi.typeof("uint8_t")
local uint8_ptr = ffi.typeof("uint8_t*")

--[[--
Writes one RGB pixel at `(x, y)` of BlitBuffer `vp` (`TYPE_BBRGB24`).
]]
function PxFmt.write_pixel(vp, x, y, r, g, b)
    local p = ffi.cast(uint8_ptr, vp.data) + y * vp.stride + x * 3
    p[0] = r
    p[1] = g
    p[2] = b
end

--[[--
Copies `count` packed `[R, G, B]` pixels from `row_ptr` to `vp` starting at `(x, y)`.
]]
function PxFmt.write_pixel_buffer(vp, x, y, row_ptr, count)
    local dst = ffi.cast(uint8_ptr, vp.data) + y * vp.stride + x * 3
    ffi.copy(dst, row_ptr, count * 3)
end

local fill_row, fill_row_len = nil, 0

--[[--
Fills a rect of `vp` with a solid colour, directly through the data pointer.
]]
function PxFmt.fill_rect(vp, x, y, w, h, r, g, b)
    if w <= 0 or h <= 0 then return end
    local base = ffi.cast(uint8_ptr, vp.data)
    local stride = vp.stride
    if w == 1 then
        for j = y, y + h - 1 do
            local p = base + j * stride + x * 3
            p[0], p[1], p[2] = r, g, b
        end
        return
    end
    if r == g and g == b then
        -- grey (most of what an e-reader is shown): one memset per row
        for j = y, y + h - 1 do
            ffi.fill(base + j * stride + x * 3, w * 3, r)
        end
        return
    end
    if fill_row_len < w * 3 then
        fill_row = ffi.new("uint8_t[?]", w * 3)
        fill_row_len = w * 3
    end
    local row = fill_row
    for i = 0, w - 1 do
        row[i * 3] = r
        row[i * 3 + 1] = g
        row[i * 3 + 2] = b
    end
    for j = y, y + h - 1 do
        ffi.copy(base + j * stride + x * 3, row, w * 3)
    end
end

--[[--
Reads one PIXEL (4 bytes) from a big-endian byte string at 0-based offset, returning r, g, b.
]]
function PxFmt.pixel_from_string(s, off)
    return s:byte(off + 1), s:byte(off + 2), s:byte(off + 3)
end

PxFmt.uint8_t = uint8_t

return PxFmt
