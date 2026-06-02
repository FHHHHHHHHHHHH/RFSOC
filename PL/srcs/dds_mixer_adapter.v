`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/03/03 09:55:41
// Design Name: 
// Module Name: dds_mixer_adapter_axi
// Project Name: 
// Target Devices: Xilinx RFSoC
// Description: 4-Sample Parallel DDS Generator for RF-DAC (184.32 MHz Clock)
//////////////////////////////////////////////////////////////////////////////////

module dds_mixer_adapter_axi #(
    // 将相位步进做成参数，方便在顶层直接修改目标频率
    // 默认 16'h0200 = 512, 对应基带频率 5.76 MHz
    // 如果想生成 10 MHz，可以改成 16'h0379
    parameter PHASE_STEP = 16'h0379
)(
    // 系统时钟与复位输入
    input  wire         clk,    // 184.32 Mhz
    input  wire         rst_n,
    
    // 输出端：强制设为 MASTER 模式，对接 RFDC
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axis, MODE MASTER, FREQ_HZ 184320000" *)
    output wire [127:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire         m_axis_tvalid
);

    // 内部寄存器与线网声明
    reg  [15:0] phase [3:0];
    wire [31:0] dds_data [3:0];
    wire [3:0]  dds_valid; // 用于分别接 4 个 DDS 的 valid 输出
    
    wire [15:0] dac_data_i0, dac_data_q0;
    wire [15:0] dac_data_i1, dac_data_q1;
    wire [15:0] dac_data_i2, dac_data_q2;
    wire [15:0] dac_data_i3, dac_data_q3;

    // 相位累加器逻辑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 复位时，赋予 4 个 DDS 阶梯状的初始相位差
            phase[0] <= 16'd0;
            phase[1] <= PHASE_STEP;
            phase[2] <= PHASE_STEP + PHASE_STEP; 
            phase[3] <= PHASE_STEP + PHASE_STEP + PHASE_STEP; 
        end
        else begin
            // 正常运行时，每个时钟周期累加量为 4 倍步进值 (<< 2)
            phase[0] <= phase[0] + (PHASE_STEP << 2);
            phase[1] <= phase[1] + (PHASE_STEP << 2);
            phase[2] <= phase[2] + (PHASE_STEP << 2);
            phase[3] <= phase[3] + (PHASE_STEP << 2);
        end
    end

    // 并行例化 4 个 DDS IP
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : dds_chan
            dds_compiler_0 dds_compiler (
                .aclk                (clk),                   
                .aresetn             (rst_n),                 
                .s_axis_phase_tvalid (1'b1),                  
                .s_axis_phase_tdata  (phase[i]),              
                .m_axis_data_tvalid  (dds_valid[i]),          
                .m_axis_data_tdata   (dds_data[i])            
            );
        end
    endgenerate

    // 提取 IQ 数据 (根据你的习惯：[31:16]为I, [15:0]为Q)
    assign dac_data_i0 = dds_data[0][31:16];  
    assign dac_data_q0 = dds_data[0][15:0];
    assign dac_data_i1 = dds_data[1][31:16];
    assign dac_data_q1 = dds_data[1][15:0];
    assign dac_data_i2 = dds_data[2][31:16];
    assign dac_data_q2 = dds_data[2][15:0];
    assign dac_data_i3 = dds_data[3][31:16];
    assign dac_data_q3 = dds_data[3][15:0];

    // 将4个点的连续 Q,I 数据合并到一个总线上
    // Xilinx 排序标准：Sample 0 在低位，Sample 3 在高位
    assign m_axis_tdata = {dac_data_q3, dac_data_i3,
                           dac_data_q2, dac_data_i2,
                           dac_data_q1, dac_data_i1,
                           dac_data_q0, dac_data_i0};

    // 因为 4 个 DDS 是同步运行的，随便取一个通道的 valid 作为总线的 valid 即可
    assign m_axis_tvalid = dds_valid[0];

endmodule