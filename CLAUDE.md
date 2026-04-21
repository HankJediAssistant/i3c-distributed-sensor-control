# CLAUDE.md — I3C Distributed Sensor Control

This file gives Claude Code instant context on where this project stands and what's next. Read this before touching anything.

---

## What This Project Is

A full I3C controller/target RTL baseline on a **Cmod S7 (Spartan-7 FPGA)**, with:
- Verilog RTL (controller + targets)
- Vivado 2025.2 build flow
- Python FastAPI backend (UART bridge)
- Next.js dashboard (Operations + CCC Lab tabs)

The goal is a real, working I3C hardware platform — not just simulation. We connect to actual sensors.

---

## Hardware

- **Board:** Digilent Cmod S7 (Spartan-7 FPGA)
- **Toolchain:** Vivado 2025.2 at `/opt/Xilinx/2025.2/`
- **FPGA plugged in via USB**
- **Dev machine:** Ubuntu Linux, `/home/jhaas/Development/i3c-distributed-sensor-control/`

---

## Current State (as of Apr 15, 2026)

### ✅ Phase 1 — Dual-Target Internal Lab (COMPLETE)

Top module: `rtl/fpga_test/spartan7_i3c_dual_target_lab_top.v`

- 1 I3C controller + 2 internal targets
- Static addresses: `0x30`, `0x31` → dynamic assigned `0x10`, `0x11`
- 10-byte sensor payload window per target (registers `0x10..0x19`)
- Writable LED/output control register at `0x04` per target
- UART command bridge (sync byte `0xA5` / `0x5A`, 5-byte request, variable response)
- Python client + FastAPI backend: `software/dual_target_lab_backend/app.py`
- Next.js dashboard: `software/dual_target_lab_frontend/`
  - **Operations tab:** live polling, payload validation, LED control, frame counter
  - **CCC Lab tab:** read-only direct CCC inspection (identity, capability, status)
- All PRs merged on `HankJediAssistant/codex/full-controller`

### ✅ Phase 2 — External PHY Bus (COMPLETE, last milestone)

Top module: `rtl/fpga_test/spartan7_i3c_external_bus_top.v`
Constraints: `constraints/spartan7_i3c_external_bus.xdc`
Bitstream: `build/i3c_external_bus/i3c_external_bus.runs/impl_1/spartan7_i3c_external_bus_top.bit`
Build log: `build_external_bus.log` — BUILD SUCCESSFUL (Mar 29, 2026)

Key: SDA/SCL now exposed on **physical FPGA pins** via IOBUF primitives (true open-drain topology).

**Last commit:** `4c70f28` — *"fix: external bus working with 2-stage synchronizers"* (Mar 31, 2026)

Critical fix: Added 2-stage input synchronizers to `i3c_target_transport.v` and `i3c_target_ccc.v` to prevent metastability from slow external edges on breadboard wiring.

**Verified working:**
- Both targets boot and respond to CCCs
- Sensor polling works continuously
- Dashboard shows all payloads matching
- **4 MHz stable** on breadboard — 6+ MHz fails (parasitic capacitance, expected)

### External Bus Pin Mapping (Cmod S7 DIP Header)

| Device | SDA Pin | SCL Pin | Cmod S7 DIP |
|--------|---------|---------|-------------|
| Controller | L1 | M4 | Pin 1, Pin 2 |
| Target 0 | M3 | N2 | Pin 3, Pin 4 |
| Target 1 | M2 | N1 | Pin 5, Pin 6 |

**Breadboard wiring:**
```
SDA Bus: L1 + M3 + M2 ──┬── 2.2kΩ ── 3.3V
SCL Bus: M4 + N2 + N1 ──┴── 2.2kΩ ── 3.3V
```

---

## 🎯 Phase 3 — TDK ICM-42605 IMU Integration (IN PROGRESS)

The external bus is ready. The next milestone is connecting a **real I3C sensor** — the **TDK/InvenSense ICM-42605** on the EV_ICM-42605 evaluation board — to the physical bus pins.

### Phase 3 plan (stored at `~/.claude/plans/zany-plotting-ladybug.md`):
- **Phase A — Hardware bring-up** (no RTL): bypass EV-board pullups, strap AD0→GND, wire IMU to DIP-5/DIP-6. ⏳ **Pending** (scheduled for the next hardware session).
- **Phase B — Wire ENTDAA into boot FSM** (feature-flagged): reuse existing `rtl/i3c_ctrl_entdaa.v`, add `USE_ENTDAA` parameter, 3-way PHY owner mux, parameterized testbench. ✅ **COMPLETE** — see below.
- **Phase C** — Widen `PAYLOAD_BYTES` 10 → 14 (accel + gyro + temp). Not started.
- **Phase D** — Swap emulated Target 1 for the real IMU, add `PWR_MGMT0` / `ACCEL_CONFIG0` / `GYRO_CONFIG0` init writes. Not started.
- **Phase E** — Backend decode + dashboard render for IMU data. Not started.

### ✅ Phase 3-B — ENTDAA boot path (COMPLETE, Apr 15, 2026)

`rtl/fpga_test/i3c_dual_target_lab_controller.v` gained a `USE_ENTDAA` parameter (default `0`). When set to `1`, the boot FSM routes through a new ENTDAA state group (`ST_BOOT_ENTDAA_REQ/WAIT_DISCOVER/ASSIGN/WAIT_DONE`) that drives the existing `i3c_ctrl_entdaa` engine, assigning `DYN_ADDR_BASE + boot_index` to each discovered target before falling into the existing `GETPID`/`GETBCR`/`GETDCR` verification pass. When `USE_ENTDAA=0`, the original `SETDASA` path runs unchanged.

- PHY ownership is now a 3-way mux (entdaa / dccc / txn) keyed on `state`.
- Top-level exposure: `rtl/fpga_test/spartan7_i3c_external_bus_top.v` forwards a `USE_ENTDAA` parameter to the controller.
- Testbench: `tb/tb_i3c_dual_target_lab_controller.v` is parameterized. Run either variant:
  - `make sim-dual-target-lab-controller` — SETDASA path (PASS)
  - `make sim-dual-target-lab-controller-entdaa` — ENTDAA path (PASS)
- Existing `make sim-entdaa{,-multi,-stress}` regressions still PASS (no ENTDAA-engine regressions from the wiring change).

### Current DAA approach:
- Internal dual-target lab still boots via `SETDASA` by default (known static addresses 0x30/0x31).
- ENTDAA is wired and simulation-validated; switch by passing `.USE_ENTDAA(1)` at the top level. The real IMU will require ENTDAA (static 0x68 doesn't match the existing `STATIC_ADDR_BASE`).

### Known non-Phase-B sim failures (pre-existing, not caused by Phase B):
- `sim-fpga-test-system`: `boot_error` at state 8, `dccc_nack=1` on target 0x30
- `sim-known-target-hub`: `boot_error asserted`

Both fail at the clean HEAD before any Phase B edits — confirmed by stashing the working tree and re-running.

---

## Build Commands

```bash
# Source Vivado
source /opt/Xilinx/2025.2/Vivado/settings64.sh

# Build dual-target internal lab
make build-dual-target   # or: vivado -mode batch -source scripts/build_dual_target.tcl

# Build external bus variant
make build-external-bus  # or: vivado -mode batch -source scripts/build_external_bus.tcl

# Program FPGA
vivado -mode batch -source scripts/program.tcl

# Run backend (FastAPI via uvicorn, set serial port env var first)
# NOTE: port MUST be 8765 — frontend .env.local hardcodes NEXT_PUBLIC_API_BASE=http://localhost:8765
# NOTE: Cmod S7 enumerates as /dev/ttyUSB1 on this machine (FT2232H UART interface);
#       /dev/ttyUSB0 is the JTAG interface. Verify with `udevadm info -q property -n /dev/ttyUSBx`.
DUAL_TARGET_LAB_PORT=/dev/ttyUSB1 uvicorn software.dual_target_lab_backend.app:app --reload --port 8765
# or from the backend dir:
cd software/dual_target_lab_backend && DUAL_TARGET_LAB_PORT=/dev/ttyUSB1 uvicorn app:app --reload --port 8765

# Run frontend (Next.js dev server)
cd software/dual_target_lab_frontend && npm run dev
# Runs on http://localhost:3000 by default
```

---

## Key Files

| File | Purpose |
|------|---------|
| `rtl/fpga_test/spartan7_i3c_external_bus_top.v` | External PHY bus top (current); exposes `USE_ENTDAA` parameter |
| `rtl/fpga_test/spartan7_i3c_dual_target_lab_top.v` | Internal dual-target top |
| `rtl/fpga_test/i3c_dual_target_lab_controller.v` | Lab controller; `USE_ENTDAA` selects SETDASA or ENTDAA boot |
| `rtl/fpga_test/i3c_sensor_gpio_target_demo.v` | Target module |
| `rtl/i3c_ctrl_entdaa.v` | Controller-side ENTDAA engine (reused by the lab controller) |
| `rtl/uart_dual_target_lab_cmd_handler.v` | UART bridge |
| `rtl/i3c_target_transport.v` | Target transport (has 2-stage sync) |
| `rtl/i3c_target_ccc.v` | Target CCC handler (has 2-stage sync) |
| `rtl/i3c_ctrl_direct_ccc.v` | Controller CCC (has ST_PRE_ACK fix) |
| `constraints/spartan7_i3c_external_bus.xdc` | External bus pin constraints |
| `tb/tb_i3c_dual_target_lab_controller.v` | Parameterized regression (SETDASA or ENTDAA path) |
| `software/dual_target_lab_backend/app.py` | FastAPI backend |
| `software/dual_target_lab_frontend/` | Next.js dashboard |
| `docs/` | Architecture docs, UART protocol, roadmap |

---

## Git / GitHub

- Repo: `HankJediAssistant` GitHub account (remote `hank`), plus `analogjedi` fork (remote `origin`)
- Current working branch: `external-phy-bus`
- Legacy merged branch: `codex/full-controller`
- All major features developed via Claude Code PRs

---

## Lessons Learned

- **Metastability is real on breadboards** — always use 2-stage synchronizers for external async inputs
- **4 MHz is the practical limit** on a breadboard with standard 2.2kΩ pullups — don't push it
- **SETDASA vs ENTDAA** — static assignment is fine for known-target demos; real sensors need ENTDAA
- The internal 12.5 MHz bus works without synchronizers because signals are clean FPGA wires — don't assume the same for external
- **Simulation rate has to match the synthesis sync penalty** — after the 2-stage target synchronizers landed, `tb_i3c_dual_target_lab_controller.v` stopped passing at 12.5 MHz SDR in iverilog (sync latency eats too much of a 40 ns half-period). Lowered the TB to 4 MHz to match hardware; that's the rate the simulation should stay at unless the sync stages are removed.
