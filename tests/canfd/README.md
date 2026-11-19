# socketcand raw mode tests (CAN CC / CAN FD / CAN XL)

Shell based tests for the raw mode (`< frame >`, `< send >`, `< fdframe >`,
`< fdsend >`) on virtual CAN interfaces. They run as a normal user. The TCP
client uses bash `/dev/tcp`; the CAN side uses `cansend`, `candump` and
`cangen` from can-utils (a version with CAN XL support).

## Setup (once, as root)

    sudo modprobe vcan
    sudo ip link add dev vcan0 type vcan && sudo ip link set vcan0 mtu 16 up     # CAN CC
    sudo ip link add dev vcan1 type vcan && sudo ip link set vcan1 mtu 72 up     # CAN FD
    sudo ip link add dev vcan2 type vcan && sudo ip link set vcan2 mtu 2060 up   # CAN XL

The interface type is taken from the MTU (16: CC, 72: FD, >= 76: XL) and the
tests adapt to it:

| Type | Tested                                                                   |
|------|--------------------------------------------------------------------------|
| CC   | CC frames both ways, `< fdsend >` is rejected, connection stays          |
| FD   | CC + CAN FD both ways, padding, invalid `< fdsend >` commands            |
| XL   | as FD, plus CAN XL traffic which must not reach the client               |

## Build and run

    meson setup build && ninja -C build
    tests/canfd/run_all.sh                 # all vcan interfaces that are up
    tests/canfd/run_all.sh vcan1 vcan2     # selected interfaces
    tests/canfd/test_tx.sh vcan2           # single test

| Script            | What it checks                                                        |
|-------------------|-----------------------------------------------------------------------|
| `test_rx.sh`      | cansend -> `< frame >` / `< fdframe >` / `< error >` at the client; RTR and CAN XL frames are not forwarded |
| `test_tx.sh`      | `< send >` / `< fdsend >` -> candump, padding, invalid commands, burst in one TCP write |
| `test_stress.sh`  | cangen random traffic (CC/EFF/len8_dlc/RTR/FD/XL/mixed) and random TX commands, compared with candump |

Each script starts its own `build/src/socketcand -v -n -l lo -p <port>`. If
the port is busy or still blocked by TIME_WAIT (socketcand does not set
SO_REUSEADDR), the next port is used.

## Environment variables

| Variable           | Default                      | Meaning                                  |
|--------------------|------------------------------|------------------------------------------|
| `SOCKETCAND`       | `<top>/build/src/socketcand` | binary to start                          |
| `START_SOCKETCAND` | `1`                          | `0` = use an already running instance    |
| `HOST` / `PORT`    | `127.0.0.1` / `29536`        | socketcand address (first port to try)   |
| `LISTEN_IF`        | `lo`                         | `-l` interface of the started instance   |
| `STRESS_N`         | `500`                        | frames per run in `test_stress.sh`       |
| `TIMEOUT`          | `2`                          | seconds to wait for an expected frame    |
| `KEEP`             | `0`                          | `1` = keep logs (always kept on failure) |

Logs (socketcand output, client stream, candump) are kept in
`$TMPDIR/socketcand-test.*` when a test fails.
