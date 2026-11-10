--[[--
Stateful zlib wrapper: `inflate_ptr` for the RFB client, `deflate` for the RFB server.

KOReader's @{ffi.zlib} only exposes the one-shot `uncompress()`, which cannot be used for
RFB: ZRLE and Tight keep **one zlib stream alive for the whole connection**, and a tile's
compressed block never ends the stream (the server flushes with `Z_SYNC_FLUSH`). So we
cdef the streaming `z_stream` API here and keep one stream per RFB zlib stream id.

`ZStream.new()` makes an inflating stream, `ZStream.new_deflate(level)` a deflating one; both
survive the whole connection and neither ends the stream on a flush.

@module vnc.zstream
]]

local ffi = require("ffi")
require("ffi/loadlib")

ffi.cdef[[
typedef struct z_stream_s {
  const uint8_t *next_in; unsigned int avail_in; unsigned long total_in;
  uint8_t *next_out; unsigned int avail_out; unsigned long total_out; const char *msg;
  void *state; void *(*zalloc)(void*,unsigned,unsigned); void (*zfree)(void*,void*); void *opaque;
  int data_type; unsigned long adler; unsigned long reserved;
} z_stream;
int inflateInit_(z_stream*, const char*, int);
int inflate(z_stream*, int);
int inflateEnd(z_stream*);
int deflateInit_(z_stream*, int, const char*, int);
int deflate(z_stream*, int);
int deflateEnd(z_stream*);
]]

-- Same call as ffi/zlib.lua, so Android's monolibtic redirection of "z" keeps working.
local libz = ffi.loadlib("z", 1)

local Z_OK = 0
local Z_STREAM_END = 1
local Z_BUF_ERROR = -5
local Z_SYNC_FLUSH = 2
local Z_DEFAULT_COMPRESSION = -1

local z_stream_p = ffi.typeof("z_stream*")
local const_u8p = ffi.typeof("const uint8_t*")
local z_stream_sz = ffi.sizeof("z_stream")

-- zlib only compares the major version ("1"), the minor/patch part is informational.
local ZLIB_VERSION_STR = "1.2.11"

local ZStream = {}
ZStream.__index = ZStream

ZStream.Z_OK = Z_OK
ZStream.Z_STREAM_END = Z_STREAM_END
ZStream.Z_BUF_ERROR = Z_BUF_ERROR
ZStream.Z_SYNC_FLUSH = Z_SYNC_FLUSH

--- Creates a stream with `inflateInit_` already called.
function ZStream.new()
    local self = setmetatable({ mode = "inflate" }, ZStream)
    self.strm = ffi.new("z_stream[1]")
    local res = libz.inflateInit_(self.strm, ZLIB_VERSION_STR, z_stream_sz)
    assert(res == Z_OK, "inflateInit_ failed: " .. tostring(res))
    self.active = true
    return self
end

--- Creates a stream with `deflateInit_` already called (used by the server's ZRLE encoder).
--- @tparam[opt=-1] number level zlib compression level
function ZStream.new_deflate(level)
    local self = setmetatable({ mode = "deflate" }, ZStream)
    self.strm = ffi.new("z_stream[1]")
    self.level = level or Z_DEFAULT_COMPRESSION
    local res = libz.deflateInit_(self.strm, self.level, ZLIB_VERSION_STR, z_stream_sz)
    assert(res == Z_OK, "deflateInit_ failed: " .. tostring(res))
    self.active = true
    return self
end

--- Ends the stream and starts a fresh one (RFB zlib "reset stream" control bit).
function ZStream:reset()
    if self.mode == "deflate" then
        -- not self:free(): that drops the z_stream the new deflateInit_ needs
        if self.active then
            libz.deflateEnd(self.strm)
            self.active = false
        end
        local res = libz.deflateInit_(self.strm, self.level, ZLIB_VERSION_STR, z_stream_sz)
        assert(res == Z_OK, "deflateInit_ failed: " .. tostring(res))
        self.active = true
        return
    end
    if self.active then
        libz.inflateEnd(self.strm)
        self.active = false
    end
    local res = libz.inflateInit_(self.strm, ZLIB_VERSION_STR, z_stream_sz)
    assert(res == Z_OK, "inflateInit_ failed: " .. tostring(res))
    self.active = true
end

--- Grows the stream's persistent output buffer to at least `need` bytes, keeping `keep` bytes.
local function grow(self, need, keep)
    local cap = self.out_cap or 0
    if cap >= need then return end
    if cap == 0 then cap = 65536 end
    while cap < need do cap = cap * 2 end
    local buf = ffi.new("uint8_t[?]", cap)
    if keep > 0 then ffi.copy(buf, self.out, keep) end
    self.out, self.out_cap = buf, cap
end

--[[--
Feeds the `len` bytes at `ptr` (nil/0 for a bare drain) and inflates everything the stream
produces into the stream's own output buffer.

The input is a pointer, not a string: the decoders pass memory straight out of the receive buffer
(`reader:ptr(n)`), so a compressed payload is never copied into a Lua string. zlib has consumed it
by the time this returns (it is not referenced afterwards); a Lua string works too (it converts to
a pointer), as long as the caller keeps it alive for the call.

The stream is *not* finished: ZRLE/Tight blocks end with a sync flush, not with a stream
end, so we drain until the input is consumed and no more output can be produced.

The buffer is reused by the next call (no allocation per rect once it has grown), so the bytes
are only valid until then.
--- @tparam cdata|string|nil ptr the compressed bytes
--- @tparam number len how many of them
--- @tparam[opt] number limit fail rather than produce more than this many bytes
--- @treturn cdata|nil `const uint8_t*` to the output, or nil plus an error
--- @treturn number|string the output length, or the error
]]
function ZStream:inflate_ptr(ptr, len, limit)
    local strm = self.strm[0]
    if not ptr then len = 0 end
    strm.next_in = len > 0 and ffi.cast(const_u8p, ptr) or nil
    strm.avail_in = len
    -- give back a buffer one big rect grew far beyond what the stream now needs
    if (self.out_cap or 0) > 1048576 and (self.last_total or 0) * 4 < self.out_cap then
        self.out, self.out_cap = nil, nil
    end
    grow(self, 65536, 0)
    local total = 0
    local iterations = 0
    while true do
        iterations = iterations + 1
        if iterations > 32 then
            return nil, "zlib produced an unreasonable amount of output (possible loop)"
        end
        -- (a full buffer means there may be more: grow it; `limit` below bounds the growth)
        if total == self.out_cap then grow(self, total * 2, total) end
        local room = self.out_cap - total
        strm.next_out = self.out + total
        strm.avail_out = room
        local res = libz.inflate(strm, Z_SYNC_FLUSH)
        local produced = room - strm.avail_out
        total = total + produced
        if limit and total > limit then
            return nil, string.format("zlib output exceeds the %d bytes the rect can hold", limit)
        end
        if res == Z_STREAM_END then
            break
        elseif res ~= Z_OK and res ~= Z_BUF_ERROR then
            return nil, string.format("zlib error %d (%s)", res,
                strm.msg ~= nil and ffi.string(strm.msg) or "no message")
        end
        if strm.avail_out == 0 then -- luacheck: ignore 542
            -- the buffer is full: grow it and drain the rest
        elseif strm.avail_in == 0 or produced == 0 then
            break
        end
    end
    self.last_total = total
    return self.out, total
end

--[[--
Feeds the `len` bytes at `ptr` and returns the bytes zlib produced (a string: they go out on the
socket), ending with a `Z_SYNC_FLUSH` marker. Like @{ZStream:inflate_ptr}, a Lua string works as
`ptr`.

That marker is what an RFB zlib stream needs at the end of every ZRLE/Tight block: the stream
stays open (and keeps its compression history) but everything written so far becomes available to
the decoder.
]]
function ZStream:deflate(ptr, len)
    local strm = self.strm[0]
    strm.next_in = ffi.cast(const_u8p, ptr)
    strm.avail_in = len
    -- deflateBound-ish room: the input plus a little, so one call is the common case
    grow(self, len + math.floor(len / 1000) + 64, 0)
    local total = 0
    local iterations = 0
    while true do
        iterations = iterations + 1
        if iterations > 64 then
            return nil, "zlib deflate did not settle (possible loop)"
        end
        if total == self.out_cap then grow(self, total * 2, total) end
        local room = self.out_cap - total
        strm.next_out = self.out + total
        strm.avail_out = room
        local res = libz.deflate(strm, Z_SYNC_FLUSH)
        total = total + room - strm.avail_out
        if res ~= Z_OK then
            return nil, string.format("zlib error %d (%s)", res,
                strm.msg ~= nil and ffi.string(strm.msg) or "no message")
        end
        if strm.avail_in == 0 and strm.avail_out > 0 then
            return ffi.string(self.out, total)
        end
    end
end

function ZStream:free()
    if self.active then
        if self.mode == "deflate" then
            libz.deflateEnd(self.strm)
        else
            libz.inflateEnd(self.strm)
        end
        self.active = false
    end
    self.strm = nil
    self.out, self.out_cap = nil, nil
end

return ZStream
