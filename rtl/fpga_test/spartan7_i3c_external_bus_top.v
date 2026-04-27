`timescale 1ns/1ps

// External-bus variant of the dual-target I3C lab demo.
//
// Instead of resolving SDA/SCL with internal wired-AND logic, each device
// (controller + 2 targets) gets its own pair of physical FPGA pins via
// IOBUF primitives (i3c_phy).  The six pins are meant to be connected
// externally on a breadboard with pull-up resistors, forming a real
// open-drain I3C bus.
//
// Pin mapping (active-low open-drain, directly on pad):
//   Controller:  ctrl_sda_pin, ctrl_scl_pin
//   Target 0:    tgt0_sda_pin, tgt0_scl_pin
//   Target 1:    tgt1_sda_pin, tgt1_scl_pin

module spartan7_i3c_external_bus_top #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer I3C_SDR_HZ  =  4_000_000,  // External bus rate — see build Tcl overrides for 8/12.5 MHz
    // Phase-3 feature flag: 1 enables ENTDAA dynamic address assignment in
    // the boot FSM; 0 preserves the legacy SETDASA-only behavior.
    parameter integer USE_ENTDAA = 0,
    // Phase-3-B' feature flag: 1 enables target-side push-pull SDA during
    // SDR read data phases (real I3C SDR).  0 preserves the legacy
    // open-drain-only behavior (I2C FM+ with dynamic address).
    parameter integer USE_PUSH_PULL = 1
) (
    input  wire       clk_12mhz,
    input  wire       btn_reset,

    // LEDs
    output wire [3:0] led_sample_valid,
    output wire       led_sv4,
    output wire       led_boot_done,
    output wire       led_error,

    // UART
    output wire       uart_txd,
    input  wire       uart_rxd,

    // External I3C bus pins (active-low open-drain via IOBUF)
    inout  wire       ctrl_sda_pin,
    inout  wire       ctrl_scl_pin,
    inout  wire       tgt0_sda_pin,
    inout  wire       tgt0_scl_pin,
    inout  wire       tgt1_sda_pin,
    inout  wire       tgt1_scl_pin,

    // 1 MHz open-drain test output (DIP pin 7 / N3)
    output wire       dbg_nack_seen,

    // Debug: tgt0_sda_oe visible on DIP pin 8 (P1) — push-pull output.
    // HIGH whenever Target 0 is driving its SDA line (ACK, data, etc.)
    // Probe this to confirm the target is responding to bus transactions.
    output wire       dbg_tgt0_sda_oe,

    // Debug: tgt0_sda_o — the push-pull data bit Target 0 is currently
    // asserting.  Paired with dbg_tgt0_sda_oe on a scope, this proves the
    // target is actively driving SDA high (vs. relying on the pull-up RC).
    output wire       dbg_tgt0_sda_o
);

    // ----------------------------------------------------------------
    // Clock generation — 12 MHz → 100 MHz via MMCM
    // ----------------------------------------------------------------
    wire clk_100m_unbuf;
    wire clk_100m;
    wire mmcm_locked;
    wire clk_fb;

    MMCME2_BASE #(
        .CLKIN1_PERIOD    (83.333),
        .DIVCLK_DIVIDE    (1),
        .CLKFBOUT_MULT_F  (62.500),
        .CLKOUT0_DIVIDE_F (7.500),
        .STARTUP_WAIT     ("FALSE")
    ) u_mmcm (
        .CLKIN1   (clk_12mhz),
        .RST      (1'b0),
        .PWRDWN   (1'b0),
        .CLKFBIN  (clk_fb),
        .CLKFBOUT (clk_fb),
        .CLKOUT0  (clk_100m_unbuf),
        .CLKOUT0B (),
        .CLKOUT1  (),
        .CLKOUT1B (),
        .CLKOUT2  (),
        .CLKOUT2B (),
        .CLKOUT3  (),
        .CLKOUT3B (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .LOCKED   (mmcm_locked)
    );

    BUFG u_bufg_clk100 (
        .I (clk_100m_unbuf),
        .O (clk_100m)
    );

    wire sys_rst_n = mmcm_locked & ~btn_reset;

    // ----------------------------------------------------------------
    // UART
    // ----------------------------------------------------------------
    wire [7:0] uart_rx_data;
    wire       uart_rx_valid;
    wire [7:0] uart_tx_data;
    wire       uart_tx_valid;
    wire       uart_tx_ready;
    wire       soft_start;

    uart_rx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (115200)
    ) u_uart_rx (
        .clk     (clk_100m),
        .rst_n   (sys_rst_n),
        .rx_pin  (uart_rxd),
        .rx_data (uart_rx_data),
        .rx_valid(uart_rx_valid)
    );

    uart_tx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (115200)
    ) u_uart_tx (
        .clk     (clk_100m),
        .rst_n   (sys_rst_n),
        .tx_data (uart_tx_data),
        .tx_valid(uart_tx_valid),
        .tx_ready(uart_tx_ready),
        .tx_pin  (uart_txd)
    );

    // ----------------------------------------------------------------
    // Demo start gating — with a 1 ms bus-idle settle delay
    //
    // After soft_start, hold demo_rst_n low for ~100 000 system clock
    // cycles (1 ms at 100 MHz) before releasing the controller and
    // targets.  This ensures the IOBUF outputs have settled and the
    // target synchronisers have a few quiet cycles before the first
    // SETDASA transaction hits the bus.
    // ----------------------------------------------------------------
    localparam integer BOOT_SETTLE_CYCLES = 100_000; // 1 ms

    reg demo_started;
    reg [$clog2(BOOT_SETTLE_CYCLES)-1:0] settle_cnt;
    reg demo_settled;

    always @(posedge clk_100m or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            demo_started  <= 1'b0;
            settle_cnt    <= 'd0;
            demo_settled  <= 1'b0;
        end else begin
            if (soft_start)
                demo_started <= 1'b1;
            if (demo_started && !demo_settled) begin
                if (settle_cnt == BOOT_SETTLE_CYCLES - 1)
                    demo_settled <= 1'b1;
                else
                    settle_cnt <= settle_cnt + 1'b1;
            end
        end
    end

    wire demo_rst_n = sys_rst_n & demo_settled;

    // ----------------------------------------------------------------
    // Controller signals
    // ----------------------------------------------------------------
    wire ctrl_scl_o;
    wire ctrl_scl_oe;
    wire ctrl_sda_o;
    wire ctrl_sda_oe;
    wire ctrl_sda_i;  // bus state read-back from PHY

    // ----------------------------------------------------------------
    // Target signals
    // ----------------------------------------------------------------
    wire tgt0_sda_oe;
    wire tgt0_sda_o;          // push-pull data bit driven onto the bus
    wire tgt0_scl_sense;
    wire tgt0_sda_sense;

    wire tgt1_sda_oe;
    wire tgt1_sda_o;
    wire tgt1_scl_sense;
    wire tgt1_sda_sense;

    // ----------------------------------------------------------------
    // PHY instances — one per device
    // ----------------------------------------------------------------

    // Controller PHY: drives both SCL and SDA
    i3c_phy u_phy_ctrl (
        .sda_pin (ctrl_sda_pin),
        .scl_pin (ctrl_scl_pin),
        .sda_t   (~ctrl_sda_oe),   // oe=1 → T=0 → drive
        .sda_i   (ctrl_sda_o),
        .sda_o   (ctrl_sda_i),     // read-back for ACK/data sensing
        .scl_t   (~ctrl_scl_oe),
        .scl_i   (ctrl_scl_o),
        .scl_o   ()                // controller doesn't read SCL back
    );

    // Target 0 PHY: reads SCL, drives SDA push-pull (real I3C SDR) when
    // USE_PUSH_PULL=1.  Target asserts sda_o with the actual data bit and
    // sda_oe for the drive window; ACK/ENTDAA phases still pull-low-only.
    i3c_phy u_phy_tgt0 (
        .sda_pin (tgt0_sda_pin),
        .scl_pin (tgt0_scl_pin),
        .sda_t   (~tgt0_sda_oe),   // T=0 → drive; T=1 → high-Z (T-bit, idle)
        .sda_i   (tgt0_sda_o),     // real push-pull data bit
        .sda_o   (tgt0_sda_sense),
        .scl_t   (1'b1),           // target never drives SCL → always high-Z
        .scl_i   (1'b0),
        .scl_o   (tgt0_scl_sense)
    );

    // Target 1 PHY: same as Target 0
    i3c_phy u_phy_tgt1 (
        .sda_pin (tgt1_sda_pin),
        .scl_pin (tgt1_scl_pin),
        .sda_t   (~tgt1_sda_oe),
        .sda_i   (tgt1_sda_o),
        .sda_o   (tgt1_sda_sense),
        .scl_t   (1'b1),
        .scl_i   (1'b0),
        .scl_o   (tgt1_scl_sense)
    );

    // ----------------------------------------------------------------
    // Status / reporting signals
    // ----------------------------------------------------------------
    wire       boot_done;
    wire       boot_error;
    wire       capture_error;
    wire       recovery_active;
    wire [1:0] verified_bitmap;
    wire [1:0] sample_valid_bitmap;
    wire [1:0] target_led_state;
    wire [63:0] signature_flat;
    wire [159:0] sample_payloads_flat;
    wire [31:0] sample_capture_count_flat;
    wire [31:0] status_word_flat;
    wire [6:0] last_service_addr;
    wire [6:0] last_recovery_addr;

    // ----------------------------------------------------------------
    // Host command interface
    // ----------------------------------------------------------------
    wire       ctrl_cmd_valid;
    wire       ctrl_cmd_ready;
    wire       ctrl_cmd_read;
    wire       ctrl_cmd_target;
    wire [7:0] ctrl_cmd_reg_addr;
    wire [7:0] ctrl_cmd_write_value;
    wire [7:0] ctrl_cmd_read_len;
    wire       ctrl_rsp_valid;
    wire       ctrl_rsp_error;
    wire [7:0] ctrl_rsp_len;
    wire [127:0] ctrl_rsp_data;
    wire       ctrl_ccc_valid;
    wire       ctrl_ccc_ready;
    wire       ctrl_ccc_direct;
    wire       ctrl_ccc_target;
    wire [7:0] ctrl_ccc_code;
    wire [7:0] ctrl_ccc_arg;
    wire       ctrl_ccc_rsp_valid;
    wire       ctrl_ccc_rsp_error;
    wire [7:0] ctrl_ccc_rsp_len;
    wire [47:0] ctrl_ccc_rsp_data;

    wire tgt0_indicator;
    wire tgt1_indicator;

    // ----------------------------------------------------------------
    // Debug outputs
    // ----------------------------------------------------------------
    assign dbg_tgt0_sda_oe = tgt0_sda_oe;
    assign dbg_tgt0_sda_o  = tgt0_sda_o;

    // ----------------------------------------------------------------
    // LED assignments
    // ----------------------------------------------------------------
    assign led_sample_valid[0] = tgt0_indicator;
    assign led_sample_valid[1] = tgt1_indicator;
    assign led_sample_valid[2] = sample_valid_bitmap[0];
    assign led_sample_valid[3] = sample_valid_bitmap[1];
    assign led_sv4             = recovery_active;
    assign led_boot_done       = boot_done;
    assign led_error           = boot_error | capture_error;

    // ----------------------------------------------------------------
    // UART command handler
    // ----------------------------------------------------------------
    uart_dual_target_lab_cmd_handler #(
        .MAX_READ_BYTES(16),
        .PAYLOAD_BYTES (10)
    ) u_cmd_handler (
        .clk              (clk_100m),
        .rst_n            (sys_rst_n),
        .rx_data          (uart_rx_data),
        .rx_valid         (uart_rx_valid),
        .tx_data          (uart_tx_data),
        .tx_valid         (uart_tx_valid),
        .tx_ready         (uart_tx_ready),
        .soft_start       (soft_start),
        .boot_done        (boot_done),
        .boot_error       (boot_error),
        .capture_error    (capture_error),
        .recovery_active  (recovery_active),
        .verified_bitmap  (verified_bitmap),
        .sample_valid_bitmap(sample_valid_bitmap),
        .target_led_state (target_led_state),
        .signature_flat   (signature_flat),
        .sample_payloads_flat(sample_payloads_flat),
        .ctrl_cmd_valid   (ctrl_cmd_valid),
        .ctrl_cmd_ready   (ctrl_cmd_ready),
        .ctrl_cmd_read    (ctrl_cmd_read),
        .ctrl_cmd_target  (ctrl_cmd_target),
        .ctrl_cmd_reg_addr(ctrl_cmd_reg_addr),
        .ctrl_cmd_write_value(ctrl_cmd_write_value),
        .ctrl_cmd_read_len(ctrl_cmd_read_len),
        .ctrl_rsp_valid   (ctrl_rsp_valid),
        .ctrl_rsp_error   (ctrl_rsp_error),
        .ctrl_rsp_len     (ctrl_rsp_len),
        .ctrl_rsp_data    (ctrl_rsp_data),
        .ccc_cmd_valid    (ctrl_ccc_valid),
        .ccc_cmd_ready    (ctrl_ccc_ready),
        .ccc_cmd_direct   (ctrl_ccc_direct),
        .ccc_cmd_target   (ctrl_ccc_target),
        .ccc_cmd_code     (ctrl_ccc_code),
        .ccc_cmd_arg      (ctrl_ccc_arg),
        .ccc_rsp_valid    (ctrl_ccc_rsp_valid),
        .ccc_rsp_error    (ctrl_ccc_rsp_error),
        .ccc_rsp_len      (ctrl_ccc_rsp_len),
        .ccc_rsp_data     (ctrl_ccc_rsp_data)
    );

    // ----------------------------------------------------------------
    // Controller — drives SCL/SDA via PHY, reads SDA back from PHY
    // ----------------------------------------------------------------
    i3c_dual_target_lab_controller #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .I3C_SDR_HZ  (I3C_SDR_HZ),
        .USE_ENTDAA  (USE_ENTDAA)
    ) u_controller (
        .clk                   (clk_100m),
        .rst_n                 (demo_rst_n),
        .scl_o                 (ctrl_scl_o),
        .scl_oe                (ctrl_scl_oe),
        .sda_o                 (ctrl_sda_o),
        .sda_oe                (ctrl_sda_oe),
        .sda_i                 (ctrl_sda_i),
        .host_cmd_valid        (ctrl_cmd_valid),
        .host_cmd_ready        (ctrl_cmd_ready),
        .host_cmd_read         (ctrl_cmd_read),
        .host_cmd_target       (ctrl_cmd_target),
        .host_cmd_reg_addr     (ctrl_cmd_reg_addr),
        .host_cmd_write_value  (ctrl_cmd_write_value),
        .host_cmd_read_len     (ctrl_cmd_read_len),
        .host_rsp_valid        (ctrl_rsp_valid),
        .host_rsp_error        (ctrl_rsp_error),
        .host_rsp_len          (ctrl_rsp_len),
        .host_rsp_data         (ctrl_rsp_data),
        .host_ccc_valid        (ctrl_ccc_valid),
        .host_ccc_ready        (ctrl_ccc_ready),
        .host_ccc_direct       (ctrl_ccc_direct),
        .host_ccc_target       (ctrl_ccc_target),
        .host_ccc_code         (ctrl_ccc_code),
        .host_ccc_arg          (ctrl_ccc_arg),
        .host_ccc_rsp_valid    (ctrl_ccc_rsp_valid),
        .host_ccc_rsp_error    (ctrl_ccc_rsp_error),
        .host_ccc_rsp_len      (ctrl_ccc_rsp_len),
        .host_ccc_rsp_data     (ctrl_ccc_rsp_data),
        .boot_done             (boot_done),
        .boot_error            (boot_error),
        .dbg_nack_seen         (dbg_nack_seen),
        .capture_error         (capture_error),
        .recovery_active       (recovery_active),
        .verified_bitmap       (verified_bitmap),
        .sample_valid_bitmap   (sample_valid_bitmap),
        .target_led_state      (target_led_state),
        .signature_flat        (signature_flat),
        .sample_payloads_flat  (sample_payloads_flat),
        .sample_capture_count_flat(sample_capture_count_flat),
        .status_word_flat      (status_word_flat),
        .last_service_addr     (last_service_addr),
        .last_recovery_addr    (last_recovery_addr)
    );

    // ----------------------------------------------------------------
    // Target 0 — reads SCL/SDA from PHY, drives SDA low via PHY
    // ----------------------------------------------------------------
    i3c_sensor_gpio_target_demo #(
        .CLK_FREQ_HZ     (CLK_FREQ_HZ),
        .STATIC_ADDR     (7'h30),
        .TARGET_INDEX    (0),
        .PROVISIONAL_ID  (48'h4100_0000_0011),
        .TARGET_SIGNATURE(32'h534E_0100),
        .USE_PUSH_PULL   (USE_PUSH_PULL)
    ) u_tgt0 (
        .clk              (clk_100m),
        .rst_n            (demo_rst_n),
        .scl              (tgt0_scl_sense),
        .sda              (tgt0_sda_sense),
        .sda_oe           (tgt0_sda_oe),
        .sda_o            (tgt0_sda_o),
        .indicator_out    (tgt0_indicator),
        .sample_payload   (),
        .signature_word   (),
        .control_reg      (),
        .register_pointer (),
        .frame_counter    (),
        .active_addr      (),
        .dynamic_addr_valid(),
        .read_valid       ()
    );

    // ----------------------------------------------------------------
    // Target 1 — reads SCL/SDA from PHY, drives SDA low via PHY
    // ----------------------------------------------------------------
    i3c_sensor_gpio_target_demo #(
        .CLK_FREQ_HZ     (CLK_FREQ_HZ),
        .STATIC_ADDR     (7'h31),
        .TARGET_INDEX    (1),
        .PROVISIONAL_ID  (48'h4100_0000_0012),
        .TARGET_SIGNATURE(32'h534E_0101),
        .USE_PUSH_PULL   (USE_PUSH_PULL)
    ) u_tgt1 (
        .clk              (clk_100m),
        .rst_n            (demo_rst_n),
        .scl              (tgt1_scl_sense),
        .sda              (tgt1_sda_sense),
        .sda_oe           (tgt1_sda_oe),
        .sda_o            (tgt1_sda_o),
        .indicator_out    (tgt1_indicator),
        .sample_payload   (),
        .signature_word   (),
        .control_reg      (),
        .register_pointer (),
        .frame_counter    (),
        .active_addr      (),
        .dynamic_addr_valid(),
        .read_valid       ()
    );

    // dbg_nack_seen is driven directly from the controller output (push-pull).
    // DIP pin 7 (N3): goes HIGH the instant the controller sees a NACK on any T-bit.

endmodule
