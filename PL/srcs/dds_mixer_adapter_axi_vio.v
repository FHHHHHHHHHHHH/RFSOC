`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: dds_mixer_adapter_axi_vio
// Description: 4-Sample Parallel DDS with Dynamic VIO Phase Offset
//////////////////////////////////////////////////////////////////////////////////

module dds_mixer_adapter_axi_vio #(
    parameter PHASE_STEP = 16'h0379 
)(
    // --- 针对 Block Design 的时钟与复位属性绑定 ---
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis, ASSOCIATED_RESET rst_n, FREQ_HZ 184320000" *)
    input  wire         clk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         rst_n,

    // --- VIO 动态相位偏移输入 ---
    // 在 BD 中连到 VIO IP 的输出，可实时改变本模块与其它模块的相位差
    input  wire [31:0]  vio_phase_offset,
    
    // --- AXI Stream Master 接口对接 DAC ---
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output wire [127:0] m_axis_tdata,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire         m_axis_tvalid
);

    // 内部寄存器与线网声明
    reg  [15:0] base_phase;     // 内部自由运转的基准相位累加器
    reg  [15:0] phase [3:0];    // 送给 4 个 DDS 的最终相位
    
    wire [31:0] dds_data [3:0];
    wire [3:0]  dds_valid;
    
    wire [15:0] dac_data_i0, dac_data_q0;
    wire [15:0] dac_data_i1, dac_data_q1;
    wire [15:0] dac_data_i2, dac_data_q2;
    wire [15:0] dac_data_i3, dac_data_q3;

    // --- 核心改动：动态相位计算逻辑 ---
    // 将自由运转的频率累加 和 静态的相位偏移 分离
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            base_phase <= 16'd0;
            phase[0]   <= 16'd0;
            phase[1]   <= PHASE_STEP;
            phase[2]   <= PHASE_STEP * 2; 
            phase[3]   <= PHASE_STEP * 3; 
        end
        else begin
            // 1. 基准相位永远按 4 倍步进无脑累加，维持中心频率不断
            base_phase <= base_phase + (PHASE_STEP << 2);
            
            // 2. 最终送给 DDS 的相位 = 基准相位 + 固定的通道间偏差 + VIO 传进来的相位差
            // 取 vio_phase_offset 的低 16 位参与计算
            phase[0] <= base_phase + vio_phase_offset[15:0];
            phase[1] <= base_phase + vio_phase_offset[15:0] + PHASE_STEP;
            phase[2] <= base_phase + vio_phase_offset[15:0] + (PHASE_STEP << 1); // <<1 等于 *2
            phase[3] <= base_phase + vio_phase_offset[15:0] + (PHASE_STEP * 3);
        end
    end

    // 并行例化 4 个 DDS IP
    // 前提：工程中已经生成了名为 "dds_compiler_0" 的全局综合 IP
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : dds_chan
            dds_compiler_0 u_dds (
                .aclk                (clk),                   
                .aresetn             (rst_n),                 
                .s_axis_phase_tvalid (1'b1),                  
                .s_axis_phase_tdata  (phase[i]),              
                .m_axis_data_tvalid  (dds_valid[i]),          
                .m_axis_data_tdata   (dds_data[i])            
            );
        end
    endgenerate

    // 提取 IQ 数据
    assign dac_data_i0 = dds_data[0][31:16];  
    assign dac_data_q0 = dds_data[0][15:0];
    assign dac_data_i1 = dds_data[1][31:16];
    assign dac_data_q1 = dds_data[1][15:0];
    assign dac_data_i2 = dds_data[2][31:16];
    assign dac_data_q2 = dds_data[2][15:0];
    assign dac_data_i3 = dds_data[3][31:16];
    assign dac_data_q3 = dds_data[3][15:0];

    // 将 4 个点合并 (Xilinx 规范: Sample 0 在低位，Sample 3 在高位)
    assign m_axis_tdata = {dac_data_q3, dac_data_i3,
                           dac_data_q2, dac_data_i2,
                           dac_data_q1, dac_data_i1,
                           dac_data_q0, dac_data_i0};

    // 输出 valid (4个通道同步，取通道 0 即可)
    assign m_axis_tvalid = dds_valid[0];

endmodule