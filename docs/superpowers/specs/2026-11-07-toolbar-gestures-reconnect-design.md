# Viewer toolbar, mouse/touch modes, gestures, reconnect — design

Rework of the viewer's in-session UX in the forked `vnc.koplugin` (KOReader VNC viewer). The user
drives a desktop from a PocketBook (greyscale e-ink, multitouch with at most two contacts as far as
KOReader is concerned, hardware page buttons) against `x11vnc` started by `../vnc-server.sh`
(which paints the pointer into the picture: `-cursor arrow`).

## Intent

Today every in-session action lives in a full-screen KOReader menu (`vnc/menu.lua`) opened by a
swipe down at the top (`ViewerApp:init_menu_zones` / `onMenuSwipe`, `vnc/app.lua:99-132`). It is
slow to open on e-ink, mixes rare and frequent actions, and hides the remote. The keyboard comes up
with a bottom swipe-up that is hard to hit. A two-finger flick sometimes scrolls instead of panning
(`onTwoFingerSwipe`, `app.lua:786`). A dropped connection only shows a 4 s toast
(`on_session_error`, `app.lua:1192`).

Goal: a compact top toolbar with the frequent actions one tap away, two pointer modes (Touch and
Mouse/touchpad), an unambiguous gesture set, and a connection that heals itself.

**Hard rule:** no mention of any other remote-desktop product anywhere — source, comments, docs,
README, NOTES, commit messages, test names.

## Goals

### 1. Toolbar

1. A compact floating bar, centred horizontally at the top of the screen, icons only, rounded
   border, white background; the remote stays visible beside it (mockup choice "B").
2. **Show/hide:** a swipe down starting in KOReader's top menu zone (the zones today's
   `init_menu_zones` registers) toggles the bar: shows it when hidden, hides it when shown. Nothing
   else hides it (no timer — every repaint costs an e-ink refresh). Whether it is shown when the
   viewer opens: builder's call; default **shown** on a fresh connect so it is discoverable.
3. Taps on the bar never reach the canvas; the canvas below and beside it stays fully interactive.
4. Buttons, left to right:
   1. **✕ Close** — disconnect, with a confirmation (reuse the existing Disconnect confirm text and
      flow from `menu.lua:272`, ending on the connection list like `ViewerApp:disconnect_session`).
   2. **Display** — opens a panel dropping down under the bar (see §2).
   3. **Mode** (☝ touch / 🖱 mouse icon reflecting the current mode) — tap toggles Touch ↔ Mouse
      and shows the gesture cheat-sheet (§4).
   4. **⌨ Keyboard** — tap toggles the on-screen keyboard *with* the key strip (§5); long press
      opens the existing "Send keys" panel (`ViewerApp:open_key_panel`).
   5. **⟳ Rotate** — rotates 90° clockwise (`ViewerApp:rotate(1)`).
   6. **▲ ▼ Scroll** — optional, hidden by default, enabled by a setting in ⋯; each tap sends one
      wheel notch (`ViewerApp:scroll_wheel`).
   7. **⋯ More** — a popup/menu with everything else (§3).
5. Icons: KOReader ships an icon set (`resources/icons/mdlight`); use existing icons where a fitting
   one exists, otherwise a text glyph. Builder's call which.
6. Removed: the full-screen menu as the swipe-down target, the bottom swipe-up/down keyboard zones
   (`KbdShow` / `KbdHide`), the two-finger flick-to-scroll (`onTwoFingerSwipe` scrolling), the
   two-finger rotate gesture (`onRotate`) — rotation is the ⟳ button only, so a pinch can never turn
   the screen.

### 2. Display panel

A panel under the bar (closes on a tap outside it, on Back, or on tapping Display again). Contents:

1. **Zoom:** Fit / Fit with keyboard / the numeric presets today's "Zoom…" offers (same values and
   code path as `menu.lua` zoom choices).
2. **Scaling:** Smooth / Sharp (existing `scaling` setting).
3. **Orientation:** Portrait / Landscape / inverted ones, plus "Use current orientation as default"
   (existing items `menu.lua:200-220`).
4. **Quality preset:** Best / Balanced / Fast. Each maps to the connection profile's existing
   `color_depth`, `enable_tight`, `jpeg_quality`, `compress_level` (`settings.lua:27-30`). Selecting
   a preset different from the current one **reconnects with it and saves it into the profile once that connection succeeds (§6.9);** it reconnects
   automatically (going through the reconnect overlay of §6). If the profile's values match no
   preset, show "Custom" as selected. Exact values per preset: builder's call, guided by: Best =
   24-bit, Tight off; Balanced = 16-bit, Tight on, mid compression; Fast = 8-bit, Tight on, high
   compression. Values chosen must be documented in README.
5. **Pointer speed** (Mouse mode): Slow / Normal / Fast — a multiplier on relative movement
   (suggested 0.75 / 1.25 / 2.0; builder's call, tune for usability).

### 3. ⋯ More

Everything from today's menu not on the bar or Display panel, plus new actions:

1. Connections… (reconnect / switch / new connection — today's `menu.lua:125-149` submenu).
2. **Send text…** — opens KOReader's `InputDialog`; on OK the text is sent as keystrokes (one
   key down/up per character, newline → Return). Editing happens locally. Characters with no
   keysym mapping are skipped and reported in a short notification. Reuse the keysym mapping the
   on-screen keyboard path already uses (`ViewerApp:onTextInput` / `vnc/keysyms.lua`).
3. **Refresh** — requests a full non-incremental update (`Session:request_full_update`) and does a
   full e-ink flash.
4. **Ctrl+Alt+Del**, **Lock screen** (Super+L) — send the combos.
5. Page buttons send: Page Up/Down keys / Mouse wheel (existing).
6. Keyboard always visible (existing).
7. Show scroll buttons on toolbar (new setting, default off).
8. Leave (keep connection) (existing).

The status line today's menu has ("Connected to X (W×H)") goes at the top of this popup.
Any other existing menu entry not listed (e.g. benchmark/debug entries if present in `menu.lua`)
also moves here unchanged.

### 4. Pointer modes and gestures

Two modes, chosen with the Mode button, **remembered per connection profile** (new profile field,
default Touch).

| Gesture | Touch mode | Mouse mode |
|---|---|---|
| One-finger tap | left click at the finger | left click at the pointer |
| Long press | right click at the finger | right click at the pointer |
| One-finger drag | left-button drag from the finger | move the pointer relatively (× speed) |
| Double tap & move | — (plain drag already drags) | left-button drag from the pointer |
| Two-finger drag | move the canvas | move the canvas |
| Pinch / spread | zoom the canvas | zoom the canvas |
| Two-finger tap | fit to screen (reset zoom/pan) | fit to screen |
| Hardware page buttons | Page Up/Down or wheel (setting) | same |

1. Touch mode is today's behaviour for tap / long press / drag (`onTap`, `onHold`, `onPan`) —
   keep the armed-modifier handling (`_press_armed`, `_release_action_mods`) and the stale-action
   guards.
2. Two-finger drag only moves the canvas; a quick two-finger drag ending as `two_finger_swipe`
   ends the pan (as `onTwoFingerPanRelease`) and never scrolls.
3. Two-finger tap uses KOReader's `two_finger_tap` gesture. "Fit" = the Fit zoom mode (or Fit with
   keyboard when the keyboard is up), view re-centred.
4. **Mouse mode details:**
   1. The viewer keeps a remote pointer position (start: centre of the remote screen, or the last
      known `_pointer_x/_pointer_y`). Relative moves are clamped to the remote screen and sent as
      pointer events with no button.
   2. One-finger drag delta is converted from screen to remote units through the current zoom,
      then multiplied by the pointer speed.
   3. Double tap & move: built only from KOReader gestures (`tap`, then a `pan` whose contact
      starts within the double-tap interval of that tap and near it) — no raw touch handling.
      To keep the remote from seeing click-then-press (a double-click-drag that selects words),
      a Mouse-mode tap's click is **deferred** by the double-tap interval (KOReader's
      `ges_double_tap_interval`, ~250–300 ms); if a pan starts in that window the click is dropped
      and the pan becomes a button drag. Touch mode clicks stay immediate.
   4. A real double-click (tap, tap) in Mouse mode must still produce two clicks at the pointer.
   5. The pointer is drawn by the server (x11vnc `-cursor arrow`); the viewer draws no cursor.
5. Gestures not listed (three fingers, rotate) are not handled. KOReader's GestureDetector emits no
   three-finger gestures (verified in `frontend/device/gesturedetector.lua`), and no custom touch
   handling is to be written.
6. **Gesture cheat-sheet:** switching mode shows a small card (centre of screen) with that mode's
   rows of the table above; dismissed by any tap (that tap is not forwarded to the remote).

### 5. Keyboard + key strip

1. ⌨ tap shows the on-screen keyboard and, directly above it, a single slim row: Ctrl, Alt, Shift,
   Super (sticky one-shot, same arming semantics as the Send keys panel), Esc, Tab, ← ↑ ↓ →, Del.
   Tapping ⌨ again hides both.
2. Reuse `vnc/keypanel.lua` (its modifier row and `take_armed` logic) rather than a second
   implementation; armed modifiers from the strip apply to the next OSK key, strip key, or canvas
   tap/drag, exactly like the panel.
3. Long press ⌨ → the full Send keys panel (unchanged). Strip and panel must not both be shown;
   opening one closes the other.
4. The view-fitting logic that today makes room for the keyboard / key panel
   (`_bottom_cover_changed`, `fit_with_keyboard`) accounts for the strip's height.

### 6. Connection loss and reconnect

1. When a connected session fails (`state == "error"` reaching `on_session_error`), the viewer
   keeps the last picture, dimmed or overlaid, and shows a centred box:
   "Connection lost — reconnecting… (attempt N, next in S s)" with **Retry now** and **Close**.
2. Retries automatically with backoff (suggested 2, 4, 8, 15, then every 30 s; never gives up on
   its own). Each attempt reuses the existing reconnect path (`Session:connect` on the same
   session, which keeps the app and plane — `session.lua:681`).
3. On success the box disappears and a full update is requested; the toolbar/mode/zoom state is
   kept.
4. **Close** stops retrying and disconnects (same as ✕). Back key = Close.
5. On device resume from sleep with a session in error/disconnected while the viewer is open,
   retry immediately.
6. The quality-preset reconnect (§2.4) shows the same box with "Reconnecting…".
7. **Wi-Fi stays on while retrying.** Today every failed attempt goes through `Session:_fail` →
   `_restore_wifi` (`session.lua:682-689`), which turns Wi-Fi back off when this plugin turned it
   on, and the next `connect` turns it on again. During a retry loop Wi-Fi must stay on (and the
   "this session turned Wi-Fi on" duty is kept); it is restored only when the loop ends without
   success (Close, Back, leaving the viewer) — the same last-connection-turns-it-off rule as now.
   One retry loop per session.
8. **The retry loop lives with the open viewer only.**
   1. A session that drops while the viewer is not open (after "Leave (keep connection)") is not
      retried in the background; it stays in `error` as today (the existing toast).
   2. Reopening the viewer on a session in `error` shows the same box, but with **no automatic
      retries**: "Connection lost — Retry / Close"; Retry starts the normal loop.
   3. Leaving the viewer while the loop runs stops it (timer cancelled, Wi-Fi restored per 6.7).
   4. No timers survive the viewer closing.
9. **Quality preset reconnect:** the new preset is written to the profile only after a connection
   with it succeeds. Until then the old values are kept; if the user Closes (or leaves) before a
   successful connect, the profile keeps its previous values.

## Non-goals

1. Three-finger gestures, rotate gesture, any custom multitouch handling below KOReader's
   GestureDetector.
2. Drawing the remote cursor locally (tried and reverted in 76aca5b).
3. A floating virtual mouse/joystick.
4. Auto-hiding the toolbar.
5. Chat, file transfer, clipboard sync.

## Anti-goals (failure even if it "works")

1. Any tap on the canvas lost or delayed in Touch mode.
2. A button or modifier left held down on the remote after a gesture, mode switch, toolbar open,
   reconnect or close.
3. Toolbar or panels causing full-screen flashes on every interaction (use partial "ui"/"fast"
   refreshes; full flash only on Refresh and wholesale changes as today).
4. Reconnect loop that leaks sessions, sockets, planes, or toggles Wi-Fi under another connection.
5. Any mention of another remote-desktop product anywhere.

## Constraints

1. KOReader plugin, Lua/LuaJIT, KOReader widget stack only; no new dependencies.
2. Existing headless test suites in `tools/` (`ui_smoke.lua`, `proto_smoke.lua`,
   `server_smoke.lua`; run per README "For developers", KOReader tree in `../tmp/koreader`) must keep
   passing; new behaviour gets tests in `ui_smoke.lua` (gesture → pointer/key events sent,
   toolbar show/hide, mode persistence, deferred click, reconnect state machine with a mock server).
3. README and NOTES.txt updated for the new UX (gesture table, toolbar, presets values, reconnect).
4. Commits without any assistant/brand attribution.

## Left to the builder

Widget structure (new `vnc/toolbar.lua` etc.), icons, exact preset values and pointer speeds,
backoff numbers within the guidance above, cheat-sheet styling, whether the old `menu.lua` is
deleted or reduced to the ⋯ content, and test structure.
