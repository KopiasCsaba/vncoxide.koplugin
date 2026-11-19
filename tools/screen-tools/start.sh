#!/usr/bin/env bash
# Create the virtual monitor and serve it over VNC; remove it again on exit.
#
# Usage: ./start.sh [PROFILE] [-- extra x0vnc-server.sh args]
# Settings: built-in defaults < profiles/PROFILE.env < .env
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "error: $*" >&2; exit 1; }
profiles() { local f; for f in profiles/*.env; do [[ -e $f ]] && f=${f#profiles/} && echo "  ${f%.env}"; done; }

cli_profile=""
if [[ $# -gt 0 && $1 != -- ]]; then
	[[ $1 =~ ^(-h|--help)$ ]] && { sed -n '4,5s/^# \{0,1\}//p' "$0"; echo "Profiles:"; profiles; exit 0; }
	cli_profile=$1; shift
fi
[[ ${1:-} == -- ]] && shift

# Defaults
VS_SIZE=1920x1080 VS_TARGET="" VS_POS=right VS_RATE=60 VS_SETTLE=3
VNC_PORT=5900 VNC_EXTRA="" VNC_OUTPUT="" PROFILE=""

[[ -f .env ]] && source ./.env   # first pass: learn PROFILE
PROFILE=${cli_profile:-$PROFILE}
if [[ -n $PROFILE ]]; then
	[[ -f profiles/$PROFILE.env ]] || { echo "Profiles:" >&2; profiles >&2; die "unknown profile '$PROFILE'"; }
	# shellcheck source=/dev/null
	source "profiles/$PROFILE.env"
fi
[[ -f .env ]] && source ./.env   # second pass: .env overrides the profile
PROFILE=${cli_profile:-$PROFILE}

vs_args=("$VS_SIZE" -p "$VS_POS" -r "$VS_RATE")
[[ -n $VS_TARGET ]] && vs_args+=(-t "$VS_TARGET")

trap './virtual-screen.sh stop' EXIT
trap 'exit 130' INT TERM

echo "profile: ${PROFILE:-none}"
vs_out=$(./virtual-screen.sh start "${vs_args[@]}")
echo "$vs_out"
output=${VNC_OUTPUT:-$(awk '/^virtual monitor:/{print $3}' <<<"$vs_out")}
[[ -n $output ]] || die "could not tell which output virtual-screen.sh created"
sleep "$VS_SETTLE"

vnc_args=(-p "$VNC_PORT" -o "$output")
# shellcheck disable=SC2206  # VNC_EXTRA is meant to word-split into flags
vnc_args+=($VNC_EXTRA "$@")
./x0vnc-server.sh "${vnc_args[@]}"
