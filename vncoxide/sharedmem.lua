--[[--
BlitBuffers over anonymous shared memory, so forked worker processes and the
parent see the same pixels.

@module vncoxide.sharedmem
]]

local bit = require("bit")
local BB = require("ffi/blitbuffer")
local ffi = require("ffi")
require("ffi/posix_h") -- mmap, munmap, PROT_*, MAP_SHARED, MAP_ANONYMOUS, MAP_FAILED
local C = ffi.C

local SharedMem = {}

local BPP = {
    [BB.TYPE_BB8] = 1, [BB.TYPE_BB8A] = 2, [BB.TYPE_BBRGB16] = 2,
    [BB.TYPE_BBRGB24] = 3, [BB.TYPE_BBRGB32] = 4,
}

--- Maps `bytes` of zeroed memory shared with forked children. Errors on failure.
function SharedMem.alloc(bytes)
    local ptr = C.mmap(nil, bytes, bit.bor(C.PROT_READ, C.PROT_WRITE),
        bit.bor(C.MAP_SHARED, C.MAP_ANONYMOUS), -1, 0)
    if ptr == nil or ffi.cast("intptr_t", ptr) == -1 then
        error("cannot allocate " .. tostring(bytes) .. " bytes of shared memory: " .. tostring(ffi.errno()))
    end
    return ptr
end

function SharedMem.free(ptr, bytes)
    C.munmap(ptr, bytes)
end

--- A BlitBuffer viewing `ptr`; never :free() it, release the mapping with SharedMem.free.
function SharedMem.bb(ptr, w, h, bbtype)
    local bpp = assert(BPP[bbtype], "unsupported blitbuffer type")
    return BB.new(w, h, bbtype, ptr, w * bpp)
end

return SharedMem
