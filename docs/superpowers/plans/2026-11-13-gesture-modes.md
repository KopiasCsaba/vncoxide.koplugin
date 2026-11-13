# Gesture Modes (Touch, Mouse, Hybrid) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove scroll lock, unify long press across modes, make Mouse-mode taps instant and its view follow the pointer like RustDesk, and add a Hybrid mode where one-finger drag scrolls.

**Architecture:** All changes live in the viewer's gesture layer (`vnc/app.lua`) plus the toolbar, settings, menu, help and docs. The RustDesk follow rule is a pure per-axis function in a new module so it can be unit-tested. Long press keeps the existing false-hold machinery (`HOLD_CONFIRM`, `_false_hold`) and only changes what a confirmed hold does: the right button is no longer pressed at confirmation; a move turns it into a left-button drag, a lift without a move sends the right click.

**Tech Stack:** Lua / LuaJIT inside KOReader (GestureDetector events: tap, pan, pan_release, swipe, hold, hold_pan, hold_release, two_finger_*).

**Spec:** `docs/superpowers/specs/2026-11-13-gesture-modes-design.md` (read it first; its behaviour table is binding).

## Global Constraints

- Pure Lua, no build step. No change to `vnc/server.lua`, `vnc/rfbserver.lua`, `vnc/serverenc.lua`, `vnc/servermenu.lua`, worker mode (`vnc/workers.lua`, `vnc/worker.lua`) or the key panel's behaviour.
- No tap in any mode may get slower than today; Touch-mode taps stay exactly as they are.
- The existing false-hold handling (InkView's burst: `HOLD_CONFIRM`, `FALSE_HOLD_FOLLOW`, `_false_hold_followed_by`) and the release watch (`_watch_release`) keep working for every new path.
- Armed modifiers (key panel one-shots) go with clicks and drags exactly as today (`_press_armed` / `_release_action_mods`).
- After every task: `P=<worktree> SUF=<suffix> ../tmp/run-tests.sh all` exits 0; at the end `../tmp/arm/run.sh proto ui server40`.
- Commit messages plain, repo style (`Area: what changed`); no assistant names, no Co-Authored-By, no signatures. Never `git stash`.

## Review Focus

1. A long press whose finger drifts a few pixels (e-ink panels are noisy) must still be a right click, not a 1-px drag. Test: `long_press_with_jitter_is_a_right_click` (Task 2) — movement below GestureDetector's pan threshold never emits hold_pan; assert the right click.
2. A long press then drag whose lift is eaten by a popup must not leave the left button down. Test: `long_press_drag_released_under_a_popup` (Task 2), via the existing release watch.
3. Mouse mode zoomed in, pointer dragged hard against a remote corner, then back: no jump, no drift of the view past the remote edges. Test: `follow_corner_and_back` (Task 4).
4. A stored profile/settings file that still names `scroll_lock` (toolbar buttons, pinned) or an unknown `pointer_mode` loads cleanly. Test: `stale_scroll_lock_settings_load` (Task 1), `unknown_pointer_mode_is_touch` (Task 5).
5. Hybrid: a drag that starts on the toolbar or under a popup never scrolls the remote (the same ownership rules as today's drags). Test: `hybrid_drag_on_toolbar_does_not_scroll` (Task 5).

---

### Task 1: Remove scroll lock; two-finger drag always pans

**Files:** Modify `vnc/app.lua` (`scroll_lock` field `:89`, `toggle_scroll_lock` `:1742`, the scroll branch of `onTwoFingerPan` `:1715`, the flick handling under scroll lock near `:1805`, `_two_finger_pan.scrolled`), `vnc/toolbar.lua` (`IDS`, `TIPS`, `specs` `:135`), `vnc/settings.lua` (`TOOLBAR_BUTTONS` `:74`, `TOOLBAR_PINNABLE` `:80`, `TOOLBAR_PINNED` `:84` → `{ keyboard = true }`), `vnc/menu.lua` (`:308`, `:330` rows), `vnc/help.lua` (COMMON row, toolbar line `:72`, SCROLL LOCK section `:88`), `README.md` (scroll lock text and the toolbar list). Keep `_scroll_by_drag` and `_wheel_position` — Task 5 reuses them. Test `tools/ui_smoke.lua`.

- [ ] **Step 1: Failing tests:**
  - `two_finger_drag_always_pans`: zoomed-in viewer; a two-finger pan moves the view (`remote:get_view()`/view_x changes) and sends no PointerEvent with wheel buttons (8/16/32/64).
  - `no_scroll_lock_button`: `Toolbar.IDS`, `Settings.TOOLBAR_PINNABLE`, `Settings.TOOLBAR_BUTTONS` have no `scroll_lock`; `Settings.TOOLBAR_PINNED` is `{ keyboard = true }`; the "Toolbar buttons…" menu has no Scroll lock row.
  - `stale_scroll_lock_settings_load`: a settings file with `toolbar_buttons = { scroll_lock = true }` and `toolbar_pinned = { scroll_lock = true, keyboard = true }` loads; the viewer opens; `scroll_lock` is absent from both tables after normalisation.
  - Delete/replace the existing scroll-lock tests (list them in the commit body).
- [ ] **Step 2:** `../tmp/run-tests.sh ui` — FAIL.
- [ ] **Step 3:** Implement; settings normalisation drops unknown toolbar ids (check how `toolbar_buttons`/`toolbar_pinned` checks work at `vnc/settings.lua:172` and extend them).
- [ ] **Step 4:** `../tmp/run-tests.sh all` passes.
- [ ] **Step 5: Commit** `Viewer: scroll lock removed; a two-finger drag always moves the picture`.

### Task 2: One long-press rule for Touch and Mouse mode

A confirmed long press no longer presses the right button. It waits: a `hold_pan` (movement past GestureDetector's pan threshold) turns it into a left-button drag; a `hold_release` without one sends the right click (press + release) there and then.

**Files:** Modify `vnc/app.lua` (`_hold_act` `:1046`, `onHoldPan` `:1097`, `onHoldRelease` `:1262`, `_end_pointer_action` / `_end_stale_pointer_action` / two-finger interruption `:1131-1190` where they release a held right button). Test `tools/ui_smoke.lua`.

**Interfaces (produced):** `self._hold_active` values: `"touch_wait"` / `"mouse_wait"` (confirmed, nothing sent yet), `"touch_drag"` (left button down at the finger, moves follow the finger absolutely), `"mouse_drag"` (left button down at the pointer, moves are relative via `_mouse_move(rel, 1)`, as today's tap-then-hold drag). Task 4 adds following to `_mouse_move`; Task 5 makes Hybrid use the `touch_*` values.

- [ ] **Step 1: Failing tests** (Touch and Mouse each, through the real widget stack like the existing hold tests):
  - `long_press_lift_is_a_right_click` (both modes): hold, confirm, lift without moving → exactly `button 4 down` then `up` at the lift, at the finger (Touch) / pointer (Mouse); nothing sent before the lift.
  - `long_press_with_jitter_is_a_right_click`: movement under the pan threshold → still the right click.
  - `long_press_then_drag_is_a_left_drag` (both modes): hold, confirm, hold_pan, hold_pan, lift → `button 1 down` at the press point (Touch: finger; Mouse: pointer), moves with button 1 (Touch: to the finger; Mouse: relative), `up` at the end; no button 4 anywhere.
  - `long_press_drag_released_under_a_popup`: the lift goes to a popup → the release watch lets go of button 1.
  - `long_press_takes_armed_modifiers`: an armed Shift goes with the right click and with the drag, and is released after.
  - Update the existing hold tests that expect button 4 pressed at confirmation (list them in the commit body).
- [ ] **Step 2:** `../tmp/run-tests.sh ui` — FAIL.
- [ ] **Step 3:** Implement. Keep every false-hold path working (`_hold_pending`, `_false_hold`, the two-finger endings).
- [ ] **Step 4:** `../tmp/run-tests.sh all` passes.
- [ ] **Step 5: Commit** `Viewer: a long press is a right click at the lift, or a left-button drag when the finger moves (Touch and Mouse)`.

### Task 3: Mouse-mode taps are instant

Remove the deferred click (tap waits out the double-tap interval) and both tap-then-drag and tap-then-hold.

**Files:** Modify `vnc/app.lua` (`_mouse_tap` `:1526`, `_mouse_pan` `:1546` near-tap branch, `_hold_act`'s `near_tap` branch, `onHold`'s `near_tap`, `_flush_deferred_click` / `_drop_deferred_click` / `_near_deferred_click` and their callers — toolbar callback `vnc/toolbar.lua` `app:_flush_deferred_click()`, key panel flush via `app:send_key`, `_deferred_click` modifier snapshot), `vnc/help.lua` (Mouse rows), `README.md` (the Mouse-mode paragraph about the deferred click). Test `tools/ui_smoke.lua`.

- [ ] **Step 1: Failing tests:**
  - `mouse_tap_clicks_at_once`: a Mouse-mode tap sends move/press/release at the pointer during the tap's own event handling (no scheduled task needed).
  - `mouse_double_tap_is_two_clicks`: two quick taps → two press/release pairs at the pointer.
  - `mouse_tap_then_drag_moves_the_pointer`: tap, then a drag starting near it → no button 1, the pointer moves.
  - Remove/replace the deferred-click tests (list them in the commit body), including the modifier-snapshot test from the earlier review fix — the armed modifiers now go with the instant click.
- [ ] **Step 2:** `../tmp/run-tests.sh ui` — FAIL.
- [ ] **Step 3:** Implement; delete the deferred-click code paths entirely (no dead code).
- [ ] **Step 4:** `../tmp/run-tests.sh all` passes.
- [ ] **Step 5: Commit** `Mouse mode: taps click at once (tap-then-drag replaced by long press then drag)`.

### Task 4: Mouse mode follows the pointer (RustDesk's rule)

**Files:** Create `vnc/pointerfollow.lua`. Modify `vnc/app.lua` (`_mouse_move` `:1580`, `_mouse_pan` start, the refresh during/after a pointer move), `vnc/framebuffer.lua` only if a view setter is missing (`Remote:set_view(scale, x, y)` exists `:269`; `visible_remote_rect`). Test `tools/ui_smoke.lua`.

**Interfaces (produced):** `PointerFollow.axis(cur, d, view_lo, view_hi, remote_lo, remote_hi) -> new_cur, view_shift` — one axis, all in remote px: `view_lo/hi` the visible span, `remote_lo/hi` the remote screen span (`0`, `w`). Algorithm (from rustdesk `CursorModel.updatePan`):

```
c = (view_lo + view_hi) / 2
if d > 0 then room = remote_hi - view_hi; follow = cur + d > c and room > 0; d = min(d, follow and room or (view_hi - 1 - cur))
elseif d < 0 then room = remote_lo - view_lo; follow = cur + d < c and room < 0; d = max(d, follow and room or (view_lo - cur)) end
new = clamp(cur + d, remote_lo, remote_hi - 1)
view_shift = follow and (new - cur) or 0
```

(When following, the pointer is clamped to the view plus the room the view may still move; the implementer verifies the RustDesk detail in `tmp/rustdesk-notes.md` and matches it, noting any deliberate deviation.) `ViewerApp:_mouse_move(rel, mask)` applies `PointerFollow.axis` per axis with `d = delta * pointer_speed / scale`, moves the view by `view_shift` (both axes in one `set_view`), then sends the pointer. A Mouse-mode drag (or long-press drag) that starts with the pointer outside `visible_remote_rect()` first moves the pointer to the view's centre (one PointerEvent). View changes during the drag paint with `"fast"` and the drag's end settles with `"ui"`, via the existing `_view_move` / `_view_settled`.

- [ ] **Step 1: Failing tests:**
  - `pointer_follow_axis_rules` (pure): from the centre moving + with room → pointer and view move together; at the far edge (room 0) → only the pointer moves, clamped to `remote_hi - 1`; from beside the centre moving back → pointer alone until the centre, then together; the mirrored cases for −; `d = 0` → nothing.
  - `follow_keeps_the_pointer_centred`: zoomed 2×, pointer at the view centre, drag right 200 px → view_x grew, the pointer's screen position is the view centre (±1 px).
  - `follow_corner_and_back`: drag hard to the bottom-right corner → view at the remote's bottom-right limit, pointer at `(w-1, h-1)`; drag back up-left → pointer returns to the centre before the view moves; the view never goes outside the remote.
  - `drag_starts_with_offscreen_pointer_at_centre`: pointer outside the visible area, start a drag → first PointerEvent is at the view centre.
  - `two_finger_pan_keeps_the_pointer`: Mouse mode, a two-finger pan moves the view, `_mouse_pointer()` unchanged, no PointerEvent sent.
  - `fit_view_does_not_follow`: at fit (nothing to pan) a drag moves only the pointer.
- [ ] **Step 2:** `../tmp/run-tests.sh ui` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `../tmp/run-tests.sh all` passes.
- [ ] **Step 5: Commit** `Mouse mode: the view follows the pointer when zoomed in (RustDesk's rule)`.

### Task 5: Hybrid mode

**Files:** Modify `vnc/app.lua` (`get_pointer_mode` `:1319`, `set_pointer_mode`, `toggle_pointer_mode` `:1337` → cycle touch → mouse → hybrid with toasts `_("Touch mode")`, `_("Mouse mode")`, `_("Hybrid mode")`; `onTap` Hybrid = Touch's tap; `onPan`/`onPanRelease`/`onSwipe` Hybrid = scroll via `_scroll_by_drag` with `ViewerApp.HYBRID_SCROLL_STEP = 1/30` of the screen height/width per notch; long press = the `touch_*` rule from Task 2), `vnc/toolbar.lua` (`MODE_GLYPHS.hybrid = "↕"`, tip), `vnc/settings.lua` (`:375`, `:566` accept `"hybrid"`; anything else → `"touch"`), `vnc/help.lua` (`Help.ROWS.hybrid`, `Help.TITLES.hybrid = _("Hybrid mode")`), `README.md` (gesture table gets a Hybrid column; the Mode button text). Test `tools/ui_smoke.lua`.

- [ ] **Step 1: Failing tests:**
  - `mode_button_cycles_three_modes`: taps on the Mode button go touch → mouse → hybrid → touch; each stores `pointer_mode` on the profile and shows its toast; the glyph follows.
  - `hybrid_drag_scrolls`: Hybrid, drag up by 3 notches' worth → 3 wheel-down notches (buttons 16) at the finger's remote position, no button 1; a sideways drag scrolls horizontally (buttons 64/32); the view does not move.
  - `hybrid_tap_clicks_at_the_finger`: instant left click at the finger.
  - `hybrid_long_press`: lift without moving → right click at the finger; long press then drag → left drag from the finger.
  - `hybrid_drag_on_toolbar_does_not_scroll`: a drag starting on the toolbar moves the bar, sends nothing.
  - `unknown_pointer_mode_is_touch`: a profile with `pointer_mode = "banana"` loads as `"touch"`; `"hybrid"` round-trips.
  - `help_lists_hybrid`: the Help page has a Hybrid section with the spec's rows.
- [ ] **Step 2:** `../tmp/run-tests.sh ui` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `../tmp/run-tests.sh all` and `../tmp/arm/run.sh proto ui server40` pass.
- [ ] **Step 5: Commit** `Viewer: Hybrid mode (a drag scrolls, a tap clicks at the finger)`.

### Task 6: Live check against x11vnc

**Files:** `../tmp/e2e/e2e.lua`, `../tmp/e2e/runall.sh` (outside git).

- [ ] **Step 1:** Add e2e cases for the spec table (all three modes): taps (single, double → xev double click), long press lift (button 3 in xev), long press drag (button 1 motion in xev), Hybrid drag (button 4/5 in xev), Mouse follow at 2× zoom (view moves, server pointer at the expected position), scroll lock gone.
- [ ] **Step 2:** `cd ../tmp/e2e && ./runall.sh` (stop x11vnc with `x11vnc -R stop`, never `pkill`; remove vnce2e containers at the end). Every failure is a bug: fix in the owning task's file with a regression test, commit.
- [ ] **Step 3:** Device check by the user: try all three modes on the reader; tune `HYBRID_SCROLL_STEP` from their feedback.
