# SPDX-License-Identifier: (GPL-2.0-only OR BSD-3-Clause)
# shellcheck shell=bash
#
# Common helpers for the socketcand CAN CC / CAN FD raw mode tests.
#
# The tests run as a normal user. The vcan interfaces have to be created
# once by root (see README.md). The client side uses bash /dev/tcp, so no
# particular netcat flavour is needed. The bus side uses cansend/candump/cangen
# from can-utils.
#
# Environment variables:
#   SOCKETCAND        socketcand binary        (default: <top>/build/socketcand)
#   START_SOCKETCAND  1 = start own instance, 0 = use running one (default: 1)
#   HOST / PORT       socketcand address       (default: 127.0.0.1 / 29536)
#   LISTEN_IF         socketcand -l interface  (default: lo)
#   TIMEOUT           seconds to wait for an expected frame (default: 2)
#   QUIET_TIME        seconds to wait when no frame is expected (default: 0.3)
#   KEEP              1 = keep the log directory also on success

TESTDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOPDIR=$(cd "$TESTDIR/../.." && pwd)

SOCKETCAND=${SOCKETCAND:-$TOPDIR/build/socketcand}
START_SOCKETCAND=${START_SOCKETCAND:-1}
HOST=${HOST:-127.0.0.1}
PORT=${PORT:-29536}
LISTEN_IF=${LISTEN_IF:-lo}
TIMEOUT=${TIMEOUT:-2}
QUIET_TIME=${QUIET_TIME:-0.3}
KEEP=${KEEP:-0}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/socketcand-test.XXXXXX") || exit 2
CLIENT_RAW=$WORK/client.raw     # everything socketcand sent to the client
BUS_LOG=$WORK/candump.log       # candump -L of the CAN interface
SC_LOG=$WORK/socketcand.log     # socketcand stdout/stderr

PASS=0
FAIL=0
SKIP=0
SC_PID=
RX_PID=
CD_PID=
CLIENT_OPEN=0

if [ -t 1 ]; then
	C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[1m' C_N=$'\e[0m'
else
	C_R='' C_G='' C_Y='' C_B='' C_N=''
fi

pass()    { PASS=$((PASS + 1)); printf '  %sPASS%s %s\n' "$C_G" "$C_N" "$*"; }
fail()    { FAIL=$((FAIL + 1)); printf '  %sFAIL%s %s\n' "$C_R" "$C_N" "$*"; }
skip()    { SKIP=$((SKIP + 1)); printf '  %sSKIP%s %s\n' "$C_Y" "$C_N" "$*"; }
info()    { printf '  %sINFO%s %s\n' "$C_Y" "$C_N" "$*"; }
section() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_N"; }
die()     { printf '%sERROR:%s %s\n' "$C_R" "$C_N" "$*" >&2; FAIL=$((FAIL + 1)); exit 2; }

cleanup() {
	client_close
	bus_stop
	if [ -n "$SC_PID" ]; then
		pkill -P "$SC_PID" 2>/dev/null
		kill "$SC_PID" 2>/dev/null
		wait "$SC_PID" 2>/dev/null
	fi
	if [ "$KEEP" = 1 ] || [ "$FAIL" -gt 0 ]; then
		printf '\nlogs kept in %s\n' "$WORK"
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

summary() {
	printf '\n%s%s: %d passed, %d failed, %d skipped%s\n' "$C_B" \
	       "$(basename "$0")" "$PASS" "$FAIL" "$SKIP" "$C_N"
	[ "$FAIL" -eq 0 ]
}

# ---------------------------------------------------------------------------
# preconditions

need_tools() {
	local t
	for t in "$@"; do
		command -v "$t" >/dev/null || die "'$t' not found (install can-utils)"
	done
}

vcan_hint() {
	cat <<-EOF
	  Create the interfaces once as root, e.g.:
	    sudo modprobe vcan
	    sudo ip link add dev vcan0 type vcan
	    sudo ip link set vcan0 mtu 72 up     # CAN FD capable (CANFD_MTU)
	    sudo ip link add dev vcan1 type vcan
	    sudo ip link set vcan1 mtu 16 up     # CAN CC only (CAN_MTU)
	  The MTU can only be changed while the interface is down:
	    sudo ip link set $1 down && sudo ip link set $1 mtu ${2} up
	EOF
}

# iface_check <iface> fd|cc  - returns 1 (with hint) if not usable
iface_check() {
	local ifc=$1 mode=$2 mtu flags want
	[ "$mode" = fd ] && want=72 || want=16
	if [ ! -e "/sys/class/net/$ifc" ]; then
		printf 'interface %s does not exist\n' "$ifc"
		vcan_hint "$ifc" "$want"
		return 1
	fi
	mtu=$(cat "/sys/class/net/$ifc/mtu")
	flags=$(cat "/sys/class/net/$ifc/flags")
	if (( (flags & 1) == 0 )); then
		printf 'interface %s is down\n' "$ifc"
		vcan_hint "$ifc" "$want"
		return 1
	fi
	if [ "$mode" = fd ] && [ "$mtu" -lt 72 ]; then
		printf 'interface %s has MTU %s - CAN FD needs MTU >= 72\n' "$ifc" "$mtu"
		vcan_hint "$ifc" "$want"
		return 1
	fi
	if [ "$mode" = cc ] && [ "$mtu" -ne 16 ]; then
		printf 'interface %s has MTU %s - CAN CC only test needs MTU 16\n' "$ifc" "$mtu"
		vcan_hint "$ifc" "$want"
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# socketcand

port_open() {
	(exec 4<>"/dev/tcp/$HOST/$PORT") 2>/dev/null
}

# start_socketcand <ifaces> [extra socketcand options]
start_socketcand() {
	local ifaces=$1 i
	shift
	if [ "$START_SOCKETCAND" != 1 ]; then
		info "using already running socketcand at $HOST:$PORT (must provide $ifaces)"
		port_open || die "nothing listens on $HOST:$PORT"
		return 0
	fi
	[ -x "$SOCKETCAND" ] || die "socketcand binary not found: $SOCKETCAND (meson setup build && ninja -C build, or set SOCKETCAND=...)"
	port_open && die "port $PORT is already in use - use PORT=<other port> or START_SOCKETCAND=0"

	"$SOCKETCAND" -v -n -l "$LISTEN_IF" -p "$PORT" -i "$ifaces" "$@" >"$SC_LOG" 2>&1 &
	SC_PID=$!
	for i in $(seq 50); do
		port_open && return 0
		kill -0 "$SC_PID" 2>/dev/null || die "socketcand exited: $(tail -n 5 "$SC_LOG")"
		sleep 0.1
	done
	die "socketcand does not listen on $HOST:$PORT"
}

# ---------------------------------------------------------------------------
# client side (bash /dev/tcp on fd 3)

client_send() {
	printf '%s' "$*" >&3
}

# expect_reply <word>  - read one '< ... >' element and check it is '< word >'
expect_reply() {
	local msg words
	IFS= read -r -t "$TIMEOUT" -d '>' -u 3 msg || die "no reply from socketcand (expected '< $1 >')"
	read -r -a words <<<"$msg"
	[ "${words[*]}" = "< $1" ] || die "unexpected reply '$msg>' (expected '< $1 >')"
}

# client_open <iface>  - connect, open bus, switch to raw mode, start capture
client_open() {
	exec 3<>"/dev/tcp/$HOST/$PORT" || die "cannot connect to $HOST:$PORT"
	CLIENT_OPEN=1
	expect_reply hi
	client_send "< open $1 >"
	expect_reply ok
	client_send "< rawmode >"
	expect_reply ok
	: >"$CLIENT_RAW"
	cat <&3 >>"$CLIENT_RAW" &
	RX_PID=$!
}

client_close() {
	if [ -n "$RX_PID" ]; then
		kill "$RX_PID" 2>/dev/null
		wait "$RX_PID" 2>/dev/null
		RX_PID=
	fi
	if [ "$CLIENT_OPEN" = 1 ]; then
		exec 3>&-
		CLIENT_OPEN=0
	fi
}

# Normalize the client stream to one line per element:
#   < frame ID ts DATA >          -> ID#DATA
#   < fdframe ID FL ts DATA >     -> ID##<flags nibble>DATA   (candump -L style)
#   < error CLASS ts >            -> ERROR:CLASS
#   < echo >                      -> ECHO
sc_norm() {
	tr '>' '\n' <"$CLIENT_RAW" | awk '
		$1 != "<"      { next }
		$2 == "frame"  { if (NF > 5) { print "BAD:" $0; next }
				 print $3 "#" (NF == 5 ? $5 : ""); next }
		$2 == "fdframe" { if (NF > 6) { print "BAD:" $0; next }
				 n = ($4 ~ /^0[0-3]$/) ? substr($4, 2, 1) : "<flags=" $4 ">"
				 print $3 "##" n (NF == 6 ? $6 : ""); next }
		$2 == "error"  { print "ERROR:" $3; next }
		$2 == "echo"   { print "ECHO"; next }
		{ print "OTHER:" $0 }'
}

# ---------------------------------------------------------------------------
# bus side (candump -L)

bus_start() {
	: >"$BUS_LOG"
	if command -v stdbuf >/dev/null; then
		stdbuf -oL candump -L "$1" >"$BUS_LOG" 2>&1 &
	else
		candump -L "$1" >"$BUS_LOG" 2>&1 &
	fi
	CD_PID=$!
	sleep 0.3
}

bus_stop() {
	if [ -n "$CD_PID" ]; then
		kill -INT "$CD_PID" 2>/dev/null
		wait "$CD_PID" 2>/dev/null
		CD_PID=
	fi
}

# Normalize candump -L output: keep the frame column, reduce the CAN FD flags
# nibble to BRS/ESI (newer kernels also set CANFD_FDF), drop the CC len8_dlc
# suffix. CAN XL frames are marked with "XL:".
bus_norm() {
	awk '{
		f = $3
		if (f ~ /###/) { print "XL:" f; next }
		if (f ~ /##/) {
			i = index(f, "##")
			v = index("0123456789ABCDEF", toupper(substr(f, i + 2, 1))) - 1
			printf "%s##%d%s\n", substr(f, 1, i - 1), v % 4, substr(f, i + 3)
			next
		}
		sub(/_[0-9A-Fa-f]$/, "", f)
		print f
	}' "$BUS_LOG"
}

# ---------------------------------------------------------------------------
# test steps

# wait_lines <normalize function> <count> [timeout]
wait_lines() {
	local fn=$1 n=$2 max=$(( ${3:-$TIMEOUT} * 20 )) i
	for ((i = 0; i < max; i++)); do
		(( $($fn | wc -l) >= n )) && return 0
		sleep 0.05
	done
	return 1
}

# rx_step <description> <cansend frame> <expected sc_norm line | ->
# '-' means: socketcand must not send anything to the client
rx_step() {
	local desc=$1 frame=$2 exp=$3 before got
	before=$(sc_norm | wc -l)
	if ! cansend "$CAN_IF" "$frame" 2>"$WORK/cansend.err"; then
		fail "$desc: 'cansend $CAN_IF $frame' failed: $(cat "$WORK/cansend.err")"
		return
	fi
	if [ "$exp" = - ]; then
		sleep "$QUIET_TIME"
		got=$(sc_norm | tail -n +$((before + 1)))
		if [ -z "$got" ]; then
			pass "$desc (nothing forwarded)"
		else
			fail "$desc: cansend $frame -> unexpected '$got'"
		fi
		return
	fi
	wait_lines sc_norm $((before + 1))
	got=$(sc_norm | sed -n "$((before + 1))p")
	if [ "$got" = "$exp" ]; then
		pass "$desc"
	else
		fail "$desc: cansend $frame -> got '${got:-<nothing>}', expected '$exp'"
	fi
}

# tx_step <description> <socketcand command> <expected bus_norm line | ->
# '-' means: nothing must appear on the CAN bus
tx_step() {
	local desc=$1 cmd=$2 exp=$3 before got
	before=$(bus_norm | wc -l)
	client_send "$cmd"
	if [ "$exp" = - ]; then
		sleep "$QUIET_TIME"
		got=$(bus_norm | tail -n +$((before + 1)))
		if [ -z "$got" ]; then
			pass "$desc (rejected)"
		else
			fail "$desc: '$cmd' -> unexpected bus frame '$got'"
		fi
		return
	fi
	wait_lines bus_norm $((before + 1))
	got=$(bus_norm | sed -n "$((before + 1))p")
	if [ "$got" = "$exp" ]; then
		pass "$desc"
	else
		fail "$desc: '$cmd' -> bus got '${got:-<nothing>}', expected '$exp'"
	fi
}

# client_alive - the connection must still answer '< echo >'
client_alive() {
	local before
	before=$(sc_norm | wc -l)
	client_send "< echo >"
	if wait_lines sc_norm $((before + 1)) && sc_norm | tail -n +$((before + 1)) | grep -qx ECHO; then
		pass "connection still alive (< echo > answered)"
	else
		fail "connection dead or no answer to < echo >"
	fi
}

# ---------------------------------------------------------------------------
# data helpers

# hex_cat <n> [start] -> "0001020304..." (uppercase, no spaces)
hex_cat() {
	local n=$1 s=${2:-0} i out=
	for ((i = 0; i < n; i++)); do
		printf -v out '%s%02X' "$out" $(((s + i) & 255))
	done
	printf '%s' "$out"
}

# hex_sp <n> [start] -> "00 01 02 03 ..." (lowercase, spaces)
hex_sp() {
	local n=$1 s=${2:-0} i out=
	for ((i = 0; i < n; i++)); do
		printf -v out '%s %02x' "$out" $(((s + i) & 255))
	done
	printf '%s' "${out# }"
}

# fd_padlen <n> -> next valid CAN FD data length
fd_padlen() {
	local l
	for l in 0 1 2 3 4 5 6 7 8 12 16 20 24 32 48 64; do
		if (( $1 <= l )); then
			echo "$l"
			return
		fi
	done
	echo 64
}

# zeros <n> -> "0000..." (n bytes)
zeros() {
	local i out=
	for ((i = 0; i < $1; i++)); do out+='00'; done
	printf '%s' "$out"
}
