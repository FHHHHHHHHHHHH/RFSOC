`timescale 1ns / 1ps

// DPD laboratory controller.
//
// The block adds the two data services needed by the software-DPD and
// hardware-DPD experiments:
//
//   1. A 4096-sample cyclic IQ waveform player.  Four 32-bit complex samples
//      are emitted every 184.32 MHz fabric clock.
//   2. A 4096-sample observation buffer.  The LAB-to-DPD stream is decimated
//      from four to two samples per clock (lanes 0 and 2) and stored together
//      with the two RFDC ADC feedback samples from the same clock.
//
// AXI-Lite map (256 KiB aperture):
//   0x00000 CONTROL
//             bit 0: waveform playback enable
//             bit 1: capture trigger (write one pulse)
//             bit 2: clear capture status/count (write one pulse)
//   0x00004 STATUS
//             bit 0: playback active in sample clock domain
//             bit 1: capture busy
//             bit 2: capture done (sticky until clear/new trigger)
//   0x00008 PLAYBACK_LENGTH, samples, 4..4096 and rounded down to /4
//   0x0000C CAPTURE_TARGET, samples, 2..4096 and rounded down to /2
//   0x00010 CAPTURE_COUNT
//   0x00014 VERSION = 0x4C414202 ("LAB", revision 2)
//   0x10000-0x13FFF waveform samples, {Q[15:0], I[15:0]}
//   0x20000-0x27FFF capture records, two words per sample:
//             word 0: TX reference {Q,I}
//             word 1: ADC feedback {Q,I}
module axis_dpd_lab_controller_impl #(
    parameter integer C_S_AXI_ADDR_WIDTH = 18,
    parameter integer C_S_AXI_DATA_WIDTH = 32
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axis_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_dbpsk_axis:m_tx_axis:s_adc_i_axis:s_adc_q_axis, ASSOCIATED_RESET axis_resetn, FREQ_HZ 184320000" *)
    input  wire                          axis_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axis_resetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                          axis_resetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_dbpsk_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_dbpsk_axis, FREQ_HZ 184320000, TDATA_NUM_BYTES 16, HAS_TREADY 0, HAS_TLAST 0" *)
    input  wire [127:0]                  s_dbpsk_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_dbpsk_axis TVALID" *)
    input  wire                          s_dbpsk_axis_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_tx_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_tx_axis, FREQ_HZ 184320000, TDATA_NUM_BYTES 16, HAS_TREADY 0, HAS_TLAST 0" *)
    output wire [127:0]                  m_tx_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_tx_axis TVALID" *)
    output wire                          m_tx_axis_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_adc_i_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_adc_i_axis, FREQ_HZ 184320000, TDATA_NUM_BYTES 4, HAS_TREADY 0, HAS_TLAST 0" *)
    input  wire [31:0]                   s_adc_i_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_adc_i_axis TVALID" *)
    input  wire                          s_adc_i_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_adc_q_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_adc_q_axis, FREQ_HZ 184320000, TDATA_NUM_BYTES 4, HAS_TREADY 0, HAS_TLAST 0" *)
    input  wire [31:0]                   s_adc_q_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_adc_q_axis TVALID" *)
    input  wire                          s_adc_q_axis_tvalid,

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

    output wire                          playback_active,
    output wire                          capture_busy,
    output wire                          capture_done,
    output wire [12:0]                   capture_count
);

    localparam [31:0] CORE_VERSION = 32'h4C41_4202;

    reg aw_hold;
    reg w_hold;
    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_hold;
    reg [31:0] wdata_hold;
    reg [3:0] wstrb_hold;

    reg playback_enable_axi;
    reg capture_trigger_toggle_axi;
    reg capture_clear_toggle_axi;
    reg [12:0] playback_length_axi;
    reg [12:0] capture_target_axi;

    (* ram_style = "block" *) reg [31:0] waveform_bank0 [0:1023];
    (* ram_style = "block" *) reg [31:0] waveform_bank1 [0:1023];
    (* ram_style = "block" *) reg [31:0] waveform_bank2 [0:1023];
    (* ram_style = "block" *) reg [31:0] waveform_bank3 [0:1023];

    (* ram_style = "block" *) reg [63:0] capture_even [0:2047];
    (* ram_style = "block" *) reg [63:0] capture_odd  [0:2047];

    reg playback_enable_sync1;
    reg playback_enable_sync2;
    reg [12:0] playback_length_sync1;
    reg [12:0] playback_length_sync2;
    reg [12:0] capture_target_sync1;
    reg [12:0] capture_target_sync2;
    reg capture_trigger_sync1;
    reg capture_trigger_sync2;
    reg capture_trigger_seen;
    reg capture_clear_sync1;
    reg capture_clear_sync2;
    reg capture_clear_seen;

    reg [11:0] playback_sample_index;
    reg [127:0] playback_data_axis;
    reg playback_valid_axis;
    reg capture_busy_axis;
    reg capture_done_axis;
    reg [12:0] capture_count_axis;

    reg playback_active_sync1;
    reg playback_active_sync2;
    reg capture_busy_sync1;
    reg capture_busy_sync2;
    reg capture_done_sync1;
    reg capture_done_sync2;
    reg [12:0] capture_count_gray_sync1;
    reg [12:0] capture_count_gray_sync2;

    wire capture_input_valid = m_tx_axis_tvalid &&
                               s_adc_i_axis_tvalid && s_adc_q_axis_tvalid;
    wire [12:0] capture_count_gray_axis =
        (capture_count_axis >> 1) ^ capture_count_axis;
    wire [12:0] capture_count_binary_axi;

    function automatic [31:0] apply_write_strobes;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0] strobes;
        integer byte_i;
        begin
            apply_write_strobes = old_value;
            for (byte_i = 0; byte_i < 4; byte_i = byte_i + 1)
                if (strobes[byte_i])
                    apply_write_strobes[byte_i*8 +: 8] = new_value[byte_i*8 +: 8];
        end
    endfunction

    function automatic [12:0] gray_to_binary13;
        input [12:0] gray_value;
        integer bit_i;
        begin
            gray_to_binary13[12] = gray_value[12];
            for (bit_i = 11; bit_i >= 0; bit_i = bit_i - 1)
                gray_to_binary13[bit_i] = gray_to_binary13[bit_i+1] ^ gray_value[bit_i];
        end
    endfunction

    assign s_axi_awready = !aw_hold && !s_axi_bvalid;
    assign s_axi_wready  = !w_hold && !s_axi_bvalid;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;

    assign m_tx_axis_tdata  = playback_enable_sync2 ? playback_data_axis
                                                    : s_dbpsk_axis_tdata;
    assign m_tx_axis_tvalid = playback_enable_sync2 ? playback_valid_axis
                                                    : s_dbpsk_axis_tvalid;

    assign capture_count_binary_axi = gray_to_binary13(capture_count_gray_sync2);
    assign playback_active = playback_active_sync2;
    assign capture_busy = capture_busy_sync2;
    assign capture_done = capture_done_sync2;
    assign capture_count = capture_count_binary_axi;

    // AXI writes: control registers and waveform memory.
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            aw_hold <= 1'b0;
            w_hold <= 1'b0;
            awaddr_hold <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            wdata_hold <= 32'd0;
            wstrb_hold <= 4'd0;
            s_axi_bvalid <= 1'b0;
            playback_enable_axi <= 1'b0;
            capture_trigger_toggle_axi <= 1'b0;
            capture_clear_toggle_axi <= 1'b0;
            playback_length_axi <= 13'd4096;
            capture_target_axi <= 13'd4096;
        end else begin
            if (s_axi_awready && s_axi_awvalid) begin
                aw_hold <= 1'b1;
                awaddr_hold <= s_axi_awaddr;
            end
            if (s_axi_wready && s_axi_wvalid) begin
                w_hold <= 1'b1;
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
            end

            if (aw_hold && w_hold && !s_axi_bvalid) begin
                aw_hold <= 1'b0;
                w_hold <= 1'b0;
                s_axi_bvalid <= 1'b1;

                if (awaddr_hold[17:14] == 4'b0100) begin
                    case (awaddr_hold[3:2])
                        2'd0: waveform_bank0[awaddr_hold[13:4]] <=
                            apply_write_strobes(waveform_bank0[awaddr_hold[13:4]],
                                                wdata_hold, wstrb_hold);
                        2'd1: waveform_bank1[awaddr_hold[13:4]] <=
                            apply_write_strobes(waveform_bank1[awaddr_hold[13:4]],
                                                wdata_hold, wstrb_hold);
                        2'd2: waveform_bank2[awaddr_hold[13:4]] <=
                            apply_write_strobes(waveform_bank2[awaddr_hold[13:4]],
                                                wdata_hold, wstrb_hold);
                        default: waveform_bank3[awaddr_hold[13:4]] <=
                            apply_write_strobes(waveform_bank3[awaddr_hold[13:4]],
                                                wdata_hold, wstrb_hold);
                    endcase
                end else if (awaddr_hold[17:16] == 2'b00) begin
                    case (awaddr_hold[11:2])
                        10'd0: if (wstrb_hold[0]) begin
                            playback_enable_axi <= wdata_hold[0];
                            if (wdata_hold[1])
                                capture_trigger_toggle_axi <= ~capture_trigger_toggle_axi;
                            if (wdata_hold[2])
                                capture_clear_toggle_axi <= ~capture_clear_toggle_axi;
                        end
                        10'd2: if (wstrb_hold[0] || wstrb_hold[1]) begin
                            if (wdata_hold[12:0] < 13'd4)
                                playback_length_axi <= 13'd4;
                            else if (wdata_hold[12:0] > 13'd4096)
                                playback_length_axi <= 13'd4096;
                            else
                                playback_length_axi <= {wdata_hold[12:2], 2'b00};
                        end
                        10'd3: if (wstrb_hold[0] || wstrb_hold[1]) begin
                            if (wdata_hold[12:0] < 13'd2)
                                capture_target_axi <= 13'd2;
                            else if (wdata_hold[12:0] > 13'd4096)
                                capture_target_axi <= 13'd4096;
                            else
                                capture_target_axi <= {wdata_hold[12:1], 1'b0};
                        end
                        default: begin end
                    endcase
                end
            end

            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    // AXI reads. Capture memories are read-only to software.
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata <= 32'd0;
        end else begin
            if (s_axi_arready && s_axi_arvalid) begin
                s_axi_rvalid <= 1'b1;
                if (s_axi_araddr[17:15] == 3'b100) begin
                    if (s_axi_araddr[3]) begin
                        s_axi_rdata <= s_axi_araddr[2]
                            ? capture_odd[s_axi_araddr[14:4]][63:32]
                            : capture_odd[s_axi_araddr[14:4]][31:0];
                    end else begin
                        s_axi_rdata <= s_axi_araddr[2]
                            ? capture_even[s_axi_araddr[14:4]][63:32]
                            : capture_even[s_axi_araddr[14:4]][31:0];
                    end
                end else begin
                    case (s_axi_araddr[11:2])
                        10'd0: s_axi_rdata <= {31'd0, playback_enable_axi};
                        10'd1: s_axi_rdata <= {29'd0, capture_done_sync2,
                                               capture_busy_sync2,
                                               playback_active_sync2};
                        10'd2: s_axi_rdata <= {19'd0, playback_length_axi};
                        10'd3: s_axi_rdata <= {19'd0, capture_target_axi};
                        10'd4: s_axi_rdata <= {19'd0, capture_count_binary_axi};
                        10'd5: s_axi_rdata <= CORE_VERSION;
                        default: s_axi_rdata <= 32'd0;
                    endcase
                end
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    // AXI-to-sample clock control crossings.
    always @(posedge axis_clk) begin
        if (!axis_resetn) begin
            playback_enable_sync1 <= 1'b0;
            playback_enable_sync2 <= 1'b0;
            playback_length_sync1 <= 13'd4096;
            playback_length_sync2 <= 13'd4096;
            capture_target_sync1 <= 13'd4096;
            capture_target_sync2 <= 13'd4096;
            capture_trigger_sync1 <= 1'b0;
            capture_trigger_sync2 <= 1'b0;
            capture_trigger_seen <= 1'b0;
            capture_clear_sync1 <= 1'b0;
            capture_clear_sync2 <= 1'b0;
            capture_clear_seen <= 1'b0;
        end else begin
            playback_enable_sync1 <= playback_enable_axi;
            playback_enable_sync2 <= playback_enable_sync1;
            playback_length_sync1 <= playback_length_axi;
            playback_length_sync2 <= playback_length_sync1;
            capture_target_sync1 <= capture_target_axi;
            capture_target_sync2 <= capture_target_sync1;
            capture_trigger_sync1 <= capture_trigger_toggle_axi;
            capture_trigger_sync2 <= capture_trigger_sync1;
            capture_clear_sync1 <= capture_clear_toggle_axi;
            capture_clear_sync2 <= capture_clear_sync1;
            if (capture_trigger_sync2 != capture_trigger_seen)
                capture_trigger_seen <= capture_trigger_sync2;
            if (capture_clear_sync2 != capture_clear_seen)
                capture_clear_seen <= capture_clear_sync2;
        end
    end

    // Four-bank cyclic waveform player.
    always @(posedge axis_clk) begin
        if (!axis_resetn) begin
            playback_sample_index <= 12'd0;
            playback_data_axis <= 128'd0;
            playback_valid_axis <= 1'b0;
        end else if (playback_enable_sync2) begin
            playback_valid_axis <= 1'b1;
            playback_data_axis <= {
                waveform_bank3[playback_sample_index[11:2]],
                waveform_bank2[playback_sample_index[11:2]],
                waveform_bank1[playback_sample_index[11:2]],
                waveform_bank0[playback_sample_index[11:2]]
            };
            if ({1'b0, playback_sample_index} + 13'd4 >= playback_length_sync2)
                playback_sample_index <= 12'd0;
            else
                playback_sample_index <= playback_sample_index + 12'd4;
        end else begin
            playback_sample_index <= 12'd0;
            playback_valid_axis <= 1'b0;
        end
    end

    // Two samples are captured per fabric clock.  DPD lanes 0 and 2 match the
    // RFDC ADC's two samples/clock after the DAC/ADC interpolation ratio.
    always @(posedge axis_clk) begin
        if (!axis_resetn) begin
            capture_busy_axis <= 1'b0;
            capture_done_axis <= 1'b0;
            capture_count_axis <= 13'd0;
        end else begin
            if (capture_clear_sync2 != capture_clear_seen) begin
                capture_busy_axis <= 1'b0;
                capture_done_axis <= 1'b0;
                capture_count_axis <= 13'd0;
            end

            if (capture_trigger_sync2 != capture_trigger_seen) begin
                capture_busy_axis <= 1'b1;
                capture_done_axis <= 1'b0;
                capture_count_axis <= 13'd0;
            end else if (capture_busy_axis && capture_input_valid) begin
                capture_even[capture_count_axis[11:1]] <= {
                    s_adc_q_axis_tdata[15:0], s_adc_i_axis_tdata[15:0],
                    m_tx_axis_tdata[31:16], m_tx_axis_tdata[15:0]
                };
                capture_odd[capture_count_axis[11:1]] <= {
                    s_adc_q_axis_tdata[31:16], s_adc_i_axis_tdata[31:16],
                    m_tx_axis_tdata[95:80], m_tx_axis_tdata[79:64]
                };

                if (capture_count_axis + 13'd2 >= capture_target_sync2) begin
                    capture_count_axis <= capture_target_sync2;
                    capture_busy_axis <= 1'b0;
                    capture_done_axis <= 1'b1;
                end else begin
                    capture_count_axis <= capture_count_axis + 13'd2;
                end
            end
        end
    end

    // Sample-to-AXI status crossings.
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            playback_active_sync1 <= 1'b0;
            playback_active_sync2 <= 1'b0;
            capture_busy_sync1 <= 1'b0;
            capture_busy_sync2 <= 1'b0;
            capture_done_sync1 <= 1'b0;
            capture_done_sync2 <= 1'b0;
            capture_count_gray_sync1 <= 13'd0;
            capture_count_gray_sync2 <= 13'd0;
        end else begin
            playback_active_sync1 <= playback_enable_sync2;
            playback_active_sync2 <= playback_active_sync1;
            capture_busy_sync1 <= capture_busy_axis;
            capture_busy_sync2 <= capture_busy_sync1;
            capture_done_sync1 <= capture_done_axis;
            capture_done_sync2 <= capture_done_sync1;
            capture_count_gray_sync1 <= capture_count_gray_axis;
            capture_count_gray_sync2 <= capture_count_gray_sync1;
        end
    end

endmodule
