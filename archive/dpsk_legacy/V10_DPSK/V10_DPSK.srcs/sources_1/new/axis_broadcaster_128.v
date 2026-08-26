`timescale 1ns / 1ps

module axis_broadcaster_128 (
    input  wire         clk,
    input  wire         resetn,
    input  wire [31:0]  s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire [127:0] m_axis_tdata,
    output wire         m_axis_tvalid
);

    // ==============================================================
    // 1. 提取 FIR 滤波器输出的原始信号 (16-bit 有符号数)
    // ==============================================================
    wire signed [15:0] original_q = s_axis_tdata[31:16];
    wire signed [15:0] original_i = s_axis_tdata[15:0];

    // ==============================================================
    // 2. 能量补偿放大 (补偿 18 倍的插值损耗)
    // ==============================================================
    // 定义足够位宽的中间变量，防止乘法过程中溢出
    wire signed [31:0] amplified_q;
    wire signed [31:0] amplified_i;

    // 乘以补偿系数 18
    assign amplified_q = original_q * 32'sd18;
    assign amplified_i = original_i * 32'sd18;

    // ==============================================================
    // 3. 饱和截断逻辑 (Saturation/Clipping) -> 极其重要！
    // ==============================================================
    // 防止放大后的信号超过 16-bit 有符号数的极限，导致波形反相撕裂
    reg signed [15:0] final_q;
    reg signed [15:0] final_i;

    always @(*) begin
        // Q 通道饱和截断
        if (amplified_q > 32'sd32767) 
            final_q = 16'sd32767;
        else if (amplified_q < -32'sd32768) 
            final_q = -16'sd32768;
        else 
            final_q = amplified_q[15:0];

        // I 通道饱和截断
        if (amplified_i > 32'sd32767) 
            final_i = 16'sd32767;
        else if (amplified_i < -32'sd32768) 
            final_i = -16'sd32768;
        else 
            final_i = amplified_i[15:0];
    end

    // ==============================================================
    // 4. 将处理后的 32-bit 数据广播/复制 4 次，拼成 128-bit 送给 RF DAC
    // ==============================================================

   // 固定复数直流输入：Q=0，I=32767
    // RFDC DAC 的 C2R mixer 会把它搬移到 DAC NCO 频率
    wire signed [15:0] test_q = 16'sd0;
    wire signed [15:0] test_i = 16'sd32767; // signed 16-bit maximum: 2^15 - 1

    assign m_axis_tdata = {
        test_q, test_i,
        test_q, test_i,
        test_q, test_i,
        test_q, test_i
    };

    assign m_axis_tvalid = 1'b1;

    //assign m_axis_tdata = {final_q, final_i, final_q, final_i, final_q, final_i, final_q, final_i};
    //assign m_axis_tvalid = s_axis_tvalid;

endmodule