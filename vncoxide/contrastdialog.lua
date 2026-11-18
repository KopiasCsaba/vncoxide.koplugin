--[[--
The contrast dialog: a small box under the toolbar (above it when the bar sits low) with KOReader's ButtonProgressWidget (the
stepped bar of its own frontlight dialog), one step per @{vncoxide.settings.CONTRAST_LEVELS} level, the
neutral one marked as the default.

A step goes to `ViewerApp:set_contrast`, which stores it and redraws the picture with the new tone
curve from the remote plane at once (no update from the server is needed, see
@{vncoxide.framebuffer.Remote:set_contrast}); the dialog stays up so the effect can be judged. ✕, Back,
a tap outside it or the toolbar button close it.

@module vncoxide.contrastdialog
]]

local _ = require("gettext")
local T = require("ffi/util").template

local Blitbuffer = require("ffi/blitbuffer")
local ButtonProgressWidget = require("ui/widget/buttonprogresswidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Settings = require("vncoxide/settings")

local Screen = Device.screen

local ContrastDialog = InputContainer:extend{
    name = "VNCContrastDialog",
    app = nil,       -- the @{vncoxide.app} that owns us (mandatory)
    modal = true,    -- taps never fall through to the viewer
}

--- The index of `value` in the levels (the neutral one when it is not a level).
local function level_index(value)
    local neutral
    for i, v in ipairs(Settings.CONTRAST_LEVELS) do
        if v == value then return i end
        if v == 1 then neutral = i end
    end
    return neutral
end

local function title_for(value)
    return T(_("Contrast: %1 %"), math.floor(value * 100 + 0.5))
end

function ContrastDialog:init()
    local app = self.app
    local levels = Settings.CONTRAST_LEVELS
    local screen = Screen:getSize()
    local width = math.floor(math.min(screen.w, screen.h) * 0.9)
    local border = Size.border.window
    local inner = width - 2 * border

    self.title_bar = TitleBar:new{
        width = inner,
        title = title_for(app.settings.remote_contrast or 1),
        with_bottom_line = true,
        bottom_line_color = Blitbuffer.COLOR_DARK_GRAY,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    self.progress = ButtonProgressWidget:new{
        width = inner - 2 * Size.padding.large,
        num_buttons = #levels,
        position = level_index(app.settings.remote_contrast),
        default_position = level_index(1),
        callback = function(i)
            local value = levels[i]
            app:set_contrast(value)
            self.title_bar:setTitle(title_for(value))
        end,
        show_parent = self,
    }
    local gap = Size.padding.large
    self.frame = FrameContainer:new{
        bordersize = border,
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            self.title_bar,
            VerticalSpan:new{ width = gap },
            CenterContainer:new{
                dimen = Geom:new{ w = inner, h = self.progress:getSize().h },
                self.progress,
            },
            VerticalSpan:new{ width = gap },
        },
    }
    self[1] = self.frame
    -- under the toolbar (or its round button) when it is up, centred on it (like the display
    -- panel), or above it when there is no room below; else at the top centre
    local size = self.frame:getSize()
    local m = Size.margin.default
    local x, y = math.floor((screen.w - size.w) / 2), m
    local bar = app.toolbar
    if bar and app.toolbar_visible then
        local d = bar.dimen
        x = math.max(0, math.min(d.x + math.floor((d.w - size.w) / 2), screen.w - size.w))
        y = d.y + d.h + m
        if y + size.h > screen.h and d.y - m - size.h >= 0 then y = d.y - m - size.h end
    end
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }

    self.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = screen.w, h = screen.h } } },
    }
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
end

--- `dimen` is where the box sits on the screen; InputContainer's own paintTo would move it to the
--- window's origin.
function ContrastDialog:paintTo(bb, x, y)
    self.frame:paintTo(bb, x + self.dimen.x, y + self.dimen.y)
end

--- A tap outside the box closes it; one inside that no button took is just swallowed.
function ContrastDialog:onTapClose(_arg, ges)
    if not self.dimen:contains(ges.pos) then self:onClose() end
    return true
end

--- ✕, Back or a tap outside: the viewer closes us.
function ContrastDialog:onClose()
    self.app:close_contrast_dialog()
    return true
end

function ContrastDialog:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

--- Opens the dialog for `app`.
--- @treturn table the dialog
function ContrastDialog.open(app)
    local dialog = ContrastDialog:new{ app = app }
    UIManager:show(dialog, "ui", dialog.dimen)
    return dialog
end

return ContrastDialog
