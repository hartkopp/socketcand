#!/bin/bash
# SPDX-License-Identifier: (GPL-2.0-only OR BSD-3-Clause)
#
# Run all socketcand CAN CC / CAN FD raw mode tests.

cd "$(dirname "$0")" || exit 2

rc=0
for t in test_rx.sh test_tx.sh test_cc_only.sh test_stress.sh; do
	printf '\n########## %s ##########\n' "$t"
	./"$t" || rc=1
done

if [ "$rc" -eq 0 ]; then
	printf '\nall tests passed\n'
else
	printf '\nsome tests FAILED\n'
fi
exit "$rc"
