# Viewer Toolbar, Pointer Modes, Gestures and Reconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the full-screen in-session menu with a compact top toolbar, add Touch/Mouse pointer modes with an unambiguous gesture set, a key strip over the on-screen keyboard, and a viewer that reconnects by itself after a drop.

**Architecture:** The toolbar is a child widget painted by `ViewerApp` on top of the canvas, and the app sends gestures to it first. It is not a separate window, so the window-stack logic (`_input_target`, `_modal_above`) stays as it is. The Display panel, the ⋯ popup (the reduced `vnc/menu.lua`), the cheat-sheet and the reconnect box are ordinary KOReader popups. A new `vnc/reconnect.lua` controller drives `Session:connect` on the same session with backoff. `Session` gains a keep-Wi-Fi retry mode.

**Tech Stack:** Lua/LuaJIT, KOReader widget stack (InputContainer, Button/IconButton, ButtonDialog, InputDialog, GestureRange), headless suites in `tools/`.

**Spec:** `docs/superpowers/specs/2026-11-07-toolbar-gestures-reconnect-design.md`

## Global Constraints

1. Never name any other remote-desktop product anywhere: source, comments, docs, README, NOTES, tests, test names or commit messages. The repo's own server tooling (`x11vnc`, `vnc-server.sh`) may still be referred to as it is today.
2. No assistant/brand attribution in commits or files (no trailers, no co-author lines).
3. KOReader widget stack only, no new dependencies. No custom raw multitouch handling: use only GestureDetector gestures (`tap`, `hold`, `hold_release`, `pan`, `pan_release`, `swipe`, `two_finger_*`, `inward_pan`/`outward_pan`, `pinch`/`spread`).
4. All three suites stay green after every task. Run them from the KOReader dir with `P=/home/dev/mnt/aitmp/pocketbook-remote-screen/vnc.koplugin` and `H=/home/dev/mnt/aitmp/pocketbook-remote-screen/tmp/vnc-home`:
   ```bash
   cd /home/dev/mnt/aitmp/pocketbook-remote-screen/tmp/koreader/lib/koreader
   # ui (NOT idempotent: a reused KO_HOME keeps the "fresh" profile and fails 2 checks, so wipe it first)
   rm -rf "$H/ui"; KO_HOME=$H/ui SDL_VIDEODRIVER=dummy LUA_PATH="$P/?.lua;;" LUA_CPATH="./common/?.so;;" ./luajit "$P/tools/ui_smoke.lua"
   # proto
   LUA_PATH="$P/?.lua;./common/?.lua;./common/?/init.lua;;" LUA_CPATH="./common/?.so;;" ./luajit "$P/tools/proto_smoke.lua" --tmp $H/proto
   # server
   KO_HOME=$H/server SDL_VIDEODRIVER=dummy LUA_PATH="$P/?.lua;./common/?.lua;./common/?/init.lua;;" LUA_CPATH="./common/?.so;;" ./luajit "$P/tools/server_smoke.lua"
   ```
   Success lines observed at plan time: ui `all checks passed` (121 `ok -` lines, fresh KO_HOME), proto `all checks passed`, server `62 check(s), 0 failure(s)`. The ui and server counts grow with new checks. Success means exit code 0, no `FAIL:` line, and the last line as above. "Run UI suite" below means the ui command. Filter with `| grep -E '^(FAIL|ok - <name>)|passed|failed'`.
5. README.md and NOTES.txt describe the new UX (Task 12). Code comments follow the file's existing style.
6. Anti-goals (spec): no Touch-mode tap lost or delayed; no button or modifier left down after a gesture, mode switch, toolbar open, reconnect or close; partial `"ui"`/`"fast"` refreshes for toolbar and panels; a full flash only on Refresh and wholesale changes, as today; the reconnect loop leaks no session/socket/plane and never toggles Wi-Fi under another connection.

## Review Focus

1. A Touch-mode canvas drag or long press whose finger lifts over the toolbar must still release the button on the remote. Test `toolbar_does_not_eat_a_canvas_drag_release` (Task 5).
2. A pending Mouse-mode click or double-tap drag when the mode switches, a key is sent or the viewer closes: the click goes out before the key or the switch, nothing goes out after close, and no button stays down. Test `mouse_pending_click_is_settled_by_key_mode_switch_and_close` (Task 3).
3. Rotating while the toolbar and key strip are up: the toolbar is re-centred for the new width and the strip sits right above the re-laid keyboard. Tests `toolbar_recentres_after_rotation` (Task 5) and `key_strip_follows_rotation_and_layout_height` (Task 7).
4. The connection drops in the middle of a drag or long press: the drag ends, and after the reconnect no stale button release or armed modifier goes out on the new connection. Test `a_drop_mid_drag_ends_it_and_reconnect_sends_nothing_stale` (Task 10).
5. The remote comes back smaller after a reconnect (server restarted at another size): the Mouse-mode pointer is clamped into the new size before the next move. Test `mouse_pointer_is_clamped_after_the_remote_shrinks` (Task 3).

---

### Task 1: Gesture cleanup and two-finger tap = fit

**Files:**
- Modify: `vnc/app.lua:143-178` (init_gestures), `:376-428` (onRotate, onTwoFingerSwipe, onKbdShow/onKbdHide), `:292-326` (drop `_two_finger_moved_view` and `last.vx/vy`)
- Test: `tools/ui_smoke.lua`

**Interfaces:**
- Produces: `ViewerApp:fit_to_screen()`. Sets the zoom mode to `"fit_with_keyboard"` when `self.vk_visible`, else `"fit"`, through `zoom_to`, flushes `plugin.settings`, and leaves the view centred. `ViewerApp:onTwoFingerTap(_, ges) -> true|nil` (nil when not `_input_target()`). `onTwoFingerSwipe(_, ges)` only calls `onTwoFingerPanRelease` and returns true. `ges_events` has no `Rotate`, `KbdShow` or `KbdHide` entry and gains `TwoFingerTap` (`ges = "two_finger_tap"`, canvas range).

- [ ] **Step 1: Write the failing tests** (delete `keyboard_shows_on_a_swipe_up_from_the_bottom`, `keyboard_swipe_honours_the_always_visible_setting`, `keyboard_hides_on_a_swipe_down_above_it`, `quick_drag_up_the_keyboard_strip_still_shows_the_keyboard`, `two_finger_flick_scrolls_the_wheel`, `two_finger_flick_leaves_armed_modifiers_alone` and `two_finger_flick_scrolls_only_when_the_view_did_not_move`, then add:)

```lua
check("two_finger_flick_only_ends_the_pan", function()
    local app, remote, sent = new_app()
    dispatch_gesture{ ges = "two_finger_pan", pos = Geom:new{x=200,y=400}, start_pos = Geom:new{x=200,y=300}, relative = {x=0,y=100} }
    dispatch_gesture{ ges = "two_finger_swipe", direction = "south", distance = 400, pos = Geom:new{x=200,y=400} }
    for _, e in ipairs(sent.pointer) do assert_true(e.mask ~= 8 and e.mask ~= 16, "a flick never scrolls") end
    assert_true(app._two_finger_pan == nil and not app._view_moving, "the flick ended the pan")
    close_viewer(app, remote)
end)
check("rotate_gesture_and_bottom_swipes_are_not_handled", function()
    local app, remote = new_app()
    local before = Screen:getRotationMode()
    dispatch_gesture{ ges = "rotate", direction = "cw", pos = Geom:new{x=100,y=100}, angle = 90 }
    assert_true(Screen:getRotationMode() == before, "a two-finger rotate never turns the screen")
    local s = Screen:getSize()
    dispatch_gesture{ ges = "swipe", direction = "north", distance = 200, pos = Geom:new{x=s.w/2, y=s.h-10} }
    assert_true(app.vk_visible == false, "a bottom swipe-up no longer shows the keyboard")
    assert_true(app.ges_events.Rotate == nil and app.ges_events.KbdShow == nil and app.ges_events.KbdHide == nil)
    close_viewer(app, remote)
end)
check("two_finger_tap_fits_and_recentres", function()
    local app, remote = new_app()
    app:zoom_to(2); remote:pan_by(-50, -40)
    dispatch_gesture{ ges = "two_finger_tap", pos = Geom:new{x=100,y=100}, span = 50 }
    assert_true(app.settings.zoom_mode == "fit", "fit, the keyboard being down")
    local vx, vy = remote.view_x, remote.view_y
    app:zoom_to("fit")
    assert_true(remote.view_x == vx and remote.view_y == vy, "re-centred like a fresh fit")
    app:set_keyboard_visible(true)
    dispatch_gesture{ ges = "two_finger_tap", pos = Geom:new{x=100,y=100}, span = 50 }
    assert_true(app.settings.zoom_mode == "fit_with_keyboard", "fit with keyboard while it is up")
    close_viewer(app, remote)
end)
```

- [ ] **Step 2: Run the UI suite and confirm it fails.** Expected: `FAIL: two_finger_flick_only_ends_the_pan`, `FAIL: rotate_gesture_and_bottom_swipes_are_not_handled` and `FAIL: two_finger_tap_fits_and_recentres`.
- [ ] **Step 3: Implement.** Remove `ViewerApp:onRotate`, `onKbdShow`, `onKbdHide`, their `ges_events` and the `bottom_strip`/`upper_canvas` helpers. Reduce `onTwoFingerSwipe` to ending the pan. Add `TwoFingerTap` and `fit_to_screen` as in Interfaces. Update the comment in `onTwoFingerPanRelease` that mentions "swipe up from the bottom".
- [ ] **Step 4: Run all three suites and confirm they pass.** Expected: the three success lines.
- [ ] **Step 5: Commit.** `git add vnc/app.lua tools/ui_smoke.lua && git commit -m "feat(viewer): two-finger tap fits; drop flick scroll, rotate and keyboard swipes"`

### Task 2: Pointer mode model, per-profile persistence, pointer speed setting

**Files:**
- Modify: `vnc/settings.lua` (`PROFILE_FIELDS`, `DEFAULTS`, `clean_profile`, `save_profile` given_or_kept list), `main.lua` (new method after `save_profile`), `vnc/app.lua`
- Test: `tools/ui_smoke.lua` (also extend `new_app`)

**Interfaces:**
- Produces:
  - Profile field `pointer_mode`, either `"touch"` or `"mouse"`. Anything else cleans to `"touch"`.
  - `Settings.DEFAULTS.pointer_speed = "normal"` and `Settings.POINTER_SPEEDS = { slow = 0.75, normal = 1.25, fast = 2.0 }`.
  - `Settings.DEFAULTS.toolbar_scroll_buttons = false` (used by Tasks 5 and 6).
  - `VNC:update_profile_fields(name: string, fields: table) -> boolean`. Merges `fields` into the stored profile through `save_profile(merged, name)`, points the live session at the stored copy, and flushes.
  - `ViewerApp:get_pointer_mode() -> "touch"|"mouse"` reads `session:get_profile().pointer_mode`, default `"touch"`.
  - `ViewerApp:set_pointer_mode(mode)` first ends any pointer action (`_end_pointer_action`) and, from Task 3 on, settles the pending click (`_flush_deferred_click`). Then it calls `plugin:update_profile_fields(profile.name, { pointer_mode = mode })` and `self.session:set_profile(...)` when the plugin does not.
  - `ViewerApp:pointer_speed() -> number` returns `POINTER_SPEEDS[settings.pointer_speed]`, or 1.25 when the value is unknown.
- `new_app(plane_w, plane_h, opts)`: the fake plugin gains `update_profile_fields` (it records its calls in `sent.profile_updates` and merges them into the fake profile). The fake session's `get_profile` returns one shared table `{ name = "test", pointer_mode = opts and opts.mode or "touch" }`, and the fake session gains `set_profile`.

- [ ] **Step 1: Write the failing tests**

```lua
check("pointer_mode_is_cleaned_and_kept_per_profile", function()
    local Settings = require("vnc/settings")
    local path = data_dir .. "/ui_smoke_pointer_mode.lua"; os.remove(path)
    local s = Settings.open(path)
    s:save_profile{ name = "m", host = "h", port = 1, pointer_mode = "mouse" }
    s:save_profile{ name = "j", host = "h", port = 1, pointer_mode = "joystick" }
    assert_true(s:get_profile("m").pointer_mode == "mouse")
    assert_true(s:get_profile("j").pointer_mode == "touch", "junk cleans to touch")
    s:save_profile({ name = "m", host = "h2", port = 1 }, "m")
    assert_true(s:get_profile("m").pointer_mode == "mouse", "an edit without the field keeps it")
    assert_true(s.data.settings.pointer_speed == "normal" and s.data.settings.toolbar_scroll_buttons == false)
end)
check("set_pointer_mode_persists_through_the_plugin", function()
    local app, remote, sent = new_app()
    assert_true(app:get_pointer_mode() == "touch")
    app:set_pointer_mode("mouse")
    assert_true(app:get_pointer_mode() == "mouse")
    assert_true(#sent.profile_updates == 1 and sent.profile_updates[1].fields.pointer_mode == "mouse")
    close_viewer(app, remote)
end)
```

- [ ] **Step 2: Run the UI suite and confirm it fails.** Expected: both new checks FAIL.
- [ ] **Step 3: Implement** the interfaces above. `update_profile_fields` builds the merge from `self.settings:get_profile(name)` and reuses `VNC:save_profile`.
- [ ] **Step 4: Run all three suites and confirm they pass.**
- [ ] **Step 5: Commit.** `git add vnc/settings.lua main.lua vnc/app.lua tools/ui_smoke.lua && git commit -m "feat(viewer): per-profile pointer mode and pointer speed setting"`

### Task 3: Mouse-mode gestures: relative move, deferred click, double-tap drag

**Files:**
- Modify: `vnc/app.lua` (`onTap`, `onHold`, `onPan`, `onPanRelease`, `send_key`, `onCloseWidget`)
- Test: `tools/ui_smoke.lua`

**Interfaces:**
- Consumes: `get_pointer_mode()` and `pointer_speed()` (Task 2).
- Produces:
  - `ViewerApp.mouse_click_delay() -> seconds` returns `time.to_s(gd.ges_double_tap_interval)`, where `gd = Device.input and Device.input.gesture_detector or require("device/gesturedetector")`.
  - `ViewerApp:_mouse_pointer() -> x, y` keeps floats in `self._mouse_x/_mouse_y`. It starts from `_pointer_x/_pointer_y`, or the remote centre, and is always clamped to `[0, w-1] x [0, h-1]` of the current `remote:get_size()`.
  - `ViewerApp:_flush_deferred_click()` sends a pending click now; no-op when none.
  - `ViewerApp:_drop_deferred_click()` unschedules it without sending.
  - `self._deferred_click_task` (scheduled with `UIManager:scheduleIn(mouse_click_delay(), ...)`) and `self._deferred_click = { pos = Geom }`.
  - Mouse-mode semantics. Tap: if a click is pending and the new tap lands within `Screen:scaleByDPI(50)` of it, send both clicks now (double click), else flush the old one and defer the new one. Pan whose start (`pos - relative`) lies within `scaleByDPI(50)` of a pending tap: drop the click, `_press_armed()`, then button 1 down at the pointer, and later moves carry mask 1 (`self._drag_active = "mouse"`). Any other pan: flush, then relative moves with mask 0 and no armed modifiers. Each move is `delta_screen / remote:get_scale() * pointer_speed()`, where delta is `relative` minus the previous `relative` of the same contact. Pan release: a button drag sends mask 0 at the pointer and `_release_action_mods()`. Hold: flush, then a right click at the pointer (mask 4), released by `onHoldRelease` as today. Touch mode is unchanged and immediate.
  - `send_key` and `set_pointer_mode` call `_flush_deferred_click()` first. `onCloseWidget` calls `_drop_deferred_click()`.
- Test helpers added: `scheduled_delay(action) -> seconds|nil` (looks up `UIManager._task_queue`) and `run_scheduled(action)` (unschedules it and calls it).

- [ ] **Step 1: Write the failing tests** (`app, remote, sent = new_app(400, 300, { mode = "mouse" })`; positions from `app.canvas`; `wire_log(app)` for order):

```lua
check("mouse_drag_moves_the_pointer_relatively_with_speed", function()
    -- pan relative {x=40,y=0} from the remote centre (200,150): one event, mask 0,
    -- x == math.floor(200 + 40 / remote:get_scale() * 1.25 + 0.5), y == 150; no mask 1 anywhere
    -- settings.pointer_speed = "fast": the next 40px pan moves 40/scale*2.0
    -- a pan far beyond the edge clamps at x == 399
end)
check("mouse_tap_click_is_deferred_and_lands_at_the_pointer", function()
    -- after a tap: #sent.pointer == 0 and scheduled_delay(app._deferred_click_task) is within 0.05 of mouse_click_delay()
    -- run_scheduled(app._deferred_click_task): log == "p0,p1,p0", all three at the pointer, not at the finger
end)
check("mouse_double_tap_and_move_drags_from_the_pointer", function()
    -- tap at P, then pan starting at P (+10px) with relative {x=30,y=0}: log == "p1,p1" (no click before it)
    -- pan_release: "p0"; scheduled_delay(app._deferred_click_task) == nil
end)
check("mouse_tap_tap_is_two_clicks_at_the_pointer", function()
    -- two taps 5px apart: log == "p0,p1,p0,p0,p1,p0" straight away, nothing left scheduled
end)
check("mouse_long_press_right_clicks_at_the_pointer", function()
    -- hold at the finger far from the pointer: mask 4 at the pointer; hold_release: mask 0
end)
check("mouse_pending_click_is_settled_by_key_mode_switch_and_close", function()
    -- tap, then app:send_key(0x61,true): log == "p0,p1,p0,+0x61"
    -- tap, then set_pointer_mode("touch"): click sent before the switch, the task unscheduled
    -- tap, then app:onCloseWidget(): nothing sent, the task unscheduled, has_pointer_action() == false
end)
check("mouse_pointer_is_clamped_after_the_remote_shrinks", function()
    -- pointer moved to (390, 290); remote:resize(200, 100); app:on_remote_resized()
    -- the next 0-px pan or tap sends x <= 199, y <= 99
end)
check("touch_tap_stays_immediate", function()
    -- touch mode: a tap sends "p0,p1,p0" at once and schedules nothing
end)
```
Fill each body with `dispatch_gesture` calls and `assert_true` on the values in the comments. Each comment is the exact assertion.

- [ ] **Step 2: Run the UI suite and confirm it fails.** Expected: all mouse_* checks FAIL. `touch_tap_stays_immediate` passes.
- [ ] **Step 3: Implement** the interfaces above. The Touch branches keep today's code path verbatim, including `_press_armed`, `_release_action_mods` and the stale-action guards. The shrink test uses `remote:resize(200, 100)` then `app:on_remote_resized()`.
- [ ] **Step 4: Run all three suites and confirm they pass.**
- [ ] **Step 5: Commit.** `git add vnc/app.lua tools/ui_smoke.lua && git commit -m "feat(viewer): mouse mode with relative pointer, deferred click and double-tap drag"`

### Task 4: Display panel (zoom, scaling, orientation, pointer speed)

**Files:**
- Create: `vnc/displaypanel.lua`
- Modify: `vnc/menu.lua` (move `ZOOM_CHOICES` and `ROTATIONS` out; drop the Zoom…, Screen orientation, Rotate screen, Use current orientation as default and Sharp scaling entries), `vnc/app.lua`
- Test: `tools/ui_smoke.lua`

**Interfaces:**
- Produces:
  - `DisplayPanel.ZOOM_CHOICES` and `DisplayPanel.ROTATIONS`, with the same labels and values as today's `menu.lua`.
  - `DisplayPanel.open(app) -> ButtonDialog`, anchored under the toolbar (`anchor` = the toolbar's `dimen` when visible, else the top of the screen).
  - Rows: zoom choices (9 buttons over up to 3 rows); `Smooth` | `Sharp`; the 4 rotations, then `Use current orientation as default`; `Slow` | `Normal` | `Fast`.
  - The current choice's text is `"✓ " .. label`.
  - Zoom: `app:zoom_to(value)`, then flush. Scaling: set `settings.scaling`, `remote:set_scaling`, `app:_wholesale_change()`, flush. Pointer speed: set `settings.pointer_speed`, flush. These three re-open the panel in place so the checkmark follows.
  - A rotation calls `app:set_rotation_mode(mode)` and closes the panel. "Use current…" sets `settings.orientation`, flushes, and re-opens the panel.
  - `ViewerApp:open_display_panel()`, `close_display_panel()` and `toggle_display_panel()`; the handle is kept in `self.display_panel`. A tap outside it, Back, or the Display button closes it (`tap_close_callback` clears the handle and calls `_sync_keyboard_later`).

- [ ] **Step 1: Write the failing tests.** Rewrite `zoom_modes_follow_the_keyboard` (its labels now come from `app:open_display_panel()` buttons), `sharp_scaling_menu_entry_applies_live` → `display_panel_scaling_applies_live`, and `menu_orientation_choice_closes_menu` → `display_panel_orientation_choice_closes_it`. Add:

```lua
check("display_panel_marks_and_applies_choices", function()
    local app, remote = new_app()
    local panel = app:open_display_panel()
    find_button(panel, "✓ Fit screen")
    find_button(panel, "200%").callback()
    assert_true(app.settings.zoom_mode == 2 and app.display_panel ~= nil, "applied, panel still open")
    find_button(app.display_panel, "✓ 200%")
    find_button(app.display_panel, "Fast").callback()
    assert_true(app.settings.pointer_speed == "fast")
    find_button(app.display_panel, "✓ Fast")
    app:toggle_display_panel()
    assert_true(app.display_panel == nil and count(function(w) return w == panel end) == 0)
    close_viewer(app, remote)
end)
```

- [ ] **Step 2: Run the UI suite and confirm it fails.**
- [ ] **Step 3: Implement** the interfaces above. Delete the moved menu entries and the `viewer_menu` assertions that named them.
- [ ] **Step 4: Run all three suites and confirm they pass.**
- [ ] **Step 5: Commit.** `git add vnc/displaypanel.lua vnc/menu.lua vnc/app.lua tools/ui_smoke.lua && git commit -m "feat(viewer): display panel for zoom, scaling, orientation and pointer speed"`

### Task 5: Toolbar widget and top-swipe toggle

**Files:**
- Create: `vnc/toolbar.lua`
- Modify: `vnc/app.lua` (`init_menu_zones` → toolbar toggle, `paintTo`, `handleEvent` override, `onScreenResize`, `init`), `vnc/menu.lua` (drop Disconnect: it moves to ✕)
- Test: `tools/ui_smoke.lua`

**Interfaces:**
- Consumes: `open_key_panel()`, `toggle_keyboard()`, `rotate(1)`, `scroll_wheel(dir, 1)`, `toggle_display_panel()` (Task 4), `open_menu()`, `get_pointer_mode()`/`set_pointer_mode()` (Task 2), `settings.toolbar_scroll_buttons`.
- Produces:
  - `Toolbar:new{ app }`, an InputContainer that is not a window.
  - `Toolbar.IDS = { "close", "display", "mode", "keyboard", "rotate", "scroll_up", "scroll_down", "more" }`. `Toolbar:visible_ids()` drops the scroll ids unless the setting is on. `self.button_by_id[id]` holds the buttons.
  - `self.dimen`: centred horizontally at the top, rounded border (`Size.radius.window`), white background.
  - `Toolbar:relayout()` rebuilds for the screen size, the mode icon and the scroll setting.
  - Icons: `close.svg`, `appbar.pagefit.svg` (Display), `appbar.rotation.svg`, `move.up.svg`/`move.down.svg`, `appbar.menu.svg` (More). Mode and Keyboard use text glyphs that render in KOReader's UI font (check the dummy run shows no tofu; otherwise use `Touch`/`Mouse` and `Kbd`).
  - Callbacks:
    - close: `ConfirmBox` with the text `Disconnect from %1?`, `ok_text = "Disconnect"`, `ok_callback = app:disconnect_session()`. This is the flow moved from `menu.lua:272`.
    - display: `app:toggle_display_panel()`.
    - mode: `app:toggle_pointer_mode()`. In this task it only calls `set_pointer_mode` and `toolbar:relayout()`; Task 8 adds the cheat-sheet.
    - keyboard: tap `app:toggle_keyboard()`, `hold_callback` `app:open_key_panel()`.
    - rotate: `app:rotate(1)`.
    - scroll: `app:scroll_wheel(-1 or 1, 1)`.
    - more: `app:open_menu()`.
  - `ViewerApp:set_toolbar_visible(on)`, `ViewerApp:toggle_toolbar()` and `self.toolbar_visible`, true by default at init. Show and hide repaint only `toolbar.dimen` with `"ui"`.
  - `ViewerApp:onTopSwipe(ges)` replaces `onMenuSwipe`: a south swipe in the zones `init_menu_zones` registers toggles the toolbar; anything else returns nil. `toggle_menu` remains for the Menu key.
  - `ViewerApp:_toolbar_owns(ges) -> boolean` is false while `_drag_active` or `_hold_active`, false for `swipe` and every `two_finger_*` gesture, and otherwise true when the toolbar is visible and the gesture's start (`pos - (relative or 0)`) lies in `toolbar.dimen`. `ViewerApp:handleEvent` forwards owned gestures to the toolbar and returns true.
  - `paintTo` paints the toolbar after the canvas when visible.
- `new_app(…, opts)`: hide the toolbar unless `opts.toolbar` (existing checks tap near the top). Helpers: `tap_toolbar(app, id)` and `hold_toolbar(app, id)` force a repaint, then dispatch at the button centre. Change `open_key_panel(app)` to `hold_toolbar(app, "keyboard")`.

- [ ] **Step 1: Write the failing tests.** Rewrite `menu_opens_on_swipe_only` → `toolbar_toggles_on_top_swipe_only` (a south swipe in the top zone flips `toolbar_visible` both ways; north/east and lower swipes do nothing; no menu opens). Rewrite `viewer_menu_disconnect_returns_to_the_list` → `toolbar_close_confirms_then_returns_to_the_list`. In `canvas_covers_the_screen`, replace the `top_bar == nil` assertion with: the canvas covers the screen while `toolbar_visible`. Add:

```lua
check("toolbar_buttons_act_and_taps_never_reach_the_canvas", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    assert_true(app.toolbar_visible, "shown on open")
    tap_toolbar(app, "rotate");   -- rotation +1, then restore
    tap_toolbar(app, "keyboard"); assert_true(app.vk_wanted == true)
    hold_toolbar(app, "keyboard"); assert_true(app.key_panel ~= nil)
    tap_toolbar(app, "display");  assert_true(app.display_panel ~= nil)
    -- across all of the above: #sent.pointer == 0
    assert_true(app.toolbar.button_by_id.scroll_up == nil, "scroll buttons hidden by default")
    app.settings.toolbar_scroll_buttons = true; app.toolbar:relayout()
    tap_toolbar(app, "scroll_down") -- exactly one notch: masks 16,0
end)
check("toolbar_does_not_eat_a_canvas_drag_release", function()
    -- touch mode: pan starting mid-canvas, release positioned inside toolbar.dimen: log ends "p0", has_pointer_action() == false
    -- same for hold then hold_release over the toolbar: mask 4 then 0
end)
check("toolbar_recentres_after_rotation", function()
    -- rotate; toolbar.dimen.x == math.floor((Screen:getWidth() - toolbar.dimen.w) / 2) and dimen.y is unchanged
end)
check("toolbar_toggle_repaints_only_its_area", function()
    -- wrap UIManager.setDirty: toggling records a "ui" refresh whose region equals toolbar.dimen, and no "full"/"flashui"
end)
```

- [ ] **Step 2: Run the UI suite and confirm it fails.**
- [ ] **Step 3: Implement** the interfaces above. Remove `onMenuSwipe` and the swipe→menu path. The ⋯ button and the Menu key are now the only ways to the menu.
- [ ] **Step 4: Run all three suites and confirm they pass.**
- [ ] **Step 5: Commit.** `git add vnc/toolbar.lua vnc/app.lua vnc/menu.lua tools/ui_smoke.lua && git commit -m "feat(viewer): top toolbar toggled by a swipe down in the menu zone"`

### Task 6: ⋯ More popup content

**Files:**
- Modify: `vnc/menu.lua`, `vnc/app.lua`
- Test: `tools/ui_smoke.lua`

**Interfaces:**
- Consumes: `send_key`, `request_full_update` on the session, `settings.toolbar_scroll_buttons`, `toolbar:relayout()` (Task 5).
- Produces:
  - Menu order: status line (not selectable, first), the existing `Reconnect to %1` (in the error state only), `Connections…`, `Send text…`, `Refresh`, `Ctrl+Alt+Del`, `Lock screen`, `Page buttons send`, `Keyboard always visible`, `Show scroll buttons on toolbar` (stays open, ✓/-, relayouts the toolbar), `Leave (keep connection)`. No Show/Hide keyboard, Send keys… or Disconnect entry.
  - `ViewerApp:send_text(text) -> skipped: integer`: one down/up per character via `Keysyms.from_char`, so `"\n"` becomes Return; characters with no keysym are skipped and counted.
  - `Send text…` opens an `InputDialog` (title `Send text`, buttons Cancel / `Send`). On Send it closes, calls `send_text`, and shows `Notification` `T("%1 character(s) skipped", n)` when `n > 0`. Afterwards it calls `reassert_text_input` and `_sync_keyboard_later`.
  - `ViewerApp:refresh_remote()` calls `session:request_full_update()` and `UIManager:setDirty(self, "full")`.
  - `ViewerApp:send_combo(keysyms: {number,...})`: downs in order, ups in reverse. `Ctrl+Alt+Del` sends `{Control_L, Alt_L, Delete}`; `Lock screen` sends `{Super_L, 0x6C}`.

- [ ] **Step 1: Write the failing tests.** Update `menu_keyboard_items_work`, `menu_stays_open_on_toggles_and_closes_with_its_close_button` and `every_menu_close_path_repaints_the_viewer_after_a_toggle` to use `Keyboard always visible` or `Show scroll buttons on toolbar` wherever they used a removed entry. Add:

```lua
check("more_menu_order_and_actions", function()
    local app, remote, sent = new_app()
    local log = wire_log(app)
    local menu = app:open_menu()
    assert_true(menu.item_table[1].select_enabled == false and menu.item_table[1].text:find("^Connected to test"))
    for _, t in ipairs{ "Send keys…", "Disconnect", "Show keyboard", "Hide keyboard", "Zoom…" } do
        for _, item in ipairs(menu.item_table) do assert_true(item.text ~= t, t .. " moved out") end
    end
    app:close_menu()
    assert_true(app:send_text("a\nb\1") == 1)
    assert_true(log() == "+0x61,-0x61,+0xFF0D,-0xFF0D,+0x62,-0x62")
    app:send_combo{ 0xFFE3, 0xFFE9, 0xFFFF }
    assert_true(log() == "+0xFFE3,+0xFFE9,+0xFFFF,-0xFFFF,-0xFFE9,-0xFFE3")
    -- Lock screen entry: "+0xFFEB,+0x6C,-0x6C,-0xFFEB"; Refresh entry: request_full_update called once and a "full" setDirty on app
    close_viewer(app, remote)
end)
```
(Add `request_full_update` to the fake session in `new_app`, counting its calls in `sent.full_updates`.)

- [ ] **Step 2: Run the UI suite and confirm it fails.**
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run all three suites and confirm they pass.**
- [ ] **Step 5: Commit.** `git add vnc/menu.lua vnc/app.lua tools/ui_smoke.lua && git commit -m "feat(viewer): more popup with send text, refresh and key combos"`

### Task 7: Key strip with the on-screen keyboard

**Files:**
- Modify: `vnc/keypanel.lua` (strip variant), `vnc/keyboard.lua` (`Keyboard.new` press hook), `vnc/app.lua` (`_is_overlay`, `_press_armed`, `evaluate_keyboard`, `_bottom_cover_height`, `on_keyboard_height_changed`, `open_key_panel`, `toggle_keyboard`, `onCloseWidget`, `onScreenResize`)
- Test: `tools/ui_smoke.lua`

**Interfaces:**
- Produces:
  - `KeyPanel:new{ app, variant = "strip", bottom_offset = px }`: one row of height `KeyPanel.row_height()`, no title bar. It reuses `_modifier_row` buttons (`mod:<name>`, without the combo button) and adds `KeyPanel.STRIP_KEYS = { {"Esc",X.Escape}, {"Tab",X.Tab}, {"←",X.Left}, {"↑",X.Up}, {"↓",X.Down}, {"→",X.Right}, {"Del",X.Delete} }` with ids `key:<label>`.
  - `self.dimen.y = screen.h - bottom_offset - h`. `KeyPanel:set_bottom_offset(px)` relayouts.
  - Strip keys and taps use the same `send_key`/`take_armed` as the panel.
  - `Keyboard.new(session, on_height_changed, press)`: optional `press(keysym)` replaces the stub's direct down/up.
  - `ViewerApp:send_osk_key(keysym)`: when the strip has armed modifiers, `key_strip:send_key(Keysyms.name_for_keysym(keysym) or "", keysym)`; else a plain down/up through `send_key`.
  - `self.key_strip` is shown exactly while `vk_visible`; it shows and hides inside `evaluate_keyboard`.
  - `_armed_source()` returns `key_strip or key_panel`, and `_press_armed` uses it.
  - `_bottom_cover_height()` is `vk_h + strip_h` while the strip is up.
  - Opening the panel hides the keyboard and strip (existing rule). `toggle_keyboard()` closes an open panel first. Never both at once.

- [ ] **Step 1: Write the failing tests**

```lua
check("key_strip_comes_and_goes_with_the_keyboard", function()
    -- tap_toolbar(app,"keyboard"): app.key_strip ~= nil, strip.dimen.y + strip.dimen.h == Screen:getHeight() - app.vk:getSize().h
    -- tap again: vk and strip both gone
end)
check("key_strip_modifiers_apply_to_osk_strip_and_canvas", function()
    -- arm Ctrl on the strip, app.vk.inputbox:addChars("c"): log == "+0xFFE3,+0x63,-0x63,-0xFFE3"
    -- arm Shift, touch(strip,"key:Tab"): "+0xFFE1,+0xFF09,-0xFF09,-0xFFE1"
    -- arm Alt, canvas tap: "+0xFFE9,p0,p1,p0,-0xFFE9"
end)
check("key_strip_and_panel_are_exclusive", function()
    -- strip up; hold_toolbar(app,"keyboard"): key_panel ~= nil and key_strip == nil
    -- tap_toolbar(app,"keyboard"): key_panel == nil and key_strip ~= nil
end)
check("fit_with_keyboard_accounts_for_the_strip", function()
    -- zoom_mode "fit_with_keyboard", strip up: remote.ch == Screen:getHeight() - vk_h - strip.dimen.h
end)
check("key_strip_follows_rotation_and_layout_height", function()
    -- rotate with the strip up: strip.dimen.w == new width and its bottom == new height - vk_h
    -- app:on_keyboard_height_changed() after a vk height change: the strip moves to stay on top of the keyboard
end)
```

- [ ] **Step 2: Run the UI suite and confirm it fails.**
- [ ] **Step 3: Implement** the interfaces above. The full panel keeps its behaviour, and every existing `key_panel_*` check stays green unchanged.
- [ ] **Step 4: Run all three suites and confirm they pass.**
- [ ] **Step 5: Commit.** `git add vnc/keypanel.lua vnc/keyboard.lua vnc/app.lua tools/ui_smoke.lua && git commit -m "feat(viewer): key strip above the on-screen keyboard"`

### Task 8: Gesture cheat-sheet on mode switch

**Files:**
- Create: `vnc/cheatsheet.lua`
- Modify: `vnc/app.lua` (`toggle_pointer_mode`)
- Test: `tools/ui_smoke.lua`

**Interfaces:**
- Consumes: `set_pointer_mode` (Task 2), the toolbar `mode` button (Task 5).
- Produces:
  - `CheatSheet.ROWS.touch` and `CheatSheet.ROWS.mouse`: `{ gesture, action }` string pairs taken from the spec table (§4).
    - Touch: `Tap`/`Left click at the finger`, `Long press`/`Right click at the finger`, `Drag`/`Drag with the left button`.
    - Mouse: `Tap`/`Left click at the pointer`, `Long press`/`Right click at the pointer`, `Drag`/`Move the pointer`, `Double tap and drag`/`Drag with the left button`.
    - Both modes also get `Two-finger drag`/`Move the picture`, `Pinch / spread`/`Zoom`, `Two-finger tap`/`Fit to screen` and `Page buttons`/`Page Up/Down or wheel`.
  - `CheatSheet:new{ mode, on_close }`: a centred framed card with the title `Touch mode` or `Mouse mode`. It is not a viewer overlay, so `_input_target()` is false while it is up. A `tap` anywhere closes it, with `"ui"` refresh of its area, and is consumed.
  - `ViewerApp:toggle_pointer_mode()` flips the mode, relayouts the toolbar, and shows the sheet in `self.cheat_sheet`.

- [ ] **Step 1: Write the failing test**

```lua
check("mode_switch_shows_the_cheat_sheet_and_its_tap_is_local", function()
    local app, remote, sent = new_app(400, 300, { toolbar = true })
    tap_toolbar(app, "mode")
    assert_true(app:get_pointer_mode() == "mouse" and top() == app.cheat_sheet)
    assert_true(app.cheat_sheet.rows == require("vnc/cheatsheet").ROWS.mouse)
    sent.pointer = {}
    dispatch_gesture{ ges = "tap", pos = Geom:new{ x = 10, y = Screen:getHeight() - 10 } }
    assert_true(app.cheat_sheet == nil and #sent.pointer == 0, "dismissed, nothing sent")
    close_viewer(app, remote)
end)
```

- [ ] **Step 2: Run the UI suite and confirm it fails.**
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run all three suites and confirm they pass.**
- [ ] **Step 5: Commit.** `git add vnc/cheatsheet.lua vnc/app.lua tools/ui_smoke.lua && git commit -m "feat(viewer): gesture cheat-sheet on mode switch"`

### Task 9: Session retry mode that keeps Wi-Fi on

**Files:**
- Modify: `vnc/session.lua` (`connect:185-213`, `_fail:682`, new methods near `disconnect`)
- Test: `tools/ui_smoke.lua` (next to `wifi_is_turned_off_by_the_last_connection_only`)

**Interfaces:**
- Produces:
  - `Session:set_keep_wifi(on: boolean)`. Turning it off while `state` is `"error"` or `"disconnected"` runs `_restore_wifi()`, so the last connection still turns Wi-Fi off. Turning it off while connecting or connected changes nothing else.
  - While `keep_wifi`: `_fail` skips `_restore_wifi`, and `connect` keeps `wifi_was_on == false` (the duty) even though Wi-Fi is on now.
  - `Session:hangup()` runs `_teardown_connection()`, keeps the plane, restores Wi-Fi unless `keep_wifi`, then `_set_state("disconnected")`.

- [ ] **Step 1: Write the failing test** (real `Session`, closed port 1, fake net):

```lua
check("retry_mode_keeps_wifi_on_until_the_loop_ends", function()
    local Session = require("vnc/session")
    local offs, ons = 0, 0
    local net = { isWifiOn = function() return true end, turnOffWifi = function() offs = offs + 1 end,
                  turnOnWifiAndWaitForConnection = function() ons = ons + 1 end }
    local s = Session.new{ profile = { name = "r", host = "127.0.0.1", port = 1 }, plugin = { sessions = {} } }
    s._net = function() return net end
    s.wifi_was_on = false; s:set_keep_wifi(true)
    local results = {}
    s:connect(function(ok) results[#results + 1] = ok end)
    assert_true(results[1] == false and s:get_state() == "error")
    assert_true(offs == 0 and s.wifi_was_on == false, "failure keeps Wi-Fi and the duty")
    s:connect(function(ok) results[#results + 1] = ok end)
    assert_true(offs == 0 and s.wifi_was_on == false)
    s:set_keep_wifi(false)
    assert_true(offs == 1 and s.wifi_was_on == nil, "the loop ending restores it once")
    s.wifi_was_on = false; s:set_keep_wifi(true); s:hangup()
    assert_true(offs == 1 and s:get_state() == "disconnected")
end)
```

- [ ] **Step 2: Run the UI suite and confirm it fails.**
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run all three suites and confirm they pass** (proto exercises `Session`).
- [ ] **Step 5: Commit.** `git add vnc/session.lua tools/ui_smoke.lua && git commit -m "feat(session): retry mode keeping Wi-Fi on, and hangup"`

### Task 10: Reconnect controller and box in the viewer

**Files:**
- Create: `vnc/reconnect.lua`
- Modify: `vnc/app.lua` (`on_session_error:807`, `onShow`, new `onResume`, `onCloseWidget`), `main.lua` (`show:249`, `_open_app:299`)
- Test: `tools/ui_smoke.lua` (the fake session in `new_app` gains `connect(cb)`, which records `cb` in `sent.connects`; `attach`, which counts `sent.attaches`; `set_keep_wifi`, which records `sent.keep_wifi`; and `hangup`. Its `get_state` reads a mutable `state` field.)

**Interfaces:**
- Consumes: `Session:set_keep_wifi`, `Session:connect`, `Session:attach`, `Session:hangup` (Task 9).
- Produces:
  - `Reconnect.BACKOFF = { 2, 4, 8, 15, 30 }` and `Reconnect.delay_for(n) -> BACKOFF[math.min(n, #BACKOFF)]`.
  - `Reconnect.new(app) -> r`, kept in `app.reconnect`.
  - `r:start{ auto: boolean, immediate: boolean, message: "lost"|"reconnecting", on_success: fn|nil, on_stop: fn|nil }` opens the box. `immediate` runs attempt 1 now; `auto` without `immediate` schedules attempt 1 after `delay_for(1)`; manual mode schedules nothing.
  - `r:retry_now()` cancels the timer, runs the next attempt now and switches to auto.
  - `r:close()` runs `stop()`, then `app:disconnect_session()` without a confirmation.
  - `r:stop()` unschedules, closes the box, calls `session:set_keep_wifi(false)` and `on_stop`. It is idempotent.
  - `r:is_running() -> boolean` is true while the box is up.
  - Fields: `r.attempt` and `r._retry_task`.
  - An attempt does `attempt += 1`, then `session:set_keep_wifi(true)` and `session:connect(cb)`. Success: unschedule, close the box, `set_keep_wifi(false)`, `session:attach(app)` (which requests the full update), `app:_wholesale_change()`, then `on_success`. Failure: schedule the next attempt after `delay_for(attempt + 1)`. A callback that arrives after `stop()` is ignored.
  - Box: `ButtonDialog`, `dismissable = false`, title updated with `setTitle` once per state change (no per-second countdown repaint). Exact copy:
    - auto, waiting: `Connection lost — reconnecting… (attempt %1, next in %2 s)`, buttons `Retry now` / `Close`.
    - attempt in flight: `Connection lost — reconnecting… (attempt %1)`.
    - manual: `Connection lost`, buttons `Retry` / `Close`.
    - preset (`message = "reconnecting"`): `Reconnecting…`.
  - The box's Back (`onClose`) calls `r:close()`.
  - `ViewerApp:on_session_error(err)`: when `reconnect:is_running()`, a no-op; otherwise `_end_pointer_action()`, `_drop_deferred_click()`, the key strip/panel disarm, then `start{ auto = true }`.
  - `onShow`: when the session state is `"error"` and no loop is running, `start{ auto = false }`.
  - `ViewerApp:onResume()`: when the box is up and the state is `"error"` or `"disconnected"`, `retry_now()`. It returns nil so others still see Resume.
  - `onCloseWidget` calls `reconnect:stop()`.
  - `VNC:show()` with exactly one session whose state is `"error"` calls `_open_app(session)`.
  - `_open_app` calls `session:attach(app)` only when the session is connected. A background drop with no viewer keeps today's toast in `on_session_state`.

- [ ] **Step 1: Write the failing tests**

```lua
check("reconnect_backoff_and_success", function()
    -- app.session.state = "error"; app:on_session_error("x")
    -- box title == "Connection lost — reconnecting… (attempt 1, next in 2 s)"; scheduled_delay(r._retry_task) ≈ 2
    -- run_scheduled → #sent.connects == 1, keep_wifi true; fail it (cb(false)) → next delay 4; then 8, 15, 30, 30
    -- run again, cb(true): box closed, r:is_running() == false, sent.attaches == 1, last keep_wifi == false
    -- a second on_session_error while running starts no second loop (one scheduled task, one box)
end)
check("reconnect_close_and_back_disconnect_without_confirm", function()
    -- running loop; Back key event to the box → plugin.disconnect_session called, task unscheduled, keep_wifi false
end)
check("reopening_on_an_error_session_waits_for_retry", function()
    -- new_app with session.state "error", then app:onShow(): box title "Connection lost", buttons Retry/Close,
    -- scheduled_delay(r._retry_task) == nil; tapping Retry → one connect now and auto mode afterwards
end)
check("resume_retries_at_once_and_leaving_stops_the_loop", function()
    -- running loop waiting 8 s; app:onResume() → a connect now, the timer cancelled
    -- app:onCloseWidget() → no task left in UIManager._task_queue for r._retry_task, keep_wifi false
end)
check("a_drop_mid_drag_ends_it_and_reconnect_sends_nothing_stale", function()
    -- strip Ctrl armed + touch drag in progress; on_session_error: has_pointer_action() == false and nothing armed
    -- after a successful reconnect: log() == "" until the next user gesture
end)
check("show_opens_the_viewer_on_a_single_errored_session", function()
    -- plugin with one session whose state is "error" (and get_remote()): plugin:show() → plugin.app ~= nil,
    -- the session's attach not called; a connected-only path is unchanged
end)
```

- [ ] **Step 2: Run the UI suite and confirm it fails.**
- [ ] **Step 3: Implement** the interfaces above. Delete the `InfoMessage` toast in `on_session_error`.
- [ ] **Step 4: Run all three suites and confirm they pass.**
- [ ] **Step 5: Commit.** `git add vnc/reconnect.lua vnc/app.lua main.lua tools/ui_smoke.lua && git commit -m "feat(viewer): reconnect box with backoff, resume retry and manual retry on reopen"`

### Task 11: Quality presets in the Display panel

**Files:**
- Modify: `vnc/settings.lua`, `vnc/displaypanel.lua`, `vnc/app.lua`
- Test: `tools/ui_smoke.lua`

**Interfaces:**
- Consumes: `Reconnect:start` (Task 10), `Session:hangup`/`set_keep_wifi` (Task 9), `VNC:update_profile_fields` (Task 2).
- Produces:
  - `Settings.QUALITY_PRESETS`, in this order:
    - `{ id = "best", label = "Best", color_depth = 24, enable_tight = false, jpeg_quality = false, compress_level = false }`
    - `{ id = "balanced", label = "Balanced", color_depth = 16, enable_tight = true, jpeg_quality = 6, compress_level = 6 }`
    - `{ id = "fast", label = "Fast", color_depth = 8, enable_tight = true, jpeg_quality = 3, compress_level = 9 }`
  - `Settings.preset_of(profile) -> id|"custom"` (an exact match on the four fields).
  - The Display panel gets the row `Best | Balanced | Fast`, with `✓` on the current preset taken from the stored profile, plus a disabled `✓ Custom` when no preset matches.
  - `ViewerApp:apply_quality_preset(id)`:
    1. The current preset, or a running loop, means no-op.
    2. Close the panel.
    3. `session:set_keep_wifi(true)`, then `session:hangup()`.
    4. `session:set_profile(candidate)`, where candidate = a copy of the stored profile plus the preset fields.
    5. `reconnect:start{ immediate = true, auto = true, message = "reconnecting", on_success = save, on_stop = restore }`. `save` = `plugin:update_profile_fields(name, preset fields)`. `restore` (stop without success) = `session:set_profile(plugin.settings:get_profile(name))`.

- [ ] **Step 1: Write the failing tests**

```lua
check("quality_presets_map_and_match", function()
    -- preset_of(best fields) == "best"; preset_of{ color_depth=16, enable_tight=true, jpeg_quality=5, compress_level=6 } == "custom"
end)
check("quality_preset_saves_only_after_a_successful_reconnect", function()
    -- profile = Best; find_button(display panel, "Fast").callback()
    -- hangup called, box title "Reconnecting…", one connect now, session profile color_depth == 8, sent.profile_updates empty
    -- cb(false) then r:close(): profile_updates still empty and the session profile is back to 24-bit
    -- again Fast, cb(true): profile_updates[1].fields == the Fast values
end)
check("same_quality_preset_does_nothing", function()
    -- tapping "✓ Best" while Best: no hangup, no connect, no box
end)
```

- [ ] **Step 2: Run the UI suite and confirm it fails.**
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run all three suites and confirm they pass.**
- [ ] **Step 5: Commit.** `git add vnc/settings.lua vnc/displaypanel.lua vnc/app.lua tools/ui_smoke.lua && git commit -m "feat(viewer): quality presets that reconnect and save after success"`

### Task 12: README and NOTES for the new UX

**Files:**
- Modify: `README.md` ("Using it" section and "Settings"), `NOTES.txt` ("CODE STRUCTURE", "DESIGN NOTES WORTH KNOWING", "TESTS")

**Interfaces:**
- Consumes: the final names and values from Tasks 1–11.

- [ ] **Step 1: Write the check.** `grep -n` the two files for the stale UX: the swipe that opened the menu, the swipe-up keyboard, the two-finger flick scroll, the rotate gesture and `Send keys…` in the menu. List the hits.
- [ ] **Step 2: Run it and confirm hits exist** (expected: hits in README "Using it" and NOTES).
- [ ] **Step 3: Rewrite those passages and add the new ones:**
  - README: the toolbar (buttons and the show/hide swipe), the gesture table for both modes (spec §4), the key strip with a long press on ⌨ for the full panel, the ⋯ contents, the Display panel, the quality preset values from Task 11 and the pointer speeds 0.75/1.25/2.0, and the reconnect behaviour (backoff 2, 4, 8, 15, then every 30 s; Wi-Fi kept on while retrying; no background retry; Retry/Close on reopen).
  - NOTES: the new modules (`toolbar`, `displaypanel`, `cheatsheet`, `reconnect`), the toolbar-is-a-child design, the deferred click, the keep-Wi-Fi retry mode, and the fact that the ui suite needs a fresh `KO_HOME`.
  - Constraint 1 applies to every line added.
- [ ] **Step 4: Re-run the grep and confirm the stale descriptions are gone. Then run all three suites and confirm they pass.**
- [ ] **Step 5: Commit.** `git add README.md NOTES.txt && git commit -m "docs: toolbar, pointer modes, gestures and reconnect"`

---

## Self-review (done at plan time)

1. Spec coverage:
   - §1 toolbar: Task 5, with the cheat-sheet in Task 8.
   - §1.6 removals: Tasks 1 and 5.
   - §2 Display: Task 4, plus presets in Task 11.
   - §3 More: Task 6. Benchmark/debug entries: none exist in today's `menu.lua`.
   - §4 modes: Tasks 2 and 3; two-finger tap in Task 1; cheat-sheet in Task 8.
   - §5 strip: Task 7.
   - §6 reconnect: Tasks 9, 10 and 11.
   - Constraints: README/NOTES in Task 12; suites in every task.
2. Types: `update_profile_fields`, `get/set_pointer_mode`, `toggle_pointer_mode`, `toggle_display_panel`, `_flush_deferred_click`/`_drop_deferred_click`, `set_keep_wifi`/`hangup`, `Reconnect:start/stop/close/retry_now/is_running` are used with the same names in every task.
3. Existing checks touched by the removals are named in the task that breaks them (Tasks 1, 4, 5, 6).
