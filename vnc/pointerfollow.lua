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
Not taken from RustDesk: `getPointInRemoteRect` drops a whole update whose target lies outside the
remote on both axes (after snapping by 5 pixels); here each axis is clamped instead, so a pointer
pushed past a corner of a picture panned beyond its edges still reaches that corner.

@module vnc.pointerfollow
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
    local follow = false
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
    return new, follow and (new - cur) or 0
end

return PointerFollow
