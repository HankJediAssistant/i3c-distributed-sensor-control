`timescale 1ns/1ps

module i3c_dual_target_lab_controller #(
    parameter integer ENDPOINT_COUNT     = 2,
    parameter integer MAX_SERVICE_BYTES  = 16,
    parameter integer PAYLOAD_BYTES      = 10,
    parameter integer CLK_FREQ_HZ        = 100_000_000,
    parameter integer I3C_SDR_HZ         = 12_500_000,
    parameter integer SAMPLE_RATE_HZ     = 2_000,
    parameter [6:0]  DYN_ADDR_BASE       = 7'h10,
    parameter [6:0]  STATIC_ADDR_BASE    = 7'h30,
    parameter [47:0] PROVISIONAL_ID_BASE = 48'h4100_0000_0011,
    parameter [31:0] SIGNATURE_BASE      = 32'h534E_0100,
    parameter [7:0]  TARGET_BCR          = 8'h21,
    parameter [7:0]  TARGET_DCR          = 8'h90,
    parameter [7:0]  SAMPLE_SELECTOR     = 8'h10,
    parameter [7:0]  CONTROL_SELECTOR    = 8'h04,
    parameter [7:0]  RECOVERY_RSTACT_ACTION = 8'h02
) (
    input  wire                                   clk,
    input  wire                                   rst_n,
    output wire                                   scl_o,
    output wire                                   scl_oe,
    output wire                                   sda_o,
    output wire                                   sda_oe,
    input  wire                                   sda_i,

    input  wire                                   host_cmd_valid,
    output wire                                   host_cmd_ready,
    input  wire                                   host_cmd_read,
    input  wire                                   host_cmd_target,
    input  wire [7:0]                             host_cmd_reg_addr,
    input  wire [7:0]                             host_cmd_write_value,
    input  wire [7:0]                             host_cmd_read_len,
    output reg                                    host_rsp_valid,
    output reg                                    host_rsp_error,
    output reg  [7:0]                             host_rsp_len,
    output reg  [8*MAX_SERVICE_BYTES-1:0]         host_rsp_data,

    input  wire                                   host_ccc_valid,
    output wire                                   host_ccc_ready,
    input  wire                                   host_ccc_direct,
    input  wire                                   host_ccc_target,
    input  wire [7:0]                             host_ccc_code,
    input  wire [7:0]                             host_ccc_arg,
    output reg                                    host_ccc_rsp_valid,
    output reg                                    host_ccc_rsp_error,
    output reg  [7:0]                             host_ccc_rsp_len,
    output reg  [47:0]                            host_ccc_rsp_data,

    output reg                                    boot_done,
    output reg                                    boot_error,
    output wire                                   dbg_nack_seen,
    output reg                                    capture_error,
    output reg                                    recovery_active,
    output reg  [ENDPOINT_COUNT-1:0]              verified_bitmap,
    output reg  [ENDPOINT_COUNT-1:0]              sample_valid_bitmap,
    output reg  [ENDPOINT_COUNT-1:0]              target_led_state,
    output reg  [ENDPOINT_COUNT*32-1:0]           signature_flat,
    output reg  [ENDPOINT_COUNT*PAYLOAD_BYTES*8-1:0] sample_payloads_flat,
    output reg  [ENDPOINT_COUNT*16-1:0]           sample_capture_count_flat,
    output reg  [ENDPOINT_COUNT*16-1:0]           status_word_flat,
    output reg  [6:0]                             last_service_addr,
    output reg  [6:0]                             last_recovery_addr
);

    localparam integer INDEX_W = 1;
    localparam integer PID_BYTES = 6;
    localparam integer STATUS_BYTES = 2;
    localparam integer SIGNATURE_BYTES = 4;
    localparam integer SCHEDULE_TICK_HZ = ENDPOINT_COUNT * SAMPLE_RATE_HZ;
    localparam integer SCHEDULE_DIV_CLKS = (SCHEDULE_TICK_HZ <= 0) ? 1 : (CLK_FREQ_HZ / SCHEDULE_TICK_HZ);
    localparam integer SCHEDULE_DIV_W = (SCHEDULE_DIV_CLKS <= 1) ? 1 : $clog2(SCHEDULE_DIV_CLKS);

    localparam [7:0] CCC_GETPID    = 8'h8D;
    localparam [7:0] CCC_GETBCR    = 8'h8E;
    localparam [7:0] CCC_GETDCR    = 8'h8F;
    localparam [7:0] CCC_GETSTATUS = 8'h90;
    localparam [7:0] CCC_GETMWL    = 8'h8B;
    localparam [7:0] CCC_GETMRL    = 8'h8C;
    localparam [7:0] CCC_GETMXDS   = 8'h94;
    localparam [7:0] CCC_GETCAPS   = 8'h95;
    localparam [7:0] CCC_SETDASA   = 8'h87;
    localparam [7:0] CCC_RSTACT    = 8'h9A;
    localparam [7:0] CCC_ENEC_DIRECT = 8'h80;
    localparam [7:0] CCC_DISEC_DIRECT = 8'h81;
    localparam [7:0] CCC_ENEC_BCAST = 8'h00;
    localparam [7:0] CCC_DISEC_BCAST = 8'h01;
    localparam [6:0] CCC_ADDR = 7'h7E;

    localparam [5:0] ST_BOOT_SETDASA_REQ   = 6'd0;
    localparam [5:0] ST_BOOT_SETDASA_WAIT  = 6'd1;
    localparam [5:0] ST_BOOT_GETPID_REQ    = 6'd2;
    localparam [5:0] ST_BOOT_GETPID_WAIT   = 6'd3;
    localparam [5:0] ST_BOOT_GETBCR_REQ    = 6'd4;
    localparam [5:0] ST_BOOT_GETBCR_WAIT   = 6'd5;
    localparam [5:0] ST_BOOT_GETDCR_REQ    = 6'd6;
    localparam [5:0] ST_BOOT_GETDCR_WAIT   = 6'd7;
    localparam [5:0] ST_BOOT_GETSTATUS_REQ = 6'd8;
    localparam [5:0] ST_BOOT_GETSTATUS_WAIT = 6'd9;
    localparam [5:0] ST_BOOT_RSTACT_REQ    = 6'd10;
    localparam [5:0] ST_BOOT_RSTACT_WAIT   = 6'd11;
    localparam [5:0] ST_BOOT_SIG_SEL_REQ   = 6'd12;
    localparam [5:0] ST_BOOT_SIG_SEL_WAIT  = 6'd13;
    localparam [5:0] ST_BOOT_SIG_RD_REQ    = 6'd14;
    localparam [5:0] ST_BOOT_SIG_RD_WAIT   = 6'd15;
    localparam [5:0] ST_BOOT_NEXT          = 6'd16;
    localparam [5:0] ST_RUN_IDLE           = 6'd17;
    localparam [5:0] ST_RUN_SCHED_SEL_REQ  = 6'd18;
    localparam [5:0] ST_RUN_SCHED_SEL_WAIT = 6'd19;
    localparam [5:0] ST_RUN_SCHED_RD_REQ   = 6'd20;
    localparam [5:0] ST_RUN_SCHED_RD_WAIT  = 6'd21;
    localparam [5:0] ST_RUN_HOST_SEL_REQ   = 6'd22;
    localparam [5:0] ST_RUN_HOST_SEL_WAIT  = 6'd23;
    localparam [5:0] ST_RUN_HOST_RD_REQ    = 6'd24;
    localparam [5:0] ST_RUN_HOST_RD_WAIT   = 6'd25;
    localparam [5:0] ST_RUN_HOST_WR_REQ    = 6'd26;
    localparam [5:0] ST_RUN_HOST_WR_WAIT   = 6'd27;
    localparam [5:0] ST_RECOVER_GETSTATUS_REQ = 6'd28;
    localparam [5:0] ST_RECOVER_GETSTATUS_WAIT = 6'd29;
    localparam [5:0] ST_RECOVER_SETDASA_REQ = 6'd30;
    localparam [5:0] ST_RECOVER_SETDASA_WAIT = 6'd31;
    localparam [5:0] ST_RECOVER_RECHECK_REQ = 6'd32;
    localparam [5:0] ST_RECOVER_RECHECK_WAIT = 6'd33;
    localparam [5:0] ST_ERROR              = 6'd34;
    localparam [5:0] ST_RUN_HOST_DCCC_REQ  = 6'd35;
    localparam [5:0] ST_RUN_HOST_DCCC_WAIT = 6'd36;
    localparam [5:0] ST_RUN_HOST_BCCC_REQ  = 6'd37;
    localparam [5:0] ST_RUN_HOST_BCCC_WAIT = 6'd38;

    localparam [1:0] OP_NONE           = 2'd0;
    localparam [1:0] OP_SCHEDULE_READ  = 2'd1;
    localparam [1:0] OP_HOST_READ      = 2'd2;
    localparam [1:0] OP_HOST_WRITE     = 2'd3;

    reg [5:0] state;
    reg [INDEX_W-1:0] boot_index;
    reg [INDEX_W-1:0] sched_index;
    reg [INDEX_W-1:0] active_target;
    reg [INDEX_W-1:0] pending_host_target;
    reg               pending_ccc_target;
    reg               pending_ccc_direct;
    reg [7:0]         pending_host_reg_addr;
    reg [7:0]         pending_host_write_value;
    reg [7:0]         pending_host_read_len;
    reg [7:0]         pending_ccc_code;
    reg [7:0]         pending_ccc_arg;
    reg [1:0]         recovery_retry_op;

    reg [SCHEDULE_DIV_W-1:0] schedule_div_cnt;
    wire schedule_tick = (schedule_div_cnt == SCHEDULE_DIV_CLKS - 1);

    reg        txn_req_valid;
    wire       txn_req_ready;
    reg [6:0]  txn_req_addr;
    reg        txn_req_read;
    reg [7:0]  txn_req_tx_len;
    reg [7:0]  txn_req_rx_len;
    reg [8*MAX_SERVICE_BYTES-1:0] txn_req_wdata;
    wire       txn_rsp_valid;
    wire       txn_rsp_nack;
    wire [7:0] txn_rsp_rx_count;
    wire [8*MAX_SERVICE_BYTES-1:0] txn_rsp_rdata;
    wire       txn_busy;
    wire       txn_scl_o;
    wire       txn_scl_oe;
    wire       txn_sda_o;
    wire       txn_sda_oe;

    reg        ccc_valid;
    wire       ccc_ready;
    reg [7:0]  ccc_code;
    reg [7:0]  ccc_data_len;
    reg [8*(MAX_SERVICE_BYTES-1)-1:0] ccc_data;
    wire       ccc_done;
    wire       ccc_nack;
    wire       ccc_txn_req_valid;
    wire       ccc_txn_req_ready;
    wire [6:0] ccc_txn_req_addr;
    wire       ccc_txn_req_read;
    wire [7:0] ccc_txn_req_tx_len;
    wire [7:0] ccc_txn_req_rx_len;
    wire [8*MAX_SERVICE_BYTES-1:0] ccc_txn_req_wdata;

    reg        dccc_cmd_valid;
    wire       dccc_cmd_ready;
    reg [7:0]  dccc_ccc_code;
    reg [6:0]  dccc_target_addr;
    reg        dccc_target_read;
    reg [7:0]  dccc_tx_len;
    reg [7:0]  dccc_rx_len;
    reg [47:0] dccc_tx_data;
    wire       dccc_rsp_valid;
    wire       dccc_rsp_nack;
    wire [7:0] dccc_rsp_rx_count;
    wire [47:0] dccc_rsp_rdata;
    wire       dccc_busy;
    wire       dccc_scl_o;
    wire       dccc_scl_oe;
    wire       dccc_sda_o;
    wire       dccc_sda_oe;

    wire dccc_bus_owner = (state == ST_BOOT_SETDASA_REQ) ||
                          (state == ST_BOOT_SETDASA_WAIT) ||
                          (state == ST_BOOT_GETPID_REQ) ||
                          (state == ST_BOOT_GETPID_WAIT) ||
                          (state == ST_BOOT_GETBCR_REQ) ||
                          (state == ST_BOOT_GETBCR_WAIT) ||
                          (state == ST_BOOT_GETDCR_REQ) ||
                          (state == ST_BOOT_GETDCR_WAIT) ||
                          (state == ST_BOOT_GETSTATUS_REQ) ||
                          (state == ST_BOOT_GETSTATUS_WAIT) ||
                          (state == ST_BOOT_RSTACT_REQ) ||
                          (state == ST_BOOT_RSTACT_WAIT) ||
                          (state == ST_RUN_HOST_DCCC_REQ) ||
                          (state == ST_RUN_HOST_DCCC_WAIT) ||
                          (state >= ST_RECOVER_GETSTATUS_REQ && state <= ST_RECOVER_RECHECK_WAIT) ||
                          (state == ST_ERROR);

    integer i;

    function [6:0] endpoint_static_addr;
        input integer idx;
        begin
            endpoint_static_addr = STATIC_ADDR_BASE + idx[6:0];
        end
    endfunction

    function [6:0] endpoint_dynamic_addr;
        input integer idx;
        begin
            endpoint_dynamic_addr = DYN_ADDR_BASE + idx[6:0];
        end
    endfunction

    function [47:0] endpoint_pid;
        input integer idx;
        begin
            endpoint_pid = PROVISIONAL_ID_BASE + idx;
        end
    endfunction

    function [31:0] endpoint_signature;
        input integer idx;
        begin
            endpoint_signature = SIGNATURE_BASE + idx;
        end
    endfunction

    function [47:0] direct_pid_value;
        input [47:0] pid;
        begin
            direct_pid_value = {pid[7:0], pid[15:8], pid[23:16], pid[31:24], pid[39:32], pid[47:40]};
        end
    endfunction

    function [15:0] decode_status_word;
        input [15:0] direct_value;
        begin
            decode_status_word = {direct_value[7:0], direct_value[15:8]};
        end
    endfunction

    function direct_ccc_is_supported;
        input [7:0] code;
        begin
            case (code)
                CCC_GETPID,
                CCC_GETBCR,
                CCC_GETDCR,
                CCC_GETSTATUS,
                CCC_GETMWL,
                CCC_GETMRL,
                CCC_GETMXDS,
                CCC_GETCAPS,
                CCC_ENEC_DIRECT,
                CCC_DISEC_DIRECT,
                CCC_RSTACT: direct_ccc_is_supported = 1'b1;
                default:    direct_ccc_is_supported = 1'b0;
            endcase
        end
    endfunction

    function direct_ccc_is_read;
        input [7:0] code;
        begin
            case (code)
                CCC_GETPID,
                CCC_GETBCR,
                CCC_GETDCR,
                CCC_GETSTATUS,
                CCC_GETMWL,
                CCC_GETMRL,
                CCC_GETMXDS,
                CCC_GETCAPS: direct_ccc_is_read = 1'b1;
                default:     direct_ccc_is_read = 1'b0;
            endcase
        end
    endfunction

    function [7:0] direct_ccc_rx_len_for;
        input [7:0] code;
        begin
            case (code)
                CCC_GETPID:    direct_ccc_rx_len_for = 8'd6;
                CCC_GETBCR:    direct_ccc_rx_len_for = 8'd1;
                CCC_GETDCR:    direct_ccc_rx_len_for = 8'd1;
                CCC_GETSTATUS: direct_ccc_rx_len_for = 8'd2;
                CCC_GETMWL:    direct_ccc_rx_len_for = 8'd2;
                CCC_GETMRL:    direct_ccc_rx_len_for = 8'd3;
                CCC_GETMXDS:   direct_ccc_rx_len_for = 8'd2;
                CCC_GETCAPS:   direct_ccc_rx_len_for = 8'd4;
                default:       direct_ccc_rx_len_for = 8'd0;
            endcase
        end
    endfunction

    function [7:0] direct_ccc_tx_len_for;
        input [7:0] code;
        begin
            case (code)
                CCC_ENEC_DIRECT,
                CCC_DISEC_DIRECT,
                CCC_RSTACT: direct_ccc_tx_len_for = 8'd1;
                default:    direct_ccc_tx_len_for = 8'd0;
            endcase
        end
    endfunction

    function broadcast_ccc_is_supported;
        input [7:0] code;
        begin
            case (code)
                default:         broadcast_ccc_is_supported = 1'b0;
            endcase
        end
    endfunction

    function [7:0] broadcast_ccc_tx_len_for;
        input [7:0] code;
        begin
            case (code)
                CCC_ENEC_BCAST,
                CCC_DISEC_BCAST: broadcast_ccc_tx_len_for = 8'd2;
                default:         broadcast_ccc_tx_len_for = 8'd0;
            endcase
        end
    endfunction

    wire [15:0] dccc_status_word = decode_status_word(dccc_rsp_rdata[15:0]);

    assign host_cmd_ready = (state == ST_RUN_IDLE);
    assign host_ccc_ready = (state == ST_RUN_IDLE);
    assign scl_o  = dccc_bus_owner ? dccc_scl_o  : txn_scl_o;
    assign scl_oe = dccc_bus_owner ? dccc_scl_oe : txn_scl_oe;
    assign sda_o  = dccc_bus_owner ? dccc_sda_o  : txn_sda_o;
    assign sda_oe = dccc_bus_owner ? dccc_sda_oe : txn_sda_oe;

    i3c_ctrl_direct_ccc #(
        .CLK_FREQ_HZ   (CLK_FREQ_HZ),
        .I3C_SDR_HZ    (I3C_SDR_HZ),
        .PUSH_PULL_DATA(1),
        .MAX_TX_BYTES  (PID_BYTES),
        .MAX_RX_BYTES  (PID_BYTES)
    ) u_direct_ccc (
        .clk         (clk),
        .rst_n       (rst_n),
        .cmd_valid   (dccc_cmd_valid),
        .cmd_ready   (dccc_cmd_ready),
        .ccc_code    (dccc_ccc_code),
        .target_addr (dccc_target_addr),
        .target_read (dccc_target_read),
        .tx_len      (dccc_tx_len),
        .rx_len      (dccc_rx_len),
        .tx_data     (dccc_tx_data),
        .rsp_valid   (dccc_rsp_valid),
        .rsp_nack    (dccc_rsp_nack),
        .rsp_rx_count(dccc_rsp_rx_count),
        .rsp_rdata   (dccc_rsp_rdata),
        .busy           (dccc_busy),
        .dbg_nack_seen  (dbg_nack_seen),
        .scl_o       (dccc_scl_o),
        .scl_oe      (dccc_scl_oe),
        .sda_o       (dccc_sda_o),
        .sda_oe      (dccc_sda_oe),
        .sda_i       (sda_i)
    );

    i3c_ctrl_ccc #(
        .MAX_TX_BYTES(MAX_SERVICE_BYTES)
    ) u_broadcast_ccc (
        .clk          (clk),
        .rst_n        (rst_n),
        .ccc_valid    (ccc_valid),
        .ccc_ready    (ccc_ready),
        .ccc_code     (ccc_code),
        .ccc_data_len (ccc_data_len),
        .ccc_data     (ccc_data),
        .ccc_done     (ccc_done),
        .ccc_nack     (ccc_nack),
        .txn_req_valid(ccc_txn_req_valid),
        .txn_req_ready(ccc_txn_req_ready),
        .txn_req_addr (ccc_txn_req_addr),
        .txn_req_read (ccc_txn_req_read),
        .txn_req_tx_len(ccc_txn_req_tx_len),
        .txn_req_rx_len(ccc_txn_req_rx_len),
        .txn_req_wdata(ccc_txn_req_wdata),
        .txn_rsp_valid(txn_rsp_valid),
        .txn_rsp_nack (txn_rsp_nack)
    );

    i3c_ctrl_txn_layer #(
        .CLK_FREQ_HZ   (CLK_FREQ_HZ),
        .I3C_SDR_HZ    (I3C_SDR_HZ),
        .PUSH_PULL_DATA(1),
        .MAX_TX_BYTES  (MAX_SERVICE_BYTES),
        .MAX_RX_BYTES  (MAX_SERVICE_BYTES)
    ) u_txn (
        .clk             (clk),
        .rst_n           (rst_n),
        .txn_req_valid   (txn_req_valid | ccc_txn_req_valid),
        .txn_req_ready   (txn_req_ready),
        .txn_req_addr    (ccc_txn_req_valid ? ccc_txn_req_addr : txn_req_addr),
        .txn_req_read    (ccc_txn_req_valid ? ccc_txn_req_read : txn_req_read),
        .txn_req_tx_len  (ccc_txn_req_valid ? ccc_txn_req_tx_len : txn_req_tx_len),
        .txn_req_rx_len  (ccc_txn_req_valid ? ccc_txn_req_rx_len : txn_req_rx_len),
        .txn_req_wdata   (ccc_txn_req_valid ? ccc_txn_req_wdata : txn_req_wdata),
        .txn_rsp_valid   (txn_rsp_valid),
        .txn_rsp_nack    (txn_rsp_nack),
        .txn_rsp_rx_count(txn_rsp_rx_count),
        .txn_rsp_rdata   (txn_rsp_rdata),
        .busy            (txn_busy),
        .scl_o           (txn_scl_o),
        .scl_oe          (txn_scl_oe),
        .sda_o           (txn_sda_o),
        .sda_oe          (txn_sda_oe),
        .sda_i           (sda_i)
    );

    assign ccc_txn_req_ready = txn_req_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                     <= ST_BOOT_SETDASA_REQ;
            boot_index                <= 1'b0;
            sched_index               <= 1'b0;
            active_target             <= 1'b0;
            pending_host_target       <= 1'b0;
            pending_ccc_target        <= 1'b0;
            pending_ccc_direct        <= 1'b0;
            pending_host_reg_addr     <= 8'h00;
            pending_host_write_value  <= 8'h00;
            pending_host_read_len     <= 8'h00;
            pending_ccc_code          <= 8'h00;
            pending_ccc_arg           <= 8'h00;
            recovery_retry_op         <= OP_NONE;
            schedule_div_cnt          <= {SCHEDULE_DIV_W{1'b0}};
            txn_req_valid             <= 1'b0;
            txn_req_addr              <= 7'h00;
            txn_req_read              <= 1'b0;
            txn_req_tx_len            <= 8'h00;
            txn_req_rx_len            <= 8'h00;
            txn_req_wdata             <= {8*MAX_SERVICE_BYTES{1'b0}};
            ccc_valid                 <= 1'b0;
            ccc_code                  <= 8'h00;
            ccc_data_len              <= 8'h00;
            ccc_data                  <= {(8*(MAX_SERVICE_BYTES-1)){1'b0}};
            dccc_cmd_valid            <= 1'b0;
            dccc_ccc_code             <= 8'h00;
            dccc_target_addr          <= 7'h00;
            dccc_target_read          <= 1'b0;
            dccc_tx_len               <= 8'h00;
            dccc_rx_len               <= 8'h00;
            dccc_tx_data              <= 48'h0;
            host_rsp_valid            <= 1'b0;
            host_rsp_error            <= 1'b0;
            host_rsp_len              <= 8'h00;
            host_rsp_data             <= {8*MAX_SERVICE_BYTES{1'b0}};
            host_ccc_rsp_valid        <= 1'b0;
            host_ccc_rsp_error        <= 1'b0;
            host_ccc_rsp_len          <= 8'h00;
            host_ccc_rsp_data         <= 48'h0;
            boot_done                 <= 1'b0;
            boot_error                <= 1'b0;
            capture_error             <= 1'b0;
            recovery_active           <= 1'b0;
            verified_bitmap           <= {ENDPOINT_COUNT{1'b0}};
            sample_valid_bitmap       <= {ENDPOINT_COUNT{1'b0}};
            target_led_state          <= {ENDPOINT_COUNT{1'b0}};
            signature_flat            <= {ENDPOINT_COUNT*32{1'b0}};
            sample_payloads_flat      <= {ENDPOINT_COUNT*PAYLOAD_BYTES*8{1'b0}};
            sample_capture_count_flat <= {ENDPOINT_COUNT*16{1'b0}};
            status_word_flat          <= {ENDPOINT_COUNT*16{1'b0}};
            last_service_addr         <= 7'h00;
            last_recovery_addr        <= 7'h00;
        end else begin
            txn_req_valid  <= 1'b0;
            ccc_valid      <= 1'b0;
            dccc_cmd_valid <= 1'b0;
            host_rsp_valid <= 1'b0;
            host_ccc_rsp_valid <= 1'b0;
            recovery_active <= (state >= ST_RECOVER_GETSTATUS_REQ) && (state <= ST_RECOVER_RECHECK_WAIT);

            if (schedule_tick)
                schedule_div_cnt <= {SCHEDULE_DIV_W{1'b0}};
            else
                schedule_div_cnt <= schedule_div_cnt + 1'b1;

            case (state)
                ST_BOOT_SETDASA_REQ: begin
                    if (dccc_cmd_ready) begin
                        dccc_cmd_valid   <= 1'b1;
                        dccc_ccc_code    <= CCC_SETDASA;
                        dccc_target_addr <= endpoint_static_addr(boot_index);
                        dccc_target_read <= 1'b0;
                        dccc_tx_len      <= 8'd1;
                        dccc_rx_len      <= 8'd0;
                        dccc_tx_data     <= {40'h0, endpoint_dynamic_addr(boot_index), 1'b0};
                        state            <= ST_BOOT_SETDASA_WAIT;
                    end
                end

                ST_BOOT_SETDASA_WAIT: begin
                    if (dccc_rsp_valid) begin
                        if (dccc_rsp_nack) begin
                            boot_error <= 1'b1;
                            state      <= ST_ERROR;
                        end else begin
                            state <= ST_BOOT_GETPID_REQ;
                        end
                    end
                end

                ST_BOOT_GETPID_REQ: begin
                    if (dccc_cmd_ready) begin
                        dccc_cmd_valid   <= 1'b1;
                        dccc_ccc_code    <= CCC_GETPID;
                        dccc_target_addr <= endpoint_dynamic_addr(boot_index);
                        dccc_target_read <= 1'b1;
                        dccc_tx_len      <= 8'd0;
                        dccc_rx_len      <= PID_BYTES;
                        dccc_tx_data     <= 48'h0;
                        state            <= ST_BOOT_GETPID_WAIT;
                    end
                end

                ST_BOOT_GETPID_WAIT: begin
                    if (dccc_rsp_valid) begin
                        if (dccc_rsp_nack ||
                            (dccc_rsp_rx_count != PID_BYTES) ||
                            (dccc_rsp_rdata != direct_pid_value(endpoint_pid(boot_index)))) begin
                            boot_error <= 1'b1;
                            state      <= ST_ERROR;
                        end else begin
                            state <= ST_BOOT_GETBCR_REQ;
                        end
                    end
                end

                ST_BOOT_GETBCR_REQ: begin
                    if (dccc_cmd_ready) begin
                        dccc_cmd_valid   <= 1'b1;
                        dccc_ccc_code    <= CCC_GETBCR;
                        dccc_target_addr <= endpoint_dynamic_addr(boot_index);
                        dccc_target_read <= 1'b1;
                        dccc_tx_len      <= 8'd0;
                        dccc_rx_len      <= 8'd1;
                        dccc_tx_data     <= 48'h0;
                        state            <= ST_BOOT_GETBCR_WAIT;
                    end
                end

                ST_BOOT_GETBCR_WAIT: begin
                    if (dccc_rsp_valid) begin
                        if (dccc_rsp_nack || (dccc_rsp_rx_count != 8'd1) || (dccc_rsp_rdata[7:0] != TARGET_BCR)) begin
                            boot_error <= 1'b1;
                            state      <= ST_ERROR;
                        end else begin
                            state <= ST_BOOT_GETDCR_REQ;
                        end
                    end
                end

                ST_BOOT_GETDCR_REQ: begin
                    if (dccc_cmd_ready) begin
                        dccc_cmd_valid   <= 1'b1;
                        dccc_ccc_code    <= CCC_GETDCR;
                        dccc_target_addr <= endpoint_dynamic_addr(boot_index);
                        dccc_target_read <= 1'b1;
                        dccc_tx_len      <= 8'd0;
                        dccc_rx_len      <= 8'd1;
                        dccc_tx_data     <= 48'h0;
                        state            <= ST_BOOT_GETDCR_WAIT;
                    end
                end

                ST_BOOT_GETDCR_WAIT: begin
                    if (dccc_rsp_valid) begin
                        if (dccc_rsp_nack || (dccc_rsp_rx_count != 8'd1) || (dccc_rsp_rdata[7:0] != TARGET_DCR)) begin
                            boot_error <= 1'b1;
                            state      <= ST_ERROR;
                        end else begin
                            state <= ST_BOOT_GETSTATUS_REQ;
                        end
                    end
                end

                ST_BOOT_GETSTATUS_REQ: begin
                    if (dccc_cmd_ready) begin
                        dccc_cmd_valid   <= 1'b1;
                        dccc_ccc_code    <= CCC_GETSTATUS;
                        dccc_target_addr <= endpoint_dynamic_addr(boot_index);
                        dccc_target_read <= 1'b1;
                        dccc_tx_len      <= 8'd0;
                        dccc_rx_len      <= STATUS_BYTES;
                        dccc_tx_data     <= 48'h0;
                        state            <= ST_BOOT_GETSTATUS_WAIT;
                    end
                end

                ST_BOOT_GETSTATUS_WAIT: begin
                    if (dccc_rsp_valid) begin
                        status_word_flat[boot_index*16 +: 16] <= dccc_status_word;
                        if (dccc_rsp_nack || (dccc_rsp_rx_count != STATUS_BYTES) || !dccc_status_word[0]) begin
                            boot_error <= 1'b1;
                            state      <= ST_ERROR;
                        end else begin
                            state <= ST_BOOT_RSTACT_REQ;
                        end
                    end
                end

                ST_BOOT_RSTACT_REQ: begin
                    if (dccc_cmd_ready) begin
                        dccc_cmd_valid   <= 1'b1;
                        dccc_ccc_code    <= CCC_RSTACT;
                        dccc_target_addr <= endpoint_dynamic_addr(boot_index);
                        dccc_target_read <= 1'b0;
                        dccc_tx_len      <= 8'd1;
                        dccc_rx_len      <= 8'd0;
                        dccc_tx_data     <= {40'h0, RECOVERY_RSTACT_ACTION};
                        state            <= ST_BOOT_RSTACT_WAIT;
                    end
                end

                ST_BOOT_RSTACT_WAIT: begin
                    if (dccc_rsp_valid) begin
                        if (dccc_rsp_nack) begin
                            boot_error <= 1'b1;
                            state      <= ST_ERROR;
                        end else begin
                            state <= ST_BOOT_SIG_SEL_REQ;
                        end
                    end
                end

                ST_BOOT_SIG_SEL_REQ: begin
                    if (txn_req_ready) begin
                        txn_req_valid         <= 1'b1;
                        txn_req_addr          <= endpoint_dynamic_addr(boot_index);
                        txn_req_read          <= 1'b0;
                        txn_req_tx_len        <= 8'd1;
                        txn_req_rx_len        <= 8'd0;
                        txn_req_wdata         <= { {(8*(MAX_SERVICE_BYTES-1)){1'b0}}, 8'h00 };
                        state                 <= ST_BOOT_SIG_SEL_WAIT;
                    end
                end

                ST_BOOT_SIG_SEL_WAIT: begin
                    if (txn_rsp_valid) begin
                        if (txn_rsp_nack) begin
                            boot_error <= 1'b1;
                            state      <= ST_ERROR;
                        end else begin
                            state <= ST_BOOT_SIG_RD_REQ;
                        end
                    end
                end

                ST_BOOT_SIG_RD_REQ: begin
                    if (txn_req_ready) begin
                        txn_req_valid   <= 1'b1;
                        txn_req_addr    <= endpoint_dynamic_addr(boot_index);
                        txn_req_read    <= 1'b1;
                        txn_req_tx_len  <= 8'd0;
                        txn_req_rx_len  <= SIGNATURE_BYTES;
                        txn_req_wdata   <= {8*MAX_SERVICE_BYTES{1'b0}};
                        state           <= ST_BOOT_SIG_RD_WAIT;
                    end
                end

                ST_BOOT_SIG_RD_WAIT: begin
                    if (txn_rsp_valid) begin
                        if (txn_rsp_nack ||
                            (txn_rsp_rx_count != SIGNATURE_BYTES) ||
                            (txn_rsp_rdata[31:0] != endpoint_signature(boot_index))) begin
                            boot_error <= 1'b1;
                            state      <= ST_ERROR;
                        end else begin
                            signature_flat[boot_index*32 +: 32] <= txn_rsp_rdata[31:0];
                            verified_bitmap[boot_index]         <= 1'b1;
                            state                               <= ST_BOOT_NEXT;
                        end
                    end
                end

                ST_BOOT_NEXT: begin
                    if (boot_index == ENDPOINT_COUNT - 1) begin
                        boot_done <= 1'b1;
                        state     <= ST_RUN_IDLE;
                    end else begin
                        boot_index <= boot_index + 1'b1;
                        state      <= ST_BOOT_SETDASA_REQ;
                    end
                end

                ST_RUN_IDLE: begin
                    if (host_ccc_valid) begin
                        pending_ccc_target <= host_ccc_target;
                        pending_ccc_direct <= host_ccc_direct;
                        pending_ccc_code   <= host_ccc_code;
                        pending_ccc_arg    <= host_ccc_arg;
                        if (host_ccc_direct && direct_ccc_is_supported(host_ccc_code)) begin
                            active_target <= host_ccc_target;
                            state         <= ST_RUN_HOST_DCCC_REQ;
                        end else if (!host_ccc_direct && broadcast_ccc_is_supported(host_ccc_code)) begin
                            state <= ST_RUN_HOST_BCCC_REQ;
                        end else begin
                            host_ccc_rsp_valid <= 1'b1;
                            host_ccc_rsp_error <= 1'b1;
                            host_ccc_rsp_len   <= 8'd0;
                            host_ccc_rsp_data  <= 48'h0;
                        end
                    end else if (host_cmd_valid) begin
                        active_target            <= host_cmd_target;
                        pending_host_target      <= host_cmd_target;
                        pending_host_reg_addr    <= host_cmd_reg_addr;
                        pending_host_write_value <= host_cmd_write_value;
                        pending_host_read_len    <= (host_cmd_read_len == 0) ? 8'd1 : host_cmd_read_len;
                        recovery_retry_op        <= host_cmd_read ? OP_HOST_READ : OP_HOST_WRITE;
                        if (host_cmd_read) begin
                            state <= ST_RUN_HOST_SEL_REQ;
                        end else begin
                            state <= ST_RUN_HOST_WR_REQ;
                        end
                    end else if (schedule_tick) begin
                        active_target     <= sched_index;
                        recovery_retry_op <= OP_SCHEDULE_READ;
                        state             <= ST_RUN_SCHED_SEL_REQ;
                    end
                end

                ST_RUN_HOST_DCCC_REQ: begin
                    if (dccc_cmd_ready) begin
                        dccc_cmd_valid   <= 1'b1;
                        dccc_ccc_code    <= pending_ccc_code;
                        dccc_target_addr <= endpoint_dynamic_addr(active_target);
                        dccc_target_read <= direct_ccc_is_read(pending_ccc_code);
                        dccc_tx_len      <= direct_ccc_tx_len_for(pending_ccc_code);
                        dccc_rx_len      <= direct_ccc_rx_len_for(pending_ccc_code);
                        dccc_tx_data     <= {40'h0, pending_ccc_arg};
                        state            <= ST_RUN_HOST_DCCC_WAIT;
                    end
                end

                ST_RUN_HOST_DCCC_WAIT: begin
                    if (dccc_rsp_valid) begin
                        host_ccc_rsp_valid <= 1'b1;
                        host_ccc_rsp_error <= dccc_rsp_nack;
                        host_ccc_rsp_len   <= dccc_rsp_nack ? 8'd0 : dccc_rsp_rx_count;
                        host_ccc_rsp_data  <= dccc_rsp_rdata;
                        if (!dccc_rsp_nack && (pending_ccc_code == CCC_GETSTATUS) &&
                            (dccc_rsp_rx_count == STATUS_BYTES)) begin
                            status_word_flat[active_target*16 +: 16] <= dccc_status_word;
                        end
                        state <= ST_RUN_IDLE;
                    end
                end

                ST_RUN_HOST_BCCC_REQ: begin
                    if (ccc_ready) begin
                        ccc_valid    <= 1'b1;
                        ccc_code     <= pending_ccc_code;
                        ccc_data_len <= broadcast_ccc_tx_len_for(pending_ccc_code) - 1'b1;
                        ccc_data     <= { {(8*(MAX_SERVICE_BYTES-2)){1'b0}}, pending_ccc_arg };
                        state        <= ST_RUN_HOST_BCCC_WAIT;
                    end
                end

                ST_RUN_HOST_BCCC_WAIT: begin
                    if (ccc_done) begin
                        host_ccc_rsp_valid <= 1'b1;
                        host_ccc_rsp_error <= ccc_nack;
                        host_ccc_rsp_len   <= 8'd0;
                        host_ccc_rsp_data  <= 48'h0;
                        state              <= ST_RUN_IDLE;
                    end
                end

                ST_RUN_SCHED_SEL_REQ: begin
                    if (txn_req_ready) begin
                        txn_req_valid <= 1'b1;
                        txn_req_addr  <= endpoint_dynamic_addr(active_target);
                        txn_req_read  <= 1'b0;
                        txn_req_tx_len <= 8'd1;
                        txn_req_rx_len <= 8'd0;
                        txn_req_wdata  <= {{(8*(MAX_SERVICE_BYTES-1)){1'b0}}, SAMPLE_SELECTOR};
                        state          <= ST_RUN_SCHED_SEL_WAIT;
                    end
                end

                ST_RUN_SCHED_SEL_WAIT: begin
                    if (txn_rsp_valid) begin
                        if (txn_rsp_nack) begin
                            last_recovery_addr <= endpoint_dynamic_addr(active_target);
                            state              <= ST_RECOVER_GETSTATUS_REQ;
                        end else begin
                            state <= ST_RUN_SCHED_RD_REQ;
                        end
                    end
                end

                ST_RUN_SCHED_RD_REQ: begin
                    if (txn_req_ready) begin
                        txn_req_valid <= 1'b1;
                        txn_req_addr  <= endpoint_dynamic_addr(active_target);
                        txn_req_read  <= 1'b1;
                        txn_req_tx_len <= 8'd0;
                        txn_req_rx_len <= PAYLOAD_BYTES;
                        txn_req_wdata  <= {8*MAX_SERVICE_BYTES{1'b0}};
                        state          <= ST_RUN_SCHED_RD_WAIT;
                    end
                end

                ST_RUN_SCHED_RD_WAIT: begin
                    if (txn_rsp_valid) begin
                        last_service_addr <= endpoint_dynamic_addr(active_target);
                        if (txn_rsp_nack || (txn_rsp_rx_count != PAYLOAD_BYTES)) begin
                            capture_error      <= 1'b1;
                            last_recovery_addr <= endpoint_dynamic_addr(active_target);
                            state              <= ST_RECOVER_GETSTATUS_REQ;
                        end else begin
                            sample_valid_bitmap[active_target] <= 1'b1;
                            sample_payloads_flat[active_target*PAYLOAD_BYTES*8 +: PAYLOAD_BYTES*8] <=
                                txn_rsp_rdata[PAYLOAD_BYTES*8-1:0];
                            sample_capture_count_flat[active_target*16 +: 16] <=
                                sample_capture_count_flat[active_target*16 +: 16] + 1'b1;
                            sched_index <= ~sched_index;
                            state       <= ST_RUN_IDLE;
                        end
                    end
                end

                ST_RUN_HOST_SEL_REQ: begin
                    if (txn_req_ready) begin
                        txn_req_valid <= 1'b1;
                        txn_req_addr  <= endpoint_dynamic_addr(active_target);
                        txn_req_read  <= 1'b0;
                        txn_req_tx_len <= 8'd1;
                        txn_req_rx_len <= 8'd0;
                        txn_req_wdata  <= {{(8*(MAX_SERVICE_BYTES-1)){1'b0}}, pending_host_reg_addr};
                        state          <= ST_RUN_HOST_SEL_WAIT;
                    end
                end

                ST_RUN_HOST_SEL_WAIT: begin
                    if (txn_rsp_valid) begin
                        if (txn_rsp_nack) begin
                            last_recovery_addr <= endpoint_dynamic_addr(active_target);
                            state              <= ST_RECOVER_GETSTATUS_REQ;
                        end else begin
                            state <= ST_RUN_HOST_RD_REQ;
                        end
                    end
                end

                ST_RUN_HOST_RD_REQ: begin
                    if (txn_req_ready) begin
                        txn_req_valid <= 1'b1;
                        txn_req_addr  <= endpoint_dynamic_addr(active_target);
                        txn_req_read  <= 1'b1;
                        txn_req_tx_len <= 8'd0;
                        txn_req_rx_len <= pending_host_read_len;
                        txn_req_wdata  <= {8*MAX_SERVICE_BYTES{1'b0}};
                        state          <= ST_RUN_HOST_RD_WAIT;
                    end
                end

                ST_RUN_HOST_RD_WAIT: begin
                    if (txn_rsp_valid) begin
                        if (txn_rsp_nack) begin
                            last_recovery_addr <= endpoint_dynamic_addr(active_target);
                            state              <= ST_RECOVER_GETSTATUS_REQ;
                        end else begin
                            host_rsp_valid <= 1'b1;
                            host_rsp_error <= 1'b0;
                            host_rsp_len   <= txn_rsp_rx_count;
                            host_rsp_data  <= txn_rsp_rdata;
                            state          <= ST_RUN_IDLE;
                        end
                    end
                end

                ST_RUN_HOST_WR_REQ: begin
                    if (txn_req_ready) begin
                        txn_req_valid <= 1'b1;
                        txn_req_addr  <= endpoint_dynamic_addr(active_target);
                        txn_req_read  <= 1'b0;
                        txn_req_tx_len <= 8'd2;
                        txn_req_rx_len <= 8'd0;
                        txn_req_wdata  <= {{(8*(MAX_SERVICE_BYTES-2)){1'b0}}, pending_host_write_value, pending_host_reg_addr};
                        state          <= ST_RUN_HOST_WR_WAIT;
                    end
                end

                ST_RUN_HOST_WR_WAIT: begin
                    if (txn_rsp_valid) begin
                        if (txn_rsp_nack) begin
                            last_recovery_addr <= endpoint_dynamic_addr(active_target);
                            state              <= ST_RECOVER_GETSTATUS_REQ;
                        end else begin
                            if (pending_host_reg_addr == CONTROL_SELECTOR)
                                target_led_state[active_target] <= pending_host_write_value[0];
                            host_rsp_valid <= 1'b1;
                            host_rsp_error <= 1'b0;
                            host_rsp_len   <= 8'd1;
                            host_rsp_data  <= {{(8*(MAX_SERVICE_BYTES-1)){1'b0}}, pending_host_write_value};
                            state          <= ST_RUN_IDLE;
                        end
                    end
                end

                ST_RECOVER_GETSTATUS_REQ: begin
                    if (dccc_cmd_ready) begin
                        dccc_cmd_valid   <= 1'b1;
                        dccc_ccc_code    <= CCC_GETSTATUS;
                        dccc_target_addr <= endpoint_dynamic_addr(active_target);
                        dccc_target_read <= 1'b1;
                        dccc_tx_len      <= 8'd0;
                        dccc_rx_len      <= STATUS_BYTES;
                        dccc_tx_data     <= 48'h0;
                        state            <= ST_RECOVER_GETSTATUS_WAIT;
                    end
                end

                ST_RECOVER_GETSTATUS_WAIT: begin
                    if (dccc_rsp_valid) begin
                        if (!dccc_rsp_nack && (dccc_rsp_rx_count == STATUS_BYTES))
                            status_word_flat[active_target*16 +: 16] <= dccc_status_word;

                        if (dccc_rsp_nack || (dccc_rsp_rx_count != STATUS_BYTES) || !dccc_status_word[0]) begin
                            state <= ST_RECOVER_SETDASA_REQ;
                        end else begin
                            if (recovery_retry_op == OP_HOST_READ) begin
                                state <= ST_RUN_HOST_SEL_REQ;
                            end else if (recovery_retry_op == OP_HOST_WRITE) begin
                                state <= ST_RUN_HOST_WR_REQ;
                            end else begin
                                sched_index <= ~active_target;
                                state       <= ST_RUN_IDLE;
                            end
                        end
                    end
                end

                ST_RECOVER_SETDASA_REQ: begin
                    if (dccc_cmd_ready) begin
                        dccc_cmd_valid   <= 1'b1;
                        dccc_ccc_code    <= CCC_SETDASA;
                        dccc_target_addr <= endpoint_static_addr(active_target);
                        dccc_target_read <= 1'b0;
                        dccc_tx_len      <= 8'd1;
                        dccc_rx_len      <= 8'd0;
                        dccc_tx_data     <= {40'h0, endpoint_dynamic_addr(active_target), 1'b0};
                        state            <= ST_RECOVER_SETDASA_WAIT;
                    end
                end

                ST_RECOVER_SETDASA_WAIT: begin
                    if (dccc_rsp_valid) begin
                        if (dccc_rsp_nack) begin
                            capture_error <= 1'b1;
                            host_rsp_valid <= (recovery_retry_op != OP_SCHEDULE_READ);
                            host_rsp_error <= (recovery_retry_op != OP_SCHEDULE_READ);
                            host_rsp_len   <= 8'd0;
                            state          <= ST_RUN_IDLE;
                        end else begin
                            state <= ST_RECOVER_RECHECK_REQ;
                        end
                    end
                end

                ST_RECOVER_RECHECK_REQ: begin
                    if (dccc_cmd_ready) begin
                        dccc_cmd_valid   <= 1'b1;
                        dccc_ccc_code    <= CCC_GETSTATUS;
                        dccc_target_addr <= endpoint_dynamic_addr(active_target);
                        dccc_target_read <= 1'b1;
                        dccc_tx_len      <= 8'd0;
                        dccc_rx_len      <= STATUS_BYTES;
                        dccc_tx_data     <= 48'h0;
                        state            <= ST_RECOVER_RECHECK_WAIT;
                    end
                end

                ST_RECOVER_RECHECK_WAIT: begin
                    if (dccc_rsp_valid) begin
                        if (!dccc_rsp_nack && (dccc_rsp_rx_count == STATUS_BYTES))
                            status_word_flat[active_target*16 +: 16] <= dccc_status_word;

                        if (dccc_rsp_nack || (dccc_rsp_rx_count != STATUS_BYTES) || !dccc_status_word[0]) begin
                            capture_error  <= 1'b1;
                            host_rsp_valid <= (recovery_retry_op != OP_SCHEDULE_READ);
                            host_rsp_error <= (recovery_retry_op != OP_SCHEDULE_READ);
                            host_rsp_len   <= 8'd0;
                            state          <= ST_RUN_IDLE;
                        end else begin
                            if (recovery_retry_op == OP_HOST_READ) begin
                                state <= ST_RUN_HOST_SEL_REQ;
                            end else if (recovery_retry_op == OP_HOST_WRITE) begin
                                state <= ST_RUN_HOST_WR_REQ;
                            end else begin
                                sched_index <= ~active_target;
                                state       <= ST_RUN_IDLE;
                            end
                        end
                    end
                end

                ST_ERROR: begin
                    boot_error <= 1'b1;
                end

                default: begin
                    state <= ST_ERROR;
                end
            endcase
        end
    end

endmodule
