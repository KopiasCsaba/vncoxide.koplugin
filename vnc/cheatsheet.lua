--[[--
The gesture cheat-sheet: a centred card listing what each gesture does in the pointer mode just
switched to. Shown by `ViewerApp:toggle_pointer_mode`; a tap anywhere (or Back) closes it and goes
no further (it is a window of its own, not a viewer overlay, so the viewer sends nothing while it
is up).

@module vnc.cheatsheet
]]

local _ = require("gettext")

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Screen = Device.screen

local CheatSheet = InputContainer:extend{
    mode = "touch",
    on_close = nil, -- called once the sheet has closed
}

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

CheatSheet.ROWS = {
    touch = rows_for{
        { _("Tap"), _("Left click at the finger") },
        { _("Long press"), _("Right click at the finger") },
        { _("Drag"), _("Drag with the left button") },
    },
    mouse = rows_for{
        { _("Tap"), _("Left click at the pointer") },
        { _("Long press"), _("Right click at the pointer") },
        { _("Drag"), _("Move the pointer") },
        { _("Double tap and drag"), _("Drag with the left button") },
    },
}

CheatSheet.TITLES = { touch = _("Touch mode"), mouse = _("Mouse mode") }

function CheatSheet:init()
    self.rows = CheatSheet.ROWS[self.mode] or CheatSheet.ROWS.touch
    local face = Font:getFace("cfont", 20)
    local col = math.floor(Screen:getWidth() * 0.3)
    local group = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = CheatSheet.TITLES[self.mode] or CheatSheet.TITLES.touch,
                        face = Font:getFace("tfont", 24), bold = true },
        VerticalSpan:new{ width = Size.padding.large },
    }
    for _i, r in ipairs(self.rows) do
        group[#group + 1] = HorizontalGroup:new{
            TextWidget:new{ text = r[1], face = face, bold = true, max_width = col },
            HorizontalSpan:new{ width = Size.padding.large },
            TextWidget:new{ text = r[2], face = face, max_width = Screen:getWidth() - col - Size.padding.large * 6 },
        }
        group[#group + 1] = VerticalSpan:new{ width = Size.padding.default }
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            padding = Size.padding.large,
            margin = 0,
            group,
        },
    }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

function CheatSheet:onShow()
    UIManager:setDirty(self, "ui")
end

function CheatSheet:onTap()
    self:close()
    return true
end

function CheatSheet:onClose()
    self:close()
    return true
end

function CheatSheet:close()
    if self._closed then return end
    self._closed = true
    UIManager:close(self, "ui")
    if self.on_close then self.on_close() end
end

return CheatSheet
