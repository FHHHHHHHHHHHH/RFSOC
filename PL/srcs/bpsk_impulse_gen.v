`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: dpsk_impulse_gen_vio
// Description: DPSK Impulse Generator with VIO Amplitude Control
//              Generates 10Mbps (or 1Mbps) DPSK impulses using Differential Encoding.
//              Designed to feed into an FIR Compiler for RRC pulse shaping.
//////////////////////////////////////////////////////////////////////////////////

module bpsk_impulse_gen_vio #(
    parameter CLK_FREQ_HZ = 184_320_000, 
    // 根据你上一步的选择，这里默认保留 10 Mbps。如果是 1 Mbps，改回 1_000_000 即可
    parameter BAUD_RATE   = 10_000_000   
)(
    // --- 时钟与复位 ---
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis, ASSOCIATED_RESET rst_n, FREQ_HZ 184320000" *)
    input  wire         clk,
    
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         rst_n,

    // --- VIO 动态幅度控制输入 ---
    input  wire [15:0]  amp_factor,

    // --- AXI Stream Master 接口 ---
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axis, MODE MASTER, FREQ_HZ 184320000" *)
    output reg  [31:0]  m_axis_tdata,
    
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output reg          m_axis_tvalid
);

    // ------------------------------------------------------------------------
    // Step 1: 循环读取信息与波特率冲激生成
    // ------------------------------------------------------------------------
    localparam MSG_LEN_BITS = 25; // 5 bytes = 40 bits 
    reg [MSG_LEN_BITS-1:0] msg_rom = 25'b1111_0000_1111_0000_1010_1010_1;

    localparam BAUD_TIMER_MAX = CLK_FREQ_HZ / BAUD_RATE;
    reg [31:0] baud_timer;
    reg [7:0]  bit_index;
    
    // 【核心修改点】新增差分编码相关的寄存器
    reg        raw_bit;       // 从 ROM 读出的原始数据比特
    reg        encoded_bit;   // 经过差分编码后实际要发送的比特
    reg        is_impulse;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            baud_timer  <= 0;
            bit_index   <= MSG_LEN_BITS - 1;
            raw_bit     <= 0;
            encoded_bit <= 0; // 差分编码初始状态通常为 0
            is_impulse  <= 0;
        end else begin
            if (baud_timer >= BAUD_TIMER_MAX - 1) begin
                baud_timer  <= 0;
                
                // 1. 读取当前的原始比特
                raw_bit <= msg_rom[bit_index];
                
                // 2. 执行差分编码逻辑 (Differential Encoding)
                // 规则：新比特 = 原始比特 XOR 上一个已发送比特
                // - 如果原始比特是 0：编码比特保持与上一次相同 (相位不变)
                // - 如果原始比特是 1：编码比特翻转 (相位翻转 180 度)
                encoded_bit <= msg_rom[bit_index] ^ encoded_bit; 

                is_impulse  <= 1'b1; // 发出单周期冲激
                
                if (bit_index == 0) bit_index <= MSG_LEN_BITS - 1; 
                else                bit_index <= bit_index - 1;
            end else begin
                baud_timer <= baud_timer + 1;
                is_impulse <= 1'b0;  // 符号周期的其余时间保持为0
            end
        end
    end

    // ------------------------------------------------------------------------
    // Step 2: 提取基准幅度 (基于编码后的比特映射)
    // ------------------------------------------------------------------------
    // 注意这里使用 encoded_bit 决定极性
    wire signed [15:0] active_i = (encoded_bit == 1'b0) ? 16'h7FFF : -16'h7FFF;
    wire signed [15:0] base_i   = is_impulse ? active_i : 16'd0;
    wire signed [15:0] base_q   = 16'd0;

    // ------------------------------------------------------------------------
    // Step 3: 第一级流水线 - 将基准冲激与 VIO 幅度因子相乘
    // ------------------------------------------------------------------------
    reg signed [32:0] mul_i;
    reg signed [32:0] mul_q;
    reg               vld_p1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mul_i  <= 33'd0;
            mul_q  <= 33'd0;
            vld_p1 <= 1'b0;
        end else begin
            mul_i  <= base_i * $signed({1'b0, amp_factor});
            mul_q  <= base_q * $signed({1'b0, amp_factor});
            vld_p1 <= 1'b1; 
        end
    end

    // ------------------------------------------------------------------------
    // Step 4: 第二级流水线 - 截断恢复至16位，打包为 32-bit AXI-Stream
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tdata  <= 32'd0;
            m_axis_tvalid <= 1'b0;
        end else begin
            m_axis_tdata  <= {mul_q[31:16], mul_i[31:16]};
            m_axis_tvalid <= vld_p1;
        end
    end

endmodule