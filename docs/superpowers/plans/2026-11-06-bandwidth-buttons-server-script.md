# Lower bandwidth, page buttons, PC server script — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Viewer colour-depth + Tight JPEG/compression options, correct page-button keys plus an optional mouse-wheel mode, and a stdlib-only `tools/vnc-server.py` with an optional on-screen frame.

**Architecture:** The client pixel format becomes a per-connection value (`PxFmt.for_depth`) passed into `Protocol.new` and into every decoder's `ctx`; decoders read PIXEL/CPIXEL through it and expand to the unchanged RGB24 plane. Settings/menu/session carry the new options; changes apply on the next connection (no in-flight format mismatch). The PC script is one Python file with pure, unit-testable helpers and a ctypes Xlib frame.

**Tech Stack:** Lua 5.1 / LuaJIT FFI (KOReader), Python 3 stdlib (mock server, PC script, ctypes/libX11).

**Spec:** `docs/superpowers/specs/2026-11-06-bandwidth-buttons-server-script-design.md` — read it first.

## Global Constraints

- Pure Lua + LuaJIT FFI, no build step; follow existing LDoc/module style.
- 24-bit (default) behaviour and performance unchanged; 24-bit fast paths keep `ffi.copy`.
- Low-depth hot paths use FFI pointers, not per-pixel `string:byte()`.
- New settings live in `Settings.DEFAULTS` (`vnc/settings.lua:30`); "off" is stored as `false`.
- `tools/vnc-server.py`: Python 3 stdlib only, no venv, relative paths only.
- No author names/brands in commits or source.
- Test runtime: KOReader's LuaJIT (Linux build in `../tmp/koreader`). Run suites with `../tmp/run-tests.sh [proto|ui|server|py|all]` from the repo root (wraps the `NOTES.txt:336-400` commands). Never claim a test passed without running it.

## Review Focus

1. A settings file written by the current version (no new keys) → defaults apply (24-bit, keys mode, JPEG/compression off). Test in Task 3.
2. 8/16-bit with every encoding incl. ZRLE/TRLE CPIXEL (= PIXEL size below 32 bpp) and Tight TPIXEL → pixel-exact. Tests in Task 1.
3. Page buttons in wheel mode before any tap → scroll at remote centre, not (0,0). Test in Task 5.
4. Holding a page button (`onKeyRepeat`) in wheel mode keeps scrolling; in keys mode keeps sending key-down. Test in Task 5.
5. `vnc-server.py -f` when libX11/display is unavailable → one warning line, server still starts; area touching the monitor edge → that frame side omitted. Tests in Task 6.

---

### Task 1: Depth-aware pixel format and decoders

**Files:**
- Modify: `vnc/pxfmt.lua`, `vnc/encodings.lua`, `vnc/protocol.lua:30-60,188-197,255-270`
- Test: `tools/proto_smoke.lua`

**Interfaces:**
- Produces:
  - `PxFmt.for_depth(depth: 24|16|8) -> fmt` — table with the 10 PIXEL_FORMAT fields plus `bytes` (PIXEL size: 4/2/1) and `cbytes` (CPIXEL/TPIXEL size: 3/2/1). 24 → existing `PxFmt.PIXEL_FORMAT` values; 16 → bpp 16, depth 16, LE, max 31/63/31, shifts 11/5/0; 8 → bpp 8, depth 8, max 7/7/3, shifts 0/3/6. Unknown depth → 24.
  - `PxFmt.to_rgb24(fmt, src: const uint8_t*, count, dst: uint8_t*, src_size)` — converts `count` wire pixels of `src_size` bytes (`fmt.bytes` or `fmt.cbytes`) into packed RGB24. Channel expansion `floor(v * 255 / max + 0.5)` (must match the mock's codec — check `PixelCodec` in `tools/mock_vnc_server.py` and use its exact inverse rule).
  - `PxFmt.unpack(fmt, s: string, off, size) -> r, g, b` for single pixels.
  - `Protocol.new{ ..., pixel_format = fmt }` (default `PxFmt.for_depth(24)`); `_set_pixel_format` sends it; decode `ctx.fmt = self.pixel_format`.
- Every decoder replaces fixed 4/3-byte reads with `ctx.fmt.bytes`/`ctx.fmt.cbytes`. When `fmt.bpp == 32` keep today's code paths byte-for-byte.

- [ ] **Step 1: Write failing tests** in `proto_smoke.lua`: for `depth` in {16, 8} and encoding in {raw, copyrect, rre, hextile, trle, zrle, tight} (whatever names `encoding_case` already uses), a case `enc_<name>_<depth>` that passes `pixel_format = PxFmt.for_depth(depth)` and expects every pixel equal to the pattern pixel quantized then expanded with the mock's rule. Also `pxfmt_wire_<depth>`: the mock's logged `SetPixelFormat bpp=<16|8> ... shifts` match. (Extend `encoding_case`/`run_case` with an optional `pixel_format` pass-through.)
- [ ] **Step 2: Run** `proto_smoke.lua` per NOTES.txt:336 — expect the new cases FAIL, existing ones PASS.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run** `proto_smoke.lua` — all PASS, incl. every existing 24-bit case unchanged. Also run `server_smoke.lua` (server shares `pxfmt.lua`) — all PASS.
- [ ] **Step 5: Commit** `feat(pxfmt): 16- and 8-bit client pixel formats in every decoder`

### Task 2: Tight JPEG quality / compression pseudo-encodings

**Files:**
- Modify: `vnc/encodings.lua:41-66`
- Test: `tools/proto_smoke.lua`

**Interfaces:**
- Produces: `Encodings.order(enable_tight: boolean, opts?: {jpeg_quality: false|0..9, compress_level: false|0..9}) -> table`. Returns a new table each call (never mutate `ORDER_*`). When `enable_tight` and a value is a number, append `-32 + jpeg_quality` and/or `-256 + compress_level` after `DESKTOP_SIZE`. When `enable_tight` is false, no pseudo-encodings. Constants `Encodings.JPEG_QUALITY_0 = -32`, `Encodings.COMPRESS_LEVEL_0 = -256`; add them to whatever set `protocol.lua:251` checks so they are never treated as rect encodings (they never arrive as rects; just don't break `SUPPORTED`).

- [ ] **Step 1: Write failing tests:** pure check `order(true,{jpeg_quality=5,compress_level=9})` ends with `-27, -247`; `order(false,{jpeg_quality=5})` equals `ORDER_DEFAULT` contents; `order(true)` equals `ORDER_TIGHT` contents. Wire case: mock log shows the SetEncodings list containing `-27`.
- [ ] **Step 2: Run** — new checks FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `proto_smoke.lua` — all PASS.
- [ ] **Step 5: Commit** `feat(encodings): Tight JPEG quality and compression level pseudo-encodings`

### Task 3: Bandwidth settings, menu, session wiring

**Files:**
- Modify: `vnc/settings.lua:30-35`, `vnc/session.lua:180-196`, `vnc/menu.lua` (next to the Tight toggle), `README.md`, `NOTES.txt`
- Test: `tools/ui_smoke.lua`

**Interfaces:**
- Consumes: `PxFmt.for_depth`, `Encodings.order(enable_tight, opts)`, `Protocol.new{pixel_format=}`.
- Produces: settings `color_depth = 24`, `jpeg_quality = false`, `compress_level = false`. Session builds `pixel_format = PxFmt.for_depth(color_depth)` and `encodings = Encodings.order(enable_tight, {jpeg_quality=…, compress_level=…})`.
- Menu: "Colour depth" (24-bit / 16-bit / 8-bit, radio), "JPEG quality" (Off, 0–9) and "Compression level" (Off, 0–9), the latter two enabled only when Tight is on. Help text for all three: "Takes effect on the next connection." JPEG help also: "Only used at 24-bit colour." Additionally (user request): the menu entry text itself carries a visible hint (e.g. "Colour depth (next connection)" or a sub-line), and changing any of the three while a session is connected shows a short `InfoMessage`/notification "Takes effect on the next connection.".
- Decision: apply on next connection only — a live SetPixelFormat races updates already in flight in the old format, which the client cannot tell apart.

- [ ] **Step 1: Write failing tests** in `ui_smoke.lua`: (a) loading a settings file without the new keys yields `color_depth == 24`, `jpeg_quality == false`, `compress_level == false`; (b) with `color_depth = 8, enable_tight = true, jpeg_quality = 3` the session hands `Protocol.new` a format with `bits_per_pixel == 8` and an encoding list ending in `-29` (stub/capture `Protocol.new` the way existing ui tests capture session calls); (c) the three menu entries exist, JPEG/compression disabled while `enable_tight` is false.
- [ ] **Step 2: Run** `ui_smoke.lua` — new checks FAIL.
- [ ] **Step 3: Implement**; document the options in README (settings section) and NOTES.txt (pixel-format paragraph).
- [ ] **Step 4: Run** `ui_smoke.lua` and `proto_smoke.lua` — all PASS.
- [ ] **Step 5: Commit** `feat(viewer): colour depth, JPEG quality and compression settings`

### Task 4: Page-button key fix

**Files:**
- Modify: `vnc/keysyms.lua:24-27,45-53`
- Test: `tools/ui_smoke.lua` (`keys_forward_to_the_remote`, ~line 1460), `tools/server_smoke.lua`

**Interfaces:**
- Produces: `LPgBack`, `RPgBack` → `0xFF55`; `LPgFwd`, `RPgFwd` → `0xFF56`. `Keysyms.key_name[0xFF55] = "LPgBack"`, `Keysyms.key_name[0xFF56] = "LPgFwd"` set explicitly.

- [ ] **Step 1: Write failing tests:** in `keys_forward_to_the_remote`, `press("LPgFwd") == "+0xFF56,-0xFF56"`, `press("LPgBack") == "+0xFF55,-0xFF55"`, same for `RPg*`. In `server_smoke.lua`: `Keysyms.name_for_keysym(0xFF55) == "LPgBack"`, `(0xFF56) == "LPgFwd"`. (If an existing assertion encodes the old mapping, update it — it encoded the bug.)
- [ ] **Step 2: Run** — FAIL on `LPgFwd`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `ui_smoke.lua`, `server_smoke.lua` — all PASS.
- [ ] **Step 5: Commit** `fix(keysyms): page forward sends Page_Down, back sends Page_Up`

### Task 5: Page buttons as mouse wheel

**Files:**
- Modify: `vnc/app.lua:439-441,619-660`, `vnc/settings.lua`, `vnc/menu.lua`, `README.md`
- Test: `tools/ui_smoke.lua`

**Interfaces:**
- Consumes: Task 4 key names.
- Produces:
  - setting `page_buttons = "keys"` (`"keys"` | `"wheel"`); menu radio "Page buttons send": "Page Up/Down keys" / "Mouse wheel".
  - `ViewerApp.WHEEL_NOTCHES = 3`.
  - `ViewerApp:send_pointer` records `self._pointer_x, self._pointer_y`.
  - `ViewerApp:_page_direction(key) -> 1 (fwd) | -1 (back) | nil` for `LPgFwd/RPgFwd/LPgBack/RPgBack`.
  - `ViewerApp:scroll_wheel(direction)` — at the recorded position (or remote `floor(w/2), floor(h/2)` if none), sends `WHEEL_NOTCHES` × (`mask`, then `0`), `mask = 16` for 1, `8` for -1.
  - In wheel mode `onKeyPress` and `onKeyRepeat` call `scroll_wheel` for page keys; `onKeyRelease` consumes them (returns true) and sends nothing. Keys mode unchanged.

- [ ] **Step 1: Write failing tests** (use `new_app()`'s `sent.pointer`): (a) wheel mode, no prior tap, `LPgFwd` press → 6 pointer events at the remote centre, masks `16,0,16,0,16,0`, no key events; (b) after `onTap` at a point mapping to remote (rx, ry), `LPgBack` → events at (rx, ry) with masks `8,0,…`; (c) `onKeyRepeat(LPgFwd)` → another 6 events; release → none; (d) keys mode → key events only, as in Task 4.
- [ ] **Step 2: Run** `ui_smoke.lua` — FAIL.
- [ ] **Step 3: Implement**; README: one paragraph on the setting.
- [ ] **Step 4: Run** `ui_smoke.lua` — all PASS.
- [ ] **Step 5: Commit** `feat(viewer): page buttons can scroll the mouse wheel at the pointer`

### Task 6: `tools/vnc-server.py` with optional frame

**Files:**
- Create: `tools/vnc-server.py` (executable), `tools/test_vnc_server.py`
- Modify: `README.md` (new "Serving a PC screen" section), `NOTES.txt` (file list ~line 64)
- Reference (read, do not modify): `../vnc-server.sh`

**Interfaces (pure helpers in `vnc-server.py`, imported by the test via `importlib` since the filename has a dash):**
- `parse_xrandr(text: str) -> list[dict]` — `{name, primary: bool, w, h, x, y}` for connected outputs with an active mode (connected-but-inactive outputs included with `w=None`).
- `pick_output(outputs, name: str|None) -> dict` — named output, else primary, else first active; `SystemExit` with the shell script's messages (`output 'X' not connected. Outputs: …`, `… has no active mode`).
- `compute_area(out, size: str|None, offset: str) -> (w, h, x, y)` in screen coordinates; same validation/messages as the shell script (`-O must look like 0,40`, `-s must look like 632x840`, `area … does not fit in …`).
- `frame_rects(area, out) -> list[(x, y, w, h)]` — 1 px lines just outside `area`, extended 1 px at the corners; a side is omitted when it would fall outside `out`.
- `build_cmd(display, area, port, auth: list, allow: str|None, extra: list) -> list[str]` — `x11vnc -display D -clip WxH+X+Y -rfbport P <auth> [-allow A] -forever -shared -cursor arrow -wait 50 -defer 100 -noxrecord -ncache 0 <extra>`.
- CLI: `-o -s -O -p -a -n -P FILE(default ./vnc.passwd) -d DISPLAY -f --list -h`, `--` passes the rest to x11vnc. Hard errors (missing x11vnc/xrandr with the apt hint, Wayland) as in the shell script.
- Frame: `Frame(display, rects)` with `.start()` / `.close()`; ctypes `libX11.so.6`; per rect an override-redirect window, red background pixel, `_NET_WM_WINDOW_OPACITY = 0x7fffffff`, mapped and raised; event-free (`XFlush`). Any failure loading/opening → print `warning: frame disabled (<reason>)` to stderr and continue.
- Process: run x11vnc as a child (`subprocess.Popen`), forward SIGINT/SIGTERM to it, wait, close the frame, exit with x11vnc's code.

- [ ] **Step 1: Write failing tests** (`unittest`, no X needed): `parse_xrandr` on a captured sample with one primary `DisplayPort-0 connected primary 2560x1440+0+0`, one `HDMI-1 connected 1920x1080+2560+0`, one disconnected; `pick_output(outs, None).name == "DisplayPort-0"`; `compute_area(hdmi, "632x840", "0,40") == (632, 840, 2560, 40)`; oversize → `SystemExit`; `frame_rects((632,840,2560,40), hdmi)` returns exactly 3 rects — top (y=39), right (x=3192), bottom (y=880); the left line (x=2559) lies outside HDMI-1 and is omitted; `frame_rects` for an area at (0,0) of DisplayPort-0 omits left and top; `build_cmd` equals the exact list above for `-n`; importing the module with `Frame` and no `libX11` → `Frame.start()` returns False and prints the warning (patch `ctypes.util.find_library`/`CDLL` to raise).
- [ ] **Step 2: Run** `python3 tools/test_vnc_server.py -v` — FAIL (module missing).
- [ ] **Step 3: Implement** `tools/vnc-server.py`; README section with usage examples and the no-venv note.
- [ ] **Step 4: Run** `python3 tools/test_vnc_server.py -v` — all PASS; `python3 tools/vnc-server.py -h` prints help and exits 0.
- [ ] **Step 5: Commit** `feat(tools): stdlib Python x11vnc launcher with optional area frame`
