# Visible-area updates, forced-request benchmark, persistent viewer menu — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** (1) when zoomed in, ask the server only for the visible part of the remote screen; (2) the benchmark measures on a still screen with forced (non-incremental) requests instead of needing changing content; (3) the viewer menu stays open on toggles and closes with an explicit close button.

**Why (user):** RFB `FramebufferUpdateRequest` carries a rectangle + incremental flag; libvncserver only sends changes inside the client's requested region (`rfbserver.c:3319-3347`, intersect with `requestedRegion`), so a smaller request = less data/decoding. Forced non-incremental requests make the server re-encode/re-send identical pixels every time → a deterministic, fair benchmark on whatever (still) content is on screen. The viewer menu currently closes on every tap (`action()` wrapper in `vnc/menu.lua:~94`), which is annoying when toggling settings.

## Global Constraints

- Pure Lua + LuaJIT FFI; follow existing LDoc/module style.
- Run suites with `../tmp/run-tests.sh [proto|ui|server|py|all]` from the repo root. Never claim a test passed without running it.
- No author names/brands in commits or source. Never stage `vnc.passwd` or `.idea/`.
- Exactly one outstanding FramebufferUpdateRequest at a time stays the invariant (memory bound while detached).

## Review Focus

1. Panning/zooming to an area that was never requested shows correct pixels (a non-incremental request for the newly visible part), never stale/black areas. Task 1.
2. At "fit" (whole remote visible) the requests are byte-identical to today's (whole screen). Task 1.
3. Benchmark with a still screen scores every combination (no "screen was still" rows any more); the same content → same pixel counts for all combinations. Task 2.
4. Viewer menu: toggles update their checkmark in place and the menu stays; the close button and Back close it; actions that must show the canvas or leave still close it. Task 3.

---

### Task 1: Request only the visible area (plus margin)

**Files:** `vnc/session.lua`, `vnc/protocol.lua` (the auto incremental request after each update), `vnc/framebuffer.lua` (visible remote rect), `vnc/app.lua` (notify on view change), `NOTES.txt`, `README.md`; Test `tools/proto_smoke.lua`, `tools/ui_smoke.lua`.

**Interfaces:**
- `Remote:visible_remote_rect(margin_frac)` → `{x, y, w, h}` in remote coords: the area currently visible on the canvas, expanded by `margin_frac` (default `Session.REQUEST_MARGIN = 0.25` of the visible width/height on each side) and clamped to the framebuffer. When the whole framebuffer is visible → exactly `{0, 0, fb_w, fb_h}`.
- Protocol gains a request-area provider: `Protocol.new{ ..., request_area = function() -> x, y, w, h }` (optional; default whole framebuffer). The incremental request after each FramebufferUpdate and `release_update()` use it. Without it, behaviour is byte-identical to today.
- `Session:set_view_area(rect)` (called by the app when zoom/pan/canvas change, debounced to the end of a pan gesture is fine): stores the area; for the part of the new area not covered by the previously requested area, sends one **non-incremental** request (bounding box of the uncovered part is fine), so newly visible pixels arrive even if unchanged. Respect the one-outstanding-request invariant: if a request is outstanding, queue it and send it as the next request (merge with the incremental one into a non-incremental request of the union if simpler — document).
- `request_full_update` stays whole-framebuffer.
- `vnc-timing: update` line unchanged.
- [ ] Step 1: failing tests: (a) fit view → every request is the whole framebuffer (assert wire bytes as today); (b) zoomed to the top-left quarter → incremental requests carry the visible rect + margin; (c) pan to the bottom-right → one non-incremental request covering the newly visible area is sent, and after the update the plane there equals the mock's pattern; (d) mock server: only changes inside the requested rect are sent (extend `tools/mock_vnc_server.py` to honour the requested rect for incremental updates if it doesn't).
- [ ] Step 2: FAIL. Step 3: implement. Step 4: `all` green. Step 5: commit `perf(session): ask the server only for the visible area when zoomed in`.

### Task 2: Benchmark on a still screen with forced requests

**Files:** `vnc/benchmark.lua`, `vnc/dialogs.lua` (intro text, result columns), `README.md`, `NOTES.txt`, `vnc/dialogs.lua` PICTURE_ADVICE wording if it mentions "keeps changing"; Test `tools/proto_smoke.lua`, `tools/ui_smoke.lua`.

**Interfaces / behaviour (user-approved redesign):**
- Remove the live phase and the still-detection. Per combination, after connect:
  1. **Full phase:** `Benchmark.FULL_SAMPLES = 3` non-incremental whole-screen requests, one at a time; the first is discarded as warm-up if more than one was taken (document).
  2. **Tiles phase:** a fixed sequence of `Benchmark.TILES = 16` areas (4×4 grid of the framebuffer), each requested non-incrementally one at a time.
  - Every received rect is marked dirty and drawn through the same off-screen `Remote:draw_to` path (with the viewer's canvas/zoom/scaling/dither) so decode + draw are always paid even though pixels are identical.
  - Per phase: elapsed wall time (request sent → update done, summed), pixels received, bytes, decode_ms, draw_ms.
- Scores: `full_px_per_s` and `tile_px_per_s` (pixels received / summed elapsed), `full_ms` (avg per full frame), `tile_ms` (avg per tile). **Main score** = `tile_px_per_s` (closest to everyday small updates); sort scored rows by it, failed rows last. Keep stop-on-connect-failure, detach/reattach of live sessions, cancel safety, guarded errors.
- Results table rows: rank, label, "<x.x> Mpx/s small", "<n> ms/tile", "full <n> ms", "<n> KB/full".
- Intro text (verbatim, replaces the old one):
  "Tries 11 picture-setting combinations on this connection, a few seconds each.\n\nBefore starting, put what you usually look at on the shared area of the PC — the page, document or app you use — and leave it still. Each combination fetches that screen several times, whole and in small pieces, and is scored by how fast it reaches this screen, including decoding and drawing at your current zoom.\n\nNothing is saved unless you tap Apply at the end."
- Help: update the "Which is fastest?" body's last sentence to: "Measure it: in the connection's menu, tap Find fastest picture settings with your usual content on the PC screen."
- [ ] Step 1: failing tests: still mock pattern → all combinations scored with identical pixel counts per phase; tiles phase issues exactly 16 non-incremental requests with the 4×4 rects (assert on the mock's request log); sort by tile_px_per_s; results viewer shows the new columns; intro text verbatim; existing safety tests (connect failure stop, cancel, detach/reattach, guarded error) still pass (adapt).
- [ ] Step 2: FAIL. Step 3: implement. Step 4: `all` green. Step 5: commit `feat(benchmark): measure with forced full and tile requests on a still screen`.

### Task 3: Viewer menu stays open; explicit close

**Files:** `vnc/menu.lua`, `vnc/app.lua` if needed; Test `tools/ui_smoke.lua`.

**Behaviour:**
- The viewer menu has a visible close button (title bar X — KOReader `Menu` with `title_bar_fm_style`/close icon; check `frontend/ui/widget/menu.lua` for how the close button is shown and wired to `close_callback`) and closes on Back/the Menu key as today.
- **Stay open** (update the item text/checkmark in place, e.g. `menu:updateItems()` or rebuilding the item table and `switchItemTable` keeping the current page): Keyboard always visible, Page buttons send (both choices), Sharp scaling, Use current orientation as default, Screen orientation choices (the menu stays; the viewer rotates underneath — if rotating while the menu is open misbehaves, close for orientation and document).
- **Still close** (they need the canvas visible or leave the viewer): Zoom choices, Show/hide keyboard, Rotate screen, Send key items, Disconnect (after confirm), Leave, Reconnect, connect to another connection, New connection.
- [ ] Step 1: failing tests: toggling Sharp scaling / Keyboard always visible / Page buttons leaves the menu on top and the item shows the new state; the close button closes it; a Zoom choice and Send key still close it. Step 2: FAIL. Step 3: implement. Step 4: `all` green. Step 5: commit `feat(viewer): menu stays open on toggles, closes with its close button`.
