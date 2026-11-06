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
local function new_app(plane_w, plane_h)
    local ViewerApp = require("vnc/app")
    local Remote = require("vnc/framebuffer")
    local remote = Remote.new(plane_w or 400, plane_h or 300)
    local sent = { pointer = {}, key = {}, input = 0, areas = {} }
    local app = ViewerApp:new{
        plugin = {
            settings = {
                data = { settings = { orientation = 0, keyboard_always_visible = false,
                                      zoom_mode = "fit" } },
                profiles = function() return {} end,
                flush = function() end,
            },
            leave_app = function() end,
            disconnect_session = function() end,
            connect_profile = function() end,
        },
        session = {
            get_remote = function() return remote end,
            send_pointer = function(_, x, y, mask)
                sent.pointer[#sent.pointer + 1] = { x = x, y = y, mask = mask }
            end,
            send_key = function(_, keysym, down) sent.key[#sent.key + 1] = { keysym = keysym, down = down } end,
            note_input = function() sent.input = sent.input + 1 end,
            set_view_area = function(_, rect) sent.areas[#sent.areas + 1] = rect end,
            get_state = function() return "connected" end,
            get_error = function() return nil end,
            get_profile = function() return { name = "test" } end,
        },
    }
    -- Shown the way main.lua shows it: a full-screen widget asks for its own refresh.
    UIManager:show(app, "full")
    return app, remote, sent
end

check("canvas_covers_the_screen", function()
    local app, remote = new_app()
    local size = Screen:getSize()
    assert_true(app.canvas.x == 0 and app.canvas.y == 0,
        string.format("the canvas must start at the top left, got %s", tostring(app.canvas)))
    assert_true(app.canvas.w == size.w and app.canvas.h == size.h,
        string.format("the canvas (%dx%d) must cover the whole screen (%dx%d)",
            app.canvas.w, app.canvas.h, size.w, size.h))
    assert_true(app.top_bar == nil, "there is no permanent toolbar any more")

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

    -- the menu offers both fitted modes, under the names users are looking for
    app:open_menu()
    local labels
    for _, item in ipairs(app.menu.item_table) do
        if item.text == "Zoom…" then
            labels = {}
            for _, sub in ipairs(item.sub_item_table) do labels[#labels + 1] = sub.text end
        end
    end
    assert_true(labels ~= nil, "the menu must offer a zoom submenu")
    assert_true(labels[1] == "Fit screen", "the first choice is \"Fit screen\", got " .. tostring(labels[1]))
    assert_true(labels[2] == "Fit (with keyboard)",
        "the second choice is \"Fit (with keyboard)\", got " .. tostring(labels[2]))
    app:close_menu()
    UIManager:_checkTasks()

    app:zoom_to("fit")
    local fit = math.min(size.w / 400, size.h / 300)
    assert_true(near(remote:get_scale(), fit),
        string.format("\"fit screen\" fits the screen: %s", remote:get_scale()))

    app:set_keyboard_visible(true)
    local kbd_h = app.vk:getSize().h
    assert_true(kbd_h > 0, "the keyboard must have a height")

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
    local kbd_h = app.vk:getSize().h
    assert_true(kbd_h > 0, "the keyboard must have a height")

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

check("menu_opens_on_swipe_only", function()
    local app, remote, sent = new_app()

    -- no tap zone may exist: the top strip must stay available to the remote desktop
    assert_true(not app:checkRegisterTouchZone("vnc_menu_tap"),
        "there must be no menu tap zone")
    assert_true(not app:checkRegisterTouchZone("vnc_menu_tap_ext"),
        "there must be no menu tap zone")
    assert_true(app:checkRegisterTouchZone("vnc_menu_swipe"),
        "the menu swipe zone must be registered")
    assert_true(app:checkRegisterTouchZone("vnc_menu_swipe_ext"),
        "the extended menu swipe zone must be registered")

    local zone = G_defaults:readSetting("DTAP_ZONE_MENU")
    local size = Screen:getSize()
    local gs_range = app._zones["vnc_menu_swipe"].gs_range
    assert_true(math.abs(gs_range.range.w - size.w * zone.w) < 1,
        "the menu swipe zone must cover KOReader's DTAP_ZONE_MENU width")
    assert_true(math.abs(gs_range.range.h - size.h * zone.h) < 1,
        "the menu swipe zone must cover KOReader's DTAP_ZONE_MENU height")

    -- dispatch: a tap inside that zone must click the remote, not open the menu
    local inside = Geom:new{ x = 10, y = 10 }
    app.menu = nil
    sent.pointer = {}
    app:onGesture({ ges = "tap", pos = inside })
    assert_true(app.menu == nil, "a tap must never open the menu")
    assert_true(#sent.pointer == 3, "a tap in the top zone must click the remote, got "
        .. #sent.pointer .. " pointer events")

    -- dispatch: a south swipe there opens the menu, other directions do not
    app:onGesture({ ges = "swipe", direction = "south", pos = inside })
    assert_true(app.menu ~= nil, "a swipe down in the top zone must open the menu")
    app:close_menu()
    app:onGesture({ ges = "swipe", direction = "north", pos = inside })
    assert_true(app.menu == nil, "only a south swipe opens the menu")

    -- and a tap anywhere else is a click too
    sent.pointer = {}
    app:onGesture({ ges = "tap", pos = Geom:new{ x = 10, y = size.h - 10 } })
    assert_true(#sent.pointer == 3, "a tap below the zone must click the remote")
    assert_true(app.menu == nil, "and must not open the menu")

    app:onCloseWidget()
    remote:free()
end)

check("keyboard_shows_on_a_swipe_up_from_the_bottom", function()
    local app, remote, sent = new_app()
    -- the same quick upward swipe the menu uses at the top, started in the canvas' bottom strip
    local function bottom()
        local canvas = app:canvas_geom()
        return Geom:new{ x = math.floor(canvas.x + canvas.w / 2), y = canvas.y + canvas.h - 2 }
    end
    local function middle()
        local canvas = app:canvas_geom()
        return Geom:new{ x = math.floor(canvas.x + canvas.w / 2), y = math.floor(canvas.y + canvas.h / 2) }
    end

    dispatch_gesture{ ges = "swipe", direction = "north", pos = bottom() }
    assert_true(app.vk_visible, "a swipe up from the bottom edge must show the keyboard")
    assert_true(app:is_keyboard_wanted(), "and it must be remembered as the user's wish")

    app:set_keyboard_visible(false)
    assert_true(not app.vk_visible, "the keyboard must hide again for the next case")

    -- the same swipe higher up is an ordinary canvas gesture: the strip is not the whole screen
    dispatch_gesture{ ges = "swipe", direction = "north", pos = middle() }
    assert_true(not app.vk_visible, "a swipe up away from the bottom strip must not show the keyboard")

    -- and only an upward swipe is the keyboard gesture
    dispatch_gesture{ ges = "swipe", direction = "south", pos = bottom() }
    assert_true(not app.vk_visible, "a swipe down in the bottom strip must not show the keyboard")
    dispatch_gesture{ ges = "swipe", direction = "east", pos = bottom() }
    assert_true(not app.vk_visible, "nor must a horizontal one")

    -- the strip stays a live part of the canvas: a tap there is still a click on the remote
    sent.pointer = {}
    dispatch_gesture{ ges = "tap", pos = bottom() }
    assert_true(#sent.pointer == 3,
        "a tap in the bottom strip must click the remote, got " .. #sent.pointer .. " pointer events")
    assert_true(not app.vk_visible, "and must not show the keyboard")

    -- the strip follows a rotation (it is recomputed from the canvas, not cached)
    local mode = Screen:getRotationMode()
    app:set_rotation_mode((mode + 1) % 4)
    dispatch_gesture{ ges = "swipe", direction = "north", pos = bottom() }
    assert_true(app.vk_visible, "the gesture must still work after a rotation")

    -- ...and a keyboard height change, which reflows the canvas under the strip
    app:on_keyboard_height_changed()
    app:set_keyboard_visible(false)
    dispatch_gesture{ ges = "swipe", direction = "north", pos = bottom() }
    assert_true(app.vk_visible, "and after the keyboard height changed")

    app:set_rotation_mode(mode)
    app:set_keyboard_visible(false)
    app:onCloseWidget()
    remote:free()
end)

check("keyboard_swipe_honours_the_always_visible_setting", function()
    local app, remote = new_app()
    app.settings.keyboard_always_visible = true
    app:set_keyboard_visible(true)
    assert_true(app.vk_visible, "with the setting on the keyboard is up")

    -- the showing swipe cannot make it "more visible", and must not touch the setting
    local canvas = app:canvas_geom()
    dispatch_gesture{ ges = "swipe", direction = "north",
        pos = Geom:new{ x = math.floor(canvas.x + canvas.w / 2), y = canvas.y + canvas.h - 2 } }
    assert_true(app.vk_visible and app:is_keyboard_wanted(),
        "a swipe up must leave the always-visible keyboard up")
    assert_true(app.settings.keyboard_always_visible, "and must not change the setting")

    -- and the hiding swipe must lose against it
    canvas = app:canvas_geom()
    dispatch_gesture{ ges = "swipe", direction = "south",
        pos = Geom:new{ x = math.floor(canvas.x + canvas.w / 2), y = math.floor(canvas.y + canvas.h / 2) } }
    assert_true(app.vk_visible, "the setting wins over a swipe that would hide the keyboard")
    assert_true(app.settings.keyboard_always_visible, "and it stays on")

    -- the menu's toggle is what turns it off, exactly as before
    app:toggle_keyboard()
    assert_true(not app.settings.keyboard_always_visible and not app.vk_visible,
        "toggling from the menu must still turn it off")

    app:onCloseWidget()
    remote:free()
end)

check("keyboard_hides_on_a_swipe_down_above_it", function()
    local app, remote = new_app()
    app:set_keyboard_visible(true)
    assert_true(app.vk_visible, "the keyboard must be up")

    -- the canvas above the keyboard is the space a hiding swipe can start in
    local canvas = app:canvas_geom()
    dispatch_gesture{ ges = "swipe", direction = "south",
        pos = Geom:new{ x = math.floor(canvas.x + canvas.w / 2), y = math.floor(canvas.y + canvas.h / 2) } }
    assert_true(not app.vk_visible, "a swipe down above the keyboard must hide it")
    assert_true(not app:is_keyboard_wanted(), "and the wish must follow it")

    app:set_keyboard_visible(true)
    canvas = app:canvas_geom()
    dispatch_gesture{ ges = "swipe", direction = "north",
        pos = Geom:new{ x = math.floor(canvas.x + canvas.w / 2), y = math.floor(canvas.y + canvas.h / 2) } }
    assert_true(app.vk_visible, "only a downward swipe hides the keyboard")

    app:set_keyboard_visible(false)
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
    app.settings.keyboard_always_visible = true
    app:set_keyboard_visible(true)
    assert_true(app.vk_visible, "with the setting on the keyboard covers the framebuffer")

    app:open_menu()
    assert_true(not app.vk_visible, "opening the menu must hide the keyboard")
    assert_true(app:is_keyboard_wanted(), "without forgetting that it was asked for")
    UIManager:_checkTasks()
    assert_true(not app.vk_visible, "and it must stay hidden while the menu is open")

    -- the menu's own keyboard item must describe the wish, not the state the menu just forced
    local label
    for _, item in ipairs(app.menu.item_table) do
        if item.text == "Hide keyboard" or item.text == "Show keyboard" then label = item.text end
    end
    assert_true(label == "Hide keyboard", "the item must still offer to hide it, got " .. tostring(label))

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

    -- "Hide keyboard" has to work even with the setting on, or the item would lie
    app:open_menu()
    app:toggle_keyboard()
    assert_true(not app.settings.keyboard_always_visible, "the setting must follow the user's wish")
    assert_true(not app:is_keyboard_wanted(), "and the wish is recorded")
    assert_true(not app.vk_visible, "still hidden while the menu is open")
    app:close_menu()
    UIManager:_checkTasks()
    assert_true(not app.vk_visible, "and hidden after the menu closes")

    -- leaving the viewer never resurrects the keyboard over whatever comes next
    app.settings.keyboard_always_visible = true
    app:evaluate_keyboard()
    assert_true(app.vk_visible, "the setting on again")
    local popup = InfoMessage:new{ text = "after the viewer" }
    app:onCloseWidget()
    UIManager:show(popup)
    app:_sync_keyboard_later()
    UIManager:_checkTasks()
    assert_true(not app.vk:isVisible(), "no keyboard may appear after the viewer closed")
    UIManager:close(popup)

    remote:free()
end)

check("menu_keyboard_items_work", function()
    -- A real tap goes through Menu:onMenuSelect, which runs the item callback *and* the menu's
    -- close callback; the latter used to switch the keyboard off again right after the item
    -- had switched it on.
    local app, remote = new_app()
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
    choose_menu_item("Show keyboard")
    assert_true(app.menu == nil, "choosing an item closes the menu")
    assert_true(app.vk_visible, "\"Show keyboard\" must leave the keyboard shown")

    choose_menu_item("Hide keyboard")
    assert_true(not app.vk_visible, "\"Hide keyboard\" must leave it hidden")

    -- with the setting on, the keyboard survives a menu round trip. (The item is labelled
    -- "Hide keyboard" throughout: it describes the wish, not the state the open menu forces.)
    app.settings.keyboard_always_visible = true
    app:set_keyboard_visible(true)
    app:open_menu()
    assert_true(not app.vk_visible, "the menu hides the keyboard while it is open")
    app:close_menu()
    UIManager:_checkTasks()
    assert_true(app.vk_visible, "the setting must bring it back when the menu closes")

    app.settings.keyboard_always_visible = false
    app:set_keyboard_visible(false)
    assert_true(not app.vk_visible, "and it can be hidden again once the setting is off")

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

check("sharp_scaling_menu_entry_applies_live", function()
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
    app:open_menu()
    local entry
    for _, item in ipairs(app.menu.item_table) do
        if item.text == "Sharp scaling (faster)" then entry = item end
    end
    assert_true(entry, "the viewer menu must have a 'Sharp scaling (faster)' entry")
    assert_true(entry.help_text and entry.help_text:find("repeating pixels", 1, true)
        and entry.help_text:find("Much faster redraws when the zoom is not 100%", 1, true), "the entry has a help text")
    assert_true(entry.mandatory ~= "✓", "smooth is the start state")
    local before = #stack()
    entry.callback()
    assert_true(s.scaling == "sharp", "toggling stores sharp, got " .. tostring(s.scaling))
    assert_true(flushed >= 1, "settings are flushed")
    assert_true(modes[#modes] == "sharp" and remote.scaling == "sharp", "the live remote is switched to sharp")
    assert_true(repaints == 1, "the view is repainted")
    for _, w in ipairs(stack()) do
        assert_true(w.text ~= "Reconnect to apply the new settings.", "no reconnect notice")
    end
    assert_true(#stack() <= before, "no notice widget was added")
    app:open_menu()
    for _, item in ipairs(app.menu.item_table) do
        if item.text == "Sharp scaling (faster)" then entry = item end
    end
    assert_true(entry.mandatory == "✓", "the entry shows sharp as on")
    entry.callback()
    assert_true(s.scaling == "smooth" and modes[#modes] == "smooth", "toggling again goes back to smooth")
end)

check("menu_stays_open_on_toggles_and_closes_with_its_close_button", function()
    local app, remote = new_app()
    local s = app.plugin.settings.data.settings
    s.scaling, s.page_buttons, s.keyboard_always_visible = "smooth", "keys", false
    app.plugin.settings.flush = function() end
    local menu = app:open_menu()
    local function entry(text) return find_item(menu.item_table, text) end
    local function tap(item)
        menu:onMenuSelect(item)
        UIManager:_checkTasks()
    end
    local function on_top() return top() == menu end

    tap(entry("Sharp scaling (faster)"))
    assert_true(s.scaling == "sharp", "the tap toggles the setting")
    assert_true(app.menu == menu and on_top(), "Sharp scaling leaves the menu on top")
    assert_true(entry("Sharp scaling (faster)").mandatory == "✓", "and the item shows the new state")
    assert_true(app._needs_flash, "the view is flashed when the menu closes")

    tap(entry("Keyboard always visible"))
    assert_true(s.keyboard_always_visible == true and app.menu == menu and on_top(), "keyboard toggle keeps the menu")
    assert_true(entry("Keyboard always visible").mandatory == "✓", "and shows the new state")

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
    tap(find_item(find_item(menu.item_table, "Zoom…").sub_item_table, "100%"))
    assert_true(app.menu == nil, "a zoom choice closes the menu")
    menu = app:open_menu()
    tap(find_item(menu.item_table, "Send keys…"))
    assert_true(app.menu == nil and app.key_panel ~= nil, "Send keys… closes the menu and opens the panel")
    app:close_key_panel()

    app:onCloseWidget()
    remote:free()
end)

check("menu_orientation_choice_closes_menu", function()
    local app, remote = new_app()
    app.plugin.settings.flush = function() end
    local menu = app:open_menu()
    local start = Screen:getRotationMode()
    local target = (start + 1) % 4
    local labels = { [0] = "Portrait", "Landscape", "Portrait inverted", "Landscape inverted" }
    menu:onMenuSelect(find_item(menu.item_table, "Screen orientation"))
    menu:onMenuSelect(find_item(menu.item_table, labels[target]))
    UIManager:_checkTasks()
    assert_true(Screen:getRotationMode() == target, "the viewer rotated")
    assert_true(app.menu == nil, "the menu closed on an orientation choice")
    menu = app:open_menu()
    assert_true(find_item(menu.item_table, "Screen orientation").mandatory == labels[target], "label follows")
    menu:onMenuSelect(find_item(menu.item_table, "Use current orientation as default"))
    assert_true(app.settings.orientation == target and app.menu == menu, "default stored, menu kept")
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
        app.settings.scaling = "smooth"
        local menu = app:open_menu()
        menu:onMenuSelect(find_item(menu.item_table, "Sharp scaling (faster)"))
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
    -- Sharp scaling is a viewer-menu setting: only the closing advice may point to it, not a setting paragraph.
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
    local ok, err = pcall(function() session:_do_connect() end)
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
    local ok, err = pcall(function() session:_do_connect() end)
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

check("viewer_menu_disconnect_returns_to_the_list", function()
    local app, remote = new_app()
    local session = app.session
    local disconnected = false
    session.disconnect = function() disconnected = true end
    session.detach = function() end
    plugin.sessions = { test = session }
    plugin.app = app
    app.plugin = plugin
    app:open_menu()
    find_item(app.menu.item_table, "Disconnect").callback()
    local confirm = top()
    assert_true(confirm.ok_callback, "a confirmation, stack: " .. stack_desc())
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
local BENCH_INTRO = "Tries 11 picture-setting combinations on this connection, a few seconds each.\n\nBefore starting, put what you usually look at on the shared area of the PC — the page, document or app you use — and leave it still. Each combination fetches that screen several times, whole and in small pieces, and is scored by how fast it reaches this screen, including decoding and drawing at your current zoom.\n\nNothing is saved unless you tap Apply at the end."

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
      error = "server refused the format" },
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
    o.on_progress(3, 11, "16-bit, Tight off", "full")
    assert_true(top() == progress, "progress stays on top")
    assert_true(progress.title == "3/11: 16-bit, Tight off — full screen", "progress text: " .. tostring(progress.title))
    o.on_progress(4, 11, "16-bit, Tight, compr. 1", "connect")
    assert_true(progress.title == "4/11: 16-bit, Tight, compr. 1 — connecting", "progress text: " .. tostring(progress.title))
    o.on_progress(4, 11, "16-bit, Tight, compr. 1", "tiles")
    assert_true(progress.title == "4/11: 16-bit, Tight, compr. 1 — small pieces", "progress text: " .. tostring(progress.title))
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
    for _, w in ipairs(stack()) do assert_true(not (w.title and w.title:find("/11:", 1, true)), "progress closed") end
    local text = viewer.text
    local p1 = text:find("1. 8-bit, Tight, compr. 2", 1, true)
    local p2 = text:find("2. 24-bit, Tight off", 1, true)
    local p3 = text:find("16-bit, Tight off", 1, true)
    local p4 = text:find("24-bit, Tight, compr. 2, JPEG 4", 1, true)
    assert_true(p1 and p2 and p3 and p4 and p1 < p2 and p2 < p3 and p3 < p4, "rows in order:\n" .. text)
    for _, want in ipairs{ "3.5 Mpx/s · 12 ms/tile · full 813 ms · 200 KB",
                           "1.0 Mpx/s · 40 ms/tile · full 95 ms · 1024 KB",
                           "failed: no update within 15 s", "failed: server refused the format" } do
        assert_true(text:find(want, 1, true), "missing " .. want .. " in:\n" .. text)
    end
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
        assert_true(text:find("10.0 Mpx/s · 999 ms/tile · full 9999 ms · 9999 KB", 1, true), "worst case row:\n" .. text)
        local viewer = Dialogs.benchmark_results(plugin, "good", results, function() end)
        local box = viewer.box_widget
        assert_true(box and box.face and box.width > 0, "the viewer's text box")
        local RenderText = require("ui/rendertext")
        local n = 0
        for line in (text .. "\n"):gmatch("(.-)\n") do
            if line:find("Mpx/s", 1, true) then
                n = n + 1
                local w = RenderText:sizeUtf8Text(0, box.width, box.face, line).x
                assert_true(w < box.width, string.format("%q is %d px wide, the text area %d px", line, w, box.width))
            end
        end
        assert_true(n == 3, "figures lines measured: " .. n)
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

--- Opens the panel the way a user does: from the viewer menu.
local function open_key_panel(app)
    local menu = app:open_menu()
    menu:onMenuSelect(find_item(menu.item_table, "Send keys…"))
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

check("key_panel_opens_from_the_menu_and_leaves_the_canvas_usable", function()
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
    assert_true(panel.button_by_id["combo"].text == "Ctrl+…", "the combo shows it: " .. panel.button_by_id["combo"].text)
    pick_tab(panel, 3) -- Letters
    touch(panel, "key:T")
    local got = take_keys(sent)
    assert_true(got == "+0xFFE3,+0x74,-0x74,-0xFFE3", "Ctrl+T on the wire, got " .. got)
    assert_true(panel:modifier_state("Ctrl") == nil, "Ctrl is disarmed after one key")
    assert_true(panel.button_by_id["combo"].text == "Tap a key", "the combo is empty again")
    touch(panel, "key:T")
    got = take_keys(sent)
    assert_true(got == "+0x74,-0x74", "the next key goes alone, got " .. got)
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
    assert_true(panel.button_by_id["combo"].text == "Tap a key", "and the panel shows it")
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
        rotate = function(app) app:onRotate(nil, { direction = "cw", pos = Geom:new{ x = 50, y = 50 } }) end,
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
        hold = function(app) app:onHold(nil, { pos = Geom:new{ x = 40, y = 30 } }) end,
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

check("two_finger_flick_scrolls_the_wheel", function()
    local app, remote, sent = new_app()
    local c = app:canvas_geom()
    app:onTap(nil, { pos = { x = c.x + 50, y = c.y + 40 } })
    local rx, ry = app:_to_remote(c.x + 50, c.y + 40)
    local function masks()
        local out = {}
        for _, e in ipairs(sent.pointer) do out[#out + 1] = e.mask end
        sent.pointer = {}
        return table.concat(out, ",")
    end
    local function notches(mask, n)
        return string.rep(mask .. ",0,", n):sub(1, -2)
    end
    masks()
    local half = Screen:getHeight() / 2
    local pos = Geom:new{ x = 50, y = 50 }
    assert_true(app:onTwoFingerSwipe(nil, { direction = "north", distance = half, pos = pos }) == true)
    local got = masks()
    assert_true(got == notches(16, 5), "north half screen: 5 notches down, got " .. got)
    app:onTwoFingerSwipe(nil, { direction = "south", distance = half, pos = pos })
    got = masks()
    assert_true(got == notches(8, 5), "south: wheel up, got " .. got)
    app:onTwoFingerSwipe(nil, { direction = "north", distance = 1, pos = pos })
    assert_true(masks() == notches(16, 1), "tiny flick: at least 1 notch")
    app:onTwoFingerSwipe(nil, { direction = "north", distance = Screen:getHeight() * 3, pos = pos })
    assert_true(masks() == notches(16, 10), "huge flick: at most 10 notches")
    for _, dir in ipairs({ "east", "west" }) do
        assert_true(app:onTwoFingerSwipe(nil, { direction = dir, distance = half, pos = pos }) == nil)
        assert_true(#sent.pointer == 0, dir .. ": nothing sent")
    end
    app:onTwoFingerSwipe(nil, { direction = "north", distance = half, pos = pos })
    for _, e in ipairs(sent.pointer) do
        assert_true(e.x == rx and e.y == ry, "the wheel goes to the last pointer position")
    end
    sent.pointer = {}
    -- a slow two-finger drag still pans and sends nothing
    app:onTwoFingerPan(nil, { relative = { x = 5, y = 5 } })
    assert_true(#sent.pointer == 0 and #sent.key == 0, "two_finger_pan sends nothing")
    close_viewer(app, remote)
end)

check("two_finger_flick_leaves_armed_modifiers_alone", function()
    local app, remote = new_app()
    local panel = open_key_panel(app)
    local wire = wire_log(app)
    touch(panel, "mod:Shift")
    UIManager:forceRePaint()
    wire()
    app:onTwoFingerSwipe(nil, { direction = "north", distance = 100, pos = Geom:new{ x = 50, y = 50 } })
    local got = wire()
    assert_true(not got:find("0x", 1, true), "a flick sends no keys, got " .. got)
    assert_true(#panel:take_armed() == 1, "Shift is still armed after a flick")
    close_viewer(app, remote)
end)

check("key_panel_combo_order_and_modifiers_only", function()
    local app, remote, sent = new_app()
    local panel = open_key_panel(app)
    -- armed in a scrambled order: the wire order is still Ctrl, Shift, Alt, Super
    for _, m in ipairs({ "Super", "Alt", "Ctrl", "Shift" }) do touch(panel, "mod:" .. m) end
    assert_true(panel.button_by_id["combo"].text == "Ctrl+Shift+Alt+Super+…", panel.button_by_id["combo"].text)
    pick_tab(panel, 2) -- F1–F12
    touch(panel, "key:F4")
    local got = take_keys(sent)
    assert_true(got == "+0xFFE3,+0xFFE1,+0xFFE9,+0xFFEB,+0xFFC1,-0xFFC1,-0xFFEB,-0xFFE9,-0xFFE1,-0xFFE3",
        "modifier downs in order, key, ups in reverse: " .. got)

    -- the combo display: nothing armed sends nothing; Super alone is pressed and released
    assert_true(panel.button_by_id["combo"].enabled == false, "with nothing armed the combo is not a button")
    touch(panel, "combo")
    assert_true(take_keys(sent) == "", "nothing armed, nothing sent")
    touch(panel, "mod:Super")
    touch(panel, "combo")
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
    touch(panel, "key:T")
    assert_true(flushed > 0, "the recent list is saved")
    local recent = app.settings.recent_combos
    assert_true(#recent == 1 and recent[1].keysym == 0x74 and recent[1].mods[1] == "Ctrl"
        and #recent[1].mods == 1 and recent[1].label == "T", "Ctrl+T is recorded")
    assert_true(panel.button_by_id["recent:1"].text == "Ctrl+T", "and shown")
    take_keys(sent)

    -- a replay is the action: it sends exactly that combo (the armed Shift is not added) and
    -- clears what was armed
    touch(panel, "mod:Shift")
    touch(panel, "recent:1")
    local got = take_keys(sent)
    assert_true(got == "+0xFFE3,+0x74,-0x74,-0xFFE3", "replay of Ctrl+T without the armed Shift, got " .. got)
    assert_true(panel:modifier_state("Shift") == nil, "the replay used up the armed Shift")
    assert_true(panel.button_by_id["recent:1"].text == "Ctrl+T", "and the list still says Ctrl+T")

    -- distinct combos, most recent first, at most four; a repeat moves to the front
    pick_tab(panel, 1)
    touch(panel, "key:Esc")
    touch(panel, "key:Tab")
    touch(panel, "mod:Alt")
    touch(panel, "key:Tab")
    touch(panel, "mod:Super")
    touch(panel, "combo")
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
    assert_true(panel.button_by_id["combo"].text == "Tap a key", "the combo is empty")
    assert_true(panel.button_by_id["release_all"].enabled == false, "and there is nothing left to release")
    close_viewer(app, remote)
end)

check("key_panel_close_paths_release_everything", function()
    local Key = require("device/key")
    local paths = {
        ["close button"] = function(app, panel)
            UIManager:forceRePaint()
            local x = panel.title_bar.right_button
            dispatch_gesture{ ges = "tap", pos = centre_of(x.dimen) }
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
        close(app, panel)
        UIManager:_checkTasks()
        got = take_keys(sent)
        assert_true(got == "-0xFFE3", name .. " during a Ctrl+drag must release Ctrl, got " .. got)
        app:onPanRelease(nil, { pos = Geom:new{ x = 40, y = 30 } })
        close_viewer(app, remote)
        got = take_keys(sent)
        assert_true(got == "", name .. ": nothing more after that, got " .. got)
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
        { "Keys", {
            { "Esc", 0xFF1B }, { "Tab", 0xFF09 }, { "Enter", 0xFF0D }, { "Backspace", 0xFF08 },
            { "Delete", 0xFFFF }, { "Insert", 0xFF63 }, { "Home", 0xFF50 }, { "End", 0xFF57 },
            { "Page Up", 0xFF55 }, { "Page Down", 0xFF56 }, { "Space", 0x20 }, { "Menu", 0xFF67 },
            { "←", 0xFF51 }, { "↑", 0xFF52 }, { "↓", 0xFF54 }, { "→", 0xFF53 },
            { "Print Screen", 0xFF61 }, { "Pause", 0xFF13 }, { "Caps Lock", 0xFFE5 } } },
        { "F1–F12", {} },
        { "Letters", {} },
        { "Symbols", {
            { "`", 0x60 }, { "-", 0x2D }, { "=", 0x3D }, { "[", 0x5B }, { "]", 0x5D }, { "\\", 0x5C },
            { ";", 0x3B }, { "'", 0x27 }, { ",", 0x2C }, { ".", 0x2E }, { "/", 0x2F } } },
    }
    for i = 1, 12 do table.insert(tabs[2][2], { "F" .. i, 0xFFBE + i - 1 }) end
    for c = string.byte("a"), string.byte("z") do
        table.insert(tabs[3][2], { string.char(c):upper(), c })
    end
    for d = 0, 9 do table.insert(tabs[3][2], { tostring(d), 0x30 + d }) end

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

if failures > 0 then
    print(string.format("%d check(s) failed", failures))
    os.exit(1)
end
print("all checks passed")
os.exit(0)
