# Dual-Target Lab Interface

This document describes the dedicated CMOD S7 dual-target lab image:

- top (internal bus): `spartan7_i3c_dual_target_lab_top`
- top (external PHY bus): `spartan7_i3c_external_bus_top`
- controller: `rtl/fpga_test/i3c_dual_target_lab_controller.v`
- ENTDAA engine: `rtl/i3c_ctrl_entdaa.v`
- targets: `rtl/fpga_test/i3c_sensor_gpio_target_demo.v`
- UART bridge: `rtl/uart_dual_target_lab_cmd_handler.v`

## Purpose

The lab image is intentionally narrower than the five-target unified demo:

- 1 controller
- 2 known internal targets
- deterministic sample polling
- writable target register map
- two target-controlled LED outputs
- host-facing UART protocol for target A/B register reads and writes

This is meant for controller/host integration work, not for showing off how many synthetic targets fit on a board.

The current lab dashboard intentionally separates:

- `Operations`: live payload polling, decoded target status, and target LED/output control
- `CCC Lab`: safe read-only direct CCC inspection through the real controller path

## Target Register Map

Each target exposes the same register map.

| Address | Size | Access | Meaning |
| --- | --- | --- | --- |
| `0x00..0x03` | 4 | Read | 32-bit target signature, little-endian |
| `0x04` | 1 | Read/Write | LED/output control (`bit0`) |
| `0x05` | 1 | Read | Target index |
| `0x06..0x07` | 2 | Read | Frame counter |
| `0x08` | 1 | Read | Target-local status summary |
| `0x09` | 1 | Read | Last seen CCC code |
| `0x0A` | 1 | Read | Event-enable mask |
| `0x0B` | 1 | Read | `RSTACT` action |
| `0x0C..0x0D` | 2 | Read | CCC status word |
| `0x0E..0x0F` | 2 | Read | Activity/group-address summary |
| `0x10..0x19` | 10 | Read | Sensor payload window |
| `0x1A..0x1D` | 4 | Read | Max read/write length bytes |
| `0x1E` | 1 | Read | IBI data length field |

The sensor payload window uses the same 10-byte layout as the main demo:

| Byte Offset | Meaning |
| --- | --- |
| `0..1` | Sample 0, little-endian |
| `2..3` | Sample 1, little-endian |
| `4..5` | Sample 2, little-endian |
| `6..7` | Sample 3, little-endian |
| `8` | Temperature |
| `9` | Misc/status |

## UART Protocol

Request frame:

| Byte | Meaning |
| --- | --- |
| `0` | Sync `0xA5` |
| `1` | Command |
| `2` | Target (`0` or `1`) |
| `3` | `arg0` |
| `4` | `arg1` |

Response frame:

| Byte | Meaning |
| --- | --- |
| `0` | Sync `0x5A` |
| `1` | Status |
| `2` | Payload length |
| `3..` | Payload bytes |

Status codes:

| Code | Meaning |
| --- | --- |
| `0x00` | Success |
| `0x01` | Bad command |
| `0x02` | Busy / not booted |
| `0x03` | Bad target |
| `0x04` | Controller-side transaction error |

Commands:

| Command | Code | `arg0` | `arg1` | Response payload |
| --- | --- | --- | --- | --- |
| Start | `0x01` | ignored | ignored | none |
| Status | `0x02` | ignored | ignored | 4 bytes |
| Target summary | `0x10` | ignored | ignored | 18 bytes |
| Read target registers | `0x11` | register address | length (`1..16`) | register bytes |
| Write target register | `0x12` | register address | value | echoed value |

Status payload:

| Byte | Meaning |
| --- | --- |
| `0` | flags: `bit0=boot_done`, `bit1=boot_error`, `bit2=capture_error`, `bit3=recovery_active` |
| `1` | verified bitmap |
| `2` | sample-valid bitmap |
| `3` | target LED-state bitmap |

Target summary payload:

| Byte | Meaning |
| --- | --- |
| `0` | target index |
| `1` | dynamic address |
| `2` | verified flag |
| `3` | LED state |
| `4..7` | signature |
| `8..17` | latest 10-byte sampled payload |

## Python Client

`tools/dual_target_lab_client.py` provides:

- `start`
- `status`
- `summary <target>`
- `read <target> <addr> <length>`
- `write <target> <addr> <value>`
- `monitor`

Examples:

```bash
python tools/dual_target_lab_client.py start
python tools/dual_target_lab_client.py status
python tools/dual_target_lab_client.py summary 0
python tools/dual_target_lab_client.py read 1 0x10 10
python tools/dual_target_lab_client.py write 0 0x04 0x01
```

## Backend / Dashboard

FastAPI backend:

- file: `software/dual_target_lab_backend/app.py`
- environment variable: `DUAL_TARGET_LAB_PORT`

Endpoints:

- `GET /api/dashboard`
- `GET /api/ccc/catalog`
- `POST /api/ccc/execute`
- `POST /api/start`
- `GET /api/status`
- `GET /api/targets/{target}`
- `GET /api/targets/{target}/registers?addr=<n>&length=<n>`
- `POST /api/targets/{target}/registers`

Next.js frontend:

- file: `software/dual_target_lab_frontend/app/page.tsx`
- environment variable: `NEXT_PUBLIC_API_BASE`

The frontend is intentionally small:

- `Operations` tab:
  - start the demo
  - poll a combined dashboard view
  - read target A/B summaries and decoded register fields
  - toggle each target LED through the real controller-to-target write path
  - issue ad hoc register reads and writes against either target
- `CCC Lab` tab:
  - run safe read-only direct CCCs against target A or B
  - decode `GETPID`, `GETBCR`, `GETDCR`, `GETSTATUS`, `GETMWL`, `GETMRL`, `GETMXDS`, and `GETCAPS`
  - show raw response bytes plus decoded results
  - keep recent CCC history visible without disturbing the live operations view

## Boot Path Selection (`USE_ENTDAA` parameter)

Both `i3c_dual_target_lab_controller` and the external-bus top expose a `USE_ENTDAA` integer parameter (default `0`).

| Value | Boot path | Use case |
| --- | --- | --- |
| `0` | `SETDASA` on each static address in `STATIC_ADDR_BASE + i` | Known-target internal lab demo (fastest, used by Phase 1 bitstream) |
| `1` | `ENTDAA` discovery loop, followed by the same `GETPID`/`GETBCR`/`GETDCR` verification pass | External bus with real sensors (e.g. TDK ICM-42605 at static 0x68) |

The ENTDAA path reuses `rtl/i3c_ctrl_entdaa.v` (PID/BCR/DCR capture + dynamic-address assignment) and walks `boot_index` from 0 to `ENDPOINT_COUNT-1`, assigning `DYN_ADDR_BASE + boot_index` to each discovered target. Failure at any point sets `boot_error` and routes to `ST_ERROR`, the same as the SETDASA path.

Regression coverage:

- `make sim-dual-target-lab-controller` — SETDASA boot (`USE_ENTDAA=0`)
- `make sim-dual-target-lab-controller-entdaa` — ENTDAA boot (`USE_ENTDAA=1`, overrides the TB parameter via `-Ptb_i3c_dual_target_lab_controller.USE_ENTDAA=1`)

Both testbenches run at `I3C_SDR_HZ = 4_000_000` (4 MHz), which matches the validated hardware rate once the target-side 2-stage input synchronizers are in play.

## CMOD LED Mapping (Dual-Target Lab Demo)

| LED | Meaning |
| --- | --- |
| LED0 | Target A writable output state |
| LED1 | Target B writable output state |
| LED2 | Target A sample-valid status |
| LED3 | Target B sample-valid status |
| RGB blue | Recovery active |
| RGB green | Boot done |
| RGB red | Boot or capture error |
