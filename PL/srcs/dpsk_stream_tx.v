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

    // AXI Stream Slave 接口 (接收 FIFO 数据)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [31:0]  s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire         s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output reg          s_axis_tready,

    // VIO 幅度控制 (0~65535)
    input  wire [15:0]  amp_factor,

    // AXI Stream Master 接口 (输出给 FIR Compiler)
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output wire [31:0]  m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire         m_axis_tvalid
);

    localparam BAUD_TIMER_MAX = CLK_FREQ_HZ / BAUD_RATE;

    reg [31:0] baud_timer;
    reg [2:0]  bit_index;
    reg [7:0]  tx_byte;
    reg        active_tx;
    reg        diff_bit;

    localparam STATE_IDLE = 0;
    localparam STATE_TX   = 1;
    reg state;

    wire current_bit = tx_byte[bit_index]; 

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            baud_timer <= 0;
            bit_index <= 7;
            active_tx <= 0;
            s_axis_tready <= 0;
            diff_bit <= 0; 
        end else begin
            case (state)
                STATE_IDLE: begin
                    active_tx <= 1'b0;
                    if (s_axis_tvalid) begin
                        tx_byte <= s_axis_tdata[7:0];
                        s_axis_tready <= 1'b1; 
                        state <= STATE_TX;
                        baud_timer <= 0;
                        bit_index <= 7;
                        diff_bit <= 0; 
                    end
                end

                STATE_TX: begin
                    active_tx <= 1'b1;
                    s_axis_tready <= 1'b0; 

                    if (baud_timer >= BAUD_TIMER_MAX - 1) begin
                        baud_timer <= 0;
                        diff_bit <= diff_bit ^ current_bit;

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

    wire signed [15:0] active_i; 
    wire signed [15:0] base_i;   
    wire is_impulse;

    // 峰值给满量程，保证 FIR 有足够能量
    assign active_i = diff_bit ? -16'sd32767 : 16'sd32767; 
    assign is_impulse = (baud_timer == 0);
    assign base_i = active_tx ? (is_impulse ? active_i : 16'sd0) : 16'sd32767;

    reg signed [32:0] mul_i; 
    wire signed [15:0] mul_q = 16'd0; 

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mul_i  <= 33'd0;
        end else begin
            // 乘法器: 最大 32767 * 65535
            mul_i <= base_i * $signed({1'b0, amp_factor});
        end
    end

    // 右移 16 位，完成小数归一化
    wire signed [15:0] final_i_out = mul_i[31:16];

    assign m_axis_tdata  = {mul_q, final_i_out};
    assign m_axis_tvalid = 1'b1;

endmodule