#!/usr/bin/env bash
# Share one monitor (or part of it) of the running X11 session with
# TigerVNC's x0vncserver (>= 1.16). No scaling: the client gets native pixels.
#
# Requires: x0vncserver (tigervnc-scraping-server), xrandr; vncpasswd to create -P.
set -euo pipefail

MIN_VERSION=1.16
die() { echo "error: $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $0 [options] [-- extra x0vncserver parameters]

  -o OUTPUT   xrandr output name (default: primary output)
  -s WxH      share only the top-left WxH of the output
  -O X,Y      offset of the shared area from the output's top-left (default: 0,0)
  -p PORT     TCP port (default: 5900)
  -a IPS      comma list of allowed clients, IP or IP/bits (default: any)
  -n          no password (otherwise uses/creates the -P file)
  -P FILE     password file (default: ./vnc.passwd)
  -d DISPLAY  X display (default: \$DISPLAY, else :0)
  --fps N     max updates per second per client (x0vncserver FrameRate)
  --list      list connected outputs and exit
  -h          this help

Example: $0 -o Virtual-1-1 -p 5910 -- -localhost -AlwaysShared
EOF
}

output="" size="" offset=0,0 port=5900 allow="" nopass=0 pwfile=vnc.passwd display="" fps="" list=0
while [[ $# -gt 0 ]]; do
	case $1 in
		-o) output=$2; shift 2 ;;
		-s) size=$2; shift 2 ;;
		-O) offset=$2; shift 2 ;;
		-p) port=$2; shift 2 ;;
		-a) allow=$2; shift 2 ;;
		-n) nopass=1; shift ;;
		-P) pwfile=$2; shift 2 ;;
		-d) display=$2; shift 2 ;;
		--fps) fps=$2; shift 2 ;;
		--list) list=1; shift ;;
		-h | --help) usage; exit 0 ;;
		--) shift; break ;;
		*) usage >&2; exit 1 ;;
	esac
done

export DISPLAY=${display:-${DISPLAY:-:0}}
[[ ${XDG_SESSION_TYPE:-x11} != wayland ]] || die "Wayland session detected; x0vncserver needs an X11 session"
command -v xrandr >/dev/null || die "'xrandr' not found (x11-xserver-utils)"

if ((list)); then xrandr --query | grep ' connected'; exit 0; fi

command -v x0vncserver >/dev/null || die "'x0vncserver' not found (TigerVNC >= $MIN_VERSION, package tigervnc-scraping-server)"
ver=$(x0vncserver -version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
if [[ -z $ver ]]; then
	echo "warning: could not read the x0vncserver version; need >= $MIN_VERSION" >&2
elif [[ $(printf '%s\n' "$MIN_VERSION" "$ver" | sort -V | head -1) != "$MIN_VERSION" ]]; then
	die "x0vncserver $ver found; need >= $MIN_VERSION"
fi

# Output geometry WxH+X+Y from xrandr
if [[ -z $output ]]; then
	output=$(xrandr --query | awk '/ connected primary/{print $1; exit}')
	[[ -n $output ]] || output=$(xrandr --query | awk '/ connected/{print $1; exit}')
fi
geom=$(xrandr --query | awk -v o="$output" '$1==o && $2=="connected"' |
	grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1 || true)
[[ -n $geom ]] || die "output '$output' is not an active screen (see: $0 --list)"
[[ $geom =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]]
ow=${BASH_REMATCH[1]} oh=${BASH_REMATCH[2]} ox=${BASH_REMATCH[3]} oy=${BASH_REMATCH[4]}

[[ $offset =~ ^([0-9]+),([0-9]+)$ ]] || die "bad -O '$offset', expected X,Y"
dx=${BASH_REMATCH[1]} dy=${BASH_REMATCH[2]}
w=$((ow - dx)) h=$((oh - dy))
if [[ -n $size ]]; then
	[[ $size =~ ^([0-9]+)x([0-9]+)$ ]] || die "bad -s '$size', expected WxH"
	w=${BASH_REMATCH[1]} h=${BASH_REMATCH[2]}
fi
((w > 0 && h > 0 && dx + w <= ow && dy + h <= oh)) || die "area ${w}x${h}+${dx}+${dy} does not fit in $output ($geom)"
area="${w}x${h}+$((ox + dx))+$((oy + dy))"

args=(-display "$DISPLAY" -Geometry "$area" -rfbport "$port")
[[ -n $fps ]] && args+=(-FrameRate "$fps")

if ((nopass)); then
	args+=(-SecurityTypes None)
else
	if [[ ! -s $pwfile ]]; then
		command -v vncpasswd >/dev/null || die "no password file '$pwfile' and no 'vncpasswd' to create it (or use -n)"
		echo "creating password file $pwfile" >&2
		vncpasswd "$pwfile"
	fi
	args+=(-SecurityTypes VncAuth -PasswordFile "$pwfile")
fi

tmpdir=""
if [[ -n $allow ]]; then
	tmpdir=$(mktemp -d)
	trap 'rm -rf "$tmpdir"' EXIT
	tr ',' '\n' <<<"$allow" | sed '/^$/d; s/^/+/' >"$tmpdir/hosts"
	echo "-" >>"$tmpdir/hosts" # reject everyone else
	args+=(-HostsFile "$tmpdir/hosts")
fi

echo "sharing $output area $area on port $port (x0vncserver $ver)" >&2
# Not exec: the EXIT trap must still remove the hosts file.
x0vncserver "${args[@]}" "$@"
