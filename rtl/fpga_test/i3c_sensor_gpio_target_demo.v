`timescale 1ns/1ps

module i3c_sensor_gpio_target_demo #(
    parameter integer MAX_READ_BYTES = 16,
    parameter integer TARGET_INDEX   = 0,
    parameter integer CLK_FREQ_HZ    = 100_000_000,
    parameter integer SAMPLE_RATE_HZ = 2_000,
    parameter [6:0]  STATIC_ADDR     = 7'h30,
    parameter [47:0] PROVISIONAL_ID  = 48'h4100_0000_0011,
    parameter [7:0]  TARGET_BCR      = 8'h21,
    parameter [7:0]  TARGET_DCR      = 8'h90,
    parameter [31:0] TARGET_SIGNATURE = 32'h534E_0001,
    // Thread through to i3c_target_top — see that module for semantics.
    parameter integer USE_PUSH_PULL    = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scl,
    input  wire        sda,
    output wire        sda_oe,
    output wire        sda_o,
    output wire        indicator_out,
    output wire [79:0] sample_payload,
    output wire [31:0] signature_word,
    output wire [7:0]  control_reg,
    output wire [7:0]  register_pointer,
    output wire [15:0] frame_counter,
    output wire [6:0]  active_addr,
    output wire        dynamic_addr_valid,
    output wire        read_valid
);

    localparam [7:0] REG_SIGNATURE_0 = 8'h00;
    localparam [7:0] REG_SIGNATURE_1 = 8'h01;
    localparam [7:0] REG_SIGNATURE_2 = 8'h02;
    localparam [7:0] REG_SIGNATURE_3 = 8'h03;
    localparam [7:0] REG_CONTROL     = 8'h04;
    localparam [7:0] REG_TARGET_IDX  = 8'h05;
    localparam [7:0] REG_FRAME_LO    = 8'h06;
    localparam [7:0] REG_FRAME_HI    = 8'h07;
    localparam [7:0] REG_STATUS      = 8'h08;
    localparam [7:0] REG_SAMPLE_BASE = 8'h10;

    wire sample_tick;
    wire [8*MAX_READ_BYTES-1:0] read_data_bus;
    wire [7:0] write_data;
    wire write_valid;
    wire selected;
    wire [7:0] latched_selector;
    wire [47:0] provisional_id;
    wire [7:0] event_enable_mask;
    wire [7:0] rstact_action;
    wire [15:0] status_word;
    wire [1:0] activity_state;
    wire group_addr_valid;
    wire [6:0] group_addr;
    wire [15:0] max_write_len;
    wire [15:0] max_read_len;
    wire [7:0] ibi_data_len;
    wire [7:0] last_ccc;

    reg [7:0] control_reg_r;
    reg [7:0] register_pointer_r;
    reg [7:0] write_count;
    reg       selected_d;
    integer k;

    assign indicator_out    = control_reg_r[0];
    assign control_reg      = control_reg_r;
    assign register_pointer = register_pointer_r;
    assign signature_word   = TARGET_SIGNATURE;

    i3c_demo_rate_tick #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .TICK_HZ    (SAMPLE_RATE_HZ)
    ) u_sample_tick (
        .clk  (clk),
        .rst_n(rst_n),
        .tick (sample_tick)
    );

    i3c_sensor_frame_gen #(
        .TARGET_INDEX(TARGET_INDEX)
    ) u_frame_gen (
        .clk           (clk),
        .rst_n         (rst_n),
        .sample_tick   (sample_tick),
        .frame_counter (frame_counter),
        .sample_payload(sample_payload)
    );

    function [7:0] read_reg_byte;
        input [7:0] addr;
        begin
            case (addr)
                REG_SIGNATURE_0: read_reg_byte = TARGET_SIGNATURE[7:0];
                REG_SIGNATURE_1: read_reg_byte = TARGET_SIGNATURE[15:8];
                REG_SIGNATURE_2: read_reg_byte = TARGET_SIGNATURE[23:16];
                REG_SIGNATURE_3: read_reg_byte = TARGET_SIGNATURE[31:24];
                REG_CONTROL:     read_reg_byte = control_reg_r;
                REG_TARGET_IDX:  read_reg_byte = TARGET_INDEX[7:0];
                REG_FRAME_LO:    read_reg_byte = frame_counter[7:0];
                REG_FRAME_HI:    read_reg_byte = frame_counter[15:8];
                REG_STATUS:      read_reg_byte = {4'h0, dynamic_addr_valid, indicator_out, selected, read_valid};
                8'h09:           read_reg_byte = last_ccc;
                8'h0A:           read_reg_byte = event_enable_mask;
                8'h0B:           read_reg_byte = rstact_action;
                8'h0C:           read_reg_byte = status_word[7:0];
                8'h0D:           read_reg_byte = status_word[15:8];
                8'h0E:           read_reg_byte = {5'h0, activity_state, group_addr_valid};
                8'h0F:           read_reg_byte = {group_addr, dynamic_addr_valid};
                8'h10:           read_reg_byte = sample_payload[7:0];
                8'h11:           read_reg_byte = sample_payload[15:8];
                8'h12:           read_reg_byte = sample_payload[23:16];
                8'h13:           read_reg_byte = sample_payload[31:24];
                8'h14:           read_reg_byte = sample_payload[39:32];
                8'h15:           read_reg_byte = sample_payload[47:40];
                8'h16:           read_reg_byte = sample_payload[55:48];
                8'h17:           read_reg_byte = sample_payload[63:56];
                8'h18:           read_reg_byte = sample_payload[71:64];
                8'h19:           read_reg_byte = sample_payload[79:72];
                8'h1A:           read_reg_byte = max_write_len[7:0];
                8'h1B:           read_reg_byte = max_write_len[15:8];
                8'h1C:           read_reg_byte = max_read_len[7:0];
                8'h1D:           read_reg_byte = max_read_len[15:8];
                8'h1E:           read_reg_byte = ibi_data_len;
                default:         read_reg_byte = 8'h00;
            endcase
        end
    endfunction

    // The case-mux inside read_reg_byte() is the longest combinational
    // path in this design (~7-8 LUT levels per byte slot, replicated
    // MAX_READ_BYTES times).  At 100 MHz it landed with ~0.7 ns slack;
    // at 140 MHz the same path would fail to close.  Pipeline here by
    // registering the read window once per system clock — the transport
    // only samples this bus on scl_falling, which at 4 MHz I3C is once
    // every ~35 sysclks at 140 MHz, so 1 cycle of latency is invisible.
    wire [8*MAX_READ_BYTES-1:0] read_data_bus_comb;
    reg  [8*MAX_READ_BYTES-1:0] read_data_bus_r;
    generate
        genvar idx;
        for (idx = 0; idx < MAX_READ_BYTES; idx = idx + 1) begin : g_read_window
            assign read_data_bus_comb[idx*8 +: 8] = read_reg_byte(register_pointer_r + idx[7:0]);
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) read_data_bus_r <= {8*MAX_READ_BYTES{1'b0}};
        else        read_data_bus_r <= read_data_bus_comb;
    end

    assign read_data_bus = read_data_bus_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            control_reg_r     <= 8'h00;
            register_pointer_r <= REG_SAMPLE_BASE;
            write_count       <= 8'h00;
            selected_d        <= 1'b0;
        end else begin
            selected_d <= selected;

            if (!selected_d && selected) begin
                write_count <= 8'h00;
            end

            if (!selected) begin
                write_count <= 8'h00;
            end

            if (write_valid) begin
                if (write_count == 8'h00) begin
                    register_pointer_r <= write_data;
                    write_count        <= 8'h01;
                end else begin
                    case (register_pointer_r)
                        REG_CONTROL: begin
                            control_reg_r <= {7'h00, write_data[0]};
                        end
                        default: begin
                        end
                    endcase
                    register_pointer_r <= register_pointer_r + 1'b1;
                    write_count        <= write_count + 1'b1;
                end
            end
        end
    end

    i3c_target_top #(
        .MAX_READ_BYTES(MAX_READ_BYTES),
        .STATIC_ADDR   (STATIC_ADDR),
        .PROVISIONAL_ID(PROVISIONAL_ID),
        .TARGET_BCR    (TARGET_BCR),
        .TARGET_DCR    (TARGET_DCR),
        .USE_PUSH_PULL (USE_PUSH_PULL)
    ) u_target_top (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .scl                      (scl),
        .sda                      (sda),
        .sda_oe                   (sda_oe),
        .sda_o                    (sda_o),
        .clear_dynamic_addr       (1'b0),
        .assign_dynamic_addr_valid(1'b0),
        .assign_dynamic_addr      (7'h00),
        .read_data                (read_data_bus),
        .write_data               (write_data),
        .write_valid              (write_valid),
        .register_selector        (latched_selector),
        .read_valid               (read_valid),
        .selected                 (selected),
        .active_addr              (active_addr),
        .dynamic_addr_valid       (dynamic_addr_valid),
        .provisional_id           (provisional_id),
        .event_enable_mask        (event_enable_mask),
        .rstact_action            (rstact_action),
        .status_word              (status_word),
        .activity_state           (activity_state),
        .group_addr_valid         (group_addr_valid),
        .group_addr               (group_addr),
        .max_write_len            (max_write_len),
        .max_read_len             (max_read_len),
        .ibi_data_len             (ibi_data_len),
        .last_ccc                 (last_ccc)
    );

endmodule
