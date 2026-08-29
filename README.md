# ZCU111 量化交易核心算法与硬件加速器

本仓库现以阶段 2 的量化交易 PL 框架为主，旧 DPSK/RF 收发内容已移入 `archive/dpsk_legacy`，不再属于当前工程。

工程入口：

- `quant_trading/QUANT_TRADING.xpr`
- `quant_trading/scripts/create_quant_trading_project.tcl`
- `quant_trading/README.md`

主链路为 FAST/STEP 流式输入、FAST 解码、订单簿/L2 快照、量化决策接口、AXI-Stream 汇聚和 AXI DMA。参考论文保留在 `REF`，用于 FAST 流水/存储优化和 PCIe DMA、BAR、中断、复位验证方法的设计依据。

当前自定义 RTL 是可综合的 Stage-2 接口骨架；实际 FAST 模板算子、盘口 KVS 更新、Int8 神经网络权重和网络 MAC/UDP/TOE 前端按项目输入继续替换。

## Block Design IP 功能汇总

以下内容基于 `quant_trading/QUANT_TRADING.srcs/sources_1/bd/design_quant/design_quant.bd` 实际配置整理，覆盖本工程中所有 IP 及其作用。

### 1. 整体数据通路

```text
PS (M_AXI_HPM0_FPD)
       |
       v
axi_smartconnect_ctrl
       |----- AXI DMA 配置
       |----- BRAM 控制器
       |----- fast_decoder_ip_0/s_axi_ctrl
       |----- order_book_engine_ip_0/s_axi_ctrl
       |----- nn_decision_engine_ip_0/s_axi_ctrl
       |
       v
S_AXIS_RAW -> fast_decoder_ip_0 -> market_event_reorder_0 -> order_book_engine_ip_0
                                        |
                                        +--> axis_broadcaster_snapshot
                                                 |---> nn_decision_engine_ip_0/s_axis_feat
                                                 |---> quant_stream_mux_0/s_snapshot
                                                          |
                                                          v
                                                   quant_stream_mux_0 -> axis_fifo_snapshot -> axi_dma_quant -> axi_dwidth_dma -> PS S_AXI_HP0_FPD
```

### 2. IP 清单与职责

| IP 名称 | 类型 | 主要职责 | 备注 |
| --- | --- | --- | --- |
| `zynq_ultra_ps_e_0` | PS | ZCU111 的处理系统核心，负责控制面、时钟、DDR/AXI 总线连接和中断 | BD 的主控制单元 |
| `proc_sys_reset_0` | reset | 生成 PL 侧复位和复位时序 | 连接到各个自定义 IP 和 AXI 设备 |
| `axi_smartconnect_ctrl` | interconnect | 连接 PS 的 HPM AXI 总线到 DMA、BRAM 控制器和自定义 IP 控制寄存器 | 负责控制面总线聚合 |
| `axi_dma_quant` | DMA | 将 AXIS 输出搬运到 PS DDR，作为数据搬运桥接 | 配置在 S2MM 模式 |
| `axi_dwidth_dma` | width converter | 处理 AXI 数据位宽转换，连接 PS HP 端口与 DMA | 解决 DMA 与 HP 总线位宽匹配 |
| `axis_fifo_snapshot` | AXIS FIFO | 缓冲输出快照流，避免上游/下游时序不匹配 | 位于 mux 后端 |
| `axis_broadcaster_snapshot` | AXIS broadcaster | 将订单簿快照广播到多路后端，如决策输入与 mux 输入 | 增强一对多数据分发 |
| `blk_mem_kvs` | BRAM | 作为订单簿字典/键值 RAM，存储订单号、价格、数量等状态 | 真双口 BRAM |
| `axi_bram_ctrl_kvs` | BRAM controller | 将 PS 侧 AXI 访问桥接到 `blk_mem_kvs` | 供 PS 读取/观测 KVS |
| `fast_decoder_ip_0` | 自定义 IP | FAST/STEP 原始字节流解码，输出标准事件记录 | 对应 `fast_decoder_ip.v` |
| `market_event_reorder_0` | 自定义 IP | 对同时间戳事件做重排，保证 order 先于 trade | 对应 `market_event_reorder.v` |
| `order_book_engine_ip_0` | 自定义 IP | 维护订单簿、哈希表、价格档位、成交和撤单逻辑 | 对应 `order_book_engine_ip.v` |
| `quant_stream_mux_0` | 自定义 IP | 对 snapshot 与 signal 两路流做选择和合并 | 对应 `quant_stream_mux.v` |
| `nn_decision_engine_ip_0` | 自定义 IP | 生成量化决策信号，后续接入 AI/NN 策略逻辑 | 对应 `nn_decision_engine_ip.v` |

### 3. 自定义 IP 的功能定位

#### 3.1 `fast_decoder_ip_0`
- 接收 `S_AXIS_RAW` 输入，典型为 FAST/STEP 原始字节流。
- 解析字段标签、长度、Pmap 和 stop-bit 编码。
- 输出标准化的 128-bit 事件记录，供后续订单簿逻辑使用。
- 对应 RTL 模块：`quant_trading/rtl/fast_decoder_ip.v`。

#### 3.2 `market_event_reorder_0`
- 对同一时间戳下的事件按“先订单后成交”的规则重排。
- 避免订单簿在相同时间点上收到错误的执行顺序。
- 对应 RTL 模块：`quant_trading/rtl/market_event_reorder.v`。

#### 3.3 `order_book_engine_ip_0`
- 维护买卖盘价格档位、订单哈希表、数量状态。
- 处理新增委托、撤单、成交和价格档位更新。
- 输出订单簿快照流，并通过 BRAM 镜像接口给 PS 调试/观测。
- 对应 RTL 模块：`quant_trading/rtl/order_book_engine_ip.v`。

#### 3.4 `quant_stream_mux_0`
- 接收 snapshot 流和 signal 流。
- 在多路输出中按优先级/控制选择最终发出的数据流。
- 对应 RTL 模块：`quant_trading/rtl/quant_stream_mux.v`。

#### 3.5 `nn_decision_engine_ip_0`
- 接收特征或快照输入，输出固定格式的决策信号。
- 当前是接口壳层，后续可替换成真正的量化决策网络或 NN。
- 对应 RTL 模块：`quant_trading/rtl/nn_decision_engine_ip.v`。

### 4. 控制与存储关系

- PS 通过 `M_AXI_HPM0_FPD` 访问 `axi_smartconnect_ctrl`。
- `axi_smartconnect_ctrl` 再连到：
  - `axi_dma_quant/S_AXI_LITE`
  - `axi_bram_ctrl_kvs/S_AXI`
  - `fast_decoder_ip_0/s_axi_ctrl`
  - `order_book_engine_ip_0/s_axi_ctrl`
  - `nn_decision_engine_ip_0/s_axi_ctrl`
- `blk_mem_kvs` 作为订单簿的 BRAM 镜像，供 `order_book_engine_ip_0` 写入和软件审计。

### 5. 关键接口连接

- `fast_decoder_ip_0/m_axis_decoded -> market_event_reorder_0/s_axis`
- `market_event_reorder_0/m_axis -> order_book_engine_ip_0/s_axis_decoded`
- `order_book_engine_ip_0/m_axis_snapshot -> axis_broadcaster_snapshot/S_AXIS`
- `axis_broadcaster_snapshot/M01_AXIS -> quant_stream_mux_0/s_snapshot`
- `nn_decision_engine_ip_0/m_axis_signal -> quant_stream_mux_0/s_signal`
- `quant_stream_mux_0/m_axis -> axis_fifo_snapshot/S_AXIS`
- `axis_fifo_snapshot/M_AXIS -> axi_dma_quant/S_AXIS_S2MM`
- `axi_dma_quant/M_AXI_S2MM -> axi_dwidth_dma/S_AXI -> PS S_AXI_HP0_FPD`

### 6. 工程定位总结

这个 BD 的核心是：

- 处理系统负责控制和 DDR 数据搬运；
- 自定义 IP 负责协议解码、时间序重排、订单簿维护和决策输出；
- BRAM 负责订单簿/字典状态的镜像；
- DMA 负责把 FPGA 侧输出传回 PS。

因此，本工程可以视为一个“PS 控制 + PL 加速”的量化交易数据处理链路，符合 ZCU111 上的 FPGA/SoC 架构。

更多详细 RTL 说明请见：
- `quant_trading/README.md`
- `quant_trading/rtl/README.md`
