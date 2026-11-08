--[[--
The help page's content: what the gestures do in each pointer mode, every toolbar button, the key
strip, scroll lock, the display panel, the menu and the reconnect behaviour. `Help.ROWS` is the one
source of the gesture rows; `Help.text(mode)` builds the whole page, the current mode's gestures
first. Shown by `ViewerApp:open_help` in a TextViewer.

@module vnc.help
]]

local _ = require("gettext")

local Help = {}

local COMMON = {
    { _("Two-finger drag"), _("Move the picture (with scroll lock on: scroll)") },
    { _("Pinch / spread"), _("Zoom") },
    { _("Two-finger tap"), _("Fit to screen") },
    { _("Page buttons"), _("Page Up/Down or wheel") },
}

local function rows_for(head)
    local rows = {}
    for _i, r in ipairs(head) do rows[#rows + 1] = r end
    for _i, r in ipairs(COMMON) do rows[#rows + 1] = r end
    return rows
end

Help.ROWS = {
    touch = rows_for{
        { _("Tap"), _("Left click at the finger") },
        { _("Long press"), _("Right click at the finger") },
        { _("Drag"), _("Drag with the left button") },
    },
    mouse = rows_for{
        { _("Tap"), _("Left click at the pointer") },
        { _("Long press"), _("Right click at the pointer") },
        { _("Drag"), _("Move the pointer") },
        { _("Tap, then drag"), _("Drag with the left button") },
        { _("Tap, then long press"), _("Hold the left button: move to drag, lift to let go") },
    },
}

Help.TITLES = { touch = _("Touch mode"), mouse = _("Mouse mode") }

local function gestures(mode)
    local lines = { Help.TITLES[mode] }
    for _i, r in ipairs(Help.ROWS[mode]) do lines[#lines + 1] = "  " .. r[1] .. ": " .. r[2] end
    return table.concat(lines, "\n")
end

--- The whole page as plain text; `mode` ("touch" or "mouse") is described first.
function Help.text(mode)
    mode = mode == "mouse" and "mouse" or "touch"
    local other = mode == "mouse" and "touch" or "mouse"
    local sections = {
        _("GESTURES"),
        gestures(mode),
        gestures(other),
        _("A swipe down in the top zone of the screen shows or hides the toolbar. Taps on the toolbar never reach the remote."),

        _("TOOLBAR (tap; long press where noted)"),
        table.concat({
            "  " .. _("Close: disconnect, after a confirmation."),
            "  " .. _("Display: the display panel (below)."),
            "  " .. _("Mode: switch between Touch and Mouse mode. Long press: this help."),
            "  " .. _("Keyboard: show or hide the on-screen keyboard with the key strip; closes the Send keys panel if it is open. Long press: the Send keys panel."),
            "  " .. _("Rotate: turn the screen a quarter turn clockwise; the viewer remembers the orientation."),
            "  " .. _("Scroll lock: while on, a two-finger drag scrolls and does not move the picture (see below)."),
            "  " .. _("Scroll up / down: mouse-wheel notches; shown only with the menu entry \"Show scroll buttons on toolbar\"."),
            "  " .. _("More (\u{22EF}): the menu (below)."),
        }, "\n"),

        _("KEY STRIP"),
        "  " .. _("One row above the on-screen keyboard: Ctrl, Shift, Alt and Super (tap to arm; an armed modifier is used for exactly the next key, or tap, long press or drag on the picture, then released), Esc, Tab, the arrow keys and Del. Keys\u{2026} opens the full Send keys panel (keyboard and strip make way for it); it sends nothing and keeps armed modifiers armed."),

        _("SEND KEYS PANEL"),
        "  " .. _("Tabs Keys, F1\u{2013}F12, Letters and Symbols, the same sticky modifiers, a combo display, recently sent combos and Release all. Close it with its X, or with the Keyboard button."),

        _("SCROLL LOCK"),
        "  " .. _("A toolbar toggle. While it is on, a two-finger drag scrolls instead of moving the picture: the content follows your fingers, and a sideways drag scrolls horizontally. Pinch still zooms. It starts off each time the viewer opens."),

        _("DISPLAY PANEL"),
        "  " .. _("Zoom (Fit screen, Fit (with keyboard), 25% to 400%), Smooth or Sharp scaling, screen orientation, picture quality (changing it reconnects), and the pointer speed for Mouse mode."),

        _("MENU (\u{22EF})"),
        table.concat({
            "  " .. _("Status line: the connection's state."),
            "  " .. _("Reconnect to <name>: only right after the connection dropped; connects again."),
            "  " .. _("Connections\u{2026}: switch to another connection, or create one."),
            "  " .. _("Send text\u{2026}: type text (newlines become Return)."),
            "  " .. _("Refresh: ask the remote for a full picture."),
            "  " .. _("Ctrl+Alt+Del and Lock screen: send those keys."),
            "  " .. _("Page buttons send: Page Up/Down keys or mouse-wheel notches."),
            "  " .. _("Keyboard always visible: keep the keyboard up."),
            "  " .. _("Keep screen on: stop the device from going to sleep or dimming the light while the viewer is open."),
            "  " .. _("Show scroll buttons on toolbar: the scroll up / down buttons."),
            "  " .. _("Help: this page."),
            "  " .. _("Leave (keep connection): close the viewer, the connection stays up."),
        }, "\n"),

        _("RECONNECT"),
        "  " .. _("When the connection drops, a box appears over the last picture and the viewer retries by itself, waiting 2, 4, 8, 15 and then 30 seconds between attempts, without giving up. Retry now tries at once; Close (or Back) drops the connection. If you reopen the viewer on a connection that dropped while you were away, the box waits for Retry. Nothing you did before the drop (held buttons, armed modifiers) is carried over."),
    }
    return table.concat(sections, "\n\n")
end

return Help
