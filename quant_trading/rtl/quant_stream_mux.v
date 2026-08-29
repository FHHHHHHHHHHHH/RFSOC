`timescale 1ns/1ps

// 流式数据选择器：在 snapshot 和 signal 两条 AXIS 流之间按优先级切换。
// 这里的语义是：当前输出通道空闲时，如果 signal 流有效，则优先输出 signal，
// 否则输出 snapshot。这样可以在不同源数据之间做简单的时间复用。

/*
输入：
    来自 nn_decision_engine_ip 的信号流
    s_snapshot_tdata: 256bit, 快照数据
    s_snapshot_tvalid: 快照数据有效
    s_snapshot_tready: 快照输出通道空闲标志
    s_snapshot_tlast: 快照数据最后一条标志

    来自 order_book_engine_ip 的快照流
    s_signal_tdata: 64bit, 决策信号数据
    s_signal_tvalid: 决策信号数据有效
    s_signal_tready: 决策信号输出通道空闲标志
    s_signal_tlast: 决策信号数据最后一条标志

功能是
    在 snapshot 流和 signal 流之间做选择，输出到 m_axis_tdata。
    优先级：当 signal 流有效时，优先输出 signal；否则输出 snapshot。
    输出数据宽度为 256bit，signal 流数据会被扩展为高位填充 0。
输出：
    m_axis_tdata: 256bit, 输出数据
    m_axis_tvalid: 输出数据有效
    m_axis_tready: 输出通道空闲标志
    m_axis_tlast: 输出数据最后一条标志

    决策信号包括
        1. 买卖方向（1bit）：0 表示买，1 表示卖
        2. 价格档位（15bit）：表示买卖的价格档位
        3. 数量档位（16bit）：表示买卖的数量档位
        4. 保留字段（32bit）：用于扩展或其他用途
    快照数据包括
        1. 时间戳（64bit）：表示当前快照的时间
        2. 成交价格（32bit）：表示最近一次成交的价格
        3. 买卖档位（32bit）：表示当前买卖的档位
        4. 证券代码（32bit）：表示当前快照对应的证券代码

*/

module quant_stream_mux (
    input wire aclk,
    input wire aresetn,

    input wire [255:0] s_snapshot_tdata,
    input wire s_snapshot_tvalid,
    output wire s_snapshot_tready,
    input wire s_snapshot_tlast,

    input wire [63:0] s_signal_tdata,
    input wire s_signal_tvalid,
    output wire s_signal_tready,
    input wire s_signal_tlast,

    output reg [255:0] m_axis_tdata,
    output reg m_axis_tvalid,
    input wire m_axis_tready,
    output reg m_axis_tlast
);

    reg select_signal;

    // 输出寄存器为空，或当前输出会在本周期完成握手时，可以接收下一拍。
    wire output_ready = !m_axis_tvalid || m_axis_tready;

    // signal 具有更高优先级；snapshot 仅在没有有效 signal 时获得 ready。
    assign s_signal_tready = output_ready;
    assign s_snapshot_tready = output_ready && !s_signal_tvalid;

    always @(posedge aclk) begin
        if (!aresetn) begin
            select_signal <= 0;
            m_axis_tvalid <= 0;
            m_axis_tdata <= 0;
            m_axis_tlast <= 0;
        end else if (output_ready) begin
            if (s_signal_tvalid && s_signal_tready) begin
                select_signal <= 1;
                m_axis_tdata <= {{192{1'b0}}, s_signal_tdata};
                m_axis_tvalid <= 1;
                m_axis_tlast <= s_signal_tlast;
            end else if (s_snapshot_tvalid && s_snapshot_tready) begin
                select_signal <= 0;
                m_axis_tdata <= s_snapshot_tdata;
                m_axis_tvalid <= 1;
                m_axis_tlast <= s_snapshot_tlast;
            end else begin
                m_axis_tvalid <= 0;
            end
        end
    end
endmodule
