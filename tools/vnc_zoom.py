"""Small RFB 3.8 server that serves a zoomed part of an X11 screen (used by vnc-server.py -z).

x11vnc's "-clip ... -scale ..." clamps the arrow it paints to the unscaled clip size, so the
pointer looks stuck in the top-left part of the frame. Here ffmpeg grabs the area with the real
pointer drawn in, scales it and converts it straight into the client's pixel format; this module
only diffs 64x64 tiles, encodes them (ZRLE or Raw) and injects input with XTest.

Python 3 standard library only (+ ctypes to libX11/libXtst); external program: ffmpeg.
"""
import ctypes
import ipaddress
import os
import secrets
import selectors
import socket
import struct
import subprocess
import sys
import threading
import time
import zlib

TILE = 64

# ---------------------------------------------------------------- DES (VNC authentication) ---

_PC1 = [57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3,
        60, 52, 44, 36, 63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45,
        37, 29, 21, 13, 5, 28, 20, 12, 4]
_PC2 = [14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
        41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32]
_SHIFTS = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
_IP = [58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6,
       64, 56, 48, 40, 32, 24, 16, 8, 57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
       61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7]
_FP = [_IP.index(i) + 1 for i in range(1, 65)]
_E = [32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17, 16, 17,
      18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1]
_P = [16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10, 2, 8, 24, 14, 32, 27, 3, 9, 19,
      13, 30, 6, 22, 11, 4, 25]
_S = [
    [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
     4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
     0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
     13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
     10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
     4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
     9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
     1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
     7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
]


def _perm(v, table, nbits):
    out = 0
    for p in table:
        out = (out << 1) | ((v >> (nbits - p)) & 1)
    return out


def _subkeys(key):
    k = _perm(int.from_bytes(key, "big"), _PC1, 64)
    c, d = k >> 28, k & 0xFFFFFFF
    res = []
    for s in _SHIFTS:
        c = ((c << s) | (c >> (28 - s))) & 0xFFFFFFF
        d = ((d << s) | (d >> (28 - s))) & 0xFFFFFFF
        res.append(_perm((c << 28) | d, _PC2, 56))
    return res


def _des_block(subkeys, block):
    v = _perm(int.from_bytes(block, "big"), _IP, 64)
    l, r = v >> 32, v & 0xFFFFFFFF
    for k in subkeys:
        x = _perm(r, _E, 32) ^ k
        f = 0
        for i in range(8):
            six = (x >> (42 - 6 * i)) & 0x3F
            f = (f << 4) | _S[i][((six & 0x20) | ((six & 1) << 4)) | ((six >> 1) & 0xF)]
        l, r = r, l ^ _perm(f, _P, 32)
    return _perm((r << 32) | l, _FP, 64).to_bytes(8, "big")


def des_encrypt(key, data):
    """Standard DES-ECB (key: 8 bytes, data: multiple of 8 bytes)."""
    ks = _subkeys(key)
    return b"".join(_des_block(ks, data[i:i + 8]) for i in range(0, len(data), 8))


def des_decrypt(key, data):
    ks = _subkeys(key)[::-1]
    return b"".join(_des_block(ks, data[i:i + 8]) for i in range(0, len(data), 8))


def _vnc_key(key):
    """VNC uses each key byte with its bits mirrored (d3des bit order)."""
    key = bytes(key[:8]).ljust(8, b"\0")
    return bytes(int("{:08b}".format(b)[::-1], 2) for b in key)


PASSWD_KEY = bytes([23, 82, 107, 6, 35, 78, 88, 7])  # fixed key of x11vnc -storepasswd / vncpasswd


def vnc_response(password, challenge):
    """What a client answers to a 16 byte VNC Authentication challenge."""
    return des_encrypt(_vnc_key(password), challenge)


def read_passwd(path):
    """Password (bytes) from an x11vnc -storepasswd file."""
    with open(path, "rb") as f:
        data = f.read(8)
    if len(data) < 8:
        raise ValueError("%s is not a VNC password file (too short)" % path)
    return des_decrypt(_vnc_key(PASSWD_KEY), data).split(b"\0", 1)[0]


def write_passwd(path, password):
    """Store password (bytes, up to 8 used) like x11vnc -storepasswd: 8 DES-encrypted bytes."""
    data = des_encrypt(_vnc_key(PASSWD_KEY), bytes(password[:8]).ljust(8, b"\0"))
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        os.fchmod(fd, 0o600)
        f.write(data)


# ------------------------------------------------------------------------- pixel formats ---

# (bits_per_pixel, big_endian (None: any), red/green/blue max, red/green/blue shift) -> ffmpeg pix_fmt
FORMATS = {
    (32, 0, 255, 255, 255, 0, 8, 16): "rgb0",
    (32, 0, 255, 255, 255, 16, 8, 0): "bgr0",
    (16, 0, 31, 63, 31, 11, 5, 0): "rgb565le",
    (8, None, 7, 7, 3, 0, 3, 6): "bgr8",
}
# What ServerInit advertises (= the viewer's own 24 bit format): R, G, B, 0 in memory.
DEFAULT_PF = dict(bpp=32, depth=24, big_endian=0, true_colour=1, red_max=255, green_max=255, blue_max=255,
                  red_shift=0, green_shift=8, blue_shift=16)


def pack_pf(pf):
    return struct.pack(">BBBBHHHBBB3x", pf["bpp"], pf["depth"], pf["big_endian"], pf["true_colour"],
                       pf["red_max"], pf["green_max"], pf["blue_max"],
                       pf["red_shift"], pf["green_shift"], pf["blue_shift"])


def unpack_pf(b):
    k = ("bpp", "depth", "big_endian", "true_colour", "red_max", "green_max", "blue_max",
         "red_shift", "green_shift", "blue_shift")
    return dict(zip(k, struct.unpack(">BBBBHHHBBB3x", b)))


def pf_to_ffmpeg(pf):
    """ffmpeg pix_fmt that produces exactly this RFB pixel format, or None."""
    if not pf["true_colour"]:
        return None
    rest = (pf["red_max"], pf["green_max"], pf["blue_max"], pf["red_shift"], pf["green_shift"], pf["blue_shift"])
    for (bpp, be, *r), name in FORMATS.items():
        if bpp == pf["bpp"] and (be is None or be == pf["big_endian"]) and tuple(r) == rest:
            return name
    return None


def cpixel_bytes(pf):
    """Bytes per ZRLE CPIXEL: 3 for 32 bpp with depth <= 24 (all our 32 bpp formats use bytes 0-2)."""
    return 3 if pf["bpp"] == 32 and pf["depth"] <= 24 else pf["bpp"] // 8


def describe_pf(pf):
    return ("bpp %(bpp)d depth %(depth)d %(e)s true_colour %(true_colour)d max %(red_max)d/%(green_max)d/"
            "%(blue_max)d shift %(red_shift)d/%(green_shift)d/%(blue_shift)d"
            % dict(pf, e="big-endian" if pf["big_endian"] else "little-endian"))


# --------------------------------------------------------------------- tiles and encoding ---

def tiles_in(rect, w, h):
    """Grid tiles (TILE x TILE) cut to rect=(x, y, w, h), itself clipped to the w x h frame."""
    x0, y0 = max(rect[0], 0), max(rect[1], 0)
    x1, y1 = min(rect[0] + rect[2], w), min(rect[1] + rect[3], h)
    res = []
    for ty in range(y0 - y0 % TILE, y1, TILE):
        for tx in range(x0 - x0 % TILE, x1, TILE):
            ax, ay = max(tx, x0), max(ty, y0)
            res.append((ax, ay, min(tx + TILE, x1) - ax, min(ty + TILE, y1) - ay))
    return res


def tile_bytes(frame, stride, bpp, t):
    x, y, w, h = t
    o, n = y * stride + x * bpp, w * bpp
    return b"".join([frame[o + i * stride:o + i * stride + n] for i in range(h)])


def changed_tiles(frame, shown, stride, bpp, tiles, force=()):
    """Tiles whose pixels differ between frame and shown (all of them if shown is None)."""
    if shown is None or len(shown) != len(frame):
        return list(tiles)
    res = []
    for t in tiles:
        x, y, w, h = t
        if t in force:
            res.append(t)
            continue
        o, n = y * stride + x * bpp, w * bpp
        for i in range(h):
            a = o + i * stride
            if frame[a:a + n] != shown[a:a + n]:
                res.append(t)
                break
    return res


def copy_tiles(dst, frame, stride, bpp, tiles):
    for x, y, w, h in tiles:
        o, n = y * stride + x * bpp, w * bpp
        for i in range(h):
            a = o + i * stride
            dst[a:a + n] = frame[a:a + n]


def zrle_tile(data, bpp, cbytes):
    """ZRLE tile payload (before zlib): solid (1) if all pixels are equal, else raw CPIXELs (0)."""
    first = data[:bpp]
    if data == first * (len(data) // bpp):
        return b"\x01" + first[:cbytes]
    if cbytes == bpp:
        return b"\x00" + data
    ba = bytearray(data)
    del ba[3::4]
    return b"\x00" + bytes(ba)


ENC_RAW, ENC_ZRLE = 0, 16


def encode_update(frame, stride, bpp, cbytes, tiles, enc, zobj=None):
    """A whole FramebufferUpdate message, one rectangle per tile."""
    out = [struct.pack(">BxH", 0, len(tiles))]
    for t in tiles:
        data = tile_bytes(frame, stride, bpp, t)
        out.append(struct.pack(">HHHHi", t[0], t[1], t[2], t[3], enc))
        if enc == ENC_ZRLE:
            z = zobj.compress(zrle_tile(data, bpp, cbytes)) + zobj.flush(zlib.Z_SYNC_FLUSH)
            out.append(struct.pack(">I", len(z)))
            out.append(z)
        else:
            out.append(data)
    return b"".join(out)


def map_pointer(x, y, area, factor):
    """Frame coordinates (zoomed) -> X screen coordinates, clamped inside the shared area."""
    w, h, ax, ay = area
    fx = (max(x, 0) * factor.denominator) // factor.numerator
    fy = (max(y, 0) * factor.denominator) // factor.numerator
    return ax + min(fx, w - 1), ay + min(fy, h - 1)


def zoomed_size(area, factor):
    return round(area[0] * factor), round(area[1] * factor)


# ---------------------------------------------------------------------- capture (ffmpeg) ---

def ffmpeg_cmd(display, area, size, pix_fmt, fps, sharp):
    w, h, x, y = area
    # neighbor: crisp pixel copies; area: blends (bilinear-like when enlarging, averaging when
    # shrinking), no overshoot halos around text like bicubic/lanczos.
    flt = "neighbor" if sharp else "area"
    # Scale in 32 bpp, then convert unscaled with flags=neighbor and no dithering: scaling straight
    # into rgb565le/bgr8 dithered (and gave wrong rgb565le colours on narrow test frames, ffmpeg
    # 7.1); this way 16/8 bpp are plain truncations of the 32 bpp frame (measured).
    vf = "scale=%d:%d:flags=%s,format=bgr0,scale=flags=neighbor:sws_dither=none,format=%s" % (
        size[0], size[1], flt, pix_fmt)
    return ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "1",
            "-framerate", str(fps), "-video_size", "%dx%d" % (w, h), "-i", "%s+%d,%d" % (display, x, y),
            # -threads 1: with ffmpeg's default threading a change reached us after ~220 ms instead
            # of ~20 ms (measured, ffmpeg 7.1 at 10 fps).
            "-vf", vf, "-threads", "1", "-f", "rawvideo", "-pix_fmt", pix_fmt, "-flush_packets", "1", "-"]


class Capture:
    """One ffmpeg process; a thread keeps only the newest frame and notifies cond on changes."""

    def __init__(self, cmd, frame_size, cond):
        self.cmd, self.size, self.cond = cmd, frame_size, cond
        self.frame, self.seq, self.error = None, 0, None
        self.proc = None

    def start(self):
        self.proc = subprocess.Popen(self.cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, bufsize=0, start_new_session=True)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        f, n = self.proc.stdout, self.size
        buf = bytearray(n)
        mv = memoryview(buf)
        while True:
            got = 0
            while got < n:
                k = f.readinto(mv[got:])
                if not k:
                    break
                got += k
            if got < n:
                break
            frame = bytes(buf)
            with self.cond:
                if frame != self.frame:
                    self.frame = frame
                    self.seq += 1
                    self.cond.notify_all()
        rc = self.proc.wait()
        err = self.proc.stderr.read().decode(errors="replace").strip()
        with self.cond:
            self.error = "ffmpeg exited (%s)%s" % (rc, ": " + err.splitlines()[-1] if err else "")
            self.cond.notify_all()

    def stop(self):
        p = self.proc
        if p and p.poll() is None:
            p.terminate()
            try:
                p.wait(2)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()


# ------------------------------------------------------------------------- input (XTest) ---

XK_SHIFT_L, XK_SHIFT_R = 0xFFE1, 0xFFE2


class XInput:
    """Pointer and key injection through XTest on one display connection."""

    def __init__(self, display):
        c = ctypes
        x = self.x = c.CDLL("libX11.so.6")
        t = self.t = c.CDLL("libXtst.so.6")
        P, UL, I, U = c.c_void_p, c.c_ulong, c.c_int, c.c_uint
        for lib, name, res, args in [
                (x, "XInitThreads", I, []), (x, "XOpenDisplay", P, [c.c_char_p]), (x, "XFlush", I, [P]),
                (x, "XSync", I, [P, I]), (x, "XCloseDisplay", I, [P]), (x, "XFree", I, [P]),
                (x, "XKeysymToKeycode", c.c_ubyte, [P, UL]),
                (x, "XDisplayKeycodes", I, [P, c.POINTER(I), c.POINTER(I)]),
                (x, "XGetKeyboardMapping", c.POINTER(UL), [P, c.c_ubyte, I, c.POINTER(I)]),
                (x, "XChangeKeyboardMapping", I, [P, I, I, c.POINTER(UL), I]),
                (t, "XTestFakeMotionEvent", I, [P, I, I, I, UL]),
                (t, "XTestFakeButtonEvent", I, [P, U, I, UL]),
                (t, "XTestFakeKeyEvent", I, [P, U, I, UL])]:
            f = getattr(lib, name)
            f.restype, f.argtypes = res, args
        x.XInitThreads()
        self.dpy = x.XOpenDisplay(display.encode())
        if not self.dpy:
            raise RuntimeError("cannot open display %s" % display)
        self.lock = threading.Lock()
        lo, hi = c.c_int(), c.c_int()
        x.XDisplayKeycodes(self.dpy, c.byref(lo), c.byref(hi))
        self.kc_range = (lo.value, hi.value)
        # Unused keycodes for keysyms no key has, from the top: XKB clients looked up NoSymbol on
        # keycode 8 even after binding it (measured on Xvfb). A rebound keycode is read with its new
        # keysym by clients that process the event late, hence round robin over all of them.
        self.spare = [kc for kc in range(hi.value, max(lo.value, 9) - 1, -1) if not any(self._syms(kc))]
        self.bound = {}  # keysym -> spare keycode we bound it to
        self.shift_kc = x.XKeysymToKeycode(self.dpy, XK_SHIFT_L)

    def _syms(self, kc):
        c = ctypes
        per = c.c_int()
        p = self.x.XGetKeyboardMapping(self.dpy, kc, 1, c.byref(per))
        if not p:
            return []
        res = [p[i] for i in range(per.value)]
        self.x.XFree(p)
        return res

    def pointer(self, x, y, old_mask, mask):
        with self.lock:
            if not self.dpy:
                return
            self.t.XTestFakeMotionEvent(self.dpy, -1, x, y, 0)
            for b in range(8):
                bit = 1 << b
                if (old_mask ^ mask) & bit:
                    self.t.XTestFakeButtonEvent(self.dpy, b + 1, 1 if mask & bit else 0, 0)
            self.x.XFlush(self.dpy)

    def _keycode(self, keysym):
        """(keycode, needs Shift) for keysym; binds it to a spare keycode if nothing has it."""
        if keysym in self.bound:
            return self.bound[keysym], False
        kc = self.x.XKeysymToKeycode(self.dpy, keysym)
        if kc:
            syms = self._syms(kc)
            if syms[:1] == [keysym]:
                return kc, False
            if syms[1:2] == [keysym]:
                return kc, True
        if not self.spare:
            return 0, False
        kc = self.spare.pop(0)
        self.spare.append(kc)  # round robin when they run out
        for k, v in list(self.bound.items()):
            if v == kc:
                del self.bound[k]
        arr = (ctypes.c_ulong * 2)(keysym, keysym)
        self.x.XChangeKeyboardMapping(self.dpy, kc, 2, arr, 1)
        self.x.XSync(self.dpy, 0)
        # Give clients time to take the new mapping before the key arrives: pressed at once, xev
        # often looked up NoSymbol; 50 ms later it got the keysym (measured on Xvfb). Once per keysym.
        time.sleep(0.05)
        self.bound[keysym] = kc
        return kc, False

    def key(self, keysym, down, held, client_shift):
        """held: this client's {keysym: keycode} of pressed keys."""
        with self.lock:
            if not self.dpy:
                return
            if down:
                kc, shift = self._keycode(keysym)
                if not kc:
                    return
                held[keysym] = kc
                fake = shift and not client_shift and self.shift_kc
                if fake:
                    self.t.XTestFakeKeyEvent(self.dpy, self.shift_kc, 1, 0)
                self.t.XTestFakeKeyEvent(self.dpy, kc, 1, 0)
                if fake:
                    self.t.XTestFakeKeyEvent(self.dpy, self.shift_kc, 0, 0)
            else:
                kc = held.pop(keysym, 0)
                if not kc:
                    return
                self.t.XTestFakeKeyEvent(self.dpy, kc, 0, 0)
            self.x.XFlush(self.dpy)

    def release_all(self, held, mask):
        with self.lock:
            if not self.dpy:
                return
            for kc in held.values():
                self.t.XTestFakeKeyEvent(self.dpy, kc, 0, 0)
            for b in range(8):
                if mask & (1 << b):
                    self.t.XTestFakeButtonEvent(self.dpy, b + 1, 0, 0)
            self.x.XFlush(self.dpy)
        held.clear()

    def close(self):
        with self.lock:
            if self.dpy:
                self.x.XCloseDisplay(self.dpy)
                self.dpy = None


# -------------------------------------------------------------------------------- server ---

def log(msg):
    print(msg, file=sys.stderr, flush=True)


class _Closed(Exception):
    pass


def _recv(sock, n):
    buf = bytearray()
    while len(buf) < n:
        k = sock.recv(n - len(buf))
        if not k:
            raise _Closed()
        buf += k
    return bytes(buf)


class Client:
    def __init__(self, server, sock, addr):
        self.srv, self.sock, self.addr = server, sock, addr
        self.cond = threading.Condition()
        self.pf = dict(DEFAULT_PF)
        self.enc, self.level = ENC_RAW, 6
        self.zobj = None
        self.req = None        # pending (x0, y0, x1, y1) union of requested areas
        self.force = set()     # tiles a non-incremental request asked for
        self.new_req = False
        self.capture = None
        self.shown = None      # what this client has, in its current pixel format
        self.closed = False
        self.held, self.mask = {}, 0

    def log(self, msg):
        log("client %s: %s" % (self.addr, msg))

    # -- handshake --------------------------------------------------------------------------
    def handshake(self):
        s = self.sock
        s.sendall(b"RFB 003.008\n")
        ver = _recv(s, 12)
        if not (ver.startswith(b"RFB 003.") and ver.endswith(b"\n")):
            raise _Closed("bad protocol version %r" % ver)
        minor = int(ver[8:11]) if ver[8:11].isdigit() else 0
        pw = self.srv.password
        sec = 2 if pw is not None else 1
        if minor >= 7:
            s.sendall(bytes([1, sec]))
            if _recv(s, 1)[0] != sec:
                raise _Closed("client chose an unsupported security type")
        else:
            s.sendall(struct.pack(">I", sec))
        if sec == 2:
            chal = secrets.token_bytes(16)
            s.sendall(chal)
            if _recv(s, 16) != vnc_response(pw, chal):
                msg = b"Authentication failed"
                s.sendall(struct.pack(">I", 1) + (struct.pack(">I", len(msg)) + msg if minor >= 8 else b""))
                raise _Closed("authentication failed")
            s.sendall(struct.pack(">I", 0))
        elif minor >= 8:
            s.sendall(struct.pack(">I", 0))
        _recv(s, 1)  # ClientInit shared flag: we always share
        name = b"vnc-server.py zoom"
        w, h = self.srv.size
        s.sendall(struct.pack(">HH", w, h) + pack_pf(DEFAULT_PF) + struct.pack(">I", len(name)) + name)

    # -- client messages (this thread) ------------------------------------------------------
    def run(self):
        writer = None
        try:
            self.handshake()
            self.log("connected")
            writer = threading.Thread(target=self._writer, daemon=True)
            writer.start()
            while True:
                self._message()
        except _Closed as e:
            self.log(e.args[0] if e.args else "disconnected")
        except OSError as e:
            self.log("disconnected (%s)" % e)
        finally:
            with self.cond:
                self.closed = True
                cap, self.capture = self.capture, None
                self.cond.notify_all()
            if cap:
                cap.stop()
            if self.srv.xin:
                self.srv.xin.release_all(self.held, self.mask)
            try:
                self.sock.close()
            except OSError:
                pass
            if writer:
                writer.join(5)
            self.srv.forget(self)

    def _message(self):
        s = self.sock
        t = _recv(s, 1)[0]
        if t == 0:
            pf = unpack_pf(_recv(s, 19)[3:])
            if not pf_to_ffmpeg(pf):
                raise _Closed("unsupported pixel format (%s), closing" % describe_pf(pf))
            with self.cond:
                if pf != self.pf:
                    self.pf, self.shown = pf, None
                    cap, self.capture = self.capture, None
                else:
                    cap = None
                self.cond.notify_all()
            if cap:
                cap.stop()
        elif t == 2:
            n = struct.unpack(">xH", _recv(s, 3))[0]
            encs = struct.unpack(">%di" % n, _recv(s, 4 * n))
            with self.cond:
                self.enc = ENC_ZRLE if ENC_ZRLE in encs else ENC_RAW
                lv = [e + 256 for e in encs if -256 <= e <= -247]
                if lv and self.zobj is None:
                    self.level = lv[0]
        elif t == 3:
            inc, x, y, w, h = struct.unpack(">BHHHH", _recv(s, 9))
            fw, fh = self.srv.size
            x1, y1 = min(x + w, fw), min(y + h, fh)
            if x >= x1 or y >= y1:
                return
            with self.cond:
                r = self.req
                self.req = (x, y, x1, y1) if r is None else (min(r[0], x), min(r[1], y), max(r[2], x1), max(r[3], y1))
                if not inc:
                    self.force.update(tiles_in((x, y, x1 - x, y1 - y), fw, fh))
                self.new_req = True
                self.cond.notify_all()
        elif t == 4:
            down, keysym = struct.unpack(">B2xI", _recv(s, 7))
            if self.srv.xin:
                shift = any(k in self.held for k in (XK_SHIFT_L, XK_SHIFT_R))
                self.srv.xin.key(keysym, bool(down), self.held, shift)
        elif t == 5:
            mask, x, y = struct.unpack(">BHH", _recv(s, 5))
            if self.srv.xin:
                px, py = map_pointer(x, y, self.srv.area, self.srv.factor)
                self.srv.xin.pointer(px, py, self.mask, mask)
            self.mask = mask
        elif t == 6:
            n = struct.unpack(">3xI", _recv(s, 7))[0]
            while n > 0:  # drop the text
                n -= len(_recv(s, min(n, 65536)))
        else:
            raise _Closed("unknown message type %d, closing" % t)

    # -- updates (writer thread) ------------------------------------------------------------
    def _writer(self):
        srv = self.srv
        fw, fh = srv.size
        checked = None  # (capture, seq) last looked at
        try:
            while True:
                with self.cond:
                    while True:
                        if self.closed:
                            return
                        cap = self.capture
                        if self.req is not None and cap is None:
                            cap = self.capture = srv.new_capture(self.pf, self.cond)
                            cap.start()
                        if cap is not None and cap.error:
                            self.log(cap.error)
                            self.sock.shutdown(socket.SHUT_RDWR)
                            return
                        if (self.req is not None and cap is not None and cap.frame is not None
                                and (self.new_req or checked != (cap, cap.seq))):
                            break
                        self.cond.wait()
                    self.new_req = False
                    checked = (cap, cap.seq)
                    frame, pf = cap.frame, self.pf
                    bpp = pf["bpp"] // 8
                    stride = fw * bpp
                    x0, y0, x1, y1 = self.req
                    tiles = changed_tiles(frame, self.shown, stride, bpp,
                                          tiles_in((x0, y0, x1 - x0, y1 - y0), fw, fh), self.force)
                    if not tiles:
                        continue  # incremental and nothing new: wait for the next frame
                    self.req, self.force = None, set()
                    shown = self.shown
                    enc = self.enc
                    if enc == ENC_ZRLE and self.zobj is None:
                        self.zobj = zlib.compressobj(self.level)
                msg = encode_update(frame, stride, bpp, cpixel_bytes(pf), tiles, enc, self.zobj)
                self.sock.sendall(msg)
                with self.cond:
                    if self.shown is shown:  # pixel format did not change meanwhile
                        if len(tiles) == len(tiles_in((0, 0, fw, fh), fw, fh)):
                            self.shown = bytearray(frame)
                        else:
                            if self.shown is None:
                                self.shown = bytearray(len(frame))
                            copy_tiles(self.shown, frame, stride, bpp, tiles)
        except OSError:
            pass


def allow_match(ip, entry):
    """One -a entry: an exact address, a prefix ending in '.' or ':' (x11vnc's -allow form), or a
    CIDR network. A bare address is never a prefix: 192.168.1.1 must not admit 192.168.1.17."""
    if "/" in entry:
        try:
            return ipaddress.ip_address(ip) in ipaddress.ip_network(entry, strict=False)
        except ValueError:
            return False
    if entry.endswith((".", ":")):
        return ip.startswith(entry)
    return ip == entry


class ZoomServer:
    def __init__(self, display, area, factor, sharp=False, port=5900, allow=None, password=None, fps=10,
                 xinput=True):
        self.display, self.area, self.factor = display, area, factor
        self.sharp, self.port, self.fps, self.password = sharp, port, fps, password
        self.allow = [a.strip() for a in allow.split(",") if a.strip()] if allow else None
        self.size = zoomed_size(area, factor)
        self.clients = set()
        self.lock = threading.Lock()
        self.xin = None
        if xinput:
            try:
                self.xin = XInput(display)
            except Exception as e:  # missing libXtst, no display ...
                log("warning: input disabled (%s)" % e)
        self._r, self._w = os.pipe()
        self.ready = threading.Event()  # set once listening (bound_port: the real port, for -p 0)
        self.bound_port = None

    def new_capture(self, pf, cond):
        w, h = self.size
        cmd = ffmpeg_cmd(self.display, self.area, self.size, pf_to_ffmpeg(pf), self.fps, self.sharp)
        return Capture(cmd, w * h * pf["bpp"] // 8, cond)

    def allowed(self, ip):
        return self.allow is None or any(allow_match(ip, a) for a in self.allow)

    def forget(self, c):
        with self.lock:
            self.clients.discard(c)

    def shutdown(self):
        """Safe from a signal handler."""
        os.write(self._w, b"x")

    def serve_forever(self):
        if socket.has_dualstack_ipv6():
            ls = socket.create_server(("", self.port), family=socket.AF_INET6, dualstack_ipv6=True)
        else:
            ls = socket.create_server(("", self.port))
        self.bound_port = ls.getsockname()[1]
        self.ready.set()
        sel = selectors.DefaultSelector()
        sel.register(ls, selectors.EVENT_READ)
        sel.register(self._r, selectors.EVENT_READ)
        try:
            while True:
                if any(k.fileobj == self._r for k, _ in sel.select()):
                    break
                try:
                    sock, addr = ls.accept()
                except OSError:
                    continue
                ip = addr[0][7:] if addr[0].startswith("::ffff:") else addr[0]
                if not self.allowed(ip):
                    log("client %s: refused (not in -a list)" % ip)
                    sock.close()
                    continue
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                c = Client(self, sock, ip)
                c.thread = threading.Thread(target=c.run, daemon=True)
                with self.lock:
                    self.clients.add(c)
                c.thread.start()
        finally:
            sel.close()
            ls.close()
            with self.lock:
                clients = list(self.clients)
            for c in clients:
                try:
                    c.sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            for c in clients:  # each stops its ffmpeg and releases its keys on the way out
                c.thread.join(5)
            if self.xin:
                self.xin.close()
