--[[--
The full-screen viewer widget.

The remote framebuffer owns the whole screen; the on-screen keyboard is drawn *over* it
(KOReader stacks it above us), so showing the keyboard never rescales the view — pan it if part
of the remote desktop ends up behind the keyboard. A compact toolbar (`vnc.toolbar`) floats at the
top; a **swipe down** in KOReader's own top screen zone (the `DTAP_ZONE_MENU` area) shows or hides
it, and a tap on the bar never reaches the remote. Everywhere else taps are *never* taken away from
the remote desktop. What a tap, a long press and a one-finger drag do depends on the pointer mode:
Touch acts at the finger, Mouse moves a pointer relatively (a tap's click is deferred by the
double-tap interval so a double-tap-and-move can drag); two-finger drag, pinch/spread and
two-finger tap behave the same in both. Rotations and screen resizes go through KOReader's generic
`SetRotationMode` / `ScreenResize` events, so that the keyboard is re-laid out for the new
dimensions as well.

It is a plain (non-modal) full-screen `InputContainer` flagged `is_always_active`, so that it
keeps receiving gestures even while one of its own popups is on top — hence the
`_input_target()` / `_modal_above()` guards on every canvas gesture.

@module vnc.app
]]

local bit = require("bit")
local _ = require("gettext")

local BD = require("ui/bidi")
local BB = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Notification = require("ui/widget/notification")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")

local Keyboard = require("vnc/keyboard")
local Keysyms = require("vnc/keysyms")
local Reconnect = require("vnc/reconnect")
local Settings = require("vnc/settings")
local Toolbar = require("vnc/toolbar")
local Util = require("vnc/util")

local Screen = Device.screen

local band = bit.band

local ViewerApp = InputContainer:extend{
    id = "vnc_app",
    name = "VNCApp",
    covers_fullscreen = true, -- UIManager skips painting the widgets underneath us
    modal = false,            -- the keyboard and our dialogs stack above us normally
    disable_double_tap = true,
    is_always_active = true,
    dimen = nil,              -- set in init()
}

-- Seconds without two-finger movement after which the view counts as settled even when the
-- gesture's release never arrived (see `_view_move`).
ViewerApp.VIEW_SETTLE = 0.3

-- ---------------------------------------------------------------- init

function ViewerApp:init()
    self.settings = self.plugin.settings.data.settings
    self.dimen = Screen:getSize()
    self.remote = self.session:get_remote()
    self.canvas = nil
    self.vk_visible = false
    self.vk_wanted = false           -- the user's wish, independent of what is on top of us
    self._needs_flash = false        -- the next remote frame must be flashed, not blitted region by region
    self._keyboard_sync_pending = false
    self._keyboard_watch_pending = false
    self.vk = Keyboard.new(self.session, function() self:on_keyboard_height_changed() end,
        function(keysym) self:send_osk_key(keysym) end)
    self._drag_active = nil
    self._last_pinch_factor = nil
    self._zoom_start_span = nil
    self._vk_screen = self:_screen_signature()
    -- true while a two-finger pan/zoom moves the view: the visible area is reported once it ends
    self._view_moving = false
    self._view_settle_task = function() self:_view_settled() end
    -- the toolbar toggle: a two-finger drag scrolls the remote instead of moving the view; off on
    -- every open, never stored
    self.scroll_lock = false
    -- Mouse mode: a tap's click waits out the double-tap interval (see `_mouse_tap`)
    self._deferred_click = nil
    self._deferred_click_task = function() self:_flush_deferred_click() end
    -- shown on open, so it is discoverable; a swipe down in the top zone hides it
    self.toolbar = Toolbar:new{ app = self }
    self.toolbar_visible = true
    -- the box that retries a dropped connection (see `on_session_error`)
    self.reconnect = Reconnect.new(self)

    self:init_menu_zones()
    self:init_gestures()
    self:_reflow()
end

function ViewerApp:_screen_signature()
    local size = Screen:getSize()
    return string.format("%dx%d", size.w, size.h)
end

-- ---------------------------------------------------------------- toolbar activation

--[[--
Registers the "show/hide the toolbar" gesture: a **swipe down** inside KOReader's own top menu
zone (`DTAP_ZONE_MENU`, plus its taller middle extension).

Taps are deliberately *not* registered: every single tap must stay a click on the remote
desktop, so the top zone is only taken away from the canvas for that one swipe. This also
ignores KOReader's global *activate menu on* preference on purpose. The menu itself is reached
from the toolbar's More button or the Menu key.
]]
function ViewerApp:init_menu_zones()
    if not Device:isTouchDevice() then return end
    local function zone_ratios(geom)
        return { ratio_x = geom.x, ratio_y = geom.y, ratio_w = geom.w, ratio_h = geom.h }
    end
    local zone = G_defaults:readSetting("DTAP_ZONE_MENU") or { x = 0, y = 0, w = 1, h = 1 / 8 }
    local zone_ext = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
        or { x = 1 / 4, y = 0, w = 1 / 2, h = 1 / 5 }

    self:registerTouchZones({
        {
            id = "vnc_toolbar_swipe",
            ges = "swipe",
            screen_zone = zone_ratios(zone),
            handler = function(ges) return self:onTopSwipe(ges) end,
        },
        {
            id = "vnc_toolbar_swipe_ext",
            ges = "swipe",
            screen_zone = zone_ratios(zone_ext),
            overrides = { "vnc_toolbar_swipe" },
            handler = function(ges) return self:onTopSwipe(ges) end,
        },
    })
end

--- A swipe down in the top menu zone shows or hides the toolbar; anything else falls through to
--- the canvas. A swipe that ends one of our drags is that drag's end, not a request for the bar.
function ViewerApp:onTopSwipe(ges)
    local dragging = self._drag_active or self._mouse_moving
    self:_end_quick_drag(ges)
    if dragging or not self:_input_target() then return nil end
    if BD.flipDirectionIfMirroredUILayout(ges.direction) ~= "south" then return nil end
    self:toggle_toolbar()
    return true
end

--- Shows or hides the toolbar, repainting only its area.
function ViewerApp:set_toolbar_visible(on)
    on = on and true or false
    if on == self.toolbar_visible then return end
    self.toolbar_visible = on
    local area = self.toolbar.dimen
    UIManager:setDirty(self, function() return "ui", area end)
end

function ViewerApp:toggle_toolbar()
    self:set_toolbar_visible(not self.toolbar_visible)
end

--- Rebuilds the toolbar (mode label, scroll buttons) and repaints the area it covered before and
--- covers now.
function ViewerApp:_toolbar_changed()
    local old = self.toolbar.dimen
    self.toolbar:relayout()
    if not self.toolbar_visible then return end
    local area = old:combine(self.toolbar.dimen)
    UIManager:setDirty(self, function() return "ui", area end)
end

-- Multi-finger gestures not named two_finger_*: the live zoom and its end.
local MULTI_FINGER = { pinch = true, spread = true, inward_pan = true, outward_pan = true }

--[[--
True when gesture `ges` belongs to the toolbar: it is up, nothing but our overlays is above us
(`_input_target`: under a popup the bar is covered, not live) and the gesture started on it. Never
while a drag or long press of ours is under way (its end is ours wherever the finger lifts), and
never for a swipe (the top-zone toggle, the end of a quick drag) or a multi-finger gesture: a pinch
or spread zooms the canvas wherever it is made.
]]
function ViewerApp:_toolbar_owns(ges)
    if not (self.toolbar_visible and self.toolbar and ges and ges.pos) then return false end
    if not self:_input_target() then return false end
    if self._drag_active or self._hold_active or self._mouse_moving then return false end
    local kind = ges.ges or ""
    if kind == "swipe" or kind:sub(1, 11) == "two_finger_" or MULTI_FINGER[kind] then return false end
    local rel = ges.relative or { x = 0, y = 0 }
    local start = Geom:new{ x = ges.pos.x - (rel.x or 0), y = ges.pos.y - (rel.y or 0), w = 0, h = 0 }
    return self.toolbar.dimen:contains(start)
end

--- Gestures that start on the toolbar go to it and nowhere else.
function ViewerApp:handleEvent(event)
    if event.handler == "onGesture" and self:_toolbar_owns(event.args and event.args[1]) then
        self.toolbar:handleEvent(event)
        return true
    end
    return InputContainer.handleEvent(self, event)
end

--- Opens the menu, or closes it when it is already open.
function ViewerApp:toggle_menu()
    if self.menu then
        self:close_menu()
    else
        self:open_menu()
    end
end

function ViewerApp:init_gestures()
    local function canvas_range() return self:canvas_geom() end
    -- The end of a drag or long press is ours wherever the finger lifts (over the key panel, or
    -- beside a view that does not fill the screen): the handlers only act on one we started.
    local function whole_screen() return Geom:new{ x = 0, y = 0, w = self.dimen.w, h = self.dimen.h } end
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = canvas_range } },
        Hold = { GestureRange:new{ ges = "hold", range = canvas_range } },
        HoldRelease = { GestureRange:new{ ges = "hold_release", range = whole_screen } },
        Pan = { GestureRange:new{ ges = "pan", range = canvas_range } },
        PanRelease = { GestureRange:new{ ges = "pan_release", range = whole_screen } },
        TwoFingerPan = { GestureRange:new{ ges = "two_finger_pan", range = canvas_range } },
        TwoFingerPanRelease = { GestureRange:new{ ges = "two_finger_pan_release", range = canvas_range } },
        InwardPan = { GestureRange:new{ ges = "inward_pan", range = canvas_range } },
        OutwardPan = { GestureRange:new{ ges = "outward_pan", range = canvas_range } },
        Pinch = { GestureRange:new{ ges = "pinch", range = canvas_range } },
        Spread = { GestureRange:new{ ges = "spread", range = canvas_range } },
        TwoFingerTap = { GestureRange:new{ ges = "two_finger_tap", range = canvas_range } },
        TwoFingerSwipe = { GestureRange:new{ ges = "two_finger_swipe", range = canvas_range } },
        -- a quick drag ends as a swipe wherever the finger lifts (see `onSwipe`)
        Swipe = { GestureRange:new{ ges = "swipe", range = whole_screen } },
    }
end

-- ---------------------------------------------------------------- layout

function ViewerApp:getSize()
    return self.dimen
end

--- Height of what covers the bottom of the screen: the on-screen keyboard (with the key strip on
--- top of it) while it is visible, else the "Send keys" panel while it is open (the keyboard makes
--- room for it), else 0.
function ViewerApp:_bottom_cover_height()
    if self.vk and self.vk_visible then
        local h = self.vk:getSize().h or 0
        if self.key_strip then h = h + self.key_strip.dimen.h end
        return h
    end
    if self.key_panel then return self.key_panel.dimen.h end
    return 0
end

--[=[--
The canvas: the area the framebuffer may be drawn in.

That is the whole widget -- the on-screen keyboard (or the "Send keys" panel, which works the same
way) is drawn *over* the framebuffer rather than shrinking it -- except when the whole remote
screen, at the current zoom, fits in the space the visible keyboard leaves. Then the view belongs
above the keyboard: spreading it over the full screen would hide part of it behind the keys and
gain nothing. The zoom itself never changes here; only where the very same view is placed.
]=]
function ViewerApp:_layout(x, y)
    x, y = x or 0, y or 0
    local size = self.dimen
    local kbd_h = self:_bottom_cover_height()
    if kbd_h > 0 and self.remote then
        local w, h = self.remote:get_size()
        local scale = self.remote:get_scale()
        local free_h = size.h - kbd_h
        -- the half pixel absorbs float error when a fit lands exactly on the edge
        if w * scale <= size.w + 0.5 and h * scale <= free_h + 0.5 then
            return Geom:new{ x = x, y = y, w = size.w, h = free_h }
        end
    end
    return Geom:new{ x = x, y = y, w = size.w, h = size.h }
end

--[[--
Fits the view for the zoom modes that are computed from the screen.

`"fit"` fills the screen; `"fit_with_keyboard"` fills the space the on-screen keyboard leaves,
so it follows the keyboard exactly like the viewer did before the keyboard stopped reflowing the
view. The fixed ratios are absolute and are left alone, so their scale never changes here (nor
with the keyboard).

Once the user has pinched or panned the view (`_user_view`), the fit is not re-applied: the
keyboard coming and going must not throw their zoom and pan away. That state lasts for the session
only (it is not stored) and ends with the next fit (`zoom_to`, `fit_to_screen`, a reflow).
--- @treturn boolean whether the current mode is one of the fitted ones
]]
function ViewerApp:_fit_zoom_mode()
    if not self.remote then return false end
    local size = self.dimen or Screen:getSize()
    local mode = self.settings.zoom_mode
    if self._user_view and (mode == "fit" or mode == "fit_with_keyboard") then return true end
    if mode == "fit" then
        self.remote:fit_view(size.w, size.h)
        return true
    elseif mode == "fit_with_keyboard" then
        self.remote:fit_view(size.w, size.h - self:_bottom_cover_height())
        return true
    end
    return false
end

--[[--
Recomputes the canvas and hands it to the view.

The canvas decides where a view that fits above the on-screen keyboard goes, so it has to be the
view's own idea of its space too - otherwise the next zoom change would be placed against the
full screen while the view lives in the space above the keyboard.
]]
function ViewerApp:update_canvas()
    self.canvas = self:_layout()
    if self.remote then
        self.remote:set_canvas(self.canvas.w, self.canvas.h)
    end
    return self.canvas
end

--- Recomputes the canvas and re-applies the fitted zoom modes.
function ViewerApp:_reflow()
    self.dimen = Screen:getSize()
    self._user_view = nil
    self:_fit_zoom_mode()
    self:update_canvas()
end

--[[--
Re-initialises the on-screen keyboard when the screen dimensions changed.

`VirtualKeyboard` derives its key sizes from `Screen:getWidth()` and builds a bottom-anchored
`BottomContainer` sized `Screen:getSize()` - both *at construction time*. Without this, a
rotation would leave the keyboard laid out (and positioned) for the previous orientation.
]]
function ViewerApp:_refresh_keyboard()
    if not self.vk then return end
    local signature = self:_screen_signature()
    if signature == self._vk_screen then return end
    self.vk:init()
    self._vk_screen = signature
    UIManager:setDirty(self.vk, "ui")
end

--[[--
KOReader's generic screen-size change notification (also broadcast by the device backends).
]]
function ViewerApp:onScreenResize(dimen)
    if dimen then self.dimen = dimen end
    -- the panel's height goes into the canvas: lay it out for the new size first
    if self.key_panel then self.key_panel:relayout() end
    self.toolbar:relayout()
    self:_reflow()
    self:_refresh_keyboard()
    -- the strip sits on the keyboard, re-laid out just above
    if self.key_strip then
        self:_place_key_strip()
        self:_reflow()
    end
    self:updateTouchZonesOnScreenResize(self.dimen)
    -- new geometry: the whole canvas changed, and nothing else here would refresh it
    self:_wholesale_change()
    return false
end

--[[--
KOReader's generic rotation entry point
(`UIManager:broadcastEvent(Event:new("SetRotationMode", mode))`).
]]
function ViewerApp:onSetRotationMode(mode)
    if mode == nil or mode == Screen:getRotationMode() then return nil end
    Screen:setRotationMode(mode)
    self:onScreenResize(Screen:getSize())
    UIManager:onRotation()
    return true
end

function ViewerApp:canvas_geom()
    if self.canvas then return self.canvas end
    local size = self.dimen or Screen:getSize()
    return Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
end

-- ---------------------------------------------------------------- paint

function ViewerApp:paintTo(bb, x, y)
    local timing = Util.timing_enabled()
    local t0 = timing and time.now()
    local size = self:getSize()
    self.canvas = self:_layout(x, y)
    if self.remote then
        -- the view's space has to match the canvas we are drawing into
        self.remote:set_canvas(self.canvas.w, self.canvas.h)
    end

    -- Read once per paint: Screen.bb is replaced on rotation/resize.
    local dither = Screen.bb:getType() == BB.TYPE_BB8 and Screen.sw_dithering or false
    if not self.remote then
        self.remote = self.session:get_remote()
    end
    if not self._view_moving then self:_sync_view_area() end
    local c = self.canvas
    if self.remote and self.remote:draw_to(bb, c.x, c.y, c.w, c.h, dither) then
        -- the canvas buffer covers its whole rect: black only around it
        local x1, y1 = x + size.w, y + size.h
        bb:paintRect(x, y, size.w, c.y - y, BB.COLOR_BLACK)
        bb:paintRect(x, c.y + c.h, size.w, y1 - c.y - c.h, BB.COLOR_BLACK)
        bb:paintRect(x, c.y, c.x - x, c.h, BB.COLOR_BLACK)
        bb:paintRect(c.x + c.w, c.y, x1 - c.x - c.w, c.h, BB.COLOR_BLACK)
    else
        bb:paintRect(x, y, size.w, size.h, BB.COLOR_BLACK)
    end
    if self.toolbar_visible then self.toolbar:paintTo(bb, x, y) end
    if timing then
        local r = self.remote
        local line = string.format("vnc-timing: paint ms=%.1f canvas=%dx%d scale=%s mode=%s recomputed_px=%d",
            time.to_ms(time.now() - t0), c.w, c.h, r and tostring(r.scale) or "-",
            r and r.scaling or "-", r and r.last_recomputed_px or 0)
        if r and r.last_blit_ms then
            line = line .. string.format(" blit_ms=%.1f", r.last_blit_ms)
        end
        logger.dbg(line)
    end
end

--[[--
Tells the session which remote area is on screen, so that zoomed-in update requests cover only
that (plus a margin). Called on every paint, which follows every view change; the session ignores
an unchanged area.
]]
function ViewerApp:_sync_view_area()
    local s = self.session
    if self.remote and s and s.set_view_area then
        s:set_view_area(self.remote:visible_remote_rect(s.REQUEST_MARGIN))
    end
end

--- A two-finger gesture is moving the view: hold the area reports until it settles (its release,
--- or `VIEW_SETTLE` seconds without movement, should the release never arrive).
function ViewerApp:_view_move()
    self._view_moving = true
    UIManager:unschedule(self._view_settle_task)
    UIManager:scheduleIn(ViewerApp.VIEW_SETTLE, self._view_settle_task)
end

--- The view stopped moving: report where it ended up.
function ViewerApp:_view_settled()
    UIManager:unschedule(self._view_settle_task)
    if not self._view_moving then return end
    self._view_moving = false
    self:_sync_view_area()
end

--[[--
Declares that the *whole* canvas changed at once: a new connection, a remote resize, a zoom, the
on-screen keyboard appearing or going away. Such a change needs a flashing full-screen refresh, not
the regional "ui" update a remote rectangle gets: on e-ink a partial waveform cannot render a
wholesale change, and KOReader's own promotion counter only ever promotes "partial"
(`UIManager:_refresh`), which a viewer drawing a live framebuffer must not use (on a REAGL Kindle
"partial" is the REAGL waveform, i.e. a flash per rectangle - c.f. ImageViewer's note on why it
uses "ui").

`_needs_flash` additionally flashes the *next* remote frame, which is the first one carrying the
new geometry's content; it is consumed by the first rectangle to arrive after the change.
]]
function ViewerApp:_wholesale_change()
    self._needs_flash = true
    -- A menu on top owns the screen; closing it flashes the view, which covers this change.
    if self.menu then return end
    UIManager:setDirty(self, "full")
end

--[[--
Repaints the parts of the canvas the remote rectangles landed on.

While a popup of ours is above us the plane is still written (the session decodes straight into
it), but the panel is left alone: the popup owns the screen, and the flash that closing it asks
for covers the whole canvas again.
--- @tparam table rect `{x, y, w, h}` in remote coordinates, or a list of such rectangles
]]
function ViewerApp:on_framebuffer_dirty(rect)
    if not self.canvas or not self.remote then return end
    if self:_modal_above() then
        -- Nothing of ours is visible: keep the plane current, and flash the next frame that is.
        self._needs_flash = true
        return
    end
    if self._needs_flash then
        -- One full-screen flash covers every rectangle of this batch.
        self._needs_flash = false
        UIManager:setDirty(self, "flashui")
        return
    end
    local rects = rect.x and { rect } or rect
    for _i, r in ipairs(rects) do
        -- exactly the canvas pixels the remote rect can change (filters reach past its edges)
        local d = self.remote:canvas_rect_for(r)
        if d then
            UIManager:setDirty(self, "ui", Geom:new{ x = self.canvas.x + d.x, y = self.canvas.y + d.y,
                w = d.w, h = d.h })
        end
    end
end

function ViewerApp:on_remote_resized()
    self:_reflow()
    self:_wholesale_change()
end

function ViewerApp:on_bell()
    -- A status blip at the top of the screen, not a dialog: it may share the screen with the
    -- keyboard. ("toast" is also what keeps KOReader stacking it above everything else.)
    UIManager:show(Notification:new{ text = _("Bell"), timeout = 1, toast = true })
end

function ViewerApp:onCloseWidget()
    -- never leave our own menu orphaned on the window stack
    self:close_menu()
    -- the reconnect loop lives with the open viewer only
    self.reconnect:stop()
    self:close_display_panel(true)
    self:close_help(true)
    -- nor the key panel, nor a modifier a drag still holds down on the remote (the session is
    -- still up here: leaving and disconnecting both close the viewer before they detach or drop it)
    self:_drop_key_panel()
    self:_drop_key_strip()
    self:_end_pointer_action()
    -- a click still waiting for a possible second tap is not worth sending any more
    self:_drop_deferred_click()
    if self._text_input_asserted then
        self._text_input_asserted = false
        Device:stopTextInput()
    end
    UIManager:unschedule(self._watch_keyboard_tick)
    self._keyboard_watch_pending = false
    UIManager:unschedule(self._view_settle_task)
    self._view_moving = false
    -- Take the keyboard down first: closing it queues a refresh of just its own area
    -- (VirtualKeyboard:onCloseWidget), and that regional request would otherwise be the last word
    -- on what the panel hears about - it even suppresses UIManager:_repaint's "something was
    -- painted but nothing was queued" fallback.
    if self.vk then
        self.vk:hideKeyboard()
        self.vk_visible = false
        self.vk_wanted = false
    end
    Keyboard.restore_layout()
    self.canvas = nil
    -- ...then hand the whole screen back ourselves: `UIManager:close` refreshes nothing on its own,
    -- a nil widget with no region means the full screen, and it merges with (and dominates) the
    -- keyboard's regional request. This is what makes the widgets underneath reach the panel.
    UIManager:setDirty(nil, "flashui")
end

-- ---------------------------------------------------------------- input plumbing

--- Widgets above us that are part of the viewer rather than popups over it: the on-screen
--- keyboard, the key strip on it, the "Send keys" panel, and toasts.
function ViewerApp:_is_overlay(w)
    return w.toast or w == self.vk or w == self.key_strip or w == self.key_panel
end

--[[--
True when no other widget is stacked above us, ignoring the virtual keyboard, the key panel and
toasts.

Without this guard a tap our own Menu does not consume would be forwarded to the server as
a pointer click.
]]
function ViewerApp:_input_target()
    local stack = UIManager._window_stack
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if w == self then return true end
        if not self:_is_overlay(w) then return false end
    end
    return false
end

--- True when a popup of ours (menu, dialog) is above us.
--- @tparam[opt] boolean except_key_popup do not count the long-press popup of one of our keyboard's
--- keys. It is no overlay for `_input_target` (modal: it must keep taps from the remote), but it
--- does not take the keyboard away either.
function ViewerApp:_modal_above(except_key_popup)
    local stack = UIManager._window_stack
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if w == self then return false end
        if not self:_is_overlay(w)
            and not (except_key_popup and self.vk and w.parent_key and w.parent_key.keyboard == self.vk) then
            return true
        end
    end
    return false
end

--- Canvas coordinates -> remote coordinates.
function ViewerApp:_to_remote(px, py)
    local c = self:canvas_geom()
    return self.remote:screen_to_remote(px - c.x, py - c.y)
end

--- Wheel notches sent per page-button press (wheel mode).
ViewerApp.WHEEL_NOTCHES = 3

function ViewerApp:send_pointer(x, y, mask)
    self._pointer_x, self._pointer_y = x, y
    self.session:send_pointer(x, y, mask)
end

--- Sends a key. A drag or long press of ours still pending (its release was eaten by the
--- on-screen keyboard or the menu) ends first, so its button and modifiers do not stay down.
function ViewerApp:send_key(keysym, down)
    self:_flush_deferred_click()
    self:_end_stale_pointer_action()
    self.session:send_key(keysym, down)
end

--- Ends a drag or long press whose release never reached us (see `_end_pointer_action`); no-op
--- when none is pending.
function ViewerApp:_end_stale_pointer_action()
    if self._drag_active or self._hold_active then
        self:_end_pointer_action()
    end
end

--- Where modifiers are armed: the key strip or the "Send keys" panel (never both up), or nil.
function ViewerApp:_armed_source()
    return self.key_strip or self.key_panel
end

--[[--
A canvas action (tap, long press, drag) begins: the modifiers armed on the key strip or the "Send
keys" panel go down now, before the pointer press, and are disarmed there - they are for this one
action only. `_release_action_mods` lets them go after the pointer release.
]]
function ViewerApp:_press_armed()
    self:_release_action_mods()
    local source = self:_armed_source()
    if not source then return end
    local keysyms = source:take_armed()
    if #keysyms == 0 then return end
    for _i, keysym in ipairs(keysyms) do
        self:send_key(keysym, true)
    end
    self._action_mods = keysyms
end

--- Releases the modifiers a canvas action holds (in reverse order); nothing when there are none.
function ViewerApp:_release_action_mods()
    local keysyms = self._action_mods
    if not keysyms then return end
    self._action_mods = nil
    for i = #keysyms, 1, -1 do
        self:send_key(keysyms[i], false)
    end
end

-- ---------------------------------------------------------------- canvas gestures

function ViewerApp:onTap(_, ges)
    if not self:_input_target() then return nil end
    if self:get_pointer_mode() == "mouse" then return self:_mouse_tap(ges) end
    self:_end_stale_pointer_action()
    local rx, ry = self:_to_remote(ges.pos.x, ges.pos.y)
    self:_press_armed()
    -- move, press, release: what a real mouse click looks like on the wire
    self:send_pointer(rx, ry, 0)
    self:send_pointer(rx, ry, 1)
    self:send_pointer(rx, ry, 0)
    self:_release_action_mods()
    return true
end

function ViewerApp:onPan(_, ges)
    if not self:_input_target() then return nil end
    if self._drag_active == "mouse" or self._mouse_moving
            or (self._drag_active == nil and self:get_pointer_mode() == "mouse") then
        return self:_mouse_pan(ges)
    end
    if self._drag_active == nil then
        self:_end_stale_pointer_action() -- a long press whose release never came
        -- A pan's `relative` is the accumulated delta since the first contact, so this
        -- recovers the exact press position without depending on `start_pos`.
        local rel = ges.relative or { x = 0, y = 0 }
        local rx, ry = self:_to_remote(ges.pos.x - rel.x, ges.pos.y - rel.y)
        -- armed modifiers stay down for the whole drag (Shift+drag selects, Alt+drag moves)
        self:_press_armed()
        self:send_pointer(rx, ry, 1)
        self._drag_active = true
        self:_pointer_action_changed()
    end
    local rx, ry = self:_to_remote(ges.pos.x, ges.pos.y)
    self:send_pointer(rx, ry, 1)
    return true
end

function ViewerApp:onPanRelease(_, ges)
    if self._mouse_moving then
        self._mouse_moving = nil
        return true
    end
    if self._drag_active == nil then return nil end
    local rx, ry
    if self._drag_active == "mouse" then
        rx, ry = self._pointer_x, self._pointer_y -- the button lets go where the pointer is
    else
        rx, ry = self:_to_remote(ges.pos.x, ges.pos.y)
    end
    self._drag_active = nil
    self:send_pointer(rx, ry, 0)
    self:_release_action_mods()
    self:_pointer_action_changed()
    return true
end

--[[--
A drag whose finger lifts within `ges_swipe_interval` of its last move ends as a swipe, not a
pan_release (GestureDetector's Contact:isSwipe): let go of the button and the modifiers at the
last pointer position. The swipe itself goes on to whatever else wants it (the top-zone toolbar
swipe, which ends the drag itself too, as it gets the swipe first and then ignores it).
]]
function ViewerApp:onSwipe(_, ges)
    self:_end_quick_drag(ges)
    return nil
end

--- Ends a drag of ours on the swipe that ended its contact (see `onSwipe`); no-op otherwise.
function ViewerApp:_end_quick_drag(ges)
    if ges and ges.ges == "swipe" then
        self._mouse_moving = nil
        if self._drag_active then self:_end_pointer_action() end
    end
end

function ViewerApp:onHold(_, ges)
    if not self:_input_target() then return nil end
    local mouse = self:get_pointer_mode() == "mouse"
    if mouse then self:_flush_deferred_click() end
    self:_end_stale_pointer_action()
    local rx, ry
    if mouse then
        rx, ry = self:_mouse_pointer_px()
    else
        rx, ry = self:_to_remote(ges.pos.x, ges.pos.y)
    end
    -- a long press is a right click: the armed modifiers go with it, like with a tap
    self:_press_armed()
    self:send_pointer(rx, ry, 4)
    self._hold_active = mouse and "mouse" or true
    self:_pointer_action_changed()
    return true
end

--- Lets go of the right click a long press of ours started - also when a popup came up on top in
--- the meantime or the finger lifted over the key panel: the button and the modifiers it took
--- would otherwise stay down on the remote.
function ViewerApp:onHoldRelease(_, ges)
    if not self._hold_active then return nil end
    local rx, ry
    if self._hold_active == "mouse" then
        rx, ry = self._pointer_x, self._pointer_y -- (Mouse mode: the finger is not the pointer)
    else
        rx, ry = self:_to_remote(ges.pos.x, ges.pos.y)
    end
    self._hold_active = nil
    self:send_pointer(rx, ry, 0)
    self:_release_action_mods()
    self:_pointer_action_changed()
    return true
end

--[[--
A second finger came down during a one-finger drag or long press. GestureDetector then turns the
contact into a two-finger gesture (Contact:handlePan with a buddy contact), and its lift is a
two_finger_pan_release (Contact:handlePanRelease), not the pan_release / hold_release the drag is
waiting for. Let go of the button and the modifiers now, before the two-finger gesture runs.
]]
function ViewerApp:_end_pointer_action()
    self._mouse_moving = nil
    if self._drag_active or self._hold_active then
        self._drag_active = nil
        self._hold_active = nil
        if self._pointer_x then
            self:send_pointer(self._pointer_x, self._pointer_y, 0)
        end
    end
    self:_release_action_mods()
    self:_pointer_action_changed()
end

--- The profile's pointer mode: "touch" (a tap clicks where it lands) or "mouse" (a drag moves a
--- cursor).
function ViewerApp:get_pointer_mode()
    local profile = self.session:get_profile()
    return profile and profile.pointer_mode == "mouse" and "mouse" or "touch"
end

--- Switches the pointer mode and stores it in the profile.
function ViewerApp:set_pointer_mode(mode)
    self:_flush_deferred_click()
    self:_end_pointer_action()
    local profile = self.session:get_profile()
    local stored = self.plugin:update_profile_fields(profile.name, { pointer_mode = mode })
    if not stored then
        -- the plugin did not (or could not) keep it: at least the live session follows
        profile.pointer_mode = mode
        self.session:set_profile(profile)
    end
end

--- Flips Touch <-> Mouse; the toolbar's Mode button follows. A tooltip says which one it is now
--- and where the help is.
function ViewerApp:toggle_pointer_mode()
    self:set_pointer_mode(self:get_pointer_mode() == "mouse" and "touch" or "mouse")
    self:_toolbar_changed()
    UIManager:show(Notification:new{
        text = self:get_pointer_mode() == "mouse" and _("Mouse mode \u{2014} long press for help")
            or _("Touch mode \u{2014} long press for help"),
    })
end

--- Shows the help page (the current pointer mode's gestures first), replacing one still up.
function ViewerApp:open_help()
    self:close_help(true)
    local viewer
    viewer = TextViewer:new{
        title = _("VNC viewer help"),
        text = require("vnc/help").text(self:get_pointer_mode()),
        justified = false,
        close_callback = function()
            if self.help == viewer then self.help = nil end
            self:_sync_keyboard_later()
        end,
    }
    self.help = viewer
    UIManager:show(viewer)
    self:_sync_keyboard_later()
    return viewer
end

function ViewerApp:close_help(quiet)
    local viewer = self.help
    if not viewer then return end
    self.help = nil
    UIManager:close(viewer)
    if not quiet then self:_sync_keyboard_later() end
end

--- Mouse-mode cursor speed: remote pixels per screen pixel dragged.
function ViewerApp:pointer_speed()
    return Settings.POINTER_SPEEDS[self.settings.pointer_speed] or 1.25
end

-- ---------------------------------------------------------------- mouse mode

--- Seconds a Mouse-mode click waits for a second tap or a drag: KOReader's double-tap interval.
function ViewerApp.mouse_click_delay()
    local gd = Device.input and Device.input.gesture_detector or require("device/gesturedetector")
    return time.to_s(gd.ges_double_tap_interval)
end

--- How near (screen pixels) a second tap or a drag's start must land to a pending tap to count
--- as its double tap.
local function double_tap_radius() return Screen:scaleByDPI(50) end

--[[--
The Mouse-mode pointer, in remote coordinates (floats, so that slow drags add up). It starts from
the last pointer event sent, or the centre of the remote screen, follows a pointer event sent
from elsewhere (a Touch-mode action before a mode switch), and is kept inside the remote screen,
which may have shrunk since.
]]
function ViewerApp:_mouse_pointer()
    local w, h = self.remote:get_size()
    local x, y = self._mouse_x, self._mouse_y
    if not x or (self._pointer_x and (self._pointer_x ~= math.floor(x + 0.5)
                                      or self._pointer_y ~= math.floor(y + 0.5))) then
        x, y = self._pointer_x, self._pointer_y
        if not x then x, y = w / 2, h / 2 end
    end
    x, y = math.max(0, math.min(x, w - 1)), math.max(0, math.min(y, h - 1))
    self._mouse_x, self._mouse_y = x, y
    return x, y
end

--- The Mouse-mode pointer in whole remote pixels.
function ViewerApp:_mouse_pointer_px()
    local x, y = self:_mouse_pointer()
    return math.floor(x + 0.5), math.floor(y + 0.5)
end

--- Clicks `n` times at the Mouse-mode pointer, the armed modifiers held around all of them.
function ViewerApp:_mouse_click(n)
    local x, y = self:_mouse_pointer_px()
    self:_press_armed()
    for _i = 1, n do
        self:send_pointer(x, y, 0)
        self:send_pointer(x, y, 1)
        self:send_pointer(x, y, 0)
    end
    self:_release_action_mods()
end

--- Sends the click a Mouse-mode tap left pending now; no-op when there is none.
function ViewerApp:_flush_deferred_click()
    if not self._deferred_click then return end
    self:_drop_deferred_click()
    self:_mouse_click(1)
end

--- Forgets the click a Mouse-mode tap left pending, without sending it.
function ViewerApp:_drop_deferred_click()
    self._deferred_click = nil
    UIManager:unschedule(self._deferred_click_task)
end

--- Whether a screen position is near enough to the pending tap to make a double tap with it.
function ViewerApp:_near_deferred_click(pos)
    local pending = self._deferred_click
    return pending ~= nil and pending.pos:distance(pos) <= double_tap_radius()
end

--[[--
Mouse-mode tap: the click goes to the pointer, not the finger, and waits out the double-tap
interval - a drag starting there in the meantime turns it into a button drag (`_mouse_pan`)
instead, so the remote never sees click-then-press. A second tap there is a double click, at once.
]]
function ViewerApp:_mouse_tap(ges)
    self:_end_stale_pointer_action()
    if self:_near_deferred_click(ges.pos) then
        self:_drop_deferred_click()
        self:_mouse_click(2)
        return true
    end
    self:_flush_deferred_click()
    self._deferred_click = { pos = ges.pos:copy() }
    UIManager:scheduleIn(ViewerApp.mouse_click_delay(), self._deferred_click_task)
    return true
end

--[[--
Mouse-mode one-finger drag: moves the pointer by the finger's movement, converted to remote
pixels through the zoom and times the pointer speed. Starting where a tap is still pending
(double tap & move), it drags with the left button held instead, from the pointer.
]]
function ViewerApp:_mouse_pan(ges)
    local rel = ges.relative or { x = 0, y = 0 }
    -- (`relative` is the delta since the contact began, so this is where its finger came down)
    local start = Geom:new{ x = ges.pos.x - rel.x, y = ges.pos.y - rel.y }
    -- a move whose pan_release never came has its own start: a new contact is a new gesture
    if self._mouse_moving and self._mouse_start:distance(start) > 1 then
        self._mouse_moving = nil
    end
    if self._drag_active == nil and not self._mouse_moving then
        self:_end_stale_pointer_action()
        if self:_near_deferred_click(start) then
            self:_drop_deferred_click()
            -- armed modifiers stay down for the whole drag, as in Touch mode
            self:_press_armed()
            local x, y = self:_mouse_pointer_px()
            self:send_pointer(x, y, 1)
            self._drag_active = "mouse"
            self:_pointer_action_changed()
        else
            self:_flush_deferred_click()
            self._mouse_moving = true
        end
        self._mouse_start = start
        self._mouse_rel = { x = 0, y = 0 }
    end
    local prev = self._mouse_rel
    self._mouse_rel = { x = rel.x, y = rel.y }
    local k = self:pointer_speed() / self.remote:get_scale()
    local x, y = self:_mouse_pointer()
    local w, h = self.remote:get_size()
    self._mouse_x = math.max(0, math.min(x + (rel.x - prev.x) * k, w - 1))
    self._mouse_y = math.max(0, math.min(y + (rel.y - prev.y) * k, h - 1))
    self:send_pointer(math.floor(self._mouse_x + 0.5), math.floor(self._mouse_y + 0.5),
        self._drag_active == "mouse" and 1 or 0)
    return true
end

--- Whether a canvas action still holds something down on the remote: a drag's or long press's
--- button, or the modifiers it took.
function ViewerApp:has_pointer_action()
    return (self._drag_active or self._hold_active or self._action_mods) and true or false
end

--- A drag or long press began or ended: the key panel's "Release all" follows.
function ViewerApp:_pointer_action_changed()
    if self.key_panel then self.key_panel:pointer_action_changed() end
end

--[[--
The movement of the two-finger drag that started at `start` since its previous event, given its
offset `rel` from that start: GestureDetector reports `relative` from where the gesture began, on
every move (a new start point is a new gesture). Nil once the drag was ended early (a scroll lock
toggle, see `toggle_scroll_lock`): the rest of it does nothing.
]]
function ViewerApp:_two_finger_move(start, rel)
    rel = rel or { x = 0, y = 0 }
    local sx, sy = start and start.x, start and start.y
    local g = self._two_finger_pan
    if not g or g.sx ~= sx or g.sy ~= sy then
        -- `wx`, `wy`: the scroll-lock movement not yet turned into wheel notches
        g = { sx = sx, sy = sy, x = 0, y = 0, wx = 0, wy = 0 }
        self._two_finger_pan = g
    end
    if g.ended then return nil end
    local dx, dy = rel.x - g.x, rel.y - g.y
    g.x, g.y = rel.x, rel.y
    return dx, dy
end

--- Where scroll-lock notches go: the mouse pointer in Mouse mode, the fingers (`pos`) in Touch
--- mode (nil: the last pointer position, see `scroll_wheel`).
function ViewerApp:_wheel_position(pos)
    if self:get_pointer_mode() == "mouse" then return self:_mouse_pointer_px() end
    if pos then return self:_to_remote(pos.x, pos.y) end
end

--[[--
Scroll lock: turns the drag's movement into wheel notches, one per tenth of the screen height
(vertically) or width (sideways); what is left over waits for the next move. The content follows
the fingers, as on a phone: fingers going up scroll down, going left scroll right.
]]
function ViewerApp:_scroll_by_drag(dx, dy, pos)
    local g = self._two_finger_pan
    g.scrolled = true
    g.wx, g.wy = g.wx + dx, g.wy + dy
    -- whole steps, towards zero (the epsilon keeps an exact multiple of a fractional step whole)
    local function steps(v, step)
        local n = math.floor(math.abs(v) / step + 1e-9)
        return v < 0 and -n or n
    end
    local step_y, step_x = Screen:getHeight() / 10, Screen:getWidth() / 10
    local ny, nx = steps(g.wy, step_y), steps(g.wx, step_x)
    if ny == 0 and nx == 0 then return end
    g.wy, g.wx = g.wy - ny * step_y, g.wx - nx * step_x
    self:_flush_deferred_click()
    local x, y = self:_wheel_position(pos)
    if ny ~= 0 then self:scroll_wheel(ny < 0 and 1 or -1, math.abs(ny), false, x, y) end
    if nx ~= 0 then self:scroll_wheel(nx < 0 and 1 or -1, math.abs(nx), true, x, y) end
end

function ViewerApp:onTwoFingerPan(_, ges)
    self:_end_pointer_action()
    if not self:_input_target() then return nil end
    local dx, dy = self:_two_finger_move(ges.start_pos, ges.relative)
    if not dx then return true end
    if self.scroll_lock then
        self:_scroll_by_drag(dx, dy, ges.pos)
        return true
    end
    -- the picture follows the fingers, like any touch scroll
    self.remote:pan_by(dx, dy)
    self._user_view = true
    self:_view_move()
    UIManager:setDirty(self, "fast")
    return true
end

function ViewerApp:onTwoFingerPanRelease(_, ges)
    self:_end_pointer_action()
    local g = self._two_finger_pan
    self._two_finger_pan = nil
    -- a scroll moved nothing here, and an early-ended pan was settled when it ended
    if g and (g.scrolled or g.ended) then return true end
    self:_view_settled()
    UIManager:setDirty(self, "ui")
    return true
end

--[[--
Turns scroll lock on or off (the toolbar toggle, drawn inverted while on). A two-finger drag under
way ends here: whatever is left of it neither moves the view nor scrolls.
]]
function ViewerApp:toggle_scroll_lock()
    self.scroll_lock = not self.scroll_lock
    local g = self._two_finger_pan
    if g and not g.ended then
        g.ended = true
        if self._view_moving then
            self:_view_settled()
            UIManager:setDirty(self, "ui")
        end
    end
    self:_toolbar_changed()
end

function ViewerApp:_live_zoom(ges)
    self:_end_pointer_action()
    if not self:_input_target() then return nil end
    local span = ges.span or 0
    local start_span = ges.start_span or 0
    if start_span <= 0 then return nil end
    if self._zoom_start_span ~= start_span then
        -- a new two-finger drag
        self._zoom_start_span = start_span
        self._last_pinch_factor = 1
    end
    local factor = span / start_span
    local step = factor / (self._last_pinch_factor or factor)
    self._last_pinch_factor = factor
    if step <= 0 then return nil end
    self.remote:zoom_at(ges.pos.x - self:canvas_geom().x, ges.pos.y - self:canvas_geom().y, step)
    self._user_view = true
    self:_view_move()
    UIManager:setDirty(self, "fast")
    return true
end

function ViewerApp:onInwardPan(_, ges) return self:_live_zoom(ges) end
function ViewerApp:onOutwardPan(_, ges) return self:_live_zoom(ges) end

function ViewerApp:onPinch()
    self:_end_pointer_action()
    self._last_pinch_factor = nil
    self._zoom_start_span = nil
    -- the new zoom may put the view above the keyboard (or back on the whole screen)
    self:update_canvas()
    self:_view_settled()
    self:_wholesale_change()
    return nil
end

function ViewerApp:onSpread()
    self:_end_pointer_action()
    self._last_pinch_factor = nil
    self._zoom_start_span = nil
    -- the new zoom may put the view above the keyboard (or back on the whole screen)
    self:update_canvas()
    self:_view_settled()
    self:_wholesale_change()
    return nil
end

--[[--
A quick two-finger drag ends as a flick (GestureDetector turns its two_finger_pan into a
two_finger_swipe when the fingers lift soon after moving): it only ends the view pan, the way
two_finger_pan_release does. With scroll lock on, the flick's movement past the drag's last event
still scrolls (a swipe reports its start as `pos` and its end as `end_pos`).
]]
function ViewerApp:onTwoFingerSwipe(_, ges)
    if self.scroll_lock and ges.pos and ges.end_pos and self:_input_target() then
        local rel = { x = ges.end_pos.x - ges.pos.x, y = ges.end_pos.y - ges.pos.y }
        local dx, dy = self:_two_finger_move(ges.pos, rel)
        if dx then self:_scroll_by_drag(dx, dy, ges.end_pos) end
    end
    self:onTwoFingerPanRelease(nil, ges)
    return true
end

--- Fits the picture to the screen (or to the space above the keyboard while it is up), centred.
function ViewerApp:fit_to_screen()
    self:zoom_to(self.vk_visible and "fit_with_keyboard" or "fit")
    self.plugin.settings:flush()
end

function ViewerApp:onTwoFingerTap(_, ges)
    self:_end_pointer_action()
    if not self:_input_target() then return nil end
    self:fit_to_screen()
    return true
end

-- ---------------------------------------------------------------- physical keyboard

--[[--
Makes sure the platform delivers *text*, not just key events.

SDL 3 only sends `SDL_EVENT_TEXT_INPUT` after `SDL_StartTextInput()` ("Text input events are not
received by default", c.f. SDL_keyboard.h), and KOReader calls it from `InputText`/`InputDialog`
only, i.e. never while this viewer is up. Without this, typing on a hardware keyboard would
produce key events we deliberately ignore (the characters belong to the text input stream) and
nothing would reach the remote at all.
]]
function ViewerApp:_ensure_text_input()
    if self._text_input_asserted then return end
    self._text_input_asserted = true
    Device:startTextInput()
end

--[[--
Re-asserts text input after one of our own popups closed: the connection editor (and any other
KOReader text field) pairs `startTextInput` with `stopTextInput`, and would leave it off.
]]
function ViewerApp:reassert_text_input()
    self._text_input_asserted = false
    self:_ensure_text_input()
end

function ViewerApp:onShow()
    self:_ensure_text_input()
    self:evaluate_keyboard()
    self:_watch_keyboard_state()
    -- A (re-)shown viewer is a wholesale change: whoever showed us may have passed no refreshtype
    -- (`UIManager:show` refreshes nothing by itself), and our first paint is the whole canvas.
    self:_wholesale_change()
    -- reopened on a connection that dropped while we were away: offer a Retry, but retry nothing
    -- by itself
    if self.session:get_state() == "error" and not self.reconnect:is_running() then
        self.reconnect:start{ auto = false }
    end
end

--- Back from sleep with the reconnect box up: retry at once instead of waiting out the backoff.
function ViewerApp:onResume()
    local state = self.session:get_state()
    if self.reconnect:is_running() and (state == "error" or state == "disconnected") then
        self.reconnect:retry_now()
    end
    -- (nil: everyone else still hears of the resume)
end

--[[--
True for the one key we keep for ourselves: KOReader's `Menu` key opens (and closes) our menu,
which is also how a keyboard-only device reaches it. Everything else is forwarded to the remote
desktop — including Escape/Back, which is what a VNC client is expected to do; leaving the
viewer with a keyboard is done from the menu.
]]
function ViewerApp:_is_menu_key(key)
    return key.key == "Menu"
end

--- True when `Back` means "leave the viewer" rather than "send Escape".
--- On a device without a keyboard there is no other way to get out, so it leaves there.
function ViewerApp:_back_leaves(key)
    return key.key == "Back" and not Device:hasKeyboard()
end

local PAGE_DIRECTION = { LPgFwd = 1, RPgFwd = 1, LPgBack = -1, RPgBack = -1 }

--- 1 for a page-forward key, -1 for page-back, nil for any other key.
function ViewerApp:_page_direction(key)
    return PAGE_DIRECTION[key.key]
end

--- The page key's direction when page buttons are set to scroll the wheel, else nil.
function ViewerApp:_wheel_direction(key)
    if self.settings.page_buttons ~= "wheel" then return nil end
    return self:_page_direction(key)
end

-- Wheel buttons as pointer masks: [horizontal][direction]. Vertical: 4 up, 5 down; horizontal:
-- 6 left, 7 right.
local WHEEL_MASK = { [false] = { [-1] = 8, [1] = 16 }, [true] = { [-1] = 32, [1] = 64 } }

--[[--
Scrolls the remote wheel (1 = down, -1 = up; `horizontal`: 1 = right, -1 = left), each notch a
press and release, at `x`, `y` on the remote, else the last pointer position, or at the centre of
the remote screen when no pointer event has been sent yet.
]]
function ViewerApp:scroll_wheel(direction, notches, horizontal, x, y)
    local w, h = self.remote:get_size()
    if not x then x, y = self._pointer_x, self._pointer_y end
    if not x then
        x, y = math.floor(w / 2), math.floor(h / 2)
    end
    -- the remote may have shrunk since the pointer was recorded
    x, y = math.max(0, math.min(x, w - 1)), math.max(0, math.min(y, h - 1))
    local mask = WHEEL_MASK[horizontal and true or false][direction > 0 and 1 or -1]
    self.session:note_input("wheel")
    for _ = 1, notches or ViewerApp.WHEEL_NOTCHES do
        self:send_pointer(x, y, mask)
        self:send_pointer(x, y, 0)
    end
end

function ViewerApp:onKeyPress(key)
    self:_ensure_text_input()
    -- a new press: whatever release was pending from the key that closed the panel is moot
    self._swallow_release = nil
    if self:_is_menu_key(key) then
        self:toggle_menu()
        return true
    end
    if self:_back_leaves(key) then
        self:on_back()
        return true
    end
    -- a key a popup of ours above us did not take is not for the remote
    if not self:_input_target() then return nil end
    local wheel = self:_wheel_direction(key)
    if wheel then
        self:scroll_wheel(wheel)
        return true
    end
    local keysym = Keysyms.special[key.key]
    if keysym then
        self:send_key(keysym, true)
        self._keys_down = self._keys_down or {}
        self._keys_down[keysym] = true
        return true
    end
    -- printable characters come through onTextInput, exactly once
    return nil
end

function ViewerApp:onKeyRelease(key)
    -- the release of the key that closed the key panel: its press never reached the remote
    if self._swallow_release and self._swallow_release == key.key then
        self._swallow_release = nil
        return true
    end
    if self:_is_menu_key(key) or self:_back_leaves(key) then return true end
    if self:_wheel_direction(key) then return true end
    local keysym = Keysyms.special[key.key]
    if keysym then
        -- a key pressed on the remote is always let go there, even if a popup opened meanwhile
        local down = self._keys_down
        if down and down[keysym] then
            down[keysym] = nil
        elseif not self:_input_target() then
            return nil
        end
        self:send_key(keysym, false)
        return true
    end
    return nil
end

--- Auto-repeat is just another key press as far as the remote is concerned.
function ViewerApp:onKeyRepeat(key)
    if self:_is_menu_key(key) or self:_back_leaves(key) then return true end
    if not self:_input_target() then return nil end
    local wheel = self:_wheel_direction(key)
    if wheel then
        self:scroll_wheel(wheel)
        return true
    end
    local keysym = Keysyms.special[key.key]
    if keysym then
        self:send_key(keysym, true)
        return true
    end
    return nil
end

function ViewerApp:onTextInput(text)
    if not self:_input_target() then return nil end
    for _, ch in ipairs(Util.split_chars(text)) do
        local codepoint = Keysyms.codepoint(ch)
        -- Control characters are what SDL delivers for Ctrl+letter; the modifier keydown
        -- was already forwarded, so sending these again would be wrong.
        if codepoint and codepoint >= 0x20 then
            local keysym = Keysyms.from_char(ch)
            if keysym then
                self:send_key(keysym, true)
                self:send_key(keysym, false)
            end
        end
    end
    return true
end

--- A key from the on-screen keyboard: with the modifiers armed on the key strip around it (and
--- them disarmed), like a strip key; else just its down and up.
function ViewerApp:send_osk_key(keysym)
    local strip = self.key_strip
    if strip and strip:has_armed() then
        strip:send_key(Keysyms.name_for_keysym(keysym) or "", keysym)
        return
    end
    self:send_key(keysym, true)
    self:send_key(keysym, false)
end

--- Types `text` on the remote, one key down/up per character ("\n" becomes Return). Characters
--- with no keysym are skipped.
--- @treturn number how many were skipped
function ViewerApp:send_text(text)
    local skipped = 0
    for _, ch in ipairs(Util.split_chars(text)) do
        local keysym = Keysyms.from_char(ch)
        if keysym then
            self:send_key(keysym, true)
            self:send_key(keysym, false)
        else
            skipped = skipped + 1
        end
    end
    return skipped
end

--- Presses `keysyms` together: downs in order, ups in reverse.
function ViewerApp:send_combo(keysyms)
    for i = 1, #keysyms do self:send_key(keysyms[i], true) end
    for i = #keysyms, 1, -1 do self:send_key(keysyms[i], false) end
end

--- Asks the server for the whole picture again and repaints the viewer in full.
function ViewerApp:refresh_remote()
    self.session:request_full_update()
    UIManager:setDirty(self, "full")
end

-- ---------------------------------------------------------------- keyboard

--- What the user asked for: the "keyboard always visible" setting, or their last manual choice.
function ViewerApp:is_keyboard_wanted()
    return self.settings.keyboard_always_visible or self.vk_wanted or false
end

--- The keyboard is only up while the framebuffer view owns the screen; a menu or dialog above it
--- takes the keyboard out of the way, and it comes back when that popup is gone.
function ViewerApp:_wanted_keyboard_visible()
    if self:_modal_above(true) then return false end
    -- the key panel sits where the keyboard would
    if self.key_panel then return false end
    return self:is_keyboard_wanted()
end

--- Applies the state implied by the setting, the user's wish and the window stack.
function ViewerApp:evaluate_keyboard()
    local want = self:_wanted_keyboard_visible()
    if want == self.vk_visible then
        -- The height may still have changed (layout switch); re-flow regardless.
        self:update_canvas()
        return
    end
    self.vk_visible = want
    if want then
        self:_end_stale_pointer_action()
        self.vk:showKeyboard()
        self:_show_key_strip()
    else
        self:_drop_key_strip()
        self.vk:hideKeyboard()
    end
    -- The keyboard decides what "fit (with keyboard)" fits into, and whether a view that fits
    -- above it is placed there. Fixed ratios keep their scale; a view too big for the space
    -- above the keyboard still spans the screen and is panned, as before.
    self:_fit_zoom_mode()
    self:update_canvas()
    self:_wholesale_change()
end

--- Asks for a keyboard state for as long as the framebuffer view is the topmost window.
function ViewerApp:set_keyboard_visible(want)
    self.vk_wanted = want and true or false
    self:evaluate_keyboard()
end

--[[--
The toolbar's keyboard button: shows the keyboard (with the key strip) when nothing is up, hides
it when it is up, and closes the "Send keys" panel when that is up, leaving nothing in its place.
Keeps the "always visible" setting in sync: that setting wins over the wish, so asking for the
keyboard to go away while it is on would silently do nothing.
]]
function ViewerApp:toggle_keyboard()
    local panel_open = self.key_panel ~= nil
    local want = not panel_open and not self:is_keyboard_wanted()
    if not want and self.settings.keyboard_always_visible then
        self.settings.keyboard_always_visible = false
        self.plugin.settings:flush()
    end
    if panel_open then
        self.vk_wanted = false
        self:close_key_panel() -- re-evaluates the keyboard, which stays down
    else
        self:set_keyboard_visible(want)
    end
end

--- How often the window stack is re-checked while the viewer is shown.
ViewerApp.KEYBOARD_WATCH_INTERVAL = 0.25

--- Re-evaluates the keyboard state on a short timer.
---
--- A popup opening above us cannot be noticed any other way: KOReader starts painting at the
--- topmost full-screen widget, so a widget shown *above* the viewer never repaints it (only
--- closing one dirties the widgets beneath). Popups we open ourselves notify us immediately;
--- this catches everything else (a message shown from outside the viewer, another plugin, ...).
function ViewerApp:_watch_keyboard_tick()
    self._keyboard_watch_pending = false
    if not UIManager:isWidgetShown(self) then return end
    if self.vk_visible ~= self:_wanted_keyboard_visible() then
        self:_sync_keyboard_later()
    end
    self:_watch_keyboard_state()
end

function ViewerApp:_watch_keyboard_state()
    if self._keyboard_watch_pending then return end
    self._keyboard_watch_pending = true
    UIManager:scheduleIn(ViewerApp.KEYBOARD_WATCH_INTERVAL, self._watch_keyboard_tick, self)
end

--- Deferred re-evaluation for the popup show/close paths (`_sync_keyboard_later`): by the time
--- the tick runs the window stack has settled.
function ViewerApp:_sync_keyboard_later()
    if self._keyboard_sync_pending then return end
    self._keyboard_sync_pending = true
    UIManager:nextTick(function()
        self._keyboard_sync_pending = false
        -- the viewer may have been left in the meantime: never bring a keyboard back on its own
        if not UIManager:isWidgetShown(self) then return end
        self:reassert_text_input()
        self:evaluate_keyboard()
    end)
end

--- The keyboard reports a new height (e.g. after a layout switch). It repaints itself; we
--- repaint the part of the canvas it used to cover.
function ViewerApp:on_keyboard_height_changed()
    -- A different layout (or a rotation) changes how much room the keyboard takes, which is what
    -- "fit (with keyboard)" fits into and whether a view fits above it.
    if self.key_strip then self:_place_key_strip() end
    self:_fit_zoom_mode()
    self:update_canvas()
    self:_wholesale_change()
end

-- ---------------------------------------------------------------- zoom / orientation

function ViewerApp:zoom_to(mode)
    self._user_view = nil
    self.settings.zoom_mode = mode
    if not self:_fit_zoom_mode() then
        self.remote:set_scale(mode)
    end
    -- the new scale may put the view above the keyboard (or back on the whole screen)
    self:update_canvas()
    self:_wholesale_change()
end

function ViewerApp:rotate(delta)
    self:choose_rotation(band(Screen:getRotationMode() + delta, 3))
end

--- A rotation the user asked for while the viewer is up: applied, and remembered as the
--- orientation the viewer opens in next time.
function ViewerApp:choose_rotation(mode)
    self:set_rotation_mode(mode)
    self.settings.orientation = mode
    self.plugin.settings:flush()
end

--- Asks for a new rotation mode, through KOReader's generic API, so that every widget
--- (including the on-screen keyboard, which we re-init in `onSetRotationMode`) follows.
function ViewerApp:set_rotation_mode(mode)
    if mode == nil or mode == Screen:getRotationMode() then return end
    UIManager:broadcastEvent(Event:new("SetRotationMode", mode))
end

--- Applies the remembered orientation (the last one used), remembering the previous mode.
function ViewerApp:apply_default_orientation(default_mode)
    self.prev_rotation = self.prev_rotation or Screen:getRotationMode()
    if default_mode == nil then default_mode = self.settings.orientation end
    self:set_rotation_mode(default_mode)
end

--- Restores the rotation mode that was active before we were shown.
function ViewerApp:restore_rotation()
    if self.prev_rotation == nil then return end
    local mode = self.prev_rotation
    self.prev_rotation = nil
    self:set_rotation_mode(mode)
end

-- ---------------------------------------------------------------- menu / lifecycle

function ViewerApp:open_menu()
    if self.menu then return self.menu end
    -- a pending Mouse-mode click belongs to the remote, before the menu covers it
    self:_flush_deferred_click()
    self.menu = require("vnc/menu").open(self)
    -- The menu is on the window stack now: it owns the screen, so the keyboard gets out of the
    -- way (it is part of the framebuffer view, not of the menu).
    self:evaluate_keyboard()
    return self.menu
end

--- Closes the in-app menu when it is open.
function ViewerApp:close_menu()
    if self.menu then
        local menu = self.menu
        self.menu = nil
        -- The menu owned the screen: ask for a full-screen flash, so the panel gets the framebuffer
        -- view back instead of keeping whatever the menu left (a menu is a wholesale change too).
        UIManager:close(menu, "flashui")
        -- `UIManager:close` does not run the menu's `close_callback`; hand the screen back to the
        -- framebuffer view (and its keyboard) ourselves.
        self:_sync_keyboard_later()
    end
end

--- Opens the display panel (see @{vnc.displaypanel}), or returns the one already open.
function ViewerApp:open_display_panel()
    if self.display_panel then return self.display_panel end
    self.display_panel = require("vnc/displaypanel").open(self)
    self:_sync_keyboard_later()
    return self.display_panel
end

--- Closes the display panel when it is open. `quiet` skips the keyboard re-evaluation, for a panel
--- that is about to be opened again in place.
function ViewerApp:close_display_panel(quiet)
    local panel = self.display_panel
    if not panel then return end
    self.display_panel = nil
    UIManager:close(panel)
    if not quiet then self:_sync_keyboard_later() end
end

--[[--
Switches the connection to quality preset `id`: reconnects with it and saves it into the stored
profile only once that connection succeeds. Until then the live session profile carries the
preset and the stored one keeps its values; a stop without success puts the stored values back.
]]
function ViewerApp:apply_quality_preset(id)
    local Settings = require("vnc/settings")
    local preset
    for _i, candidate in ipairs(Settings.QUALITY_PRESETS) do
        if candidate.id == id then preset = candidate end
    end
    local session = self.session
    local live = session:get_profile()
    local stored = preset and live and self.plugin.settings:get_profile(live.name)
    if not stored or Settings.preset_of(stored) == id or self.reconnect:is_running() then return end
    local name = stored.name
    local fields = {
        color_depth = preset.color_depth, enable_tight = preset.enable_tight,
        jpeg_quality = preset.jpeg_quality, compress_level = preset.compress_level,
    }
    self:close_display_panel()
    session:set_keep_wifi(true)
    session:hangup()
    local trial = {}
    for k, v in pairs(stored) do trial[k] = v end
    for k, v in pairs(fields) do trial[k] = v end
    session:set_profile(trial)
    self.reconnect:start{
        immediate = true, auto = true, message = "reconnecting",
        on_success = function() self.plugin:update_profile_fields(name, fields) end,
        on_stop = function() session:set_profile(self.plugin.settings:get_profile(name)) end,
    }
end

function ViewerApp:toggle_display_panel()
    if self.display_panel then
        self:close_display_panel()
    else
        self:open_display_panel()
    end
end

--- The panel went away by its own means (a tap outside, Back): forget it.
function ViewerApp:_display_panel_dismissed(panel)
    if self.display_panel == panel then self.display_panel = nil end
    self:_sync_keyboard_later()
end

--- Opens the "Send keys" panel (see @{vnc.keypanel}), or returns the one already open. It takes
--- the keyboard's place, and the modifiers armed on the key strip stay armed on it.
function ViewerApp:open_key_panel()
    if self.key_panel then return self.key_panel end
    local strip = self.key_strip
    local mods = {}
    if strip then
        for name, state in pairs(strip.mods) do mods[name] = state end
    end
    self.key_panel = require("vnc/keypanel"):new{ app = self, mods = mods }
    UIManager:show(self.key_panel, "ui")
    self:_bottom_cover_changed()
    return self.key_panel
end

--- Closes the key panel; a drag still under way lets go of the modifiers it took from it.
--- @tparam[opt] string key_name the KOReader key that closed it: its release is not forwarded
function ViewerApp:close_key_panel(key_name)
    if not self.key_panel then return end
    self:_drop_key_panel()
    self:_release_action_mods()
    self._swallow_release = key_name
    self:_bottom_cover_changed()
end

function ViewerApp:_drop_key_panel()
    local panel = self.key_panel
    if not panel then return end
    self.key_panel = nil
    UIManager:close(panel)
end

--- Shows the key strip on top of the keyboard (with it, in `evaluate_keyboard`).
function ViewerApp:_show_key_strip()
    if self.key_strip then return end
    self.key_strip = require("vnc/keypanel"):new{
        app = self,
        variant = "strip",
        bottom_offset = self.vk:getSize().h or 0,
    }
    UIManager:show(self.key_strip, "ui", self.key_strip.dimen)
end

--- Takes the key strip down (with the keyboard); whatever was armed on it is dropped.
function ViewerApp:_drop_key_strip()
    local strip = self.key_strip
    if not strip then return end
    self.key_strip = nil
    UIManager:close(strip, "ui", strip.dimen)
end

--- Re-lays the strip out right above the keyboard's current height, and repaints it there.
function ViewerApp:_place_key_strip()
    local strip = self.key_strip
    strip:set_bottom_offset(self.vk:getSize().h or 0)
    UIManager:setDirty(strip, "ui", strip.dimen)
end

--- The panel came or went: the keyboard follows (it makes room for the panel), and the view is
--- placed against the new free space, like it is for the keyboard.
function ViewerApp:_bottom_cover_changed()
    self:evaluate_keyboard()
    self:_fit_zoom_mode()
    self:update_canvas()
    self:_wholesale_change()
end

function ViewerApp:disconnect_session()
    self.plugin:disconnect_session(self.session:get_profile().name)
    -- a user-initiated disconnect lands on the connection list, not the file browser
    self.plugin:show_connection_list()
end

--[[--
The connection dropped: nothing stays down or armed (a reconnect must not carry a half-finished
action over to the new connection), our other popups go, and the reconnect box takes over. A failed
attempt of the running loop lands here too, and changes nothing.
]]
function ViewerApp:on_session_error(_err)
    if self.reconnect:is_running() then return end
    self:_end_pointer_action()
    self:_drop_deferred_click()
    local armed = self:_armed_source()
    if armed then armed:take_armed() end
    self:close_help(true)
    self:close_display_panel(true)
    self.reconnect:start{ auto = true }
end

--- Leaves the app, keeping the connection alive.
function ViewerApp:on_back()
    if self:_modal_above() then return nil end
    self:leave()
    return true
end

function ViewerApp:leave()
    logger.dbg("vnc: leaving the app, keeping the session")
    self.plugin:leave_app()
end

return ViewerApp
