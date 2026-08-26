# ZCU111 量化交易核心算法与硬件加速器

本仓库现以阶段 2 的量化交易 PL 框架为主，旧 DPSK/RF 收发内容已移入 `archive/dpsk_legacy`，不再属于当前工程。

工程入口：

- `quant_trading/QUANT_TRADING.xpr`
- `quant_trading/scripts/create_quant_trading_project.tcl`
- `quant_trading/README.md`

主链路为 FAST/STEP 流式输入、FAST 解码、订单簿/L2 快照、量化决策接口、AXI-Stream 汇聚和 AXI DMA。参考论文保留在 `REF`，用于 FAST 流水/存储优化和 PCIe DMA、BAR、中断、复位验证方法的设计依据。

当前自定义 RTL 是可综合的 Stage-2 接口骨架；实际 FAST 模板算子、盘口 KVS 更新、Int8 神经网络权重和网络 MAC/UDP/TOE 前端按项目输入继续替换。
