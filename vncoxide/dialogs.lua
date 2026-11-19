--[[--
Connection list, profile actions, profile editor (with its picture settings) and delete
confirmation.

Every surface here has an explicit way back, and each one returns to the surface it was
opened from: the list is the root, `profile_actions` goes back to the list, the editor goes
back to whatever opened it, and a failed connection returns to the list instead of dropping
the user out of the plugin. `Menu`, `ButtonDialog` and the editor's own `id = "close"` button
(which `InputDialog:onCloseDialog` invokes for the Back key) all funnel into those callbacks.

@module vncoxide.dialogs
]]

local _ = require("gettext")
local T = require("ffi/util").template

local BenchResults = require("vncoxide/benchresults")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
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

-- The explanation of each setting: shown above the rows (names in bold) and, per setting, as the
-- row's long-press help.
local PICTURE_TEXT = {
    color_depth = {
        name = _("Colour depth"),
        body = _("how many bits the PC sends per pixel. 24-bit is full colour. 16-bit halves the data, and greys still look smooth on e-ink. 8-bit quarters it, but greys show visible steps."),
    },
    enable_tight = {
        name = _("Tight"),
        body = _("a different packing format. Its main advantage is JPEG: photo-like areas (pictures, video, images in web pages) can be sent as JPEG, which is far smaller than lossless. Worth trying on slow Wi-Fi when the screen shows images. Without JPEG it is lossless, like the default format."),
    },
    jpeg_quality = {
        name = _("JPEG quality"),
        body = _("Off sends everything lossless. 0–9 sends photo-like areas as JPEG; lower is smaller and blurrier. Only works at 24-bit colour."),
    },
    compress_level = {
        name = _("Compression level"),
        body = _("how hard the PC packs the lossless parts of the screen: text, menus and flat areas. JPEG areas are not affected. With JPEG on, a higher level also keeps areas with more shades, such as smooth text, lossless instead of turning them into JPEG. Higher means fewer bytes and more work for the PC; unpacking on the e-reader costs about the same. On x11vnc only a few values differ: with JPEG, 0–1 act as 1 and 2–9 as 2, so pick 2; without JPEG, 0 sends the data unpacked (for a fast network) and 1–9 all act as 1. Other servers may use the whole range. Off uses the server's default."),
    },
}
local PICTURE_ORDER = { "color_depth", "enable_tight", "jpeg_quality", "compress_level" }
local PICTURE_FOOTER = _("Changes take effect on the next connection.")
-- Only in the Help viewer, after the per-setting paragraphs.
local PICTURE_ADVICE = {
    {
        name = _("Which is fastest?"),
        body = _("it depends on the PC, the network and what is on the screen: on a PocketBook Era, 8-bit with compression has felt faster than 24-bit even on fast Wi-Fi. Measure it: in the connection's menu, tap Find fastest picture settings with your usual content on the PC screen."),
    },
    {
        name = _("Scale on the PC, not on the e-reader"),
        body = _("letting the server send an already scaled image (the server script's -z option, e.g. -z 2; add --sharp for crisp pixel doubling) is better than any viewer zoom other than 100%: at 100% the e-reader only copies pixels, at any other zoom it has to compute every screen pixel. If you do zoom on the e-reader, turn Sharp scaling on (toolbar Display button). With -z the server script uses its own small server with ffmpeg instead of x11vnc (install ffmpeg on the PC), because x11vnc drew the mouse arrow in the wrong place when it scaled part of the screen."),
    },
    {
        name = _("Example"),
        body = _("to fill the Era's 1264×1680 screen with a 632×840 area of the PC, start the server with: vnc-server.py -s 632x840 -z 2, and keep the viewer at 100%. The PC doubles the image, the e-reader just copies it. Measured on an Era: a full redraw took 17 ms at 100%, against 306 ms when the e-reader itself scaled by 2 (before partial redraws were added). The image has four times as many pixels to send, which a fast network carries easily."),
    },
}

--- Long-press help for each picture setting (plain text).
local PICTURE_HELP = {}
for key, entry in pairs(PICTURE_TEXT) do PICTURE_HELP[key] = entry.name .. ": " .. entry.body end

--- Shown by the picture dialog's Help button in a TextViewer (its ScrollTextWidget/TextBoxWidget
--- honours PTF): what each setting does, with the setting names in bold.
local PICTURE_EXPLANATION
do
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local paragraphs = {}
    for _i, key in ipairs(PICTURE_ORDER) do
        local entry = PICTURE_TEXT[key]
        paragraphs[#paragraphs + 1] = TextBoxWidget.PTF_BOLD_START .. entry.name
            .. TextBoxWidget.PTF_BOLD_END .. ": " .. entry.body
    end
    paragraphs[#paragraphs + 1] = PICTURE_FOOTER
    for _i, entry in ipairs(PICTURE_ADVICE) do
        paragraphs[#paragraphs + 1] = TextBoxWidget.PTF_BOLD_START .. entry.name
            .. TextBoxWidget.PTF_BOLD_END .. ": " .. entry.body
    end
    PICTURE_EXPLANATION = TextBoxWidget.PTF_HEADER .. table.concat(paragraphs, "\n\n")
end

-- Marks the Tight pseudo-encodings as sub-items of the Tight row.
local SUB_ITEM = "   \u{21B3} "

--- Profile fields that are only read when connecting (see @{vncoxide.session}).
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
`Picture: 16-bit, Tight, JPEG 3, compr. 9`. JPEG quality and compression level are Tight
pseudo-encodings, so they only show (and only matter) with Tight on.

--- @tparam table picture `{ color_depth, enable_tight, jpeg_quality, compress_level }`
--- @treturn string
]]
function Dialogs.picture_summary(picture)
    local parts = { depth_label(picture.color_depth) }
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
The picture settings of one connection: colour depth, Tight, and Tight's JPEG
quality and compression level (indented under it, dimmed while it is off). An
Help button opens the explanation of every setting in a scrollable viewer on top of this dialog.

Edits `picture` in place. Picking a value reopens this dialog so its labels follow; Done, Back or
a tap outside calls `on_done`. Nothing is stored here: the editor saves (or drops) the choice.

--- @tparam table picture `{ color_depth, enable_tight, jpeg_quality, compress_level }`
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
    -- A Tight pseudo-encoding row: dimmed (but still long-pressable) while Tight is off.
    local function tight_sub_item(label, title, key)
        return { {
            text = SUB_ITEM .. T(label, level_label(picture[key])),
            align = "left",
            enabled = picture.enable_tight,
            allow_hold_when_disabled = true,
            callback = choose(title, level_rows, key),
            hold_callback = show_help(key),
        } }
    end

    dialog = ButtonDialog:new{
        title = _("Long-press a setting for details, or tap Help."),
        buttons = {
            { {
                text = T(_("Colour depth: %1"), depth_label(picture.color_depth)),
                align = "left",
                callback = choose(_("Colour depth"), { COLOR_DEPTHS }, "color_depth"),
                hold_callback = show_help("color_depth"),
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
                text = _("Help"),
                callback = function()
                    -- On top of this dialog, which stays as it is (choices and hidden keyboard).
                    UIManager:show(TextViewer:new{ title = _("Picture settings"), text = PICTURE_EXPLANATION })
                end,
            } },
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

-- ---------------------------------------------------------------- picture benchmark

--- The benchmark engine; tests replace it with a stand-in (nil means @{vncoxide.benchmark}).
Dialogs.Benchmark = nil

local BENCH_INTRO = _("This test presses keys on your PC and times how fast each change reaches this screen.\n\nOn the PC:\n1. Open the test page bench-page.html from the plugin's tools folder in a browser.\n2. Make it full screen (F11) on the shared screen.\n3. Click once into the page so it has the keyboard focus.\n\nDuring the test (about 4 minutes) don't touch the PC: Page Down and Home are sent to the page.\n\nNothing is saved unless you pick a result at the end.")
local BENCH_REMINDER = _("Keep the test page focused. Don't touch the PC.")
local BENCH_NO_RESPONSE = _("The PC screen did not change after a key press.\n\nCheck that the test page is open full screen on the shared screen and click once into it, then try again.")

local function bench_phase_text(phase, step, steps)
    if phase == "connect" then return _("connecting") end
    if phase == "reset" then return _("resetting the page") end
    if phase == "steps" then return T(_("step %1/%2"), step, steps) end
    return tostring(phase)
end

--- Saves `combination`'s four picture fields to the stored profile `name`, nothing else.
local function save_picture_fields(plugin, name, combination)
    local stored = plugin.settings:get_profile(name)
    if not stored then return false, "no such profile" end
    local p = {}
    for k, v in pairs(stored) do p[k] = v end
    for _i, k in ipairs(PICTURE_ORDER) do p[k] = combination[k] end
    return plugin:save_profile(p, name)
end

--[[--
"Find fastest picture settings": the intro with what to do on the PC (Start / Cancel), then a
progress dialog with Cancel while @{vncoxide.benchmark} runs (the plugin's attached sessions are
detached meanwhile), then the ranked @{vncoxide.benchresults} cards. Tapping a scored card asks
"Use <label>?": Use applies it (by default: saves its four picture fields to the stored profile)
and closes the cards, Cancel returns to them.

A run that stopped on a connect failure says "Could not connect: <reason>"; one whose first key
press changed nothing on the PC says what to check and offers Try again (a new run, no intro).
Every way out (Cancel anywhere, closing the cards, Use, the connect failure) ends in `on_back`.

--- @tparam table plugin
--- @tparam table profile
--- @tparam function on_back
--- @tparam[opt] table opts `{ unsaved = true }`: benchmark `profile` as given instead of the stored
---   one; `{ on_pick = function(combination) }`: called on Use instead of saving
]]
function Dialogs.picture_benchmark(plugin, profile, on_back, opts)
    opts = opts or {}
    local run

    --- Use in the confirmation: closes the cards (back to where the benchmark was opened) and
    --- applies `combination`; a saved result is confirmed on top.
    local function use(cards, combination)
        if opts.on_pick then
            opts.on_pick(combination)
            cards:onClose()
            return
        end
        local ok, err = save_picture_fields(plugin, profile.name, combination)
        cards:onClose()
        UIManager:show(InfoMessage:new{
            text = ok and T(_("Saved: %1. Takes effect on the next connection."), combination.label)
                or T(_("Could not save: %1"), tostring(err)),
        })
    end

    local function show_results(results)
        local cards
        cards = BenchResults:new{
            rows = results,
            on_pick = function(row)
                UIManager:show(ConfirmBox:new{
                    text = T(_("Use %1?"), row.combination.label),
                    ok_text = _("Use"),
                    cancel_text = _("Cancel"),
                    dismissable = false,
                    ok_callback = function() use(cards, row.combination) end,
                    cancel_callback = function() end,
                })
            end,
            on_close = on_back,
        }
        UIManager:show(cards)
    end

    run = function()
        local Benchmark = Dialogs.Benchmark or require("vncoxide/benchmark")
        local source = opts.unsaved and profile or plugin.settings:get_profile(profile.name) or profile
        local copy = {}
        for k, v in pairs(source) do copy[k] = v end
        local progress, bench
        progress = ButtonDialog:new{
            title = _("Starting…"),
            dismissable = false,
            buttons = { { {
                text = _("Cancel"),
                callback = function()
                    bench:cancel()
                    UIManager:close(progress)
                    on_back()
                end,
            } } },
        }
        progress:addWidget(TextBoxWidget:new{
            text = BENCH_REMINDER,
            face = Font:getFace("x_smallinfofont"),
            bold = true,
            width = progress:getAddedWidgetAvailableWidth(),
            parent = progress,  -- kept across `setTitle` re-inits (see ButtonDialog:reinit)
            not_focusable = true,
        })
        bench = Benchmark.new{
            profile = copy,
            canvas = plugin:benchmark_canvas(),
            sessions = plugin.sessions,
            on_progress = function(i, n, label, phase, pass, passes, step, steps)
                progress:setTitle(T("%1/%2 (pass %3/%4): %5 — %6", i, n, pass, passes, label,
                    bench_phase_text(phase, step, steps)))
            end,
            on_done = function(results, stop)
                UIManager:close(progress)
                if stop and stop.reason == "connect" then
                    UIManager:show(InfoMessage:new{ text = T(_("Could not connect: %1"), tostring(stop.error)) })
                    on_back()
                elseif stop and stop.reason == "no_response" then
                    UIManager:show(ConfirmBox:new{
                        text = BENCH_NO_RESPONSE,
                        ok_text = _("Try again"),
                        cancel_text = _("Cancel"),
                        dismissable = false,
                        ok_callback = run,
                        cancel_callback = on_back,
                    })
                else
                    show_results(results)
                end
            end,
        }
        UIManager:show(progress)
        bench:start()
    end

    UIManager:show(ConfirmBox:new{
        text = BENCH_INTRO,
        ok_text = _("Start"),
        cancel_text = _("Cancel"),
        dismissable = false,
        ok_callback = run,
        cancel_callback = on_back,
    })
end

--[[--
Connect / Edit / Find fastest picture settings / Delete for one connection, with a Back button that returns to `opts.on_back`
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
                text = _("Find fastest picture settings"),
                callback = function()
                    UIManager:close(dialog)
                    Dialogs.picture_benchmark(plugin, profile, reopen_actions)
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
only stored by Save. "Test speed with these settings…" runs @{Dialogs.picture_benchmark} on the typed
fields (validated like Save); a picked result becomes the picture choice, again only stored by Save. Saving the connection that is live says that a reconnect applies the changes, when any
per-connection field changed.

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
    }
    local picture_button
    --- Shows the current `picture` on the Picture button.
    local function update_picture_label()
        local label = Dialogs.picture_summary(picture)
        picture_button.text = label  -- for a re-init from `buttons` (keyboard toggles)
        local button = dialog.button_table:getButtonById("picture")
        button:setText(label, button.width)
        dialog:refreshButtons()
    end
    picture_button = {
        text = Dialogs.picture_summary(picture),
        id = "picture",
        callback = function()
            -- The editor stays up underneath (so the typed fields are kept); only its keyboard
            -- makes way for the picture dialog.
            dialog:onCloseKeyboard()
            UIManager:show(Dialogs.picture_settings(picture, function()
                update_picture_label()
                dialog:onShowKeyboard()
            end))
        end,
    }

    --- The typed host and port (default port when empty), or nil after saying what is wrong.
    local function typed_address(fields)
        local host = trim(fields[2])
        local port_text = trim(fields[3])
        if host == "" then
            report(_("Please enter a host name or IP address."))
            return nil
        end
        local port = port_text == "" and DEFAULT_PORT or tonumber(port_text)
        if not port or port < 1 or port > 65535 then
            report(T(_("The port must be a number between 1 and %1."), 65535))
            return nil
        end
        return host, math.floor(port)
    end

    -- Runs the picture benchmark on the typed fields (nothing is stored); a picked result goes into
    -- `picture` like a choice in the picture dialog, and Save stores it.
    local bench_button = {
        text = _("Test speed with these settings…"),
        id = "bench",
        callback = function()
            local fields = dialog:getFields()
            local host, port = typed_address(fields)
            if not host then return end
            local name = trim(fields[1])
            local typed = {
                name = name ~= "" and name or _("New connection"),
                host = host,
                port = port,
                password = fields[4] or "",
            }
            for _i, key in ipairs(PICTURE_ORDER) do typed[key] = picture[key] end
            dialog:onCloseKeyboard()
            Dialogs.picture_benchmark(plugin, typed, function() dialog:onShowKeyboard() end, {
                unsaved = true,
                on_pick = function(combination)
                    for _i, key in ipairs(PICTURE_ORDER) do picture[key] = combination[key] end
                    update_picture_label()
                end,
            })
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
        buttons = { { picture_button }, { bench_button }, {
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
                    local password = fields[4] or ""

                    if name == "" then
                        return report(_("Please give the connection a name."))
                    end
                    local existing = plugin.settings:get_profile(name)
                    if existing and (not profile or profile.name ~= name) then
                        return report(T(_("A connection named %1 already exists."), name))
                    end
                    local host, port = typed_address(fields)
                    if not host then return end

                    local saved = {
                        name = name,
                        host = host,
                        port = port,
                        password = password,
                        color_depth = picture.color_depth,
                        enable_tight = picture.enable_tight,
                        jpeg_quality = picture.jpeg_quality,
                        compress_level = picture.compress_level,
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
