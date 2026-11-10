#!/usr/bin/env python3
"""Unit and in-process protocol tests for vnc_zoom.py (no X display or ffmpeg needed)."""
import os, socket, struct, sys, tempfile, threading, unittest, zlib
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vnc_zoom as vz  # noqa: E402

PF32 = dict(vz.DEFAULT_PF)
PF16 = dict(bpp=16, depth=16, big_endian=0, true_colour=1, red_max=31, green_max=63, blue_max=31,
            red_shift=11, green_shift=5, blue_shift=0)
PF8 = dict(bpp=8, depth=8, big_endian=0, true_colour=1, red_max=7, green_max=7, blue_max=3,
           red_shift=0, green_shift=3, blue_shift=6)


def recv_exact(s, n):
    buf = bytearray()
    while len(buf) < n:
        k = s.recv(n - len(buf))
        if not k:
            raise EOFError("connection closed")
        buf += k
    return bytes(buf)


class RfbTestClient:
    """Minimal independent RFB 3.8 client with a reference Raw/ZRLE decoder (subencodings 0 and 1)."""

    def __init__(self, host, port, password=None, timeout=10):
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.z = zlib.decompressobj()
        try:
            self._handshake(password)
        except BaseException:
            self.s.close()
            raise

    def _handshake(self, password):
        assert recv_exact(self.s, 12) == b"RFB 003.008\n"
        self.s.sendall(b"RFB 003.008\n")
        n = recv_exact(self.s, 1)[0]
        types = recv_exact(self.s, n)
        sec = 2 if password is not None else 1
        if sec not in types:
            raise RuntimeError("server offers %r" % types)
        self.s.sendall(bytes([sec]))
        if sec == 2:
            chal = recv_exact(self.s, 16)
            self.s.sendall(vz.vnc_response(password, chal))
        if struct.unpack(">I", recv_exact(self.s, 4))[0] != 0:
            reason = recv_exact(self.s, struct.unpack(">I", recv_exact(self.s, 4))[0])
            raise PermissionError(reason.decode())
        self.s.sendall(b"\x01")
        self.w, self.h = struct.unpack(">HH", recv_exact(self.s, 4))
        self.pf = vz.unpack_pf(recv_exact(self.s, 16))
        self.name = recv_exact(self.s, struct.unpack(">I", recv_exact(self.s, 4))[0])
        self.fb = None
        self._alloc()

    def _alloc(self):
        self.bpp = self.pf["bpp"] // 8
        self.fb = bytearray(self.w * self.h * self.bpp)

    def set_pf(self, pf):
        self.s.sendall(b"\x00\x00\x00\x00" + vz.pack_pf(pf))
        self.pf = pf
        self._alloc()

    def set_encodings(self, *encs):
        self.s.sendall(struct.pack(">BxH%di" % len(encs), 2, len(encs), *encs))

    def request(self, incremental, x=0, y=0, w=None, h=None):
        self.s.sendall(struct.pack(">BBHHHH", 3, incremental, x, y, self.w if w is None else w,
                                   self.h if h is None else h))

    def pointer(self, mask, x, y):
        self.s.sendall(struct.pack(">BBHH", 5, mask, x, y))

    def key(self, down, keysym):
        self.s.sendall(struct.pack(">BBxxI", 4, down, keysym))

    def read_update(self):
        """Reads one FramebufferUpdate into self.fb; returns its rectangles."""
        t = recv_exact(self.s, 1)[0]
        assert t == 0, "message type %d" % t
        n = struct.unpack(">xH", recv_exact(self.s, 3))[0]
        rects = []
        for _ in range(n):
            x, y, w, h, enc = struct.unpack(">HHHHi", recv_exact(self.s, 12))
            rects.append((x, y, w, h, enc))
            if enc == 0:
                self._put(x, y, w, h, recv_exact(self.s, w * h * self.bpp))
            elif enc == 16:
                data = self.z.decompress(recv_exact(self.s, struct.unpack(">I", recv_exact(self.s, 4))[0]))
                self._zrle(x, y, w, h, data)
            else:
                raise AssertionError("encoding %d" % enc)
        return rects

    def _put(self, x, y, w, h, data):
        st, n = self.w * self.bpp, w * self.bpp
        for i in range(h):
            o = (y + i) * st + x * self.bpp
            self.fb[o:o + n] = data[i * n:(i + 1) * n]

    def _zrle(self, x, y, w, h, data):
        cb = vz.cpixel_bytes(self.pf)
        pad = b"\0" * (self.bpp - cb)
        pos = 0
        for ty in range(y, y + h, 64):
            for tx in range(x, x + w, 64):
                tw, th = min(64, x + w - tx), min(64, y + h - ty)
                sub = data[pos]
                pos += 1
                if sub == 1:
                    px = data[pos:pos + cb] + pad
                    pos += cb
                    self._put(tx, ty, tw, th, px * (tw * th))
                elif sub == 0:
                    out = bytearray()
                    for i in range(tw * th):
                        out += data[pos + i * cb:pos + (i + 1) * cb] + pad
                    pos += tw * th * cb
                    self._put(tx, ty, tw, th, bytes(out))
                else:
                    raise AssertionError("subencoding %d" % sub)
        assert pos == len(data), (pos, len(data))

    def close(self):
        self.s.close()


def make_frame(w, h, bpp, seed=1):
    """Deterministic frame: noise in the left half, flat colour bands in the right (solid tiles)."""
    out = bytearray()
    v = seed
    for y in range(h):
        for x in range(w):
            if x < w // 2:
                v = (v * 1103515245 + 12345) & 0x7FFFFFFF
                px = (v >> 8).to_bytes(4, "little")
            else:
                px = bytes([(y // 64) * 40 & 255, 200, 7, 0])
            px = px[:bpp]
            if bpp == 4:
                px = px[:3] + b"\0"  # the X byte is 0, as ffmpeg's rgb0 writes it
            out += px
    return bytes(out)


class Des(unittest.TestCase):
    def test_vectors(self):
        for key, pt, ct in [("133457799BBCDFF1", "0123456789ABCDEF", "85E813540F0AB405"),
                            ("0E329232EA6D0D73", "8787878787878787", "0000000000000000")]:
            k, p, c = bytes.fromhex(key), bytes.fromhex(pt), bytes.fromhex(ct)
            self.assertEqual(vz.des_encrypt(k, p), c)
            self.assertEqual(vz.des_decrypt(k, c), p)

    def test_x11vnc_passwd_files(self):
        # produced by x11vnc 0.9.16 -storepasswd (Debian trixie) for "secret12" and "ab"
        d = tempfile.mkdtemp()
        for pw, hexdata in ((b"secret12", "24b5ae4ce15503c6"), (b"ab", "f9b845297cb5d3f2")):
            p = os.path.join(d, "f")
            with open(p, "wb") as f:
                f.write(bytes.fromhex(hexdata))
            self.assertEqual(vz.read_passwd(p), pw)
            vz.write_passwd(p, pw)
            with open(p, "rb") as f:
                self.assertEqual(f.read(), bytes.fromhex(hexdata))
            self.assertEqual(os.stat(p).st_mode & 0o777, 0o600)
        with open(p, "wb") as f:
            f.write(b"abc")
        with self.assertRaises(ValueError):
            vz.read_passwd(p)

    def test_response(self):
        chal = bytes(range(16))
        r = vz.vnc_response(b"pw", chal)
        self.assertEqual(len(r), 16)
        self.assertEqual(vz.des_decrypt(vz._vnc_key(b"pw"), r), chal)
        self.assertNotEqual(r, vz.vnc_response(b"pX", chal))
        self.assertEqual(vz._vnc_key(b"\x01\x80"), b"\x80\x01" + b"\0" * 6)


class Pure(unittest.TestCase):
    def test_formats(self):
        self.assertEqual(vz.pf_to_ffmpeg(PF32), "rgb0")
        self.assertEqual(vz.pf_to_ffmpeg(PF16), "rgb565le")
        self.assertEqual(vz.pf_to_ffmpeg(PF8), "bgr8")
        self.assertEqual(vz.pf_to_ffmpeg(dict(PF8, big_endian=1)), "bgr8")
        self.assertEqual(vz.pf_to_ffmpeg(dict(PF32, red_shift=16, blue_shift=0)), "bgr0")
        for bad in (dict(PF16, big_endian=1), dict(PF32, true_colour=0), dict(PF16, green_max=31),
                    dict(PF32, bpp=24)):
            self.assertIsNone(vz.pf_to_ffmpeg(bad))
        self.assertEqual(vz.unpack_pf(vz.pack_pf(PF16)), PF16)
        self.assertEqual([vz.cpixel_bytes(p) for p in (PF32, PF16, PF8)], [3, 2, 1])

    def test_tiles_in(self):
        t = vz.tiles_in((0, 0, 130, 70), 130, 70)
        self.assertEqual(t, [(0, 0, 64, 64), (64, 0, 64, 64), (128, 0, 2, 64),
                             (0, 64, 64, 6), (64, 64, 64, 6), (128, 64, 2, 6)])
        self.assertEqual(vz.tiles_in((10, 10, 60, 60), 130, 70),
                         [(10, 10, 54, 54), (64, 10, 6, 54), (10, 64, 54, 6), (64, 64, 6, 6)])
        self.assertEqual(vz.tiles_in((120, 60, 500, 500), 130, 70), [(120, 60, 8, 4), (128, 60, 2, 4),
                                                                      (120, 64, 8, 6), (128, 64, 2, 6)])

    def test_changed_tiles(self):
        w, h, bpp = 130, 70, 4
        a = make_frame(w, h, bpp)
        tiles = vz.tiles_in((0, 0, w, h), w, h)
        self.assertEqual(vz.changed_tiles(a, None, w * bpp, bpp, tiles), tiles)
        self.assertEqual(vz.changed_tiles(a, bytearray(a), w * bpp, bpp, tiles), [])
        b = bytearray(a)
        o = (65 * w + 129) * bpp  # one pixel in the bottom-right edge tile
        b[o] ^= 0xFF
        self.assertEqual(vz.changed_tiles(bytes(b), bytearray(a), w * bpp, bpp, tiles), [(128, 64, 2, 6)])
        self.assertEqual(vz.changed_tiles(a, bytearray(a), w * bpp, bpp, tiles, {(0, 0, 64, 64)}), [(0, 0, 64, 64)])
        shown = bytearray(a)
        vz.copy_tiles(shown, bytes(b), w * bpp, bpp, [(128, 64, 2, 6)])
        self.assertEqual(bytes(shown), bytes(b))

    def test_zrle_tile(self):
        self.assertEqual(vz.zrle_tile(b"\x01\x02\x03\x00" * 4, 4, 3), b"\x01\x01\x02\x03")
        self.assertEqual(vz.zrle_tile(b"\x01\x02\x03\x00\x04\x05\x06\x00", 4, 3), b"\x00\x01\x02\x03\x04\x05\x06")
        self.assertEqual(vz.zrle_tile(b"\x01\x02\x01\x03", 2, 2), b"\x00\x01\x02\x01\x03")
        self.assertEqual(vz.zrle_tile(b"\x09\x09", 1, 1), b"\x01\x09")

    def test_encode_decode(self):
        w, h = 130, 70
        for pf in (PF32, PF16, PF8):
            bpp = pf["bpp"] // 8
            frame = make_frame(w, h, bpp)
            for enc in (vz.ENC_ZRLE, vz.ENC_RAW):
                for rect in ((0, 0, w, h), (10, 10, 60, 60), (100, 3, 30, 67)):
                    c = RfbTestClient.__new__(RfbTestClient)
                    c.w, c.h, c.pf, c.z = w, h, pf, zlib.decompressobj()
                    c._alloc()
                    tiles = vz.tiles_in(rect, w, h)
                    msg = vz.encode_update(frame, w * bpp, bpp, vz.cpixel_bytes(pf), tiles, enc,
                                           zlib.compressobj(6))
                    a, b = socket.socketpair()
                    threading.Thread(target=lambda: (a.sendall(msg), a.close())).start()
                    c.s = b
                    rects = c.read_update()
                    b.close()
                    self.assertEqual(len(rects), len(tiles))
                    expect = bytearray(len(frame))
                    vz.copy_tiles(expect, frame, w * bpp, bpp, tiles)
                    self.assertEqual(bytes(c.fb), bytes(expect), (pf["bpp"], enc, rect))
        # solid tiles really are sent as solid
        frame = make_frame(w, h, 4)
        z = zlib.compressobj(6)
        msg = vz.encode_update(frame, w * 4, 4, 3, [(66, 0, 62, 64)], vz.ENC_ZRLE, z)
        self.assertEqual(zlib.decompressobj().decompress(msg[4 + 12 + 4:]), b"\x01\x00\xc8\x07")

    def test_map_pointer(self):
        area = (632, 840, 100, 50)
        self.assertEqual(vz.map_pointer(1000, 1500, area, Fraction(2)), (600, 800))
        self.assertEqual(vz.map_pointer(0, 0, area, Fraction(2)), (100, 50))
        self.assertEqual(vz.map_pointer(1263, 1679, area, Fraction(2)), (731, 889))
        self.assertEqual(vz.map_pointer(65535, 65535, area, Fraction(2)), (731, 889))
        self.assertEqual(vz.map_pointer(4, 5, area, Fraction(4, 3)), (103, 53))
        self.assertEqual(vz.map_pointer(3, 3, area, Fraction(3, 2)), (102, 52))
        self.assertEqual(vz.zoomed_size(area, Fraction(4, 3)), (843, 1120))

    def test_ffmpeg_cmd(self):
        cmd = vz.ffmpeg_cmd(":9", (632, 840, 100, 50), (1264, 1680), "rgb565le", 10, True)
        self.assertEqual(cmd[cmd.index("-i") + 1], ":9+100,50")
        self.assertEqual(cmd[cmd.index("-video_size") + 1], "632x840")
        self.assertEqual(cmd[cmd.index("-vf") + 1], "scale=1264:1680:flags=neighbor,format=bgr0,"
                                                    "scale=flags=neighbor:sws_dither=none,format=rgb565le")
        self.assertEqual(cmd[cmd.index("-pix_fmt") + 1], "rgb565le")
        cmd = vz.ffmpeg_cmd(":0", (1, 1, 0, 0), (2, 2), "rgb0", 5, False)
        self.assertTrue(cmd[cmd.index("-vf") + 1].startswith("scale=2:2:flags=area,"))
        self.assertEqual(cmd[cmd.index("-framerate") + 1], "5")


class FakeCapture:
    def __init__(self, test, pf, cond):
        self.test, self.pf, self.cond = test, pf, cond
        self.frame, self.seq, self.error = None, 0, None
        self.stopped = False

    def start(self):
        self.test.captures.append(self)
        self.test.cap_event.set()

    def put(self, frame):
        with self.cond:
            self.frame = frame
            self.seq += 1
            self.cond.notify_all()

    def stop(self):
        self.stopped = True


class Protocol(unittest.TestCase):
    W, H = 130, 70

    def start(self, password=None, allow=None):
        self.logs = []
        orig = vz.log
        vz.log = self.logs.append
        self.addCleanup(setattr, vz, "log", orig)
        self.captures, self.cap_event = [], threading.Event()
        srv = vz.ZoomServer(":0", (65, 35, 0, 0), Fraction(2), port=0, allow=allow, password=password,
                            xinput=False)
        srv.new_capture = lambda pf, cond: FakeCapture(self, pf, cond)
        t = threading.Thread(target=srv.serve_forever, daemon=True)
        t.start()
        self.assertTrue(srv.ready.wait(5))
        self.addCleanup(lambda: (srv.shutdown(), t.join(5)))
        return srv

    def capture(self, n=1):
        while len(self.captures) < n:
            self.assertTrue(self.cap_event.wait(5))
            self.cap_event.clear()
        return self.captures[n - 1]

    def test_updates(self):
        srv = self.start()
        c = RfbTestClient("127.0.0.1", srv.bound_port)
        self.addCleanup(c.close)
        self.assertEqual((c.w, c.h, c.pf), (self.W, self.H, PF32))
        c.set_encodings(16, 0, -250)
        c.request(0)
        cap = self.capture()
        self.assertEqual(cap.pf, PF32)
        f1 = make_frame(self.W, self.H, 4)
        cap.put(f1)
        self.assertEqual(len(c.read_update()), 6)
        self.assertEqual(bytes(c.fb), f1)
        # incremental, nothing changed: stays pending until a frame changes something
        c.request(1)
        c.s.settimeout(0.3)
        with self.assertRaises(socket.timeout):
            c.s.recv(1)
        c.s.settimeout(10)
        f2 = bytearray(f1)
        f2[(66 * self.W + 70) * 4] ^= 0x55
        cap.put(bytes(f2))
        self.assertEqual(c.read_update(), [(64, 64, 64, 6, 16)])
        self.assertEqual(bytes(c.fb), bytes(f2))
        # a non-incremental request for a part sends that part even though nothing changed
        c.request(0, 10, 10, 20, 20)
        self.assertEqual(c.read_update(), [(10, 10, 20, 20, 16)])
        # an incremental request only covers its own area
        f3 = bytearray(f2)
        f3[0] ^= 1
        f3[(69 * self.W + 129) * 4] ^= 1
        cap.put(bytes(f3))
        c.request(1, 100, 50, 30, 20)
        self.assertEqual(c.read_update(), [(128, 64, 2, 6, 16)])
        c.request(1)
        self.assertEqual(c.read_update(), [(0, 0, 64, 64, 16)])
        self.assertEqual(bytes(c.fb), bytes(f3))

    def test_pixel_format_change_and_raw(self):
        srv = self.start()
        c = RfbTestClient("127.0.0.1", srv.bound_port)
        self.addCleanup(c.close)
        c.set_pf(PF16)
        c.set_encodings(0)
        c.request(0)
        cap = self.capture()
        self.assertEqual(vz.pf_to_ffmpeg(cap.pf), "rgb565le")
        f = make_frame(self.W, self.H, 2)
        cap.put(f)
        self.assertTrue(all(r[4] == 0 for r in c.read_update()))
        self.assertEqual(bytes(c.fb), f)
        c.set_pf(PF8)
        c.set_encodings(16)
        c.request(1)
        cap2 = self.capture(2)
        self.assertTrue(cap.stopped)
        self.assertEqual(vz.pf_to_ffmpeg(cap2.pf), "bgr8")
        f = make_frame(self.W, self.H, 1)
        cap2.put(f)
        c.read_update()
        self.assertEqual(bytes(c.fb), f)
        # ClientCutText is read and dropped
        c.s.sendall(struct.pack(">BxxxI", 6, 5) + b"hello")
        c.request(0, 0, 0, 1, 1)
        self.assertEqual(c.read_update(), [(0, 0, 1, 1, 16)])

    def test_unsupported_format_closes(self):
        srv = self.start()
        c = RfbTestClient("127.0.0.1", srv.bound_port)
        self.addCleanup(c.close)
        c.set_pf(dict(PF16, big_endian=1))
        self.assertEqual(c.s.recv(1), b"")
        self.assertIn("client 127.0.0.1: unsupported pixel format (bpp 16 depth 16 big-endian true_colour 1 "
                      "max 31/63/31 shift 11/5/0), closing", self.logs)

    def test_auth(self):
        srv = self.start(password=b"secret")
        c = RfbTestClient("127.0.0.1", srv.bound_port, password=b"secret")
        self.assertEqual(c.w, self.W)
        c.close()
        with self.assertRaises(PermissionError) as e:
            RfbTestClient("127.0.0.1", srv.bound_port, password=b"wrong")
        self.assertEqual(str(e.exception), "Authentication failed")
        with self.assertRaises(RuntimeError):
            RfbTestClient("127.0.0.1", srv.bound_port)  # client wants None, server offers only VNC auth

    def test_allow(self):
        srv = self.start(allow="10.9.,192.168.")
        s = socket.create_connection(("127.0.0.1", srv.bound_port), timeout=5)
        self.addCleanup(s.close)
        self.assertEqual(s.recv(12), b"")
        self.assertTrue(srv.allowed("10.9.1.2"))
        self.assertFalse(srv.allowed("10.90.1.2"))

    def test_allow_match(self):
        self.assertTrue(vz.allow_match("192.168.1.1", "192.168.1.1"))
        self.assertFalse(vz.allow_match("192.168.1.17", "192.168.1.1"))  # was a string prefix
        self.assertTrue(vz.allow_match("192.168.1.17", "192.168.1."))
        self.assertFalse(vz.allow_match("192.168.10.1", "192.168.1."))
        self.assertTrue(vz.allow_match("10.0.5.9", "10.0.0.0/16"))
        self.assertFalse(vz.allow_match("10.1.5.9", "10.0.0.0/16"))
        self.assertFalse(vz.allow_match("10.1.5.9", "not/a-net"))
        self.assertTrue(vz.allow_match("::1", "::1"))


if __name__ == "__main__":
    unittest.main()
