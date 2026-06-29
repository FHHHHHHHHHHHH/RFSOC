`timescale 1ns / 1ps

module axis_broadcaster_128 (
    input  wire         clk,
    input  wire         resetn,
    input  wire [31:0]  s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire [127:0] m_axis_tdata,
    output wire         m_axis_tvalid
);

    // 提取 FIR 滤波器输出的微弱信号
    wire signed [15:0] fir_q = s_axis_tdata[31:16];
    wire signed [15:0] fir_i = s_axis_tdata[15:0];

    // --- 数字前置放大器 (x128 增益) ---
    // 左移 7 位补偿过采样带来的能量损失，使用 24 位宽防止中间计算溢出
    wire signed [23:0] gain_q = fir_q * 128;
    wire signed [23:0] gain_i = fir_i * 128;

    // --- 饱和截断保护 (Clipping) ---
    // 如果放大后的数值超过了 16-bit 有符号数的极限，强制锁定在最大/最小值，防止波形反相
    wire [15:0] out_q = (gain_q > 32767) ? 16'd32767 : (gain_q < -32768) ? -16'd32768 : gain_q[15:0];
    wire [15:0] out_i = (gain_i > 32767) ? 16'd32767 : (gain_i < -32768) ? -16'd32768 : gain_i[15:0];

    // 重新打包为单采样点
    wire [31:0] boosted_sample = {out_q, out_i};

    // 1分4广播到 128-bit 总线
    assign m_axis_tdata  = {4{boosted_sample}}; 
    assign m_axis_tvalid = s_axis_tvalid;

endmodule