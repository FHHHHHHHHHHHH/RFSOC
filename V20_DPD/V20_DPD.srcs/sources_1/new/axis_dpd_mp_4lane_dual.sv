`timescale 1ns / 1ps

// AXI-Stream/AXI-Lite wrapper for the four-lane MP-DPD core.
//
// One processed stream is duplicated to both RFDC DAC paths.  This preserves
// the existing V10 dual-DAC topology while adding a common predistorter before
// the RFDC fine-mixer phase offsets.
//
// AXI-Lite register map (256 KiB aperture):
//   0x00000 CONTROL
//             bit 0: DPD enable (0 = latency-matched bypass)
//             bit 1: coefficient bank commit toggle (write 1)
//             bit 2: clear clipping counter (write 1)
//   0x00004 STATUS
//             bit 0: active coefficient bank
//             bit 1: synchronized DPD enable
//   0x00008 CLIP_COUNT (number of output beats containing saturation)
//   0x0000C CORE_VERSION (0x44504401 = "DPD", revision 1)
//
// Coefficient writes occupy 0x20000-0x3FFFF:
//   address bit 16    : bank
//   address bits 15:14: memory tap (0..3)
//   address bits 13:2 : LUT address (0..4095)
//   write data         : {gain_q[15:0], gain_i[15:0]}
//
// Coefficient RAM write ports use s_axi_aclk while their read ports use
// axis_clk, so no AXI clock converter is needed.
module axis_dpd_mp_4lane_dual_impl #(
    parameter integer C_S_AXI_ADDR_WIDTH = 18,
    parameter integer C_S_AXI_DATA_WIDTH = 32
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axis_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m0_axis:m1_axis, ASSOCIATED_RESET axis_resetn, FREQ_HZ 184320000" *)
    input  wire                          axis_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axis_resetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                          axis_resetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axis, FREQ_HZ 184320000, TDATA_NUM_BYTES 16, HAS_TREADY 0, HAS_TLAST 0" *)
    input  wire [127:0]                  s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire                          s_axis_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m0_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m0_axis, FREQ_HZ 184320000, TDATA_NUM_BYTES 16, HAS_TREADY 0, HAS_TLAST 0" *)
    output wire [127:0]                  m0_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m0_axis TVALID" *)
    output wire                          m0_axis_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m1_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m1_axis, FREQ_HZ 184320000, TDATA_NUM_BYTES 16, HAS_TREADY 0, HAS_TLAST 0" *)
    output wire [127:0]                  m1_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m1_axis TVALID" *)
    output wire                          m1_axis_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET s_axi_aresetn, FREQ_HZ 99999001" *)
    input  wire                          s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                          s_axi_aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 18, FREQ_HZ 99999001, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 1, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, SUPPORTS_NARROW_BURST 0, MAX_BURST_LENGTH 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
    input  wire [2:0]                    s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  wire                          s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output wire                          s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  wire                          s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output wire                          s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output wire [1:0]                    s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output reg                           s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  wire                          s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
    input  wire [2:0]                    s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  wire                          s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output wire                          s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output reg  [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output wire [1:0]                    s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output reg                           s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  wire                          s_axi_rready,

    output wire                          dpd_active_bank,
    output wire [31:0]                   dpd_clip_count
);

    localparam [31:0] CORE_VERSION = 32'h4450_4401;

    reg aw_hold;
    reg w_hold;
    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_hold;
    reg [C_S_AXI_DATA_WIDTH-1:0] wdata_hold;
    reg [C_S_AXI_DATA_WIDTH/8-1:0] wstrb_hold;

    reg dpd_enable_axi;
    reg commit_toggle_axi;
    reg clear_toggle_axi;

    reg cfg_we;
    reg cfg_bank;
    reg [1:0] cfg_tap;
    reg [11:0] cfg_addr;
    reg [31:0] cfg_wdata;

    reg enable_sync1;
    reg enable_sync2;
    reg commit_sync1;
    reg commit_sync2;
    reg commit_seen;
    reg commit_pulse_axis;
    reg clear_sync1;
    reg clear_sync2;
    reg clear_seen;
    reg clear_pulse_axis;

    wire core_active_bank;
    wire [31:0] clip_count_gray_axis;
    wire [127:0] core_axis_tdata;
    wire core_axis_tvalid;

    reg active_bank_sync1;
    reg active_bank_sync2;
    reg enable_status_sync1;
    reg enable_status_sync2;
    reg [31:0] clip_gray_sync1;
    reg [31:0] clip_gray_sync2;
    wire [31:0] clip_count_binary_axi;

    integer byte_i;

    function automatic [31:0] gray_to_binary;
        input [31:0] gray_value;
        integer bit_i;
        begin
            gray_to_binary[31] = gray_value[31];
            for (bit_i = 30; bit_i >= 0; bit_i = bit_i - 1)
                gray_to_binary[bit_i] = gray_to_binary[bit_i+1] ^ gray_value[bit_i];
        end
    endfunction

    function automatic [31:0] apply_write_strobes;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0] strobes;
        integer strobe_i;
        begin
            apply_write_strobes = old_value;
            for (strobe_i = 0; strobe_i < 4; strobe_i = strobe_i + 1)
                if (strobes[strobe_i])
                    apply_write_strobes[strobe_i*8 +: 8] = new_value[strobe_i*8 +: 8];
        end
    endfunction

    assign s_axi_awready = !aw_hold && !s_axi_bvalid;
    assign s_axi_wready  = !w_hold  && !s_axi_bvalid;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;

    assign clip_count_binary_axi = gray_to_binary(clip_gray_sync2);
    assign dpd_active_bank = active_bank_sync2;
    assign dpd_clip_count  = clip_count_binary_axi;

    assign m0_axis_tdata  = core_axis_tdata;
    assign m1_axis_tdata  = core_axis_tdata;
    assign m0_axis_tvalid = core_axis_tvalid;
    assign m1_axis_tvalid = core_axis_tvalid;

    // AXI-Lite write channel and coefficient write decoding.
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            aw_hold          <= 1'b0;
            w_hold           <= 1'b0;
            awaddr_hold      <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            wdata_hold       <= {C_S_AXI_DATA_WIDTH{1'b0}};
            wstrb_hold       <= {C_S_AXI_DATA_WIDTH/8{1'b0}};
            s_axi_bvalid     <= 1'b0;
            dpd_enable_axi   <= 1'b0;
            commit_toggle_axi<= 1'b0;
            clear_toggle_axi <= 1'b0;
            cfg_we           <= 1'b0;
            cfg_bank         <= 1'b0;
            cfg_tap          <= 2'd0;
            cfg_addr         <= 12'd0;
            cfg_wdata        <= 32'd0;
        end else begin
            cfg_we <= 1'b0;

            if (s_axi_awready && s_axi_awvalid) begin
                aw_hold     <= 1'b1;
                awaddr_hold <= s_axi_awaddr;
            end

            if (s_axi_wready && s_axi_wvalid) begin
                w_hold     <= 1'b1;
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
            end

            if (aw_hold && w_hold && !s_axi_bvalid) begin
                aw_hold      <= 1'b0;
                w_hold       <= 1'b0;
                s_axi_bvalid <= 1'b1;

                if (awaddr_hold[17]) begin
                    // Coefficient memory window.  Partial writes are allowed
                    // and zero-fill bytes not selected by WSTRB.
                    cfg_we    <= 1'b1;
                    cfg_bank  <= awaddr_hold[16];
                    cfg_tap   <= awaddr_hold[15:14];
                    cfg_addr  <= awaddr_hold[13:2];
                    cfg_wdata <= apply_write_strobes(32'd0, wdata_hold, wstrb_hold);
                end else if (awaddr_hold[11:2] == 10'd0) begin
                    if (wstrb_hold[0]) begin
                        dpd_enable_axi <= wdata_hold[0];
                        if (wdata_hold[1])
                            commit_toggle_axi <= ~commit_toggle_axi;
                        if (wdata_hold[2])
                            clear_toggle_axi <= ~clear_toggle_axi;
                    end
                end
            end

            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    // AXI-Lite read channel.  Coefficient memory is intentionally write-only;
    // software verifies tables before loading them and reads status here.
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= 32'd0;
        end else begin
            if (s_axi_arready && s_axi_arvalid) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr[11:2])
                    10'd0: s_axi_rdata <= {29'd0, 2'b00, dpd_enable_axi};
                    10'd1: s_axi_rdata <= {30'd0, enable_status_sync2, active_bank_sync2};
                    10'd2: s_axi_rdata <= clip_count_binary_axi;
                    10'd3: s_axi_rdata <= CORE_VERSION;
                    default: s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    // Control/status clock-domain crossings.
    always @(posedge axis_clk) begin
        if (!axis_resetn) begin
            enable_sync1     <= 1'b0;
            enable_sync2     <= 1'b0;
            commit_sync1     <= 1'b0;
            commit_sync2     <= 1'b0;
            commit_seen      <= 1'b0;
            commit_pulse_axis<= 1'b0;
            clear_sync1      <= 1'b0;
            clear_sync2      <= 1'b0;
            clear_seen       <= 1'b0;
            clear_pulse_axis <= 1'b0;
        end else begin
            enable_sync1 <= dpd_enable_axi;
            enable_sync2 <= enable_sync1;

            commit_sync1 <= commit_toggle_axi;
            commit_sync2 <= commit_sync1;
            commit_pulse_axis <= commit_sync2 ^ commit_seen;
            if (commit_sync2 != commit_seen)
                commit_seen <= commit_sync2;

            clear_sync1 <= clear_toggle_axi;
            clear_sync2 <= clear_sync1;
            clear_pulse_axis <= clear_sync2 ^ clear_seen;
            if (clear_sync2 != clear_seen)
                clear_seen <= clear_sync2;
        end
    end

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            active_bank_sync1 <= 1'b0;
            active_bank_sync2 <= 1'b0;
            enable_status_sync1 <= 1'b0;
            enable_status_sync2 <= 1'b0;
            clip_gray_sync1   <= 32'd0;
            clip_gray_sync2   <= 32'd0;
        end else begin
            active_bank_sync1 <= core_active_bank;
            active_bank_sync2 <= active_bank_sync1;
            enable_status_sync1 <= enable_sync2;
            enable_status_sync2 <= enable_status_sync1;
            clip_gray_sync1   <= clip_count_gray_axis;
            clip_gray_sync2   <= clip_gray_sync1;
        end
    end

    dpd_mp_4lane_core u_dpd_core (
        .axis_clk          (axis_clk),
        .axis_resetn       (axis_resetn),
        .s_axis_tdata      (s_axis_tdata),
        .s_axis_tvalid     (s_axis_tvalid),
        .m_axis_tdata      (core_axis_tdata),
        .m_axis_tvalid     (core_axis_tvalid),
        .dpd_enable        (enable_sync2),
        .commit_pulse      (commit_pulse_axis),
        .clear_clip_pulse  (clear_pulse_axis),
        .active_bank       (core_active_bank),
        .clip_count_gray   (clip_count_gray_axis),
        .cfg_clk           (s_axi_aclk),
        .cfg_we            (cfg_we),
        .cfg_bank          (cfg_bank),
        .cfg_tap           (cfg_tap),
        .cfg_addr          (cfg_addr),
        .cfg_wdata         (cfg_wdata)
    );

endmodule
