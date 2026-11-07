--[[--
The "Send keys" panel: any hotkey for the remote desktop, from a touch screen.

A bottom-anchored panel (full width, as tall as it needs) built from KOReader's own pieces: a
TitleBar with a close button, rows of borderless Buttons separated by grey lines (the ButtonTable
look), and the ToggleSwitch of the bottom configuration panel for the tabs. The remote stays
visible above it and keeps updating; taps there still click the remote (the viewer does not count
the panel as a popup, c.f. `ViewerApp:_input_target`).

Modifiers (Ctrl, Shift, Alt, Super) are sticky for exactly one action. A tap arms one (it turns
black), another tap disarms it. The next action takes every armed modifier and then disarms them
all; nothing stays down on the remote between actions. That action is either

* a key from the panel: armed modifier downs in Ctrl, Shift, Alt, Super order, key down, key up,
  modifier ups in reverse;
* the combo display, with only modifiers armed: those modifiers alone (Super on its own);
* a tap, long press or drag on the remote canvas (Ctrl+click, Shift+click, Alt+drag): the viewer
  sends the downs before the pointer press and the ups right after the pointer release
  (`ViewerApp:_press_armed`), and sends any ups still pending when the panel or the viewer closes
  in the middle of a drag.

The same module also makes the key strip (`variant = "strip"`): one row above the on-screen keyboard
with the panel's modifier buttons and a few keys (`STRIP_KEYS`), no title, tabs or combo display.
Its modifiers arm and are taken exactly like the panel's; the viewer also hands it the keyboard's
keys while a modifier is armed (`ViewerApp:send_osk_key`). It sits `bottom_offset` pixels above the
bottom of the screen, i.e. on top of the keyboard.

The last few distinct combos sent from the panel are kept in the `recent_combos` setting; tapping
one sends exactly that combo again. That counts as the action: the armed modifiers are cleared, not
added to it.

@module vnc.keypanel
]]

local _ = require("gettext")

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local ToggleSwitch = require("ui/widget/toggleswitch")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Keysyms = require("vnc/keysyms")
local Settings = require("vnc/settings")

local Screen = Device.screen
local X = Keysyms.x11

-- ---------------------------------------------------------------- the keys

local function letters()
    local rows = {}
    local function row(chars)
        local out = {}
        for ch in chars:gmatch(".") do
            -- keycaps show capitals; the keysym is the unshifted one (Shift is the user's modifier)
            out[#out + 1] = { ch:upper(), ch:byte() }
        end
        rows[#rows + 1] = out
    end
    row("1234567890")
    row("qwertyuiop")
    row("asdfghjkl")
    row("zxcvbnm")
    return rows
end

local function function_keys()
    local rows = {}
    for r = 0, 2 do
        local out = {}
        for c = 1, 4 do
            local n = r * 4 + c
            out[#out + 1] = { "F" .. n, Keysyms.special["F" .. n] }
        end
        rows[#rows + 1] = out
    end
    return rows
end

--- The tabs: a label, how many key columns a row is laid out for, and the rows of
--- `{ label, keysym }`. Short rows are centred, like the staggered rows of a keyboard.
local TABS = {
    {
        label = _("Keys"),
        columns = 5,
        rows = {
            { { _("Esc"), X.Escape }, { _("Tab"), X.Tab }, { _("Enter"), X.Return },
              { _("Backspace"), X.BackSpace }, { _("Delete"), X.Delete } },
            { { _("Insert"), X.Insert }, { _("Home"), X.Home }, { _("End"), X.End },
              { _("Page Up"), X.Prior }, { _("Page Down"), X.Next } },
            { { _("Space"), X.space }, { _("Menu"), X.Menu }, { _("Print Screen"), X.Print },
              { _("Pause"), X.Pause }, { _("Caps Lock"), X.Caps_Lock } },
            { { "←", X.Left }, { "↑", X.Up }, { "↓", X.Down }, { "→", X.Right } },
        },
    },
    { label = "F1–F12", columns = 4, rows = function_keys() },
    { label = _("Letters"), columns = 10, rows = letters() },
    {
        -- the unshifted US-layout symbol keys, by keyboard row; Shift reaches the other half
        label = _("Symbols"),
        columns = 3,
        rows = {
            { { "`", 0x60 }, { "-", 0x2D }, { "=", 0x3D } },
            { { "[", 0x5B }, { "]", 0x5D }, { "\\", 0x5C } },
            { { ";", 0x3B }, { "'", 0x27 } },
            { { ",", 0x2C }, { ".", 0x2E }, { "/", 0x2F } },
        },
    },
}

--- Key rows every tab's grid is as tall as, so switching tabs never changes the panel's height
--- (which would move the view above it).
local GRID_ROWS = 4

-- ---------------------------------------------------------------- the widget

local KeyPanel = InputContainer:extend{
    name = "VNCKeyPanel",
    app = nil,            -- the @{vnc.app} that owns us (mandatory)
    variant = nil,        -- nil: the full panel; "strip": the one-row strip above the keyboard
    bottom_offset = 0,    -- the strip: pixels between its bottom and the bottom of the screen
    modal = false,        -- the viewer's keyboard and dialogs stack above us normally
    covers_fullscreen = false,
}

--- The strip's keys, after its modifiers.
KeyPanel.STRIP_KEYS = {
    { "Esc", X.Escape }, { "Tab", X.Tab },
    { "←", X.Left }, { "↑", X.Up }, { "↓", X.Down }, { "→", X.Right },
    { "Del", X.Delete },
}

--- Height of one row: KOReader's large list item, comfortably tappable on a 300 dpi panel.
function KeyPanel.row_height()
    return Size.item.height_big
end

function KeyPanel:init()
    self.mods = {}        -- modifier name -> "armed"
    self.tab = self.tab or 1
    if self.variant == "strip" then
        -- The keyboard is modal, so it stays above the strip on the window stack and is the one
        -- widget UIManager hands input first; widgets below it get what it leaves only when they
        -- are always active (as the viewer is).
        self.is_always_active = true
    end
    -- (the strip leaves Back and Menu to the viewer: it is part of the keyboard, not a panel)
    if Device:hasKeys() and self.variant ~= "strip" then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            CloseMenuKey = { { "Menu" }, event = "Close" },
        }
    end
    self:_build()
end

--- The current state of a modifier: nil (idle) or "armed".
function KeyPanel:modifier_state(name)
    return self.mods[name]
end

-- ---------------------------------------------------------------- sending

function KeyPanel:_send(keysym, down)
    self.app:send_key(keysym, down)
end

--- Sends one combo: `press` (modifier names, any order) go down in modifier order around the key
--- (if any) and up in reverse.
function KeyPanel:_send_combo(press, keysym)
    local wanted = {}
    for _i, name in ipairs(press) do wanted[name] = true end
    local downs = {}
    for _i, m in ipairs(Keysyms.modifiers) do
        if wanted[m.name] then
            self:_send(m.keysym, true)
            downs[#downs + 1] = m.keysym
        end
    end
    if keysym then
        self:_send(keysym, true)
        self:_send(keysym, false)
    end
    for i = #downs, 1, -1 do
        self:_send(downs[i], false)
    end
end

--- Modifier names in modifier order whose state passes `pred`.
function KeyPanel:_mods_where(pred)
    local out = {}
    for _i, m in ipairs(Keysyms.modifiers) do
        if pred(self.mods[m.name]) then out[#out + 1] = m.name end
    end
    return out
end

local function is_armed(state) return state == "armed" end

--- Sends a panel key with the armed modifiers around it, then disarms them.
function KeyPanel:send_key(label, keysym)
    local armed = self:_mods_where(is_armed)
    self:_send_combo(armed, keysym)
    self.mods = {}
    self:_remember({ mods = armed, keysym = keysym, label = label })
    self:_update()
end

--- The combo display: presses and releases just the armed modifiers (e.g. Super alone).
function KeyPanel:send_modifiers_only()
    local armed = self:_mods_where(is_armed)
    if #armed == 0 then return end
    self:_send_combo(armed, nil)
    self.mods = {}
    self:_remember({ mods = armed, label = "" })
    self:_update()
end

--- Sends a remembered combo exactly. It is the action the armed modifiers were waiting for: they
--- are not added to it, and are cleared.
function KeyPanel:replay(combo)
    self:_send_combo(combo.mods, combo.keysym)
    self.mods = {}
    self:_remember(combo)
    self:_update()
end

-- ---------------------------------------------------------------- modifier states

--- Tap: idle -> armed -> idle.
function KeyPanel:tap_modifier(name)
    self.mods[name] = not self.mods[name] and "armed" or nil
    self:_update()
end

--- Whether any modifier is armed.
function KeyPanel:has_armed()
    return next(self.mods) ~= nil
end

--- Hands the armed modifiers to an action on the canvas, and disarms them.
--- @treturn {number,...} their keysyms, in the order they are to be pressed
function KeyPanel:take_armed()
    local keysyms = {}
    for _i, m in ipairs(Keysyms.modifiers) do
        if self.mods[m.name] == "armed" then keysyms[#keysyms + 1] = m.keysym end
    end
    if #keysyms > 0 then
        self.mods = {}
        self:_update()
    end
    return keysyms
end

--- Whether "Release all" has anything to do: an armed modifier, or a canvas drag or long press
--- still holding a button or modifiers down on the remote (also one whose release never came).
function KeyPanel:_anything_to_release()
    return next(self.mods) ~= nil or self.app:has_pointer_action()
end

--- "Release all": disarms everything and lets go of whatever a canvas drag or long press still
--- holds (its button, then its modifiers).
function KeyPanel:release_all()
    self.mods = {}
    self.app:_end_pointer_action()
    self:_update()
end

--- The viewer's drag or long press began or ended: "Release all" follows (repainted only when
--- that changes whether it has anything to do).
function KeyPanel:pointer_action_changed()
    if self.variant == "strip" then return end -- no "Release all" on the strip
    if self:_anything_to_release() ~= self._release_enabled then self:_update() end
end

-- ---------------------------------------------------------------- recent combos

local function same_combo(a, b)
    if a.keysym ~= b.keysym or #a.mods ~= #b.mods then return false end
    for i = 1, #a.mods do
        if a.mods[i] ~= b.mods[i] then return false end
    end
    return true
end

local function combo_text(combo)
    local parts = {}
    for _i, name in ipairs(combo.mods) do parts[#parts + 1] = name end
    if combo.keysym then parts[#parts + 1] = combo.label end
    return table.concat(parts, "+")
end

function KeyPanel:_recent()
    local settings = self.app.settings
    if type(settings.recent_combos) ~= "table" then settings.recent_combos = {} end
    return settings.recent_combos
end

--- Moves `combo` to the front of the recent list (dropping its older copy) and saves the list.
function KeyPanel:_remember(combo)
    local list = { { mods = combo.mods, keysym = combo.keysym, label = combo.label } }
    for _i, c in ipairs(self:_recent()) do
        if #list >= Settings.RECENT_COMBOS_MAX then break end
        if not same_combo(c, combo) then list[#list + 1] = c end
    end
    self.app.settings.recent_combos = list
    self.app.plugin.settings:flush()
end

-- ---------------------------------------------------------------- layout

--- What the combo display says: the modifiers that will go with the next key.
function KeyPanel:combo_display_text()
    local parts = {}
    for _i, m in ipairs(Keysyms.modifiers) do
        if self.mods[m.name] == "armed" then parts[#parts + 1] = m.name end
    end
    if #parts == 0 then return _("Tap a key") end
    return table.concat(parts, "+") .. "+…"
end

local function separator(w, h)
    return LineWidget:new{
        background = Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{ w = w, h = h },
    }
end

--- A row of buttons in the ButtonTable style. `entries` are `{ id, text, width, callback,
--- enabled, preselect, bold }`, all `row_height` tall.
function KeyPanel:_button_row(entries, row_height)
    local sep_w = Size.line.medium
    local group = HorizontalGroup:new{}
    local pad_v = Size.padding.buttontable
    for i, e in ipairs(entries) do
        local button = Button:new{
            text = e.text,
            width = e.width,
            height = row_height - 2 * pad_v,
            bordersize = 0,
            margin = 0,
            radius = 0,
            padding = pad_v,
            padding_h = Size.padding.button,
            text_font_bold = e.bold ~= false,
            preselect = e.preselect,
            enabled = e.enabled ~= false,
            callback = e.callback,
            show_parent = self,
        }
        self.button_by_id[e.id] = button
        group[#group + 1] = button
        if i < #entries then
            group[#group + 1] = separator(sep_w, row_height)
        end
    end
    -- exactly `row_height` tall whatever the font makes of the labels, so the panel never jumps
    return CenterContainer:new{
        dimen = Geom:new{ w = group:getSize().w, h = row_height },
        group,
    }
end

--- Splits `width` into `units` equal shares (with the separators between `count` buttons taken
--- out first); returns the width of one unit and the leftover pixels.
local function unit_width(width, units, count)
    local avail = width - Size.line.medium * (count - 1)
    local unit = math.floor(avail / units)
    return unit, avail - unit * units
end

--- The modifier buttons (Ctrl, Shift, Alt, Super), `unit` wide each, appended to `entries`.
function KeyPanel:_modifier_entries(entries, unit)
    for _i, m in ipairs(Keysyms.modifiers) do
        local name = m.name
        entries[#entries + 1] = {
            id = "mod:" .. name,
            text = name,
            width = unit,
            -- armed: inverted, like a selected button
            preselect = self.mods[name] ~= nil,
            callback = function() self:tap_modifier(name) end,
        }
    end
    return entries
end

function KeyPanel:_modifier_row(width, row_height)
    local unit, rest = unit_width(width, 6, 5)
    local entries = self:_modifier_entries({}, unit)
    entries[#entries + 1] = {
        id = "combo",
        text = self:combo_display_text(),
        width = 2 * unit + rest,
        bold = false,
        enabled = #self:_mods_where(is_armed) > 0,
        callback = function() self:send_modifiers_only() end,
    }
    return self:_button_row(entries, row_height)
end

function KeyPanel:_tab_row(width, row_height)
    local labels = {}
    for i, tab in ipairs(TABS) do labels[i] = tab.label end
    local values = {}
    for i = 1, #TABS do values[i] = i end
    local pad = Size.padding.default
    local switch = ToggleSwitch:new{
        width = width - 2 * Size.padding.large,
        height = row_height - 2 * pad,
        -- font: ToggleSwitch's own default, the size of the bottom config panel's toggles
        toggle = labels,
        values = values,
        name = "vnc_key_tab",
        config = self,
        -- the hardware arrows belong to the remote, not to focus moves in here
        key_events_enabled = false,
        callback = function(position) self:select_tab(position) end,
    }
    switch.key_events = {}
    switch:setPosition(self.tab)
    self.tab_switch = switch
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = row_height },
        switch,
    }
end

-- ToggleSwitch reports its choice to a ConfigDialog; the callback above is all we need.
function KeyPanel:onConfigChoice() return true end
function KeyPanel:onConfigChoose() return true end

--- The key grid of the current tab: always `GRID_ROWS` rows tall; tabs with fewer rows get
--- taller keys.
function KeyPanel:_grid(width, row_height)
    local line = Size.line.medium
    local grid_h = GRID_ROWS * row_height + (GRID_ROWS - 1) * line
    local tab = TABS[self.tab]
    local n = #tab.rows
    local key_h = math.floor((grid_h - (n - 1) * line) / n)
    local unit = unit_width(width, tab.columns, tab.columns)
    local group = VerticalGroup:new{ align = "center" }
    for r, row in ipairs(tab.rows) do
        local entries = {}
        for _i, key in ipairs(row) do
            local label, keysym = key[1], key[2]
            entries[#entries + 1] = {
                id = "key:" .. label,
                text = label,
                width = unit,
                callback = function() self:send_key(label, keysym) end,
            }
        end
        group[#group + 1] = self:_button_row(entries, key_h)
        if r < n then group[#group + 1] = separator(width, line) end
    end
    -- (not group:getSize(): it caches, and the span would be left out of the layout)
    local used = n * key_h + (n - 1) * line
    if used < grid_h then
        group[#group + 1] = VerticalSpan:new{ width = grid_h - used }
    end
    return group
end

function KeyPanel:_bottom_row(width, row_height)
    local recent = self:_recent()
    local entries = {}
    local count = math.max(1, #recent) + 1
    local unit, rest = unit_width(width, 6, count)
    if #recent == 0 then
        entries[1] = {
            id = "recent:none",
            text = _("Recent keys appear here"),
            width = 4 * unit + rest,
            bold = false,
            enabled = false,
        }
    else
        -- the recent combos share four units; the last one absorbs the rounding
        local area = 4 * unit + rest
        local share = math.floor(area / #recent)
        local used = 0
        for i, combo in ipairs(recent) do
            local w = i < #recent and share or area - used
            used = used + w
            entries[#entries + 1] = {
                id = "recent:" .. i,
                text = combo_text(combo),
                width = w,
                callback = function() self:replay(combo) end,
            }
        end
    end
    self._release_enabled = self:_anything_to_release()
    entries[#entries + 1] = {
        id = "release_all",
        text = _("Release all"),
        width = 2 * unit,
        enabled = self._release_enabled,
        callback = function() self:release_all() end,
    }
    return self:_button_row(entries, row_height)
end

--- The strip's single row: the modifiers, then `STRIP_KEYS`; the last key absorbs the rounding.
function KeyPanel:_strip_row(width, row_height)
    local count = #Keysyms.modifiers + #KeyPanel.STRIP_KEYS
    local unit, rest = unit_width(width, count, count)
    local entries = self:_modifier_entries({}, unit)
    for i, key in ipairs(KeyPanel.STRIP_KEYS) do
        local label, keysym = key[1], key[2]
        entries[#entries + 1] = {
            id = "key:" .. label,
            text = label,
            width = i < #KeyPanel.STRIP_KEYS and unit or unit + rest,
            callback = function() self:send_key(label, keysym) end,
        }
    end
    return self:_button_row(entries, row_height)
end

--- (Re)builds the strip: a grey line on top of one row, `row_height()` tall in all, ending
--- `bottom_offset` above the bottom of the screen.
function KeyPanel:_build_strip(screen)
    local line = Size.line.medium
    local row_h = KeyPanel.row_height()
    local frame = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        radius = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            separator(screen.w, line),
            self:_strip_row(screen.w, row_h - line),
        },
    }
    local h = frame:getSize().h
    local bottom = screen.h - self.bottom_offset
    self[1] = BottomContainer:new{
        dimen = Geom:new{ w = screen.w, h = bottom },
        frame,
    }
    self.dimen = Geom:new{ x = 0, y = bottom - h, w = screen.w, h = h }
end

--- (Re)builds the panel for the current state and screen size.
function KeyPanel:_build()
    if self[1] then self[1]:free() end
    self.button_by_id = {}
    local screen = Screen:getSize()
    if self.variant == "strip" then return self:_build_strip(screen) end
    local border = Size.border.window
    local width = screen.w - 2 * border
    local row_h = KeyPanel.row_height()
    local line = Size.line.medium

    self.title_bar = TitleBar:new{
        width = width,
        title = _("Send keys"),
        with_bottom_line = true,
        bottom_line_color = Blitbuffer.COLOR_DARK_GRAY,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local content = VerticalGroup:new{
        align = "center",
        self.title_bar,
        self:_modifier_row(width, row_h),
        separator(width, line),
        self:_tab_row(width, row_h),
        separator(width, line),
        self:_grid(width, row_h),
        separator(width, line),
        self:_bottom_row(width, row_h),
    }
    local frame = FrameContainer:new{
        bordersize = border,
        padding = 0,
        margin = 0,
        radius = 0,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
    local h = frame:getSize().h
    self[1] = BottomContainer:new{
        dimen = Geom:new{ w = screen.w, h = screen.h },
        frame,
    }
    self.dimen = Geom:new{ x = 0, y = screen.h - h, w = screen.w, h = h }
end

--- `dimen` is where the panel lands at the bottom of the screen, which the viewer and the gesture
--- ranges rely on; InputContainer's own paintTo would move it to the window's origin.
function KeyPanel:paintTo(bb, x, y)
    self[1]:paintTo(bb, x, y)
end

--- Rebuilds after a state change and repaints just the panel.
function KeyPanel:_update()
    self:_build()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function KeyPanel:select_tab(n)
    if not TABS[n] or n == self.tab then return end
    self.tab = n
    self:_update()
end

--- Re-lays the panel out for the current screen size (after a rotation).
function KeyPanel:relayout()
    self:_build()
end

--- The strip: moves it to end `px` above the bottom of the screen (the keyboard's new height),
--- re-laid out for the current screen size.
function KeyPanel:set_bottom_offset(px)
    self.bottom_offset = px
    self:_build()
end

-- ---------------------------------------------------------------- input / lifecycle

--- Gestures that continue one started earlier, by the gesture that started it. A quick drag ends
--- as a swipe, not a release (GestureDetector's Contact:isSwipe), and a quick two-finger drag as
--- a two_finger_swipe.
local CONTINUES = {
    pan = "pan", pan_release = "pan", swipe = "pan",
    two_finger_pan = "pan", two_finger_pan_release = "pan", two_finger_swipe = "pan",
    hold = "hold", hold_pan = "hold", hold_release = "hold",
}
local STARTS = { pan = true, two_finger_pan = true, hold = true }
local ENDS = {
    pan_release = true, swipe = true,
    two_finger_pan_release = true, two_finger_swipe = true,
    hold_release = true,
}

--[[--
Whether a gesture is the panel's: true (ours wherever it is now), false (the viewer's wherever it is
now), or nil (decided by where it lands). A drag or a long press belongs to where it started: one
that began on the canvas stays the viewer's even when the finger slides over the panel (its release
must reach the remote, or a button and the modifiers it took would stay down), and one that began
here stays ours. Any other gesture means none is under way any more (whatever end it had did not
reach us): it forgets them all.
]]
function KeyPanel:_gesture_owner(ev)
    local kind = CONTINUES[ev.ges]
    if not kind then
        self._owner = nil
        return nil
    end
    self._owner = self._owner or {}
    local owner = self._owner[kind]
    if owner == nil and STARTS[ev.ges] then
        local rel = ev.relative or { x = 0, y = 0 }
        owner = self.dimen:contains(Geom:new{ x = ev.pos.x - rel.x, y = ev.pos.y - rel.y })
        self._owner[kind] = owner
    end
    if ENDS[ev.ges] then self._owner[kind] = nil end
    return owner
end

--[[--
Gestures: the viewer's never reach our buttons (a button rebuilt since the last paint does not know
where it is yet and would take a canvas tap for its own), and ours never reach the viewer - whatever
lands on the panel and none of its buttons takes (the gaps, the title) is swallowed, or the remote
under the panel would be clicked.
]]
function KeyPanel:handleEvent(event)
    if event.handler == "onGesture" then
        local ev = event.args and event.args[1]
        if ev and ev.pos and self.dimen then
            local owner = self:_gesture_owner(ev)
            if owner == nil then owner = self.dimen:contains(ev.pos) end
            if not owner then return nil end
            InputContainer.handleEvent(self, event)
            return true
        end
    end
    return InputContainer.handleEvent(self, event)
end

--- ✕, Back or the Menu key: the viewer closes us.
function KeyPanel:onClose(_args, key)
    if self.variant == "strip" then return nil end -- it goes with the keyboard
    self.app:close_key_panel(key and key.key)
    return true
end

function KeyPanel:onCloseWidget()
    -- nothing armed outlives the panel (the viewer sends any ups a drag still holds)
    self.mods = {}
end

return KeyPanel
