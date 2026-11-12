# Worker Processes, Invert Button, Toolbar Anchor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take every per-pixel job off KOReader's UI thread and use both cores of the reader: a decode worker (network + decoding) and a scale worker (scaling, tone curve, dithering) run as forked processes; the UI process keeps input, view geometry, one blit and the e-ink refresh. Also: an "Invert" toolbar button, and a collapsed toolbar that returns to its corner.

**Architecture:** Three processes in a pipeline. The UI process connects and handshakes as today, then forks a **decode worker** (inherits the socket and protocol state, writes the remote plane) and a **scale worker** (renders the visible part of the plane into a canvas already in the screen buffer's format). Plane and canvas live in `MAP_SHARED` memory; pipes carry only small messages. The UI process stays the authority for the view (zoom, pan, canvas size, contrast, invert, mode) and answers gesture geometry without a round trip; on paint it blits the finished canvas. A remote desktop resize ends the workers and reconnects.

**Tech Stack:** Lua 5.1 / LuaJIT FFI inside KOReader; `ffi/util` (`runInSubProcess`, `isSubProcessDone`, `getNonBlockingReadSize`), `ffi/posix_h` (`mmap`, `pipe`, `read`, `write`, `close`, `kill`), libc `setpriority` via FFI, LuaSocket `socket.select`, `libs/libkoreader-lfs`.

**Spec:** this plan, agreed in conversation 2026-11-12/13. User decisions: the plugin's own VNC server is not touched; a remote resize is handled by reconnecting; highest performance on the target, a 2 x 1 GHz, 1 GB RAM, 1264x1680 grey e-ink PocketBook (KOReader refreshes through InkView, `ffi/framebuffer_pocketbook.lua`, which must stay in the UI process).

## Why this layout (review of the alternatives)

1. Decode and scale are both per-pixel and both sit on the UI thread today (`Session:_poll` → decoders; `ViewerApp:paintTo` → `Remote:draw_to` → `Scaler.render`, which recomputes the whole 1264x1680 canvas after every pan/zoom). Refresh and input cannot leave the UI process. So: everything per-pixel goes out; the UI keeps geometry, blit, refresh, input.
2. Decode and scale in two workers rather than one: the UI process is mostly idle once pixels are gone, so one worker would leave a core unused while it runs decode and scale back to back; two workers pipeline them (decode of the next rects overlaps scaling of the last), up to max(decode, scale) per frame instead of their sum. Which stage dominates on the device is unmeasured; with two workers neither has to be guessed.
3. Workers run at a lower priority (`setpriority`, nice +5), so a tap on the UI process wins a contended core.
4. Geometry stays in the UI process: of `Remote`'s methods the viewer calls, only `draw_to` and `set_contrast` touch pixels; `get_size`, `get_scale`, `fit_view`, `set_view`, `set_scale`, `pan_by`, `zoom_at`, `screen_to_remote`, `visible_remote_rect`, `canvas_rect_for`, `set_canvas` are arithmetic, so gestures stay instant.
5. The scale worker writes the canvas in the screen buffer's type and already dithered (BB8 + `sw_dithering` on the device), so the UI's blit is a plain copy.
6. Latest-wins view messages: during a pan the UI sends a view message per move; the scale worker drains all pending ones and renders only the newest.
7. Self-adapting refresh: the UI drains every pending "canvas rects ready" message per tick into one paint; while the panel is fast you keep the banding, when a refresh blocks the UI the bands merge instead of queueing.
8. Considered and rejected: workers writing straight into `Screen.bb` (overlays such as the toolbar, keyboard and dialogs would be overwritten, and InkView's buffer is a closed library's); a grey (1 byte) plane (every decoder path rewritten; separate project after measuring); blitting only the changed canvas rects (a few ms at most for a 2 MB BB8 copy, estimated not measured, against the risk of leaving stale pixels under a closed dialog).

## Global Constraints

- Pure Lua + LuaJIT FFI: no C component, no build step.
- No change to `vnc/server.lua`, `vnc/rfbserver.lua`, `vnc/serverenc.lua`, `vnc/servermenu.lua`.
- The setting `worker_processes` (boolean, default `false`) switches the mode; with it off, behaviour is today's and every existing test passes unchanged.
- The picture benchmark (`vnc/benchmark.lua`) always runs in-process.
- Commit messages: plain, in the repo's style (`Area: what changed`); no assistant names, no Co-Authored-By, no signatures.
- After every task: `P=<worktree> SUF=<suffix> ../tmp/run-tests.sh all` exits 0. At the end also `../tmp/arm/run.sh proto ui server40`.
- Never `git stash` (shared across worktrees).

## Review Focus

1. A worker dies or hangs → the viewer shows its normal reconnect box within 2 s, never a frozen picture. Test: `worker_death_is_a_session_error` (Task 6).
2. KOReader exits or the session closes mid-update → both workers exit (pipe EOF or `Q`, SIGKILL after 2 s); none keeps the TCP connection or Wi-Fi up. Tests: `workers_exit_when_the_ui_pipe_closes`, `hangup_kills_a_stuck_worker` (Task 6).
3. Workers inherit KOReader's other descriptors (the plugin server's listening socket, framebuffer, input) → each closes all but its own. Test: `workers_keep_only_their_own_descriptors` (Task 6).
4. A popup above the viewer closes while a view change is still rendering → the screen is never left with dialog remnants: the UI repaint blits the whole canvas, the next ready message corrects it. Test: `closing_a_dialog_mid_render_leaves_no_remnant` (Task 8).
5. Keys typed while a large update decodes reach the server in order within one decode tick (≤ 50 ms). Test: `keys_reach_the_server_during_a_long_decode` (Task 8).

---

### Task 1: A collapsed toolbar returns to the spot it was anchored to

Cause (`vnc/app.lua:183-200`): `set_toolbar_collapsed` relayouts with `at = old top-left corner`; expanding a top-right round button clamps the wide bar leftwards and stores that corner as `toolbar_pos`, so collapsing leaves the button at the wide bar's left edge.

**Files:** Modify `vnc/app.lua:193-198`. Test `tools/ui_smoke.lua`.

- [ ] **Step 1: Failing tests** (next to the existing collapse tests):
  - `collapsing_a_bar_expanded_from_the_top_right_returns_it_there`: `toolbar_pos = {x = 1, y = 0}`, collapsed; expand, collapse. Assert round button `dimen.x + dimen.w == Screen:getWidth() - Size.margin.default`, `dimen.y == Size.margin.default`, `toolbar_pos` still `{x = 1, y = 0}`.
  - `toggling_the_bar_keeps_a_dragged_position`: `toolbar_pos = {x = 0.3, y = 0.5}`; expand, collapse, expand; `toolbar_pos` unchanged.
- [ ] **Step 2:** `../tmp/run-tests.sh ui` — first test FAILS.
- [ ] **Step 3:** `set_toolbar_collapsed` calls `bar:relayout()` (no `at`); keep the `old:combine(bar.dimen)` repaint.
- [ ] **Step 4:** `../tmp/run-tests.sh ui` passes (an existing test asserting the old corner-keeping is updated, noted in the commit message).
- [ ] **Step 5: Commit** `Toolbar: collapsing returns the button to where it was anchored (an expanded bar clamped leftwards no longer moves it)`.

### Task 2: Invert button for the remote picture

Only the remote picture is inverted (toolbar, keyboard, dialogs stay). Same mechanism as contrast: the tone curve.

**Files:** Modify `vnc/scaler.lua:553`, `vnc/framebuffer.lua` (`Remote:set_invert`), `vnc/settings.lua` (DEFAULTS, `SETTING_CHECKS`, `TOOLBAR_BUTTONS`, `TOOLBAR_PINNABLE`), `vnc/toolbar.lua` (`IDS`, `TIPS`, `specs`), `vnc/app.lua` (`:491`, near `set_contrast` `:2525`), `README.md` (toolbar list). Create `icons/invert.svg` (circle, left half black, right half white; canvas and stroke as `icons/scroll-lock.svg`). Test `tools/ui_smoke.lua`.

**Interfaces (produced):** `Scaler.contrast_lut(f, invert) -> table|nil` (nil only for `f == 1 and not invert`; inverted = `255 - contrast(x)`). `Remote:set_invert(on) -> boolean` (true when changed; whole canvas stale). Setting `remote_invert` (boolean, default `false`). Toolbar id `"invert"` right after `"contrast"`, shown by default, pinnable, tip `_("Invert the remote picture")`, `selected = settings.remote_invert`. `ViewerApp:toggle_invert()`.

- [ ] **Step 1: Failing tests:**
  - `contrast_lut_inverts`: `contrast_lut(1, true).g[0] == 255`, `.g[255] == 0`, `.w[0] == 255 * 256`; `contrast_lut(1, false) == nil`; `contrast_lut(2, true).g[x] == 255 - contrast_lut(2).g[x]` for x = 0, 64, 200.
  - `invert_button_inverts_the_picture_and_persists`: plane filled RGB (10, 10, 10); tap `invert` through the widget stack; canvas probe grey `245`; `settings.remote_invert == true`; button drawn selected; tap again → `10`; a reopened viewer applies the stored value.
  - `invert_is_a_toolbar_button`: `Toolbar.IDS` and `TOOLBAR_PINNABLE` have `"invert"` right after `"contrast"`; `TOOLBAR_BUTTONS.invert == true`.
- [ ] **Step 2:** `../tmp/run-tests.sh ui` — FAIL.
- [ ] **Step 3:** Implement; apply `remote_invert` wherever `remote_contrast` is applied; repaint like `set_contrast`.
- [ ] **Step 4:** `../tmp/run-tests.sh all` passes (update button-order tests).
- [ ] **Step 5: Commit** `Toolbar: Invert button (the remote picture drawn inverted; stored as remote_invert)`.

### Task 3: Shared-memory BlitBuffers

**Files:** Create `vnc/sharedmem.lua`. Test `tools/proto_smoke.lua`.

**Interfaces (produced):** `SharedMem.alloc(bytes) -> ptr` (`mmap(nil, bytes, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_ANONYMOUS, -1, 0)`; errors on failure), `SharedMem.free(ptr, bytes)` (`munmap`), `SharedMem.bb(ptr, w, h, bbtype) -> BlitBuffer` (`BB.new(w, h, bbtype, ptr, stride)`, stride = `w * bytes per pixel`; never `:free()`d — the mapping is freed with `SharedMem.free`). `pcall(ffi.cdef, ...)` what `ffi/posix_h` lacks (Linux: `PROT_READ = 1`, `PROT_WRITE = 2`, `MAP_SHARED = 1`, `MAP_ANONYMOUS = 0x20`).

- [ ] **Step 1: Failing test** `shared_memory_is_shared_across_fork`: alloc 64x32 RGB24, `SharedMem.bb`; a `runInSubProcess` child writes RGB (1, 2, 3) at (5, 7) and exits; after `isSubProcessDone(pid, true)` the parent reads (1, 2, 3).
- [ ] **Step 2:** `../tmp/run-tests.sh proto` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `../tmp/run-tests.sh all` passes.
- [ ] **Step 5: Commit** `SharedMem: BlitBuffers over shared memory (for worker processes)`.

### Task 4: `Remote` pixel work behind a renderer (no behaviour change)

**Files:** Create `vnc/renderer.lua`. Modify `vnc/framebuffer.lua` (`draw_to` `:380-447`, `set_contrast`, `set_invert`, `set_scaling`, `resize`, `free`). Test: existing suites.

**Interfaces (produced):**
- `Renderer.new(opts) -> renderer` owns the canvas buffer, the dither buffer, the tone curve and the "filled for view" bookkeeping (`_canvas_bb`, `_dither_bb`, `_dither_ok`, `_filled`, `_lut` move here from `Remote`). `opts.canvas_mem` (optional `{ptr, bytes}`) makes it build its canvas with `SharedMem.bb` over that memory instead of `BB.new` (must fit `cw * ch * bpp`, else error).
- `renderer:render(plane, view: {x, y, scale}, mode, cw, ch, btype, dither, stale_rects|nil, all_stale) -> rects|"full"|nil` — exactly the body of today's `draw_to` from canvas (re)allocation through the dithered copy, minus the final blit into the screen; returns the canvas rects it changed.
- `renderer:canvas() -> BlitBuffer` (the dithered buffer when dithering, else the canvas).
- `renderer:set_tone(contrast, invert)`; `renderer:free()`.
- `Remote:draw_to(bb, cx, cy, cw, ch, dither)` keeps its signature and result: calls `self.renderer:render(...)`, then `bb:blitFrom(self.renderer:canvas(), cx, cy, 0, 0, cw, ch)`.

- [ ] **Step 1:** Refactor as above, nothing else.
- [ ] **Step 2:** `../tmp/run-tests.sh all` and `../tmp/arm/run.sh ui`: identical ok counts to before (record them in the commit body).
- [ ] **Step 3: Commit** `Remote: pixel work (scale, tone curve, dither) in a Renderer (no behaviour change)`.

### Task 5: Split `Session:_poll` into scheduling and one service step (no behaviour change)

**Files:** Modify `vnc/session.lua:790-841`. Test: existing suites.

**Interfaces (produced):** `Session:_service() -> status, rects|nil` — `_pump`, forced/held update release with their flushes, and taking `self.dirty` (returned, not handed to the app). `_poll` = timing + `_service()` + `app:on_framebuffer_dirty(rects)` + the reschedule logic.

- [ ] **Step 1:** Refactor.
- [ ] **Step 2:** `../tmp/run-tests.sh all`: identical ok counts.
- [ ] **Step 3: Commit** `Session: one poll tick's work as _service (no behaviour change)`.

### Task 6: Worker process plumbing

**Files:** Create `vnc/worker.lua`. Test `tools/proto_smoke.lua`.

**Interfaces (produced):**
- `Worker.spawn(name, main_fn, keep_fds) -> w|nil, err` — `runInSubProcess(fn, "bidi", true)` (double fork; reap the intermediate with `isSubProcessDone(pid, true)`). In the child before `main_fn(ctx)`: close every fd in `/proc/self/fd` (`lfs.dir`) except 0, 1, 2, its two pipe ends and `keep_fds`; `setpriority(PRIO_PROCESS, 0, Worker.NICE = 5)`; send `H <pid>`. `ctx = {read_fd, write_fd, send = function(line) end, recv = function(timeout) -> lines|nil (EOF) end}`; on EOF the child exits with `os.exit(0)` through the `runInSubProcess` path.
- Parent side `w`: `w:send(line)`, `w:poll() -> lines, eof` (non-blocking; `getNonBlockingReadSize`), `w:stop()` (`Q`, close pipes, SIGKILL after `Worker.KILL_AFTER = 2` s via a scheduled task, using the pid from `H`), `w.pid`.
- Message codec: one message per line, single spaces, decimal integers; a payload message `T <len>` is followed by exactly `<len>` raw bytes.
- Test hooks: `Worker._test_ignore_quit` (child keeps running after `Q`).

- [ ] **Step 1: Failing tests:**
  - `worker_round_trip`: an echo worker; `send("X 1 2")` → parent polls `"X 1 2"` within 1 s; first message is `H <pid>` with a live pid.
  - `workers_exit_when_the_ui_pipe_closes`: close the parent ends without `Q`; within 2 s `kill(pid, 0)` fails with ESRCH.
  - `hangup_kills_a_stuck_worker`: `_test_ignore_quit = true`; `stop()`; pid gone within `KILL_AFTER + 1` s.
  - `workers_keep_only_their_own_descriptors`: open a listening socket in the parent first; `/proc/<pid>/fd` of the worker lists exactly 0, 1, 2, its two pipes and `keep_fds`.
  - `workers_run_at_lower_priority`: `/proc/<pid>/stat` nice field `== 5`.
- [ ] **Step 2:** `../tmp/run-tests.sh proto` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `../tmp/run-tests.sh all` passes.
- [ ] **Step 5: Commit** `Worker: forked worker processes with a line protocol, descriptor hygiene and lower priority`.

### Task 7: Decode worker and scale worker

**Files:** Create `vnc/workers.lua` (both workers' main loops and `Workers.start(session)`). Modify `vnc/session.lua`: `Session.new` takes `opts.worker_processes`; then the remote plane is allocated in shared memory (`Remote.new(w, h, {shared = true})`, `Remote:resize` likewise, freed with `SharedMem.free`); in `_finish_connect(ok)`, when `ok and self.worker_processes`, `Workers.start(self)` before the callback (on failure: log, continue in-process). Test `tools/proto_smoke.lua`.

**Interfaces:**
- Consumes: `Worker.spawn` (Task 6), `SharedMem` (Task 3), `Renderer` (Task 4), `Session:_service` (Task 5).
- Produces: `Workers.start(session) -> link|nil, err`; `link.decode`, `link.scale` (Worker handles), `link.canvas_mem = {ptr, bytes}` with `bytes = Screen:getWidth() * Screen:getHeight() * 4` (any canvas ≤ the screen, any type ≤ 4 bytes/pixel, either rotation). A pipe `decode → scale` is created with `C.pipe` before the forks and passed in `keep_fds`.
- Messages:
  - UI → decode: `K <keysym> <0|1>`, `P <x> <y> <mask>`, `V <x> <y> <w> <h>` | `V -`, `F`, `N <what>`, `T <len>` + bytes (cut text), `S` (detached: stop reading), `R` (attached: resume), `Q`.
  - decode → UI: `H <pid>`, `Z <w> <h>` (desktop resized; exits after), `B` (bell), `E <message>` (error; exits after).
  - decode → scale: `D <x> <y> <w> <h> [...]` (plane rects fully written).
  - UI → scale: `G <id> <scale> <view_x> <view_y> <cw> <ch> <btype> <dither 0|1> <mode smooth|sharp> <contrast> <invert 0|1>` (view; latest wins: the worker drains all pending `G` and uses the newest), `Q`.
  - scale → UI: `H <pid>`, `C <id> full` | `C <id> <x> <y> <w> <h> [...]` (canvas rects of view `<id>` written).
- Decode worker loop: `socket.select({sock, cmd})`, timeout `Session.POLL_INTERVAL_BUSY` while in an update or holding input, else `Session.POLL_INTERVAL`; apply all complete commands through the session's own methods; unless `S`, `session:_service()` and forward its rects as `D`; `Session.MAX_CPU_PER_TICK = Workers.DECODE_CPU_PER_TICK = 0.05` in this process. The session's app is replaced by a forwarder (`on_remote_resized` → `Z`, `on_bell` → `B`), its `on_state` error → `E`.
- Scale worker loop: blocks in `select` on its two inputs; accumulates `D` rects as stale; on a new `G` (or with stale rects) calls `renderer:render(plane, view, ...)` with `canvas_mem`, then sends `C`.

- [ ] **Step 1: Failing tests** (`tools/mock_vnc_server.py` over TCP, `worker_processes = true`, the test drives the UI side's polls):
  - `workers_decode_and_scale_into_shared_memory`: mock `--pattern quadrants`; send `G` for scale 0.5 into a BB8 canvas; after `C <id> full` the shared canvas equals `Scaler.render` of the same pattern (four probe points); the UI's `session.sock == nil`.
  - `latest_view_wins`: send 10 `G` messages in one write; exactly one `C full`, carrying the last id.
  - `decode_rects_reach_the_canvas`: mock changes one quadrant; a `C <id> x y w h` arrives covering exactly `canvas_rect_for` of that quadrant.
  - `worker_death_is_a_session_error`: SIGKILL the decode worker; within 2 s of UI polls `get_state() == "error"`, `on_state("error")` once, the scale worker has exited too.
  - `workers_off_is_in_process`: `worker_processes = false` → no workers, socket kept.
- [ ] **Step 2:** `../tmp/run-tests.sh proto` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `../tmp/run-tests.sh all` passes.
- [ ] **Step 5: Commit** `Workers: a decode worker and a scale worker fed through shared memory after the handshake`.

### Task 8: The UI side — session proxy, viewer paint, resize → reconnect

**Files:** Modify `vnc/session.lua` (`send_key`, `send_pointer`, `send_cut_text`, `set_view_area`, `request_full_update`, `note_input`, `attach`, `detach`, `hangup`, `disconnect`, `_live`, `poll_soon`, `_poll`, `_teardown_connection`), `vnc/framebuffer.lua` (`Remote:draw_to` in worker mode), `vnc/app.lua` (`on_framebuffer_dirty` accepts canvas rects). Test `tools/proto_smoke.lua`, `tools/ui_smoke.lua`.

**Behaviour while `session.workers`:**
- Input methods send their message and return (`_input_gap` runs in the decode worker).
- `attach(app)`: schedule the poll, send `R` then `F`. `detach()`: unschedule, send `S`.
- `_poll` every `Workers.UI_POLL = 0.01` s: drain both workers; all `C` messages of the current view id since the last tick become one `app:on_framebuffer_dirty_canvas(rects)` (union per tick; `full` → one full-canvas dirty); `C` of an older id is dropped; `B` → `app:on_bell()`; `E msg` or EOF of either → `link:stop()`, `session.workers = nil`, `_fail(msg or "worker process exited")`; `Z w h` → stop, teardown, `self:connect(cb)` where `cb` on success re-attaches the current app and calls `app:on_remote_resized(w, h)`, on failure `_fail(err)`.
- `Remote:draw_to` in worker mode: if the view (scale, view x/y, canvas size, btype, dither, mode, contrast, invert) differs from the last one sent, send `G` with a new id; blit the shared canvas (`SharedMem.bb(canvas_mem, cw, ch, btype)`) at `cx, cy`; never scale on the UI thread. Geometry methods unchanged.
- `ViewerApp:on_framebuffer_dirty_canvas(rects)`: like `on_framebuffer_dirty` but rects are already canvas rects (the `_modal_above` / `_needs_flash` rules apply unchanged).
- `hangup` / `disconnect` / `_teardown_connection` call `link:stop()` first.

- [ ] **Step 1: Failing tests:**
  - `worker_viewer_shows_the_remote` (ui_smoke, mock, `worker_processes = true`): open the real viewer via `connect_profile`; after polls the screen probe equals the pattern; a canvas tap → mock logs a PointerEvent at the mapped position.
  - `pan_does_not_scale_on_the_ui_thread` (ui_smoke): wrap `Scaler.render` in the UI process with a counter; pan and zoom the viewer 10 times; counter `== 0`; after polls the screen shows the panned view.
  - `closing_a_dialog_mid_render_leaves_no_remnant` (ui_smoke): show a ConfirmBox over the viewer, send a `G` (zoom), close the box before the `C` arrives; after the `C` the screen region the box covered equals the canvas.
  - `detached_workers_read_nothing_and_resync_on_attach` (proto_smoke): attach, detach; mock changes its pattern; no `C` for 1 s; attach → full update, canvas matches the new pattern.
  - `keys_reach_the_server_during_a_long_decode` (proto_smoke): mock streams a large Raw update slowly; 5 keys sent meanwhile all appear in the mock log, in order, before the update completes.
  - `desktop_resize_reconnects` (proto_smoke): mock resizes its desktop; the session reconnects by itself, `remote:get_size()` is the new size, canvas matches the pattern, `on_remote_resized` fired once.
  - Every existing live-connection session test in `tools/proto_smoke.lua` also runs with `worker_processes = true` (a loop over both modes); tests inspecting in-process internals (`session.proto`, the rx buffer) stay in-process only, listed in a comment.
- [ ] **Step 2:** `../tmp/run-tests.sh proto ui` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `../tmp/run-tests.sh all` passes.
- [ ] **Step 5: Commit** `Viewer: in worker mode the UI process only blits the workers' canvas and forwards input; a desktop resize reconnects`.

### Task 9: Setting, menu switch, wiring, docs

**Files:** Modify `vnc/settings.lua` (DEFAULTS `worker_processes = false`, boolean `SETTING_CHECKS`), `vnc/menu.lua` (switch after "Match orientation to the remote screen", `:239`; text `_("Decode in background processes")`, help `_("Faster on multi-core readers. Applies from the next connection.")`), `main.lua:359` (`Session.new{ profile = profile, worker_processes = <setting> }`), `README.md` (one paragraph), `NOTES.txt` (a "Worker processes" section: the layout and why, the message table from Task 7, resize → reconnect, what stays in-process). Test `tools/ui_smoke.lua`.

- [ ] **Step 1: Failing tests:** `worker_switch_round_trips` (toggle flips and flushes `settings.worker_processes`, mark `"✓"`/`"-"`); `new_connections_use_the_setting` (setting on → `connect_profile`'s session has `worker_processes == true`, benchmark sessions `false`); menu-order test updated.
- [ ] **Step 2:** `../tmp/run-tests.sh ui` — FAIL.
- [ ] **Step 3:** Implement and write the docs.
- [ ] **Step 4:** `../tmp/run-tests.sh all` and `../tmp/arm/run.sh proto ui server40` pass.
- [ ] **Step 5: Commit** `Settings: Decode in background processes (off by default)`.

### Task 10: Live end-to-end against x11vnc in both modes, with numbers

**Files:** `../tmp/e2e/e2e.lua`, `../tmp/e2e/runall.sh` (outside git): `MODE=workers|inline` sets `worker_processes`.

- [ ] **Step 1:** `cd ../tmp/e2e && MODE=inline ./runall.sh` and `MODE=workers ./runall.sh` (image `vnce2e:latest`; x11vnc stopped with `x11vnc -R stop`, never `pkill`; containers removed at the end).
- [ ] **Step 2:** The same checks pass in both modes (server-to-client clipboard is a known x11vnc failure). Every difference is a bug: fix it in the owning task's file with a regression test in the suites, commit.
- [ ] **Step 3:** Write `../tmp/e2e/logs/final/mode_compare.txt`: per mode, for full-screen Hextile, ZRLE and Tight updates and for a 10-step pan: time from request to the last canvas rect painted, the longest UI poll gap during it, and the workers' VmRSS (`/proc/<pid>/status`). Expected in worker mode: UI poll gaps < 30 ms during decode and pan.

### Task 11: Device check (the user, on the reader)

- [ ] **Step 1:** `./sync.sh`; Developer options → Enable debug logging; "Decode in background processes" on; connect; type a sentence, scroll, pan/zoom, move a window, one full-screen change.
- [ ] **Step 2:** Same with the switch off; `./sync.sh` brings `crash.log` back.
- [ ] **Step 3:** Compare `vnc-timing` (`update wall_ms`, `paint ms`, `poll gap`) and KOReader's `hold timer tripped` lines near key presses between the two runs. Remaining poll gaps in worker mode are the e-ink refresh itself and are the next target (refresh scheduling while typing, `DynamicUpdate`).
