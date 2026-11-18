--[[--
The display panel: zoom, scaling, orientation (icon buttons) and pointer speed.

A ButtonDialog that hangs under the toolbar (above it when there is no room below; from the top of the screen without one). Built
fresh on every open and re-opened in place after a choice, so the checkmarks always show the live
state. Only a rotation closes it: the dialog is laid out for the old orientation.

@module vncoxide.displaypanel
]]

local _ = require("gettext")

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Geom = require("ui/geometry")
local Settings = require("vncoxide/settings")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

local DisplayPanel = {}

DisplayPanel.ZOOM_CHOICES = {
    { label = _("Fit screen"), value = "fit" },
    { label = _("Fit (with keyboard)"), value = "fit_with_keyboard" },
    { label = "25%", value = 0.25 },
    { label = "50%", value = 0.5 },
    { label = "75%", value = 0.75 },
    { label = "100%", value = 1 },
    { label = "150%", value = 1.5 },
    { label = "200%", value = 2 },
    { label = "400%", value = 4 },
}

-- Mirrors KOReader's `rotation_mode` config option: the four buttons stand for these modes, in this
-- order (90 CCW, upright, 90 CW, 180), and the icon set (portrait or landscape) follows the screen.
DisplayPanel.ROTATION_MODES = { 3, 0, 1, 2 }
local ROTATION_ICONS = {
    [0] = { "rotation.P.90CCW", "rotation.P.0UR", "rotation.P.90CW", "rotation.P.180UD" },
    [2] = { "rotation.P.90CW", "rotation.P.180UD", "rotation.P.90CCW", "rotation.P.0UR" },
    [1] = { "rotation.L.90CCW", "rotation.L.0UR", "rotation.L.90CW", "rotation.L.180UD" },
    [3] = { "rotation.L.90CW", "rotation.L.180UD", "rotation.L.90CCW", "rotation.L.0UR" },
}

local SPEEDS = {
    { label = _("Slow"), value = "slow" },
    { label = _("Normal"), value = "normal" },
    { label = _("Fast"), value = "fast" },
}

local function mark(label, current)
    return current and ("✓ " .. label) or label
end

--- Chunks `list` into rows of at most `per_row` entries.
local function rows_of(list, per_row)
    local rows = {}
    for i = 1, #list, per_row do
        local row = {}
        for j = i, math.min(i + per_row - 1, #list) do row[#row + 1] = list[j] end
        rows[#rows + 1] = row
    end
    return rows
end

--- Opens the display panel for `app`.
--- @tparam table app the @{vncoxide.app} instance
--- @treturn table the ButtonDialog
function DisplayPanel.open(app)
    local settings = app.settings
    local plugin_settings = app.plugin.settings
    local panel

    -- A choice that leaves the panel up: close the old one quietly, then build the new one in place.
    local function reopen()
        app:close_display_panel(true)
        app:open_display_panel()
    end
    local function stays(fn)
        return function()
            fn()
            plugin_settings:flush()
            reopen()
        end
    end

    local buttons = {}
    local zoom_buttons = {}
    for _i, choice in ipairs(DisplayPanel.ZOOM_CHOICES) do
        zoom_buttons[#zoom_buttons + 1] = {
            text = mark(choice.label, settings.zoom_mode == choice.value and not app._user_view),
            callback = stays(function() app:zoom_to(choice.value) end),
        }
    end
    for _i, row in ipairs(rows_of(zoom_buttons, 3)) do buttons[#buttons + 1] = row end

    local function scaling_button(label, value)
        return {
            text = mark(label, settings.scaling == value),
            callback = stays(function()
                settings.scaling = value
                local live = app.session:get_remote()
                if live then live:set_scaling(value) end
                app:_wholesale_change()
            end),
        }
    end
    buttons[#buttons + 1] = { scaling_button(_("Smooth"), "smooth"), scaling_button(_("Sharp"), "sharp") }

    local current_rotation = Screen:getRotationMode()
    local rotation_buttons = {}
    for i, icon in ipairs(ROTATION_ICONS[current_rotation]) do
        local mode = DisplayPanel.ROTATION_MODES[i]
        local selected = current_rotation == mode
        -- Closes the panel: it only relayouts on a broadcast ScreenResize, which a rotation does not
        -- send, so an open panel would stay laid out for the old orientation.
        rotation_buttons[#rotation_buttons + 1] = {
            icon = icon,
            selected = selected,
            background = selected and Blitbuffer.COLOR_LIGHT_GRAY or nil,
            callback = function()
                app:close_display_panel()
                app:choose_rotation(mode)
            end,
        }
    end
    buttons[#buttons + 1] = rotation_buttons

    -- Quality: the mark follows the stored profile (the live one only differs during a preset attempt)
    local session_profile = app.session:get_profile()
    local stored = session_profile and plugin_settings:get_profile(session_profile.name)
    if stored then
        local current = Settings.preset_of(stored)
        local quality_buttons = {}
        for _i, preset in ipairs(Settings.QUALITY_PRESETS) do
            quality_buttons[#quality_buttons + 1] = {
                text = mark(preset.label, current == preset.id),
                callback = function() app:apply_quality_preset(preset.id) end,
            }
        end
        buttons[#buttons + 1] = {{ text = _("Picture quality (reconnects)"), enabled = false }}
        buttons[#buttons + 1] = quality_buttons
        if current == "custom" then
            buttons[#buttons + 1] = {{ text = "✓ " .. _("Custom"), enabled = false }}
        end
    end

    local speed_buttons = {}
    for _i, speed in ipairs(SPEEDS) do
        speed_buttons[#speed_buttons + 1] = {
            text = mark(speed.label, settings.pointer_speed == speed.value),
            callback = stays(function() settings.pointer_speed = speed.value end),
        }
    end
    buttons[#buttons + 1] = {{ text = _("Pointer speed (mouse mode)"), enabled = false }}
    buttons[#buttons + 1] = speed_buttons

    panel = ButtonDialog:new{
        buttons = buttons,
        -- under the toolbar when it is up, else from the top edge; the true asks to pop down
        anchor = function()
            local bar = app.toolbar
            if bar and app.toolbar_visible then
                return Geom:new{ x = bar.dimen.x, y = bar.dimen.y, w = bar.dimen.w, h = bar.dimen.h }, true
            end
            return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = 0 }, true
        end,
        tap_close_callback = function() app:_display_panel_dismissed(panel) end,
    }
    -- The stock close asks for a flashing refresh of the panel's area; a partial one is enough.
    function panel:onCloseWidget()
        UIManager:setDirty(nil, function() return "ui", self.movable.dimen end)
    end
    UIManager:show(panel, "ui")
    return panel
end

return DisplayPanel
