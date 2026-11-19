#!/usr/bin/env bash
# Virtual extra monitor for an X11 session (XFCE).
#
# Loads the kernel's virtual display driver (vkms). X picks it up as an extra
# provider whose output (Virtual-1-1) is "connected", so XFCE/GTK treat it as a
# real monitor. This script sets its size and position. Share its region with
# any VNC server (geometry WxH+X+Y is printed on start).
#
# Requires: xrandr (x11-xserver-utils), cvt (xserver-xorg-core), sudo for modprobe.
set -euo pipefail

usage() {
	cat <<EOF
Usage:
  $0 start [WIDTHxHEIGHT] [options]   create/resize the virtual monitor (default 1920x1080)
  $0 stop                             switch it off and try to unload vkms
  $0 status                           show monitors
  $0 outputs                          list active screens (for -t)

Options for start:
  -t SCREEN   screen to place it next to, e.g. DisplayPort-0 (default: primary)
  -p POS      right|left|above|below of that screen (default: right)
  -r HZ       refresh rate (default: 60)
EOF
}

die() { echo "error: $*" >&2; exit 1; }

if [[ "${1:-}" =~ ^(start|stop|status|outputs)$ && -z "${DISPLAY:-}" ]]; then
	die "DISPLAY is not set; run this inside your X session"
fi

primary_output() {
	local p
	p=$(xrandr --query | awk '/ connected primary/{print $1; exit}')
	[[ -n "$p" ]] || p=$(xrandr --query | awk '/ connected/{print $1; exit}')
	echo "$p"
}

virtual_output() { xrandr --query | awk '/^Virtual[^ ]* connected/{print $1; exit}'; }

ensure_vkms() {
	local i out
	out=$(virtual_output)
	[[ -n "$out" ]] && { echo "$out"; return; }
	if ! lsmod | grep -q '^vkms '; then
		cat >&2 <<-'EOF'
			notice: loading the vkms kernel module, which needs sudo.
			        To skip this step (and the password prompt), load it at boot instead,
			        e.g. on Ubuntu/Debian and other systemd-based systems:
			            echo vkms | sudo tee /etc/modules-load.d/vkms.conf
		EOF
		sudo modprobe vkms >&2
	fi
	# X adds the new GPU asynchronously; wait up to ~5 s for its output.
	for i in {1..10}; do
		out=$(virtual_output)
		[[ -n "$out" ]] && { echo "$out"; return; }
		# Not auto-attached: attach the vkms provider as output sink of the main GPU.
		if ((i == 4)); then
			xrandr --setprovideroutputsource modesetting 0 2>/dev/null || true
		fi
		sleep 0.5
	done
	die "no Virtual-* output appeared (check 'xrandr --listproviders')"
}

cmd_start() {
	local size=1920x1080 out pos=right hz=60 target="" posarg
	if [[ "${1:-}" =~ ^[0-9]+x[0-9]+$ ]]; then size=$1; shift; fi
	while getopts "p:r:t:" opt; do
		case $opt in
			p) pos=$OPTARG ;;
			r) hz=$OPTARG ;;
			t) target=$OPTARG ;;
			*) usage; exit 1 ;;
		esac
	done
	command -v cvt >/dev/null || die "'cvt' not found (sudo apt install xserver-xorg-core)"

	case $pos in
		right) posarg=--right-of ;; left) posarg=--left-of ;;
		above) posarg=--above ;; below) posarg=--below ;;
		*) die "bad position: $pos" ;;
	esac

	out=$(ensure_vkms)
	# With the vkms sink attached, amdgpu's TearFree "auto" lets real screens tear.
	for o in $(xrandr --query | awk '/ connected/ && $1 !~ /^Virtual/{print $1}'); do
		xrandr --output "$o" --set TearFree on 2>/dev/null || true
	done
	local w=${size%x*} h=${size#*x} ref mode modeline geom
	ref=${target:-$(primary_output)}
	[[ "$ref" != "$out" ]] || die "target and virtual output are the same"
	xrandr --query | grep -qE "^$ref connected [^(]*[0-9]+x[0-9]+\+" ||
		die "target '$ref' is not an active screen, see '$0 outputs'"
	mode="VS_${size}_${hz}"

	# cvt prints: Modeline "name" clock timings... -> keep clock + timings only
	modeline=$(cvt "$w" "$h" "$hz" | awk '/^Modeline/{$1="";$2=""; print}')
	[[ -n "$modeline" ]] || die "cvt failed for $size@$hz"
	# shellcheck disable=SC2086
	xrandr --newmode "$mode" $modeline 2>/dev/null || true # may already exist
	xrandr --addmode "$out" "$mode" 2>/dev/null || true
	xrandr --output "$out" --mode "$mode" "$posarg" "$ref" ||
		die "could not set $mode on $out"

	geom=$(xrandr --query | awk -v o="$out" '$1==o' | grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1)
	echo "virtual monitor: $out $geom ($pos of $ref)"
}

cmd_stop() {
	local out
	out=$(virtual_output)
	[[ -n "$out" ]] && xrandr --output "$out" --off && echo "switched off $out"
	if lsmod | grep -q '^vkms '; then
		sudo modprobe -r vkms 2>/dev/null && echo "vkms unloaded" ||
			echo "vkms still in use by X; it goes away on logout/reboot (output stays off)"
	fi
}

case "${1:-}" in
	start) shift; cmd_start "$@" ;;
	stop) cmd_stop ;;
	status) xrandr --listmonitors ;;
	outputs) xrandr --query | grep ' connected' ;;
	*) usage ;;
esac
