--[[--
Mouse mode, zoomed in: the view follows the pointer, RustDesk's rule (flutter/lib/models/model.dart,
`CursorModel.updatePan`).

Per axis, a move of the pointer that takes it to or past the centre of the view, outwards, moves
the view along by the same remote distance (so the pointer stays at the centre on screen) as long
as the view has room to the remote's edge; any other move moves the pointer alone, kept inside the
view. Either way the pointer stays on the remote screen.

Matching RustDesk where the plan's sketch differed:
- the room is measured from the view edge rounded to whole pixels (`roundToDouble`);
- a pointer moving alone may reach the view edge itself (`r.right - _x`), not one pixel short of
  it; the clamp to the remote screen keeps it on the last pixel there.
Not taken from RustDesk:
- the view's shift is capped by the unrounded room, so the view never passes the remote's edge
  (RustDesk's rounded room lets it end up to half a pixel beyond);
- `getPointInRemoteRect` drops a whole update whose target lies outside the
remote on both axes (after snapping by 5 pixels); here each axis is clamped instead, so a pointer
pushed past a corner of a picture panned beyond its edges still reaches that corner.

@module vncoxide.pointerfollow
]]

local PointerFollow = {}

local function round(v) return math.floor(v + 0.5) end

--[[--
One axis of a pointer move, all in remote pixels.
--- @tparam number cur the pointer
--- @tparam number d the move
--- @tparam number view_lo, view_hi the span the view shows
--- @tparam number remote_lo, remote_hi the remote screen's span (`0`, its width or height)
--- @treturn number, number the new pointer, and how far the view moves with it (0: it stays)
]]
function PointerFollow.axis(cur, d, view_lo, view_hi, remote_lo, remote_hi)
    local follow, dir = false, d
    if d > 0 then
        local room = remote_hi - round(view_hi)
        follow = cur + d > (view_lo + view_hi) / 2 and room > 0
        d = math.min(d, follow and room or (view_hi - cur))
    elseif d < 0 then
        local room = remote_lo - round(view_lo)
        follow = cur + d < (view_lo + view_hi) / 2 and room < 0
        d = math.max(d, follow and room or (view_lo - cur))
    end
    local new = math.max(remote_lo, math.min(cur + d, remote_hi - 1))
    if not follow then return new, 0 end
    -- (the room above is rounded, as in RustDesk; the view itself stops exactly at the edge)
    if dir > 0 then return new, math.min(new - cur, remote_hi - view_hi) end
    return new, math.max(new - cur, remote_lo - view_lo)
end

return PointerFollow
