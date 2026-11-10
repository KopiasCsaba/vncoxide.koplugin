--[[--
The in-app menu.

Built fresh on every open, so the checkmarks and the title (the connection's name and state)
always reflect the live session state. Naming: a row that switches something on or off is the plain
name of that thing, with ✓ or - beside it; a row that does something is a verb.

@module vnc.menu
]]

local _ = require("gettext")
local T = require("ffi/util").template

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")

local Dialogs = require("vnc/dialogs")
local Keysyms = require("vnc/keysyms")
local Toolbar = require("vnc/toolbar")

local MenuBuilder = {}

-- The title bar's X must close the whole menu; Menu's own wiring (like the Back key) only
-- steps up one submenu level.
local VncMenu = Menu:extend{}
function VncMenu:init()
    Menu.init(self)
    if self.title_bar and self.title_bar.right_button then
        self.title_bar.right_button.callback = function() self:onCloseAllMenus() end
    end
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
    -- A failed attempt must come back to a menu, not leave the user staring at the canvas.
    local function back_into_menu() app:open_menu() end
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
    item_table[#item_table + 1] = {
        text = _("Lock screen"),
        callback = action(function() app:send_combo{ Keysyms.x11.Super_L, 0x6C } end),
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
    local has_frontlight = Device:hasFrontlight()
    item_table[#item_table + 1] = {
        text = _("Toolbar buttons…"),
        help_text = _("Which buttons the toolbar shows. Close and More are always there: More is the only way to this menu on a device without keys."),
        sub_item_table = {
            toolbar_row(_("Collapse button"), { "toggle" }, {
                help_text = _("Folds the toolbar into a small round button; a tap on that opens it again."),
            }),
            toolbar_row(_("Display"), { "display" }),
            toolbar_row(_("Zoom"), { "zoom" }),
            toolbar_row(_("Mode"), { "mode" }),
            toolbar_row(_("Keyboard"), { "keyboard" }),
            toolbar_row(_("Rotate"), { "rotate" }),
            toolbar_row(_("Scroll lock"), { "scroll_lock" }),
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
