#!/bin/bash
# SPDX-License-Identifier: (GPL-2.0-only OR BSD-3-Clause)
#
# socketcand client -> CAN bus (raw mode)
#
# '< send >' and '< fdsend >' commands are sent over TCP and the frames on the
# CAN FD capable interface are checked with candump. Invalid commands must not
# put anything on the bus and must not terminate the connection.

. "$(dirname "$0")/lib.sh"

CAN_IF=${CAN_IF:-vcan0}

need_tools candump
iface_check "$CAN_IF" fd || exit 2

start_socketcand "$CAN_IF"
bus_start "$CAN_IF"
client_open "$CAN_IF"

section "CAN CC: client -> $CAN_IF (< send >)"
tx_step "CC SFF len 0"              "< send 123 0 >"                          "123#"
tx_step "CC SFF len 1"              "< send 123 1 11 >"                       "123#11"
tx_step "CC SFF len 8"              "< send 123 8 11 22 33 44 55 66 77 88 >"  "123#1122334455667788"
tx_step "CC SFF id 7FF, uppercase"  "< send 7FF 2 DE AD >"                    "7FF#DEAD"
tx_step "CC SFF id 000"             "< send 000 1 00 >"                       "000#00"
tx_step "CC EFF 00000123"           "< send 00000123 4 01 02 03 04 >"         "00000123#01020304"
tx_step "CC EFF 1FFFFFFF len 8"     "< send 1FFFFFFF 8 $(hex_sp 8 1) >"       "1FFFFFFF#$(hex_cat 8 1)"
tx_step "CC EFF len 0"              "< send 12345678 0 >"                     "12345678#"

section "CAN CC: invalid < send > commands"
tx_step "CC len 9"                  "< send 123 9 $(hex_sp 9) >"              "-"
tx_step "CC too few data bytes"     "< send 123 3 11 22 >"                    "-"
client_alive

section "CAN FD: client -> $CAN_IF (< fdsend >)"
tx_step "FD SFF len 0"              "< fdsend 123 00 0 >"                     "123##0"
tx_step "FD SFF len 1"              "< fdsend 123 00 1 11 >"                  "123##011"
tx_step "FD SFF len 2 (stays FD)"   "< fdsend 123 00 2 11 22 >"               "123##01122"
for l in 8 12 16 20 24 32 48 64; do
	tx_step "FD SFF len $l"     "< fdsend 123 00 $l $(hex_sp "$l") >"     "123##0$(hex_cat "$l")"
done
tx_step "FD flags BRS"              "< fdsend 123 01 8 $(hex_sp 8 16) >"      "123##1$(hex_cat 8 16)"
tx_step "FD flags ESI"              "< fdsend 123 02 8 $(hex_sp 8 16) >"      "123##2$(hex_cat 8 16)"
tx_step "FD flags BRS+ESI"          "< fdsend 123 03 8 $(hex_sp 8 16) >"      "123##3$(hex_cat 8 16)"
tx_step "FD flags single digit"     "< fdsend 123 1 1 aa >"                   "123##1AA"
tx_step "FD EFF 00000123 len 64"    "< fdsend 00000123 01 64 $(hex_sp 64 128) >" "00000123##1$(hex_cat 64 128)"
tx_step "FD EFF 1FFFFFFF len 64"    "< fdsend 1FFFFFFF 03 64 $(hex_sp 64 200) >" "1FFFFFFF##3$(hex_cat 64 200)"
tx_step "FD SFF 7FF, uppercase data" "< fdsend 7FF 00 3 AA BB CC >"           "7FF##0AABBCC"
tx_step "FD EFF len 0"              "< fdsend 1ABCDEF0 01 0 >"                "1ABCDEF0##1"
tx_step "FD no space before '>'"    "< fdsend 123 00 1 11>"                   "123##011"

section "CAN FD: padding of non-canonical lengths"
for l in 9 11 13 17 21 25 33 47 49 63; do
	p=$(fd_padlen "$l")
	tx_step "FD len $l -> $p"   "< fdsend 123 00 $l $(hex_sp "$l" 1) >"   "123##0$(hex_cat "$l" 1)$(zeros $((p - l)))"
done

section "CAN FD: invalid < fdsend > commands"
tx_step "FD len 65"                 "< fdsend 123 00 65 $(hex_sp 65) >"       "-"
tx_step "FD flags 04 (FDF)"         "< fdsend 123 04 1 11 >"                  "-"
tx_step "FD flags 10"               "< fdsend 123 10 1 11 >"                  "-"
tx_step "FD SFF id 800 (> 7FF)"     "< fdsend 800 00 1 11 >"                  "-"
tx_step "FD EFF id 20000000"        "< fdsend 20000000 00 1 11 >"             "-"
tx_step "FD too few data bytes"     "< fdsend 123 00 3 11 22 >"               "-"
tx_step "FD too many data bytes"    "< fdsend 123 00 2 11 22 33 >"            "-"
tx_step "FD missing len"            "< fdsend 123 00 >"                       "-"
tx_step "FD missing flags and len"  "< fdsend 123 >"                          "-"
tx_step "FD non-hex data"           "< fdsend 123 00 1 zz >"                  "-"
client_alive
tx_step "valid FD frame after invalid ones" "< fdsend 123 01 1 42 >"          "123##142"

section "Burst: several commands in one TCP write"
burst=
exp=()
for i in $(seq 0 9); do
	burst+="< fdsend 2$(printf %02X "$i") 01 64 $(hex_sp 64 "$i") >"
	exp+=("2$(printf %02X "$i")##1$(hex_cat 64 "$i")")
	burst+="< send 3$(printf %02X "$i") 8 $(hex_sp 8 "$i") >"
	exp+=("3$(printf %02X "$i")#$(hex_cat 8 "$i")")
done
before=$(bus_norm | wc -l)
client_send "$burst"
wait_lines bus_norm $((before + ${#exp[@]}))
if diff <(printf '%s\n' "${exp[@]}") <(bus_norm | tail -n +$((before + 1))) >"$WORK/burst.diff"; then
	pass "burst of ${#exp[@]} mixed CC/FD commands (${#burst} bytes)"
else
	fail "burst of ${#exp[@]} mixed CC/FD commands, diff expected/bus:"
	head -n 20 "$WORK/burst.diff"
fi
client_alive

summary
