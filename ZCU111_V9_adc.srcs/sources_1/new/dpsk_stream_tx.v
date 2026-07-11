`timescale 1ns / 1ps

module dpsk_stream_tx #(
    parameter CLK_FREQ_HZ = 184_320_000,
    parameter BAUD_RATE   = 10_000_000
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis:s_axis, ASSOCIATED_RESET rst_n" *)
    input  wire         clk,
    
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         rst_n,

    // AXI Stream Slave 接口 (接收来自 ARM/FIFO 的数据)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [31:0]  s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire         s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output reg          s_axis_tready,

    // 【已删除 VIO amp_factor 接口】

    // AXI Stream Master 接口 (全精度输出到 FIR 滤波器)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output wire [31:0]  m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire         m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input  wire         m_axis_tready
);

    localparam BAUD_TIMER_MAX = CLK_FREQ_HZ / BAUD_RATE;

    localparam STATE_IDLE = 2'd0;
    localparam STATE_TX   = 2'd1;

    reg [1:0]  state;
    reg [31:0] baud_timer;
    reg [7:0]  shift_reg;
    reg [2:0]  bit_index;

    wire current_bit = shift_reg[bit_index];
    reg  diff_bit;
    reg  active_tx;

    // 永远输出有效数据，保持下游 FIR 和 DAC 处于连续工作状态
    assign m_axis_tvalid = 1'b1; 

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= STATE_IDLE;
            baud_timer    <= 0;
            shift_reg     <= 8'd0;
            bit_index     <= 3'd7;
            diff_bit      <= 1'b0;
            s_axis_tready <= 1'b0;
            active_tx     <= 1'b0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    active_tx <= 1'b0;
                    s_axis_tready <= 1'b1;

                    if (s_axis_tvalid && s_axis_tready) begin
                        shift_reg     <= s_axis_tdata[7:0];
                        bit_index     <= 3'd7;
                        state         <= STATE_TX;
                        baud_timer    <= 0;
                        s_axis_tready <= 1'b0;
                    end
                end

                STATE_TX: begin
                    active_tx <= 1'b1;
                    s_axis_tready <= 1'b0; 

                    if (baud_timer >= BAUD_TIMER_MAX - 1) begin
                        baud_timer <= 0;
                        diff_bit   <= diff_bit ^ current_bit;

                        if (bit_index == 0) begin
                            state <= STATE_IDLE; 
                        end else begin
                            bit_index <= bit_index - 1;
                        end
                    end else begin
                        baud_timer <= baud_timer + 1;
                    end
                end
            endcase
        end
    end

    // ==========================================
    // 全精度数据生成与输出 (无乘法器直通)
    // ==========================================
    wire signed [15:0] active_i; 
    wire signed [15:0] base_i;   
    wire is_impulse;

    // 峰值给 16-bit 满量程
    assign active_i = diff_bit ? -16'sd32767 : 16'sd32767; 
    assign is_impulse = (baud_timer == 0);
    
    // 【核心架构魔法】
    // active_tx = 0 (无发射数据时): 输出满量程直流 +32767，配合 NCO 输出 CW 单音
    // active_tx = 1 (发射数据时): 输出 DPSK 冲激序列给 FIR 成型
    assign base_i = active_tx ? (is_impulse ? active_i : 16'sd0) : 16'sd32767;

    // Q 通道置 0 (因为我们是单边带调制，靠后续 NCO 变频)
    wire signed [15:0] out_q = 16'd0; 
    
    // 直接将 I/Q 拼接输出，避免原版的位截断损失
    assign m_axis_tdata = {out_q, base_i};

endmodule