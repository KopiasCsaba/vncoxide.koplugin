--[[--
The help page's content: what the gestures do in each pointer mode, every toolbar button, the key
strip, the display panel, the menu and the reconnect behaviour. `Help.ROWS` is the one
source of the gesture rows; `Help.text(mode)` builds the whole page, the current mode's gestures
first. Shown by `ViewerApp:open_help` in a TextViewer.

@module vnc.help
]]

local _ = require("gettext")

local Help = {}

local COMMON = {
    { _("Two-finger drag"), _("Move the picture") },
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
        { _("Tap"), _("Left click at the finger (two quick taps: double click)") },
        { _("Long press"), _("Lift without moving: right click at the finger; move: drag with the left button") },
        { _("Drag"), _("Drag with the left button") },
        { _("Two-finger long press"), _("Left click between the fingers, then the keyboard") },
    },
    mouse = rows_for{
        { _("Tap"), _("Left click at the pointer, at once (two quick taps: double click)") },
        { _("Long press"), _("Lift without moving: right click at the pointer; move: drag with the left button") },
        { _("Drag"), _("Move the pointer; zoomed in, the picture follows it") },
        { _("Two-finger long press"), _("Left click at the pointer, then the keyboard") },
    },
}

Help.ROWS.hybrid = rows_for{
    { _("Tap"), _("Left click at the finger (two quick taps: double click)") },
    { _("Long press"), _("Lift without moving: right click at the finger; move: drag with the left button") },
    { _("Drag"), _("Scroll the remote (mouse wheel where the drag began); the content follows the finger") },
    { _("Two-finger long press"), _("Left click between the fingers, then the keyboard") },
}

Help.TITLES = { touch = _("Touch mode"), mouse = _("Mouse mode"), hybrid = _("Hybrid mode") }

local function gestures(mode)
    local lines = { Help.TITLES[mode] }
    for _i, r in ipairs(Help.ROWS[mode]) do lines[#lines + 1] = "  " .. r[1] .. ": " .. r[2] end
    return table.concat(lines, "\n")
end

--- The whole page as plain text; `mode` ("touch", "mouse" or "hybrid") is described first.
function Help.text(mode)
    if not Help.ROWS[mode] then mode = "touch" end
    local sections = {
        _("GESTURES"),
        gestures(mode),
    }
    for _i, other in ipairs{ "touch", "mouse", "hybrid" } do
        if other ~= mode then sections[#sections + 1] = gestures(other) end
    end
    local rest = {
        _("A swipe down in the top zone of the screen shows or hides the toolbar. Taps on the toolbar never reach the remote."),

        _("TOOLBAR"),
        "  " .. _("A tap on a button does what is listed here; a long press only shows the button's name. Drag the toolbar by any button to move it anywhere on the screen; it stays there, also after a rotation."),
        table.concat({
            "  " .. _("Collapse: fold the toolbar into a small round button, which returns to its anchored spot (where you last dragged the toolbar or the button); tap that to open the toolbar again."),
            "  " .. _("Display: the display panel (below)."),
            "  " .. _("Zoom: cycle fit, 1:1 (one remote pixel per screen pixel) and your own view (the last one you made by pinching or panning); without one, just fit and 1:1. The icon shows the current state."),
            "  " .. _("Mode: switch between Touch, Mouse and Hybrid mode."),
            "  " .. _("Keyboard: show or hide the on-screen keyboard with the key strip; closes the Send keys panel if it is open. The viewer opens with the keyboard as you last left it. Drag the button out onto the picture to click a field and type: where you let go it left-clicks (Mouse mode: the pointer moves there first) and shows the keyboard; let go anywhere else and nothing happens."),
            "  " .. _("Rotate: turn the screen a quarter turn clockwise; the viewer remembers the orientation."),
            "  " .. _("Scroll up / down: mouse-wheel notches (hidden by default)."),
            "  " .. _("Brightness: KOReader's frontlight dialog; only on devices with a frontlight."),
            "  " .. _("Contrast: the contrast of the remote picture as drawn here (50% to 300%), remembered."),
            "  " .. _("Invert: draw the remote picture inverted (a toggle, drawn inverted while on), remembered."),
            "  " .. _("Close: disconnect, after a confirmation."),
            "  " .. _("More (\u{22EF}): the menu (below)."),
            "  " .. _("Menu > Toolbar buttons\u{2026} > On the toolbar\u{2026} picks which buttons are shown; Close and More always are. Also when collapsed\u{2026} picks buttons that stay next to the round button when the toolbar is collapsed."),
        }, "\n"),

        _("KEY STRIP"),
        "  " .. _("One row above the on-screen keyboard: X (closes the keyboard), the Send keys icon (opens the full Send keys panel; keyboard and strip make way for it; it sends nothing and keeps armed modifiers armed), then Ctrl, Shift, Alt and Super (tap to arm; an armed modifier is used for exactly the next key, or tap, long press or drag on the picture, then released), Esc, Tab, the arrow keys and Del."),

        _("SEND KEYS PANEL"),
        "  " .. _("Its top row is the key strip's, except for its first two buttons: X (closes the panel) and the keyboard icon (back to the on-screen keyboard and its strip; armed modifiers stay armed). Below it: tabs Keys, Hotkeys (Ctrl+Z/X/C/V/A/S/F/W, Alt+Tab, Alt+F4, Lock = Super+L, Ctrl+Alt+Del, each sent exactly as named) and F1\u{2013}F12, recently sent combos and Release all. Modifiers only (Keys tab) sends just the armed modifiers (Super on its own). The Keyboard button closes the panel too."),

        _("DISPLAY PANEL"),
        "  " .. _("Zoom (Fit screen, Fit (with keyboard), 25% to 400%), Smooth or Sharp scaling, screen orientation, picture quality (changing it reconnects), and the pointer speed for Mouse mode."),

        _("MENU (\u{22EF})"),
        table.concat({
            "  " .. _("Title: the connection's name and state (its screen size while connected)."),
            "  " .. _("Reconnect to <name>: only right after the connection dropped; connects again. Long press: why it dropped."),
            "  " .. _("Connections\u{2026}: switch to another connection, or create one."),
            "  " .. _("Refresh: ask the remote for a full picture."),
            "  " .. _("Page buttons send: Page Up/Down keys or mouse-wheel notches."),
            "  " .. _("Keep screen on: stop the device from going to sleep or dimming the light while the viewer is open."),
            "  " .. _("Match orientation to the remote screen: after connecting (or when the remote switches between landscape and portrait), turn this screen the same way, to the side you last picked by hand. A rotation you pick yourself stays until the remote's orientation changes."),
            "  " .. _("Toolbar buttons\u{2026}: On the toolbar\u{2026} (which buttons are shown; the scroll up / down pair is one row) and Also when collapsed\u{2026} (which stay next to the round button)."),
            "  " .. _("Decode in background processes: decode and scale the picture in separate processes, so the viewer stays responsive while a big update arrives (faster on multi-core readers). Applies to the next new connection, after Close; a connection left with Leave, or one that dropped and reconnects, keeps its mode until it is closed."),
            "  " .. _("Help: this page."),
            "  " .. _("Leave (keep connection): close the viewer, the connection stays up."),
        }, "\n"),

        _("RECONNECT"),
        "  " .. _("When the connection drops, a box appears over the last picture and the viewer retries by itself, waiting 2, 4, 8, 15 and then 30 seconds between attempts, without giving up. Retry now tries at once; Close (or Back) drops the connection. If you reopen the viewer on a connection that dropped while you were away, the box waits for Retry. Nothing you did before the drop (held buttons, armed modifiers) is carried over."),
    }
    for _i, section in ipairs(rest) do sections[#sections + 1] = section end
    return table.concat(sections, "\n\n")
end

return Help
