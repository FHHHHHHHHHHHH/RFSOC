`timescale 1ns / 1ps
module dpsk_stream_tx #(
    parameter integer CLK_FREQ_HZ = 184_320_000,
    parameter integer BAUD_RATE = 10_000_000
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis:s_axis, ASSOCIATED_RESET rst_n" *)
    input wire clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input wire rst_n,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input wire [31:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input wire s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output wire s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output wire [31:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input wire m_axis_tready
);
    localparam STATE_IDLE = 1'b0, STATE_TX = 1'b1;
    reg state, diff_bit, symbol_impulse;
    reg [31:0] baud_phase;
    reg [7:0] shift_reg;
    reg [2:0] bit_index;
    wire transfer = m_axis_tvalid && m_axis_tready;
    wire symbol_end = baud_phase >= (CLK_FREQ_HZ - BAUD_RATE);
    wire signed [15:0] symbol_i = diff_bit ? -16'sd32767 : 16'sd32767;
    wire signed [15:0] base_i = state == STATE_IDLE ? 16'sd32767 :
                               (symbol_impulse ? symbol_i : 16'sd0);
    assign m_axis_tvalid = 1'b1;
    assign m_axis_tdata = {16'd0, base_i};
    assign s_axis_tready = (state == STATE_IDLE) && m_axis_tready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE; diff_bit <= 1'b0; symbol_impulse <= 1'b0; baud_phase <= 0;
            shift_reg <= 0; bit_index <= 3'd7;
        end else if (transfer) begin
            if (state == STATE_IDLE) begin
                if (s_axis_tvalid && s_axis_tready) begin
                    shift_reg <= s_axis_tdata[7:0]; bit_index <= 3'd7;
                    diff_bit <= diff_bit ^ s_axis_tdata[7];
                    baud_phase <= 0; symbol_impulse <= 1'b1; state <= STATE_TX;
                end
            end else if (symbol_end) begin
                baud_phase <= baud_phase + BAUD_RATE - CLK_FREQ_HZ;
                symbol_impulse <= 1'b1;
                if (bit_index == 0) begin
                    state <= STATE_IDLE;
                    symbol_impulse <= 1'b0;
                end
                else begin
                    bit_index <= bit_index - 1'b1;
                    diff_bit <= diff_bit ^ shift_reg[bit_index - 1'b1];
                end
            end else begin
                baud_phase <= baud_phase + BAUD_RATE;
                symbol_impulse <= 1'b0;
            end
        end
    end
endmodule
