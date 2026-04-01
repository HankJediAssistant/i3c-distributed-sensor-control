`timescale 1ns/1ps

module i3c_target_transport #(
    parameter integer MAX_READ_BYTES = 4
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       scl,
    input  wire       sda,
    output wire       sda_drive_en,

    input  wire       suppress,
    input  wire [6:0] target_addr,
    input  wire       alt_addr_valid,
    input  wire [6:0] alt_addr,
    input  wire [8*MAX_READ_BYTES-1:0] read_data,
    output reg  [7:0] write_data,
    output reg        write_valid,
    output reg        read_valid,
    output reg        selected
);

    localparam [2:0] P_IDLE   = 3'd0;
    localparam [2:0] P_ADDR   = 3'd1;
    localparam [2:0] P_WRITE  = 3'd2;
    localparam [2:0] P_READ   = 3'd3;
    localparam [2:0] P_READ_ACK = 3'd4;
    localparam [2:0] P_IGNORE   = 3'd5;

    reg [2:0] phase;
    reg [3:0] bit_pos;
    reg [7:0] read_byte_idx;
    reg [7:0] rx_shift;
    reg       sda_drive_low;
    reg       ack_pending;
    reg       addr_match;
    reg       rw_latched;

    function [7:0] get_read_byte;
        input [8*MAX_READ_BYTES-1:0] data_bus;
        input [7:0]                  idx;
        begin
            if (idx < MAX_READ_BYTES) begin
                get_read_byte = data_bus[idx*8 +: 8];
            end else begin
                get_read_byte = data_bus[(MAX_READ_BYTES-1)*8 +: 8];
            end
        end
    endfunction

    wire [7:0] current_read_byte = get_read_byte(read_data, read_byte_idx);

    assign sda_drive_en = sda_drive_low;

    // 2-stage synchronizers for external SCL/SDA inputs
    // Prevents metastability with slow external edges
    reg scl_sync1, scl_sync2;
    reg sda_sync1, sda_sync2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_sync1 <= 1'b1;
            scl_sync2 <= 1'b1;
            sda_sync1 <= 1'b1;
            sda_sync2 <= 1'b1;
        end else begin
            scl_sync1 <= scl;
            scl_sync2 <= scl_sync1;
            sda_sync1 <= sda;
            sda_sync2 <= sda_sync1;
        end
    end

    // Edge detection on synchronized signals
    reg scl_d, sda_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_d <= 1'b1;
            sda_d <= 1'b1;
        end else begin
            scl_d <= scl_sync2;
            sda_d <= sda_sync2;
        end
    end
    wire scl_rising  = ~scl_d &  scl_sync2;
    wire scl_falling =  scl_d & ~scl_sync2;
    wire sda_falling =  sda_d & ~sda_sync2;
    wire sda_rising  = ~sda_d &  sda_sync2;

    // Single synchronous state machine
    // Priority: reset > START (sda_falling) > STOP (sda_rising) > SCL edges
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase         <= P_IDLE;
            bit_pos       <= 4'd0;
            read_byte_idx <= 8'd0;
            rx_shift      <= 8'h00;
            sda_drive_low <= 1'b0;
            ack_pending   <= 1'b0;
            addr_match    <= 1'b0;
            rw_latched    <= 1'b0;
            selected      <= 1'b0;
            write_data    <= 8'h00;
            write_valid   <= 1'b0;
            read_valid    <= 1'b0;
        end else begin
            // Clear single-cycle pulses every cycle
            write_valid <= 1'b0;
            read_valid  <= 1'b0;

            if (sda_falling && scl) begin
                // START condition — highest priority
                phase         <= suppress ? P_IGNORE : P_ADDR;
                bit_pos       <= 4'd0;
                read_byte_idx <= 8'd0;
                rx_shift      <= 8'h00;
                sda_drive_low <= 1'b0;
                ack_pending   <= 1'b0;
                addr_match    <= 1'b0;
                rw_latched    <= 1'b0;
                selected      <= 1'b0;
            end else if (sda_rising && scl) begin
                // STOP condition
                phase         <= P_IDLE;
                bit_pos       <= 4'd0;
                sda_drive_low <= 1'b0;
                ack_pending   <= 1'b0;
                selected      <= 1'b0;
            end else if (scl_falling) begin
                // Drive SDA for ACK / read data on falling SCL edge
                if (suppress) begin
                    sda_drive_low <= 1'b0;
                end else if (ack_pending && (phase == P_ADDR || phase == P_WRITE) && (bit_pos == 4'd8)) begin
                    sda_drive_low <= addr_match;
                end else if (phase == P_READ && bit_pos < 4'd8) begin
                    sda_drive_low <= ~current_read_byte[7 - bit_pos];
                end else begin
                    sda_drive_low <= 1'b0;
                end
            end else if (scl_rising) begin
                // Sample data / advance state machine on rising SCL edge
                if (suppress) begin
                    phase         <= P_IGNORE;
                    bit_pos       <= 4'd0;
                    read_byte_idx <= 8'd0;
                    ack_pending   <= 1'b0;
                    addr_match    <= 1'b0;
                    rw_latched    <= 1'b0;
                    selected      <= 1'b0;
                end else begin
                    case (phase)
                        P_ADDR: begin
                            if (bit_pos < 4'd8) begin
                                rx_shift <= {rx_shift[6:0], sda};
                                if (bit_pos == 4'd7) begin
                                    addr_match  <= (({rx_shift[6:0], sda} & 8'hFE) == {target_addr, 1'b0}) ||
                                                   (alt_addr_valid &&
                                                    (({rx_shift[6:0], sda} & 8'hFE) == {alt_addr, 1'b0}));
                                    rw_latched  <= sda;
                                    ack_pending <= 1'b1;
                                    bit_pos     <= 4'd8;
                                end else begin
                                    bit_pos <= bit_pos + 1'b1;
                                end
                            end else begin
                                ack_pending <= 1'b0;
                                bit_pos     <= 4'd0;
                                selected    <= addr_match;
                                if (addr_match) begin
                                    if (rw_latched) begin
                                        read_valid <= 1'b1;
                                    end
                                    read_byte_idx <= 8'd0;
                                    phase <= rw_latched ? P_READ : P_WRITE;
                                end else begin
                                    phase <= P_IGNORE;
                                end
                            end
                        end

                        P_WRITE: begin
                            if (bit_pos < 4'd8) begin
                                rx_shift <= {rx_shift[6:0], sda};
                                if (bit_pos == 4'd7) begin
                                    write_data  <= {rx_shift[6:0], sda};
                                    write_valid <= 1'b1;
                                    ack_pending <= 1'b1;
                                    bit_pos     <= 4'd8;
                                end else begin
                                    bit_pos <= bit_pos + 1'b1;
                                end
                            end else begin
                                ack_pending <= 1'b0;
                                bit_pos     <= 4'd0;
                                phase       <= P_WRITE;
                            end
                        end

                        P_READ: begin
                            if (bit_pos < 4'd8) begin
                                if (bit_pos == 4'd7) begin
                                    bit_pos <= 4'd0;
                                    phase   <= P_READ_ACK;
                                end else begin
                                    bit_pos <= bit_pos + 1'b1;
                                end
                            end else begin
                                bit_pos <= 4'd0;
                                phase   <= P_READ_ACK;
                            end
                        end

                        P_READ_ACK: begin
                            if (sda == 1'b0) begin
                                if ((read_byte_idx + 1'b1) < MAX_READ_BYTES) begin
                                    read_byte_idx <= read_byte_idx + 1'b1;
                                    bit_pos       <= 4'd0;
                                    phase         <= P_READ;
                                end else begin
                                    phase <= P_IGNORE;
                                end
                            end else begin
                                phase <= P_IGNORE;
                            end
                        end

                        default: begin
                        end
                    endcase
                end
            end
        end
    end
endmodule
