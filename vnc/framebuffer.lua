--[[--
The remote framebuffer plane and the view transform that maps it onto the screen.

The plane is a `TYPE_BBRGB24` BlitBuffer holding the remote pixels 1:1 (that is the format
@{vnc.pxfmt} negotiates, so decoders write straight into it). The view transform is a
uniform `scale` (screen pixels per remote pixel) plus an offset `view_x, view_y` naming the
remote coordinate shown at the canvas' top-left corner.

What the view shows is kept in a persistent canvas-sized buffer (see @{Remote:draw_to}): a remote
update rescales only the canvas pixels that depend on the remote rects it changed
(@{vnc.scaler}), and every paint blits the whole buffer. The contrast of the picture
(@{Remote:set_contrast}) is applied on that plane-to-canvas step, so the plane always holds the
remote pixels as sent.

@module vnc.framebuffer
]]

local BB = require("ffi/blitbuffer")
local Renderer = require("vnc/renderer")
local Scaler = require("vnc/scaler")
local SharedMem = require("vnc/sharedmem")
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

-- A plane of `w` x `h`: in shared memory (worker processes write and read it) for a shared remote.
local function new_plane(self, w, h)
    if self.shared then
        local bytes = w * h * 3
        local ptr = SharedMem.alloc(bytes)
        self._plane_mem = { ptr = ptr, bytes = bytes }
        return SharedMem.bb(ptr, w, h, BB.TYPE_BBRGB24)
    end
    return BB.new(w, h, BB.TYPE_BBRGB24)
end

local function free_plane(self)
    if self._plane_mem then
        SharedMem.free(self._plane_mem.ptr, self._plane_mem.bytes)
        self._plane_mem = nil
    elseif self.plane then
        self.plane:free()
    end
    self.plane = nil
end

--[[--
Creates a plane of `width` x `height` remote pixels.
--- @tparam number width
--- @tparam number height
--- @tparam[opt] table opts `shared = true`: the plane lives in memory shared with forked
---   worker processes (see @{vnc.workers})
]]
function Remote.new(width, height, opts)
    local self = setmetatable({
        shared = opts and opts.shared or false,
        plane = nil,
        w = width,
        h = height,
        scale = 1,
        view_x = 0,
        view_y = 0,
        cw = width,     -- canvas size (screen pixels) the view was last fitted to
        ch = height,
        version = 0,    -- bumped whenever the plane may have changed
        scaling = "smooth",
        contrast = 1,       -- contrast factor of the picture as drawn (@{Remote:set_contrast})
        invert = false,     -- the picture is drawn inverted (@{Remote:set_invert})
        renderer = Renderer.new(), -- scales the plane into the canvas buffer, tone curve, dither
        _stale = {},        -- remote rects changed since _canvas_bb was last updated
        _all_stale = true,  -- the whole buffer must be recomputed
        _unplaced = true,   -- not yet placed in a canvas: the first one centres it
        last_recomputed_px = 0, -- canvas pixels the last draw_to rescaled
        last_blit_ms = nil,     -- the last draw_to's blit time, when it dithered
    }, Remote)
    self.plane = new_plane(self, width, height)
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

--[[--
Sets the contrast of the picture as it is drawn (`1`: as the server sent it).

The plane keeps the remote pixels untouched; the curve (@{vnc.scaler.contrast_lut}) is applied
where the canvas is computed from the plane, folded into the scaler's per-pixel conversion. So a
change needs no new update from the server: the whole canvas is recomputed from the plane on the
next paint, exactly like after a scaling-mode change. At neutral there is no curve at all.
--- @tparam number f
--- @treturn boolean whether it changed
]]
function Remote:set_contrast(f)
    if f == self.contrast then return false end
    self.contrast = f
    self.renderer:set_tone(f, self.invert)
    self._all_stale = true
    return true
end

--[[--
Draws the picture inverted (`255 - contrast(x)`, the same tone-curve step as the contrast) or as
it is. The plane is untouched; the whole canvas is recomputed on the next paint.
--- @tparam boolean on
--- @treturn boolean whether it changed
]]
function Remote:set_invert(on)
    on = on and true or false
    if on == self.invert then return false end
    self.invert = on
    self.renderer:set_tone(self.contrast, on)
    self._all_stale = true
    return true
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
    -- Not left pointing at freed memory should the allocation fail (BB.new asserts): without a
    -- plane nothing draws or decodes. Freed first, so a big desktop never needs both at once.
    free_plane(self)
    self.plane = new_plane(self, w, h)
    self.w, self.h = w, h
    self:mark_dirty()
    if self.cw and self.ch and self.cw > 0 and self.ch > 0 then
        self:fit_view(self.cw, self.ch)
    else
        self.scale, self.view_x, self.view_y = 1, 0, 0
        self._unplaced = true
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
    if self._unplaced then
        self._unplaced = false
        self:_centre()
    else
        self:_clamp()
    end
end

--- Frees the plane and the canvas buffer.
function Remote:free()
    self.renderer:free()
    free_plane(self)
end

--[[--
Keeps the view within reach of the plane: any plane point can be brought to the canvas centre,
and no further, so the plane can be panned past its edges (e.g. a corner moved to the middle of
the screen) but at least a quarter of the canvas still shows it.
]]
function Remote:_clamp()
    local hx = self.cw / self.scale / 2
    local hy = self.ch / self.scale / 2
    self.view_x = math.max(-hx, math.min(self.view_x, self.w - hx))
    self.view_y = math.max(-hy, math.min(self.view_y, self.h - hy))
end

--- Centres the plane in the canvas.
function Remote:_centre()
    self.view_x = (self.w - self.cw / self.scale) / 2
    self.view_y = (self.h - self.ch / self.scale) / 2
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
    self._unplaced = false
    self:_centre()
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
    if self._unplaced then
        self._unplaced = false
        self:_centre()
    else
        self:_clamp()
    end
end

--[[--
Sets the whole view at once: `scale` and the remote point `(x, y)` at the canvas' top-left corner
(a view saved earlier from `scale`, `view_x`, `view_y`), clamped like any other.
]]
function Remote:set_view(scale, x, y)
    self.scale = clamp_scale(scale)
    self.view_x, self.view_y = x, y
    self._unplaced = false
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
Worker mode: sends the view to the scale worker as `G <id> ...` unless it is the one last sent.
Each view id's canvas geometry (`"cw ch btype"`) is kept in `link.view_geoms`; the session sets
`link.canvas_geom` to the geometry of the last view the scale worker reported (`C`), i.e. the
layout the shared canvas memory holds.
--- @treturn string the geometry this paint needs
]]
function Remote:_send_view(link, cw, ch, btype, dither, srot, sinv)
    local v = self:_render_view()
    local key = string.format("%.17g %.17g %.17g %d %d %d %d %s %.17g %d", v.scale, v.x, v.y, cw, ch,
        btype, dither and 1 or 0, self.scaling, self.contrast, self.invert and 1 or 0)
    local geom = string.format("%d %d %d", cw, ch, btype)
    if srot ~= 0 or sinv ~= 0 then
        -- the canvas in the screen's physical layout (see @{Remote:draw_to})
        key = key .. string.format(" %d %d", srot, sinv)
        geom = geom .. string.format(" %d %d", srot, sinv)
    end
    if key ~= link.view_key then
        link.view_id = (link.view_id or 0) + 1
        link.view_key, link.view_cw, link.view_ch = key, cw, ch
        link.view_geoms = link.view_geoms or {}
        link.view_geoms[link.view_id] = geom
        link.scale:send("G " .. link.view_id .. " " .. key)
    end
    return geom
end

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

While worker processes run (`worker_link`, see @{vnc.workers}) nothing is scaled here: a view
(scale, offset, canvas size and type, dithering, scaling mode, contrast, inversion) other than the
one last sent goes to the scale worker as a `G` message with a new id, and the shared canvas the
workers keep is blitted as it is. The canvas rects the scale worker then reports for that id are
repainted by the session's poll (@{vnc.session}).
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
    local link = self.worker_link
    if link then
        -- A rotated or inverted screen gets the canvas in its physical layout from the scale
        -- worker (which does the rotating blit on its own core): the blit here is then a plain
        -- copy of physical rows. Only for a destination of the canvas type itself.
        local srot, sinv = 0, 0
        if bb:getType() == btype and not Remote.NO_NATIVE then srot, sinv = bb:getRotation(), bb:getInverse() end
        local geom = self:_send_view(link, cw, ch, btype, dither, srot, sinv)
        -- the in-process canvas buffer is out of date: should the workers stop, the next paint
        -- here recomputes all of it
        self._all_stale = true
        if #self._stale > 0 then self._stale = {} end
        if link.canvas_geom ~= geom then
            -- The shared memory still holds a render of another size or type: read with this
            -- geometry it would be garbage. The canvas area keeps what the screen shows (black
            -- when nothing was drawn there yet) until the scale worker's `C` for this geometry
            -- makes the session repaint it.
            if not self._canvas_painted then
                bb:paintRect(cx, cy, cw, ch, BB.COLOR_BLACK)
                self._canvas_painted = true
            end
            return true
        end
        local t0 = Util.timing_enabled() and time.now()
        local pw, ph = cw, ch
        if srot % 2 == 1 then pw, ph = ch, cw end
        local cb = link.canvas_bb
        if not (cb and cb:getWidth() == pw and cb:getHeight() == ph and cb:getType() == btype) then
            cb = SharedMem.bb(link.canvas_mem.ptr, pw, ph, btype)
            link.canvas_bb = cb
        end
        if srot ~= 0 or sinv ~= 0 then
            -- unrotated, uninverted view of the destination's memory, and the canvas' physical rect
            local px, py, ppw, pph = bb:getPhysicalRect(cx, cy, cw, ch)
            local view = BB.new(bb.w, bb.h, btype, bb.data, bb.stride, bb.pixel_stride)
            view:blitFrom(cb, px, py, 0, 0, ppw, pph)
        else
            bb:blitFrom(cb, cx, cy, 0, 0, cw, ch)
        end
        if t0 then self.last_blit_ms = time.to_ms(time.now() - t0) end
        self._canvas_painted = true
        return true
    end
    local renderer = self.renderer
    renderer:render(self.plane, self:_render_view(), self.scaling, cw, ch, btype, dither,
        self._stale, self._all_stale)
    self.last_recomputed_px = renderer.last_recomputed_px
    self._all_stale = false
    if #self._stale > 0 then self._stale = {} end

    if dither then
        local t0 = Util.timing_enabled() and time.now()
        bb:blitFrom(renderer:canvas(), cx, cy, 0, 0, cw, ch)
        if t0 then self.last_blit_ms = time.to_ms(time.now() - t0) + (renderer.last_dither_ms or 0) end
    else
        bb:blitFrom(renderer:canvas(), cx, cy, 0, 0, cw, ch)
    end
    return true
end

return Remote
