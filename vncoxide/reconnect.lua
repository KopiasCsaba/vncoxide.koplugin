--[[--
The viewer's reconnect loop: a centred box over the last picture that retries a dropped connection
with backoff (`ViewerApp:on_session_error`), or waits for a Retry when the viewer is reopened on a
connection that dropped while it was away (`ViewerApp:onShow`).

Every attempt is `Session:connect` on the same session, which keeps the app and the plane. While
the loop runs the session keeps Wi-Fi on (`Session:set_keep_wifi`); it is handed back when the loop
ends, however it ends. The loop lives with the open viewer only: closing the viewer stops it.

@module vncoxide.reconnect
]]

local _ = require("gettext")

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template

local Reconnect = {}
Reconnect.__index = Reconnect

--- Seconds before attempt n (the last one repeats: the loop never gives up on its own).
Reconnect.BACKOFF = { 2, 4, 8, 15, 30 }

function Reconnect.delay_for(n)
    return Reconnect.BACKOFF[math.min(n, #Reconnect.BACKOFF)]
end

function Reconnect.new(app)
    local r = setmetatable({
        app = app,
        attempt = 0,
        auto = false,
        box = nil,
        _in_flight = nil, -- the token of the attempt waiting for its callback
    }, Reconnect)
    r._retry_task = function() r:_run_attempt() end
    return r
end

function Reconnect:is_running()
    return self.box ~= nil
end

--[[--
Opens the box and starts the loop.
--- @tparam table opts `auto` retries by itself; `immediate` runs attempt 1 now; `message`
---   "reconnecting" titles the box "Reconnecting…" until an attempt fails; `on_success`, `on_stop`
]]
function Reconnect:start(opts)
    if self.box then return end
    self.attempt = 0
    self.auto = opts.auto and true or false
    self.message = opts.message or "lost"
    self.on_success = opts.on_success
    self.on_stop = opts.on_stop
    self._in_flight = nil
    -- From the start, not from the first attempt: a drop reports its error before it restores Wi-Fi
    -- (`Session:_fail`), so Wi-Fi we turned on stays on for the attempt instead of being turned off
    -- and on again.
    self.app.session:set_keep_wifi(true)
    self:_show_box()
    if opts.immediate then
        self:_run_attempt()
    elseif self.auto then
        UIManager:scheduleIn(Reconnect.delay_for(1), self._retry_task)
    end
end

--- Runs the next attempt now, and retries by itself from then on.
function Reconnect:retry_now()
    if not self.box then return end
    self.auto = true
    if self._in_flight then
        -- one is on its way already: its outcome decides what comes next
        self:_update_box()
        return
    end
    self:_run_attempt()
end

--- Stops the loop and drops the connection (the box's Close and Back: no confirmation).
function Reconnect:close()
    self:stop()
    self.app:disconnect_session()
end

--- Stops the loop: no timer, no box, and the Wi-Fi duty handed back. Safe to call any time.
function Reconnect:stop()
    UIManager:unschedule(self._retry_task)
    local in_flight = self._in_flight
    self._in_flight = nil
    local box = self.box
    if not box then return end
    self.box = nil
    UIManager:close(box)
    local session = self.app.session
    session:set_keep_wifi(false)
    -- an attempt still on its way is given up (and, with the duty handed back, restores Wi-Fi)
    if in_flight and session:get_state() == "connecting" then session:hangup() end
    local on_stop = self.on_stop
    self.on_stop, self.on_success = nil, nil
    if on_stop then on_stop() end
    self.app:_sync_keyboard_later()
end

-- ---------------------------------------------------------------- attempts

function Reconnect:_run_attempt()
    if not self.box then return end
    UIManager:unschedule(self._retry_task)
    -- connected meanwhile by another route: a second connect would only be refused
    if self.app.session:is_connected() then
        self._in_flight = nil
        self:_succeeded()
        return
    end
    self.attempt = self.attempt + 1
    local token = {}
    self._in_flight = token
    self:_update_box()
    local session = self.app.session
    session:set_keep_wifi(true)
    session:connect(function(ok)
        -- the loop stopped, or this attempt was given up, since it started
        if self._in_flight ~= token then return end
        self._in_flight = nil
        if ok then self:_succeeded() else self:_failed() end
    end)
end

function Reconnect:_succeeded()
    UIManager:unschedule(self._retry_task)
    local box = self.box
    self.box = nil
    UIManager:close(box)
    local app = self.app
    app.session:set_keep_wifi(false)
    app.session:attach(app) -- (requests the full update)
    -- a remote of another orientation than last time turns the screen
    app:match_remote_orientation()
    app:_wholesale_change()
    local on_success = self.on_success
    self.on_stop, self.on_success = nil, nil
    if on_success then on_success() end
    app:_sync_keyboard_later()
end

function Reconnect:_failed()
    if not self.box then return end
    -- a failed attempt means the connection is lost, whatever the box said so far
    self.message = "lost"
    if self.auto then
        UIManager:scheduleIn(Reconnect.delay_for(self.attempt + 1), self._retry_task)
    end
    self:_update_box()
end

-- ---------------------------------------------------------------- the box

function Reconnect:_box_title()
    if self.message == "reconnecting" then return _("Reconnecting…") end
    if not self.auto then return _("Connection lost") end
    if self._in_flight then
        return T(_("Connection lost — reconnecting… (attempt %1)"), self.attempt)
    end
    return T(_("Connection lost — reconnecting… (attempt %1, next in %2 s)"),
        self.attempt + 1, Reconnect.delay_for(self.attempt + 1))
end

function Reconnect:_box_buttons()
    return { {
        { text = self.auto and _("Retry now") or _("Retry"), callback = function() self:retry_now() end },
        { text = _("Close"), callback = function() self:close() end },
    } }
end

function Reconnect:_show_box()
    local box = ButtonDialog:new{
        title = self:_box_title(),
        title_align = "center",
        dismissable = false, -- no tap outside: only Back, which is Close
        buttons = self:_box_buttons(),
    }
    if Device:hasKeys() then
        box.key_events.Close = { { Device.input.group.Back } }
    end
    box.onClose = function()
        self:close()
        return true
    end
    self.box = box
    UIManager:show(box, "ui")
    -- it owns the screen now: the keyboard makes way
    self.app:_sync_keyboard_later()
end

--- Retitles the box (and relabels Retry) once per state change: no countdown repaints.
function Reconnect:_update_box()
    local box = self.box
    if not box then return end
    local title = self:_box_title()
    local buttons = self:_box_buttons()
    if title == box.title and buttons[1][1].text == box.buttons[1][1].text then return end
    box.buttons = buttons
    box:setTitle(title) -- (rebuilds the buttons too)
end

return Reconnect
