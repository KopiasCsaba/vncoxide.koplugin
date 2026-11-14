--[[--
The on-screen keyboard, wired to the RFB KeyEvent stream.

`VirtualKeyboard` never type-checks its `inputbox`: it just calls 12 methods on it, so a
stub that forwards those calls to @{vnc.session} is all the glue that is needed.

Layouts that ship an IME (`zh`, `zh_CN`, `ja`, `ko_KR`, `vi`) export `wrapInputBox()`,
which is written for `InputText`: it proxies methods our stub does not have and buffers
typed characters into IME candidates. For the lifetime of this keyboard we therefore pin
the layout to `en` (restoring the user's choice in @{Keyboard.restore_layout}), so that a
tap always sends exactly the character on the key.

@module vnc.keyboard
]]

local Keysyms = require("vnc/keysyms")
local Util = require("vnc/util")

local Keyboard = {}

--- Seconds between two Backspaces while the keyboard's Backspace key is held.
Keyboard.REPEAT_INTERVAL = 0.1
--- Ticks after which a repeat whose finger cannot be followed stops anyway (10 s), so that a lost
--- release can never make it repeat forever.
Keyboard.REPEAT_UNTRACKED_MAX = 100
--[[--
Seconds a key's long press waits before it acts (the canvas's `ViewerApp.HOLD_CONFIRM`). On
PocketBook, InkView sometimes withholds a tap's events for ~0.5 s: GestureDetector's hold timer
trips, and the lift follows 10-70 ms after the hold in one burst, often with the next key's tap. On
a key that hold opened the alternate-characters popup, which then took the next tap to close itself
(both keys lost), and on Backspace started the repeat. So a key's hold is passed on only once it has
lasted this long with no lift (or once it moves, a hold_pan); lifted sooner, the lift reaches the
key alone, which types it like a tap (`VirtualKey:onHoldReleaseKey`).
]]
Keyboard.HOLD_CONFIRM = 0.12

-- Saved G_reader_settings values while a keyboard created here is alive.
local saved_layout = nil

local function current_layout_name()
    if G_reader_settings:isFalse("keyboard_remember_layout") then
        return G_reader_settings:readSetting("keyboard_layout_default")
            or G_reader_settings:readSetting("keyboard_layout") or "en"
    end
    return G_reader_settings:readSetting("keyboard_layout")
        or G_reader_settings:readSetting("language") or "en"
end

local function layout_uses_ime(lang)
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local mod = (VirtualKeyboard.lang_to_keyboard_layout or {})[lang] or "en_keyboard"
    local ok, keyboard = pcall(require, "ui/data/keyboardlayouts/" .. mod)
    return ok and type(keyboard) == "table" and keyboard.wrapInputBox ~= nil
end

local function pin_latin_layout()
    local lang = current_layout_name()
    if not layout_uses_ime(lang) then return end
    saved_layout = {
        layout = G_reader_settings:readSetting("keyboard_layout"),
        default = G_reader_settings:readSetting("keyboard_layout_default"),
    }
    G_reader_settings:saveSetting("keyboard_layout", "en")
    if saved_layout.default ~= nil then
        G_reader_settings:saveSetting("keyboard_layout_default", "en")
    end
end

--- Restores the keyboard layout that @{Keyboard.new} pinned. Call once, when the keyboard
--- is destroyed.
function Keyboard.restore_layout()
    if not saved_layout then return end
    local function put(key, value)
        if value == nil then
            G_reader_settings:delSetting(key)
        else
            G_reader_settings:saveSetting(key, value)
        end
    end
    put("keyboard_layout", saved_layout.layout)
    put("keyboard_layout_default", saved_layout.default)
    saved_layout = nil
end

--- Builds the inputbox stub the keyboard talks to. Each key goes to `send(keysym)`.
local function make_stub(send, on_height_changed, on_backspace_hold)
    local stub = {
        parent = { onKeyboardHeightChanged = on_height_changed },
    }
    local special = Keysyms.special

    function stub:addChars(chars)
        for _, ch in ipairs(Util.split_chars(chars)) do
            local keysym = Keysyms.from_char(ch)
            if keysym then send(keysym) end
        end
    end
    function stub:delChar() send(special.Backspace) end
    function stub:delWord() send(special.Backspace) end
    -- the Backspace key's hold_callback (the key ignores its own release after it): repeat instead
    function stub:delToStartOfLine() on_backspace_hold() end
    function stub:leftChar() send(special.Left) end
    function stub:rightChar() send(special.Right) end
    function stub:goToStartOfLine() send(special.Home) end
    function stub:goToEndOfLine() send(special.End) end
    function stub:upLine() send(special.Up) end
    function stub:downLine() send(special.Down) end
    function stub:scrollUp() end
    function stub:scrollDown() end

    return stub
end

--[[--
Closes the long-press popup of one of `vk`'s keys once the key that typed has returned.

KOReader's popup (`VirtualKeyPopup`) gives its centre key, the plain letter, the parent key's own
callback, which closes only its `close_after_callback_widget`: nil on a key of the keyboard itself.
Picking the plain letter therefore typed it and left the popup on top. Every other popup key closes
the popup itself right after typing, so the check waits for the next tick: a popup still on the
window stack then is closed (its `onCloseWidget` refreshes its own area, "ui"), one already gone is
not closed twice.
]]
local function close_key_popup_later(vk)
    local UIManager = require("ui/uimanager")
    local function find()
        for _i, entry in ipairs(UIManager._window_stack) do
            local w = entry.widget
            if w.parent_key and w.parent_key.keyboard == vk then return w end
        end
    end
    local popup = vk and find()
    if not popup then return end
    UIManager:nextTick(function()
        if find() == popup then UIManager:close(popup) end
    end)
end

--[[--
The Backspace key's hold fired: one Backspace now, then one every REPEAT_INTERVAL until the hold
ends, like a PC key. Each one is a whole press (down and up), so nothing is ever left down on the
remote; the plugin repeats, not the remote's own auto-repeat. The hold ends with the next gesture
reaching the keyboard (the lift's hold_release first of all), with the keyboard closing, with
@{Keyboard.stop_repeat} (the viewer closing, the connection dropping), or - when that lift went
elsewhere - once GestureDetector no longer has the finger down; a finger that cannot be followed
stops it after REPEAT_UNTRACKED_MAX repeats.
]]
function Keyboard._start_repeat(vk, rep, send)
    local UIManager = require("ui/uimanager")
    UIManager:unschedule(rep.task)
    -- the finger that held the key: the one down nearest to where the hold was; none when that
    -- cannot be told (several fingers down and no distance to go by)
    local best, best_d, unplaced = nil, nil, 0
    for _i, f in ipairs(Util.fingers_down() or {}) do
        local d = (rep.hold_pos and f.start) and rep.hold_pos:distance(f.start) or math.huge
        if d == math.huge then unplaced = unplaced + 1 end
        if not best or d < best_d then best, best_d = f, d end
    end
    if best and best_d == math.huge and unplaced > 1 then best = nil end
    rep.finger = best and { slot = best.slot, contact = best.contact } or nil
    rep.untracked_ticks = 0
    rep.running = true
    send(Keysyms.special.Backspace)
    -- (sending may have ended it: a popup or the session going)
    if rep.running then UIManager:scheduleIn(Keyboard.REPEAT_INTERVAL, rep.task) end
end

function Keyboard._repeat_tick(vk, rep, send)
    if not rep.running then return end
    if not vk.visible or Util.finger_still_down(rep.finger) == false then
        Keyboard.stop_repeat(vk, vk.visible and "finger up, release lost" or "keyboard hidden")
        return
    end
    if not rep.finger then
        rep.untracked_ticks = (rep.untracked_ticks or 0) + 1
        if rep.untracked_ticks > Keyboard.REPEAT_UNTRACKED_MAX then
            Keyboard.stop_repeat(vk, "untracked repeat cap")
            return
        end
    end
    send(Keysyms.special.Backspace)
    if rep.running then require("ui/uimanager"):scheduleIn(Keyboard.REPEAT_INTERVAL, rep.task) end
end

--- Stops a held Backspace's repeat on keyboard `vk` (a no-op when none runs).
function Keyboard.stop_repeat(vk, reason)
    local rep = vk and vk.vnc_backspace_repeat
    if not rep then return end
    if rep.running then require("logger").dbg("vnc: Backspace repeat stops:", reason) end
    rep.running = false
    rep.finger = nil
    require("ui/uimanager"):unschedule(rep.task)
end

--- The key of keyboard `vk` under screen point `pos`, or nil.
local function key_at(vk, pos)
    if not pos then return nil end
    for _i, row in ipairs(vk.layout or {}) do
        for _j, key in ipairs(row) do
            if key.dimen and key.dimen.x and key.dimen:contains(pos) then return key end
        end
    end
end

--- Forgets a key's long press waiting for its confirmation on keyboard `vk` (a no-op when none
--- waits): nothing of it reaches the key.
function Keyboard.drop_key_hold(vk, reason)
    local h = vk and vk.vnc_key_hold
    if not (h and h.event) then return end
    require("logger").dbg("vnc: key hold dropped:", reason)
    h.event = nil
    h.ges = nil
    require("ui/uimanager"):unschedule(h.task)
end

--[[--
Creates the on-screen keyboard.

--- @tparam table session the @{vnc.session} to send key events to
--- @tparam function on_height_changed called when the keyboard height changes
--- @tparam[opt] function press called with the keysym of each key instead of sending its down and
--- up to the session directly
--- @treturn table a ready-to-show VirtualKeyboard (`UIManager:show(vk)`)
]]
function Keyboard.new(session, on_height_changed, press)
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local vk
    local deliver = press or function(keysym)
        session:send_key(keysym, true)
        session:send_key(keysym, false)
    end
    local function send(keysym)
        deliver(keysym)
        close_key_popup_later(vk)
    end
    local rep = { finger = nil, hold_pos = nil, running = false }
    local stub = make_stub(send, on_height_changed, function() Keyboard._start_repeat(vk, rep, send) end)
    pin_latin_layout()
    local ok
    ok, vk = pcall(VirtualKeyboard.new, VirtualKeyboard, { inputbox = stub })
    if not ok then
        Keyboard.restore_layout()
        error(vk)
    end
    vk.vnc_backspace_repeat = rep
    rep.task = function() Keyboard._repeat_tick(vk, rep, send) end
    -- what reaches the keyboard while the repeat runs: the gesture that ends the hold (KOReader
    -- delivers the lift to the key as a hold_release, which the key then ignores) and the keyboard
    -- going away
    local handle = vk.handleEvent
    local function pass(w, event)
        if event.handler == "onGesture" then
            local ges = event.args and event.args[1]
            local kind = ges and ges.ges
            if kind == "hold" then
                rep.hold_pos = ges.pos
            elseif rep.running and kind ~= "hold_pan" then
                Keyboard.stop_repeat(vk, kind)
            end
        elseif event.handler == "onCloseWidget" then
            Keyboard.stop_repeat(vk, "keyboard closed")
        end
        return handle(w, event)
    end
    -- a key's long press waits for its confirmation (see HOLD_CONFIRM)
    local hold = {}
    vk.vnc_key_hold = hold
    local function confirm(why)
        local event = hold.event
        if not event then return end
        hold.event, hold.ges = nil, nil
        require("ui/uimanager"):unschedule(hold.task)
        if not vk.visible then return end
        require("logger").dbg("vnc: key hold confirmed:", why)
        pass(vk, event)
    end
    hold.task = function() confirm("still down after " .. Keyboard.HOLD_CONFIRM .. " s") end
    vk.handleEvent = function(w, event)
        if event.handler == "onGesture" then
            local ges = event.args and event.args[1]
            local kind = ges and ges.ges
            if kind == "hold" and w.visible and key_at(w, ges.pos) then
                Keyboard.drop_key_hold(w, "a new hold")
                hold.event, hold.ges = event, ges
                require("ui/uimanager"):scheduleIn(Keyboard.HOLD_CONFIRM, hold.task)
                return true
            elseif hold.event and kind == "hold_pan" then
                confirm("it moves")
            elseif hold.event and kind == "hold_release" then
                -- lifted before its confirmation: InkView's late burst of a tap, which the lift
                -- alone types
                Keyboard.drop_key_hold(w, "lifted before " .. Keyboard.HOLD_CONFIRM .. " s: a tap")
            end
        elseif event.handler == "onCloseWidget" then
            Keyboard.drop_key_hold(w, "keyboard closed")
        end
        return pass(w, event)
    end
    return vk
end

return Keyboard
