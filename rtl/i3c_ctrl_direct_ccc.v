`timescale 1ns/1ps

module i3c_ctrl_direct_ccc #(
    parameter integer CLK_FREQ_HZ    = 100_000_000,
    parameter integer I3C_SDR_HZ     = 1_000_000,
    parameter integer PUSH_PULL_DATA = 1,
    parameter integer MAX_TX_BYTES   = 4,
    parameter integer MAX_RX_BYTES   = 4,
    parameter [6:0]  CCC_ADDR        = 7'h7E
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          cmd_valid,
    output reg                           cmd_ready,
    input  wire [7:0]                    ccc_code,
    input  wire [6:0]                    target_addr,
    input  wire                          target_read,
    input  wire [7:0]                    tx_len,
    input  wire [7:0]                    rx_len,
    input  wire [8*MAX_TX_BYTES-1:0]     tx_data,

    output reg                           rsp_valid,
    output reg                           rsp_nack,
    output reg [7:0]                     rsp_rx_count,
    output reg [8*MAX_RX_BYTES-1:0]      rsp_rdata,
    output reg                           busy,
    output wire                          dbg_nack_seen,

    output reg                           scl_o,
    output reg                           scl_oe,
    output reg                           sda_o,
    output reg                           sda_oe,
    input  wire                          sda_i
);

    localparam integer HALF_PERIOD_CLKS = CLK_FREQ_HZ / (2 * I3C_SDR_HZ);
    localparam integer DIVIDER          = (HALF_PERIOD_CLKS < 2) ? 2 : HALF_PERIOD_CLKS;

    localparam [4:0] ST_IDLE          = 5'd0;
    localparam [4:0] ST_START_A       = 5'd1;
    localparam [4:0] ST_START_B       = 5'd2;
    localparam [4:0] ST_TX_BIT_L      = 5'd3;
    localparam [4:0] ST_TX_BIT_H      = 5'd4;
    localparam [4:0] ST_ACK_L         = 5'd5;
    localparam [4:0] ST_ACK_H         = 5'd6;
    localparam [4:0] ST_PRE_RSTART    = 5'd17; // SCL low to release target SDA before Sr
    localparam [4:0] ST_PRE_ACK       = 5'd18; // SCL low to release controller SDA before target T-bit (writes)
    localparam [4:0] ST_PRE_T_BIT     = 5'd19; // SCL low to release target SDA before controller T-bit (reads)
    localparam [4:0] ST_RSTART_A      = 5'd7;
    localparam [4:0] ST_RSTART_B      = 5'd8;
    localparam [4:0] ST_RX_BIT_L      = 5'd9;
    localparam [4:0] ST_RX_BIT_H      = 5'd10;
    localparam [4:0] ST_MASTER_ACK_L  = 5'd11;
    localparam [4:0] ST_MASTER_ACK_H  = 5'd12;
    localparam [4:0] ST_STOP_A        = 5'd13;
    localparam [4:0] ST_STOP_B        = 5'd14;
    localparam [4:0] ST_STOP_C        = 5'd15;
    localparam [4:0] ST_DONE          = 5'd16;

    localparam [2:0] PH_CCC_ADDR     = 3'd0;
    localparam [2:0] PH_CCC_CODE     = 3'd1;
    localparam [2:0] PH_TARGET_ADDR  = 3'd2;
    localparam [2:0] PH_TARGET_WRITE = 3'd3;
    localparam [2:0] PH_TARGET_READ  = 3'd4;

    reg [4:0] state;
    reg [2:0] phase;
    reg [31:0] div_cnt;
    reg [3:0] bit_idx;
    reg [7:0] shreg;
    reg [7:0] tx_len_lat;
    reg [7:0] rx_len_lat;
    reg [7:0] tx_idx;
    reg [7:0] rx_idx;
    reg [7:0] ccc_code_lat;
    reg [6:0] target_addr_lat;
    reg       target_read_lat;
    reg [8*MAX_TX_BYTES-1:0] tx_data_lat;
    reg       nack_seen;

    wire tick = (div_cnt == 0);

    function [7:0] get_tx_byte;
        input [8*MAX_TX_BYTES-1:0] data_bus;
        input [7:0]                idx;
        begin
            get_tx_byte = data_bus[idx*8 +: 8];
        end
    endfunction

    task set_sda;
        input bit_value;
        input open_drain;
        begin
            if (open_drain) begin
                sda_o  <= 1'b0;
                sda_oe <= ~bit_value;
            end else begin
                sda_o  <= bit_value;
                sda_oe <= 1'b1;
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_IDLE;
            phase           <= PH_CCC_ADDR;
            div_cnt         <= DIVIDER - 1;
            bit_idx         <= 4'd0;
            shreg           <= 8'h00;
            tx_len_lat      <= 8'd0;
            rx_len_lat      <= 8'd0;
            tx_idx          <= 8'd0;
            rx_idx          <= 8'd0;
            ccc_code_lat    <= 8'h00;
            target_addr_lat <= 7'h00;
            target_read_lat <= 1'b0;
            tx_data_lat     <= {8*MAX_TX_BYTES{1'b0}};
            nack_seen       <= 1'b0;
            cmd_ready       <= 1'b1;
            rsp_valid       <= 1'b0;
            rsp_nack        <= 1'b0;
            rsp_rx_count    <= 8'd0;
            rsp_rdata       <= {8*MAX_RX_BYTES{1'b0}};
            busy            <= 1'b0;
            scl_o           <= 1'b1;
            scl_oe          <= 1'b1;
            sda_o           <= 1'b0;
            sda_oe          <= 1'b0;
        end else begin
            rsp_valid <= 1'b0;

            if (state == ST_IDLE) begin
                div_cnt <= DIVIDER - 1;
            end else if (tick) begin
                div_cnt <= DIVIDER - 1;
            end else begin
                div_cnt <= div_cnt - 1'b1;
            end

            case (state)
                ST_IDLE: begin
                    cmd_ready <= 1'b1;
                    busy      <= 1'b0;
                    scl_o     <= 1'b1;
                    scl_oe    <= 1'b1;
                    set_sda(1'b1, 1'b1);

                    if (cmd_valid) begin
                        phase           <= PH_CCC_ADDR;
                        shreg           <= {CCC_ADDR, 1'b0};
                        bit_idx         <= 4'd7;
                        tx_len_lat      <= tx_len;
                        rx_len_lat      <= rx_len;
                        tx_idx          <= 8'd0;
                        rx_idx          <= 8'd0;
                        ccc_code_lat    <= ccc_code;
                        target_addr_lat <= target_addr;
                        target_read_lat <= target_read;
                        tx_data_lat     <= tx_data;
                        nack_seen       <= 1'b0;
                        rsp_rx_count    <= 8'd0;
                        rsp_rdata       <= {8*MAX_RX_BYTES{1'b0}};
                        cmd_ready       <= 1'b0;
                        busy            <= 1'b1;
                        state           <= ST_START_A;
                    end
                end

                ST_START_A: begin
                    scl_o  <= 1'b1;
                    scl_oe <= 1'b1;
                    set_sda(1'b0, 1'b1);
                    if (tick) begin
                        state <= ST_START_B;
                    end
                end

                ST_START_B: begin
                    scl_o  <= 1'b0;
                    scl_oe <= 1'b1;
                    set_sda(1'b0, 1'b1);
                    if (tick) begin
                        state <= ST_TX_BIT_L;
                    end
                end

                ST_TX_BIT_L: begin
                    scl_o  <= 1'b0;
                    scl_oe <= 1'b1;
                    if (phase == PH_TARGET_WRITE) begin
                        set_sda(shreg[bit_idx], (PUSH_PULL_DATA == 0));
                    end else begin
                        set_sda(shreg[bit_idx], 1'b1);
                    end
                    if (tick) begin
                        state <= ST_TX_BIT_H;
                    end
                end

                ST_TX_BIT_H: begin
                    scl_o  <= 1'b1;
                    scl_oe <= 1'b1;
                    if (phase == PH_TARGET_WRITE) begin
                        set_sda(shreg[bit_idx], (PUSH_PULL_DATA == 0));
                    end else begin
                        set_sda(shreg[bit_idx], 1'b1);
                    end
                    if (tick) begin
                        if (bit_idx == 0) begin
                            // Insert a pre-ACK state when using push-pull data mode.
                            // This ensures SDA is released (high-Z) for a full half-period
                            // before the target's T-bit response, avoiding bus contention.
                            state <= (PUSH_PULL_DATA && (phase == PH_TARGET_WRITE)) ? ST_PRE_ACK : ST_ACK_L;
                        end else begin
                            bit_idx <= bit_idx - 1'b1;
                            state   <= ST_TX_BIT_L;
                        end
                    end
                end

                // Extra half-period with SCL low and SDA released before the T-bit.
                // Needed when PUSH_PULL_DATA=1 during PH_TARGET_WRITE: the controller
                // was driving SDA push-pull for the data bits, and we need to give
                // the bus time to float HIGH via the pull-up before the target
                // pulls it LOW for the ACK. Without this, controller and target
                // fight over the bus during the T-bit sample window.
                ST_PRE_ACK: begin
                    scl_o  <= 1'b0;
                    scl_oe <= 1'b1;
                    set_sda(1'b1, 1'b1); // release SDA (open-drain HIGH = high-Z)
                    if (tick) begin
                        state <= ST_ACK_L;
                    end
                end

                ST_ACK_L: begin
                    scl_o  <= 1'b0;
                    scl_oe <= 1'b1;
                    set_sda(1'b1, 1'b1);
                    if (tick) begin
                        state <= ST_ACK_H;
                    end
                end

                ST_ACK_H: begin
                    scl_o  <= 1'b1;
                    scl_oe <= 1'b1;
                    set_sda(1'b1, 1'b1);
                    if (tick) begin
                        if (sda_i) begin
                            nack_seen <= 1'b1;
                            state     <= ST_STOP_A;
                        end else begin
                            case (phase)
                                PH_CCC_ADDR: begin
                                    phase   <= PH_CCC_CODE;
                                    shreg   <= ccc_code_lat;
                                    bit_idx <= 4'd7;
                                    state   <= ST_TX_BIT_L;
                                end
                                PH_CCC_CODE: begin
                                    phase <= PH_TARGET_ADDR;
                                    state <= ST_PRE_RSTART; // dip SCL low first so target releases SDA
                                end
                                PH_TARGET_ADDR: begin
                                    if (target_read_lat && (rx_len_lat != 0)) begin
                                        phase   <= PH_TARGET_READ;
                                        bit_idx <= 4'd7;
                                        shreg   <= 8'h00;
                                        state   <= ST_RX_BIT_L;
                                    end else if (!target_read_lat && (tx_len_lat != 0)) begin
                                        phase   <= PH_TARGET_WRITE;
                                        shreg   <= get_tx_byte(tx_data_lat, 8'd0);
                                        bit_idx <= 4'd7;
                                        tx_idx  <= 8'd0;
                                        state   <= ST_TX_BIT_L;
                                    end else begin
                                        state <= ST_STOP_A;
                                    end
                                end
                                PH_TARGET_WRITE: begin
                                    if ((tx_idx + 1'b1) < tx_len_lat) begin
                                        tx_idx  <= tx_idx + 1'b1;
                                        shreg   <= get_tx_byte(tx_data_lat, tx_idx + 1'b1);
                                        bit_idx <= 4'd7;
                                        state   <= ST_TX_BIT_L;
                                    end else begin
                                        state <= ST_STOP_A;
                                    end
                                end
                                default: begin
                                    state <= ST_STOP_A;
                                end
                            endcase
                        end
                    end
                end

                // Dip SCL low for one half-period before the Repeated Start.
                // The target's scl_falling detection will fire here and clear
                // sda_drive_low, releasing the target's SDA hold from the
                // preceding CCC-code T-bit ACK.  This lets SDA rise to the
                // pull-up level so the true SDA falling edge of the Sr is
                // visible on the physical bus.
                ST_PRE_RSTART: begin
                    scl_o  <= 1'b0;
                    scl_oe <= 1'b1;
                    set_sda(1'b1, 1'b1); // release SDA (high-Z → pull-up)
                    if (tick) begin
                        state <= ST_RSTART_A;
                    end
                end

                ST_RSTART_A: begin
                    scl_o  <= 1'b1;
                    scl_oe <= 1'b1;
                    set_sda(1'b1, 1'b1);
                    if (tick) begin
                        state <= ST_RSTART_B;
                    end
                end

                ST_RSTART_B: begin
                    scl_o  <= 1'b1;
                    scl_oe <= 1'b1;
                    set_sda(1'b0, 1'b1);
                    shreg   <= {target_addr_lat, target_read_lat};
                    bit_idx <= 4'd7;
                    if (tick) begin
                        state <= ST_TX_BIT_L;
                    end
                end

                ST_RX_BIT_L: begin
                    scl_o  <= 1'b0;
                    scl_oe <= 1'b1;
                    set_sda(1'b1, 1'b1);
                    if (tick) begin
                        state <= ST_RX_BIT_H;
                    end
                end

                ST_RX_BIT_H: begin
                    scl_o  <= 1'b1;
                    scl_oe <= 1'b1;
                    set_sda(1'b1, 1'b1);
                    if (tick) begin
                        shreg[bit_idx] <= sda_i;
                        if (bit_idx == 0) begin
                            rsp_rdata[rx_idx*8 +: 8] <= {shreg[7:1], sda_i};
                            rsp_rx_count             <= rx_idx + 1'b1;
                            // When driving push-pull, insert a release gap so the
                            // target can let SDA float (accounting for its 2-stage
                            // SCL synchronizer) before the controller drives the
                            // T-bit HIGH.  Without this, the controller would push
                            // HIGH while the target is still pulling LOW on its
                            // last data bit, producing bus contention.
                            state                    <= PUSH_PULL_DATA ? ST_PRE_T_BIT : ST_MASTER_ACK_L;
                        end else begin
                            bit_idx <= bit_idx - 1'b1;
                            state   <= ST_RX_BIT_L;
                        end
                    end
                end

                // Extra half-period with SCL low and SDA released before the
                // controller's T-bit on PH_TARGET_READ.  Mirrors ST_PRE_ACK,
                // but releases on the read→T-bit handoff instead of the
                // write→ACK handoff.  Only used when PUSH_PULL_DATA=1.
                ST_PRE_T_BIT: begin
                    scl_o  <= 1'b0;
                    scl_oe <= 1'b1;
                    set_sda(1'b1, 1'b1);
                    if (tick) begin
                        state <= ST_MASTER_ACK_L;
                    end
                end

                ST_MASTER_ACK_L: begin
                    scl_o  <= 1'b0;
                    scl_oe <= 1'b1;
                    if (PUSH_PULL_DATA) begin
                        set_sda(1'b1, 1'b0);
                    end else begin
                        set_sda(1'b1, 1'b1);
                    end
                    if (tick) begin
                        state <= ST_MASTER_ACK_H;
                    end
                end

                ST_MASTER_ACK_H: begin
                    scl_o  <= 1'b1;
                    scl_oe <= 1'b1;
                    if (PUSH_PULL_DATA) begin
                        set_sda(1'b1, 1'b0);
                    end else begin
                        set_sda(1'b1, 1'b1);
                    end
                    if (tick) begin
                        if ((rx_idx + 1'b1) < rx_len_lat) begin
                            rx_idx  <= rx_idx + 1'b1;
                            bit_idx <= 4'd7;
                            shreg   <= 8'h00;
                            state   <= ST_RX_BIT_L;
                        end else begin
                            state <= ST_STOP_A;
                        end
                    end
                end

                ST_STOP_A: begin
                    scl_o  <= 1'b0;
                    scl_oe <= 1'b1;
                    set_sda(1'b0, 1'b1);
                    if (tick) begin
                        state <= ST_STOP_B;
                    end
                end

                ST_STOP_B: begin
                    scl_o  <= 1'b1;
                    scl_oe <= 1'b1;
                    set_sda(1'b0, 1'b1);
                    if (tick) begin
                        state <= ST_STOP_C;
                    end
                end

                ST_STOP_C: begin
                    scl_o  <= 1'b1;
                    scl_oe <= 1'b1;
                    set_sda(1'b1, 1'b1);
                    if (tick) begin
                        state <= ST_DONE;
                    end
                end

                ST_DONE: begin
                    cmd_ready <= 1'b1;
                    busy      <= 1'b0;
                    rsp_valid <= 1'b1;
                    rsp_nack  <= nack_seen;
                    scl_o     <= 1'b1;
                    scl_oe    <= 1'b1;
                    set_sda(1'b1, 1'b1);
                    state     <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
assign dbg_nack_seen = nack_seen;

endmodule
