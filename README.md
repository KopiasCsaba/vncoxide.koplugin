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
to build and no native component to install.
It works with standard VNC servers.

## Origins

VNCoxide began as a fork of [vnc.koplugin](https://github.com/hwhw/vnc.koplugin) by Hans-Werner
Hilse, a promising proof of concept. It has since been substantially rewritten, with a heavily
optimized rendering path and a much broader feature set.

The user interface draws inspiration from [RustDesk](https://rustdesk.com/). The two projects
share no code, but credit is due for the design ideas.

---

## Contents
<!-- TOC -->
* [UNDER CONSTRUCTION](#under-construction)
* [VNCoxide](#vncoxide)
   * [Origins](#origins)
   * [Contents](#contents)
   * [Demo](#demo)
   * [Highlights](#highlights)
   * [Installation](#installation)
   * [Quick start](#quick-start)
   * [Compatibility](#compatibility)
   * [Security](#security)
   * [Development and testing](#development-and-testing)
   * [Support](#support)
   * [License](#license)
<!-- TOC -->

Every gesture, menu, setting and tool is described in the
**[User Guide](docs/USER_GUIDE.md)**.

---

## Demo

<!-- TODO: demo video. Drag the .mp4 into the GitHub README editor and paste the generated link here. -->

*Demo video coming soon.*

<!-- TODO: screenshots, e.g.
| Toolbar | Send keys panel | Zoomed in |
| --- | --- | --- |
| ![](docs/media/toolbar.png) | ![](docs/media/sendkeys.png) | ![](docs/media/zoom.png) |
-->

---

## Highlights

Turn your e-reader into a second screen, a remote terminal or a distraction-free display for your
computer.

### 1. Made for e-ink

1. **Fast and responsive**, even on modest e-reader hardware. Typing and paging stay snappy while
   the picture updates.
2. **Crisp text.** Choose *sharp* scaling for clean, readable letters or *smooth* scaling for
   photos and graphics.
3. **Contrast and inversion** controls make any desktop theme readable on e-ink.
4. **One-tap tuning.** *Find fastest picture settings* tests your connection and picks the best
   setup for you.
5. **Works on slow Wi-Fi.** Lower colour depth and image quality per connection to save
   bandwidth.

### 2. Natural touch control

1. **Three pointer modes**, chosen per connection:
   1. *Touch*: tap exactly where you want to click.
   2. *Mouse*: move a pointer like on a laptop trackpad.
   3. *Hybrid*: drag to scroll, tap to click.
2. **Right click and drag** with a long press.
3. **Pinch to zoom, two fingers to pan**, and a two-finger tap to fit the whole screen.
4. **Double click** with a quick second tap.

### 3. Everything at your fingertips

1. **Floating toolbar.** Drag it anywhere, fold it into a small round button and choose which
   buttons it shows.
2. **Zoom, frontlight, contrast and display settings**, one tap away.
3. **Key strip** above the on-screen keyboard with Ctrl, Alt, Esc, Tab, arrows and Del.
4. **Send keys panel** for Ctrl+Alt+Del, Alt+Tab, Super, function keys, Print Screen and more.
   Your recent combinations stay one tap away.
5. **Click and type** in one step: drag the Keyboard button onto a text field.
6. **Physical keyboards** are fully supported, including modifiers and key repeat.
7. **Page buttons** work as Page Up/Down or as a mouse wheel.

### 4. Set it up once, then just use it

1. **Saved connections** with their own picture and pointer settings.
2. **Auto connect** when KOReader starts, for a dedicated remote-screen device.
3. **Automatic reconnect** when Wi-Fi drops.
4. **Follows your screen's orientation**, portrait or landscape.
5. **Stays awake** while the viewer is open: no sleep, no dimming.
6. **Background sessions.** Leave the viewer to read a book and come back to where you were.


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

1. On your computer, start a VNC server such as x11vnc, TigerVNC or TightVNC.

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

---

## Security

VNC is not encrypted, and VNC Authentication is a weak scheme based on DES. Passwords are stored
in clear text in `settings/vncoxide.lua`, the same way KOReader stores OPDS and sync credentials.
Use the plugin on a trusted network, or tunnel the connection over SSH or WireGuard. Never expose
a VNC server to the internet.

---

## Development and testing

1. Behaviour is covered by two test suites:
   1. `tests/proto_smoke.lua` tests the client protocol stack against a deterministic mock RFB
      server.
   2. `tests/ui_smoke.lua` tests the dialogs and the viewer headless, using KOReader's own widget
      stack.
2. The commands to run each suite are in `NOTES.txt`.
3. `NOTES.txt` covers the architecture, the internals, the live end-to-end recipe and what has
   and has not been verified.

Bug reports and patches are welcome.

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
