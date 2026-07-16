`timescale 1ns / 1ps

// Constant-envelope DBPSK transmitter shared by both DAC channels.
//
// The input stream carries one byte in TDATA[7:0]. Bits are transmitted MSB
// first. A data bit of one reverses the carrier phase; a zero preserves it.
// Between AXI packets the output is a continuous positive-I idle carrier.
// Both DAC AXIS outputs are generated from the same state, so their digital
// samples are always identical. The RFDC fine-mixer phase offsets provide the
// symmetric outphasing angle.
module dual_dac_dbpsk_tx #(
    parameter integer CLK_FREQ_HZ = 184_320_000,
    parameter integer BAUD_RATE   = 10_000_000,
    parameter integer AMPLITUDE   = 32767
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m0_axis:m1_axis, ASSOCIATED_RESET rst_n, FREQ_HZ 184320000" *)
    input  wire         clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         rst_n,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axis, FREQ_HZ 184320000" *)
    input  wire [31:0]  s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire         s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output wire         s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *)
    input  wire         s_axis_tlast,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m0_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m0_axis, FREQ_HZ 184320000" *)
    output wire [127:0] m0_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m0_axis TVALID" *)
    output wire         m0_axis_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m1_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m1_axis, FREQ_HZ 184320000" *)
    output wire [127:0] m1_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m1_axis TVALID" *)
    output wire         m1_axis_tvalid,

    output wire         tx_active,
    output reg          frame_start
);

    reg                 active;
    reg                 phase_state;
    reg [31:0]          baud_phase;
    reg [7:0]           current_byte;
    reg [2:0]           bit_index;
    reg                 current_last;
    reg [7:0]           prefetch_byte;
    reg                 prefetch_last;
    reg                 prefetch_valid;

    wire input_fire = s_axis_tvalid && s_axis_tready;
    wire symbol_end = baud_phase >= (CLK_FREQ_HZ - BAUD_RATE);

    // Do not read beyond the final byte of the current AXI packet. One byte is
    // prefetched during transmission so adjacent bytes have no idle gap.
    assign s_axis_tready = !active || (!current_last && !prefetch_valid);

    wire signed [15:0] sample_i = phase_state ? -AMPLITUDE : AMPLITUDE;
    wire signed [15:0] sample_q = 16'sd0;
    wire [127:0] packed_samples = {
        sample_q, sample_i,
        sample_q, sample_i,
        sample_q, sample_i,
        sample_q, sample_i
    };

    assign m0_axis_tdata  = packed_samples;
    assign m1_axis_tdata  = packed_samples;
    assign m0_axis_tvalid = 1'b1;
    assign m1_axis_tvalid = 1'b1;
    assign tx_active      = active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active         <= 1'b0;
            phase_state    <= 1'b0;
            baud_phase     <= 32'd0;
            current_byte   <= 8'd0;
            bit_index      <= 3'd7;
            current_last   <= 1'b0;
            prefetch_byte  <= 8'd0;
            prefetch_last  <= 1'b0;
            prefetch_valid <= 1'b0;
            frame_start    <= 1'b0;
        end else begin
            frame_start <= 1'b0;

            if (!active) begin
                baud_phase  <= 32'd0;
                phase_state <= 1'b0;
                if (input_fire) begin
                    active       <= 1'b1;
                    current_byte <= s_axis_tdata[7:0];
                    current_last <= s_axis_tlast;
                    bit_index    <= 3'd7;
                    phase_state  <= s_axis_tdata[7];
                    frame_start  <= 1'b1;
                end
            end else begin
                // Capture the following byte while the current byte is on air.
                if (input_fire && !symbol_end) begin
                    prefetch_byte  <= s_axis_tdata[7:0];
                    prefetch_last  <= s_axis_tlast;
                    prefetch_valid <= 1'b1;
                end

                if (symbol_end) begin
                    baud_phase <= baud_phase + BAUD_RATE - CLK_FREQ_HZ;
                    if (bit_index != 0) begin
                        bit_index   <= bit_index - 1'b1;
                        phase_state <= phase_state ^ current_byte[bit_index - 1'b1];
                        if (input_fire) begin
                            prefetch_byte  <= s_axis_tdata[7:0];
                            prefetch_last  <= s_axis_tlast;
                            prefetch_valid <= 1'b1;
                        end
                    end else if (current_last) begin
                        active         <= 1'b0;
                        phase_state    <= 1'b0;
                        prefetch_valid <= 1'b0;
                    end else if (prefetch_valid) begin
                        current_byte   <= prefetch_byte;
                        current_last   <= prefetch_last;
                        bit_index      <= 3'd7;
                        phase_state    <= phase_state ^ prefetch_byte[7];
                        prefetch_valid <= 1'b0;
                    end else if (input_fire) begin
                        // A new byte may arrive on the exact final-symbol edge.
                        current_byte <= s_axis_tdata[7:0];
                        current_last <= s_axis_tlast;
                        bit_index    <= 3'd7;
                        phase_state  <= phase_state ^ s_axis_tdata[7];
                    end else begin
                        active      <= 1'b0;
                        phase_state <= 1'b0;
                    end
                end else begin
                    baud_phase <= baud_phase + BAUD_RATE;
                end
            end
        end
    end

endmodule
