`timescale 1ns/1ps

// Contention-aware bus model for validating target-side push-pull SDA
// (Phase 3-B').  Unlike the wired-AND bus used by the other dual-target
// TBs, this bench tracks every device's drive state independently:
//
//   per device:   {sda_oe, sda_o}  →  drv_lo = oe & ~o   (pulling low)
//                                     drv_hi = oe &  o   (pushing high)
//
// The bus fails closed: if any device drives LOW, SDA is LOW (matches the
// physical reality — open-drain pull-low beats push-pull high through the
// driver's RON).  But that event is ALSO flagged as contention and fails
// the test, because a correct controller/target pair should never have
// push-pull-high and pull-low overlapping — the T-bit handoff gaps exist
// precisely to prevent that.
//
// We also assert that at least one target drove SDA HIGH push-pull during
// the test.  If that never happens, the targets are still open-drain and
// the whole change hasn't landed.
//
// Override I3C_SDR_HZ on the iverilog command line:
//   -Ptb_i3c_external_bus_pushpull.I3C_SDR_HZ=8000000
//   -Ptb_i3c_external_bus_pushpull.I3C_SDR_HZ=12500000

module tb_i3c_external_bus_pushpull;

    parameter integer CLK_FREQ_HZ = 100_000_000;
    parameter integer I3C_SDR_HZ  =  4_000_000;
    parameter integer USE_ENTDAA  = 0;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // Device-level signals
    wire ctrl_scl_o, ctrl_scl_oe;
    wire ctrl_sda_o, ctrl_sda_oe;
    wire tgt0_sda_oe, tgt0_sda_o;
    wire tgt1_sda_oe, tgt1_sda_o;

    // Per-device drive decomposition
    wire ctrl_drv_lo = ctrl_sda_oe & ~ctrl_sda_o;
    wire ctrl_drv_hi = ctrl_sda_oe &  ctrl_sda_o;
    wire tgt0_drv_lo = tgt0_sda_oe & ~tgt0_sda_o;
    wire tgt0_drv_hi = tgt0_sda_oe &  tgt0_sda_o;
    wire tgt1_drv_lo = tgt1_sda_oe & ~tgt1_sda_o;
    wire tgt1_drv_hi = tgt1_sda_oe &  tgt1_sda_o;

    wire any_drv_lo = ctrl_drv_lo | tgt0_drv_lo | tgt1_drv_lo;
    wire any_drv_hi = ctrl_drv_hi | tgt0_drv_hi | tgt1_drv_hi;

    // Contention: one device pulling low while another pushes high.
    // Two-target wire-AND of matching lows (e.g. ENTDAA arbitration) is NOT
    // contention — that's just multiple OD pull-lows resolving to LOW.
    wire contention = any_drv_lo & any_drv_hi;

    // Resolved bus value — OD pull-low dominates, else HIGH (pullup or PP high).
    wire scl_bus = ~(ctrl_scl_oe & ~ctrl_scl_o);
    wire sda_bus = any_drv_lo ? 1'b0 : 1'b1;

    // Assertions
    reg contention_seen;
    reg tgt_drove_high_seen;
    reg [31:0] contention_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            contention_seen     <= 1'b0;
            tgt_drove_high_seen <= 1'b0;
            contention_count    <= 32'd0;
        end else begin
            if (contention) begin
                contention_seen  <= 1'b1;
                contention_count <= contention_count + 1'b1;
                if (contention_count < 3) begin
                    $display("ERROR: SDA contention at t=%0t ctrl{lo=%b hi=%b} tgt0{lo=%b hi=%b} tgt1{lo=%b hi=%b}",
                             $time, ctrl_drv_lo, ctrl_drv_hi,
                             tgt0_drv_lo, tgt0_drv_hi, tgt1_drv_lo, tgt1_drv_hi);
                    $display("    tgt0 trans.phase=%0d bit=%0d pp_en=%b drvlo=%b   ccc.state=%0d ack_pend=%b ack_drv=%b pp_en=%b drvlo=%b read_kind=%0d",
                             u_tgt0.u_target_top.u_target_transport.phase,
                             u_tgt0.u_target_top.u_target_transport.bit_pos,
                             u_tgt0.u_target_top.u_target_transport.sda_pp_en,
                             u_tgt0.u_target_top.u_target_transport.sda_drive_low,
                             u_tgt0.u_target_top.u_target_ccc.state,
                             u_tgt0.u_target_top.u_target_ccc.ack_pending,
                             u_tgt0.u_target_top.u_target_ccc.ack_drive_low,
                             u_tgt0.u_target_top.u_target_ccc.sda_pp_en,
                             u_tgt0.u_target_top.u_target_ccc.sda_drive_low,
                             u_tgt0.u_target_top.u_target_ccc.read_kind);
                    $display("    tgt1 trans.phase=%0d bit=%0d pp_en=%b drvlo=%b   ccc.state=%0d ack_pend=%b ack_drv=%b pp_en=%b drvlo=%b read_kind=%0d",
                             u_tgt1.u_target_top.u_target_transport.phase,
                             u_tgt1.u_target_top.u_target_transport.bit_pos,
                             u_tgt1.u_target_top.u_target_transport.sda_pp_en,
                             u_tgt1.u_target_top.u_target_transport.sda_drive_low,
                             u_tgt1.u_target_top.u_target_ccc.state,
                             u_tgt1.u_target_top.u_target_ccc.ack_pending,
                             u_tgt1.u_target_top.u_target_ccc.ack_drive_low,
                             u_tgt1.u_target_top.u_target_ccc.sda_pp_en,
                             u_tgt1.u_target_top.u_target_ccc.sda_drive_low,
                             u_tgt1.u_target_top.u_target_ccc.read_kind);
                end
            end
            if (tgt0_drv_hi | tgt1_drv_hi) begin
                tgt_drove_high_seen <= 1'b1;
            end
        end
    end

    // Host-command interface
    reg  host_cmd_valid;
    wire host_cmd_ready;
    reg  host_cmd_read;
    reg  host_cmd_target;
    reg  [7:0] host_cmd_reg_addr;
    reg  [7:0] host_cmd_write_value;
    reg  [7:0] host_cmd_read_len;
    wire host_rsp_valid;
    wire host_rsp_error;
    wire [7:0] host_rsp_len;
    wire [127:0] host_rsp_data;

    reg  host_ccc_valid;
    wire host_ccc_ready;
    reg  host_ccc_direct;
    reg  host_ccc_target;
    reg  [7:0] host_ccc_code;
    reg  [7:0] host_ccc_arg;
    wire host_ccc_rsp_valid;
    wire host_ccc_rsp_error;
    wire [7:0] host_ccc_rsp_len;
    wire [47:0] host_ccc_rsp_data;

    wire boot_done;
    wire boot_error;
    wire capture_error;
    wire [1:0] verified_bitmap;
    wire [1:0] sample_valid_bitmap;
    wire [1:0] target_led_state;
    wire [63:0] signature_flat;
    wire [159:0] sample_payloads_flat;
    wire [31:0] sample_capture_count_flat;
    wire [31:0] status_word_flat;
    wire [6:0] last_service_addr;
    wire [6:0] last_recovery_addr;

    i3c_dual_target_lab_controller #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .I3C_SDR_HZ (I3C_SDR_HZ),
        .USE_ENTDAA (USE_ENTDAA)
    ) dut_ctrl (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .scl_o                    (ctrl_scl_o),
        .scl_oe                   (ctrl_scl_oe),
        .sda_o                    (ctrl_sda_o),
        .sda_oe                   (ctrl_sda_oe),
        .sda_i                    (sda_bus),
        .host_cmd_valid           (host_cmd_valid),
        .host_cmd_ready           (host_cmd_ready),
        .host_cmd_read            (host_cmd_read),
        .host_cmd_target          (host_cmd_target),
        .host_cmd_reg_addr        (host_cmd_reg_addr),
        .host_cmd_write_value     (host_cmd_write_value),
        .host_cmd_read_len        (host_cmd_read_len),
        .host_rsp_valid           (host_rsp_valid),
        .host_rsp_error           (host_rsp_error),
        .host_rsp_len             (host_rsp_len),
        .host_rsp_data            (host_rsp_data),
        .host_ccc_valid           (host_ccc_valid),
        .host_ccc_ready           (host_ccc_ready),
        .host_ccc_direct          (host_ccc_direct),
        .host_ccc_target          (host_ccc_target),
        .host_ccc_code            (host_ccc_code),
        .host_ccc_arg             (host_ccc_arg),
        .host_ccc_rsp_valid       (host_ccc_rsp_valid),
        .host_ccc_rsp_error       (host_ccc_rsp_error),
        .host_ccc_rsp_len         (host_ccc_rsp_len),
        .host_ccc_rsp_data        (host_ccc_rsp_data),
        .boot_done                (boot_done),
        .boot_error               (boot_error),
        .capture_error            (capture_error),
        .recovery_active          (),
        .verified_bitmap          (verified_bitmap),
        .sample_valid_bitmap      (sample_valid_bitmap),
        .target_led_state         (target_led_state),
        .signature_flat           (signature_flat),
        .sample_payloads_flat     (sample_payloads_flat),
        .sample_capture_count_flat(sample_capture_count_flat),
        .status_word_flat         (status_word_flat),
        .last_service_addr        (last_service_addr),
        .last_recovery_addr       (last_recovery_addr)
    );

    i3c_sensor_gpio_target_demo #(
        .CLK_FREQ_HZ     (CLK_FREQ_HZ),
        .SAMPLE_RATE_HZ  (2_000),
        .STATIC_ADDR     (7'h30),
        .TARGET_INDEX    (0),
        .PROVISIONAL_ID  (48'h4100_0000_0011),
        .TARGET_SIGNATURE(32'h534E_0100),
        .USE_PUSH_PULL   (1)
    ) u_tgt0 (
        .clk               (clk),
        .rst_n             (rst_n),
        .scl               (scl_bus),
        .sda               (sda_bus),
        .sda_oe            (tgt0_sda_oe),
        .sda_o             (tgt0_sda_o),
        .indicator_out     (),
        .sample_payload    (),
        .signature_word    (),
        .control_reg       (),
        .register_pointer  (),
        .frame_counter     (),
        .active_addr       (),
        .dynamic_addr_valid(),
        .read_valid        ()
    );

    i3c_sensor_gpio_target_demo #(
        .CLK_FREQ_HZ     (CLK_FREQ_HZ),
        .SAMPLE_RATE_HZ  (2_000),
        .STATIC_ADDR     (7'h31),
        .TARGET_INDEX    (1),
        .PROVISIONAL_ID  (48'h4100_0000_0012),
        .TARGET_SIGNATURE(32'h534E_0101),
        .USE_PUSH_PULL   (1)
    ) u_tgt1 (
        .clk               (clk),
        .rst_n             (rst_n),
        .scl               (scl_bus),
        .sda               (sda_bus),
        .sda_oe            (tgt1_sda_oe),
        .sda_o             (tgt1_sda_o),
        .indicator_out     (),
        .sample_payload    (),
        .signature_word    (),
        .control_reg       (),
        .register_pointer  (),
        .frame_counter     (),
        .active_addr       (),
        .dynamic_addr_valid(),
        .read_valid        ()
    );

    task automatic issue_read;
        input        target;
        input [7:0]  reg_addr;
        input [7:0]  read_len;
        output [127:0] data;
        begin
            @(posedge clk);
            while (!host_cmd_ready) @(posedge clk);
            host_cmd_valid       <= 1'b1;
            host_cmd_read        <= 1'b1;
            host_cmd_target      <= target;
            host_cmd_reg_addr    <= reg_addr;
            host_cmd_write_value <= 8'h00;
            host_cmd_read_len    <= read_len;
            @(posedge clk);
            host_cmd_valid <= 1'b0;
            while (!host_rsp_valid) @(posedge clk);
            if (host_rsp_error) begin
                $display("FAIL: host read returned error target=%0d reg=0x%02x", target, reg_addr);
                $finish;
            end
            data = host_rsp_data;
        end
    endtask

    task automatic issue_direct_ccc;
        input        target;
        input [7:0]  ccc_code;
        input [7:0]  ccc_arg;
        output [47:0] data;
        output [7:0]  data_len;
        begin
            @(posedge clk);
            while (!host_ccc_ready) @(posedge clk);
            host_ccc_valid  <= 1'b1;
            host_ccc_direct <= 1'b1;
            host_ccc_target <= target;
            host_ccc_code   <= ccc_code;
            host_ccc_arg    <= ccc_arg;
            @(posedge clk);
            host_ccc_valid <= 1'b0;
            while (!host_ccc_rsp_valid) @(posedge clk);
            if (host_ccc_rsp_error) begin
                $display("FAIL: direct CCC returned error target=%0d code=0x%02x", target, ccc_code);
                $finish;
            end
            data     = host_ccc_rsp_data;
            data_len = host_ccc_rsp_len;
        end
    endtask

    reg [127:0] readback;
    reg [47:0]  ccc_readback;
    reg [7:0]   ccc_readback_len;

    initial begin
        $dumpfile("tb_i3c_external_bus_pushpull.vcd");
        $dumpvars(0, tb_i3c_external_bus_pushpull);
        $display("INFO: push-pull bus test, I3C_SDR_HZ=%0d USE_ENTDAA=%0d", I3C_SDR_HZ, USE_ENTDAA);

        host_cmd_valid       = 1'b0;
        host_cmd_read        = 1'b0;
        host_cmd_target      = 1'b0;
        host_cmd_reg_addr    = 8'h00;
        host_cmd_write_value = 8'h00;
        host_cmd_read_len    = 8'h00;
        host_ccc_valid       = 1'b0;
        host_ccc_direct      = 1'b0;
        host_ccc_target      = 1'b0;
        host_ccc_code        = 8'h00;
        host_ccc_arg         = 8'h00;

        repeat (20) @(posedge clk);
        rst_n = 1'b1;

        wait (boot_done);
        if (boot_error) begin
            $display("FAIL: boot_error asserted");
            $finish;
        end
        if (verified_bitmap != 2'b11) begin
            $display("FAIL: verified_bitmap=%b", verified_bitmap);
            $finish;
        end

        wait (sample_valid_bitmap == 2'b11);

        // Read signatures from both targets (transport-layer read, push-pull)
        issue_read(1'b0, 8'h00, 8'd4, readback);
        if (readback[31:0] != 32'h534E_0100) begin
            $display("FAIL: target0 signature mismatch 0x%08x", readback[31:0]);
            $finish;
        end
        issue_read(1'b1, 8'h00, 8'd4, readback);
        if (readback[31:0] != 32'h534E_0101) begin
            $display("FAIL: target1 signature mismatch 0x%08x", readback[31:0]);
            $finish;
        end

        // Read a full 10-byte sensor payload — exercises many consecutive
        // push-pull-data + T-bit handoffs.
        issue_read(1'b1, 8'h10, 8'd10, readback);
        if (readback[79:0] == 80'h0) begin
            $display("FAIL: target1 sample payload readback is zero");
            $finish;
        end

        // Direct CCC GETPID — CCC-handler push-pull path.
        issue_direct_ccc(1'b0, 8'h8D, 8'h00, ccc_readback, ccc_readback_len);
        if ((ccc_readback_len != 8'd6) || (ccc_readback != 48'h11_00_00_00_00_41)) begin
            $display("FAIL: GETPID target0 mismatch len=%0d data=0x%012x",
                     ccc_readback_len, ccc_readback);
            $finish;
        end

        // Direct CCC GETBCR — single-byte PP read.
        issue_direct_ccc(1'b0, 8'h8E, 8'h00, ccc_readback, ccc_readback_len);
        if ((ccc_readback_len != 8'd1) || (ccc_readback[7:0] != 8'h21)) begin
            $display("FAIL: GETBCR target0 mismatch len=%0d data=0x%02x",
                     ccc_readback_len, ccc_readback[7:0]);
            $finish;
        end

        // Final assertions
        if (contention_seen) begin
            $display("FAIL: SDA contention observed during test (count=%0d)", contention_count);
            $finish;
        end
        if (!tgt_drove_high_seen) begin
            $display("FAIL: no target ever drove SDA HIGH actively — push-pull not wired through");
            $finish;
        end

        $display("PASS: push-pull bus @ %0d Hz — boot + transport read + direct-CCC read, no contention, target actively drove HIGH",
                 I3C_SDR_HZ);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL: timeout boot_done=%0d boot_error=%0d verified=%b sample_valid=%b contention_seen=%0d tgt_drove_high=%0d",
                 boot_done, boot_error, verified_bitmap, sample_valid_bitmap,
                 contention_seen, tgt_drove_high_seen);
        $finish;
    end

endmodule
