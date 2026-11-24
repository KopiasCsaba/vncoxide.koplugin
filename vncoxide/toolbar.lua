--[[--
The viewer's toolbar: a compact bar floating over the remote, at the top centre until the user
drags it elsewhere.

Not a window of its own: the viewer paints it after the canvas and hands it the gestures that
start on it (`ViewerApp:_toolbar_owns`), so a tap on the bar never reaches the remote while the
canvas beside and below it stays fully interactive. A swipe down in the top menu zone shows or
hides it (`ViewerApp:toggle_toolbar`).

Buttons, left to right: Collapse (folds the bar into a small round button with the same icon, at
the same spot; a tap on that brings the bar back), Display (the display panel), Zoom (cycles fit ->
1:1 -> the user's own pinch/pan view -> fit, see `ViewerApp:cycle_zoom`; its icon shows the current
state: `zoom.page`, the plugin's `zoom-1to1`, `zoom.manual`), Mode (Touch/Mouse, the label shows the
current one), Keyboard (shows or hides the on-screen keyboard with the key strip, or closes the
"Send keys" panel), Scroll up/down, Brightness (KOReader's frontlight dialog; only on a device with
a frontlight), Contrast (the contrast dialog, @{vncoxide.contrastdialog}), Invert (a toggle, drawn inverted
while on: the remote picture drawn inverted), Close (disconnect, after a
confirmation) and More (the menu). All but Close and More can be hidden (`toolbar_buttons`, the
menu's "Toolbar buttons…"); by default only the scroll pair is.

Buttons can also be pinned to the collapsed toolbar (`toolbar_pinned`, the menu's "Toolbar
buttons… > Also when collapsed…"): then collapsing leaves a short bar, the expand button followed by
the pinned ones that the full bar shows, instead of the round button alone.

A long press on any button (and on the round one) shows a one-line tooltip and does nothing else.
A one-finger drag that starts on the bar (or the round button) moves it, clamped to the screen;
where it sits is stored as fractions of the free space (`toolbar_pos`), so it keeps its place over
rotations and resizes. One that starts on the Keyboard button instead drags a keyboard icon off it:
dropped on the remote it clicks there and brings the keyboard up (`ViewerApp:drop_keyboard_at`),
dropped anywhere else it does nothing.

@module vncoxide.toolbar
]]

local _ = require("gettext")
local T = require("ffi/util").template

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local Icons = require("vncoxide/icons")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Settings = require("vncoxide/settings")
local Util = require("vncoxide/util")

local Screen = Device.screen

local Toolbar = InputContainer:extend{
    app = nil, -- the @{vncoxide.app} instance
}

Toolbar.IDS = { "toggle", "display", "zoom", "mode", "keyboard", "scroll_up", "scroll_down",
    "brightness", "contrast", "invert", "close", "more" }

--- The long-press tooltip of each button; `expand` is the round button's.
Toolbar.TIPS = {
    toggle = _("Collapse toolbar"),
    expand = _("Show toolbar"),
    display = _("Display settings"),
    zoom = _("Zoom: fit, 1:1, your own view"),
    mode = _("Pointer mode: touch, mouse or hybrid"),
    keyboard = _("Keyboard (drag onto a field to click it and type)"),
    scroll_up = _("Scroll up"),
    scroll_down = _("Scroll down"),
    brightness = _("Frontlight"),
    contrast = _("Contrast of the remote picture"),
    invert = _("Invert the remote picture"),
    close = _("Disconnect"),
    more = _("Menu"),
}

--- Whether button `id` is switched on in `settings` (`toolbar_buttons`, its default when unset).
--- Close and More are always on; this does not ask whether the device has a frontlight.
function Toolbar.is_enabled(settings, id)
    local default = Settings.TOOLBAR_BUTTONS[id]
    if default == nil then return true end
    local buttons = settings.toolbar_buttons
    if type(buttons) == "table" and type(buttons[id]) == "boolean" then return buttons[id] end
    return default
end

-- Labels for the buttons without a fitting icon: these glyphs come from KOReader's default UI font
-- fallbacks (FreeSerif has both).
local MODE_GLYPHS = { touch = "☝", mouse = "🖱", hybrid = "↕" }

-- The zoom button's icon per view state (`ViewerApp:view_state`); 1:1 has a plugin icon instead.
local ZOOM_ICONS = { fit = "zoom.page", user = "zoom.manual", preset = "zoom.manual" }

--- Asks before disconnecting; the answer lands on the connection list (`ViewerApp:disconnect_session`).
local function confirm_disconnect(app)
    local profile = app.session:get_profile()
    UIManager:show(ConfirmBox:new{
        text = profile and T(_("Disconnect from %1?"), profile.name) or _("Disconnect?"),
        ok_text = _("Disconnect"),
        dismissable = false,
        ok_callback = function() app:disconnect_session() end,
        cancel_callback = function() app:_sync_keyboard_later() end,
    })
    -- the confirmation is above the view now: it owns the screen too
    app:_sync_keyboard_later()
end

--- Per button: an icon from KOReader's set (`icon`), one of the plugin's own (`icon_file`) or a text
--- label, what a tap does, and for a toggle whether it is on (`selected`).
local function specs(app)
    return {
        toggle = { icon_file = Icons.path("toolbar"), callback = function() app:set_toolbar_collapsed(true) end },
        close = { icon = "close", callback = function() confirm_disconnect(app) end },
        display = { icon = "appbar.pagefit", callback = function() app:toggle_display_panel() end },
        zoom = {
            icon = ZOOM_ICONS[app:view_state()],
            icon_file = app:view_state() == "1:1" and Icons.path("zoom-1to1") or nil,
            callback = function() app:cycle_zoom() end,
        },
        mode = {
            text = MODE_GLYPHS[app:get_pointer_mode()],
            callback = function() app:toggle_pointer_mode() end,
        },
        keyboard = {
            icon_file = Icons.path("keyboard"),
            callback = function() app:toggle_keyboard() end,
        },
        scroll_up = { icon = "move.up", callback = function() app:scroll_wheel(-1, 1) end },
        scroll_down = { icon = "move.down", callback = function() app:scroll_wheel(1, 1) end },
        brightness = { icon_file = Icons.path("brightness"), callback = function() app:open_frontlight_dialog() end },
        contrast = { icon = "appbar.contrast", callback = function() app:toggle_contrast_dialog() end },
        invert = {
            icon_file = Icons.path("invert"),
            selected = app.settings.remote_invert,
            callback = function() app:toggle_invert() end,
        },
        more = { icon = "appbar.menu", callback = function() app:open_menu() end },
    }
end

--[[--
Shows a button's tooltip. A toast closes on any input, which would take it away the moment the
finger that asked for it lifts: the end of that long press (its hold_pan moves and hold_release)
leaves it up; the next touch closes it as usual.
]]
local function show_tip(app, text)
    local toast = app:show_toast(text)
    local on_gesture = toast.onGesture
    function toast:onGesture(ev)
        if ev and (ev.ges == "hold_release" or ev.ges == "hold_pan") then return false end
        return on_gesture(self, ev)
    end
    return toast
end

--[[--
A button's long press shows its tooltip only once confirmed, like the canvas's (see
`ViewerApp.HOLD_CONFIRM`): still down HOLD_CONFIRM seconds after the hold (a confirmation that ran
behind a busy UI thread looks again, `Util.hold_check_late`). Lifted sooner it is InkView's late
burst of a tap (PocketBook withholds a tap's events for ~0.5 s at times, long enough for the hold
timer to trip): the button's `callback` runs, as for a tap. `button.vnc_hold` is the state (tests).
]]
local function arm_hold(app, button, callback, tip)
    local time = require("ui/time")
    local confirm = app.HOLD_CONFIRM or 0.12
    local h = {}
    button.vnc_hold = h
    h.task = function()
        if not h.since then return end
        if Util.hold_check_late(h.due, h.since) then
            h.due = time.now() + time.s(Util.HOLD_RECHECK)
            UIManager:scheduleIn(Util.HOLD_RECHECK, h.task)
            return
        end
        h.since = nil
        show_tip(app, tip)
    end
    button.hold_callback = function()
        UIManager:unschedule(h.task)
        h.since = time.now()
        h.due = h.since + time.s(confirm)
        UIManager:scheduleIn(confirm, h.task)
    end
    local release = button.onHoldReleaseSelectButton
    button.onHoldReleaseSelectButton = function(b)
        if h.since then
            h.since = nil
            UIManager:unschedule(h.task)
            if b._hold_handled and callback then
                logger.dbg("vncoxide: toolbar hold lifted before", confirm, "s: a tap")
                b._hold_handled = nil
                callback()
                return true
            end
        end
        return release(b)
    end
end

function Toolbar:init()
    self:relayout()
end

--- The ids of the buttons on the bar, left to right: those switched on (`Toolbar.is_enabled`),
--- Brightness only on a device with a frontlight.
function Toolbar:visible_ids()
    local settings = self.app.settings
    local ids = {}
    for _i, id in ipairs(Toolbar.IDS) do
        if Toolbar.is_enabled(settings, id) and (id ~= "brightness" or Device:hasFrontlight()) then
            ids[#ids + 1] = id
        end
    end
    return ids
end

--- Whether button `id` is pinned to the collapsed toolbar in `settings` (`toolbar_pinned`, its
--- default when unset: @{Settings.TOOLBAR_PINNED}). Collapse and Close never are.
function Toolbar.is_pinned(settings, id)
    if id == "toggle" or id == "close" then return false end
    local pinned = settings.toolbar_pinned
    if type(pinned) == "table" and type(pinned[id]) == "boolean" then return pinned[id] end
    return Settings.TOOLBAR_PINNED[id] == true
end

--- The buttons that stay beside the round button while collapsed, in bar order: those pinned
--- (`Toolbar.is_pinned`) that the full bar shows too.
function Toolbar:pinned_ids()
    local ids = {}
    for _i, id in ipairs(self:visible_ids()) do
        if Toolbar.is_pinned(self.app.settings, id) then ids[#ids + 1] = id end
    end
    return ids
end

--- Whether the bar is folded into its round button: stored (`toolbar_collapsed`), and only while
--- the Collapse button is switched on (it is the only way back from the menu's side).
function Toolbar:wants_collapsed()
    local settings = self.app.settings
    return settings.toolbar_collapsed == true and Toolbar.is_enabled(settings, "toggle")
end

local function sizes()
    local icon_size = Screen:scaleBySize(G_defaults:readSetting("DGENERIC_ICON_SIZE") * 0.8)
    local padding = Size.padding.default
    return icon_size, padding, icon_size + 2 * padding
end

--- The position along one axis for fraction `f` of the free space `total - size` (less a margin on
--- both sides), and back.
local function axis_place(f, size, total)
    local m = Size.margin.default
    local free = total - size - 2 * m
    if free <= 0 then return m end
    return m + math.floor(f * free + 0.5)
end
local function axis_clamp(v, size, total)
    local m = Size.margin.default
    return math.max(m, math.min(v, math.max(m, total - size - m)))
end
local function axis_fraction(v, size, total)
    local m = Size.margin.default
    local free = total - size - 2 * m
    if free <= 0 then return 0.5 end
    return math.max(0, math.min(1, (v - m) / free))
end

--- The stored position (`toolbar_pos`), the default top centre when there is none.
function Toolbar:_stored_pos()
    local pos = self.app.settings.toolbar_pos
    if type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.y) ~= "number" then
        return Settings.TOOLBAR_POS
    end
    return pos
end

--[[--
Rebuilds the bar (or the round button while collapsed) for the current screen size, pointer mode
and button settings. It goes where `toolbar_pos` says, or with `at` (a point) at that
spot on the screen, clamped, which is then stored as the new `toolbar_pos` (not flushed).
]]
function Toolbar:relayout(at)
    if self[1] then self[1]:free() end
    self.button_by_id = {}
    local app = self.app
    local icon_size, padding, cell = sizes()
    local function make_button(spec, tip)
        local button = Button:new{
            -- a plugin icon starts as KOReader's placeholder, then gets its file (below)
            icon = spec.icon or (spec.icon_file and "icon-not-found"),
            icon_width = icon_size,
            icon_height = icon_size,
            text = spec.text,
            text_font_size = 26,
            width = spec.text and icon_size or nil,
            height = spec.text and icon_size or nil,
            bordersize = 0,
            margin = 0,
            radius = 0,
            padding = padding,
            callback = spec.callback,
            -- a long press only tells what the button is (once confirmed, see `arm_hold`)
            hold_callback = function() end,
            -- a toggle that is on is drawn inverted
            preselect = spec.selected or nil,
            show_parent = app,
        }
        if spec.icon_file then Icons.set_button_icon(button, spec.icon_file, icon_size) end
        arm_hold(app, button, spec.callback, tip)
        return button
    end
    self.collapsed = self:wants_collapsed()
    local border = Size.border.window
    -- the view state the zoom button shows, for `ViewerApp:_zoom_state_changed`
    self.zoom_state = app:view_state()
    local ids = self:visible_ids()
    local expand
    if self.collapsed then
        ids = self:pinned_ids()
        if #ids > 0 then
            -- a short bar: the expand button where Collapse was, then the pinned buttons
            table.insert(ids, 1, "toggle")
            expand = { icon_file = Icons.path("toolbar"), callback = function() app:set_toolbar_collapsed(false) end }
        end
    end
    -- the buttons left to right and where the first one starts inside the frame (`button_rect`)
    self.ids = ids
    self.cell = cell
    if self.collapsed and not expand then
        self.ids = { "toggle" }
        self.inset = border
        local button = make_button({ icon_file = Icons.path("toolbar"),
            callback = function() app:set_toolbar_collapsed(false) end }, Toolbar.TIPS.expand)
        self.button_by_id.toggle = button
        -- the square button would paint its white corners over the round border: only its icon is drawn
        button.frame.background = nil
        self[1] = FrameContainer:new{
            bordersize = border,
            radius = math.floor((cell + 2 * border) / 2),
            padding = 0,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = cell, h = cell }, button },
        }
    else
        local all = specs(app)
        local group = HorizontalGroup:new{}
        for _i, id in ipairs(ids) do
            local button
            if expand and id == "toggle" then
                button = make_button(expand, Toolbar.TIPS.expand)
            else
                button = make_button(all[id], Toolbar.TIPS[id])
            end
            self.button_by_id[id] = button
            group[#group + 1] = CenterContainer:new{ dimen = Geom:new{ w = cell, h = cell }, button }
        end
        -- the buttons are square and paint their own white: inset them just enough that their
        -- corners stay inside the rounded border's inner arc instead of covering it
        local radius = Size.radius.window
        local inset = math.max(0, math.ceil((radius - border) * (1 - 1 / math.sqrt(2))))
        self.inset = border + inset
        self[1] = FrameContainer:new{
            bordersize = border,
            radius = radius,
            padding = inset,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            group,
        }
    end
    local size = self[1]:getSize()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local x, y
    if at then
        x, y = axis_clamp(at.x, size.w, sw), axis_clamp(at.y, size.h, sh)
    else
        local pos = self:_stored_pos()
        x, y = axis_place(pos.x, size.w, sw), axis_place(pos.y, size.h, sh)
    end
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    if at then self:_store_pos() end
end

--- Stores where the bar (or the round button) is now as `toolbar_pos` (the caller flushes).
function Toolbar:_store_pos()
    local d, sw, sh = self.dimen, Screen:getWidth(), Screen:getHeight()
    self.app.settings.toolbar_pos = { x = axis_fraction(d.x, d.w, sw), y = axis_fraction(d.y, d.h, sh) }
end

--- Moves the bar so its top left corner is at `x, y`, clamped to the screen; `dimen` becomes a new
--- Geom (the caller may hold the old one). Stores the position (not flushed).
function Toolbar:move_to(x, y)
    local d, sw, sh = self.dimen, Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = axis_clamp(x, d.w, sw), y = axis_clamp(y, d.h, sh), w = d.w, h = d.h }
    self:_store_pos()
end

--- Where button `id` is on the screen (its cell), or nil when the bar does not show it. Computed from
--- the layout, so it is known before the bar is painted.
function Toolbar:button_rect(id)
    local d = self.dimen
    if not (d and self.ids) then return nil end
    for i, b in ipairs(self.ids) do
        if b == id then
            return Geom:new{ x = d.x + self.inset + (i - 1) * self.cell, y = d.y + self.inset, w = self.cell, h = self.cell }
        end
    end
    return nil
end

--- Whether screen point `pos` is on the Keyboard button.
function Toolbar:_on_keyboard_button(pos)
    local r = pos and self:button_rect("keyboard")
    return r ~= nil and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

--[[--
Puts the keyboard icon a drag off the Keyboard button carries centred on screen point `pos`, or
takes it away (`pos` nil). Repaints where it was and where it is with `mode` (`"fast"` while it
follows the finger, `"ui"` once it is gone). The icon is `drag_icon` (`{ dimen = }`) while it is up.
]]
function Toolbar:_place_icon(pos, mode)
    local old = self.drag_icon and self.drag_icon.dimen
    local new
    if pos then
        if not self._icon_widget then
            local icon_size = sizes()
            self._icon_widget = FrameContainer:new{
                bordersize = Size.border.window,
                radius = Size.radius.window,
                padding = Size.padding.small,
                margin = 0,
                background = Blitbuffer.COLOR_WHITE,
                IconWidget:new{ file = Icons.path("keyboard"), width = icon_size, height = icon_size },
            }
        end
        local size = self._icon_widget:getSize()
        new = Geom:new{ x = pos.x - math.floor(size.w / 2), y = pos.y - math.floor(size.h / 2), w = size.w, h = size.h }
        self.drag_icon = { dimen = new }
    else
        self.drag_icon = nil
    end
    if old or new then self.app:_toolbar_moved(old or new, new or old, mode) end
end

--- Gestures that move the bar: a one-finger drag that starts on it, ending in a pan_release, or in
--- a swipe when the finger lifts while still moving (a swipe's `pos` is where it started).
Toolbar.DRAG_GESTURES = { pan = true, pan_release = true, swipe = true, multiswipe = true }

--- Whether a drag of the bar is under way (its moves and its end are the bar's wherever they are).
function Toolbar:is_dragging()
    return self.drag ~= nil
end

--- Ends a drag whose lift never reached the bar (a popup took it) when `ges`, a pan or a swipe,
--- starts elsewhere: that is a new gesture, not the drag's. Returns whether it ended one.
function Toolbar:drop_lost_drag(ges)
    local drag = self.drag
    if not drag or ges.ges == "pan_release" then return false end
    local start = ges.ges == "pan" and (ges.start_pos or ges.pos) or ges.pos
    if drag.sx == start.x and drag.sy == start.y then return false end
    self.drag = nil
    if drag.icon then self:_place_icon(nil, "ui") end
    return true
end

--- One step of a drag of the bar (`ges` is one of `DRAG_GESTURES`). The viewer repaints the area.
function Toolbar:_on_drag(ges)
    local kind = ges.ges
    local old = self.dimen
    if kind == "pan" then
        local start = ges.start_pos or ges.pos
        local drag = self.drag
        -- a pan from a new start point is a new drag (a lost end must not carry over)
        if not drag or drag.sx ~= start.x or drag.sy ~= start.y then
            if drag and drag.icon then self:_place_icon(nil, "ui") end
            drag = { sx = start.x, sy = start.y, x = old.x, y = old.y, from = old,
                     icon = self:_on_keyboard_button(start) or nil }
            self.drag = drag
        end
        if drag.icon then
            -- the keyboard icon follows the finger; the bar stays, nothing is sent
            self:_place_icon(ges.pos, "fast")
            return true
        end
        local rel = ges.relative or { x = 0, y = 0 }
        self:move_to(drag.x + (rel.x or 0), drag.y + (rel.y or 0))
        self.app:_toolbar_moved(old, self.dimen, "fast")
        return true
    end
    local drag = self.drag
    self.drag = nil
    local swipe = kind == "swipe" or kind == "multiswipe"
    if swipe and not (drag and drag.sx == ges.pos.x and drag.sy == ges.pos.y) then
        -- a flick with no pan of its own: it counts by where it started
        if drag and drag.icon then
            self:_place_icon(nil, "ui")
            drag = nil
        end
        if self:_on_keyboard_button(ges.pos) then drag = { icon = true } end
    end
    if drag and drag.icon then
        -- the keyboard icon is put down: where the finger lifted (a swipe's end)
        local at = swipe and (ges.end_pos or ges.pos) or ges.pos
        self:_place_icon(nil, "ui")
        self.app:drop_keyboard_at(at)
        return true
    end
    if swipe then
        local s, e = ges.pos, ges.end_pos or ges.pos
        local x0, y0 = old.x, old.y
        if drag and drag.sx == s.x and drag.sy == s.y then x0, y0 = drag.x, drag.y end
        self:move_to(x0 + e.x - s.x, y0 + e.y - s.y)
    elseif not drag then
        return true
    end
    self.app:_toolbar_moved(drag and drag.from or old, self.dimen, "ui", true)
    return true
end

function Toolbar:handleEvent(event)
    if event.handler == "onGesture" then
        local ges = event.args and event.args[1]
        if ges and Toolbar.DRAG_GESTURES[ges.ges] then return self:_on_drag(ges) end
    end
    return InputContainer.handleEvent(self, event)
end

--- `dimen` is where the bar sits on the screen, which the viewer's gesture routing relies on;
--- InputContainer's own paintTo would move it to the viewer's origin.
function Toolbar:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.dimen.x, y + self.dimen.y)
    local icon = self.drag_icon
    if icon then self._icon_widget:paintTo(bb, x + icon.dimen.x, y + icon.dimen.y) end
end

return Toolbar
