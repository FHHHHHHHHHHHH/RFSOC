`timescale 1ns/1ps

// 量化神经网络决策壳层。
// AXIS 帧长度固定为 64 bit，便于后续用 HLS 或更大规模 RTL CNN 核替换本模块。
// 当前实现只是一个占位型决策输出，负责接收特征并输出一条固定格式的信号。
module nn_decision_engine_ip #(
    parameter integer FEAT_WIDTH = 256,
    parameter integer SIGNAL_WIDTH = 64
) (
    input wire aclk,
    input wire aresetn,

    // AXI-Lite 控制接口
    input wire [7:0] s_axi_ctrl_awaddr,
    input wire s_axi_ctrl_awvalid,
    output wire s_axi_ctrl_awready,
    input wire [31:0] s_axi_ctrl_wdata,
    input wire [3:0] s_axi_ctrl_wstrb,
    input wire s_axi_ctrl_wvalid,
    output wire s_axi_ctrl_wready,
    output wire [1:0] s_axi_ctrl_bresp,
    output wire s_axi_ctrl_bvalid,
    input wire s_axi_ctrl_bready,
    input wire [7:0] s_axi_ctrl_araddr,
    input wire s_axi_ctrl_arvalid,
    output wire s_axi_ctrl_arready,
    output wire [31:0] s_axi_ctrl_rdata,
    output wire [1:0] s_axi_ctrl_rresp,
    output wire s_axi_ctrl_rvalid,
    input wire s_axi_ctrl_rready,

    // 特征输入 AXIS
    input wire [FEAT_WIDTH-1:0] s_axis_feat_tdata,
    input wire s_axis_feat_tvalid,
    output wire s_axis_feat_tready,
    input wire s_axis_feat_tlast,

    // 决策输出 AXIS
    output reg [SIGNAL_WIDTH-1:0] m_axis_signal_tdata,
    output reg m_axis_signal_tvalid,
    input wire m_axis_signal_tready,
    output reg m_axis_signal_tlast
);

    reg [31:0] threshold;
    reg [31:0] inference_count;
    reg aw_hold;
    reg w_hold;
    reg b_hold;
    reg r_hold;
    reg [31:0] awaddr;
    reg [31:0] wdata;
    reg [31:0] rdata;
    reg [3:0] wstrb;

    assign s_axi_ctrl_awready = !aw_hold && !b_hold;
    assign s_axi_ctrl_wready = !w_hold && !b_hold;
    assign s_axi_ctrl_bresp = 0;
    assign s_axi_ctrl_bvalid = b_hold;
    assign s_axi_ctrl_arready = !r_hold;
    assign s_axi_ctrl_rdata = rdata;
    assign s_axi_ctrl_rresp = 0;
    assign s_axi_ctrl_rvalid = r_hold;
    assign s_axis_feat_tready = !m_axis_signal_tvalid || m_axis_signal_tready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            threshold <= 32'd128;
            inference_count <= 0;
            aw_hold <= 0;
            w_hold <= 0;
            b_hold <= 0;
            r_hold <= 0;
            awaddr <= 0;
            wdata <= 0;
            wstrb <= 0;
            rdata <= 0;
            m_axis_signal_tdata <= 0;
            m_axis_signal_tvalid <= 0;
            m_axis_signal_tlast <= 0;
        end else begin
            if (s_axi_ctrl_awvalid && s_axi_ctrl_awready) begin
                aw_hold <= 1;
                awaddr <= s_axi_ctrl_awaddr;
            end
            if (s_axi_ctrl_wvalid && s_axi_ctrl_wready) begin
                w_hold <= 1;
                wdata <= s_axi_ctrl_wdata;
                wstrb <= s_axi_ctrl_wstrb;
            end
            if (aw_hold && w_hold && !b_hold) begin
                if (awaddr[7:2] == 0) begin
                    threshold <= wdata;
                end
                aw_hold <= 0;
                w_hold <= 0;
                b_hold <= 1;
            end
            if (b_hold && s_axi_ctrl_bready) begin
                b_hold <= 0;
            end

            if (s_axi_ctrl_arvalid && s_axi_ctrl_arready) begin
                case (s_axi_ctrl_araddr[7:2])
                    0: rdata <= threshold;
                    1: rdata <= inference_count;
                    default: rdata <= 32'h4E4E3031;
                endcase
                r_hold <= 1;
            end
            if (r_hold && s_axi_ctrl_rready) begin
                r_hold <= 0;
            end

            if (m_axis_signal_tvalid && m_axis_signal_tready) begin
                m_axis_signal_tvalid <= 0;
            end

            if (s_axis_feat_tvalid && s_axis_feat_tready) begin
                // 占位输出格式：{type, confidence, target price, quantity}
                m_axis_signal_tdata <= {8'h00, 8'h80, s_axis_feat_tdata[31:0], 16'h0001};
                m_axis_signal_tvalid <= 1;
                m_axis_signal_tlast <= s_axis_feat_tlast;
                inference_count <= inference_count + 1'b1;
            end
        end
    end
endmodule
