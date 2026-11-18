--[[--
The pixel work behind @{Remote:draw_to}: scaling the plane into a persistent canvas-sized
buffer, the tone curve (contrast, invert) and the dithered copy.

It owns the canvas buffer, the dithered buffer and the "filled for view" bookkeeping, and knows
nothing of the viewer's geometry: the view, the stale rects and the size come in with every
@{Renderer:render}. The picture (what @{Renderer:canvas} returns) may live in memory given by
the caller (`opts.canvas_mem`), e.g. shared memory a forked worker renders into: the canvas
buffer, or while dithering the dithered buffer (the canvas is then private).

@module vncoxide.renderer
]]

local BB = require("ffi/blitbuffer")
local Scaler = require("vncoxide/scaler")
local SharedMem = require("vncoxide/sharedmem")
local Util = require("vncoxide/util")
local time = require("ui/time")

local Renderer = {}
Renderer.__index = Renderer

local BPP = {
    [BB.TYPE_BB8] = 1, [BB.TYPE_BBRGB24] = 3, [BB.TYPE_BBRGB32] = 4,
}

--[[--
Creates a renderer.
--- @tparam[opt] table opts `canvas_mem = {ptr = cdata, bytes = number}`: build the canvas over
---   that memory (it must fit the canvas, else `render` errors) instead of allocating it
--- @treturn Renderer
]]
function Renderer.new(opts)
    return setmetatable({
        canvas_mem = opts and opts.canvas_mem or nil,
        _lut = nil,         -- the tone curve for the scaler, nil at neutral
        _canvas_bb = nil,   -- persistent canvas-sized buffer holding the scaled view
        _dither_bb = nil,   -- the canvas buffer dithered (only while painting dithered)
        _mem_dither = nil,  -- with canvas_mem: whether the dithered buffer is the one over it
        _dither_ok = false, -- _dither_bb matches _canvas_bb
        _dithered = false,  -- the last render was dithered: canvas() is _dither_bb
        _filled = nil,      -- what _canvas_bb was last fully computed for (view, size, mode)
        last_recomputed_px = 0, -- canvas pixels the last render rescaled
        last_dither_ms = nil,   -- the last render's dithering time, when it dithered
    }, Renderer)
end

--- Sets the tone curve: `contrast` factor (1: neutral) and `invert`. The caller must treat the
--- whole canvas as stale.
function Renderer:set_tone(contrast, invert)
    self._lut = Scaler.contrast_lut(contrast, invert)
end

local function drop_canvas(self)
    if self._canvas_bb then
        -- a buffer over caller-given memory is not ours to free
        if not (self.canvas_mem and not self._mem_dither) then self._canvas_bb:free() end
        self._canvas_bb = nil
    end
    if self._dither_bb then
        if not (self.canvas_mem and self._mem_dither) then self._dither_bb:free() end
        self._dither_bb = nil
    end
    self._mem_dither = nil
    self._dither_ok = false
    self._dithered = false
    self._filled = nil
end

--[[--
Brings the canvas up to date and, dithering, the dithered copy.

Everything is recomputed when `all_stale`, or the view, scaling mode, plane or canvas buffer
changed since the last render; otherwise only the canvas pixels depending on `stale_rects`
(remote rects, may be nil). Dithering happens only where the canvas was recomputed.

Sets `last_recomputed_px` and, when dithering, `last_dither_ms`.
--- @tparam BlitBuffer plane
--- @tparam table view `{x, y, scale}`, as the scaler draws it
--- @tparam string mode "smooth" or "sharp"
--- @tparam number cw, ch canvas size
--- @tparam number btype canvas buffer type (one the scaler writes)
--- @tparam boolean dither
--- @tparam[opt] table stale_rects
--- @tparam boolean all_stale
--- @treturn table|string|nil the canvas rects recomputed, `"full"`, or nil when nothing changed
]]
function Renderer:render(plane, view, mode, cw, ch, btype, dither, stale_rects, all_stale)
    self.last_recomputed_px, self.last_dither_ms = 0, nil
    local canvas = self._canvas_bb
    local mem = self.canvas_mem
    dither = dither and true or false
    if not (canvas and canvas:getWidth() == cw and canvas:getHeight() == ch and canvas:getType() == btype)
            or (mem and self._mem_dither ~= dither) then
        drop_canvas(self)
        if mem then
            local need = cw * ch * assert(BPP[btype], "unsupported canvas type")
            if need > mem.bytes then
                error("vncoxide.renderer: a " .. cw .. "x" .. ch .. " canvas needs " .. need
                    .. " bytes, the canvas memory has " .. tostring(mem.bytes))
            end
            -- the picture goes into the caller's memory: the dithered buffer while dithering
            self._mem_dither = dither
            if dither then
                canvas = BB.new(cw, ch, btype)
                self._dither_bb = SharedMem.bb(mem.ptr, cw, ch, btype)
                self._dither_ok = false
            else
                canvas = SharedMem.bb(mem.ptr, cw, ch, btype)
            end
        else
            canvas = BB.new(cw, ch, btype)
        end
        self._canvas_bb = canvas
    end

    local s, vx, vy = view.scale, view.x, view.y
    local f = self._filled
    local full, rects = false, nil
    if all_stale or not f or f.x ~= vx or f.y ~= vy or f.scale ~= s or f.mode ~= mode
            or f.plane ~= plane then
        Scaler.render(canvas, plane, view, { x = 0, y = 0, w = cw, h = ch }, mode, self._lut)
        self._filled = { x = vx, y = vy, scale = s, mode = mode, plane = plane }
        self.last_recomputed_px = cw * ch
        full = true
    elseif stale_rects and #stale_rects > 0 then
        rects = {}
        for _i, r in ipairs(stale_rects) do
            local d = Scaler.dst_rect_for(r, view, cw, ch, mode)
            if d then rects = Util.add_rect(rects, d) end
        end
        local px = 0
        for _i, d in ipairs(rects) do
            Scaler.render(canvas, plane, view, d, mode, self._lut)
            px = px + d.w * d.h
        end
        self.last_recomputed_px = px
        if not rects[1] then rects = nil end -- (none of them is in the canvas: nothing changed)
    end

    if dither then
        local t0 = Util.timing_enabled() and time.now()
        local dbb = self._dither_bb
        if not dbb then
            dbb = BB.new(cw, ch, btype)
            self._dither_bb = dbb
            self._dither_ok = false
        end
        if full or not self._dither_ok then
            dbb:ditherblitFrom(canvas, 0, 0, 0, 0, cw, ch)
        elseif rects then
            for _i, d in ipairs(rects) do
                dbb:ditherblitFrom(canvas, d.x, d.y, d.x, d.y, d.w, d.h)
            end
        end
        self._dither_ok = true
        self._dithered = true
        if t0 then self.last_dither_ms = time.to_ms(time.now() - t0) end
    else
        -- the canvas changes from here on without the dithered copy following it
        if full or rects then self._dither_ok = false end
        self._dithered = false
    end
    if full then return "full" end
    return rects
end

--- @treturn BlitBuffer the picture as last rendered: the dithered buffer when dithering, else the canvas
function Renderer:canvas()
    return self._dithered and self._dither_bb or self._canvas_bb
end

--- Frees the buffers it allocated (memory given as `canvas_mem` stays the caller's).
function Renderer:free()
    drop_canvas(self)
end

return Renderer
