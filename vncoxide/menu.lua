--[[--
The in-app menu.

Built fresh on every open, so the checkmarks and the title (the connection's name and state)
always reflect the live session state. Naming: a row that switches something on or off is the plain
name of that thing, with ✓ or - beside it; a row that does something is a verb.

@module vncoxide.menu
]]

local _ = require("gettext")
local T = require("ffi/util").template

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local Dialogs = require("vncoxide/dialogs")
local Settings = require("vncoxide/settings")
local Toolbar = require("vncoxide/toolbar")

local MenuBuilder = {}

-- The title bar's X must close the whole menu; Menu's own wiring (like the Back key) only
-- steps up one submenu level.
--[[--
False long presses: on PocketBook, InkView sometimes withholds a touch's events for ~0.5 s, long
enough for the hold timer to trip, then delivers the lift right after it (see
`ViewerApp.HOLD_CONFIRM`). A tap on a row then arrived as a long press: nothing happened, or its
help text showed. So a row's long press acts on its release (`handle_hold_on_hold_release`), and a
release that comes less than `hold_confirm` seconds after the hold was a tap: the row is selected.
]]
local VncMenu = Menu:extend{
    handle_hold_on_hold_release = true,
    hold_confirm = 0.12,
    clock = time.now, -- (replaceable in tests)
}
function VncMenu:init()
    Menu.init(self)
    -- when the hold itself came (the rows only see its release)
    self.ges_events.VncHoldSeen = {
        GestureRange:new{
            ges = "hold",
            range = function() return Geom:new{ x = 0, y = 0, w = Device.screen:getWidth(), h = Device.screen:getHeight() } end,
        },
    }
    if self.title_bar and self.title_bar.right_button then
        self.title_bar.right_button.callback = function() self:onCloseAllMenus() end
    end
end
-- Inside a submenu the footer's return arrow (KOReader's "back.top", as in its file lists) steps up
-- one level, like the Back key; at the top level there is nothing to go back to, so it is hidden.
function VncMenu:onReturn()
    if #self.item_table_stack > 0 then self:onClose() end
    return true
end
function VncMenu:updatePageInfo(select_number)
    Menu.updatePageInfo(self, select_number)
    local arrow = self.page_return_arrow
    if arrow then
        local nested = #self.item_table_stack > 0
        arrow:showHide(nested)
        arrow:enableDisable(nested)
    end
end
function VncMenu:onVncHoldSeen()
    self._hold_at = self.clock()
    return true
end
--- A row's long press, on its release: a tap when it was a false one, else its help text.
function VncMenu:onMenuHold(item)
    local held = self._hold_at and time.to_s(self.clock() - self._hold_at)
    self._hold_at = nil
    if held and held < self.hold_confirm then return self:onMenuSelect(item) end
    if item.help_text then
        UIManager:show(InfoMessage:new{ text = item.help_text })
    end
    return true
end
-- Settings toggles leave the menu open: the stock handler would run close_callback after them.
function VncMenu:onMenuSelect(item)
    if item.keep_open and item.sub_item_table == nil then
        if item.select_enabled == false then return true end
        if item.select_enabled_func and not item.select_enabled_func() then return true end
        self:onMenuChoice(item)
        return true
    end
    return Menu.onMenuSelect(self, item)
end

--- Opens the in-app menu for `app`.
--- @tparam table app the @{vncoxide.app} instance
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
    -- Items that only change a setting keep the menu open: their `refresh` re-reads the state into
    -- the item, and `refresh_all` redraws the current page in place. Tapping one skips the menu's
    -- close_callback (see `onMenuSelect` below).
    local item_table = {}
    local function refresh_all()
        local function walk(items)
            for _i, item in ipairs(items) do
                if item.refresh then item.refresh(item) end
                if item.sub_item_table then walk(item.sub_item_table) end
            end
        end
        walk(item_table)
        if menu then menu:updateItems(1, true) end
    end
    local function stays_open(item, refresh)
        item.keep_open = true
        item.refresh = refresh
        if refresh then refresh(item) end
        if item.callback then
            local fn = item.callback
            item.callback = function() fn() refresh_all() end
        end
        return item
    end
    -- A failed attempt must come back to a menu, not leave the user staring at the canvas - while
    -- the viewer is still up (the user may have left it while the attempt ran).
    local function back_into_menu()
        if UIManager:isWidgetShown(app) then app:open_menu() end
    end
    -- While the reconnect loop runs, connecting to the session's own profile is the loop's next
    -- attempt: a connect beside it would leave the box up over a live link.
    local function connect_to(name)
        if profile and name == profile.name and app.reconnect:is_running() then
            app.reconnect:retry_now()
        else
            plugin:connect_profile(name, back_into_menu)
        end
    end

    -- ---- the title: the connection and its state
    local title
    local state = session:get_state()
    if not profile then
        title = _("VNC viewer")
    elseif state == "error" then
        title = T(_("%1 · connection lost"), profile.name)
    elseif state == "connected" and remote then
        local w, h = remote:get_size()
        title = T(_("%1 · %2×%3"), profile.name, w, h)
    else
        title = T(_("%1 · %2"), profile.name, state)
    end

    -- ---- a lost / failed connection: offer a retry right at the top
    if profile and session:get_state() == "error" then
        item_table[#item_table + 1] = {
            text = T(_("Reconnect to %1"), profile.name),
            help_text = session:get_error() and tostring(session:get_error()) or nil,
            callback = action(function() connect_to(profile.name) end),
        }
    end

    -- ---- connections
    local connections = {}
    for _, p in ipairs(plugin.settings:profiles()) do
        connections[#connections + 1] = {
            text = p.name,
            mandatory = string.format("%s:%d", p.host, p.port),
            callback = action(function() connect_to(p.name) end),
        }
    end
    connections[#connections + 1] = {
        text = _("New connection…"),
        -- the menu is closed by now, so there is nothing to return to but the canvas
        callback = action(function() Dialogs.edit_profile(plugin, nil, {}) end),
    }
    item_table[#item_table + 1] = { text = _("Connections…"), sub_item_table = connections }

    -- ---- things to send or ask for
    item_table[#item_table + 1] = {
        text = _("Refresh"),
        callback = action(function() app:refresh_remote() end),
    }

    -- ---- page buttons: read on every key press, so this applies at once
    local function set_page_buttons(value)
        return function()
            settings.page_buttons = value
            plugin.settings:flush()
        end
    end
    item_table[#item_table + 1] = stays_open({
        text = _("Page buttons send"),
        help_text = _("Page Up/Down keys go to the focused window on the remote. The mouse wheel scrolls whatever is under the last tap, even in a window that is not focused."),
        sub_item_table = {
            stays_open({
                text = _("Page Up/Down keys"),
                callback = set_page_buttons("keys"),
            }, function(item) item.mandatory = settings.page_buttons ~= "wheel" and "✓" or nil end),
            stays_open({
                text = _("Mouse wheel"),
                callback = set_page_buttons("wheel"),
            }, function(item) item.mandatory = settings.page_buttons == "wheel" and "✓" or nil end),
        },
    }, function(item)
        item.mandatory = settings.page_buttons == "wheel" and _("Mouse wheel") or _("Page Up/Down keys")
    end)

    -- ---- Hybrid mode: how far one wheel notch scrolls the remote (per connection, applies at once)
    if profile then
        local function is_preset(px)
            for _i, p in ipairs(Settings.HYBRID_NOTCH_PRESETS) do
                if p == px then return true end
            end
            return false
        end
        local function px_label(px) return T(_("%1 px"), px) end
        local notch_rows = {}
        for _i, px in ipairs(Settings.HYBRID_NOTCH_PRESETS) do
            notch_rows[#notch_rows + 1] = stays_open({
                text = px_label(px),
                callback = function() app:set_hybrid_notch_px(px) end,
            }, function(item) item.mandatory = app:hybrid_notch_px() == px and "✓" or nil end)
        end
        local function edit_custom()
            local dialog
            dialog = InputDialog:new{
                title = _("Hybrid scroll distance"),
                description = T(_("Remote pixels one wheel notch scrolls (%1 to %2)."),
                    Settings.HYBRID_NOTCH_MIN, Settings.HYBRID_NOTCH_MAX),
                input = tostring(app:hybrid_notch_px()),
                input_type = "number",
                buttons = { {
                    {
                        text = _("Cancel"),
                        id = "close",
                        callback = function() UIManager:close(dialog) end,
                    },
                    {
                        text = _("OK"),
                        is_enter_default = true,
                        callback = function()
                            local px = tonumber(dialog:getInputValue())
                            UIManager:close(dialog)
                            if px and px >= Settings.HYBRID_NOTCH_MIN and px <= Settings.HYBRID_NOTCH_MAX then
                                app:set_hybrid_notch_px(px)
                                refresh_all()
                            else
                                UIManager:show(InfoMessage:new{
                                    text = T(_("Enter a number from %1 to %2."), Settings.HYBRID_NOTCH_MIN, Settings.HYBRID_NOTCH_MAX),
                                    timeout = 3,
                                })
                            end
                        end,
                    },
                } },
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end
        notch_rows[#notch_rows + 1] = stays_open({
            text = _("Custom…"),
            callback = edit_custom,
        }, function(item) item.mandatory = not is_preset(app:hybrid_notch_px()) and "✓" or nil end)
        item_table[#item_table + 1] = stays_open({
            text = _("Hybrid scroll distance"),
            help_text = _("How far the remote scrolls per wheel notch in Hybrid mode, in remote pixels. If the content moves further than your finger, pick a larger value; if less, a smaller one."),
            sub_item_table = notch_rows,
        }, function(item) item.mandatory = px_label(app:hybrid_notch_px()) end)
    end

    -- ---- keep the device awake while the viewer is up
    item_table[#item_table + 1] = stays_open({
        text = _("Keep screen on"),
        callback = function()
            settings.keep_screen_on = not settings.keep_screen_on
            plugin.settings:flush()
            app:_apply_keep_screen_on()
        end,
    }, function(item) item.mandatory = settings.keep_screen_on and "✓" or "-" end)

    -- ---- turn the screen to the remote's orientation after connecting (nothing turns right now)
    item_table[#item_table + 1] = stays_open({
        text = _("Match orientation to the remote screen"),
        help_text = _("After connecting, and when the remote screen changes between landscape and portrait, turn this screen the same way: to the landscape (or portrait) side you last picked by hand. A rotation you pick yourself is kept until the remote's orientation changes."),
        callback = function()
            settings.match_orientation = not settings.match_orientation
            plugin.settings:flush()
        end,
    }, function(item) item.mandatory = settings.match_orientation and "✓" or "-" end)

    -- ---- which buttons the toolbar shows: the bar is rebuilt and the area it covered repainted
    local function toolbar_row(text, ids, extra)
        local function shown() return Toolbar.is_enabled(settings, ids[1]) end
        local row = {
            text = text,
            callback = function()
                local on = not shown()
                -- the round button cannot stay without its way back: the bar opens first
                if ids[1] == "toggle" and not on then app:set_toolbar_collapsed(false) end
                local buttons = {}
                for k, v in pairs(type(settings.toolbar_buttons) == "table" and settings.toolbar_buttons or {}) do
                    buttons[k] = v
                end
                for _i, id in ipairs(ids) do buttons[id] = on end
                settings.toolbar_buttons = buttons
                plugin.settings:flush()
                app:_toolbar_changed()
            end,
        }
        for k, v in pairs(extra or {}) do row[k] = v end
        return stays_open(row, function(item) item.mandatory = shown() and "✓" or "-" end)
    end
    -- ---- which of them stay on the collapsed toolbar: only those the full bar shows
    local function pinned_row(text, ids)
        local function on_bar() return Toolbar.is_enabled(settings, ids[1]) end
        local function pinned()
            return Toolbar.is_pinned(settings, ids[1])
        end
        return stays_open({
            text = text,
            select_enabled_func = on_bar,
            callback = function()
                local on = not pinned()
                local list = {}
                for k, v in pairs(type(settings.toolbar_pinned) == "table" and settings.toolbar_pinned or {}) do
                    list[k] = v
                end
                for _i, id in ipairs(ids) do list[id] = on end
                settings.toolbar_pinned = list
                plugin.settings:flush()
                app:_toolbar_changed()
            end,
        }, function(item)
            item.mandatory = pinned() and "✓" or "-"
            item.dim = not on_bar() or nil
        end)
    end
    local has_frontlight = Device:hasFrontlight()
    local collapsed_rows = {
        pinned_row(_("Display"), { "display" }),
        pinned_row(_("Zoom"), { "zoom" }),
        pinned_row(_("Mode"), { "mode" }),
        pinned_row(_("Keyboard"), { "keyboard" }),
        pinned_row(_("Scroll up/down"), { "scroll_up", "scroll_down" }),
    }
    if has_frontlight then collapsed_rows[#collapsed_rows + 1] = pinned_row(_("Brightness"), { "brightness" }) end
    collapsed_rows[#collapsed_rows + 1] = pinned_row(_("Contrast"), { "contrast" })
    collapsed_rows[#collapsed_rows + 1] = pinned_row(_("Invert"), { "invert" })
    collapsed_rows[#collapsed_rows + 1] = pinned_row(_("More"), { "more" })
    item_table[#item_table + 1] = {
        text = _("Toolbar buttons…"),
        sub_item_table = {
            {
                text = _("On the toolbar…"),
                help_text = _("Which buttons the toolbar shows. Close and More are always there: More is the only way to this menu on a device without keys."),
                sub_item_table = {
                    toolbar_row(_("Collapse button"), { "toggle" }, {
                        help_text = _("Folds the toolbar into a small round button; a tap on that opens it again."),
                    }),
                    toolbar_row(_("Display"), { "display" }),
                    toolbar_row(_("Zoom"), { "zoom" }),
                    toolbar_row(_("Mode"), { "mode" }),
                    toolbar_row(_("Keyboard"), { "keyboard" }),
                    toolbar_row(_("Scroll up/down"), { "scroll_up", "scroll_down" }),
                    toolbar_row(_("Brightness"), { "brightness" }, {
                        help_text = has_frontlight and _("KOReader's frontlight dialog.")
                            or _("This device has no frontlight: the button is never shown."),
                        dim = not has_frontlight or nil,
                        select_enabled = has_frontlight,
                    }),
                    toolbar_row(_("Contrast"), { "contrast" }, {
                        help_text = _("The contrast of the remote picture as it is drawn here."),
                    }),
                    toolbar_row(_("Invert"), { "invert" }, {
                        help_text = _("Draws the remote picture inverted (light on dark and the other way round)."),
                    }),
                },
            },
            {
                text = _("Also when collapsed…"),
                help_text = _("Buttons that stay next to the round button when the toolbar is collapsed. Only buttons the toolbar shows can stay (the others are greyed out)."),
                sub_item_table = collapsed_rows,
            },
        },
    }

    -- ---- help, session
    item_table[#item_table + 1] = {
        text = _("Help"),
        callback = action(function() app:open_help() end),
    }
    item_table[#item_table + 1] = {
        text = _("Leave (keep connection)"),
        callback = action(function() app:leave() end),
    }

    menu = VncMenu:new{
        title = title,
        item_table = item_table,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        -- The menu covers the framebuffer view, so UIManager must composite from us instead of
        -- repainting the viewer underneath on every tick. Every full-screen menu in core says so
        -- (c.f. frontend/ui/widget/booklist.lua, keyvaluepage.lua, filemanagercollection.lua).
        covers_fullscreen = true,
        close_callback = function()
            -- Still set: the stock close paths (X, Back) get here without app:close_menu(), and
            -- `UIManager:close` asked for no refresh. The viewer repaints in full, which also
            -- carries whatever the open menu changed (scaling, rotation).
            if app.menu then
                UIManager:setDirty(app, "flashui")
            end
            app.menu = nil
            app:_sync_keyboard_later()
        end,
    }
    menu.hold_confirm = app.HOLD_CONFIRM or menu.hold_confirm
    -- A menu over a framebuffer view is a wholesale change: without a flash the panel would keep
    -- the desktop where the menu belongs, and the viewer's per-rectangle refreshes would only ever
    -- push a band of it. Core's TouchMenu flashes its first popup for exactly this reason.
    UIManager:show(menu, "flashui")
    return menu
end

return MenuBuilder
