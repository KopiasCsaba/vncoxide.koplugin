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
- Touch control: taps, long presses and drags drive the remote pointer, and two-finger gestures
  pan, zoom and rotate the view.
- An on-screen keyboard that types into the remote session, plus a physical keyboard with
  modifiers, arrows, function keys and auto-repeat. Keys the on-screen keyboard does not have
  (Enter, Tab, Esc, Delete) are in the menu.
- Connection profiles (name, host, port, password) you can add, edit and delete from KOReader.
- One connection can be flagged to connect by itself at KOReader's start (and to appear as
  **VNC auto connect** in KOReader's **Start with** menu).
- Wi-Fi is turned on when a connection needs it.
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

There is no permanent toolbar: the remote desktop owns the whole screen.

| Gesture | Effect |
| --- | --- |
| tap | left click |
| long press | right click |
| one-finger drag | drag with the left button held |
| two-finger drag | pan the view (does not move the remote pointer) |
| pinch / spread | zoom the view, keeping the point between the fingers fixed |
| two-finger rotate | change the screen orientation |
| swipe up from the bottom strip | show the on-screen keyboard |
| swipe down above the keyboard | hide it again |
| swipe down in the top menu zone | open the menu |

The two keyboard swipes have to start outside the keys: a swipe that begins on a key belongs to
KOReader's keyboard, where it inserts one of the key's alternate characters — so there is no "swipe
down on the keyboard to put it away". The menu's **Hide keyboard** entry does that from anywhere,
and **keyboard always visible** keeps the keyboard up regardless of either swipe.

A tap is *always* a click on the remote — including in the top menu zone — so there is never a
dead spot on the screen. That is why the menu opens on a **swipe down** there; with a physical
keyboard, the **Menu** key (F1 on KOReader's own keymap) toggles it too.

**The menu** offers the connection list, a status line, the zoom presets, a "keyboard always
visible" toggle, show/hide keyboard, the screen orientation (including rotations), "use current
orientation as default", what the page buttons send, sending single keys (Enter/Tab/Esc/Delete),
**Disconnect** (with a confirmation) and **Leave (keep connection)**. If the connection has just
dropped, it leads with **Reconnect to …**.

**The keyboard** is drawn over the framebuffer, and showing it leaves the zoom alone — except in
**Fit (with keyboard)**, the mode that deliberately fits the zoom into the space the keyboard
leaves and follows it. Otherwise, a view that is too large for the space above the keyboard keeps
the whole screen (pan with two fingers to reach what the keys cover), while a view that fits in
that space is moved into it instead of hiding behind the keys. The keyboard gets out of the way
whenever a menu or dialog is open, and comes back when it closes.

**Leave (keep connection)** closes the viewer but keeps the session, the remote framebuffer and
Wi-Fi up, so reopening it is instant and the picture is resynchronised. **Disconnect** closes the
connection and restores Wi-Fi if the plugin turned it on.

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
                ["compress_level"] = false }, -- Tight compression level 0..9 (false = server default)
    },
    ["settings"] = {
        ["orientation"] = 0,               -- default screen orientation (0 = upright)
        ["keyboard_always_visible"] = false,
        ["zoom_mode"] = "fit",             -- "fit", "fit_with_keyboard" or 0.25 .. 4
        ["page_buttons"] = "keys",         -- device page buttons send "keys" (Page Up/Down) or the "wheel"
        ["scaling"] = "smooth",            -- "smooth" or "sharp" (faster, crisper text; the viewer menu's switch)
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
  compression level and JPEG quality on that connection, a few seconds each, each on its own
  extra connection. Open connections stay connected but are paused for the run (they stop
  receiving screen updates, so they do not slow the measurement) and catch up when it ends. If a
  combination cannot connect at all (refused, timed out, wrong password, no Wi-Fi), the run stops
  at once and shows "Could not connect: <reason>" instead of a table of failures; a combination
  that connects but then fails (say, a format the server rejects) is listed as failed and the run
  goes on. Put what you usually look at on the PC's shared area and leave it still: each
  combination fetches that screen three times whole (the first is a warm-up and not counted) and
  then in 16 pieces (a 4×4 grid), each forced to be sent again even though nothing changed, and
  decodes and draws every piece at your current zoom and scaling. It is ranked by the pixels per
  second of the small pieces, the closest to everyday updates; the results also show the time per
  piece, the time for a full screen and the kilobytes a full screen took. **Apply best** saves
  the winner's four picture settings to the connection (nothing else; it takes effect on the next
  connection); **Cancel** or **Close** save nothing.
- **Sharp scaling (faster)**: a switch in the viewer menu, next to **Page buttons send**. It scales
  by repeating pixels instead of blending them: much faster redraws when the zoom is not 100% and
  crisper text, but uneven at non-whole zoom levels. It is one global setting (not per connection)
  and applies immediately to the live view.
- **Page buttons**: the menu's **Page buttons send** chooses what a device's page-turn buttons do.
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
standard library (plus `x11vnc` and `xrandr`: `sudo apt install x11vnc x11-xserver-utils`).
Run `tools/vnc-server.py -h` for every option.

```
tools/vnc-server.py --list                       # connected outputs and their geometry
tools/vnc-server.py                              # primary monitor, port 5900, asks for a password once
tools/vnc-server.py -o HDMI-1 -n                 # a named output, no password
tools/vnc-server.py -s 632x840 -O 0,40 -f        # top-left 632x840 below a 40 px taskbar, with a red frame
tools/vnc-server.py -s 632x840 -z 2 --sharp      # frames scaled 2x on the PC (1264x1680 for the reader)
tools/vnc-server.py -a 192.168.1.50 -p 5901 -- -viewonly   # only that client; extra args go to x11vnc
```

- `-s WxH` / `-O X,Y` select the area, handy to match the reader's screen size.
- `-z ZOOM` (`2`, `1.5`, `4/3`) makes x11vnc scale the frames before sending (`-scale`); `--sharp`
  adds nearest-neighbour scaling (no blending, crisper text). The start-up line shows the frame size
  the viewer will get, e.g. `-s 632x840 -z 2` gives 1264x1680 for a 1264x1680 screen. Set the viewer
  zoom to 100% then: the reader does no scaling and draws fastest, at the price of zoom² times the
  pixels to transfer and decode. The viewer menu's "Sharp scaling" is the client-side
  alternative that keeps the bandwidth low.
- `-f` draws a thin red frame (50% opacity with a compositor) just outside the shared area, so
  you can see what the reader shows. It is removed when the server stops; if it cannot be drawn
  you get one warning and the server runs without it.
- The password file is `./vnc.passwd` (change with `-P FILE`); it is created on first use.
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
against fake `x11vnc`/`xrandr` stubs). It needs only Python 3, no KOReader:

    python3 tools/test_vnc_server.py

Keep the scratch directories on the home filesystem: a quota-limited `/tmp` makes the suites fail
(its default locations are under `/tmp`). The UI suite needs a **fresh** `KO_HOME` — it reuses fixed
paths under it — and `SDL_VIDEODRIVER=dummy` keeps the SDL emulator from opening a window without
changing what the checks see. `NOTES.txt` has the rest of the pitfalls, the live end-to-end recipe
(mock server plus a real KOReader driven through its HTTP inspector) and the open ends.
