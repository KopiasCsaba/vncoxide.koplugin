--[[--
The picture benchmark's results as ranked cards on a full-screen page: one card per combination
in the given (ranked) order, each with its rank, label, speed against the best time of each step type and time for one
round of the five steps, a bar as long as that speed, and the five step times below in smaller
grey type. Tapping a scored card hands its row to `on_pick` (the caller confirms and applies); a
failed card shows its reason and takes no tap. ✕, Close and Back close the page and call `on_close`.

    UIManager:show(BenchResults:new{ rows = rows, on_pick = function(row) end, on_close = function() end })

@module vncoxide.benchresults
]]

local _ = require("gettext")
local T = require("ffi/util").template

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Screen = Device.screen

local STEPS = { "photo", "text", "scroll", "small", "flip" }
local STEP_NAMES = { photo = _("photo"), text = _("text"), scroll = _("scroll"), small = _("small"), flip = _("flip") }
local FAILED_RANK = "\u{2013}"

local function round(x) return math.floor(x + 0.5) end

local BenchResults = InputContainer:extend{
    name = "VNCBenchResults",
    title = _("Picture benchmark"),
    rows = nil,      -- ranked rows from @{vncoxide.benchmark} (mandatory)
    on_pick = nil,   -- function(row), a scored card was tapped
    on_close = nil,  -- function(), after the page closed
    covers_fullscreen = true,
}

--[[--
A card's texts: `title` the combination's label; `figure` "speed%   round s" for a scored row,
the failure reason for a failed one; `steps` the five step times (nil for a failed row).

--- @tparam table row
--- @treturn table { title, figure, steps }
]]
function BenchResults.card_text(row)
    local out = { title = row.combination.label }
    if not row.ok then
        local err = tostring(row.error)
        -- the engine's per-pass failures already say "failed in pass N: ..."
        out.figure = err:find("^failed") and err or T(_("failed: %1"), err)
        return out
    end
    out.figure = T(_("%1%   %2 s"), round(row.speed_pct), string.format("%.2f", row.round_s))
    local parts = {}
    for _i, id in ipairs(STEPS) do
        parts[#parts + 1] = STEP_NAMES[id] .. " " .. round(row.cat_ms[id])
    end
    out.steps = T(_("%1 ms"), table.concat(parts, " · "))
    return out
end

--- One card: a tap target over its whole area when the row was scored.
local Card = InputContainer:extend{
    row = nil,
    on_pick = nil,
}

--- The part of the card inside the scroll container's visible area (an empty range when none), so
--- the scrolled-out or truncated (hidden) part of a card is not tappable.
function Card:visible_dimen()
    local view = self.view and self.view()
    if not view then return self.dimen end
    local d = self.dimen
    local x0, y0 = math.max(d.x, view.x), math.max(d.y, view.y)
    local x1, y1 = math.min(d.x + d.w, view.x + view.w), math.min(d.y + d.h, view.y + view.h)
    if x1 <= x0 or y1 <= y0 then return Geom:new{ x = -1, y = -1, w = 0, h = 0 } end
    return Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

function Card:onTapCard()
    if self.row.ok and self.on_pick then self.on_pick(self.row) end
    return true
end

--[[--
Builds the card for `row` on a line `width` pixels wide. Line 1: rank, label and (scored) the
figure flush right, all bold; then the bar and the step times, indented under the label.
]]
local function build_card(row, width, on_pick)
    local text = BenchResults.card_text(row)
    local pad_v = Size.padding.large
    local label_face = Font:getFace("x_smallinfofont")
    local small_face = Font:getFace("xx_smallinfofont")
    local gap = Size.padding.large
    local rank_text = row.rank and tostring(row.rank) or FAILED_RANK
    -- room for a two-digit rank, so the labels line up whatever the ranks
    local rank_width = TextWidget:new{ text = "00", face = label_face, bold = true }:getSize().w + gap
    local card = Card:new{
        row = row, on_pick = on_pick,
        rank_text = rank_text, label_text = text.title,
        line_width = width, rank_width = rank_width, gap = gap,
        label_face = label_face, figure_face = label_face,
    }

    local first = HorizontalGroup:new{ align = "center" }
    local rank_widget = TextWidget:new{ text = rank_text, face = label_face, bold = true }
    first[1] = rank_widget
    first[2] = HorizontalSpan:new{ width = rank_width - rank_widget:getSize().w }
    local body = VerticalGroup:new{ align = "left", first }
    if row.ok then
        local figure = TextWidget:new{ text = text.figure, face = label_face, bold = true }
        local fw = figure:getSize().w
        local label = TextWidget:new{ text = text.title, face = label_face, bold = true,
            max_width = width - rank_width - gap - fw }
        first[3] = label
        first[4] = HorizontalSpan:new{ width = width - rank_width - label:getSize().w - fw }
        first[5] = figure
        card.bar = ProgressWidget:new{
            width = width - rank_width,
            height = math.floor(Size.item.height_default / 2),
            margin_h = 0,
            percentage = math.max(0, math.min(1, (row.speed_pct or 0) / 100)),
        }
        body[#body + 1] = VerticalSpan:new{ width = Size.padding.default }
        body[#body + 1] = HorizontalGroup:new{ HorizontalSpan:new{ width = rank_width }, card.bar }
        body[#body + 1] = VerticalSpan:new{ width = Size.padding.small }
        body[#body + 1] = HorizontalGroup:new{
            HorizontalSpan:new{ width = rank_width },
            TextBoxWidget:new{ text = text.steps, face = small_face, width = width - rank_width,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY },
        }
    else
        first[3] = TextWidget:new{ text = text.title, face = label_face, bold = true,
            max_width = width - rank_width }
        body[#body + 1] = VerticalSpan:new{ width = Size.padding.small }
        body[#body + 1] = HorizontalGroup:new{
            HorizontalSpan:new{ width = rank_width },
            TextBoxWidget:new{ text = text.figure, face = small_face, width = width - rank_width },
        }
    end
    card[1] = FrameContainer:new{
        bordersize = 0, margin = 0,
        padding = 0, padding_top = pad_v, padding_bottom = pad_v,
        body,
    }
    card.dimen = Geom:new{ x = 0, y = 0, w = width, h = card[1]:getSize().h }
    if row.ok and Device:isTouchDevice() then
        card.ges_events = {
            TapCard = { GestureRange:new{ ges = "tap", range = function() return card:visible_dimen() end } },
        }
    else
        card.ges_events = {}
    end
    return card
end

function BenchResults:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    local side = Size.padding.fullscreen
    local scroll_w = sw - ScrollableContainer:getScrollbarWidth()
    local width = scroll_w - 2 * side

    self.title_bar = TitleBar:new{
        width = sw,
        fullscreen = true,
        title = self.title,
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    self.buttons = { { { text = _("Close"), callback = function() self:onClose() end } } }
    local button_table = ButtonTable:new{
        width = sw - 2 * side,
        buttons = self.buttons,
        zero_sep = true,
        show_parent = self,
    }

    local content = VerticalGroup:new{ align = "left" }
    local grid = {}
    local content_h = 0 -- (VerticalGroup caches its layout on the first getSize: track it here)
    local function add(widget, as_row)
        local h = widget:getSize().h
        content[#content + 1] = widget
        if as_row then grid[#grid + 1] = { top = content_h, bottom = content_h + h - 1 } end
        content_h = content_h + h
    end
    local header = { _("Speed vs. the best time of each step type (longer bar = faster) · time for one round of 5 steps") }
    local any_scored = false
    for _i, row in ipairs(self.rows) do
        if row.ok then any_scored = true break end
    end
    if any_scored then header[2] = _("Tap a setting to use it.") end
    local header_box = VerticalGroup:new{ align = "left", VerticalSpan:new{ width = Size.padding.large } }
    for _i, line in ipairs(header) do
        header_box[#header_box + 1] = TextBoxWidget:new{ text = line, face = Font:getFace("xx_smallinfofont"),
            width = width, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
    end
    add(header_box, true)

    self.cards = {}
    local on_pick = function(row) if self.on_pick then self.on_pick(row) end end
    for i, row in ipairs(self.rows) do
        if i > 1 then
            add(LineWidget:new{ dimen = Geom:new{ w = width, h = Size.line.thin },
                background = Blitbuffer.COLOR_GRAY })
        end
        local card = build_card(row, width, on_pick)
        card.view = function() return self:visible_area() end
        self.cards[i] = card
        add(card, true)
    end

    local body_h = sh - self.title_bar:getSize().h - button_table:getSize().h - 2 * Size.padding.default
    self.cropping_widget = ScrollableContainer:new{
        dimen = Geom:new{ w = sw, h = body_h },
        show_parent = self,
        step_scroll_grid = grid,
        hide_truncated_grid_items = true,
        FrameContainer:new{
            bordersize = 0, margin = 0, padding = 0, padding_left = side, padding_right = side,
            content,
        },
    }
    self[1] = FrameContainer:new{
        width = sw, height = sh,
        bordersize = 0, margin = 0, padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            self.title_bar,
            self.cropping_widget,
            VerticalSpan:new{ width = Size.padding.default },
            button_table,
            VerticalSpan:new{ width = Size.padding.default },
        },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

--- The screen rectangle of the cards' scroll container that is actually drawn (a bottom card cut
--- off by the container is hidden, see `hide_truncated_grid_items`).
function BenchResults:visible_area()
    local c = self.cropping_widget
    if not (c and c.dimen) then return nil end
    return Geom:new{ x = c.dimen.x, y = c.dimen.y, w = c.dimen.w, h = c._crop_h_limited or c._crop_h or c.dimen.h }
end

function BenchResults:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function BenchResults:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

--- ✕, Close or Back: closes the page, then `on_close`.
function BenchResults:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

return BenchResults
