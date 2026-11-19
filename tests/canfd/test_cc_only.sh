#!/bin/bash
# SPDX-License-Identifier: (GPL-2.0-only OR BSD-3-Clause)
#
# socketcand on a CAN CC only interface (MTU 16)
#
# Classic CAN must work in both directions, '< fdsend >' must be rejected
# without putting anything on the bus and without dropping the connection.

. "$(dirname "$0")/lib.sh"

CAN_IF=${CC_IF:-vcan1}

need_tools cansend candump
if ! iface_check "$CAN_IF" cc; then
	skip "CAN CC only interface $CAN_IF not available"
	summary
	exit 0
fi

start_socketcand "$CAN_IF"
bus_start "$CAN_IF"
client_open "$CAN_IF"

section "CAN CC only interface $CAN_IF"
tx_step "CC send SFF"               "< send 123 2 11 22 >"                    "123#1122"
tx_step "CC send EFF len 8"         "< send 00000456 8 $(hex_sp 8) >"         "00000456#$(hex_cat 8)"
tx_step "fdsend rejected"           "< fdsend 123 00 2 11 22 >"               "-"
tx_step "fdsend len 64 rejected"    "< fdsend 123 01 64 $(hex_sp 64) >"       "-"
client_alive
rx_step "CC SFF -> client"          "321#AABB"                                "321#AABB"
rx_step "CC EFF -> client"          "1FFFFFFF#0102030405060708"               "1FFFFFFF#0102030405060708"
tx_step "CC send still works"       "< send 7FF 1 01 >"                       "7FF#01"

if [ "$START_SOCKETCAND" = 1 ]; then
	if grep -q "CAN FD is not supported" "$SC_LOG"; then
		pass "socketcand logged 'CAN FD is not supported'"
	else
		fail "no 'CAN FD is not supported' message in socketcand log"
	fi
fi

summary
