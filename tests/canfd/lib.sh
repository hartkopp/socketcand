# SPDX-License-Identifier: (GPL-2.0-only OR BSD-3-Clause)
# shellcheck shell=bash
#
# Common helpers for the socketcand raw mode tests on vcan interfaces.
#
# The tests run as a normal user. The vcan interfaces have to be created
# once by root (see README.md). The client side uses bash /dev/tcp, the bus
# side uses cansend/candump/cangen from can-utils.
#
# The CAN interface type is derived from the MTU:
#   16 (CAN_MTU) -> cc, 72 (CANFD_MTU) -> fd, >= 76 (CANXL_MIN_MTU) -> xl
#
# Environment variables:
#   SOCKETCAND        socketcand binary        (default: <top>/build/src/socketcand)
#   START_SOCKETCAND  1 = start own instance, 0 = use running one (default: 1)
#   HOST / PORT       socketcand address       (default: 127.0.0.1 / 29536)
#                     with START_SOCKETCAND=1 the next free port is used
#                     if PORT is busy or blocked (TIME_WAIT)
#   LISTEN_IF         socketcand -l interface  (default: lo)
#   TIMEOUT           seconds to wait for an expected frame (default: 2)
#   QUIET_TIME        seconds to wait when no frame is expected (default: 0.3)
#   KEEP              1 = keep the log directory also on success

TESTDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOPDIR=$(cd "$TESTDIR/../.." && pwd)

SOCKETCAND=${SOCKETCAND:-$TOPDIR/build/src/socketcand}
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
CAN_IF=
IF_KIND=

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
	# close the client first: the client side gets TIME_WAIT, not the
	# socketcand port
	client_close
	bus_stop
	if [ -n "$SC_PID" ]; then
		sleep 0.1
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
	printf '\n%s%s %s (%s): %d passed, %d failed, %d skipped%s\n' "$C_B" \
	       "$(basename "$0")" "$CAN_IF" "$IF_KIND" "$PASS" "$FAIL" "$SKIP" "$C_N"
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
	    sudo ip link add dev vcan0 type vcan && sudo ip link set vcan0 mtu 16 up     # CAN CC
	    sudo ip link add dev vcan1 type vcan && sudo ip link set vcan1 mtu 72 up     # CAN FD
	    sudo ip link add dev vcan2 type vcan && sudo ip link set vcan2 mtu 2060 up   # CAN XL
	EOF
}

# iface_kind <iface> -> cc | fd | xl | missing | down | mtu<N>
iface_kind() {
	local ifc=$1 mtu flags
	[ -e "/sys/class/net/$ifc" ] || { echo missing; return; }
	flags=$(cat "/sys/class/net/$ifc/flags")
	(( (flags & 1) == 0 )) && { echo down; return; }
	mtu=$(cat "/sys/class/net/$ifc/mtu")
	if [ "$mtu" -eq 16 ]; then
		echo cc
	elif [ "$mtu" -eq 72 ]; then
		echo fd
	elif [ "$mtu" -ge 76 ]; then
		echo xl
	else
		echo "mtu$mtu"
	fi
}

# need_iface <iface> - sets CAN_IF and IF_KIND or exits
need_iface() {
	CAN_IF=$1
	IF_KIND=$(iface_kind "$CAN_IF")
	case $IF_KIND in
	cc|fd|xl)
		printf '%s%s: %s (%s)%s\n' "$C_B" "$(basename "$0")" "$CAN_IF" "$IF_KIND" "$C_N"
		;;
	*)
		printf 'CAN interface %s not usable: %s\n' "$CAN_IF" "$IF_KIND"
		vcan_hint
		exit 2
		;;
	esac
}

has_fd() { [ "$IF_KIND" = fd ] || [ "$IF_KIND" = xl ]; }
has_xl() { [ "$IF_KIND" = xl ]; }

# ---------------------------------------------------------------------------
# socketcand

port_open() {
	(exec 4<>"/dev/tcp/$HOST/$PORT") 2>/dev/null
}

# start_socketcand <ifaces> [extra socketcand options]
start_socketcand() {
	local ifaces=$1 try i
	shift
	if [ "$START_SOCKETCAND" != 1 ]; then
		info "using already running socketcand at $HOST:$PORT (must provide $ifaces)"
		port_open || die "nothing listens on $HOST:$PORT"
		return 0
	fi
	[ -x "$SOCKETCAND" ] || die "socketcand binary not found: $SOCKETCAND (meson setup build && ninja -C build, or set SOCKETCAND=/path/to/socketcand)"

	for ((try = 0; try < 20; try++, PORT++)); do
		if port_open; then
			info "port $PORT already in use - trying $((PORT + 1))"
			continue
		fi
		"$SOCKETCAND" -v -n -l "$LISTEN_IF" -p "$PORT" -i "$ifaces" "$@" >"$SC_LOG" 2>&1 &
		SC_PID=$!
		for i in $(seq 50); do
			if port_open; then
				info "socketcand -i $ifaces $* listens on $HOST:$PORT"
				return 0
			fi
			kill -0 "$SC_PID" 2>/dev/null || break
			sleep 0.1
		done
		kill -0 "$SC_PID" 2>/dev/null && die "socketcand does not listen on $HOST:$PORT"
		wait "$SC_PID" 2>/dev/null
		SC_PID=
		if grep -q "Address already in use" "$SC_LOG"; then
			# socketcand does not set SO_REUSEADDR (only with -DDEBUG)
			info "port $PORT blocked (bind: Address already in use, e.g. TIME_WAIT) - trying $((PORT + 1))"
			continue
		fi
		die "socketcand exited:"$'\n'"$(cat "$SC_LOG")"
	done
	die "no usable TCP port found"
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

# client_open - connect, open $CAN_IF, switch to raw mode, start capture
client_open() {
	exec 3<>"/dev/tcp/$HOST/$PORT" || die "cannot connect to $HOST:$PORT"
	CLIENT_OPEN=1
	expect_reply hi
	client_send "< open $CAN_IF >"
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
		stdbuf -oL candump -L "$CAN_IF" >"$BUS_LOG" 2>&1 &
	else
		candump -L "$CAN_IF" >"$BUS_LOG" 2>&1 &
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

# Normalize candump -L output:
#   CAN CC  123#1122 / 123#R / 123#1122334455667788_9 -> drop _<dlc>
#   CAN FD  123##<flags>DATA  -> flags reduced to BRS/ESI (candump adds FDF)
#   CAN XL  VVPPP#FF:SS:AAAAAAAA#DATA -> "XL:" prefix
bus_norm() {
	awk '{
		f = $3
		if (f ~ /:/) { print "XL:" f; next }
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
	if ! cansend "$CAN_IF" "$frame" >"$WORK/cansend.err" 2>&1; then
		fail "$desc: 'cansend $CAN_IF ${frame:0:60}' failed: $(head -n 1 "$WORK/cansend.err")"
		return
	fi
	if [ "$exp" = - ]; then
		sleep "$QUIET_TIME"
		got=$(sc_norm | tail -n +$((before + 1)))
		if [ -z "$got" ]; then
			pass "$desc (nothing forwarded)"
		else
			fail "$desc: cansend ${frame:0:60} -> unexpected '${got:0:100}'"
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
	local n=$1 s=${2:-0} i out=''
	for ((i = 0; i < n; i++)); do
		printf -v out '%s%02X' "$out" $(((s + i) & 255))
	done
	printf '%s' "$out"
}

# hex_sp <n> [start] -> "00 01 02 03 ..." (lowercase, spaces)
hex_sp() {
	local n=$1 s=${2:-0} i out=''
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
	local i out=''
	for ((i = 0; i < $1; i++)); do out+='00'; done
	printf '%s' "$out"
}

# xl_frame <vcid> <prio> <flags> <sdt> <af> <len> -> cansend CAN XL frame
xl_frame() {
	printf '%02X%03X#%02X:%02X:%08X#%s' "$1" "$2" "$3" "$4" "$5" "$(hex_cat "$6")"
}
