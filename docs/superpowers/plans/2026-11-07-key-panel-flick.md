# Key panel, two-finger flick scrolling, benchmark row fit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** (1) a professional, KOReader-native "Send keys" panel able to send any hotkey (modifier toggles + full key set); (2) a fast two-finger vertical flick sends mouse-wheel notches; (3) benchmark result rows fit one line on a 1264-px-wide portrait screen.

**Why (user):** the viewer menu's "Send key" only offers Enter/Tab/Esc/Delete and there is no Ctrl/Alt/Super anywhere, so most hotkeys are impossible. KOReader's gesture detector has no three-finger gestures (`frontend/device/gesturedetector.lua` lists up to `two_finger_*`), so scrolling uses a two-finger flick (`two_finger_swipe`), distinct from the slow two-finger drag that pans. On the user's Era the benchmark rows wrapped ("KB/ full").

## Global Constraints

- Pure Lua; KOReader widgets only (FocusManager/InputContainer, ButtonTable, Button, TitleBar, FrameContainer, VerticalGroup, etc. — look at how KOReader's own dialogs such as ButtonDialog, TextViewer and the VirtualKeyboard are built and styled; match their fonts, sizes (Size.*), borders, padding and the title bar with a close X). It must look native.
- Run suites with `../tmp/run-tests.sh [proto|ui|server|py|all]` from the repo root. Never claim a test passed without running it.
- No author names/brands in commits or source. Never stage `vnc.passwd` or `.idea/`.
- Key events go through the existing `ViewerApp:send_key(keysym, down)` (which notes input for the update hold).

## Review Focus

1. A combo is sent in X order: all armed modifier downs (Ctrl, Shift, Alt, Super order), key down, key up, modifier ups in reverse; armed (not locked) modifiers clear after one key; locked ones stay. Task 1.
2. Closing the panel (✕, Back, Menu key, or leaving the viewer) never leaves a modifier held down on the remote (no key-up missing). Task 1.
3. The panel does not cover the whole canvas: the remote stays visible above it and the viewer keeps updating underneath. Task 1.
4. A slow two-finger drag still pans; only `two_finger_swipe` north/south scrolls; east/west does nothing. Task 2.
5. The benchmark row text fits one line at the Era's portrait width with the TextViewer's default font. Task 3.

---

### Task 1: "Send keys" panel

**Files:** Create `vnc/keypanel.lua`; Modify `vnc/menu.lua` (replace the "Send key" submenu with an entry "Send keys…" that opens the panel and closes the menu), `vnc/keysyms.lua` (add any missing keysyms), `vnc/app.lua` (own/close the panel; release held modifiers on close/leave), `README.md`, `NOTES.txt`; Test `tools/ui_smoke.lua`.

**Behaviour (user-approved design; the "apply armed modifiers to the on-screen keyboard" idea was explicitly declined — do not implement it):**
- A bottom-anchored panel (not full screen; width = screen width, height as needed), KOReader TitleBar "Send keys" with a close ✕. Remote visible above it.
- **Modifier row:** toggle buttons Ctrl, Shift, Alt, Super (keysyms Control_L 0xFFE3, Shift_L 0xFFE1, Alt_L 0xFFE9, Super_L 0xFFEB). Tap = arm for the next key (shown inverted/bold via KOReader's button preselect/invert styling); tap again = disarm; long-press = lock (distinct look, e.g. underlined or "🔒"-free text such as "Ctrl ●" — pick a KOReader-consistent indicator) until tapped. Tapping a modifier when nothing else is armed and then pressing "Send" is not needed: instead, a **long row button "Send modifiers only"** is NOT wanted — keep it simple: if the user taps the combo display (see below) with only modifiers armed, those modifiers are pressed and released (e.g. Super alone). A right-aligned **combo display** shows the pending combo, e.g. "Ctrl+Shift+…", or "Tap a key" when nothing is armed.
- **Tabs** (KOReader-style segmented buttons): **Keys**, **F1–F12**, **Letters**, **Symbols**.
  - Keys: Esc, Tab, Enter, Backspace, Delete, Insert, Home, End, Page Up, Page Down, Space, Menu, ←, ↑, ↓, →, Print Screen, Pause, Caps Lock (as a normal key press).
  - F1–F12: grid of 12.
  - Letters: a–z and 0–9 (send the lowercase/digit keysym; Shift is the user's modifier).
  - Symbols: ` - = [ ] \ ; ' , . / and their shifted forms are reached with Shift, so list the unshifted US-layout symbol keys only.
- **Recent:** a row with the last 4 distinct combos sent (persist in settings as `recent_combos`, max 4); tapping one resends it exactly (including its modifiers).
- **Release all:** sends key-up for every modifier the panel considers down/armed/locked and clears all state.
- Sending: modifier downs in order Ctrl, Shift, Alt, Super; key down; key up; modifier ups in reverse. Armed modifiers clear after the key; locked stay (and are not re-pressed per key? — they are pressed down per combo and released after, like armed ones; "locked" only means they stay armed; document).
- The panel stays open after sending; closes with ✕/Back/Menu key; closing or the viewer closing/disconnecting releases everything (no modifier left down — it never holds a key down between combos anyway; assert it).
- Keysyms needed beyond `Keysyms.special`: Insert 0xFF63 (exists), Print 0xFF61, Pause 0xFF13, Caps_Lock 0xFFE5, Super_L 0xFFEB, Menu 0xFF67, letters/digits/symbols = their ASCII codes (X11 Latin-1 keysyms equal the code point).
- [ ] Step 1: failing tests: panel opens from the menu ("Send keys…") and the menu closes; Ctrl armed + "t" sends exactly +Ctrl,+t,-t,-Ctrl and Ctrl is disarmed after; Ctrl locked + "c" then "v" sends Ctrl around both and Ctrl stays locked; Ctrl+Shift+Alt+Super + F4 order; Super alone via the combo display; Recent records and replays; Release all; close via ✕ / Back leaves no pending state and sends no stray key-down; panel height < screen height and the viewer canvas is still on the stack under it; every tab's keys produce the expected keysyms (table-driven).
- [ ] Step 2: FAIL. Step 3: implement. Step 4: `all` green. Step 5: commit `feat(viewer): Send keys panel with modifier toggles for any hotkey`.

### Task 2: Two-finger flick scrolls the remote

**Files:** `vnc/app.lua` (gesture table + handler), `README.md`, `NOTES.txt`; Test `tools/ui_smoke.lua`.

- Register `two_finger_swipe` on the canvas. North = content moves up = wheel **down** (mask 16)? — follow the page-button semantics: a flick **up** scrolls **down** the page like a touch scroll (finger moves up → content scrolls down → wheel down, mask 16); flick down → wheel up (mask 8). East/west: ignored (return nil).
- Notches = `clamp(round(distance / (screen_h / 10)), 1, 10)` where distance is the swipe's travel in pixels (`ges.distance` or from `ges.relative`; check what KOReader's two_finger_swipe event carries).
- Sent at the last recorded pointer position (same as `scroll_wheel`; reuse it with a notch count parameter) and notes input (update hold).
- Two-finger slow drag (two_finger_pan) behaviour unchanged.
- [ ] Step 1: failing tests: north flick of half the screen height → 5 notches of mask 16 (press+release each) at the pointer position; south → mask 8; east → nothing sent; a two_finger_pan still pans and sends nothing. Step 2–5 as usual; commit `feat(viewer): two-finger flick scrolls the remote`.

### Task 3: Benchmark rows fit one line

**Files:** `vnc/dialogs.lua` (~line 375 row format), Test `tools/ui_smoke.lua`.

- Row figures format becomes: `"%.1f Mpx/s · %d ms/tile · full %d ms · %d KB"` (U+00B7 separators, drop "small" and "/full"; the intro line already explains the columns — update its text to: "Fastest first: changed pixels per second in small pieces, time per piece, time per full screen and its size, decoding and drawing included.").
- Test: render the results TextViewer at 1264×1680 portrait (Screen size used by ui_smoke if configurable; otherwise measure with the TextViewer's TextBoxWidget face and width) and assert no row's figures line wraps (e.g. TextBoxWidget line count == number of logical lines). If exact measuring is impractical, assert the figures string width (via `RenderText:sizeUtf8Text` with the viewer's face) is below the text area width for the worst case "10.0 Mpx/s · 999 ms/tile · full 9999 ms · 9999 KB".
- Commit `fix(benchmark): result rows fit one line`.

### Task 4: Benchmark — two passes and median scoring (user-approved)

**Why:** on the user's Era (photo of the results, 1264×1680 frame): per-request overhead varied 0–90 ms between combinations with no pattern (16 tiles took 1.0–2.2 s for the same pixels one full frame delivered in 0.7–1.0 s), and the combinations that ran last scored best — order/warm-up effects and Wi-Fi round-trip jitter decide the ranking. Run everything twice (forward, then reverse order) and score with medians.

**Files:** `vnc/benchmark.lua`, `vnc/dialogs.lua` (intro text, progress label), `README.md`, `NOTES.txt`; Test `tools/proto_smoke.lua`, `tools/ui_smoke.lua`.

**Behaviour:**
- `Benchmark.PASSES = 2`. Pass 1 runs the combinations in list order, pass 2 in reverse order (each combination reconnects in each pass as today). Total runs = 2 × combinations.
- Per combination, collect every tile sample from both passes (per sample: pixels, elapsed) and every counted full-frame sample.
- Scores: `tile_ms` = median of the tile sample times; `tile_px_per_s` = median of the per-sample (pixels / elapsed); `full_ms` = median of the counted full-frame times; `full_px_per_s` from that median; `full_bytes` = mean as today. Keep phase totals (`full`, `tiles`) summed over both passes.
- A combination that failed in either pass: ranked with the failed rows, error text from the first failure ("failed in pass N: <reason>"). Stop-on-connect-failure stays (first pre-handshake failure ends the whole run).
- Progress label: "<run>/<total> (pass <p>/2): <label> — <phase>".
- Intro text: replace "a few seconds each" with "twice each, in opposite order, a few seconds per try"; keep the rest verbatim.
- Results intro line: append " Medians over two runs."
- [ ] Step 1: failing tests: run order is forward then reverse (assert on Session creation order / mock connection log); medians computed correctly from known samples (unit-test the scoring function with hand-made samples incl. an outlier that a mean would be skewed by); a failure in pass 2 marks the row failed with "failed in pass 2"; cancel during pass 2 stops cleanly; progress label format. Step 2: FAIL. Step 3: implement. Step 4: `all` green. Step 5: commit `feat(benchmark): two passes in opposite order, median scoring`.
