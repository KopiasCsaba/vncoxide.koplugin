--[[--
The viewer's toolbar: a compact bar floating at the top centre of the screen, over the remote.

Not a window of its own: the viewer paints it after the canvas and hands it the gestures that
start on it (`ViewerApp:_toolbar_owns`), so a tap on the bar never reaches the remote while the
canvas beside and below it stays fully interactive. A swipe down in the top menu zone shows or
hides it (`ViewerApp:toggle_toolbar`).

Buttons, left to right: Close (disconnect, after a confirmation), Display (the display panel),
Mode (tap: Touch/Mouse, the label shows the current one; long press: the help), Keyboard (tap: shows or hides the on-screen
keyboard with the key strip, or closes the "Send keys" panel; long press: that panel), Rotate,
Scroll lock (a toggle, drawn inverted while on: a two-finger drag scrolls the remote), Scroll up/down (only with the `toolbar_scroll_buttons` setting) and More (the menu).

@module vnc.toolbar
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
local Icons = require("vnc/icons")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

local Toolbar = InputContainer:extend{
    app = nil, -- the @{vnc.app} instance
}

Toolbar.IDS = { "close", "display", "mode", "keyboard", "rotate", "scroll_lock", "scroll_up", "scroll_down", "more" }

-- Labels for the buttons without a fitting icon: these glyphs come from KOReader's default UI font
-- fallbacks (FreeSerif has both).
local MODE_GLYPHS = { touch = "☝", mouse = "🖱" }

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
--- label, what a tap (and a long press) does, and for a toggle whether it is on (`selected`).
local function specs(app)
    return {
        close = { icon = "close", callback = function() confirm_disconnect(app) end },
        display = { icon = "appbar.pagefit", callback = function() app:toggle_display_panel() end },
        mode = {
            text = MODE_GLYPHS[app:get_pointer_mode()],
            callback = function() app:toggle_pointer_mode() end,
            hold_callback = function() app:open_help() end,
        },
        keyboard = {
            icon_file = Icons.path("keyboard"),
            callback = function() app:toggle_keyboard() end,
            hold_callback = function() app:open_key_panel() end,
        },
        rotate = { icon = "appbar.rotation", callback = function() app:rotate(1) end },
        scroll_lock = {
            icon_file = Icons.path("scroll-lock"),
            selected = app.scroll_lock,
            callback = function() app:toggle_scroll_lock() end,
        },
        scroll_up = { icon = "move.up", callback = function() app:scroll_wheel(-1, 1) end },
        scroll_down = { icon = "move.down", callback = function() app:scroll_wheel(1, 1) end },
        more = { icon = "appbar.menu", callback = function() app:open_menu() end },
    }
end

--- Button only takes icon names, which KOReader resolves in its own folders: give `button` a fresh
--- image of the plugin icon `file` instead, at the same size, in the place the label is painted from.
local function show_plugin_icon(button, file, size)
    button.label_widget:free()
    button.label_widget = IconWidget:new{ file = file, width = size, height = size }
    button.label_container[1] = button.label_widget
end

function Toolbar:init()
    self:relayout()
end

--- The ids of the buttons on the bar, left to right: the scroll pair only with its setting on.
function Toolbar:visible_ids()
    local with_scroll = self.app.settings.toolbar_scroll_buttons
    local ids = {}
    for _i, id in ipairs(Toolbar.IDS) do
        if with_scroll or (id ~= "scroll_up" and id ~= "scroll_down") then ids[#ids + 1] = id end
    end
    return ids
end

--- Rebuilds the bar for the current screen size, pointer mode, scroll lock and scroll setting.
function Toolbar:relayout()
    if self[1] then self[1]:free() end
    self.button_by_id = {}
    local app = self.app
    local icon_size = Screen:scaleBySize(G_defaults:readSetting("DGENERIC_ICON_SIZE") * 0.8)
    local padding = Size.padding.default
    local cell = icon_size + 2 * padding
    local all = specs(app)
    local group = HorizontalGroup:new{}
    for _i, id in ipairs(self:visible_ids()) do
        local spec = all[id]
        -- a pending Mouse-mode click goes to the remote before the bar does anything: it belongs
        -- to where the user tapped before reaching for the bar
        local function act(fn)
            return fn and function()
                app:_flush_deferred_click()
                fn()
            end
        end
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
            callback = act(spec.callback),
            hold_callback = act(spec.hold_callback),
            -- a toggle that is on is drawn inverted
            preselect = spec.selected or nil,
            show_parent = app,
        }
        if spec.icon_file then show_plugin_icon(button, spec.icon_file, icon_size) end
        self.button_by_id[id] = button
        group[#group + 1] = CenterContainer:new{ dimen = Geom:new{ w = cell, h = cell }, button }
    end
    self[1] = FrameContainer:new{
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        group,
    }
    local size = self[1]:getSize()
    self.dimen = Geom:new{
        x = math.floor((Screen:getWidth() - size.w) / 2),
        y = Size.margin.default,
        w = size.w,
        h = size.h,
    }
end

--- `dimen` is where the bar sits on the screen, which the viewer's gesture routing relies on;
--- InputContainer's own paintTo would move it to the viewer's origin.
function Toolbar:paintTo(bb, x, y)
    self[1]:paintTo(bb, x + self.dimen.x, y + self.dimen.y)
end

return Toolbar
