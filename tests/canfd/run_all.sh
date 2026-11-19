#!/bin/bash
# SPDX-License-Identifier: (GPL-2.0-only OR BSD-3-Clause)
#
# Run all socketcand raw mode tests on all vcan interfaces.
#
# usage: run_all.sh [vcanX ...]   (default: all vcan interfaces that are up)
#
# The interface type (CAN CC / FD / XL) is taken from the MTU, the tests
# adapt to it.

cd "$(dirname "$0")" || exit 2

if [ $# -gt 0 ]; then
	ifaces=("$@")
else
	ifaces=()
	for ifc in $(printf "%s\n" /sys/class/net/vcan* | sed "s,.*/,," | grep -v "^vcan\*$" | sort -V); do
		if (( $(cat "/sys/class/net/$ifc/flags") & 1 )); then
			ifaces+=("$ifc")
		else
			printf 'skipping %s (interface is down)\n' "$ifc"
		fi
	done
fi

if [ ${#ifaces[@]} -eq 0 ]; then
	cat <<-EOF
	no vcan interfaces found. Create them once as root, e.g.:
	  sudo modprobe vcan
	  sudo ip link add dev vcan0 type vcan && sudo ip link set vcan0 mtu 16 up     # CAN CC
	  sudo ip link add dev vcan1 type vcan && sudo ip link set vcan1 mtu 72 up     # CAN FD
	  sudo ip link add dev vcan2 type vcan && sudo ip link set vcan2 mtu 2060 up   # CAN XL
	EOF
	exit 2
fi

results=()
rc=0
for ifc in "${ifaces[@]}"; do
	for t in test_rx.sh test_tx.sh test_stress.sh; do
		printf '\n########## %s %s ##########\n' "$t" "$ifc"
		./"$t" "$ifc"
		r=$?
		case $r in
		0) res=ok ;;
		2) res=ERROR; rc=1 ;;
		*) res=FAILED; rc=1 ;;
		esac
		mtu=$(cat "/sys/class/net/$ifc/mtu" 2>/dev/null)
		results+=("$(printf '%-8s mtu %-5s %-16s %s' "$ifc" "${mtu:--}" "$t" "$res")")
	done
done

printf '\n########## summary ##########\n'
printf '%s\n' "${results[@]}"
if [ "$rc" -eq 0 ]; then
	printf '\nall tests passed\n'
else
	printf '\nsome tests FAILED\n'
fi
exit "$rc"
