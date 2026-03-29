`timescale 1ns/1ps

// I3C Physical Layer (PHY) wrapper for Xilinx 7-series IOBUFs.
//
// Provides bidirectional SDA and SCL with open-drain and push-pull modes.
// Each signal uses an IOBUF primitive:
//   T = 1 → high-Z (pad floats, pull-up brings it high)
//   T = 0 → drive pad with value on I
//   O     → actual pad state (always readable)
//
// Open-drain mode (DAA, I2C compat):
//   Drive low:    T=0, I=0
//   Release high: T=1 (external pull-up)
//
// Push-pull mode (I3C SDR high-speed):
//   Drive low:    T=0, I=0
//   Drive high:   T=0, I=1

module i3c_phy (
    // External FPGA pins (directly to package pad)
    inout  wire sda_pin,
    inout  wire scl_pin,

    // SDA pad-level interface
    input  wire sda_t,          // 1=high-Z, 0=drive
    input  wire sda_i,          // value driven onto pad when T=0
    output wire sda_o,          // actual pad state (read-back)

    // SCL pad-level interface
    input  wire scl_t,          // 1=high-Z, 0=drive
    input  wire scl_i,          // value driven onto pad when T=0
    output wire scl_o           // actual pad state (read-back)
);

    IOBUF u_sda_iobuf (
        .IO (sda_pin),
        .T  (sda_t),
        .I  (sda_i),
        .O  (sda_o)
    );

    IOBUF u_scl_iobuf (
        .IO (scl_pin),
        .T  (scl_t),
        .I  (scl_i),
        .O  (scl_o)
    );

endmodule
