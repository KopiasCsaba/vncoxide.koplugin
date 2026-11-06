#!/usr/bin/env python3
"""Share one monitor (or part of it) of a running X11 session over VNC with x11vnc.

Standard library only - no venv needed. Optionally draws a thin red frame on the
PC screen just outside the shared area (-f).
"""
import argparse
import ctypes
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
from fractions import Fraction

APT_HINT = "Debian/Ubuntu: sudo apt install x11vnc x11-xserver-utils"
_LINE = re.compile(r"^(\S+) connected( primary)?\s*(?:(\d+)x(\d+)\+(\d+)\+(\d+))?")


def die(msg):
    raise SystemExit("error: " + msg)


def parse_xrandr(text):
    """Connected outputs: {name, primary, w, h, x, y}; w/h/x/y are None without an active mode."""
    res = []
    for line in text.splitlines():
        m = _LINE.match(line)
        if not m:
            continue
        geo = [int(g) if g is not None else None for g in m.groups()[2:]]
        res.append(dict(name=m.group(1), primary=bool(m.group(2)), w=geo[0], h=geo[1], x=geo[2], y=geo[3]))
    return res


def pick_output(outputs, name):
    names = " ".join(o["name"] for o in outputs)
    if name:
        for o in outputs:
            if o["name"] == name:
                if o["w"] is None:
                    die("output '%s' is connected but has no active mode" % name)
                return o
        die("output '%s' not connected. Outputs: %s" % (name, names))
    active = [o for o in outputs if o["w"] is not None]
    for o in active:
        if o["primary"]:
            return o
    if active:
        return active[0]
    die("no connected output with an active mode. Outputs: %s" % names)


def compute_area(out, size, offset):
    """(w, h, x, y) of the shared area in X screen coordinates."""
    m = re.fullmatch(r"(\d+),(\d+)", offset)
    if not m:
        die("-O must look like 0,40")
    dx, dy = int(m.group(1)), int(m.group(2))
    w, h = out["w"] - dx, out["h"] - dy
    if size:
        m = re.fullmatch(r"(\d+)x(\d+)", size)
        if not m:
            die("-s must look like 632x840")
        w, h = int(m.group(1)), int(m.group(2))
    if not (w > 0 and h > 0 and dx + w <= out["w"] and dy + h <= out["h"]):
        die("area %dx%d at offset %d,%d does not fit in %s (%dx%d)" % (w, h, dx, dy, out["name"], out["w"], out["h"]))
    return w, h, out["x"] + dx, out["y"] + dy


def frame_rects(area, out):
    """1 px lines just outside area, top/bottom extended over the corners; sides beyond out are dropped."""
    w, h, x, y = area
    ox0, oy0, ox1, oy1 = out["x"], out["y"], out["x"] + out["w"], out["y"] + out["h"]
    hx0, hx1 = max(x - 1, ox0), min(x + w + 1, ox1)
    rects = []
    if y - 1 >= oy0:
        rects.append((hx0, y - 1, hx1 - hx0, 1))
    if x - 1 >= ox0:
        rects.append((x - 1, y, 1, h))
    if x + w < ox1:
        rects.append((x + w, y, 1, h))
    if y + h < oy1:
        rects.append((hx0, y + h, hx1 - hx0, 1))
    return rects


def parse_zoom(zoom, sharp):
    """(x11vnc -scale value or None, numeric factor) from -z/--sharp; factor 1 means no scaling."""
    if zoom is None:
        if sharp:
            die("--sharp needs -z")
        return None, 1
    m = re.fullmatch(r"(\d+(?:\.\d+)?)|(\d+)/(\d+)", zoom)
    factor = 0
    if m:
        factor = Fraction(zoom) if m.group(1) else Fraction(int(m.group(2)), int(m.group(3))) if int(m.group(3)) else 0
    if factor <= 0:
        die("-z must look like 2, 1.5 or 4/3")
    if factor == 1:
        if sharp:
            die("--sharp needs -z other than 1")
        return None, 1
    return zoom + (":nb" if sharp else ""), factor


def build_cmd(display, area, port, auth, allow, extra, scale=None, gentle=False, noxdamage=False):
    w, h, x, y = area
    cmd = ["x11vnc", "-display", display, "-clip", "%dx%d+%d+%d" % (w, h, x, y)]
    if scale:
        cmd += ["-scale", scale]
        if noxdamage:
            # x11vnc's X DAMAGE hints made every request ~170 ms slower with -scale on a real
            # display (measured; ~8 ms with this flag). x11vnc then scans the screen itself.
            cmd += ["-noxdamage"]
    cmd += ["-rfbport", str(port)] + list(auth)
    if allow:
        cmd += ["-allow", allow]
    # -cursor arrow: pointer drawn into the image (visible on e-ink); -wait/-defer: 5/0 answer
    # at once (~6 ms per request, measured), --gentle batches with 50/100 (~145 ms slower).
    wait, defer = ("50", "100") if gentle else ("5", "0")
    return cmd + ["-forever", "-shared", "-cursor", "arrow", "-wait", wait, "-defer", defer,
                  "-noxrecord", "-ncache", "0"] + list(extra)


class _SetWinAttrs(ctypes.Structure):
    _fields_ = [("background_pixmap", ctypes.c_ulong), ("background_pixel", ctypes.c_ulong),
                ("border_pixmap", ctypes.c_ulong), ("border_pixel", ctypes.c_ulong),
                ("bit_gravity", ctypes.c_int), ("win_gravity", ctypes.c_int),
                ("backing_store", ctypes.c_int), ("backing_planes", ctypes.c_ulong),
                ("backing_pixel", ctypes.c_ulong), ("save_under", ctypes.c_int),
                ("event_mask", ctypes.c_long), ("do_not_propagate_mask", ctypes.c_long),
                ("override_redirect", ctypes.c_int), ("colormap", ctypes.c_ulong),
                ("cursor", ctypes.c_ulong)]


class _XColor(ctypes.Structure):
    _fields_ = [("pixel", ctypes.c_ulong), ("red", ctypes.c_ushort), ("green", ctypes.c_ushort),
                ("blue", ctypes.c_ushort), ("flags", ctypes.c_char), ("pad", ctypes.c_char)]


class Frame:
    """Red 1 px lines as override-redirect X windows (click-through, no events). Never raises."""
    RERAISE_SECS = 3.0

    def __init__(self, display, rects):
        self.display, self.rects = display, rects
        self.x = self.dpy = None
        self.wins = []
        self._stop = threading.Event()
        self._thread = None

    def start(self):
        try:
            self._open()
        except Exception as e:  # missing lib, no display, ctypes mismatch ...
            print("warning: frame disabled (%s)" % e, file=sys.stderr)
            self._teardown()
            return False
        self._thread = threading.Thread(target=self._reraise_loop, daemon=True)
        self._thread.start()
        return True

    def raise_(self):
        if self.dpy:
            for w in self.wins:
                self.x.XRaiseWindow(self.dpy, w)
            self.x.XFlush(self.dpy)

    def close(self):
        self._stop.set()
        if self._thread:
            self._thread.join(2)
        self._teardown()

    def _reraise_loop(self):
        while not self._stop.wait(self.RERAISE_SECS):
            self.raise_()

    def _open(self):
        c = ctypes
        x = self.x = c.CDLL("libX11.so.6")
        P, UL, I, U = c.c_void_p, c.c_ulong, c.c_int, c.c_uint
        sig = {"XInitThreads": (I, []), "XOpenDisplay": (P, [c.c_char_p]),
               "XDefaultRootWindow": (UL, [P]), "XDefaultScreen": (I, [P]), "XDefaultColormap": (UL, [P, I]),
               "XAllocColor": (I, [P, UL, c.POINTER(_XColor)]),
               "XCreateSimpleWindow": (UL, [P, UL, I, I, U, U, U, UL, UL]),
               "XChangeWindowAttributes": (I, [P, UL, UL, c.POINTER(_SetWinAttrs)]),
               "XInternAtom": (UL, [P, c.c_char_p, I]),
               "XChangeProperty": (I, [P, UL, UL, UL, I, I, c.c_void_p, I]),
               "XMapRaised": (I, [P, UL]), "XRaiseWindow": (I, [P, UL]), "XFlush": (I, [P]),
               "XDestroyWindow": (I, [P, UL]), "XCloseDisplay": (I, [P])}
        for name, (res, args) in sig.items():
            f = getattr(x, name)
            f.restype, f.argtypes = res, args
        x.XInitThreads()
        self.dpy = x.XOpenDisplay(self.display.encode())
        if not self.dpy:
            raise RuntimeError("cannot open display %s" % self.display)
        dpy = self.dpy
        pixel = 0xFF0000  # fallback for a TrueColor default visual
        red = _XColor(0, 0xFFFF, 0, 0, 7, 0)
        if x.XAllocColor(dpy, x.XDefaultColormap(dpy, x.XDefaultScreen(dpy)), c.byref(red)):
            pixel = red.pixel
        root = x.XDefaultRootWindow(dpy)
        attrs = _SetWinAttrs(override_redirect=1)
        atom = x.XInternAtom(dpy, b"_NET_WM_WINDOW_OPACITY", 0)
        opacity = (c.c_long * 1)(0x7FFFFFFF)
        for (rx, ry, rw, rh) in self.rects:
            win = x.XCreateSimpleWindow(dpy, root, rx, ry, rw, rh, 0, pixel, pixel)
            self.wins.append(win)
            x.XChangeWindowAttributes(dpy, win, 1 << 9, c.byref(attrs))  # CWOverrideRedirect
            x.XChangeProperty(dpy, win, atom, 6, 32, 0, opacity, 1)  # XA_CARDINAL, PropModeReplace
            x.XMapRaised(dpy, win)
        x.XFlush(dpy)

    def _teardown(self):
        if self.dpy:
            for w in self.wins:
                self.x.XDestroyWindow(self.dpy, w)
            self.x.XCloseDisplay(self.dpy)
        self.dpy, self.wins = None, []


def make_parser():
    p = argparse.ArgumentParser(
        prog="vnc-server.py",
        description="Share one monitor (or part of it) of the running X11 session over VNC (x11vnc). "
                    "Standard library only.",
        epilog="Anything after -- is passed to x11vnc, e.g.: vnc-server.py -s 632x840 -- -viewonly")
    p.add_argument("-o", metavar="OUTPUT", help="xrandr output name (default: primary output)")
    p.add_argument("-s", metavar="WxH", help="share only the top-left WxH of the output, e.g. 632x840")
    p.add_argument("-O", metavar="X,Y", default="0,0",
                   help="offset of the shared area from the output's top-left, e.g. 0,40 to skip a taskbar")
    p.add_argument("-z", metavar="ZOOM",
                   help="scale the frame server-side (x11vnc -scale), e.g. 2, 1.5 or 4/3; "
                        "use 100%% zoom in the viewer then")
    p.add_argument("--sharp", action="store_true", help="with -z: nearest-neighbour scaling (no blending)")
    p.add_argument("--xdamage", action="store_true",
                   help="with -z: keep X DAMAGE hints (slower, see README)")
    p.add_argument("--gentle", action="store_true",
                   help="batch screen updates (-wait 50 -defer 100): less CPU on the PC, about 145 ms slower updates")
    p.add_argument("-p", metavar="PORT", type=int, default=5900, help="TCP port (default: 5900)")
    p.add_argument("-a", metavar="IPS", help="comma list of allowed client IPs/prefixes (default: any)")
    p.add_argument("-n", action="store_true", help="no password (otherwise uses/creates the -P file)")
    p.add_argument("-P", metavar="FILE", default="vnc.passwd", help="password file (default: ./vnc.passwd)")
    p.add_argument("-d", metavar="DISPLAY", help="X display (default: $DISPLAY, else :0)")
    p.add_argument("-f", action="store_true",
                   help="draw a thin red frame just outside the shared area on the PC screen")
    p.add_argument("--list", action="store_true", help="list connected outputs and exit")
    return p


def _run(cmd, frame_rects_=None, display=":0"):
    proc = None
    stop_sig = []

    def forward(signum, _frame):
        stop_sig.append(signum)
        if proc and proc.poll() is None:
            proc.send_signal(signum)

    old = {s: signal.signal(s, forward) for s in (signal.SIGINT, signal.SIGTERM)}
    frame = None
    try:
        try:
            proc = subprocess.Popen(cmd, start_new_session=True)  # our forwarded signal is its only SIGINT
        except OSError as e:
            die("cannot start x11vnc: %s" % e)
        for s in stop_sig:  # signal that arrived before Popen returned
            proc.send_signal(s)
        if frame_rects_:
            frame = Frame(display, frame_rects_)
            frame.start()
        rc = proc.wait()
    finally:
        if frame:
            frame.close()
        for s, h in old.items():
            signal.signal(s, h)
    return rc if rc >= 0 else 128 - rc


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    extra = []
    if "--" in argv:
        i = argv.index("--")
        argv, extra = argv[:i], argv[i + 1:]
    args = make_parser().parse_args(argv)
    try:
        return _main(args, extra)
    except SystemExit as e:
        if isinstance(e.code, str):
            print(e.code, file=sys.stderr)
            return 1
        raise


def _main(args, extra):
    scale, factor = parse_zoom(args.z, args.sharp)
    display = args.d or os.environ.get("DISPLAY") or ":0"
    need = ["xrandr"] if args.list else ["x11vnc", "xrandr"]
    for c in need:
        if not shutil.which(c):
            die("'%s' not found (%s)" % (c, APT_HINT))
    if os.environ.get("XDG_SESSION_TYPE", "x11") == "wayland":
        die("Wayland session detected; x11vnc needs an X11 session")
    env = dict(os.environ, DISPLAY=display)
    r = subprocess.run(["xrandr", "--query"], env=env, capture_output=True, text=True)
    if r.returncode != 0:
        die("xrandr failed: %s" % (r.stderr.strip() or "exit %d" % r.returncode))
    outputs = parse_xrandr(r.stdout)
    if args.list:
        for o in outputs:
            geo = "%dx%d+%d+%d" % (o["w"], o["h"], o["x"], o["y"]) if o["w"] is not None else "(no active mode)"
            print("%s %s%s" % (o["name"], geo, " primary" if o["primary"] else ""))
        return 0
    out = pick_output(outputs, args.o)
    area = compute_area(out, args.s, args.O)
    auth = ["-nopw"]
    if not args.n:
        if not (os.path.isfile(args.P) and os.path.getsize(args.P) > 0):
            print("Set a VNC password (max 8 chars, VNC protocol limit):", flush=True)
            if subprocess.call(["x11vnc", "-storepasswd", args.P]) != 0:
                die("could not store the VNC password in %s" % args.P)
        auth = ["-rfbauth", args.P]
    w, h, x, y = area
    note = ""
    noxdamage = bool(scale) and not args.xdamage
    if scale:
        note = " scaled %s%s -> %dx%d" % (args.z, " sharp" if args.sharp else "", round(w * factor), round(h * factor))
        if noxdamage:
            note += " (no damage hints)"
    print("Sharing %s (%dx%d+%d+%d) of %s on port %d%s" % (out["name"], w, h, x, y, display, args.p, note),
          flush=True)
    cmd = build_cmd(display, area, args.p, auth, args.a, extra, scale, args.gentle, noxdamage)
    rects = frame_rects(area, out) if args.f else None
    if args.f and not rects:
        print("warning: frame disabled (shared area fills the whole output)", file=sys.stderr)
    return _run(cmd, rects, display)


if __name__ == "__main__":
    sys.exit(main())
