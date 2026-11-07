--[[--
The in-app menu.

Built fresh on every open, so the checkmarks and the status row always reflect the live
session state.

@module vnc.menu
]]

local _ = require("gettext")
local T = require("ffi/util").template

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")

local Dialogs = require("vnc/dialogs")

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

    -- ---- keyboard
    item_table[#item_table + 1] = stays_open({
        text = _("Keyboard always visible"),
        callback = function()
            settings.keyboard_always_visible = not settings.keyboard_always_visible
            plugin.settings:flush()
            app:evaluate_keyboard()
        end,
    }, function(item) item.mandatory = settings.keyboard_always_visible and "✓" or "-" end)
    item_table[#item_table + 1] = {
        -- Driven by the wish, not by the current state: while this very menu is open the
        -- keyboard is hidden, but the item must still describe what tapping it does.
        text = app:is_keyboard_wanted() and _("Hide keyboard") or _("Show keyboard"),
        callback = action(function() app:toggle_keyboard() end),
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

    -- ---- any key or hotkey the on-screen keyboard cannot send
    item_table[#item_table + 1] = {
        text = _("Send keys…"),
        help_text = _("A panel at the bottom of the screen with Ctrl, Shift, Alt and Super, special and function keys, letters and symbols. Tap a modifier to use it once: with the next key from the panel, or with the next tap, long press or drag on the screen."),
        callback = action(function() app:open_key_panel() end),
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

    menu = VncMenu:new{
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
