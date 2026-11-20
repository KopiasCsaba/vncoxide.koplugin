# Give your e-reader its own virtual monitor

These optional scripts run on your **Linux computer**. They create an extra X11
monitor sized for your reader and share that monitor through VNC. Move a window
onto the extra monitor to use it on the reader.

For ordinary desktop sharing, follow the [plugin connection instructions](../../README.md#quick-start).

## Requirements

1. An active **Xorg/X11 desktop session**. Run inside that session, with `DISPLAY`
   set. The VNC wrapper rejects Wayland sessions.
2. `xrandr`, `cvt`, and the kernel's `vkms` module. Loading `vkms` may require `sudo`.
   The X server must expose a usable `Virtual-*` output.
3. TigerVNC's **`x0vncserver` version 1.16 or newer**, plus `vncpasswd` to create a
   password file. The wrapper identifies `tigervnc-scraping-server` as its Debian
   package; check available versions on your distribution.

The scripts target Debian-based Xorg setups. Other desktop/driver combinations
are not documented as tested. Profiles specify dimensions, not tested hardware.

## Start a screen

From the repository root:

```bash
cd tools/screen-tools
cp .env.example .env
./start.sh -h
```

1. Edit `.env` and choose a `PROFILE` from the names printed by `./start.sh -h`.
   The example uses `pb700_portrait_halfsize`.
2. Pick portrait or landscape to match how you hold the reader. A `_halfsize`
   profile halves both dimensions, making applications larger when scaled to fit.
3. Start the monitor and server:

   ```bash
   ./start.sh
   ```

4. If prompted, authorize loading `vkms`, then create a VNC password. The wrapper
   saves its password file as `vnc.passwd` in this tools directory by default and
   reuses it on later runs.
5. Leave the terminal running. Connect from VNCoxide using the computer's address,
   `VNC_PORT` (default `5900`), and that VNC password.
6. Move a window onto the new monitor. It may show only your desktop background
   until you move a window there.

Choose a profile for one run without changing `.env`:

```bash
./start.sh pb700_landscape_halfsize
```

## Configure the layout

Load order: **built-in defaults → selected profile → `.env`**. A command-line
profile name selects the profile, but explicit values in `.env` still override
its dimensions and other settings.

| Setting in `.env` | Purpose |
| --- | --- |
| `PROFILE` | Profile name without the `.env` extension. |
| `VS_SIZE` | Optional `WIDTHxHEIGHT` override; leave commented to use the profile. |
| `VS_TARGET` | Output to place the virtual screen next to; empty means primary. |
| `VS_POS` | `right`, `left`, `above`, or `below` the target output. |
| `VS_RATE` | Virtual monitor refresh rate in Hz, independent of the e-ink panel refresh rate. |
| `VS_SETTLE` | Delay after monitor creation before starting the server. |
| `VNC_PORT` | TCP port clients connect to. |
| `VNC_OUTPUT` | Optional output override; normally leave unset. |
| `VNC_EXTRA` | Additional wrapper flags, such as a client address restriction. |

Find an output name for `VS_TARGET`:

```bash
./virtual-screen.sh outputs
```

The `.env` file is sourced as shell code. Only use configuration you trust.

## Restrict access

The wrapper uses classic VNC authentication by default, without transport
encryption. It does not restrict client addresses unless configured. Use a trusted
network or a separately configured secure tunnel; do not forward the port to the internet.

Allow only a reader whose address is `192.168.1.50` (replace with its actual address):

```bash
./start.sh pb700_portrait_halfsize -- -a 192.168.1.50
```

Choose a different password-file location with `-P`:

```bash
./start.sh pb700_portrait_halfsize -- -P ./reader.passwd
```

Keep password files private and out of version control. The wrapper also offers
`-n` to disable authentication; avoid that for normal use. Full wrapper options:

```bash
./x0vnc-server.sh -h
```

## Stop and clean up

Press **Ctrl+C** in the terminal running `start.sh`. Its exit handler switches off
the virtual output and tries to unload `vkms`. If X still uses the module, the
output stays off and the module remains loaded until logout or reboot.

If the process was forcibly terminated and cleanup did not run:

```bash
./virtual-screen.sh stop
```

## Share an existing monitor

Use the VNC wrapper without creating a virtual monitor:

```bash
./x0vnc-server.sh --list
./x0vnc-server.sh -o HDMI-1 -p 5900
```

Replace `HDMI-1` with an active output from `--list`. Use `-s WIDTHxHEIGHT` and
`-O X,Y` to share a smaller area with an offset.

## Troubleshooting

| Message or symptom | What to check |
| --- | --- |
| `DISPLAY is not set` | Run inside your logged-in X11 desktop session. |
| `Wayland session detected` | These scripts require an X11 session. |
| `x0vncserver … need >= 1.16` | Check the installed version; an older package does not meet the wrapper's requirement. |
| `no Virtual-* output appeared` | Check `xrandr --listproviders` and whether `vkms` loaded. The driver/X server setup must expose the virtual output. |
| `target … is not an active screen` | Run `./virtual-screen.sh outputs` and correct `VS_TARGET`. |
| `could not set …` | Check the requested size/rate and the X server's reported error. |
| Port already in use | Stop the conflicting server or change `VNC_PORT`, then use the same port on the reader. |
| Cannot connect from the reader | Check the computer address, firewall, port, `-a` restriction, and password. See [plugin troubleshooting](../../docs/USER_GUIDE.md#8-troubleshooting). |
