--[[--
Settings store for the vnc plugin.

Thin wrapper over @{luasettings|LuaSettings}, holding connection profiles and global
application settings in `~/.config/koreader/settings/vnc.lua`.

There is no schema version and no migration: there is no released file format to stay compatible
with. The file is just kept in shape instead - missing keys get their defaults, unknown keys are
dropped, and profiles that cannot be used are dropped - so a hand-edited file still loads.

@module vnc.settings
]]

local _ = require("gettext")

local LuaSettings = require("luasettings")
local logger = require("logger")

local Keysyms = require("vnc/keysyms")

local Settings = {}
Settings.__index = Settings

--- Profile field names.
Settings.PROFILE_FIELDS = {
    "name", "host", "port", "password", "autoconnect",
    "pointer_mode",                  -- how the screen drives the pointer: "touch" or "mouse"
    -- Picture: read once per connection, so a change applies on the next one (see NOTES.txt,
    -- "Pixel format").
    "color_depth",                   -- client pixel format: 24, 16 or 8 bits (@{vnc.pxfmt.for_depth})
    "enable_tight",                  -- opt-in Tight encoding (not in RFC 6143; see NOTES.txt)
    "jpeg_quality",                  -- Tight JPEG quality 0..9, false = server default
    "compress_level",                -- Tight zlib level 0..9, false = server default
}

--- The only top-level keys of the file.
Settings.DATA_KEYS = { "profiles", "settings", "server" }

local known_data_key = {}
for _, key in ipairs(Settings.DATA_KEYS) do known_data_key[key] = true end

--- Global settings defaults (the `settings` sub-table).
Settings.DEFAULTS = {
    orientation = 0,                 -- Screen.DEVICE_ROTATED_UPRIGHT, the last one used; the viewer opens in it
    keyboard_always_visible = false,
    keep_screen_on = true,           -- hold off the device's auto-suspend, standby and light dimming while the viewer is shown
    zoom_mode = "fit",               -- "fit", "fit_with_keyboard", or a numeric scale factor
    page_buttons = "keys",           -- device page buttons send "keys" (Page Up/Down) or the "wheel"
    scaling = "smooth",              -- viewer scaling: "smooth" (blended) or "sharp" (nearest neighbour)
    pointer_speed = "normal",        -- mouse-mode cursor speed: a key of @{Settings.POINTER_SPEEDS}
    toolbar_scroll_buttons = false,  -- the toolbar shows scroll up/down buttons
    toolbar_brightness_button = true, -- the toolbar shows a button for KOReader's frontlight dialog (with a frontlight)
    toolbar_contrast_button = false, -- the toolbar shows a button for the remote picture's contrast
    remote_contrast = 1,             -- contrast of the remote picture as drawn here: one of @{Settings.CONTRAST_LEVELS}
    -- the "Send keys" panel's last combos, most recent first: { mods = {"Ctrl", ...}, keysym, label }
    recent_combos = {},
}

--- Mouse-mode cursor speed presets: remote pixels moved per screen pixel dragged.
Settings.POINTER_SPEEDS = { slow = 0.75, normal = 1.25, fast = 2.0 }

--- The contrast levels of the remote picture (the contrast dialog's steps): a factor applied around
--- mid grey, 1 is the picture as the server sends it (see @{vnc.scaler.contrast_lut}).
Settings.CONTRAST_LEVELS = { 0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3 }

--- How many combos the "Send keys" panel remembers.
Settings.RECENT_COMBOS_MAX = 4

local modifier_rank = {}
for i, m in ipairs(Keysyms.modifiers) do modifier_rank[m.name] = i end

--- The largest keysym (X11 keysyms are 29-bit values).
local KEYSYM_MAX = 0x1FFFFFFF

--- One remembered combo in canonical form (modifiers once each, in press order), or nil when it is
--- not one: known modifiers, a keysym in range, and a key or at least one modifier.
local function clean_combo(c)
    if type(c) ~= "table" or type(c.mods) ~= "table" or type(c.label) ~= "string" then return nil end
    local keysym = c.keysym
    if keysym ~= nil and (type(keysym) ~= "number" or keysym ~= math.floor(keysym)
            or keysym < 0 or keysym > KEYSYM_MAX) then
        return nil
    end
    local seen = {}
    for _, name in ipairs(c.mods) do
        if not modifier_rank[name] then return nil end
        seen[name] = true
    end
    local mods = {}
    for _, m in ipairs(Keysyms.modifiers) do
        if seen[m.name] then mods[#mods + 1] = m.name end
    end
    if keysym == nil and #mods == 0 then return nil end
    return { mods = mods, keysym = keysym, label = c.label }
end

--- A key identifying a combo regardless of the order its modifiers were listed in.
local function combo_key(c)
    return table.concat(c.mods, "+") .. "|" .. tostring(c.keysym)
end

--- Settings whose value is not just "the type of the default": each maps a raw value to a usable
--- one, falling back to the default.
local SETTING_CHECKS = {
    page_buttons = function(value)
        if value == "keys" or value == "wheel" then return value end
        return Settings.DEFAULTS.page_buttons
    end,
    scaling = function(value)
        if value == "sharp" then return value end
        return Settings.DEFAULTS.scaling
    end,
    remote_contrast = function(value)
        for _, level in ipairs(Settings.CONTRAST_LEVELS) do
            if value == level then return value end
        end
        return Settings.DEFAULTS.remote_contrast
    end,
    pointer_speed = function(value)
        if Settings.POINTER_SPEEDS[value] then return value end
        return Settings.DEFAULTS.pointer_speed
    end,
    recent_combos = function(value)
        local list = {}
        if type(value) ~= "table" then return list end
        local seen = {}
        for _, c in ipairs(value) do
            if #list >= Settings.RECENT_COMBOS_MAX then break end
            local combo = clean_combo(c)
            if combo and not seen[combo_key(combo)] then
                seen[combo_key(combo)] = true
                list[#list + 1] = combo
            end
        end
        return list
    end,
}

--- VNC server defaults (the `server` sub-table). See @{vnc.server}.
Settings.SERVER_DEFAULTS = {
    ip = "0.0.0.0",                  -- bind address; 0.0.0.0 serves every interface
    port = 5900,
    password = "",                   -- empty = no authentication (RFB "None" security)
    autostart = false,               -- start the server with KOReader (main.lua defers it)
}

--- Environment variables that override the server settings for one run.
---
--- They are read once (at load) and never written back to the settings file: a run binds what the
--- environment says while the menu keeps showing and editing the stored values.
Settings.ENV = {
    enable   = "VNC_KOPLUGIN_ENABLE_SERVER",   -- decides the boot start, in place of `autostart`
    host     = "VNC_KOPLUGIN_SERVER_HOST",     -- overrides `ip`
    port     = "VNC_KOPLUGIN_SERVER_PORT",     -- overrides `port`
    password = "VNC_KOPLUGIN_SERVER_PASSWORD",  -- overrides `password`
}

--[[--
Reads the server environment once, behind a lookup seam so it is testable without touching the
real environment.

Rules (a value that is `nil` in the result means "no opinion": use the stored setting):

* `enable`: unset or set-but-empty -> no opinion. Trimmed, case-insensitive `0`, `no` and `false`
  -> do not start; anything else non-empty -> start. An accidentally exported empty variable must
  therefore not open a listening server.
* `host`: empty -> no opinion, otherwise the (trimmed) bind address.
* `port`: an integer 1..65535 -> the port. Anything else is ignored with a warning.
* `password`: empty-but-set is a meaningful override ("no password"), so any set value is kept
  verbatim (not trimmed).

--- @tparam[opt] function getenv `name -> value|nil`; defaults to `os.getenv`
--- @treturn table `{ enable, host, port, password }`; absent means no opinion
]]
function Settings.read_env(getenv)
    getenv = getenv or os.getenv
    local env = {}

    local enable = getenv(Settings.ENV.enable)
    if enable ~= nil then
        enable = enable:gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if enable ~= "" then
            env.enable = not (enable == "0" or enable == "no" or enable == "false")
        end
    end

    local host = getenv(Settings.ENV.host)
    if host ~= nil then
        host = host:gsub("^%s+", ""):gsub("%s+$", "")
        if host ~= "" then env.host = host end
    end

    local port = getenv(Settings.ENV.port)
    if port ~= nil then
        local n = tonumber(port)
        if n and n == math.floor(n) and n >= 1 and n <= 65535 then
            env.port = math.floor(n)
        else
            logger.warn("vnc: ignoring an invalid", Settings.ENV.port .. ":", port)
        end
    end

    local password = getenv(Settings.ENV.password)
    if password ~= nil then env.password = password end

    return env
end

--- Opens (and returns) the settings store at `path`.
--- @param path string
--- @param[opt] function getenv lookup seam for @{Settings.read_env}; defaults to `os.getenv`
--- @treturn table settings object with fields `ls` (LuaSettings) and `data` (raw table)
function Settings.open(path, getenv)
    local ls = LuaSettings:open(path)
    -- The environment is read once, here, and kept away from `data` so it can never be flushed.
    local self = setmetatable({ ls = ls, data = ls.data, env = Settings.read_env(getenv) }, Settings)
    self:normalise()
    local names = {}
    for _, key in ipairs({ "enable", "host", "port", "password" }) do
        if self.env[key] ~= nil then names[#names + 1] = key end
    end
    if #names > 0 then
        logger.info("vnc: environment overrides in effect for this run: " .. table.concat(names, ", "))
    end
    return self
end

--- Coerces a raw value to the type of the corresponding default.
local function coerce_like(value, default)
    local want = type(default)
    if want == "number" then
        local n = tonumber(value)
        return n or default
    elseif want == "boolean" then
        if type(value) == "boolean" then return value end
        return default
    elseif want == "string" then
        if type(value) == "string" then return value end
        return default
    end
    return value
end

--- A Tight level (JPEG quality or compression level): an integer 0..9, else false (server default).
local function level_or_off(value)
    if type(value) == "number" and value == math.floor(value) and value >= 0 and value <= 9 then
        return value
    end
    return false
end

--- The picture-quality presets of the viewer's Display panel, each a set of the four profile
--- fields above (false = the server's default). Documented in README.md.
Settings.QUALITY_PRESETS = {
    { id = "best", label = _("Best"), color_depth = 24, enable_tight = false, jpeg_quality = false,
      compress_level = false },
    { id = "balanced", label = _("Balanced"), color_depth = 16, enable_tight = true, jpeg_quality = 6,
      compress_level = 6 },
    { id = "fast", label = _("Fast"), color_depth = 8, enable_tight = true, jpeg_quality = 3,
      compress_level = 9 },
}

--- The preset a profile's picture fields match exactly, else "custom".
--- @tparam table profile a cleaned profile (see @{Settings:get_profile})
--- @treturn string "best", "balanced", "fast" or "custom"
function Settings.preset_of(profile)
    for _i, preset in ipairs(Settings.QUALITY_PRESETS) do
        if profile.color_depth == preset.color_depth and profile.enable_tight == preset.enable_tight
            and profile.jpeg_quality == preset.jpeg_quality
            and profile.compress_level == preset.compress_level then
            return preset.id
        end
    end
    return "custom"
end

--- Cleans one profile table, dropping unknown fields and coercing types.
--- @tparam table p raw profile
--- @tparam[opt] boolean tight_default `enable_tight` for a profile that has no such field
--- @treturn table|nil cleaned profile, or nil when it has no usable name
local function clean_profile(p, tight_default)
    if type(p) ~= "table" then return nil end
    local name = p.name
    if type(name) ~= "string" then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    local port = tonumber(p.port) or 5900
    port = math.floor(port)
    if port < 1 or port > 65535 then port = 5900 end
    return {
        name = name,
        host = type(p.host) == "string" and p.host or "",
        port = port,
        password = type(p.password) == "string" and p.password or "",
        -- Only the boolean true counts: a hand-edited `"yes"` (or anything else) means "no".
        autoconnect = p.autoconnect == true,
        pointer_mode = p.pointer_mode == "mouse" and "mouse" or "touch",
        color_depth = (p.color_depth == 16 or p.color_depth == 8) and p.color_depth or 24,
        enable_tight = (p.enable_tight == nil and tight_default or p.enable_tight) == true,
        jpeg_quality = level_or_off(p.jpeg_quality),
        compress_level = level_or_off(p.compress_level),
    }
end

--[[--
Keeps a raw settings table in shape, in place.

Fills in missing global settings, drops settings and profiles that are not usable, and closes
holes in the profile array. Never raises, so a broken file cannot keep the plugin from loading.
]]
function Settings:normalise()
    if type(self.data) ~= "table" then
        self.data = {}
    end
    local data = self.data

    for key in pairs(data) do
        if not known_data_key[key] then
            logger.dbg("vnc: dropping unknown settings key", key)
            data[key] = nil
        end
    end

    local function normalise_section(key, defaults, checks)
        if type(data[key]) ~= "table" then data[key] = {} end
        local section = data[key]
        for name, default in pairs(defaults) do
            local check = checks and checks[name]
            if check then
                section[name] = check(section[name])
            else
                section[name] = coerce_like(section[name], default)
            end
        end
        for name in pairs(section) do
            if defaults[name] == nil then
                logger.dbg("vnc: dropping unknown", key, "key", name)
                section[name] = nil
            end
        end
        return section
    end

    -- `enable_tight` used to be a global setting (and was released as one): a user who turned it on
    -- keeps it, as the value of every profile that has no choice of its own. The global itself is
    -- dropped with the other unknown settings below.
    local legacy_tight = type(data.settings) == "table" and data.settings.enable_tight == true
    normalise_section("settings", Settings.DEFAULTS, SETTING_CHECKS)
    local server = normalise_section("server", Settings.SERVER_DEFAULTS)
    server.port = math.max(1, math.min(65535, math.floor(server.port)))
    if server.ip == "" then server.ip = Settings.SERVER_DEFAULTS.ip end

    if type(data.profiles) ~= "table" then data.profiles = {} end
    local cleaned = {}
    for _, p in ipairs(data.profiles) do
        local c = clean_profile(p, legacy_tight)
        if c then
            cleaned[#cleaned + 1] = c
        else
            logger.dbg("vnc: dropping an unusable connection profile")
        end
    end
    data.profiles = cleaned

    -- At most one profile may auto-connect: keep the first flagged one and clear the rest, so a
    -- hand-edited file cannot break the invariant the UI and the boot start rely on.
    local autoconnect_seen = false
    for _, p in ipairs(cleaned) do
        if p.autoconnect then
            if autoconnect_seen then
                logger.dbg("vnc: clearing a second autoconnect profile:", p.name)
                p.autoconnect = false
            else
                autoconnect_seen = true
            end
        end
    end
end

--- @treturn table array of connection profiles
function Settings:profiles()
    return self.data.profiles
end

--- Finds a profile by name (exact match).
--- @treturn table|nil
function Settings:get_profile(name)
    for _, p in ipairs(self:profiles()) do
        if p.name == name then return p end
    end
    return nil
end

--- The one profile flagged to auto-connect at start, if any.
---
--- At most one profile ever carries the flag (@{Settings:normalise} and @{Settings:save_profile}
--- both enforce it), so the first match is the only match.
--- @treturn table|nil
function Settings:autoconnect_profile()
    for _, p in ipairs(self:profiles()) do
        if p.autoconnect then return p end
    end
    return nil
end

--- Makes `name` the auto-connect profile, clearing the flag on every other one (or clears it
--- everywhere when `name` is nil).
--- @tparam string|nil name
function Settings:set_autoconnect(name)
    for _, p in ipairs(self:profiles()) do
        p.autoconnect = name ~= nil and p.name == name
    end
end

--- Adds or updates a profile, keyed by name.
---
--- An omitted `autoconnect` or picture field (`color_depth`, `enable_tight`, `jpeg_quality`,
--- `compress_level`) keeps the value the profile had, so an editor that does not know a field
--- cannot reset it.
--- @param p table profile (see @{Settings.PROFILE_FIELDS})
--- @param existing_name string|nil name to replace; when nil, `p.name` must be unused
--- @treturn boolean, string|nil true on success, else false and an error message
function Settings:save_profile(p, existing_name)
    local name = type(p.name) == "string" and p.name:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if name == "" then
        return false, "empty name"
    end
    if type(p.host) ~= "string" or p.host:gsub("%s", "") == "" then
        return false, "empty host"
    end
    local port = tonumber(p.port) or 5900
    port = math.floor(port)
    if port < 1 or port > 65535 then
        return false, "invalid port"
    end

    local profiles = self:profiles()
    local idx, found
    for i, existing in ipairs(profiles) do
        if existing.name == name then
            idx, found = i, existing
            break
        end
    end
    if found and name ~= existing_name then
        return false, "duplicate name"
    end
    if not found and existing_name then
        -- Rename: the old name must exist and the new one must be free.
        for i, existing in ipairs(profiles) do
            if existing.name == existing_name then
                idx, found = i, existing
                break
            end
        end
        if not found then
            return false, "no such profile"
        end
    end

    -- An omitted field means "keep what this profile had" (or the default for a new one).
    local function given_or_kept(key)
        if p[key] ~= nil then return p[key] end
        if found then return found[key] end
        return nil
    end
    local cleaned = clean_profile({
        name = name, host = p.host, port = port, password = p.password,
        autoconnect = given_or_kept("autoconnect"),
        pointer_mode = given_or_kept("pointer_mode"),
        color_depth = given_or_kept("color_depth"),
        enable_tight = given_or_kept("enable_tight"),
        jpeg_quality = given_or_kept("jpeg_quality"),
        compress_level = given_or_kept("compress_level"),
    })
    if idx then
        profiles[idx] = cleaned
    else
        profiles[#profiles + 1] = cleaned
    end
    if cleaned.autoconnect then
        -- Only one profile may carry it: saving it here clears it on every other profile.
        for _, other in ipairs(profiles) do
            if other ~= cleaned then other.autoconnect = false end
        end
    end
    return true
end

--- Deletes a profile by name.
--- @treturn boolean whether a profile was removed
function Settings:delete_profile(name)
    local profiles = self:profiles()
    for i, p in ipairs(profiles) do
        if p.name == name then
            table.remove(profiles, i)
            return true
        end
    end
    return false
end

--- The VNC server configuration sub-table (bind address, port, password).
--- @treturn table
function Settings:server()
    return self.data.server
end

--- Whether the server should start with KOReader. The environment's enable variable, when it has
--- an opinion, wins over the stored `autostart` setting; otherwise the stored setting decides.
--- @treturn boolean
function Settings:should_autostart()
    if self.env.enable ~= nil then return self.env.enable end
    return self.data.server.autostart == true
end

--- The server settings this *run* uses: the stored table with the environment overrides merged in.
---
--- The overrides live outside `data.server`, so `flush()` cannot persist them. Without an override
--- the stored table itself is returned, so the menu and a running server share it exactly as
--- before; with one, the run gets a snapshot and the menu keeps showing/editing the stored values.
--- @treturn table
function Settings:server_for_run()
    local stored = self.data.server
    local env = self.env
    if env.host == nil and env.port == nil and env.password == nil then
        return stored
    end
    return {
        ip = env.host ~= nil and env.host or stored.ip,
        port = env.port ~= nil and env.port or stored.port,
        password = env.password ~= nil and env.password or stored.password,
        autostart = stored.autostart,
    }
end

--- @treturn any the global setting `key`, or nil
function Settings:get_setting(key)
    return self.data.settings[key]
end

--- Sets a global setting.
function Settings:set_setting(key, value)
    self.data.settings[key] = value
end

--- Writes the settings file.
function Settings:flush()
    self.ls.data = self.data
    self.ls:flush()
end

return Settings
