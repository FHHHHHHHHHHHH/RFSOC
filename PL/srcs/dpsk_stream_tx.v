`timescale 1ns / 1ps

module dpsk_stream_tx #(
    // 修改为实际的 RF 时钟频率 184.32 MHz
    parameter CLK_FREQ_HZ = 184_320_000, 
    parameter BAUD_RATE   = 10_000_000
)(
    // --- 时钟与复位 (删除了 FREQ_HZ 强约束，让 Vivado 自动继承连接线的频率) ---
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis:s_axis, ASSOCIATED_RESET rst_n" *)
    input  wire         clk,
    
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         rst_n,

    // --- AXI Stream Slave 接口 (接收来自 FIFO 的字节流) ---
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [31:0]   s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire         s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output reg          s_axis_tready,

    // --- VIO 幅度控制 ---
    input  wire [15:0]  amp_factor,

    // --- AXI Stream Master 接口 (输出给 FIR Compiler, 32-bit) ---
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output reg  [31:0]  m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output reg          m_axis_tvalid
);

    localparam BAUD_TIMER_MAX = CLK_FREQ_HZ / BAUD_RATE;
    
    // 突发发送状态机
    localparam STATE_IDLE = 1'b0;
    localparam STATE_TX   = 1'b1;
    
    reg        state;
    reg [31:0] baud_timer;
    reg [2:0]  bit_index;
    reg [7:0]  tx_byte;
    
    reg        encoded_bit;
    reg        is_impulse;
    reg        active_tx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= STATE_IDLE;
            s_axis_tready <= 1'b0;
            baud_timer    <= 0;
            bit_index     <= 7;
            encoded_bit   <= 1'b0;
            is_impulse    <= 1'b0;
            active_tx     <= 1'b0;
        end else begin
            is_impulse <= 1'b0; // 默认无冲激

            case (state)
                // 空闲状态，等待 FIFO 数据
                STATE_IDLE: begin
                    active_tx <= 1'b0;
                    if (s_axis_tvalid) begin
                        // FIFO 中有数据，读取一个字节
                        // 虽然收到了 32 位，但我们只截取最低的 8 位作为有效字节发送
                        tx_byte       <= s_axis_tdata[7:0];
                        s_axis_tready <= 1'b1; // 发出读取握手信号
                        state         <= STATE_TX;
                        baud_timer    <= BAUD_TIMER_MAX - 1; // 强制下一个时钟立刻触发发送
                        bit_index     <= 7;    // 从最高位(MSB)开始发送
                    end else begin
                        s_axis_tready <= 1'b0;
                    end
                end

                // 发送状态，逐位发送字节
                // baud_timer 用于控制每个比特的发送间隔，确保按照设定的波特率发送
                STATE_TX: begin
                    s_axis_tready <= 1'b0; // 停止读取，专心发送当前字节
                    active_tx     <= 1'b1;
                    
                    if (baud_timer >= BAUD_TIMER_MAX - 1) begin
                        baud_timer <= 0;
                        
                        // DPSK 差分编码: 新比特 = 原比特 XOR 上一个已发比特
                        encoded_bit <= tx_byte[bit_index] ^ encoded_bit;
                        is_impulse  <= 1'b1; // 在符号起点产生一次冲激
                        
                        if (bit_index == 0) begin
                            state <= STATE_IDLE; // 一个字节发完，回IDLE检查FIFO是否还有数据
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

    // ------------------------------------------------------------------------
    // 基带映射与幅度控制 (新版本 - 连续波待机 + 突发 DPSK)
    // ------------------------------------------------------------------------
    wire signed [15:0] active_i;
    wire signed [15:0] base_i;
    wire signed [15:0] base_q = 16'd0; // BPSK/DPSK Q通道永远为0

    // 判断当前的比特极性
    assign active_i = (encoded_bit == 1'b0) ? 16'h7FFF : -16'h7FFF;

    // 核心切换逻辑：
    // 如果处于发送状态 (active_tx == 1)：只有在冲激时刻 (is_impulse == 1) 才输出冲激值，否则输出 0 等待 FIR 滤波。
    // 如果处于空闲状态 (active_tx == 0)：永远持续输出正向最大直流值 (16'h7FFF)，以维持连续波。
    assign base_i = active_tx ? (is_impulse ? active_i : 16'd0) : 16'h7FFF;

    reg signed [32:0] mul_i, mul_q;
    reg               vld_p1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mul_i  <= 33'd0;
            mul_q  <= 33'd0;
            vld_p1 <= 1'b0;
            m_axis_tdata  <= 32'd0;
            m_axis_tvalid <= 1'b0;
        end else begin
            // 级联乘法 (VIO 幅度控制)
            mul_i  <= base_i * $signed({1'b0, amp_factor});
            mul_q  <= base_q * $signed({1'b0, amp_factor});
            vld_p1 <= 1'b1; // 永久输出(含静默的0)，维持 FIR 滤波器的数据流运转
            
            // AXI-Stream 打包输出 {Q, I}
            m_axis_tdata  <= {mul_q[31:16], mul_i[31:16]};
            m_axis_tvalid <= vld_p1;
        end
    end

endmodule