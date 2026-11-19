# socketcand CAN CC / CAN FD raw mode tests

Shell based tests for the raw mode (`< frame >`, `< send >`, `< fdframe >`,
`< fdsend >`) on virtual CAN interfaces. They run as a normal user. The TCP
client uses bash `/dev/tcp`; the CAN side uses `cansend`, `candump` and
`cangen` from can-utils.

## Setup (once, as root)

    sudo modprobe vcan
    sudo ip link add dev vcan0 type vcan
    sudo ip link set vcan0 mtu 72 up     # CAN FD capable
    sudo ip link add dev vcan1 type vcan
    sudo ip link set vcan1 mtu 16 up     # CAN CC only (optional)

## Build and run

    meson setup build && ninja -C build
    tests/canfd/run_all.sh

By default each script starts its own `build/socketcand -n -l lo -p 29536`.

| Script            | What it checks                                                        |
|-------------------|-----------------------------------------------------------------------|
| `test_rx.sh`      | cansend on vcan0 -> `< frame >` / `< fdframe >` / `< error >` at the client |
| `test_tx.sh`      | `< send >` / `< fdsend >` -> candump, padding, invalid commands, burst |
| `test_cc_only.sh` | vcan1 (MTU 16): CC works, `< fdsend >` is rejected, connection stays  |
| `test_stress.sh`  | cangen random traffic and random TX commands, compared with candump   |

## Environment variables

| Variable           | Default                 | Meaning                                  |
|--------------------|-------------------------|------------------------------------------|
| `SOCKETCAND`       | `<top>/build/socketcand`| binary to start                          |
| `START_SOCKETCAND` | `1`                     | `0` = use an already running instance    |
| `HOST` / `PORT`    | `127.0.0.1` / `29536`   | socketcand address                       |
| `LISTEN_IF`        | `lo`                    | `-l` interface of the started instance   |
| `CAN_IF` / `CC_IF` | `vcan0` / `vcan1`       | CAN FD / CAN CC only interface           |
| `STRESS_N`         | `500`                   | frames per run in `test_stress.sh`       |
| `TIMEOUT`          | `2`                     | seconds to wait for an expected frame    |
| `KEEP`             | `0`                     | `1` = keep logs (always kept on failure) |

Logs (socketcand output, client stream, candump) are kept in
`$TMPDIR/socketcand-test.*` when a test fails.
