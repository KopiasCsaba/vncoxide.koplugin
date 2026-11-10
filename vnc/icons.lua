--[[--
The plugin's own icons (`icons/<name>.svg` in the plugin folder), for the buttons KOReader's icon
set has nothing fitting for.

KOReader looks icons up by name in its own folders only, so these are handed over by path: an
absolute one, as KOReader's working directory is not the plugin's.

@module vnc.icons
]]

local IconWidget = require("ui/widget/iconwidget")
local lfs = require("libs/libkoreader-lfs")

local Icons = {}

-- this file is <plugin>/vnc/icons.lua: the plugin folder is two levels up
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local plugin_dir = source:match("^(.*)[/\\]vnc[/\\][^/\\]*$") or "."
if plugin_dir:sub(1, 1) ~= "/" then
    plugin_dir = lfs.currentdir() .. (plugin_dir == "." and "" or "/" .. plugin_dir:gsub("^%./", ""))
end

--- The absolute path of the plugin icon `name` (`icons/<name>.svg`).
function Icons.path(name)
    return plugin_dir .. "/icons/" .. name .. ".svg"
end

--- Button and IconButton only take icon names: build them with KOReader's placeholder
--- (`"icon-not-found"`) and hand them the plugin icon `file` here instead, at `size` pixels square,
--- in the place their image is painted from.
function Icons.set_button_icon(button, file, size)
    button.label_widget:free()
    button.label_widget = IconWidget:new{ file = file, width = size, height = size }
    button.label_container[1] = button.label_widget
end

--- The same for an IconButton (its image sits between the padding spans of a HorizontalGroup).
function Icons.set_icon_button_icon(button, file)
    local old = button.image
    button.image = IconWidget:new{ file = file, width = old.width, height = old.height }
    button.horizontal_group[2] = button.image
    old:free()
end

return Icons
