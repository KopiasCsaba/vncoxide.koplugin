# "Find fastest picture settings" benchmark — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** an on-device benchmark that tries picture-setting combinations against the real server and recommends/apply the fastest, measuring what the user feels (network + decode + draw) on their own content.

**Why (user):** the Help's "24-bit, Tight off is fastest" was reasoning, not measurement; on the user's PocketBook Era, 8-bit with compression felt faster. Only the device can measure the real round trip.

**User-approved design:** per combination: reconnect with that combination; (1) a short **full-screen baseline** (non-incremental FramebufferUpdateRequest for the whole screen, 2 samples, first discarded if 3 are cheap enough — builder's call, documented); (2) **5 s live** on whatever the user keeps changing on the PC (video, scrolling page, animation). **Main score = changed screen pixels delivered per second** in the live phase (sum of decoded rect areas, in remote pixels, divided by elapsed live time, where the time includes decode + draw). Results table (fastest first): score, avg time per update, bytes/s, full-screen ms. Live phase with almost no change → row marked "screen was still — not scored". "Apply" saves the winner's picture settings to the connection.

## Global Constraints

- Pure Lua + LuaJIT FFI; follow existing LDoc/module style; reuse `Session`, `Protocol`, `Remote`, `Scaler`, `Settings` rather than duplicating protocol code.
- Run suites with `../tmp/run-tests.sh [proto|ui|server|py|all]` from the repo root. Never claim a test passed without running it.
- No author names/brands in commits or source. Never stage `vnc.passwd`.
- The benchmark uses its **own** connection (servers are shared: `shared = true`), never disturbs a live session of the same profile, and never writes settings unless the user taps Apply.
- All time via the injectable monotonic clock pattern already used (`Session._now`) so tests need no real sleeps.

## Review Focus

1. A combination whose connection fails (auth, refused, server rejects a format) is recorded as "failed: <reason>" and the run continues. Task 1.
2. Cancel mid-run tears down the benchmark connection and leaves settings untouched. Task 2.
3. A still screen in the live phase → "not scored", never ranked first. Task 1.
4. The draw cost uses the user's current viewer zoom/sharp setting (draw into an off-screen buffer of the viewer's canvas size/type via `Remote:draw_to`), so results match what they will see. Task 1.
5. Apply writes exactly color_depth/enable_tight/jpeg_quality/compress_level of the winner to the profile, nothing else. Task 2.

---

### Task 1: `vnc/benchmark.lua` — runner and scoring

**Files:** Create `vnc/benchmark.lua`; Modify `vnc/session.lua` only if a small hook is needed (e.g. an `on_update` callback with rect area/bytes, or reuse the timing `tm` bookkeeping); Test `tools/proto_smoke.lua` (real mock server; `tools/mock_vnc_server.py` already serves every format; add a `--pattern` that keeps changing if none exists, e.g. a moving bar, minimal).

**Interfaces:**
- `Benchmark.COMBINATIONS` — ordered list of `{ color_depth, enable_tight, jpeg_quality, compress_level, label }`:
  24/16/8-bit × {Tight off; Tight + compression 1; Tight + compression 2} (9), plus 24-bit Tight + compression 2 + JPEG 8 and JPEG 4 (2) = 11. `label` e.g. "16-bit, Tight, compr. 2", "24-bit, Tight, compr. 2, JPEG 4".
- `Benchmark.LIVE_SECONDS = 5`, `Benchmark.STILL_MIN_PX_PER_S` = 1% of the remote screen area per second (below → not scored).
- `Benchmark.new{ profile, combinations?, live_seconds?, canvas = {w, h, bb_type, view_mode = "fit"|scale, scaling = "smooth"|"sharp"}, on_progress(i, n, label, phase), on_done(results) }` → object with `:start()`, `:cancel()`.
  - Drives one combination at a time with a fresh `Session` (profile copy + the combination's fields), scheduling via `UIManager` like the session's own poll loop; never blocks.
  - Phase "full": after connect, N non-incremental full-screen requests, timing request → `on_update_done`.
  - Phase "live": incremental updates for `live_seconds`; per update: sum of rect areas (remote px), bytes, decode+draw time; draw = `Remote:draw_to` into a persistent off-screen BlitBuffer of the canvas size/type (allocated once per run) with the given view/scaling.
  - `results[i] = { combination, ok = bool, error = string|nil, px_per_s, ms_per_update, bytes_per_s, full_ms, still = bool }`; `on_done(results)` with results sorted: scored rows by `px_per_s` desc, then still rows, then failed rows.
  - Every Session is disconnected (and its Remote freed) before the next starts and on cancel.
- [ ] Step 1: failing tests (mock server, injectable clock): two combinations with a changing pattern → both scored, sorted by px_per_s; a still pattern → `still = true`, not first; a combination the mock refuses (e.g. wrong password via a bad profile, or a forced connect failure) → `ok = false` with reason, run continues; cancel mid-live → session disconnected, `on_done` not called (or called with `cancelled = true` — pick one, document); draw path exercised (canvas 2× the remote, sharp) and its time counted.
- [ ] Step 2: FAIL. Step 3: implement. Step 4: `all` green. Step 5: commit `feat(benchmark): measure picture-setting combinations on the live server`.

### Task 2: UI — "Find fastest picture settings"

**Files:** Modify `vnc/dialogs.lua` (the per-connection Connect/Edit/Delete dialog ~line 330-395: add a button), possibly `main.lua` (plugin glue: canvas info from the viewer settings, current zoom/scaling), `README.md`, `NOTES.txt`; Test `tools/ui_smoke.lua`.

**Interfaces:**
- New button "Find fastest picture settings" in that dialog. Tap → an intro `ConfirmBox`/`InfoMessage`-style dialog with Start/Cancel and this text (verbatim):
  "Tries 11 picture-setting combinations on this connection, about 7 seconds each (roughly 1.5 minutes).\n\nBefore starting, make the shared area of the PC keep changing — play a video, scroll a long page or run an animation — and leave it running. Each combination is scored by how many changed screen pixels per second reach this screen, including decoding and drawing at your current zoom.\n\nNothing is saved unless you tap Apply at the end."
- While running: a non-blocking progress widget showing "<i>/<n>: <label> — <phase>" with a Cancel button (Cancel → `bench:cancel()`, back to the connection dialog).
- Done: a `TextViewer` "Picture benchmark" with a monospace-ish table (one row per combination: rank, label, "<x.x> Mpx/s", "<n> ms/update", "<n> KB/s", "full <n> ms"; still rows "screen was still — not scored"; failed rows "failed: <reason>"), and buttons "Apply best" (saves the first scored row's 4 picture fields to the profile via `plugin:save_profile`, then InfoMessage "Saved: <label>. Takes effect on the next connection.") and "Close". If nothing was scored: no Apply, text explains to start something that keeps changing and run again.
- Canvas for the draw cost: the viewer's canvas size for this device/orientation (Screen size minus nothing, or the viewer's last canvas if known) and type `Screen.bb:getType()`; view = the viewer's zoom mode/scale and the global `scaling` setting.
- [ ] Step 1: failing tests: button present; intro text verbatim; Start runs a stubbed Benchmark (inject a fake runner) and shows progress; Cancel calls cancel and returns; results viewer lists rows in order with the formats above; Apply best writes exactly the four fields of the top scored row and nothing else; all-still → no Apply button. Step 2: FAIL. Step 3: implement. Step 4: `all` green. Step 5: commit `feat(ui): find the fastest picture settings for a connection`.

### Task 3: Help advice says to measure

**Files:** Modify `vnc/dialogs.lua` (PICTURE_ADVICE), `README.md`; Test `tools/ui_smoke.lua`.

- Replace the first advice paragraph ("Fastest on a fast network …") with (verbatim):
  name "Which is fastest?", body "it depends on the PC, the network and what is on the screen: on a PocketBook Era, 8-bit with compression has felt faster than 24-bit even on fast Wi-Fi. Measure it: in the connection's menu, tap Find fastest picture settings while something keeps changing on the PC."
- Keep "Scale on the PC, not on the e-reader" and "Example" paragraphs unchanged.
- Update the bold-count test for the renamed heading; assert the text contains "Find fastest picture settings".
- [ ] Steps: failing test → implement → `all` green → commit `docs(ui): Help points to the benchmark instead of guessing`.
