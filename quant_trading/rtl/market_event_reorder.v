`timescale 1ns/1ps

/*
// 市场事件重排：在知道下一个事件时间前，先暂存当前事件。
// 规则：同一时间戳下，后到达的订单会先被输出，再输出之前被 hold 的 trade。
// 作用相当于把流中的事件按“时间顺序 + 事件优先级”进行重新排序。

输入
    s_axis_tdata: 128bit, 事件数据，低4bit为type，16~47bit为timestamp
    s_axis_tvalid: 输入数据有效
    s_axis_tready: 输出空闲时允许接收新数据
    s_axis_tlast: 输入数据最后一条标志
输出
    m_axis_tdata: 128bit, 输出事件数据
    128位分别是
        [3:0] type
        [15:4] 保留
        [47:16] timestamp
        [127:48] 其他数据

    m_axis_tvalid: 输出数据有效
    m_axis_tready: 输出通道空闲标志
*/

module market_event_reorder (
    input wire aclk,
    input wire aresetn,

    input wire [127:0] s_axis_tdata,
    input wire s_axis_tvalid,
    output wire s_axis_tready,
    input wire s_axis_tlast,

    output reg [127:0] m_axis_tdata,
    output reg m_axis_tvalid,
    input wire m_axis_tready,
    output reg m_axis_tlast
);

    // hold_valid: 表示当前存在一个待决定顺序的事件
    // follow_valid: 表示下一条事件已经被缓存好，需要在当前输出后立即发出
    reg hold_valid;
    reg follow_valid;
    reg [127:0] hold_data;
    reg [127:0] follow_data;
    reg hold_last;
    reg follow_last;

    // 事件内部字段解释：
    // 低 4 bit = type
    // [47:16] = timestamp
    // 这里的 hold_time 用于比较当前输入事件和暂存事件是否同一个时间。
    wire [3:0] in_type = s_axis_tdata[3:0];
    wire [31:0] in_time = s_axis_tdata[47:16];
    wire [31:0] hold_time = hold_data[47:16];

    // 输出通道空闲时，允许接受新数据并发出缓存中的 follow 事件。
    wire output_free = !m_axis_tvalid || m_axis_tready;

    // 只有当输出空闲且没有 follow 事件等待输出时，才允许接受新输入。
    assign s_axis_tready = output_free && !follow_valid;

    always @(posedge aclk) begin
        
        if (!aresetn) begin
            // 复位：清空缓存、状态和输出寄存器
            hold_valid <= 0;
            follow_valid <= 0;
            hold_data <= 0;
            follow_data <= 0;
            hold_last <= 0;
            follow_last <= 0;
            m_axis_tdata <= 0;
            m_axis_tvalid <= 0;
            m_axis_tlast <= 0;
        
        end else begin
            // 先处理当前输出通道上的握手完成
            if (m_axis_tvalid && m_axis_tready) begin
                m_axis_tvalid <= 0;
            end

            // 若存在 follow 事件，优先把它送出去
            if (output_free && follow_valid) begin
                m_axis_tdata <= follow_data;
                m_axis_tvalid <= 1;
                m_axis_tlast <= follow_last;
                follow_valid <= 0;
            end else if (s_axis_tvalid && s_axis_tready) begin
                // 这里有一个缓存的 hold 事件，需和新来的事件做顺序判断
                if (hold_valid) begin
                    // 规则：同一时间戳下，后来的 order 先出，旧的 trade 后出
                    if (in_type == 4'd1 && in_time == hold_time) begin
                        m_axis_tdata <= s_axis_tdata;
                        m_axis_tvalid <= 1;
                        m_axis_tlast <= 0;

                        follow_data <= hold_data;
                        follow_last <= hold_last;
                        follow_valid <= 1;
                        hold_valid <= 0;
                    end else begin
                        // 时间不等或类型不匹配时，先输出暂存的 hold 事件
                        m_axis_tdata <= hold_data;
                        m_axis_tvalid <= 1;
                        m_axis_tlast <= hold_last;

                        // 如果新事件属于需要延迟的类型，就保留到下一轮，否则进入 follow 缓存
                        if (in_type == 4'd3) begin
                            hold_data <= s_axis_tdata;
                            hold_last <= s_axis_tlast;
                            hold_valid <= 1;
                        end else begin
                            follow_data <= s_axis_tdata;
                            follow_last <= s_axis_tlast;
                            follow_valid <= 1;
                            hold_valid <= 0;
                        end
                    end
                end else if (in_type == 4'd3) begin
                    // 需要暂存的事件：等待下一个事件来决定最终顺序
                    hold_data <= s_axis_tdata;
                    hold_last <= s_axis_tlast;
                    hold_valid <= 1;
                end else begin
                    // 普通事件，直接输出
                    m_axis_tdata <= s_axis_tdata;
                    m_axis_tvalid <= 1;
                    m_axis_tlast <= s_axis_tlast;
                end
            end
        end
    end
endmodule
