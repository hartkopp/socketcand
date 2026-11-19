#!/bin/bash
# SPDX-License-Identifier: (GPL-2.0-only OR BSD-3-Clause)
#
# Random traffic in both directions, compared against candump as reference.
#
# usage: test_stress.sh [vcanX]   (default: vcan1)
#
#   RX: cangen generates all frame types the interface supports (CC, FD, XL,
#       RTR). Everything candump sees, except RTR and CAN XL frames, has to
#       arrive at the client - nothing else.
#   TX: random '< send >' (and '< fdsend >' on CAN FD/XL interfaces)
#       commands, everything has to show up on the bus (CAN FD padded to
#       valid lengths).
#
# STRESS_N: frames per cangen run and number of random TX frames (default 500)

. "$(dirname "$0")/lib.sh"

need_tools cangen candump
need_iface "${1:-vcan1}"
N=${STRESS_N:-500}

start_socketcand "$CAN_IF"
bus_start
client_open

variants=("" "-e" "-8" "-R")
has_fd && variants+=("-f" "-f -b -E -e")
has_xl && variants+=("-X")
variants+=("-m")

section "RX: cangen on $CAN_IF -> client ($N frames per run)"
for opts in "${variants[@]}"; do
	# shellcheck disable=SC2086
	if cangen "$CAN_IF" $opts -n "$N" -g 1 -p 10 >"$WORK/cangen.err" 2>&1; then
		info "cangen ${opts:-(CC)} -n $N done"
	else
		fail "cangen $opts failed: $(head -n 1 "$WORK/cangen.err")"
	fi
done

# reference: everything candump saw, without RTR and CAN XL frames
bus_norm | grep -v -e '#R' -e '^XL:' >"$WORK/rx.expected"
n_rtr=$(bus_norm | grep -c '#R')
n_xl=$(bus_norm | grep -c '^XL:')
want=$(wc -l <"$WORK/rx.expected")
wait_lines sc_norm "$want" 10
sleep "$QUIET_TIME"
sc_norm >"$WORK/rx.got"
if diff "$WORK/rx.expected" "$WORK/rx.got" >"$WORK/rx.diff"; then
	pass "all $want frames received by the client (CC: $(grep -vc '##' "$WORK/rx.got"), FD: $(grep -c '##' "$WORK/rx.got"))"
else
	fail "client stream differs from candump ($want expected, $(wc -l <"$WORK/rx.got") received), first differences:"
	head -n 20 "$WORK/rx.diff"
fi
info "not forwarded as expected: $n_rtr RTR frames, $n_xl CAN XL frames"
if has_xl && [ "$n_xl" -eq 0 ]; then
	fail "no CAN XL frames seen on the bus - XL traffic was not generated"
fi

section "TX: $N random < send > $(has_fd && echo '/ < fdsend > ')commands -> $CAN_IF"

# gen_random sets CMD and EXP
gen_random() {
	local fd=0 id len flags=0 i b sp='' cat=''
	has_fd && fd=$((RANDOM % 2))
	if ((RANDOM % 2)); then
		printf -v id '%08X' $((((RANDOM << 15) | RANDOM) & 0x1FFFFFFF))
	else
		printf -v id '%03X' $((RANDOM & 0x7FF))
	fi
	if ((fd)); then
		len=$((RANDOM % 65))
		flags=$((RANDOM % 4))
	else
		len=$((RANDOM % 9))
	fi
	for ((i = 0; i < len; i++)); do
		b=$((RANDOM & 255))
		printf -v sp '%s %02x' "$sp" "$b"
		printf -v cat '%s%02X' "$cat" "$b"
	done
	if ((fd)); then
		CMD="< fdsend $id 0$flags $len$sp >"
		EXP="$id##$flags$cat$(zeros $(($(fd_padlen "$len") - len)))"
	else
		CMD="< send $id $len$sp >"
		EXP="$id#$cat"
	fi
}

before=$(bus_norm | wc -l)
: >"$WORK/tx.expected"
sent=0
while ((sent < N)); do
	batch=''
	for ((k = 0; k < 10 && sent < N; k++, sent++)); do
		gen_random
		batch+=$CMD
		printf '%s\n' "$EXP" >>"$WORK/tx.expected"
	done
	client_send "$batch"
	# let socketcand drain the batch before the next write
	wait_lines bus_norm $((before + sent)) || break
done
sleep "$QUIET_TIME"
bus_norm | tail -n +$((before + 1)) >"$WORK/tx.got"
if diff "$WORK/tx.expected" "$WORK/tx.got" >"$WORK/tx.diff"; then
	pass "all $N random frames on the bus (CC: $(grep -vc '##' "$WORK/tx.got"), FD: $(grep -c '##' "$WORK/tx.got"))"
else
	fail "bus traffic differs ($N expected, $(wc -l <"$WORK/tx.got") on bus), first differences:"
	head -n 20 "$WORK/tx.diff"
fi
client_alive

summary
