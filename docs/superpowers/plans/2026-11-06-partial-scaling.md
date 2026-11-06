# Partial rescale with a persistent canvas buffer, sharp/smooth per connection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** At any zoom, only the screen pixels covering changed remote rectangles are recomputed; no per-frame allocation; a per-connection "Sharp scaling" option (nearest neighbour) for fast full-frame changes.

**Why (measured on the user's PocketBook, 632x840 remote, 1264x1680 canvas):** paint at scale 2 = 306 ms median vs 17 ms at scale 1. `Remote:draw_to` (`vnc/framebuffer.lua:230-288`) rescales the *whole* visible plane through MuPDF into a newly allocated 6.4 MB RGB24 buffer on every update (the cache key includes `version`, bumped per update), then blits it RGB->grey. Desktop bench (`../tmp/bench/scale.lua`, KOReader LuaJIT): full frame at 2x — current 18.5 ms, own bilinear->grey without allocation 16.2 ms, nearest-neighbour 2.0 ms; a grey->grey full-canvas blit 0.1 ms. So: recompute only dirty areas, keep one buffer, offer nearest-neighbour.

**Spec:** this file.

## Global Constraints

- Pure Lua + LuaJIT FFI; follow existing LDoc/module style. Hot loops use FFI pointers and precomputed per-column tables (see the bench for the shape), no per-pixel table allocation or string ops.
- Run suites with `../tmp/run-tests.sh [proto|ui|server|py|all]` from the repo root. Never claim a test passed without running it.
- No author names/brands in commits or source.
- Scale exactly 1 (dst == src size) keeps a direct blit path (no filtering) in both modes.
- Behaviour visible to the user other than speed and the new option must not change: smooth mode stays smooth (bilinear up, area-average down).

## Review Focus

1. Partial result == full result, pixel-exact, at scales 0.75, 1, 1.37, 2, 2.5, both modes, for dirty rects touching plane edges and view edges. Task 1.
2. Pan/zoom/canvas-size/mode change → whole buffer recomputed once; no stale strips. Task 2.
3. No allocation per update: the buffer is (re)allocated only when canvas size or buffer type changes. Task 2 (assert buffer identity across updates).
4. Popup closing / keyboard toggling repaints correctly (paintTo always blits the whole buffer). Task 2.
5. Old profiles without the new field load as smooth. Task 3.

---

### Task 1: `vnc/scaler.lua` — global-coordinate scaler into a target buffer

**Files:** Create `vnc/scaler.lua`; Test `tools/ui_smoke.lua` or a new section in `tools/proto_smoke.lua` (whichever already loads BlitBuffer headlessly; pure function tests, no widgets).

**Interfaces:**
- `Scaler.render(dst_bb, plane_bb, view, rect, mode)` — `view = {x=view_x, y=view_y, scale=s}` (canvas pixel `(cx, cy)` shows remote point `(view_x + (cx+0.5)/s - 0.5, …)`); `rect = {x, y, w, h}` in **canvas** coordinates (already clipped to the canvas); `mode = "smooth" | "sharp"`. Writes exactly the pixels of `rect` in `dst_bb`, each computed from its global canvas position only, so any partition of the canvas into rects yields the same image as one full-canvas call.
  - `sharp`: nearest neighbour, `src = floor(view + (c+0.5)/s)` clamped to the plane.
  - `smooth`, s ≥ 1: bilinear with the mapping above, clamped at plane edges.
  - `smooth`, s < 1: area average over the source footprint `[view + c/s, view + (c+1)/s)` (box filter; integer-weight approximation is fine).
  - s == 1 exactly and integral view offset: plain copy.
  - Canvas pixels whose source lies outside the plane are set to black.
- Destination types: `TYPE_BB8` (grey: `(r*77 + g*150 + b*29) >> 8`) and the colour type the screen uses (check `Screen.bb:getType()` values KOReader produces: BB8, BBRGB32, BBRGB24 at least; support BB8 + RGB32 + RGB24). Source is always the `TYPE_BBRGB24` plane.
- `Scaler.dst_rect_for(remote_rect, view, canvas_w, canvas_h, mode)` → canvas rect covering every canvas pixel whose value depends on any pixel of `remote_rect` (sharp: footprint; smooth bilinear: +1 source pixel of influence each side; box: footprint), clipped; nil if empty.

- [ ] Step 1: failing tests: for each scale in {0.75, 1, 1.37, 2, 2.5}, mode in {smooth, sharp}, dst type in {BB8, RGB32}: render the full canvas once into A; render into B as a 3x3 grid of rects plus a few odd rects touching edges; assert A == B byte-exact. Plus: sharp at scale 2 duplicates each source pixel into a 2x2 block; smooth at scale 1 == source; `dst_rect_for` of a 1x1 remote change at scale 2 smooth covers the pixels that differ when that source pixel changes (compute by brute force: render, change pixel, render, diff, assert diff ⊆ returned rect).
- [ ] Step 2: FAIL. Step 3: implement. Step 4: `all` green; also run `../tmp/bench/scale.lua`-style timing of `Scaler.render` full canvas 632x840→1264x1680 (both modes, BB8) and record the ms in the report. Step 5: commit `feat(scaler): global-coordinate sharp/smooth scaler for partial redraws`.

### Task 2: Persistent canvas buffer + partial recompute in `Remote`

**Files:** Modify `vnc/framebuffer.lua` (`Remote`), `vnc/session.lua` (the `on_rect` path that calls `remote:mark_dirty()`), `vnc/app.lua` (`paintTo`, timing line), `NOTES.txt`; Test `tools/ui_smoke.lua`.

**Interfaces:**
- `Remote:mark_dirty(x, y, w, h)` (remote coords) accumulates stale remote rects (keep the existing version bump if other code relies on it). Called per decoded rect.
- `Remote:set_scaling(mode)` (`"smooth"|"sharp"`), default `"smooth"`; a change marks the whole buffer stale.
- `Remote:draw_to(bb, cx, cy, cw, ch, dither)` becomes:
  1. Ensure `self._canvas_bb` exists with size `cw x ch` and type matching `bb:getType()` (allocate only when size/type differ; free the old one).
  2. If view (view_x, view_y, scale), canvas size, mode or buffer changed since last fill → full recompute via `Scaler.render` over the whole canvas. Else recompute only `Scaler.dst_rect_for(r, …)` of each stale remote rect (dedupe/merge with the existing `Util.add_rect` if handy).
  3. Clear the stale list; blit the whole `_canvas_bb` to `bb` at `(cx, cy)` (`ditherblitFrom` when `dither`; measure its cost in the timing line — if dithering the whole canvas is expensive, dither only the recomputed rects into a second persistent buffer, builder's call based on measurement).
  - Remove the MuPDF path and the old `_scaled` cache entirely.
- `ViewerApp:paintTo` keeps the black background only outside the canvas area (canvas fully covers its rect now).
- Timing line becomes `vnc-timing: paint ms=<ms> canvas=<w>x<h> scale=<s> mode=<m> recomputed_px=<n>`.

- [ ] Step 1: failing tests: (a) after a full paint, mark one small remote rect dirty, change those plane pixels, paint again → output equals a fresh full render of the new plane (compare canvas area of the target bb); `recomputed_px` < 5% of the canvas; (b) `_canvas_bb` is the same object across 3 updates; changes after canvas resize; (c) pan by a few pixels → output equals fresh full render; (d) `set_scaling("sharp")` → output equals fresh sharp full render; (e) paint with no stale rects recomputes 0 px but still blits (simulates popup close).
- [ ] Step 2: FAIL. Step 3: implement. Step 4: `all` green. Step 5: commit `perf(viewer): rescale only changed areas into a persistent canvas buffer`.

### Task 3: "Sharp scaling" per connection

**Files:** Modify `vnc/settings.lua` (profile field), `vnc/dialogs.lua` (Picture sub-dialog + summary label), `vnc/session.lua`/`vnc/app.lua` (apply to `Remote:set_scaling`), `README.md`, `NOTES.txt`; Test `tools/ui_smoke.lua`.

**Interfaces:**
- Profile field `scaling = "smooth" | "sharp"`, default `"smooth"`; `clean_profile` normalises anything else to `"smooth"`; omitted on save = kept (same `given_or_kept` pattern).
- Picture sub-dialog: toggle "Sharp scaling (faster)" with help: "Scales by repeating pixels instead of blending them. Much faster on large changes; text looks crisper but can look uneven at non-whole zoom levels. Applies immediately." Summary label includes `sharp` when on (e.g. `Picture: 16-bit, sharp`).
- **Picture dialog UX (user request):** today it is not obvious what "Tight encoding" is, nor that JPEG quality / Compression level only matter when Tight is on. Rework the Picture sub-dialog so that:
  1. Rows are ordered and visually grouped: Colour depth; Sharp scaling; Tight encoding; then JPEG quality and Compression level shown as indented sub-items of Tight (e.g. prefixed "   ↳ "), and when Tight is off they read e.g. "↳ JPEG quality: needs Tight" (dimmed, still long-pressable for help).
  2. An always-visible explanation text block sits below all controls (a `TextBoxWidget` or the dialog's info text area — builder picks what KOReader's ButtonDialog/InputDialog offers; a ButtonDialog `title`/`info_text`-style area or a custom `CenterContainer`+`TextBoxWidget` is fine) with short plain-language lines, roughly:
     - "Colour depth: fewer bits = less data. 16-bit looks the same on e-ink greys."
     - "Sharp scaling: faster redraws when the zoom is not 100%; text looks crisper."
     - "Tight: an extra compression method; needed for the JPEG and compression settings."
     - "JPEG quality: lower = smaller photos/video (24-bit colour only)."
     - "Compression level: higher = less data, more work for the PC."
     - "Depth, Tight, JPEG and compression take effect on the next connection; sharp scaling right away."
  3. Long-press help on each row stays.
  Test: the dialog shows the explanation text (assert its text contains "Tight:" and "next connection"), and the sub-item labels change with the Tight toggle.
- Applied when the session/app starts drawing for a profile and immediately when the connected profile is saved (no reconnect). The "Reconnect to apply the new settings." notice is shown only if a field that needs a reconnect changed (host, port, password, color_depth, enable_tight, jpeg_quality, compress_level) — not for a scaling-only change.

- [ ] Step 1: failing tests: old profile → smooth; invalid → smooth; editor toggle + Save stores sharp; Cancel discards; saving the connected profile with only scaling changed calls `set_scaling("sharp")` on the live remote and shows no reconnect notice; changing depth still shows it. Step 2: FAIL. Step 3: implement. Step 4: `all` green. Step 5: commit `feat(connections): per-connection sharp scaling option`.

### Task 4: Server-side zoom in `tools/vnc-server.py`

**Why (user request):** let x11vnc send frames already scaled to the e-reader's size, so the viewer runs at 1:1 (17 ms paint measured) — trading bandwidth (zoom² more pixels) for zero client-side scaling.

**Files:** Modify `tools/vnc-server.py`, `tools/test_vnc_server.py`, `README.md` ("Serving a PC screen").

**Interfaces:**
- `-z ZOOM`: positive number or fraction (`2`, `1.5`, `4/3`); passed to x11vnc as `-scale <ZOOM>` (x11vnc scales after `-clip`; pointer input is mapped back by x11vnc). Validate: `^\d+(\.\d+)?$|^\d+/\d+$`, value > 0, else `SystemExit("-z must look like 2, 1.5 or 4/3")`. `-z 1` or omitted → no `-scale`.
- `--sharp`: with `-z`, append `:nb` (x11vnc "no blending", i.e. nearest neighbour) → `-scale 2:nb`. Without `-z` → `SystemExit("--sharp needs -z")`.
- `build_cmd(..., scale=None)` gains the parameter; place `-scale` right after `-clip …`.
- The "Sharing …" line appends ` scaled <ZOOM>[ sharp] -> <W'>x<H'>` where `W' = round(w*zoom)`, `H' = round(h*zoom)` so the user can see the frame size the viewer will get (to pick a zoom that matches the e-reader, e.g. 632x840 at 2 -> 1264x1680).
- README: explain the trade-off (fastest e-reader drawing vs zoom² bandwidth/decoding), example `-s 632x840 -z 2` for a 1264x1680 screen, and that the viewer zoom should then be 100%.

- [ ] Step 1: failing tests: `build_cmd` with scale "2" → `[..., "-clip", G, "-scale", "2", "-rfbport", ...]`; `--sharp` → `"2:nb"`; `-z 4/3` accepted; `-z 0`, `-z abc` → SystemExit; `--sharp` alone → SystemExit; end-to-end with fake x11vnc asserts argv and the "scaled 2 -> 1264x1680" text for `-s 632x840 -z 2`. Step 2: FAIL. Step 3: implement. Step 4: `all` green. Step 5: commit `feat(tools): server-side zoom (-z, --sharp) for 1:1 e-reader drawing`.
