--[[--
The in-app menu.

Built fresh on every open, so the checkmarks and the status row always reflect the live
session state.

@module vnc.menu
]]

local _ = require("gettext")
local T = require("ffi/util").template

local Device = require("device")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")

local Dialogs = require("vnc/dialogs")
local Keysyms = require("vnc/keysyms")

local Screen = Device.screen

local MenuBuilder = {}

local ZOOM_CHOICES = {
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

local ROTATIONS = {
    { label = _("Portrait"), mode = 0 },
    { label = _("Landscape"), mode = 1 },
    { label = _("Portrait inverted"), mode = 2 },
    { label = _("Landscape inverted"), mode = 3 },
}

local COLOR_DEPTHS = {
    { label = _("24-bit"), value = 24 },
    { label = _("16-bit"), value = 16 },
    { label = _("8-bit"), value = 8 },
}

local NEXT_CONNECTION = _("Takes effect on the next connection.")

local function level_label(value)
    return value == false and _("Off") or tostring(value)
end

local function depth_label(depth)
    for _i, choice in ipairs(COLOR_DEPTHS) do
        if choice.value == depth then return choice.label end
    end
    return tostring(depth)
end

local function zoom_label(mode)
    for _i, choice in ipairs(ZOOM_CHOICES) do
        if choice.value == mode then return choice.label end
    end
    return tostring(mode)
end

local function rotation_label(mode)
    for _i, rotation in ipairs(ROTATIONS) do
        if rotation.mode == mode then return rotation.label end
    end
    return tostring(mode)
end

--- Opens the in-app menu for `app`.
--- @tparam table app the @{vnc.app} instance
--- @treturn table the Menu
function MenuBuilder.open(app)
    local plugin = app.plugin
    local settings = app.settings
    local session = app.session
    local profile = session:get_profile()
    local remote = session:get_remote()
    local menu

    -- Delegating to the app keeps its menu handle in sync, so a later open_menu() cannot
    -- hand back a widget that is already closed.
    local function close_menu()
        app:close_menu()
    end
    local function action(fn)
        return function()
            close_menu()
            fn()
        end
    end
    -- A failed attempt must come back to a menu, not leave the user staring at the canvas.
    local function back_into_menu() app:open_menu() end

    local item_table = {}

    -- ---- a lost / failed connection: offer a retry right at the top
    if profile and session:get_state() == "error" then
        item_table[#item_table + 1] = {
            text = T(_("Reconnect to %1"), profile.name),
            callback = action(function() plugin:connect_profile(profile.name, back_into_menu) end),
        }
    end

    -- ---- connections
    local connections = {}
    for _, p in ipairs(plugin.settings:profiles()) do
        connections[#connections + 1] = {
            text = p.name,
            mandatory = string.format("%s:%d", p.host, p.port),
            callback = action(function() plugin:connect_profile(p.name, back_into_menu) end),
        }
    end
    connections[#connections + 1] = {
        text = _("New connection…"),
        -- the menu is closed by now, so there is nothing to return to but the canvas
        callback = action(function() Dialogs.edit_profile(plugin, nil, {}) end),
    }
    item_table[#item_table + 1] = { text = _("Connections…"), sub_item_table = connections }

    -- ---- status (not selectable)
    local status
    if not profile then
        status = _("No active session")
    elseif session:get_state() == "error" then
        status = T(_("Connection lost: %1"), tostring(session:get_error()))
    elseif session:get_state() == "connected" and remote then
        status = T(_("Connected to %1 (%2×%3)"), profile.name, remote:get_size())
    else
        status = T(_("Not connected (%1)"), session:get_state())
    end
    item_table[#item_table + 1] = { text = status, select_enabled = false }

    -- ---- zoom
    local zoom_items = {}
    for _i, choice in ipairs(ZOOM_CHOICES) do
        zoom_items[#zoom_items + 1] = {
            text = choice.label,
            mandatory = settings.zoom_mode == choice.value and "✓" or nil,
            callback = action(function()
                app:zoom_to(choice.value)
                plugin.settings:flush()
            end),
        }
    end
    item_table[#item_table + 1] = {
        text = _("Zoom…"),
        sub_item_table = zoom_items,
        mandatory = zoom_label(settings.zoom_mode),
    }

    -- ---- keyboard
    item_table[#item_table + 1] = {
        text = _("Keyboard always visible"),
        mandatory = settings.keyboard_always_visible and "✓" or "-",
        callback = action(function()
            settings.keyboard_always_visible = not settings.keyboard_always_visible
            plugin.settings:flush()
            app:evaluate_keyboard()
        end),
    }
    item_table[#item_table + 1] = {
        -- Driven by the wish, not by the current state: while this very menu is open the
        -- keyboard is hidden, but the item must still describe what tapping it does.
        text = app:is_keyboard_wanted() and _("Hide keyboard") or _("Show keyboard"),
        callback = action(function() app:toggle_keyboard() end),
    }

    -- ---- orientation
    local rotation_items = {}
    for _i, rotation in ipairs(ROTATIONS) do
        rotation_items[#rotation_items + 1] = {
            text = rotation.label,
            mandatory = settings.orientation == rotation.mode and _("default") or nil,
            callback = action(function() app:set_rotation_mode(rotation.mode) end),
        }
    end
    item_table[#item_table + 1] = {
        text = _("Screen orientation"),
        sub_item_table = rotation_items,
        mandatory = rotation_label(Screen:getRotationMode()),
    }
    item_table[#item_table + 1] = {
        text = _("Rotate screen"),
        callback = action(function() app:rotate(1) end),
    }
    item_table[#item_table + 1] = {
        text = _("Use current orientation as default"),
        callback = action(function()
            settings.orientation = Screen:getRotationMode()
            plugin.settings:flush()
        end),
    }

    -- ---- bandwidth: read once per connection, so a change only applies to the next one
    local function set_connection_setting(key, value)
        return action(function()
            settings[key] = value
            plugin.settings:flush()
            if session:get_state() == "connected" then
                UIManager:show(InfoMessage:new{ text = NEXT_CONNECTION, timeout = 2 })
            end
        end)
    end
    local depth_items = {}
    for _i, choice in ipairs(COLOR_DEPTHS) do
        depth_items[#depth_items + 1] = {
            text = choice.label,
            mandatory = settings.color_depth == choice.value and "✓" or nil,
            callback = set_connection_setting("color_depth", choice.value),
        }
    end
    item_table[#item_table + 1] = {
        text = _("Colour depth (next connection)"),
        sub_item_table = depth_items,
        mandatory = depth_label(settings.color_depth),
        help_text = NEXT_CONNECTION,
    }
    -- JPEG quality and compression level are Tight pseudo-encodings: without Tight the server
    -- never sees them, so the entries are dimmed (and have no submenu to open).
    local function level_entry(text, key, help_text)
        local entry = {
            text = text,
            mandatory = level_label(settings[key]),
            help_text = help_text,
        }
        if not settings.enable_tight then
            entry.select_enabled = false
            entry.dim = true
            return entry
        end
        local items = {}
        for value = -1, 9 do
            local stored = value >= 0 and value or false
            items[#items + 1] = {
                text = level_label(stored),
                mandatory = settings[key] == stored and "✓" or nil,
                callback = set_connection_setting(key, stored),
            }
        end
        entry.sub_item_table = items
        return entry
    end
    item_table[#item_table + 1] = level_entry(_("JPEG quality (next connection)"), "jpeg_quality",
        NEXT_CONNECTION .. "\n" .. _("Only used at 24-bit colour."))
    item_table[#item_table + 1] = level_entry(_("Compression level (next connection)"), "compress_level",
        NEXT_CONNECTION)

    -- ---- keys the on-screen keyboard does not have
    local function send(keysym)
        return action(function()
            app:send_key(keysym, true)
            app:send_key(keysym, false)
        end)
    end
    item_table[#item_table + 1] = {
        text = _("Send key"),
        sub_item_table = {
            { text = _("Enter"), callback = send(Keysyms.special.Press) },
            { text = _("Tab"), callback = send(Keysyms.special.Tab) },
            { text = _("Esc"), callback = send(Keysyms.special.Back) },
            { text = _("Delete"), callback = send(Keysyms.special.Del) },
        },
    }

    -- ---- session
    item_table[#item_table + 1] = {
        text = _("Disconnect"),
        callback = action(function()
            UIManager:show(ConfirmBox:new{
                text = profile and T(_("Disconnect from %1?"), profile.name) or _("Disconnect?"),
                ok_text = _("Disconnect"),
                dismissable = false,
                ok_callback = function() app:disconnect_session() end,
                cancel_callback = function() app:_sync_keyboard_later() end,
            })
            -- the confirmation is above the view now: it owns the screen too
            app:_sync_keyboard_later()
        end),
    }
    item_table[#item_table + 1] = {
        text = _("Leave (keep connection)"),
        callback = action(function() app:leave() end),
    }

    menu = Menu:new{
        title = profile and T(_("VNC — %1"), profile.name) or _("VNC viewer"),
        item_table = item_table,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        -- The menu covers the framebuffer view, so UIManager must composite from us instead of
        -- repainting the viewer underneath on every tick. Every full-screen menu in core says so
        -- (c.f. frontend/ui/widget/booklist.lua, keyvaluepage.lua, filemanagercollection.lua).
        covers_fullscreen = true,
        close_callback = function()
            app.menu = nil
            app:_sync_keyboard_later()
        end,
    }
    -- Menu has no help text of its own: a long press on an entry that carries one shows it.
    function menu:onMenuHold(item)
        if item.help_text then
            UIManager:show(InfoMessage:new{ text = item.help_text })
        end
        return true
    end
    -- A menu over a framebuffer view is a wholesale change: without a flash the panel would keep
    -- the desktop where the menu belongs, and the viewer's per-rectangle refreshes would only ever
    -- push a band of it. Core's TouchMenu flashes its first popup for exactly this reason.
    UIManager:show(menu, "flashui")
    return menu
end

return MenuBuilder
