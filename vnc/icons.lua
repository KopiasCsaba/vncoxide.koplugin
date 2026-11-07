--[[--
The plugin's own icons (`icons/<name>.svg` in the plugin folder), for the buttons KOReader's icon
set has nothing fitting for.

KOReader looks icons up by name in its own folders only, so these are handed over by path: an
absolute one, as KOReader's working directory is not the plugin's.

@module vnc.icons
]]

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

return Icons
