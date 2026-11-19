#!/bin/bash
# SPDX-License-Identifier: (GPL-2.0-only OR BSD-3-Clause)
#
# CAN bus -> socketcand client (raw mode)
#
# Frames are injected with cansend on a CAN FD capable interface and the
# '< frame >' / '< fdframe >' / '< error >' elements sent to the TCP client
# are checked.

. "$(dirname "$0")/lib.sh"

CAN_IF=${CAN_IF:-vcan0}

need_tools cansend
iface_check "$CAN_IF" fd || exit 2

# error frames are only forwarded with an error mask (-e)
start_socketcand "$CAN_IF" -e 0x1FFFFFFF
client_open "$CAN_IF"

section "CAN CC: $CAN_IF -> client"
rx_step "CC SFF len 0"                  "123#"                     "123#"
rx_step "CC SFF len 1"                  "123#11"                   "123#11"
rx_step "CC SFF len 4"                  "123#11223344"             "123#11223344"
rx_step "CC SFF len 8"                  "123#1122334455667788"     "123#1122334455667788"
rx_step "CC SFF id 000"                 "000#00"                   "000#00"
rx_step "CC SFF id 7FF"                 "7FF#DEADBEEF"             "7FF#DEADBEEF"
rx_step "CC EFF id 00000123"            "00000123#11223344"        "00000123#11223344"
rx_step "CC EFF id 1FFFFFFF len 8"      "1FFFFFFF#0102030405060708" "1FFFFFFF#0102030405060708"
rx_step "CC EFF len 0"                  "12345678#"                "12345678#"
# len8_dlc shares the byte with canfd_frame.flags - must still be a < frame >
rx_step "CC len 8 with len8_dlc 9"      "123#1122334455667788_9"   "123#1122334455667788"
rx_step "CC len 8 with len8_dlc F"      "123#1122334455667788_F"   "123#1122334455667788"
rx_step "CC RTR (not implemented in socketcand)" "123#R"           "-"
rx_step "CC RTR with len (not implemented)"      "123#R4"          "-"

if [ "$START_SOCKETCAND" = 1 ]; then
	rx_step "error frame CAN_ERR_CRTL (-e mask)" "20000004#0004000000000000" "ERROR:004"
else
	skip "error frame (needs socketcand started with -e)"
fi

section "CAN FD: $CAN_IF -> client"
rx_step "FD SFF len 0"                  "123##0"                   "123##0"
rx_step "FD SFF len 1"                  "123##011"                 "123##011"
# FD frames with <= 8 bytes must not be reported as < frame >
rx_step "FD SFF len 2 (not a CC frame)" "123##01122"               "123##01122"
for l in 8 12 16 20 24 32 48 64; do
	d=$(hex_cat "$l")
	rx_step "FD SFF len $l"         "123##0$d"                 "123##0$d"
done
d=$(hex_cat 8 16)
rx_step "FD flags BRS"                  "123##1$d"                 "123##1$d"
rx_step "FD flags ESI"                  "123##2$d"                 "123##2$d"
rx_step "FD flags BRS+ESI"              "123##3$d"                 "123##3$d"
d=$(hex_cat 64 128)
rx_step "FD EFF 00000123 len 64 BRS"    "00000123##1$d"            "00000123##1$d"
rx_step "FD EFF 1FFFFFFF len 64 BRS+ESI" "1FFFFFFF##3$d"           "1FFFFFFF##3$d"
rx_step "FD SFF 7FF len 64"             "7FF##0$d"                 "7FF##0$d"
rx_step "FD EFF len 0"                  "1ABCDEF0##1"              "1ABCDEF0##1"

section "mixed CC / FD sequence: $CAN_IF -> client"
rx_step "CC after FD"                   "321#AA"                   "321#AA"
rx_step "FD after CC"                   "321##1AA"                 "321##1AA"
rx_step "CC after FD (len 8)"           "321#0011223344556677"     "321#0011223344556677"

section "CAN FD with non-canonical length (informational)"
# cansend passes len 9 unchanged, vcan does not round it up
before=$(sc_norm | wc -l)
cansend "$CAN_IF" "456##0$(hex_cat 9)" 2>/dev/null
wait_lines sc_norm $((before + 1))
info "cansend 456##0$(hex_cat 9) -> '$(sc_norm | sed -n "$((before + 1))p")'"

client_alive
summary
