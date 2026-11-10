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
local function make_stub(send, on_height_changed)
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
    function stub:delToStartOfLine() end -- no equivalent single RFB event
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
    local stub = make_stub(send, on_height_changed)
    pin_latin_layout()
    local ok
    ok, vk = pcall(VirtualKeyboard.new, VirtualKeyboard, { inputbox = stub })
    if not ok then
        Keyboard.restore_layout()
        error(vk)
    end
    return vk
end

return Keyboard
