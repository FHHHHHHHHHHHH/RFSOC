`timescale 1ns / 1ps

module axis_broadcaster_128 (
    input  wire         clk,
    input  wire         resetn,
    input  wire [31:0]  s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire [127:0] m_axis_tdata,
    output wire         m_axis_tvalid
);

    // 提取 FIR 滤波器输出的信号 (不再做任何放大)
    wire [15:0] out_q = s_axis_tdata[31:16];
    wire [15:0] out_i = s_axis_tdata[15:0];

    // 将 32-bit 数据广播/复制 4 次，拼成 128-bit 送给 RF Data Converter
    assign m_axis_tdata = {out_q, out_i, out_q, out_i, out_q, out_i, out_q, out_i};
    assign m_axis_tvalid = s_axis_tvalid;

endmodule