`timescale 1ns/1ps

module i3c_ctrl_entdaa #(
    parameter integer CLK_FREQ_HZ    = 100_000_000,
    parameter integer I3C_SDR_HZ     = 1_000_000,
    parameter integer PUSH_PULL_DATA = 1,
    parameter [6:0]  CCC_ADDR        = 7'h7E,
    parameter [7:0]  CCC_ENTDAA      = 8'h07
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       cmd_valid,
    output reg        cmd_ready,

    output reg        discover_valid,
    output reg [47:0] discover_pid,
    output reg [7:0]  discover_bcr,
    output reg [7:0]  discover_dcr,

    input  wire       assign_valid,
    input  wire [6:0] assign_dynamic_addr,

    output reg        done,
    output reg        nack,
    output reg [6:0]  assigned_addr,
    output reg        busy,

    output reg        scl_o,
    output reg        scl_oe,
    output reg        sda_o,
    output reg        sda_oe,
    input  wire       sda_i
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
    localparam [4:0] ST_RSTART_A      = 5'd7;
    localparam [4:0] ST_RSTART_B      = 5'd8;
    localparam [4:0] ST_RX_BIT_L      = 5'd9;
    localparam [4:0] ST_RX_BIT_H      = 5'd10;
    localparam [4:0] ST_MASTER_ACK_L  = 5'd11;
    localparam [4:0] ST_MASTER_ACK_H  = 5'd12;
    localparam [4:0] ST_WAIT_ASSIGN   = 5'd13;
    localparam [4:0] ST_STOP_A        = 5'd14;
    localparam [4:0] ST_STOP_B        = 5'd15;
    localparam [4:0] ST_STOP_C        = 5'd16;
    localparam [4:0] ST_DONE          = 5'd17;

    localparam [2:0] PH_CCC_ADDR     = 3'd0;
    localparam [2:0] PH_CCC_CODE     = 3'd1;
    localparam [2:0] PH_ENTDAA_ADDR  = 3'd2;
    localparam [2:0] PH_ENTDAA_READ  = 3'd3;
    localparam [2:0] PH_ASSIGN_ADDR  = 3'd4;

    reg [4:0] state;
    reg [2:0] phase;
    reg [31:0] div_cnt;
    reg [3:0] bit_idx;
    reg [7:0] shreg;
    reg [7:0] rx_idx;
    reg [63:0] read_data;
    reg        nack_seen;
    reg        discover_emitted;

    wire tick = (div_cnt == 0);

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
            rx_idx          <= 8'd0;
            read_data       <= 64'h0;
            nack_seen       <= 1'b0;
            discover_emitted<= 1'b0;
            cmd_ready       <= 1'b1;
            discover_valid  <= 1'b0;
            discover_pid    <= 48'h0;
            discover_bcr    <= 8'h00;
            discover_dcr    <= 8'h00;
            done            <= 1'b0;
            nack            <= 1'b0;
            assigned_addr   <= 7'h00;
            busy            <= 1'b0;
            scl_o           <= 1'b1;
            scl_oe          <= 1'b1;
            sda_o           <= 1'b0;
            sda_oe          <= 1'b0;
        end else begin
            discover_valid <= 1'b0;
            done           <= 1'b0;

            if (state == ST_IDLE) begin
                div_cnt <= DIVIDER - 1;
            end else if (tick) begin
                div_cnt <= DIVIDER - 1;
            end else begin
                div_cnt <= div_cnt - 1'b1;
            end

            case (state)
                ST_IDLE: begin
                    cmd_ready        <= 1'b1;
                    busy             <= 1'b0;
                    nack             <= 1'b0;
                    assigned_addr    <= 7'h00;
                    scl_o            <= 1'b1;
                    scl_oe           <= 1'b1;
                    set_sda(1'b1, 1'b1);

                    if (cmd_valid) begin
                        phase            <= PH_CCC_ADDR;
                        shreg            <= {CCC_ADDR, 1'b0};
                        bit_idx          <= 4'd7;
                        rx_idx           <= 8'd0;
                        read_data        <= 64'h0;
                        nack_seen        <= 1'b0;
                        discover_emitted <= 1'b0;
                        discover_pid     <= 48'h0;
                        discover_bcr     <= 8'h00;
                        discover_dcr     <= 8'h00;
                        cmd_ready        <= 1'b0;
                        busy             <= 1'b1;
                        state            <= ST_START_A;
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
                    if (phase == PH_ASSIGN_ADDR) begin
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
                    if (phase == PH_ASSIGN_ADDR) begin
                        set_sda(shreg[bit_idx], (PUSH_PULL_DATA == 0));
                    end else begin
                        set_sda(shreg[bit_idx], 1'b1);
                    end
                    if (tick) begin
                        if (bit_idx == 0) begin
                            state <= ST_ACK_L;
                        end else begin
                            bit_idx <= bit_idx - 1'b1;
                            state   <= ST_TX_BIT_L;
                        end
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
                                    shreg   <= CCC_ENTDAA;
                                    bit_idx <= 4'd7;
                                    state   <= ST_TX_BIT_L;
                                end
                                PH_CCC_CODE: begin
                                    phase <= PH_ENTDAA_ADDR;
                                    state <= ST_RSTART_A;
                                end
                                PH_ENTDAA_ADDR: begin
                                    phase   <= PH_ENTDAA_READ;
                                    bit_idx <= 4'd7;
                                    shreg   <= 8'h00;
                                    state   <= ST_RX_BIT_L;
                                end
                                PH_ASSIGN_ADDR: begin
                                    assigned_addr <= assign_dynamic_addr;
                                    state         <= ST_STOP_A;
                                end
                                default: begin
                                    state <= ST_STOP_A;
                                end
                            endcase
                        end
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
                    shreg   <= {CCC_ADDR, 1'b1};
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
                            read_data[rx_idx*8 +: 8] <= {shreg[7:1], sda_i};
                            state                    <= ST_MASTER_ACK_L;
                        end else begin
                            bit_idx <= bit_idx - 1'b1;
                            state   <= ST_RX_BIT_L;
                        end
                    end
                end

                // ENTDAA response T-bit: the target drives LOW to signal
                // "I'm still participating, continue to next byte".  The
                // controller MUST be open-drain (released) here regardless
                // of PUSH_PULL_DATA — otherwise controller push-pull HIGH
                // would fight against the target's pull-low.  This is the
                // one read path where the T-bit is target-driven, not
                // controller-driven, so push-pull is not applicable.
                ST_MASTER_ACK_L: begin
                    scl_o  <= 1'b0;
                    scl_oe <= 1'b1;
                    set_sda(1'b1, 1'b1);
                    if (tick) begin
                        state <= ST_MASTER_ACK_H;
                    end
                end

                ST_MASTER_ACK_H: begin
                    scl_o  <= 1'b1;
                    scl_oe <= 1'b1;
                    set_sda(1'b1, 1'b1);
                    if (tick) begin
                        if ((rx_idx + 1'b1) < 8) begin
                            rx_idx  <= rx_idx + 1'b1;
                            bit_idx <= 4'd7;
                            shreg   <= 8'h00;
                            state   <= ST_RX_BIT_L;
                        end else begin
                            state <= ST_WAIT_ASSIGN;
                        end
                    end
                end

                ST_WAIT_ASSIGN: begin
                    scl_o  <= 1'b0;
                    scl_oe <= 1'b1;
                    set_sda(1'b1, 1'b1);
                    busy <= 1'b1;

                    if (!discover_emitted) begin
                        discover_valid   <= 1'b1;
                        discover_pid     <= {read_data[7:0], read_data[15:8], read_data[23:16],
                                             read_data[31:24], read_data[39:32], read_data[47:40]};
                        discover_bcr     <= read_data[55:48];
                        discover_dcr     <= read_data[63:56];
                        discover_emitted <= 1'b1;
                    end

                    if (assign_valid) begin
                        phase   <= PH_ASSIGN_ADDR;
                        shreg   <= {assign_dynamic_addr, 1'b0};
                        bit_idx <= 4'd7;
                        state   <= ST_TX_BIT_L;
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
                    done      <= 1'b1;
                    nack      <= nack_seen;
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
endmodule
