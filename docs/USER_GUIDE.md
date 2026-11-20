# VNCoxide User Guide

This guide explains how VNCoxide works and how to get the most out of it. For installation and a
first connection, see the [README](../README.md#install). For a complete list of every gesture,
button and menu entry, open **⋯ ▸ Help** in the viewer. That page always matches the installed
version and lists the gestures for your current pointer mode first.

## Contents

1. [Connections](#1-connections)
2. [Pointer modes and gestures](#2-pointer-modes-and-gestures)
3. [The toolbar](#3-the-toolbar)
4. [Keyboard input](#4-keyboard-input)
5. [Picture: display and quality](#5-picture-display-and-quality)
6. [Finding the fastest settings](#6-finding-the-fastest-settings)
7. [Sessions, reconnects and orientation](#7-sessions-reconnects-and-orientation)
8. [Troubleshooting](#8-troubleshooting)

## 1. Connections

Connections are managed under **More tools ▸ VNC viewer** in KOReader's file browser. Each saved
connection keeps its own:

1. **Address and password.** Leave the password empty for servers without authentication.
2. **Pointer mode**: Touch, Mouse or Hybrid (see [§2](#2-pointer-modes-and-gestures)).
3. **Hybrid scroll distance** (see [§2](#2-pointer-modes-and-gestures)).
4. **Picture settings**: colour depth, Tight, JPEG quality and compression level
   (see [§5.3](#53-picture-settings-per-connection)).

All other settings (zoom, scaling, contrast, toolbar layout, keyboard state) are global.

**Manage connections…** offers Edit, Delete, *Find fastest picture settings* and
**Auto connect on start**. Only one connection can auto-connect: turning it on for one turns it off
for the others. That connection is dialled once when KOReader starts. If it fails, you get the
usual error message and remain in KOReader; there is no retry. While a connection is flagged,
KOReader's own **Start with** menu also shows a *VNC auto connect* entry.

## 2. Pointer modes and gestures

Switch modes with the toolbar's **Mode** button. The mode is saved with the connection.

| Gesture | Touch | Mouse | Hybrid |
| --- | --- | --- | --- |
| Tap | Left click at the finger | Left click at the pointer | Left click at the finger |
| Two quick taps | Double click | Double click | Double click |
| Long press, lift | Right click | Right click | Right click |
| Long press, then move | Left-button drag | Left-button drag | Left-button drag |
| One-finger drag | Left-button drag | Move the pointer (trackpad) | Scroll (mouse wheel) |

Common to all modes: **two-finger drag** pans, **pinch/spread** zooms, a **two-finger tap** fits the
screen again, and a **two-finger long press** clicks and opens the keyboard.

Two settings fine-tune this:

1. **Pointer speed** (Display panel) sets how far the Mouse-mode pointer moves per finger movement.
   When you are zoomed in, the view follows the pointer.
2. **Hybrid scroll distance** (⋯ menu) tells the plugin how many remote pixels one wheel notch
   scrolls. The plugin cannot detect this, because the remote application decides. If the content
   runs ahead of your finger, choose a larger value; if it lags behind, a smaller one.

The device's **page buttons** send Page Up/Down by default. Page Up/Down goes to the focused
remote window. Switch **⋯ ▸ Page buttons send** to *Mouse wheel* to scroll whatever is under your
last tap instead.

## 3. The toolbar

The toolbar floats over the picture, and taps on it never reach the remote. To move it, drag it by
any button; it keeps its place across rotations. Long-press a button to see its name.

1. **Collapse** folds the toolbar into a small round button. Under
   **⋯ ▸ Toolbar buttons… ▸ Also when collapsed…** you can choose which buttons remain next to it;
   by default only Keyboard does.
2. **⋯ ▸ Toolbar buttons… ▸ On the toolbar…** chooses which buttons are shown. **Close** and **⋯**
   are always shown, because on devices without keys ⋯ is the only way to reach the menu.
   **Scroll up/down** (mouse-wheel notches) is hidden by default. **Brightness** only appears on
   devices with a frontlight.
3. **Zoom** cycles between *fit*, *1:1* and your own view, which is the last zoom you made by
   pinching or panning.

## 4. Keyboard input

**On-screen keyboard.** The **⌨** button toggles the keyboard; the viewer reopens with it as you
left it. To *click and type* in one move, drag the ⌨ button onto a text field: it clicks where you
let go and opens the keyboard. Hold Backspace to repeat it.

**Key strip.** The row above the keyboard holds Ctrl, Shift, Alt and Super, plus Esc, Tab, the
arrow keys and Del. Modifiers are *one-shot*: an armed (black) modifier applies to the next key,
**or** to the next tap, long press or drag on the picture, and is then released. For example,
Ctrl then a tap gives a Ctrl+click.

**Send keys panel.** The two-keycap icon in the strip opens this panel. It has three tabs:

1. **Keys**: Home/End, Page Up/Down, Insert, Print Screen and more, plus *Modifiers only* to send
   just the armed modifiers (for example Super alone).
2. **Hotkeys**: ready-made combinations such as Ctrl+C/V/Z, Alt+Tab, Alt+F4, Lock (Super+L) and
   Ctrl+Alt+Del.
3. **F1–F12**.

Your last four combinations are kept at the bottom of the panel. **Release all** clears any key the
remote still believes is held.

**Physical keyboards** work directly, including Ctrl/Alt combinations and key repeat.

## 5. Picture: display and quality

### 5.1 Display panel

The toolbar's **Display** button opens a panel with:

1. **Zoom**: *Fit screen*, *Fit (with keyboard)* (fits the area left above the keyboard), or a fixed
   scale from 25% to 400%.
2. **Scaling**: *Sharp* (nearest neighbour) keeps text crisp. *Smooth* (blended, the default) suits
   photos and graphics.
3. Screen orientation, the picture-quality preset (§5.2), and the Mouse-mode pointer speed.

**Contrast** (50%–300%) and **Invert** have their own toolbar buttons. They only change how the
picture is drawn on the reader, not what the server sends, and both are remembered.

### 5.2 Quality presets

The Display panel's **Picture quality** applies one of three presets to the current connection
and reconnects:

| Preset | Colour depth | Tight | JPEG quality | Compression |
| --- | --- | --- | --- | --- |
| Best | 24-bit | off | — | server default |
| Balanced | 16-bit | on | 6 | 6 |
| Fast | 8-bit | on | 3 | 9 |

If your settings don't match any preset, the panel shows *Custom*.

### 5.3 Picture settings per connection

Find these in the connection editor under **Picture settings**. Long-press any row in the editor
for an explanation. In short:

1. **Colour depth.** 16-bit halves the data, and greys still look smooth on e-ink. 8-bit quarters
   it, but greys show visible steps.
2. **Tight** is an alternative encoding. Its main benefit is JPEG for photo-like areas, which helps
   on slow Wi-Fi when the screen shows images.
3. **JPEG quality** (Off, or 0–9) only takes effect at 24-bit colour.
4. **Compression level** (Off, or 0–9) controls how hard the server packs text and flat areas.
   Servers differ: x11vnc only distinguishes a few levels, and the editor's help explains which.

Changes take effect on the next connection.

## 6. Finding the fastest settings

Which settings are fastest depends on the computer, the network and what is on screen; it is not
always the one with the least data. For example, on a PocketBook Era, 8-bit with compression has
felt faster than 24-bit even on fast Wi-Fi. The built-in benchmark measures this on your own setup.

1. On the computer, open [`tools/bench-page.html`](../tools/bench-page.html) in a browser on the
   shared screen. Make it full screen (F11) and click into it once so it has keyboard focus.
2. On the reader: **Manage connections… ▸ *your connection* ▸ Find fastest picture settings ▸
   Start**. The connection editor also has a *Test speed with these settings…* button that tests
   the address you typed before you save it.
3. Don't touch the computer while it runs (about four minutes). The plugin sends Page Down and Home
   to the test page and times how long each change takes to appear on the reader.
4. Tap a result card and confirm **Use** to save its picture settings to the connection.

The benchmark tests 11 combinations of colour depth, Tight, compression and JPEG, each in two passes
in opposite order. Any other change on the shared screen, such as a clock or a blinking cursor,
skews the timings, which is why the page must fill the screen. Nothing is saved unless you pick a
result. Live sessions are paused during the run and resume afterwards.

## 7. Sessions, reconnects and orientation

1. **Background sessions.** **⋯ ▸ Leave (keep connection)** returns to KOReader without
   disconnecting. Tap the connection again to return instantly. Switching to another connection
   via **⋯ ▸ Connections…** also leaves the previous one running in the background.
2. **Reconnect.** When the connection drops, the last picture stays on screen and the viewer retries
   automatically after 2, 4, 8 and 15 seconds, then every 30 seconds, until you stop it. Use
   **Retry now** to try immediately or **Close** to disconnect. Modifiers or buttons held at the
   time of the drop are not carried over.
3. **Keep screen on** (on by default) prevents sleep and frontlight dimming while the viewer is
   open.
4. **Match orientation to the remote screen** (on by default) turns the reader to landscape or
   portrait to match the remote, using the side you last chose by hand. A rotation you choose
   yourself stays until the remote's orientation changes.

## 8. Troubleshooting

| Symptom | What to check |
| --- | --- |
| *Could not connect* | Host, port, and that the server listens on the network (not only on localhost) and is allowed through the computer's firewall. |
| *Server offers no supported security type* | VNCoxide supports only *None* and *VNC Authentication*. Enable VNC password authentication on the server; servers that require TLS/VeNCrypt-only or proprietary encryption are not supported. |
| *The server asks for a password* | The connection has no password saved, but the server requires one. |
| Picture updates slowly | Try the *Fast* or *Balanced* preset and *Sharp* scaling, or run the [benchmark](#6-finding-the-fastest-settings). |
| Text too small, constant panning | Give the reader its own screen with a `_halfsize` profile of the [screen tools](../tools/screen-tools/README.md). |
| Benchmark: *The PC screen did not change* | The test page must be full screen on the *shared* screen and have keyboard focus. |
| Hybrid scrolling overshoots or lags | Adjust **⋯ ▸ Hybrid scroll distance** (§2). |
| A key or modifier seems stuck on the remote | **Release all** in the Send keys panel. |
| Picture looks out of date | **⋯ ▸ Refresh** requests a full picture. |

Security considerations are covered in the [README](../README.md#security).
