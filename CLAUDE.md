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

## Current State (as of Mar 31, 2026)

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

## 🎯 Phase 3 — TDK InfantSense IMU Integration (NEXT)

The external bus is ready. The next milestone is connecting a **real I3C sensor** — specifically the **TDK InfantSense IMU** — to the physical bus pins.

### What needs to happen:
1. Confirm TDK part number → determine I3C static/dynamic address, supported CCCs, payload format
2. Update controller to support `ENTDAA` (Dynamic Address Assignment) for unknown targets
3. Replace synthetic payload with real IMU data parser (accel/gyro)
4. Update backend + dashboard to display real sensor data

### Current DAA approach:
The internal demo uses `SETDASA` (static address assignment) — known targets only. Real external sensors need `ENTDAA` for proper discovery.

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
| `rtl/fpga_test/spartan7_i3c_external_bus_top.v` | External PHY bus top (current) |
| `rtl/fpga_test/spartan7_i3c_dual_target_lab_top.v` | Internal dual-target top |
| `rtl/fpga_test/i3c_dual_target_lab_controller.v` | Lab controller |
| `rtl/fpga_test/i3c_sensor_gpio_target_demo.v` | Target module |
| `rtl/uart_dual_target_lab_cmd_handler.v` | UART bridge |
| `rtl/i3c_target_transport.v` | Target transport (has 2-stage sync) |
| `rtl/i3c_target_ccc.v` | Target CCC handler (has 2-stage sync) |
| `rtl/i3c_ctrl_direct_ccc.v` | Controller CCC (has ST_PRE_ACK fix) |
| `constraints/spartan7_i3c_external_bus.xdc` | External bus pin constraints |
| `software/dual_target_lab_backend/app.py` | FastAPI backend |
| `software/dual_target_lab_frontend/` | Next.js dashboard |
| `docs/` | Architecture docs, UART protocol, roadmap |

---

## Git / GitHub

- Repo: `HankJediAssistant` GitHub account
- Main working branch: `codex/full-controller`
- All major features developed via Claude Code PRs

---

## Lessons Learned

- **Metastability is real on breadboards** — always use 2-stage synchronizers for external async inputs
- **4 MHz is the practical limit** on a breadboard with standard 2.2kΩ pullups — don't push it
- **SETDASA vs ENTDAA** — static assignment is fine for known-target demos; real sensors need ENTDAA
- The internal 12.5 MHz bus works without synchronizers because signals are clean FPGA wires — don't assume the same for external
