# Decoder Process, Invert Button, Toolbar Anchor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take network receive + decoding off KOReader's UI thread (a forked decoder process on the dual-core reader), add an "Invert" toolbar button, and make a collapsed toolbar return to its corner.

**Architecture:** The parent does Wi-Fi, connect and the RFB handshake exactly as today. Right after the session is connected it forks (KOReader's `ffiutil.runInSubProcess`): the child inherits the socket, the protocol state and a remote plane that lives in `MAP_SHARED` memory, and from then on reads, decodes into that plane and reports finished rectangles over a pipe. The parent's `Session` turns into a proxy: its public methods forward input over the pipe, its poll task only reads pipe messages and hands rects to the unchanged viewer. A remote desktop resize makes the child exit and the parent reconnect.

**Tech Stack:** Lua 5.1 / LuaJIT FFI inside KOReader; `ffi/util` (`runInSubProcess`, `getNonBlockingReadSize`), `ffi/posix_h` (`mmap`, `pipe`, `read`, `write`, `close`, `kill`), LuaSocket `socket.select`, `libs/libkoreader-lfs`.

**Spec:** this plan (agreed in conversation 2026-11-12). Decisions fixed by the user: the plugin's own VNC server (`vnc/server.lua`, `vnc/rfbserver.lua`, `vnc/serverenc.lua`, `vnc/servermenu.lua`) is not touched; a remote resize is handled by reconnecting, nothing more elaborate; the target is a 2 x 1 GHz, 1 GB, 1264x1680 PocketBook.

## Global Constraints

- Pure Lua + LuaJIT FFI: no C component, no build step.
- No file under the plugin's server half changes (`vnc/server.lua`, `vnc/rfbserver.lua`, `vnc/serverenc.lua`, `vnc/servermenu.lua`).
- The decoder process is a setting, `decoder_process`, default `false`; with it off, behaviour is byte-for-byte today's (all existing tests pass unchanged).
- The picture benchmark (`vnc/benchmark.lua`) always uses in-process sessions.
- Commit messages: plain, descriptive, in the repo's style (`Area: what changed`); no assistant names, no Co-Authored-By, no signatures.
- Tests: `P=<worktree> SUF=<suffix> ../tmp/run-tests.sh all` must exit 0 after every task; at the end also `tmp/arm/run.sh proto ui server40` (ARM LuaJIT under qemu).
- Never `git stash` (the stash list is shared across worktrees).

## Review Focus

1. The decoder process dies or hangs (crash, OOM, bug) → the viewer shows its normal reconnect box within 2 s, never a frozen picture. Test: `child_death_is_a_session_error` (Task 5).
2. KOReader exits, or the session is closed, while the child is mid-update → the child exits (pipe EOF / `Q`, then SIGKILL after 2 s); no orphan keeps the TCP connection or Wi-Fi up. Tests: `child_exits_when_the_parent_pipe_closes`, `hangup_kills_a_stuck_child` (Task 5).
3. The child inherits KOReader's other descriptors (the plugin server's listening socket, the framebuffer, input devices) → it closes all but its own; stopping and restarting the plugin's server while a viewer is connected still binds the port. Test: `child_keeps_only_its_own_descriptors` (Task 5).
4. Viewer closed with keep-alive (detach) then reopened → the child stops reading while detached and the reopened viewer gets a full update. Test: `detached_child_reads_nothing_and_resyncs_on_attach` (Task 6).
5. Keys typed while a large update is decoding → reach the server in order, within one child tick (≤ 50 ms of decode). Test: `keys_reach_the_server_during_a_long_decode` (Task 6).

---

### Task 1: A collapsed toolbar returns to the spot it was anchored to

Bug: `ViewerApp:set_toolbar_collapsed` (`vnc/app.lua:183-200`) relayouts with `at = old top-left corner`. Expanding a round button anchored top right clamps the wide bar leftwards and stores that clamped corner as `toolbar_pos`; collapsing then puts the round button at the wide bar's left edge instead of back top right.

**Files:**
- Modify: `vnc/app.lua:193-198`
- Test: `tools/ui_smoke.lua`

**Interfaces:** none new. `Toolbar:relayout()` with no argument places by the stored fractional `toolbar_pos` (`vnc/toolbar.lua:243`).

- [ ] **Step 1: Write the failing tests** in `tools/ui_smoke.lua`, next to the existing toolbar collapse tests:
  - `collapsing_a_bar_expanded_from_the_top_right_returns_it_there`: `settings.toolbar_pos = {x = 1, y = 0}`, `toolbar_collapsed = true`, open the viewer; `set_toolbar_collapsed(false)` then `(true)`. Assert the round button's `dimen.x + dimen.w == Screen:getWidth() - Size.margin.default` and `dimen.y == Size.margin.default`, and `settings.toolbar_pos.x == 1`, `settings.toolbar_pos.y == 0`.
  - `toggling_the_bar_keeps_a_dragged_position`: `toolbar_pos = {x = 0.3, y = 0.5}`; expand, collapse, expand. Assert `toolbar_pos` is still exactly `{x = 0.3, y = 0.5}`.
- [ ] **Step 2: Run** `../tmp/run-tests.sh ui` — expected: the first test FAILS (round button left of the right edge).
- [ ] **Step 3: Fix** — in `set_toolbar_collapsed`, call `bar:relayout()` (no `at`) so the stored fraction is used and not overwritten. Keep the dirty-area repaint of `old:combine(bar.dimen)`.
- [ ] **Step 4: Run** `../tmp/run-tests.sh ui` — expected: all pass. If an existing test asserted the old corner-keeping behaviour, update it to the anchored behaviour and say so in the commit message.
- [ ] **Step 5: Commit** — `Toolbar: collapsing returns the button to where it was anchored (an expanded bar clamped leftwards no longer moves it)`.

### Task 2: Invert button for the remote picture

Inverts only the remote picture as drawn (toolbar, keyboard and dialogs stay as they are), like contrast: the plane keeps the server's pixels, the tone curve does the work.

**Files:**
- Modify: `vnc/scaler.lua:553` (`Scaler.contrast_lut`), `vnc/framebuffer.lua` (new `Remote:set_invert`), `vnc/settings.lua` (DEFAULTS, `SETTING_CHECKS`, `TOOLBAR_BUTTONS`, `TOOLBAR_PINNABLE`), `vnc/toolbar.lua` (`IDS`, `TIPS`, `specs`), `vnc/app.lua` (near `set_contrast`, `:491`, `:2525`), `vnc/menu.lua` (the "Toolbar buttons…" list picks the new id up from `Settings`; verify), `README.md` (toolbar section, one line)
- Create: `icons/invert.svg` (a circle, left half black, right half white, same canvas/stroke as `icons/scroll-lock.svg`)
- Test: `tools/ui_smoke.lua`

**Interfaces:**
- Produces: `Scaler.contrast_lut(f: number, invert: boolean|nil) -> table|nil` — nil only when `f == 1 and not invert`; inverted curve is `255 - contrast(x)`. `Remote:set_invert(on: boolean) -> boolean` (true when it changed; marks the whole canvas stale). Setting `remote_invert` (boolean, default `false`). Toolbar id `"invert"`, placed right after `"contrast"`, default shown, pinnable, tip `_("Invert the remote picture")`. `ViewerApp:toggle_invert()`.

- [ ] **Step 1: Write the failing tests** in `tools/ui_smoke.lua`:
  - `contrast_lut_inverts`: `Scaler.contrast_lut(1, true).g[0] == 255`, `.g[255] == 0`, `.w[0] == 255 * 256`; `Scaler.contrast_lut(1, false) == nil`; `Scaler.contrast_lut(2, true).g[x] == 255 - Scaler.contrast_lut(2).g[x]` for x = 0, 64, 200.
  - `invert_button_inverts_the_picture_and_persists`: open a viewer on a plane filled with RGB (10, 10, 10); tap the toolbar's `invert` button through the widget stack; paint; probe a canvas pixel: grey value `245`. Assert `settings.remote_invert == true` and the button is drawn selected (`preselect`). Tap again: pixel back to `10`. Reopen a viewer: the stored value is applied.
  - `invert_is_a_toolbar_button`: `Toolbar.IDS` contains `"invert"` right after `"contrast"`; `Settings.TOOLBAR_BUTTONS.invert == true`; it appears in `TOOLBAR_PINNABLE` right after `"contrast"`.
- [ ] **Step 2: Run** `../tmp/run-tests.sh ui` — expected: FAIL.
- [ ] **Step 3: Implement** the interfaces above. `remote_invert` gets a `SETTING_CHECKS` boolean entry (a non-boolean loads as `false`). The viewer applies `remote_invert` wherever it applies `remote_contrast` today (`vnc/app.lua:491`). The button uses `selected = settings.remote_invert` so it is drawn inverted while on. Repaint after a toggle with the same refresh `set_contrast` uses.
- [ ] **Step 4: Run** `../tmp/run-tests.sh all` — expected: all pass (update the toolbar-order / menu-order tests that enumerate buttons).
- [ ] **Step 5: Commit** — `Toolbar: Invert button (the remote picture drawn inverted; stored as remote_invert)`.

### Task 3: Remote plane in shared memory

**Files:**
- Create: `vnc/sharedplane.lua`
- Modify: `vnc/framebuffer.lua:39-60` (`Remote.new`), `:168-185` (`Remote:resize`), and `Remote:free` if present
- Test: `tools/proto_smoke.lua`

**Interfaces:**
- Produces: `SharedPlane.new(w: integer, h: integer) -> BlitBuffer` — a `TYPE_BBRGB24` BB over `mmap(nil, w*h*3, PROT_READ|PROT_WRITE, MAP_SHARED|MAP_ANONYMOUS, -1, 0)`, stride `w*3`; errors with a message when mmap fails. `SharedPlane.free(bb)` — `munmap`s it (BB `:free()` must not be used on it). `Remote.new(w, h, opts)` and `Remote:resize(w, h)` take `opts.shared == true` (remembered as `self.shared`) to allocate through `SharedPlane`; without it, unchanged.
- Note: `ffi/posix_h` may lack `MAP_ANONYMOUS`/`munmap`; `pcall(ffi.cdef, ...)` what is missing (Linux values: `MAP_ANONYMOUS = 0x20`, `PROT_READ = 1`, `PROT_WRITE = 2`, `MAP_SHARED = 1`; check `ffi/posix_h.lua` first).

- [ ] **Step 1: Write the failing tests:**
  - `shared_plane_is_shared_across_fork`: `SharedPlane.new(64, 32)`; `runInSubProcess` a child that writes RGB (1, 2, 3) at (5, 7) and exits; wait with `isSubProcessDone(pid, true)`; parent reads `(1, 2, 3)` at (5, 7).
  - `shared_remote_resize_reallocates_shared`: `Remote.new(64, 32, {shared = true})`, `resize(128, 16)`; plane is 128x16, `remote.shared == true`, the fork check above passes on the new plane.
- [ ] **Step 2: Run** `../tmp/run-tests.sh proto` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `../tmp/run-tests.sh all` — pass.
- [ ] **Step 5: Commit** — `Remote: optional plane in shared memory (for a decoder process)`.

### Task 4: Split `Session:_poll` into scheduling and one service step (no behaviour change)

**Files:**
- Modify: `vnc/session.lua:790-841`
- Test: existing suites only

**Interfaces:**
- Produces: `Session:_service() -> status: string, rects: table|nil` — everything `_poll` does between the timing bookkeeping and the rescheduling: `_pump`, forced/held update release with their flushes, and taking `self.dirty` (returned, not handed to the app). On `"error"`/`"done"` it returns that status. `_poll` = timing + `_service()` + `self.app:on_framebuffer_dirty(rects)` when rects + the existing reschedule logic.

- [ ] **Step 1: Refactor** as above, no other change.
- [ ] **Step 2: Run** `../tmp/run-tests.sh all` and `../tmp/arm/run.sh proto` — expected: identical ok counts to before (record them in the commit message body).
- [ ] **Step 3: Commit** — `Session: one poll tick's work as _service (no behaviour change)`.

### Task 5: The decoder process — fork, pipe protocol, child loop, lifecycle

**Files:**
- Create: `vnc/decoderproc.lua` (both sides: `DecoderProc.start(session)` in the parent, the child loop, the message codec)
- Modify: `vnc/session.lua` — `Session.new` takes `opts.decoder_process` (boolean); the remote is created with `{shared = true}` when it is set; in `_finish_connect(ok)` when `ok and self.decoder_process`, call `DecoderProc.start(self)` before the callback; when start fails, log it and continue in-process.
- Test: `tools/proto_smoke.lua` (real `tools/mock_vnc_server.py` over TCP, like the existing session tests)

**Interfaces:**
- Produces: `DecoderProc.start(session) -> link|nil, err`. `link` (stored as `session.child`) has `:send(cmd: string)`, `:poll() -> list of messages`, `:stop()` (send `Q`, close pipes, SIGKILL after `DecoderProc.KILL_AFTER = 2` s via a scheduled task), `.pid`.
- Pipe protocol, one message per line, fields separated by single spaces, integers in decimal:
  - parent → child: `K <keysym> <0|1>`, `P <x> <y> <mask>`, `V <x> <y> <w> <h>` or `V -`, `F` (full update), `N <what>` (note_input), `T <len>` followed by exactly `<len>` raw bytes (cut text), `S` (stop reading: detached), `R` (resume: attached), `Q` (quit).
  - child → parent: `H <pid>` (first message), `D <x> <y> <w> <h> [<x> <y> <w> <h> ...]` (rects fully written to the plane), `Z <w> <h>` (desktop resized; the child exits after it), `B` (bell), `E <message to end of line>` (session error; the child exits after it).
- Child side: inside the `runInSubProcess(func, "bidi", true)` child (double fork; the intermediate pid is reaped right away with `isSubProcessDone(pid, true)`):
  1. close every fd in `/proc/self/fd` (via `lfs.dir`) except 0, 1, 2, the socket's fd and its two pipe fds;
  2. replace `session.app` with a forwarder: `on_framebuffer_dirty(rects)` → `D`, `on_remote_resized(w, h)` → `Z` then exit, `on_bell()` → `B`; `session.on_state` → on `"error"` send `E` then exit;
  3. loop: `socket.select({sock, cmd_pipe_wrapper}, nil, timeout)` where `timeout` is `Session.POLL_INTERVAL_BUSY` while in an update or holding, else `Session.POLL_INTERVAL`; apply every complete command (by calling the session's own `send_key` / `send_pointer` / `set_view_area` / `request_full_update` / `note_input` / `send_cut_text`); unless stopped (`S`), run `session:_service()` and send its rects; on pipe EOF or `Q`, close the socket and `os.exit(0)` through the `runInSubProcess` path.
  4. `Session.MAX_CPU_PER_TICK` in the child is `DecoderProc.CHILD_CPU_PER_TICK = 0.05`.
- Parent side after a successful start: close the parent's copy of the socket fd (`C.close(fd)`; drop `self.sock` without LuaSocket's `close` running a shutdown), free `self.proto`, keep `self.remote` (its plane is the shared one), keep `state = "connected"`.

- [ ] **Step 1: Write the failing tests** in `tools/proto_smoke.lua` (each with a mock server, `decoder_process = true`, parent poll driven by the test the way the existing session tests drive `_poll`):
  - `child_decodes_into_the_shared_plane`: mock `--pattern quadrants`; after the first `D` messages the parent's `remote:get_plane()` pixels equal the mock's pattern at four probe points; the parent's `session.sock == nil`.
  - `child_keys_and_pointer_reach_the_server`: `send_key(0x61, true/false)`, `send_pointer(10, 20, 1)`; the mock's log shows `INPUT KeyEvent` and `INPUT PointerEvent` with those values, in order.
  - `child_death_is_a_session_error`: `kill(child_pid, SIGKILL)`; within 2 s of parent polls `session:get_state() == "error"` and `on_state` fired once with `"error"`.
  - `child_exits_when_the_parent_pipe_closes`: close the parent's pipe ends without `Q`; within 2 s `kill(pid, 0)` fails (ESRCH).
  - `hangup_kills_a_stuck_child`: make the child ignore `Q` (test hook `DecoderProc._test_ignore_quit = true` read in the child); `session:hangup()`; within `KILL_AFTER + 1` s the pid is gone.
  - `child_keeps_only_its_own_descriptors`: open an extra listening socket in the parent before connecting; the child reports (test hook message, or `/proc/<pid>/fd` from the parent) exactly 0, 1, 2, its socket and two pipes.
  - `decoder_process_off_is_in_process`: `decoder_process = false` → no child, `session.child == nil`, socket kept.
- [ ] **Step 2: Run** `../tmp/run-tests.sh proto` — FAIL.
- [ ] **Step 3: Implement** `vnc/decoderproc.lua` and the `Session` changes above; the parent-side proxying of the public methods is Task 6, so for these tests the parent may call `link:send` directly where needed.
- [ ] **Step 4: Run** `../tmp/run-tests.sh all` — pass.
- [ ] **Step 5: Commit** — `Decoder process: after the handshake a forked child reads and decodes into a shared plane and reports rects over a pipe`.

### Task 6: The parent `Session` as a proxy; resize → reconnect; detach/attach

**Files:**
- Modify: `vnc/session.lua` — `send_key`, `send_pointer`, `send_cut_text`, `set_view_area`, `request_full_update`, `note_input`, `attach`, `detach`, `hangup`, `disconnect`, `_live`, `poll_soon`, `_poll`, `_teardown_connection`
- Test: `tools/proto_smoke.lua`, `tools/ui_smoke.lua`

**Interfaces:**
- Consumes: `session.child` (`link`) from Task 5.
- Behaviour while `self.child`:
  - the input methods send their command and return (`send_key` still runs `_input_gap` in the child, not the parent);
  - `attach(app)` sets `app`, schedules the poll and sends `R` then `F`; `detach()` unschedules and sends `S`;
  - `_poll` reads `link:poll()`: `D` → `self.remote:mark_dirty(...)` for each rect, then one `app:on_framebuffer_dirty(rects)`; `B` → `app:on_bell()`; `E msg` or pipe EOF → `link:stop()`, `self.child = nil`, then the existing `_fail(msg or "decoder process exited")`; `Z w h` → `link:stop()`, `self.child = nil`, teardown, and `self:connect(cb)` again where `cb` on success re-attaches the current app and calls `app:on_remote_resized(w, h)` (the new connection's `on_connected` already resizes the shared plane through `Remote:resize`), on failure `_fail(err)`;
  - the parent poll interval is `DecoderProc.PARENT_POLL = 0.02` s (pipe reads are cheap);
  - `hangup` / `disconnect` / `_teardown_connection` call `link:stop()` first.

- [ ] **Step 1: Write the failing tests:**
  - `proxy_viewer_shows_the_remote` (ui_smoke, mock server, `decoder_process = true`): open the real viewer through `connect_profile`; after polls the canvas probe equals the mock's pattern; tap on the canvas → mock logs a PointerEvent at the mapped remote position.
  - `detached_child_reads_nothing_and_resyncs_on_attach` (proto_smoke): attach, detach; the mock changes its pattern; for 1 s the parent receives no `D`; attach → a full update arrives and the plane matches the new pattern.
  - `keys_reach_the_server_during_a_long_decode` (proto_smoke): mock sends a large Raw update (`--pattern noise` 1920x1080 or the largest the mock supports) slowly; while it is in flight send 5 keys; the mock logs all 5 KeyEvents, in order, before the update has been fully sent.
  - `desktop_resize_reconnects` (proto_smoke): mock resizes its desktop (its DesktopSize option); the session reconnects on its own, `remote:get_size()` is the new size, the plane matches the mock's pattern, `app:on_remote_resized` fired once.
  - Run every existing session test in `tools/proto_smoke.lua` a second time with `decoder_process = true` where it uses a live connection (a loop over both modes); tests that inspect in-process internals (`session.proto`, the rx buffer) stay in-process only, listed in a comment.
- [ ] **Step 2: Run** `../tmp/run-tests.sh proto ui` — FAIL.
- [ ] **Step 3: Implement** the behaviour above.
- [ ] **Step 4: Run** `../tmp/run-tests.sh all` — pass.
- [ ] **Step 5: Commit** — `Session: with a decoder process the session proxies input and repaints over the pipe; a desktop resize reconnects`.

### Task 7: Setting, menu switch, wiring; docs

**Files:**
- Modify: `vnc/settings.lua` (DEFAULTS `decoder_process = false`, boolean `SETTING_CHECKS`), `vnc/menu.lua` (a switch after "Match orientation to the remote screen", `vnc/menu.lua:239`, text `_("Decode in a separate process")`, help line `_("Faster on multi-core readers. Applies from the next connection.")`), `main.lua:359` (`Session.new{ profile = profile, decoder_process = <setting> }`), `README.md` (one paragraph in the settings section), `NOTES.txt` (a "Decoder process" section: the design, the pipe protocol table from Task 5, resize → reconnect, what stays in-process: benchmark, plugin server)
- Test: `tools/ui_smoke.lua`

- [ ] **Step 1: Write the failing tests:**
  - `decoder_process_switch_round_trips`: toggling the menu switch flips `settings.decoder_process`, flushes, and the switch's mark follows (`"✓"`/`"-"`, like `match_orientation`).
  - `new_connections_use_the_setting`: with the setting on, `connect_profile` creates a session with `decoder_process == true`; the benchmark's sessions have it `false` with the setting on.
  - Update the menu-order test for the new item.
- [ ] **Step 2: Run** `../tmp/run-tests.sh ui` — FAIL.
- [ ] **Step 3: Implement** and write the docs.
- [ ] **Step 4: Run** `../tmp/run-tests.sh all` and `../tmp/arm/run.sh proto ui server40` — pass.
- [ ] **Step 5: Commit** — `Settings: Decode in a separate process (off by default)`.

### Task 8: Live end-to-end against x11vnc in both modes

**Files:**
- Modify: `../tmp/e2e/e2e.lua`, `../tmp/e2e/runall.sh` (outside git): a `MODE=process|inline` switch that sets `decoder_process`.

- [ ] **Step 1:** Run `cd ../tmp/e2e && MODE=inline ./runall.sh` and `MODE=process ./runall.sh` (image `vnce2e:latest`; stop x11vnc with `x11vnc -R stop`, never `pkill`; remove containers at the end).
- [ ] **Step 2:** Expected: the same checks pass in both modes (the server-to-client clipboard check is a known x11vnc failure). Every difference is a bug: fix it in the owning task's file with a regression test in the suites, commit.
- [ ] **Step 3:** Add a timing comparison: for the Hextile and ZRLE full-screen cases, log per mode the time from the update request to the last `D` handled by the parent, and the longest parent poll gap during it. Expected: parent poll gaps in `process` mode stay under 60 ms while an update decodes. Save the table to `../tmp/e2e/logs/final/mode_compare.txt`.

### Task 9: Device check (the user, on the reader)

- [ ] **Step 1:** `./sync.sh`; Developer options → Enable debug logging; switch "Decode in a separate process" on; connect; type a sentence, scroll, move a window, one full-screen change.
- [ ] **Step 2:** Same with the switch off. `./sync.sh` again (brings `crash.log` back).
- [ ] **Step 3:** Compare `vnc-timing` lines of both runs (`update ... wall_ms`, `poll gap`), and check KOReader's `hold timer tripped` lines near key presses. Expected: fewer/shorter poll gaps and no false holds while typing in process mode; if poll gaps remain, they come from the e-ink refresh and are the next thing to fix.
