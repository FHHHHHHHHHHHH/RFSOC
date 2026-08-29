`timescale 1ns/1ps

// 流式 L2 订单簿引擎。
// 本地字典采用开放寻址的 1024 项哈希表，适合 BRAM 友好存储。
// 外部真正的双端口 BRAM 接口用于镜像 {valid, side, remaining_qty, order_id, price_delta}
// 以供 PS / debug 查看。
// BRAM_ADDR_WIDTH 代表 Vivado BRAM 接口宽度（blk_mem_gen 通常是 32 bit），
// 真正使用到的仅是 HASH_BITS 低位，保证 1024-entry 表索引有效。

/*
输入
    s_axis_decoded_tdata: 128bit, 解码后的订单事件数据
    s_axis_decoded_tvalid: 输入数据有效
    s_axis_decoded_tready: 输出空闲时允许接收新数据
    s_axis_decoded_tlast: 输入数据最后一条标志

输出
    m_axis_snapshot_tdata: 256bit, 输出订单簿快照数据
    m_axis_snapshot_tvalid: 输出数据有效
    m_axis_snapshot_tready: 输出通道空闲标志
    m_axis_snapshot_tlast: 输出数据最后一条标志

功能：
    1. 接收解码后的订单事件，按 order_id 在本地哈希表中查找。
    2. 根据事件类型（新增、修改、取消）更新哈希表和价格/数量等级。
    3. 输出当前订单簿快照，包括 bid/ask 价格和数量的各层信息。
    4. 提供 AXI-Lite 控制接口，用于配置和状态监控。
    5. 提供 BRAM 接口，用于调试镜像和外部状态查看。

接受来自market_event_reorder的事件流，按时间戳和事件优先级进行处理，确保订单簿状态的一致性和正确性。
输出给quant_stream_mux的快照流，供后续处理或决策模块使用。
输出给nn_decision_engine_ip的信号流，供神经网络决策模块使用。
*/

module order_book_engine_ip #(
    parameter integer DECODED_WIDTH = 128,
    parameter integer SNAPSHOT_WIDTH = 256,
    parameter integer BRAM_ADDR_WIDTH = 32,
    parameter integer BRAM_DATA_WIDTH = 64
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

    // 解码后的订单事件输入 AXIS
    input wire [DECODED_WIDTH-1:0] s_axis_decoded_tdata,
    input wire s_axis_decoded_tvalid,
    output wire s_axis_decoded_tready,
    input wire s_axis_decoded_tlast,

    // 订单薄快照输出 AXIS
    output reg [SNAPSHOT_WIDTH-1:0] m_axis_snapshot_tdata,
    output reg m_axis_snapshot_tvalid,
    input wire m_axis_snapshot_tready,
    output reg m_axis_snapshot_tlast,

    // BRAM 接口，用于调试镜像和外部状态查看
    output wire bram_clk,
    output reg bram_en,
    output reg [BRAM_ADDR_WIDTH-1:0] bram_addr,
    output reg [BRAM_DATA_WIDTH-1:0] bram_wrdata,
    input wire [BRAM_DATA_WIDTH-1:0] bram_rddata,
    output reg [BRAM_DATA_WIDTH/8-1:0] bram_we
);

    localparam integer HASH_BITS = 10;
    localparam integer HASH_SIZE = 1024;
    localparam integer LEVELS = 10;
    localparam [2:0] IDLE = 0;
    localparam [2:0] PROBE_READ = 1;
    localparam [2:0] PROBE_CHECK = 2;
    localparam [2:0] APPLY = 3;
    localparam [2:0] EMIT = 4;

    // 订单簿哈希表：key、delta、qty、valid、side。
    (* ram_style = "block" *) reg [31:0] dict_key [0:HASH_SIZE-1];
    (* ram_style = "block" *) reg [23:0] dict_delta [0:HASH_SIZE-1];
    (* ram_style = "block" *) reg [15:0] dict_qty [0:HASH_SIZE-1];
    reg dict_valid [0:HASH_SIZE-1];
    reg dict_side [0:HASH_SIZE-1];

    // 订单薄价位表：bid/ask 价格和数量的各层快照。
    reg [31:0] bid_price [0:LEVELS-1];
    reg [31:0] ask_price [0:LEVELS-1];
    reg [31:0] bid_qty [0:LEVELS-1];
    reg [31:0] ask_qty [0:LEVELS-1];

    reg [2:0] state;
    reg [9:0] probe_idx;
    reg [2:0] probe_count;
    reg lookup_found;
    reg [3:0] apply_rank;
    reg [31:0] rd_key;
    reg [23:0] rd_delta;
    reg [15:0] rd_qty;
    reg rd_valid;
    reg rd_side;
    reg [31:0] control_reg;
    reg [31:0] event_count;
    reg [31:0] collision_count;
    reg [31:0] miss_count;
    reg [31:0] offset_price;
    reg [31:0] last_trade_price;
    reg [31:0] last_timestamp;
    reg [7:0] last_security;

    reg [31:0] cur_order;
    reg [31:0] cur_price;
    reg [31:0] cur_time;
    reg [31:0] cur_qty;
    reg [15:0] cur_qty16;
    reg [7:0] cur_sec;
    reg [3:0] cur_side;
    reg [3:0] cur_type;
    reg cur_last;

    reg [31:0] lookup_price;
    reg [31:0] snap_trade;
    reg [31:0] snap_bid_price;
    reg [31:0] snap_ask_price;
    reg [31:0] snap_bid_qty;
    reg [31:0] snap_ask_qty;
    reg [31:0] remove_qty;
    reg level_found;
    integer i;
    integer j;

    reg aw_hold;
    reg w_hold;
    reg b_hold;
    reg r_hold;
    reg [7:0] awaddr;
    reg [31:0] wdata;
    reg [31:0] rdata;

    // 输入事件字段解释：
    // [127:96] order_id
    // [95:80]  quantity
    // [79:48]  price
    // [47:16]  timestamp
    // [15:8]   security_id
    // [7:4]    side
    // [3:0]    type
    wire [31:0] in_order = s_axis_decoded_tdata[127:96];
    wire [15:0] in_qty = s_axis_decoded_tdata[95:80];
    wire [31:0] in_price = s_axis_decoded_tdata[79:48];
    wire [31:0] in_time = s_axis_decoded_tdata[47:16];
    wire [7:0] in_sec = s_axis_decoded_tdata[15:8];
    wire [3:0] in_side = s_axis_decoded_tdata[7:4];
    wire [3:0] in_type = s_axis_decoded_tdata[3:0];

    assign s_axi_ctrl_awready = !aw_hold && !b_hold;
    assign s_axi_ctrl_wready = !w_hold && !b_hold;
    assign s_axi_ctrl_bresp = 0;
    assign s_axi_ctrl_bvalid = b_hold;
    assign s_axi_ctrl_arready = !r_hold;
    assign s_axi_ctrl_rdata = rdata;
    assign s_axi_ctrl_rresp = 0;
    assign s_axi_ctrl_rvalid = r_hold;
    assign s_axis_decoded_tready = (state == IDLE)
                                 && (!m_axis_snapshot_tvalid || m_axis_snapshot_tready);
    assign bram_clk = aclk;

    initial begin
        for (i = 0; i < HASH_SIZE; i = i + 1) begin
            dict_valid[i] = 0;
            dict_key[i] = 0;
            dict_delta[i] = 0;
            dict_qty[i] = 0;
            dict_side[i] = 0;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            // 复位：清空状态、字典、LEVEL 表和输出寄存器
            state <= IDLE;
            probe_idx <= 0;
            probe_count <= 0;
            lookup_found <= 0;
            apply_rank <= 0;
            level_found <= 0;
            rd_key <= 0;
            rd_delta <= 0;
            rd_qty <= 0;
            rd_valid <= 0;
            rd_side <= 0;
            control_reg <= 0;
            event_count <= 0;
            collision_count <= 0;
            miss_count <= 0;
            offset_price <= 100;
            last_trade_price <= 0;
            last_timestamp <= 0;
            last_security <= 0;
            cur_order <= 0;
            cur_price <= 0;
            cur_time <= 0;
            cur_qty <= 0;
            cur_qty16 <= 0;
            cur_sec <= 0;
            cur_side <= 0;
            cur_type <= 0;
            cur_last <= 0;
            lookup_price <= 0;
            snap_trade <= 0;
            snap_bid_price <= 0;
            snap_ask_price <= 0;
            snap_bid_qty <= 0;
            snap_ask_qty <= 0;
            remove_qty <= 0;
            m_axis_snapshot_tdata <= 0;
            m_axis_snapshot_tvalid <= 0;
            m_axis_snapshot_tlast <= 0;
            aw_hold <= 0;
            w_hold <= 0;
            b_hold <= 0;
            r_hold <= 0;
            awaddr <= 0;
            wdata <= 0;
            rdata <= 0;
            bram_en <= 0;
            bram_addr <= 0;
            bram_wrdata <= 0;
            bram_we <= 0;

            for (j = 0; j < LEVELS; j = j + 1) begin
                bid_price[j] <= 0;
                ask_price[j] <= 0;
                bid_qty[j] <= 0;
                ask_qty[j] <= 0;
            end
        end else begin
            // 每个周期默认关闭 BRAM 写使能，真正需要写时再在 APPLY 阶段置 1。
            bram_en <= 0;
            bram_we <= 0;

            // AXI-Lite 写地址/写数据握手
            if (s_axi_ctrl_awvalid && s_axi_ctrl_awready) begin
                aw_hold <= 1;
                awaddr <= s_axi_ctrl_awaddr;
            end
            if (s_axi_ctrl_wvalid && s_axi_ctrl_wready) begin
                w_hold <= 1;
                wdata <= s_axi_ctrl_wdata;
            end
            if (aw_hold && w_hold && !b_hold) begin
                if (awaddr[7:2] == 0) begin
                    control_reg <= wdata;
                end else if (awaddr[7:2] == 3) begin
                    offset_price <= wdata;
                end
                aw_hold <= 0;
                w_hold <= 0;
                b_hold <= 1;
            end
            if (b_hold && s_axi_ctrl_bready) begin
                b_hold <= 0;
            end

            // AXI-Lite 读寄存器映射
            if (s_axi_ctrl_arvalid && s_axi_ctrl_arready) begin
                case (s_axi_ctrl_araddr[7:2])
                    0: rdata <= control_reg;
                    1: rdata <= event_count;
                    2: rdata <= collision_count;
                    3: rdata <= offset_price;
                    4: rdata <= last_trade_price;
                    5: rdata <= miss_count;
                    default: rdata <= 32'h4f424b34;
                endcase
                r_hold <= 1;
            end
            if (r_hold && s_axi_ctrl_rready) begin
                r_hold <= 0;
            end

            if (m_axis_snapshot_tvalid && m_axis_snapshot_tready) begin
                m_axis_snapshot_tvalid <= 0;
            end

            case (state)

                // 空闲状态：等待新的解码事件输入。
                IDLE: begin
                    // 空闲时，接受一条解码后的事件，并准备做订单簿查找/更新。
                    if (s_axis_decoded_tvalid && s_axis_decoded_tready) begin
                        cur_order <= in_order;
                        cur_price <= in_price;
                        cur_time <= in_time;
                        cur_qty <= in_qty;
                        cur_qty16 <= in_qty;
                        cur_sec <= in_sec;
                        cur_side <= in_side;
                        cur_type <= in_type;
                        cur_last <= s_axis_decoded_tlast;
                        probe_idx <= in_order[HASH_BITS-1:0];
                        probe_count <= 0;
                        lookup_found <= 0;
                        lookup_price <= in_price;
                        state <= PROBE_READ;
                    end
                end
                
                // 读取哈希表项：检查当前 probe_idx 的字典项是否有效，并准备做匹配。
                PROBE_READ: begin
                    // 读取候选哈希槽中的字典项：valid、key、delta、qty、side。
                    rd_valid <= dict_valid[probe_idx];
                    rd_key <= dict_key[probe_idx];
                    rd_delta <= dict_delta[probe_idx];
                    rd_qty <= dict_qty[probe_idx];
                    rd_side <= dict_side[probe_idx];
                    state <= PROBE_CHECK;
                end


                // 检查哈希表项：根据当前事件的 order_id 和字典项的 key 做匹配，决定下一步操作。
                PROBE_CHECK: begin
                    // 1) 找到同 order_id：说明这是一次修改/删除事件
                    // 2) 没找到且是 add：插入新订单
                    // 3) probes 超过阈值：视为 miss
                    if (rd_valid && rd_key == cur_order) begin
                        lookup_found <= 1;
                        lookup_price <= offset_price + rd_delta;
                        state <= APPLY;
                    end else if (!rd_valid && cur_type == 4'd1) begin
                        lookup_found <= 1;
                        lookup_price <= cur_price;
                        dict_valid[probe_idx] <= 1;
                        dict_key[probe_idx] <= cur_order;
                        dict_delta[probe_idx] <= cur_price - offset_price;
                        dict_qty[probe_idx] <= cur_qty16;
                        dict_side[probe_idx] <= cur_side[0];
                        state <= APPLY;
                    end else if (probe_count == 3) begin
                        lookup_found <= 0;
                        miss_count <= miss_count + 1;
                        state <= APPLY;
                    end else begin
                        probe_idx <= probe_idx + 1;
                        probe_count <= probe_count + 1;
                        collision_count <= collision_count + 1;
                        state <= PROBE_READ;
                    end
                end

                // 应用订单簿更新：根据事件类型和查找结果，更新字典和价格/数量等级。
                APPLY: begin
                    // 给快照寄存器准备基础当前状态，便于后续发射事件。
                    snap_trade <= last_trade_price;
                    snap_bid_price <= bid_price[0];
                    snap_ask_price <= ask_price[0];
                    snap_bid_qty <= bid_qty[0];
                    snap_ask_qty <= ask_qty[0];

                    // 新增订单：更新哈希表和价格/数量等级。
                    if (cur_type == 4'd1) begin
                        dict_delta[probe_idx] <= cur_price - offset_price;
                        dict_qty[probe_idx] <= cur_qty16;
                        dict_side[probe_idx] <= cur_side[0];
                        level_found = 0;
                        apply_rank = LEVELS;

                        if (cur_side[0] == 0) begin
                            for (j = 0; j < LEVELS; j = j + 1) begin
                                if (bid_price[j] == cur_price && bid_qty[j] != 0) begin
                                    bid_qty[j] <= bid_qty[j] + cur_qty;
                                    level_found = 1;
                                    if (j == 0) snap_bid_qty <= bid_qty[j] + cur_qty;
                                end else if (apply_rank == LEVELS && (bid_qty[j] == 0 || cur_price > bid_price[j])) begin
                                    apply_rank = j;
                                end
                            end

                            if (!level_found && apply_rank < LEVELS) begin
                                for (j = LEVELS - 1; j > 0; j = j - 1) begin
                                    if (j > apply_rank) begin
                                        bid_price[j] <= bid_price[j - 1];
                                        bid_qty[j] <= bid_qty[j - 1];
                                    end
                                end
                                bid_price[apply_rank] <= cur_price;
                                bid_qty[apply_rank] <= cur_qty;
                                if (apply_rank == 0) begin
                                    snap_bid_price <= cur_price;
                                    snap_bid_qty <= cur_qty;
                                end
                            end
                        end else begin
                            for (j = 0; j < LEVELS; j = j + 1) begin
                                if (ask_price[j] == cur_price && ask_qty[j] != 0) begin
                                    ask_qty[j] <= ask_qty[j] + cur_qty;
                                    level_found = 1;
                                    if (j == 0) snap_ask_qty <= ask_qty[j] + cur_qty;
                                end else if (apply_rank == LEVELS && (ask_qty[j] == 0 || cur_price < ask_price[j])) begin
                                    apply_rank = j;
                                end
                            end

                            if (!level_found && apply_rank < LEVELS) begin
                                for (j = LEVELS - 1; j > 0; j = j - 1) begin
                                    if (j > apply_rank) begin
                                        ask_price[j] <= ask_price[j - 1];
                                        ask_qty[j] <= ask_qty[j - 1];
                                    end
                                end
                                ask_price[apply_rank] <= cur_price;
                                ask_qty[apply_rank] <= cur_qty;
                                if (apply_rank == 0) begin
                                    snap_ask_price <= cur_price;
                                    snap_ask_qty <= cur_qty;
                                end
                            end
                        end
                    end else if ((cur_type == 4'd2 || cur_type == 4'd3) && lookup_found) begin
                        // 修改/取消订单：从哈希表和价位表中扣减 qty。
                        remove_qty = (cur_type == 4'd2 && cur_qty16 == 0) ? rd_qty : cur_qty;

                        if (cur_type == 4'd2 || rd_qty <= remove_qty) begin
                            dict_qty[probe_idx] <= 0;
                            dict_valid[probe_idx] <= 0;
                        end else begin
                            dict_qty[probe_idx] <= rd_qty - remove_qty;
                        end

                        for (j = 0; j < LEVELS; j = j + 1) begin
                            if (rd_side == 0 && bid_price[j] == lookup_price && bid_qty[j] != 0) begin
                                if (bid_qty[j] > remove_qty) begin
                                    bid_qty[j] <= bid_qty[j] - remove_qty;
                                    if (j == 0) snap_bid_qty <= bid_qty[j] - remove_qty;
                                end else begin
                                    for (i = j; i < LEVELS - 1; i = i + 1) begin
                                        bid_price[i] <= bid_price[i + 1];
                                        bid_qty[i] <= bid_qty[i + 1];
                                    end
                                    bid_price[LEVELS - 1] <= 0;
                                    bid_qty[LEVELS - 1] <= 0;
                                    if (j == 0) begin
                                        snap_bid_price <= bid_price[1];
                                        snap_bid_qty <= bid_qty[1];
                                    end
                                end
                            end

                            if (rd_side == 1 && ask_price[j] == lookup_price && ask_qty[j] != 0) begin
                                if (ask_qty[j] > remove_qty) begin
                                    ask_qty[j] <= ask_qty[j] - remove_qty;
                                    if (j == 0) snap_ask_qty <= ask_qty[j] - remove_qty;
                                end else begin
                                    for (i = j; i < LEVELS - 1; i = i + 1) begin
                                        ask_price[i] <= ask_price[i + 1];
                                        ask_qty[i] <= ask_qty[i + 1];
                                    end
                                    ask_price[LEVELS - 1] <= 0;
                                    ask_qty[LEVELS - 1] <= 0;
                                    if (j == 0) begin
                                        snap_ask_price <= ask_price[1];
                                        snap_ask_qty <= ask_qty[1];
                                    end
                                end
                            end
                        end
                    end

                    // 若该事件有效或命中查找，则在 BRAM 中更新相应的镜像项。
                    if (cur_type == 4'd1 || lookup_found) begin
                        bram_en <= 1;
                        bram_addr <= probe_idx;
                        bram_wrdata <= {cur_order, lookup_price};
                        bram_we <= {BRAM_DATA_WIDTH/8{1'b1}};
                    end

                    // 交易事件（type=3）更新最后成交价/时间/证券代码。
                    if (cur_type == 4'd3) begin
                        snap_trade <= lookup_price;
                        last_trade_price <= lookup_price;
                        last_timestamp <= cur_time;
                        last_security <= cur_sec;
                    end

                    event_count <= event_count + 1;
                    state <= EMIT;
                end

                // 生成快照输出：将当前订单簿状态打包成 256-bit 快照，发射到输出通道。
                EMIT: begin
                    // 生成 256-bit 快照，包含时间、成交、买卖档位、证券代码、类型和 side。
                    if (!m_axis_snapshot_tvalid || m_axis_snapshot_tready) begin
                        m_axis_snapshot_tdata <= {40'd0, cur_time, snap_trade, snap_ask_qty,
                                                 snap_ask_price, snap_bid_qty, snap_bid_price,
                                                 cur_sec, cur_type, cur_side, 8'd0};
                        m_axis_snapshot_tvalid <= 1;
                        m_axis_snapshot_tlast <= cur_last;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end
endmodule
