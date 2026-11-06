--[[--
Connection list, profile actions, profile editor (with its picture settings) and delete
confirmation.

Every surface here has an explicit way back, and each one returns to the surface it was
opened from: the list is the root, `profile_actions` goes back to the list, the editor goes
back to whatever opened it, and a failed connection returns to the list instead of dropping
the user out of the plugin. `Menu`, `ButtonDialog` and the editor's own `id = "close"` button
(which `InputDialog:onCloseDialog` invokes for the Back key) all funnel into those callbacks.

@module vnc.dialogs
]]

local _ = require("gettext")
local T = require("ffi/util").template

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")

local Dialogs = {}

local DEFAULT_PORT = 5900

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---------------------------------------------------------------- picture settings

local COLOR_DEPTHS = {
    { label = _("24-bit"), value = 24 },
    { label = _("16-bit"), value = 16 },
    { label = _("8-bit"), value = 8 },
}

local NEXT_CONNECTION = _("Takes effect on the next connection.")

--- Long-press help for each picture setting.
local PICTURE_HELP = {
    color_depth = NEXT_CONNECTION,
    scaling = _("Scales by repeating pixels instead of blending them. Much faster on large changes; text looks crisper but can look uneven at non-whole zoom levels. Applies immediately."),
    enable_tight = NEXT_CONNECTION .. "\n"
        .. _("Tight can send JPEG, so lowering JPEG quality saves bandwidth on photos."),
    jpeg_quality = NEXT_CONNECTION .. "\n" .. _("Only used at 24-bit colour."),
    compress_level = NEXT_CONNECTION,
}

--- Always shown in the picture dialog: what each setting does, and when it applies.
local PICTURE_EXPLANATION = table.concat({
    _("Colour depth: fewer bits = less data. 16-bit looks the same on e-ink greys."),
    _("Sharp scaling: faster redraws when the zoom is not 100%; text looks crisper."),
    _("Tight: an extra compression method; needed for the JPEG and compression settings."),
    _("JPEG quality: lower = smaller photos/video (24-bit colour only)."),
    _("Compression level: higher = less data, more work for the PC."),
    _("Depth, Tight, JPEG and compression take effect on the next connection; sharp scaling right away."),
}, "\n")

-- Marks the Tight pseudo-encodings as sub-items of the Tight row.
local SUB_ITEM = "   \u{21B3} "

--- Profile fields that are only read when connecting (see @{vnc.session}).
local RECONNECT_FIELDS = {
    "host", "port", "password", "color_depth", "enable_tight", "jpeg_quality", "compress_level",
}

local function level_label(value)
    return value == false and _("Off") or tostring(value)
end

local function depth_label(depth)
    for _i, choice in ipairs(COLOR_DEPTHS) do
        if choice.value == depth then return choice.label end
    end
    return tostring(depth)
end

local function show_help(key)
    return function() UIManager:show(InfoMessage:new{ text = PICTURE_HELP[key] }) end
end

--[[--
The editor's one-line summary of a profile's picture settings, e.g.
`Picture: 16-bit, sharp, Tight, JPEG 3, compr. 9`. JPEG quality and compression level are Tight
pseudo-encodings, so they only show (and only matter) with Tight on.

--- @tparam table picture `{ color_depth, scaling, enable_tight, jpeg_quality, compress_level }`
--- @treturn string
]]
function Dialogs.picture_summary(picture)
    local parts = { depth_label(picture.color_depth) }
    if picture.scaling == "sharp" then
        parts[#parts + 1] = _("sharp")
    end
    if picture.enable_tight then
        parts[#parts + 1] = _("Tight")
        if type(picture.jpeg_quality) == "number" then
            parts[#parts + 1] = T(_("JPEG %1"), picture.jpeg_quality)
        end
        if type(picture.compress_level) == "number" then
            parts[#parts + 1] = T(_("compr. %1"), picture.compress_level)
        end
    end
    return T(_("Picture: %1"), table.concat(parts, ", "))
end

--[[--
The picture settings of one connection: colour depth, sharp scaling, Tight, and Tight's JPEG
quality and compression level (indented under it, and marked as needing it while it is off). An
explanation of every setting stays visible above the rows (ButtonDialog's title area).

Edits `picture` in place. Picking a value reopens this dialog so its labels follow; Done, Back or
a tap outside calls `on_done`. Nothing is stored here: the editor saves (or drops) the choice.

--- @tparam table picture `{ color_depth, scaling, enable_tight, jpeg_quality, compress_level }`
--- @tparam function on_done
--- @treturn table the ButtonDialog (the caller shows it)
]]
function Dialogs.picture_settings(picture, on_done)
    local dialog
    local function reopen()
        UIManager:show(Dialogs.picture_settings(picture, on_done))
    end
    -- A sub-dialog of choices (an array of button rows of `{ label, value }`) for `key`.
    local function choose(title, rows, key)
        return function()
            UIManager:close(dialog)
            local chooser
            local buttons = {}
            for _i, row in ipairs(rows) do
                local button_row = {}
                for _j, choice in ipairs(row) do
                    button_row[#button_row + 1] = {
                        text = choice.label,
                        callback = function()
                            UIManager:close(chooser)
                            picture[key] = choice.value
                            reopen()
                        end,
                    }
                end
                buttons[#buttons + 1] = button_row
            end
            chooser = ButtonDialog:new{
                title = title,
                buttons = buttons,
                tap_close_callback = reopen,
            }
            UIManager:show(chooser)
        end
    end
    local level_rows = { { { label = level_label(false), value = false } }, {}, {} }
    for value = 0, 9 do
        local row = level_rows[value < 5 and 2 or 3]
        row[#row + 1] = { label = level_label(value), value = value }
    end

    local function toggle(update)
        return function()
            UIManager:close(dialog)
            update()
            reopen()
        end
    end
    -- A Tight pseudo-encoding row: without Tight the server never sees it.
    local function tight_sub_item(label, title, key)
        return { {
            text = SUB_ITEM .. T(label, picture.enable_tight and level_label(picture[key])
                or _("needs Tight")),
            align = "left",
            enabled = picture.enable_tight,
            allow_hold_when_disabled = true,
            callback = choose(title, level_rows, key),
            hold_callback = show_help(key),
        } }
    end

    dialog = ButtonDialog:new{
        title = PICTURE_EXPLANATION,
        buttons = {
            { {
                text = T(_("Colour depth: %1"), depth_label(picture.color_depth)),
                align = "left",
                callback = choose(_("Colour depth"), { COLOR_DEPTHS }, "color_depth"),
                hold_callback = show_help("color_depth"),
            } },
            { {
                text = picture.scaling == "sharp" and _("Sharp scaling (faster): on")
                    or _("Sharp scaling (faster): off"),
                align = "left",
                callback = toggle(function()
                    picture.scaling = picture.scaling == "sharp" and "smooth" or "sharp"
                end),
                hold_callback = show_help("scaling"),
            } },
            { {
                text = picture.enable_tight and _("Tight encoding: on") or _("Tight encoding: off"),
                align = "left",
                callback = toggle(function() picture.enable_tight = not picture.enable_tight end),
                hold_callback = show_help("enable_tight"),
            } },
            tight_sub_item(_("JPEG quality: %1"), _("JPEG quality"), "jpeg_quality"),
            tight_sub_item(_("Compression level: %1"), _("Compression level"), "compress_level"),
            { {
                text = _("Done"),
                callback = function()
                    UIManager:close(dialog)
                    on_done()
                end,
            } },
        },
        tap_close_callback = on_done,
    }
    return dialog
end

--[[--
Shows a (new) connection list. `plugin:show_connection_list()` is the way to *go back* to it,
since it also drops a list that is already on screen.

--- @tparam table plugin
--- @tparam[opt] table opts `{ on_close = fn }`
--- @treturn table the Menu that was shown
]]
function Dialogs.open_connection_list(plugin, opts)
    local menu = Dialogs.connection_list(plugin, opts)
    UIManager:show(menu)
    return menu
end

--[[--
The list of saved connections, plus "New connection…" and "Manage connections…".

--- @tparam table plugin
--- @tparam[opt] table opts `{ on_close = fn }`, `on_close` runs when the list is closed
--- @treturn table the Menu (the caller shows it)
]]
function Dialogs.connection_list(plugin, opts)
    opts = opts or {}
    local menu
    -- Where every sub-dialog returns to.
    local function back() plugin:show_connection_list() end

    local profiles = plugin.settings:profiles()
    local item_table = {}
    for _i, profile in ipairs(profiles) do
        item_table[#item_table + 1] = {
            -- The marker is how the list shows which connection starts with KOReader.
            text = profile.autoconnect and T(_("%1 (auto connect)"), profile.name) or profile.name,
            mandatory = string.format("%s:%d", profile.host, profile.port),
            callback = function()
                plugin:close_connection_list()
                plugin:connect_profile(profile.name, back)
            end,
        }
    end
    table.insert(item_table, {
        text = _("New connection…"),
        callback = function()
            plugin:close_connection_list()
            Dialogs.edit_profile(plugin, nil, { on_back = back })
        end,
    })
    if #profiles > 0 then
        local manage = {}
        for _, profile in ipairs(profiles) do
            manage[#manage + 1] = {
                text = profile.name,
                callback = function()
                    plugin:close_connection_list()
                    UIManager:show(Dialogs.profile_actions(plugin, profile, { on_back = back }))
                end,
            }
        end
        table.insert(item_table, {
            text = _("Manage connections…"),
            sub_item_table = manage,
        })
    end

    menu = Menu:new{
        title = _("Connections"),
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        item_table = item_table,
        close_callback = opts.on_close,
    }
    return menu
end

--[[--
Connect / Edit / Delete for one connection, with a Back button that returns to `opts.on_back`
(the connection list). Tapping outside, or Back, does the same.

--- @tparam table plugin
--- @tparam table profile
--- @tparam[opt] table opts `{ on_back = fn }`
--- @treturn table the ButtonDialog (the caller shows it)
]]
function Dialogs.profile_actions(plugin, profile, opts)
    opts = opts or {}
    local function back()
        if opts.on_back then opts.on_back() else Dialogs.open_connection_list(plugin) end
    end
    local function reopen_actions()
        UIManager:show(Dialogs.profile_actions(plugin, profile, opts))
    end

    local dialog
    dialog = ButtonDialog:new{
        title = profile.name,
        buttons = {
            { {
                text = _("Connect"),
                callback = function()
                    UIManager:close(dialog)
                    plugin:connect_profile(profile.name, back)
                end,
            } },
            { {
                -- A per-connection switch for the boot start. Turning it on for one connection
                -- turns it off everywhere else (only one profile may carry it), which is why the
                -- dialog is reopened afterwards: the label has to reflect the new state.
                text = profile.autoconnect and _("Auto connect on start: on")
                    or _("Auto connect on start: off"),
                callback = function()
                    if profile.autoconnect then
                        plugin.settings:set_autoconnect(nil)
                    else
                        plugin.settings:set_autoconnect(profile.name)
                    end
                    plugin.settings:flush()
                    UIManager:close(dialog)
                    reopen_actions()
                end,
            } },
            { {
                text = _("Edit"),
                callback = function()
                    UIManager:close(dialog)
                    Dialogs.edit_profile(plugin, profile, { on_back = reopen_actions })
                end,
            } },
            { {
                text = _("Delete"),
                callback = function()
                    UIManager:close(dialog)
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete connection %1?"), profile.name),
                        ok_text = _("Delete"),
                        cancel_text = _("Cancel"),
                        dismissable = false,
                        ok_callback = function()
                            plugin:delete_profile(profile.name)
                            back()
                        end,
                        cancel_callback = reopen_actions,
                    })
                end,
            } },
            { {
                text = _("Back"),
                callback = function()
                    UIManager:close(dialog)
                    back()
                end,
            } },
        },
        dismissable = true,
        tap_close_callback = back,
    }
    return dialog
end

--[[--
The connection editor. Cancel (or the Back key, which `InputDialog:onCloseDialog` routes to the
`id = "close"` button) and a successful save both call `opts.on_back`.

The Picture button opens @{Dialogs.picture_settings} over the editor; the choice is held here and
only stored by Save. Saving the connection that is live applies its scaling at once (see
`VNC:save_profile`) and says that a reconnect applies the rest, when any of that changed.

--- @tparam table plugin
--- @tparam[opt] table profile profile to edit, or nil to create one
--- @tparam[opt] table opts `{ on_back = fn }`
--- @treturn table the dialog that was shown
]]
function Dialogs.edit_profile(plugin, profile, opts)
    opts = opts or {}
    local dialog
    local function finish(saved)
        UIManager:close(dialog)
        if saved and opts.on_saved then opts.on_saved() end
        if opts.on_back then opts.on_back() end
    end
    local function report(message)
        UIManager:show(InfoMessage:new{ text = message, timeout = 3 })
    end

    local picture = {
        color_depth = profile and profile.color_depth or 24,
        enable_tight = profile and profile.enable_tight or false,
        jpeg_quality = profile and profile.jpeg_quality or false,
        compress_level = profile and profile.compress_level or false,
        scaling = profile and profile.scaling or "smooth",
    }
    local picture_button
    picture_button = {
        text = Dialogs.picture_summary(picture),
        id = "picture",
        callback = function()
            -- The editor stays up underneath (so the typed fields are kept); only its keyboard
            -- makes way for the picture dialog.
            dialog:onCloseKeyboard()
            UIManager:show(Dialogs.picture_settings(picture, function()
                local label = Dialogs.picture_summary(picture)
                picture_button.text = label  -- for a re-init from `buttons` (keyboard toggles)
                local button = dialog.button_table:getButtonById("picture")
                button:setText(label, button.width)
                dialog:refreshButtons()
                dialog:onShowKeyboard()
            end))
        end,
    }

    dialog = MultiInputDialog:new{
        title = profile and _("Edit connection") or _("New connection"),
        fields = {
            {
                text = profile and profile.name or "",
                hint = _("Name"),
            },
            {
                text = profile and profile.host or "",
                hint = _("Host name or IP address"),
            },
            {
                text = profile and tostring(profile.port) or tostring(DEFAULT_PORT),
                hint = T(_("Port (default %1)"), DEFAULT_PORT),
                input_type = "number",
            },
            {
                text = profile and profile.password or "",
                hint = _("Password (optional)"),
                text_type = "password",
            },
        },
        buttons = { { picture_button }, {
            {
                -- `id = "close"` makes this the dialog's cancel action: the Back key and the
                -- title bar's close button both end up here (see InputDialog:onCloseDialog).
                text = _("Cancel"),
                id = "close",
                callback = function() finish(false) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local name = trim(fields[1])
                    local host = trim(fields[2])
                    local port_text = trim(fields[3])
                    local password = fields[4] or ""

                    if name == "" then
                        return report(_("Please give the connection a name."))
                    end
                    local existing = plugin.settings:get_profile(name)
                    if existing and (not profile or profile.name ~= name) then
                        return report(T(_("A connection named %1 already exists."), name))
                    end
                    if host == "" then
                        return report(_("Please enter a host name or IP address."))
                    end
                    local port = port_text == "" and DEFAULT_PORT or tonumber(port_text)
                    if not port or port < 1 or port > 65535 then
                        return report(T(_("The port must be a number between 1 and %1."), 65535))
                    end

                    local saved = {
                        name = name,
                        host = host,
                        port = math.floor(port),
                        password = password,
                        color_depth = picture.color_depth,
                        enable_tight = picture.enable_tight,
                        jpeg_quality = picture.jpeg_quality,
                        compress_level = picture.compress_level,
                        scaling = picture.scaling,
                    }
                    local needs_reconnect = false
                    for _i, key in ipairs(RECONNECT_FIELDS) do
                        if profile and saved[key] ~= profile[key] then needs_reconnect = true end
                    end
                    plugin:save_profile(saved, profile and profile.name or nil)
                    -- (a rename moves the live session to the new name)
                    local session = profile and plugin.sessions and plugin.sessions[name]
                    finish(true)
                    if needs_reconnect and session and session:is_connected() then
                        UIManager:show(InfoMessage:new{
                            text = _("Reconnect to apply the new settings."),
                            timeout = 3,
                        })
                    end
                end,
            },
        } },
        dismissable = false,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return dialog
end

Dialogs.DEFAULT_PORT = DEFAULT_PORT

return Dialogs
