# Lower bandwidth, page-button fix/scroll, PC server script — design

Three independent changes to the forked `vnc.koplugin` (KOReader VNC viewer + server plugin).
The user runs the viewer on a PocketBook (greyscale e-ink, page buttons only) against
`x11vnc` on a Linux desktop, over links where it "is kinda slow".

## 1. Lower bandwidth: colour depth + Tight JPEG quality/compression

### Why
The viewer always requests 32 bpp / depth 24 (`vnc/pxfmt.lua` `PxFmt.PIXEL_FORMAT`), i.e. ~3 bytes
of colour per pixel, while the e-ink panel shows 16 grey levels. Most of that data is never seen.
The server (x11vnc) already converts to any client pixel format; only the client must ask for and
decode it.

### Goals
1. New viewer setting **Colour depth**: `24-bit` (default, current behaviour), `16-bit`, `8-bit`.
   1. 24-bit: current format, unchanged.
   2. 16-bit: true colour RGB565 (bpp 16, depth 16, little-endian, r/g/b max 31/63/31,
      shifts 11/5/0).
   3. 8-bit: true colour BGR233 (bpp 8, depth 8, r/g/b max 7/7/3, shifts 0/3/6).
   The exact masks/shifts are the builder's call as long as greys map well; above is the
   conventional choice.
2. Every decoder the viewer supports (Raw, CopyRect, RRE, Hextile, TRLE, ZRLE, Tight) works in all
   three depths. Per RFC 6143: PIXEL is `bpp/8` bytes; CPIXEL is 3 bytes only for 32 bpp/depth ≤ 24
   true colour, otherwise equal to PIXEL. Tight's TPIXEL follows the same rule. Decoded values are
   expanded to RGB24 into the existing `TYPE_BBRGB24` plane (scale each channel `v * 255 / max`).
3. New viewer settings (only meaningful when the existing `enable_tight` setting is on):
   1. **JPEG quality**: `off` (default; no pseudo-encoding sent = server default) or 0–9 →
      pseudo-encoding `-32 + level` (`-32`..`-23`).
   2. **Compression level**: `off` (default) or 0–9 → pseudo-encoding `-256 + level`.
   Pseudo-encodings are appended to the SetEncodings list built by `Encodings.order`.
   Note: servers only send Tight JPEG at 32 bpp, so at 16/8-bit JPEG quality has no effect; the
   menu should say so (e.g. help text) rather than hide it.
4. Changing any of these while connected takes effect without reconnecting if practical
   (send new SetPixelFormat + SetEncodings + a full non-incremental update request); otherwise on
   next connect, stated in the menu help text. Builder's call which, based on how
   `vnc/session.lua`/`vnc/protocol.lua` are structured.
5. Settings persist like the existing ones (`vnc/settings.lua` defaults table) and live in the
   viewer menu next to the Tight toggle.

### Non-goals
1. Greyscale-specific pixel format, palette (non true-colour) mode, or server-side greyscale.
2. Changing the plugin's own *server* side (`vnc/server.lua`, `serverenc.lua`) — it already
   honours arbitrary client pixel formats.

### Anti-goals
1. Any regression at 24-bit (default) — performance or correctness.
2. Pure-Lua per-pixel paths where the current code uses `ffi.copy` at 24-bit; low-depth paths may be
   per-pixel but must use FFI pointers, not string `:byte()` per pixel, on the hot paths.

## 2. Page buttons

### Bug (verified)
KOReader names PocketBook's two page buttons `LPgBack` / `LPgFwd`
(`frontend/device/pocketbook/device.lua:202-203` upstream). `vnc/keysyms.lua:24-27` maps
`LPgBack` *and* `LPgFwd` to `0xFF55` (Page_Up) and both `RPg*` to `0xFF56` (Page_Down) — split by
side instead of direction. So on PocketBook both buttons send Page Up.

### Goals
1. Fix: `LPgBack`, `RPgBack` → `0xFF55` Prior/Page_Up; `LPgFwd`, `RPgFwd` → `0xFF56` Next/Page_Down.
   The reverse map (`Keysyms.key_name`, used by the plugin's server side) currently depends on
   `pairs` order for shared keysyms; pin it explicitly (`0xFF55 → "LPgBack"`, `0xFF56 → "LPgFwd"`).
2. New viewer setting **Page buttons send**: `Page Up/Down keys` (default) or `Mouse wheel`.
   1. Wheel mode: forward = wheel down (mask bit 4, value 16), back = wheel up (bit 3, value 8);
      each notch is press-then-release (`mask`, then `0`) at the **current remote pointer
      position**.
   2. Current pointer position = the last remote coordinate any pointer event was sent at (tap,
      drag, hold); before any, the centre of the remote framebuffer. Track it in
      `ViewerApp:send_pointer` (or the session).
   3. Notches per press: a setting is not required; default 3 (builder's call to expose it).
   4. Key repeat (`onKeyRepeat`) repeats the scroll in wheel mode.
   5. Applies to all four `*PgBack`/`*PgFwd` names; `Up`/`Down` arrow keys stay keys.

### Non-goals
1. Remapping other keys.

## 3. PC server script: `tools/vnc-server.py`

### Why
`../vnc-server.sh` (outside the plugin repo, user's personal copy) works but is hard-wired
(`DisplayPort-0` default, password file next to the script) and lives outside the repo. The user
also wants to see on the PC which area the e-reader shows.

### Goals
1. One Python 3 file, **stdlib only** (argparse, subprocess, ctypes), executable, in the plugin
   repo at `tools/vnc-server.py`. Replaces the shell script; feature parity with it:
   `-o OUTPUT`, `-s WxH`, `-O X,Y`, `-p PORT`, `-a ALLOW`, `-n` (no password), `--` extra x11vnc
   args; same validation and error messages; same x11vnc flags
   (`-clip GEOM -forever -shared -cursor arrow -wait 50 -defer 100 -noxrecord -ncache 0`).
   Read the existing script for exact behaviour.
2. Generalised:
   1. `-o` default: the primary xrandr output (fallback: first connected one).
   2. `-d DISPLAY` (default `$DISPLAY`, else `:0`).
   3. `-P FILE` password file (default `./vnc.passwd` relative to the current directory;
      created via `x11vnc -storepasswd` if missing, as now).
   4. `--list`: print connected outputs with geometry `WxH+X+Y`, mark primary, exit.
   5. `-h`: full help.
3. **Frame** (`-f`, default off): a 1 px red line drawn just **outside** the shared rectangle, on
   top of other windows, click-through by construction (four 1 px override-redirect windows, so
   the interior is not covered). Sides lying on/after the monitor edge are skipped. 50% opacity via
   `_NET_WM_WINDOW_OPACITY` (needs a compositor; without one the line is opaque — acceptable).
   Implemented with ctypes against `libX11.so.6`. Lives while the server runs, removed on exit
   (incl. Ctrl+C / x11vnc exiting).
4. Fail gracefully: if `-f` is given but libX11 cannot be loaded or the display cannot be opened,
   print one warning line and continue without the frame. Missing `x11vnc`/`xrandr` or a Wayland
   session remain hard errors with install hints, as now.
5. Must not need a venv (zero dependencies — deliberate exception to the user's usual
   setup.sh/run.sh rule; stated in README). Works identically from host or container; relative
   paths only.
6. README section documenting it; remove nothing else. The old `../vnc-server.sh` outside the repo
   is left alone (user's file).

### Non-goals
1. Wayland support, multi-client management, auto-detecting the e-reader's resolution.

## Constraints (all parts)
1. Plugin is pure Lua + LuaJIT FFI, no build step (`NOTES.txt`). Follow the existing code style
   (LDoc comments, module layout).
2. Tests: extend the existing headless suites — `tools/proto_smoke.lua` (decoders per depth,
   pseudo-encodings in SetEncodings; `tools/mock_vnc_server.py` may need to emit 16/8 bpp),
   `tools/ui_smoke.lua` (menu entries, page-button behaviour in both modes). They run with
   KOReader's LuaJIT as described in `NOTES.txt:336+`; if that environment is unavailable, say so
   plainly rather than claiming tests pass. The Python script gets at least a `--help`/arg-parse
   and geometry-math check runnable without X.
3. Update `NOTES.txt`/`README.md` where behaviour changes.
4. No author names/brands in commits or source.

## Left to the builder
1. Internal structure of the depth-aware decoders.
2. Live-apply vs next-connect for depth/quality changes (goal 1.4).
3. Whether wheel notches-per-press is user-visible.
4. Menu wording and nesting.
