--[[--
Server-side rectangle encoders: the pixel-format conversion from KOReader's screen to whatever
format a client asked for, plus Raw, RRE, Hextile and ZRLE encoders.

The screen a client sees is `Screen.bb`, whose BlitBuffer type differs from device to device
(`BB8` on most e-ink, `BBRGB16/24/32` elsewhere). Rather than knowing every one of those layouts,
each rectangle is first blitted into a reusable `TYPE_BBRGB24` buffer - the C blitter does all
cross-format work - which leaves exactly one layout to handle here: three bytes `[r, g, b]` per
pixel (the same layout this plugin's client side relies on).

From there a rectangle is turned into
  * a `uint32_t` array of pixel *values* in the client's format (what the encoders compare), and
  * a byte string of those pixels as they go on the wire (what Raw sends).

The pixel format is the client's, per RFC 6143 §7.6.2: channel values are scaled to the client's
maxima and placed at its shifts, with the bytes ordered by its big-endian flag. Clients that ask
for a colour-mapped format get the fixed 3-3-2 map in @{Enc.COLOUR_MAP}.

@module vnc.serverenc
]]

local BB = require("ffi/blitbuffer")
local ffi = require("ffi")
local ZStream = require("vnc/zstream")
local logger = require("logger")

local Enc = {}
Enc.__index = Enc

Enc.RAW = 0
Enc.RRE = 2
Enc.HEXTILE = 5
Enc.ZRLE = 16

Enc.HEXTILE_SIZE = 16
Enc.ZRLE_TILE = 64

--- The pixel format a client sees if it never sends SetPixelFormat (and what ServerInit
--- announces): 32bpp true colour with RGB in the low address bytes, i.e. what this plugin's own
--- client asks for.
Enc.DEFAULT_FORMAT = {
    bits_per_pixel = 32, depth = 24, big_endian = 0, true_colour = 1,
    red_max = 255, green_max = 255, blue_max = 255,
    red_shift = 0, green_shift = 8, blue_shift = 16,
}

--- The 3-3-2 colour map served to colour-mapped clients (256 entries of `{r, g, b}`, 0..255).
Enc.COLOUR_MAP = {}
for i = 0, 255 do
    local r = math.floor((i / 32) % 8)
    local g = math.floor((i / 4) % 8)
    local b = i % 4
    Enc.COLOUR_MAP[i + 1] = {
        math.floor(r * 255 / 7 + 0.5),
        math.floor(g * 255 / 7 + 0.5),
        math.floor(b * 255 / 3 + 0.5),
    }
end

--- The colour map entry index for a pixel (inverse of @{Enc.COLOUR_MAP}).
local function map_index(r, g, b)
    return math.floor(r * 7 / 255 + 0.5) * 32
        + math.floor(g * 7 / 255 + 0.5) * 4
        + math.floor(b * 3 / 255 + 0.5)
end

function Enc.new()
    return setmetatable({
        -- Never nil: an encoder is always able to convert, and ServerInit announces this format
        -- until the client asks for another one.
        fmt = Enc.DEFAULT_FORMAT,
        encodings = { Enc.RAW },
        -- reuse buffers across rectangles; a full-screen rectangle is the worst case
        bb24 = nil,
        out = nil,
        values = nil,
        wbuf = nil,                  -- the encoders' output buffer (c.f., reserve)
        wcap = 0,
        zstream = nil,
        convert_serial = 0,          -- which conversion `values`/`out` currently hold
        values_size = 0,             -- pixels the buffer holds (0 = nothing allocated yet)
        out_len = 0,                 -- bytes the packed-pixel buffer holds
        cpixel_bytes = nil,          -- which of the 4 bytes of a 32bpp pixel carry the channels
        lut = { ffi.new("uint32_t[256]"), ffi.new("uint32_t[256]"), ffi.new("uint32_t[256]") },
    }, Enc)
end

--- Frees the reusable buffers (the zlib stream and the temp BlitBuffer).
function Enc:free()
    if self.bb24 then self.bb24:free() self.bb24 = nil end
    if self.zstream then self.zstream:free() self.zstream = nil end
    self.out, self.values, self.wbuf, self.wcap = nil, nil, nil, 0
end

-- ---------------------------------------------------------------- pixel format

--- Adopts the client's pixel format (as parsed from SetPixelFormat).
function Enc:set_pixel_format(fmt)
    self.fmt = fmt
    local true_colour = fmt.true_colour ~= 0
    if true_colour then
        local maxima = { fmt.red_max, fmt.green_max, fmt.blue_max }
        local shifts = { fmt.red_shift, fmt.green_shift, fmt.blue_shift }
        for channel = 1, 3 do
            local lut, max, shift = self.lut[channel], maxima[channel], shifts[channel]
            for v = 0, 255 do
                lut[v] = math.floor(v * max / 255 + 0.5) * 2 ^ shift
            end
        end
        -- At 32bpp the CPIXEL is the three bytes of the pixel that carry the channels - the least
        -- significant three if every channel fits there, else the most significant three - in the
        -- client's byte order (RFC 6143 §7.7.6; libvncserver's ZRLE 24A/24B make the same choice).
        -- `cpixel_bytes` lists them by significance (0 = least) in wire order.
        if fmt.bits_per_pixel == 32 then
            local ls3, ms3 = true, true
            for channel = 1, 3 do
                if maxima[channel] * 2 ^ shifts[channel] >= 2 ^ 24 then ls3 = false end
                if shifts[channel] < 8 then ms3 = false end
            end
            local cpixel = ls3 and { 0, 1, 2 } or (ms3 and { 1, 2, 3 } or nil)
            if cpixel and fmt.big_endian ~= 0 then cpixel = { cpixel[3], cpixel[2], cpixel[1] } end
            self.cpixel_bytes = cpixel
        else
            self.cpixel_bytes = nil
        end
    else
        self.cpixel_bytes = nil
    end
    logger.dbg("vnc: server encoder for", fmt.bits_per_pixel, "bpp,",
        true_colour and "true colour" or "colour mapped")
end

--- The client's encoding preference, filtered to what we can produce.
function Enc:set_encodings(encodings)
    self.encodings = encodings
end

--- Whether the client's list will need the per-pixel `values` array.
---
--- The list is in preference order and Raw is mandatory for every client, so the first entry of
--- the encodings we can actually reach decides: an encoder after a Raw entry never runs, and Raw
--- itself is happy with the byte string. Skipping the array matters for a Raw client - building it
--- is a pass over every pixel of the rectangle, and it is 4 bytes per pixel of allocation.
--- @tparam table|nil encodings
--- @treturn boolean
function Enc.needs_values(encodings)
    for _, encoding in ipairs(encodings or {}) do
        if encoding == Enc.RAW then return false end
        if encoding == Enc.ZRLE or encoding == Enc.HEXTILE or encoding == Enc.RRE then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------- conversion

local function ensure_buffers(self, w, h, need_values)
    local bpp = math.floor(self.fmt.bits_per_pixel / 8)
    if self.bb24 == nil or self.bb24:getWidth() < w or self.bb24:getHeight() < h then
        if self.bb24 then self.bb24:free() end
        self.bb24 = BB.new(w, h, BB.TYPE_BBRGB24)
    end
    if need_values ~= false and (self.values == nil or (self.values_size or 0) < w * h) then
        -- FFI arrays are 0-based while the encoders index pixels 1..count, so one extra slot.
        self.values = ffi.new("uint32_t[?]", w * h + 1)
        self.values_size = w * h
    end
    local need = w * h * bpp
    if self.out == nil or (self.out_len or 0) < need then
        self.out = ffi.new("uint8_t[?]", need)
        self.out_len = need
    end
    return bpp
end

--[[--
The byte-aligned RGB copy: the RGB24 plane is already the pixel (only a 32bpp format's padding byte
differs), so the bytes go straight across. Four plain loops rather than one with the layout tests
inside: the tests are constant for the whole rectangle, and a loop that carries them does not
compile as well (measured 25 ns/pixel against 2-4 ns/pixel here).

Each helper is `(data, stride, out, [values,] w, h)`; the caller has already blitted the rectangle
into `self.bb24`, so `data`/`stride` describe that RGB24 buffer.
]]
local function rgb32_into(data, stride, out, w, h)          -- 32bpp, no values array
    for y = 0, h - 1 do
        local p = data + y * stride
        local o = y * w * 4
        for x = 0, w - 1 do
            out[o], out[o + 1], out[o + 2], out[o + 3] = p[0], p[1], p[2], 0
            p = p + 3
            o = o + 4
        end
    end
end

local function rgb32_values_into(data, stride, out, values, w, h)
    for y = 0, h - 1 do
        local p = data + y * stride
        local o = y * w * 4
        local vi = y * w + 1
        for x = 0, w - 1 do
            local r, g, b = p[0], p[1], p[2]
            out[o], out[o + 1], out[o + 2], out[o + 3] = r, g, b, 0
            values[vi + x] = r + g * 256 + b * 65536
            p = p + 3
            o = o + 4
        end
    end
end

local function rgb24_into(data, stride, out, w, h)          -- 24bpp, no values array
    for y = 0, h - 1 do
        local p = data + y * stride
        local o = y * w * 3
        for x = 0, w - 1 do
            out[o], out[o + 1], out[o + 2] = p[0], p[1], p[2]
            p = p + 3
            o = o + 3
        end
    end
end

local function rgb24_values_into(data, stride, out, values, w, h)
    for y = 0, h - 1 do
        local p = data + y * stride
        local o = y * w * 3
        local vi = y * w + 1
        for x = 0, w - 1 do
            local r, g, b = p[0], p[1], p[2]
            out[o], out[o + 1], out[o + 2] = r, g, b
            values[vi + x] = r + g * 256 + b * 65536
            p = p + 3
            o = o + 3
        end
    end
end

--[[--
Converts one screen rectangle into the client's pixel format.

Returns the byte string as it goes on the wire. When `need_values` is true, `self.values`
additionally holds one entry per pixel (the same value, unpacked into a Lua number) for the
encoders that have to compare pixels; when it is false, `self.values` is left as it was (an
encoding that does not need it never reads it, and the array is not even allocated).
]]
--- `need_values` may be false when the client's first encoding is Raw (c.f.,
--- @{Enc.needs_values}): the byte string is all that encoding needs, and the per-pixel array is a
--- whole extra pass and four bytes per pixel of allocation.
---
--- @tparam BlitBuffer source the screen being served
--- @tparam table rect `{x, y, w, h}` in screen coordinates
--- @tparam[opt=true] boolean need_values
--- @treturn string pixels, number count
function Enc:convert(source, rect, need_values)
    if need_values == nil then need_values = true end
    -- Bumped for every conversion, and it identifies which rectangle `values` holds from now on.
    -- `out`/`values` are this one encoder's reusable buffers, so a conversion another caller stored
    -- away is only still *this* rectangle's pixels while the encoder has not converted anything
    -- since (c.f., @{Server:_encode}, which shares a conversion between clients of one pixel
    -- format only under exactly that condition).
    self.convert_serial = self.convert_serial + 1
    local w, h = rect.w, rect.h
    local bpp = ensure_buffers(self, w, h, need_values)
    local fmt = self.fmt
    local true_colour = fmt.true_colour ~= 0

    -- One cross-format blit, then everything below only ever sees [r, g, b] triples.
    self.bb24:blitFrom(source, 0, 0, rect.x, rect.y, w, h)
    local stride = self.bb24.stride
    local data = ffi.cast("const uint8_t*", self.bb24.data)

    -- Only when wanted: an array from an earlier (smaller, tiled) rectangle may still be there, and
    -- a conversion that did not ask for it did not grow it either.
    local out, values = self.out, need_values and self.values or nil
    local count = w * h

    -- The layout every viewer asks for (and the one ServerInit announces): 8 bits per channel, in
    -- byte order, so the RGB24 plane is *already* the pixel - only a 32bpp format's padding byte
    -- differs. Copy the bytes straight across instead of looking each channel up in a LUT and
    -- re-assembling the value with divisions; the general loop below stays for every other format.
    local byte_aligned = true_colour and fmt.big_endian == 0 and fmt.red_max == 255
        and fmt.green_max == 255 and fmt.blue_max == 255 and fmt.red_shift == 0
        and fmt.green_shift == 8 and fmt.blue_shift == 16 and (bpp == 3 or bpp == 4)
    if byte_aligned then
        if bpp == 4 then
            if need_values then
                rgb32_values_into(data, stride, out, values, w, h)
            else
                rgb32_into(data, stride, out, w, h)
            end
        elseif need_values then
            rgb24_values_into(data, stride, out, values, w, h)
        else
            rgb24_into(data, stride, out, w, h)
        end
        return ffi.string(out, count * bpp), count
    end

    if true_colour then
        local R, G, B = self.lut[1], self.lut[2], self.lut[3]
        local rs, gs, bs = fmt.red_shift, fmt.green_shift, fmt.blue_shift
        local be = fmt.big_endian ~= 0
        local i, pi = 0, 0
        for y = 0, h - 1 do
            local p = data + y * stride
            for _ = 0, w - 1 do
                local v = R[p[0]] + G[p[1]] + B[p[2]]
                p = p + 3
                pi = pi + 1
                -- May be nil: a client whose first encoding is Raw asked for the bytes only
                -- (c.f., @{Enc.needs_values}), and no encoder that reads the array can run then.
                if values then values[pi] = v end   -- 1-based, matching the encoders' loops
                if bpp == 4 then
                    -- build the little-endian bytes, then reverse for big-endian clients
                    local b0, b1 = v % 256, math.floor(v / 256) % 256
                    local b2, b3 = math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256
                    if be then
                        out[i] = b3 out[i + 1] = b2 out[i + 2] = b1 out[i + 3] = b0
                    else
                        out[i] = b0 out[i + 1] = b1 out[i + 2] = b2 out[i + 3] = b3
                    end
                elseif bpp == 3 then
                    local b0, b1 = v % 256, math.floor(v / 256) % 256
                    local b2 = math.floor(v / 65536) % 256
                    if be then
                        out[i] = b2 out[i + 1] = b1 out[i + 2] = b0
                    else
                        out[i] = b0 out[i + 1] = b1 out[i + 2] = b2
                    end
                elseif bpp == 2 then
                    local b0, b1 = v % 256, math.floor(v / 256) % 256
                    if be then
                        out[i] = b1 out[i + 1] = b0
                    else
                        out[i] = b0 out[i + 1] = b1
                    end
                else
                    out[i] = v % 256
                end
                i = i + bpp
            end
        end
    else
        -- colour mapped (8bpp): the 3-3-2 index of Enc.COLOUR_MAP
        local i, pi = 0, 0
        for y = 0, h - 1 do
            local p = data + y * stride
            for _ = 0, w - 1 do
                local idx = map_index(p[0], p[1], p[2])
                p = p + 3
                pi = pi + 1
                if values then values[pi] = idx end  -- 1-based; nil for a Raw-only client
                out[i] = idx
                i = i + 1
            end
        end
    end

    return ffi.string(out, count * bpp), count
end

-- ---------------------------------------------------------------- output buffer

--[[--
The encoders write into one reusable byte buffer per encoder (`self.wbuf`, 0-based, `self.wcap`
bytes) and turn it into a string once per rectangle; a writer per field and a string per pixel was
an allocation for every byte they emitted.

Each writer takes and returns the write position, so an encoder keeps it in a local; @{reserve}
must have made room first (it returns the buffer, which a growth replaces, keeping `pos` bytes).
]]
local function reserve(self, pos, need)
    local cap = self.wcap or 0
    if pos + need > cap then
        if cap == 0 then cap = 4096 end
        while pos + need > cap do cap = cap * 2 end
        local buf = ffi.new("uint8_t[?]", cap)
        if pos > 0 then ffi.copy(buf, self.wbuf, pos) end
        self.wbuf, self.wcap = buf, cap
    end
    return self.wbuf
end

local function put_u16(buf, pos, v)
    buf[pos], buf[pos + 1] = math.floor(v / 256) % 256, v % 256
    return pos + 2
end

local function put_u32(buf, pos, v)
    buf[pos], buf[pos + 1] = math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256
    buf[pos + 2], buf[pos + 3] = math.floor(v / 256) % 256, v % 256
    return pos + 4
end

--- One pixel value as it goes on the wire: `bpp` bytes in the client's byte order (`be`).
local function put_pixel(buf, pos, v, bpp, be)
    if bpp == 4 then
        local b0, b1 = v % 256, math.floor(v / 256) % 256
        local b2, b3 = math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256
        if be then
            buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3] = b3, b2, b1, b0
        else
            buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3] = b0, b1, b2, b3
        end
    elseif bpp == 3 then
        local b0, b1, b2 = v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256
        if be then
            buf[pos], buf[pos + 1], buf[pos + 2] = b2, b1, b0
        else
            buf[pos], buf[pos + 1], buf[pos + 2] = b0, b1, b2
        end
    elseif bpp == 2 then
        local b0, b1 = v % 256, math.floor(v / 256) % 256
        if be then
            buf[pos], buf[pos + 1] = b1, b0
        else
            buf[pos], buf[pos + 1] = b0, b1
        end
    else
        buf[pos] = v % 256
    end
    return pos + bpp
end

--- One CPIXEL (ZRLE/TRLE omit a 32bpp format's padding byte, c.f. `cpixel_bytes`).
local function put_cpixel(self, buf, pos, v, bpp, be)
    local cp = self.cpixel_bytes
    if not cp then return put_pixel(buf, pos, v, bpp, be) end
    for i = 1, 3 do
        buf[pos + i - 1] = math.floor(v / 2 ^ (8 * cp[i])) % 256
    end
    return pos + 3
end

--- The client's bytes per pixel and byte order, as the writers above take them.
local function wire_layout(self)
    return math.floor(self.fmt.bits_per_pixel / 8), self.fmt.big_endian ~= 0
end

-- ---------------------------------------------------------------- encoders

--[[--
Encodes one rectangle with the best encoding the client announced (its list is in preference
order), falling back to Raw.
]]
--- `converted` (optional) is a conversion of this same rectangle, in this encoder's pixel
--- format, made by another encoder ({ pixels = <string>, count = <number>, values = <array|nil> }).
--- The server hands one over when several clients of the same format are being served in the same
--- tick, so the per-pixel conversion is done once rather than once per client. It is only used
--- when it carries what this client's encodings need.
---
--- @treturn number encoding, string payload
function Enc:encode(source, rect, converted)
    local want_values = Enc.needs_values(self.encodings)
    local pixels, count, values
    if converted and (converted.values ~= nil or not want_values) then
        pixels, count, values = converted.pixels, converted.count, converted.values
    else
        pixels, count = self:convert(source, rect, want_values)
        -- The encoders compare pixels, so they work on the per-pixel value array; only Raw uses
        -- the byte string itself.
        values = self.values
    end
    for _, encoding in ipairs(self.encodings) do
        if encoding == Enc.ZRLE then
            local payload = self:encode_zrle(values, count, rect.w, rect.h)
            if payload then return Enc.ZRLE, payload end
        elseif encoding == Enc.HEXTILE then
            local payload = self:encode_hextile(values, count, rect.w, rect.h)
            if payload then return Enc.HEXTILE, payload end
        elseif encoding == Enc.RRE then
            local payload = self:encode_rre(values, count, rect.w, rect.h)
            if payload then return Enc.RRE, payload end
        elseif encoding == Enc.RAW then
            return Enc.RAW, pixels
        end
    end
    return Enc.RAW, pixels
end

--- The most frequent pixel value of a range, with its count.
local function dominant(values, from, to, scratch)
    local counts = scratch.counts
    local distinct = 0
    local best, best_count = values[from], 0
    for i = from, to do
        local v = values[i]
        local c = counts[v]
        if c == nil then
            c = 0
            distinct = distinct + 1
        end
        c = c + 1
        counts[v] = c
        if c > best_count then best, best_count = v, c end
    end
    -- clear for the next caller without allocating a new table
    for i = from, to do counts[values[i]] = nil end
    return best, best_count, distinct
end

local function new_scratch(w, h)
    return { counts = {}, runs = {} }
end

--[[--
RRE: one background pixel, then subrectangles of non-background pixels with their own pixel.

Runs are taken per row and extended downwards while the rows below match, which is what makes
this worthwhile on the large flat areas a reader UI has. The pixels a run extended over are marked
covered, so the rows below neither start subrectangles of their own there nor re-walk them. If the
result would not be smaller than Raw, Raw is used instead (returning nil).
]]
function Enc:encode_rre(values, count, w, h)
    local scratch = self.scratch or new_scratch(w, h)
    self.scratch = scratch
    local background = dominant(values, 1, count, scratch)

    -- 1-based like `values`; cleared per rectangle, grown only when a bigger one arrives
    if (scratch.covered_size or 0) < count then
        scratch.covered = ffi.new("uint8_t[?]", count + 1)
        scratch.covered_size = count
    else
        ffi.fill(scratch.covered, count + 1)
    end
    local covered = scratch.covered

    local subrects = {}
    for y = 0, h - 1 do
        local row = y * w
        local x = 0
        while x < w do
            local i = row + x + 1
            local v = values[i]
            if covered[i] ~= 0 or v == background then
                x = x + 1
            else
                local run = 1
                while x + run < w and values[i + run] == v and covered[i + run] == 0 do
                    run = run + 1
                end
                -- extend downwards while the next row has the same, still uncovered, run
                local height = 1
                while y + height < h do
                    local base = i + height * w
                    local same = true
                    for dx = 0, run - 1 do
                        if values[base + dx] ~= v or covered[base + dx] ~= 0 then
                            same = false
                            break
                        end
                    end
                    if not same then break end
                    for dx = 0, run - 1 do covered[base + dx] = 1 end
                    height = height + 1
                end
                subrects[#subrects + 1] = { x = x, y = y, w = run, h = height, value = v }
                x = x + run
            end
        end
    end

    local bpp, be = wire_layout(self)
    local n = #subrects
    local size = 4 + bpp + n * (bpp + 8)
    if size >= count * bpp then return nil end

    local buf = reserve(self, 0, size)
    local pos = put_u32(buf, 0, n)
    pos = put_pixel(buf, pos, background, bpp, be)
    for i = 1, n do
        local r = subrects[i]
        pos = put_pixel(buf, pos, r.value, bpp, be)
        pos = put_u16(buf, pos, r.x)
        pos = put_u16(buf, pos, r.y)
        pos = put_u16(buf, pos, r.w)
        pos = put_u16(buf, pos, r.h)
    end
    return ffi.string(buf, pos)
end

--[[--
Hextile: 16x16 tiles. Uniform tiles cost one pixel, tiles with a dominant colour cost that plus
subrectangles, and anything that would not pay off is sent Raw.
]]
function Enc:encode_hextile(values, count, w, h)
    local scratch = self.scratch or new_scratch(w, h)
    self.scratch = scratch
    local bpp, be = wire_layout(self)
    local background                      -- carried between tiles, per RFC 6143 §7.7.4
    local first_tile = true               -- ... but never assumed at the start of a rectangle
    local tile = scratch.tile
    if not tile then tile = {} scratch.tile = tile end
    -- the tile's subrectangles, as parallel arrays (x, y, w, value)
    local rx, ry, rw, rv = scratch.hx_x, scratch.hx_y, scratch.hx_w, scratch.hx_v
    if not rx then
        rx, ry, rw, rv = {}, {}, {}, {}
        scratch.hx_x, scratch.hx_y, scratch.hx_w, scratch.hx_v = rx, ry, rw, rv
    end
    local buf, pos = reserve(self, 0, 1), 0     -- never nil, even for an empty rectangle

    local ty = 0
    while ty < h do
        local th = math.min(Enc.HEXTILE_SIZE, h - ty)
        local tx = 0
        while tx < w do
            local tw = math.min(Enc.HEXTILE_SIZE, w - tx)

            -- gather the tile's values
            local n = 0
            for y = 0, th - 1 do
                local base = (ty + y) * w + tx
                for x = 0, tw - 1 do
                    n = n + 1
                    tile[n] = values[base + x + 1]
                end
            end
            -- the most a tile can take: mask, both colours, the count, a coloured subrect a pixel
            buf = reserve(self, pos, 2 + 2 * bpp + n * (bpp + 2))
            -- One call answers both questions: `bg` is the tile's most frequent value and
            -- `uniform_count` its count, which is the whole tile exactly when it is uniform. The
            -- second pass over the same range would recompute the first one's answer.
            local bg, uniform_count = dominant(tile, 1, n, scratch)
            local mask = 0
            local mask_pos = pos                     -- written once the payload decided it
            pos = pos + 1

            if uniform_count == n then
                if first_tile or bg ~= background then
                    mask = mask + 2                          -- BackgroundSpecified
                    pos = put_pixel(buf, pos, bg, bpp, be)
                end
                background = bg
                -- A tile with no subrects is entirely background.
            else
                -- subrectangles: one per run of equal pixels, keeping the tile's own geometry
                if first_tile or bg ~= background then
                    mask = mask + 2
                    pos = put_pixel(buf, pos, bg, bpp, be)
                    background = bg
                end

                local runs = 0
                for y = 0, th - 1 do
                    local x = 0
                    while x < tw do
                        local v = tile[y * tw + x + 1]
                        local run = 1
                        while x + run < tw and tile[y * tw + x + run + 1] == v do run = run + 1 end
                        if v ~= background then
                            runs = runs + 1
                            rx[runs], ry[runs], rw[runs], rv[runs] = x, y, run, v
                        end
                        x = x + run
                    end
                end

                -- if every subrect shares one colour, an uncoloured (foreground) tile is smaller
                local single = runs > 0 and rv[1] or nil
                for i = 2, runs do
                    if rv[i] ~= single then single = nil break end
                end
                if single then
                    -- Always specify it: the semantic is "carried over unless specified", but a
                    -- decoder that has not seen a foreground yet would have to reject the tile.
                    mask = mask + 4                          -- ForegroundSpecified
                    pos = put_pixel(buf, pos, single, bpp, be)
                end
                if runs > 0 then
                    local coloured = not single
                    mask = mask + 8                          -- AnySubrects
                    if coloured then mask = mask + 16 end    -- SubrectsColoured
                    buf[pos] = runs % 256
                    pos = pos + 1
                    for i = 1, runs do
                        if coloured then pos = put_pixel(buf, pos, rv[i], bpp, be) end
                        buf[pos] = ((rx[i] % 16) * 16) + (ry[i] % 16)
                        buf[pos + 1] = ((rw[i] - 1) % 16) * 16
                        pos = pos + 2
                    end
                end
            end
            buf[mask_pos] = mask
            first_tile = false
            tx = tx + tw
        end
        ty = ty + th
    end
    return ffi.string(self.wbuf, pos)
end

-- ---------------------------------------------------------------- ZRLE

--- Packs palette indices, MSB first, one row at a time, padded to whole bytes.
local function pack_indices(buf, pos, indices, w, bits)
    local per_byte = math.floor(8 / bits)
    local x = 0
    while x < w do
        local byte = 0
        for i = 0, per_byte - 1 do
            local idx = indices[x + i + 1]
            byte = byte * 2 ^ bits + (idx or 0)
        end
        buf[pos] = byte
        pos = pos + 1
        x = x + per_byte
    end
    return pos
end

--- One TRLE tile (the subencoding ZRLE is built from), for a 64x64 (or smaller) tile, written at
--- `pos` of the encoder's buffer; returns the position after it.
local function zrle_tile(self, pos, tile, tw, th, scratch, bpp, be)
    local n = tw * th
    local cb = self.cpixel_bytes and 3 or bpp
    -- the most a tile can take: plain RLE with a run per pixel, or a 16-colour palette
    local buf = reserve(self, pos, 1 + math.max(16 * cb + n, n * (cb + 1)))
    -- One call answers all three: the most frequent value, its count (the tile is solid exactly
    -- when that count is the whole tile) and how many distinct values there are.
    local uniform, uniform_count, distinct = dominant(tile, 1, n, scratch)
    if uniform_count == n then
        buf[pos] = 1                                         -- solid
        return put_cpixel(self, buf, pos + 1, uniform, bpp, be)
    end

    if distinct <= 16 then
        -- packed palette: subencoding = palette size, palette, then packed indices
        local palette = scratch.palette
        if not palette then palette = {} scratch.palette = palette end
        local index_of = scratch.index_of
        if not index_of then index_of = {} scratch.index_of = index_of end
        local size = 0
        for i = 1, n do
            local v = tile[i]
            if index_of[v] == nil then
                size = size + 1
                palette[size] = v
                index_of[v] = size
            end
        end
        buf[pos] = size
        pos = pos + 1
        for i = 1, size do pos = put_cpixel(self, buf, pos, palette[i], bpp, be) end
        local bits = (size == 2) and 1 or (size <= 4 and 2 or 4)
        local indices = scratch.indices
        if not indices then indices = {} scratch.indices = indices end
        for y = 0, th - 1 do
            for x = 0, tw - 1 do
                indices[x + 1] = index_of[tile[y * tw + x + 1]] - 1
            end
            pos = pack_indices(buf, pos, indices, tw, bits)
        end
        for i = 1, size do index_of[palette[i]] = nil end
    else
        -- plain RLE: runs of equal pixels, length = 1 + sum of the length bytes (255 repeats)
        buf[pos] = 128
        pos = pos + 1
        local i = 1
        while i <= n do
            local v = tile[i]
            local run = 1
            while i + run <= n and tile[i + run] == v do run = run + 1 end
            pos = put_cpixel(self, buf, pos, v, bpp, be)
            local len = run - 1
            while len >= 255 do
                buf[pos] = 255
                pos = pos + 1
                len = len - 255
            end
            buf[pos] = len
            pos = pos + 1
            i = i + run
        end
    end
    return pos
end

--[[--
ZRLE: the rectangle's TRLE-style tile stream, compressed through the connection's zlib stream
with a Z_SYNC_FLUSH at the end, prefixed by its length.
]]
function Enc:encode_zrle(values, count, w, h)
    local scratch = self.scratch or new_scratch(w, h)
    self.scratch = scratch
    if not self.zstream then
        self.zstream = ZStream.new_deflate()
    end
    local bpp, be = wire_layout(self)

    local tile = scratch.zrle_tile
    if not tile then tile = {} scratch.zrle_tile = tile end

    reserve(self, 0, 1)                          -- never nil, even for an empty rectangle
    local pos = 0
    local tile_size = Enc.ZRLE_TILE
    local ty = 0
    while ty < h do
        local th = math.min(tile_size, h - ty)
        local tx = 0
        while tx < w do
            local tw = math.min(tile_size, w - tx)
            local n = 0
            for y = 0, th - 1 do
                local base = (ty + y) * w + tx
                for x = 0, tw - 1 do
                    n = n + 1
                    tile[n] = values[base + x + 1]
                end
            end
            pos = zrle_tile(self, pos, tile, tw, th, scratch, bpp, be)
            tx = tx + tw
        end
        ty = ty + th
    end

    local compressed, err = self.zstream:deflate(ffi.string(self.wbuf, pos))
    if not compressed then
        logger.warn("vnc: ZRLE compression failed:", err)
        return nil
    end
    local len = #compressed
    return string.char(math.floor(len / 16777216) % 256, math.floor(len / 65536) % 256,
        math.floor(len / 256) % 256, len % 256) .. compressed
end

return Enc
