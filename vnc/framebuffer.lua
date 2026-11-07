--[[--
The remote framebuffer plane and the view transform that maps it onto the screen.

The plane is a `TYPE_BBRGB24` BlitBuffer holding the remote pixels 1:1 (that is the format
@{vnc.pxfmt} negotiates, so decoders write straight into it). The view transform is a
uniform `scale` (screen pixels per remote pixel) plus an offset `view_x, view_y` naming the
remote coordinate shown at the canvas' top-left corner.

What the view shows is kept in a persistent canvas-sized buffer (see @{Remote:draw_to}): a remote
update rescales only the canvas pixels that depend on the remote rects it changed
(@{vnc.scaler}), and every paint blits the whole buffer.

@module vnc.framebuffer
]]

local BB = require("ffi/blitbuffer")
local Scaler = require("vnc/scaler")
local Util = require("vnc/util")
local time = require("ui/time")

local Remote = {}
Remote.__index = Remote

Remote.MIN_SCALE = 0.05
Remote.MAX_SCALE = 8
-- More stale rects than this between two paints recompute the whole canvas instead.
Remote.MAX_STALE_RECTS = 1024
-- Default margin of @{Remote:visible_remote_rect}, as a fraction of the visible width/height on
-- each side (`Session.REQUEST_MARGIN` is this value).
Remote.REQUEST_MARGIN = 0.25

--[[--
Creates a plane of `width` x `height` remote pixels.
--- @tparam number width
--- @tparam number height
]]
function Remote.new(width, height)
    local self = setmetatable({
        plane = BB.new(width, height, BB.TYPE_BBRGB24),
        w = width,
        h = height,
        scale = 1,
        view_x = 0,
        view_y = 0,
        cw = width,     -- canvas size (screen pixels) the view was last fitted to
        ch = height,
        version = 0,    -- bumped whenever the plane may have changed
        scaling = "smooth",
        _canvas_bb = nil,   -- persistent canvas-sized buffer holding the scaled view
        _dither_bb = nil,   -- the canvas buffer dithered (only while painting dithered)
        _dither_ok = false, -- _dither_bb matches _canvas_bb
        _filled = nil,      -- what _canvas_bb was last fully computed for (view, size, mode)
        _stale = {},        -- remote rects changed since _canvas_bb was last updated
        _all_stale = true,  -- the whole buffer must be recomputed
        last_recomputed_px = 0, -- canvas pixels the last draw_to rescaled
        last_blit_ms = nil,     -- the last draw_to's blit time, when it dithered
    }, Remote)
    return self
end

--[[--
The plane, for writing.

Handing the plane out advances the version counter, but does not mark anything stale: the
write happens *after* this, and a decode can span several UI ticks (a frame can be several
hundred KiB), so a repaint may well happen while the plane is half written. Every writer must
therefore call @{Remote:mark_dirty} once it is done (the session does this from its `on_rect`
callback), which makes the next @{Remote:draw_to} rescale what it wrote.
--- @treturn BlitBuffer
]]
function Remote:get_plane()
    self.version = self.version + 1
    return self.plane
end

--[[--
Marks a remote rect as changed, for the next @{Remote:draw_to} to rescale.

Without arguments the whole plane counts as changed.
--- @tparam[opt] number x, y, w, h the rect in remote coordinates
]]
function Remote:mark_dirty(x, y, w, h)
    self.version = self.version + 1
    if x == nil then
        self._all_stale = true
    elseif not self._all_stale and w > 0 and h > 0 then
        local stale = self._stale
        if #stale >= Remote.MAX_STALE_RECTS then
            -- e.g. many updates while a popup hides the viewer: one full recompute instead
            self._all_stale, self._stale = true, {}
        else
            stale[#stale + 1] = { x = x, y = y, w = w, h = h }
        end
    end
end

--[[--
Chooses how the view is scaled: `"smooth"` (bilinear up, area average down) or `"sharp"`
(nearest neighbour). A change recomputes the whole canvas on the next paint.
--- @tparam string mode
]]
function Remote:set_scaling(mode)
    assert(mode == "smooth" or mode == "sharp", "vnc.framebuffer: unknown scaling mode")
    if mode ~= self.scaling then
        self.scaling = mode
        self._all_stale = true
    end
end

--- @treturn number, number plane size in remote pixels
function Remote:get_size()
    return self.w, self.h
end

--- @treturn number screen pixels per remote pixel
function Remote:get_scale()
    return self.scale
end

--- Zero-copy sub-window of the plane (shares its stride). The caller must not free it.
function Remote:viewport(x, y, w, h)
    return self:get_plane():viewport(x, y, w, h)
end

local function drop_canvas(self)
    if self._canvas_bb then
        self._canvas_bb:free()
        self._canvas_bb = nil
    end
    if self._dither_bb then
        self._dither_bb:free()
        self._dither_bb = nil
    end
    self._dither_ok = false
    self._filled = nil
end

--[[--
Replaces the plane with one of the new size and re-fits the view.

The same size again (a reconnect, a DesktopSize that changes nothing) is not a new desktop: the
plane and the view - a numeric zoom and where it looks - are kept, the view only re-clamped, and
everything is marked stale for the full update that follows.
]]
function Remote:resize(w, h)
    if w == self.w and h == self.h and self.plane then
        self:mark_dirty()
        if self.cw and self.ch and self.cw > 0 and self.ch > 0 then self:_clamp() end
        return
    end
    self.plane:free()
    self.plane = BB.new(w, h, BB.TYPE_BBRGB24)
    self.w, self.h = w, h
    self:mark_dirty()
    if self.cw and self.ch and self.cw > 0 and self.ch > 0 then
        self:fit_view(self.cw, self.ch)
    else
        self.scale, self.view_x, self.view_y = 1, 0, 0
    end
end

--[=[--
Tells the view which area (screen pixels) it has, and re-places it inside.

@{Remote:draw_to} does this implicitly for every frame; this is for the paths that change the
available space without painting (a zoom change, the on-screen keyboard appearing or going away,
a rotation), so that the view is placed - and clamped - against the space it actually has.
]=]
function Remote:set_canvas(cw, ch)
    self.cw, self.ch = cw, ch
    self:_clamp()
end

--- Frees the plane and the canvas buffer.
function Remote:free()
    drop_canvas(self)
    if self.plane then
        self.plane:free()
        self.plane = nil
    end
end

--- Keeps the view inside the plane (centring it when the plane is smaller than the canvas).
function Remote:_clamp()
    local cw, ch = self.cw, self.ch
    local span_x = cw / self.scale
    local span_y = ch / self.scale
    if self.w <= span_x then
        self.view_x = (self.w - span_x) / 2
    else
        self.view_x = math.max(0, math.min(self.view_x, self.w - span_x))
    end
    if self.h <= span_y then
        self.view_y = (self.h - span_y) / 2
    else
        self.view_y = math.max(0, math.min(self.view_y, self.h - span_y))
    end
end

local function clamp_scale(s)
    return math.max(Remote.MIN_SCALE, math.min(Remote.MAX_SCALE, s))
end

--[[--
Scales the plane so the whole thing is visible in `cw` x `ch` and centres it.
]]
function Remote:fit_view(cw, ch)
    self.cw, self.ch = cw, ch
    self.scale = clamp_scale(math.min(cw / self.w, ch / self.h))
    self:_clamp()
end

--[[--
Sets an absolute scale, keeping the current view centre.
]]
function Remote:set_scale(s)
    local ns = clamp_scale(s)
    local cx = self.view_x + self.cw / (2 * self.scale)
    local cy = self.view_y + self.ch / (2 * self.scale)
    self.scale = ns
    self.view_x = cx - self.cw / (2 * ns)
    self.view_y = cy - self.ch / (2 * ns)
    self:_clamp()
end

--[[--
Pans by a screen-pixel delta (positive = content moves right/down).
--- @treturn bool whether the view moved (it stops at the plane's edges)
]]
function Remote:pan_by(dx, dy)
    local x, y = self.view_x, self.view_y
    self.view_x = self.view_x - dx / self.scale
    self.view_y = self.view_y - dy / self.scale
    self:_clamp()
    return self.view_x ~= x or self.view_y ~= y
end

--[[--
Multiplies the scale by `factor`, keeping the remote pixel under canvas `(sx, sy)` fixed.
]]
function Remote:zoom_at(sx, sy, factor)
    local rx = self.view_x + sx / self.scale
    local ry = self.view_y + sy / self.scale
    local ns = clamp_scale(self.scale * factor)
    self.scale = ns
    self.view_x = rx - sx / ns
    self.view_y = ry - sy / ns
    self:_clamp()
end

--[[--
Canvas coordinates -> remote coordinates, clamped to the plane.

Maps the canvas pixel's centre, which is the remote pixel the sharp mode draws there (and the
one nearest to what the smooth mode shows there).
--- @treturn number, number
]]
function Remote:screen_to_remote(sx, sy)
    local rx = math.floor(self.view_x + (sx + 0.5) / self.scale)
    local ry = math.floor(self.view_y + (sy + 0.5) / self.scale)
    rx = math.max(0, math.min(self.w - 1, rx))
    ry = math.max(0, math.min(self.h - 1, ry))
    return rx, ry
end

--- The view as the scaler draws it: at scale 1 the offset is rounded to whole pixels.
function Remote:_render_view()
    local s, vx, vy = self.scale, self.view_x, self.view_y
    if s == 1 then
        vx, vy = math.floor(vx + 0.5), math.floor(vy + 0.5)
    end
    return { x = vx, y = vy, scale = s }
end

--[[--
The remote area the canvas currently shows, expanded by a margin and clamped to the plane: what is
worth asking the server for. Whenever the whole plane is visible this is exactly the whole plane.
--- @tparam[opt=Remote.REQUEST_MARGIN] number margin_frac margin on each side, as a fraction of
---   the visible width (left/right) and height (top/bottom)
--- @treturn table `{x, y, w, h}` in remote coordinates
]]
function Remote:visible_remote_rect(margin_frac)
    margin_frac = margin_frac or Remote.REQUEST_MARGIN
    local view = self:_render_view()
    local span_x, span_y = self.cw / view.scale, self.ch / view.scale
    local mx, my = span_x * margin_frac, span_y * margin_frac
    local x0 = math.max(0, math.floor(view.x - mx))
    local y0 = math.max(0, math.floor(view.y - my))
    local x1 = math.min(self.w, math.ceil(view.x + span_x + mx))
    local y1 = math.min(self.h, math.ceil(view.y + span_y + my))
    return { x = x0, y = y0, w = math.max(0, x1 - x0), h = math.max(0, y1 - y0) }
end

--[[--
The canvas rect (relative to the canvas origin, clipped to the canvas) whose pixels depend on
any pixel of a remote rect, in the current view and scaling mode: what @{Remote:draw_to}
recomputes for it, and so what has to reach the screen when it changes.
--- @tparam table remote_rect `{x, y, w, h}` in remote coordinates
--- @treturn table|nil `{x, y, w, h}`, or nil when it is not visible
]]
function Remote:canvas_rect_for(remote_rect)
    return Scaler.dst_rect_for(remote_rect, self:_render_view(), self.cw, self.ch, self.scaling)
end

-- Canvas buffer types the scaler writes; anything else gets an RGB24 buffer and a converting blit.
local CANVAS_TYPES = { [BB.TYPE_BB8] = true, [BB.TYPE_BBRGB24] = true, [BB.TYPE_BBRGB32] = true }

--[[--
Draws the view into `bb` at `(cx, cy)`, using a canvas of `cw` x `ch`.

The scaled view lives in a persistent canvas-sized buffer of `bb`'s type, (re)allocated only when
the canvas size or that type changes. A change of view (pan, zoom), canvas size, scaling mode or
buffer recomputes the whole buffer; otherwise only the canvas pixels depending on the remote rects
marked by @{Remote:mark_dirty} are recomputed (none at all when nothing changed). The whole buffer
is then blitted, so the canvas area of `bb` is always fully painted (e.g. after a popup closed).

At scale 1 the view offset is rounded to whole pixels, so the canvas is a plain copy of the plane
(no filtering); that rounding gives exactly the pixel @{Remote:screen_to_remote} maps a tap to.

Dithered, the canvas is dithered into a second persistent buffer, again only where it was
recomputed (KOReader's ordered dither depends on the source position only, so this is exactly
what dithering the whole canvas would give), and that buffer is blitted as is.

Sets `last_recomputed_px` (canvas pixels rescaled) and, when dithering, `last_blit_ms` (the
dithering plus the blit).
--- @tparam BlitBuffer bb destination
--- @tparam boolean dither use the dithered blit (grey-screen screenshot path)
--- @treturn boolean whether the canvas area was painted
]]
function Remote:draw_to(bb, cx, cy, cw, ch, dither)
    self.last_recomputed_px, self.last_blit_ms = 0, nil
    if not self.plane or cw <= 0 or ch <= 0 then return false end
    self.cw, self.ch = cw, ch

    local btype = bb:getType()
    if not CANVAS_TYPES[btype] then btype = BB.TYPE_BBRGB24 end
    local canvas = self._canvas_bb
    if not (canvas and canvas:getWidth() == cw and canvas:getHeight() == ch and canvas:getType() == btype) then
        drop_canvas(self)
        canvas = BB.new(cw, ch, btype)
        self._canvas_bb = canvas
    end

    local view = self:_render_view()
    local s, vx, vy = view.scale, view.x, view.y
    local mode = self.scaling
    local f = self._filled
    local full, rects = false, nil
    if self._all_stale or not f or f.x ~= vx or f.y ~= vy or f.scale ~= s or f.mode ~= mode
            or f.plane ~= self.plane then
        Scaler.render(canvas, self.plane, view, { x = 0, y = 0, w = cw, h = ch }, mode)
        self._filled = { x = vx, y = vy, scale = s, mode = mode, plane = self.plane }
        self.last_recomputed_px = cw * ch
        full = true
    elseif #self._stale > 0 then
        rects = {}
        for _i, r in ipairs(self._stale) do
            local d = self:canvas_rect_for(r)
            if d then rects = Util.add_rect(rects, d) end
        end
        local px = 0
        for _i, d in ipairs(rects) do
            Scaler.render(canvas, self.plane, view, d, mode)
            px = px + d.w * d.h
        end
        self.last_recomputed_px = px
    end
    self._all_stale = false
    if #self._stale > 0 then self._stale = {} end

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
        bb:blitFrom(dbb, cx, cy, 0, 0, cw, ch)
        if t0 then self.last_blit_ms = time.to_ms(time.now() - t0) end
    else
        -- the canvas changes from here on without the dithered copy following it
        if full or rects then self._dither_ok = false end
        bb:blitFrom(canvas, cx, cy, 0, 0, cw, ch)
    end
    return true
end

return Remote
