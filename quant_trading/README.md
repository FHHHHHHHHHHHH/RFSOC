# ZCU111 量化交易核心算法与硬件加速器（Stage 2）

本目录是独立的 Vivado PL 框架，目标器件为
`xczu28dr-ffvg1517-2-e`，Vivado 2020.2，板卡为 ZCU111。

数据流为：

`FAST/STEP AXIS 512 bit -> fast_decoder_ip -> order_book_engine_ip -> 256 bit L2 snapshot -> nn_decision_engine_ip -> 64 bit signal -> quant_stream_mux -> AXI DMA S2MM -> PS DDR`

控制面由 PS `M_AXI_HPM0_FPD` 经 `axi_smartconnect_ctrl` 连接 DMA、BRAM 控制器及三个自定义 IP 的 AXI4-Lite 寄存器。`blk_mem_kvs` 为订单号/价格字典的 True Dual-Port RAM；B 口保留给订单簿实现，A 口由 PS 配置和观测。

## 生成工程

在 Vivado 2020.2 Tcl Console 或批处理模式执行：

```tcl
source E:/Vivado_prj/ZCU111_CNN/quant_trading/scripts/create_quant_trading_project.tcl
```

生成工程后执行 `quant_trading/scripts/build_quant_trading.tcl` 进行综合检查。

## 已实现算法

- `fast_decoder_ip.v`：512-bit AXIS 字节扫描状态机，识别 STEP `95=<length><SOH>96=` 嵌套包（同时兼容裸 `96=` 回放），执行 Pmap stop-bit 提取、7-bit 拼接和字段操作符恢复，并输出 128-bit 标准记录。
- `market_event_reorder.v`：成交单暂存一拍；同时间戳的委托到达时先发委托、再发成交。
- `order_book_engine_ip.v`：四探针开放寻址订单字典，保存订单号、价格偏移、方向和剩余数量；支持新增、撤单、成交查价、同价合并、10 档移位和最优档提升，外接 True-Dual-Port BRAM 镜像接口。
- `hls/fast_decoder_hls.cpp` 和 `hls/order_book_hls.cpp`：对应的 Vitis HLS 参考内核，便于后续以 HLS 替换 RTL。

当前 FAST 字段恢复使用标准化 7 字段记录；Pmap 和 Direct/Copy/Default/Increment/Delta/Constant 操作符均有 AXI-Lite 配置入口。论文中的 183 ns FAST 解码和约 189.8 ns 行情解析是目标指标，不代表当前版本已经达到该指标。

PCIe 论文用于确定高速主机接口的事务、BAR、DMA、中断和链路复位验证方法；ZCU111 本工程采用 PS HPM 控制面、S_AXI_HP0_FPD/DDR_LOW 数据面和 AXI DMA，未虚构板上 PCIe 端点。

验证命令：

```powershell
quant_trading/scripts/run_rtl_sim.ps1
E:/Xilinx/Vivado/2020.2/bin/vivado.bat -mode batch -nojournal -nolog -notrace -source quant_trading/scripts/synth_core_rtl.tcl
```

仿真平台覆盖：
- `tb_quant_pipeline_top.sv`：全链路端到端综合验证平台（FAST 解码 -> 事件重排序 -> 订单簿维护 -> NN 决策 -> 流多路复用 -> AXI-Lite 寄存器读写与冲突探针）。
- `tb_fast_orderbook.sv`：FAST/STEP 帧解析与基础单笔建仓。
- `tb_market_sequence.sv`：时间戳乱序重排与哈希碰撞探针验证。

当前回归输出：基础 STEP 帧 PASS；盘口序列 `PASS sequence snapshots=5 collisions=1`。完整 BD 工程生成脚本会执行 `validate_bd_design` 并生成 `design_quant_wrapper.v`；顶层并行综合受 Windows OOC 文件锁/内存竞争影响时，应使用 `build_quant_trading.tcl` 的单作业模式重跑。
