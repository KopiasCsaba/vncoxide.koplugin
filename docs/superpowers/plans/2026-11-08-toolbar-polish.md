# Toolbar polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Polish the viewer toolbar after first on-device use: orientation icons, remembered orientation, a keyboard button that really shows/hides, a Keys button on the strip, a Help page, a light mode tooltip, and a scroll-lock toggle.

**Architecture:** Changes stay inside the existing modules (`vnc/displaypanel.lua`, `vnc/toolbar.lua`, `vnc/keypanel.lua`, `vnc/app.lua`, `vnc/menu.lua`); the gesture card (`vnc/cheatsheet.lua`) becomes the content source of a Help page shown with KOReader's `TextViewer`. Plugin-owned SVG icons live in `icons/` inside the plugin folder and are loaded by path.

**Tech Stack:** Lua/LuaJIT, KOReader widget stack, headless suites in `tools/`.

**Spec:** `docs/superpowers/specs/2026-11-07-toolbar-gestures-reconnect-design.md` (base design) plus the user's follow-up requests recorded in this plan's "Requests" section (binding where they differ).

## Requests (user, 2026-11-08)

1. Display panel: orientation buttons use the same (or same-style) icons KOReader uses for screen rotation, instead of text. Drop "Use current orientation as default": the viewer remembers the last orientation used.
2. ⌨ tap shows or hides the keyboard together with the key strip (today it can toggle between keyboard and panel but not hide). The strip gets a button that opens the full Send keys panel. The ⌨ long press stays. A better keyboard icon.
3. Switching mode no longer pops the big gesture card. Instead a small tooltip appears: `Touch mode — long press for help` / `Mouse mode — long press for help`. A long press on the mode button opens the help.
4. A Help page revealing all features (toolbar, gestures per mode, key strip, long presses, scroll lock, reconnect), reachable from ⋯ → `Help`.
5. A scroll-lock toggle button on the toolbar, next to (not replacing) the optional ▲▼ buttons: while on, a two-finger drag sends mouse-wheel events instead of moving the picture.

## Global Constraints

1. Never name any other remote-desktop product anywhere (source, comments, docs, tests, commits). README's existing list of compatible VNC clients stays.
2. No assistant/brand attribution in commits or files.
3. KOReader widget stack only, no new dependencies, no raw multitouch handling (GestureDetector gestures only).
4. All three suites stay green after every task. From `/home/dev/mnt/aitmp/pocketbook-remote-screen/tmp/koreader/lib/koreader`, with `P=/home/dev/mnt/aitmp/pocketbook-remote-screen/vnc.koplugin`, `H=/home/dev/mnt/aitmp/pocketbook-remote-screen/tmp/vnc-home`:
   ```bash
   rm -rf "$H/ui"; KO_HOME=$H/ui SDL_VIDEODRIVER=dummy LUA_PATH="$P/?.lua;;" LUA_CPATH="./common/?.so;;" ./luajit "$P/tools/ui_smoke.lua"
   LUA_PATH="$P/?.lua;./common/?.lua;./common/?/init.lua;;" LUA_CPATH="./common/?.so;;" ./luajit "$P/tools/proto_smoke.lua" --tmp $H/proto
   KO_HOME=$H/server SDL_VIDEODRIVER=dummy LUA_PATH="$P/?.lua;./common/?.lua;./common/?/init.lua;;" LUA_CPATH="./common/?.so;;" ./luajit "$P/tools/server_smoke.lua"
   ```
   Baseline at plan time: ui `all checks passed` (162 ok), proto `all checks passed`, server `62 check(s), 0 failure(s)`. A `WARN vnc: session failed: could not connect to 127.0.0.1:1` line is pre-existing.
5. E-ink: partial `"ui"` refreshes for toolbar, strip, tooltip; no new full flashes.
6. No button or modifier left down on the remote after any new action (scroll lock toggling mid-gesture, keyboard hide, help open).
7. TDD: add checks, run the ui suite and record RED, implement, run all three suites, commit.

---

### Task 1: Orientation icons and remembered orientation

**Files:** Modify `vnc/displaypanel.lua`, `vnc/app.lua` (rotation path), `vnc/settings.lua` only if needed; Test `tools/ui_smoke.lua`.

**Interfaces:**
- The rotation row shows four `IconButton`/icon buttons using KOReader's icons, mirroring `frontend/ui/data/koptoptions.lua` `rotation_mode` (`item_icons_func` picks the `rotation.P.*` / `rotation.L.*` set for the current rotation; the four buttons mean "rotate 90° CCW", "upright as now", "rotate 90° CW", "rotate 180°" relative to the current mode — copy its mapping of icon → resulting mode exactly). The current one is marked selected (inverted/bordered, as KOReader's config buttons do, or the `✓` convention if an icon button cannot show selection — implementer's call, state it in the report).
- `DisplayPanel.ROTATIONS` text labels are no longer shown; keep the mode values if useful.
- "Use current orientation as default" is removed. Every orientation change made while the viewer is shown (panel, ⟳ button) stores `settings.orientation = new_mode` and flushes; the viewer opens in `settings.orientation` as today.
- Tests: rotation buttons are icon buttons with the expected icon names for an upright screen; tapping the "90° CW" one rotates to mode 1 and `settings.orientation == 1` after flush; ⟳ also stores it; no "Use current orientation as default" button exists.

### Task 2: Keyboard button shows/hides; Keys button on the strip; keyboard icon

**Files:** Modify `vnc/app.lua` (`toggle_keyboard`, keyboard state), `vnc/keypanel.lua` (strip), `vnc/toolbar.lua`; Create `icons/keyboard.svg` (and the plugin icon path helper if none exists); Test `tools/ui_smoke.lua`.

**Interfaces:**
- First reproduce the user's bug through the real widget stack (toolbar taps via `tap_toolbar`, with the real VirtualKeyboard shown): "⌨ toggles between keyboard and panel but does not hide". Record the root cause in the report before fixing.
- `toggle_keyboard()`: keyboard+strip hidden → show both; shown → hide both; key panel open → close the panel (keyboard+strip stay hidden). Turning it off also clears `keyboard_always_visible` as today.
- Strip: a last button `Keys…` (id `key:panel`) that opens the full Send keys panel (`app:open_key_panel()`), which hides keyboard+strip as today. It sends nothing to the remote and does not consume armed modifiers.
- ⌨ long press still opens the panel.
- `icons/keyboard.svg`: an original, simple keyboard glyph drawn for this plugin (rounded rectangle with key rows), monochrome, same viewBox/stroke style as KOReader's `mdlight` icons; the toolbar loads it by absolute path derived from the plugin directory (`debug.getinfo` / the plugin's `path` field — follow how the plugin already locates itself).
- Tests: ⌨ tap ×2 → shown then hidden (vk and strip both gone); with panel open, ⌨ tap → nothing shown; strip `Keys…` opens the panel, sends no key events, armed modifiers stay armed; toolbar keyboard button uses the icon file.

### Task 3: Help page, mode tooltip, no gesture card on switch

**Files:** Modify `vnc/cheatsheet.lua` (becomes help content: `CheatSheet.help_text(mode) -> string` or a new `vnc/help.lua` — implementer's call, keep one source of truth for gesture rows), `vnc/app.lua` (`toggle_pointer_mode`, `open_help`), `vnc/toolbar.lua` (mode `hold_callback`), `vnc/menu.lua` (`Help` entry, placed last before `Leave (keep connection)`); Test `tools/ui_smoke.lua`.

**Interfaces:**
- `toggle_pointer_mode()` flips the mode, relayouts the toolbar and shows a KOReader `Notification` (auto-dismissing, partial refresh) with exactly `Touch mode — long press for help` or `Mouse mode — long press for help`. It no longer opens the gesture card.
- `ViewerApp:open_help()` shows a `TextViewer` titled `VNC viewer help`, whose text covers, in order: gestures for the current mode then the other mode (from the same rows the card used), toolbar buttons (each button, tap and long press), key strip (incl. `Keys…`), scroll lock, Display panel, ⋯ entries, reconnect behaviour. Closing it re-syncs the keyboard (`_sync_keyboard_later`).
- Mode button long press → `open_help()`. ⋯ → `Help` → `open_help()`.
- The help viewer is a popup: the toolbar is inert under it (existing `_input_target` gate) and taps never reach the remote.
- Remove the now-unused card widget code paths and their checks; keep `CheatSheet.ROWS` if used as the data source.
- Tests: mode tap → `Notification` with the exact text, no card, nothing sent; mode long press → help viewer on top, text contains `Double tap and drag` and `Scroll lock`; ⋯ `Help` opens the same; closing returns to the viewer.

### Task 4: Scroll lock

**Files:** Modify `vnc/toolbar.lua` (new id `scroll_lock` placed right after `rotate`, always visible; `Toolbar.IDS` updated), `vnc/app.lua` (`onTwoFingerPan`, `onTwoFingerPanRelease`, `onTwoFingerSwipe`, new state), Create `icons/scroll-lock.svg` (original, same style as Task 2's icon); Test `tools/ui_smoke.lua`.

**Interfaces:**
- `ViewerApp.scroll_lock` (boolean, starts false on every viewer open, not persisted); `ViewerApp:toggle_scroll_lock()`; the toolbar button is drawn inverted (selected) while on and relayouts with a partial refresh.
- While on, a two-finger drag sends wheel notches instead of panning: accumulate the drag delta since the last notch; one notch per `Screen:getHeight() / 10` of vertical movement (and `Screen:getWidth() / 10` horizontal), content follows the fingers like a phone (fingers move up → scroll down = button 5 / mask 16; fingers move down → button 4 / mask 8; fingers move left → scroll right = button 7 / mask 64; right → button 6 / mask 32). Each notch is press+release of that button at the current pointer position (Touch: the two-finger gesture's position mapped to remote; Mouse: the mouse pointer), via the same `scroll_wheel` path where possible (extend it for horizontal).
- Pinch/spread still zoom; two-finger tap still fits; one-finger gestures unchanged. Armed modifiers are neither sent nor consumed by scroll notches (as `scroll_wheel` today).
- Toggling while a two-finger gesture is in progress ends that gesture cleanly (no stray pan or notch after the toggle).
- Tests: lock off → two-finger drag pans, no wheel masks; lock on → drag up by 3/10 of the screen sends exactly 3 notches of mask 16 (press+release each), view unchanged; drag left 2/10 width → 2 notches mask 64; pinch while locked still changes scale; lock state resets on a new viewer; button shows selected while on.

### Task 5: README, NOTES and help consistency

**Files:** `README.md`, `NOTES.txt`.
- Update for Tasks 1–4: rotation icons and remembered orientation (no default entry), ⌨ show/hide and `Keys…`, mode tooltip and Help (⋯ `Help`, long press on mode), scroll lock (behaviour and directions), plugin `icons/` folder. Remove the cheat-sheet-card description. Check every number/label against the code. Constraint 1 applies.
