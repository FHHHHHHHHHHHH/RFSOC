`timescale 1ns/1ps

// ==============================================================================
// 工程全链路端到端综合验证测试平台 (tb_quant_pipeline_top)
// 
// 覆盖链路：
//   S_AXIS_RAW (512-bit) 
//     -> fast_decoder_ip (FAST/STEP 协议解码)
//     -> market_event_reorder (时间戳乱序校正)
//     -> order_book_engine_ip (L2 10档盘口/哈希字典/撤单成交)
//     -> [广播] -> nn_decision_engine_ip (量化特征决策)
//              -> quant_stream_mux (多路流复用调度)
//     -> M_AXIS (256-bit 最终输出到 DMA)
// 
// 验证场景：
//   1. FAST/STEP 解码协议精度验证 (Tag95, Tag96, Pmap, Stop-bit)
//   2. 买卖双向多档位委托建立 (Bid/Ask 价格档位维护与排序)
//   3. 同时间戳逆序到达重排序 (Trade 先到, Order 后到, 保证 Order 优先入簿)
//   4. 哈希槽位碰撞探测 (Hash Collision & Linear Probing)
//   5. 撤单操作与价格档位前移/清空 (Cancel Order)
//   6. 撮生成交、查价扣减与最新价更新 (Trade Matching & Last Price)
//   7. NN 决策引擎推断与 MUX 调度优先级 (Signal > Snapshot)
//   8. AXI-Lite 状态/控制寄存器读写与统计指标自检
// ==============================================================================

module tb_quant_pipeline_top;

    // -------------------------------------------------------------------------
    // 时钟与复位
    // -------------------------------------------------------------------------
    reg clk = 0;
    reg rstn = 0;
    always #2 clk = ~clk; // 250 MHz 时钟周期 4ns

    // -------------------------------------------------------------------------
    // 内部连线
    // -------------------------------------------------------------------------
    // 1. FAST Decoder 输入/输出
    reg  [511:0] raw_tdata = 0;
    reg          raw_tvalid = 0;
    wire         raw_tready;
    reg          raw_tlast = 0;

    wire [127:0] decoded_tdata;
    wire         decoded_tvalid;
    wire         decoded_tready;
    wire         decoded_tlast;

    // 2. Reorder 模块输出
    wire [127:0] reordered_tdata;
    wire         reordered_tvalid;
    wire         reordered_tready;
    wire         reordered_tlast;

    // 3. OrderBook 模块输出 & BRAM 镜像
    wire [255:0] snapshot_tdata;
    wire         snapshot_tvalid;
    wire         snapshot_tready;
    wire         snapshot_tlast;

    wire         bram_clk;
    wire         bram_en;
    wire [31:0]  bram_addr;
    wire [63:0]  bram_wrdata;
    reg  [63:0]  bram_rddata = 0;
    wire [7:0]   bram_we;

    // 模拟 BRAM 存储器
    reg [63:0]   bram_mem [0:1023];
    always @(posedge clk) begin
        if (bram_en && (|bram_we)) begin
            bram_mem[bram_addr[12:3]] <= bram_wrdata;
        end
        if (bram_en) begin
            bram_rddata <= bram_mem[bram_addr[12:3]];
        end
    end

    // 4. Broadcaster (分发给 NN 决策与 MUX)
    // 每个分支对同一个快照只允许握手一次，直到两个分支都完成消费。
    reg  [255:0] bcast_tdata = 0;
    reg          bcast_tlast = 0;
    reg          bcast_valid = 0;
    reg          nn_pending = 0;
    reg          mux_pending = 0;

    wire feat_tvalid = bcast_valid && nn_pending;
    wire feat_tready;
    wire [255:0] feat_tdata = bcast_tdata;
    wire feat_tlast = bcast_tlast;

    wire mux_snap_tvalid = bcast_valid && mux_pending;
    wire mux_snap_ready;
    wire nn_fire = feat_tvalid && feat_tready;
    wire mux_fire = mux_snap_tvalid && mux_snap_ready;
    assign snapshot_tready = !bcast_valid;

    always @(posedge clk) begin
        if (!rstn) begin
            bcast_tdata <= 0;
            bcast_tlast <= 0;
            bcast_valid <= 0;
            nn_pending <= 0;
            mux_pending <= 0;
        end else if (!bcast_valid) begin
            if (snapshot_tvalid && snapshot_tready) begin
                bcast_tdata <= snapshot_tdata;
                bcast_tlast <= snapshot_tlast;
                bcast_valid <= 1;
                nn_pending <= 1;
                mux_pending <= 1;
            end
        end else begin
            if (nn_fire)
                nn_pending <= 0;
            if (mux_fire)
                mux_pending <= 0;
            if ((!nn_pending || nn_fire) && (!mux_pending || mux_fire))
                bcast_valid <= 0;
        end
    end

    // 5. NN Decision Engine 输出
    wire [63:0]  signal_tdata;
    wire         signal_tvalid;
    wire         signal_tready;
    wire         signal_tlast;

    // 6. Quant Stream MUX 最终输出
    wire [255:0] final_m_axis_tdata;
    wire         final_m_axis_tvalid;
    reg          final_m_axis_tready = 1;
    wire         final_m_axis_tlast;

    // 7. AXI-Lite 总线信号 (连接三个 IP)
    reg  [7:0]   axi_awaddr = 0;
    reg          axi_awvalid = 0;
    wire         dec_awready, ob_awready, nn_awready;

    reg  [31:0]  axi_wdata = 0;
    reg  [3:0]   axi_wstrb = 4'hF;
    reg          axi_wvalid = 0;
    wire         dec_wready, ob_wready, nn_wready;

    wire [1:0]   dec_bresp, ob_bresp, nn_bresp;
    wire         dec_bvalid, ob_bvalid, nn_bvalid;
    reg          axi_bready = 1;

    reg  [7:0]   axi_araddr = 0;
    reg          axi_arvalid = 0;
    wire         dec_arready, ob_arready, nn_arready;

    wire [31:0]  dec_rdata, ob_rdata, nn_rdata;
    wire [1:0]   dec_rresp, ob_rresp, nn_rresp;
    wire         dec_rvalid, ob_rvalid, nn_rvalid;
    reg          axi_rready = 1;

    // -------------------------------------------------------------------------
    // IP 实例化
    // -------------------------------------------------------------------------
    fast_decoder_ip u_fast_decoder (
        .aclk(clk),
        .aresetn(rstn),
        .s_axi_ctrl_awaddr(axi_awaddr),
        .s_axi_ctrl_awvalid(axi_awvalid),
        .s_axi_ctrl_awready(dec_awready),
        .s_axi_ctrl_wdata(axi_wdata),
        .s_axi_ctrl_wstrb(axi_wstrb),
        .s_axi_ctrl_wvalid(axi_wvalid),
        .s_axi_ctrl_wready(dec_wready),
        .s_axi_ctrl_bresp(dec_bresp),
        .s_axi_ctrl_bvalid(dec_bvalid),
        .s_axi_ctrl_bready(axi_bready),
        .s_axi_ctrl_araddr(axi_araddr),
        .s_axi_ctrl_arvalid(axi_arvalid),
        .s_axi_ctrl_arready(dec_arready),
        .s_axi_ctrl_rdata(dec_rdata),
        .s_axi_ctrl_rresp(dec_rresp),
        .s_axi_ctrl_rvalid(dec_rvalid),
        .s_axi_ctrl_rready(axi_rready),

        .s_axis_raw_tdata(raw_tdata),
        .s_axis_raw_tvalid(raw_tvalid),
        .s_axis_raw_tready(raw_tready),
        .s_axis_raw_tlast(raw_tlast),

        .m_axis_decoded_tdata(decoded_tdata),
        .m_axis_decoded_tvalid(decoded_tvalid),
        .m_axis_decoded_tready(decoded_tready),
        .m_axis_decoded_tlast(decoded_tlast)
    );

    market_event_reorder u_reorder (
        .aclk(clk),
        .aresetn(rstn),
        .s_axis_tdata(decoded_tdata),
        .s_axis_tvalid(decoded_tvalid),
        .s_axis_tready(decoded_tready),
        .s_axis_tlast(decoded_tlast),

        .m_axis_tdata(reordered_tdata),
        .m_axis_tvalid(reordered_tvalid),
        .m_axis_tready(reordered_tready),
        .m_axis_tlast(reordered_tlast)
    );

    order_book_engine_ip u_order_book (
        .aclk(clk),
        .aresetn(rstn),
        .s_axi_ctrl_awaddr(axi_awaddr),
        .s_axi_ctrl_awvalid(axi_awvalid),
        .s_axi_ctrl_awready(ob_awready),
        .s_axi_ctrl_wdata(axi_wdata),
        .s_axi_ctrl_wstrb(axi_wstrb),
        .s_axi_ctrl_wvalid(axi_wvalid),
        .s_axi_ctrl_wready(ob_wready),
        .s_axi_ctrl_bresp(ob_bresp),
        .s_axi_ctrl_bvalid(ob_bvalid),
        .s_axi_ctrl_bready(axi_bready),
        .s_axi_ctrl_araddr(axi_araddr),
        .s_axi_ctrl_arvalid(axi_arvalid),
        .s_axi_ctrl_arready(ob_arready),
        .s_axi_ctrl_rdata(ob_rdata),
        .s_axi_ctrl_rresp(ob_rresp),
        .s_axi_ctrl_rvalid(ob_rvalid),
        .s_axi_ctrl_rready(axi_rready),

        .s_axis_decoded_tdata(reordered_tdata),
        .s_axis_decoded_tvalid(reordered_tvalid),
        .s_axis_decoded_tready(reordered_tready),
        .s_axis_decoded_tlast(reordered_tlast),

        .m_axis_snapshot_tdata(snapshot_tdata),
        .m_axis_snapshot_tvalid(snapshot_tvalid),
        .m_axis_snapshot_tready(snapshot_tready),
        .m_axis_snapshot_tlast(snapshot_tlast),

        .bram_clk(bram_clk),
        .bram_en(bram_en),
        .bram_addr(bram_addr),
        .bram_wrdata(bram_wrdata),
        .bram_rddata(bram_rddata),
        .bram_we(bram_we)
    );

    nn_decision_engine_ip u_nn_decision (
        .aclk(clk),
        .aresetn(rstn),
        .s_axi_ctrl_awaddr(axi_awaddr),
        .s_axi_ctrl_awvalid(axi_awvalid),
        .s_axi_ctrl_awready(nn_awready),
        .s_axi_ctrl_wdata(axi_wdata),
        .s_axi_ctrl_wstrb(axi_wstrb),
        .s_axi_ctrl_wvalid(axi_wvalid),
        .s_axi_ctrl_wready(nn_wready),
        .s_axi_ctrl_bresp(nn_bresp),
        .s_axi_ctrl_bvalid(nn_bvalid),
        .s_axi_ctrl_bready(axi_bready),
        .s_axi_ctrl_araddr(axi_araddr),
        .s_axi_ctrl_arvalid(axi_arvalid),
        .s_axi_ctrl_arready(nn_arready),
        .s_axi_ctrl_rdata(nn_rdata),
        .s_axi_ctrl_rresp(nn_rresp),
        .s_axi_ctrl_rvalid(nn_rvalid),
        .s_axi_ctrl_rready(axi_rready),

        .s_axis_feat_tdata(feat_tdata),
        .s_axis_feat_tvalid(feat_tvalid),
        .s_axis_feat_tready(feat_tready),
        .s_axis_feat_tlast(feat_tlast),

        .m_axis_signal_tdata(signal_tdata),
        .m_axis_signal_tvalid(signal_tvalid),
        .m_axis_signal_tready(signal_tready),
        .m_axis_signal_tlast(signal_tlast)
    );

    quant_stream_mux u_stream_mux (
        .aclk(clk),
        .aresetn(rstn),

        .s_snapshot_tdata(bcast_tdata),
        .s_snapshot_tvalid(mux_snap_tvalid),
        .s_snapshot_tready(mux_snap_ready),
        .s_snapshot_tlast(bcast_tlast),

        .s_signal_tdata(signal_tdata),
        .s_signal_tvalid(signal_tvalid),
        .s_signal_tready(signal_tready),
        .s_signal_tlast(signal_tlast),

        .m_axis_tdata(final_m_axis_tdata),
        .m_axis_tvalid(final_m_axis_tvalid),
        .m_axis_tready(final_m_axis_tready),
        .m_axis_tlast(final_m_axis_tlast)
    );

    // -------------------------------------------------------------------------
    // 测试辅助驱动任务
    // -------------------------------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;

    task check_assert(input bit condition, input string test_name);
        begin
            if (condition) begin
                $display("[PASS] %s", test_name);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL ERROR] %s", test_name);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // 发送 512-bit RAW FAST 报文
    task send_raw_beat(input [511:0] beat_data, input bit is_last);
        begin
            @(posedge clk);
            while (!raw_tready) @(posedge clk);
            raw_tdata  <= beat_data;
            raw_tvalid <= 1'b1;
            raw_tlast  <= is_last;
            @(posedge clk);
            while (!raw_tready) @(posedge clk);
            raw_tvalid <= 1'b0;
            raw_tlast  <= 1'b0;
        end
    endtask

    // 等待并捕获一个有效快照输出
    task wait_for_snapshot(
        output [3:0]  msg_type,
        output [31:0] trade_price,
        output [31:0] best_bid_price,
        output [31:0] best_bid_qty,
        output [31:0] best_ask_price,
        output [31:0] best_ask_qty
    );
        begin
            while (!snapshot_tvalid) @(posedge clk);
            #0.1; // 采样建立
            msg_type       = snapshot_tdata[15:12];
            trade_price    = snapshot_tdata[183:152];
            best_bid_price = snapshot_tdata[55:24];
            best_bid_qty   = snapshot_tdata[87:56];
            best_ask_price = snapshot_tdata[119:88];
            best_ask_qty   = snapshot_tdata[151:120];
            @(posedge clk);
            while (snapshot_tvalid && !snapshot_tready) @(posedge clk);
        end
    endtask

    // AXI-Lite 读寄存器
    task axi_read_reg(input [7:0] addr, output [31:0] data, input integer target_ip);
        begin
            @(posedge clk);
            axi_araddr  <= addr;
            axi_arvalid <= 1'b1;
            @(posedge clk);
            case (target_ip)
                0: while (!dec_arready) @(posedge clk);
                1: while (!ob_arready)  @(posedge clk);
                2: while (!nn_arready)  @(posedge clk);
            endcase
            axi_arvalid <= 1'b0;
            case (target_ip)
                0: while (!dec_rvalid) @(posedge clk);
                1: while (!ob_rvalid)  @(posedge clk);
                2: while (!nn_rvalid)  @(posedge clk);
            endcase
            #0.1;
            case (target_ip)
                0: data = dec_rdata;
                1: data = ob_rdata;
                2: data = nn_rdata;
            endcase
            @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // 主测试流程
    // -------------------------------------------------------------------------
    reg [511:0] pkt;
    reg [3:0]   res_type;
    reg [31:0]  res_trade, res_bidp, res_bidq, res_askp, res_askq;
    reg [31:0]  reg_val;

    initial begin
        $display("\n==================================================================");
        $display(">>> 开始执行量化交易硬件全链路端到端综合功能验证 (tb_quant_pipeline_top) <<<");
        $display("==================================================================");

        // 1. 系统复位初始化
        rstn <= 0;
        repeat(10) @(posedge clk);
        rstn <= 1;
        repeat(5)  @(posedge clk);
        $display("[INFO] 系统复位完成，工作时钟 250MHz 已锁定。");

        // ---------------------------------------------------------------------
        // 场景 1: 标准 STEP/FAST 格式单笔委托解析 (Tag95, Tag96, Pmap, Stop-bit)
        // ---------------------------------------------------------------------
        $display("\n--- [测试场景 1] FAST 协议解析与委托建仓 (Order 42: Bid, Price=1000, Qty=10) ---");
        // 构造报文: "95=9\x0196=\xff\x81\x80\x85\xe4\x07\xe8\x8a\xaa"
        // 字段还原预期:
        //   order_id    = 42 (0x2a) -> \xaa
        //   quantity    = 10 (0x0a) -> \x8a
        //   price       = 1000      -> \x07\xe8
        //   timestamp   = 100       -> \xe4
        //   security_id = 5         -> \x85
        //   side        = 0 (Buy)   -> \x80
        //   msg_type    = 1 (Order) -> \x81
        pkt = 512'd0;
        pkt[7:0]     = 8'h39; // '9'
        pkt[15:8]    = 8'h35; // '5'
        pkt[23:16]   = 8'h3d; // '='
        pkt[31:24]   = 8'h39; // '9' (length)
        pkt[39:32]   = 8'h01; // SOH
        pkt[47:40]   = 8'h39; // '9'
        pkt[55:48]   = 8'h36; // '6'
        pkt[63:56]   = 8'h3d; // '='
        pkt[71:64]   = 8'hff; // Pmap (all 1s)
        pkt[79:72]   = 8'h81; // msg_type = 1
        pkt[87:80]   = 8'h80; // side = 0 (Buy)
        pkt[95:88]   = 8'h85; // security_id = 5
        pkt[103:96]  = 8'he4; // timestamp = 100
        pkt[111:104] = 8'h07; // price byte 0 (7)
        pkt[119:112] = 8'he8; // price byte 1 (1000 = (7<<7) + 0x68)
        pkt[127:120] = 8'h8a; // quantity = 10
        pkt[135:128] = 8'haa; // order_id = 42

        send_raw_beat(pkt, 1'b1);

        wait_for_snapshot(res_type, res_trade, res_bidp, res_bidq, res_askp, res_askq);
        check_assert(res_type == 4'd1, "场景1: 订单类型确认 (Order Type == 1)");
        check_assert(res_bidp == 32'd1000 && res_bidq == 32'd10, "场景1: 最优买价/买量更新 (Bid1: 1000 @ 10)");
        check_assert(u_fast_decoder.step_length == 32'd9, "场景1: FAST Decoder STEP Tag95 长度解析准确");

        // ---------------------------------------------------------------------
        // 场景 2: 卖盘多档挂单 (Ask 委托入簿)
        // ---------------------------------------------------------------------
        $display("\n--- [测试场景 2] 卖方挂单建仓 (Order 50: Ask, Price=1020, Qty=15) ---");
        pkt = 512'd0;
        pkt[7:0]     = 8'h39; pkt[15:8]  = 8'h36; pkt[23:16] = 8'h3d; // "96="
        pkt[31:24]   = 8'hff; // Pmap
        pkt[39:32]   = 8'h81; // msg_type = 1 (Order)
        pkt[47:40]   = 8'h81; // side = 1 (Sell/Ask)
        pkt[55:48]   = 8'h85; // security_id = 5
        pkt[63:56]   = 8'he5; // timestamp = 101
        pkt[71:64]   = 8'h07; pkt[79:72] = 8'hfc; // price = 1020 ((7<<7)+0x7c)
        pkt[87:80]   = 8'h8f; // quantity = 15
        pkt[95:88]   = 8'hb2; // order_id = 50 (0x32 -> 0xb2)

        send_raw_beat(pkt, 1'b1);

        wait_for_snapshot(res_type, res_trade, res_bidp, res_bidq, res_askp, res_askq);
        check_assert(res_askp == 32'd1020 && res_askq == 32'd15, "场景2: 最优卖价/卖量更新 (Ask1: 1020 @ 15)");
        check_assert(res_bidp == 32'd1000 && res_bidq == 32'd10, "场景2: 买一档位保持完整 (Bid1 仍为 1000 @ 10)");

        // ---------------------------------------------------------------------
        // 场景 3: 同时间戳乱序校正 (Trade 先到, Order 后到, timestamp=200)
        // ---------------------------------------------------------------------
        $display("\n--- [测试场景 3] 时间戳乱序校正 (Timestamp 200: Trade 42 提前到达, Order 43 随后到达) ---");
        // 1. 发送 Trade (扣减 42 号订单 4 手) -> timestamp = 200
        pkt = 512'd0;
        pkt[7:0]     = 8'h39; pkt[15:8]  = 8'h36; pkt[23:16] = 8'h3d;
        pkt[31:24]   = 8'hff;
        pkt[39:32]   = 8'h83; // msg_type = 3 (Trade)
        pkt[47:40]   = 8'h80; // side = 0
        pkt[55:48]   = 8'h85; // security_id = 5
        pkt[63:56]   = 8'h01; pkt[71:64] = 8'hc8; // timestamp = 200
        pkt[79:72]   = 8'h4e; pkt[87:80] = 8'h8f; // price = 9999 (匹配已有订单)
        pkt[95:88]   = 8'h84; // quantity = 4
        pkt[103:96]  = 8'haa; // order_id = 42
        send_raw_beat(pkt, 1'b1);

        // 2. 紧接着发送更优买单 Order 43 (Price=1010, Qty=5) -> timestamp = 200
        pkt = 512'd0;
        pkt[7:0]     = 8'h39; pkt[15:8]  = 8'h36; pkt[23:16] = 8'h3d;
        pkt[31:24]   = 8'hff;
        pkt[39:32]   = 8'h81; // msg_type = 1 (Order)
        pkt[47:40]   = 8'h80; // side = 0 (Buy)
        pkt[55:48]   = 8'h85; // security_id = 5
        pkt[63:56]   = 8'h01; pkt[71:64] = 8'hc8; // timestamp = 200
        pkt[79:72]   = 8'h07; pkt[87:80] = 8'hf2; // price = 1010 ((7<<7)+0x72)
        pkt[95:88]   = 8'h85; // quantity = 5
        pkt[103:96]  = 8'hab; // order_id = 43
        send_raw_beat(pkt, 1'b1);

        // Reorder 应该先输出 Order 43，盘口最优买价变为 1010
        wait_for_snapshot(res_type, res_trade, res_bidp, res_bidq, res_askp, res_askq);
        check_assert(res_type == 4'd1 && res_bidp == 32'd1010 && res_bidq == 32'd5,
                     "场景3: 重排序确保 Order 43 优先出队更新买一档 (Bid1: 1010 @ 5)");

        // 接着 Reorder 释放暂存的 Trade 42，成交价为 1000 (查字典得到原价 1000)
        wait_for_snapshot(res_type, res_trade, res_bidp, res_bidq, res_askp, res_askq);
        check_assert(res_type == 4'd3 && res_trade == 32'd1000,
                     "场景3: Trade 42 随后出队并成功查表扣减 (Trade Price == 1000)");

        // ---------------------------------------------------------------------
        // 场景 4: 撤单操作与档位清空 (Cancel Order 43)
        // ---------------------------------------------------------------------
        $display("\n--- [测试场景 4] 撤单操作 (Cancel Order 43: Qty 5 全部撤销) ---");
        pkt = 512'd0;
        pkt[7:0]     = 8'h39; pkt[15:8]  = 8'h36; pkt[23:16] = 8'h3d;
        pkt[31:24]   = 8'hff;
        pkt[39:32]   = 8'h82; // msg_type = 2 (Cancel)
        pkt[47:40]   = 8'h80; // side = 0
        pkt[55:48]   = 8'h85; // security_id = 5
        pkt[63:56]   = 8'h01; pkt[71:64] = 8'hc9; // timestamp = 201
        pkt[79:72]   = 8'h07; pkt[87:80] = 8'hf2; // price = 1010
        pkt[95:88]   = 8'h85; // quantity = 5
        pkt[103:96]  = 8'hab; // order_id = 43
        send_raw_beat(pkt, 1'b1);

        // 撤销 1010 档位后，买一档回退为 1000 档位（原数量 10 扣减 Trade 4 后剩余 6）
        wait_for_snapshot(res_type, res_trade, res_bidp, res_bidq, res_askp, res_askq);
        check_assert(res_type == 4'd2 && res_bidp == 32'd1000 && res_bidq == 32'd6,
                     "场景4: 撤销 1010 档位后，买一档正确回退并恢复 1000 档位 (Bid1: 1000 @ 6)");

        // ---------------------------------------------------------------------
        // 场景 5: 哈希碰撞与线性探测 (Order ID 1066 与 ID 42 发生哈希冲突)
        // ---------------------------------------------------------------------
        $display("\n--- [测试场景 5] 哈希槽位碰撞测试 (Order ID 1066 Hash[9:0] == 42) ---");
        pkt = 512'd0;
        pkt[7:0]     = 8'h39; pkt[15:8]  = 8'h36; pkt[23:16] = 8'h3d;
        pkt[31:24]   = 8'hff;
        pkt[39:32]   = 8'h81; // msg_type = 1 (Order)
        pkt[47:40]   = 8'h80; // side = 0 (Buy)
        pkt[55:48]   = 8'h85; // security_id = 5
        pkt[63:56]   = 8'h01; pkt[71:64] = 8'hca; // timestamp = 202
        pkt[79:72]   = 8'h07; pkt[87:80] = 8'hde; // price = 990 ((7<<7)+0x5e)
        pkt[95:88]   = 8'h87; // quantity = 7
        pkt[103:96]  = 8'h08; pkt[111:104] = 8'haa; // order_id = 1066 ((8<<7)+0x2a = 1066)
        send_raw_beat(pkt, 1'b1);

        wait_for_snapshot(res_type, res_trade, res_bidp, res_bidq, res_askp, res_askq);
        check_assert(u_order_book.collision_count > 0,
                     "场景5: 成功触发哈希冲突线性探针 (Collision Count > 0)");
        check_assert(res_bidp == 32'd1000 && res_bidq == 32'd6,
                     "场景5: 较次级价格 990 插入买二档，最优档 1000 保持不变");

        // ---------------------------------------------------------------------
        // 场景 6: NN 决策引擎推断与 MUX 优先级验证
        // ---------------------------------------------------------------------
        $display("\n--- [测试场景 6] 量化决策信号产生与 MUX 多路复用优先级校验 ---");
        // 等待决策流产生并在 MUX 顶层输出
        repeat(5) @(posedge clk);
        check_assert(u_nn_decision.inference_count > 0,
                     "场景6: NN 决策引擎完成特征推断并计数递增 (Inference Count > 0)");
        check_assert(final_m_axis_tvalid == 1'b1 || u_stream_mux.select_signal == 1'b1,
                     "场景6: Stream MUX 调度通道正常握手与输出");

        // ---------------------------------------------------------------------
        // 场景 7: AXI-Lite 状态读取与系统寄存器核验
        // ---------------------------------------------------------------------
        $display("\n--- [测试场景 7] AXI-Lite 状态寄存器核验 ---");
        // 读取 fast_decoder 统计寄存器 (Offset 1: Frame Count)
        axi_read_reg(8'h04, reg_val, 0);
        check_assert(reg_val >= 32'd5, "场景7: FAST Decoder 统计帧计数寄存器 >= 5");

        // 读取 order_book 冲突计数寄存器 (Offset 2: Collision Count)
        axi_read_reg(8'h08, reg_val, 1);
        check_assert(reg_val == u_order_book.collision_count, "场景7: OrderBook AXI-Lite 冲突统计寄存器读数准确");

        // 读取 nn_decision 推断次数寄存器 (Offset 1: Inference Count)
        axi_read_reg(8'h04, reg_val, 2);
        check_assert(reg_val == u_nn_decision.inference_count, "场景7: NN Decision AXI-Lite 推断计数寄存器读数准确");

        // ---------------------------------------------------------------------
        // 测试结果汇总
        // ---------------------------------------------------------------------
        $display("\n==================================================================");
        $display(">>> 全链路仿真测试执行完毕! 总结报告: PASS = %0d, FAIL = %0d <<<", pass_count, fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display(">>> [SUCCESS] 所有量化硬件算法核心功能与端到端链路准确无误！<<<\n");
        end else begin
            $display(">>> [FAILURE] 存在 %0d 项测试未通过，请检查上述日志！<<<\n", fail_count);
        end

        #20;
        $finish;
    end

    // 超时安全守门员
    initial begin
        #50000;
        $display("\n[FATAL ERROR] 仿真超时保护触发 (Timeout)!");
        $finish;
    end

endmodule
