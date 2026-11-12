#!/usr/bin/env luajit
--[[--
Headless test for the viewer's UI plumbing: the connection dialogs' back-flow and the toolbar's
reflow on rotation.

It drives the real @{vnc.main} plugin, its @{vnc.dialogs} and a real
@{vnc.app} against KOReader's widget stack (no KOReader process and no VNC server are
needed; a profile pointing at a closed port is used to exercise the failure path).

Run it from the KOReader root, with a writable data directory (KOReader wants a `cache/` dir):

  cd /usr/lib/koreader
  PLUGIN=~/.config/koreader/plugins/vnc.koplugin
  KO_HOME=/tmp/vncv_ui_home \
    LUA_PATH="$PLUGIN/?.lua;;" LUA_CPATH="./common/?.so;;" \
    ./luajit "$PLUGIN/tools/ui_smoke.lua"

Prints one `ok - <name>` line per check and exits 0 on success, 1 on the first failure.
]]

dofile("setupkoenv.lua")

local lfs = require("libs/libkoreader-lfs")
local tool_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local plugin_dir = tool_dir .. "/.."

-- The widget stack needs a settings store and a data directory (for its cache).
local data_dir = os.getenv("KO_HOME") or "/tmp/vncv_ui_home"
if lfs.attributes(data_dir, "mode") ~= "directory" then
    lfs.mkdir(data_dir)
end
if lfs.attributes(data_dir .. "/cache", "mode") ~= "directory" then
    lfs.mkdir(data_dir .. "/cache")
end
_G.G_reader_settings = require("luasettings"):open(data_dir .. "/ui_smoke_settings.lua")
_G.G_reader_settings:flush()
_G.G_defaults = require("luasettings"):wrap(dofile("defaults.lua"))

local Device = require("device")
require("document/canvascontext"):init(Device)
local Screen = Device.screen
local Geom = require("ui/geometry")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")

package.path = plugin_dir .. "/?.lua;" .. package.path

-- ---------------------------------------------------------------- helpers

local failures = 0
local function check(name, fn)
    UIManager._window_stack = {}
    local ok, err = pcall(fn)
    UIManager._window_stack = {}
    if ok then
        print("ok - " .. name)
    else
        failures = failures + 1
        print(string.format("FAIL: %s: %s", name, tostring(err)))
    end
end

local function assert_true(value, message)
    if not value then error(message or "assertion failed", 2) end
end

local function stack()
    local out = {}
    for _, entry in ipairs(UIManager._window_stack) do out[#out + 1] = entry.widget end
    return out
end
local function top() local s = stack() return s[#s] end
local function stack_desc()
    local out = {}
    for _, w in ipairs(stack()) do
        local kind = "other"
        if w.title == "Connections" and w.item_table then kind = "list"
        elseif w.input_fields then kind = "editor"
        elseif w.ok_callback then kind = "confirm"
        elseif w.buttons then kind = "actions"
        elseif w.text then kind = "message" end
        out[#out + 1] = kind
    end
    return table.concat(out, " > ")
end
local function is_list(w) return w ~= nil and w.title == "Connections" and w.item_table ~= nil end
local function is_editor(w) return w ~= nil and w.input_fields ~= nil end
local function is_actions(w)
    return w ~= nil and w.buttons ~= nil and w.ok_callback == nil and w.input_fields == nil
        and w.buttons[1] ~= nil and w.buttons[1][1] ~= nil and w.buttons[1][1].text == "Connect"
end
local function count(pred)
    local n = 0
    for _, w in ipairs(stack()) do if pred(w) then n = n + 1 end end
    return n
end
local function expect_top(pred, what)
    assert_true(pred(top()), string.format("expected %s on top, stack: %s", what, stack_desc()))
end
local function find_button(widget, text)
    for _, row in ipairs(widget.buttons or {}) do
        for _, btn in ipairs(row) do
            if btn.text == text then return btn end
        end
    end
    error(string.format("no %q button in %s", text, stack_desc()), 2)
end
--- The button `text` in the row right under the disabled caption row `caption`.
local function find_in_section(widget, caption, text)
    for i, row in ipairs(widget.buttons or {}) do
        if #row == 1 and row[1].text == caption then
            assert_true(row[1].enabled == false, caption .. " is not tappable")
            for _, btn in ipairs(widget.buttons[i + 1] or {}) do
                if btn.text == text then return btn end
            end
        end
    end
    error(string.format("no %q under %q in %s", text, caption, stack_desc()), 2)
end
local QUALITY, SPEED = "Picture quality (reconnects)", "Pointer speed (mouse mode)"
local function find_item(item_table, text)
    for _, item in ipairs(item_table or {}) do
        if item.text == text then return item end
    end
    error(string.format("no %q entry", text), 2)
end
--- Calls a list entry's callback, then runs the menu's own close callback like Menu does.
local function choose(plugin, text)
    find_item(plugin.connection_list.item_table, text).callback()
end
--- Runs UIManager's due tasks until no session of `plugin` is connecting (a connect runs in ticks).
local function settle_connects(plugin)
    local socket = require("socket")
    local deadline = socket.gettime() + 10
    local function busy()
        for _, s in pairs(plugin.sessions) do if s.state == "connecting" then return true end end
    end
    repeat UIManager:_checkTasks(); socket.sleep(0.005) until not busy() or socket.gettime() > deadline
end
--- Emulates a ConfirmBox button (its callbacks run before it closes, c.f. confirmbox.lua).
local function answer_confirm(confirm, yes)
    if yes then confirm.ok_callback() else confirm.cancel_callback() end
    UIManager:close(confirm)
end

--- Reads a whole file as bytes (for the settings-file identity checks).
local function slurp(path)
    local f = assert(io.open(path, "rb"))
    local content = f:read("*a")
    f:close()
    return content
end

--- Delivers a gesture the way `Device.input` does: through the real widget stack, so whatever is
--- on top gets the first chance to consume it.
local function dispatch_gesture(ges)
    UIManager:sendEvent(Event:new("Gesture", ges))
end

--- A long press of the viewer's acts once confirmed (see ViewerApp.HOLD_CONFIRM): lets that time
--- pass now, the finger still down. No-op when no long press waits for it.
local function confirm_hold(app)
    if app and app._hold_pending then
        UIManager:unschedule(app._hold_confirm_task)
        app._hold_confirm_task()
    end
end

-- ---------------------------------------------------------------- a plugin with two profiles

local plugin_module = assert(dofile(plugin_dir .. "/main.lua"))
plugin_module.name = "vnc"
local settings_path = data_dir .. "/ui_smoke_store.lua"
os.remove(settings_path)
os.remove(settings_path .. ".old")
local plugin = plugin_module:new{ ui = { menu = { registerToMainMenu = function() end } } }
plugin.settings.ls.close = nil -- (the store is a plain object in this test)
local store = plugin.settings
store:save_profile{ name = "good", host = "127.0.0.1", port = 5900 }
store:save_profile{ name = "dead", host = "127.0.0.1", port = 1 } -- nothing listens there
store:flush()
plugin.settings_file = settings_path

-- ---------------------------------------------------------------- checks

check("connection_list_root", function()
    plugin:show_connection_list()
    expect_top(is_list, "the connection list")
    assert_true(plugin.connection_list == top(), "the plugin must track the open list")
    assert_true(count(is_list) == 1, "exactly one list: " .. stack_desc())
    -- every profile is listed, plus the two extras
    local names = {}
    for _, item in ipairs(plugin.connection_list.item_table) do names[#names + 1] = item.text end
    assert_true(#names == 4, "4 entries, got: " .. table.concat(names, ","))
end)

check("editor_cancel_returns_to_list", function()
    plugin:show_connection_list()
    choose(plugin, "New connection…")
    expect_top(is_editor, "the editor")
    assert_true(count(is_list) == 0, "the list must be closed while the editor is up")
    find_button(top(), "Cancel").callback()
    expect_top(is_list, "the list after cancelling the editor")
    assert_true(plugin.connection_list == top(), "the reopened list must be tracked")
    assert_true(count(is_list) == 1, "no stacked lists: " .. stack_desc())
end)

check("editor_save_returns_to_list", function()
    plugin:show_connection_list()
    choose(plugin, "New connection…")
    local editor = top()
    editor.input_fields[1]:setText("fresh")
    editor.input_fields[2]:setText("10.0.0.7")
    editor.input_fields[3]:setText("5901")
    find_button(editor, "Save").callback()
    expect_top(is_list, "the list after saving")
    local saved = store:get_profile("fresh")
    assert_true(saved and saved.host == "10.0.0.7" and saved.port == 5901, "the profile must be saved")
    assert_true(count(is_list) == 1, "no stacked lists: " .. stack_desc())
end)

check("editor_rejects_without_closing", function()
    plugin:show_connection_list()
    choose(plugin, "New connection…")
    local editor = top()
    editor.input_fields[1]:setText("")            -- no name
    find_button(editor, "Save").callback()
    local kept = false
    for _, w in ipairs(stack()) do if w == editor then kept = true end end
    assert_true(kept, "a rejected save must leave the editor open: " .. stack_desc())
    assert_true(count(function(w) return w ~= editor and w.text ~= nil end) == 1,
        "and must say why once: " .. stack_desc())
    UIManager:close(top())                        -- dismiss the message
    find_button(editor, "Cancel").callback()
    expect_top(is_list, "the list after cancelling")
    -- duplicate name is rejected too
    choose(plugin, "New connection…")
    editor = top()
    editor.input_fields[1]:setText("good")
    editor.input_fields[2]:setText("h")
    find_button(editor, "Save").callback()
    kept = false
    for _, w in ipairs(stack()) do if w == editor then kept = true end end
    assert_true(kept, "a duplicate name must leave the editor open")
end)

check("actions_back_returns_to_list", function()
    plugin:show_connection_list()
    find_item(find_item(plugin.connection_list.item_table, "Manage connections…").sub_item_table, "good").callback()
    expect_top(is_actions, "the actions dialog")
    assert_true(count(is_list) == 0, "the list must be closed while the actions dialog is up")
    find_button(top(), "Back").callback()
    expect_top(is_list, "the list after Back")
    assert_true(count(is_list) == 1, "no stacked lists: " .. stack_desc())
end)

check("actions_edit_cancel_returns_to_actions", function()
    plugin:show_connection_list()
    find_item(find_item(plugin.connection_list.item_table, "Manage connections…").sub_item_table, "good").callback()
    find_button(top(), "Edit").callback()
    expect_top(is_editor, "the editor")
    find_button(top(), "Cancel").callback()
    expect_top(is_actions, "the actions dialog after cancelling the editor")
end)

check("delete_confirm_cancel_returns_to_actions", function()
    plugin:show_connection_list()
    find_item(find_item(plugin.connection_list.item_table, "Manage connections…").sub_item_table, "good").callback()
    find_button(top(), "Delete").callback()
    local confirm = top()
    assert_true(confirm.ok_callback and confirm.cancel_callback, "expected a ConfirmBox: " .. stack_desc())
    answer_confirm(confirm, false)
    expect_top(is_actions, "the actions dialog after cancelling the delete")
    assert_true(store:get_profile("good"), "cancel must not delete")
end)

check("delete_confirm_ok_returns_to_list", function()
    plugin:show_connection_list()
    find_item(find_item(plugin.connection_list.item_table, "Manage connections…").sub_item_table, "good").callback()
    find_button(top(), "Delete").callback()
    answer_confirm(top(), true)
    expect_top(is_list, "the list after deleting")
    assert_true(not store:get_profile("good"), "the named profile must be deleted")
    assert_true(store:get_profile("dead"), "the other profile must survive")
    assert_true(plugin.sessions["good"] == nil, "no session for a deleted profile")
    -- put it back for the remaining checks
    store:save_profile{ name = "good", host = "127.0.0.1", port = 5900 }
    store:flush()
end)

check("failed_connect_returns_to_list", function()
    plugin:show_connection_list()
    choose(plugin, "dead")                        -- closed port: connection refused
    settle_connects(plugin)
    expect_top(function(w) return w ~= nil and w.text ~= nil and w.buttons == nil end,
        "the connection error message")
    assert_true(count(is_list) == 1, "the list must be back under the message: " .. stack_desc())
    assert_true(count(function(w) return w.text ~= nil and w.buttons == nil and w.options_stack == nil end) == 1,
        "exactly one error message: " .. stack_desc())
    assert_true(plugin.sessions["dead"] == nil, "a session that never connected must be dropped")
    UIManager:close(top())
    expect_top(is_list, "the list after dismissing the error")
    assert_true(plugin.connection_list == top(), "the list must stay tracked")
    assert_true(count(is_list) == 1, "no stacked lists: " .. stack_desc())
end)

--- Every Display panel zoom choice survives a restart: the numeric presets (100%, ...) used to be
--- dropped on load, the type of the default being a string, so the viewer reopened fitted.
check("every_zoom_choice_survives_a_restart", function()
    local Settings = require("vnc/settings")
    local DisplayPanel = require("vnc/displaypanel")
    local path = data_dir .. "/ui_smoke_zoom_mode.lua"
    for _i, choice in ipairs(DisplayPanel.ZOOM_CHOICES) do
        os.remove(path)
        local s = Settings.open(path)
        s.data.settings.zoom_mode = choice.value
        s:flush()
        local back = Settings.open(path).data.settings.zoom_mode
        assert_true(back == choice.value, "zoom " .. tostring(choice.value) .. " came back as " .. tostring(back))
    end
    os.remove(path)
    local s = Settings.open(path)
    s.data.settings.zoom_mode = 3 -- not a preset
    s:flush()
    assert_true(Settings.open(path).data.settings.zoom_mode == "fit", "an unknown zoom must fall back to fit")
    os.remove(path)
end)

-- ---------------------------------------------------------------- auto connect on start

check("autoconnect_flag_round_trips", function()
    local Settings = require("vnc/settings")
    local path = data_dir .. "/ui_smoke_autoconnect_roundtrip.lua"
    os.remove(path)
    os.remove(path .. ".old")

    -- off by default
    local s = Settings.open(path)
    s:save_profile{ name = "a", host = "h1", port = 5900 }
    s:save_profile{ name = "b", host = "h2", port = 5901 }
    assert_true(s:get_profile("a").autoconnect == false, "a profile defaults to no autoconnect")
    assert_true(s:autoconnect_profile() == nil, "and nothing is flagged")

    -- set it on one profile and write the file
    s:save_profile({ name = "a", host = "h1", port = 5900, autoconnect = true }, "a")
    s:flush()
    assert_true(s:autoconnect_profile().name == "a", "the store reports the flagged profile")
    local on_disk = dofile(path)
    assert_true(on_disk.profiles[1].autoconnect == true, "the flag is written to the settings file")
    assert_true(on_disk.profiles[2].autoconnect == false, "the other profile is written without it")
end)

check("autoconnect_flag_is_kept_by_an_edit_and_cleared_by_another", function()
    -- on the shared store, so the UI checks below can rely on its profiles
    store:set_autoconnect(nil)
    store:save_profile({ name = "good", host = "127.0.0.1", port = 5900, autoconnect = true }, "good")
    assert_true(store:get_profile("good").autoconnect == true, "good is flagged")

    -- an editor that does not know the field must not clear it
    store:save_profile({ name = "good", host = "127.0.0.1", port = 5900 }, "good")
    assert_true(store:get_profile("good").autoconnect == true,
        "an edit that does not mention autoconnect must keep the flag")

    -- flagging another profile clears the first (only one may carry it)
    store:save_profile({ name = "dead", host = "127.0.0.1", port = 1, autoconnect = true }, "dead")
    assert_true(store:get_profile("dead").autoconnect == true, "the new profile is flagged")
    assert_true(store:get_profile("good").autoconnect == false, "and the old one is cleared")

    -- and the file agrees
    store:flush()
    local on_disk = dofile(store.ls.file)
    for _, p in ipairs(on_disk.profiles) do
        if p.name == "dead" then assert_true(p.autoconnect == true, "dead is flagged on disk") end
        if p.name == "good" then assert_true(p.autoconnect == false, "good is clear on disk") end
    end

    store:set_autoconnect(nil)
    store:flush()
end)

check("settings_normalise_keeps_a_single_autoconnect", function()
    -- A hand-edited file may flag several profiles; loading must normalise it down to one.
    local Settings = require("vnc/settings")
    local writeToFile = require("util").writeToFile
    local path = data_dir .. "/ui_smoke_autoconnect_normalise.lua"
    os.remove(path)
    os.remove(path .. ".old")
    writeToFile([==[
{
    ["profiles"] = {
        { ["name"] = "first", ["host"] = "h1", ["port"] = 5900, ["autoconnect"] = true },
        { ["name"] = "second", ["host"] = "h2", ["port"] = 5901, ["autoconnect"] = true },
        { ["name"] = "third", ["host"] = "h3", ["port"] = 5902, ["autoconnect"] = "yes" },
    },
}
]==], path, true, true)

    local s = Settings.open(path)
    assert_true(s.data.profiles[1].autoconnect == true, "the first flagged profile keeps the flag")
    assert_true(s.data.profiles[2].autoconnect == false, "a second one is cleared on load")
    assert_true(s.data.profiles[3].autoconnect == false, "a hand-written non-boolean is not a flag")
    assert_true(s:autoconnect_profile().name == "first", "exactly one profile is flagged")

    s:set_autoconnect("second")
    assert_true(s:autoconnect_profile().name == "second", "setting one moves the flag")
    assert_true(s.data.profiles[1].autoconnect == false, "clearing the previous one")
    s:flush()
    local on_disk = dofile(path)
    assert_true(on_disk.profiles[2].autoconnect == true and on_disk.profiles[1].autoconnect == false,
        "and the single flag is what gets written")
end)

check("actions_toggle_autoconnect_and_list_marks_it", function()
    store:set_autoconnect(nil)
    plugin:show_connection_list()
    local function open_actions()
        find_item(find_item(plugin.connection_list.item_table, "Manage connections…").sub_item_table,
            "good").callback()
    end
    local function listed(name)
        for _, item in ipairs(plugin.connection_list.item_table) do
            if item.text == name or item.text == name .. " (auto connect)" then return item.text end
        end
    end

    assert_true(listed("good") == "good", "an unflagged profile is listed by its name")
    open_actions()
    expect_top(is_actions, "the actions dialog")
    find_button(top(), "Auto connect on start: off").callback()
    assert_true(store:get_profile("good").autoconnect == true, "the toggle must flag the profile")
    expect_top(is_actions, "the actions dialog reopened after the toggle")
    find_button(top(), "Auto connect on start: on")   -- its label must reflect the new state
    find_button(top(), "Back").callback()
    expect_top(is_list, "the list after the toggle")
    assert_true(listed("good") == "good (auto connect)",
        "the list must mark the flagged profile, got " .. tostring(listed("good")))
    assert_true(listed("dead") == "dead", "and leave an unflagged one alone")

    -- toggling off clears it and the marker
    open_actions()
    find_button(top(), "Auto connect on start: on").callback()
    assert_true(store:get_profile("good").autoconnect == false, "toggling off must clear it")
    find_button(top(), "Back").callback()
    assert_true(listed("good") == "good", "the marker must be gone, got " .. tostring(listed("good")))
    plugin:close_connection_list()
    UIManager._window_stack = {}
end)

check("boot_autoconnect_connects_only_the_flagged_profile", function()
    -- The network is stubbed (this is the boot *decision*, not a dial-out).
    store:set_autoconnect(nil)
    local real_connect = plugin.connect_profile
    local calls = {}
    plugin.connect_profile = function(_, name) calls[#calls + 1] = name end
    local ok, err = pcall(function()
        -- nothing flagged: the deferred tick must connect to nothing
        plugin:schedule_autoconnect()
        UIManager:_checkTasks()
        assert_true(#calls == 0, "with nothing flagged the boot must not connect")

        -- flagged: one attempt, for that profile, deferred to the tick
        store:set_autoconnect("good")
        plugin:schedule_autoconnect()
        assert_true(#calls == 0, "the connect must be deferred, not immediate")
        UIManager:_checkTasks()
        assert_true(#calls == 1 and calls[1] == "good",
            "the tick must connect the flagged profile once, got: " .. table.concat(calls, ","))

        -- and it does not re-arm
        UIManager:_checkTasks()
        assert_true(#calls == 1, "a second tick must not connect again")
    end)
    plugin.connect_profile = real_connect
    store:set_autoconnect(nil)
    store:flush()
    if not ok then error(err, 0) end
end)

check("boot_autoconnect_failure_is_reported_like_a_manual_one", function()
    -- "dead" points at a closed port, so the attempt fails deterministically (and locally).
    plugin.sessions = {}
    plugin.app = nil
    store:set_autoconnect("dead")
    local ok, err = pcall(function()
        plugin:schedule_autoconnect()
        UIManager:_checkTasks()
        settle_connects(plugin)
    end)
    store:set_autoconnect(nil)
    store:flush()
    assert_true(ok, "a failed boot connect must not raise: " .. tostring(err))
    local message
    for _, w in ipairs(stack()) do
        if type(w.text) == "string" and w.text:find("Could not connect to dead", 1, true) then
            message = w.text
        end
    end
    assert_true(message ~= nil, "the boot failure must be reported: " .. stack_desc())
    assert_true(plugin.app == nil, "no viewer may be opened on a failed boot connect")
    assert_true(plugin.sessions["dead"] == nil, "a session that never connected must be dropped")
    UIManager:close(top())
    UIManager._window_stack = {}
end)

check("start_with_entry_lands_in_the_submenu_only_while_flagged", function()
    -- The extension point is `sorting_hint = "start_with"`: KOReader's own MenuSorter nests such an
    -- item into the "Start with" submenu (whose id comes from ui/elements/filemanager_menu_order).
    local FileManagerMenu = require("apps/filemanager/filemanagermenu")
    local MenuSorter = require("ui/menusorter")
    local order = require("ui/elements/filemanager_menu_order")

    local function built_menu()
        local menu_items = {
            ["KOMenu:menu_buttons"] = {},
            filemanager_settings = { icon = "appbar.filebrowser" },
            setting = { icon = "appbar.settings" },
            tools = { icon = "appbar.tools" },
            search = { icon = "appbar.search" },
            main = { icon = "appbar.menu" },
            start_with = FileManagerMenu.getStartWithMenuTable({}),
        }
        plugin:addToMainMenu(menu_items)
        -- this scoped probe only has ids for the file-manager menus; drop the plugin's other items
        menu_items.vnc = nil
        menu_items.vnc_server = nil
        return menu_items, MenuSorter:mergeAndSort("filemanager", menu_items, order)
    end
    local function find_start_with(tbl)
        for _, it in pairs(tbl) do
            if type(it) == "table" then
                if it.id == "start_with" then return it end
                -- merged tabs are plain arrays of their items; items may nest via sub_item_table
                local found = find_start_with(it.sub_item_table or it)
                if found then return found end
            end
        end
    end
    local function texts(item)
        local items = item.sub_item_table_func and item.sub_item_table_func() or item.sub_item_table
        local out = {}
        for _, i in ipairs(items) do out[#out + 1] = i.text or (i.text_func and i.text_func()) end
        return out, items
    end
    local function index_of(list, text)
        for i, t in ipairs(list) do if t == text then return i end end
    end

    -- nothing flagged: KOReader's own five entries, and no VNC one
    store:set_autoconnect(nil)
    G_reader_settings:saveSetting("start_with", "filemanager")
    local _mi, built = built_menu()
    local sw = find_start_with(built)
    assert_true(sw ~= nil, "the core Start with submenu must still be there")
    local names = texts(sw)
    assert_true(#names == 5, "the core offers its five entries, got: " .. table.concat(names, ", "))
    assert_true(index_of(names, "VNC auto connect") == nil,
        "with nothing flagged the entry must be absent, got: " .. table.concat(names, ", "))

    -- flagged: the sorter nests the item at the end of the submenu, and it is offered
    store:set_autoconnect("good")
    local _mi2, built2 = built_menu()
    sw = find_start_with(built2)
    local sorted = sw.sub_item_table
    assert_true(sorted[#sorted].text == "VNC auto connect",
        "MenuSorter must nest the entry inside the submenu (last), got: "
        .. tostring(sorted[#sorted].text))
    local entry = sorted[#sorted]
    assert_true(entry.sorting_hint == "start_with", "it carries the documented sorting hint")
    names = texts(sw)
    assert_true(index_of(names, "VNC auto connect") == #names,
        "and it is offered last: " .. table.concat(names, ", "))

    -- the tick/callback: on records the choice, off clears the flag and the choice together
    assert_true(entry.checked_func() == false, "unticked while the stored setting is not ours")
    entry.callback()
    assert_true(G_reader_settings:readSetting("start_with") == plugin.START_WITH,
        "toggling on must store the plugin's value")
    assert_true(store:autoconnect_profile() ~= nil and store:autoconnect_profile().name == "good",
        "and keep the profile flagged")
    assert_true(entry.checked_func() == true, "so it reads as ticked")
    entry.callback()
    assert_true(G_reader_settings:readSetting("start_with") ~= plugin.START_WITH,
        "toggling off must clear the stored choice")
    assert_true(store:autoconnect_profile() == nil, "and the profile flag")
    assert_true(index_of(texts(sw), "VNC auto connect") == nil,
        "and the entry must then be gone from the submenu")

    -- the label: core cannot name our value, the additive wrapper can; the core values still work
    local core_item = FileManagerMenu.getStartWithMenuTable({})
    G_reader_settings:saveSetting("start_with", plugin.START_WITH)
    assert_true(core_item.text_func() == nil,
        "core alone labels our value as nothing (hence the wrapper)")
    assert_true(sw.text_func() == "Start with: VNC auto connect",
        "the wrapper names it, got: " .. tostring(sw.text_func()))
    G_reader_settings:saveSetting("start_with", "history")
    assert_true(sw.text_func() == "Start with: history",
        "and every core value still goes to the core label, got: " .. tostring(sw.text_func()))
    G_reader_settings:saveSetting("start_with", "filemanager")
    store:set_autoconnect(nil)
    store:flush()
end)

check("start_with_naming_us_without_a_flag_is_a_normal_start", function()
    -- KOReader's core only special-cases its own values; our sentinel is not one of them, so a
    -- stale `start_with` leaves it starting in the file browser. The plugin must then do nothing
    -- but log it.
    assert_true(plugin.START_WITH ~= "filemanager" and plugin.START_WITH ~= "last"
        and plugin.START_WITH ~= "history" and plugin.START_WITH ~= "favorites"
        and plugin.START_WITH ~= "folder_shortcuts",
        "our value must be one reader.lua does not know, so it falls back to the file browser")

    store:set_autoconnect(nil)
    G_reader_settings:saveSetting("start_with", plugin.START_WITH)
    local logger = require("logger")
    local real_warn, warned = logger.warn, {}
    logger.warn = function(...) warned[#warned + 1] = table.concat({ ... }, " ") end
    local real_connect = plugin.connect_profile
    local calls = 0
    plugin.connect_profile = function() calls = calls + 1 end
    local ok, err = pcall(function()
        plugin:schedule_autoconnect()
        UIManager:_checkTasks()
    end)
    logger.warn = real_warn
    plugin.connect_profile = real_connect
    G_reader_settings:saveSetting("start_with", "filemanager")
    store:flush()
    assert_true(ok, "a stale start_with must not raise: " .. tostring(err))
    assert_true(calls == 0, "and must not connect anything")
    local named = false
    for _, message in ipairs(warned) do
        if message:find("start_with", 1, true) and message:find(plugin.START_WITH, 1, true) then
            named = true
        end
    end
    assert_true(named, "the stale setting must be logged: " .. table.concat(warned, " | "))
end)

-- ---------------------------------------------------------------- a real viewer widget

--- Builds a shown viewer app with a fake session and plugin (no network involved).
--- @tparam[opt] number plane_w, plane_h the remote plane's size (400x300 by default)
--- @treturn table, table, table the app, its remote plane and a record of what it sent
local function new_app(plane_w, plane_h, opts)
    local ViewerApp = require("vnc/app")
    local Remote = require("vnc/framebuffer")
    local remote = Remote.new(plane_w or 400, plane_h or 300)
    local sent = { pointer = {}, key = {}, input = 0, areas = {}, profile_updates = {}, full_updates = 0,
                   connects = {}, attaches = 0, hangups = 0 }
    local profile = { name = "test", pointer_mode = opts and opts.mode or "touch",
                      color_depth = 24, enable_tight = false, jpeg_quality = false, compress_level = false }
    local stored = {}   -- what the settings file holds; `profile` is the session's live one
    for k, v in pairs(profile) do stored[k] = v end
    local app = ViewerApp:new{
        plugin = {
            settings = {
                data = { settings = { orientation = 0, keyboard_shown = false,
                                      keep_screen_on = true, zoom_mode = "fit" } },
                profiles = function() return {} end,
                get_profile = function() return stored end,
                flush = function() end,
            },
            leave_app = function() end,
            disconnect_session = function() end,
            connect_profile = function() end,
            update_profile_fields = function(_, name, fields)
                sent.profile_updates[#sent.profile_updates + 1] = { name = name, fields = fields }
                for k, v in pairs(fields) do stored[k] = v; profile[k] = v end
                return true
            end,
        },
        session = {
            set_profile = function(_, p) profile = p end,
            get_remote = function() return remote end,
            send_pointer = function(_, x, y, mask)
                sent.pointer[#sent.pointer + 1] = { x = x, y = y, mask = mask }
            end,
            send_key = function(_, keysym, down) sent.key[#sent.key + 1] = { keysym = keysym, down = down } end,
            note_input = function() sent.input = sent.input + 1 end,
            request_full_update = function() sent.full_updates = sent.full_updates + 1 end,
            set_view_area = function(_, rect) sent.areas[#sent.areas + 1] = rect end,
            state = opts and opts.state or "connected",
            get_state = function(s_) return s_.state end,
            is_connected = function(s_) return s_.state == "connected" end,
            -- like Session:connect, a live connection refuses a second one
            connect = function(s_, cb)
                if s_.state == "connected" then
                    cb(false, "already connecting or connected")
                    return
                end
                sent.connects[#sent.connects + 1] = cb
            end,
            attach = function() sent.attaches = sent.attaches + 1 end,
            set_keep_wifi = function(_, on) sent.keep_wifi = on end,
            hangup = function(s_) sent.hangups = sent.hangups + 1; s_.state = "disconnected" end,
            get_error = function() return nil end,
            get_profile = function() return profile end,
        },
    }
    -- Shown the way main.lua shows it: a full-screen widget asks for its own refresh.
    UIManager:show(app, "full")
    -- most checks tap near the top of the screen: the toolbar stays out of their way
    if not (opts and opts.toolbar) then app:set_toolbar_visible(false) end
    return app, remote, sent
end

--- The centre of toolbar button `id`, after a repaint (a button only learns where it is when it
--- is painted).
local function toolbar_button_centre(app, id)
    UIManager:setDirty(app, "ui")
    UIManager:forceRePaint()
    local button = app.toolbar.button_by_id[id]
    assert_true(button ~= nil, "no toolbar button " .. id)
    local d = button.dimen
    return Geom:new{ x = d.x + math.floor(d.w / 2), y = d.y + math.floor(d.h / 2) }
end

--- Taps toolbar button `id` where a finger would: through the real widget stack.
local function tap_toolbar(app, id)
    UIManager:sendEvent(Event:new("Gesture", { ges = "tap", pos = toolbar_button_centre(app, id) }))
end

--- Long-presses toolbar button `id`, then lifts the finger there.
local function hold_toolbar(app, id)
    local pos = toolbar_button_centre(app, id)
    UIManager:sendEvent(Event:new("Gesture", { ges = "hold", pos = pos }))
    UIManager:sendEvent(Event:new("Gesture", { ges = "hold_release", pos = pos }))
end

check("pointer_mode_is_cleaned_and_kept_per_profile", function()
    local Settings = require("vnc/settings")
    local path = data_dir .. "/ui_smoke_pointer_mode.lua"; os.remove(path)
    local s = Settings.open(path)
    s:save_profile{ name = "m", host = "h", port = 1, pointer_mode = "mouse" }
    s:save_profile{ name = "j", host = "h", port = 1, pointer_mode = "joystick" }
    assert_true(s:get_profile("m").pointer_mode == "mouse")
    assert_true(s:get_profile("j").pointer_mode == "touch", "junk cleans to touch")
    s:save_profile({ name = "m", host = "h2", port = 1 }, "m")
    assert_true(s:get_profile("m").pointer_mode == "mouse", "an edit without the field keeps it")
    assert_true(s.data.settings.pointer_speed == "normal" and s.data.settings.toolbar_buttons.scroll_up == nil)
end)
check("canvas_covers_the_screen", function()
    local app, remote = new_app(nil, nil, { toolbar = true })
    local size = Screen:getSize()
    assert_true(app.canvas.x == 0 and app.canvas.y == 0,
        string.format("the canvas must start at the top left, got %s", tostring(app.canvas)))
    assert_true(app.canvas.w == size.w and app.canvas.h == size.h,
        string.format("the canvas (%dx%d) must cover the whole screen (%dx%d)",
            app.canvas.w, app.canvas.h, size.w, size.h))
    assert_true(app.toolbar_visible, "the toolbar floats over the canvas, it does not shrink it")

    -- and it follows a rotation
    local before = { w = app.canvas.w, h = app.canvas.h }
    app:set_rotation_mode((Screen:getRotationMode() + 1) % 4)
    size = Screen:getSize()
    assert_true(app.canvas.w == size.w and app.canvas.h == size.h,
        string.format("after rotation the canvas (%dx%d) must cover the screen (%dx%d)",
            app.canvas.w, app.canvas.h, size.w, size.h))
    assert_true(app.canvas.w ~= before.w or app.canvas.h ~= before.h,
        "the canvas must be re-laid out for the new orientation")
    assert_true(remote.scale > 0, "the view must still be usable")
    app:set_rotation_mode(Screen:getRotationMode())
    app:onCloseWidget()
    remote:free()
end)

check("zoom_modes_follow_the_keyboard", function()
    local app, remote = new_app()
    local size = Screen:getSize()
    local function near(a, b) return math.abs(a - b) < 1e-9 end

    -- the display panel offers both fitted modes, under the names users are looking for
    local panel = app:open_display_panel()
    local labels = {}
    for _, row in ipairs(panel.buttons) do
        for _, btn in ipairs(row) do labels[#labels + 1] = btn.text end
    end
    assert_true(labels[1] == "✓ Fit screen", "the first choice is \"Fit screen\", got " .. tostring(labels[1]))
    assert_true(labels[2] == "Fit (with keyboard)",
        "the second choice is \"Fit (with keyboard)\", got " .. tostring(labels[2]))
    app:close_display_panel()
    UIManager:_checkTasks()

    app:zoom_to("fit")
    local fit = math.min(size.w / 400, size.h / 300)
    assert_true(near(remote:get_scale(), fit),
        string.format("\"fit screen\" fits the screen: %s", remote:get_scale()))

    app:set_keyboard_visible(true)
    assert_true(app.vk:getSize().h > 0, "the keyboard must have a height")
    -- what the keyboard covers, with the key strip on top of it
    local kbd_h = app.vk:getSize().h + app.key_strip.dimen.h

    app:zoom_to("fit_with_keyboard")
    local fit_kbd = math.min(size.w / 400, (size.h - kbd_h) / 300)
    assert_true(near(remote:get_scale(), fit_kbd),
        string.format("\"fit (with keyboard)\" fits the space above the keyboard: %s", remote:get_scale()))
    assert_true(fit_kbd < fit, "which is smaller than fitting the screen here")

    -- it follows the keyboard, which is the point of the mode
    app:set_keyboard_visible(false)
    assert_true(near(remote:get_scale(), fit), "with the keyboard hidden it is a plain fit again")
    app:set_keyboard_visible(true)
    assert_true(near(remote:get_scale(), fit_kbd), "and it shrinks again when the keyboard returns")

    -- a fixed ratio is never touched by the keyboard
    app:zoom_to(0.5)
    assert_true(near(remote:get_scale(), 0.5), "a fixed ratio is applied as-is")
    app:set_keyboard_visible(false)
    app:set_keyboard_visible(true)
    assert_true(near(remote:get_scale(), 0.5), "and the keyboard does not change it")

    app:onCloseWidget()
    remote:free()
end)

check("a_view_that_fits_goes_above_the_keyboard", function()
    local app, remote = new_app()
    local size = Screen:getSize()

    app:set_keyboard_visible(true)
    assert_true(app.vk:getSize().h > 0, "the keyboard must have a height")
    -- what the keyboard covers, with the key strip on top of it
    local kbd_h = app.vk:getSize().h + app.key_strip.dimen.h

    -- 50% of the 400x300 plane is 200x150: it fits in the space the keyboard leaves
    app:zoom_to(0.5)
    assert_true(app.canvas.h == size.h - kbd_h,
        string.format("the canvas must be the space above the keyboard, got %d of %d", app.canvas.h, size.h))
    assert_true(remote:get_scale() == 0.5, "placing the view must not change the zoom")
    local cr = remote:canvas_rect_for({ x = 0, y = 0, w = 400, h = 300 })
    assert_true(cr ~= nil, "the whole remote screen must be visible")
    local dx, dy, dw, dh = app.canvas.x + cr.x, app.canvas.y + cr.y, cr.w, cr.h
    assert_true(dy >= app.canvas.y and dy + dh <= app.canvas.y + app.canvas.h + 1,
        string.format("the whole remote screen must be above the keyboard: y %d..%d, keyboard at %d",
            dy, dy + dh, app.canvas.y + app.canvas.h))
    assert_true(dx >= 0 and dx + dw <= size.w + 1, "and inside the screen horizontally")

    -- a view that cannot fit there keeps the full canvas
    app:zoom_to(4)
    assert_true(app.canvas.h == size.h, "a view too big for that space spans the screen")

    -- "fit screen" lands there too whenever its scale leaves the room for it
    app:zoom_to("fit")
    local fitted = 300 * remote:get_scale()
    if fitted <= size.h - kbd_h then
        assert_true(app.canvas.h == size.h - kbd_h, "a fitted view that leaves room goes above the keyboard")
    else
        assert_true(app.canvas.h == size.h, "one that does not fills the screen")
    end

    -- a pinch that lands on a fitting zoom is re-placed as well
    app:zoom_to(4)
    assert_true(app.canvas.h == size.h, "at 400% the view spans the screen")
    app:_live_zoom({ pos = { x = 100, y = 100 }, span = 50, start_span = 400 })
    app:onPinch()
    assert_true(remote:get_scale() < 1, "the pinch zoomed out")
    assert_true(app.canvas.h == size.h - kbd_h, "and the view moved above the keyboard")

    -- "fit (with keyboard)" always fits there, by choosing the scale
    app:zoom_to("fit_with_keyboard")
    assert_true(app.canvas.h == size.h - kbd_h, "the keyboard-aware fit uses the space above the keyboard")
    local cr2 = remote:canvas_rect_for({ x = 0, y = 0, w = 400, h = 300 })
    assert_true(cr2 ~= nil, "the whole remote screen must be visible")
    local dy2, dh2 = app.canvas.y + cr2.y, cr2.h
    assert_true(dy2 >= app.canvas.y and dy2 + dh2 <= app.canvas.y + app.canvas.h + 1,
        "and the whole remote screen is inside it")

    app:onCloseWidget()
    remote:free()
end)

check("keyboard_overlaps_without_rescaling", function()
    local app, remote = new_app()
    local size = Screen:getSize()
    -- a view too big for the space above the keyboard keeps the whole screen: the keyboard
    -- overlays it and the user pans
    app:zoom_to(4)
    local canvas = { w = app.canvas.w, h = app.canvas.h }
    local scale = remote.scale
    local view = { x = remote.view_x, y = remote.view_y }

    app:set_keyboard_visible(true)
    assert_true(app.vk_visible, "the keyboard must be visible")
    assert_true(app.vk:getSize().h > 0, "the keyboard must have a height")
    assert_true(app.canvas.w == canvas.w and app.canvas.h == canvas.h,
        "a view that cannot fit above the keyboard must keep the full canvas")
    assert_true(math.abs(remote.scale - scale) < 1e-9,
        string.format("showing the keyboard must not rescale the view (%s -> %s)", scale, remote.scale))
    assert_true(math.abs(remote.view_x - view.x) < 1e-9 and math.abs(remote.view_y - view.y) < 1e-9,
        "showing the keyboard must not move a view that does not fit above it")

    app:set_keyboard_visible(false)
    assert_true(not app.vk_visible, "the keyboard must hide again")
    assert_true(math.abs(remote.scale - scale) < 1e-9, "hiding it must not rescale either")
    assert_true(app.canvas.h == size.h, "and the canvas covers the screen again")
    app:onCloseWidget()
    remote:free()
end)

check("keyboard_follows_rotation", function()
    local app, remote = new_app()
    app:set_keyboard_visible(true)
    assert_true(app.vk_visible, "the keyboard must be visible")

    -- VirtualKeyboard anchors itself in a BottomContainer sized Screen:getSize() at init time,
    -- and sizes its keys from Screen:getWidth(): both must have been refreshed.
    local container = app.vk[1].dimen
    local size = Screen:getSize()
    assert_true(container.w == size.w and container.h == size.h,
        string.format("the keyboard container (%dx%d) must match the screen (%dx%d)",
            container.w, container.h, size.w, size.h))
    local width_before = app.vk:getSize().w

    app:set_rotation_mode((Screen:getRotationMode() + 1) % 4)
    size = Screen:getSize()
    container = app.vk[1].dimen
    assert_true(container.w == size.w and container.h == size.h,
        string.format("after rotation the keyboard container (%dx%d) must match the screen (%dx%d)",
            container.w, container.h, size.w, size.h))
    assert_true(app.vk:getSize().w ~= width_before,
        "the keyboard must be laid out for the new screen width")
    assert_true(app.vk_visible, "the keyboard must stay visible across a rotation")

    app:set_rotation_mode(Screen:getRotationMode())
    app:set_keyboard_visible(false)
    app:onCloseWidget()
    remote:free()
end)

check("toolbar_toggles_on_top_swipe_only", function()
    local app, remote, sent = new_app()

    -- no tap zone may exist: the top strip must stay available to the remote desktop
    assert_true(not app:checkRegisterTouchZone("vnc_menu_tap"), "there must be no menu tap zone")
    assert_true(not app:checkRegisterTouchZone("vnc_menu_tap_ext"), "there must be no menu tap zone")
    assert_true(app:checkRegisterTouchZone("vnc_toolbar_swipe"), "the toolbar swipe zone must be registered")
    assert_true(app:checkRegisterTouchZone("vnc_toolbar_swipe_ext"),
        "the extended toolbar swipe zone must be registered")
    assert_true(app.onMenuSwipe == nil, "no swipe opens the menu any more")

    local zone = G_defaults:readSetting("DTAP_ZONE_MENU")
    local size = Screen:getSize()
    local gs_range = app._zones["vnc_toolbar_swipe"].gs_range
    assert_true(math.abs(gs_range.range.w - size.w * zone.w) < 1,
        "the toolbar swipe zone must cover KOReader's DTAP_ZONE_MENU width")
    assert_true(math.abs(gs_range.range.h - size.h * zone.h) < 1,
        "the toolbar swipe zone must cover KOReader's DTAP_ZONE_MENU height")

    -- a tap inside that zone clicks the remote
    local inside = Geom:new{ x = 10, y = 10 }
    sent.pointer = {}
    dispatch_gesture{ ges = "tap", pos = inside }
    assert_true(app.menu == nil and not app.toolbar_visible, "a tap opens nothing")
    assert_true(#sent.pointer == 3, "a tap in the top zone must click the remote, got "
        .. #sent.pointer .. " pointer events")

    -- a south swipe there flips the toolbar both ways
    dispatch_gesture{ ges = "swipe", direction = "south", pos = inside }
    assert_true(app.toolbar_visible == true, "a swipe down in the top zone shows the toolbar")
    dispatch_gesture{ ges = "swipe", direction = "south", pos = inside }
    assert_true(app.toolbar_visible == false, "and the next one hides it")
    -- other directions, or lower down, do nothing
    for _, dir in ipairs({ "north", "east" }) do
        dispatch_gesture{ ges = "swipe", direction = dir, pos = inside }
        assert_true(app.toolbar_visible == false, dir .. " swipe must not toggle the toolbar")
    end
    dispatch_gesture{ ges = "swipe", direction = "south", pos = Geom:new{ x = 10, y = math.floor(size.h / 2) } }
    assert_true(app.toolbar_visible == false, "a swipe down below the zone must not toggle the toolbar")
    assert_true(app.menu == nil, "no swipe opens the menu")

    -- and a tap anywhere else is a click too
    sent.pointer = {}
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = 10, y = size.h - 10 } }
    assert_true(#sent.pointer == 3, "a tap below the zone must click the remote")
    assert_true(app.menu == nil, "and must not open the menu")

    app:onCloseWidget()
    remote:free()
end)




check("server_section_is_in_the_network_menu", function()
    -- The plugin's own menu table, as `addToMainMenu` builds it.
    local menu_items = {}
    plugin:addToMainMenu(menu_items)

    assert_true(menu_items.vnc == nil or menu_items.vnc.text == "VNC viewer",
        "the viewer entry stays")
    local section = menu_items.vnc_server
    assert_true(section ~= nil, "a VNC server section must be registered")
    assert_true(section.text == "VNC server", "named \"VNC server\", got " .. tostring(section.text))
    assert_true(section.sorting_hint == "network", "it belongs in the Network menu")
    assert_true(type(section.checked_func) == "function", "it must be checkable")
    assert_true(section.checked_func() == false, "and not checked while the server is stopped")

    local items = section.sub_item_table
    assert_true(type(items) == "table" and #items >= 4, "it must offer a submenu")
    local labels = {}
    for _, item in ipairs(items) do
        labels[#labels + 1] = item.text or (item.text_func and item.text_func())
    end
    local function has(pattern)
        for _, l in ipairs(labels) do
            if type(l) == "string" and l:find(pattern) then return l end
        end
        return nil
    end
    assert_true(has("^Start VNC server$") ~= nil,
        "a start/stop entry, got: " .. table.concat(labels, " | "))
    assert_true(has("^Not running$") ~= nil, "a status line, got: " .. table.concat(labels, " | "))
    assert_true(has("^IP address: 0%.0%.0%.0$") ~= nil,
        "the IP address with its default, got: " .. table.concat(labels, " | "))
    assert_true(has("^Port: 5900$") ~= nil,
        "the port with its default, got: " .. table.concat(labels, " | "))
    assert_true(has("^Password: not set$") ~= nil,
        "the optional password, got: " .. table.concat(labels, " | "))
    assert_true(plugin.settings:server().ip == "0.0.0.0"
        and plugin.settings:server().port == 5900
        and plugin.settings:server().password == "",
        "and the defaults it shows are the stored ones")
end)

check("server_menu_offers_autostart", function()
    -- The entry is a checkbox over the stored setting, and toggling it persists to the file.
    local menu_items = {}
    plugin:addToMainMenu(menu_items)
    local item = find_item(menu_items.vnc_server.sub_item_table, "Start with KOReader")
    assert_true(type(item.checked_func) == "function", "the autostart entry must be a checkbox")

    store.data.server.autostart = false
    assert_true(item.checked_func() == false, "the item must show the stored setting (off by default)")

    item.callback({ updateItems = function() end })
    assert_true(store.data.server.autostart == true, "toggling must set the stored setting")
    assert_true(item.checked_func() == true, "and the item must then show it")
    local persisted = dofile(store.ls.file)
    assert_true(persisted.server.autostart == true,
        "the toggle must have been flushed to the settings file")

    item.callback({ updateItems = function() end })
    assert_true(store.data.server.autostart == false, "and toggling again clears it")
    persisted = dofile(store.ls.file)
    assert_true(persisted.server.autostart == false, "which is flushed too")
end)

--- An IP address or password changed while the server runs takes effect at once: the server is
--- stopped and started again (a start() on a running server is a no-op, so calling only that left
--- the old socket bound and the old password in force).
check("server_menu_rebinds_on_an_ip_or_password_change", function()
    local menu_items = {}
    plugin:addToMainMenu(menu_items)
    local calls = {}
    local fake = {
        running = true,
        is_running = function(self) return self.running end,
        start = function(self)
            calls[#calls + 1] = "start"
            if self.running then return true end
            self.running = true
            return true
        end,
        stop = function(self) calls[#calls + 1] = "stop" self.running = false end,
        client_count = function() return 0 end,
        status_text = function() return "" end,
    }
    local real_server, real_show = plugin.server, UIManager.show
    local saved_ip, saved_password = store.data.server.ip, store.data.server.password
    local shown
    plugin.server = fake
    UIManager.show = function(mgr, widget, ...)
        shown = widget
        return real_show(mgr, widget, ...)
    end
    local ok, err = pcall(function()
        for _, case in ipairs({ { "IP address", "127.0.0.1" }, { "Password", "secret" } }) do
            local item
            for _, it in ipairs(menu_items.vnc_server.sub_item_table) do
                local label = it.text or (it.text_func and it.text_func())
                if type(label) == "string" and label:find(case[1], 1, true) == 1 then item = it end
            end
            assert_true(item ~= nil, "no " .. case[1] .. " entry")
            calls, shown = {}, nil
            item.callback({ updateItems = function() end })
            assert_true(shown and shown.buttons, case[1] .. ": an input dialog must be shown")
            shown.getInputValue = function() return case[2] end
            shown.buttons[1][2].callback()
            assert_true(table.concat(calls, ",") == "stop,start",
                case[1] .. ": a running server must be stopped and started, got " .. table.concat(calls, ","))
            assert_true(fake.running, case[1] .. ": and it is running again")
        end
    end)
    UIManager.show = real_show
    plugin.server = real_server
    store.data.server.ip, store.data.server.password = saved_ip, saved_password
    plugin.settings:flush()
    if not ok then error(err, 0) end
end)

check("server_environment_rules", function()
    -- The parsing seam: a lookup function stands in for os.getenv, so every documented rule can be
    -- exercised without touching the real environment.
    local Settings = require("vnc/settings")
    local E = Settings.ENV
    local function read(map)
        return Settings.read_env(function(name) return map[name] end)
    end

    -- enable: unset, set-but-empty and whitespace-only all mean "no opinion"
    for _, map in ipairs({ {}, { [E.enable] = "" }, { [E.enable] = "   " } }) do
        assert_true(read(map).enable == nil, "an empty enable variable must mean no opinion")
    end
    -- the disable words, trimmed and case-insensitive
    for _, word in ipairs({ "0", "no", "false", " NO ", "False" }) do
        assert_true(read({ [E.enable] = word }).enable == false,
            string.format("enable=%q must mean do not start", word))
    end
    -- anything else non-empty means start
    for _, word in ipairs({ "1", "yes", "true", "anything", " no! " }) do
        assert_true(read({ [E.enable] = word }).enable == true,
            string.format("enable=%q must mean start", word))
    end

    -- host: empty/unset leave the stored value; otherwise the trimmed address
    assert_true(read({}).host == nil and read({ [E.host] = "" }).host == nil
        and read({ [E.host] = "  " }).host == nil, "an empty host must mean no opinion")
    assert_true(read({ [E.host] = " 10.0.0.9 " }).host == "10.0.0.9", "the host is trimmed")

    -- port: an integer in range, else ignored (and warned about, never applied)
    assert_true(read({ [E.port] = "5901" }).port == 5901, "a valid port is applied")
    assert_true(read({ [E.port] = " 5902 " }).port == 5902, "surrounding space is tolerated")
    assert_true(read({ [E.port] = "1" }).port == 1 and read({ [E.port] = "65535" }).port == 65535,
        "the ends of the range are valid")
    local logger = require("logger")
    local real_warn, warned = logger.warn, {}
    logger.warn = function(...) warned[#warned + 1] = table.concat({ ... }, " ") end
    local ok, err = pcall(function()
        for _, value in ipairs({ "0", "65536", "70000", "abc", "5900.5", "" }) do
            assert_true(read({ [E.port] = value }).port == nil,
                string.format("port=%q must be ignored", value))
        end
    end)
    logger.warn = real_warn
    if not ok then error(err) end
    assert_true(#warned == 6, "each invalid port must be warned about, got " .. #warned)
    for _, message in ipairs(warned) do
        assert_true(message:find("VNC_KOPLUGIN_SERVER_PORT", 1, true) ~= nil,
            "the warning must name the variable: " .. message)
    end

    -- password: set-but-empty is a meaningful "no password", kept verbatim
    assert_true(read({}).password == nil, "an unset password must mean no opinion")
    assert_true(read({ [E.password] = "" }).password == "",
        "an empty password must be kept as an override")
    assert_true(read({ [E.password] = " with space " }).password == " with space ",
        "a password must not be trimmed")

    -- all four variables at once
    local all = read({ [E.enable] = "1", [E.host] = "10.0.0.9", [E.port] = "5999", [E.password] = "pw" })
    assert_true(all.enable == true and all.host == "10.0.0.9" and all.port == 5999
        and all.password == "pw", "the four variables are read together")
end)

check("server_environment_overrides_the_stored_settings", function()
    local Settings = require("vnc/settings")
    local E = Settings.ENV
    local function env(map) return function(name) return map[name] end end
    local path = data_dir .. "/ui_smoke_env_precedence.lua"
    os.remove(path)
    os.remove(path .. ".old")

    -- stored: do not autostart, listen on 127.0.0.1:5901 with a password
    local s = Settings.open(path)
    s.data.server.ip, s.data.server.port = "127.0.0.1", 5901
    s.data.server.password, s.data.server.autostart = "stored", false
    s:flush()

    -- no environment at all: the stored setting decides and the stored table is used as-is
    local plain = Settings.open(path)
    assert_true(plain:should_autostart() == false, "without the environment the stored setting decides")
    assert_true(plain:server_for_run() == plain.data.server,
        "without overrides the running server shares the stored table")

    -- a set-but-empty enable variable is no opinion: the stored setting still decides
    local blank = Settings.open(path, env({ [E.enable] = "" }))
    assert_true(blank:should_autostart() == false,
        "an empty enable variable leaves the stored setting in charge")
    s.data.server.autostart = true
    s:flush()
    assert_true(Settings.open(path, env({ [E.enable] = "" })):should_autostart() == true,
        "and the stored setting can turn it on")

    -- the environment decides regardless of the stored setting
    assert_true(Settings.open(path, env({ [E.enable] = "1" })):should_autostart() == true,
        "enable=1 starts with the stored setting on")
    s.data.server.autostart = false
    s:flush()
    assert_true(Settings.open(path, env({ [E.enable] = "1" })):should_autostart() == true,
        "enable=1 starts even with the stored setting off")
    assert_true(Settings.open(path, env({ [E.enable] = "0" })):should_autostart() == false,
        "enable=0 does not start")
    s.data.server.autostart = true
    s:flush()
    assert_true(Settings.open(path, env({ [E.enable] = "no" })):should_autostart() == false,
        "enable=no does not start even with the stored setting on")

    -- host/port/password overrides are merged into the run, the stored values untouched
    local run = Settings.open(path, env({
        [E.host] = "10.9.8.7", [E.port] = "6001", [E.password] = "envsecret",
    }))
    local effective = run:server_for_run()
    assert_true(effective.ip == "10.9.8.7" and effective.port == 6001
        and effective.password == "envsecret", "the run must see the environment values")
    assert_true(effective ~= run.data.server, "the run must not get the stored table itself")
    assert_true(run.data.server.ip == "127.0.0.1" and run.data.server.port == 5901
        and run.data.server.password == "stored", "the stored values must be untouched")

    -- an empty password override really means "no password"; the other fields stay stored
    local no_pw = Settings.open(path, env({ [E.password] = "" })):server_for_run()
    assert_true(no_pw.password == "" and no_pw.ip == "127.0.0.1" and no_pw.port == 5901,
        "an empty password is applied while the other stored values stay")
end)

check("server_environment_is_not_persisted", function()
    local Settings = require("vnc/settings")
    local E = Settings.ENV
    local path = data_dir .. "/ui_smoke_env_store.lua"
    os.remove(path)
    os.remove(path .. ".old")

    -- a canonical file, written the way the plugin writes it
    local s = Settings.open(path)
    s.data.server.ip, s.data.server.port = "127.0.0.1", 5901
    s.data.server.password, s.data.server.autostart = "stored", false
    s:flush()
    local before = slurp(path)

    -- reopen with a full set of overrides and force a flush (what an exit-time save does)
    local run = Settings.open(path, function(name)
        return ({ [E.enable] = "1", [E.host] = "10.9.8.7",
                  [E.port] = "6001", [E.password] = "envsecret" })[name]
    end)
    assert_true(run:server_for_run().password == "envsecret", "the overrides are in effect for the run")
    run:flush()
    assert_true(slurp(path) == before,
        "a flush after the overrides must leave the settings file byte-identical")

    -- and nothing must have leaked into the stored table either
    local reloaded = Settings.open(path)
    assert_true(reloaded.data.server.ip == "127.0.0.1" and reloaded.data.server.port == 5901
        and reloaded.data.server.password == "stored" and reloaded.data.server.autostart == false,
        "the file still holds the stored values")
end)

--- KOReader instantiates the plugin once per FileManager and once per ReaderUI, so a server made per
--- instance left the first one running (listening, hooked into UIManager) while the menu of the next
--- instance showed a fresh one as "Not running" - and starting that failed with the port in use.
--- There is one server per KOReader run, and it follows the settings of the latest instance.
check("every_plugin_instance_shares_one_server", function()
    local saved_settings = plugin.server.settings
    local second = plugin_module:new{ ui = { menu = { registerToMainMenu = function() end } } }
    local same = second.server == plugin.server
    local follows = plugin.server.settings == second.settings:server_for_run()
    plugin.server.settings = saved_settings
    assert_true(same, "a second instance must use the same server")
    assert_true(follows, "and the server must follow the latest instance's settings")
end)

--- The boot connect is armed by the first instance only: every book opened or closed builds
--- another instance, whose init() used to arm it again - a reconnect on each return to the library.
check("later_plugin_instances_do_not_rearm_the_boot_connect", function()
    local saved_settings = plugin.server.settings
    local real_connect, real_flagged = plugin_module.connect_profile, plugin_module.autoconnect_profile
    local calls = 0
    plugin_module.connect_profile = function() calls = calls + 1 end
    -- (a new instance opens the default settings file, not this test's store)
    plugin_module.autoconnect_profile = function() return { name = "good" } end
    local ok, err = pcall(function()
        plugin_module:new{ ui = { document = {} } }
        UIManager:_checkTasks()
        plugin_module:new{ ui = { menu = { registerToMainMenu = function() end } } }
        UIManager:_checkTasks()
    end)
    plugin_module.connect_profile, plugin_module.autoconnect_profile = real_connect, real_flagged
    plugin.server.settings = saved_settings
    if not ok then error(err, 0) end
    assert_true(calls == 0, "a later instance must not connect at its init, got " .. calls .. " connects")
end)

--- `sessions` is shared by all instances; a session made by an instance that KOReader has since
--- replaced must report its drop to the instance showing the viewer, i.e. to its reconnect box.
check("a_session_reports_to_the_instance_that_shows_it", function()
    local Session = require("vnc/session")
    local session = Session.new{ profile = store:get_profile("good") }
    local old = setmetatable({ sessions = plugin.sessions }, { __index = plugin_module })
    session.on_state = function(state, err) old:on_session_state(session, state, err) end
    local errors = {}
    local app = { session = session, on_session_error = function(_, m) errors[#errors + 1] = m end }
    local saved_settings = plugin.server.settings
    local second = plugin_module:new{ ui = { menu = { registerToMainMenu = function() end } } }
    plugin.server.settings = saved_settings
    local real_show = UIManager.show
    UIManager.show = function() end
    local ok, err = pcall(function()
        second.app = app -- (the viewer reopened by the new instance: not connected, so no attach)
        second:_open_app(session)
        session:_set_state("error", "connection reset")
    end)
    UIManager.show = real_show
    if not ok then error(err, 0) end
    assert_true(#errors == 1 and errors[1] == "connection reset",
        "the drop must reach the viewer of the current instance, got " .. #errors)
    assert_true(session.plugin == second, "and the session must read that instance's settings")
end)

--- Connect tapped again while the first attempt is still connecting (waiting for Wi-Fi, typically)
--- must leave that attempt alone: its "already connecting" answer used to be handled as a failed
--- connect, which dropped the session from the plugin - and with it the only way to disconnect it.
check("connecting_twice_keeps_the_attempt_in_progress", function()
    local saved = plugin.sessions.good
    local connects = 0
    local fake = {
        get_state = function() return "connecting" end,
        is_connected = function() return false end,
        set_profile = function() end,
        connect = function(_, cb)
            connects = connects + 1
            if cb then cb(false, "already connecting or connected") end
        end,
    }
    plugin.sessions.good = fake
    local depth = #stack()
    local failed = 0
    local ok, err = pcall(function()
        plugin:connect_profile("good", function() failed = failed + 1 end)
        assert_true(plugin.sessions.good == fake, "the session in progress must stay the plugin's")
        assert_true(failed == 0, "a connect still in progress is not a failure")
        assert_true(connects == 0, "and it must not be asked to connect again")
    end)
    -- whatever the plugin showed about it
    while #stack() > depth do UIManager:close(top()) end
    plugin.sessions.good = saved
    if not ok then error(err, 0) end
end)

--- A first connect runs in ticks (Wi-Fi, TCP, handshake), so the list must say it is on its way:
--- "Connecting to <name>…" from the attempt's start until it succeeds, fails or is cancelled (a
--- disconnect), and never two messages at once. The viewer's reconnect box has titles of its own,
--- so an attempt for the session the viewer shows gets no extra message.
check("first_connect_shows_connecting_until_it_ends", function()
    local saved, saved_open, saved_app = plugin.sessions.good, plugin._open_app, plugin.app
    local state, pending = "disconnected", nil
    local fake = {
        get_state = function() return state end,
        is_connected = function() return state == "connected" end,
        set_profile = function() end,
        connect = function(_, cb) state, pending = "connecting", cb end,
    }
    local function is_connecting(w)
        return w ~= nil and w.text == "Connecting to good…" and w.buttons == nil
    end
    local opened = 0
    local depth = #stack()
    local ok, err = pcall(function()
        plugin._open_app = function() opened = opened + 1 end

        -- success: the message goes before the viewer comes up
        plugin.sessions.good = fake
        plugin:connect_profile("good")
        expect_top(is_connecting, "the connecting message")
        state = "connected"; pending(true)
        assert_true(count(is_connecting) == 0, "the message must close on success: " .. stack_desc())
        assert_true(opened == 1, "and the viewer must open")

        -- failure: the message is replaced by the error, not stacked under it
        state = "disconnected"
        plugin.sessions.good = fake
        plugin:connect_profile("good")
        expect_top(is_connecting, "the connecting message")
        state = "error"; pending(false, "refused")
        assert_true(count(is_connecting) == 0, "the message must close on failure: " .. stack_desc())
        expect_top(function(w) return w ~= nil and w.text and w.text:find("Could not connect to good", 1, true) end,
            "the connection error")
        UIManager:close(top())

        -- cancel: a disconnect ends the attempt without its callback
        state = "disconnected"
        plugin.sessions.good = fake
        plugin:connect_profile("good")
        expect_top(is_connecting, "the connecting message")
        plugin:on_session_state(fake, "disconnected")
        assert_true(count(is_connecting) == 0, "the message must close on a disconnect: " .. stack_desc())

        -- the viewer's own session: its reconnect box speaks for it
        state = "disconnected"
        plugin.sessions.good = fake
        plugin.app = { session = fake }
        plugin:connect_profile("good")
        assert_true(count(is_connecting) == 0, "no message over the viewer's own session: " .. stack_desc())
        state = "connected"; pending(true)
        plugin.app = saved_app
    end)
    while #stack() > depth do UIManager:close(top()) end
    plugin.sessions.good, plugin._open_app, plugin.app = saved, saved_open, saved_app
    plugin._pending_connect = nil
    if not ok then error(err, 0) end
end)

check("server_autostart_starts_once_the_tick_runs", function()
    local socket = require("socket")
    local probe = assert(socket.bind("127.0.0.1", 0))
    local _, port = probe:getsockname()
    probe:close()

    local server_settings = store.data.server
    local saved = { ip = server_settings.ip, port = server_settings.port,
                    password = server_settings.password, autostart = server_settings.autostart,
                    env = plugin.settings.env }
    server_settings.ip = "127.0.0.1"
    server_settings.port = port
    server_settings.password = ""
    plugin.settings.env = {}

    local ok, err = pcall(function()
        -- off: the deferred tick starts nothing
        server_settings.autostart = false
        plugin:schedule_autostart()
        UIManager:_checkTasks()
        assert_true(not plugin.server:is_running(), "with autostart off nothing may start")

        -- on: the start is deferred to the next UI loop turn, and then it happens
        server_settings.autostart = true
        plugin:schedule_autostart()
        assert_true(not plugin.server:is_running(), "the start must be deferred, not immediate")
        UIManager:_checkTasks()
        assert_true(plugin.server:is_running(), "the next tick must start the server")
        assert_true(plugin.server:status_text() == "127.0.0.1:" .. port,
            "it must listen where the settings say, got " .. tostring(plugin.server:status_text()))

        -- and it does not re-arm: a manual stop stays a stop
        plugin.server:stop()
        UIManager:_checkTasks()
        assert_true(not plugin.server:is_running(), "a manual stop must not be undone")

        -- the environment decides too, with the stored setting off
        server_settings.autostart = false
        plugin.settings.env = { enable = true }
        plugin:schedule_autostart()
        UIManager:_checkTasks()
        assert_true(plugin.server:is_running(), "the environment must be able to start it")
        plugin.server:stop()
        UIManager:_checkTasks()
        assert_true(not plugin.server:is_running(), "and it stops again")

        -- a boot start that cannot bind is warned about and left in the server's state
        local holder = assert(socket.bind("127.0.0.1", 0))
        server_settings.port = select(2, holder:getsockname())
        server_settings.autostart = true
        plugin.settings.env = {}
        local logger = require("logger")
        local real_warn, warned = logger.warn, 0
        logger.warn = function() warned = warned + 1 end
        local started, start_err = pcall(function()
            plugin:schedule_autostart()
            UIManager:_checkTasks()
        end)
        logger.warn = real_warn
        holder:close()
        if not started then error(start_err) end
        assert_true(not plugin.server:is_running(), "a start that cannot bind must not report running")
        assert_true(plugin.server.last_error ~= nil,
            "the failure must be visible in the server state (the menu's status line)")
        assert_true(warned >= 1, "a failed boot start must be logged as a warning")
    end)

    if plugin.server:is_running() then plugin.server:stop() end
    plugin.server.last_error = nil
    server_settings.ip, server_settings.port = saved.ip, saved.port
    server_settings.password, server_settings.autostart = saved.password, saved.autostart
    plugin.settings.env = saved.env
    if not ok then error(err, 0) end
end)

check("settings_file_is_kept_in_shape", function()
    -- There is no schema version and no migration; the store still has to survive a file that a
    -- user edited by hand (or that does not exist yet). `LuaSettings` caches one instance per
    -- path (and flushing on close would overwrite the file), so each case gets its own path.
    local Settings = require("vnc/settings")
    local writeToFile = require("util").writeToFile   -- (data, path, force_flush, lua_dofile_ready)

    local fresh = data_dir .. "/ui_smoke_settings_fresh.lua"
    local s = Settings.open(fresh)
    assert_true(s.data.settings.zoom_mode == "fit", "a fresh install gets the defaults")
    assert_true(type(s.data.profiles) == "table" and #s.data.profiles == 0, "and no profiles")

    local junk = data_dir .. "/ui_smoke_settings_junk.lua"
    -- (`lua_dofile_ready` makes writeToFile add the `return`, so the content is the table itself)
    writeToFile([==[
-- hand-edited, with junk in it
{
    ["settings"] = { ["zoom_mode"] = "fit_with_keyboard", ["bogus"] = 1 },
    ["profiles"] = {
        { ["name"] = "ok", ["host"] = "h", ["port"] = 5901, ["password"] = "p" },
        { ["host"] = "no name" },
        "not a table",
    },
    ["settings_version"] = 1,
}
]==], junk, true, true)
    s = Settings.open(junk)
    assert_true(s.data.settings.zoom_mode == "fit_with_keyboard", "the settings that are there survive")
    assert_true(s.data.settings.bogus == nil, "unknown settings are dropped")
    assert_true(s.data.settings_version == nil, "so are unknown top-level keys")
    assert_true(#s.data.profiles == 1, "only the usable profiles are kept")
    local profile = s.data.profiles[1]
    assert_true(profile.name == "ok" and profile.host == "h" and profile.port == 5901
        and profile.password == "p", "and they keep their fields")

    local empty = data_dir .. "/ui_smoke_settings_empty.lua"
    writeToFile("{}\n", empty, true, true)
    s = Settings.open(empty)
    assert_true(s.data.settings.zoom_mode == "fit" and #s.data.profiles == 0,
        "an empty file is filled in rather than breaking the viewer")
end)

check("keyboard_yields_to_popups", function()
    -- The keyboard belongs to the framebuffer view: a menu or dialog above it takes it out of the
    -- way, and it comes back when that popup is gone.
    local app, remote = new_app()
    local flushes = 0
    app.plugin.settings.flush = function() flushes = flushes + 1 end
    app:set_keyboard_visible(true)
    assert_true(app.vk_visible, "the keyboard covers the framebuffer")
    assert_true(app.settings.keyboard_shown == true and flushes == 1, "and the wish is saved")

    app:open_menu()
    assert_true(not app.vk_visible, "opening the menu must hide the keyboard")
    assert_true(app:is_keyboard_wanted(), "without forgetting that it was asked for")
    UIManager:_checkTasks()
    assert_true(not app.vk_visible, "and it must stay hidden while the menu is open")

    -- there is no keyboard entry in the menu any more (the toolbar button remembers)
    for _, item in ipairs(app.menu.item_table) do
        assert_true(item.text ~= "Hide keyboard" and item.text ~= "Show keyboard"
            and item.text ~= "Keyboard always visible", "no keyboard entry: " .. tostring(item.text))
    end
    assert_true(app.settings.keyboard_shown == true and flushes == 1, "the menu leaves the saved wish alone")

    app:close_menu()
    UIManager:_checkTasks()
    assert_true(app.vk_visible, "closing the menu must bring the keyboard back")

    -- any popup above the view, ours or not
    local InfoMessage = require("ui/widget/infomessage")
    local dialog = InfoMessage:new{ text = "dialog" }
    UIManager:show(dialog)
    app:_sync_keyboard_later()                 -- what the repaint watcher does when a popup appears
    UIManager:_checkTasks()
    assert_true(not app.vk_visible, "a dialog above the view must hide the keyboard")

    UIManager:close(dialog)
    app:_sync_keyboard_later()
    UIManager:_checkTasks()
    assert_true(app.vk_visible, "and closing it must bring the keyboard back")
    assert_true(app.settings.keyboard_shown == true and flushes == 1, "popups leave the saved wish alone")

    -- the toolbar button hides it even while a popup has taken it away
    app:open_menu()
    app:toggle_keyboard()
    assert_true(app.settings.keyboard_shown == false, "the saved wish follows the user's")
    assert_true(not app:is_keyboard_wanted(), "and the wish is recorded")
    assert_true(not app.vk_visible, "still hidden while the menu is open")
    app:close_menu()
    UIManager:_checkTasks()
    assert_true(not app.vk_visible, "and hidden after the menu closes")

    -- leaving the viewer never resurrects the keyboard over whatever comes next
    app:set_keyboard_visible(true)
    assert_true(app.vk_visible, "the keyboard on again")
    local popup = InfoMessage:new{ text = "after the viewer" }
    app:onCloseWidget()
    UIManager:show(popup)
    app:_sync_keyboard_later()
    UIManager:_checkTasks()
    assert_true(not app.vk:isVisible(), "no keyboard may appear after the viewer closed")
    UIManager:close(popup)

    remote:free()
end)

check("keyboard_always_visible_migrates_to_keyboard_shown", function()
    local Settings = require("vnc/settings")
    local writeToFile = require("util").writeToFile
    for _, case in ipairs({ { "true", true }, { "false", false }, { nil, false } }) do
        local path = data_dir .. "/ui_smoke_keyboard_shown.lua"
        local line = case[1] and ("        [\"keyboard_always_visible\"] = " .. case[1] .. ",\n") or ""
        os.remove(path); os.remove(path .. ".old")
        writeToFile("{\n    [\"settings\"] = {\n" .. line .. "    },\n}\n", path, true, true)
        local s = Settings.open(path)
        assert_true(s.data.settings.keyboard_shown == case[2],
            tostring(case[1]) .. ": keyboard_shown " .. tostring(s.data.settings.keyboard_shown))
        assert_true(s.data.settings.keyboard_always_visible == nil, "the old key is gone")
        -- a new file keeps the new key, whatever an old one would have said
        s.data.settings.keyboard_shown = not case[2]
        s:flush()
        s = Settings.open(path)
        assert_true(s.data.settings.keyboard_shown == not case[2], "the saved new key wins after the migration")
        os.remove(path); os.remove(path .. ".old")
    end
end)

check("menu_toggles_leave_the_keyboard_alone", function()
    -- A real tap goes through Menu:onMenuSelect, which runs the item callback *and* the menu's
    -- close callback; the latter once switched the keyboard off again right after the item had
    -- switched it on.
    local app, remote = new_app()
    app.plugin.settings.flush = function() end
    local function choose_menu_item(text)
        app:open_menu()
        local menu = app.menu
        for _, item in ipairs(menu.item_table) do
            if item.text == text then
                menu:onMenuSelect(item)
                UIManager:_checkTasks()   -- run the deferred keyboard sync
                return
            end
        end
        local have = {}
        for _i, item in ipairs(menu.item_table) do have[#have + 1] = tostring(item.text) end
        error(string.format("no %q menu item, only: %s", text, table.concat(have, ", ")))
    end

    assert_true(not app.vk_visible, "the keyboard starts hidden")
    choose_menu_item("Keep screen on")
    assert_true(app.menu ~= nil, "the toggle keeps the menu open")
    app:close_menu()
    UIManager:_checkTasks()
    assert_true(not app.vk_visible, "a menu toggle does not bring the keyboard up")

    -- with the keyboard wanted, it survives a menu round trip and a toggle in it
    app:set_keyboard_visible(true)
    choose_menu_item("Keep screen on")
    assert_true(not app.vk_visible, "the menu hides the keyboard while it is open")
    app:close_menu()
    UIManager:_checkTasks()
    assert_true(app.vk_visible and app.settings.keyboard_shown == true, "the wish brings it back when the menu closes")

    app:set_keyboard_visible(false)
    assert_true(not app.vk_visible, "and it can be hidden again")

    app:onCloseWidget()
    remote:free()
end)

check("text_input_reaches_the_remote", function()
    -- SDL 3 only delivers SDL_EVENT_TEXT_INPUT after SDL_StartTextInput() ("not received by
    -- default"), and KOReader's input widgets are the only core callers of it. The viewer must
    -- therefore enable it itself, or typing on a hardware keyboard reaches nobody.
    local started, stopped = 0, 0
    local original_start, original_stop = Device.startTextInput, Device.stopTextInput
    Device.startTextInput = function() started = started + 1 end
    Device.stopTextInput = function() stopped = stopped + 1 end

    local ok, err = pcall(function()
        local app, remote, sent = new_app()
        assert_true(started == 1, "showing the viewer must enable platform text input")
        assert_true(stopped == 0, "and must not disable it")

        -- What SDL 3's backend does afterwards: the device's SDL event handler turns
        -- SDL_EVENT_TEXT_INPUT into a TextInput event for the widget stack.
        local SDL_EVENT_TEXT_INPUT = 0x303
        Device.input:handleSdlEv({ code = SDL_EVENT_TEXT_INPUT, value = "hi" })
        assert_true(#sent.key == 4, "typing must reach the remote, got " .. #sent.key .. " key events")
        assert_true(sent.key[1].keysym == 0x68 and sent.key[1].down == true, "h down")
        assert_true(sent.key[2].keysym == 0x68 and sent.key[2].down == false, "h up")
        assert_true(sent.key[3].keysym == 0x69 and sent.key[4].keysym == 0x69, "i down/up")

        -- the second character set: a real keypress must not re-enable it over and over
        Device.input:handleSdlEv({ code = SDL_EVENT_TEXT_INPUT, value = "A" })
        assert_true(started == 1, "text input must be asserted once, not per key")
        sent.key = {}
        app:onKeyPress(require("device/key"):new("Left", {}))
        assert_true(started == 1, "and a key event must not re-assert it either")
        assert_true(#sent.key == 1, "while still forwarding the key")

        -- one of our own dialogs (a text field) turns it off: we must get it back
        Device.stopTextInput()                      -- as InputText:onCloseWidget would
        assert_true(stopped == 1, "the simulated dialog turned text input off")
        app:reassert_text_input()
        assert_true(started == 2, "a closed dialog must lead to a re-assert")

        sent.key = {}
        Device.input:handleSdlEv({ code = SDL_EVENT_TEXT_INPUT, value = "ok" })
        assert_true(#sent.key == 4, "and typing must work again")

        -- closing the viewer hands text input back
        app:onCloseWidget()
        assert_true(stopped == 2, "closing the viewer must disable platform text input again")
        remote:free()
    end)

    Device.startTextInput, Device.stopTextInput = original_start, original_stop
    if not ok then error(err) end
end)

check("physical_modifiers_reach_the_remote_through_koreader_input", function()
    -- KOReader's Input swallows Ctrl/Shift/Alt presses (they only become `key.modifiers` of the
    -- next key) and SDL sends no text for Ctrl/Alt+letter: against x11vnc a physical Ctrl+C, Alt+F
    -- or Ctrl+Left used to send nothing or the bare key. Driven through Input:handleKeyBoardEv
    -- with SDL keycodes, as the emulator's event loop does.
    local app, remote = new_app()
    local wire = {}
    app.session.send_key = function(_, k, d) wire[#wire + 1] = string.format("%s%X", d and "+" or "-", k) end
    local function sdl(code, value)
        local ev = Device.input:handleKeyBoardEv({ type = 1, code = code, value = value })
        if type(ev) == "table" then UIManager:sendEvent(ev) end
    end
    local CTRL, SHIFT, ALT, LEFT = 0x400000E0, 1073742049, 1073742050, 1073741904
    local function take() local w = table.concat(wire, " "); wire = {}; return w end
    -- Ctrl+C
    sdl(CTRL, 1); sdl(99, 1); sdl(99, 0); sdl(CTRL, 0)
    local got = take()
    assert_true(got == "+FFE3 +63 -63 -FFE3", "Ctrl+C, got " .. got)
    -- Alt+F, and a text event for it (some platforms send one) must not type a second f
    sdl(ALT, 1); sdl(102, 1)
    Device.input:handleSdlEv({ code = 0x303, value = "f" })
    sdl(102, 0); sdl(ALT, 0)
    got = take()
    assert_true(got == "+FFE9 +66 -66 -FFE9", "Alt+F, got " .. got)
    -- Ctrl+Shift+T
    sdl(CTRL, 1); sdl(SHIFT, 1); sdl(116, 1); sdl(116, 0); sdl(SHIFT, 0); sdl(CTRL, 0)
    got = take()
    assert_true(got == "+FFE3 +FFE1 +54 -54 -FFE1 -FFE3", "Ctrl+Shift+T, got " .. got)
    -- the modifiers let go before the letter (xdotool's order): the letter's release still
    -- releases what its press sent, nothing stays down on the remote
    sdl(CTRL, 1); sdl(SHIFT, 1); sdl(116, 1); sdl(SHIFT, 0); sdl(CTRL, 0); sdl(116, 0)
    got = take()
    assert_true(got == "+FFE3 +FFE1 +54 -54 -FFE1 -FFE3", "Ctrl+Shift+T released modifiers first, got " .. got)
    -- Ctrl+Left (a named key; at the rotation the test runs in, Left stays Left)
    local rota = Screen:getRotationMode()
    local expect_left = string.format("%X", require("vnc/keysyms").special[Device.input.rotation_map[rota].Left or "Left"])
    sdl(CTRL, 1); sdl(LEFT, 1); sdl(LEFT, 0); sdl(CTRL, 0)
    got = take()
    assert_true(got == "+FFE3 +" .. expect_left .. " -" .. expect_left .. " -FFE3", "Ctrl+Left, got " .. got)
    -- plain typing still goes through the text event only (Shift+a is the text "A")
    sdl(SHIFT, 1); sdl(97, 1); Device.input:handleSdlEv({ code = 0x303, value = "A" }); sdl(97, 0); sdl(SHIFT, 0)
    got = take()
    assert_true(got == "+41 -41", "Shift+A as text, got " .. got)
    app:onCloseWidget()
    remote:free()
end)

check("page_buttons_scroll_the_wheel_in_wheel_mode", function()
    local Key = require("device/key")
    local app, remote, sent = new_app()
    app.settings.page_buttons = "wheel"
    local function masks()
        local out = {}
        for _, e in ipairs(sent.pointer) do out[#out + 1] = e.mask end
        return table.concat(out, ",")
    end

    -- (a) no tap yet: the remote centre, wheel down, and no key events
    local cx, cy = math.floor(remote.w / 2), math.floor(remote.h / 2)
    app:onKeyPress(Key:new("LPgFwd", {}))
    assert_true(masks() == "16,0,16,0,16,0", "forward must scroll 3 notches down, got " .. masks())
    for _, e in ipairs(sent.pointer) do
        assert_true(e.x == cx and e.y == cy, "no tap yet: the wheel must go to the remote centre")
    end
    assert_true(#sent.key == 0, "wheel mode must not send keys")

    -- (c) auto-repeat scrolls again; release sends nothing but is consumed
    sent.pointer = {}
    app:onKeyRepeat(Key:new("LPgFwd", {}))
    assert_true(#sent.pointer == 6, "a repeat must scroll another 3 notches")
    sent.pointer = {}
    assert_true(app:onKeyRelease(Key:new("LPgFwd", {})) == true, "release must be consumed")
    assert_true(#sent.pointer == 0 and #sent.key == 0, "release must send nothing")

    -- (b) after a tap the wheel goes under the last pointer position
    local c = app:canvas_geom()
    app:onTap(nil, { pos = { x = c.x + 50, y = c.y + 40 } })
    local rx, ry = app:_to_remote(c.x + 50, c.y + 40)
    sent.pointer = {}
    app:onKeyPress(Key:new("RPgBack", {}))
    assert_true(masks() == "8,0,8,0,8,0", "back must scroll up, got " .. masks())
    for _, e in ipairs(sent.pointer) do
        assert_true(e.x == rx and e.y == ry, "the wheel must go to the last tapped position")
    end
end)

check("page_buttons_wheel_clamps_to_a_shrunk_remote", function()
    local Key = require("device/key")
    local app, remote, sent = new_app()
    app.settings.page_buttons = "wheel"
    app:send_pointer(remote.w - 1, remote.h - 1, 0)
    remote:resize(100, 80)
    sent.pointer = {}
    app:onKeyPress(Key:new("LPgFwd", {}))
    assert_true(#sent.pointer == 6, "wheel must still send 3 notches")
    for _, e in ipairs(sent.pointer) do
        assert_true(e.x >= 0 and e.x <= 99 and e.y >= 0 and e.y <= 79,
            "wheel must land inside the shrunk remote, got " .. e.x .. "," .. e.y)
    end
end)

--- A reconnect (and a DesktopSize that changes nothing) reports the same size again: that is not a
--- new desktop, so a numeric zoom and the place it shows stay, and the plane is not reallocated.
check("remote_resize_to_the_same_size_keeps_the_view", function()
    local Remote = require("vnc/framebuffer")
    local remote = Remote.new(800, 600)
    remote:fit_view(400, 300)
    remote:set_scale(2)
    remote:pan_by(-100, -50)
    local scale, vx, vy, plane = remote:get_scale(), remote.view_x, remote.view_y, remote:get_plane()
    remote:resize(800, 600)
    assert_true(remote:get_scale() == scale, "the zoom must stay, got " .. remote:get_scale())
    assert_true(remote.view_x == vx and remote.view_y == vy, "and so must the view")
    assert_true(remote:get_plane() == plane, "the plane is not reallocated")
    remote:resize(400, 300)
    assert_true(remote:get_plane() ~= plane and remote:get_size() == 400, "a real resize still reallocates")
    remote:free()
end)

check("page_buttons_send_keys_in_keys_mode", function()
    local Key = require("device/key")
    local app, _, sent = new_app()
    app.settings.page_buttons = "keys"
    app:onKeyPress(Key:new("LPgFwd", {}))
    app:onKeyRelease(Key:new("LPgFwd", {}))
    assert_true(#sent.pointer == 0, "keys mode must not move the wheel")
    assert_true(#sent.key == 2 and sent.key[1].keysym == 0xFF56, "keys mode must send Page_Down")
end)

check("page_buttons_count_as_input_taps_do_not", function()
    local Key = require("device/key")
    local app, _, sent = new_app()
    app.settings.page_buttons = "wheel"
    local c = app:canvas_geom()
    app:onTap(nil, { pos = { x = c.x + 10, y = c.y + 10 } })
    assert_true(sent.input == 0, "a tap must not hold screen updates")
    app:onKeyPress(Key:new("LPgFwd", {}))
    assert_true(sent.input >= 1, "a wheel page button must hold screen updates")

    -- the real session: a key marks input, a pointer event does not
    local Session = require("vnc/session")
    local real_now = Session._now
    Session._now = function() return 50 end
    local s = Session.new{ profile = { name = "t", host = "127.0.0.1", port = 1, password = "" } }
    s.proto = { send_key = function() end, send_pointer = function() end }
    s:send_pointer(1, 2, 1)
    local after_pointer = s.last_input
    s:send_key(0xFF56, true)
    local after_key = s.last_input
    s.last_input = nil
    s:send_key(0xFF56, false)
    local after_release = s.last_input
    Session._now = real_now
    assert_true(after_release == nil, "a key release must not be noted as input")
    assert_true(after_pointer == nil, "a pointer event must not hold screen updates")
    assert_true(after_key == 50, "a key must record the input time, got " .. tostring(after_key))
end)

check("page_buttons_setting_validates", function()
    local Settings = require("vnc/settings")
    assert_true(Settings.DEFAULTS.page_buttons == "keys", "default must be keys")
    local path = data_dir .. "/ui_smoke_page_buttons.lua"
    for _, bad in ipairs({ "bogus", 5, true }) do
        os.remove(path)
        os.remove(path .. ".old")
        local f = assert(io.open(path, "w"))
        f:write(string.format('return { settings = { page_buttons = %s } }\n',
            type(bad) == "string" and string.format("%q", bad) or tostring(bad)))
        f:close()
        local got = Settings.open(path).data.settings.page_buttons
        assert_true(got == "keys", string.format("stored %s must load as keys, got %s", tostring(bad), tostring(got)))
    end
    os.remove(path)
    local f = assert(io.open(path, "w"))
    f:write('return { settings = { page_buttons = "wheel" } }\n')
    f:close()
    assert_true(Settings.open(path).data.settings.page_buttons == "wheel", "a valid wheel value must be kept")
    os.remove(path)
end)

check("page_buttons_menu_entry", function()
    local app = new_app()
    local s = app.plugin.settings.data.settings
    s.page_buttons = "keys"
    app:open_menu()
    local entry
    for _, item in ipairs(app.menu.item_table) do
        if item.text == "Page buttons send" then entry = item end
    end
    assert_true(entry, "the viewer menu must have a 'Page buttons send' entry")
    assert_true(entry.help_text and entry.help_text:find("wheel", 1, true), "the entry has a help text")
    assert_true(entry.text:find("next connection", 1, true) == nil, "it applies at once")
    local keys, wheel = find_item(entry.sub_item_table, "Page Up/Down keys"), find_item(entry.sub_item_table, "Mouse wheel")
    assert_true(keys.mandatory == "✓" and wheel.mandatory == nil, "keys is the shown choice")
    local before = #stack()
    wheel.callback()
    assert_true(s.page_buttons == "wheel", "choosing Mouse wheel stores wheel, got " .. tostring(s.page_buttons))
    for _, w in ipairs(stack()) do
        assert_true(w.text ~= "Takes effect on the next connection.", "no next-connection notice")
    end
    assert_true(#stack() <= before, "no notice widget was added")
end)

check("scaling_setting_defaults_and_validates", function()
    local Settings = require("vnc/settings")
    assert_true(Settings.DEFAULTS.scaling == "smooth", "default must be smooth")
    local path = data_dir .. "/ui_smoke_scaling.lua"
    for _, bad in ipairs({ '"blurry"', "5", "true" }) do
        local f = assert(io.open(path, "w"))
        f:write(string.format('return { settings = { scaling = %s } }\n', bad))
        f:close()
        local got = Settings.open(path).data.settings.scaling
        assert_true(got == "smooth", "stored " .. bad .. " must become smooth, got " .. tostring(got))
    end
    local f = assert(io.open(path, "w"))
    f:write('return { settings = { scaling = "sharp" } }\n')
    f:close()
    assert_true(Settings.open(path).data.settings.scaling == "sharp", "a valid sharp value must be kept")
    os.remove(path)
end)

check("display_panel_scaling_applies_live", function()
    local app, remote = new_app()
    local s = app.plugin.settings.data.settings
    s.scaling = "smooth"
    local flushed = 0
    app.plugin.settings.flush = function() flushed = flushed + 1 end
    local modes, repaints = {}, 0
    local real_set = remote.set_scaling
    remote.set_scaling = function(self, mode) modes[#modes + 1] = mode return real_set(self, mode) end
    local real_change = app._wholesale_change
    app._wholesale_change = function(self) repaints = repaints + 1 return real_change(self) end
    local panel = app:open_display_panel()
    find_button(panel, "✓ Smooth")
    local before = #stack()
    find_button(panel, "Sharp").callback()
    assert_true(s.scaling == "sharp", "tapping Sharp stores sharp, got " .. tostring(s.scaling))
    assert_true(flushed >= 1, "settings are flushed")
    assert_true(modes[#modes] == "sharp" and remote.scaling == "sharp", "the live remote is switched to sharp")
    assert_true(repaints == 1, "the view is repainted")
    for _, w in ipairs(stack()) do
        assert_true(w.text ~= "Reconnect to apply the new settings.", "no reconnect notice")
    end
    assert_true(#stack() <= before, "no notice widget was added")
    assert_true(app.display_panel ~= nil, "the panel stays open")
    find_button(app.display_panel, "✓ Sharp")
    find_button(app.display_panel, "Smooth").callback()
    assert_true(s.scaling == "smooth" and modes[#modes] == "smooth", "tapping Smooth goes back")
    app:close_display_panel()
    app:onCloseWidget()
    remote:free()
end)

check("display_panel_marks_and_applies_choices", function()
    local app, remote = new_app()
    app.plugin.settings.flush = function() end
    local panel = app:open_display_panel()
    find_button(panel, "✓ Fit screen")
    find_button(panel, "200%").callback()
    assert_true(app.settings.zoom_mode == 2 and app.display_panel ~= nil, "applied, panel still open")
    find_button(app.display_panel, "✓ 200%")
    find_in_section(app.display_panel, SPEED, "Fast").callback()
    assert_true(app.settings.pointer_speed == "fast")
    find_in_section(app.display_panel, SPEED, "✓ Fast")
    app:toggle_display_panel()
    assert_true(app.display_panel == nil and count(function(w) return w == panel end) == 0)
    app:onCloseWidget()
    remote:free()
end)

check("display_panel_anchors_and_closes_by_tap_outside", function()
    local app, remote = new_app()
    local panel = app:open_display_panel()
    assert_true(type(panel.anchor) == "function", "the panel is anchored")
    local anchor = panel.anchor()
    assert_true(anchor.y == 0, "without a toolbar it hangs from the top of the screen")
    assert_true(app:open_display_panel() == panel, "opening twice returns the same panel")
    panel:onTapClose(nil, { pos = require("ui/geometry"):new{ x = 1, y = Screen:getSize().h - 1, w = 0, h = 0 } })
    UIManager:_checkTasks()
    assert_true(app.display_panel == nil and count(function(w) return w == panel end) == 0, "tap outside closes it")
    app:open_display_panel()
    app:close_display_panel()
    assert_true(app.display_panel == nil, "close_display_panel closes it")
    app:onCloseWidget()
    remote:free()
end)

check("keep_screen_on_pauses_auto_suspend_while_shown", function()
    local share = require("pluginshare")
    local saved = share.pause_auto_suspend
    -- previous false: set while shown, back to false after close
    share.pause_auto_suspend = false
    local app, remote = new_app()
    assert_true(share.pause_auto_suspend == true, "shown with the setting on pauses auto-suspend")
    app:onCloseWidget()
    assert_true(share.pause_auto_suspend == false, "closing gives back the previous value")
    remote:free()
    -- someone else's pause stays
    share.pause_auto_suspend = true
    app, remote = new_app()
    app:onCloseWidget()
    assert_true(share.pause_auto_suspend == true, "another owner's pause survives our close")
    remote:free()
    -- the menu entry
    share.pause_auto_suspend = false
    app, remote = new_app()
    local flushed = 0
    app.plugin.settings.flush = function() flushed = flushed + 1 end
    local function toggle()
        local menu = app:open_menu()
        menu:onMenuSelect(find_item(menu.item_table, "Keep screen on"))
        UIManager:_checkTasks()
        app:close_menu()
    end
    toggle()
    assert_true(app.settings.keep_screen_on == false and flushed == 1, "toggled off and persisted")
    assert_true(share.pause_auto_suspend == false, "off clears the pause at once")
    toggle()
    assert_true(app.settings.keep_screen_on == true and flushed == 2, "toggled on and persisted")
    assert_true(share.pause_auto_suspend == true, "on sets the pause at once")
    app:onCloseWidget()
    app:onCloseWidget()
    assert_true(share.pause_auto_suspend == false, "release is idempotent")
    remote:free()
    share.pause_auto_suspend = saved
end)

check("menu_stays_open_on_toggles_and_closes_with_its_close_button", function()
    local app, remote = new_app()
    local s = app.plugin.settings.data.settings
    s.page_buttons, s.keep_screen_on = "keys", false
    app.plugin.settings.flush = function() end
    local menu = app:open_menu()
    local function entry(text) return find_item(menu.item_table, text) end
    local function tap(item)
        menu:onMenuSelect(item)
        UIManager:_checkTasks()
    end
    local function on_top() return top() == menu end

    tap(entry("Keep screen on"))
    assert_true(s.keep_screen_on == true and app.menu == menu and on_top(), "a toggle keeps the menu")
    assert_true(entry("Keep screen on").mandatory == "✓", "and shows the new state")

    -- a submenu choice: stays in the submenu, checkmarks and the parent's label follow
    tap(entry("Page buttons send"))
    local sub = menu.item_table
    assert_true(find_item(sub, "Mouse wheel"), "entered the submenu")
    tap(find_item(sub, "Mouse wheel"))
    assert_true(s.page_buttons == "wheel" and app.menu == menu and on_top(), "Page buttons choice keeps the menu")
    assert_true(menu.item_table == sub, "and stays in the submenu")
    assert_true(find_item(sub, "Mouse wheel").mandatory == "✓" and find_item(sub, "Page Up/Down keys").mandatory == nil,
        "the checkmark moved")
    menu:onClose()
    assert_true(entry("Page buttons send").mandatory == "Mouse wheel", "the parent label follows")

    -- the title bar's X closes everything, also from inside a submenu
    tap(entry("Page buttons send"))
    menu.title_bar.right_button.callback()
    UIManager:_checkTasks()
    assert_true(app.menu == nil and top() ~= menu, "the close button closes the whole menu")

    -- items that need the canvas still close it
    menu = app:open_menu()
    tap(find_item(menu.item_table, "Help"))
    assert_true(app.menu == nil and app.help ~= nil and top() == app.help, "Help closes the menu and opens the help")
    app.help:onClose()

    app:onCloseWidget()
    remote:free()
end)

check("display_panel_orientation_buttons_are_icons_and_remembered", function()
    local app, remote = new_app()
    local flushes = 0
    app.plugin.settings.flush = function() flushes = flushes + 1 end
    local start = Screen:getRotationMode()
    app:set_rotation_mode(0)
    local panel = app:open_display_panel()
    local row
    for _, r in ipairs(panel.buttons) do
        if r[1].icon and r[1].icon:find("^rotation%.") then row = r end
    end
    assert_true(row and #row == 4, "four rotation icon buttons")
    local names = {}
    for i, b in ipairs(row) do names[i] = b.icon; assert_true(b.text == nil, "icon only") end
    assert_true(table.concat(names, ",") == "rotation.P.90CCW,rotation.P.0UR,rotation.P.90CW,rotation.P.180UD", table.concat(names, ","))
    assert_true(row[2].selected and not row[1].selected and not row[3].selected and not row[4].selected, "upright marked")
    for _, r in ipairs(panel.buttons) do
        for _, b in ipairs(r) do
            assert_true(b.text ~= "Use current orientation as default", "no default-orientation button")
        end
    end
    local before = flushes
    row[3].callback()
    UIManager:_checkTasks()
    assert_true(Screen:getRotationMode() == 1, "90 CW rotates to mode 1")
    assert_true(app.display_panel == nil, "the panel closed on an orientation choice")
    assert_true(app.settings.orientation == 1 and flushes > before, "orientation stored and flushed")
    -- landscape: the L icon set, current one marked
    panel = app:open_display_panel()
    for _, r in ipairs(panel.buttons) do
        if r[1].icon and r[1].icon:find("^rotation%.") then row = r end
    end
    assert_true(row[3].icon == "rotation.L.90CW" and row[3].selected, "landscape set, mode 1 marked")
    app:close_display_panel()
    -- the toolbar's rotate button remembers it too
    app:rotate(1)
    assert_true(app.settings.orientation == 2, "rotate button stores the orientation")
    app:set_rotation_mode(start)
    app:onCloseWidget()
    remote:free()
end)

check("every_menu_close_path_repaints_the_viewer_after_a_toggle", function()
    local Event = require("ui/event")
    local paths = {
        ["X from a submenu"] = function(app, menu)
            menu:onMenuSelect(find_item(menu.item_table, "Page buttons send"))
            menu.title_bar.right_button.callback()
        end,
        ["Back at the top level"] = function(app, menu) menu:onClose() end,
        ["Menu key"] = function(app, menu) app:onKeyPress({ key = "Menu" }) end,
    }
    for name, close in pairs(paths) do
        local app, remote = new_app()
        app.plugin.settings.flush = function() end
        app.settings.keep_screen_on = false
        local menu = app:open_menu()
        menu:onMenuSelect(find_item(menu.item_table, "Keep screen on"))
        UIManager:_checkTasks()
        local modes = {}
        local real_dirty, real_refresh = UIManager.setDirty, UIManager._refresh
        UIManager.setDirty = function(self_, w, mode, ...)
            modes[#modes + 1] = mode
            return real_dirty(self_, w, mode, ...)
        end
        UIManager._refresh = function(self_, mode, ...)
            modes[#modes + 1] = mode
            return real_refresh(self_, mode, ...)
        end
        local ok, err = pcall(close, app, menu)
        UIManager.setDirty, UIManager._refresh = real_dirty, real_refresh
        assert_true(ok, tostring(err))
        assert_true(app.menu == nil, name .. " closes the menu")
        local flashed, seen = false, {}
        for _, m in ipairs(modes) do
            seen[#seen + 1] = tostring(m)
            if m == "flashui" or m == "full" or m == "flashpartial" then flashed = true end
        end
        assert_true(flashed, name .. " must request a flash/full refresh, got: " .. table.concat(seen, ","))
        app:onCloseWidget()
        remote:free()
    end
end)

check("keys_forward_to_the_remote", function()
    local Key = require("device/key")
    local app, remote, sent = new_app()
    assert_true(Device:hasKeyboard(), "this check is about devices that have a keyboard")

    local function press(name)
        sent.key = {}
        app:onKeyPress(Key:new(name, {}))
        app:onKeyRelease(Key:new(name, {}))
        local out = {}
        for _, e in ipairs(sent.key) do
            out[#out + 1] = string.format("%s0x%X", e.down and "+" or "-", e.keysym)
        end
        return table.concat(out, ",")
    end

    local cases = {
        { "Back", "+0xFF1B,-0xFF1B" },          -- Escape: the remote gets it, we do not leave
        { "Press", "+0xFF0D,-0xFF0D" },         -- Enter
        { "Tab", "+0xFF09,-0xFF09" },
        { "Backspace", "+0xFF08,-0xFF08" },
        { "Left", "+0xFF51,-0xFF51" },
        { "ContextMenu", "+0xFF67,-0xFF67" },   -- the PC "menu" key
        { "F5", "+0xFFC2,-0xFFC2" },
        { "LPgFwd", "+0xFF56,-0xFF56" },        -- Page_Down
        { "LPgBack", "+0xFF55,-0xFF55" },       -- Page_Up
        { "RPgFwd", "+0xFF56,-0xFF56" },
        { "RPgBack", "+0xFF55,-0xFF55" },
    }
    for _, case in ipairs(cases) do
        local got = press(case[1])
        assert_true(got == case[2], string.format("%s must be forwarded as %s, got %s",
            case[1], case[2], got))
    end

    -- auto-repeat is another press
    sent.key = {}
    app:onKeyRepeat(Key:new("Left", {}))
    assert_true(#sent.key == 1 and sent.key[1].down and sent.key[1].keysym == 0xFF51,
        "a repeated key must be forwarded as a press")

    -- the Menu key is ours: it must not be sent, and it opens the menu
    sent.key = {}
    app:onKeyPress(Key:new("Menu", {}))
    assert_true(#sent.key == 0, "the Menu key must not be forwarded")
    assert_true(app.menu ~= nil, "the Menu key must open the menu")
    app:onKeyPress(Key:new("Menu", {}))
    assert_true(app.menu == nil, "the Menu key must close it again")
    app:onKeyRelease(Key:new("Menu", {}))
    assert_true(#sent.key == 0, "the Menu key release must not be forwarded either")

    -- on a device without a keyboard, Back leaves the viewer instead
    local left = false
    app.plugin.leave_app = function() left = true end
    app:onKeyPress(Key:new("Back", {}))
    assert_true(not left, "with a keyboard, Escape must not leave the viewer")
    local original = Device.hasKeyboard
    Device.hasKeyboard = function() return false end
    app:onKeyPress(Key:new("Back", {}))
    Device.hasKeyboard = original
    assert_true(left, "without a keyboard, Back must leave the viewer")

    app:onCloseWidget()
    remote:free()
end)

-- ---------------------------------------------------------------- the panel: what a refresh reaches

--[=[--
An e-ink panel, modelled.

A panel is a physical medium: a pixel only changes where a refresh asked for it, no matter what was
painted into `Screen.bb` in between. That is precisely the difference the viewer has to respect (and
the reason a full-screen widget must ask for the refresh it needs), so these checks compare the panel
against the framebuffer after every step.

Every kind of refresh ends up in `Screen:refreshFullImp` on the emulator too (the base class routes
them all there), so one hook sees them all.
]=]
local bb = require("ffi/blitbuffer")
local Widget = require("ui/widget/widget")
local panel, refresh_log
local real_refresh_full_imp = Screen.refreshFullImp
function Screen:refreshFullImp(x, y, w, h, dither)
    if panel then
        local bx, by, bw, bh = self.bb:getBoundedRect(x, y, w, h)
        refresh_log[#refresh_log + 1] = { x = bx, y = by, w = bw, h = bh }
        panel:blitFrom(self.bb, bx, by, bx, by, bw, bh)
    end
    return real_refresh_full_imp(self, x, y, w, h, dither)
end

--[[--
A blank panel, an empty paint/refresh queue (a fresh screen), and the "home screen" the viewer is
shown over: a full-screen widget with a pattern, so a panel that missed an update is recognisable.
]]
local function fresh_screen()
    local size = Screen:getSize()
    UIManager._window_stack = {}
    UIManager._dirty = {}
    UIManager._refresh_stack = {}
    UIManager._refresh_func_stack = {}
    panel = bb.new(size.w, size.h, Screen.bb:getType())
    refresh_log = {}   -- the hook may run before fresh_screen() is done
    panel:paintRect(0, 0, size.w, size.h, bb.COLOR_WHITE)
    local Home = Widget:extend{ covers_fullscreen = true }
    function Home:paintTo(target, x, y)
        target:paintRect(x, y, self.dimen.w, self.dimen.h, bb.COLOR_WHITE)
        for i = 0, 15 do
            target:paintRect(x, y + i * math.floor(self.dimen.h / 16), self.dimen.w,
                math.max(1, math.floor(self.dimen.h / 32)), bb.COLOR_GRAY_5)
        end
    end
    local home = Home:new{}
    home.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    UIManager:show(home)
    UIManager:forceRePaint()
    refresh_log = {}   -- only what the viewer does from here on is asserted
end

--- A pixel as an independent value. `getPixel` hands back a *reference* into the buffer (LuaJIT
--- allows holding on to `p[0]`), so a value kept across a repaint would follow the repaint instead
--- of remembering it; `getColorRGB32()` builds a fresh one.
local function pixel_at(target, x, y)
    return target:getPixel(x, y):getColorRGB32()
end

--- Pixels the panel never received, i.e. what a user would still be seeing from before.
local function stale_pixels()
    local n = 0
    for py = 0, panel:getHeight() - 1 do
        for px = 0, panel:getWidth() - 1 do
            if pixel_at(panel, px, py) ~= pixel_at(Screen.bb, px, py) then n = n + 1 end
        end
    end
    return n
end

--- True when one of the refreshes applied since the last `refresh_log = {}` covered the screen.
local function flushed_full_screen()
    local size = Screen:getSize()
    for _, r in ipairs(refresh_log) do
        if r.w >= size.w and r.h >= size.h then return true end
    end
    return false
end

check("showing_the_viewer_pushes_the_whole_screen", function()
    fresh_screen()
    local app, remote = new_app()
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0,
        string.format("showing the viewer must reach the panel, %d px never arrived", stale_pixels()))
    assert_true(flushed_full_screen(), "and it must be a full-screen refresh, not a regional one")
    app:onCloseWidget()
    remote:free()
end)

check("a_wholesale_change_repaints_the_panel", function()
    fresh_screen()
    local app, remote = new_app()
    UIManager:forceRePaint()
    app:on_framebuffer_dirty({ x = 0, y = 0, w = 400, h = 300 })
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "a frame must reach the panel")

    -- a zoom changes the whole canvas at once
    refresh_log = {}
    app:zoom_to(0.5)
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "a zoom must leave the panel matching the framebuffer")
    assert_true(flushed_full_screen(), "a zoom is a wholesale change: it has to flash the screen")
    -- ...and the first frame after it carries the new geometry, so it is flashed too
    refresh_log = {}
    app:on_framebuffer_dirty({ x = 0, y = 0, w = 400, h = 300 })
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "the first frame after a zoom must reach the panel")
    assert_true(flushed_full_screen(), "and it is flashed, not blitted region by region")

    -- the keyboard appearing and going away is the same kind of change
    refresh_log = {}
    app:set_keyboard_visible(true)
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "showing the keyboard must not leave the panel behind")
    assert_true(flushed_full_screen(), "nor push it region by region")
    refresh_log = {}
    app:set_keyboard_visible(false)
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "and the same when it goes away again")

    -- a remote desktop resize
    refresh_log = {}
    remote:resize(800, 600)
    app:on_remote_resized()
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "a remote resize must leave the panel matching the framebuffer")
    assert_true(flushed_full_screen(), "a remote resize is a wholesale change as well")

    app:onCloseWidget()
    remote:free()
end)

check("the_menu_lands_on_the_panel", function()
    fresh_screen()
    local app, remote = new_app()
    UIManager:forceRePaint()
    app:zoom_to(1)                    -- 1:1, so a pixel probe below means what it says
    UIManager:forceRePaint()
    local cr = remote:canvas_rect_for({ x = 0, y = 0, w = 400, h = 300 })
    assert_true(cr ~= nil, "the whole remote screen must be visible")
    local dx, dy = app.canvas.x + cr.x, app.canvas.y + cr.y
    app:on_framebuffer_dirty({ x = 0, y = 0, w = 400, h = 300 })
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "the frame must reach the panel")
    local desktop = pixel_at(panel, dx + 5, dy + 5)

    refresh_log = {}
    app:open_menu()
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0,
        string.format("opening the menu must flush the whole screen, %d px are stale", stale_pixels()))
    assert_true(flushed_full_screen(), "a menu over a framebuffer is a wholesale change")
    assert_true(pixel_at(panel, dx + 5, dy + 5) ~= desktop,
        "and the panel has to show the menu, not the desktop")
    assert_true(app.menu.covers_fullscreen == true,
        "the menu must declare that it covers the screen, so the viewer underneath is not repainted")

    refresh_log = {}
    app:close_menu()
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "closing the menu must give the whole screen back to the viewer")
    assert_true(pixel_at(panel, dx + 5, dy + 5) == desktop,
        "and the panel has to show the desktop again")

    app:onCloseWidget()
    remote:free()
end)

check("a_popup_leaves_the_panel_alone_but_not_the_plane", function()
    fresh_screen()
    local app, remote = new_app()
    UIManager:forceRePaint()
    app:zoom_to(1)
    UIManager:forceRePaint()
    local cr = remote:canvas_rect_for({ x = 0, y = 0, w = 400, h = 300 })
    assert_true(cr ~= nil, "the whole remote screen must be visible")
    local dx, dy = app.canvas.x + cr.x, app.canvas.y + cr.y
    local plane = remote:get_plane()
    plane:paintRect(0, 0, 400, 300, bb.COLOR_GRAY_7)
    remote:mark_dirty()
    app:on_framebuffer_dirty({ x = 0, y = 0, w = 400, h = 300 })
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "the frame must reach the panel")

    app:open_menu()
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "the menu must reach the panel")
    local menu_px = pixel_at(panel, dx + 5, dy + 5)
    local flushes = #refresh_log

    -- the server changes the desktop while the menu is up
    local plane_before = pixel_at(plane, 5, 5)
    plane:paintRect(0, 0, 400, 300, bb.COLOR_GRAY_3)
    remote:mark_dirty()
    app:on_framebuffer_dirty({ x = 0, y = 0, w = 400, h = 300 })
    UIManager:forceRePaint()
    assert_true(#refresh_log == flushes, "a popup above us must leave the panel alone")
    assert_true(pixel_at(panel, dx + 5, dy + 5) == menu_px, "so the panel still shows the menu")
    assert_true(pixel_at(plane, 5, 5) ~= plane_before, "but the plane itself must stay current")

    -- and the flash that closing the menu asks for carries that change to the panel
    app:close_menu()
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "closing the menu must flush the whole screen")
    assert_true(pixel_at(panel, dx + 5, dy + 5) ~= menu_px,
        "and the panel must show the change that arrived while the menu was up")

    app:onCloseWidget()
    remote:free()
end)

check("closing_the_viewer_shows_the_home_screen", function()
    fresh_screen()
    local app, remote = new_app()
    UIManager:forceRePaint()
    app:on_framebuffer_dirty({ x = 0, y = 0, w = 400, h = 300 })
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "the viewer must be on the panel")
    local viewer_px = pixel_at(panel, 10, 10)

    -- Leave it with nothing but the viewer's own close path, with the keyboard up: closing the
    -- keyboard queues a refresh of just its own area, and that regional request used to be the last
    -- word on the whole screen (`UIManager:close` refreshes nothing by itself).
    app:set_keyboard_visible(true)
    UIManager:forceRePaint()
    refresh_log = {}
    UIManager:close(app)              -- the plain close: no refreshtype at all
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0,
        string.format("the home screen must reach the panel, %d px never arrived", stale_pixels()))
    assert_true(flushed_full_screen(), "and it must be a full-screen refresh")
    assert_true(pixel_at(panel, 10, 10) ~= viewer_px, "the panel must have moved on from the viewer")
end)

check("leaving_the_viewer_through_the_plugin_restores_the_home_screen", function()
    fresh_screen()
    local app, remote = new_app()
    UIManager:forceRePaint()
    app:on_framebuffer_dirty({ x = 0, y = 0, w = 400, h = 300 })
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0, "the viewer must be on the panel")
    local viewer_px = pixel_at(panel, 10, 10)

    app:set_keyboard_visible(true)
    UIManager:forceRePaint()
    plugin.sessions = {}
    plugin.app = app                  -- as VNC:_open_app leaves it
    plugin:leave_app()                -- main.lua's own path
    plugin.app = nil
    UIManager:forceRePaint()
    assert_true(stale_pixels() == 0,
        string.format("leave_app must leave the home screen on the panel, %d px never arrived", stale_pixels()))
    assert_true(flushed_full_screen(), "leave_app must ask for a full-screen refresh")
    assert_true(pixel_at(panel, 10, 10) ~= viewer_px, "the panel must have moved on from the viewer")
    remote:free()
end)

-- ---------------------------------------------------------------- picture settings (per connection)

check("picture_settings_are_profile_fields_kept_in_shape", function()
    local Settings = require("vnc/settings")
    local writeToFile = require("util").writeToFile
    local path = data_dir .. "/ui_smoke_settings_picture.lua"
    writeToFile([==[
{
    ["settings"] = { ["color_depth"] = 8, ["jpeg_quality"] = 3, ["compress_level"] = 9 },
    ["profiles"] = {
        { ["name"] = "old", ["host"] = "h", ["port"] = 5900 },
        { ["name"] = "good", ["host"] = "h", ["port"] = 5900, ["color_depth"] = 16,
          ["enable_tight"] = true, ["jpeg_quality"] = 0, ["compress_level"] = 9, ["scaling"] = "sharp" },
        { ["name"] = "bad", ["host"] = "h", ["port"] = 5900, ["color_depth"] = 15,
          ["enable_tight"] = "yes", ["jpeg_quality"] = 12, ["compress_level"] = 2.5, ["scaling"] = "blurry" },
    },
}
]==], path, true, true)
    local s = Settings.open(path)
    local old, good, bad = s:get_profile("old"), s:get_profile("good"), s:get_profile("bad")
    assert_true(old.color_depth == 24 and old.enable_tight == false and old.jpeg_quality == false
        and old.compress_level == false, "a profile without the fields loads as 24/false/false/false")
    assert_true(good.color_depth == 16 and good.enable_tight == true and good.jpeg_quality == 0
        and good.compress_level == 9, "valid values are kept")
    assert_true(good.scaling == nil and bad.scaling == nil, "a stray scaling field is dropped from profiles")
    assert_true(bad.color_depth == 24, "an unknown depth falls back to 24")
    assert_true(bad.enable_tight == false, "only the boolean true turns Tight on")
    assert_true(bad.jpeg_quality == false, "an out-of-range quality falls back to off")
    assert_true(bad.compress_level == false, "a non-integer level falls back to off")
    for _, key in ipairs({ "color_depth", "enable_tight", "jpeg_quality", "compress_level" }) do
        assert_true(s.data.settings[key] == nil, "the global " .. key .. " is gone")
    end
end)

check("a_stored_global_tight_becomes_the_profile_default", function()
    -- `enable_tight` was a global setting in released versions: a user who had it on keeps it.
    local Settings = require("vnc/settings")
    local writeToFile = require("util").writeToFile
    local path = data_dir .. "/ui_smoke_settings_legacy_tight.lua"
    writeToFile([==[
{
    ["settings"] = { ["enable_tight"] = true },
    ["profiles"] = {
        { ["name"] = "plain", ["host"] = "h", ["port"] = 5900 },
        { ["name"] = "off", ["host"] = "h", ["port"] = 5900, ["enable_tight"] = false },
    },
}
]==], path, true, true)
    local s = Settings.open(path)
    assert_true(s:get_profile("plain").enable_tight == true, "a profile without the field inherits Tight")
    assert_true(s:get_profile("off").enable_tight == false, "a profile's own choice wins")
    assert_true(s.data.settings.enable_tight == nil, "the global is dropped")
    s:flush()
    local on_disk = dofile(path)
    assert_true(on_disk.profiles[1].enable_tight == true, "the inherited value is written to the profile")
    assert_true(on_disk.settings.enable_tight == nil, "and the global is not written back")

    local path2 = data_dir .. "/ui_smoke_settings_legacy_tight_off.lua"
    writeToFile('{ ["settings"] = { ["enable_tight"] = false }, ["profiles"] = { { ["name"] = "p", ["host"] = "h" } } }\n',
        path2, true, true)
    assert_true(Settings.open(path2):get_profile("p").enable_tight == false, "a global off leaves Tight off")
end)

check("save_profile_keeps_omitted_picture_fields", function()
    local Settings = require("vnc/settings")
    local path = data_dir .. "/ui_smoke_settings_picture_save.lua"
    os.remove(path)
    local s = Settings.open(path)
    s:save_profile{ name = "p", host = "h", port = 5900 }
    local p = s:get_profile("p")
    assert_true(p.color_depth == 24 and p.enable_tight == false and p.jpeg_quality == false
        and p.compress_level == false, "a new profile gets the defaults")
    assert_true(p.scaling == nil, "scaling is not a profile field")
    s:save_profile({ name = "p", host = "h", port = 5900, color_depth = 8, enable_tight = true,
        jpeg_quality = 3, compress_level = 9 }, "p")
    s:save_profile({ name = "p", host = "h2", port = 5900 }, "p")
    p = s:get_profile("p")
    assert_true(p.host == "h2", "the edit is applied")
    assert_true(p.color_depth == 8 and p.enable_tight == true and p.jpeg_quality == 3
        and p.compress_level == 9, "an edit without the picture fields keeps them")
    s:save_profile({ name = "p", host = "h2", port = 5900, color_depth = 99, enable_tight = false,
        jpeg_quality = false, compress_level = false }, "p")
    p = s:get_profile("p")
    assert_true(p.color_depth == 24 and p.enable_tight == false and p.jpeg_quality == false
        and p.compress_level == false, "given fields are applied and normalised")
end)

--- The editor's Picture button (its label carries the summary).
local function picture_button(editor)
    for _, row in ipairs(editor.buttons or {}) do
        for _, btn in ipairs(row) do
            if btn.text and btn.text:sub(1, 8) == "Picture:" then return btn end
        end
    end
    error("no Picture button in the editor")
end
local SUB = "   \u{21B3} "
--- A connected session for profile `name` whose remote records `set_scaling` calls.
local function live_session(name)
    local Session = require("vnc/session")
    local session = Session.new{ profile = store:get_profile(name) }
    session.state = "connected"
    session.remote = { calls = {}, set_scaling = function(self, mode) self.calls[#self.calls + 1] = mode end }
    plugin.sessions = { [name] = session }
    return session
end
local function button_starting(widget, prefix)
    for _, row in ipairs(widget.buttons or {}) do
        for _, btn in ipairs(row) do
            if btn.text and btn.text:sub(1, #prefix) == prefix then return btn end
        end
    end
    error(string.format("no button starting with %q in %s", prefix, stack_desc()), 2)
end

check("editor_picture_settings_save_and_cancel", function()
    local Dialogs = require("vnc/dialogs")
    store:save_profile({ name = "good", host = "127.0.0.1", port = 5900, color_depth = 24,
        enable_tight = false, jpeg_quality = false, compress_level = false }, "good")
    local NEXT = "Takes effect on the next connection."

    local editor = Dialogs.edit_profile(plugin, store:get_profile("good"), {})
    assert_true(picture_button(editor).text == "Picture: 24-bit", "all defaults read as 24-bit, got "
        .. picture_button(editor).text)
    assert_true(editor.buttons[#editor.buttons][1].text == "Cancel", "Cancel/Save stay the last row")
    editor.input_fields[2]:setText("10.1.1.1")   -- typed, not yet saved

    picture_button(editor).callback()
    local pic = top()
    assert_true(pic ~= editor and pic.buttons, "the picture dialog opens over the editor")
    assert_true(not editor:isKeyboardVisible(), "the editor's keyboard makes way for it")
    local depth = button_starting(pic, "Colour depth")
    local jpeg = button_starting(pic, SUB .. "JPEG quality")
    local level = button_starting(pic, SUB .. "Compression level")
    assert_true(depth.text == "Colour depth: 24-bit", "the depth row shows the value, got " .. depth.text)
    assert_true(jpeg.enabled == false and level.enabled == false, "JPEG/compression need Tight")
    assert_true(jpeg.text == SUB .. "JPEG quality: Off", "the JPEG row shows its value, got " .. jpeg.text)
    assert_true(level.text == SUB .. "Compression level: Off", "so does compression, got " .. level.text)
    assert_true(jpeg.allow_hold_when_disabled and level.allow_hold_when_disabled, "dimmed rows stay long-pressable")
    for _, row in ipairs(pic.buttons) do
        assert_true(not row[1].text:find("needs", 1, true), "no label says needs: " .. row[1].text)
    end
    for _, row in ipairs(pic.buttons) do
        assert_true(not row[1].text:find("Sharp", 1, true), "no sharp row in the picture dialog: " .. row[1].text)
    end
    local SHORT = "Long-press a setting for details, or tap Help."
    assert_true(pic.title == SHORT, "the title is the short line, got " .. tostring(pic.title))
    for _, word in ipairs({ "Its main advantage", "next connection", "how many bits", "Sharp" }) do
        assert_true(not pic.title:find(word, 1, true), "no paragraph text in the title: " .. word)
    end
    local before = #stack()
    find_button(pic, "Help").callback()
    local viewer = top()
    assert_true(#stack() == before + 1 and viewer ~= pic and viewer.text, "Help opens a viewer on top: " .. stack_desc())
    assert_true(viewer.title == "Picture settings", "viewer title, got " .. tostring(viewer.title))
    assert_true(not editor:isKeyboardVisible(), "the keyboard stays hidden while the viewer is open")
    assert_true(viewer.text:find("Its main advantage is JPEG", 1, true) and viewer.text:find("next connection", 1, true),
        "the full explanation, got " .. viewer.text)
    -- Sharp scaling is a Display-panel setting: only the closing advice may point to it, not a setting paragraph.
    local settings_part = viewer.text:sub(1, (viewer.text:find("next connection", 1, true)))
    assert_true(not settings_part:find("Sharp", 1, true) and not settings_part:find("sharp", 1, true),
        "no setting paragraph mentions sharp scaling")
    assert_true(viewer.text:find("-z 2", 1, true) and viewer.text:find("other than 100%", 1, true),
        "the advice points to the server script's -z and to zoom 100%")
    assert_true(viewer.text:find("Measure it: in the connection's menu, tap Find fastest picture settings with your usual content on the PC screen.", 1, true),
        "the advice points to the benchmark")
    assert_true(not viewer.text:find("needs", 1, true), "no 'needs' in the explanation")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    assert_true(viewer.text:sub(1, #TextBoxWidget.PTF_HEADER) == TextBoxWidget.PTF_HEADER, "viewer text is PTF text")
    assert_true(viewer.text:find(TextBoxWidget.PTF_BOLD_START .. "Colour depth" .. TextBoxWidget.PTF_BOLD_END
        .. ": how many bits", 1, true), "setting names are bold")
    local tbw = viewer.box_widget
    assert_true(tbw and tbw._ptf_char_is_bold, "the viewer's TextBoxWidget honours PTF (bold map built)")
    local bold_n = 0
    for _ in pairs(tbw._ptf_char_is_bold) do bold_n = bold_n + 1 end
    assert_true(bold_n == #("Colour depth") + #("Tight") + #("JPEG quality") + #("Compression level")
        + #("Which is fastest?") + #("Scale on the PC, not on the e-reader")
        + #("Example"),
        "exactly the four names and the three advice headings are bold, got " .. bold_n)
    assert_true(tbw.text:find("Colour depth: how many bits", 1, true) and not tbw.text:find("\u{FFF2}", 1, true),
        "markers are stripped from the rendered text")
    viewer:onClose()
    assert_true(top() == pic and #stack() == before, "closing the viewer returns to the picture dialog: " .. stack_desc())
    assert_true(button_starting(pic, "Colour depth").text == "Colour depth: 24-bit", "choices intact after Help")
    assert_true(not editor:isKeyboardVisible(), "the keyboard is still hidden")
    local order = {}
    for _, row in ipairs(pic.buttons) do order[#order + 1] = row[1].text:match("^[^:]+") end
    assert_true(table.concat(order, "|") == "Colour depth|Tight encoding|"
        .. SUB .. "JPEG quality|" .. SUB .. "Compression level|Help|Done", "row order, got " .. table.concat(order, "|"))
    -- long press shows the same help as the old menu entries
    jpeg.hold_callback()
    assert_true(top().text and top().text:find("JPEG quality: Off sends everything lossless.", 1, true)
        and top().text:find("Only works at 24-bit colour.", 1, true), "JPEG help, got " .. tostring(top().text))
    UIManager:close(top())
    button_starting(pic, "Tight encoding").hold_callback()
    assert_true(top().text:find("JPEG", 1, true), "Tight help mentions JPEG")
    UIManager:close(top())

    depth.callback()
    local choice = top()
    find_button(choice, "8-bit").callback()
    pic = top()
    assert_true(button_starting(pic, "Colour depth").text == "Colour depth: 8-bit", "the choice is shown")
    button_starting(pic, "Tight encoding").callback()
    pic = top()
    assert_true(button_starting(pic, "Tight encoding").text == "Tight encoding: on", "Tight is shown on")
    jpeg = button_starting(pic, SUB .. "JPEG quality")
    assert_true(jpeg.enabled ~= false, "with Tight on JPEG is selectable")
    assert_true(jpeg.text == SUB .. "JPEG quality: Off", "with Tight on the row shows the value, got " .. jpeg.text)
    jpeg.callback()
    choice = top()
    find_button(choice, "Off")
    find_button(choice, "9")
    find_button(choice, "3").callback()
    pic = top()
    find_button(pic, "Done").callback()
    -- (the editor's keyboard comes back above it)
    for _, w in ipairs(stack()) do
        assert_true(w == editor or not w.buttons, "the picture dialog is gone: " .. stack_desc())
    end
    assert_true(count(is_editor) == 1 and stack()[1] == editor, "the same editor, not a new one")
    assert_true(editor:isKeyboardVisible(), "the keyboard is back")
    assert_true(editor.input_fields[2]:getText() == "10.1.1.1", "typed text survives the picture dialog")
    assert_true(picture_button(editor).text == "Picture: 8-bit, Tight, JPEG 3",
        "the button summarises the choice, got " .. picture_button(editor).text)
    assert_true(editor.button_table:getButtonById("picture").text == "Picture: 8-bit, Tight, JPEG 3",
        "the shown button is relabelled")
    local p = store:get_profile("good")
    assert_true(p.color_depth == 24 and p.enable_tight == false, "nothing is stored before Save")

    local live = live_session("good")
    find_button(editor, "Save").callback()
    plugin.sessions = {}
    p = store:get_profile("good")
    assert_true(p.color_depth == 8 and p.enable_tight == true and p.jpeg_quality == 3
        and p.compress_level == false, "Save stores the choice on the profile")
    assert_true(top().text == "Reconnect to apply the new settings.", "saving the live profile says to reconnect")
    UIManager:close(top())

    -- the same changes, then Cancel: nothing changes
    editor = Dialogs.edit_profile(plugin, store:get_profile("good"), {})
    assert_true(picture_button(editor).text == "Picture: 8-bit, Tight, JPEG 3", "the stored choice is shown")
    picture_button(editor).callback()
    button_starting(top(), "Colour depth").callback()
    find_button(top(), "16-bit").callback()
    button_starting(top(), SUB .. "Compression level").callback()
    find_button(top(), "9").callback()
    find_button(top(), "Done").callback()
    assert_true(picture_button(editor).text == "Picture: 16-bit, Tight, JPEG 3, compr. 9", "summary with all four")
    find_button(editor, "Cancel").callback()
    p = store:get_profile("good")
    assert_true(p.color_depth == 8 and p.compress_level == false, "Cancel discards the choice")

    -- a save while not connected shows no notice
    editor = Dialogs.edit_profile(plugin, store:get_profile("good"), {})
    find_button(editor, "Save").callback()
    for _, w in ipairs(stack()) do
        assert_true(w.text ~= "Reconnect to apply the new settings.", "no notice without a live session")
    end
    store:save_profile({ name = "good", host = "127.0.0.1", port = 5900, color_depth = 24,
        enable_tight = false, jpeg_quality = false, compress_level = false }, "good")
end)

check("session_hands_the_profile_picture_settings_to_the_protocol", function()
    local socket = require("socket")
    local Protocol = require("vnc/protocol")
    local Session = require("vnc/session")
    local listener = assert(socket.bind("127.0.0.1", 0))
    local _, port = listener:getsockname()
    local session = Session.new{
        profile = { name = "t", host = "127.0.0.1", port = port, password = "",
                    color_depth = 8, enable_tight = true, jpeg_quality = 3, compress_level = false },
    }
    local real_new, captured = Protocol.new, nil
    local STOP = {}
    Protocol.new = function(opts) captured = opts error(STOP) end
    session.state = "connecting"                    -- what connect() puts it in before dialling
    local ok, err = pcall(function() session:_do_connect(session._attempt) end)
    Protocol.new = real_new
    if session.sock then session.sock:close() end
    listener:close()
    if not ok and err ~= STOP then error(err, 0) end
    assert_true(captured ~= nil, "the session must build a protocol")
    assert_true(captured.pixel_format and captured.pixel_format.bits_per_pixel == 8,
        "the protocol must get the 8-bit pixel format")
    local enc = captured.encodings
    assert_true(enc[#enc] == -29, "the encoding list must end in JPEG quality 3 (-29), got " .. tostring(enc[#enc]))
    for _, e in ipairs(enc) do
        assert_true(e > -256 or e < -247, "an off compression level must not be sent")
    end
end)

check("editor_reconnect_notice_only_for_per_connection_fields", function()
    local Dialogs = require("vnc/dialogs")
    local RECONNECT = "Reconnect to apply the new settings."
    store:save_profile({ name = "good", host = "127.0.0.1", port = 5900, color_depth = 24,
        enable_tight = false, jpeg_quality = false, compress_level = false}, "good")
    local function no_notice(why)
        for _, w in ipairs(stack()) do assert_true(w.text ~= RECONNECT, why) end
    end
    live_session("good")
    local editor

    -- a depth change on the live profile still asks for a reconnect
    editor = Dialogs.edit_profile(plugin, store:get_profile("good"), {})
    picture_button(editor).callback()
    button_starting(top(), "Colour depth").callback()
    find_button(top(), "16-bit").callback()
    find_button(top(), "Done").callback()
    find_button(editor, "Save").callback()
    assert_true(top().text == RECONNECT, "a depth change says to reconnect")
    UIManager:close(top())

    -- a host change too, while an unchanged save says nothing
    editor = Dialogs.edit_profile(plugin, store:get_profile("good"), {})
    find_button(editor, "Save").callback()
    no_notice("an unchanged save needs no reconnect")
    editor = Dialogs.edit_profile(plugin, store:get_profile("good"), {})
    editor.input_fields[2]:setText("127.0.0.2")
    find_button(editor, "Save").callback()
    assert_true(top().text == RECONNECT, "a host change says to reconnect")
    UIManager:close(top())
    plugin.sessions = {}
    store:save_profile({ name = "good", host = "127.0.0.1", port = 5900, color_depth = 24,
        enable_tight = false, jpeg_quality = false, compress_level = false}, "good")
end)

check("session_applies_the_global_scaling_to_its_remote", function()
    local socket = require("socket")
    local Protocol = require("vnc/protocol")
    local Session = require("vnc/session")
    local listener = assert(socket.bind("127.0.0.1", 0))
    local _, port = listener:getsockname()
    local session = Session.new{
        profile = { name = "t", host = "127.0.0.1", port = port, password = "" },
        plugin = { settings = { data = { settings = { scaling = "sharp" } } } },
    }
    local real_new, captured = Protocol.new, nil
    local STOP = {}
    Protocol.new = function(opts) captured = opts error(STOP) end
    session.state = "connecting"                    -- what connect() puts it in before dialling
    local ok, err = pcall(function() session:_do_connect(session._attempt) end)
    Protocol.new = real_new
    if session.sock then session.sock:close() end
    listener:close()
    if not ok and err ~= STOP then error(err, 0) end
    captured.callbacks.on_connected("n", 8, 8)
    assert_true(session.remote.scaling == "sharp", "a new remote gets the global scaling")
    session.plugin.settings.data.settings.scaling = "smooth"
    captured.callbacks.on_connected("n", 8, 8)
    assert_true(session.remote.scaling == "smooth", "a reused remote gets the global scaling")
    session.plugin.settings.data.settings.scaling = "sharp"
    captured.callbacks.on_desktop_resize(16, 16)
    assert_true(session.remote.scaling == "sharp", "a resized remote gets the global scaling")
    session.remote:free()
    session.remote = nil
end)

check("session_teardown_drops_the_timing_state", function()
    local Session = require("vnc/session")
    local session = Session.new{ profile = { name = "t", host = "h", port = 1 } }
    session.tm = { bytes = 0 }
    session:_teardown_connection()
    assert_true(session.tm == nil, "a torn-down connection keeps no timing state")
end)

check("opening_another_connection_replaces_the_viewer", function()
    -- a connection picked from the viewer's own menu must get a viewer of its own; the one shown
    -- so far is detached (it stays connected, as after Leave)
    local old_app, old_remote = new_app()
    local other_app, other_remote = new_app()
    local a, b = old_app.session, other_app.session
    UIManager:close(other_app)
    local log = {}
    a.detach = function() log[#log + 1] = "detach a" end
    b.attach = function(_, app) log[#log + 1] = "attach b"; b.attached_to = app end
    plugin.app = old_app
    -- (not about orientation: the remote's must not turn the screen here)
    local match = store:get_setting("match_orientation")
    store:set_setting("match_orientation", false)
    plugin:_open_app(b)
    store:set_setting("match_orientation", match)
    local now = plugin.app
    assert_true(now ~= old_app and now.session == b, "the viewer must be the new session's")
    assert_true(now.remote == other_remote, "and show the new session's remote")
    assert_true(table.concat(log, ",") == "detach a,attach b", "the old session detached first: " .. table.concat(log, ","))
    assert_true(b.attached_to == now, "the new session is attached to the new viewer")
    for _, w in ipairs(stack()) do assert_true(w ~= old_app, "the old viewer is still on the stack") end
    now:onCloseWidget()
    UIManager:close(now)
    plugin.app = nil
    old_remote:free(); other_remote:free()
end)

check("two_finger_pan_follows_the_cumulative_relative", function()
    -- GestureDetector's two_finger_pan carries the offset from the gesture's start on every move;
    -- fingers moving left drag the picture left, i.e. the view moves right
    local app, remote = new_app(2000, 1500)
    app:zoom_to(2)
    local start = { x = 300, y = 400 }
    local x0, y0 = remote.view_x, remote.view_y
    app:onTwoFingerPan(nil, { relative = { x = -10, y = 0 }, start_pos = start })
    app:onTwoFingerPan(nil, { relative = { x = -20, y = -6 }, start_pos = start })
    local s = remote:get_scale()
    assert_true(math.abs((remote.view_x - x0) * s - 20) < 1e-6 and math.abs((remote.view_y - y0) * s - 6) < 1e-6,
        string.format("two events at 10 then 20 px must pan 20 px, panned %.1f, %.1f",
            (remote.view_x - x0) * s, (remote.view_y - y0) * s))
    -- a new gesture (another start point) starts from zero again
    x0 = remote.view_x
    app:onTwoFingerPan(nil, { relative = { x = -5, y = 0 }, start_pos = { x = 10, y = 10 } })
    assert_true(math.abs((remote.view_x - x0) * s - 5) < 1e-6, "a new gesture pans by its own offset")
    app:onTwoFingerPanRelease(nil, {})
    app:onCloseWidget()
    UIManager:close(app)
    remote:free()
end)

check("onscreen_keyboard_enter_and_tab_send_their_keys", function()
    -- the on-screen keyboard's Enter types "\n" through the inputbox stub
    local Keysyms = require("vnc/keysyms")
    assert_true(Keysyms.from_char("\n") == 0xFF0D and Keysyms.from_char("\r") == 0xFF0D, "newline is Return")
    assert_true(Keysyms.from_char("\t") == 0xFF09, "tab is Tab")
    assert_true(Keysyms.from_char("\1") == nil and Keysyms.from_char("\127") == nil, "other control characters have no key")
    assert_true(Keysyms.from_char("a") == 0x61 and Keysyms.from_char("é") == 0xE9
        and Keysyms.from_char("ő") == 0x01000151, "printable characters are unchanged")
end)

check("wifi_is_turned_off_by_the_last_connection_only", function()
    local Session = require("vnc/session")
    local offs = 0
    local net = { turnOffWifi = function() offs = offs + 1 end }
    local fake_plugin = { sessions = {} }
    local a = Session.new{ profile = { name = "a", host = "h", port = 1 }, plugin = fake_plugin }
    local b = Session.new{ profile = { name = "b", host = "h", port = 2 }, plugin = fake_plugin }
    a._net, b._net = function() return net end, function() return net end
    fake_plugin.sessions = { a = a, b = b }
    a.wifi_was_on, a.state = false, "connected" -- a turned Wi-Fi on
    b.wifi_was_on, b.state = true, "connected"  -- b found it on
    a:_restore_wifi()
    assert_true(offs == 0, "b still needs the Wi-Fi")
    assert_true(b.wifi_was_on == false, "b inherits turning it off")
    fake_plugin.sessions.a, a.state = nil, "disconnected"
    b:_restore_wifi()
    assert_true(offs == 1, "the last connection turns it off")
end)

check("retry_mode_keeps_wifi_on_until_the_loop_ends", function()
    local Session = require("vnc/session")
    local offs, ons = 0, 0
    local net = { isWifiOn = function() return true end, turnOffWifi = function() offs = offs + 1 end,
                  turnOnWifiAndWaitForConnection = function() ons = ons + 1 end }
    local s = Session.new{ profile = { name = "r", host = "127.0.0.1", port = 1 }, plugin = { sessions = {} } }
    s._net = function() return net end
    s.wifi_was_on = false; s:set_keep_wifi(true)
    local results = {}
    s:connect(function(ok) results[#results + 1] = ok end)
    while s._phase == "dial" do s:_connect_tick(); require("socket").sleep(0.002) end
    assert_true(results[1] == false and s:get_state() == "error")
    assert_true(offs == 0 and s.wifi_was_on == false, "failure keeps Wi-Fi and the duty")
    s:connect(function(ok) results[#results + 1] = ok end)
    while s._phase == "dial" do s:_connect_tick(); require("socket").sleep(0.002) end
    assert_true(offs == 0 and s.wifi_was_on == false)
    s:set_keep_wifi(false)
    assert_true(offs == 1 and s.wifi_was_on == nil, "the loop ending restores it once")
    s.wifi_was_on = false; s:set_keep_wifi(true); s:hangup()
    assert_true(offs == 1 and s:get_state() == "disconnected")
    assert_true(ons == 0, "Wi-Fi was already on, so it was never turned on")
end)

check("a_retrying_session_inherits_the_wifi_duty", function()
    local Session = require("vnc/session")
    local offs = 0
    local net = { isWifiOn = function() return true end, turnOffWifi = function() offs = offs + 1 end }
    local plugin = { sessions = {} }
    local a = Session.new{ profile = { name = "a", host = "127.0.0.1", port = 1 }, plugin = plugin }
    local b = Session.new{ profile = { name = "b", host = "127.0.0.1", port = 2 }, plugin = plugin }
    a._net, b._net = function() return net end, function() return net end
    plugin.sessions = { a = a, b = b }
    b.wifi_was_on, b.state = false, "connected" -- b turned Wi-Fi on
    a.state, a.keep_wifi = "error", true         -- a is between retry attempts
    b:disconnect()
    assert_true(offs == 0, "a's retry loop still needs the Wi-Fi")
    assert_true(a.wifi_was_on == false, "a inherits turning it off")
    a:set_keep_wifi(false)
    assert_true(offs == 1, "the loop ending turns it off exactly once")
end)

check("hardware_keys_stay_local_under_a_popup_but_held_keys_are_released", function()
    local Key = require("device/key")
    local InfoMessage = require("ui/widget/infomessage")
    local app, remote, sent = new_app()
    -- held before the popup opens: its release must still reach the remote
    app:onKeyPress(Key:new("Left", {}))
    local popup = InfoMessage:new{ text = "popup" }
    UIManager:show(popup)
    sent.key = {}
    assert_true(app:onKeyPress(Key:new("Right", {})) == nil, "a press under a popup is not ours")
    assert_true(app:onKeyRepeat(Key:new("Right", {})) == nil, "nor a repeat")
    assert_true(app:onKeyRelease(Key:new("Right", {})) == nil, "nor the release of a key never sent")
    assert_true(#sent.key == 0, "nothing reached the remote under the popup")
    assert_true(app:onKeyRelease(Key:new("Left", {})) == true, "the held key's release is ours")
    assert_true(#sent.key == 1 and sent.key[1].keysym == 0xFF51 and sent.key[1].down == false,
        "and it lets the remote's key go")
    UIManager:close(popup)
    app:onCloseWidget()
    UIManager:close(app)
    remote:free()
end)

check("two_finger_pan_moves_the_picture_past_its_edges", function()
    -- fitted (the whole picture on screen), a drag still moves it: up to its corner reaching the
    -- canvas centre, no further
    local app, remote = new_app(400, 300)
    app.settings.zoom_mode = "fit"
    app:_reflow()
    local s = remote:get_scale()
    local x0 = remote.view_x
    assert_true(math.abs(x0 - (400 - remote.cw / s) / 2) < 1e-6, "fit centres the picture")
    local start = { x = 300, y = 300 }
    app:onTwoFingerPan(nil, { relative = { x = -100, y = 0 }, start_pos = start })
    assert_true(math.abs((remote.view_x - x0) * s - 100) < 1e-6, "fitted, the picture moves with the fingers")
    app:onTwoFingerPan(nil, { relative = { x = -100000, y = -100000 }, start_pos = start })
    assert_true(math.abs(remote.view_x - (400 - remote.cw / s / 2)) < 1e-6
        and math.abs(remote.view_y - (300 - remote.ch / s / 2)) < 1e-6,
        "dragged far, the picture's bottom-right corner stops at the canvas centre")
    app:onTwoFingerPan(nil, { relative = { x = 100000, y = 100000 }, start_pos = { x = 1, y = 1 } })
    assert_true(math.abs(remote.view_x + remote.cw / s / 2) < 1e-6 and math.abs(remote.view_y + remote.ch / s / 2) < 1e-6,
        "and its top-left corner the other way")
    app:onTwoFingerPanRelease(nil, {})
    app:onCloseWidget()
    UIManager:close(app)
    remote:free()
end)

check("toolbar_close_confirms_then_returns_to_the_list", function()
    local app, remote = new_app(nil, nil, { toolbar = true })
    local session = app.session
    local disconnected = false
    session.disconnect = function() disconnected = true end
    session.detach = function() end
    plugin.sessions = { test = session }
    plugin.app = app
    app.plugin = plugin
    app:open_menu()
    assert_true(not pcall(find_item, app.menu.item_table, "Disconnect"), "Disconnect moved to the toolbar")
    app:close_menu()
    tap_toolbar(app, "close")
    local confirm = top()
    assert_true(confirm.ok_callback, "a confirmation, stack: " .. stack_desc())
    assert_true(confirm.text == "Disconnect from test?" and confirm.ok_text == "Disconnect",
        "the menu's old confirmation: " .. tostring(confirm.text) .. " / " .. tostring(confirm.ok_text))
    assert_true(plugin.sessions.test == session and not disconnected, "nothing happens before the answer")
    answer_confirm(confirm, true)
    UIManager:close(confirm)
    assert_true(plugin.sessions.test == nil and disconnected, "the session is gone")
    assert_true(plugin.app == nil, "the viewer is closed")
    for _, w in ipairs(stack()) do assert_true(w ~= app, "viewer still on the stack") end
    assert_true(is_list(top()) and plugin.connection_list == top(), "the connection list is on top: " .. stack_desc())
    UIManager:close(top())
    remote:free()
end)

check("viewer_menu_has_no_picture_entries", function()
    local app, remote = new_app()
    app:open_menu()
    local has_page_buttons = false
    for _, item in ipairs(app.menu.item_table) do
        for _, prefix in ipairs({ "Colour depth", "Tight encoding", "JPEG quality", "Compression level" }) do
            assert_true(item.text:sub(1, #prefix) ~= prefix, "the viewer menu still has " .. item.text)
        end
        if item.text == "Page buttons send" then has_page_buttons = true end
    end
    assert_true(has_page_buttons, "Page buttons send stays in the viewer menu")
    app:onCloseWidget()
    remote:free()
end)

-- ---------------------------------------------------------------- find fastest picture settings

local BENCH_BUTTON = "Find fastest picture settings"
local BENCH_INTRO = "Tries 11 picture-setting combinations on this connection, twice each, in opposite order, a few seconds per try.\n\nBefore starting, put what you usually look at on the shared area of the PC — the page, document or app you use — and leave it still. Each combination fetches that screen several times, whole and in small pieces, and is scored by how fast it reaches this screen, including decoding and drawing at your current zoom.\n\nNothing is saved unless you tap Apply at the end."

--- A stand-in for vnc/benchmark: records what the UI asks of it; the test drives the callbacks.
local FakeBench = { instances = {} }
FakeBench.__index = FakeBench
function FakeBench.new(opts)
    local b = setmetatable({ opts = opts, started = false, cancelled = false }, FakeBench)
    FakeBench.instances[#FakeBench.instances + 1] = b
    return b
end
function FakeBench:start() self.started = true end
function FakeBench:cancel() self.cancelled = true end

local function bench_combo(depth, tight, compr, jpeg, label)
    return { color_depth = depth, enable_tight = tight, compress_level = compr, jpeg_quality = jpeg, label = label }
end
local BENCH_RESULTS = {
    { combination = bench_combo(8, true, 2, false, "8-bit, Tight, compr. 2"), ok = true,
      tile_px_per_s = 3456789, full_px_per_s = 900000, tile_ms = 12.4, full_ms = 812.6, full_bytes = 204800 },
    { combination = bench_combo(24, false, false, false, "24-bit, Tight off"), ok = true,
      tile_px_per_s = 1000000, full_px_per_s = 5000000, tile_ms = 40, full_ms = 95, full_bytes = 1048576 },
    { combination = bench_combo(16, false, false, false, "16-bit, Tight off"), ok = false,
      error = "no update within 15 s" },
    { combination = bench_combo(24, true, 2, 4, "24-bit, Tight, compr. 2, JPEG 4"), ok = false,
      error = "failed in pass 2: server refused the format" },
}

--- Opens the Connect/Edit/Delete dialog for `good` with the fake benchmark injected.
local function open_bench_actions()
    local Dialogs = require("vnc/dialogs")
    Dialogs.Benchmark = FakeBench
    FakeBench.instances = {}
    plugin.sessions = {}
    local actions = Dialogs.profile_actions(plugin, store:get_profile("good"), { on_back = function() end })
    UIManager:show(actions)
    return actions
end
local function viewer_buttons(viewer)
    local out = {}
    for _, row in ipairs(viewer.buttons_table or {}) do
        for _, btn in ipairs(row) do out[btn.text] = btn end
    end
    return out
end
--- Taps the button, Start in the intro, and returns the fake benchmark and the progress dialog.
local function start_bench()
    find_button(top(), BENCH_BUTTON).callback()
    answer_confirm(top(), true)
    return FakeBench.instances[#FakeBench.instances], top()
end

check("bench_button_and_intro_text", function()
    open_bench_actions()
    find_button(top(), BENCH_BUTTON).callback()
    local intro = top()
    assert_true(intro.ok_callback and intro.cancel_callback, "an intro ConfirmBox: " .. stack_desc())
    assert_true(intro.text == BENCH_INTRO, "intro text: " .. tostring(intro.text))
    assert_true(intro.ok_text == "Start" and intro.cancel_text == "Cancel", "Start/Cancel buttons")
    assert_true(count(is_actions) == 0, "the actions dialog is closed under the intro")
    answer_confirm(intro, false)
    expect_top(is_actions, "the actions dialog after Cancel in the intro")
    assert_true(#FakeBench.instances == 0, "Cancel in the intro starts nothing")
    require("vnc/dialogs").Benchmark = nil
end)

check("bench_start_shows_progress_and_cancel_returns", function()
    local before = store:get_profile("good")
    open_bench_actions()
    local bench, progress = start_bench()
    assert_true(bench and bench.started, "Start starts the benchmark")
    local o = bench.opts
    assert_true(o.profile.name == "good" and o.profile.host == before.host, "the stored profile is benchmarked")
    assert_true(o.combinations == nil, "the default combinations are used")
    assert_true(o.canvas.w > 0 and o.canvas.h > 0 and o.canvas.bb_type == Screen.bb:getType(),
        "canvas from the screen")
    assert_true(type(o.on_progress) == "function" and type(o.on_done) == "function", "callbacks")
    assert_true(o.sessions == plugin.sessions, "the plugin's sessions are handed over, to be detached for the run")
    assert_true(find_button(progress, "Cancel"), "progress has Cancel")
    assert_true(progress.dismissable == false, "the progress dialog is not dismissed by a stray tap")
    o.on_progress(3, 22, "16-bit, Tight off", "full", 1, 2)
    assert_true(top() == progress, "progress stays on top")
    assert_true(progress.title == "3/22 (pass 1/2): 16-bit, Tight off — full screen", "progress text: " .. tostring(progress.title))
    o.on_progress(4, 22, "16-bit, Tight, compr. 1", "connect", 1, 2)
    assert_true(progress.title == "4/22 (pass 1/2): 16-bit, Tight, compr. 1 — connecting", "progress text: " .. tostring(progress.title))
    o.on_progress(15, 22, "16-bit, Tight, compr. 1", "tiles", 2, 2)
    assert_true(progress.title == "15/22 (pass 2/2): 16-bit, Tight, compr. 1 — small pieces", "progress text: " .. tostring(progress.title))
    find_button(progress, "Cancel").callback()
    assert_true(bench.cancelled, "Cancel cancels the benchmark")
    expect_top(is_actions, "the actions dialog after Cancel")
    for _, w in ipairs(stack()) do assert_true(w ~= progress, "progress still on the stack") end
    local after = store:get_profile("good")
    for _, k in ipairs{ "color_depth", "enable_tight", "jpeg_quality", "compress_level" } do
        assert_true(after[k] == before[k], "cancel must not change " .. k)
    end
    require("vnc/dialogs").Benchmark = nil
end)

check("bench_canvas_follows_zoom_scaling_and_orientation", function()
    local saved = {}
    for _, k in ipairs{ "zoom_mode", "scaling", "orientation" } do saved[k] = store:get_setting(k) end
    local real_app = plugin.app
    plugin.app = nil
    store:set_setting("zoom_mode", 2)
    store:set_setting("scaling", "sharp")
    store:set_setting("orientation", (Screen:getRotationMode() + 1) % 4)
    local c = plugin:benchmark_canvas()
    assert_true(c.view_mode == 2 and c.scaling == "sharp", "zoom factor and sharp scaling")
    assert_true(c.w == Screen:getHeight() and c.h == Screen:getWidth(), "the viewer's orientation is used")
    store:set_setting("zoom_mode", "fit_with_keyboard")
    store:set_setting("scaling", "smooth")
    store:set_setting("orientation", Screen:getRotationMode())
    c = plugin:benchmark_canvas()
    assert_true(c.view_mode == "fit" and c.scaling == "smooth", "fitted modes fit")
    assert_true(c.w == Screen:getWidth() and c.h == Screen:getHeight(), "same orientation: the screen")
    -- the viewer's dither flag: software dithering on a BB8 screen only
    local BBm = require("ffi/blitbuffer")
    local real_dither, real_bb = Screen.sw_dithering, Screen.bb
    local bb8, bbrgb = BBm.new(4, 4, BBm.TYPE_BB8), BBm.new(4, 4, BBm.TYPE_BBRGB32)
    for _, case in ipairs{ { bb8, true, true }, { bb8, false, false }, { bbrgb, true, false } } do
        Screen.bb, Screen.sw_dithering = case[1], case[2]
        c = plugin:benchmark_canvas()
        assert_true(c.dither == case[3], string.format("dither: type %d sw %s: got %s",
            case[1]:getType(), tostring(case[2]), tostring(c.dither)))
    end
    Screen.bb, Screen.sw_dithering = real_bb, real_dither
    bb8:free(); bbrgb:free()
    plugin.app = { canvas = { x = 0, y = 0, w = 321, h = 123 } }
    c = plugin:benchmark_canvas()
    assert_true(c.w == 321 and c.h == 123, "an open viewer's canvas wins")
    plugin.app = real_app
    for k, v in pairs(saved) do store:set_setting(k, v) end
end)

check("bench_results_table_and_apply_best", function()
    store:save_profile({ name = "good", host = "127.0.0.1", port = 5900, password = "pw", color_depth = 16,
        enable_tight = false, jpeg_quality = false, compress_level = false }, "good")
    local before = {}
    for k, v in pairs(store:get_profile("good")) do before[k] = v end
    open_bench_actions()
    local bench = start_bench()
    bench.opts.on_done(BENCH_RESULTS)
    local viewer = top()
    assert_true(viewer.title == "Picture benchmark", "results viewer: " .. stack_desc())
    assert_true(viewer.monospace_font == true, "monospace table")
    for _, w in ipairs(stack()) do assert_true(not (w.title and w.title:find("(pass ", 1, true)), "progress closed") end
    local text = viewer.text
    local p1 = text:find("1. 8-bit, Tight, compr. 2", 1, true)
    local p2 = text:find("2. 24-bit, Tight off", 1, true)
    local p3 = text:find("16-bit, Tight off", 1, true)
    local p4 = text:find("24-bit, Tight, compr. 2, JPEG 4", 1, true)
    assert_true(p1 and p2 and p3 and p4 and p1 < p2 and p2 < p3 and p3 < p4, "rows in order:\n" .. text)
    for _, want in ipairs{ "\n   3.5 Mpx/s · 12 ms · 813 ms · 200 KB\n",
                           "\n   1.0 Mpx/s · 40 ms · 95 ms · 1024 KB\n",
                           "\n   failed: no update within 15 s\n", "\n   failed in pass 2: server refused the format" } do
        assert_true(text:find(want, 1, true), "missing " .. want .. " in:\n" .. text)
    end
    assert_true(not text:find("failed: failed", 1, true), "the engine's \"failed in pass N\" is not prefixed again:\n" .. text)
    assert_true(text:sub(1, text:find("\n", 1, true) - 1) == "Fastest first. Each row: screen pixels per second in small pieces · time per piece · time per full screen · size of a full screen; decoding and drawing included. Medians over two runs.",
        "results intro:\n" .. text)
    local buttons = viewer_buttons(viewer)
    assert_true(buttons["Apply best"] and buttons["Close"], "Apply best and Close")
    buttons["Apply best"].callback()
    local after = store:get_profile("good")
    assert_true(after.color_depth == 8 and after.enable_tight == true and after.compress_level == 2
        and after.jpeg_quality == false, "the best row's picture fields are saved")
    for k, v in pairs(before) do
        if k ~= "color_depth" and k ~= "enable_tight" and k ~= "compress_level" and k ~= "jpeg_quality" then
            assert_true(after[k] == v, "Apply best changed " .. k)
        end
    end
    for k in pairs(after) do assert_true(before[k] ~= nil or after[k] == nil, "Apply best added " .. k) end
    local info = top()
    assert_true(info.text == "Saved: 8-bit, Tight, compr. 2. Takes effect on the next connection.",
        "saved message: " .. tostring(info.text))
    UIManager:close(info)
    expect_top(is_actions, "the actions dialog under the message")
    for _, w in ipairs(stack()) do assert_true(w ~= viewer, "results viewer closed") end
    require("vnc/dialogs").Benchmark = nil
end)

check("bench_results_rows_fit_one_line_on_era_portrait", function()
    -- the PocketBook Era's 1264x1680 portrait frame (KOReader scales fonts by the screen size)
    local saved_bb = Screen.bb
    local era = require("ffi/blitbuffer").new(1264, 1680, saved_bb:getType())
    Screen.bb = era
    local ok, err = pcall(function()
        local Dialogs = require("vnc/dialogs")
        local worst = { combination = bench_combo(24, true, 2, 4, "24-bit, Tight, compr. 2, JPEG 4"), ok = true,
            tile_px_per_s = 10e6, full_px_per_s = 1e6, tile_ms = 999, full_ms = 9999, full_bytes = 9999 * 1024 }
        local results = { worst, BENCH_RESULTS[1], BENCH_RESULTS[2] }
        local text = Dialogs.benchmark_table(results)
        local worst_line = "   10.0 Mpx/s · 999 ms · 9999 ms · 9999 KB"
        assert_true(text:find("\n" .. worst_line .. "\n", 1, true), "worst case row:\n" .. text)
        local viewer = Dialogs.benchmark_results(plugin, "good", results, function() end)
        local box = viewer.box_widget
        assert_true(box and box.face and box.width > 0, "the viewer's text box")
        local RenderText = require("ui/rendertext")
        local function share(line) return RenderText:sizeUtf8Text(0, box.width, box.face, line).x / box.width end
        -- calibrated on the device: this row (about 0.97 of the emulated width) wrapped in the photo,
        -- so the device has less room than the emulation; 0.85 keeps a margin below that
        local LIMIT = 0.85
        local photo = share("   2.1 Mpx/s small  63 ms/tile  full 998 ms  648 KB/full")
        assert_true(photo > LIMIT, string.format("the photo's wrapped row measures %.3f, the limit would not catch it", photo))
        local w = share(worst_line)
        assert_true(w <= LIMIT, string.format("%q takes %.3f of the text area (limit %.2f)", worst_line, w, LIMIT))
        viewer:free()
    end)
    Screen.bb = saved_bb
    era:free()
    assert_true(ok, err)
end)

check("bench_results_close_returns_without_saving", function()
    local before = store:get_profile("good").color_depth
    open_bench_actions()
    start_bench().opts.on_done(BENCH_RESULTS)
    viewer_buttons(top())["Close"].callback()
    expect_top(is_actions, "the actions dialog after Close")
    assert_true(store:get_profile("good").color_depth == before, "Close saves nothing")
    require("vnc/dialogs").Benchmark = nil
end)

check("bench_nothing_scored_has_no_apply", function()
    open_bench_actions()
    start_bench().opts.on_done({ BENCH_RESULTS[3], BENCH_RESULTS[4] })
    local viewer = top()
    assert_true(viewer.title == "Picture benchmark", "results viewer: " .. stack_desc())
    local buttons = viewer_buttons(viewer)
    assert_true(not buttons["Apply best"] and buttons["Close"], "no Apply best when nothing was scored")
    assert_true(viewer.text:find("No combination could be scored", 1, true) and not viewer.text:find("changing", 1, true),
        "says nothing was scored:\n" .. viewer.text)
    assert_true(viewer.text:find("failed: no update within 15 s", 1, true), "rows still listed")
    viewer_buttons(viewer)["Close"].callback()
    require("vnc/dialogs").Benchmark = nil
end)

check("bench_connect_failure_shows_reason", function()
    open_bench_actions()
    local bench, progress = start_bench()
    bench.opts.on_done({ { combination = BENCH_RESULTS[2].combination, ok = false, error = "connection refused" } },
        "connection refused")
    local info = top()
    assert_true(info.text == "Could not connect: connection refused", "connect failure message: " .. stack_desc())
    for _, w in ipairs(stack()) do
        assert_true(w ~= progress, "progress closed")
        assert_true(w.title ~= "Picture benchmark", "no results table on a connect failure")
    end
    UIManager:close(info)
    expect_top(is_actions, "the actions dialog under the message")
    require("vnc/dialogs").Benchmark = nil
end)

-- ---------------------------------------------------------------- persistent canvas buffer

-- A remote plane with a deterministic pattern, a fresh reference render and a canvas compare.
local function canvas_plane(remote, seed)
    local ffi = require("ffi")
    local p = remote:get_plane()
    local d = ffi.cast("uint8_t*", p.data)
    for y = 0, remote.h - 1 do
        for x = 0, remote.w - 1 do
            local o = y * p.stride + x * 3
            d[o] = (x * 37 + y * 101 + seed) % 256
            d[o + 1] = (x * 11 + y * 59 + seed * 3) % 256
            d[o + 2] = (x * y * 7 + seed * 5) % 256
        end
    end
    remote:mark_dirty()
end

--- Number of canvas pixels of `target` (canvas at cx, cy) that differ from a fresh full render.
local function canvas_mismatch(remote, target, cx, cy, cw, ch, mode)
    local Scaler = require("vnc/scaler")
    local bb = require("ffi/blitbuffer")
    local ref = bb.new(cw, ch, target:getType())
    local s = remote.scale
    local vx, vy = remote.view_x, remote.view_y
    Scaler.render(ref, remote.plane, { x = vx, y = vy, scale = s }, { x = 0, y = 0, w = cw, h = ch },
        mode or "smooth")
    local n = 0
    for y = 0, ch - 1 do
        for x = 0, cw - 1 do
            if target:getPixel(cx + x, cy + y):getColorRGB32().r ~= ref:getPixel(x, y):getColorRGB32().r
                    or target:getPixel(cx + x, cy + y):getColorRGB32().g ~= ref:getPixel(x, y):getColorRGB32().g
                    or target:getPixel(cx + x, cy + y):getColorRGB32().b ~= ref:getPixel(x, y):getColorRGB32().b then
                n = n + 1
            end
        end
    end
    ref:free()
    return n
end

local CB_TYPES = { { "BB8", 1 }, { "RGB32", 9 } }

local function canvas_fixture(btype)
    local Remote = require("vnc/framebuffer")
    local bb = require("ffi/blitbuffer")
    local remote = Remote.new(120, 90)
    local cx, cy, cw, ch = 7, 5, 160, 120
    local target = bb.new(cw + 20, ch + 12, btype)
    remote:set_canvas(cw, ch)
    remote:set_scale(2)
    remote:pan_by(-13, -9)
    canvas_plane(remote, 1)
    return remote, target, cx, cy, cw, ch
end

for _, t in ipairs(CB_TYPES) do
    local btype = require("ffi/blitbuffer")["TYPE_" .. (t[1] == "BB8" and "BB8" or "BBRGB32")]

    check("canvas_partial_update_matches_a_full_render_" .. t[1], function()
        local remote, target, cx, cy, cw, ch = canvas_fixture(btype)
        remote:draw_to(target, cx, cy, cw, ch)
        assert_true(remote.last_recomputed_px == cw * ch, "the first paint computes the whole canvas")
        -- the server changes a small rect
        local plane = remote:get_plane()
        plane:paintRect(30, 20, 5, 4, require("ffi/blitbuffer").COLOR_WHITE)
        remote:mark_dirty(30, 20, 5, 4)
        remote:draw_to(target, cx, cy, cw, ch)
        local px = remote.last_recomputed_px
        assert_true(px > 0 and px < cw * ch * 0.05, "a small change recomputes a small area, got " .. px)
        local bad = canvas_mismatch(remote, target, cx, cy, cw, ch)
        assert_true(bad == 0, bad .. " canvas pixels differ from a full render")
        target:free(); remote:free()
    end)

    check("canvas_buffer_is_kept_across_updates_" .. t[1], function()
        local remote, target, cx, cy, cw, ch = canvas_fixture(btype)
        remote:draw_to(target, cx, cy, cw, ch)
        local buf = remote._canvas_bb
        assert_true(buf ~= nil, "a canvas buffer must exist after a paint")
        for i = 1, 3 do
            remote:get_plane():paintRect(i * 10, i * 5, 6, 6, require("ffi/blitbuffer").COLOR_BLACK)
            remote:mark_dirty(i * 10, i * 5, 6, 6)
            remote:draw_to(target, cx, cy, cw, ch)
            assert_true(remote._canvas_bb == buf, "update " .. i .. " must reuse the canvas buffer")
        end
        remote:draw_to(target, cx, cy, cw - 10, ch - 6)
        assert_true(remote._canvas_bb ~= buf, "a resized canvas needs a new buffer")
        assert_true(canvas_mismatch(remote, target, cx, cy, cw - 10, ch - 6) == 0,
            "and the resized canvas shows a full render")
        target:free(); remote:free()
    end)

    check("canvas_pan_recomputes_everything_" .. t[1], function()
        local remote, target, cx, cy, cw, ch = canvas_fixture(btype)
        remote:draw_to(target, cx, cy, cw, ch)
        remote:pan_by(3, -2)
        remote:draw_to(target, cx, cy, cw, ch)
        assert_true(remote.last_recomputed_px == cw * ch, "a pan recomputes the whole canvas")
        local bad = canvas_mismatch(remote, target, cx, cy, cw, ch)
        assert_true(bad == 0, bad .. " canvas pixels differ after a pan")
        target:free(); remote:free()
    end)

    check("canvas_sharp_mode_recomputes_everything_" .. t[1], function()
        local remote, target, cx, cy, cw, ch = canvas_fixture(btype)
        remote:set_scale(1.37)
        remote:draw_to(target, cx, cy, cw, ch)
        remote:set_scaling("sharp")
        remote:draw_to(target, cx, cy, cw, ch)
        assert_true(remote.last_recomputed_px == cw * ch, "a mode change recomputes the whole canvas")
        local bad = canvas_mismatch(remote, target, cx, cy, cw, ch, "sharp")
        assert_true(bad == 0, bad .. " canvas pixels differ from a sharp full render")
        target:free(); remote:free()
    end)

    check("canvas_paint_without_changes_still_blits_" .. t[1], function()
        local remote, target, cx, cy, cw, ch = canvas_fixture(btype)
        remote:draw_to(target, cx, cy, cw, ch)
        -- a popup covered the canvas and is gone again
        target:paintRect(cx, cy, cw, ch, require("ffi/blitbuffer").COLOR_GRAY_7)
        remote:draw_to(target, cx, cy, cw, ch)
        assert_true(remote.last_recomputed_px == 0, "nothing changed, nothing to recompute")
        local bad = canvas_mismatch(remote, target, cx, cy, cw, ch)
        assert_true(bad == 0, bad .. " canvas pixels were not restored")
        target:free(); remote:free()
    end)
end

check("canvas_too_many_stale_rects_recompute_everything", function()
    local bb = require("ffi/blitbuffer")
    local remote, target, cx, cy, cw, ch = canvas_fixture(bb.TYPE_BB8)
    remote:draw_to(target, cx, cy, cw, ch)
    for i = 0, remote.MAX_STALE_RECTS do remote:mark_dirty(i % 100, 3, 1, 1) end
    assert_true(#remote._stale <= remote.MAX_STALE_RECTS, "the stale list must stay bounded")
    remote:draw_to(target, cx, cy, cw, ch)
    assert_true(remote.last_recomputed_px == cw * ch, "an overflowing stale list recomputes everything")
    target:free(); remote:free()
end)

check("a_changed_remote_pixel_refreshes_every_canvas_pixel_it_changed", function()
    local bb = require("ffi/blitbuffer")
    local app, remote = new_app()
    remote:set_scaling("smooth")
    app:paintTo(Screen.bb, 0, 0)
    remote:set_scale(2.5)
    remote:pan_by(-7.3, -4.6)
    app:paintTo(Screen.bb, 0, 0)
    canvas_plane(remote, 3)
    local c = app.canvas
    local before, after = bb.new(c.w, c.h, bb.TYPE_BBRGB32), bb.new(c.w, c.h, bb.TYPE_BBRGB32)
    local real_set_dirty = UIManager.setDirty
    local ok, err = pcall(function()
        local vx, vy = remote.view_x, remote.view_y
        assert_true(remote.scale == 2.5 and vx ~= math.floor(vx), "a fractional view at scale 2.5 is needed")
        -- (the plane is less tall than the canvas here: it is centred, view_y < 0)
        -- the zoom asked for a flash of the next frame: let it go before looking at regions
        app:on_framebuffer_dirty({ x = 0, y = 0, w = 1, h = 1 })
        local x0 = math.floor(vx)
        local px = { { x0 + 5, math.max(0, math.floor(vy)) + 4 }, { x0 + 40, 150 }, { x0 + 20, remote.h - 1 } }
        for _, p in ipairs(px) do
            remote:draw_to(before, 0, 0, c.w, c.h)
            remote:get_plane():setPixel(p[1], p[2], bb.ColorRGB32(255, 255, 255, 255))
            remote:mark_dirty(p[1], p[2], 1, 1)
            remote:draw_to(after, 0, 0, c.w, c.h)
            local regions = {}
            UIManager.setDirty = function(_, _w, _mode, region)
                if region then regions[#regions + 1] = region end
            end
            app:on_framebuffer_dirty({ x = p[1], y = p[2], w = 1, h = 1 })
            UIManager.setDirty = real_set_dirty
            assert_true(#regions > 0, "a regional refresh was expected")
            local changed = 0
            for y = 0, c.h - 1 do
                for x = 0, c.w - 1 do
                    local a, b2 = before:getPixel(x, y), after:getPixel(x, y)
                    if a:getR() ~= b2:getR() or a:getG() ~= b2:getG() or a:getB() ~= b2:getB() then
                        changed = changed + 1
                        local sx, sy, hit = c.x + x, c.y + y, false
                        for _, r in ipairs(regions) do
                            if sx >= r.x and sx < r.x + r.w and sy >= r.y and sy < r.y + r.h then hit = true end
                        end
                        assert_true(hit, string.format("remote %d,%d changed canvas %d,%d outside the refresh",
                            p[1], p[2], x, y))
                    end
                end
            end
            assert_true(changed > 6, "the change must show at scale 2.5, changed " .. changed)
        end
    end)
    UIManager.setDirty = real_set_dirty
    before:free(); after:free()
    app:onCloseWidget()
    remote:free()
    if not ok then error(err, 0) end
end)

check("canvas_dithered_paint_reports_its_blit_time", function()
    local bb = require("ffi/blitbuffer")
    local remote, target, cx, cy, cw, ch = canvas_fixture(bb.TYPE_BB8)
    local Util = require("vnc/util")
    local real_on = Util.timing_enabled
    Util.timing_enabled = function() return false end
    remote:draw_to(target, cx, cy, cw, ch, true)
    assert_true(remote.last_blit_ms == nil, "no blit time is measured while timing is off")
    Util.timing_enabled = function() return true end
    remote:draw_to(target, cx, cy, cw, ch, true)
    Util.timing_enabled = real_on
    assert_true(type(remote.last_blit_ms) == "number", "the blit time must be measured")
    target:free(); remote:free()
end)

check("a_failed_plane_resize_leaves_no_freed_plane", function()
    -- BB.new asserts when it cannot allocate; the old plane must not stay behind freed
    local Remote = require("vnc/framebuffer")
    local bb = require("ffi/blitbuffer")
    local remote = Remote.new(40, 30)
    local real_new = bb.new
    bb.new = function() error("cannot allocate memory for new bb") end
    local ok = pcall(remote.resize, remote, 9000, 9000)
    bb.new = real_new
    assert_true(not ok, "the resize must fail")
    assert_true(remote.plane == nil, "no plane must be left after the failed allocation")
    local target = bb.new(50, 40, bb.TYPE_BB8)
    assert_true(remote:draw_to(target, 0, 0, 50, 40) == false, "without a plane nothing is drawn")
    remote:resize(20, 10)
    assert_true(remote.plane ~= nil and remote.w == 20, "a later resize allocates again")
    target:free(); remote:free()
end)

check("canvas_dithered_partial_paint_matches_a_full_dither", function()
    -- only the recomputed rects are re-dithered; the result must be the whole canvas dithered,
    -- also after undithered paints changed the canvas in between
    local bb = require("ffi/blitbuffer")
    local remote, target, cx, cy, cw, ch = canvas_fixture(bb.TYPE_BB8)
    local ref = bb.new(cw + 20, ch + 12, bb.TYPE_BB8)
    local function same(what)
        ref:fill(bb.COLOR_WHITE)
        ref:ditherblitFrom(remote._canvas_bb, cx, cy, 0, 0, cw, ch)
        for y = cy, cy + ch - 1 do
            for x = cx, cx + cw - 1 do
                assert_true(target:getPixel(x, y):getColor8().a == ref:getPixel(x, y):getColor8().a,
                    string.format("%s: pixel %d,%d differs from a full dither", what, x, y))
            end
        end
    end
    remote:draw_to(target, cx, cy, cw, ch, true)
    same("first paint")
    local plane = remote:get_plane()
    plane:paintRect(30, 20, 5, 4, bb.COLOR_WHITE)
    remote:mark_dirty(30, 20, 5, 4)
    remote:draw_to(target, cx, cy, cw, ch, true)
    assert_true(remote.last_recomputed_px < cw * ch, "the update must be partial")
    same("partial update")
    plane:paintRect(60, 40, 7, 3, bb.COLOR_BLACK)
    remote:mark_dirty(60, 40, 7, 3)
    remote:draw_to(target, cx, cy, cw, ch, false)
    plane:paintRect(10, 10, 3, 3, bb.COLOR_WHITE)
    remote:mark_dirty(10, 10, 3, 3)
    remote:draw_to(target, cx, cy, cw, ch, true)
    same("dithered again after an undithered paint")
    ref:free(); target:free(); remote:free()
end)

check("a_tap_hits_the_remote_pixel_drawn_under_it", function()
    local bb = require("ffi/blitbuffer")
    local remote, target, cx, cy, cw, ch = canvas_fixture(bb.TYPE_BBRGB32)
    -- sharp at several scales, and smooth at 1 with a half-pixel view offset (an odd-sized canvas
    -- centring the plane), which is drawn as a plain copy
    for _, case in ipairs({ { 1.37, "sharp" }, { 2.5, "sharp" }, { 0.75, "sharp" }, { 1, "smooth", 1 } }) do
        local s = case[1]
        if case[3] then cw, ch = cw - case[3], ch - case[3] end
        remote:set_canvas(cw, ch)
        remote:set_scale(s)
        remote:set_scaling(case[2])
        remote:draw_to(target, cx, cy, cw, ch)
        local inside = 0
        for _, c in ipairs({ { 0, 0 }, { 3, 4 }, { 57, 33 }, { 80, 60 }, { cw - 1, ch - 1 } }) do
            local rx, ry = remote:screen_to_remote(c[1], c[2])
            -- (at 0.75 the plane is smaller than the canvas: its black margins map to the edge)
            local ux = remote.view_x + (c[1] + 0.5) / s
            local uy = remote.view_y + (c[2] + 0.5) / s
            if ux >= 0 and ux < remote.w and uy >= 0 and uy < remote.h then
                inside = inside + 1
                local want = remote.plane:getPixel(rx, ry):getColorRGB32()
                local got = target:getPixel(cx + c[1], cy + c[2]):getColorRGB32()
                assert_true(want.r == got.r and want.g == got.g and want.b == got.b,
                    string.format("scale %s %s: canvas %d,%d does not show remote %d,%d",
                        s, case[2], c[1], c[2], rx, ry))
            end
        end
        assert_true(inside >= 2, "scale " .. s .. ": too few probes inside the plane")
    end
    assert_true(remote.view_x ~= math.floor(remote.view_x) and remote.view_y ~= math.floor(remote.view_y),
        "the scale-1 case must have a fractional view")
    target:free(); remote:free()
end)

-- The timing trace (debug log only): paint, blocked polls and input, silent when off.
local function capture_dbg(timing_on, fn)
    local logger = require("logger")
    local Util = require("vnc/util")
    local real_dbg, real_on, lines = logger.dbg, Util.timing_enabled, {}
    logger.dbg = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        lines[#lines + 1] = table.concat(parts, " ")
    end
    Util.timing_enabled = function() return timing_on end
    local ok, err = pcall(fn)
    logger.dbg, Util.timing_enabled = real_dbg, real_on
    if not ok then error(err, 0) end
    local out = {}
    for _, l in ipairs(lines) do
        if l:find("vnc-timing:", 1, true) then out[#out + 1] = l end
    end
    return out
end

local function timing_scenario()
    local Session = require("vnc/session")
    local app, remote = new_app()
    app:paintTo(Screen.bb, 0, 0)
    local real_now, clock = Session._now, 10
    Session._now = function() return clock end
    local s = Session.new{ profile = { host = "h", port = 1, password = "", name = "t" } }
    s.attached, s._pump = true, function() return "again" end
    s:_poll() -- first poll: no previous one, no gap
    clock = clock + Session.POLL_INTERVAL -- on time
    s:_poll()
    clock = clock + 1.5 -- the UI thread was blocked
    s:_poll()
    s:note_input()
    s.attached = false
    Session._now = real_now
    app:onCloseWidget()
    remote:free()
end

check("timing_trace_logs_paint_poll_gap_and_input", function()
    local lines = capture_dbg(true, timing_scenario)
    local joined = table.concat(lines, "\n")
    assert_true(joined:find("vnc%-timing: paint ms=%d+%.%d canvas=%d+x%d+ scale=%S+ mode=smooth recomputed_px=%d+"),
        "paint line: " .. joined)
    local gaps = 0
    for _, l in ipairs(lines) do
        if l:find("vnc-timing: poll gap ms=1500.0", 1, true) then gaps = gaps + 1 end
    end
    assert_true(gaps == 1, "exactly one poll gap line expected: " .. joined)
    assert_true(joined:find("vnc-timing: input key", 1, true), "input line: " .. joined)
end)

check("timing_trace_is_silent_when_debug_logging_is_off", function()
    local lines = capture_dbg(false, timing_scenario)
    assert_true(#lines == 0, "no vnc-timing lines expected, got: " .. table.concat(lines, "\n"))
end)

check("viewer_reports_the_visible_area", function()
    local app, remote, sent = new_app()
    local function last() return sent.areas[#sent.areas] end
    local function same(a, b) return a and b and a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h end
    local function show(a) return a and string.format("%d,%d %dx%d", a.x, a.y, a.w, a.h) or "nil" end
    UIManager:forceRePaint()
    assert_true(same(last(), { x = 0, y = 0, w = 400, h = 300 }),
        "at fit the whole remote screen is the area: " .. show(last()))

    app:zoom_to(4)
    UIManager:forceRePaint()
    assert_true(same(last(), remote:visible_remote_rect()) and last().w < 400,
        "zoomed in, the visible rect plus margin: " .. show(last()))

    -- during a two-finger pan nothing is reported; its release reports the final area
    local n = #sent.areas
    app:onTwoFingerPan(nil, { relative = { x = -200, y = -150 } })
    UIManager:forceRePaint()
    assert_true(#sent.areas == n, "no report while the pan is under way")
    app:onTwoFingerPanRelease(nil, {})
    UIManager:forceRePaint()
    assert_true(#sent.areas > n and same(last(), remote:visible_remote_rect()),
        "the release reports the panned area: " .. show(last()))

    -- a pan whose release never arrives still settles after a quiet moment
    n = #sent.areas
    app:onTwoFingerPan(nil, { relative = { x = 100, y = 100 } })
    UIManager:forceRePaint()
    assert_true(#sent.areas == n, "no report while the second pan is under way")
    local want = remote:visible_remote_rect()
    UIManager:scheduleIn(0, function() end)
    local deadline = os.time() + 3
    while #sent.areas == n and os.time() <= deadline do
        UIManager:_checkTasks()
        require("ffi/util").usleep(20000)
    end
    assert_true(same(last(), want), "the settle task reports it: " .. show(last()))

    app:zoom_to("fit")
    UIManager:forceRePaint()
    assert_true(same(last(), { x = 0, y = 0, w = 400, h = 300 }), "back at fit: " .. show(last()))
    app:onCloseWidget()
    remote:free()
end)

-- ---------------------------------------------------------------- the "Send keys" panel

local CTRL, SHIFT, ALT, SUPER = 0xFFE3, 0xFFE1, 0xFFE9, 0xFFEB

--- The keys sent so far as "+0x..,-0x.." (down/up), then forgets them.
local function take_keys(sent)
    local out = {}
    for _, e in ipairs(sent.key) do
        out[#out + 1] = string.format("%s0x%X", e.down and "+" or "-", e.keysym)
    end
    sent.key = {}
    return table.concat(out, ",")
end

--- Opens the panel the way a user does: the toolbar's keyboard button (when the key strip is not up
--- yet), then the strip's Send keys icon (the toolbar is shown for it and hidden again when it was
--- hidden).
local function open_key_panel(app)
    if app.key_panel then return app.key_panel end
    if not app.key_strip then
        local shown = app.toolbar_visible
        if not shown then app:set_toolbar_visible(true) end
        tap_toolbar(app, "keyboard")
        if not shown then app:set_toolbar_visible(false) end
    end
    UIManager:_checkTasks()
    UIManager:setDirty(app, "ui")
    UIManager:forceRePaint()
    local button = app.key_strip.button_by_id.panel
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = button.dimen.x + math.floor(button.dimen.w / 2),
                                                  y = button.dimen.y + math.floor(button.dimen.h / 2) } }
    UIManager:_checkTasks()
    return app.key_panel
end

--- The centre of a widget's painted rectangle, as a gesture position.
local function centre_of(dimen, nx, n)
    nx, n = nx or 1, n or 1
    return Geom:new{ x = dimen.x + math.floor(dimen.w * (nx - 0.5) / n), y = dimen.y + math.floor(dimen.h / 2) }
end

--- Touches a panel button where a finger would: through the real widget stack, after a paint
--- (a button only learns where it is when it is painted).
local function touch(panel, id)
    UIManager:forceRePaint()
    local button = panel.button_by_id[id]
    assert_true(button ~= nil, "no panel button " .. id)
    dispatch_gesture{ ges = "tap", pos = centre_of(button.dimen) }
end

--- Picks a tab (1-based) on the panel's segmented switch, with a tap on that segment.
local function pick_tab(panel, n)
    UIManager:forceRePaint()
    local switch = panel.tab_switch
    dispatch_gesture{ ges = "tap", pos = centre_of(switch.dimen, n, #switch.toggle) }
    assert_true(panel.tab == n, "tab " .. n .. " must be selected, got " .. tostring(panel.tab))
end

--- Records keys and pointer events in the order they go out: "+0xFFE3" / "-0xFFE3" for keys,
--- "p<mask>" for pointer events.
local function wire_log(app)
    local log = {}
    local session = app.session
    local send_key, send_pointer = session.send_key, session.send_pointer
    session.send_key = function(s_, keysym, down)
        log[#log + 1] = string.format("%s0x%X", down and "+" or "-", keysym)
        return send_key(s_, keysym, down)
    end
    session.send_pointer = function(s_, x, y, mask)
        log[#log + 1] = "p" .. mask
        return send_pointer(s_, x, y, mask)
    end
    return function()
        local out = table.concat(log, ",")
        for i = #log, 1, -1 do log[i] = nil end
        return out
    end
end

local function close_viewer(app, remote)
    app:onCloseWidget()
    remote:free()
end

check("mode_switch_shows_a_tooltip_not_a_card", function()
    local Notification = require("ui/widget/notification")
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    tap_toolbar(app, "mode")
    assert_true(app:get_pointer_mode() == "mouse", "switched")
    local tip = top()
    assert_true(tip.text == "Mouse mode" and tip.toast,
        "a tooltip on top: " .. stack_desc() .. " " .. tostring(tip.text))
    assert_true(getmetatable(tip) == Notification or tip.timeout, "a Notification")
    assert_true(app.help == nil and #sent.pointer == 0, "no card, nothing sent")
    UIManager:close(tip)
    tap_toolbar(app, "mode")
    assert_true(app:get_pointer_mode() == "touch" and top().text == "Touch mode")
    UIManager:close(top())
    close_viewer(app, remote)
end)

check("help_opens_from_the_menu_and_is_local", function()
    local Key = require("device/key")
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    hold_toolbar(app, "mode")
    assert_true(app.help == nil, "a long press on Mode only shows its tooltip")
    UIManager:close(top())
    app:open_help()
    local help = app.help
    assert_true(help ~= nil and top() == help, "the help is on top: " .. stack_desc())
    assert_true(help.title == "VNC viewer help", "title")
    local text = help.text
    assert_true(text:find("Tap, then long press", 1, true) and text:find("Scroll lock", 1, true), "content")
    assert_true(text:find("KEY STRIP", 1, true) and text:find("RECONNECT", 1, true), "strip and reconnect")
    assert_true(not text:find("Keys\u{2026}", 1, true), "no Keys\u{2026} button any more")
    for _, needle in ipairs({ "Zoom: cycle", "1:1", "Brightness:", "Contrast:", "Toolbar buttons\u{2026}",
                              "keyboard icon", "Collapse", "drag" }) do
        assert_true(text:find(needle, 1, true), "the help tells about " .. needle)
    end
    -- the current mode (touch) is described before the other one
    assert_true(text:find("Touch mode", 1, true) < text:find("Mouse mode", 1, true), "current mode first")
    assert_true(not app:_input_target(), "the viewer is under a popup")
    sent.pointer = {}
    tap_toolbar(app, "rotate")
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = 10, y = Screen:getHeight() - 10 } }
    assert_true(#sent.pointer == 0, "nothing reaches the remote")
    help:onClose()
    assert_true(app.help == nil and top() == app, "closed, back on the viewer: " .. stack_desc())
    -- mouse mode lists its own rows first
    app:set_pointer_mode("mouse")
    local menu = app:open_menu()
    local items = menu.item_table
    assert_true(items[#items - 1].text == "Help" and items[#items].text == "Leave (keep connection)", "Help before Leave")
    menu:onMenuSelect(items[#items - 1])
    assert_true(app.help ~= nil and app.menu == nil and top() == app.help, "Help opened from the menu")
    assert_true(app.help.text:find("Mouse mode", 1, true) < app.help.text:find("Touch mode", 1, true), "mouse first")
    UIManager:sendEvent(Event:new("KeyPress", Key:new("Back", {})))
    assert_true(app.help == nil, "Back closes it")
    close_viewer(app, remote)
end)

check("more_menu_order_and_actions", function()
    local app, remote, sent = new_app()
    local log = wire_log(app)
    local menu = app:open_menu()
    assert_true(menu.title == "test \u{00B7} 400\u{00D7}300", "the status is the title: " .. tostring(menu.title))
    for _, t in ipairs{ "Send keys…", "Disconnect", "Show keyboard", "Hide keyboard", "Zoom…", "Send text…",
                        "Ctrl+Alt+Del", "Lock screen", "Show scroll buttons on toolbar", "Enable brightness button",
                        "Enable contrast button" } do
        for _, item in ipairs(menu.item_table) do assert_true(item.text ~= t, t .. " is gone") end
    end
    for _, item in ipairs(menu.item_table) do
        assert_true(item.select_enabled ~= false, "no status row: " .. item.text)
    end
    local order = {}
    for _, item in ipairs(menu.item_table) do order[#order + 1] = item.text end
    assert_true(table.concat(order, "|") == "Connections…|Refresh|"
        .. "Page buttons send|Keep screen on|Match orientation to the remote screen|Toolbar buttons…|Help|Leave (keep connection)",
        table.concat(order, "|"))
    app:close_menu()
    assert_true(app.send_text == nil and app.send_combo == nil, "send_text and send_combo are gone with their rows")

    local function choose(text)
        menu = app:open_menu()
        menu:onMenuSelect(find_item(menu.item_table, text))
        UIManager:_checkTasks()
    end

    local dirty = {}
    local real_dirty = UIManager.setDirty
    UIManager.setDirty = function(self_, w, mode, ...)
        if w == app then dirty[#dirty + 1] = mode end
        return real_dirty(self_, w, mode, ...)
    end
    choose("Refresh")
    UIManager.setDirty = real_dirty
    local full = false
    for _, m in ipairs(dirty) do if m == "full" then full = true end end
    assert_true(sent.full_updates == 1 and full and app.menu == nil, "Refresh asks for a full update and repaint")
    close_viewer(app, remote)
end)

check("menu_title_carries_the_connection_state", function()
    local app, remote = new_app(400, 300, { state = "error" })
    app.session.get_error = function() return "connection reset" end
    local menu = app:open_menu()
    assert_true(menu.title == "test \u{00B7} connection lost", tostring(menu.title))
    local item = menu.item_table[1]
    assert_true(item.text == "Reconnect to test" and item.help_text == "connection reset",
        "the error is the help of the Reconnect row: " .. tostring(item.text) .. " / " .. tostring(item.help_text))
    app:close_menu()
    app.session.state = "connecting"
    menu = app:open_menu()
    assert_true(menu.title == "test \u{00B7} connecting", tostring(menu.title))
    assert_true(menu.item_table[1].text == "Connections…", "no Reconnect row without an error")
    app:close_menu()
    local get_profile = app.session.get_profile
    app.session.get_profile = function() return nil end
    menu = app:open_menu()
    assert_true(menu.title == "VNC viewer", tostring(menu.title))
    app:close_menu()
    app.session.get_profile = get_profile
    close_viewer(app, remote)
end)

check("menu_toolbar_buttons_submenu", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    local has = Device.hasFrontlight
    local ok, err = pcall(function()
        Device.hasFrontlight = function() return true end
        app.toolbar:relayout()
        local menu = app:open_menu()
        local top_row = find_item(menu.item_table, "Toolbar buttons…")
        local subs = {}
        for _, r in ipairs(top_row.sub_item_table) do subs[#subs + 1] = r.text end
        assert_true(table.concat(subs, "|") == "On the toolbar…|Also when collapsed…", table.concat(subs, "|"))
        local parent = find_item(top_row.sub_item_table, "On the toolbar…")
        assert_true(parent.help_text and parent.help_text:find("More", 1, true), "its help says why More stays")
        local rows = parent.sub_item_table
        local texts = {}
        for _, r in ipairs(rows) do texts[#texts + 1] = r.text end
        assert_true(table.concat(texts, "|") == "Collapse button|Display|Zoom|Mode|Keyboard|Rotate|Scroll lock|"
            .. "Scroll up/down|Brightness|Contrast", table.concat(texts, "|"))
        local cases = {
            { "Collapse button", { "toggle" }, true }, { "Display", { "display" }, true },
            { "Zoom", { "zoom" }, true }, { "Mode", { "mode" }, true }, { "Keyboard", { "keyboard" }, true },
            { "Rotate", { "rotate" }, true }, { "Scroll lock", { "scroll_lock" }, true },
            { "Scroll up/down", { "scroll_up", "scroll_down" }, false }, { "Brightness", { "brightness" }, true },
            { "Contrast", { "contrast" }, true },
        }
        for _, case in ipairs(cases) do
            local text, ids, on = case[1], case[2], case[3]
            local item = find_item(rows, text)
            local function shown()
                for _, id in ipairs(ids) do
                    if (app.toolbar.button_by_id[id] ~= nil) ~= (item.mandatory == "\u{2713}") then return false end
                end
                return true
            end
            assert_true(item.mandatory == (on and "\u{2713}" or "-") and shown(), text .. ": default " .. tostring(on))
            menu:onMenuSelect(item)
            UIManager:_checkTasks()
            assert_true(app.menu == menu, text .. ": the menu stays open")
            assert_true(item.mandatory == (on and "-" or "\u{2713}") and shown(), text .. ": switched")
            for _, id in ipairs(ids) do
                assert_true(app.settings.toolbar_buttons[id] == not on, text .. ": stored as " .. id)
            end
            menu:onMenuSelect(item)
            UIManager:_checkTasks()
            assert_true(item.mandatory == (on and "\u{2713}" or "-") and shown(), text .. ": and back")
        end
        local ids = table.concat(app.toolbar:visible_ids(), ",")
        assert_true(ids:find("close,more$"), "Close and More always stay: " .. ids)
        -- hiding the collapse button while collapsed brings the bar back
        app:set_toolbar_collapsed(true)
        assert_true(app.toolbar.collapsed, "collapsed")
        menu:onMenuSelect(find_item(rows, "Collapse button"))
        UIManager:_checkTasks()
        assert_true(not app.toolbar.collapsed and app.toolbar.button_by_id.more ~= nil
            and app.settings.toolbar_collapsed == false, "expanded again")
        menu:onMenuSelect(find_item(rows, "Collapse button"))
        app:close_menu()
        -- no frontlight: the Brightness row is dimmed and says why
        Device.hasFrontlight = function() return false end
        menu = app:open_menu()
        local bright = find_item(find_item(find_item(menu.item_table, "Toolbar buttons…").sub_item_table,
            "On the toolbar…").sub_item_table, "Brightness")
        assert_true(bright.dim and bright.select_enabled == false and bright.help_text, "dimmed with a help text")
        app:close_menu()
    end)
    Device.hasFrontlight = has
    assert_true(ok, tostring(err))
    close_viewer(app, remote)
end)

check("toolbar_settings_migrate_and_clean", function()
    local Settings = require("vnc/settings")
    local path = data_dir .. "/ui_smoke_toolbar_migrate.lua"
    local function load(body)
        local f = io.open(path, "w"); f:write("return { settings = " .. body .. " }\n"); f:close()
        return Settings.open(path).data.settings
    end
    local Toolbar = require("vnc/toolbar")
    local s = load("{}")
    assert_true(next(s.toolbar_buttons) == nil and next(s.toolbar_pinned) == nil, "only choices are stored")
    assert_true(Toolbar.is_enabled(s, "toggle") and not Toolbar.is_enabled(s, "scroll_up")
        and Toolbar.is_enabled(s, "brightness") and Toolbar.is_enabled(s, "contrast"), "defaults: all but the scroll pair")
    assert_true(Toolbar.is_pinned(s, "keyboard") and Toolbar.is_pinned(s, "scroll_lock")
        and not Toolbar.is_pinned(s, "display") and not Toolbar.is_pinned(s, "toggle"), "pinned: Keyboard, Scroll lock")
    assert_true(s.toolbar_collapsed == false and s.toolbar_pos.x == 0.5 and s.toolbar_pos.y == 0, "top centre")
    s = load("{ toolbar_scroll_buttons = true, toolbar_brightness_button = false, toolbar_contrast_button = true }")
    assert_true(s.toolbar_buttons.scroll_up == true and s.toolbar_buttons.scroll_down == true
        and s.toolbar_buttons.brightness == false and s.toolbar_buttons.contrast == true, "the old switches migrate")
    assert_true(s.toolbar_scroll_buttons == nil and s.toolbar_brightness_button == nil
        and s.toolbar_contrast_button == nil, "and the old keys go")
    s = load("{ toolbar_scroll_buttons = true, toolbar_buttons = { contrast = true } }")
    assert_true(not Toolbar.is_enabled(s, "scroll_up") and s.toolbar_buttons.contrast == true, "the new key wins")
    s = load("{ toolbar_buttons = { close = false, more = false, zoom = 'x', bogus = true }, toolbar_pos = { x = 3, y = 0.25 } }")
    assert_true(s.toolbar_buttons.close == nil and s.toolbar_buttons.more == nil and s.toolbar_buttons.bogus == nil
        and s.toolbar_buttons.zoom == nil and Toolbar.is_enabled(s, "zoom"), "junk is cleaned")
    assert_true(s.toolbar_pos.x == 0.5 and s.toolbar_pos.y == 0.25, "a fraction out of range is reset")
    s = load("{ toolbar_pinned = { keyboard = false, rotate = true, toggle = true, close = true } }")
    assert_true(s.toolbar_pinned.keyboard == false and s.toolbar_pinned.rotate == true
        and s.toolbar_pinned.toggle == nil and s.toolbar_pinned.close == nil, "pinned choices kept, junk cleaned")
    os.remove(path)
end)

check("set_pointer_mode_persists_through_the_plugin", function()
    local app, remote, sent = new_app()
    assert_true(app:get_pointer_mode() == "touch")
    app:set_pointer_mode("mouse")
    assert_true(app:get_pointer_mode() == "mouse")
    assert_true(#sent.profile_updates == 1 and sent.profile_updates[1].fields.pointer_mode == "mouse")
    close_viewer(app, remote)
end)

check("key_panel_opens_from_the_toolbar_and_leaves_the_canvas_usable", function()
    local app, remote, sent = new_app()
    local panel = open_key_panel(app)
    local size = Screen:getSize()
    assert_true(app.menu == nil, "the menu closes")
    assert_true(panel ~= nil and top() == panel, "the panel is on top: " .. stack_desc())
    local s = stack()
    assert_true(s[#s - 1] == app, "the viewer stays on the stack right under the panel")
    assert_true(panel.dimen.h < size.h and panel.dimen.h > 0, "the panel is not full screen: " .. panel.dimen.h)
    assert_true(panel.dimen.w == size.w and panel.dimen.y + panel.dimen.h == size.h, "it is bottom-anchored, full width")
    assert_true(panel.covers_fullscreen ~= true, "the viewer under it keeps painting")
    assert_true(not app:_modal_above() and app:_input_target(), "the panel does not count as a popup")
    assert_true(app.vk_visible == false, "the keyboard makes room for the panel")

    -- a remote update still reaches the screen under the panel
    UIManager:forceRePaint()
    app._needs_flash = false
    local dirtied = false
    local real_dirty = UIManager.setDirty
    UIManager.setDirty = function(self_, w, ...)
        if w == app then dirtied = true end
        return real_dirty(self_, w, ...)
    end
    app:on_framebuffer_dirty({ x = 0, y = 0, w = 10, h = 10 })
    UIManager.setDirty = real_dirty
    assert_true(dirtied, "the viewer keeps refreshing the remote while the panel is up")

    -- a tap above the panel clicks the remote; one on the panel (even between buttons) does not
    UIManager:forceRePaint()
    sent.pointer = {}
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = 20, y = 20 } }
    assert_true(#sent.pointer == 3, "a tap above the panel must click the remote, got " .. #sent.pointer)
    sent.pointer = {}
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = 1, y = panel.dimen.y + 1 } }
    dispatch_gesture{ ges = "hold", pos = Geom:new{ x = 1, y = panel.dimen.y + 1 } }
    assert_true(#sent.pointer == 0, "the panel's own area must never click the remote, got " .. #sent.pointer)
    assert_true(take_keys(sent) == "", "opening the panel sends no key")

    -- opening it again does not stack a second one
    assert_true(app:open_key_panel() == panel and count(function(w) return w == panel end) == 1, "one panel")
    close_viewer(app, remote)
end)

check("key_panel_armed_modifier_wraps_the_next_key_only", function()
    local app, remote, sent = new_app()
    local panel = open_key_panel(app)
    touch(panel, "mod:Ctrl")
    assert_true(panel:modifier_state("Ctrl") == "armed", "a tap arms Ctrl")
    assert_true(take_keys(sent) == "", "arming sends nothing")
    assert_true(panel.button_by_id["mod:Ctrl"].preselect == true, "the Ctrl button shows it")
    assert_true(panel.button_by_id["modifiers_only"].enabled == true, "and Modifiers only has something to send")
    pick_tab(panel, 3) -- F1–F12
    touch(panel, "key:F5")
    local got = take_keys(sent)
    assert_true(got == "+0xFFE3,+0xFFC2,-0xFFC2,-0xFFE3", "Ctrl+F5 on the wire, got " .. got)
    assert_true(panel:modifier_state("Ctrl") == nil, "Ctrl is disarmed after one key")
    assert_true(not panel.button_by_id["mod:Ctrl"].preselect, "the Ctrl button shows it")
    touch(panel, "key:F5")
    got = take_keys(sent)
    assert_true(got == "+0xFFC2,-0xFFC2", "the next key goes alone, got " .. got)
    -- tap, tap again: disarmed, nothing sent
    touch(panel, "mod:Shift")
    touch(panel, "mod:Shift")
    assert_true(panel:modifier_state("Shift") == nil and take_keys(sent) == "", "a second tap disarms")
    assert_true(top() == panel, "the panel stays open after sending")
    close_viewer(app, remote)
end)

check("key_panel_armed_modifiers_go_with_the_next_canvas_action", function()
    local app, remote, sent = new_app()
    local panel = open_key_panel(app)
    local wire = wire_log(app)
    local above = Geom:new{ x = 20, y = 20 }

    -- a tap: downs before the press, ups right after the release, then disarmed
    touch(panel, "mod:Ctrl")
    wire()
    UIManager:forceRePaint()
    dispatch_gesture{ ges = "tap", pos = above }
    local got = wire()
    assert_true(got == "+0xFFE3,p0,p1,p0,-0xFFE3", "Ctrl+click, got " .. got)
    assert_true(panel:modifier_state("Ctrl") == nil, "Ctrl is disarmed after the click")
    assert_true(not panel.button_by_id["mod:Ctrl"].preselect, "and the panel shows it")
    dispatch_gesture{ ges = "tap", pos = above }
    got = wire()
    assert_true(got == "p0,p1,p0", "the next tap has no Ctrl, got " .. got)

    -- a drag: the modifiers stay down from the press to the release
    touch(panel, "mod:Shift")
    wire()
    UIManager:forceRePaint()
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = 40, y = 30 }, relative = { x = 20, y = 10 } }
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = 60, y = 40 }, relative = { x = 40, y = 20 } }
    assert_true(panel:modifier_state("Shift") == nil, "Shift is disarmed as soon as the drag takes it")
    dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = 60, y = 40 } }
    got = wire()
    assert_true(got == "+0xFFE1,p1,p1,p1,p0,-0xFFE1", "Shift+drag, got " .. got)
    UIManager:forceRePaint()
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = 40, y = 30 }, relative = { x = 20, y = 10 } }
    dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = 40, y = 30 } }
    got = wire()
    assert_true(got == "p1,p1,p0", "the next drag has no Shift, got " .. got)

    -- a long press (right click) takes them too; several go down in order, up in reverse
    touch(panel, "mod:Alt")
    touch(panel, "mod:Ctrl")
    wire()
    UIManager:forceRePaint()
    dispatch_gesture{ ges = "hold", pos = above }
    confirm_hold(app)
    dispatch_gesture{ ges = "hold_release", pos = above }
    got = wire()
    assert_true(got == "+0xFFE3,+0xFFE9,p4,p0,-0xFFE9,-0xFFE3", "Ctrl+Alt+right click, got " .. got)

    -- nothing armed: a two-finger view pan is not an action and sends no key
    touch(panel, "mod:Super")
    wire()
    UIManager:forceRePaint()
    app:onTwoFingerPan(nil, { relative = { x = 1, y = 1 } })
    app:onTwoFingerPanRelease(nil, {})
    assert_true(wire() == "" and panel:modifier_state("Super") == "armed", "a view pan leaves Super armed")
    close_viewer(app, remote)
end)

check("key_panel_long_press_ending_over_the_panel_releases_its_modifiers", function()
    local InfoMessage = require("ui/widget/infomessage")
    for _, case in ipairs({ "over the panel", "under a message" }) do
        local app, remote = new_app()
        local panel = open_key_panel(app)
        local wire = wire_log(app)
        touch(panel, "mod:Ctrl")
        touch(panel, "mod:Alt")
        wire()
        UIManager:forceRePaint()
        local above = Geom:new{ x = 20, y = 20 }
        local on_panel = Geom:new{ x = 20, y = panel.dimen.y + math.floor(panel.dimen.h / 2) }
        dispatch_gesture{ ges = "hold", pos = above }
        confirm_hold(app)
        local message
        if case == "under a message" then
            message = InfoMessage:new{ text = "busy" }
            UIManager:show(message)
        end
        -- the finger slides onto the panel before it lifts
        dispatch_gesture{ ges = "hold_pan", pos = on_panel, relative = { x = 0, y = on_panel.y - 20 } }
        dispatch_gesture{ ges = "hold_release", pos = on_panel }
        local got = wire()
        assert_true(got == "+0xFFE3,+0xFFE9,p4,p0,-0xFFE9,-0xFFE3",
            case .. ": the right click and its modifiers are let go, got " .. got)
        if message then UIManager:close(message) end
        close_viewer(app, remote)
        assert_true(wire() == "", case .. ": nothing more later")
    end
end)

check("key_panel_two_finger_gesture_ends_a_drag_and_its_modifiers", function()
    -- GestureDetector turns a one-finger pan that gains a second finger into a two-finger gesture,
    -- whose lift is a two_finger_pan_release (Contact:handlePan/handlePanRelease with a buddy):
    -- the one-finger pan_release never comes.
    local start = Screen:getRotationMode()
    local starters = {
        two_finger_pan = function(app) app:onTwoFingerPan(nil, { relative = { x = 5, y = 5 } }) end,
        inward_pan = function(app) app:onInwardPan(nil, { pos = Geom:new{ x = 50, y = 50 }, span = 90, start_span = 100 }) end,
        outward_pan = function(app) app:onOutwardPan(nil, { pos = Geom:new{ x = 50, y = 50 }, span = 110, start_span = 100 }) end,
        pinch = function(app) app:onPinch(nil, { pos = Geom:new{ x = 50, y = 50 } }) end,
        spread = function(app) app:onSpread(nil, { pos = Geom:new{ x = 50, y = 50 } }) end,
        two_finger_tap = function(app) app:onTwoFingerTap(nil, { pos = Geom:new{ x = 50, y = 50 } }) end,
        two_finger_swipe = function(app)
            app:onTwoFingerSwipe(nil, { direction = "south", pos = Geom:new{ x = 50, y = 50 } })
        end,
        two_finger_pan_release = function(app) app:onTwoFingerPanRelease(nil, {}) end,
    }
    for name, start_two_finger in pairs(starters) do
        local app, remote = new_app()
        local panel = open_key_panel(app)
        local wire = wire_log(app)
        touch(panel, "mod:Shift")
        UIManager:forceRePaint()
        wire()
        dispatch_gesture{ ges = "pan", pos = Geom:new{ x = 40, y = 30 }, relative = { x = 20, y = 10 } }
        local got = wire()
        assert_true(got == "+0xFFE1,p1,p1", name .. ": a Shift+drag is under way, got " .. got)
        start_two_finger(app)
        got = wire()
        assert_true(got:sub(1, 10) == "p0,-0xFFE1", name .. " lets go of the button, then Shift, got " .. got)
        assert_true(app._drag_active == nil and app._action_mods == nil, name .. ": no drag left")
        app:onPanRelease(nil, { pos = Geom:new{ x = 40, y = 30 } })
        assert_true(wire() == "", name .. ": a late pan_release sends nothing")
        app:set_rotation_mode(start)
        close_viewer(app, remote)
    end
end)

check("stale_drag_is_ended_before_the_next_action_or_key", function()
    -- a pan_release eaten by the keyboard or the menu leaves the button and modifiers down
    local actions = {
        tap = function(app) app:onTap(nil, { pos = Geom:new{ x = 40, y = 30 } }) end,
        hold = function(app) app:onHold(nil, { pos = Geom:new{ x = 40, y = 30 } }); confirm_hold(app) end,
        key = function(app) app:send_key(0x61, true) end,
    }
    local expected = { tap = "p0,-0xFFE1,p0,p1,p0", hold = "p0,-0xFFE1,p4", key = "p0,-0xFFE1,+0x61" }
    for name, act in pairs(actions) do
        local app, remote = new_app()
        local panel = open_key_panel(app)
        local wire = wire_log(app)
        touch(panel, "mod:Shift")
        UIManager:forceRePaint()
        wire()
        dispatch_gesture{ ges = "pan", pos = Geom:new{ x = 40, y = 30 }, relative = { x = 20, y = 10 } }
        assert_true(wire() == "+0xFFE1,p1,p1", name .. ": a Shift+drag is under way")
        act(app) -- the pan_release never comes
        local got = wire()
        assert_true(got == expected[name], name .. ": expected " .. expected[name] .. ", got " .. got)
        assert_true(app._drag_active == nil and app._action_mods == nil, name .. ": no stale drag")
        close_viewer(app, remote)
    end
end)


check("quick_drag_ending_as_a_swipe_ends_it", function()
    -- A contact that lifts within ges_swipe_interval of moving ends as a swipe, not a pan_release
    -- (GestureDetector's Contact:isSwipe): a quick drag never gets its pan_release.
    local app, remote = new_app()
    local panel = open_key_panel(app)
    local wire = wire_log(app)
    touch(panel, "mod:Shift")
    UIManager:forceRePaint()
    wire()
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = 40, y = 30 }, relative = { x = 20, y = 10 } }
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = 60, y = 40 }, relative = { x = 40, y = 20 } }
    dispatch_gesture{ ges = "swipe", direction = "east", distance = 45, pos = Geom:new{ x = 20, y = 20 } }
    local got = wire()
    assert_true(got == "+0xFFE1,p1,p1,p1,p0,-0xFFE1", "the swipe ends the Shift+drag, got " .. got)
    assert_true(app._drag_active == nil and app._action_mods == nil, "no drag left")
    close_viewer(app, remote)
    assert_true(wire() == "", "nothing more at close")
end)


check("key_panel_quick_drag_does_not_keep_the_next_gesture", function()
    local app, remote = new_app()
    local panel = open_key_panel(app)
    local wire = wire_log(app)
    UIManager:forceRePaint()
    local on_panel = Geom:new{ x = 20, y = panel.dimen.y + math.floor(panel.dimen.h / 2) }
    local panel_end = Geom:new{ x = 40, y = on_panel.y }
    -- a quick drag on the panel, then a drag on the canvas: the canvas drag is the viewer's
    dispatch_gesture{ ges = "pan", pos = panel_end, relative = { x = 20, y = 0 } }
    dispatch_gesture{ ges = "swipe", direction = "east", distance = 20, pos = on_panel }
    assert_true(wire() == "", "the panel's quick drag sends nothing")
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = 40, y = 30 }, relative = { x = 20, y = 10 } }
    dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = 40, y = 30 } }
    local got = wire()
    assert_true(got == "p1,p1,p0", "the next canvas drag reaches the remote, got " .. got)
    -- the reverse: a quick canvas drag, then a drag on the panel stays the panel's
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = 40, y = 30 }, relative = { x = 20, y = 10 } }
    dispatch_gesture{ ges = "swipe", direction = "east", distance = 22, pos = Geom:new{ x = 20, y = 20 } }
    got = wire()
    assert_true(got == "p1,p1,p0", "the quick canvas drag, got " .. got)
    dispatch_gesture{ ges = "pan", pos = panel_end, relative = { x = 20, y = 0 } }
    dispatch_gesture{ ges = "pan_release", pos = panel_end }
    got = wire()
    assert_true(got == "", "the next drag on the panel does not reach the remote, got " .. got)
    close_viewer(app, remote)
end)

check("key_panel_release_all_ends_a_pending_drag_or_long_press", function()
    for _, case in ipairs({ "Shift+drag", "drag", "long press" }) do
        local app, remote = new_app()
        local panel = open_key_panel(app)
        local wire = wire_log(app)
        if case == "Shift+drag" then touch(panel, "mod:Shift") end
        UIManager:forceRePaint()
        wire()
        if case == "long press" then
            dispatch_gesture{ ges = "hold", pos = Geom:new{ x = 20, y = 20 } }
            confirm_hold(app)
        else
            dispatch_gesture{ ges = "pan", pos = Geom:new{ x = 40, y = 30 }, relative = { x = 20, y = 10 } }
        end
        wire()
        -- its release never came (eaten by a popup, say)
        assert_true(panel.button_by_id["release_all"].enabled == true, case .. ": something to release")
        touch(panel, "release_all")
        local got = wire()
        local want = case == "Shift+drag" and "p0,-0xFFE1" or "p0"
        assert_true(got == want, case .. ": expected " .. want .. ", got " .. got)
        assert_true(app._drag_active == nil and app._hold_active == nil and app._action_mods == nil,
            case .. ": nothing left pending")
        assert_true(panel.button_by_id["release_all"].enabled == false, case .. ": nothing left to release")
        -- an action that ends normally leaves nothing to release either
        UIManager:forceRePaint()
        dispatch_gesture{ ges = "pan", pos = Geom:new{ x = 40, y = 30 }, relative = { x = 20, y = 10 } }
        dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = 40, y = 30 } }
        assert_true(panel.button_by_id["release_all"].enabled == false, case .. ": a finished drag leaves nothing")
        close_viewer(app, remote)
    end
end)


check("key_panel_combo_order_and_modifiers_only", function()
    local app, remote, sent = new_app()
    local panel = open_key_panel(app)
    -- armed in a scrambled order: the wire order is still Ctrl, Shift, Alt, Super
    for _, m in ipairs({ "Super", "Alt", "Ctrl", "Shift" }) do touch(panel, "mod:" .. m) end
    for _, m in ipairs({ "Ctrl", "Shift", "Alt", "Super" }) do
        assert_true(panel.button_by_id["mod:" .. m].preselect == true, m .. " shows armed")
    end
    pick_tab(panel, 3) -- F1–F12
    touch(panel, "key:F4")
    local got = take_keys(sent)
    assert_true(got == "+0xFFE3,+0xFFE1,+0xFFE9,+0xFFEB,+0xFFC1,-0xFFC1,-0xFFEB,-0xFFE9,-0xFFE1,-0xFFE3",
        "modifier downs in order, key, ups in reverse: " .. got)

    -- Modifiers only (Keys tab): nothing armed sends nothing; Super alone is pressed and released
    pick_tab(panel, 1)
    assert_true(panel.button_by_id["modifiers_only"].enabled == false, "with nothing armed it is disabled")
    touch(panel, "modifiers_only")
    assert_true(take_keys(sent) == "", "nothing armed, nothing sent")
    touch(panel, "mod:Super")
    assert_true(panel.button_by_id["modifiers_only"].enabled == true, "Super armed: enabled")
    touch(panel, "modifiers_only")
    got = take_keys(sent)
    assert_true(got == "+0xFFEB,-0xFFEB", "Super alone, got " .. got)
    assert_true(panel:modifier_state("Super") == nil, "and it is disarmed")
    close_viewer(app, remote)
end)

check("key_panel_recent_combos_record_and_replay", function()
    local app, remote, sent = new_app()
    local flushed = 0
    app.plugin.settings.flush = function() flushed = flushed + 1 end
    local panel = open_key_panel(app)
    pick_tab(panel, 3)
    touch(panel, "mod:Ctrl")
    touch(panel, "key:F5")
    assert_true(flushed > 0, "the recent list is saved")
    local recent = app.settings.recent_combos
    assert_true(#recent == 1 and recent[1].keysym == 0xFFC2 and recent[1].mods[1] == "Ctrl"
        and #recent[1].mods == 1 and recent[1].label == "F5", "Ctrl+F5 is recorded")
    assert_true(panel.button_by_id["recent:1"].text == "Ctrl+F5", "and shown")
    take_keys(sent)

    -- a replay is the action: it sends exactly that combo (the armed Shift is not added) and
    -- clears what was armed
    touch(panel, "mod:Shift")
    touch(panel, "recent:1")
    local got = take_keys(sent)
    assert_true(got == "+0xFFE3,+0xFFC2,-0xFFC2,-0xFFE3", "replay of Ctrl+F5 without the armed Shift, got " .. got)
    assert_true(panel:modifier_state("Shift") == nil, "the replay used up the armed Shift")
    assert_true(panel.button_by_id["recent:1"].text == "Ctrl+F5", "and the list still says Ctrl+F5")

    -- distinct combos, most recent first, at most four; a repeat moves to the front
    pick_tab(panel, 1)
    touch(panel, "key:Esc")
    touch(panel, "key:Tab")
    touch(panel, "mod:Alt")
    touch(panel, "key:Tab")
    touch(panel, "mod:Super")
    touch(panel, "modifiers_only")
    recent = app.settings.recent_combos
    assert_true(#recent == 4, "at most four, got " .. #recent)
    local labels = {}
    for i = 1, 4 do labels[i] = panel.button_by_id["recent:" .. i].text end
    local shown = table.concat(labels, "|")
    assert_true(shown == "Super|Alt+Tab|Tab|Esc", "most recent first: " .. shown)
    touch(panel, "key:Tab")
    for i = 1, 4 do labels[i] = panel.button_by_id["recent:" .. i].text end
    shown = table.concat(labels, "|")
    assert_true(shown == "Tab|Super|Alt+Tab|Esc", "a repeat moves to the front: " .. shown)
    take_keys(sent)

    -- a new panel (and a new viewer) starts with the saved list
    app:close_key_panel()
    panel = open_key_panel(app)
    assert_true(panel.button_by_id["recent:1"].text == "Tab", "the list survives the panel")
    close_viewer(app, remote)
end)

check("key_panel_release_all", function()
    local app, remote, sent = new_app()
    local panel = open_key_panel(app)
    assert_true(panel.button_by_id["release_all"].enabled == false, "nothing to release yet")
    touch(panel, "mod:Ctrl")
    touch(panel, "mod:Shift")
    touch(panel, "mod:Super")
    assert_true(panel.button_by_id["release_all"].enabled == true, "something to release")
    touch(panel, "release_all")
    assert_true(take_keys(sent) == "", "armed modifiers were never pressed: nothing goes out")
    for _, m in ipairs({ "Ctrl", "Shift", "Alt", "Super" }) do
        assert_true(panel:modifier_state(m) == nil, m .. " is cleared")
    end
    assert_true(panel.button_by_id["modifiers_only"].enabled == false, "Modifiers only has nothing to send")
    assert_true(panel.button_by_id["release_all"].enabled == false, "and there is nothing left to release")
    close_viewer(app, remote)
end)

check("key_panel_close_paths_release_everything", function()
    local Key = require("device/key")
    local paths = {
        ["close button"] = function(app, panel)
            UIManager:forceRePaint()
            touch(panel, "close")
        end,
        ["Back key"] = function(app, panel)
            UIManager:sendEvent(Event:new("KeyPress", Key:new("Back", {})))
            UIManager:sendEvent(Event:new("KeyRelease", Key:new("Back", {})))
        end,
        ["Menu key"] = function(app, panel)
            UIManager:sendEvent(Event:new("KeyPress", Key:new("Menu", {})))
            UIManager:sendEvent(Event:new("KeyRelease", Key:new("Menu", {})))
        end,
        ["leaving the viewer"] = function(app, panel) UIManager:close(app) end,
    }
    for name, close in pairs(paths) do
        -- armed only: nothing was ever pressed, so nothing at all goes out
        local app, remote, sent = new_app()
        local panel = open_key_panel(app)
        touch(panel, "mod:Ctrl")
        take_keys(sent)
        close(app, panel)
        UIManager:_checkTasks()
        local got = take_keys(sent)
        assert_true(got == "", name .. " with Ctrl armed must send nothing, got " .. got)
        assert_true(app.key_panel == nil and count(function(w) return w == panel end) == 0, name .. " closes it")
        if name ~= "leaving the viewer" then
            assert_true(top() == app and app:_input_target(), name .. ": the viewer is on top again")
            assert_true(app.menu == nil, name .. " does not open the menu")
            -- a new panel starts clean
            panel = open_key_panel(app)
            assert_true(panel:modifier_state("Ctrl") == nil, name .. ": no pending state survives")
            app:close_key_panel()
        end
        close_viewer(app, remote)

        -- in the middle of a Ctrl+drag: the pending Ctrl up goes out, exactly once
        app, remote, sent = new_app()
        panel = open_key_panel(app)
        touch(panel, "mod:Ctrl")
        UIManager:forceRePaint()
        dispatch_gesture{ ges = "pan", pos = Geom:new{ x = 40, y = 30 }, relative = { x = 20, y = 10 } }
        got = take_keys(sent)
        assert_true(got == "+0xFFE3", name .. ": the drag pressed Ctrl, got " .. got)
        local wire = wire_log(app)
        close(app, panel)
        UIManager:_checkTasks()
        got = wire()
        assert_true(got == "p0,-0xFFE3", name .. " during a Ctrl+drag must let go of the button, then Ctrl, got " .. got)
        close_viewer(app, remote)
        got = wire()
        assert_true(got == "", name .. ": nothing more after that, got " .. got)
    end
end)

check("leaving_the_viewer_mid_drag_lets_go_of_the_button", function()
    for _, case in ipairs({ "drag", "long press" }) do
        local app, remote = new_app()
        local wire = wire_log(app)
        if case == "drag" then
            dispatch_gesture{ ges = "pan", pos = Geom:new{ x = 40, y = 30 }, relative = { x = 20, y = 10 } }
        else
            dispatch_gesture{ ges = "hold", pos = Geom:new{ x = 20, y = 20 } }
            confirm_hold(app)
        end
        wire()
        UIManager:close(app)
        local got = wire()
        assert_true(got == "p0", case .. ": leaving the viewer must let go of the button, got " .. got)
        assert_true(app._drag_active == nil and app._hold_active == nil, case .. ": nothing left pending")
        close_viewer(app, remote)
        assert_true(wire() == "", case .. ": nothing more after that")
    end
end)

check("key_panel_disconnect_mid_drag_releases_modifiers_before_teardown", function()
    local app, remote, sent = new_app()
    local panel = open_key_panel(app)
    touch(panel, "mod:Shift")
    UIManager:forceRePaint()
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = 40, y = 30 }, relative = { x = 20, y = 10 } }
    assert_true(take_keys(sent) == "+0xFFE1", "a Shift+drag is under way")
    local order = {}
    local session = app.session
    local real_send = session.send_key
    session.send_key = function(s, keysym, down)
        order[#order + 1] = string.format("%s0x%X", down and "+" or "-", keysym)
        return real_send(s, keysym, down)
    end
    session.disconnect = function() order[#order + 1] = "teardown" end
    -- the plugin's real disconnect path (main.lua), around this viewer and its session
    local plugin = setmetatable({ sessions = { test = session }, app = app }, { __index = plugin_module })
    plugin_module.disconnect_session(plugin, "test")
    local got = table.concat(order, ",")
    assert_true(got == "-0xFFE1,teardown", "Shift is released before the socket goes, got " .. got)
    remote:free()
end)

check("key_panel_every_tab_sends_its_keysyms", function()
    local tabs = {
        -- (plus Modifiers only, which is no key: key_panel_combo_order_and_modifiers_only)
        { "Keys", {
            { "Home", 0xFF50 }, { "Page Up", 0xFF55 }, { "Insert", 0xFF63 }, { "Backspace", 0xFF08 },
            { "End", 0xFF57 }, { "Page Down", 0xFF56 }, { "Menu", 0xFF67 }, { "Enter", 0xFF0D },
            { "Print Screen", 0xFF61 }, { "Pause", 0xFF13 } } },
        { "Hotkeys", {} }, -- (no plain keys: key_panel_hotkeys_send_exactly_their_combo)
        { "F1–F12", {} },
    }
    for i = 1, 12 do table.insert(tabs[3][2], { "F" .. i, 0xFFBE + i - 1 }) end
    -- the top row's keys are on every tab
    local top_keys = { { "Esc", 0xFF1B }, { "Tab", 0xFF09 }, { "←", 0xFF51 }, { "↑", 0xFF52 },
                       { "↓", 0xFF54 }, { "→", 0xFF53 }, { "Del", 0xFFFF } }
    for _, tab in ipairs(tabs) do
        for _, key in ipairs(top_keys) do table.insert(tab[2], key) end
    end

    local app, remote, sent = new_app()
    local panel = open_key_panel(app)
    local height = panel.dimen.h
    for n, tab in ipairs(tabs) do
        pick_tab(panel, n)
        assert_true(panel.tab_switch.toggle[n] == tab[1], "tab " .. n .. " is " .. tab[1])
        assert_true(panel.dimen.h == height, tab[1] .. ": the panel keeps its height")
        local count_keys = 0
        for id in pairs(panel.button_by_id) do
            if id:sub(1, 4) == "key:" then count_keys = count_keys + 1 end
        end
        assert_true(count_keys == #tab[2], string.format("%s has %d keys, expected %d", tab[1], count_keys, #tab[2]))
        assert_true(panel.button_by_id["key:Caps Lock"] == nil, tab[1] .. ": no Caps Lock")
        assert_true((panel.button_by_id["modifiers_only"] ~= nil) == (n == 1), tab[1] .. ": Modifiers only on Keys alone")
        for _, key in ipairs(tab[2]) do
            touch(panel, "key:" .. key[1])
            local want = string.format("+0x%X,-0x%X", key[2], key[2])
            local got = take_keys(sent)
            assert_true(got == want, string.format("%s / %s must send %s, got %s", tab[1], key[1], want, got))
        end
    end
    close_viewer(app, remote)
end)

check("key_panel_follows_a_rotation", function()
    local app, remote = new_app()
    local panel = open_key_panel(app)
    local start = Screen:getRotationMode()
    app:set_rotation_mode((start + 1) % 4)
    local size = Screen:getSize()
    assert_true(app.key_panel == panel, "the panel stays open")
    assert_true(panel.dimen.w == size.w and panel.dimen.y + panel.dimen.h == size.h,
        "and is re-laid out for the new orientation")
    app:set_rotation_mode(start)
    close_viewer(app, remote)
end)

-- ---------------------------------------------------------------- key strip

--- The strip's bottom edge: right on top of the on-screen keyboard.
local function strip_bottom(strip) return strip.dimen.y + strip.dimen.h end

check("toasts_sit_below_the_toolbar", function()
    local Blitbuffer = require("ffi/blitbuffer")
    local app, remote = new_app(400, 300, { toolbar = true })
    local bb = Blitbuffer.new(Screen:getWidth(), Screen:getHeight())
    local function drawn(tip)
        tip:paintTo(bb, 0, 0)
        return tip.frame.dimen
    end
    local tb = app.toolbar.dimen
    assert_true(app.toolbar_visible, "toolbar shown")
    tap_toolbar(app, "mode")
    local tip = top()
    assert_true(tip.toast and tip.text, "a toast: " .. stack_desc())
    local d = drawn(tip)
    assert_true(d.y >= tb.y + tb.h, "below the toolbar: " .. d.y .. " vs " .. (tb.y + tb.h))
    assert_true(not d:intersectWith(tb), "and clear of it")
    -- a second one stacks below the first
    app:show_toast("second")
    local d2 = drawn(top())
    assert_true(d2.y >= d.y + d.h, "stacked under the first")
    UIManager:close(top()); UIManager:close(tip)
    -- hidden toolbar: at the top as before
    app:set_toolbar_visible(false)
    app:toggle_pointer_mode()
    local tip3 = top()
    local d3 = drawn(tip3)
    assert_true(d3.y < tb.y + tb.h, "toolbar hidden: toast at the top, y=" .. d3.y)
    UIManager:close(tip3)
    close_viewer(app, remote)
end)

check("keyboard_toggle_keeps_a_pinched_zoom_and_pan", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    local fit_scale = remote:get_scale()
    -- spread to a bigger scale, then pan with two fingers
    app:_live_zoom({ pos = { x = 100, y = 100 }, span = 300, start_span = 100 })
    app:onSpread()
    app:onTwoFingerPan(nil, { relative = { x = -30, y = -20 }, start_pos = Geom:new{ x = 100, y = 100 } })
    local scale, vx, vy = remote:get_scale(), remote.view_x, remote.view_y
    assert_true(scale > fit_scale * 1.5, "the spread zoomed in")
    tap_toolbar(app, "keyboard")
    assert_true(app.vk_visible, "keyboard up")
    assert_true(remote:get_scale() == scale and remote.view_x == vx and remote.view_y == vy,
        "keyboard show keeps scale and pan")
    app:on_keyboard_height_changed()
    assert_true(remote:get_scale() == scale and remote.view_x == vx and remote.view_y == vy,
        "a keyboard height change keeps them")
    tap_toolbar(app, "keyboard")
    assert_true(not app.vk_visible, "keyboard down")
    assert_true(remote:get_scale() == scale and remote.view_x == vx and remote.view_y == vy,
        "keyboard hide keeps them")
    assert_true(app.settings.zoom_mode == "fit", "the pinched scale is not stored")
    -- a pan alone (no pinch) is kept as well
    app:fit_to_screen()
    assert_true(math.abs(remote:get_scale() - fit_scale) < 1e-9, "fit_to_screen fits again")
    tap_toolbar(app, "keyboard")
    local fitted_kb = remote:get_scale()
    tap_toolbar(app, "keyboard")
    assert_true(math.abs(remote:get_scale() - fit_scale) < 1e-9, "fitted behaviour: toggling re-fits")
    -- the Display panel's zoom choice fits again too
    app:_live_zoom({ pos = { x = 100, y = 100 }, span = 300, start_span = 100 })
    app:onSpread()
    app:zoom_to("fit")
    assert_true(math.abs(remote:get_scale() - fit_scale) < 1e-9, "zoom_to fits again")
    -- a rotation/resize re-fits
    app:_live_zoom({ pos = { x = 100, y = 100 }, span = 300, start_span = 100 })
    app:onSpread()
    app:_reflow()
    assert_true(math.abs(remote:get_scale() - fit_scale) < 1e-9, "a reflow fits again")
    close_viewer(app, remote)
end)

check("key_strip_comes_and_goes_with_the_keyboard", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    -- the strip's own show/close refreshes: partial "ui" ones only
    local modes = {}
    local real_show, real_close = UIManager.show, UIManager.close
    UIManager.show = function(self_, w, mode, ...)
        if w and w.variant == "strip" then modes[#modes + 1] = { "show", mode, (...) } end
        return real_show(self_, w, mode, ...)
    end
    UIManager.close = function(self_, w, mode, ...)
        if w and w.variant == "strip" then modes[#modes + 1] = { "close", mode, (...) } end
        return real_close(self_, w, mode, ...)
    end
    local ok, err = pcall(function()
        tap_toolbar(app, "keyboard")
        local strip = app.key_strip
        assert_true(app.vk_visible and strip ~= nil, "the keyboard comes with the strip")
        assert_true(count(function(w) return w == strip end) == 1, "the strip is on the stack once")
        assert_true(strip.dimen.w == Screen:getWidth(), "full width")
        assert_true(strip.dimen.h == require("vnc/keypanel").row_height(), "one row tall: " .. strip.dimen.h)
        assert_true(strip_bottom(strip) == Screen:getHeight() - app.vk:getSize().h,
            "right above the keyboard: " .. strip_bottom(strip))
        assert_true(strip.title_bar == nil and strip.button_by_id["modifiers_only"] == nil, "no title bar, no tabs")
        for _, id in ipairs({ "mod:Ctrl", "mod:Alt", "mod:Shift", "mod:Super", "key:Esc", "key:Tab",
                              "key:←", "key:↑", "key:↓", "key:→", "key:Del" }) do
            assert_true(strip.button_by_id[id] ~= nil, "strip button " .. id)
        end
        assert_true(not app:_modal_above() and app:_input_target(), "the strip does not count as a popup")
        tap_toolbar(app, "keyboard")
        assert_true(not app.vk_visible and app.key_strip == nil, "both go away")
        assert_true(count(function(w) return w == strip end) == 0, "the strip left the stack")
    end)
    UIManager.show, UIManager.close = real_show, real_close
    assert_true(ok, tostring(err))
    assert_true(#modes == 2, "one show and one close of the strip, got " .. #modes)
    for _, m in ipairs(modes) do
        assert_true(m[2] == "ui" and m[3] ~= nil, m[1] .. ": a partial ui refresh, got " .. tostring(m[2]))
    end
    close_viewer(app, remote)
end)

check("key_strip_modifiers_apply_to_osk_strip_and_canvas", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    tap_toolbar(app, "keyboard")
    app:set_toolbar_visible(false)
    local strip = app.key_strip
    local wire = wire_log(app)
    -- nothing sent from the strip (or through it) is remembered or written to disk
    local flushes = 0
    app.plugin.settings.flush = function() flushes = flushes + 1 end
    app.settings.recent_combos = { { mods = { "Ctrl" }, keysym = 0x74, label = "T" } }
    local recent = app.settings.recent_combos
    -- an on-screen keyboard key
    app.vk.inputbox:addChars("c")
    assert_true(wire() == "+0x63,-0x63", "a plain OSK key")
    touch(strip, "mod:Ctrl")
    assert_true(strip:modifier_state("Ctrl") == "armed" and wire() == "", "a tap arms Ctrl, sending nothing")
    app.vk.inputbox:addChars("c")
    local got = wire()
    assert_true(got == "+0xFFE3,+0x63,-0x63,-0xFFE3", "Ctrl+c from the keyboard, got " .. got)
    assert_true(strip:modifier_state("Ctrl") == nil, "disarmed after one key")
    -- a strip key
    touch(strip, "mod:Shift")
    touch(strip, "key:Tab")
    got = wire()
    assert_true(got == "+0xFFE1,+0xFF09,-0xFF09,-0xFFE1", "Shift+Tab from the strip, got " .. got)
    touch(strip, "key:Esc")
    got = wire()
    assert_true(got == "+0xFF1B,-0xFF1B", "the next strip key goes alone, got " .. got)
    -- a canvas tap
    touch(strip, "mod:Alt")
    wire()
    UIManager:forceRePaint()
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = 20, y = 20 } }
    got = wire()
    assert_true(got == "+0xFFE9,p0,p1,p0,-0xFFE9", "Alt+click, got " .. got)
    assert_true(strip:modifier_state("Alt") == nil, "Alt is disarmed after the click")
    assert_true(app.settings.recent_combos == recent and #recent == 1 and recent[1].label == "T",
        "the recent combos are left alone")
    assert_true(flushes == 0, "and no settings were written, got " .. flushes .. " flush(es)")
    -- the strip itself never clicks the remote
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = 1, y = strip.dimen.y + 1 } }
    got = wire()
    assert_true(not got:find("p"), "the strip's area never clicks the remote, got " .. got)
    close_viewer(app, remote)
end)

check("key_strip_and_panel_are_exclusive", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    tap_toolbar(app, "keyboard")
    assert_true(app.key_strip ~= nil, "strip up")
    open_key_panel(app)
    assert_true(app.key_panel ~= nil and app.key_strip == nil and not app.vk_visible,
        "the panel replaces the keyboard and the strip")
    tap_toolbar(app, "keyboard")
    UIManager:_checkTasks()
    assert_true(app.key_panel == nil and app.key_strip == nil and not app.vk_visible,
        "the keyboard tap closes the panel, and nothing comes back in its place")
    close_viewer(app, remote)
end)

--- Whether the real VirtualKeyboard or the key strip is on the window stack.
local function keyboard_on_stack(app)
    return count(function(w) return w == app.vk or (w.variant == "strip") end) > 0
end

check("keyboard_button_shows_then_hides_and_closes_the_panel", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    -- tap, tap: shown, then hidden (the real keyboard and the strip both leave the stack)
    tap_toolbar(app, "keyboard")
    UIManager:_checkTasks()
    assert_true(app.vk_visible and app.key_strip ~= nil and keyboard_on_stack(app), "first tap shows both")
    tap_toolbar(app, "keyboard")
    UIManager:_checkTasks()
    assert_true(not app.vk_visible and app.key_strip == nil and not keyboard_on_stack(app),
        "second tap hides both")
    -- keyboard up, the strip's keys icon: the panel; then a tap closes it and shows nothing
    tap_toolbar(app, "keyboard")
    open_key_panel(app)
    assert_true(app.key_panel ~= nil and not keyboard_on_stack(app), "the panel alone")
    tap_toolbar(app, "keyboard")
    UIManager:_checkTasks()
    assert_true(app.key_panel == nil and not app.vk_visible and app.key_strip == nil
        and not keyboard_on_stack(app), "with the panel open a tap closes it and shows nothing")
    -- the next tap shows the keyboard again
    tap_toolbar(app, "keyboard")
    UIManager:_checkTasks()
    assert_true(app.vk_visible and app.key_strip ~= nil, "then a tap shows the keyboard again")
    -- the panel's close also saves "no keyboard"
    open_key_panel(app)
    assert_true(app.key_panel ~= nil and app.settings.keyboard_shown == true, "panel open, keyboard still wished")
    tap_toolbar(app, "keyboard")
    UIManager:_checkTasks()
    assert_true(app.key_panel == nil and not app.vk_visible and not keyboard_on_stack(app),
        "the tap leaves nothing shown")
    assert_true(app.settings.keyboard_shown == false, "and saves that")
    close_viewer(app, remote)
end)

check("key_strip_keys_button_opens_the_panel_keeping_armed_modifiers", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    tap_toolbar(app, "keyboard")
    app:set_toolbar_visible(false)
    local strip = app.key_strip
    local keys = strip.button_by_id["panel"]
    assert_true(keys ~= nil, "the strip has a Send keys button")
    assert_true(keys.text == nil, "an icon, not a label, got " .. tostring(keys.text))
    assert_true(keys.label_widget.file == require("vnc/icons").path("keys"),
        "the plugin's keys icon, got " .. tostring(keys.label_widget.file))
    local wire = wire_log(app)
    touch(strip, "mod:Ctrl")
    UIManager:forceRePaint()
    local x_close = strip.button_by_id["close"]
    local ctrl = strip.button_by_id["mod:Ctrl"]
    assert_true(x_close.dimen.x <= 2 and x_close.dimen.x < keys.dimen.x and keys.dimen.x < ctrl.dimen.x,
        "X first, then the keys icon, then the modifiers")
    touch(strip, "panel")
    UIManager:_checkTasks()
    local panel = app.key_panel
    assert_true(panel ~= nil and panel.variant == nil, "the full Send keys panel opens")
    assert_true(app.key_strip == nil and not app.vk_visible and not keyboard_on_stack(app),
        "keyboard and strip go away")
    assert_true(wire() == "", "nothing is sent")
    assert_true(panel:modifier_state("Ctrl") == "armed", "Ctrl stays armed on the panel")
    close_viewer(app, remote)
end)

check("key_strip_close_button_hides_the_keyboard", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    tap_toolbar(app, "keyboard")
    app:set_toolbar_visible(false)
    local strip = app.key_strip
    local x_close = strip.button_by_id["close"]
    assert_true(x_close ~= nil and x_close.text == nil, "an X icon button")
    assert_true(x_close.icon == "close", "KOReader's close icon, got " .. tostring(x_close.icon))
    local last = strip.button_by_id["key:Del"]
    UIManager:forceRePaint()
    assert_true(last.dimen.x + last.dimen.w >= strip.dimen.w - 2, "Del is the strip's last button")
    local wire = wire_log(app)
    touch(strip, "close")
    UIManager:_checkTasks()
    assert_true(not app.vk_visible and app.key_strip == nil and not keyboard_on_stack(app),
        "keyboard and strip go away")
    assert_true(app.vk_wanted == false and app.key_panel == nil, "like toggling it off, no panel")
    assert_true(wire() == "", "nothing is sent")
    close_viewer(app, remote)
end)

check("keyboard_shown_is_remembered_across_viewers", function()
    local ViewerApp = require("vnc/app")
    local app, remote = new_app(400, 300, { toolbar = true })
    local flushes = 0
    app.plugin.settings.flush = function() flushes = flushes + 1 end
    --- Closes the viewer the way leaving it does and opens a new one on the same settings.
    local function reopen()
        UIManager:close(app)
        UIManager:_checkTasks()
        app = ViewerApp:new{ plugin = app.plugin, session = app.session }
        UIManager:show(app, "full")
        UIManager:_checkTasks()
    end
    assert_true(not app.vk_visible and app.settings.keyboard_shown == false, "starts without the keyboard")
    tap_toolbar(app, "keyboard")
    assert_true(app.vk_visible and app.settings.keyboard_shown == true and flushes == 1, "on, and saved")
    reopen()
    assert_true(app.vk_visible and app.key_strip ~= nil, "the next viewer opens with the keyboard")
    assert_true(app.settings.keyboard_shown == true, "leaving the viewer does not change the saved wish")
    tap_toolbar(app, "keyboard")
    assert_true(not app.vk_visible and app.settings.keyboard_shown == false, "off, and saved")
    reopen()
    assert_true(not app.vk_visible and app.key_strip == nil, "the next viewer opens without it")

    -- the strip's X, the panel's keyboard icon and its X save the wish too
    app:set_keyboard_visible(true)
    touch(app.key_strip, "close")
    assert_true(not app.vk_visible and app.settings.keyboard_shown == false, "strip X: off, saved")
    app:set_keyboard_visible(true)
    touch(app.key_strip, "panel")
    UIManager:_checkTasks()
    assert_true(app.key_panel ~= nil and app.settings.keyboard_shown == true, "the panel keeps the wish")
    app.settings.keyboard_shown = false -- (as if it had been changed elsewhere)
    touch(app.key_panel, "keyboard")
    UIManager:_checkTasks()
    assert_true(app.vk_visible and app.settings.keyboard_shown == true, "panel keyboard icon: on, saved")
    touch(app.key_strip, "panel")
    UIManager:_checkTasks()
    touch(app.key_panel, "close")
    UIManager:_checkTasks()
    assert_true(app.key_panel == nil and not app.vk_visible and app.settings.keyboard_shown == false,
        "panel X: nothing shown, saved")
    close_viewer(app, remote)
end)

--- The key labelled `key` in a VirtualKeyboard or a key popup (its `layout` rows of VirtualKeys).
local function find_vk_key(widget, key)
    for _, row in ipairs(widget.layout or {}) do
        for _, k in ipairs(row) do
            if k.key == key then return k end
        end
    end
end

--- The long-press popup of one of the viewer keyboard's keys, if one is on the window stack.
local function key_popup(app)
    for _, w in ipairs(stack()) do
        if w.parent_key and w.parent_key.keyboard == app.vk then return w end
    end
end

check("keyboard_accent_popup_closes_after_any_pick", function()
    -- KOReader's popup gives its centre key (the plain letter) the parent key's callback, which
    -- only closes `close_after_callback_widget`, nil on a main keyboard key: the letter was typed
    -- and the popup stayed on top.
    local app, remote = new_app()
    app:toggle_keyboard()
    UIManager:forceRePaint()
    local key = find_vk_key(app.vk, "e")
    assert_true(key ~= nil, "the keyboard has an e key")
    local pos = centre_of(key.dimen)
    local wire = wire_log(app)
    for _, pick in ipairs({ { "e", "+0x65,-0x65" }, { "é", "+0xE9,-0xE9" } }) do
        dispatch_gesture{ ges = "hold", pos = pos }
        local popup = key_popup(app)
        assert_true(popup ~= nil, pick[1] .. ": a long press opens the popup")
        local closes = 0
        local real_close = popup.onCloseWidget
        popup.onCloseWidget = function(...) closes = closes + 1; return real_close(...) end
        UIManager:forceRePaint()
        dispatch_gesture{ ges = "hold_release", pos = pos }
        assert_true(wire() == "", pick[1] .. ": lifting the finger types nothing")
        assert_true(key_popup(app) == popup, pick[1] .. ": and leaves the popup up")
        UIManager:forceRePaint()
        local target = find_vk_key(popup, pick[1])
        assert_true(target ~= nil, "the popup has " .. pick[1])
        dispatch_gesture{ ges = "tap", pos = centre_of(target.dimen) }
        UIManager:_checkTasks()
        local got = wire()
        assert_true(got == pick[2], pick[1] .. ": one down and up, got " .. got)
        assert_true(key_popup(app) == nil and count(function(w) return w == popup end) == 0,
            pick[1] .. ": the popup is gone")
        assert_true(closes == 1, pick[1] .. ": closed exactly once, got " .. closes)
        assert_true(app.vk_visible and count(function(w) return w == app.vk end) == 1,
            pick[1] .. ": the keyboard stays up")
    end
    close_viewer(app, remote)
end)

check("key_panel_top_row_is_the_strip_row_with_close_and_keyboard", function()
    local KeyPanel = require("vnc/keypanel")
    local Size = require("ui/size")
    local app, remote, sent = new_app()
    local panel = open_key_panel(app)
    UIManager:forceRePaint()
    assert_true(panel.title_bar == nil, "no title bar")
    local function find_title_bar(w)
        if type(w) ~= "table" then return false end
        if w.title_widget and w.left_icon then return true end
        for _, child in ipairs(w) do
            if find_title_bar(child) then return true end
        end
        return false
    end
    assert_true(not find_title_bar(panel[1]), "no TitleBar anywhere in the panel")
    -- the first row, left to right
    local want = { "close", "keyboard", "mod:Ctrl", "mod:Shift", "mod:Alt", "mod:Super" }
    for _, key in ipairs(KeyPanel.STRIP_KEYS) do want[#want + 1] = "key:" .. key[1] end
    local top_y = panel.button_by_id["close"].dimen.y
    local row = {}
    for id, button in pairs(panel.button_by_id) do
        if button.dimen.y == top_y then row[#row + 1] = { id = id, x = button.dimen.x } end
    end
    table.sort(row, function(a, b) return a.x < b.x end)
    local ids = {}
    for i, e in ipairs(row) do ids[i] = e.id end
    assert_true(table.concat(ids, ",") == table.concat(want, ","), "the top row: " .. table.concat(ids, ","))
    assert_true(panel.button_by_id["close"].icon == "close", "KOReader's close icon")
    assert_true(panel.button_by_id["keyboard"].label_widget.file == require("vnc/icons").path("keyboard"),
        "the plugin keyboard icon")
    assert_true(panel.button_by_id["panel"] == nil, "no Send keys icon on the panel itself")
    -- the Keys tab: 4 columns x 3 rows, Modifiers only last
    local grid = {}
    for id, button in pairs(panel.button_by_id) do
        if button.dimen.y > top_y and (id:sub(1, 4) == "key:" or id == "modifiers_only") then
            grid[#grid + 1] = { id = id, x = button.dimen.x, y = button.dimen.y }
        end
    end
    table.sort(grid, function(a, b) return a.y < b.y or (a.y == b.y and a.x < b.x) end)
    ids = {}
    for i, e in ipairs(grid) do ids[i] = e.id end
    assert_true(table.concat(ids, ",") == "key:Home,key:Page Up,key:Insert,key:Backspace,key:End,key:Page Down,"
        .. "key:Menu,key:Enter,key:Print Screen,key:Pause,modifiers_only",
        "the Keys grid: " .. table.concat(ids, ","))
    assert_true(grid[1].y < grid[5].y and grid[5].y < grid[9].y and grid[4].y == grid[1].y, "4 columns, 3 rows")
    -- six rows: top, tabs, three grid rows, recent; five lines between them; the window border
    local line, border = Size.line.medium, Size.border.window
    local h = 6 * KeyPanel.row_height() + 5 * line + 2 * border
    assert_true(panel.dimen.h == h, "six rows tall: " .. panel.dimen.h .. " vs " .. h)
    -- a top-row key from the panel goes to the recent combos (the strip's do not)
    touch(panel, "mod:Ctrl")
    touch(panel, "key:Tab")
    assert_true(take_keys(sent) == "+0xFFE3,+0xFF09,-0xFF09,-0xFFE3", "Ctrl+Tab from the top row")
    assert_true(app.settings.recent_combos[1].label == "Tab" and app.settings.recent_combos[1].mods[1] == "Ctrl",
        "and it is remembered")
    -- ✕ closes it
    touch(panel, "close")
    UIManager:_checkTasks()
    assert_true(app.key_panel == nil and count(function(w) return w == panel end) == 0, "✕ closes the panel")
    close_viewer(app, remote)
end)

check("key_panel_keyboard_icon_switches_back_to_the_keyboard", function()
    local app, remote = new_app()
    app:toggle_keyboard()
    local strip = app.key_strip
    touch(strip, "panel")
    UIManager:_checkTasks()
    local panel = app.key_panel
    assert_true(panel ~= nil and not app.vk_visible, "the panel replaced the keyboard")
    touch(panel, "mod:Shift")
    local wire = wire_log(app)
    touch(panel, "keyboard")
    UIManager:_checkTasks()
    assert_true(app.key_panel == nil, "the panel closes")
    assert_true(app.vk_visible and app.key_strip ~= nil and keyboard_on_stack(app), "keyboard and strip are back")
    assert_true(app.key_strip:modifier_state("Shift") == "armed", "Shift stays armed on the strip")
    assert_true(wire() == "", "nothing is sent")
    close_viewer(app, remote)
end)

check("toolbar_keyboard_button_uses_the_plugin_icon", function()
    local Icons = require("vnc/icons")
    local path = Icons.path("keyboard")
    assert_true(path:sub(1, 1) == "/", "an absolute path: " .. path)
    local here, there = lfs.attributes(path), lfs.attributes(plugin_dir .. "/icons/keyboard.svg")
    assert_true(here and there and here.ino == there.ino and here.dev == there.dev,
        "the plugin's icons/keyboard.svg: " .. path)
    local f = io.open(path, "rb")
    assert_true(f ~= nil, "the icon file exists")
    local svg = f:read("*a"); f:close()
    assert_true(svg:find('viewBox="0 0 48 48"', 1, true), "the mdlight viewBox")
    local app, remote = new_app(400, 300, { toolbar = true })
    local button = app.toolbar.button_by_id.keyboard
    assert_true(button.text == nil, "no text glyph")
    assert_true(button.label_widget.file == path, "the button draws the icon file, got "
        .. tostring(button.label_widget.file))
    UIManager:setDirty(app, "ui")
    UIManager:forceRePaint()
    assert_true(button.label_widget._bb ~= nil, "and renders it")
    close_viewer(app, remote)
end)

check("fit_with_keyboard_accounts_for_the_strip", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    app:zoom_to("fit_with_keyboard")
    tap_toolbar(app, "keyboard")
    local strip = app.key_strip
    local want = Screen:getHeight() - app.vk:getSize().h - strip.dimen.h
    assert_true(remote.ch == want, "the view fits above the strip: " .. tostring(remote.ch) .. " vs " .. want)
    close_viewer(app, remote)
end)

check("key_strip_follows_rotation_and_layout_height", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    tap_toolbar(app, "keyboard")
    local strip = app.key_strip
    local start = Screen:getRotationMode()
    app:set_rotation_mode((start + 1) % 4)
    local size = Screen:getSize()
    assert_true(app.key_strip == strip, "the strip stays")
    assert_true(strip.dimen.w == size.w and strip_bottom(strip) == size.h - app.vk:getSize().h,
        "re-laid out for the new orientation, on top of the keyboard")
    -- a keyboard layout of a different height
    local vk_h = app.vk:getSize().h + 40
    app.vk.getSize = function(self_) return Geom:new{ w = size.w, h = vk_h } end
    app:on_keyboard_height_changed()
    assert_true(strip_bottom(strip) == size.h - vk_h, "the strip moves to stay on top of the keyboard")
    app.vk.getSize = nil
    app:set_rotation_mode(start)
    close_viewer(app, remote)
end)

check("recent_combos_setting_is_kept_in_shape", function()
    local Settings = require("vnc/settings")
    local store = Settings.open(data_dir .. "/recent_combos_check.lua")
    store.data.settings.recent_combos = {
        { mods = { "Shift", "Ctrl", "Shift" }, keysym = 0x74, label = "T" }, -- repeated, out of order
        { mods = { "Ctrl", "Shift" }, keysym = 0x74, label = "T" },  -- the same combo again
        { mods = { "Hyper" }, keysym = 0x74, label = "T" },          -- unknown modifier
        { mods = {}, keysym = 0x20000000, label = "big" },           -- not a keysym
        { mods = {}, keysym = -1, label = "neg" },
        "junk",
        { mods = {}, label = "nothing" },                             -- neither key nor modifier
        { mods = { "Super" }, label = "" },                           -- a modifier on its own is fine
        { mods = {}, keysym = 0xFF1B, label = "Esc" },
        { mods = {}, keysym = 0xFF09, label = "Tab" },
        { mods = {}, keysym = 0x20, label = "Space" },                -- a fifth valid one
    }
    store:flush()
    store = Settings.open(data_dir .. "/recent_combos_check.lua")
    local list = store.data.settings.recent_combos
    local labels = {}
    for _, c in ipairs(list) do labels[#labels + 1] = table.concat(c.mods, "+") .. ":" .. tostring(c.keysym) end
    local got = table.concat(labels, " ")
    assert_true(got == "Ctrl+Shift:116 Super:nil :65307 :65289",
        "valid entries only, canonical, without duplicates, at most four: " .. got)
    store.data.settings.recent_combos = "nonsense"
    store:flush()
    store = Settings.open(data_dir .. "/recent_combos_check.lua")
    assert_true(type(store.data.settings.recent_combos) == "table" and #store.data.settings.recent_combos == 0,
        "garbage becomes an empty list")
end)

check("two_finger_flick_only_ends_the_pan", function()
    local app, remote, sent = new_app()
    dispatch_gesture{ ges = "two_finger_pan", pos = Geom:new{x=200,y=400}, start_pos = Geom:new{x=200,y=300}, relative = {x=0,y=100} }
    dispatch_gesture{ ges = "two_finger_swipe", direction = "south", distance = 400, pos = Geom:new{x=200,y=400} }
    for _, e in ipairs(sent.pointer) do assert_true(e.mask ~= 8 and e.mask ~= 16, "a flick never scrolls") end
    assert_true(app._two_finger_pan == nil and not app._view_moving, "the flick ended the pan")
    close_viewer(app, remote)
end)
check("rotate_gesture_and_bottom_swipes_are_not_handled", function()
    local app, remote = new_app()
    local before = Screen:getRotationMode()
    dispatch_gesture{ ges = "rotate", direction = "cw", pos = Geom:new{x=100,y=100}, angle = 90 }
    assert_true(Screen:getRotationMode() == before, "a two-finger rotate never turns the screen")
    local s = Screen:getSize()
    dispatch_gesture{ ges = "swipe", direction = "north", distance = 200, pos = Geom:new{x=s.w/2, y=s.h-10} }
    assert_true(app.vk_visible == false, "a bottom swipe-up no longer shows the keyboard")
    assert_true(app.ges_events.Rotate == nil and app.ges_events.KbdShow == nil and app.ges_events.KbdHide == nil)
    close_viewer(app, remote)
end)
check("two_finger_tap_fits_and_recentres", function()
    local app, remote = new_app()
    app:zoom_to(2); remote:pan_by(-50, -40)
    dispatch_gesture{ ges = "two_finger_tap", pos = Geom:new{x=100,y=100}, span = 50 }
    assert_true(app.settings.zoom_mode == "fit", "fit, the keyboard being down")
    local vx, vy = remote.view_x, remote.view_y
    app:zoom_to("fit")
    assert_true(remote.view_x == vx and remote.view_y == vy, "re-centred like a fresh fit")
    app:set_keyboard_visible(true)
    dispatch_gesture{ ges = "two_finger_tap", pos = Geom:new{x=100,y=100}, span = 50 }
    assert_true(app.settings.zoom_mode == "fit_with_keyboard", "fit with keyboard while it is up")
    close_viewer(app, remote)
end)

-- ---------------------------------------------------------------- mouse mode

local time = require("ui/time")

--- Seconds until `action` is due on UIManager's task queue, or nil when it is not scheduled.
local function scheduled_delay(action)
    for _, task in ipairs(UIManager._task_queue) do
        if task.action == action then return time.to_s(task.time - time.now()) end
    end
    return nil
end

--- Runs a scheduled action now, the way UIManager would when it falls due.
local function run_scheduled(action)
    UIManager:unschedule(action)
    action()
end

check("keep_screen_on_feeds_the_idle_clocks_so_the_light_does_not_dim", function()
    local ticks = 0
    local fake = function() ticks = ticks + 1 end
    UIManager.event_hook:register("InputEvent", fake)
    local app, remote = new_app()
    local tick = app._keep_awake_task
    assert_true(type(tick) == "function", "has a keep-awake task")
    local d = scheduled_delay(tick)
    assert_true(d and d > 0 and d <= 20, "scheduled within 20 s while shown, got " .. tostring(d))
    run_scheduled(tick)
    assert_true(ticks == 1, "the task fires InputEvent, got " .. ticks)
    assert_true(scheduled_delay(tick) ~= nil, "and re-arms itself")
    -- applying twice does not double up
    app:_apply_keep_screen_on()
    local n = 0
    for _, t in ipairs(UIManager._task_queue) do if t.action == tick then n = n + 1 end end
    assert_true(n == 1, "one scheduled copy, got " .. n)
    -- setting off
    app.settings.keep_screen_on = false
    app:_apply_keep_screen_on()
    assert_true(scheduled_delay(tick) == nil, "off unschedules")
    local before = ticks
    UIManager:_checkTasks()
    assert_true(ticks == before, "no further calls once off")
    -- back on, then close
    app.settings.keep_screen_on = true
    app:_apply_keep_screen_on()
    assert_true(scheduled_delay(tick) ~= nil, "on schedules again")
    app:onCloseWidget()
    assert_true(scheduled_delay(tick) == nil, "close unschedules")
    app:onCloseWidget()
    assert_true(scheduled_delay(tick) == nil, "close is idempotent")
    UIManager.event_hook:unregister("InputEvent", fake)
    remote:free()
end)

local function last_pointer(sent) return sent.pointer[#sent.pointer] end

check("mouse_drag_moves_the_pointer_relatively_with_speed", function()
    local app, remote, sent = new_app(400, 300, { mode = "mouse" })
    local c = app.canvas
    local p = Geom:new{ x = c.x + 100, y = c.y + 100 }
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = p.x + 40, y = p.y }, relative = { x = 40, y = 0 } }
    assert_true(#sent.pointer == 1, "one event, got " .. #sent.pointer)
    local e = sent.pointer[1]
    local want = math.floor(200 + 40 / remote:get_scale() * 1.25 + 0.5)
    assert_true(e.mask == 0 and e.x == want and e.y == 150,
        string.format("expected (%d,150) mask 0, got (%d,%d) mask %d", want, e.x, e.y, e.mask))
    dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = p.x + 40, y = p.y } }
    -- faster
    app.settings.pointer_speed = "fast"
    local fx = app._mouse_x
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = p.x + 40, y = p.y }, relative = { x = 40, y = 0 } }
    want = math.floor(fx + 40 / remote:get_scale() * 2.0 + 0.5)
    assert_true(last_pointer(sent).x == want, "fast: expected " .. want .. ", got " .. last_pointer(sent).x)
    -- and clamped at the edge
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = p.x + 40, y = p.y }, relative = { x = 40000, y = 0 } }
    assert_true(last_pointer(sent).x == 399, "clamped, got " .. last_pointer(sent).x)
    dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = p.x + 40, y = p.y } }
    for _, ev in ipairs(sent.pointer) do assert_true(ev.mask == 0, "no button: mask " .. ev.mask) end
    assert_true(app:has_pointer_action() == false, "nothing held")
    close_viewer(app, remote)
end)

check("mouse_tap_click_is_deferred_and_lands_at_the_pointer", function()
    local app, remote, sent = new_app(400, 300, { mode = "mouse" })
    local wire = wire_log(app)
    local c = app.canvas
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = c.x + 10, y = c.y + 10 } }
    assert_true(#sent.pointer == 0, "the click waits")
    local delay = scheduled_delay(app._deferred_click_task)
    assert_true(delay and math.abs(delay - app.mouse_click_delay()) <= 0.05,
        "deferred by the double-tap interval: " .. tostring(delay) .. " vs " .. app.mouse_click_delay())
    run_scheduled(app._deferred_click_task)
    local got = wire()
    assert_true(got == "p0,p1,p0", "a click, got " .. got)
    for _, e in ipairs(sent.pointer) do
        assert_true(e.x == 200 and e.y == 150, string.format("at the pointer, got (%d,%d)", e.x, e.y))
    end
    close_viewer(app, remote)
end)

check("mouse_double_tap_and_move_drags_from_the_pointer", function()
    local app, remote, sent = new_app(400, 300, { mode = "mouse" })
    local wire = wire_log(app)
    local c = app.canvas
    local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
    dispatch_gesture{ ges = "tap", pos = P }
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = P.x + 40, y = P.y }, relative = { x = 30, y = 0 } }
    local got = wire()
    assert_true(got == "p1,p1", "a press then a drag move, no click: " .. got)
    assert_true(sent.pointer[1].x == 200 and sent.pointer[1].y == 150, "pressed at the pointer")
    local want = math.floor(200 + 30 / remote:get_scale() * 1.25 + 0.5)
    assert_true(sent.pointer[2].x == want, "dragged relatively: " .. sent.pointer[2].x .. " vs " .. want)
    assert_true(app._drag_active == "mouse")
    dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = P.x + 40, y = P.y } }
    got = wire()
    assert_true(got == "p0", "released: " .. got)
    assert_true(last_pointer(sent).x == want, "released at the pointer")
    assert_true(scheduled_delay(app._deferred_click_task) == nil, "no click left over")
    assert_true(app:has_pointer_action() == false)
    close_viewer(app, remote)
end)

check("mouse_tap_tap_is_two_clicks_at_the_pointer", function()
    local app, remote, sent = new_app(400, 300, { mode = "mouse" })
    local wire = wire_log(app)
    local c = app.canvas
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = c.x + 50, y = c.y + 50 } }
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = c.x + 55, y = c.y + 50 } }
    local got = wire()
    assert_true(got == "p0,p1,p0,p0,p1,p0", "a double click straight away: " .. got)
    for _, e in ipairs(sent.pointer) do assert_true(e.x == 200 and e.y == 150, "at the pointer") end
    assert_true(scheduled_delay(app._deferred_click_task) == nil, "nothing left scheduled")
    close_viewer(app, remote)
end)

check("mouse_long_press_right_clicks_at_the_pointer", function()
    local app, remote, sent = new_app(400, 300, { mode = "mouse" })
    local c = app.canvas
    local far = Geom:new{ x = c.x + 5, y = c.y + 5 }
    dispatch_gesture{ ges = "hold", pos = far }
    confirm_hold(app)
    local e = last_pointer(sent)
    assert_true(#sent.pointer == 1 and e.mask == 4 and e.x == 200 and e.y == 150,
        "a right press at the pointer, got " .. #sent.pointer .. " event(s)")
    dispatch_gesture{ ges = "hold_release", pos = far }
    e = last_pointer(sent)
    assert_true(#sent.pointer == 2 and e.mask == 0 and e.x == 200 and e.y == 150, "released at the pointer")
    assert_true(app:has_pointer_action() == false)
    close_viewer(app, remote)
end)

check("mouse_pending_click_is_settled_by_key_mode_switch_and_close", function()
    local c
    do
        local app, remote = new_app(400, 300, { mode = "mouse" })
        c = app.canvas
        local wire = wire_log(app)
        dispatch_gesture{ ges = "tap", pos = Geom:new{ x = c.x + 50, y = c.y + 50 } }
        app:send_key(0x61, true)
        local got = wire()
        assert_true(got == "p0,p1,p0,+0x61", "the click goes before the key: " .. got)
        assert_true(scheduled_delay(app._deferred_click_task) == nil)
        close_viewer(app, remote)
    end
    do
        local app, remote, sent = new_app(400, 300, { mode = "mouse" })
        local wire = wire_log(app)
        local mode_at_click
        local send_pointer = app.session.send_pointer
        app.session.send_pointer = function(...)
            mode_at_click = mode_at_click or app:get_pointer_mode()
            return send_pointer(...)
        end
        dispatch_gesture{ ges = "tap", pos = Geom:new{ x = c.x + 50, y = c.y + 50 } }
        app:set_pointer_mode("touch")
        local got = wire()
        assert_true(got == "p0,p1,p0", "the click is sent: " .. got)
        assert_true(mode_at_click == "mouse", "before the switch")
        assert_true(scheduled_delay(app._deferred_click_task) == nil, "unscheduled")
        assert_true(#sent.pointer == 3)
        close_viewer(app, remote)
    end
    do
        local app, remote, sent = new_app(400, 300, { mode = "mouse" })
        dispatch_gesture{ ges = "tap", pos = Geom:new{ x = c.x + 50, y = c.y + 50 } }
        local task = app._deferred_click_task
        app:onCloseWidget()
        assert_true(#sent.pointer == 0, "nothing sent on close")
        assert_true(scheduled_delay(task) == nil, "unscheduled")
        assert_true(app:has_pointer_action() == false)
        remote:free()
    end
end)

check("mouse_pointer_is_clamped_after_the_remote_shrinks", function()
    local app, remote, sent = new_app(400, 300, { mode = "mouse" })
    local c = app.canvas
    local p = Geom:new{ x = c.x + 100, y = c.y + 100 }
    local s = remote:get_scale() / 1.25
    dispatch_gesture{ ges = "pan", pos = p, relative = { x = 190 * s, y = 140 * s } }
    dispatch_gesture{ ges = "pan_release", pos = p }
    local e = last_pointer(sent)
    assert_true(e.x == 390 and e.y == 290, string.format("moved to (390,290), got (%d,%d)", e.x, e.y))
    remote:resize(200, 100)
    app:on_remote_resized()
    dispatch_gesture{ ges = "pan", pos = p, relative = { x = 0, y = 0 } }
    dispatch_gesture{ ges = "pan_release", pos = p }
    e = last_pointer(sent)
    assert_true(e.x <= 199 and e.y <= 99, string.format("pan clamped, got (%d,%d)", e.x, e.y))
    dispatch_gesture{ ges = "tap", pos = p }
    run_scheduled(app._deferred_click_task)
    for i = #sent.pointer - 2, #sent.pointer do
        e = sent.pointer[i]
        assert_true(e.x <= 199 and e.y <= 99, string.format("click clamped, got (%d,%d)", e.x, e.y))
    end
    close_viewer(app, remote)
end)


--[[ A finger down on GestureDetector's books: a contact that began at screen position `pos` (the
test runs upright, so screen and touch coordinates are the same). Returns a function lifting it. ]]
local function finger_down(pos, slot)
    local gd = Device.input.gesture_detector
    slot = slot or 7
    gd.active_contacts[slot] = { slot = slot, down = true, initial_tev = { x = pos.x, y = pos.y } }
    return function() gd.active_contacts[slot] = nil end
end

check("mouse_click_waits_while_a_finger_is_down_then_a_pan_drags", function()
    local app, remote, sent = new_app(400, 300, { mode = "mouse" })
    local wire = wire_log(app)
    local c = app.canvas
    local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
    dispatch_gesture{ ges = "tap", pos = P }
    local lift = finger_down(Geom:new{ x = P.x + 10, y = P.y })
    run_scheduled(app._deferred_click_task)
    assert_true(wire() == "", "the click stays pending while the finger is down")
    assert_true(app._deferred_click ~= nil, "still pending")
    local delay = scheduled_delay(app._deferred_click_task)
    assert_true(delay and delay > 0 and delay <= 0.1, "re-checked shortly: " .. tostring(delay))
    run_scheduled(app._deferred_click_task)
    assert_true(wire() == "" and app._deferred_click ~= nil, "and again")
    -- the finger crosses the pan threshold only now
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = P.x + 50, y = P.y }, relative = { x = 40, y = 0 } }
    local got = wire()
    assert_true(got == "p1,p1", "one press then a drag move, no click: " .. got)
    assert_true(app._drag_active == "mouse" and app._deferred_click == nil)
    assert_true(scheduled_delay(app._deferred_click_task) == nil, "nothing left scheduled")
    lift()
    dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = P.x + 50, y = P.y } }
    assert_true(wire() == "p0", "released")
    close_viewer(app, remote)
end)

check("mouse_click_waits_for_a_finger_down_only_up_to_the_cap", function()
    local app, remote = new_app(400, 300, { mode = "mouse" })
    local wire = wire_log(app)
    local c = app.canvas
    local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
    -- the cap leaves room for a finger that lands as late as the click falls due to become a long
    -- press: double-tap interval + hold interval + a margin, after the tap
    local gd = Device.input.gesture_detector
    local saved = rawget(gd, "ges_hold_interval")
    local ok, err = pcall(function()
        for _, hold_s in ipairs{ 0.5, 2 } do
            gd.ges_hold_interval = time.s(hold_s)
            local cap = app:mouse_click_wait_cap()
            local want = app.mouse_click_delay() + hold_s
            assert_true(cap > want and cap <= want + 0.5, string.format("hold %.1f s: cap %.2f vs %.2f", hold_s, cap, want))
        end
        gd.ges_hold_interval = time.s(2)
        local before = time.now()
        dispatch_gesture{ ges = "tap", pos = P }
        local left = time.to_s(app._deferred_click.deadline - before)
        assert_true(left > app.mouse_click_delay() + 2, "the deadline follows the hold interval: " .. left)
        app:_drop_deferred_click()
    end)
    gd.ges_hold_interval = saved
    if not ok then error(err, 0) end
    app.mouse_click_wait_cap = function() return 0 end
    local lift = finger_down(P)
    ok, err = pcall(function()
        dispatch_gesture{ ges = "tap", pos = P }
        run_scheduled(app._deferred_click_task)
        assert_true(wire() == "p0,p1,p0", "past the cap the click goes")
        assert_true(app._deferred_click == nil and scheduled_delay(app._deferred_click_task) == nil)
    end)
    app.mouse_click_wait_cap = nil
    lift()
    if not ok then error(err, 0) end
    close_viewer(app, remote)
end)

check("mouse_click_does_not_wait_for_a_finger_far_away", function()
    local app, remote = new_app(400, 300, { mode = "mouse" })
    local wire = wire_log(app)
    local c = app.canvas
    local P = Geom:new{ x = c.x + 20, y = c.y + 20 }
    dispatch_gesture{ ges = "tap", pos = P }
    local lift = finger_down(Geom:new{ x = c.x + c.w - 5, y = c.y + c.h - 5 })
    run_scheduled(app._deferred_click_task)
    lift()
    assert_true(wire() == "p0,p1,p0", "a finger elsewhere is no second tap: the click goes")
    close_viewer(app, remote)
end)

--- The click a Mouse-mode tap left pending takes the modifiers armed when the tap came; one armed
--- while it waits is for the next action (it used to be pressed, and disarmed, with that click).
check("mouse_deferred_click_takes_only_the_modifiers_armed_at_its_tap", function()
    local app, remote = new_app(400, 300, { mode = "mouse" })
    local panel = open_key_panel(app)
    local wire = wire_log(app)
    panel:tap_modifier("Shift")
    local c = app.canvas
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = c.x + 20, y = c.y + 20 } }
    assert_true(app._deferred_click ~= nil and wire() == "", "the click waits")
    panel:tap_modifier("Ctrl")
    run_scheduled(app._deferred_click_task)
    local got = wire()
    assert_true(got == "+0xFFE1,p0,p1,p0,-0xFFE1", "Shift-click only: " .. got)
    assert_true(panel:modifier_state("Ctrl") == "armed" and panel:modifier_state("Shift") == nil,
        "Ctrl stays armed for the next action")
    close_viewer(app, remote)
end)

--- A connect picked in the viewer's menu that fails comes back to the menu - unless the user left
--- the viewer while it ran: the menu used to open over the closed viewer, on top of the library.
check("a_failed_connect_from_the_menu_reopens_it_only_on_a_shown_viewer", function()
    local app, remote = new_app()
    app.plugin.settings.profiles = function() return { { name = "slow", host = "10.0.0.1", port = 5900 } } end
    local on_failure
    app.plugin.connect_profile = function(_, name, cb) on_failure = cb end
    local function pick_slow()
        local menu = app:open_menu()
        find_item(find_item(menu.item_table, "Connections…").sub_item_table, "slow").callback()
        assert_true(on_failure ~= nil and app.menu == nil, "the attempt starts, the menu is closed")
    end
    pick_slow()
    on_failure()
    assert_true(app.menu ~= nil and UIManager:isWidgetShown(app.menu), "a failure on the viewer reopens the menu")
    app:close_menu()
    pick_slow()
    UIManager:close(app)
    on_failure()
    assert_true(app.menu == nil, "but not once the viewer is gone")
    close_viewer(app, remote)
end)

--- A physical key held down on the remote when the viewer closes (Leave from the menu, Shift still
--- held) is let go there: its release will not reach a closed viewer, and it used to stay down.
check("closing_the_viewer_releases_held_keys", function()
    local app, remote, sent = new_app()
    local Key = require("device/key")
    app:onKeyPress(Key:new("Shift", {}))
    assert_true(take_keys(sent) == "+0xFFE1", "Shift goes down on the remote")
    UIManager:close(app)
    assert_true(take_keys(sent) == "-0xFFE1", "and is let go when the viewer closes")
    app:onCloseWidget()
    assert_true(take_keys(sent) == "", "once")
    remote:free()
end)

check("mouse_tap_then_hold_drags_with_the_left_button", function()
    local app, remote, sent = new_app(400, 300, { mode = "mouse" })
    local wire = wire_log(app)
    local c = app.canvas
    local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
    dispatch_gesture{ ges = "tap", pos = P }
    local lift = finger_down(P)
    run_scheduled(app._deferred_click_task)
    dispatch_gesture{ ges = "hold", pos = Geom:new{ x = P.x + 5, y = P.y } }
    confirm_hold(app)
    local got = wire()
    assert_true(got == "p1", "a left press, no click, no right button: " .. got)
    assert_true(sent.pointer[1].x == 200 and sent.pointer[1].y == 150, "at the pointer")
    assert_true(app._deferred_click == nil and scheduled_delay(app._deferred_click_task) == nil)
    dispatch_gesture{ ges = "hold_pan", pos = Geom:new{ x = P.x + 40, y = P.y }, relative = { x = 40, y = 0 } }
    local want = math.floor(200 + 40 / remote:get_scale() * 1.25 + 0.5)
    local e = last_pointer(sent)
    assert_true(wire() == "p1" and e.x == want and e.y == 150,
        string.format("moved like a drag, button held: (%d,%d) vs (%d,150)", e.x, e.y, want))
    dispatch_gesture{ ges = "hold_pan", pos = Geom:new{ x = P.x + 40, y = P.y + 20 }, relative = { x = 40, y = 20 } }
    local wy = math.floor(150 + 20 / remote:get_scale() * 1.25 + 0.5)
    e = last_pointer(sent)
    assert_true(wire() == "p1" and e.x == want and e.y == wy, "moved by the difference only")
    lift()
    dispatch_gesture{ ges = "hold_release", pos = Geom:new{ x = P.x + 40, y = P.y + 20 } }
    e = last_pointer(sent)
    assert_true(wire() == "p0" and e.x == want and e.y == wy, "let go at the pointer")
    assert_true(app:has_pointer_action() == false)
    close_viewer(app, remote)
end)

check("mouse_hold_without_a_pending_tap_stays_a_right_click", function()
    local app, remote, sent = new_app(400, 300, { mode = "mouse" })
    local wire = wire_log(app)
    local c = app.canvas
    local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
    dispatch_gesture{ ges = "tap", pos = P }
    run_scheduled(app._deferred_click_task)
    assert_true(wire() == "p0,p1,p0", "the tap clicked")
    dispatch_gesture{ ges = "hold", pos = P }
    dispatch_gesture{ ges = "hold_pan", pos = Geom:new{ x = P.x + 40, y = P.y }, relative = { x = 40, y = 0 } }
    dispatch_gesture{ ges = "hold_release", pos = P }
    local got = wire()
    assert_true(got == "p4,p0", "a right click, the pointer stays: " .. got)
    for _, e in ipairs(sent.pointer) do assert_true(e.x == 200 and e.y == 150, "at the pointer") end
    -- a hold far from a pending tap: the click, then the right click
    dispatch_gesture{ ges = "tap", pos = P }
    dispatch_gesture{ ges = "hold", pos = Geom:new{ x = c.x + c.w - 5, y = c.y + c.h - 5 } }
    confirm_hold(app)
    dispatch_gesture{ ges = "hold_release", pos = P }
    got = wire()
    assert_true(got == "p0,p1,p0,p4,p0", "click then right click: " .. got)
    close_viewer(app, remote)
end)

check("pointer_button_changes_are_logged_with_a_reason", function()
    local logger = require("logger")
    local lines = {}
    local dbg = logger.dbg
    logger.dbg = function(tag, ...)
        if tag == "vnc-pointer:" then lines[#lines + 1] = table.concat({ tostring(select(1, ...)), tostring(select(4, ...)) }, " ") end
        return dbg(tag, ...)
    end
    local ok, err = pcall(function()
        local app, remote = new_app(400, 300, { mode = "mouse" })
        local c = app.canvas
        local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
        dispatch_gesture{ ges = "tap", pos = P }
        dispatch_gesture{ ges = "pan", pos = Geom:new{ x = P.x + 40, y = P.y }, relative = { x = 30, y = 0 } }
        dispatch_gesture{ ges = "pan", pos = Geom:new{ x = P.x + 60, y = P.y }, relative = { x = 50, y = 0 } }
        dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = P.x + 60, y = P.y } }
        dispatch_gesture{ ges = "pan", pos = Geom:new{ x = c.x + 200, y = P.y }, relative = { x = 50, y = 0 } }
        dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = c.x + 200, y = P.y } }
        dispatch_gesture{ ges = "hold", pos = P }
        confirm_hold(app)
        dispatch_gesture{ ges = "hold_release", pos = P }
        close_viewer(app, remote)
    end)
    logger.dbg = dbg
    if not ok then error(err, 0) end
    local got = table.concat(lines, "|")
    assert_true(got == "1 drag start|0 drag end|4 hold start|0 hold end",
        "one line per button change, not per move: " .. got)
end)

check("a_drag_whose_release_is_eaten_ends_when_the_finger_lifts", function()
    -- Mouse-mode button drag, Touch-mode drag, Touch- and Mouse-mode long press, tap-then-hold
    -- drag: each one's end goes to a widget above us (the on-screen keyboard's keys, a menu) and
    -- never reaches us; the finger is up on GestureDetector's books all the same.
    local cases = {
        { "touch", "drag", function(c, P)
            dispatch_gesture{ ges = "pan", pos = Geom:new{ x = P.x + 40, y = P.y }, relative = { x = 40, y = 0 } }
        end },
        { "touch", "hold", function(c, P) dispatch_gesture{ ges = "hold", pos = P } end },
        { "mouse", "drag", function(c, P)
            dispatch_gesture{ ges = "tap", pos = P }
            dispatch_gesture{ ges = "pan", pos = Geom:new{ x = P.x + 40, y = P.y }, relative = { x = 40, y = 0 } }
        end },
        { "mouse", "hold", function(c, P) dispatch_gesture{ ges = "hold", pos = P } end },
        { "mouse", "tap-hold", function(c, P)
            dispatch_gesture{ ges = "tap", pos = P }
            dispatch_gesture{ ges = "hold", pos = P }
        end },
    }
    for _, case in ipairs(cases) do
        local mode, name, start = case[1], case[2], case[3]
        local app, remote, sent = new_app(400, 300, { mode = mode })
        local c = app.canvas
        local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
        local lift = finger_down(P)
        start(c, P)
        confirm_hold(app)
        local what = mode .. " " .. name
        assert_true(app:has_pointer_action(), what .. ": under way")
        local mask = last_pointer(sent).mask
        assert_true(mask ~= 0, what .. ": a button is down")
        local delay = scheduled_delay(app._release_watch_task)
        assert_true(delay and delay > 0 and delay <= 0.5, what .. ": watched: " .. tostring(delay))
        -- the finger is still down: nothing changes
        run_scheduled(app._release_watch_task)
        assert_true(app:has_pointer_action() and last_pointer(sent).mask == mask, what .. ": still held")
        assert_true(scheduled_delay(app._release_watch_task) ~= nil, what .. ": still watched")
        lift()
        run_scheduled(app._release_watch_task)
        assert_true(last_pointer(sent).mask == 0, what .. ": let go once the finger is up")
        assert_true(app:has_pointer_action() == false, what .. ": nothing held")
        assert_true(scheduled_delay(app._release_watch_task) == nil, what .. ": no longer watched")
        close_viewer(app, remote)
    end
end)

check("a_pointer_move_whose_release_is_eaten_ends_when_the_finger_lifts", function()
    local app, remote, sent = new_app(400, 300, { mode = "mouse", toolbar = true })
    local c = app.canvas
    local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
    local lift = finger_down(P)
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = P.x + 40, y = P.y }, relative = { x = 40, y = 0 } }
    assert_true(app._mouse_moving, "moving the pointer")
    lift()
    run_scheduled(app._release_watch_task)
    assert_true(not app._mouse_moving, "the move is over")
    for _, e in ipairs(sent.pointer) do assert_true(e.mask == 0, "no button ever") end
    close_viewer(app, remote)
end)

check("no_release_watch_without_a_finger_on_the_books", function()
    -- GestureDetector shows no finger down (or does not tell): today's behaviour, no watch
    local app, remote = new_app(400, 300, { mode = "mouse" })
    local c = app.canvas
    local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
    dispatch_gesture{ ges = "hold", pos = P }
    confirm_hold(app)
    assert_true(app:has_pointer_action() and scheduled_delay(app._release_watch_task) == nil, "not watched")
    dispatch_gesture{ ges = "hold_release", pos = P }
    close_viewer(app, remote)
end)

check("pan_release_ends_a_drag_even_with_a_stale_pointer_move", function()
    local app, remote, sent = new_app(400, 300, { mode = "mouse" })
    local c = app.canvas
    local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
    dispatch_gesture{ ges = "tap", pos = P }
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = P.x + 40, y = P.y }, relative = { x = 40, y = 0 } }
    assert_true(app._drag_active == "mouse")
    app._mouse_moving = true -- whatever left it behind
    dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = P.x + 40, y = P.y } }
    assert_true(last_pointer(sent).mask == 0, "the button is let go")
    assert_true(app:has_pointer_action() == false and not app._mouse_moving)
    close_viewer(app, remote)
end)

check("opening_a_popup_of_ours_ends_a_drag", function()
    local opens = {
        menu = function(app) app:open_menu() end,
        display = function(app) app:open_display_panel() end,
        help = function(app) app:open_help() end,
    }
    for name, open in pairs(opens) do
        for _, mode in ipairs{ "touch", "mouse" } do
            local app, remote, sent = new_app(400, 300, { mode = mode })
            local c = app.canvas
            local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
            if mode == "mouse" then dispatch_gesture{ ges = "tap", pos = P } end
            dispatch_gesture{ ges = "pan", pos = Geom:new{ x = P.x + 40, y = P.y }, relative = { x = 40, y = 0 } }
            assert_true(app:has_pointer_action(), name .. "/" .. mode .. ": dragging")
            open(app)
            assert_true(last_pointer(sent).mask == 0 and not app:has_pointer_action(),
                name .. "/" .. mode .. ": the drag ended as the popup came up")
            app:close_menu(); app:close_display_panel(true); app:close_help(true)
            close_viewer(app, remote)
        end
    end
end)
check("a_canvas_drag_ending_over_a_keyboard_key_is_ours", function()
    -- A key of the on-screen keyboard took the end of a canvas drag or long press that lifted on
    -- it: a letter typed itself, and a key that types nothing (the symbol switch) left the button
    -- down. The end is the viewer's: released at once, no key, the layout unchanged.
    for _, mode in ipairs{ "touch", "mouse" } do
        local app, remote = new_app(400, 300, { mode = mode })
        app:set_keyboard_visible(true)
        UIManager:forceRePaint()
        local keys = {}
        local function walk(w, d)
            if type(w) ~= "table" or d > 30 then return end
            if w.keyboard == app.vk and w.dimen and w.dimen.x and w.label then keys[w.label] = w end
            for _, c in ipairs(w) do walk(c, d + 1) end
        end
        walk(app.vk, 0)
        assert_true(keys["a"] and keys["\u{2325}"], "found the keys")
        local wire = wire_log(app)
        local P = Geom:new{ x = app.canvas.x + 60, y = app.canvas.y + 40 }
        for _, label in ipairs{ "a", "\u{2325}" } do
            local k = keys[label]
            local over = Geom:new{ x = k.dimen.x + 5, y = k.dimen.y + 5 }
            local what = mode .. " over " .. label
            if mode == "mouse" then dispatch_gesture{ ges = "tap", pos = P } end
            dispatch_gesture{ ges = "pan", pos = Geom:new{ x = P.x + 40, y = P.y }, relative = { x = 40, y = 0 } }
            dispatch_gesture{ ges = "pan_release", pos = over }
            assert_true(wire() == "p1,p1,p0", what .. ": the drag let go, no key")
            assert_true(not app:has_pointer_action(), what .. ": nothing held")
            dispatch_gesture{ ges = "hold", pos = P }
            confirm_hold(app)
            dispatch_gesture{ ges = "hold_release", pos = over }
            local got = wire()
            assert_true(got == "p4,p0", what .. ": the long press let go, no key: " .. got)
            assert_true(not app:has_pointer_action(), what .. ": nothing held after the long press")
            assert_true(keys[label].dimen ~= nil, what .. ": the keyboard was not rebuilt")
        end
        -- the keyboard's own gestures are still its own
        local a = keys["a"]
        dispatch_gesture{ ges = "tap", pos = Geom:new{ x = a.dimen.x + 5, y = a.dimen.y + 5 } }
        assert_true(wire() == "+0x61,-0x61", mode .. ": a tap on a key types it")
        -- a pointer move whose release never came does not keep a key's long press from it: the
        -- long press is the keyboard's, exactly as without it
        local on_a = Geom:new{ x = a.dimen.x + 5, y = a.dimen.y + 5 }
        local function long_press_on_a()
            dispatch_gesture{ ges = "hold", pos = on_a }
            dispatch_gesture{ ges = "hold_release", pos = on_a }
            local out = wire() .. "|" .. tostring(top() == app.vk or top() == app.key_strip)
            while top() ~= app.key_strip and top() ~= app.vk and top() ~= app do UIManager:close(top()) end
            return out
        end
        local plain = long_press_on_a()
        app._mouse_moving = true
        local got = long_press_on_a()
        assert_true(got == plain, mode .. ": the long press on a key is the keyboard's: " .. got .. " vs " .. plain)
        assert_true(not app._mouse_moving, mode .. ": the stale move is forgotten")
        close_viewer(app, remote)
    end
end)
check("a_hold_drag_turning_two_finger_ends_cleanly", function()
    -- GestureDetector renames a two-finger pan seen in hold state to hold_pan (with no relative
    -- for an inward/outward pan), and a hold whose contact gets a buddy ends as a
    -- two_finger_hold(_pan)_release or is voided by a two_finger_hold, never a hold_release
    local enders = {
        { ges = "hold_pan", span = 80 },                 -- an inward_pan renamed: no relative
        { ges = "two_finger_hold" },
        { ges = "two_finger_hold_pan", relative = { x = 30, y = 0 } },
        { ges = "two_finger_hold_release" },
        { ges = "two_finger_hold_pan_release" },
    }
    for _, ender in ipairs(enders) do
        for _, kind in ipairs{ "hold-drag", "right" } do
            local app, remote, sent = new_app(400, 300, { mode = "mouse" })
            local wire = wire_log(app)
            local c = app.canvas
            local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
            if kind == "hold-drag" then dispatch_gesture{ ges = "tap", pos = P } end
            dispatch_gesture{ ges = "hold", pos = P }
            confirm_hold(app)
            if kind == "hold-drag" then
                dispatch_gesture{ ges = "hold_pan", pos = Geom:new{ x = P.x + 120, y = P.y + 40 }, relative = { x = 120, y = 40 } }
            end
            local before = last_pointer(sent)
            wire()
            local ev = { pos = Geom:new{ x = P.x + 60, y = P.y } }
            for k, v in pairs(ender) do ev[k] = v end
            dispatch_gesture(ev)
            local what = kind .. " / " .. ender.ges .. (ender.span and " (no relative)" or "")
            local got = wire()
            assert_true(got == "p0", what .. ": one release, no move: " .. got)
            local e = last_pointer(sent)
            assert_true(e.x == before.x and e.y == before.y, what .. ": let go at the pointer")
            assert_true(not app:has_pointer_action(), what .. ": nothing held")
            dispatch_gesture{ ges = "hold_pan", pos = Geom:new{ x = P.x + 10, y = P.y }, relative = { x = 10, y = 0 } }
            dispatch_gesture{ ges = "hold_release", pos = P }
            assert_true(wire() == "", what .. ": the rest of it sends nothing")
            close_viewer(app, remote)
        end
    end
end)

check("a_hold_drag_under_a_foreign_popup_ends", function()
    local app, remote, sent = new_app(400, 300, { mode = "mouse" })
    local wire = wire_log(app)
    local c = app.canvas
    local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
    dispatch_gesture{ ges = "tap", pos = P }
    dispatch_gesture{ ges = "hold", pos = P }
    confirm_hold(app)
    wire()
    local InfoMessage = require("ui/widget/infomessage")
    local popup = InfoMessage:new{ text = "server says hi" }
    UIManager:show(popup)
    local x, y = last_pointer(sent).x, last_pointer(sent).y
    dispatch_gesture{ ges = "hold_pan", pos = Geom:new{ x = P.x + 40, y = P.y }, relative = { x = 40, y = 0 } }
    local got = wire()
    assert_true(got == "p0" and last_pointer(sent).x == x and last_pointer(sent).y == y,
        "ended at the pointer, not dragged blind: " .. got)
    assert_true(not app:has_pointer_action())
    UIManager:close(popup)
    close_viewer(app, remote)
end)

check("the_release_watch_follows_the_finger_that_started_it", function()
    local gd = Device.input.gesture_detector
    for _, case in ipairs{ "other finger", "same slot, new contact" } do
        local app, remote, sent = new_app(400, 300, { mode = "touch" })
        local c = app.canvas
        local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
        local lift = finger_down(P, 3)
        dispatch_gesture{ ges = "pan", pos = Geom:new{ x = P.x + 40, y = P.y }, relative = { x = 40, y = 0 } }
        assert_true(scheduled_delay(app._release_watch_task) ~= nil, case .. ": watched")
        local lift2
        if case == "other finger" then
            -- another finger lands (on a popup that ate our release) and stays down
            lift(); lift2 = finger_down(Geom:new{ x = c.x + 300, y = c.y + 200 }, 4)
        else
            lift(); lift2 = finger_down(P, 3)
        end
        run_scheduled(app._release_watch_task)
        assert_true(last_pointer(sent).mask == 0 and not app:has_pointer_action(),
            case .. ": the drag's own finger is gone: let go")
        lift2()
        close_viewer(app, remote)
    end
end)

check("a_new_pan_never_continues_a_stale_drag", function()
    for _, mode in ipairs{ "touch", "mouse" } do
        local app, remote, sent = new_app(400, 300, { mode = mode })
        local wire = wire_log(app)
        local c = app.canvas
        local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
        if mode == "mouse" then dispatch_gesture{ ges = "tap", pos = P } end
        dispatch_gesture{ ges = "pan", pos = Geom:new{ x = P.x + 40, y = P.y }, relative = { x = 40, y = 0 } }
        assert_true(app:has_pointer_action(), mode .. ": dragging")
        wire() -- its release never comes
        local Q = Geom:new{ x = c.x + 200, y = c.y + 150 }
        dispatch_gesture{ ges = "pan", pos = Geom:new{ x = Q.x + 30, y = Q.y }, relative = { x = 30, y = 0 } }
        local got = wire()
        local want = mode == "mouse" and "p0,p0" or "p0,p1,p1"
        assert_true(got == want, mode .. ": the old drag is let go first, then a new gesture: " .. got)
        if mode == "mouse" then
            assert_true(app._drag_active == nil and app._mouse_moving, "mouse: a pointer move now, no button")
        end
        dispatch_gesture{ ges = "pan_release", pos = Q }
        close_viewer(app, remote)
    end
end)

check("touch_double_tap_clicks_at_one_spot", function()
    local time = require("ui/time")
    local app, remote, sent = new_app()
    local c = app.canvas
    local function tap(dx, dy, at)
        local before = #sent.pointer
        dispatch_gesture{ ges = "tap", pos = Geom:new{ x = c.x + 50 + dx, y = c.y + 50 + dy }, time = time.s(at) }
        local out = {}
        for i = before + 1, #sent.pointer do out[#out + 1] = sent.pointer[i] end
        assert_true(#out == 3, "a click is move, press, release")
        assert_true(out[1].x == out[2].x and out[2].x == out[3].x and out[1].y == out[3].y, "one spot")
        return out[2].x, out[2].y
    end
    local x1, y1 = tap(0, 0, 100)
    local x2, y2 = tap(15, 10, 100.3)
    assert_true(x1 == x2 and y1 == y2, "a quick second tap nearby clicks at the first one's spot")
    local x3, y3 = tap(-12, 14, 100.6)
    assert_true(x3 == x1 and y3 == y1, "a third one keeps snapping (triple click)")
    local x4, y4 = tap(15, 0, 101.3)
    assert_true(x4 ~= x1, "too slow: its own spot")
    local x5 = tap(80, 0, 101.5)
    assert_true(x5 ~= x4 and x5 ~= x1, "too far: its own spot")
    -- another gesture in between starts over
    local x6, y6 = tap(0, 0, 105)
    app:onHold(nil, { pos = Geom:new{ x = c.x + 50, y = c.y + 50 } })
    confirm_hold(app)
    app:onHoldRelease(nil, { pos = Geom:new{ x = c.x + 50, y = c.y + 50 } })
    local x7 = tap(15, 0, 105.2)
    assert_true(x7 ~= x6, "a long press in between resets")
    -- a mode switch resets too
    local xa = tap(0, 0, 120)
    app:set_pointer_mode("mouse"); app:set_pointer_mode("touch")
    local xb = tap(15, 0, 120.2)
    assert_true(xb ~= xa, "a mode switch resets")
    close_viewer(app, remote)
end)

check("touch_tap_stays_immediate", function()
    local app, remote = new_app()
    local wire = wire_log(app)
    local n = #UIManager._task_queue
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = app.canvas.x + 50, y = app.canvas.y + 50 } }
    local got = wire()
    assert_true(got == "p0,p1,p0", "clicked at once: " .. got)
    assert_true(#UIManager._task_queue == n, "nothing scheduled")
    assert_true(app._deferred_click == nil)
    close_viewer(app, remote)
end)

-- ---------------------------------------------------------------- toolbar

check("toolbar_buttons_act_and_taps_never_reach_the_canvas", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    assert_true(app.toolbar_visible, "shown on open")
    local Toolbar = require("vnc/toolbar")
    assert_true(table.concat(Toolbar.IDS, ",") == "toggle,display,zoom,mode,keyboard,rotate,scroll_lock,scroll_up,scroll_down,brightness,contrast,close,more",
        table.concat(Toolbar.IDS, ","))
    local before = Screen:getRotationMode()
    tap_toolbar(app, "rotate")
    assert_true(Screen:getRotationMode() == (before + 1) % 4, "rotated a quarter turn clockwise")
    app:set_rotation_mode(before)
    tap_toolbar(app, "mode")
    assert_true(app:get_pointer_mode() == "mouse", "mode switches to mouse")
    UIManager:close(top())  -- the tooltip
    tap_toolbar(app, "mode")
    assert_true(app:get_pointer_mode() == "touch", "and back to touch")
    UIManager:close(top())
    tap_toolbar(app, "keyboard"); assert_true(app.vk_wanted == true, "keyboard tap toggles the keyboard")
    hold_toolbar(app, "keyboard")
    local tip
    for _, w in ipairs(stack()) do if w.toast then tip = w end end
    assert_true(app.key_panel == nil and tip and tip.text == "Keyboard (drag onto a field to click it and type)",
        "a long press on Keyboard only shows its tooltip: " .. stack_desc())
    UIManager:close(tip)
    tap_toolbar(app, "display"); assert_true(app.display_panel ~= nil, "display opens the display panel")
    -- the display panel hangs under the toolbar
    UIManager:forceRePaint()
    local bar = app.toolbar.dimen
    local panel_top = app.display_panel.movable.dimen.y
    assert_true(panel_top >= bar.y + bar.h,
        string.format("the display panel (top %d) sits below the toolbar (bottom %d)", panel_top, bar.y + bar.h))
    assert_true(#sent.pointer == 0, "no toolbar tap reached the canvas, got " .. #sent.pointer .. " pointer events")
    app:close_display_panel()
    app:close_key_panel()
    app:set_keyboard_visible(false)
    assert_true(app.toolbar.button_by_id.scroll_up == nil, "scroll buttons hidden by default")
    app.settings.toolbar_buttons = { scroll_up = true, scroll_down = true }; app.toolbar:relayout()
    tap_toolbar(app, "scroll_down")
    local masks = {}
    for _, e in ipairs(sent.pointer) do masks[#masks + 1] = e.mask end
    assert_true(table.concat(masks, ",") == "16,0", "exactly one notch down, got " .. table.concat(masks, ","))
    sent.pointer = {}
    tap_toolbar(app, "scroll_up")
    masks = {}
    for _, e in ipairs(sent.pointer) do masks[#masks + 1] = e.mask end
    assert_true(table.concat(masks, ",") == "8,0", "exactly one notch up, got " .. table.concat(masks, ","))
    app.settings.toolbar_buttons = nil
    close_viewer(app, remote)
end)

--- Every toolbar button on (the scroll pair and contrast are off by default), on a device with a
--- frontlight; returns a function that restores the frontlight probe.
local function all_toolbar_buttons(app)
    local has = Device.hasFrontlight
    Device.hasFrontlight = function() return true end
    app.settings.toolbar_buttons = { scroll_up = true, scroll_down = true, contrast = true }
    app.toolbar:relayout()
    return function() Device.hasFrontlight = has end
end

check("toolbar_long_press_shows_a_tooltip_and_does_nothing_else", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    local restore = all_toolbar_buttons(app)
    local ok, err = pcall(function()
        local Toolbar = require("vnc/toolbar")
        local want = {
            toggle = "Collapse toolbar", display = "Display settings", zoom = "Zoom: fit, 1:1, your own view",
            mode = "Pointer mode: touch or mouse", keyboard = "Keyboard (drag onto a field to click it and type)", rotate = "Rotate the screen",
            scroll_lock = "Scroll lock: two-finger drag scrolls the remote", scroll_up = "Scroll up",
            scroll_down = "Scroll down", brightness = "Frontlight", contrast = "Contrast of the remote picture",
            close = "Disconnect", more = "Menu",
        }
        local rotation, mode, state = Screen:getRotationMode(), app:get_pointer_mode(), app:view_state()
        for _, id in ipairs(Toolbar.IDS) do
            local base = #UIManager._window_stack
            hold_toolbar(app, id)
            UIManager:_checkTasks()
            local tip = top()
            assert_true(tip.toast and tip.text == want[id], id .. ": tooltip, got " .. tostring(tip.text) .. " " .. stack_desc())
            assert_true(#UIManager._window_stack == base + 1, id .. ": nothing else opens: " .. stack_desc())
            UIManager:close(tip)
            assert_true(#sent.pointer == 0 and #sent.key == 0, id .. ": nothing is sent")
            assert_true(app.menu == nil and app.help == nil and app.key_panel == nil and app.display_panel == nil
                and app.contrast_dialog == nil and not app.vk_wanted and not app.scroll_lock, id .. ": no action")
            assert_true(Screen:getRotationMode() == rotation and app:get_pointer_mode() == mode
                and app:view_state() == state and not app.toolbar.collapsed, id .. ": nothing changed")
        end
        -- the collapsed bubble too
        app:set_toolbar_collapsed(true)
        hold_toolbar(app, "toggle")
        assert_true(top().text == "Show toolbar" and app.toolbar.collapsed, "the bubble's tooltip")
        UIManager:close(top())
    end)
    restore()
    assert_true(ok, tostring(err))
    close_viewer(app, remote)
end)

check("collapsing_a_bar_expanded_from_the_top_right_returns_it_there", function()
    local app = new_app(400, 300, { toolbar = true })
    local Size = require("ui/size")
    app.settings.toolbar_pinned = { keyboard = false, scroll_lock = false } -- (nothing pinned: the round button)
    app.settings.toolbar_pos = { x = 1, y = 0 }
    app:set_toolbar_collapsed(true)
    app:set_toolbar_collapsed(false)
    app:set_toolbar_collapsed(true)
    local d = app.toolbar.dimen
    assert_true(app.toolbar.collapsed, "collapsed")
    assert_true(d.x + d.w == Screen:getWidth() - Size.margin.default and d.y == Size.margin.default,
        string.format("the round button is at the top right corner: %d,%d %dx%d", d.x, d.y, d.w, d.h))
    local p = app.settings.toolbar_pos
    assert_true(p.x == 1 and p.y == 0, "toolbar_pos is still top right")
end)

check("toggling_the_bar_keeps_a_dragged_position", function()
    local app = new_app(400, 300, { toolbar = true })
    app.settings.toolbar_pos = { x = 0.3, y = 0.5 }
    app:set_toolbar_collapsed(true)
    app:set_toolbar_collapsed(false)
    app:set_toolbar_collapsed(true)
    app:set_toolbar_collapsed(false)
    local p = app.settings.toolbar_pos
    assert_true(p.x == 0.3 and p.y == 0.5, "toolbar_pos unchanged: " .. tostring(p.x) .. "," .. tostring(p.y))
end)

check("toolbar_collapses_into_a_bubble_and_back", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    local Icons = require("vnc/icons")
    local bar = app.toolbar.dimen
    local toggle = app.toolbar.button_by_id.toggle
    assert_true(app.toolbar:visible_ids()[1] == "toggle", "the collapse button is the leftmost")
    assert_true(toggle.label_widget.file == Icons.path("toolbar"), "with the plugin's toolbar icon")
    UIManager:setDirty(app, "ui")
    UIManager:forceRePaint()
    assert_true(toggle.label_widget._bb ~= nil, "and renders it")
    local dirty = {}
    local real_dirty = UIManager.setDirty
    UIManager.setDirty = function(self_, w, mode, ...)
        if w == app and type(mode) == "function" then
            local m, r = mode(); dirty[#dirty + 1] = { mode = m, area = r }
        end
        return real_dirty(self_, w, mode, ...)
    end
    app.settings.toolbar_pinned = { keyboard = false, scroll_lock = false } -- (nothing pinned: the round button)
    tap_toolbar(app, "toggle")
    UIManager.setDirty = real_dirty
    local d = app.toolbar.dimen
    assert_true(app.toolbar.collapsed and app.settings.toolbar_collapsed == true, "collapsed and stored")
    local Size = require("ui/size")
    local m = Size.margin.default
    assert_true(d.x == m + math.floor(0.5 * (Screen:getWidth() - d.w - 2 * m) + 0.5) and d.y == m
        and d.w == d.h and d.w < bar.w, "a small round button at the bar's anchor (top centre)")
    assert_true(#dirty == 1 and dirty[1].mode == "ui" and dirty[1].area:contains(bar), "a ui refresh of the old bar")
    assert_true(app.toolbar.button_by_id.more == nil and app.toolbar.button_by_id.toggle ~= nil, "just the bubble")
    -- the bubble is the toolbar: a tap on it never reaches the remote
    assert_true(app:_toolbar_owns({ ges = "tap", pos = Geom:new{ x = d.x + 2, y = d.y + 2 } }), "the bubble owns its taps")
    assert_true(not app:_toolbar_owns({ ges = "tap", pos = Geom:new{ x = bar.x + bar.w - 3, y = bar.y + 3 } }),
        "where the bar was is the canvas again")
    tap_toolbar(app, "toggle")
    assert_true(not app.toolbar.collapsed and app.settings.toolbar_collapsed == false, "expanded and stored")
    assert_true(app.toolbar.dimen.x == bar.x and app.toolbar.dimen.y == bar.y and app.toolbar.dimen.w == bar.w,
        "the bar is back where it was")
    assert_true(#sent.pointer == 0, "nothing reached the remote")
    -- the next viewer opens collapsed; the top-zone swipe still hides and shows the whole thing
    app:set_toolbar_collapsed(true)
    local settings = app.settings
    close_viewer(app, remote)
    local app2, remote2 = new_app(400, 300, { toolbar = true })
    app2.settings.toolbar_collapsed = settings.toolbar_collapsed
    app2.toolbar:relayout()
    assert_true(app2.toolbar.collapsed, "opens collapsed")
    app2:toggle_toolbar()
    assert_true(not app2.toolbar_visible and app2.toolbar.collapsed, "hidden, still collapsed")
    app2:toggle_toolbar()
    assert_true(app2.toolbar_visible and app2.toolbar.collapsed, "shown again as the bubble")
    close_viewer(app2, remote2)
end)

--- Drags the toolbar by (dx, dy) from point `from` on it: pans then a pan_release, like a slow drag.
local function drag_toolbar(from, dx, dy, steps)
    steps = steps or 3
    for i = 1, steps do
        local rx, ry = math.floor(dx * i / steps), math.floor(dy * i / steps)
        dispatch_gesture{ ges = "pan", relative = { x = rx, y = ry }, start_pos = Geom:new{ x = from.x, y = from.y, w = 0, h = 0 },
                          pos = Geom:new{ x = from.x + rx, y = from.y + ry, w = 0, h = 0 } }
    end
    dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = from.x + dx, y = from.y + dy, w = 0, h = 0 } }
end

check("toolbar_drags_and_stays_on_screen", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    local m = require("ui/size").margin.default
    local W, H = Screen:getWidth(), Screen:getHeight()
    local bar = app.toolbar.dimen
    local from = toolbar_button_centre(app, "zoom")
    local refreshes = {}
    local real_dirty = UIManager.setDirty
    UIManager.setDirty = function(self_, w, mode, ...)
        if w == app and type(mode) == "function" then
            local mm, r = mode(); refreshes[#refreshes + 1] = { mode = mm, area = r }
        end
        return real_dirty(self_, w, mode, ...)
    end
    drag_toolbar(from, -15, 200)
    UIManager.setDirty = real_dirty
    local d = app.toolbar.dimen
    assert_true(d.x == bar.x - 15 and d.y == bar.y + 200, string.format("moved with the finger: %d,%d", d.x, d.y))
    assert_true(#refreshes == 4, "one refresh per move and one at the end, got " .. #refreshes)
    for i = 1, 3 do assert_true(refreshes[i].mode == "fast", "fast while it follows the finger") end
    assert_true(refreshes[4].mode == "ui" and refreshes[4].area:contains(d) and refreshes[4].area:contains(bar),
        "ui at the end, over where it was and is")
    assert_true(#sent.pointer == 0, "a drag on the bar never reaches the remote")
    assert_true(app.toolbar_visible and app.menu == nil and app.display_panel == nil, "and it opened nothing")
    local pos = app.settings.toolbar_pos
    assert_true(pos and math.abs(pos.y - (d.y - m) / (H - d.h - 2 * m)) < 1e-9
        and math.abs(pos.x - (d.x - m) / (W - d.w - 2 * m)) < 1e-9, "stored as fractions of the free space")
    -- clamped: never off the screen
    drag_toolbar(toolbar_button_centre(app, "zoom"), -W, 2 * H)
    d = app.toolbar.dimen
    assert_true(d.x == m and d.y == H - d.h - m, string.format("clamped to the bottom left: %d,%d", d.x, d.y))
    assert_true(app.settings.toolbar_pos.x == 0 and app.settings.toolbar_pos.y == 1, "stored as 0, 1")
    -- buttons still work where it is now
    tap_toolbar(app, "rotate")
    local W2, H2 = Screen:getWidth(), Screen:getHeight()
    d = app.toolbar.dimen
    assert_true(W2 == H and H2 == W, "rotated")
    assert_true(d.x == m and d.y == H2 - d.h - m, string.format("still at the bottom left after a rotation: %d,%d", d.x, d.y))
    app:rotate(-1)
    -- the bubble drags too, and the bar opens where the bubble is
    app.settings.toolbar_pos = { x = 0.5, y = 0 }
    app.toolbar:relayout()
    app:set_toolbar_collapsed(true)
    local b = app.toolbar.dimen
    drag_toolbar(toolbar_button_centre(app, "toggle"), 20, 100)
    assert_true(app.toolbar.dimen.x == b.x + 20 and app.toolbar.dimen.y == b.y + 100, "the bubble moves")
    assert_true(#sent.pointer == 0 and app.toolbar.collapsed, "and stays a bubble")
    tap_toolbar(app, "toggle")
    local pos = app.settings.toolbar_pos
    local stored_pos = { x = pos.x, y = pos.y }
    assert_true(not app.toolbar.collapsed and app.toolbar.dimen.y > b.y, "the bar opens at the bubble's anchor")
    app:set_toolbar_collapsed(true)
    assert_true(app.toolbar.dimen.x == b.x + 20 and app.toolbar.dimen.y == b.y + 100
        and app.settings.toolbar_pos.x == stored_pos.x and app.settings.toolbar_pos.y == stored_pos.y,
        "and folds back to where the bubble was dropped")
    app:set_toolbar_collapsed(false)
    close_viewer(app, remote)
end)

--- A drag of the bar whose lift a popup took (the bar never saw its end) must not capture the next
--- gesture: a drag or a swipe on the remote used to move the bar instead of reaching the remote.
check("a_bar_drag_that_lost_its_lift_does_not_take_the_next_gesture", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    local from = toolbar_button_centre(app, "zoom")
    dispatch_gesture{ ges = "pan", relative = { x = 0, y = 40 }, start_pos = Geom:new{ x = from.x, y = from.y, w = 0, h = 0 },
                      pos = Geom:new{ x = from.x, y = from.y + 40, w = 0, h = 0 } }
    assert_true(app.toolbar:is_dragging(), "the bar is being dragged")
    local InfoMessage = require("ui/widget/infomessage")
    local box = InfoMessage:new{ text = "popup" }
    UIManager:show(box)
    dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = from.x, y = from.y + 40, w = 0, h = 0 } }
    UIManager:close(box)
    local b = { x = app.toolbar.dimen.x, y = app.toolbar.dimen.y }
    local far = Geom:new{ x = 300, y = Screen:getHeight() - 200, w = 0, h = 0 }
    for _i, kind in ipairs{ "swipe", "pan" } do
        if kind == "pan" then
            app.toolbar.drag = { sx = from.x, sy = from.y, x = b.x, y = b.y, from = app.toolbar.dimen }
            drag_toolbar(far, 60, 60)
        else
            dispatch_gesture{ ges = "swipe", direction = "southeast", pos = far,
                              end_pos = Geom:new{ x = far.x + 60, y = far.y + 60, w = 0, h = 0 } }
        end
        assert_true(app.toolbar.dimen.x == b.x and app.toolbar.dimen.y == b.y,
            kind .. ": the bar must stay where it was")
        assert_true(not app.toolbar:is_dragging(), kind .. ": and the lost drag is over")
    end
    assert_true(#sent.pointer > 0, "the drag on the remote reaches the remote")
    close_viewer(app, remote)
end)

check("a_swipe_that_starts_on_the_toolbar_moves_it", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    local bar = app.toolbar.dimen
    local from = toolbar_button_centre(app, "mode")
    -- a quick drag ends as a swipe: the pans move the bar, the swipe puts it down
    dispatch_gesture{ ges = "pan", relative = { x = 0, y = 40 }, start_pos = Geom:new{ x = from.x, y = from.y, w = 0, h = 0 },
                      pos = Geom:new{ x = from.x, y = from.y + 40, w = 0, h = 0 } }
    dispatch_gesture{ ges = "swipe", direction = "south", distance = 120, pos = Geom:new{ x = from.x, y = from.y, w = 0, h = 0 },
                      end_pos = Geom:new{ x = from.x, y = from.y + 120, w = 0, h = 0 } }
    assert_true(app.toolbar_visible, "the swipe does not hide the bar")
    assert_true(app.toolbar.dimen.y == bar.y + 120 and app.toolbar.dimen.x == bar.x, "it moved to the lift point")
    -- a flick without any pan: the same
    from = toolbar_button_centre(app, "mode")
    dispatch_gesture{ ges = "swipe", direction = "north", distance = 60, pos = Geom:new{ x = from.x, y = from.y, w = 0, h = 0 },
                      end_pos = Geom:new{ x = from.x, y = from.y - 60, w = 0, h = 0 } }
    assert_true(app.toolbar_visible and app.toolbar.dimen.y == bar.y + 60, "flicked up by 60")
    assert_true(#sent.pointer == 0 and app.mode == nil, "nothing reached the remote")
    assert_true(app:get_pointer_mode() == "touch", "and the button under the finger did not act")
    -- a swipe down that starts in the top zone beside the bar still hides it
    app.toolbar:relayout()
    close_viewer(app, remote)
end)

check("toasts_and_the_contrast_box_follow_a_moved_toolbar", function()
    local Blitbuffer = require("ffi/blitbuffer")
    local app, remote = new_app(400, 300, { toolbar = true })
    local H = Screen:getHeight()
    drag_toolbar(toolbar_button_centre(app, "zoom"), 0, H)
    local tb = app.toolbar.dimen
    assert_true(tb.y > H / 2, "the bar is at the bottom")
    local bb = Blitbuffer.new(Screen:getWidth(), H)
    local tip = app:show_toast("hello")
    tip:paintTo(bb, 0, 0)
    assert_true(tip.frame.dimen.y < H / 4 and not tip.frame.dimen:intersectWith(tb), "the toast stays at the top")
    UIManager:close(tip)
    app.settings.toolbar_buttons = { contrast = true }
    app.toolbar:relayout()
    tap_toolbar(app, "contrast")
    local dlg = app.contrast_dialog
    tb = app.toolbar.dimen
    assert_true(dlg ~= nil and dlg.dimen.y + dlg.dimen.h <= tb.y, "the contrast box sits above a bar at the bottom")
    assert_true(dlg.dimen.y >= 0, "on the screen")
    app:close_contrast_dialog()
    bb:free()
    close_viewer(app, remote)
end)

--- What the toolbar's zoom button shows: KOReader's icon name, or the plugin icon file.
local function zoom_icon(app)
    local b = app.toolbar.button_by_id.zoom
    assert_true(b ~= nil, "the toolbar has a zoom button")
    if b.icon == "icon-not-found" then return b.label_widget.file end
    return b.icon
end
local function near(a, b) return math.abs(a - b) < 1e-6 end

check("toolbar_zoom_button_cycles_fit_and_one_to_one", function()
    local Icons = require("vnc/icons")
    local app, remote = new_app(800, 600, { toolbar = true })
    local ids = table.concat(app.toolbar:visible_ids(), ",")
    assert_true(ids:find("display,zoom,mode", 1, true), "right after Display: " .. ids)
    assert_true(app:view_state() == "fit" and zoom_icon(app) == "zoom.page", "starts fitted: " .. tostring(zoom_icon(app)))
    local fit_scale = remote:get_scale()
    assert_true(fit_scale < 1, "the test plane is bigger than the screen")
    tap_toolbar(app, "zoom")
    assert_true(app:view_state() == "1:1" and remote:get_scale() == 1, "one remote pixel per screen pixel")
    assert_true(app.settings.zoom_mode == 1, "stored like the 100% preset")
    assert_true(near(remote.view_x + remote.cw / 2, 400) and near(remote.view_y + remote.ch / 2, 300),
        "the view centre stays where it was (the picture's centre)")
    assert_true(zoom_icon(app) == Icons.path("zoom-1to1"), "the 1:1 icon, got " .. tostring(zoom_icon(app)))
    tap_toolbar(app, "zoom")
    assert_true(app:view_state() == "fit" and near(remote:get_scale(), fit_scale), "no user view yet: back to fit")
    assert_true(zoom_icon(app) == "zoom.page", "and its icon")
    close_viewer(app, remote)
end)

check("toolbar_zoom_button_remembers_the_user_view", function()
    local app, remote = new_app(800, 600, { toolbar = true })
    local fit_scale = remote:get_scale()
    -- a pinch makes it the user's view
    app:_live_zoom({ pos = { x = 100, y = 120 }, span = 300, start_span = 100 })
    app:onSpread()
    local start = { x = 300, y = 300 }
    app:onTwoFingerPan(nil, { relative = { x = -40, y = -25 }, start_pos = start })
    app:onTwoFingerPanRelease(nil, {})
    assert_true(app:view_state() == "user", "a manual zoom and pan is the user state")
    assert_true(zoom_icon(app) == "zoom.manual", "shown as such, got " .. tostring(zoom_icon(app)))
    local us, ux, uy = remote:get_scale(), remote.view_x, remote.view_y
    tap_toolbar(app, "zoom")
    assert_true(app:view_state() == "fit" and near(remote:get_scale(), fit_scale), "user -> fit")
    tap_toolbar(app, "zoom")
    assert_true(app:view_state() == "1:1" and remote:get_scale() == 1, "fit -> 1:1")
    tap_toolbar(app, "zoom")
    assert_true(app:view_state() == "user" and zoom_icon(app) == "zoom.manual", "1:1 -> the user view")
    assert_true(near(remote:get_scale(), us) and near(remote.view_x, ux) and near(remote.view_y, uy),
        "exactly the view the user made")
    tap_toolbar(app, "zoom")
    assert_true(app:view_state() == "fit", "and round again")
    -- a pan at 1:1 is a new user view, remembered in place of the old one
    tap_toolbar(app, "zoom")
    app:onTwoFingerPan(nil, { relative = { x = 30, y = 10 }, start_pos = { x = 5, y = 5 } })
    app:onTwoFingerPanRelease(nil, {})
    assert_true(app:view_state() == "user" and remote:get_scale() == 1, "a pan alone makes it the user's")
    local px, py = remote.view_x, remote.view_y
    tap_toolbar(app, "zoom"); tap_toolbar(app, "zoom"); tap_toolbar(app, "zoom")
    assert_true(app:view_state() == "user" and near(remote.view_x, px) and near(remote.view_y, py),
        "the newest user view comes back")
    close_viewer(app, remote)
end)

check("toolbar_zoom_button_follows_the_display_panel_and_two_finger_tap", function()
    local app, remote = new_app(800, 600, { toolbar = true })
    app:zoom_to(0.5)
    assert_true(app:view_state() == "preset" and zoom_icon(app) == "zoom.manual", "another preset: a manual zoom")
    tap_toolbar(app, "zoom")
    assert_true(app:view_state() == "fit", "the button goes to fit from there")
    app:zoom_to(1)
    assert_true(app:view_state() == "1:1" and zoom_icon(app) == require("vnc/icons").path("zoom-1to1"),
        "the 100% preset is the 1:1 state")
    app:onTwoFingerTap(nil, { pos = { x = 300, y = 300 } })
    assert_true(app:view_state() == "fit" and zoom_icon(app) == "zoom.page", "a two-finger tap fits")
    close_viewer(app, remote)
end)

check("toolbar_brightness_and_contrast_buttons_follow_their_settings", function()
    local Settings = require("vnc/settings")
    assert_true(Settings.TOOLBAR_BUTTONS.brightness == true, "brightness on by default")
    assert_true(Settings.TOOLBAR_BUTTONS.contrast == true, "contrast on by default")
    local app, remote = new_app(400, 300, { toolbar = true })
    local has = Device.hasFrontlight
    local ok, err = pcall(function()
        app.settings.toolbar_buttons = { brightness = true, contrast = true }
        Device.hasFrontlight = function() return true end
        app.toolbar:relayout()
        local ids = table.concat(app.toolbar:visible_ids(), ",")
        assert_true(ids:find("brightness,contrast,close,more", 1, true), "both before Close and More: " .. ids)
        assert_true(app.toolbar.button_by_id.contrast.icon == "appbar.contrast", "KOReader's contrast icon")
        assert_true(app.toolbar.button_by_id.brightness.label_widget.file == require("vnc/icons").path("brightness"),
            "the plugin's brightness icon")
        Device.hasFrontlight = function() return false end
        app.toolbar:relayout()
        assert_true(app.toolbar.button_by_id.brightness == nil, "no frontlight, no brightness button")
        assert_true(app.toolbar.button_by_id.contrast ~= nil, "contrast does not need one")
    end)
    Device.hasFrontlight = has
    assert_true(ok, tostring(err))
    close_viewer(app, remote)
end)

check("toolbar_brightness_button_opens_the_frontlight_dialog", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    local has, broadcast = Device.hasFrontlight, UIManager.broadcastEvent
    local events = {}
    local ok, err = pcall(function()
        Device.hasFrontlight = function() return true end
        app.settings.toolbar_buttons = { brightness = true }
        app.toolbar:relayout()
        app:toggle_keyboard()
        assert_true(app.vk_visible, "the keyboard is up")
        UIManager.broadcastEvent = function(self_, ev)
            events[#events + 1] = ev.handler
            -- what DeviceListener's handler does: KOReader's own light dialog goes on top
            if ev.handler == "onShowFlDialog" then
                UIManager:show(require("ui/widget/infomessage"):new{ text = "frontlight" })
            end
        end
        tap_toolbar(app, "brightness")
        UIManager.broadcastEvent = broadcast
        assert_true(table.concat(events, ",") == "onShowFlDialog", "asks KOReader for its dialog: " .. table.concat(events, ","))
        UIManager:_checkTasks()
        assert_true(not app.vk_visible, "the keyboard makes way for the dialog")
        UIManager:close(top())
        UIManager:_checkTasks()
        app:_watch_keyboard_tick()
        UIManager:_checkTasks()
        assert_true(app.vk_visible, "and comes back when it is gone")
        assert_true(#sent.pointer == 0, "nothing reached the remote")
    end)
    Device.hasFrontlight, UIManager.broadcastEvent = has, broadcast
    assert_true(ok, tostring(err))
    close_viewer(app, remote)
end)

check("contrast_setting_is_kept_and_cleaned", function()
    local Settings = require("vnc/settings")
    assert_true(Settings.DEFAULTS.remote_contrast == 1, "neutral by default")
    local levels = Settings.CONTRAST_LEVELS
    assert_true(type(levels) == "table" and #levels >= 5, "a list of levels")
    local neutral = 0
    for i, v in ipairs(levels) do
        if v == 1 then neutral = i end
        if i > 1 then assert_true(v > levels[i - 1], "ascending") end
    end
    assert_true(neutral > 1 and neutral < #levels, "neutral in the middle, both ways possible")
    local path = data_dir .. "/ui_smoke_contrast.lua"; os.remove(path)
    local s = Settings.open(path)
    s.data.settings.remote_contrast = levels[#levels]; s:flush()
    assert_true(Settings.open(path).data.settings.remote_contrast == levels[#levels], "a level is kept")
    for _, junk in ipairs({ 1.1, -2, "x", 0 }) do
        local f = io.open(path, "w")
        f:write("return { settings = { remote_contrast = " .. string.format("%q", junk) .. " } }\n"); f:close()
        assert_true(Settings.open(path).data.settings.remote_contrast == 1, "junk " .. tostring(junk) .. " cleans to neutral")
    end
end)

--- Opens the contrast dialog from its toolbar button (switched on for the check).
local function open_contrast(app)
    app.settings.toolbar_buttons = { contrast = true }
    app.toolbar:relayout()
    tap_toolbar(app, "contrast")
    UIManager:_checkTasks()
    local dlg = app.contrast_dialog
    assert_true(dlg ~= nil and top() == dlg, "the contrast dialog is on top: " .. stack_desc())
    return dlg
end

check("contrast_dialog_steps_through_the_levels", function()
    local Settings = require("vnc/settings")
    local levels = Settings.CONTRAST_LEVELS
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    app.settings.remote_contrast = 1
    app:toggle_keyboard()
    local dlg = open_contrast(app)
    assert_true(not app.vk_visible, "the keyboard makes way for it")
    local progress = dlg.progress
    assert_true(progress.num_buttons == #levels, "one step per level")
    local neutral
    for i, v in ipairs(levels) do if v == 1 then neutral = i end end
    assert_true(progress.position == neutral and progress.default_position == neutral, "at neutral, marked as the default")
    -- a step repaints the whole canvas, with the new curve, without asking the server
    local dirty = {}
    local real_dirty = UIManager.setDirty
    UIManager.setDirty = function(self_, w, mode, region)
        if w == app then
            local m, r = mode, region
            if type(mode) == "function" then m, r = mode() end
            dirty[#dirty + 1] = { m, r }
        end
        return real_dirty(self_, w, mode, region)
    end
    UIManager:forceRePaint()
    local target = #levels
    dispatch_gesture{ ges = "tap", pos = centre_of(progress.buttonprogress_content[target].dimen) }
    UIManager.setDirty = real_dirty
    assert_true(app.settings.remote_contrast == levels[target], "stored: " .. tostring(app.settings.remote_contrast))
    assert_true(remote.contrast == levels[target] and remote._lut ~= nil, "the picture takes it")
    local whole = false
    for _, d in ipairs(dirty) do
        local r = d[2]
        if d[1] == "ui" and r and r.x == app.canvas.x and r.y == app.canvas.y and r.w == app.canvas.w
                and r.h == app.canvas.h then
            whole = true
        end
    end
    assert_true(whole, "the canvas is repainted in place (partial ui refresh)")
    UIManager:forceRePaint()
    assert_true(remote.last_recomputed_px == app.canvas.w * app.canvas.h, "redrawn in full from the plane")
    assert_true(sent.full_updates == 0, "no update asked from the server")
    assert_true(top() == dlg, "the dialog stays up")
    -- back to neutral: no curve at all
    dispatch_gesture{ ges = "tap", pos = centre_of(progress.buttonprogress_content[neutral].dimen) }
    assert_true(app.settings.remote_contrast == 1 and remote._lut == nil, "neutral: no curve")
    close_viewer(app, remote)
end)

check("contrast_dialog_close_paths", function()
    local Key = require("device/key")
    local paths = {
        ["close button"] = function(app, dlg)
            UIManager:forceRePaint()
            dispatch_gesture{ ges = "tap", pos = centre_of(dlg.title_bar.right_button.dimen) }
        end,
        ["tap outside"] = function(app, dlg)
            UIManager:forceRePaint()
            local d = dlg.dimen
            dispatch_gesture{ ges = "tap", pos = Geom:new{ x = d.x + 5, y = d.y + d.h + 20 } }
        end,
        ["toolbar button"] = function(app, dlg)
            local pos = toolbar_button_centre(app, "contrast")
            dispatch_gesture{ ges = "tap", pos = pos }
        end,
        ["Back key"] = function(app, dlg)
            UIManager:sendEvent(Event:new("KeyPress", Key:new("Back", {})))
        end,
    }
    for name, act in pairs(paths) do
        local app, remote, sent = new_app(400, 300, { toolbar = true })
        app:toggle_keyboard()
        local dlg = open_contrast(app)
        act(app, dlg)
        UIManager:_checkTasks()
        assert_true(app.contrast_dialog == nil, name .. ": closed")
        assert_true(count(function(w) return w == dlg end) == 0, name .. ": off the stack")
        assert_true(app.vk_visible, name .. ": the keyboard is back")
        assert_true(#sent.pointer == 0, name .. ": nothing reached the remote")
        close_viewer(app, remote)
    end
end)

check("contrast_dialog_goes_with_a_rotation_and_with_the_viewer", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    local before = Screen:getRotationMode()
    local dlg = open_contrast(app)
    app:rotate(1)
    assert_true(app.contrast_dialog == nil and count(function(w) return w == dlg end) == 0, "a rotation closes it")
    app:set_rotation_mode(before)
    dlg = open_contrast(app)
    close_viewer(app, remote)
    assert_true(app.contrast_dialog == nil and count(function(w) return w == dlg end) == 0, "closing the viewer too")
end)

check("stored_contrast_applies_when_the_viewer_paints", function()
    local app, remote = new_app(400, 300)
    app.settings.remote_contrast = 2
    UIManager:setDirty(app, "ui")
    UIManager:forceRePaint()
    assert_true(remote.contrast == 2, "the stored level is drawn, got " .. tostring(remote.contrast))
    close_viewer(app, remote)
end)

check("toolbar_more_opens_the_menu", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    tap_toolbar(app, "more")
    assert_true(app.menu ~= nil, "the menu is open")
    app:close_menu()
    close_viewer(app, remote)
end)

check("toolbar_does_not_eat_a_canvas_drag_release", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    local wire = wire_log(app)
    local bar = app.toolbar.dimen
    local over_bar = Geom:new{ x = bar.x + math.floor(bar.w / 2), y = bar.y + math.floor(bar.h / 2) }
    local size = Screen:getSize()
    local mid = Geom:new{ x = math.floor(size.w / 2), y = math.floor(size.h / 2) }
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = mid.x, y = mid.y - 20 }, relative = { x = 0, y = -20 } }
    dispatch_gesture{ ges = "pan", pos = over_bar, relative = { x = over_bar.x - mid.x, y = over_bar.y - mid.y } }
    dispatch_gesture{ ges = "pan_release", pos = over_bar }
    local log = wire()
    assert_true(log:sub(-2) == "p0", "the drag's release reached the remote: " .. log)
    assert_true(app:has_pointer_action() == false, "nothing held after the drag")
    dispatch_gesture{ ges = "hold", pos = mid }
    confirm_hold(app)
    dispatch_gesture{ ges = "hold_release", pos = over_bar }
    log = wire()
    assert_true(log == "p4,p0", "the long press let go over the toolbar: " .. log)
    assert_true(app:has_pointer_action() == false, "nothing held after the long press")
    close_viewer(app, remote)
end)

check("toolbar_leaves_a_zoom_on_it_to_the_canvas", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    local bar = app.toolbar.dimen
    local over_bar = Geom:new{ x = bar.x + math.floor(bar.w / 2), y = bar.y + math.floor(bar.h / 2) }
    local spreads = 0
    local on_spread = app.onSpread
    app.onSpread = function(...) spreads = spreads + 1; return on_spread(...) end
    local before = remote:get_scale()
    -- a spread: the live zoom (outward_pan) and its end (spread), both centred on the bar
    dispatch_gesture{ ges = "outward_pan", pos = over_bar, start_span = 100, span = 150 }
    dispatch_gesture{ ges = "spread", pos = over_bar, span = 150 }
    assert_true(remote:get_scale() > before,
        string.format("the canvas zoomed: scale %s -> %s", tostring(before), tostring(remote:get_scale())))
    assert_true(spreads == 1, "the spread reached the canvas, got " .. spreads)
    for _, kind in ipairs({ "pinch", "spread", "inward_pan", "outward_pan", "two_finger_tap" }) do
        assert_true(app:_toolbar_owns({ ges = kind, pos = over_bar }) == false, kind .. " is never the toolbar's")
    end
    -- a swipe is the toolbar's only when it starts on it (a quick drag of the bar)
    local beside = Geom:new{ x = bar.x + bar.w + 5, y = over_bar.y }
    assert_true(app:_toolbar_owns({ ges = "swipe", pos = beside, end_pos = over_bar }) == false,
        "a swipe from beside the bar is not")
    assert_true(app:_toolbar_owns({ ges = "tap", pos = over_bar }) == true, "a tap there is")
    close_viewer(app, remote)
end)

check("toolbar_recentres_after_rotation", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    local before = Screen:getRotationMode()
    local y0 = app.toolbar.dimen.y
    assert_true(app.toolbar.dimen.x == math.floor((Screen:getWidth() - app.toolbar.dimen.w) / 2), "centred")
    app:rotate(1)
    local d = app.toolbar.dimen
    assert_true(d.x == math.floor((Screen:getWidth() - d.w) / 2),
        string.format("re-centred for width %d, got x=%d w=%d", Screen:getWidth(), d.x, d.w))
    assert_true(d.y == y0, "same distance from the top")
    app:set_rotation_mode(before)
    close_viewer(app, remote)
end)

check("toolbar_toggle_repaints_only_its_area", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    UIManager:forceRePaint()
    local real = UIManager.setDirty
    local seen = {}
    UIManager.setDirty = function(self_, widget, mode, region)
        if type(mode) == "function" then mode, region = mode() end
        seen[#seen + 1] = { mode = mode, region = region }
        return real(self_, widget, mode, region)
    end
    local ok, err = pcall(function()
        for _, want in ipairs({ false, true }) do
            seen = {}
            app:toggle_toolbar()
            assert_true(app.toolbar_visible == want, "toggled to " .. tostring(want))
            local d, hit = app.toolbar.dimen, false
            for _, r in ipairs(seen) do
                assert_true(r.mode ~= "full" and r.mode ~= "flashui", "no flashing refresh: " .. tostring(r.mode))
                local g = r.region
                if r.mode == "ui" and g and g.x == d.x and g.y == d.y and g.w == d.w and g.h == d.h then hit = true end
            end
            assert_true(hit, "a ui refresh of exactly the toolbar's area")
        end
    end)
    UIManager.setDirty = real
    assert_true(ok, tostring(err))
    close_viewer(app, remote)
end)

-- ---------------------------------------------------------------- scroll lock

--- The masks of the pointer events sent so far, comma separated; clears the record.
local function take_masks(sent)
    local masks = {}
    for _, e in ipairs(sent.pointer) do masks[#masks + 1] = e.mask end
    sent.pointer = {}
    return table.concat(masks, ",")
end

--- A two-finger drag event as GestureDetector reports it: from `start`, `rel` away from it so far.
local function two_finger_pan(start, rx, ry)
    dispatch_gesture{ ges = "two_finger_pan", start_pos = Geom:new{ x = start.x, y = start.y },
        pos = Geom:new{ x = start.x + rx, y = start.y + ry }, relative = { x = rx, y = ry } }
end

local function two_finger_lift(at)
    dispatch_gesture{ ges = "two_finger_pan_release", pos = Geom:new{ x = at.x, y = at.y } }
end

check("scroll_lock_off_two_finger_drag_pans", function()
    local app, remote, sent = new_app(2000, 1500)
    assert_true(app.scroll_lock == false, "off on open")
    app:zoom_to(2)
    local vy = remote.view_y
    local start = { x = 300, y = 500 }
    two_finger_pan(start, 0, -Screen:getHeight() * 0.3)
    two_finger_lift(start)
    assert_true(remote.view_y ~= vy, "the picture moved")
    for _, e in ipairs(sent.pointer) do
        assert_true(e.mask ~= 8 and e.mask ~= 16 and e.mask ~= 32 and e.mask ~= 64, "no wheel, got mask " .. e.mask)
    end
    close_viewer(app, remote)
end)

check("scroll_lock_on_two_finger_drag_sends_wheel_notches", function()
    local app, remote, sent = new_app(2000, 1500)
    app:zoom_to(2)
    app:toggle_scroll_lock()
    assert_true(app.scroll_lock == true, "on")
    local vx, vy, scale = remote.view_x, remote.view_y, remote:get_scale()
    local sy, sx = Screen:getHeight() / 10, Screen:getWidth() / 10
    local start = { x = 300, y = 500 }
    -- fingers up 3/10 of the screen, in two moves: three notches down, at the fingers
    two_finger_pan(start, 0, -1.5 * sy)
    two_finger_pan(start, 0, -3 * sy)
    local wx, wy = app:_to_remote(start.x, start.y - 3 * sy)
    local last = sent.pointer[#sent.pointer]
    assert_true(last and last.x == wx and last.y == wy,
        string.format("at the fingers (%d,%d), got (%s,%s)", wx, wy, tostring(last and last.x), tostring(last and last.y)))
    two_finger_lift(start)
    assert_true(take_masks(sent) == "16,0,16,0,16,0", "three notches down")
    assert_true(remote.view_x == vx and remote.view_y == vy and remote:get_scale() == scale, "the view stays")
    -- fingers left 2/10 of the width: two notches right
    two_finger_pan(start, -2 * sx, 0); two_finger_lift(start)
    assert_true(take_masks(sent) == "64,0,64,0", "two notches right")
    -- down: up; right: left; less than a step: nothing
    start = { x = 310, y = 500 }
    two_finger_pan(start, 0, sy); two_finger_lift(start)
    assert_true(take_masks(sent) == "8,0", "one notch up")
    start = { x = 320, y = 500 }
    two_finger_pan(start, sx, 0); two_finger_lift(start)
    assert_true(take_masks(sent) == "32,0", "one notch left")
    start = { x = 330, y = 500 }
    two_finger_pan(start, 0.9 * sx, -0.9 * sy); two_finger_lift(start)
    assert_true(take_masks(sent) == "", "less than a step sends nothing")
    -- a quick drag ends as a flick: its remaining distance still scrolls
    start = { x = 340, y = 500 }
    two_finger_pan(start, 0, -sy)
    dispatch_gesture{ ges = "two_finger_swipe", direction = "north", distance = 3 * sy,
        pos = Geom:new{ x = start.x, y = start.y }, end_pos = Geom:new{ x = start.x, y = start.y - 3 * sy } }
    assert_true(take_masks(sent) == "16,0,16,0,16,0", "the flick finishes the three notches")
    assert_true(app._two_finger_pan == nil, "and ends the gesture")
    assert_true(remote.view_x == vx and remote.view_y == vy, "the view still stays")
    close_viewer(app, remote)
end)

check("scroll_lock_notches_go_to_the_mouse_pointer_in_mouse_mode", function()
    local app, remote, sent = new_app(400, 300, { mode = "mouse" })
    app:toggle_scroll_lock()
    local px, py = app:_mouse_pointer_px()
    local start = { x = 100, y = 400 }
    two_finger_pan(start, 0, Screen:getHeight() / 10); two_finger_lift(start)
    local e = sent.pointer[1]
    assert_true(take_masks(sent) == "8,0" and e.x == px and e.y == py,
        string.format("one notch up at the mouse pointer (%d,%d), got (%d,%d)", px, py, e.x, e.y))
    close_viewer(app, remote)
end)

check("scroll_lock_neither_sends_nor_takes_armed_modifiers", function()
    local app, remote, sent = new_app(2000, 1500)
    local panel = open_key_panel(app)
    touch(panel, "mod:Shift")
    app:toggle_scroll_lock()
    sent.key = {}; sent.pointer = {}
    -- above the panel
    local start = { x = 300, y = 300 }
    two_finger_pan(start, 0, -2 * Screen:getHeight() / 10); two_finger_lift(start)
    local masks = take_masks(sent)
    assert_true(masks == "16,0,16,0", "two notches, got " .. masks)
    assert_true(take_keys(sent) == "", "no key sent")
    assert_true(panel:modifier_state("Shift") == "armed", "Shift stays armed")
    app:close_key_panel()
    close_viewer(app, remote)
end)

check("scroll_lock_pinch_still_zooms_and_two_finger_tap_fits", function()
    local app, remote, sent = new_app(2000, 1500)
    app:toggle_scroll_lock()
    local scale = remote:get_scale()
    dispatch_gesture{ ges = "outward_pan", pos = Geom:new{ x = 300, y = 400 }, span = 200, start_span = 100 }
    dispatch_gesture{ ges = "spread", pos = Geom:new{ x = 300, y = 400 }, span = 200 }
    assert_true(remote:get_scale() > scale * 1.5, "the spread zoomed in")
    dispatch_gesture{ ges = "two_finger_tap", pos = Geom:new{ x = 300, y = 400 }, span = 50 }
    assert_true(app.settings.zoom_mode == "fit", "two-finger tap fits")
    assert_true(take_masks(sent) == "", "no wheel")
    close_viewer(app, remote)
    local app2, remote2 = new_app()
    assert_true(app2.scroll_lock == false, "a new viewer starts with scroll lock off")
    close_viewer(app2, remote2)
end)

check("scroll_lock_toggle_ends_the_two_finger_gesture", function()
    local app, remote, sent = new_app(2000, 1500)
    app:zoom_to(2)
    local sy = Screen:getHeight() / 10
    -- turning it on mid-pan: the rest of that drag neither pans nor scrolls
    local start = { x = 300, y = 500 }
    two_finger_pan(start, 0, -sy)
    local vy = remote.view_y
    app:toggle_scroll_lock()
    assert_true(not app._view_moving, "the pan settled")
    two_finger_pan(start, 0, -4 * sy)
    assert_true(remote.view_y == vy and take_masks(sent) == "", "no stray pan or notch")
    two_finger_lift(start)
    -- the next drag scrolls
    start = { x = 310, y = 500 }
    two_finger_pan(start, 0, -sy); two_finger_lift(start)
    assert_true(take_masks(sent) == "16,0", "the next drag scrolls")
    -- turning it off mid-drag: no notch and no pan for the rest of it
    start = { x = 320, y = 500 }
    two_finger_pan(start, 0, -0.5 * sy)
    app:toggle_scroll_lock()
    two_finger_pan(start, 0, -3 * sy)
    dispatch_gesture{ ges = "two_finger_swipe", direction = "north", distance = 4 * sy,
        pos = Geom:new{ x = start.x, y = start.y }, end_pos = Geom:new{ x = start.x, y = start.y - 4 * sy } }
    assert_true(remote.view_y == vy and take_masks(sent) == "", "no notch, no pan after the toggle")
    close_viewer(app, remote)
end)

check("toolbar_scroll_lock_button_toggles_and_shows_selected", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    local Toolbar = require("vnc/toolbar")
    local ids = table.concat(Toolbar.IDS, ",")
    assert_true(ids:find("rotate,scroll_lock,scroll_up", 1, true), "right after Rotate: " .. ids)
    assert_true(app.toolbar.button_by_id.scroll_up == nil and app.toolbar.button_by_id.scroll_lock ~= nil,
        "shown without the scroll buttons setting")
    local Icons = require("vnc/icons")
    local path = Icons.path("scroll-lock")
    local f = io.open(path, "rb")
    assert_true(f ~= nil, "icons/scroll-lock.svg exists")
    local svg = f:read("*a"); f:close()
    assert_true(svg:find('viewBox="0 0 48 48"', 1, true), "the mdlight viewBox")
    for id, name in pairs({ scroll_lock = "scroll-lock", keyboard = "keyboard" }) do
        local b = app.toolbar.button_by_id[id]
        assert_true(b.label_widget.file == Icons.path(name), id .. " draws its icon file")
        assert_true(b.label_container[1] == b.label_widget, id .. ": the icon is the painted one")
    end
    UIManager:forceRePaint()
    local real = UIManager.setDirty
    local seen = {}
    UIManager.setDirty = function(self_, widget, mode, region)
        if type(mode) == "function" then mode, region = mode() end
        seen[#seen + 1] = { mode = mode, region = region }
        return real(self_, widget, mode, region)
    end
    local ok, err = pcall(function()
        for _, want in ipairs({ true, false }) do
            local pos = toolbar_button_centre(app, "scroll_lock")
            seen = {}
            dispatch_gesture{ ges = "tap", pos = pos }
            assert_true(app.scroll_lock == want, "toggled to " .. tostring(want))
            local b = app.toolbar.button_by_id.scroll_lock
            assert_true(b.label_widget.file == path and b.label_container[1] == b.label_widget,
                "still the plugin icon after the relayout")
            assert_true((b.frame.invert and true or false) == want, "inverted exactly while on")
            local bar, hit = app.toolbar.dimen, false
            for _, r in ipairs(seen) do
                assert_true(r.mode ~= "full" and r.mode ~= "flashui" and r.mode ~= "partial",
                    "no flashing refresh: " .. tostring(r.mode))
                local g = r.region
                assert_true(g and g.w <= bar.w and g.h <= bar.h, "nothing beyond the bar is refreshed")
                if r.mode == "ui" and g:contains(b.dimen or bar) then hit = true end
            end
            assert_true(hit, "a ui refresh of the toolbar")
            UIManager:forceRePaint()
            -- the button's corner is in its padding: white normally, black inverted
            local d = b.dimen
            local px = pixel_at(Screen.bb, d.x + 1, d.y + 1)
            local black = px.r < 128
            assert_true(black == want, "painted " .. (want and "inverted" or "plain"))
        end
    end)
    UIManager.setDirty = real
    assert_true(ok, tostring(err))
    assert_true(#sent.pointer == 0, "nothing sent")
    close_viewer(app, remote)
end)

check("toolbar_settles_a_pending_mouse_click_first", function()
    local app, remote = new_app(400, 300, { mode = "mouse", toolbar = true })
    local wire = wire_log(app)
    local size = Screen:getSize()
    local seen
    local open_display_panel = app.open_display_panel
    app.open_display_panel = function(self_)
        seen = wire()
        return open_display_panel(self_)
    end
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = math.floor(size.w / 2), y = math.floor(size.h / 2) } }
    assert_true(wire() == "", "the click waits")
    tap_toolbar(app, "display")
    assert_true(app.display_panel ~= nil, "the panel opened")
    assert_true(seen == "p0,p1,p0", "the click went out before the panel opened: " .. tostring(seen))
    assert_true(scheduled_delay(app._deferred_click_task) == nil, "nothing left scheduled")
    app:close_display_panel()
    -- the menu too
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = math.floor(size.w / 2), y = math.floor(size.h / 2) } }
    app:open_menu()
    assert_true(wire() == "p0,p1,p0", "open_menu sends the pending click first")
    assert_true(scheduled_delay(app._deferred_click_task) == nil, "nothing left scheduled")
    app:close_menu()
    close_viewer(app, remote)
end)

-- ---------------------------------------------------------------- reconnect

--- How many times `action` is in UIManager's task queue.
local function scheduled_count(action)
    local n = 0
    for _, task in ipairs(UIManager._task_queue) do
        if task.action == action then n = n + 1 end
    end
    return n
end

local function near(a, b) return a ~= nil and math.abs(a - b) < 0.5 end

--- The latest connect callback the fake session got.
local function last_connect(sent) return sent.connects[#sent.connects] end

check("reconnect_backoff_and_success", function()
    local app, remote, sent = new_app()
    local r = app.reconnect
    app.session.state = "error"
    app:on_session_error("x")
    assert_true(r:is_running() and top() == r.box, "the box is up")
    assert_true(sent.keep_wifi == true, "Wi-Fi stays on from the drop to the first attempt")
    assert_true(r.box.title == "Connection lost — reconnecting… (attempt 1, next in 2 s)",
        "title: " .. tostring(r.box.title))
    find_button(r.box, "Retry now"); find_button(r.box, "Close")
    assert_true(near(scheduled_delay(r._retry_task), 2), "first attempt in 2 s")
    -- a second drop while the loop runs starts no second one
    app:on_session_error("x")
    assert_true(scheduled_count(r._retry_task) == 1, "one scheduled attempt")
    assert_true(count(function(w) return w == r.box or (w.buttons and w.title
        and w.title:find("Connection lost", 1, true)) end) == 1, "one box: " .. stack_desc())
    run_scheduled(r._retry_task)
    assert_true(#sent.connects == 1 and sent.keep_wifi == true, "attempt 1 keeps Wi-Fi on")
    assert_true(r.box.title == "Connection lost — reconnecting… (attempt 1)", "in flight: " .. r.box.title)
    for i, want in ipairs({ 4, 8, 15, 30, 30 }) do
        last_connect(sent)(false, "refused")
        assert_true(near(scheduled_delay(r._retry_task), want),
            string.format("after failure %d: %s, want %d", i, tostring(scheduled_delay(r._retry_task)), want))
        assert_true(r.box.title == string.format("Connection lost — reconnecting… (attempt %d, next in %d s)",
            i + 1, want), "title: " .. r.box.title)
        run_scheduled(r._retry_task)
        assert_true(#sent.connects == i + 1, "one connect per attempt")
    end
    last_connect(sent)(true)
    assert_true(not r:is_running() and r.box == nil, "the box closed")
    assert_true(count(function(w) return w.title and w.title:find("Connection lost", 1, true) end) == 0,
        "no box on the stack: " .. stack_desc())
    assert_true(sent.attaches == 1 and sent.keep_wifi == false, "attached, Wi-Fi duty handed back")
    assert_true(scheduled_delay(r._retry_task) == nil, "nothing left scheduled")
    close_viewer(app, remote)
end)

check("reconnect_close_and_back_disconnect_without_confirm", function()
    local Key = require("device/key")
    for _, how in ipairs({ "Back", "Close" }) do
        local app, remote, sent = new_app()
        local r = app.reconnect
        local disconnected = 0
        app.plugin.disconnect_session = function() disconnected = disconnected + 1 end
        app.plugin.show_connection_list = function() end
        app.session.state = "error"
        app:on_session_error("x")
        if how == "Back" then
            UIManager:sendEvent(Event:new("KeyPress", Key:new("Back", {})))
        else
            find_button(r.box, "Close").callback()
        end
        assert_true(disconnected == 1, how .. ": disconnected, got " .. disconnected)
        assert_true(not r:is_running() and scheduled_delay(r._retry_task) == nil, how .. ": loop stopped")
        assert_true(sent.keep_wifi == false, how .. ": Wi-Fi duty handed back")
        assert_true(count(function(w) return w.ok_callback end) == 0, how .. ": no confirmation: " .. stack_desc())
        close_viewer(app, remote)
    end
end)

check("quality_presets_map_and_match", function()
    local S = require("vnc/settings")
    local ids = {}
    for i, p in ipairs(S.QUALITY_PRESETS) do ids[i] = p.id end
    assert_true(table.concat(ids, ",") == "best,balanced,fast", "order: " .. table.concat(ids, ","))
    for _, p in ipairs(S.QUALITY_PRESETS) do
        assert_true(S.preset_of(p) == p.id, p.id .. " matches itself")
    end
    assert_true(S.preset_of{ color_depth = 24, enable_tight = false, jpeg_quality = false,
                             compress_level = false } == "best")
    assert_true(S.preset_of{ color_depth = 16, enable_tight = true, jpeg_quality = 5,
                             compress_level = 6 } == "custom")
end)

check("quality_preset_saves_only_after_a_successful_reconnect", function()
    local app, remote, sent = new_app()
    local r = app.reconnect
    app.plugin.show_connection_list = function() end
    local function pick_fast()
        local panel = app:open_display_panel()
        find_in_section(panel, QUALITY, "✓ Best")
        find_in_section(panel, QUALITY, "Fast").callback()
    end
    pick_fast()
    assert_true(sent.hangups == 1 and sent.keep_wifi == true, "hung up, Wi-Fi kept on")
    assert_true(app.display_panel == nil, "the panel closed")
    assert_true(r:is_running() and r.box.title == "Reconnecting…", "box: " .. tostring(r.box and r.box.title))
    assert_true(#sent.connects == 1, "one connect now")
    assert_true(app.session:get_profile().color_depth == 8, "the live profile carries the preset")
    assert_true(#sent.profile_updates == 0, "nothing saved yet")
    last_connect(sent)(false, "refused")
    assert_true(r.box.title:find("Connection lost", 1, true), "plain lost text: " .. r.box.title)
    assert_true(#sent.profile_updates == 0, "still nothing saved")
    r:close()
    assert_true(#sent.profile_updates == 0, "closing saves nothing")
    assert_true(app.session:get_profile().color_depth == 24, "the live profile is back to the stored values")
    pick_fast()
    assert_true(#sent.connects == 2, "second connect")
    last_connect(sent)(true)
    assert_true(#sent.profile_updates == 1, "saved after success")
    local f = sent.profile_updates[1].fields
    assert_true(f.color_depth == 8 and f.enable_tight == true and f.jpeg_quality == 3
        and f.compress_level == 9, "the Fast values")
    assert_true(app.session:get_profile().color_depth == 8, "the live profile keeps the preset")
    local panel = app:open_display_panel()
    find_in_section(panel, QUALITY, "✓ Fast")
    app:close_display_panel()
    close_viewer(app, remote)
end)

check("quality_custom_row_shows_for_a_profile_matching_no_preset", function()
    local app, remote = new_app()
    app.plugin.settings.get_profile().jpeg_quality = 5
    local panel = app:open_display_panel()
    assert_true(find_button(panel, "✓ Custom").enabled == false, "Custom is shown, disabled")
    find_in_section(panel, QUALITY, "Best")
    app:close_display_panel()
    close_viewer(app, remote)
end)

check("same_quality_preset_does_nothing", function()
    local app, remote, sent = new_app()
    local panel = app:open_display_panel()
    local before = #stack()
    find_in_section(panel, QUALITY, "✓ Best").callback()
    assert_true(sent.hangups == 0 and #sent.connects == 0, "no hangup, no connect")
    assert_true(not app.reconnect:is_running(), "no box")
    assert_true(app.display_panel ~= nil and #stack() == before, "the panel is untouched")
    app:close_display_panel()
    close_viewer(app, remote)
end)

check("reopening_on_an_error_session_waits_for_retry", function()
    local app, remote, sent = new_app(400, 300, { state = "error" })
    local r = app.reconnect
    app:onShow()
    assert_true(r:is_running() and r.box.title == "Connection lost", "title: " .. tostring(r.box and r.box.title))
    assert_true(count(function(w) return w == r.box end) == 1, "one box: " .. stack_desc())
    find_button(r.box, "Close")
    assert_true(scheduled_delay(r._retry_task) == nil and #sent.connects == 0, "no automatic retry")
    find_button(r.box, "Retry").callback()
    assert_true(#sent.connects == 1, "Retry connects now")
    last_connect(sent)(false, "refused")
    assert_true(near(scheduled_delay(r._retry_task), 4), "and the loop goes on by itself")
    find_button(r.box, "Retry now")
    close_viewer(app, remote)
end)

check("resume_retries_at_once_and_leaving_stops_the_loop", function()
    local app, remote, sent = new_app()
    local r = app.reconnect
    app.session.state = "error"
    app:on_session_error("x")
    run_scheduled(r._retry_task); last_connect(sent)(false)
    run_scheduled(r._retry_task); last_connect(sent)(false)
    assert_true(near(scheduled_delay(r._retry_task), 8), "waiting 8 s")
    assert_true(app:onResume() == nil, "Resume is not consumed")
    assert_true(#sent.connects == 3 and scheduled_delay(r._retry_task) == nil, "a connect now, timer cancelled")
    -- leaving with that attempt still on its way gives it up
    app.session.state = "connecting"
    app:onCloseWidget()
    assert_true(scheduled_count(r._retry_task) == 0 and not r:is_running(), "no timer survives the viewer")
    assert_true(sent.keep_wifi == false and sent.hangups == 1, "Wi-Fi duty handed back, the attempt hung up")
    last_connect(sent)(true)
    assert_true(sent.attaches == 0 and not r:is_running(), "its late callback is ignored")
    remote:free()
end)

check("a_drop_mid_drag_ends_it_and_reconnect_sends_nothing_stale", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    tap_toolbar(app, "keyboard")
    app:set_toolbar_visible(false)
    local strip = app.key_strip
    local log = wire_log(app)
    touch(strip, "mod:Ctrl")
    UIManager:forceRePaint()
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = 40, y = 30 }, relative = { x = 20, y = 10 } }
    touch(strip, "mod:Shift")
    assert_true(app:has_pointer_action() and strip:modifier_state("Shift") == "armed", "drag held, Shift armed")
    app:open_display_panel()
    app:open_help()
    app.session.state = "error"
    app:on_session_error("x")
    assert_true(not app:has_pointer_action(), "the drag ended")
    assert_true(not strip:has_armed(), "nothing armed")
    assert_true(app.help == nil and app.display_panel == nil, "the other popups closed")
    UIManager:_checkTasks()                    -- the keyboard makes way for the box
    assert_true(not app.vk_visible and top() == app.reconnect.box, "the box is on top: " .. stack_desc())
    log()
    run_scheduled(app.reconnect._retry_task)
    last_connect(sent)(true)
    assert_true(log() == "", "nothing stale sent after the reconnect")
    close_viewer(app, remote)
end)

--- Taps and long-presses every visible toolbar button where it sits, its actions replaced by a
--- recorder; `before_each` runs before each button's gestures. Returns the ids that fired.
local function toolbar_actions_fired(app, before_each)
    local fired = {}
    for _, id in ipairs(require("vnc/toolbar").IDS) do
        local b = app.toolbar.button_by_id[id]
        if b then
            local pos = toolbar_button_centre(app, id)
            before_each()
            local cb, hold = b.callback, b.hold_callback
            b.callback = function() fired[#fired + 1] = id end
            b.hold_callback = function() fired[#fired + 1] = id .. "(hold)" end
            dispatch_gesture{ ges = "tap", pos = pos }
            -- (a tap that reached what covers the bar may have closed it: cover it again)
            before_each()
            dispatch_gesture{ ges = "hold", pos = pos }
            dispatch_gesture{ ges = "hold_release", pos = pos }
            b.callback, b.hold_callback = cb, hold
        end
    end
    return table.concat(fired, ",")
end

check("toolbar_is_inert_under_the_menu", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    local log = wire_log(app)
    local fired = toolbar_actions_fired(app, function() if not app.menu then app:open_menu() end end)
    assert_true(fired == "", "toolbar actions fired under the menu: " .. fired)
    assert_true(log() == "", "nothing sent")
    app:close_menu()
    close_viewer(app, remote)
end)

check("toolbar_is_inert_under_the_reconnect_box", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    local r = app.reconnect
    local log = wire_log(app)
    app.session.state = "error"
    app:on_session_error("x")
    assert_true(r:is_running() and top() == r.box, "the box is up")
    local fired = toolbar_actions_fired(app, function() end)
    assert_true(fired == "", "toolbar actions fired under the box: " .. fired)
    -- and for real: ⋯ opens no menu, Mode keeps the mode and the live profile
    local live, mode = app.session:get_profile(), app:get_pointer_mode()
    tap_toolbar(app, "more")
    tap_toolbar(app, "mode")
    assert_true(app.menu == nil and top() == r.box, "no menu over the box: " .. stack_desc())
    assert_true(app:get_pointer_mode() == mode and app.session:get_profile() == live, "mode and profile kept")
    assert_true(#sent.profile_updates == 0 and log() == "", "nothing saved or sent")
    r:stop()
    close_viewer(app, remote)
end)

check("menu_reconnect_while_the_loop_runs_is_a_retry_now", function()
    local app, remote, sent = new_app()
    local r = app.reconnect
    local direct = {}
    app.plugin.connect_profile = function(_, name) direct[#direct + 1] = name end
    app.plugin.settings.profiles = function()
        return { { name = "test", host = "h", port = 1 }, { name = "other", host = "h", port = 2 } }
    end
    app.session.state = "error"
    app:on_session_error("x")
    find_item(app:open_menu().item_table, "Reconnect to test").callback()
    assert_true(#direct == 0, "no connect beside the loop")
    assert_true(#sent.connects == 1 and r:is_running()
        and r.box.title == "Connection lost — reconnecting… (attempt 1)", "the loop's attempt runs now")
    last_connect(sent)(false, "refused")
    local conns = find_item(app:open_menu().item_table, "Connections…").sub_item_table
    find_item(conns, "test").callback()
    assert_true(#direct == 0 and #sent.connects == 2, "the current profile's entry retries too")
    find_item(conns, "other").callback()
    assert_true(#direct == 1 and direct[1] == "other", "another profile connects as before")
    r:stop()
    close_viewer(app, remote)
end)

check("reconnect_attempt_on_a_live_session_succeeds", function()
    local app, remote, sent = new_app()
    local r = app.reconnect
    app.session.state = "error"
    app:on_session_error("x")
    -- connected meanwhile by some other route
    app.session.state = "connected"
    run_scheduled(r._retry_task)
    assert_true(not r:is_running() and r.box == nil, "the box closed: " .. stack_desc())
    assert_true(#sent.connects == 0 and sent.attaches == 1 and sent.keep_wifi == false,
        "no second connect, attached, Wi-Fi duty handed back")
    assert_true(scheduled_delay(r._retry_task) == nil, "nothing left scheduled")
    close_viewer(app, remote)
end)

check("show_opens_the_viewer_on_a_single_errored_session", function()
    local tmp_app, remote, sent = new_app()
    local session = tmp_app.session
    close_viewer(tmp_app, { free = function() end })
    UIManager:close(tmp_app)
    local saved = plugin.sessions
    local ok, err = pcall(function()
        session.state = "error"
        plugin.sessions = { test = session }
        plugin:show()
        assert_true(plugin.app ~= nil and plugin.app.session == session, "the viewer opened")
        assert_true(sent.attaches == 0, "an errored session is not attached")
        assert_true(plugin.app.reconnect:is_running() and plugin.app.reconnect.box.title == "Connection lost",
            "the manual box is up")
        plugin:_close_app_if(session)
        session.state = "connected"
        plugin:show()
        assert_true(plugin.app ~= nil and sent.attaches == 1, "a connected session is attached")
        assert_true(not plugin.app.reconnect:is_running(), "no box")
    end)
    if plugin.app then plugin:_close_app_if(plugin.app.session) end
    plugin.sessions = saved
    remote:free()
    assert_true(ok, tostring(err))
end)

check("key_popup_leaves_keyboard_and_view_alone", function()
    -- Long-pressing a letter opens KOReader's VirtualKeyPopup (modal, above us). It belongs to the
    -- keyboard: it must not hide it, re-fit the view, or let a tap through to the remote.
    local app, remote, sent = new_app(400, 300)
    app:set_keyboard_visible(true)
    UIManager:_checkTasks()
    UIManager:forceRePaint()
    assert_true(app.vk_visible, "keyboard up")
    local key
    local function walk(t, depth)
        if key or depth > 6 or type(t) ~= "table" then return end
        if t.key_chars and t.hold_callback and t.keyboard == app.vk then key = t return end
        for _, v in ipairs(t) do walk(v, depth + 1) end
    end
    walk(app.vk, 0)
    assert_true(key ~= nil, "found a key with extra characters")
    local scale, cx, cy, cw, ch = remote:get_scale(), app.canvas.x, app.canvas.y, app.canvas.w, app.canvas.h
    local areas, fulls = #sent.areas, sent.full_updates
    key.hold_callback()
    local popup = top()
    assert_true(popup and popup.parent_key == key and popup.modal, "the key popup is on top")
    UIManager:forceRePaint()
    for _ = 1, 3 do
        app:_sync_keyboard_later()
        UIManager:_checkTasks()
    end
    assert_true(app.vk_visible, "the popup must not hide the keyboard")
    assert_true(remote:get_scale() == scale and app.canvas.x == cx and app.canvas.y == cy
        and app.canvas.w == cw and app.canvas.h == ch, "nor change the view")
    assert_true(#sent.areas == areas and sent.full_updates == fulls, "nor re-request the remote")
    assert_true(not app:_input_target(), "the popup, not the viewer, is the input target")
    -- the toolbar and canvas stay inert, the popup closes on a tap outside, nothing reaches the remote
    local outside = Geom:new{ x = cx + 10, y = cy + 10 }
    dispatch_gesture{ ges = "hold", pos = outside }
    dispatch_gesture{ ges = "pan", pos = outside, relative = { x = 20, y = 0 } }
    assert_true(#sent.pointer == 0 and top() == popup, "hold and pan outside the popup do nothing")
    dispatch_gesture{ ges = "tap", pos = outside }
    assert_true(#sent.pointer == 0, "the tap that closes the popup sends no pointer event")
    assert_true(top() ~= popup, "a tap outside closes the popup")
    app:_sync_keyboard_later()
    UIManager:_checkTasks()
    assert_true(app.vk_visible and remote:get_scale() == scale and app.canvas.h == ch,
        "closing it leaves keyboard and view as they were")
    assert_true(#sent.areas == areas and sent.full_updates == fulls, "and does not re-request the remote")
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = cx + 10, y = cy + 10 } }
    assert_true(#sent.pointer > 0, "afterwards taps reach the remote again")
    app:set_keyboard_visible(false)
    close_viewer(app, remote)
end)

check("viewer_follows_the_keyboards_tap_interval", function()
    local Input = require("device").input
    local saved = G_reader_settings:readSetting("ges_tap_interval_ms")
    local saved_kb = G_reader_settings:readSetting("ges_tap_interval_on_keyboard_ms")
    G_reader_settings:saveSetting("ges_tap_interval_ms", 200)
    G_reader_settings:saveSetting("ges_tap_interval_on_keyboard_ms", 0)
    local time = require("ui/time")
    local function want() return time.ms(G_reader_settings:readSetting("ges_tap_interval_on_keyboard_ms", 0)) end
    local ok, err = pcall(function()
        local before = Input.tap_interval_override
        local app, remote = new_app(400, 300, { toolbar = true })
        assert_true(Input.tap_interval_override == want(), "viewer shown: " .. tostring(Input.tap_interval_override))
        app:toggle_toolbar(); app:toggle_toolbar()
        assert_true(Input.tap_interval_override == want(), "toolbar toggled")
        app:show_toast("hello", 1)
        assert_true(Input.tap_interval_override == want(), "toast shown")
        UIManager:close(top())
        assert_true(Input.tap_interval_override == want(), "toast closed")
        app:open_key_panel()
        assert_true(Input.tap_interval_override == want(), "key panel shown")
        app:close_key_panel()
        app:_show_key_strip()
        assert_true(Input.tap_interval_override == want(), "key strip shown")
        app:_drop_key_strip()
        -- a settings change applies to the next show
        G_reader_settings:saveSetting("ges_tap_interval_on_keyboard_ms", 50)
        app:show_toast("again", 1)
        assert_true(Input.tap_interval_override == want() and want() ~= 0, "setting change applies when shown")
        UIManager:close(top())
        G_reader_settings:saveSetting("ges_tap_interval_on_keyboard_ms", 0)
        close_viewer(app, remote)
        assert_true(Input.tap_interval_override == before, "closing restores what is beneath")
    end)
    G_reader_settings:saveSetting("ges_tap_interval_ms", saved)
    G_reader_settings:saveSetting("ges_tap_interval_on_keyboard_ms", saved_kb)
    if not ok then error(err, 0) end
end)

-- ---------------------------------------------------------------- hold confirmation

--[[ InkView (PocketBook) can withhold a touch's events for ~0.5 s and then deliver them in one
burst: GestureDetector's hold timer trips meanwhile, and the lift (and often a new contact that
pans) follows within milliseconds. These replay that with synthetic gestures and times. ]]

--- Whether any pointer event sent so far carried the right button.
local function no_right_button(sent)
    for _, e in ipairs(sent.pointer) do if e.mask == 4 then return false end end
    return true
end

local function hold_at(pos, t) dispatch_gesture{ ges = "hold", pos = Geom:new{ x = pos.x, y = pos.y }, time = t } end
local function hold_release_at(pos, t) dispatch_gesture{ ges = "hold_release", pos = Geom:new{ x = pos.x, y = pos.y }, time = t } end
local function pan_from(start, rx, ry, t)
    dispatch_gesture{ ges = "pan", pos = Geom:new{ x = start.x + rx, y = start.y + ry }, relative = { x = rx, y = ry }, time = t }
end

check("false_hold_burst_with_nothing_after_is_one_tap", function()
    for _, mode in ipairs{ "touch", "mouse" } do
        local app, remote, sent = new_app(400, 300, { mode = mode })
        local wire = wire_log(app)
        local c = app.canvas
        local P = Geom:new{ x = c.x + 60, y = c.y + 40 }
        local t0 = time.now()
        hold_at(P, t0)
        assert_true(wire() == "", mode .. ": a hold waits for its confirmation")
        local d = scheduled_delay(app._hold_confirm_task)
        assert_true(d and math.abs(d - app.HOLD_CONFIRM) <= 0.02, mode .. ": confirmed after HOLD_CONFIRM: " .. tostring(d))
        assert_true(math.abs(app.HOLD_CONFIRM - 0.12) < 1e-9, "HOLD_CONFIRM is 0.12 s")
        hold_release_at(P, t0 + time.ms(540))
        assert_true(scheduled_delay(app._hold_confirm_task) == nil, mode .. ": no confirmation any more")
        assert_true(wire() == "", mode .. ": a false hold waits a moment for a following contact")
        d = scheduled_delay(app._false_hold_task)
        assert_true(d and d > 0 and d <= 0.05 + 0.01, mode .. ": follow-up window: " .. tostring(d))
        run_scheduled(app._false_hold_task)
        if mode == "touch" then
            local rx, ry = app:_to_remote(P.x, P.y)
            assert_true(wire() == "p0,p1,p0", "touch: one left click")
            for _, e in ipairs(sent.pointer) do
                assert_true(e.x == rx and e.y == ry, string.format("at the hold position (%d,%d) vs (%d,%d)", e.x, e.y, rx, ry))
            end
            -- a tap right after snaps onto it like any Touch-mode double tap
            dispatch_gesture{ ges = "tap", pos = Geom:new{ x = P.x + 4, y = P.y }, time = t0 + time.ms(700) }
            assert_true(wire() == "p0,p1,p0" and last_pointer(sent).x == rx, "touch: the double-tap snap applies")
        else
            assert_true(wire() == "" and app._deferred_click ~= nil, "mouse: the click is deferred like a tap's")
            run_scheduled(app._deferred_click_task)
            assert_true(wire() == "p0,p1,p0", "mouse: one click")
        end
        assert_true(no_right_button(sent), mode .. ": never a right button")
        assert_true(app:has_pointer_action() == false, mode .. ": nothing held")
        close_viewer(app, remote)
    end
end)

check("false_hold_burst_then_pan_is_one_drag_from_the_hold", function()
    local app, remote, sent = new_app(400, 300)
    local wire = wire_log(app)
    local c = app.canvas
    local P = Geom:new{ x = c.x + 60, y = c.y + 40 }
    local t0 = time.now()
    hold_at(P, t0)
    hold_release_at(P, t0 + time.ms(528))
    -- the new contact landed a few pixels away and pans, all in the same burst
    local S = Geom:new{ x = P.x + 3, y = P.y + 2 }
    pan_from(S, 20, 0, t0 + time.ms(529))
    assert_true(scheduled_delay(app._false_hold_task) == nil, "the follow-up is settled")
    local got = wire()
    assert_true(got == "p1,p1", "a press then a drag move: " .. got)
    local rx, ry = app:_to_remote(P.x, P.y)
    assert_true(sent.pointer[1].x == rx and sent.pointer[1].y == ry, "pressed at the original hold position")
    local mx, my = app:_to_remote(S.x + 20, S.y)
    assert_true(sent.pointer[2].x == mx and sent.pointer[2].y == my, "then follows the finger")
    pan_from(S, 40, 10, t0 + time.ms(560))
    assert_true(wire() == "p1", "the drag goes on")
    dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = S.x + 40, y = S.y + 10 } }
    assert_true(wire() == "p0", "released")
    assert_true(no_right_button(sent), "never a right button")
    assert_true(app:has_pointer_action() == false)
    close_viewer(app, remote)
end)

check("false_hold_burst_then_a_tap_is_that_one_tap", function()
    for _, mode in ipairs{ "touch", "mouse" } do
        local app, remote, sent = new_app(400, 300, { mode = mode })
        local wire = wire_log(app)
        local c = app.canvas
        local P = Geom:new{ x = c.x + 60, y = c.y + 40 }
        local t0 = time.now()
        hold_at(P, t0)
        hold_release_at(P, t0 + time.ms(530))
        dispatch_gesture{ ges = "tap", pos = Geom:new{ x = P.x + 3, y = P.y }, time = t0 + time.ms(531) }
        assert_true(scheduled_delay(app._false_hold_task) == nil, mode .. ": the follow-up is settled")
        if mode == "mouse" then run_scheduled(app._deferred_click_task) end
        local got = wire()
        assert_true(got == "p0,p1,p0", mode .. ": exactly one click: " .. got)
        assert_true(no_right_button(sent))
        close_viewer(app, remote)
    end
end)

check("genuine_hold_confirms_then_right_clicks", function()
    for _, mode in ipairs{ "touch", "mouse" } do
        local app, remote, sent = new_app(400, 300, { mode = mode })
        local wire = wire_log(app)
        local c = app.canvas
        local P = Geom:new{ x = c.x + 60, y = c.y + 40 }
        local t0 = time.now()
        hold_at(P, t0)
        run_scheduled(app._hold_confirm_task)
        assert_true(wire() == "p4", mode .. ": right press once confirmed")
        hold_release_at(P, t0 + time.ms(1100))
        assert_true(wire() == "p0", mode .. ": released")
        local rx, ry = app:_to_remote(P.x, P.y)
        if mode == "mouse" then rx, ry = 200, 150 end
        for _, e in ipairs(sent.pointer) do assert_true(e.x == rx and e.y == ry, mode .. ": where it should be") end
        assert_true(scheduled_delay(app._false_hold_task) == nil, mode .. ": nothing else pending")
        assert_true(app:has_pointer_action() == false)
        close_viewer(app, remote)
    end
end)

check("hold_pan_before_confirmation_is_a_genuine_hold", function()
    local app, remote, sent = new_app(400, 300)
    local wire = wire_log(app)
    local c = app.canvas
    local P = Geom:new{ x = c.x + 60, y = c.y + 40 }
    hold_at(P, time.now())
    dispatch_gesture{ ges = "hold_pan", pos = Geom:new{ x = P.x + 8, y = P.y }, relative = { x = 8, y = 0 } }
    assert_true(wire() == "p4", "touch: right press at once")
    assert_true(scheduled_delay(app._hold_confirm_task) == nil, "no confirmation left")
    hold_release_at(P)
    assert_true(wire() == "p0", "released")
    close_viewer(app, remote)
    -- Mouse mode, tap then hold: the button drag, moved by the hold_pan
    app, remote, sent = new_app(400, 300, { mode = "mouse" })
    wire = wire_log(app)
    c = app.canvas
    P = Geom:new{ x = c.x + 60, y = c.y + 40 }
    dispatch_gesture{ ges = "tap", pos = P }
    hold_at(Geom:new{ x = P.x + 4, y = P.y }, time.now())
    assert_true(wire() == "" and app._deferred_click ~= nil, "mouse: the tap still waits")
    dispatch_gesture{ ges = "hold_pan", pos = Geom:new{ x = P.x + 40, y = P.y }, relative = { x = 40, y = 0 } }
    local got = wire()
    assert_true(got == "p1,p1", "mouse: a left press, then the move: " .. got)
    hold_release_at(Geom:new{ x = P.x + 40, y = P.y })
    assert_true(wire() == "p0" and no_right_button(sent), "mouse: released, no right button")
    assert_true(app._deferred_click == nil, "the tap's click is gone")
    close_viewer(app, remote)
end)

check("mouse_tap_then_false_hold_burst_and_pan_drags_with_the_button", function()
    local app, remote, sent = new_app(400, 300, { mode = "mouse" })
    local wire = wire_log(app)
    local c = app.canvas
    local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
    dispatch_gesture{ ges = "tap", pos = P }
    local lift = finger_down(P)
    run_scheduled(app._deferred_click_task) -- (the finger is down: it waits)
    local t0 = time.now()
    hold_at(Geom:new{ x = P.x + 2, y = P.y }, t0)
    -- the deferred click falling due while the hold is unconfirmed still waits
    lift()
    run_scheduled(app._deferred_click_task)
    assert_true(wire() == "" and app._deferred_click ~= nil, "nothing sent yet, the tap still pending")
    hold_release_at(Geom:new{ x = P.x + 2, y = P.y }, t0 + time.ms(1))
    pan_from(Geom:new{ x = P.x + 5, y = P.y }, 30, 0, t0 + time.ms(2))
    local got = wire()
    assert_true(got == "p1,p1", "a button drag from the pointer: " .. got)
    assert_true(sent.pointer[1].x == 200 and sent.pointer[1].y == 150, "pressed at the pointer")
    dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = P.x + 35, y = P.y } }
    assert_true(wire() == "p0", "released")
    assert_true(no_right_button(sent), "never a right button")
    assert_true(app._deferred_click == nil and scheduled_delay(app._deferred_click_task) == nil, "no click left over")
    close_viewer(app, remote)
    -- without a pending tap the same burst only moves the pointer
    app, remote, sent = new_app(400, 300, { mode = "mouse" })
    wire = wire_log(app)
    c = app.canvas
    P = Geom:new{ x = c.x + 50, y = c.y + 50 }
    hold_at(P, t0)
    hold_release_at(P, t0 + time.ms(1))
    pan_from(Geom:new{ x = P.x + 5, y = P.y }, 30, 0, t0 + time.ms(2))
    dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = P.x + 35, y = P.y } }
    got = wire()
    assert_true(got == "p0", "a pointer move only: " .. got)
    assert_true(no_right_button(sent) and app._deferred_click == nil)
    close_viewer(app, remote)
end)

check("pending_hold_ends_cleanly_when_the_gesture_goes_elsewhere", function()
    local cases = {
        close = function(app, remote) close_viewer(app, remote) end,
        mode_switch = function(app) app:set_pointer_mode("mouse") end,
        two_finger = function(app, _, P) two_finger_pan(P, 30, 0) end,
        swipe = function(app, _, P) dispatch_gesture{ ges = "swipe", pos = P, direction = "east", distance = 100 } end,
        menu = function(app) app:open_menu(); app:close_menu() end,
    }
    for name, act in pairs(cases) do
        for _, phase in ipairs{ "pending", "released" } do
            local app, remote, sent = new_app(400, 300)
            local c = app.canvas
            local P = Geom:new{ x = c.x + 60, y = c.y + 40 }
            local t0 = time.now()
            hold_at(P, t0)
            if phase == "released" then hold_release_at(P, t0 + time.ms(1)) end
            act(app, remote, P)
            assert_true(scheduled_delay(app._hold_confirm_task) == nil
                and scheduled_delay(app._false_hold_task) == nil, name .. "/" .. phase .. ": nothing left scheduled")
            app._hold_confirm_task(); app._false_hold_task()
            assert_true(#sent.pointer == 0, name .. "/" .. phase .. ": nothing sent, got " .. #sent.pointer)
            assert_true(app:has_pointer_action() == false, name .. "/" .. phase .. ": nothing held")
            if name ~= "close" then close_viewer(app, remote) end
        end
    end
end)

check("hold_confirmation_decisions_are_logged", function()
    local logger = require("logger")
    local lines = {}
    local dbg = logger.dbg
    logger.dbg = function(tag, ...)
        if tag == "vnc-hold:" then lines[#lines + 1] = table.concat({ ... }, " ") end
        return dbg(tag, ...)
    end
    local ok, err = pcall(function()
        local app, remote = new_app(400, 300)
        local c = app.canvas
        local P = Geom:new{ x = c.x + 60, y = c.y + 40 }
        hold_at(P, time.now()); hold_release_at(P); run_scheduled(app._false_hold_task)
        hold_at(P, time.now()); run_scheduled(app._hold_confirm_task); hold_release_at(P)
        close_viewer(app, remote)
    end)
    logger.dbg = dbg
    if not ok then error(err, 0) end
    local all = table.concat(lines, "|")
    assert_true(all:find("false hold", 1, true) and all:find("confirmed", 1, true), "logged: " .. all)
end)

-- ---------------------------------------------------------------- matching the remote's orientation

check("orientation_settings_default_and_clean", function()
    local Settings = require("vnc/settings")
    local path = data_dir .. "/ui_smoke_orientation.lua"; os.remove(path)
    local f = assert(io.open(path, "w"))
    f:write('return { settings = { landscape_orientation = 7, portrait_orientation = "x" } }')
    f:close()
    local s = Settings.open(path)
    local st = s.data.settings
    assert_true(st.match_orientation == true, "matching is on by default")
    assert_true(st.landscape_orientation == 1, "an out-of-range mode cleans to the default: " .. tostring(st.landscape_orientation))
    assert_true(st.portrait_orientation == 0, "junk cleans to upright: " .. tostring(st.portrait_orientation))
    os.remove(path)
end)

--- A viewer on a remote of `w`x`h`, opened on the upright (portrait) screen with matching on;
--- `rotations` counts the screen rotations from here on.
local function orient_app(w, h, settings)
    Screen:setRotationMode(0)
    UIManager:onRotation()
    assert_true(Screen:getWidth() < Screen:getHeight(), "the test screen is portrait upright")
    local app, remote, sent = new_app(w, h)
    app:onScreenResize(Screen:getSize())
    app.settings.match_orientation = true
    for k, v in pairs(settings or {}) do app.settings[k] = v end
    local log = { n = 0 }
    local real = Screen.setRotationMode
    log.restore = function() Screen.setRotationMode = real end
    Screen.setRotationMode = function(s_, mode) log.n = log.n + 1; return real(s_, mode) end
    return app, remote, sent, log
end

local function orient_done(app, remote, log)
    app:restore_rotation()
    log.restore()
    Screen:setRotationMode(0)
    UIManager:onRotation()
    close_viewer(app, remote)
end

check("orientation_landscape_remote_on_portrait_screen_rotates_once", function()
    -- the remembered orientation (upside down) and the match both apply at open: one rotation
    local app, remote, _, log = orient_app(400, 300, { orientation = 2 })
    app:apply_default_orientation()
    assert_true(Screen:getRotationMode() == 1, "landscape, KOReader's default side: " .. Screen:getRotationMode())
    assert_true(log.n == 1, "one rotation, got " .. log.n)
    assert_true(Screen:getWidth() > Screen:getHeight(), "the screen is landscape")
    assert_true(app.canvas.w == Screen:getWidth() and app.canvas.h == Screen:getHeight(), "the canvas follows")
    assert_true(app.settings.orientation == 2, "the manual choice is not overwritten")
    orient_done(app, remote, log)
end)

check("orientation_same_shape_square_or_off_does_nothing", function()
    for _, case in ipairs{ { 300, 400, true, "portrait" }, { 300, 300, true, "square" },
                           { 400, 300, false, "off" } } do
        local app, remote, _, log = orient_app(case[1], case[2], { match_orientation = case[3] })
        app:apply_default_orientation()
        assert_true(Screen:getRotationMode() == 0 and log.n == 0, case[4] .. ": no rotation, mode "
            .. Screen:getRotationMode())
        orient_done(app, remote, log)
    end
end)

check("orientation_uses_the_remembered_landscape_side", function()
    local app, remote, _, log = orient_app(300, 400)
    -- a hand-picked rotation remembers its side, per orientation
    app:choose_rotation(3)
    assert_true(app.settings.orientation == 3 and app.settings.landscape_orientation == 3, "landscape side kept")
    app:choose_rotation(2)
    assert_true(app.settings.orientation == 2 and app.settings.portrait_orientation == 2, "portrait side kept")
    app:choose_rotation(0)
    orient_done(app, remote, log)
    app, remote, _, log = orient_app(400, 300, { landscape_orientation = 3 })
    app:apply_default_orientation()
    assert_true(Screen:getRotationMode() == 3, "the remembered landscape side: " .. Screen:getRotationMode())
    orient_done(app, remote, log)
end)

check("orientation_manual_rotate_survives_a_same_shape_reconnect", function()
    local app, remote, sent, log = orient_app(400, 300)
    app:apply_default_orientation()
    assert_true(Screen:getRotationMode() == 1, "matched at open")
    app:choose_rotation(0)
    local r = app.reconnect
    app.session.state = "error"
    app:on_session_error("x")
    run_scheduled(r._retry_task)
    app.session.state = "connected"
    last_connect(sent)(true)
    assert_true(not r:is_running(), "reconnected")
    assert_true(Screen:getRotationMode() == 0, "the hand-picked portrait stays: " .. Screen:getRotationMode())
    -- a reconnect to a remote of the other orientation does rotate
    app:choose_rotation(1)
    app.session.state = "error"
    app:on_session_error("x")
    run_scheduled(r._retry_task)
    remote:resize(300, 400)
    app.session.state = "connected"
    last_connect(sent)(true)
    assert_true(Screen:getRotationMode() == 0, "portrait remote after the reconnect: " .. Screen:getRotationMode())
    orient_done(app, remote, log)
end)

check("orientation_desktop_resize_to_the_other_orientation_rotates", function()
    local app, remote, _, log = orient_app(400, 300)
    app:apply_default_orientation()
    assert_true(Screen:getRotationMode() == 1, "matched at open")
    remote:resize(600, 800)
    app:on_remote_resized(600, 800)
    assert_true(Screen:getRotationMode() == 0, "portrait now: " .. Screen:getRotationMode())
    assert_true(app.canvas.w == Screen:getWidth() and app.canvas.h == Screen:getHeight(), "the canvas follows")
    -- the same shape again changes nothing, after a hand-picked rotation either
    app:choose_rotation(1)
    remote:resize(300, 400)
    app:on_remote_resized(300, 400)
    assert_true(Screen:getRotationMode() == 1, "same shape: kept " .. Screen:getRotationMode())
    orient_done(app, remote, log)
end)

check("orientation_leaving_restores_the_mode_from_before", function()
    local app, remote, _, log = orient_app(400, 300)
    app:apply_default_orientation()
    assert_true(Screen:getRotationMode() == 1, "matched at open")
    local saved_app = plugin.app
    plugin.app = app
    plugin:leave_app()
    plugin.app = saved_app
    assert_true(Screen:getRotationMode() == 0, "back to upright: " .. Screen:getRotationMode())
    orient_done(app, remote, log)
end)

check("orientation_match_menu_switch_and_help", function()
    local MATCH = "Match orientation to the remote screen"
    local Screen_mode = Screen:getRotationMode()
    local app, remote = new_app()
    app.settings.match_orientation = true
    local flushed = 0
    app.plugin.settings.flush = function() flushed = flushed + 1 end
    local menu = app:open_menu()
    local keep, match
    for i, item in ipairs(menu.item_table) do
        if item.text == "Keep screen on" then keep = i end
        if item.text == MATCH then match = i end
    end
    assert_true(match and keep and match == keep + 1, "right after Keep screen on: " .. tostring(match))
    assert_true(menu.item_table[match].mandatory == "\u{2713}", "checked while on")
    menu:onMenuSelect(menu.item_table[match])
    UIManager:_checkTasks()
    app:close_menu()
    assert_true(app.settings.match_orientation == false and flushed == 1, "toggled off and persisted")
    assert_true(Screen:getRotationMode() == Screen_mode, "toggling turns nothing")
    menu = app:open_menu()
    assert_true(find_item(menu.item_table, MATCH).mandatory == "-", "unchecked while off")
    app:close_menu()
    assert_true(require("vnc/help").text("touch"):find(MATCH, 1, true), "the help names it")
    close_viewer(app, remote)
end)


check("toolbar_corners_are_round_not_covered_by_buttons", function()
    -- the square buttons must not paint white over the rounded border's corners (bar and round button)
    local BBc = require("ffi/blitbuffer")
    local app, remote = new_app()
    local function corner_pixels()
        local d = app.toolbar.dimen
        local canvas = BBc.new(Screen:getWidth(), Screen:getHeight(), BBc.TYPE_BB8)
        canvas:fill(BBc.COLOR_BLACK)
        app.toolbar:paintTo(canvas, 0, 0)
        local out = {}
        -- just inside the border's rectangle, which a rounded corner leaves outside the shape
        local b = require("ui/size").border.window
        local l, t, r, btm = d.x + b, d.y + b, d.x + d.w - 1 - b, d.y + d.h - 1 - b
        for _, p in ipairs({ { l, t }, { r, t }, { l, btm }, { r, btm } }) do
            out[#out + 1] = canvas:getPixel(p[1], p[2]):getColor8().a
        end
        canvas:free()
        return out
    end
    for _, collapsed in ipairs({ false, true }) do
        app:set_toolbar_collapsed(collapsed)
        UIManager:forceRePaint()
        for i, v in ipairs(corner_pixels()) do
            assert_true(v == 0, string.format("%s: corner %d left alone, got %d",
                collapsed and "round button" or "bar", i, v))
        end
    end
    app:set_toolbar_collapsed(false)
    close_viewer(app, remote)
end)

check("key_panel_hotkeys_send_exactly_their_combo", function()
    local app, remote, sent = new_app()
    local panel = open_key_panel(app)
    pick_tab(panel, 2)
    local want = {
        { "Z", "+0xFFE3,+0x7A,-0x7A,-0xFFE3" }, { "X", "+0xFFE3,+0x78,-0x78,-0xFFE3" },
        { "C", "+0xFFE3,+0x63,-0x63,-0xFFE3" }, { "V", "+0xFFE3,+0x76,-0x76,-0xFFE3" },
        { "A", "+0xFFE3,+0x61,-0x61,-0xFFE3" }, { "S", "+0xFFE3,+0x73,-0x73,-0xFFE3" },
        { "F", "+0xFFE3,+0x66,-0x66,-0xFFE3" }, { "W", "+0xFFE3,+0x77,-0x77,-0xFFE3" },
        { "Tab", "+0xFFE9,+0xFF09,-0xFF09,-0xFFE9" }, { "F4", "+0xFFE9,+0xFFC1,-0xFFC1,-0xFFE9" },
        { "L", "+0xFFEB,+0x6C,-0x6C,-0xFFEB" }, { "Del", "+0xFFE3,+0xFFE9,+0xFFFF,-0xFFFF,-0xFFE9,-0xFFE3" },
    }
    local count_hotkeys = 0
    for id in pairs(panel.button_by_id) do
        if id:sub(1, 7) == "hotkey:" then count_hotkeys = count_hotkeys + 1 end
    end
    assert_true(count_hotkeys == #want, "12 hotkeys, got " .. count_hotkeys)
    assert_true(panel.button_by_id["hotkey:L"].text == "Lock (Super+L)", "the lock one says what it does")
    for _, w in ipairs(want) do
        touch(panel, "hotkey:" .. w[1])
        local got = take_keys(sent)
        assert_true(got == w[2], w[1] .. " must send " .. w[2] .. ", got " .. got)
    end
    -- an armed modifier is not added, and is cleared
    touch(panel, "mod:Shift")
    touch(panel, "hotkey:C")
    assert_true(take_keys(sent) == "+0xFFE3,+0x63,-0x63,-0xFFE3" and panel:modifier_state("Shift") == nil,
        "sent exactly, Shift cleared")
    assert_true(panel.button_by_id["recent:1"].text == "Ctrl+C", "remembered as Ctrl+C")
    close_viewer(app, remote)
end)

check("toolbar_pinned_buttons_stay_when_collapsed", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    local has = Device.hasFrontlight
    local ok, err = pcall(function()
        Device.hasFrontlight = function() return true end
        app.toolbar:relayout()
        local function collapsed_rows(menu)
            return find_item(find_item(menu.item_table, "Toolbar buttons…").sub_item_table,
                "Also when collapsed…").sub_item_table
        end
        local menu = app:open_menu()
        local rows = collapsed_rows(menu)
        local texts = {}
        for _, r in ipairs(rows) do texts[#texts + 1] = r.text end
        assert_true(table.concat(texts, "|") == "Display|Zoom|Mode|Keyboard|Rotate|Scroll lock|Scroll up/down|"
            .. "Brightness|Contrast|More", table.concat(texts, "|"))
        for _, r in ipairs(rows) do
            local on = r.text == "Keyboard" or r.text == "Scroll lock"
            assert_true(r.mandatory == (on and "\u{2713}" or "-"), r.text .. ": default " .. tostring(on))
        end
        app:close_menu()
        -- by default: the expand button, Keyboard and Scroll lock
        app:set_toolbar_collapsed(true)
        local b = app.toolbar.button_by_id
        assert_true(b.toggle and b.keyboard and b.scroll_lock and b.display == nil and b.more == nil,
            "expand + keyboard + scroll lock by default")
        app:set_toolbar_collapsed(false)
        -- nothing pinned: collapsing leaves the round button alone
        app.settings.toolbar_pinned = { keyboard = false, scroll_lock = false }
        app:set_toolbar_collapsed(true)
        local round = app.toolbar.dimen
        assert_true(round.w == round.h and app.toolbar.button_by_id.keyboard == nil, "the round button alone")
        -- pin Keyboard: the collapsed toolbar is the expand button and the keyboard button
        menu = app:open_menu()
        local kb = find_item(collapsed_rows(menu), "Keyboard")
        menu:onMenuSelect(kb)
        UIManager:_checkTasks()
        assert_true(app.menu == menu and kb.mandatory == "\u{2713}", "the row stays open and is checked")
        assert_true(app.settings.toolbar_pinned.keyboard == true, "stored")
        app:close_menu()
        local bar = app.toolbar
        assert_true(bar.collapsed and bar.button_by_id.toggle and bar.button_by_id.keyboard
            and bar.button_by_id.display == nil and bar.button_by_id.more == nil, "expand + keyboard")
        assert_true(bar.dimen.w > bar.dimen.h, "a short bar now")
        -- its keyboard button works, sends nothing to the remote; its first button expands
        UIManager:forceRePaint()
        local before = #sent.pointer
        dispatch_gesture{ ges = "tap", pos = centre_of(bar.button_by_id.keyboard.dimen) }
        UIManager:_checkTasks()
        assert_true(app.vk_visible and #sent.pointer == before, "the keyboard came up, nothing sent")
        app:toggle_keyboard()
        UIManager:_checkTasks()
        UIManager:forceRePaint()
        dispatch_gesture{ ges = "tap", pos = centre_of(app.toolbar.button_by_id.toggle.dimen) }
        UIManager:_checkTasks()
        assert_true(not app.toolbar.collapsed and app.toolbar.button_by_id.more ~= nil, "expanded")
        -- a pinned button hidden from the toolbar is not on the collapsed one either, and its row is grey
        app.settings.toolbar_buttons = { keyboard = false }
        app:set_toolbar_collapsed(true)
        app:_toolbar_changed()
        assert_true(app.toolbar.button_by_id.keyboard == nil and app.toolbar.dimen.w == app.toolbar.dimen.h,
            "hidden from the bar: back to the round button")
        menu = app:open_menu()
        kb = find_item(collapsed_rows(menu), "Keyboard")
        assert_true(kb.dim and kb.select_enabled_func() == false, "greyed out while off on the toolbar")
        app:close_menu()
        app.settings.toolbar_buttons = nil
        app.settings.toolbar_pinned = nil
        app:set_toolbar_collapsed(false)
        -- the setting only keeps known ids, all false unless true
        local Settings = require("vnc/settings")
        assert_true(Settings.TOOLBAR_PINNABLE[#Settings.TOOLBAR_PINNABLE] == "more", "More can be pinned")
    end)
    Device.hasFrontlight = has
    assert_true(ok, tostring(err))
    close_viewer(app, remote)
end)

check("menu_submenus_have_a_back_button", function()
    local app, remote = new_app()
    local menu = app:open_menu()
    UIManager:forceRePaint()
    local arrow = menu.page_return_arrow
    assert_true(arrow ~= nil and arrow.hidden, "no back button at the top level")
    menu:onMenuSelect(find_item(menu.item_table, "Toolbar buttons…"))
    menu:onMenuSelect(find_item(menu.item_table, "On the toolbar…"))
    UIManager:forceRePaint()
    assert_true(not menu.page_return_arrow.hidden and menu.page_return_arrow.enabled, "shown and enabled in a submenu")
    menu.page_return_arrow.callback()
    assert_true(app.menu == menu and find_item(menu.item_table, "Also when collapsed…") ~= nil, "back one level")
    menu.page_return_arrow.callback()
    assert_true(app.menu == menu and find_item(menu.item_table, "Toolbar buttons…") ~= nil, "back at the top")
    UIManager:forceRePaint()
    assert_true(menu.page_return_arrow.hidden, "and hidden again")
    app:close_menu()
    close_viewer(app, remote)
end)

check("menu_false_hold_is_a_tap", function()
    -- the device's late burst: hold, then its release a few ms later -> a tap on the row
    local app, remote = new_app()
    local menu = app:open_menu()
    UIManager:forceRePaint()
    local now = 0
    menu.clock = function() return now end
    local time = require("ui/time")
    local function row_pos(text)
        for _, w in ipairs(menu.item_group) do
            if w.entry and w.entry.text == text then return centre_of(w.dimen) end
        end
    end
    local pos = row_pos("Toolbar buttons…")
    assert_true(pos ~= nil, "the row is on screen")
    dispatch_gesture{ ges = "hold", pos = pos }
    now = now + time.ms(15)
    dispatch_gesture{ ges = "hold_release", pos = pos }
    UIManager:_checkTasks()
    assert_true(app.menu == menu and find_item(menu.item_table, "On the toolbar…") ~= nil, "the submenu opened")
    -- a genuine long press shows the help text and selects nothing
    UIManager:forceRePaint()
    pos = row_pos("On the toolbar…")
    dispatch_gesture{ ges = "hold", pos = pos }
    now = now + time.ms(600)
    dispatch_gesture{ ges = "hold_release", pos = pos }
    UIManager:_checkTasks()
    local info = top()
    assert_true(info ~= menu and info.text and info.text:find("Close and More", 1, true), "its help shows")
    UIManager:close(info)
    assert_true(find_item(menu.item_table, "On the toolbar…") ~= nil, "nothing was opened")
    app:close_menu()
    close_viewer(app, remote)
end)

-- ---------------------------------------------------------------- click and type

--[[ Drags the keyboard icon off the toolbar's Keyboard button to `to`: `steps` pans (3 by default),
then a pan_release, or with `swipe` a swipe that ends there (a flick without pans: steps = 0).
`mid(i)` runs after each pan. ]]
local function drag_keyboard_icon(app, to, opts)
    opts = opts or {}
    local from = toolbar_button_centre(app, "keyboard")
    local sp = Geom:new{ x = from.x, y = from.y, w = 0, h = 0 }
    local dx, dy = to.x - from.x, to.y - from.y
    local steps = opts.steps or 3
    for i = 1, steps do
        local rx, ry = math.floor(dx * i / steps), math.floor(dy * i / steps)
        dispatch_gesture{ ges = "pan", relative = { x = rx, y = ry }, start_pos = sp,
                          pos = Geom:new{ x = from.x + rx, y = from.y + ry, w = 0, h = 0 } }
        if opts.mid then opts.mid(i, Geom:new{ x = from.x + rx, y = from.y + ry, w = 0, h = 0 }) end
    end
    if opts.swipe then
        dispatch_gesture{ ges = "swipe", direction = dy >= 0 and "south" or "north", distance = math.abs(dy), pos = sp,
                          end_pos = Geom:new{ x = to.x, y = to.y, w = 0, h = 0 } }
    else
        dispatch_gesture{ ges = "pan_release", pos = Geom:new{ x = to.x, y = to.y, w = 0, h = 0 } }
    end
    UIManager:_checkTasks()
end

--- Whether every pointer event in `list` is at `x, y`.
local function all_at(list, x, y)
    for _, e in ipairs(list) do if e.x ~= x or e.y ~= y then return false end end
    return #list > 0
end

check("keyboard_button_drag_clicks_where_dropped_and_shows_the_keyboard", function()
    for _, mode in ipairs{ "touch", "mouse" } do
        for _, how in ipairs{ "pan", "swipe", "flick" } do
            local what = mode .. "/" .. how
            local app, remote, sent = new_app(400, 300, { toolbar = true, mode = mode })
            local wire = wire_log(app)
            local c = app:canvas_geom()
            local bar = app.toolbar.dimen
            local P = Geom:new{ x = c.x + math.floor(c.w / 3), y = c.y + math.floor(c.h / 2) }
            local rx, ry = app:_to_remote(P.x, P.y)
            local refreshes = {}
            local real_dirty = UIManager.setDirty
            UIManager.setDirty = function(self_, w, m, ...)
                if w == app and type(m) == "function" then refreshes[#refreshes + 1] = (m()) end
                return real_dirty(self_, w, m, ...)
            end
            drag_keyboard_icon(app, P, { swipe = how ~= "pan", steps = how == "flick" and 0 or 3,
                mid = function(i, at)
                    assert_true(wire() == "", what .. ": nothing sent mid-drag")
                    local icon = app.toolbar.drag_icon
                    assert_true(icon and icon.dimen:contains(Geom:new{ x = at.x, y = at.y, w = 0, h = 0 }),
                        what .. ": the icon follows the finger")
                    assert_true(refreshes[#refreshes] == "fast", what .. ": fast while it moves")
                    assert_true(not app.vk_visible, what .. ": no keyboard yet")
                end })
            UIManager.setDirty = real_dirty
            local saw_ui = false
            for _, m in ipairs(refreshes) do if m == "ui" then saw_ui = true end end
            -- (a flick showed no icon: nothing to repaint)
            assert_true(saw_ui == (how ~= "flick"), what .. ": ui on release")
            for _, m in ipairs(refreshes) do assert_true(m == "fast" or m == "ui", what .. ": no other refresh: " .. m) end
            assert_true(app.toolbar.drag_icon == nil and not app.toolbar:is_dragging(), what .. ": the icon is gone")
            local got = wire()
            assert_true(got == "p0,p1,p0", what .. ": one click, got " .. got)
            assert_true(all_at({ sent.pointer[#sent.pointer - 2], sent.pointer[#sent.pointer - 1],
                last_pointer(sent) }, rx, ry), what .. ": at the drop point")
            if mode == "mouse" then
                local mx, my = app:_mouse_pointer_px()
                assert_true(mx == rx and my == ry, what .. ": the pointer stays there")
            end
            assert_true(app.vk_visible and keyboard_on_stack(app) and app.settings.keyboard_shown == true,
                what .. ": the keyboard came up and was saved")
            assert_true(app.toolbar.dimen.x == bar.x and app.toolbar.dimen.y == bar.y, what .. ": the bar did not move")
            assert_true(not app:has_pointer_action(), what .. ": nothing held")
            close_viewer(app, remote)
        end
    end
end)

check("keyboard_button_drag_with_the_keyboard_up_only_clicks", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    app:set_keyboard_visible(true)
    -- (the strip's armed modifiers go with the click, as with a tap)
    app.key_strip:tap_modifier("Ctrl")
    local wire = wire_log(app)
    local c = app:canvas_geom()
    local P = Geom:new{ x = c.x + 40, y = c.y + math.floor(c.h / 2) }
    drag_keyboard_icon(app, P)
    local got = wire()
    assert_true(got == "+0xFFE3,p0,p1,p0,-0xFFE3", "Ctrl around one click, got " .. got)
    assert_true(app.vk_visible and app.settings.keyboard_shown == true, "the keyboard stays up")
    -- with the Send keys panel in its place: the click, and the panel stays
    open_key_panel(app)
    drag_keyboard_icon(app, Geom:new{ x = 40, y = app.key_panel.dimen.y - 20 })
    assert_true(wire() == "p0,p1,p0" and app.key_panel ~= nil and not app.vk_visible, "the panel stays")
    close_viewer(app, remote)
end)

check("keyboard_button_drag_dropped_elsewhere_does_nothing", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    local wire = wire_log(app)
    local bar = app.toolbar.dimen
    -- back on the bar
    drag_keyboard_icon(app, toolbar_button_centre(app, "zoom"))
    assert_true(wire() == "" and not app.vk_wanted and app.settings.keyboard_shown == false, "on the bar: nothing")
    assert_true(app.toolbar.dimen.x == bar.x and app.toolbar.dimen.y == bar.y and app.toolbar.drag_icon == nil,
        "the bar stays, the icon is gone")
    assert_true(app:view_state() == "fit", "the button under the drop did not act")
    -- over the keyboard (and the strip)
    app:set_keyboard_visible(true)
    local H = Screen:getHeight()
    drag_keyboard_icon(app, Geom:new{ x = 50, y = H - 10 })
    drag_keyboard_icon(app, Geom:new{ x = 50, y = app.key_strip.dimen.y + 2 })
    drag_keyboard_icon(app, Geom:new{ x = 50, y = H - 10 }, { swipe = true })
    assert_true(wire() == "", "over the keyboard or the strip: nothing")
    assert_true(not app.toolbar:is_dragging() and app.toolbar.drag_icon == nil, "the drop reached the bar: no icon left")
    -- over the Send keys panel
    open_key_panel(app)
    drag_keyboard_icon(app, Geom:new{ x = 50, y = app.key_panel.dimen.y + 5 })
    assert_true(wire() == "" and app.key_panel ~= nil, "over the panel: nothing")
    assert_true(not app.toolbar:is_dragging() and app.toolbar.drag_icon == nil, "no icon left over the panel")
    app:close_key_panel()
    UIManager:_checkTasks()
    app:set_keyboard_visible(false)
    -- a drag that starts on another button still moves the bar
    local from = toolbar_button_centre(app, "mode")
    drag_toolbar(from, 0, 100)
    assert_true(app.toolbar.dimen.y == bar.y + 100 and wire() == "" and not app.vk_wanted, "the bar moved, nothing else")
    close_viewer(app, remote)
end)

check("keyboard_button_drag_off_the_canvas_does_nothing", function()
    -- a small remote that fits above the keyboard: the canvas ends where the keyboard starts
    local app, remote = new_app(400, 300, { toolbar = true })
    app:set_keyboard_visible(true)
    app:zoom_to(0.5)
    local c = app:canvas_geom()
    assert_true(c.h < Screen:getHeight(), "the canvas is shorter than the screen")
    local wire = wire_log(app)
    drag_keyboard_icon(app, Geom:new{ x = 30, y = c.y + c.h + 1 })
    assert_true(wire() == "", "below the canvas: nothing")
    drag_keyboard_icon(app, Geom:new{ x = 30, y = c.y + c.h - 30 })
    assert_true(wire() == "p0,p1,p0", "inside it: a click")
    close_viewer(app, remote)
end)

check("keyboard_button_drag_works_from_the_collapsed_bar", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    app:set_toolbar_collapsed(true)
    local bar = app.toolbar.dimen
    assert_true(app.toolbar.button_by_id.keyboard ~= nil, "Keyboard is pinned by default")
    local wire = wire_log(app)
    local c = app:canvas_geom()
    local P = Geom:new{ x = c.x + 100, y = c.y + math.floor(c.h / 2) }
    local rx, ry = app:_to_remote(P.x, P.y)
    drag_keyboard_icon(app, P)
    assert_true(wire() == "p0,p1,p0" and all_at({ last_pointer(sent) }, rx, ry), "one click at the drop point")
    assert_true(app.vk_visible and app.toolbar.collapsed, "the keyboard came up, the bar stays collapsed")
    assert_true(app.toolbar.dimen.x == bar.x and app.toolbar.dimen.y == bar.y, "and in place")
    -- its tap is still the toggle
    tap_toolbar(app, "keyboard")
    UIManager:_checkTasks()
    assert_true(not app.vk_visible and app.settings.keyboard_shown == false and wire() == "", "a tap hides it")
    tap_toolbar(app, "keyboard")
    UIManager:_checkTasks()
    assert_true(app.vk_visible and wire() == "", "and shows it")
    -- the expand button still drags the short bar
    drag_toolbar(toolbar_button_centre(app, "toggle"), 30, 60)
    assert_true(app.toolbar.dimen.x == bar.x + 30 and app.toolbar.dimen.y == bar.y + 60, "the short bar moves")
    close_viewer(app, remote)
end)

local function two_finger(kind, pos, t, extra)
    local ev = { ges = kind, pos = Geom:new{ x = pos.x, y = pos.y, w = 0, h = 0 }, span = 80, time = t }
    for k, v in pairs(extra or {}) do ev[k] = v end
    dispatch_gesture(ev)
    UIManager:_checkTasks()
end

check("two_finger_long_press_clicks_and_shows_the_keyboard", function()
    for _, mode in ipairs{ "touch", "mouse" } do
        local app, remote, sent = new_app(400, 300, { mode = mode })
        local wire = wire_log(app)
        local c = app:canvas_geom()
        local P = Geom:new{ x = c.x + 70, y = c.y + 90 }
        local rx, ry = app:_to_remote(P.x, P.y)
        if mode == "mouse" then rx, ry = 200, 150 end -- the pointer starts at the centre
        local t0 = time.now()
        two_finger("two_finger_hold", P, t0)
        assert_true(wire() == "" and not app.vk_visible, mode .. ": nothing until the fingers lift")
        two_finger("two_finger_hold_release", P, t0 + time.ms(600))
        local got = wire()
        assert_true(got == "p0,p1,p0", mode .. ": one click, got " .. got)
        assert_true(all_at({ sent.pointer[#sent.pointer - 1], last_pointer(sent) }, rx, ry), mode .. ": where it should be")
        assert_true(app.vk_visible and app.settings.keyboard_shown == true, mode .. ": the keyboard came up and was saved")
        assert_true(not app:has_pointer_action(), mode .. ": nothing held")
        -- again with the keyboard up: only the click
        two_finger("two_finger_hold", P, t0 + time.ms(2000))
        two_finger("two_finger_hold_release", P, t0 + time.ms(2600))
        assert_true(wire() == "p0,p1,p0" and app.vk_visible, mode .. ": again, the click alone")
        close_viewer(app, remote)
    end
end)

check("two_finger_long_press_that_moves_or_lifts_at_once_does_not_click", function()
    local app, remote = new_app(400, 300, { toolbar = true })
    local wire = wire_log(app)
    local c = app:canvas_geom()
    local P = Geom:new{ x = c.x + 70, y = c.y + math.floor(c.h / 2) }
    local t0 = time.now()
    -- it moves: cancelled
    two_finger("two_finger_hold", P, t0)
    two_finger("two_finger_hold_pan", Geom:new{ x = P.x + 30, y = P.y }, t0 + time.ms(300), { relative = { x = 30, y = 0 } })
    two_finger("two_finger_hold_pan_release", Geom:new{ x = P.x + 30, y = P.y }, t0 + time.ms(700))
    assert_true(wire() == "" and not app.vk_wanted, "a hold_pan cancels it")
    -- lifted before HOLD_CONFIRM: the device's false hold, i.e. a two-finger tap (fit)
    app:zoom_to(2); remote:pan_by(-50, -40)
    two_finger("two_finger_hold", P, t0 + time.ms(1000))
    two_finger("two_finger_hold_release", P, t0 + time.ms(1015))
    assert_true(wire() == "" and not app.vk_wanted, "a fast lift: no click, no keyboard")
    assert_true(app.settings.zoom_mode == "fit", "but a fit, like a two-finger tap")
    -- on the toolbar: nothing
    local on_bar = toolbar_button_centre(app, "zoom")
    two_finger("two_finger_hold", on_bar, t0 + time.ms(2000))
    two_finger("two_finger_hold_release", on_bar, t0 + time.ms(2600))
    assert_true(wire() == "" and not app.vk_wanted, "on the toolbar: nothing")
    -- under a popup: nothing
    app:open_menu()
    two_finger("two_finger_hold", P, t0 + time.ms(3000))
    two_finger("two_finger_hold_release", P, t0 + time.ms(3600))
    app:close_menu()
    UIManager:_checkTasks()
    assert_true(wire() == "" and not app.vk_wanted, "under the menu: nothing")
    close_viewer(app, remote)
end)

check("a_second_finger_joining_a_long_press_only_ends_it", function()
    for _, mode in ipairs{ "touch", "mouse" } do
        local app, remote = new_app(400, 300, { mode = mode })
        local wire = wire_log(app)
        local c = app:canvas_geom()
        local P = Geom:new{ x = c.x + 50, y = c.y + 50 }
        local t0 = time.now()
        dispatch_gesture{ ges = "hold", pos = P, time = t0 }
        confirm_hold(app)
        assert_true(wire() == "p4", mode .. ": right press")
        two_finger("two_finger_hold", P, t0 + time.ms(800))
        assert_true(wire() == "p0", mode .. ": let go")
        two_finger("two_finger_hold_release", P, t0 + time.ms(1600))
        assert_true(wire() == "" and not app.vk_wanted, mode .. ": its lift clicks nothing, no keyboard")
        close_viewer(app, remote)
    end
end)

if failures > 0 then
    print(string.format("%d check(s) failed", failures))
    os.exit(1)
end
print("all checks passed")
os.exit(0)
