## Digilent CMOD S7 (XC7S25-1CSGA225) — I3C External Bus Demo
## Pin assignments from Cmod-S7-25-Master.xdc (Digilent)

## 12 MHz System Clock (M9, MRCC-capable)
set_property -dict { PACKAGE_PIN M9  IOSTANDARD LVCMOS33 } [get_ports clk_12mhz]
create_clock -period 83.333 -name sys_clk [get_ports clk_12mhz]

## Active-high reset button (BTN0)
set_property -dict { PACKAGE_PIN D2  IOSTANDARD LVCMOS33 } [get_ports btn_reset]

## Discrete LEDs (active-high)
set_property -dict { PACKAGE_PIN E2  IOSTANDARD LVCMOS33 } [get_ports {led_sample_valid[0]}]
set_property -dict { PACKAGE_PIN K1  IOSTANDARD LVCMOS33 } [get_ports {led_sample_valid[1]}]
set_property -dict { PACKAGE_PIN J1  IOSTANDARD LVCMOS33 } [get_ports {led_sample_valid[2]}]
set_property -dict { PACKAGE_PIN E1  IOSTANDARD LVCMOS33 } [get_ports {led_sample_valid[3]}]

## RGB LED
set_property -dict { PACKAGE_PIN F1  IOSTANDARD LVCMOS33 } [get_ports led_sv4]
set_property -dict { PACKAGE_PIN D3  IOSTANDARD LVCMOS33 } [get_ports led_boot_done]
set_property -dict { PACKAGE_PIN F2  IOSTANDARD LVCMOS33 } [get_ports led_error]

## UART (FT2232H USB-UART bridge)
set_property -dict { PACKAGE_PIN L12 IOSTANDARD LVCMOS33 } [get_ports uart_txd]
set_property -dict { PACKAGE_PIN K15 IOSTANDARD LVCMOS33 } [get_ports uart_rxd]

## ----------------------------------------------------------------
## External I3C Bus Pins
## ----------------------------------------------------------------
## Uses DIP header GPIO pins on the Cmod S7 inner row.
## Connect all SDA pins together externally with a 2.2k pull-up to 3.3V.
## Connect all SCL pins together externally with a 2.2k pull-up to 3.3V.
##
##   DIP Pin 1  (L1)  → Controller SDA
##   DIP Pin 2  (M4)  → Controller SCL
##   DIP Pin 3  (M3)  → Target 0 SDA
##   DIP Pin 4  (N2)  → Target 0 SCL
##   DIP Pin 5  (M2)  → Target 1 SDA
##   DIP Pin 6  (P3)  → Target 1 SCL

## Controller I3C
set_property -dict { PACKAGE_PIN L1  IOSTANDARD LVCMOS33  PULLTYPE NONE } [get_ports ctrl_sda_pin]
set_property -dict { PACKAGE_PIN M4  IOSTANDARD LVCMOS33  PULLTYPE NONE } [get_ports ctrl_scl_pin]

## Target 0 I3C
set_property -dict { PACKAGE_PIN M3  IOSTANDARD LVCMOS33  PULLTYPE NONE } [get_ports tgt0_sda_pin]
set_property -dict { PACKAGE_PIN N2  IOSTANDARD LVCMOS33  PULLTYPE NONE } [get_ports tgt0_scl_pin]

## Target 1 I3C
set_property -dict { PACKAGE_PIN M2  IOSTANDARD LVCMOS33  PULLTYPE NONE } [get_ports tgt1_sda_pin]
set_property -dict { PACKAGE_PIN P3  IOSTANDARD LVCMOS33  PULLTYPE NONE } [get_ports tgt1_scl_pin]

## nack_seen debug output — DIP pin 7 (J1-7, package pin N3)
## Goes HIGH the instant the controller detects a NACK on any T-bit
set_property -dict { PACKAGE_PIN N3  IOSTANDARD LVCMOS33 } [get_ports dbg_nack_seen]
set_false_path -to [get_ports dbg_nack_seen]

## Debug: tgt0_sda_oe — DIP pin 8 (J1-8, package pin P1) — push-pull output
## Probe with scope: HIGH = Target 0 is asserting its SDA drive-enable (ACK/data).
## No pull-up needed — standard push-pull LVCMOS33 output.
set_property -dict { PACKAGE_PIN P1  IOSTANDARD LVCMOS33 } [get_ports dbg_tgt0_sda_oe]
set_false_path -to [get_ports dbg_tgt0_sda_oe]

## Debug: tgt0_sda_o — package pin H2 — push-pull output
## Paired with dbg_tgt0_sda_oe on a scope: when sda_oe=HIGH and sda_o=HIGH,
## the target is actively driving the bus HIGH push-pull (real I3C SDR).
## When sda_oe=HIGH and sda_o=LOW, target is pulling the bus LOW (ACK or data '0').
## Change the PACKAGE_PIN if H2 conflicts with anything on your bench.
set_property -dict { PACKAGE_PIN H2  IOSTANDARD LVCMOS33 } [get_ports dbg_tgt0_sda_o]
set_false_path -to [get_ports dbg_tgt0_sda_o]

## ----------------------------------------------------------------
## I3C timing — false-path the async pad read-back
## ----------------------------------------------------------------
## The SDA/SCL pads are sampled synchronously by the bus engine's
## registered logic, so pad-to-register paths are not true clocked paths.
set_false_path -from [get_ports {ctrl_sda_pin ctrl_scl_pin}]
set_false_path -from [get_ports {tgt0_sda_pin tgt0_scl_pin}]
set_false_path -from [get_ports {tgt1_sda_pin}]
set_false_path -from [get_ports {tgt1_scl_pin}]

## Configuration
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
