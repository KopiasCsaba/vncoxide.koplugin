# UNDER CONSTRUCTION

This code is in progress of publishing, documentation is under construction. Stay tuned.

Thank you for your patience.

# VNCoxide

**VNCoxide (`vncoxide.koplugin`) is a full-screen VNC viewer for e-readers running [KOReader](https://koreader.rocks).**
Drive a remote desktop by touch, on-screen keyboard or physical keyboard, with decoding,
scaling and screen refreshes tuned for e-ink.

![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)
![Language: Lua](https://img.shields.io/badge/language-Lua%20%2B%20LuaJIT%20FFI-000080)
![Protocol: RFB 3.8](https://img.shields.io/badge/protocol-RFB%203.8-informational)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/KopiasCsaba)

The plugin is plain Lua and LuaJIT FFI, using only what KOReader already ships. There is nothing
to build and no native component to install. It works with standard VNC servers (x11vnc,
TigerVNC, TightVNC, RealVNC in compatibility mode, and others) and includes an optional PC-side
helper for sharing part of an X11 screen at the reader's resolution.

---

## Contents

1. [Highlights](#highlights)
2. [Feature overview](#feature-overview)
3. [Installation](#installation)
4. [Quick start](#quick-start)
5. [Compatibility](#compatibility)
6. [Security](#security)
7. [Development and testing](#development-and-testing)
8. [Origin and credits](#origin-and-credits)
9. [Support](#support)
10. [License](#license)

Every gesture, menu, setting and tool is described in the
**[User Guide](docs/USER_GUIDE.md)**. Code structure and internals are in `NOTES.txt`.

---

## Highlights

VNCoxide is built for everyday use on an e-reader. It was developed and measured on a
PocketBook. Compared with the prototype it grew out of (see [Origin and credits](#origin-and-credits)),
grouped by area:

### 1. Performance on low-power hardware

1. **Background pipeline.** Decoding and scaling run in two forked worker processes that share
   memory with the UI. The interface stays responsive while a large update arrives, and
   multi-core readers use their extra cores. If the workers cannot start, the plugin falls back
   to doing the work in-process.
2. **Faster decoders.** Network data is received into a single C buffer and read through
   pointers. zlib and TurboJPEG state is reused. Solid fills go through libblitbuffer. On the
   PocketBook build, RRE runs about 0.57× and Hextile 0.5–0.7× of the original time.
3. **Partial requests and redraws.** When zoomed in, only the visible area (plus a margin) is
   requested from the server. Only changed regions are rescaled and dithered, into a persistent
   canvas.
4. **Sharp and smooth scaling.** Sharp scaling is a fast nearest-neighbour mode with crisp text.
   Smooth scaling uses faster box and bilinear filters.
5. **Settings for less bandwidth.** Colour depth (24, 16 or 8-bit), Tight JPEG quality and
   compression level can be set per connection.
6. **Built-in benchmark.** *Find fastest picture settings* tries 11 combinations against your
   live server, in two passes ranked by median, and can apply the winner.
7. **Input before redraws.** Screen updates are held back briefly while keys or page buttons are
   pressed, so a fast run of key presses is not slowed by e-ink refreshes.

### 2. Pointer and gestures

1. **Three pointer modes**, chosen per connection:
   1. *Touch*: the remote acts exactly where you tap.
   2. *Mouse*: a relative pointer, like a laptop trackpad, with adjustable speed. When zoomed in,
      the view follows the pointer.
   3. *Hybrid*: a drag scrolls the remote, a tap clicks under your finger. The scroll distance
      can be set per connection.
2. **Reliable long press.** A long press is confirmed before it acts: it gives a right click, or
   a left-button drag if your finger moves. This filters out the false holds some e-ink touch
   panels report.
3. **Two-finger gestures.** Pan, pinch-zoom (the view can go past the picture's edges) and a
   two-finger tap to fit.
4. **Double clicks.** A quick second tap counts as a double click.
5. **No stuck buttons.** A mouse button is never left held down on the remote.

### 3. Toolbar and on-screen controls

1. **Floating toolbar.** You can drag it anywhere, fold it into a round button, pin chosen
   buttons to the folded bar and pick which buttons it shows. A long press on a button shows its
   name.
2. **Toolbar buttons:**
   1. a zoom button that cycles between fit, 1:1 and your own pinch/pan view;
   2. frontlight control;
   3. a stepped contrast control and picture inversion;
   4. a Display panel for zoom, scaling, orientation and pointer speed.
3. **Key strip** above the on-screen keyboard: modifiers, Esc, Tab, arrows and Del.
4. **Send keys panel** for anything the on-screen keyboard cannot type: Ctrl+Alt+Del, Alt+Tab,
   Super, function keys, Print Screen and more. The last four combinations stay one tap away.
5. **Click and type.** Drag the Keyboard button onto the remote picture, or use a two-finger
   long press, to click a text field and open the keyboard in one step.
6. **Physical keyboards.** Ctrl, Shift and Alt now reach the remote. Held Backspace repeats.

### 4. Connection robustness

1. **Automatic reconnect.** A dropped connection is retried with backoff, and Wi-Fi is kept on
   while it retries. A reconnect box lets you retry by hand or hang up.
2. **Connecting does not block the UI.** A Wi-Fi link that has no route yet is brought up first.
3. **Orientation matching.** The screen turns to the remote's orientation after connecting,
   reconnecting or a desktop resize.
4. **Keep screen on.** Auto-suspend, standby and frontlight dimming are paused while the viewer
   is open.
5. **Hardened protocol handling.** The client rejects oversized framebuffers and malformed
   lengths, caps server strings at 1 MiB, answers RFB 4.x/5.x servers with 3.8, and gives a clear
   error when a server needs a password that was not set.

### 5. PC-side tooling

1. **`tools/vnc-server.py`** shares a whole monitor or any rectangle of an X11 session through
   x11vnc. It can draw an optional frame around the shared area and defaults to low-latency
   settings. It uses only the Python standard library.
2. **`tools/vnc_zoom.py`** is a small RFB server built on ffmpeg. It scales frames on the PC
   (`-z 2`, `--sharp`), so the reader can draw at 1:1 with no scaling of its own. It supports
   ZRLE, XTest input injection and CIDR allow-lists.

### 6. Scope

VNCoxide is a viewer only. The prototype also shipped a VNC **server** for sharing KOReader's own
screen; it was dropped to focus entirely on the viewer.

---

## Feature overview

| Area | Capabilities |
| --- | --- |
| Display | Full-screen remote framebuffer, fit and 25–400 % zoom presets, pan, pinch zoom, sharp or smooth scaling, contrast and inversion, orientation matching |
| Input | Touch, Mouse and Hybrid pointer modes; on-screen keyboard with key strip; Send keys panel; physical keyboard with modifiers and auto-repeat; page buttons as Page Up/Down or mouse wheel |
| Connections | Saved profiles, picture settings per connection, auto connect at start-up (also offered in KOReader's *Start with* menu), automatic reconnect, Wi-Fi management |
| Sessions | *Leave* keeps a session running in the background; *Disconnect* closes it |
| Performance | Decode and scale worker processes, partial requests when zoomed, incremental redraws, built-in benchmark |
| Diagnostics | `vnc-timing:` trace in KOReader's debug log (decode, paint and blocked-UI times) |

---

## Installation

1. Download this repository as a ZIP: **Code** ▸ **Download ZIP**.
2. Unpack it and rename the folder from `vncoxide.koplugin-main` to **`vncoxide.koplugin`**. KOReader only
   loads plugin folders whose names end in `.koplugin`.
3. Copy the folder into the `plugins` directory of your KOReader installation.
4. Restart KOReader.

There is nothing to compile.

---

## Quick start

1. On your computer, start a VNC server. For example, to share the primary monitor:

   ```sh
   tools/vnc-server.py            # needs x11vnc and xrandr; run with -h to see every option
   ```

2. On the reader, open the file browser menu and choose **More tools** ▸ **VNC viewer** ▸
   **New connection…**. Enter a name, the host, the port (default 5900) and the password.
3. Tap the connection to connect. The toolbar appears at the top. Swipe down in the top strip of
   the screen to hide it or show it again.

See the [User Guide](docs/USER_GUIDE.md) for gestures, the toolbar, keyboard panels, picture
settings and troubleshooting.

---

## Compatibility

1. **Protocol:** RFB 3.8, with security type *None* or *VNC Authentication*.
2. **Encodings:**
   1. ZRLE, TRLE, Hextile, RRE, CopyRect and Raw (all of RFC 6143);
   2. Tight, including JPEG (opt-in per connection);
   3. DesktopSize and the quality and compression pseudo-encodings.
3. **Not supported:** TLS, VeNCrypt and SASL. Servers that require them cannot be used.
4. **PC helpers:** these need X11. Wayland sessions are refused.

---

## Security

VNC is not encrypted, and VNC Authentication is a weak scheme based on DES. Passwords are stored
in clear text in `settings/vncoxide.lua`, the same way KOReader stores OPDS and sync credentials.
Use the plugin on a trusted network, or tunnel the connection over SSH or WireGuard. Never expose
a VNC server to the internet.

---

## Development and testing

1. Behaviour is covered by three test suites:
   1. `tools/proto_smoke.lua` tests the client protocol stack against a deterministic mock RFB
      server.
   2. `tools/ui_smoke.lua` tests the dialogs and the viewer headless, using KOReader's own widget
      stack.
   3. `tools/test_vnc_server.py` tests the PC-side launcher and zoom server, using Python 3 only.
2. The commands to run each suite are in the
   [User Guide](docs/USER_GUIDE.md#for-developers).
3. `NOTES.txt` covers the architecture, the internals, the live end-to-end recipe and what has
   and has not been verified.

Bug reports and patches are welcome.

---

## Origin and credits

VNCoxide is written and maintained by **Kopiás Csaba**.

It started on 2026-11-06 as a fork of **[hwhw/vnc.koplugin](https://github.com/hwhw/vnc.koplugin)**
by **Hans-Werner Hilse**, an experimental prototype, and has since been largely rewritten: about
four fifths of the current Lua code is new. The prototype laid the foundation:

1. The RFB 3.8 client, with every encoding in RFC 6143 (ZRLE, TRLE, Hextile, RRE, CopyRect and
   Raw), DesktopSize, VNC authentication and opt-in Tight.
2. The full-screen viewer with zoom presets, panning and touch control.
3. Forwarding from the on-screen and physical keyboards.
4. Connection profiles, auto connect at start-up and Wi-Fi handling.
5. The headless protocol and UI test suites that pin the behaviour down.

Its history is kept intact in git (71 commits by the original author), and every change since is
recorded on top of it. Many thanks to Hans-Werner Hilse for the original work and for releasing
it under the AGPL.

---

## Support

If VNCoxide is useful to you, you can support its development through
[GitHub Sponsors](https://github.com/sponsors/KopiasCsaba).

---

## License

Copyright © 2026 Kopiás Csaba.
Portions copyright © 2026 Hans-Werner Hilse (the original
[vnc.koplugin](https://github.com/hwhw/vnc.koplugin)), modified by Kopiás Csaba since 2026-11-06.

This program is free software, licensed under the **GNU Affero General Public License v3.0**,
the same license as the original. See [`LICENSE`](LICENSE). The complete source of this version
is available at <https://github.com/KopiasCsaba/vncoxide.koplugin>.

This software comes with **no warranty** of any kind. Use it at your own risk.
