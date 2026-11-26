--[[--
The plugin's version string. `_meta.lua` holds the release number; `vncoxide/build.lua` carries a
`git archive` stamp (`export-subst`, see .gitattributes) that is only expanded in a release
archive. A checkout, where the stamp is still the literal `$Format:...$`, reports `<number>-dev`.

@module vncoxide.version
]]

local Version = {}

local cached

--- Combines the number from `_meta.lua` with the archive stamp (nil, "", an unexpanded
--- `$Format:...$` or a `git describe` string such as "v1.0.0" or "v1.0.0-12-gabc1234").
function Version.resolve(meta_version, stamp)
    if stamp == nil or stamp == "" or stamp:find("$Format", 1, true) then
        return meta_version .. "-dev"
    end
    return (stamp:gsub("^v", "", 1))
end

--- The plugin root: the directory above `vncoxide/`, found from this file's own path.
local function plugin_root()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return src:match("^(.*)/vncoxide/[^/]*$") or "."
end

--- The version string of this install, computed once.
function Version.get()
    if not cached then
        -- dofile, not require("_meta"): other plugins share that module name.
        local meta = dofile(plugin_root() .. "/_meta.lua")
        cached = Version.resolve(meta.version or "0.0.0", require("vncoxide/build"))
    end
    return cached
end

return Version
