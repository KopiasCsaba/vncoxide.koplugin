# Toolbar buttons menu, collapsible/draggable toolbar, compact Send keys

Branch: `feat/toolbar-buttons-menu`. Two tasks, run in order (both touch `vnc/app.lua`, `vnc/help.lua`,
`tools/ui_smoke.lua`, README, NOTES).

## Constraints (both tasks)

1. No name/brand/signature anywhere (commits, comments, source). Commit with the repo's git identity, no trailers.
2. TDD: add checks to `tools/ui_smoke.lua`, run, see RED, implement, see GREEN. Run all three suites before committing.
   From `../tmp/koreader/lib/koreader` (P = plugin dir, H = a fresh scratch dir, wiped each run):
   ```
   rm -rf "$H/ui"; KO_HOME=$H/ui SDL_VIDEODRIVER=dummy LUA_PATH="$P/?.lua;;" LUA_CPATH="./common/?.so;;" ./luajit "$P/tools/ui_smoke.lua"
   LUA_PATH="$P/?.lua;./common/?.lua;./common/?/init.lua;;" LUA_CPATH="./common/?.so;;" ./luajit "$P/tools/proto_smoke.lua" --tmp $H/proto
   KO_HOME=$H/server SDL_VIDEODRIVER=dummy LUA_PATH="$P/?.lua;./common/?.lua;./common/?/init.lua;;" LUA_CPATH="./common/?.so;;" ./luajit "$P/tools/server_smoke.lua"
   ```
   Baseline: ui `all checks passed`; proto `all checks passed`; server `0 failure(s)`. A `session failed: could not connect to 127.0.0.1:1` WARN is pre-existing.
3. E-ink: partial `"ui"` refreshes of the changed area only; no new full flashes.
4. Nothing left pressed on the remote (buttons/modifiers) by any new path.
5. Update existing checks that assert behaviour this plan changes; do not delete coverage silently (say which checks changed in the report).
6. README.md, NOTES.txt and `vnc/help.lua` describe exactly what the code does after the task (check labels/numbers against the code).
7. Settings migrations: an old settings file must keep working (read old keys once, write the new ones).

---

## Task 1: Keyboard — popup fix, compact Send keys panel, remembered keyboard

### 1a. Accent popup stays open after picking the plain letter (KOReader bug, work around it)
Root cause (verified headless): in KOReader's `VirtualKeyPopup:init` the centre key reuses
`parent_key.callback` (`key_char_orig_func`) as its callback; that callback only closes
`close_after_callback_widget`, which is nil for the main keyboard's keys. So hold "e" -> popup, release,
tap "e": the char is typed, the popup stays on top, and it looks like nothing happened.
Fix: whenever a key from our keyboard is sent (the stub's send path in `vnc/keyboard.lua` / the viewer's
`press`), close a `VirtualKeyPopup` of our keyboard (`w.parent_key and w.parent_key.keyboard == app.vk`)
if one is on the window stack, with a `"ui"` refresh of its area. Other popup keys already close it;
this must not double-close.
Test: hold the "e" key (real gesture dispatch: `hold`, `hold_release` at the key centre), then `tap` at
the same spot -> exactly one `e` down/up sent and the popup is gone; picking `é` from the popup still
works and closes it; keyboard stays up.

### 1b. Send keys panel: same top bar as the key strip
- Replace the panel's TitleBar + modifier row with ONE row built like the strip's (`_strip_row`):
  `[✕ close panel] [keyboard icon -> app:switch_to_keyboard()] [Ctrl] [Shift] [Alt] [Super] [Esc] [Tab] [←] [↑] [↓] [→] [Del]`.
  The strip keeps `[✕ close keyboard] [keys icon -> open panel] ...same...`. Share the code; only the
  two leading buttons differ. Panel-variant keys still go to the recent combos (`_remember`), strip ones don't (as today).
- Keys tab: remove the keys now on the top bar (Esc, Tab, Delete, arrows) and Caps Lock. Add a
  "Modifiers only" key that does `send_modifiers_only()` (enabled only while a modifier is armed) —
  it replaces the removed combo display. Result: 12 keys, 4 columns x 3 rows:
  Enter, Backspace, Insert, Home / End, Page Up, Page Down, Space / Menu, Print Screen, Pause, Modifiers only.
- Remove the combo display button and its text helper if unused. Keep tabs, grid height (GRID_ROWS
  stays 4: Letters needs it), recent row and Release all.
- Update the module doc comment.
Tests: panel has no TitleBar; its first row's ids are close, keyboard, mod:*, the strip keys; the
keyboard button switches to the keyboard with armed modifiers kept; ✕ closes; no Caps Lock anywhere;
"Modifiers only" sends Super down/up when Super is armed and is disabled when nothing is armed; the panel is
exactly one row shorter than before (assert height == 7 rows' worth, computed the way `_build` does).

### 1c. "Keyboard always visible" removed; the keyboard button remembers
- Remove the menu row and the `keyboard_always_visible` setting. New persisted setting `keyboard_shown`
  (default false). Migration: an old `keyboard_always_visible = true` becomes `keyboard_shown = true`.
- The toolbar keyboard button / strip ✕ / `switch_to_keyboard` / closing the panel set the wish and
  persist it; the viewer opens with the keyboard shown iff `keyboard_shown`. Popups still hide it
  temporarily without changing the saved wish.
Tests: toggle on, close and reopen the viewer -> keyboard up; toggle off, reopen -> down; old setting migrates;
menu has no "Keyboard always visible".

---

## Task 2: Toolbar — hide button, reorder, tooltips, drag; menu "Toolbar buttons…"

### 2a. Order, new hide button, collapsed bubble
- New order: `toggle` (new, leftmost), display, zoom, mode, keyboard, rotate, scroll_lock, scroll_up,
  scroll_down, brightness, contrast, `close`, `more`.
- `toggle`: icon = new plugin icon `icons/toolbar.svg` (original, simple, same style as the existing
  plugin icons). Tap collapses the toolbar to a small circle (bordered round FrameContainer, white,
  just the same icon) at the spot where the toggle button was; tapping the circle expands the bar
  again. Collapsed state is persisted (`toolbar_collapsed`). The circle is the toolbar while collapsed:
  same gesture routing (`_toolbar_owns` uses its dimen), so taps on it never reach the remote.
- The top-zone swipe down keeps toggling full visibility (hidden entirely / shown, collapsed or not) as today.
- Toast placement (`show_toast`) and the panels placed under the bar (`displaypanel`, `contrastdialog`)
  must use the current dimen (bar or circle) and position.

### 2b. Long-press tooltips
- Every toolbar button (and the circle) shows a one-line tooltip on long press via `app:show_toast(text)`
  and does nothing else. The old long-press actions go away: Mode no longer opens Help (Help stays in
  the ⋯ menu), Keyboard no longer opens Send keys (reachable from the strip's keys icon). The Mode
  toast becomes just `Touch mode` / `Mouse mode` (no "long press for help").
- One-liners (keep them short): toggle "Collapse toolbar" (circle: "Show toolbar"), display "Display
  settings", zoom "Zoom: fit, 1:1, your own view", mode "Pointer mode: touch or mouse", keyboard
  "On-screen keyboard", rotate "Rotate the screen", scroll_lock "Scroll lock: two-finger drag scrolls the
  remote", scroll_up "Scroll up", scroll_down "Scroll down", brightness "Frontlight", contrast "Contrast
  of the remote picture", close "Disconnect", more "Menu".

### 2c. Draggable
- A one-finger drag that starts on the bar (or the circle) moves it; it never reaches the remote and
  never toggles the bar. Note a quick drag ends as `swipe` (currently excluded in `_toolbar_owns`) —
  a swipe that STARTS on the bar is a move; a swipe starting elsewhere keeps today's meaning.
- Live follow with `"fast"` refresh of old+new area during the pan, `"ui"` on release. Clamped fully on
  screen. Position persisted (`toolbar_pos = { x = fraction, y = fraction }` of the free space, so it
  survives rotation/resizes; default = today's top centre). Reclamped on relayout/rotation.
- Taps and long presses on buttons keep working (a drag is only a pan/swipe start on the bar).

### 2d. Menu
- New submenu `Toolbar buttons…`: one checkable row per button except Close and More (More is the
  only way to the menu on a touch-only device; say so in the submenu's help_text): Collapse button
  (`toggle`), Display, Zoom, Mode, Keyboard, Rotate, Scroll lock, Scroll up/down (one row for the pair),
  Brightness (disabled with help text on devices without frontlight), Contrast. Rows stay open
  (`stays_open`), `✓`/`-` like the other toggles, and rebuild the bar (`_toolbar_changed`).
  Persist as `toolbar_buttons = { id = bool }`; defaults: everything on except scroll pair and contrast
  (as today). Migrate `toolbar_scroll_buttons`, `toolbar_brightness_button`, `toolbar_contrast_button`.
  Hiding `toggle` while collapsed expands the bar.
- Remove the old top-level rows "Show scroll buttons on toolbar", "Enable brightness button", "Enable contrast button".
- Unified naming: checkable rows are plain names of the thing with `✓`/`-` (no "Show"/"Enable" verbs);
  actions are verbs. Review every row in `vnc/menu.lua` for this.
- Remove "Send text…" (and its dialog; remove `app:send_text` and anything else that becomes dead)
  and "Ctrl+Alt+Del".
- Status row merged into the title: connected `"<name> · <w>×<h>"`, error `"<name> · connection lost"`
  (the error message becomes the help_text of the "Reconnect to …" row), other states `"<name> · <state>"`,
  no profile `"VNC viewer"`. No non-selectable status row any more.

Tests: order of ids; collapse/expand via tap and persisted; circle routing (tap on circle sends no pointer);
long press on each button -> toast text, no other action, nothing sent; drag moves the bar, sends no pointer,
persists, clamps, survives rotation; swipe starting on bar moves it and does not toggle; submenu toggles each
button, migrations, title texts, removed rows absent.
