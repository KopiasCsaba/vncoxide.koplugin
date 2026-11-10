# VNC for KOReader

Two halves of one thing. **Control a remote desktop from KOReader**: the plugin adds *VNC viewer* to
KOReader's file browser menu, and the remote screen fills the display, driven by touch, the
on-screen keyboard and a physical keyboard. And **share KOReader's own screen**: a small VNC server,
started from the *Network* menu, lets a computer elsewhere watch and drive the reader — see
[Sharing this screen (VNC server)](#sharing-this-screen-vnc-server).

Both halves speak RFB 3.8, the protocol ordinary VNC servers and viewers (x11vnc, TigerVNC,
TightVNC, RealVNC in compatibility mode, Remmina, phone apps, ...) all understand.

## What you get

- The remote framebuffer on the whole screen, scaled to fit, with zoom presets (fit screen, fit
  with the on-screen keyboard, or a fixed 25 % … 400 %) and panning for the rest. Zoomed in, only
  the visible part (plus a margin) is requested from the server, so less is sent and decoded.
- Two ways to drive the pointer: **Touch** mode acts where your finger is, **Mouse** mode moves a
  pointer like a laptop trackpad. Two-finger gestures pan and zoom the view.
- A small toolbar over the picture for the things you reach for most (including one zoom button
  that cycles fit, 1:1 and your own pinch/pan view, the frontlight and a contrast control for the
  remote picture), with the rest one tap away behind **⋯**. Drag it anywhere, fold it into a small
  round button, and pick which buttons it shows.
- An on-screen keyboard that types into the remote session, plus a physical keyboard with
  modifiers, arrows, function keys and auto-repeat.
- A key strip above the on-screen keyboard (modifiers, Esc, Tab, arrows, Del) and a **Send keys**
  panel for any key or hotkey the on-screen keyboard cannot type (Ctrl+Alt+T,
  Super, F5, Print Screen, ...), with the last four combos one tap away.
- Connection profiles (name, host, port, password) you can add, edit and delete from KOReader.
- One connection can be flagged to connect by itself at KOReader's start (and to appear as
  **VNC auto connect** in KOReader's **Start with** menu).
- Wi-Fi is turned on when a connection needs it.
- A dropped connection is retried by itself, with Wi-Fi kept on meanwhile.
- **Leave** the viewer and the connection survives; only **Disconnect** closes the session (and
  returns you to the connection list).

## Install

1. On GitHub, download this repository as a ZIP: green **Code** button ▸ **Download ZIP**.
2. Unpack the ZIP.
3. Move the plugin folder into the `plugins` directory in your KOReader folder (create it if it is
   not there yet). GitHub names the unpacked folder after the repository and the branch —
   `vnc.koplugin-main` — so rename it to **`vnc.koplugin`**: KOReader only loads plugin directories
   whose name ends in `.koplugin`.
4. Restart KOReader.

There are no release artefacts to fetch: the plugin is plain Lua and uses only what KOReader
already ships.

## Using it

Open the file browser menu in KOReader, then **More tools** ▸ **VNC viewer**. You get the
connection list; start with **New connection…** and give it a name, the host, the port (5900 by
default) and the password your VNC server uses; the **Picture: …** button sets that connection's
colour depth and Tight options (see "Lower bandwidth" below). Tap a connection to connect.

**Manage connections…** opens each saved connection's own actions (Connect, Edit, Delete), plus an
**Auto connect on start** switch. Turning it on dials that connection by itself on KOReader's next
start and shows it in the viewer; the connection list then marks it (**name (auto connect)**).
Only one connection can carry it — turning it on for another clears the first. While a connection
carries it, KOReader's own **Start with** menu also offers **VNC auto connect**.

KOReader cannot be told about the viewer before it opens the file browser — it has no boot hook for
plugins — so with **VNC auto connect** selected the file browser appears for a moment and the
viewer opens over it. If the connection cannot be made, the failure is reported exactly as a manual
connect's is, and you are left in the normal KOReader UI; there is no retry.

**The toolbar** is a small bar over the remote picture, at the top centre until you move it; the
picture stays visible and clickable beside and below it. It is shown when a connection opens. A
**swipe down in the top strip of the screen** (KOReader's menu zone) hides it and shows it again
(folded or not). A tap on the bar never reaches the remote. A **long press** on any button only
shows its name in a one-line tooltip. **Drag** the bar by any of its buttons to move it: it follows
the finger, stays fully on the screen, and keeps its place (as a share of the free space, so also
after a rotation) for the next time. Its buttons, left to right:

1. **Collapse** (a small bar icon) folds the toolbar into a round button with the same icon, at the
   same spot. A tap on the round button opens the toolbar again; it can be dragged like the bar,
   and the bar opens where it is. The folded state is remembered.
2. **Display** opens the Display panel (below).
3. **Zoom** cycles the view: **fit** → **1:1** (one remote pixel per screen pixel, keeping the
   middle of the view where it was) → **your view** → fit … "Your view" is the last one you made
   by pinching or two-finger panning: as soon as you pinch or pan, that is the current state, and
   it is remembered for the button to come back to. Until you have made one (or after the remote
   screen size changes) the button just switches between fit and 1:1. The icon shows the current
   state: a page (fit), **1:1**, or a magnifier (your view; also shown for another Display panel
   zoom preset, from which the button goes to fit). Fit follows the keyboard like a two-finger tap.
4. **Mode** (☝ Touch / 🖱 Mouse) switches the pointer mode and shows a short tooltip (*Touch mode*
   or *Mouse mode*). The **Help** page is under **⋯**. The mode is remembered per connection.
5. **⌨ Keyboard** shows or hides the on-screen keyboard together with the key strip (and closes
   the **Send keys** panel if it is open; the panel opens from the strip's keys icon).
   The viewer opens with the keyboard as you last left it (shown or hidden; the strip's **✕** and the
   panel's **✕** and keyboard icon count too; a menu or dialog hides it only while it is open).
6. **Rotate** turns the screen 90° clockwise. (Rotating is only ever done with this button or the
   Display panel: a pinch never turns the screen.) The viewer remembers the orientation you last
   used and opens in it, unless **Match orientation to the remote screen** (see below) turns it.
7. **Scroll lock** is a toggle, drawn inverted while on; it starts off each time the viewer opens.
   While it is on, a two-finger drag scrolls the remote instead of moving the picture (see below).
8. **Scroll up / down** send one wheel notch each. Hidden by default.
9. **Brightness** (a sun) opens KOReader's own frontlight dialog. Only on devices with a frontlight.
10. **Contrast** opens a small dialog under the toolbar (above it when the bar sits low) with a
    stepped bar (50 % … 300 %, 100 % is the picture as the server sends it, marked as the default).
    It changes the contrast of the remote picture as it is drawn on this screen (a stretch around
    mid grey; the remote desktop is not touched), at once and without a new picture from the
    server, and is remembered. ✕, Back, a tap outside or the button close it. Hidden by default.
11. **✕ Close** disconnects, after a confirmation, and returns to the connection list.
12. **⋯** opens the menu (below).

**⋯ › Toolbar buttons…** switches each button but Close and **⋯** on or off (one row for the scroll
pair); **⋯** always stays, as on a device without keys it is the only way to the menu.

| Gesture | Touch mode | Mouse mode |
| --- | --- | --- |
| tap | left click at the finger | left click at the pointer |
| long press | right click at the finger | right click at the pointer |
| one-finger drag | drag with the left button held | move the pointer (relative to your finger's movement, by the pointer speed) |
| tap, then drag | not used (a plain drag already drags) | drag with the left button held from the pointer |
| tap, then long press | right click at the finger (the tap clicked first) | hold the left button at the pointer: moving drags, lifting lets go |
| two-finger drag | pan the view (with **scroll lock** on: scroll the remote, see below): the picture follows the fingers, also past its edges until a corner reaches the middle of the screen (does not move the remote pointer) | same |
| pinch / spread | zoom the view, keeping the point between the fingers fixed | same |
| two-finger tap | fit to screen (Fit, or Fit with keyboard while the keyboard is up) | same |
| device page buttons | Page Up/Down or wheel (setting) | same |

In Mouse mode the pointer starts in the middle of the remote screen and is drawn by the server (with
x11vnc, `-cursor arrow`); the viewer draws none. A tap's click waits out KOReader's double-tap
interval before it is sent, so that a tap followed by a drag or a long press near it can become a
drag with the left button instead of a click and a press; two quick taps still give two clicks. A
finger that comes down near the tap and is still down when that interval runs out keeps the click
waiting (at most the double-tap interval plus KOReader's long-press interval plus a quarter second
after the tap) until it turns into a tap, a drag or a long press, so a slow second touch still
drags. A second finger joining a long press or a tap-then-hold drag lets go of its button. Touch mode clicks are sent at once. A long press acts
about 0.12 s after KOReader reports it (at once if the finger moves first): some PocketBook
firmware holds a touch back for half a second and then delivers it in a burst, which KOReader
takes for a long press; one that lifts within that time is treated as the tap or drag it really
was. Three-finger gestures are not used.

The end of a drag or long press is the viewer's wherever the finger lifts: over the toolbar, the
**Send keys** panel or the on-screen keyboard (no key is typed then). Should that end still not
arrive, the button is let go as soon as the finger that started it is off the screen, and opening
the menu, the display panel or the help ends a drag first. Every button press and release sent is
written to KOReader's debug log (`vnc-pointer: <buttons> <x> <y> <reason>`).

**Scroll lock.** With the toolbar's scroll lock on, a two-finger drag, and the quick flick that
ends one, sends mouse-wheel notches instead of panning: one notch per tenth of the screen height
(sideways: of the width) the fingers travel. The content follows the fingers, as on a phone:
fingers up scroll down, fingers left scroll right (horizontal wheel). The notches go to the pointer
in Mouse mode and to the fingers in Touch mode. Pinch still zooms and a two-finger tap still fits.
Switching it on or off in the middle of a drag ends that drag.

A tap is *always* a click on the remote, everywhere outside the bar, so there is never a dead spot
on the screen. With a physical keyboard, the **Menu** key (F1 on KOReader's own keymap) opens the
menu and **Back** closes whatever is open on top.

**The Display panel** hangs under the toolbar (above it when there is no room below). A choice stays in the panel (the check marks follow
the live state) except a rotation, which closes it. It tells:

- **Zoom**: Fit screen, Fit (with keyboard), 25 %, 50 %, 75 %, 100 %, 150 %, 200 %, 400 %.
- **Smooth / Sharp** scaling (see "Sharp scaling" below).
- **Orientation**: four icon buttons, the same ones KOReader uses for screen rotation (90° counter-
  clockwise, upright, 90° clockwise, 180°, relative to the screen as it is now); the current one is
  highlighted. The viewer remembers the last orientation used and opens in it.

**Matching the remote's orientation.** With **Match orientation to the remote screen** on (⋯ menu,
default on), the screen turns to the remote desktop's orientation once its size is known: a
landscape remote (wider than tall) on a portrait screen turns it to landscape, a portrait remote on
a landscape screen to portrait; a square remote, or one already of the screen's orientation, turns
nothing. The side it turns to is the landscape (or portrait) side you last picked with Rotate or
the Display panel, else KOReader's default landscape (90° clockwise) or upright. It happens after
connecting (in one rotation together with the remembered orientation), and after a reconnect or a
remote desktop resize only when the remote's orientation changed since it was last matched for that
connection: a rotation you picked by hand meanwhile survives a reconnect to the same remote. It does
not change the remembered orientation, and leaving the viewer still restores the orientation from
before it opened.
- **Picture quality (reconnects)**: **Best**, **Balanced**, **Fast**. The preset is a set of the
  connection's picture settings:

  | Preset | Colour depth | Tight | JPEG quality | Compression level |
  | --- | --- | --- | --- | --- |
  | Best | 24-bit | off | server default | server default |
  | Balanced | 16-bit | on | 6 | 6 |
  | Fast | 8-bit | on | 3 | 9 |

  Choosing another preset reconnects with it, and saves it into the connection only once that
  connection has succeeded; closing or leaving first keeps the old values. A connection whose picture
  settings match no preset is shown as **Custom**. The settings themselves are described under
  "Lower bandwidth" below.
- **Pointer speed (mouse mode)**: Slow (0.75), Normal (1.25), Fast (2.0): a multiplier on how far
  the pointer moves for a given drag.

**The ⋯ menu** holds the rest. Its title is the connection and its state (*name · 1920×1080* while
connected, *name · connection lost* after a drop). Then **Reconnect to …** when the connection has
just dropped (a long press tells why), the connection list (**Connections…**, to switch or add one),
**Refresh** (asks for a full picture and flashes the screen), **Lock screen** (Super+L), **Page
buttons send** (Page Up/Down keys or Mouse wheel),
**Keep screen on** (default on: the device does not auto-suspend, go to standby or dim the light while the viewer is open),
**Match orientation to the remote screen** (default on, see above),
**Toolbar buttons…** (above), **Help** and **Leave (keep connection)**. Rows that switch something
on or off show ✓ or - and keep the menu open; anything else closes it.

**The key strip** sits right above the on-screen keyboard: **✕** (closes the keyboard, like a tap on
**⌨**), the **Send keys** icon (two keycaps), which opens the full **Send keys** panel (the keyboard
and strip make way for it; it sends nothing and leaves armed modifiers armed), then **Ctrl**,
**Shift**, **Alt**, **Super**, Esc, Tab, the four arrows and Del. A modifier armed there goes with exactly one action, like
the panel's: the next key on the on-screen keyboard or the strip, or the next tap or drag on the
screen.

**Send keys** is a panel at the bottom of the screen; the remote stays visible (and clickable) above
it. Its top row is the key strip's row with two other buttons at the left: **✕** closes the panel and
the keyboard icon next to it switches back to the on-screen keyboard with its strip (armed modifiers
stay armed there); then **Ctrl**, **Shift**, **Alt**, **Super**, Esc, Tab, the four arrows and Del.
Tap a modifier to arm it (it turns black), tap again to cancel. Armed modifiers go with exactly one
action and are then let go: the next key from the panel, or the next tap, long press or drag on the
screen (Ctrl+click, Shift+click or Shift+drag to select, Alt+drag). The tabs hold the other special
keys (**Keys**: Home above End, Page Up above Page Down, Insert above Space, Backspace above Enter,
then Print Screen, Pause, Menu and **Modifiers only**, which sends just the armed modifiers: Super on
its own opens most desktops' launcher) and F1-F12; letters and symbols are on the on-screen keyboard
(armed modifiers go with its keys too). The bottom row repeats your last four combos exactly
(armed modifiers are not added to them, and are cleared), and **Release all** disarms every modifier
and lets go of whatever a drag or long press still holds on the remote (its button, then its
modifiers), e.g. when its release never arrived; it is available whenever something is armed or
held. Nothing stays pressed between actions. The panel stays open until its close button, Back or
the Menu key; closing it, leaving the viewer or disconnecting in the middle of a drag lets go of the
button and the modifiers that drag holds.

**The keyboard** is drawn over the framebuffer, and showing it leaves the zoom alone — except in
**Fit (with keyboard)**, the mode that deliberately fits the zoom into the space the keyboard
leaves and follows it. Otherwise, a view that is too large for the space above the keyboard keeps
the whole screen (pan with two fingers to reach what the keys cover), while a view that fits in
that space is moved into it instead of hiding behind the keys. The keyboard gets out of the way
whenever a menu or dialog is open, and comes back when it closes.

**Losing the connection.** When the connection drops while the viewer is open, the last picture
stays and a box appears over it: *Connection lost — reconnecting…* with the attempt number and the
seconds to the next one, and **Retry now** and **Close**. Attempts follow 2, 4, 8 and 15 seconds,
then every 30 seconds, and go on until one succeeds or you choose **Close** (Back does the same).
On success the box goes, a full picture is requested, and the toolbar, mode and zoom are as they
were. Wi-Fi stays on while it retries; it is turned off again (if the plugin had turned it on) only
when the retrying ends without a connection. A retry that is under way is also repeated at once when the device wakes up.
There is no retrying in the background: if the connection drops while you have left the viewer, it
stays down, and reopening the viewer shows *Connection lost* with **Retry** and **Close** and
retries only after you tap **Retry**. Closing the viewer stops everything.

**Leave (keep connection)** closes the viewer but keeps the session, the remote framebuffer and
Wi-Fi up, so reopening it is instant and the picture is resynchronised. **Close** on the toolbar
(Disconnect) closes the connection and restores Wi-Fi if the plugin turned it on.

## Sharing this screen (VNC server)

The plugin can also serve the other way round: KOReader's own screen as a VNC desktop, so a
computer elsewhere can watch what your reader is showing and drive it with its mouse and keyboard.

It is **off by default**. Turn it on in KOReader's *Network* menu: **VNC server** — the entry is
checked while it runs and opens a submenu with

- **Start/Stop VNC server**,
- a status line (the address it listens on, and how many clients are connected),
- **Start with KOReader** — off by default; when on, the server starts by itself when KOReader
  starts (a manual stop still stops it, and it stays stopped until the next start),
- **IP address** — `0.0.0.0` (the default) serves every interface, `127.0.0.1` only this device,
- **Port** — 5900 by default,
- **Password** — clients must then authenticate (VNC Authentication); leave it empty and anybody
  who can reach the port gets in.

For scripted or headless setups a few environment variables override the server settings. They
apply to that run only and are **never written to the settings file** — setting the password this
way keeps it out of `settings/vnc.lua` — while the menu always shows and edits the stored values:

| Variable | Effect |
| --- | --- |
| `VNC_KOPLUGIN_ENABLE_SERVER` | Start at boot. Any non-empty value except `0`, `no`, `false` (trimmed, case-insensitive) starts the server; empty or unset means "use the stored setting". |
| `VNC_KOPLUGIN_SERVER_HOST` | Bind address for this run; empty or unset leaves the stored one. |
| `VNC_KOPLUGIN_SERVER_PORT` | Port for this run (an integer 1–65535); anything else is ignored with a warning. |
| `VNC_KOPLUGIN_SERVER_PASSWORD` | Password for this run; set it empty for "no password". |

On Kindles the plugin opens the port in the device's firewall while it runs (the same thing
KOReader's own HTTP inspector does) and closes it again when you stop the server.

Connect with any VNC viewer to `<reader-ip>:5900`. You see KOReader's screen; clicking, dragging and
typing act on the reader. Everything KOReader can do is therefore remote-controllable, so the
password matters — see the warning under [Settings](#settings). **The server is only reachable while
it is started**, and KOReader must be running.

The server uses the viewer's own choice of encoding — **Raw, RRE, Hextile or ZRLE**, the first entry
of the client's preference list it can produce, falling back to Raw when the viewer asks for none of
those (Tight, TRLE, CopyRect) — and tiles a large changed region, so a full-screen change cannot
hold up the reader's UI.

An incremental update request with nothing to answer is **held**, not answered with an empty update
(a viewer asks again the moment it is answered, so answering every time would be a ping-pong at the
poll rate): the hold ends as soon as something inside the region the request named has changed, and
a client that has gone quiet with a request outstanding is sent one empty update a second as a sign
of life that does not release the hold. Viewers that keep their picture up to date without asking
(the Continuous Updates extension) are supported too, and the community extensions real viewers send
are handled rather than fatal — a Fence ping is answered, while a client asking the server to resize
the desktop is declined, because the picture follows the reader's own screen. `NOTES.txt` has the
rest.

A client's click becomes a KOReader tap, drag or long press exactly as a finger would — the press is
held back until it is known which.

What a client sees is KOReader's logical screen: the e-ink panel's own flash/ghosting is not
reproduced, and the on-screen keyboard, dialogs and rotations are simply part of the picture.

## Power consumption

The two halves behave very differently.

**The viewer** costs nothing while it is not connected: with no session open there is no timer, no
socket and no work of any kind. While a session is up, expect the usual power use of a network
connection and — mostly — of screen updates, because every frame has to be received, decoded and
drawn. A picture that does not change costs very little; a moving one costs what the update rate
implies.

**The server**:

- **Installed but not started**: no runtime overhead worth mentioning — nothing is scheduled, and
  nothing listens.
- **Started, nobody connected**: a small, steady overhead. The server checks for a connection about
  a hundred times a second — the network does not wake it up by itself — a constant, low-level cost
  you can expect to show only as slightly shorter runtime on a battery-powered device.
- **A client connected**: a little more, because that is when the per-connection work and the
  network traffic happen. With a still screen even that stays very small — about one tiny
  keep-alive-sized packet a second, and no frame work at all until something on the screen actually
  changes.

One caveat matters more than the above on an e-reader: the server does not manage Wi-Fi itself — it
neither turns it on nor keeps it on — so a device that goes to sleep drops the connection. And
while Wi-Fi is up it is usually the **larger** part of the power bill, bigger than the server's own
periodic check.

## Settings

Connection profiles live in a plain Lua file inside KOReader's settings directory,
`settings/vnc.lua`:

```lua
return {
    ["profiles"] = {
        [1] = { ["name"] = "desktop", ["host"] = "10.0.0.5", ["port"] = 5900, ["password"] = "",
                ["autoconnect"] = true,    -- connect here at start
                -- picture settings, per connection (see "Lower bandwidth" below)
                ["color_depth"] = 24,      -- 24, 16 or 8: fewer bits = less bandwidth, fewer colours
                ["enable_tight"] = false,  -- opt-in Tight encoding, see below
                ["jpeg_quality"] = false,  -- Tight JPEG quality 0..9 (false = server default)
                ["compress_level"] = false,   -- Tight compression level 0..9 (false = server default)
                ["pointer_mode"] = "touch" }, -- "touch" or "mouse" (the toolbar's Mode button)
    },
    ["settings"] = {
        ["orientation"] = 0,               -- default screen orientation (0 = upright)
        ["match_orientation"] = true,      -- turn the screen to the remote's orientation after connecting
        ["landscape_orientation"] = 1,     -- landscape side last picked by hand (1 = 90° clockwise)
        ["portrait_orientation"] = 0,      -- portrait side last picked by hand (0 = upright)
        ["keyboard_shown"] = false,        -- the keyboard's last state: the viewer opens with it shown or not
        ["keep_screen_on"] = true,         -- no auto-suspend, standby or light dimming while the viewer is open
        ["zoom_mode"] = "fit",             -- "fit", "fit_with_keyboard" or 0.25 .. 4
        ["page_buttons"] = "keys",         -- device page buttons send "keys" (Page Up/Down) or the "wheel"
        ["scaling"] = "smooth",            -- "smooth" or "sharp" (faster, crisper text; the Display panel's switch)
        ["pointer_speed"] = "normal",      -- Mouse mode: "slow" (0.75), "normal" (1.25) or "fast" (2.0)
        ["toolbar_buttons"] = {            -- which toolbar buttons are shown (Close and More always are)
            ["toggle"] = true, ["display"] = true, ["zoom"] = true, ["mode"] = true, ["keyboard"] = true,
            ["rotate"] = true, ["scroll_lock"] = true, ["scroll_up"] = false, ["scroll_down"] = false,
            ["brightness"] = true,         -- (only on devices with a frontlight)
            ["contrast"] = false,
        },
        ["toolbar_collapsed"] = false,     -- the toolbar is folded into its round button
        ["toolbar_pos"] = { ["x"] = 0.5, ["y"] = 0 }, -- where it sits: fractions of the free space (0.5, 0 = top centre)
        ["remote_contrast"] = 1,           -- contrast of the remote picture as drawn: 0.5, 0.75, 1, 1.25, 1.5, 2, 2.5 or 3
    },
    ["server"] = {                         -- the VNC server (Network menu); 0.0.0.0 = any interface
        ["ip"] = "0.0.0.0",
        ["port"] = 5900,
        ["password"] = "",                 -- empty = no authentication at all
        ["autostart"] = false,             -- start the server with KOReader
    },
}
```

You never have to edit it by hand (the editor in the viewer writes it), but it is one way to set a
password without typing it into a dialog. Unknown keys are dropped and missing ones defaulted when
it is loaded, so a broken file does not keep the plugin from starting; if a hand-edited file flags
more than one profile for `autoconnect`, the first keeps the flag and the rest are cleared. A
global `["enable_tight"] = true` in `settings` (where older versions kept it) turns Tight on for
every profile that has no `enable_tight` of its own, and is then dropped.

> **Passwords are stored in clear text**, like KOReader itself does for OPDS and progress sync.
> VNC Authentication is a weak, DES-based scheme anyway, and **nothing in a VNC session is
> encrypted** — run it over SSH, WireGuard or a trusted network.

## Troubleshooting lag

If page-button presses lag while the screen redraws, KOReader's debug log can show where the time
goes. Turn on Developer options -> Enable debug logging, reproduce the lag, then look in
`crash.log` in KOReader's folder (`koreader/crash.log`) for lines starting with `vnc-timing:`
(`grep vnc-timing crash.log`). They report decode time, paint time, key/wheel presses and gaps where
the UI was blocked (such as an e-ink refresh). Nothing is logged with debug logging off.

## Server compatibility

- RFB 3.8 with security type *None* or *VNC Authentication* (password). No TLS/VeNCrypt/SASL, so
  servers that require those cannot be used — as a client *and* as the server above.
- Encodings: ZRLE, TRLE, Hextile, RRE, CopyRect and Raw — all of RFC 6143 — plus DesktopSize
  (servers that resize their desktop are followed automatically).
- **Tight** compression is implemented but **off by default**: it is not part of RFC 6143 and
  servers interpret its control byte differently, so it is opt-in per connection (**Tight
  encoding** under the connection editor's **Picture** button, or the profile's
  `["enable_tight"] = true`) until it has been tested against the server you use.
- **Lower bandwidth**: each connection has its own picture settings, set with the **Picture: …**
  button in the connection editor (its label sums them up, e.g. `Picture: 16-bit, Tight, JPEG 3`).
  **Colour depth** (24/16/8-bit) asks the server for fewer bits per pixel; with Tight on, **JPEG
  quality** and **Compression level** (Off or 0–9; Off leaves the server's default) trade picture
  quality and CPU for bytes. Compression level only packs the lossless parts (text, menus, flat
  areas); on x11vnc only a few values differ: 2 with JPEG, 0 or 1 without (see its help). Both
  are listed under **Tight encoding** and are dimmed, but still show their value and can be
  long-pressed, while it is off. JPEG is only used at 24-bit colour. The choice is stored when the
  connection is saved and **takes effect on the next connection** — saving the connection that is live says to
  reconnect when one of these (or the host, port or password) changed. New connections start with
  Tight off. The **Help** button opens a scrollable explanation of every setting, with the setting names in bold;
  long-press a row for that setting's explanation.
- **Find fastest picture settings** (in a connection's **Manage connections…** dialog) measures
  the picture settings instead of guessing: it tries 11 combinations of colour depth, Tight,
  compression level and JPEG quality on that connection, twice each, in opposite order (the
  second pass runs the list backwards, so no combination gains from running last), a few
  seconds per try, each try on its own extra connection. Open connections stay connected but are paused for the run (they stop
  receiving screen updates, so they do not slow the measurement) and catch up when it ends. If a
  combination cannot connect at all (refused, timed out, wrong password, no Wi-Fi), the run stops
  at once and shows "Could not connect: <reason>" instead of a table of failures; a combination
  that connects but then fails (say, a format the server rejects) is listed as failed and the run
  goes on. Put what you usually look at on the PC's shared area and leave it still: each
  combination fetches that screen three times whole (the first is a warm-up and not counted) and
  then in 16 pieces (a 4×4 grid), each forced to be sent again even though nothing changed, and
  decodes and draws every piece at your current zoom and scaling. It is ranked by the pixels per
  second of the small pieces, the closest to everyday updates; the results also show the time per
  piece, the time for a full screen and the kilobytes a full screen took. Every figure but the
  kilobytes is a median over both tries, so one slow Wi-Fi round trip does not decide the
  ranking; a combination that fails in either try is listed as failed ("failed in pass N: ..."). **Apply best** saves
  the winner's four picture settings to the connection (nothing else; it takes effect on the next
  connection); **Cancel** or **Close** save nothing.
- **Sharp scaling (faster)**: **Sharp** in the Display panel (toolbar ▸ **Display**). It scales
  by repeating pixels instead of blending them: much faster redraws when the zoom is not 100% and
  crisper text, but uneven at non-whole zoom levels. It is one global setting (not per connection)
  and applies immediately to the live view.
- **Page buttons**: **Page buttons send** under **⋯** chooses what a device's page-turn buttons do.
  The default sends Page Up/Down keys to the remote's focused window; **Mouse wheel** instead
  scrolls 3 notches at the last tapped position (the remote's centre before any tap), which also
  works on a window that is not focused. It applies immediately, no reconnect needed.
  While you press keys or page buttons, screen updates pause until 0.3 s after the last press,
  so a fast run of presses is not slowed down by e-ink redraws.

## How this was written

This plugin is **vibe coded**: the code was written by a machine — **DeepSeek V4 Flash**, driven
prompt by prompt from a specification — with the protocol and the UI behaviour pinned down by the
tests described in `NOTES.txt`. Treat it as what it is: a hobby project that happens to be tested
rather than a polished product.

## Disclaimer

It comes with **no warranty** of any kind, and the developer may not be able to offer support for
it. Use it at your own risk, and do not expose a VNC session to a network you do not trust. Bug
reports and patches are welcome.

## Serving a PC screen

`tools/vnc-server.py` shares a monitor (or just part of it) of a running X11 session with
`x11vnc`, so this plugin's viewer can show it. It needs no venv: it uses only the Python 3
standard library (plus `x11vnc` and `xrandr`: `sudo apt install x11vnc x11-xserver-utils`; with
`-z`, `ffmpeg` instead of `x11vnc`: `sudo apt install ffmpeg x11-xserver-utils`).
Run `tools/vnc-server.py -h` for every option.

```
tools/vnc-server.py --list                       # connected outputs and their geometry
tools/vnc-server.py                              # primary monitor, port 5900, asks for a password once
tools/vnc-server.py -o HDMI-1 -n                 # a named output, no password
tools/vnc-server.py -s 632x840 -O 0,40 -f        # top-left 632x840 below a 40 px taskbar, with a red frame
tools/vnc-server.py -s 632x840 -z 2 --sharp      # frames scaled 2x on the PC (1264x1680 for the reader)
tools/vnc-server.py -a 192.168.1.50 -p 5901 -- -viewonly   # only that client; extra args go to x11vnc (not with -z)
```

- `-s WxH` / `-O X,Y` select the area, handy to match the reader's screen size.
- `-z ZOOM` (`2`, `1.5`, `4/3`) scales the frames on the PC before sending; `--sharp` uses
  nearest-neighbour scaling (no blending, crisper text), otherwise ffmpeg's `area` filter blends
  neighbouring pixels (no over- or undershoot at edges, unlike bicubic). The start-up line shows the frame size the viewer will get, e.g.
  `-s 632x840 -z 2` gives 1264x1680 for a 1264x1680 screen. Set the viewer zoom to 100% then: the
  reader does no scaling and draws fastest, at the price of zoom² times the pixels to transfer and
  decode. The Display panel's **Sharp** scaling is the client-side alternative that keeps the bandwidth
  low.
- With `-z` the script does not use x11vnc but its own small RFB server (`tools/vnc_zoom.py`), because
  x11vnc's `-clip` + `-scale` clamps the arrow it draws to the unscaled size, so on the reader the
  pointer looks stuck in the top-left part. `ffmpeg` grabs the area 10 times a second (`--fps N`
  to change) with the real pointer drawn in, scales it and converts it to the viewer's pixel
  format; the server sends the 64x64 tiles that changed, as ZRLE (or Raw), and injects pointer and
  keys with XTest (keysyms on no key, such as `ő` on a US layout, are bound to a spare keycode). It
  takes the same `-a`, `-n`, `-P`, `-p`, `-f` options; `--gentle` and arguments after `--` are
  x11vnc-only and refused with `-z`. Measured in Xvfb with a 632x840 area at `-z 2` (3 runs of 20):
  a pointer move reached the viewer in 77–92 ms on average (38–137 ms), and a still screen cost about
  21% of one core for ffmpeg plus about 7% for the server (a lower `--fps` lowers both).
- `-f` draws a thin red frame (50% opacity with a compositor) just outside the shared area, so
  you can see what the reader shows. It is removed when the server stops; if it cannot be drawn
  you get one warning and the server runs without it.
- Latency (x11vnc, without `-z`): the defaults are `-wait 5 -defer 0` (x11vnc answers at once).
  Measured against x11vnc 0.9.16 on a 632x840 area, the old `-wait 50 -defer 100` cost about 150 ms
  per request against about 6 ms. `--gentle` goes back to `-wait 50 -defer 100` (less CPU on a slow
  PC, about 145 ms more per update).
- The password file is `./vnc.passwd` (change with `-P FILE`); it is created on first use, in
  x11vnc's `-storepasswd` format (written by the script itself when `-z` runs without x11vnc).
- X11 only; a Wayland session is refused.

## For developers

`NOTES.txt` has the architecture, the internals, the test setup and what has and has not been
verified. The three Lua suites it describes live in `tools/` and are run from the KOReader root with
KOReader's own LuaJIT:

    PLUGIN=~/.config/koreader/plugins/vnc.koplugin
    cd /usr/lib/koreader

    # the client protocol stack, over a real socket, against tools/mock_vnc_server.py
    LUA_PATH="$PLUGIN/?.lua;./common/?.lua;./common/?/init.lua;;" LUA_CPATH="./common/?.so;;" \
      ./luajit "$PLUGIN/tools/proto_smoke.lua" --tmp "$HOME/vnc-smoke"   # --tmp=<dir> works as well

    # the dialogs and the viewer widget against KOReader's widget stack, headless
    KO_HOME="$HOME/vnc-smoke/ui" SDL_VIDEODRIVER=dummy \
      LUA_PATH="$PLUGIN/?.lua;;" LUA_CPATH="./common/?.so;;" \
      ./luajit "$PLUGIN/tools/ui_smoke.lua"

    # the server half: pixel formats, encoders, protocol, the real socket path, input injection
    KO_HOME="$HOME/vnc-smoke/server" SDL_VIDEODRIVER=dummy \
      LUA_PATH="$PLUGIN/?.lua;./common/?.lua;./common/?/init.lua;;" LUA_CPATH="./common/?.so;;" \
      ./luajit "$PLUGIN/tools/server_smoke.lua"

`tools/mock_vnc_server.py` is the RFB fixture the client suite talks to — deterministic patterns in
every encoding, both security types, and every client message logged — and
`tools/tight_jpeg.b64` is the fixed 32×32 JPEG it serves for its Tight JPEG rectangle.
`tools/mock_vnc_client.py` is the independent Python client used to check the server, so the server
half is validated by something that is not this plugin's own code.

A fourth suite covers the PC-side launcher `tools/vnc-server.py` (unit tests plus end-to-end runs
against fake `x11vnc`/`xrandr` stubs) and its zoom server `tools/vnc_zoom.py` (DES, ZRLE checked by
a reference decoder, the RFB protocol against a fake capture; `tools/test_vnc_zoom.py`). It needs only
Python 3, no KOReader:

    python3 tools/test_vnc_server.py

Keep the scratch directories on the home filesystem: a quota-limited `/tmp` makes the suites fail
(its default locations are under `/tmp`). The UI suite needs a **fresh** `KO_HOME` — it reuses fixed
paths under it — and `SDL_VIDEODRIVER=dummy` keeps the SDL emulator from opening a window without
changing what the checks see. `NOTES.txt` has the rest of the pitfalls, the live end-to-end recipe
(mock server plus a real KOReader driven through its HTTP inspector) and the open ends.
