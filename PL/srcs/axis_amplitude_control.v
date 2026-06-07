`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: axis_amplitude_control
// Description: 4-Sample Parallel IQ Amplitude Controller via VIO/Register
//              Scales 128-bit AXI-Stream DDS data (4x 16-bit I/Q) using DSP blocks.
//////////////////////////////////////////////////////////////////////////////////

module axis_amplitude_control (
    // --- 时钟与复位 ---
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET rst_n, FREQ_HZ 184320000" *)
    input  wire         clk,
    
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         rst_n,

    // --- 动态幅度控制输入 (可直接接 VIO) ---
    // 16位无符号量化系数: 
    // 16'h0000 = 静音 (系数 0)
    // 16'h7FFF = 一半幅度 (系数 0.5)
    // 16'hFFFF = 最大幅度 (系数 约1.0)
    input  wire [15:0]  amp_factor,

    // --- AXI Stream Slave 接口 (接 DDS 适配器输出) ---
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [127:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire         s_axis_tvalid,

    // --- AXI Stream Master 接口 (接 RFDC 或后续混频级) ---
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output reg  [127:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output reg          m_axis_tvalid
);

    // ------------------------------------------------------------------------
    // Step 1: 提取 4 个样点的有符号 I/Q 数据 (与原模块排布完全一致)
    // ------------------------------------------------------------------------
    wire signed [15:0] s_i0 = s_axis_tdata[15:0];
    wire signed [15:0] s_q0 = s_axis_tdata[31:16];
    wire signed [15:0] s_i1 = s_axis_tdata[47:32];
    wire signed [15:0] s_q1 = s_axis_tdata[63:48];
    wire signed [15:0] s_i2 = s_axis_tdata[79:64];
    wire signed [15:0] s_q2 = s_axis_tdata[95:80];
    wire signed [15:0] s_i3 = s_axis_tdata[111:96];
    wire signed [15:0] s_q3 = s_axis_tdata[127:112];

    // ------------------------------------------------------------------------
    // Step 2: 第一级流水线 - 有符号数与无符号数相乘 (自动映射到 DSP48E2)
    // ------------------------------------------------------------------------
    // 16位有符号 * 17位有符号(将16位无符号转为最高位为0的有符号) = 33位有符号结果
    // 为了节省资源，这里直接采用 Verilog 符号扩展特性
    reg signed [32:0] mul_i0, mul_q0;
    reg signed [32:0] mul_i1, mul_q1;
    reg signed [32:0] mul_i2, mul_q2;
    reg signed [32:0] mul_i3, mul_q3;
    reg               vld_p1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mul_i0 <= 33'd0; mul_q0 <= 33'd0;
            mul_i1 <= 33'd0; mul_q1 <= 33'd0;
            mul_i2 <= 33'd0; mul_q2 <= 33'd0;
            mul_i3 <= 33'd0; mul_q3 <= 33'd0;
            vld_p1 <= 1'b0;
        end else begin
            // $signed({1'b0, amp_factor}) 将无符号增益转为正的有符号数参与乘法
            mul_i0 <= s_i0 * $signed({1'b0, amp_factor});
            mul_q0 <= s_q0 * $signed({1'b0, amp_factor});
            mul_i1 <= s_i1 * $signed({1'b0, amp_factor});
            mul_q1 <= s_q1 * $signed({1'b0, amp_factor});
            mul_i2 <= s_i2 * $signed({1'b0, amp_factor});
            mul_q2 <= s_q2 * $signed({1'b0, amp_factor});
            mul_i3 <= s_i3 * $signed({1'b0, amp_factor});
            mul_q3 <= s_q3 * $signed({1'b0, amp_factor});
            vld_p1 <= s_axis_tvalid;
        end
    end

    // ------------------------------------------------------------------------
    // Step 3: 第二级流水线 - 截断高位输出并拼装总线
    // ------------------------------------------------------------------------
    // 乘以 16 位系数后，相当于整体数据放大了 2^16 倍，因此右移 16 位（取高位）回缩尺寸
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tdata  <= 128'd0;
            m_axis_tvalid <= 1'b0;
        end else begin
            m_axis_tdata <= {
                mul_q3[31:16], mul_i3[31:16],
                mul_q2[31:16], mul_i2[31:16],
                mul_q1[31:16], mul_i1[31:16],
                mul_q0[31:16], mul_i0[31:16]
            };
            m_axis_tvalid <= vld_p1;
        end
    end

endmodule