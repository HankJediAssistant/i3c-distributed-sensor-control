`timescale 1ns/1ps

module i3c_target_top #(
    parameter integer MAX_READ_BYTES = 4,
    parameter [6:0]  STATIC_ADDR    = 7'h2A,
    parameter [47:0] PROVISIONAL_ID = 48'h1234_5678_9ABC,
    parameter [7:0]  TARGET_BCR     = 8'h01,
    parameter [7:0]  TARGET_DCR     = 8'h5A,
    parameter [15:0] TARGET_MAX_WRITE_LEN = 16'h0010,
    parameter [15:0] TARGET_MAX_READ_LEN  = 16'h0010,
    parameter [7:0]  TARGET_IBI_DATA_LEN  = 8'h00,
    parameter [15:0] TARGET_MXDS          = 16'h0860,
    parameter [31:0] TARGET_CAPS          = 32'h0000_0000,
    // When 1, read-data bits are driven push-pull on SDA (direct-CCC GET* reads
    // and transport-layer reads). ENTDAA response remains open-drain always.
    // When 0 (default), target is open-drain only — preserves legacy behavior
    // for all internal wired-AND top-level wrappers and their testbenches.
    parameter integer USE_PUSH_PULL       = 0
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       scl,
    input  wire       sda,
    output wire       sda_oe,
    output wire       sda_o,

    input  wire       clear_dynamic_addr,
    input  wire       assign_dynamic_addr_valid,
    input  wire [6:0] assign_dynamic_addr,

    input  wire [8*MAX_READ_BYTES-1:0] read_data,
    output wire [7:0] write_data,
    output wire       write_valid,
    output wire [7:0] register_selector,
    output wire       read_valid,
    output wire       selected,
    output wire [6:0] active_addr,
    output wire       dynamic_addr_valid,
    output wire [47:0] provisional_id,
    output wire [7:0]  event_enable_mask,
    output wire [7:0]  rstact_action,
    output wire [15:0] status_word,
    output wire [1:0]  activity_state,
    output wire        group_addr_valid,
    output wire [6:0]  group_addr,
    output wire [15:0] max_write_len,
    output wire [15:0] max_read_len,
    output wire [7:0]  ibi_data_len,
    output wire [7:0]  last_ccc
);

    wire ccc_rstdaa_pulse;
    wire ccc_setaasa_pulse;
    wire ccc_setdasa_valid;
    wire [6:0] ccc_setdasa_addr;
    wire ccc_setnewda_valid;
    wire [6:0] ccc_setnewda_addr;
    wire ccc_entdaa_assign_valid;
    wire [6:0] ccc_entdaa_assign_addr;
    wire ccc_transport_holdoff;
    wire ccc_seen;
    wire transport_sda_drive_en;
    wire ccc_sda_drive_en;
    wire transport_sda_o;
    wire ccc_sda_o;
    wire target_assign_dynamic_addr_valid;
    wire [6:0] target_assign_dynamic_addr;
    reg  [7:0] register_selector_r;

    assign register_selector = register_selector_r;
    assign sda_oe = transport_sda_drive_en | ccc_sda_drive_en;
    // OR the data bits — at most one submodule drives a data byte at a time
    // (transport handles addressed read/write; CCC handler holds off transport
    // via transport_holdoff during CCC sequences).  When neither asserts PP,
    // sda_o is 0 but sda_oe gates it out via sda_t=1 (high-Z) at the PHY.
    assign sda_o  = transport_sda_o | ccc_sda_o;

    assign target_assign_dynamic_addr_valid = assign_dynamic_addr_valid |
                                              ccc_setdasa_valid |
                                              ccc_setnewda_valid |
                                              ccc_entdaa_assign_valid;
    assign target_assign_dynamic_addr = ccc_entdaa_assign_valid ? ccc_entdaa_assign_addr :
                                        (ccc_setnewda_valid ? ccc_setnewda_addr :
                                        (ccc_setdasa_valid ? ccc_setdasa_addr : assign_dynamic_addr));

    i3c_target_daa #(
        .STATIC_ADDR(STATIC_ADDR),
        .PROVISIONAL_ID(PROVISIONAL_ID)
    ) u_target_daa (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .clear_dynamic_addr      (clear_dynamic_addr | ccc_rstdaa_pulse),
        .set_static_dynamic_addr (ccc_setaasa_pulse),
        .assign_dynamic_addr_valid(target_assign_dynamic_addr_valid),
        .assign_dynamic_addr     (target_assign_dynamic_addr),
        .active_addr             (active_addr),
        .dynamic_addr_valid      (dynamic_addr_valid),
        .provisional_id          (provisional_id)
    );

    i3c_target_transport #(
        .MAX_READ_BYTES(MAX_READ_BYTES),
        .USE_PUSH_PULL (USE_PUSH_PULL)
    ) u_target_transport (
        .clk         (clk),
        .rst_n       (rst_n),
        .scl         (scl),
        .sda         (sda),
        .sda_drive_en(transport_sda_drive_en),
        .sda_o       (transport_sda_o),
        .suppress    (ccc_transport_holdoff),
        .read_data   (read_data),
        .alt_addr_valid(group_addr_valid),
        .alt_addr    (group_addr),
        .write_data  (write_data),
        .write_valid (write_valid),
        .read_valid  (read_valid),
        .selected    (selected),
        .target_addr (active_addr)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            register_selector_r <= 8'h00;
        end else if (write_valid) begin
            register_selector_r <= write_data;
        end
    end

    i3c_target_ccc #(
        .STATIC_ADDR(STATIC_ADDR),
        .TARGET_BCR (TARGET_BCR),
        .TARGET_DCR (TARGET_DCR),
        .TARGET_MAX_WRITE_LEN(TARGET_MAX_WRITE_LEN),
        .TARGET_MAX_READ_LEN (TARGET_MAX_READ_LEN),
        .TARGET_IBI_DATA_LEN (TARGET_IBI_DATA_LEN),
        .TARGET_MXDS         (TARGET_MXDS),
        .TARGET_CAPS         (TARGET_CAPS),
        .USE_PUSH_PULL       (USE_PUSH_PULL)
    ) u_target_ccc (
        .clk              (clk),
        .rst_n            (rst_n),
        .scl              (scl),
        .sda              (sda),
        .sda_drive_en     (ccc_sda_drive_en),
        .sda_o            (ccc_sda_o),
        .active_addr      (active_addr),
        .dynamic_addr_valid(dynamic_addr_valid),
        .provisional_id   (provisional_id),
        .rstdaa_pulse     (ccc_rstdaa_pulse),
        .setaasa_pulse    (ccc_setaasa_pulse),
        .setdasa_valid    (ccc_setdasa_valid),
        .setdasa_addr     (ccc_setdasa_addr),
        .setnewda_valid   (ccc_setnewda_valid),
        .setnewda_addr    (ccc_setnewda_addr),
        .entdaa_assign_valid(ccc_entdaa_assign_valid),
        .entdaa_assign_addr(ccc_entdaa_assign_addr),
        .transport_holdoff(ccc_transport_holdoff),
        .event_enable_mask(event_enable_mask),
        .rstact_action   (rstact_action),
        .status_word     (status_word),
        .activity_state  (activity_state),
        .group_addr_valid(group_addr_valid),
        .group_addr      (group_addr),
        .max_write_len   (max_write_len),
        .max_read_len    (max_read_len),
        .ibi_data_len    (ibi_data_len),
        .ccc_seen         (ccc_seen),
        .last_ccc         (last_ccc)
    );
endmodule
