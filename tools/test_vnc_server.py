#!/usr/bin/env python3
"""Unit tests for vnc-server.py and vnc_zoom.py (no X display, x11vnc, ffmpeg or xrandr needed)."""
import contextlib, importlib.util, io, os, stat, sys, tempfile, unittest
from fractions import Fraction
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("vnc_server", os.path.join(HERE, "vnc-server.py"))
vs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vs)
sys.path.insert(0, HERE)
import vnc_zoom as vz  # noqa: E402
from test_vnc_zoom import Des, Protocol, Pure as ZoomPure  # noqa: E402,F401  (run with this suite)

XRANDR = """Screen 0: minimum 8 x 8, current 4480 x 1440, maximum 32767 x 32767
DisplayPort-0 connected primary 2560x1440+0+0 (normal left inverted right x axis y axis) 597mm x 336mm
   2560x1440     59.95*+
HDMI-1 connected 1920x1080+2560+0 (normal left inverted right x axis y axis) 527mm x 296mm
   1920x1080     60.00*+
HDMI-2 disconnected (normal left inverted right x axis y axis)
"""
XRANDR_IDLE = XRANDR + "DP-3 connected (normal left inverted right x axis y axis)\n"


def outs(text=XRANDR):
    return vs.parse_xrandr(text)


class Pure(unittest.TestCase):
    def test_parse(self):
        o = outs()
        self.assertEqual([x["name"] for x in o], ["DisplayPort-0", "HDMI-1"])
        self.assertEqual(o[0], dict(name="DisplayPort-0", primary=True, w=2560, h=1440, x=0, y=0))
        self.assertEqual((o[1]["primary"], o[1]["w"], o[1]["x"]), (False, 1920, 2560))

    def test_parse_inactive(self):
        o = outs(XRANDR_IDLE)
        self.assertEqual(o[2]["name"], "DP-3")
        self.assertIsNone(o[2]["w"])

    def test_pick(self):
        o = outs()
        self.assertEqual(vs.pick_output(o, None)["name"], "DisplayPort-0")
        self.assertEqual(vs.pick_output(o, "HDMI-1")["name"], "HDMI-1")
        noprim = [dict(x, primary=False) for x in o]
        self.assertEqual(vs.pick_output(noprim, None)["name"], "DisplayPort-0")

    def test_pick_errors(self):
        o = outs(XRANDR_IDLE)
        with self.assertRaises(SystemExit) as c:
            vs.pick_output(o, "VGA-1")
        self.assertEqual(str(c.exception.code),
                         "error: output 'VGA-1' not connected. Outputs: DisplayPort-0 HDMI-1 DP-3")
        with self.assertRaises(SystemExit) as c:
            vs.pick_output(o, "DP-3")
        self.assertEqual(str(c.exception.code), "error: output 'DP-3' is connected but has no active mode")
        with self.assertRaises(SystemExit):
            vs.pick_output([], None)

    def test_area(self):
        hdmi = outs()[1]
        self.assertEqual(vs.compute_area(hdmi, "632x840", "0,40"), (632, 840, 2560, 40))
        self.assertEqual(vs.compute_area(hdmi, None, "0,40"), (1920, 1040, 2560, 40))
        self.assertEqual(vs.compute_area(hdmi, None, "0,0"), (1920, 1080, 2560, 0))

    def test_area_errors(self):
        hdmi = outs()[1]
        for size, off, msg in [
            ("5000x10", "0,0", "error: area 5000x10 at offset 0,0 does not fit in HDMI-1 (1920x1080)"),
            ("10x10", "x", "error: -O must look like 0,40"),
            ("10", "0,0", "error: -s must look like 632x840"),
            ("0x10", "0,0", "error: area 0x10 at offset 0,0 does not fit in HDMI-1 (1920x1080)"),
        ]:
            with self.assertRaises(SystemExit) as c:
                vs.compute_area(hdmi, size, off)
            self.assertEqual(str(c.exception.code), msg)

    def test_frame_rects_clipped(self):
        o = outs()
        r = vs.frame_rects((632, 840, 2560, 40), o[1])
        self.assertEqual(len(r), 3)
        self.assertIn((2560, 39, 632 + 1, 1), r)       # top, left end clipped to the output
        self.assertIn((3192, 40, 1, 840), r)           # right
        self.assertIn((2560, 880, 632 + 1, 1), r)      # bottom
        self.assertFalse(any(x == 2559 and w == 1 and h > 1 for x, y, w, h in r))

    def test_frame_rects_origin(self):
        r = vs.frame_rects((100, 50, 0, 0), outs()[0])
        self.assertEqual(sorted(r), sorted([(0, 50, 101, 1), (100, 0, 1, 50)]))

    def test_frame_rects_inner(self):
        r = vs.frame_rects((100, 50, 10, 10), outs()[0])
        self.assertEqual(sorted(r), sorted([(9, 9, 102, 1), (9, 10, 1, 50), (110, 10, 1, 50), (9, 60, 102, 1)]))

    def test_build_cmd(self):
        cmd = vs.build_cmd(":0", (632, 840, 2560, 40), 5900, ["-nopw"], None, [])
        self.assertEqual(cmd, ["x11vnc", "-display", ":0", "-clip", "632x840+2560+40", "-rfbport", "5900",
                               "-nopw", "-forever", "-shared", "-cursor", "arrow", "-wait", "5",
                               "-defer", "0", "-noxrecord", "-ncache", "0"])
        cmd = vs.build_cmd(":1", (1, 2, 3, 4), 5901, ["-rfbauth", "p"], "1.2.3.4", ["-v"])
        self.assertEqual(cmd[7:11], ["-rfbauth", "p", "-allow", "1.2.3.4"])
        self.assertEqual(cmd[-1], "-v")

    def test_build_cmd_gentle(self):
        cmd = vs.build_cmd(":0", (1, 2, 3, 4), 5900, [], None, [], gentle=True)
        i = cmd.index("-wait")
        self.assertEqual(cmd[i:i + 4], ["-wait", "50", "-defer", "100"])
        self.assertNotIn("-scale", cmd)

    def test_parse_zoom(self):
        self.assertEqual(vs.parse_zoom("2", False), 2)
        self.assertEqual(vs.parse_zoom("2", True), 2)
        self.assertEqual(vs.parse_zoom("4/3", False), Fraction(4, 3))
        self.assertEqual(vs.parse_zoom("1.5", False), Fraction(3, 2))
        self.assertEqual(vs.parse_zoom(None, False), 1)
        self.assertEqual(vs.parse_zoom("1", False), 1)
        for bad in ("0", "abc", "-2", "1/0", "0/5", "2x", ""):
            with self.assertRaises(SystemExit):
                vs.parse_zoom(bad, False)
        with self.assertRaises(SystemExit):
            vs.parse_zoom(None, True)
        with self.assertRaises(SystemExit):
            vs.parse_zoom("1", True)


class FrameNoLib(unittest.TestCase):
    def test_start_without_libx11(self):
        f = vs.Frame(":0", [(0, 0, 1, 1)])
        err = io.StringIO()
        with mock.patch("ctypes.CDLL", side_effect=OSError("libX11.so.6: cannot open")), \
             contextlib.redirect_stderr(err):
            self.assertFalse(f.start())
        self.assertRegex(err.getvalue(), r"^warning: frame disabled \(.*libX11.*\)\n$")
        f.close()  # must be harmless after a failed start


class MainEndToEnd(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="vncsrv")
        self.argv_file = os.path.join(self.d, "argv")
        self.bin = os.path.join(self.d, "bin")
        os.mkdir(self.bin)
        self._stub("xrandr", "cat <<'EOF'\n" + XRANDR + "EOF\n")
        self._stub("x11vnc", 'printf "%s\\n" "$@" > "$ARGV_FILE"\nexit ${FAKE_RC:-0}\n')
        self._stub("ffmpeg", "exit 1\n")
        self.env = mock.patch.dict(os.environ, {
            "PATH": self.bin + os.pathsep + os.environ["PATH"], "DISPLAY": ":7",
            "ARGV_FILE": self.argv_file, "XDG_SESSION_TYPE": "x11"})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.addCleanup(lambda: __import__("shutil").rmtree(self.d, ignore_errors=True))

    def _stub(self, name, body):
        p = os.path.join(self.bin, name)
        with open(p, "w") as f:
            f.write("#!/bin/sh\n" + body)
        os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)

    def run_main(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                rc = vs.main(list(args))
            except SystemExit as e:
                rc = e.code
        return rc, out.getvalue(), err.getvalue()

    def argv(self):
        with open(self.argv_file) as f:
            return f.read().split("\n")[:-1]

    def test_serve(self):
        rc, out, err = self.run_main("-o", "HDMI-1", "-s", "632x840", "-O", "0,40", "-p", "5901", "-n",
                                     "-a", "10.0.0.2", "--", "-v")
        self.assertEqual((rc, err), (0, ""))
        self.assertEqual(out, "Sharing HDMI-1 (632x840+2560+40) of :7 on port 5901\n")
        self.assertEqual(self.argv(), ["-display", ":7", "-clip", "632x840+2560+40", "-rfbport", "5901",
                                       "-nopw", "-allow", "10.0.0.2", "-forever", "-shared", "-cursor",
                                       "arrow", "-wait", "5", "-defer", "0", "-noxrecord", "-ncache", "0", "-v"])

    def run_zoom(self, *args):
        """run_main with the zoom server replaced by a recorder; returns (rc, out, err, ctor args)."""
        calls = []

        class FakeServer:
            def __init__(self, *a):
                calls.append(a)
                self.port = a[4]

            def serve_forever(self):
                pass
        with mock.patch.object(vz, "ZoomServer", FakeServer):
            rc, out, err = self.run_main(*args)
        return rc, out, err, calls[0] if calls else None

    def test_zoom(self):
        rc, out, err, a = self.run_zoom("-n", "-s", "632x840", "-O", "0,40", "-o", "HDMI-1", "-z", "2", "--sharp",
                                        "-p", "5931", "-a", "10.0.0.")
        self.assertEqual((rc, err), (0, ""))
        self.assertEqual(out, "Sharing HDMI-1 (632x840+2560+40) of :7 on port 5931 scaled 2 sharp -> 1264x1680\n")
        self.assertEqual(a, (":7", (632, 840, 2560, 40), 2, True, 5931, "10.0.0.", None, 10))
        self.assertFalse(os.path.exists(self.argv_file))  # x11vnc not run
        rc, out, _, a = self.run_zoom("-n", "-s", "632x840", "-z", "4/3", "--fps", "25")
        self.assertIn("scaled 4/3 -> 843x1120\n", out)
        self.assertEqual((a[2], a[3], a[7]), (Fraction(4, 3), False, 25))

    def test_zoom_without_x11vnc_and_password(self):
        os.remove(os.path.join(self.bin, "x11vnc"))
        pw = os.path.join(self.d, "pw")
        with mock.patch.object(vs.getpass, "getpass", side_effect=["s3cret", "s3cret"]):
            rc, out, err, a = self.run_zoom("-z", "2", "-P", pw)
        self.assertEqual((rc, err), (0, ""))
        self.assertIn("Password written to: %s" % pw, out)
        self.assertEqual(a[6], b"s3cret")
        self.assertEqual(vz.read_passwd(pw), b"s3cret")
        rc, _, _, a = self.run_zoom("-z", "2", "-P", pw)  # existing file: no prompt
        self.assertEqual((rc, a[6]), (0, b"s3cret"))
        with mock.patch.object(vs.getpass, "getpass", side_effect=["a", "b"]):
            rc, _, err, a = self.run_zoom("-z", "2", "-P", os.path.join(self.d, "pw2"))
        self.assertEqual((rc, err, a), (1, "error: the passwords differ\n", None))

    def test_zoom_uses_x11vnc_storepasswd_when_present(self):
        self._stub("x11vnc", 'printf "%s\\n" "$@" > "$ARGV_FILE"\nprintf "\\044\\265\\256\\114\\341\\125\\003\\306" > "$2"\n')
        pw = os.path.join(self.d, "pw")
        rc, _, err, a = self.run_zoom("-z", "2", "-P", pw)
        self.assertEqual((rc, err), (0, ""))
        self.assertEqual(self.argv(), ["-storepasswd", pw])
        self.assertEqual(a[6], b"secret12")

    def test_gentle(self):
        self.run_main("-n", "--gentle")
        a = self.argv()
        self.assertEqual(a[a.index("-wait"):a.index("-wait") + 4], ["-wait", "50", "-defer", "100"])

    def test_zoom_one_is_x11vnc(self):
        rc, out, _ = self.run_main("-n", "-z", "1", "--", "-v")
        self.assertEqual(rc, 0)
        self.assertNotIn("scaled", out)
        self.assertEqual(self.argv()[-1], "-v")

    def test_zoom_errors(self):
        for args, msg in ((("-z", "0"), "error: -z must look like 2, 1.5 or 4/3"),
                          (("-z", "abc"), "error: -z must look like"),
                          (("--sharp",), "error: --sharp needs -z"),
                          (("--fps", "5"), "error: --fps needs -z"),
                          (("-z", "2", "--fps", "0"), "error: --fps must be at least 1"),
                          (("-z", "2", "--gentle"), "error: --gentle: x11vnc only, and -z does not use x11vnc"),
                          (("-z", "2", "--xdamage"), "error: --xdamage: x11vnc only, and -z does not use x11vnc"),
                          (("-z", "2", "--", "-viewonly"),
                           "error: arguments after --: x11vnc only, and -z does not use x11vnc")):
            rc, _, err, a = self.run_zoom("-n", *args)
            self.assertEqual((rc, a), (1, None), args)
            self.assertIn(msg, err)
        with mock.patch.dict(os.environ, {"XDG_SESSION_TYPE": "wayland"}):
            rc, _, err = self.run_main("-n", "-z", "2")
        self.assertEqual(err, "error: Wayland session detected; ffmpeg x11grab needs an X11 session\n")
        os.remove(os.path.join(self.bin, "ffmpeg"))
        with mock.patch.dict(os.environ, {"PATH": self.bin + os.pathsep + "/nonexistent"}):
            rc, _, err, _ = self.run_zoom("-n", "-z", "2")
        self.assertEqual((rc, err), (1, "error: 'ffmpeg' not found (Debian/Ubuntu: sudo apt install ffmpeg "
                                        "x11-xserver-utils)\n"))

    def test_zoom_frame(self):
        with mock.patch("ctypes.CDLL", side_effect=OSError("no libX11")):
            rc, out, err, a = self.run_zoom("-n", "-f", "-s", "100x100", "-O", "10,10", "-z", "2")
        self.assertEqual(rc, 0)
        self.assertEqual(err, "warning: frame disabled (no libX11)\n")

    def test_default_primary_and_password_file(self):
        pw = os.path.join(self.d, "pw")
        with open(pw, "w") as f:
            f.write("x")
        rc, out, _ = self.run_main("-P", pw, "-d", ":3")
        self.assertEqual(rc, 0)
        self.assertIn("Sharing DisplayPort-0 (2560x1440+0+0) of :3 on port 5900", out)
        a = self.argv()
        self.assertEqual(a[a.index("-rfbauth") + 1], pw)

    def test_exit_code_passthrough(self):
        with mock.patch.dict(os.environ, {"FAKE_RC": "3"}):
            self.assertEqual(self.run_main("-n")[0], 3)

    def test_frame_warning(self):
        with mock.patch("ctypes.CDLL", side_effect=OSError("no libX11")):
            rc, out, err = self.run_main("-n", "-f", "-s", "100x100", "-O", "10,10")
        self.assertEqual(rc, 0)
        self.assertEqual(err, "warning: frame disabled (no libX11)\n")
        self.assertTrue(os.path.exists(self.argv_file))

    def test_frame_disabled_when_area_fills_output(self):
        rc, _, err = self.run_main("-n", "-f", "-o", "HDMI-1")
        self.assertEqual(rc, 0)
        self.assertEqual(err, "warning: frame disabled (shared area fills the whole output)\n")

    def test_list(self):
        rc, out, _ = self.run_main("--list")
        self.assertEqual(rc, 0)
        self.assertEqual(out, "DisplayPort-0 2560x1440+0+0 primary\nHDMI-1 1920x1080+2560+0\n")
        self.assertFalse(os.path.exists(self.argv_file))

    def test_errors(self):
        rc, _, err = self.run_main("-o", "VGA-9", "-n")
        self.assertEqual(rc, 1)
        self.assertEqual(err, "error: output 'VGA-9' not connected. Outputs: DisplayPort-0 HDMI-1\n")
        with mock.patch.dict(os.environ, {"XDG_SESSION_TYPE": "wayland"}):
            rc, _, err = self.run_main("-n")
        self.assertEqual((rc, err), (1, "error: Wayland session detected; x11vnc needs an X11 session\n"))
        os.remove(os.path.join(self.bin, "x11vnc"))
        with mock.patch.dict(os.environ, {"PATH": self.bin + os.pathsep + "/nonexistent"}):
            rc, _, err = self.run_main("-n")
        self.assertEqual(rc, 1)
        self.assertIn("'x11vnc' not found (Debian/Ubuntu: sudo apt install x11vnc x11-xserver-utils)", err)


if __name__ == "__main__":
    unittest.main()
