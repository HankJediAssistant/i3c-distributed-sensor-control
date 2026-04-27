`timescale 1ns/1ps

module i3c_target_ccc #(
    parameter [6:0]  CCC_ADDR     = 7'h7E,
    parameter [6:0]  STATIC_ADDR  = 7'h2A,
    parameter [7:0]  CCC_ENEC_BCAST = 8'h00,
    parameter [7:0]  CCC_DISEC_BCAST= 8'h01,
    parameter [7:0]  CCC_RSTDAA   = 8'h06,
    parameter [7:0]  CCC_ENTDAA   = 8'h07,
    parameter [7:0]  CCC_ENTAS0_BCAST = 8'h02,
    parameter [7:0]  CCC_ENTAS1_BCAST = 8'h03,
    parameter [7:0]  CCC_ENTAS2_BCAST = 8'h04,
    parameter [7:0]  CCC_ENTAS3_BCAST = 8'h05,
    parameter [7:0]  CCC_SETMWL_BCAST = 8'h09,
    parameter [7:0]  CCC_SETMRL_BCAST = 8'h0A,
    parameter [7:0]  CCC_SETAASA  = 8'h2A,
    parameter [7:0]  CCC_RSTGRPA_BCAST = 8'h2C,
    parameter [7:0]  CCC_DEFGRPA_BCAST = 8'h2B,
    parameter [7:0]  CCC_ENEC_DIRECT = 8'h80,
    parameter [7:0]  CCC_DISEC_DIRECT= 8'h81,
    parameter [7:0]  CCC_ENTAS0_DIRECT = 8'h82,
    parameter [7:0]  CCC_ENTAS1_DIRECT = 8'h83,
    parameter [7:0]  CCC_ENTAS2_DIRECT = 8'h84,
    parameter [7:0]  CCC_ENTAS3_DIRECT = 8'h85,
    parameter [7:0]  CCC_SETMWL_DIRECT = 8'h89,
    parameter [7:0]  CCC_SETMRL_DIRECT = 8'h8A,
    parameter [7:0]  CCC_GETMWL   = 8'h8B,
    parameter [7:0]  CCC_GETMRL   = 8'h8C,
    parameter [7:0]  CCC_GETPID   = 8'h8D,
    parameter [7:0]  CCC_GETBCR   = 8'h8E,
    parameter [7:0]  CCC_GETDCR   = 8'h8F,
    parameter [7:0]  CCC_GETSTATUS= 8'h90,
    parameter [7:0]  CCC_GETMXDS  = 8'h94,
    parameter [7:0]  CCC_GETCAPS  = 8'h95,
    parameter [7:0]  CCC_SETDASA  = 8'h87,
    parameter [7:0]  CCC_SETNEWDA = 8'h88,
    parameter [7:0]  CCC_SETGRPA_DIRECT = 8'h9B,
    parameter [7:0]  CCC_RSTGRPA_DIRECT = 8'h9C,
    parameter [7:0]  CCC_RSTACT_DIRECT = 8'h9A,
    parameter [7:0]  TARGET_BCR   = 8'h01,
    parameter [7:0]  TARGET_DCR   = 8'h5A,
    parameter [15:0] TARGET_MAX_WRITE_LEN = 16'h0010,
    parameter [15:0] TARGET_MAX_READ_LEN  = 16'h0010,
    parameter [7:0]  TARGET_IBI_DATA_LEN  = 8'h00,
    parameter [15:0] TARGET_MXDS          = 16'h0860,
    parameter [31:0] TARGET_CAPS          = 32'h0000_0000,
    // When 1, target drives direct-CCC read-data bits push-pull
    // (GETPID / GETBCR / GETDCR / GETSTATUS / GETMWL / GETMRL / GETMXDS / GETCAPS).
    // ENTDAA response bits remain open-drain unconditionally — arbitration phase
    // requires multiple targets to wire-AND their PIDs bit-by-bit.
    parameter integer USE_PUSH_PULL = 0
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       scl,
    input  wire       sda,
    output wire       sda_drive_en,
    output wire       sda_o,
    input  wire [6:0] active_addr,
    input  wire       dynamic_addr_valid,
    input  wire [47:0] provisional_id,

    output reg        rstdaa_pulse,
    output reg        setaasa_pulse,
    output reg        setdasa_valid,
    output reg [6:0]  setdasa_addr,
    output reg        setnewda_valid,
    output reg [6:0]  setnewda_addr,
    output reg        entdaa_assign_valid,
    output reg [6:0]  entdaa_assign_addr,
    output reg        transport_holdoff,
    output reg [7:0]  event_enable_mask,
    output reg [7:0]  rstact_action,
    output reg [15:0] status_word,
    output reg [1:0]  activity_state,
    output reg        group_addr_valid,
    output reg [6:0]  group_addr,
    output wire [15:0] max_write_len,
    output wire [15:0] max_read_len,
    output wire [7:0]  ibi_data_len,
    output reg        ccc_seen,
    output reg [7:0]  last_ccc
);

    localparam [2:0] ST_IDLE     = 3'd0;
    localparam [2:0] ST_ADDR     = 3'd1;
    localparam [2:0] ST_ACK      = 3'd2;
    localparam [2:0] ST_DATA     = 3'd3;
    localparam [2:0] ST_READ     = 3'd4;
    localparam [2:0] ST_WAIT_STOP= 3'd5;

    localparam [2:0] ACK_NONE          = 3'd0;
    localparam [2:0] ACK_CCC_ADDR      = 3'd1;
    localparam [2:0] ACK_CCC_CODE      = 3'd2;
    localparam [2:0] ACK_DIRECT_ADDR   = 3'd3;
    localparam [2:0] ACK_DIRECT_DATA   = 3'd4;
    localparam [2:0] ACK_ENTDAA_ADDR   = 3'd5;
    localparam [2:0] ACK_ENTDAA_ASSIGN = 3'd6;
    localparam [2:0] ACK_BCAST_DATA    = 3'd7;

    localparam [3:0] READ_NONE      = 4'd0;
    localparam [3:0] READ_GETPID    = 4'd1;
    localparam [3:0] READ_ENTDAA    = 4'd2;
    localparam [3:0] READ_GETBCR    = 4'd3;
    localparam [3:0] READ_GETDCR    = 4'd4;
    localparam [3:0] READ_GETSTATUS = 4'd5;
    localparam [3:0] READ_GETMWL    = 4'd6;
    localparam [3:0] READ_GETMRL    = 4'd7;
    localparam [3:0] READ_GETMXDS   = 4'd8;
    localparam [3:0] READ_GETCAPS   = 4'd9;

    reg [2:0] state;
    reg [2:0] ack_context;
    reg [3:0] bit_pos;
    reg [7:0] shift_reg;
    reg [7:0] current_ccc;
    reg       ack_pending;
    reg       ack_drive_low;
    reg       sda_drive_low;   // open-drain pull-low (ACK, ENTDAA response, legacy OD reads)
    reg       sda_pp_en;       // push-pull drive enable (direct-CCC read data when USE_PUSH_PULL=1)
    reg       sda_o_reg;       // push-pull data bit
    reg       current_rw;
    reg       current_addr_is_ccc;
    reg       collecting_ccc_code;
    reg       collecting_direct_data;
    reg       collecting_broadcast_data;
    reg       collecting_entdaa_assign;
    reg       pending_direct_ccc;
    reg       pending_broadcast_data;
    reg       pending_entdaa;
    reg       entdaa_lost;
    reg       direct_target_match;
    reg [3:0] read_kind;
    reg [3:0] read_bit_pos;
    reg [3:0] read_byte_idx;
    reg [3:0] read_len;
    reg [7:0] read_shift;
    reg [1:0] data_expected;
    reg [1:0] data_count;
    reg [7:0] data_byte_0;
    reg [7:0] data_byte_1;
    reg [7:0] max_write_len_msb;
    reg [7:0] max_write_len_lsb;
    reg [7:0] max_read_len_msb;
    reg [7:0] max_read_len_lsb;
    reg [7:0] ibi_data_len_r;

    wire [7:0] assembled_byte = {shift_reg[6:0], sda};
    wire       direct_addr_match = ((assembled_byte[7:1] == STATIC_ADDR) ||
                                    (assembled_byte[7:1] == active_addr));
    wire       setdasa_data_valid = (assembled_byte[0] == 1'b0) &&
                                    (assembled_byte[7:1] != 7'h00) &&
                                    (assembled_byte[7:1] != 7'h7E);
    wire       setnewda_data_valid = (assembled_byte[0] == 1'b0) &&
                                     (assembled_byte[7:1] != 7'h00) &&
                                     (assembled_byte[7:1] != 7'h7E);
    wire       group_addr_data_valid = (assembled_byte[0] == 1'b0) &&
                                       (assembled_byte[7:1] != 7'h00) &&
                                       (assembled_byte[7:1] != 7'h7E);
    wire       entdaa_addr_valid = (assembled_byte[0] == 1'b0) &&
                                   (assembled_byte[7:1] != 7'h00) &&
                                   (assembled_byte[7:1] != 7'h7E);

    assign max_write_len = {max_write_len_msb, max_write_len_lsb};
    assign max_read_len  = {max_read_len_msb, max_read_len_lsb};
    assign ibi_data_len  = ibi_data_len_r;

    function [7:0] pid_byte;
        input [47:0] pid;
        input [2:0]  idx;
        begin
            case (idx)
                3'd0: pid_byte = pid[47:40];
                3'd1: pid_byte = pid[39:32];
                3'd2: pid_byte = pid[31:24];
                3'd3: pid_byte = pid[23:16];
                3'd4: pid_byte = pid[15:8];
                default: pid_byte = pid[7:0];
            endcase
        end
    endfunction

    function [7:0] read_byte_value;
        input [3:0]  kind;
        input [3:0]  idx;
        input [47:0] pid;
        begin
            case (kind)
                READ_GETPID: begin
                    read_byte_value = pid_byte(pid, idx[2:0]);
                end
                READ_GETBCR: begin
                    read_byte_value = TARGET_BCR;
                end
                READ_GETDCR: begin
                    read_byte_value = TARGET_DCR;
                end
                READ_GETSTATUS: begin
                    if (idx == 4'd0) begin
                        read_byte_value = status_word[15:8];
                    end else begin
                        read_byte_value = status_word[7:0];
                    end
                end
                READ_GETMWL: begin
                    if (idx == 4'd0) begin
                        read_byte_value = max_write_len_msb;
                    end else begin
                        read_byte_value = max_write_len_lsb;
                    end
                end
                READ_GETMRL: begin
                    case (idx)
                        4'd0: read_byte_value = max_read_len_msb;
                        4'd1: read_byte_value = max_read_len_lsb;
                        default: read_byte_value = ibi_data_len_r;
                    endcase
                end
                READ_GETMXDS: begin
                    if (idx == 4'd0) begin
                        read_byte_value = TARGET_MXDS[15:8];
                    end else begin
                        read_byte_value = TARGET_MXDS[7:0];
                    end
                end
                READ_GETCAPS: begin
                    case (idx)
                        4'd0: read_byte_value = TARGET_CAPS[31:24];
                        4'd1: read_byte_value = TARGET_CAPS[23:16];
                        4'd2: read_byte_value = TARGET_CAPS[15:8];
                        default: read_byte_value = TARGET_CAPS[7:0];
                    endcase
                end
                READ_ENTDAA: begin
                    case (idx)
                        4'd0: read_byte_value = pid_byte(pid, 3'd0);
                        4'd1: read_byte_value = pid_byte(pid, 3'd1);
                        4'd2: read_byte_value = pid_byte(pid, 3'd2);
                        4'd3: read_byte_value = pid_byte(pid, 3'd3);
                        4'd4: read_byte_value = pid_byte(pid, 3'd4);
                        4'd5: read_byte_value = pid_byte(pid, 3'd5);
                        4'd6: read_byte_value = TARGET_BCR;
                        default: read_byte_value = TARGET_DCR;
                    endcase
                end
                default: begin
                    read_byte_value = 8'h00;
                end
            endcase
        end
    endfunction

    function [1:0] entas_state_value;
        input [7:0] code;
        begin
            case (code)
                CCC_ENTAS1_BCAST, CCC_ENTAS1_DIRECT: entas_state_value = 2'd1;
                CCC_ENTAS2_BCAST, CCC_ENTAS2_DIRECT: entas_state_value = 2'd2;
                CCC_ENTAS3_BCAST, CCC_ENTAS3_DIRECT: entas_state_value = 2'd3;
                default: entas_state_value = 2'd0;
            endcase
        end
    endfunction

    assign sda_drive_en = sda_drive_low | sda_pp_en;
    // Gate the data bit by sda_pp_en — see the matching comment in
    // i3c_target_transport.v.  Prevents a stale PP bit from leaking through
    // the OR with the transport submodule during OD ACK windows.
    assign sda_o        = sda_pp_en & sda_o_reg;

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
            state                   <= ST_IDLE;
            ack_context             <= ACK_NONE;
            bit_pos                 <= 4'd0;
            shift_reg               <= 8'h00;
            current_ccc             <= 8'h00;
            ack_pending             <= 1'b0;
            ack_drive_low           <= 1'b0;
            sda_drive_low           <= 1'b0;
            sda_pp_en               <= 1'b0;
            sda_o_reg               <= 1'b0;
            current_rw              <= 1'b0;
            current_addr_is_ccc     <= 1'b0;
            collecting_ccc_code     <= 1'b0;
            collecting_direct_data  <= 1'b0;
            collecting_broadcast_data <= 1'b0;
            collecting_entdaa_assign<= 1'b0;
            pending_direct_ccc      <= 1'b0;
            pending_broadcast_data  <= 1'b0;
            pending_entdaa          <= 1'b0;
            entdaa_lost            <= 1'b0;
            direct_target_match     <= 1'b0;
            read_kind               <= READ_NONE;
            read_bit_pos            <= 4'd0;
            read_byte_idx           <= 4'd0;
            read_len                <= 4'd0;
            read_shift              <= 8'h00;
            data_expected           <= 2'd0;
            data_count              <= 2'd0;
            data_byte_0             <= 8'h00;
            data_byte_1             <= 8'h00;
            transport_holdoff       <= 1'b0;
            event_enable_mask       <= 8'h00;
            rstact_action           <= 8'h00;
            status_word             <= 16'h0000;
            activity_state          <= 2'd0;
            group_addr_valid        <= 1'b0;
            group_addr              <= 7'h00;
            rstdaa_pulse            <= 1'b0;
            setaasa_pulse           <= 1'b0;
            setdasa_valid           <= 1'b0;
            setdasa_addr            <= 7'h00;
            setnewda_valid          <= 1'b0;
            setnewda_addr           <= 7'h00;
            entdaa_assign_valid     <= 1'b0;
            entdaa_assign_addr      <= 7'h00;
            ccc_seen                <= 1'b0;
            last_ccc                <= 8'h00;
            max_write_len_msb       <= TARGET_MAX_WRITE_LEN[15:8];
            max_write_len_lsb       <= TARGET_MAX_WRITE_LEN[7:0];
            max_read_len_msb        <= TARGET_MAX_READ_LEN[15:8];
            max_read_len_lsb        <= TARGET_MAX_READ_LEN[7:0];
            ibi_data_len_r          <= TARGET_IBI_DATA_LEN;
        end else begin
            // Clear single-cycle pulses every cycle
            rstdaa_pulse        <= 1'b0;
            setaasa_pulse       <= 1'b0;
            setdasa_valid       <= 1'b0;
            setnewda_valid      <= 1'b0;
            entdaa_assign_valid <= 1'b0;
            ccc_seen            <= 1'b0;
            // Update status word continuously
            status_word         <= {event_enable_mask,
                                    rstact_action[2:0], 3'b000,
                                    (|event_enable_mask),
                                    dynamic_addr_valid};

            if (sda_falling && scl) begin
                // START condition — highest priority
                if (entdaa_lost) begin
                    pending_entdaa    <= 1'b0;
                    transport_holdoff <= 1'b0;
                end
                state                   <= ST_ADDR;
                ack_context             <= ACK_NONE;
                bit_pos                 <= 4'd0;
                shift_reg               <= 8'h00;
                ack_pending             <= 1'b0;
                ack_drive_low           <= 1'b0;
                sda_drive_low           <= 1'b0;
                sda_pp_en               <= 1'b0;
                data_expected           <= 2'd0;
                data_count              <= 2'd0;
                current_rw              <= 1'b0;
                current_addr_is_ccc     <= 1'b0;
                collecting_ccc_code     <= 1'b0;
                collecting_direct_data  <= 1'b0;
                collecting_broadcast_data <= 1'b0;
                collecting_entdaa_assign<= 1'b0;
                direct_target_match     <= collecting_direct_data ? direct_target_match : 1'b0;
                entdaa_lost            <= 1'b0;
            end else if (sda_rising && scl) begin
                // STOP or repeated-start preamble. Preserve pending direct/ENTDAA
                // context by moving back to ST_ADDR when a follow-on address phase
                // is expected, matching the pre-synchronous model behavior.
                state                   <= (collecting_direct_data || collecting_broadcast_data ||
                                            pending_broadcast_data) ? ST_DATA :
                                           ((pending_direct_ccc || pending_entdaa) ? ST_ADDR : ST_IDLE);
                ack_context             <= ACK_NONE;
                bit_pos                 <= 4'd0;
                shift_reg               <= 8'h00;
                ack_pending             <= 1'b0;
                ack_drive_low           <= 1'b0;
                sda_drive_low           <= 1'b0;
                sda_pp_en               <= 1'b0;
                current_rw              <= 1'b0;
                current_addr_is_ccc     <= 1'b0;
                collecting_ccc_code     <= 1'b0;
                collecting_direct_data  <= collecting_direct_data;
                collecting_broadcast_data <= collecting_broadcast_data || pending_broadcast_data;
                collecting_entdaa_assign<= 1'b0;
                // Preserve direct_target_match if we're in the middle of collecting
                // direct data — a spurious SDA edge shouldn't invalidate the match.
                direct_target_match     <= collecting_direct_data ? direct_target_match : 1'b0;
                entdaa_lost            <= 1'b0;
                read_kind               <= READ_NONE;
                read_bit_pos            <= 4'd0;
                read_byte_idx           <= 4'd0;
                read_len                <= 4'd0;
                if (collecting_direct_data) begin
                    if (current_ccc == CCC_SETMWL_DIRECT) begin
                        data_expected <= 2'd2;
                    end else if (current_ccc == CCC_SETMRL_DIRECT) begin
                        data_expected <= 2'd3;
                    end else begin
                        data_expected <= 2'd1;
                    end
                end else if (collecting_broadcast_data || pending_broadcast_data) begin
                    if (current_ccc == CCC_SETMWL_BCAST) begin
                        data_expected <= 2'd2;
                    end else if (current_ccc == CCC_SETMRL_BCAST) begin
                        data_expected <= 2'd3;
                    end else begin
                        data_expected <= 2'd1;
                    end
                end else begin
                    data_expected <= 2'd0;
                end
                data_count              <= 2'd0;
                if (!(pending_direct_ccc || pending_entdaa || pending_broadcast_data ||
                      collecting_direct_data || collecting_broadcast_data)) begin
                    transport_holdoff   <= 1'b0;
                end
            end else if (scl_falling) begin
                // Drive SDA for ACK / read data on falling SCL edge.
                // ACK and ENTDAA response bits MUST stay open-drain (arbitration
                // phase where multiple targets can wire-AND their PIDs).
                // Direct-CCC read data (GETPID/GETBCR/GETDCR/etc) goes push-pull
                // when USE_PUSH_PULL=1 — only the addressed target responds, and
                // the controller has released SDA for the T-bit handoff.
                if (ack_pending) begin
                    sda_drive_low <= ack_drive_low;
                    sda_pp_en     <= 1'b0;
                end else if ((state == ST_READ) && (read_bit_pos < 4'd8)) begin
                    if (USE_PUSH_PULL && (read_kind != READ_ENTDAA)) begin
                        sda_drive_low <= 1'b0;
                        sda_pp_en     <= 1'b1;
                        sda_o_reg     <= read_shift[7 - read_bit_pos[2:0]];
                    end else begin
                        sda_drive_low <= ~read_shift[7 - read_bit_pos[2:0]];
                        sda_pp_en     <= 1'b0;
                    end
                end else begin
                    // T-bit slot / idle — release so controller can drive T-bit
                    sda_drive_low <= 1'b0;
                    sda_pp_en     <= 1'b0;
                end
            end else if (scl_rising) begin
                // Data sampling and state machine on rising SCL edge
                case (state)
                    ST_ADDR: begin
                        shift_reg <= assembled_byte;
                        if (bit_pos == 4'd7) begin
                            current_rw          <= sda;
                            current_addr_is_ccc <= (!pending_direct_ccc && !pending_entdaa &&
                                                    ((assembled_byte & 8'hFE) == {CCC_ADDR, 1'b0}));
                            direct_target_match <= pending_direct_ccc && direct_addr_match;
                            ack_pending         <= 1'b1;
                            bit_pos             <= 4'd0;
                            state               <= ST_ACK;

                            if (pending_entdaa && (assembled_byte == {CCC_ADDR, 1'b1})) begin
                                ack_context   <= ACK_ENTDAA_ADDR;
                                ack_drive_low <= !dynamic_addr_valid;
                            end else if (pending_entdaa &&
                                         ((assembled_byte & 8'hFE) == {CCC_ADDR, 1'b0})) begin
                                pending_entdaa    <= 1'b0;
                                transport_holdoff <= 1'b0;
                                current_addr_is_ccc <= 1'b1;
                                ack_context       <= ACK_CCC_ADDR;
                                ack_drive_low     <= !sda;
                            end else if (pending_direct_ccc) begin
                                ack_context   <= ACK_DIRECT_ADDR;
                                ack_drive_low <= direct_addr_match &&
                                                 (((current_ccc == CCC_SETDASA) && !sda) ||
                                                  ((current_ccc == CCC_SETNEWDA) && dynamic_addr_valid && !sda) ||
                                                  ((current_ccc == CCC_SETGRPA_DIRECT) && dynamic_addr_valid && !sda) ||
                                                  ((current_ccc == CCC_ENTAS0_DIRECT) && !sda) ||
                                                  ((current_ccc == CCC_ENTAS1_DIRECT) && !sda) ||
                                                  ((current_ccc == CCC_ENTAS2_DIRECT) && !sda) ||
                                                  ((current_ccc == CCC_ENTAS3_DIRECT) && !sda) ||
                                                  ((current_ccc == CCC_SETMWL_DIRECT) && !sda) ||
                                                  ((current_ccc == CCC_SETMRL_DIRECT) && !sda) ||
                                                  ((current_ccc == CCC_ENEC_DIRECT) && !sda) ||
                                                  ((current_ccc == CCC_DISEC_DIRECT) && !sda) ||
                                                  ((current_ccc == CCC_RSTGRPA_DIRECT) && !sda) ||
                                                  ((current_ccc == CCC_RSTACT_DIRECT) && !sda) ||
                                                  ((current_ccc == CCC_GETMWL) && sda) ||
                                                  ((current_ccc == CCC_GETMRL) && sda) ||
                                                  ((current_ccc == CCC_GETPID) && sda) ||
                                                  ((current_ccc == CCC_GETBCR) && sda) ||
                                                  ((current_ccc == CCC_GETDCR) && sda) ||
                                                  ((current_ccc == CCC_GETSTATUS) && sda) ||
                                                  ((current_ccc == CCC_GETMXDS) && sda) ||
                                                  ((current_ccc == CCC_GETCAPS) && sda));
                            end else begin
                                ack_context   <= ACK_CCC_ADDR;
                                ack_drive_low <= ((assembled_byte & 8'hFE) == {CCC_ADDR, 1'b0}) && !sda;
                            end
                        end else begin
                            bit_pos <= bit_pos + 1'b1;
                        end
                    end

                    ST_ACK: begin
                        ack_pending <= 1'b0;

                        case (ack_context)
                            ACK_CCC_ADDR: begin
                                if (current_addr_is_ccc && !current_rw) begin
                                    state               <= ST_DATA;
                                    collecting_ccc_code <= 1'b1;
                                    bit_pos             <= 4'd0;
                                    shift_reg           <= 8'h00;
                                end else begin
                                    state <= ST_IDLE;
                                end
                            end

                            ACK_CCC_CODE: begin
                                if (pending_direct_ccc || pending_entdaa) begin
                                    state     <= ST_ADDR;
                                    bit_pos   <= 4'd0;
                                    shift_reg <= 8'h00;
                                end else if (pending_broadcast_data) begin
                                    state                   <= ST_DATA;
                                    collecting_broadcast_data <= 1'b1;
                                    bit_pos                 <= 4'd0;
                                    shift_reg               <= 8'h00;
                                end else begin
                                    state <= ST_IDLE;
                                end
                            end

                            ACK_DIRECT_ADDR: begin
                                if (((current_ccc == CCC_SETDASA) ||
                                     (current_ccc == CCC_SETNEWDA) ||
                                     (current_ccc == CCC_SETGRPA_DIRECT) ||
                                     (current_ccc == CCC_SETMWL_DIRECT) ||
                                     (current_ccc == CCC_SETMRL_DIRECT) ||
                                     (current_ccc == CCC_ENEC_DIRECT) ||
                                     (current_ccc == CCC_DISEC_DIRECT) ||
                                     (current_ccc == CCC_RSTACT_DIRECT)) &&
                                    direct_target_match && !current_rw) begin
                                    state                  <= ST_DATA;
                                    collecting_direct_data <= 1'b1;
                                    bit_pos                <= 4'd0;
                                    shift_reg              <= 8'h00;
                                    data_count             <= 2'd0;
                                    if (current_ccc == CCC_SETMWL_DIRECT) begin
                                        data_expected <= 2'd2;
                                    end else if (current_ccc == CCC_SETMRL_DIRECT) begin
                                        data_expected <= 2'd3;
                                    end else begin
                                        data_expected <= 2'd1;
                                    end
                                end else if ((current_ccc == CCC_GETPID) && direct_target_match && current_rw) begin
                                    state        <= ST_READ;
                                    read_kind    <= READ_GETPID;
                                    read_byte_idx<= 4'd0;
                                    read_bit_pos <= 4'd0;
                                    read_len     <= 4'd6;
                                    read_shift   <= pid_byte(provisional_id, 3'd0);
                                end else if ((current_ccc == CCC_GETBCR) && direct_target_match && current_rw) begin
                                    state        <= ST_READ;
                                    read_kind    <= READ_GETBCR;
                                    read_byte_idx<= 4'd0;
                                    read_bit_pos <= 4'd0;
                                    read_len     <= 4'd1;
                                    read_shift   <= TARGET_BCR;
                                end else if ((current_ccc == CCC_GETDCR) && direct_target_match && current_rw) begin
                                    state        <= ST_READ;
                                    read_kind    <= READ_GETDCR;
                                    read_byte_idx<= 4'd0;
                                    read_bit_pos <= 4'd0;
                                    read_len     <= 4'd1;
                                    read_shift   <= TARGET_DCR;
                                end else if ((current_ccc == CCC_GETSTATUS) && direct_target_match && current_rw) begin
                                    state        <= ST_READ;
                                    read_kind    <= READ_GETSTATUS;
                                    read_byte_idx<= 4'd0;
                                    read_bit_pos <= 4'd0;
                                    read_len     <= 4'd2;
                                    read_shift   <= status_word[15:8];
                                end else if ((current_ccc == CCC_GETMWL) && direct_target_match && current_rw) begin
                                    state        <= ST_READ;
                                    read_kind    <= READ_GETMWL;
                                    read_byte_idx<= 4'd0;
                                    read_bit_pos <= 4'd0;
                                    read_len     <= 4'd2;
                                    read_shift   <= max_write_len_msb;
                                end else if ((current_ccc == CCC_GETMRL) && direct_target_match && current_rw) begin
                                    state        <= ST_READ;
                                    read_kind    <= READ_GETMRL;
                                    read_byte_idx<= 4'd0;
                                    read_bit_pos <= 4'd0;
                                    read_len     <= 4'd3;
                                    read_shift   <= max_read_len_msb;
                                end else if ((current_ccc == CCC_GETMXDS) && direct_target_match && current_rw) begin
                                    state        <= ST_READ;
                                    read_kind    <= READ_GETMXDS;
                                    read_byte_idx<= 4'd0;
                                    read_bit_pos <= 4'd0;
                                    read_len     <= 4'd2;
                                    read_shift   <= TARGET_MXDS[15:8];
                                end else if ((current_ccc == CCC_GETCAPS) && direct_target_match && current_rw) begin
                                    state        <= ST_READ;
                                    read_kind    <= READ_GETCAPS;
                                    read_byte_idx<= 4'd0;
                                    read_bit_pos <= 4'd0;
                                    read_len     <= 4'd4;
                                    read_shift   <= TARGET_CAPS[31:24];
                                end else if (((current_ccc == CCC_ENTAS0_DIRECT) ||
                                              (current_ccc == CCC_ENTAS1_DIRECT) ||
                                              (current_ccc == CCC_ENTAS2_DIRECT) ||
                                              (current_ccc == CCC_ENTAS3_DIRECT)) &&
                                             direct_target_match && !current_rw) begin
                                    activity_state     <= entas_state_value(current_ccc);
                                    pending_direct_ccc <= 1'b0;
                                    transport_holdoff  <= 1'b0;
                                    state              <= ST_IDLE;
                                end else if ((current_ccc == CCC_RSTGRPA_DIRECT) &&
                                             direct_target_match && !current_rw) begin
                                    group_addr_valid   <= 1'b0;
                                    group_addr         <= 7'h00;
                                    pending_direct_ccc <= 1'b0;
                                    transport_holdoff  <= 1'b0;
                                    state              <= ST_IDLE;
                                end else begin
                                    pending_direct_ccc <= 1'b0;
                                    transport_holdoff  <= 1'b0;
                                    state <= ST_IDLE;
                                end
                            end

                            ACK_DIRECT_DATA: begin
                                if (collecting_direct_data) begin
                                    state     <= ST_DATA;
                                    bit_pos   <= 4'd0;
                                    shift_reg <= 8'h00;
                                end else begin
                                    state <= ST_IDLE;
                                end
                            end

                            ACK_BCAST_DATA: begin
                                if (collecting_broadcast_data) begin
                                    state     <= ST_DATA;
                                    bit_pos   <= 4'd0;
                                    shift_reg <= 8'h00;
                                end else begin
                                    state <= ST_IDLE;
                                end
                            end

                            ACK_ENTDAA_ADDR: begin
                                if (!dynamic_addr_valid && !entdaa_lost) begin
                                    state        <= ST_READ;
                                    read_kind    <= READ_ENTDAA;
                                    read_byte_idx<= 4'd0;
                                    read_bit_pos <= 4'd0;
                                    read_len     <= 4'd8;
                                    read_shift   <= pid_byte(provisional_id, 3'd0);
                                end else begin
                                    state <= ST_IDLE;
                                end
                            end

                            ACK_ENTDAA_ASSIGN: begin
                                state <= ST_IDLE;
                            end

                            default: begin
                                state <= ST_IDLE;
                            end
                        endcase
                    end

                    ST_DATA: begin
                        shift_reg <= assembled_byte;
                        if (bit_pos == 4'd7) begin
                            ack_pending <= 1'b1;
                            bit_pos     <= 4'd0;
                            state       <= ST_ACK;

                            if (collecting_ccc_code) begin
                                current_ccc           <= assembled_byte;
                                last_ccc              <= assembled_byte;
                                ccc_seen              <= 1'b1;
                                collecting_ccc_code   <= 1'b0;
                                ack_context           <= ACK_CCC_CODE;
                                ack_drive_low         <= 1'b1;

                                if (assembled_byte == CCC_RSTDAA) begin
                                    rstdaa_pulse      <= 1'b1;
                                    group_addr_valid  <= 1'b0;
                                    group_addr        <= 7'h00;
                                end
                                if (assembled_byte == CCC_SETAASA) begin
                                    setaasa_pulse     <= 1'b1;
                                end
                                if ((assembled_byte == CCC_ENTAS0_BCAST) ||
                                    (assembled_byte == CCC_ENTAS1_BCAST) ||
                                    (assembled_byte == CCC_ENTAS2_BCAST) ||
                                    (assembled_byte == CCC_ENTAS3_BCAST)) begin
                                    activity_state    <= entas_state_value(assembled_byte);
                                end
                                if (assembled_byte == CCC_RSTGRPA_BCAST) begin
                                    group_addr_valid  <= 1'b0;
                                    group_addr        <= 7'h00;
                                end
                                if ((assembled_byte == CCC_SETDASA) ||
                                    (assembled_byte == CCC_SETNEWDA) ||
                                    (assembled_byte == CCC_SETGRPA_DIRECT) ||
                                    (assembled_byte == CCC_ENTAS0_DIRECT) ||
                                    (assembled_byte == CCC_ENTAS1_DIRECT) ||
                                    (assembled_byte == CCC_ENTAS2_DIRECT) ||
                                    (assembled_byte == CCC_ENTAS3_DIRECT) ||
                                    (assembled_byte == CCC_SETMWL_DIRECT) ||
                                    (assembled_byte == CCC_SETMRL_DIRECT) ||
                                    (assembled_byte == CCC_ENEC_DIRECT) ||
                                    (assembled_byte == CCC_DISEC_DIRECT) ||
                                    (assembled_byte == CCC_GETMWL) ||
                                    (assembled_byte == CCC_GETMRL) ||
                                    (assembled_byte == CCC_GETPID) ||
                                    (assembled_byte == CCC_GETBCR) ||
                                    (assembled_byte == CCC_GETDCR) ||
                                    (assembled_byte == CCC_GETSTATUS) ||
                                    (assembled_byte == CCC_GETMXDS) ||
                                    (assembled_byte == CCC_GETCAPS) ||
                                    (assembled_byte == CCC_RSTGRPA_DIRECT) ||
                                    (assembled_byte == CCC_RSTACT_DIRECT)) begin
                                    pending_direct_ccc<= 1'b1;
                                    transport_holdoff <= 1'b1;
                                end
                                if ((assembled_byte == CCC_ENEC_BCAST) ||
                                    (assembled_byte == CCC_DISEC_BCAST) ||
                                    (assembled_byte == CCC_SETMWL_BCAST) ||
                                    (assembled_byte == CCC_SETMRL_BCAST)) begin
                                    pending_broadcast_data <= 1'b1;
                                    transport_holdoff      <= 1'b1;
                                end
                                if ((assembled_byte == CCC_ENTDAA) && !dynamic_addr_valid) begin
                                    pending_entdaa    <= 1'b1;
                                    transport_holdoff <= 1'b1;
                                end
                            end else if (collecting_direct_data) begin
                                if (data_count == 2'd0) begin
                                    data_byte_0 <= assembled_byte;
                                end else if (data_count == 2'd1) begin
                                    data_byte_1 <= assembled_byte;
                                end
                                ack_context   <= ACK_DIRECT_DATA;
                                ack_drive_low <= direct_target_match;

                                if ((data_count + 1'b1) < data_expected) begin
                                    data_count <= data_count + 1'b1;
                                end else begin
                                    collecting_direct_data <= 1'b0;
                                    data_count             <= 2'd0;
                                    data_expected          <= 2'd0;

                                    if (direct_target_match) begin
                                        if ((current_ccc == CCC_SETDASA) && setdasa_data_valid) begin
                                            setdasa_valid      <= 1'b1;
                                            setdasa_addr       <= assembled_byte[7:1];
                                            pending_direct_ccc <= 1'b0;
                                            transport_holdoff  <= 1'b0;
                                            ack_drive_low      <= 1'b1;
                                        end else if ((current_ccc == CCC_SETNEWDA) && dynamic_addr_valid &&
                                                     setnewda_data_valid) begin
                                            setnewda_valid     <= 1'b1;
                                            setnewda_addr      <= assembled_byte[7:1];
                                            pending_direct_ccc <= 1'b0;
                                            transport_holdoff  <= 1'b0;
                                            ack_drive_low      <= 1'b1;
                                        end else if ((current_ccc == CCC_SETGRPA_DIRECT) &&
                                                     group_addr_data_valid) begin
                                            group_addr_valid   <= 1'b1;
                                            group_addr         <= assembled_byte[7:1];
                                            pending_direct_ccc <= 1'b0;
                                            transport_holdoff  <= 1'b0;
                                            ack_drive_low      <= 1'b1;
                                        end else if (current_ccc == CCC_SETMWL_DIRECT) begin
                                            max_write_len_msb  <= data_byte_0;
                                            max_write_len_lsb  <= assembled_byte;
                                            pending_direct_ccc <= 1'b0;
                                            transport_holdoff  <= 1'b0;
                                        end else if (current_ccc == CCC_SETMRL_DIRECT) begin
                                            max_read_len_msb   <= data_byte_0;
                                            max_read_len_lsb   <= data_byte_1;
                                            ibi_data_len_r     <= assembled_byte;
                                            pending_direct_ccc <= 1'b0;
                                            transport_holdoff  <= 1'b0;
                                        end else if (current_ccc == CCC_ENEC_DIRECT) begin
                                            event_enable_mask  <= event_enable_mask | assembled_byte;
                                            pending_direct_ccc <= 1'b0;
                                            transport_holdoff  <= 1'b0;
                                        end else if (current_ccc == CCC_DISEC_DIRECT) begin
                                            event_enable_mask  <= event_enable_mask & ~assembled_byte;
                                            pending_direct_ccc <= 1'b0;
                                            transport_holdoff  <= 1'b0;
                                        end else if (current_ccc == CCC_RSTACT_DIRECT) begin
                                            rstact_action      <= assembled_byte;
                                            pending_direct_ccc <= 1'b0;
                                            transport_holdoff  <= 1'b0;
                                        end
                                    end
                                end
                            end else if (collecting_broadcast_data) begin
                                if (data_count == 2'd0) begin
                                    data_byte_0 <= assembled_byte;
                                end else if (data_count == 2'd1) begin
                                    data_byte_1 <= assembled_byte;
                                end
                                ack_context   <= ACK_BCAST_DATA;
                                ack_drive_low <= 1'b1;

                                if ((data_count + 1'b1) < data_expected) begin
                                    data_count <= data_count + 1'b1;
                                end else begin
                                    collecting_broadcast_data <= 1'b0;
                                    pending_broadcast_data    <= 1'b0;
                                    transport_holdoff         <= 1'b0;
                                    data_count                <= 2'd0;
                                    data_expected             <= 2'd0;

                                    if (current_ccc == CCC_ENEC_BCAST) begin
                                        event_enable_mask <= event_enable_mask | assembled_byte;
                                    end else if (current_ccc == CCC_DISEC_BCAST) begin
                                        event_enable_mask <= event_enable_mask & ~assembled_byte;
                                    end else if (current_ccc == CCC_SETMWL_BCAST) begin
                                        max_write_len_msb <= data_byte_0;
                                        max_write_len_lsb <= assembled_byte;
                                    end else if (current_ccc == CCC_SETMRL_BCAST) begin
                                        max_read_len_msb  <= data_byte_0;
                                        max_read_len_lsb  <= data_byte_1;
                                        ibi_data_len_r    <= assembled_byte;
                                    end
                                end
                            end else if (collecting_entdaa_assign) begin
                                collecting_entdaa_assign <= 1'b0;
                                ack_context              <= ACK_ENTDAA_ASSIGN;
                                ack_drive_low            <= entdaa_addr_valid;

                                if (entdaa_addr_valid) begin
                                    entdaa_assign_valid <= 1'b1;
                                    entdaa_assign_addr  <= assembled_byte[7:1];
                                    pending_entdaa      <= 1'b0;
                                    transport_holdoff   <= 1'b0;
                                end
                            end
                        end else begin
                            bit_pos <= bit_pos + 1'b1;
                        end
                    end

                    ST_READ: begin
                        if (read_bit_pos < 4'd8) begin
                            if ((read_kind == READ_ENTDAA) &&
                                read_shift[7 - read_bit_pos[2:0]] &&
                                (sda == 1'b0)) begin
                                state       <= ST_WAIT_STOP;
                                entdaa_lost <= 1'b1;
                                read_kind   <= READ_NONE;
                                read_len    <= 4'd0;
                                read_bit_pos<= 4'd0;
                            end else if (read_bit_pos < 4'd7) begin
                                read_bit_pos <= read_bit_pos + 1'b1;
                            end else begin
                                read_bit_pos <= 4'd8;
                            end
                        end else begin
                            if ((read_byte_idx + 1'b1) < read_len) begin
                                read_byte_idx <= read_byte_idx + 1'b1;
                                read_shift    <= read_byte_value(read_kind, read_byte_idx + 1'b1, provisional_id);
                                read_bit_pos  <= 4'd0;
                            end else begin
                                read_bit_pos <= 4'd0;
                                if (read_kind == READ_ENTDAA) begin
                                    state                   <= ST_DATA;
                                    collecting_entdaa_assign<= 1'b1;
                                    bit_pos                 <= 4'd0;
                                    shift_reg               <= 8'h00;
                                end else begin
                                    state              <= ST_IDLE;
                                    pending_direct_ccc <= 1'b0;
                                    transport_holdoff  <= 1'b0;
                                end
                                read_kind <= READ_NONE;
                                read_len  <= 4'd0;
                            end
                        end
                    end

                    ST_WAIT_STOP: begin
                        // Another target won ENTDAA arbitration for this cycle.
                        // Stay quiet until the controller issues a new START.
                    end

                    default: begin
                        state <= ST_IDLE;
                    end
                endcase

                if ((state == ST_ACK) && (ack_context == ACK_CCC_CODE) &&
                    (pending_broadcast_data) && (state != ST_IDLE)) begin
                    if ((current_ccc == CCC_SETMWL_BCAST)) begin
                        data_expected <= 2'd2;
                        data_count    <= 2'd0;
                    end else if (current_ccc == CCC_SETMRL_BCAST) begin
                        data_expected <= 2'd3;
                        data_count    <= 2'd0;
                    end else begin
                        data_expected <= 2'd1;
                        data_count    <= 2'd0;
                    end
                end
            end
        end
    end
endmodule
