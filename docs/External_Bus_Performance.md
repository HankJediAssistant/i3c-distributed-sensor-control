# External I3C Bus — Performance and Limits

This doc captures what works, what doesn't, and *why*, for the
external-PHY-bus variant of the dual-target I3C demo on the Cmod S7
(Spartan-7 XC7S25). It exists so future work doesn't have to
re-derive the rate ceiling from scratch.

Top module: [`rtl/fpga_test/spartan7_i3c_external_bus_top.v`](../rtl/fpga_test/spartan7_i3c_external_bus_top.v)
Constraints: [`constraints/spartan7_i3c_external_bus.xdc`](../constraints/spartan7_i3c_external_bus.xdc)
Build: `vivado -mode batch -source scripts/build_external_bus.tcl`
Build with rate override: `I3C_SDR_HZ=6000000 vivado -mode batch -source scripts/build_external_bus.tcl`

---

## Headline result

On a breadboard with **1 kΩ pullups**, **140 MHz sysclk**, and **target-side push-pull SDA enabled**:

- **6.36 MHz I3C SDR** — verified end-to-end (boot, both targets, register reads, register writes, sample polling, dashboard round-trip).
- **7.0 MHz I3C SDR** — fails to boot.
- That's a **+54%** bus-throughput improvement over the prior 4.12 MHz baseline on the same physical setup.

---

## Hardware-validated rate matrix

All tests on the same Cmod S7 + 1 kΩ breadboard pullups, with the
push-pull RTL from Phase 3-B'. *Actual* I3C SDR rate after integer
divider truncation `HALF_PERIOD_CLKS = sysclk / (2 × I3C_SDR_HZ)`:

| sysclk | requested I3C | actual I3C | half-period | result |
|---|---|---|---|---|
| 100 MHz | 4 MHz | 4.17 MHz | 120 ns | ✓ works (prior baseline) |
| 100 MHz | 6 MHz | 6.25 MHz | 80 ns | ✗ boot fails |
| 100 MHz | 8 MHz | 8.33 MHz | 60 ns | ✗ boot fails |
| **140 MHz** | **4 MHz** | **4.12 MHz** | **121 ns** | **✓ works** |
| **140 MHz** | **6 MHz** | **6.36 MHz** | **157 ns** | **✓ works ← current peak** |
| 140 MHz | 7 MHz | 7.00 MHz | 143 ns | ✗ boot fails |
| 140 MHz | 8 MHz | 8.75 MHz | 114 ns | ✗ boot fails |
| 160 MHz | 4 MHz | 4.00 MHz | 125 ns | ✗ boot fails despite STA closing — see "PLL stability" below |

The "actual" rate is always slightly different from the requested rate
because `HALF_PERIOD_CLKS` is a rounded integer count of sysclks per
half-period.

---

## Why 140 MHz sysclk?

The targets use a **2-stage SCL synchronizer** (added in commit
`4c70f28` on `external-phy-bus`) to handle metastability on the
asynchronous bus pad. That synchronizer eats real time from each I3C
half-period before the target can react to a clock edge:

```
sync_latency = 2 × sysclk_period   (two FF stages)
edge_detect  = 1 × sysclk_period   (the rising/falling edge XOR)
total        ≈ 3 × sysclk_period   ← per I3C half-period
```

| sysclk | sync penalty | usable window @ 6 MHz I3C (83 ns half-period) |
|---|---|---|
| 100 MHz | ~30 ns | ~50 ns ← below threshold, fails |
| 140 MHz | ~21 ns | ~59 ns ← above threshold, works |
| 160 MHz | ~19 ns | ~61 ns ← would work, but PLL marginal |

Empirically, the target needs ~55 ns of stable usable window per
half-period to boot reliably. The jump from 100 MHz to 140 MHz buys
~9 ns back, which is the difference between 6 MHz failing and working.

### Why not just go higher?

Two reasons:

1. **MMCM PLL stability.** Spartan-7 -1 grade specifies VCO 600-1200 MHz
   and `CLKFBOUT_MULT_F` ≤ 64.000, so on a 12 MHz reference the cleanest
   high-VCO points fall around 700-768 MHz. We tried 160 MHz output
   (VCO 640 MHz), and despite static-timing analysis closing with
   positive setup *and* hold slack, the design failed to boot on the
   real silicon. We couldn't confirm whether the issue was VCO jitter,
   an unmodeled hold path, or something else — but the empirical result
   is clear, so we stayed at 140 MHz (VCO 702 MHz).

2. **Diminishing returns.** Even at 200 MHz sysclk (~16 ns sync penalty),
   the next granular I3C rate that's faster than 6.36 MHz is 7 MHz at
   140 MHz sysclk or ~7.7 MHz at 200 MHz, which still bumps into the
   pullup RC ceiling described next.

---

## Timing closure at 140 MHz

The longest combinational path at 100 MHz was 9.025 ns through 10 logic
levels — the `read_reg_byte()` case-mux inside
[`rtl/fpga_test/i3c_sensor_gpio_target_demo.v`](../rtl/fpga_test/i3c_sensor_gpio_target_demo.v),
feeding the transport's read-data slice and ending at `sda_o_reg`.

At 100 MHz (10 ns period) it landed with 0.683 ns slack. At 140 MHz
(7.14 ns period) it would fail by ~2 ns.

Fix: register `read_data_bus` once per sysclk in the demo wrapper,
splitting the chain into a ~7 ns piece (case-mux → register) and a ~2 ns
piece (transport slice → `sda_o_reg`). The 1-cycle latency is invisible
because the transport only samples on `scl_falling`, which is once per
~24 sysclks at 140/6 — far longer than one cycle.

After the pipeline change, 140 MHz closes with ~0.8 ns of WNS.

---

## Push-pull SDA on the target side

Phase 3-B' (committed in `3f7f4e7` and `9586f1a`) replaced the previous
target-side OD-only SDA path with a real push-pull driver during SDR
read data phases:

- Old: target IOBUFs had `.sda_i(1'b0)` hardwired, so they could only
  pull SDA low or release. Logic-HIGH bits relied on the pullup
  RC-charging the line — i.e. I2C Fast-mode-Plus with dynamic
  addressing on top.
- New: target IOBUFs are wired `.sda_i(tgtN_sda_o)`, with a separate
  `sda_oe` enable. ENTDAA arbitration response stays open-drain (it
  needs the wire-AND), but every other read-data phase drives both
  edges actively.

Three subtle bugs were caught and fixed by the new contention-aware
testbench [`tb/tb_i3c_external_bus_pushpull.v`](../tb/tb_i3c_external_bus_pushpull.v):

1. **Controller T-bit handoff** — the controller pushed HIGH for the
   T-bit while the target's 2-stage sync was still propagating the last
   data bit's SCL falling edge, leaving the target driving LOW for ~20
   ns. Fixed by adding `ST_PRE_T_BIT` (a half-period release gap) in
   `i3c_ctrl_direct_ccc.v` and `i3c_bus_engine.v`.
2. **ENTDAA T-bit was push-pull** — but ENTDAA's T-bit is target-driven
   (continue/halt arbitration signal), so the controller was fighting
   the target. Fixed by forcing OD on `ST_MASTER_ACK_{L,H}` in
   `i3c_ctrl_entdaa.v` regardless of `PUSH_PULL_DATA`.
3. **Stale `sda_o` leakage** — the target_top OR'd `transport_sda_o` and
   `ccc_sda_o`, but neither submodule cleared its data-bit output when
   inactive, so a stale PP bit could smuggle through during a subsequent
   OD-ACK window and flip it from LOW (correct) to HIGH (broken). Fixed
   by gating each submodule's `sda_o` with its own `sda_pp_en`.

---

## Electrical limits — what's actually capping us

At 6.36 MHz the design works comfortably; at 7.0 MHz it consistently
fails to boot. That's a real ceiling on this physical setup, with
two contributors:

### 1. Synchronizer latency (digital, ~21 ns)

Already covered above. Going higher than 140 MHz sysclk on this part
ran into PLL stability problems we didn't fully diagnose.

### 2. Pullup RC time (analog, ~30-50 ns)

With ~30-50 pF of bus capacitance (3 IOBUFs in parallel + breadboard
wire + scope probe load) and a 1 kΩ pullup, the OD-LOW → HIGH
recovery RC is ~30-50 ns. That recovery happens during every
open-drain ACK / address bit. At a 71 ns half-period (7.0 MHz), there
isn't enough stable HIGH window left for the controller to sample
correctly.

Push-pull data phases dodge this entirely (the target actively drives
HIGH, no pullup needed), but the address byte and ACK windows are
*always* open-drain by spec. Those are what set the ceiling.

---

## What would unlock higher rates

The bottleneck above 6.36 MHz on this board is the OD ACK/address
recovery RC. To push further:

| Lever | Estimated gain | Cost |
|---|---|---|
| Drop pullup R from 1 kΩ → 470 Ω | ~10 ns/half-period | Resistor swap; ~7 mA per bus when LOW (was ~3.3 mA at 1 kΩ) — well within FPGA pad limits |
| Drop pullup R further to 220 Ω | ~5 ns more | ~15 mA per bus — pad current still OK but worth verifying |
| Reduce bus C: shorter wires, no probe loading, PCB instead of breadboard | ~10-30 ns | Hardware-side rework |
| Single-stage SCL sync at the target | ~7 ns | Higher metastability MTBF risk; would want explicit MTBF analysis |
| Higher sysclk (200 MHz) with VCO stability resolved | ~5 ns sync penalty | Need to investigate why 160 MHz failed despite STA passing; possibly use a different MMCM config or external/dedicated PLL |

The cleanest single-knob improvement is the pullup swap. On a real PCB
with controlled trace capacitance and 470 Ω pullups, 8-12 MHz I3C SDR
on this RTL is plausible; the 12.5 MHz that's the goal of the internal
wired-AND demo would still need the synchronizer rework or sysclk bump.

---

## How to reproduce on hardware

```bash
# 1. Source Vivado
source /opt/Xilinx/2025.2/Vivado/settings64.sh

# 2. Build at the desired I3C rate (default 4 MHz; override via env)
I3C_SDR_HZ=6000000 vivado -mode batch -source scripts/build_external_bus.tcl

# 3. Program the Cmod S7 (FPGA must be plugged in via USB)
vivado -mode batch -source scripts/program_external_bus.tcl

# 4. Wire breadboard:
#    SDA bus: L1 + M3 + M2 ─┬─ 1 kΩ ─ 3.3 V
#    SCL bus: M4 + N2 + P3 ─┴─ 1 kΩ ─ 3.3 V
#
#    (Note: the README pin table shows N1 for tgt1 SCL — the actual
#     XDC uses P3.  Trust constraints/spartan7_i3c_external_bus.xdc.)
#    (Note: the README pullup table shows 2.2 kΩ — that was the
#     original; this hardware run uses 1 kΩ pullups.)

# 5. Start the host stack
DUAL_TARGET_LAB_PORT=/dev/ttyUSB1 \
  uvicorn software.dual_target_lab_backend.app:app --port 8765 &

cd software/dual_target_lab_frontend && npm run dev   # http://localhost:3000

# 6. Trigger boot
curl -X POST http://localhost:8765/api/start

# 7. Verify
curl http://localhost:8765/api/status
# expect: boot_done=true, verified_bitmap=3, sample_valid_bitmap=3
```

Each rate change requires a rebuild (the divider is a synthesis-time
parameter, not a runtime register).

---

## Sim regressions covering this work

```bash
make sim-dual-target-lab-controller             # SETDASA path, OD targets (no-op for this work)
make sim-dual-target-lab-controller-entdaa      # ENTDAA path, OD targets
make sim-entdaa sim-entdaa-multi sim-entdaa-stress
make sim-external-bus-pushpull                  # 4 MHz I3C, push-pull on
make sim-external-bus-pushpull-8m               # 8 MHz I3C, push-pull on (sim-only — passes; HW differs)
make sim-external-bus-pushpull-entdaa           # ENTDAA + push-pull
```

`sim-external-bus-pushpull-12m5` (12.5 MHz) currently fails in
simulation due to the same 2-stage sync latency biting at the
sub-40 ns half-period — same root cause as the hardware ceiling at
1 kΩ pullups, just visible in iverilog without needing real silicon.
