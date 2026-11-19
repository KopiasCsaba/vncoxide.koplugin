# VNCoxide — User Guide

VNCoxide shows your computer's screen on your e-reader, and lets you control it with your finger
and the keyboard. It works with ordinary VNC servers (x11vnc, TigerVNC, TightVNC, RealVNC, …).

## 1. Install

1. On GitHub, click the green **Code** button ▸ **Download ZIP**.
2. Unpack the ZIP.
3. Rename the unpacked folder to **`vncoxide.koplugin`**.
4. Copy it into the `plugins` folder inside your KOReader folder.
5. Restart KOReader.

## 2. Connect

1. In KOReader's file browser, open the menu ▸ **More tools** ▸ **VNC viewer**.
2. Tap **New connection…** and fill in a name, your computer's address, the port (usually 5900)
   and the VNC password.
3. Tap the connection to connect. Your computer's screen fills the display.

Want it to connect by itself every time KOReader starts? Open **Manage connections…** and turn on
**Auto connect on start** for that connection.

## 3. Touch gestures

You can pick one of three ways to control the pointer with the **Mode** button on the toolbar:

| Gesture | ☝ Touch | 🖱 Mouse | ↕ Hybrid |
| --- | --- | --- | --- |
| Tap | Click where you tap | Click at the pointer | Click where you tap |
| Long press | Right click | Right click | Right click |
| Long press, then drag | Drag (e.g. select text) | Drag | Drag |
| One-finger drag | Drag | Move the pointer, like a trackpad | Scroll the page |

In every mode:

1. **Two fingers drag** — move the view around.
2. **Pinch / spread** — zoom out / in.
3. **Two-finger tap** — fit the whole screen again.
4. **Two-finger long press** — click there and open the keyboard.
5. **Page buttons** — Page Up / Page Down (or scroll, if you change it in the **⋯** menu).

## 4. The toolbar

A small toolbar sits at the top of the screen. **Swipe down from the very top** to hide or show it.
Drag it anywhere you like. Long-press any button to see its name.

1. **Collapse** — fold the toolbar into a small round button. Tap it to open it again.
2. **Display** — zoom, sharp/smooth scaling, screen rotation, picture quality, pointer speed.
3. **Zoom** — switch between *fit*, *1:1* and the last zoom you made with your fingers.
4. **Mode** — Touch, Mouse or Hybrid (see above).
5. **⌨ Keyboard** — show or hide the on-screen keyboard. Tip: drag this button onto a text field
   to click it and start typing straight away.
6. **Rotate** — turn the screen 90°.
7. **Brightness** — the frontlight.
8. **Contrast** — make the picture darker or lighter.
9. **Invert** — swap black and white.
10. **✕** — disconnect.
11. **⋯** — more options (see below).

You can choose which buttons appear under **⋯ ▸ Toolbar buttons…**.

## 5. Typing

1. Tap **⌨** to bring up the keyboard and type normally.
2. Above the keyboard is a row of extra keys: **Ctrl**, **Shift**, **Alt**, **Super**, Esc, Tab,
   arrows and Del. Tap a modifier (it turns black), then the next key or tap uses it — e.g.
   **Ctrl** then **C** copies.
3. For anything else, tap the **Send keys** icon (two keycaps) in that row. There you find
   Home/End, Page Up/Down, F1–F12, and ready-made shortcuts like Ctrl+C, Ctrl+V, Ctrl+Z, Alt+Tab and
   Ctrl+Alt+Del. Your last four shortcuts are kept at the bottom.
4. Something feels stuck down on the computer? Tap **Release all**.

A physical keyboard works too.

## 6. The ⋯ menu

1. **Connections…** — switch to or add another connection.
2. **Refresh** — redraw the whole picture.
3. **Page buttons send** — Page Up/Down keys, or mouse-wheel scrolling.
4. **Hybrid scroll distance** — if scrolling in Hybrid mode moves too far, pick a bigger number;
   too little, a smaller one.
5. **Keep screen on** — stop the reader from sleeping while you use it.
6. **Match orientation to the remote screen** — turn the reader sideways automatically for a wide
   computer screen.
7. **Toolbar buttons…** — choose which buttons show.
8. **Help** — a quick reminder of the gestures.
9. **Leave (keep connection)** — go back to KOReader but stay connected, so coming back is instant.

## 7. Faster or sharper picture

If the picture is slow to update:

1. Open **Display** and choose **Picture quality ▸ Fast** (or **Balanced**).
2. Turn on **Sharp** scaling in the same panel — faster redraws and crisper text.
3. Or let the plugin find the best settings for you: **Manage connections…** ▸ your connection ▸
   **Find fastest picture settings**, then **Apply best**. Keep the computer screen still while it
   runs.

## 8. If the connection drops

The last picture stays on screen and the plugin keeps trying to reconnect by itself. Tap
**Retry now** to try straight away, or **Close** to give up.

## 9. Stay safe

VNC is **not encrypted**, and your password is saved as plain text on the reader. Use it only on
your own home network (or through a VPN), and never open your VNC server to the internet.
