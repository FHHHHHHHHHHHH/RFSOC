# ZCU111 V10 恒包络 DBPSK DAC–ADC 回环

本工程基于 Xilinx ZCU111 RFSoC 和 Vivado/Vitis 2020.2，实现双路 DAC
恒包络 DBPSK 发射、对称 outphasing 相位控制，以及 ADC10 IQ 接收解调。

V10 在独立工程和软件工作区中开发，没有继续修改已验证的 V9 环境。完整的
实现记录、调试过程和文件索引见
[V10_DPSK_CONTEXT.md](V10_DPSK_CONTEXT.md)。

## 项目总结

V10 的目标是在不破坏 V9 已验证工程的前提下，建立一套可独立维护的双路
DAC–ADC 恒包络 DBPSK 收发平台，为后续外接 outphasing PA、功率合成和更完整的
接收算法提供基础。当前工程已经形成以下闭环：

| 子系统 | 当前实现 |
|---|---|
| 双路发射 | DAC10、DAC11 发送完全相同的恒包络 DBPSK 数据 |
| 空闲载波 | 无数据时持续输出 `+A+j0`，RF 端保持连续正弦载波 |
| 频率控制 | DAC/ADC NCO 可通过串口动态修改，默认形成 10 MHz 数字中频 |
| 幅相控制 | 两路等幅 QMC 增益；对称 `-Δφ/2`、`+Δφ/2` outphasing 相位控制 |
| 信息接口 | 支持 ASCII、二进制、单帧发送和连续帧发送 |
| 接收解调 | ADC10 I/Q 下变频、差分检测、帧同步、长度解析和 CRC16 校验 |
| 调试接口 | UART 状态、RFDC mixer 回读、JTAG AXI、VIO 和 8 槽 System ILA |
| 工程隔离 | V10 使用独立 Vivado 工程、Vitis workspace 和 Git 分支 `v10-dpsk` |

当前物理验证范围是 `DAC10 J7 -> ADC10 J2` 的直连回环，不包含外置 PA。
DAC11 已与 DAC10 同步产生数据，可用于双通道示波器/VSA 测相，或在后续阶段接入
outphasing PA。两路理想合成幅度和功率分别满足：

```text
|Vsum| = 2A·cos(Δφ/2)
Psum / Pmax = cos²(Δφ/2)
```

## 当前状态

- Vivado Block Design 验证通过。
- RTL 端到端 DBPSK 回环仿真通过，成功解码 `HELLO`。
- 综合、布局布线和 bitstream 生成通过。
- 时序通过：WNS `+0.563 ns`，TNS `0 ns`。
- DAC Tile1、ADC Tile1 上板启动成功，状态均为 `0xF`。
- DAC/ADC 数据路径时钟正常，FIFO 无告警。
- 默认 DAC NCO `2400 MHz`、ADC NCO `2390 MHz`，数字中频 `10 MHz`。
- 串口命令输入、AXI FIFO 收发和 DAC→ADC DBPSK 解调已完成上板验证。
- `SEND Hello RFSoC` 和 `TRAS 01010101` 已验证。
- `LOOP <text>`、`STOP` 已完成 AArch64 编译和链接验证；连续模式的最终板级统计
  仍应以上板输出为准。

## 数据链路

```text
UART command
  -> PS AXI FIFO TX
  -> dual_dac_dbpsk_tx
  -> DAC10 / DAC11

DAC10 J7
  -> RF cable
  -> ADC10 J2
  -> ADC10 I/Q fine mixer
  -> dbpsk_adc_rx_v10
  -> AXI async FIFO
  -> PS AXI FIFO RX
  -> UART decoded payload
```

DAC11 与 DAC10 发送相同的 DBPSK 数据和包络，仅通过 RFDC mixer 调整两路
载波相位。当前解调器使用 ADC10 的 I/Q；ADC12/ADC13 保留在 ILA 中用于第二路
观测。

## RFDC 配置

| 项目 | 配置 |
|---|---:|
| FPGA/RFSoC | XCZU28DR / ZCU111 |
| Vivado/Vitis | 2020.2 |
| DAC Tile | 软件 Tile1 / GUI Tile 229 |
| DAC 通道 | DAC10、DAC11 |
| DAC 采样率 | 5.89824 GSPS |
| DAC 插值 | 8 |
| ADC Tile | 软件 Tile1 / GUI Tile 225 |
| ADC 通道 | ADC10/11、ADC12/13 高速配对 |
| ADC 采样率 | 2.94912 GSPS |
| ADC 抽取 | 8 |
| ADC AXIS 时钟 | 184.32 MHz |
| 默认 DAC NCO | 2400 MHz |
| 默认 ADC NCO | 2390 MHz |
| 数字中频 | 10 MHz |
| DBPSK 符号率 | 10 Mbaud（DBPSK 数据率 10 Mbit/s） |

RFDC 使用外部采样时钟，因此状态中的 `pll_enable=0`、`pll=0` 是正常现象。

## 恒包络 DBPSK

本工程不使用 RRC FIR。每个符号期间持续输出：

```text
+A 或 -A，A = 32767
Q = 0
```

- 空闲时连续输出 `+A`，因此 DAC 始终有基本正弦载波。
- DBPSK 比特 `1` 翻转差分相位，`0` 保持相位。
- DAC10 和 DAC11 始终保持相同数据、幅度和 DBPSK 相位变化。
- `PASE Δφ` 使用对称相位：DAC10=`-Δφ/2`，DAC11=`+Δφ/2`。
- 对称 outphasing 调节相位差时，合成信号的公共相位基本不变。

为保留从 V9 演进到 V10 的工程可追溯性，源码目录中仍包含旧 RRC COE、DDS 和早期
DPSK/广播模块文件；它们未实例化到当前有效 BD 数据链中，实际 V10 收发链路不经过
RRC FIR。

## 帧格式

每个 AXI FIFO 字的低 8 位携带一个字节，比特按 MSB first 发送。

```text
FF FF FF FF                 preamble
D3 91 C5 A7                 sync word
length[15:8] length[7:0]    payload length
payload                     0..256 bytes
CRC[15:8] CRC[7:0]          CRC16-CCITT
```

CRC 初值为 `0xFFFF`，多项式为 `0x1021`，覆盖长度字段和 payload。

## 物理回环

当前接收解调验证只需要：

```text
DAC10 J7 -> ADC10 J2
```

如需同时观察第二路 IQ，可增加：

```text
DAC11 J8 -> ADC12 J1
```

当前阶段不需要接入外置 outphasing PA。

## 串口命令

串口设置：`115200 8N1`，关闭流控，行尾使用 CR 或 CRLF。

| 命令 | 功能 |
|---|---|
| `SEND Hello RFSoC` | 发送 ASCII payload，自动添加同步字、长度和 CRC |
| `LOOP RFSOC` | 连续、背靠背发送带完整帧结构和 CRC 的 ASCII payload |
| `STOP` | 停止 `LOOP` 连续发送，并输出排队帧数及接收统计 |
| `TRAS 01010101` | 发送二进制字节，MSB first |
| `DACF <MHz>` | 同时设置 DAC10/DAC11 NCO |
| `ADCF <MHz>` | 同时设置 ADC Tile1 两个软件 Block NCO |
| `PASE <deg>` | 设置两路 DAC 的对称 outphasing 相位差 |
| `AMPL <0..1>` | 同时设置两路 DAC QMC 增益 |
| `DACR` | 回读 DAC mixer |
| `ADCR` | 回读 ADC mixer |
| `STAT` | 输出 RFDC Tile、Block、时钟和 FIFO 状态 |
| `HELP` | 显示帮助 |

推荐测试：

```text
STAT
SEND Hello RFSoC
TRAS 01010101
PASE 60
```

`PASE 60` 对应 DAC10=`-30°`、DAC11=`+30°`。

需要使用频谱仪或示波器持续观察 DBPSK 信号时，可使用：

```text
LOOP RFSOC
PASE 60
AMPL 0.5
STAT
STOP
```

`LOOP` 运行期间串口仍然可以接收 `DACF`、`ADCF`、`PASE`、`AMPL`、`STAT`
和 `STOP`。为避免逐帧打印占满 115200 baud 串口，连续模式只累计回环接收统计；
执行 `STOP` 或 `STAT` 时可查看 `queued`、`rx_ok`、`crc_fail` 和 `rx_err`。
`STOP` 停止继续向发送 FIFO 补帧，FIFO 中已经排队的少量帧会在停止后发送完毕。

## 已解决的上板问题

### 误启动 DAC Tile0

Xilinx 2020.2 的 `XRFdc_GetIPStatus()` 不会主动清零禁用 Tile 的
`IsEnabled` 字段。未初始化的栈数据曾导致程序误判 DAC Tile0 已启用，并调用
`XRFdc_StartUp()` 启动 Tile0。

应用层修复：

- 调用 `XRFdc_GetIPStatus()` 前清零 `XRFdc_IPStatus`；
- 只启动工程明确配置的 DAC Tile1 和 ADC Tile1。

没有修改 Xilinx 安装目录中的官方驱动，工程内 `xrfdc_clk.c/.h` 与 V9
验证版本保持一致。

### 提示符出现后串口不能输入

原主循环先轮询 RX FIFO，而且没有先判断完整接收包，可能阻止 UART 轮询。

应用层修复：

- UART 优先轮询；
- 仅在 `XLlFifo_IsRxDone()` 有效时读取 RX FIFO；
- 初始化和包读取完成后清除 FIFO 状态标志。

## 主要文件

```text
V10_DPSK/V10_DPSK.xpr
V10_DPSK/V10_DPSK.srcs/sources_1/bd/design_1/design_1.bd
V10_DPSK/V10_DPSK.srcs/sources_1/new/dual_dac_dbpsk_tx.v
V10_DPSK/V10_DPSK.srcs/sources_1/new/dbpsk_adc_rx.v
sim/tb_dbpsk_loopback.sv
sw/RFSOC/src/main.c
sw/RFSOC/src/xrfdc_clk.c
scripts/update_v10_dbpsk_bd.tcl
scripts/build_v10_direct.tcl
sw/design_1_wrapper.xsa
```

## 构建

完整硬件构建：

```powershell
E:\Xilinx\Vivado\2020.2\bin\vivado.bat -mode batch `
  -source scripts\build_v10_direct.tcl
```

端到端 RTL 仿真测试台位于 `sim/tb_dbpsk_loopback.sv`。构建产生的 bitstream、
LTX、DCP、ELF、Vivado/Vitis 缓存和日志不提交到 Git；仓库保留生成这些文件所需
的工程源码、Tcl 脚本和含 bitstream 的 V10 XSA。

## 已知提示

FSBL 可能输出：

```text
PMU-FW is not running, certain applications may not be supported.
```

该提示在已验证的 V9/V10 裸机 RFDC 回环流程中均存在，不影响本工程的时钟、
NCO、FIFO 或 DBPSK 回环验证。

## Block Design 各 IP 功能分析

本节对应当前有效的
`V10_DPSK/V10_DPSK.srcs/sources_1/bd/design_1/design_1.bd`。工程中保留的旧
RRC、DDS 和早期 DPSK 源文件不属于下面的数据链，也未实例化到当前 BD。

### 顶层 IP 总览

| BD 实例 | IP 类型/关键配置 | 在本工程中的功能 |
|---|---|---|
| `zynq_ultra_ps_e_0` | Zynq UltraScale+ MPSoC PS | A53 裸机程序运行平台；提供 UART0、DDR、100 MHz `pl_clk0`、`pl_resetn0`，并通过 `M_AXI_HPM0_FPD`/`M_AXI_HPM1_FPD`访问 PL 寄存器。 |
| `ps8_0_axi_periph` | AXI Interconnect，3 SI / 2 MI | 汇聚 PS HPM0、PS HPM1 和 JTAG AXI 三个主端，路由到 RFDC AXI-Lite 寄存器和 AXI FIFO MM-S。内部自动完成协议及位宽适配。 |
| `proc_sys_reset_0` | Processor System Reset | 在约 100 MHz PS/AXI 时钟域内同步 `pl_resetn0`，产生 AXI interconnect、RFDC 控制口、AXI FIFO、JTAG AXI 和发送 CDC 输入侧所需的低有效复位。 |
| `usp_rf_data_converter_0` | RF Data Converter 2.4 | 启用 DAC Tile1 的 DAC10/DAC11 和 ADC Tile1 的 ADC10/ADC12 高速配对；完成 DAC 8×插值、ADC 8×抽取、数字 mixer、NCO、QMC 以及模拟 RF I/O。 |
| `axi_fifo_mm_s_0` | AXI FIFO MM-S 4.2，TX/RX 深度 512 | 软件与 AXI4-Stream 数据链之间的双向桥。PS 将待发帧写入 TX FIFO，并从 RX FIFO读取解调后的状态头和 payload。采用 store-and-forward。 |
| `axis_data_fifo_0` | AXIS Data FIFO，32 bit，异步，深度 512，带 TLAST | 发送时钟域转换：100 MHz AXI FIFO TX 流转换到 184.32 MHz DAC/DSP 时钟域，同时缓存完整帧字节流。 |
| `dual_dac_dbpsk_tx_0` | 自定义 RTL `dual_dac_dbpsk_tx` | 从每个 32-bit AXIS 字的低 8 位取一个字节，MSB first 按 10 Mbaud 差分编码；输出四组并行 `I=+32767/-32767, Q=0` 样点，并复制到 DAC10、DAC11 两路 128-bit AXIS。 |
| `dbpsk_adc_rx_0` | 自定义 RTL `dbpsk_adc_rx_v10` | 接收 ADC10 的 32-bit I/Q 流，取每拍 sample0；用本地 -10 MHz 复数 NCO 下变频，建立相位参考、检测 180°翻转、恢复符号、搜索同步字并完成长度和 CRC16 校验。 |
| `axis_data_fifo_rx` | AXIS Data FIFO，32 bit，异步，深度 1024，带 TLAST | 接收时钟域转换：将 184.32 MHz 解调输出跨到约 100 MHz AXI/PS 域，再送入 AXI FIFO MM-S 的 RX 流接口。 |
| `system_ila_1` | System ILA，8 个 AXIS 槽，深度 16384 | 同时观察 ADC10/ADC12 原始 I/Q、DAC10/DAC11 数字样点、解调输出和 PS 发送字节流，用于定位 RFDC、调制器、解调器和 FIFO 边界问题。 |
| `jtag_axi_0` | JTAG to AXI Master | 允许 Vivado Hardware Manager 不依赖 A53 软件直接访问 RFDC 和 AXI FIFO 地址空间，适合寄存器检查和底层调试。 |
| `proc_sys_reset_dac` | Processor System Reset | 在 `clk_dac1=184.32 MHz` DSP 时钟域内同步复位，驱动 DBPSK 发射器、接收器和 RX 异步 FIFO 写入侧。 |
| `util_ds_buf_0` | Differential Buffer | 将 ZCU111 板载 `default_sysclk1_300mhz` 差分时钟转换为单端内部时钟，仅服务于 VIO 调试时钟支路。 |
| `util_ds_buf_1` | `BUFGCE_DIV`，除数 6 | 将 300 MHz 调试时钟分频到约 50 MHz，作为 `vio_0` 的采样时钟；CE 固定为 1，CLR 由 VIO 输出控制。 |
| `xlconstant_0` | Constant 1 | 将 `util_ds_buf_1/BUFGCE_CE` 固定拉高，使调试时钟分频器持续工作。 |
| `vio_0` | Virtual I/O，3 输入/1 输出 | 输入探测 PS `pl_clk0`、RFDC `clk_dac1` 和 AXI 域复位状态；输出控制 `BUFGCE_DIV` 的清零端。它不参与 DBPSK 数据处理。 |

### RFDC 配置与软件运行时控制

`usp_rf_data_converter_0` 的 BD 配置决定启用的 Tile/Slice、采样率、插值、抽取、
数据宽度和 RF 接口。实际运行频率、相位和幅度由软件在 RFDC 启动后重新配置：

| 功能 | BD/硬件职责 | `sw/RFSOC/src/main.c` 运行时职责 |
|---|---|---|
| DAC 采样 | 5.89824 GSPS，8×插值，DAC10/DAC11 启用 | `DACF` 同时设置两个 DAC fine mixer NCO，默认 2400 MHz |
| ADC 采样 | 2.94912 GSPS，8×抽取，ADC10/ADC12 配对启用 | `ADCF` 同时设置两个 ADC 软件 Block NCO，默认 2390 MHz |
| 相位 | RFDC mixer 支持独立 phase offset | `PASE Δφ` 写入 DAC10=`-Δφ/2`、DAC11=`+Δφ/2` |
| 幅度 | RFDC QMC 支持每通道 gain correction | `AMPL 0..1` 对两路设置相同 QMC 增益 |

因此，Vivado BD 中保存的初始 NCO 字段不是最终上板工作频率；以软件启动日志、
`DACR`/`ADCR` 回读和 `MODE requested` 状态为准。

### 发送链 IP 协作

```text
A53/UART
  -> axi_fifo_mm_s_0 TX (100 MHz)
  -> axis_data_fifo_0 CDC (100 -> 184.32 MHz)
  -> dual_dac_dbpsk_tx_0
  -> RFDC s10_axis / s11_axis
  -> DAC10 J7 / DAC11 J8
```

`dual_dac_dbpsk_tx_0` 在无数据时仍令 AXIS 输出有效并持续送出正 I 样点，因此 RFDC
不会因 FIFO 空闲而失去载波。数据比特 `1` 对 `phase_state` 异或翻转，数据比特
`0` 保持；两路数字样点始终相同，outphasing 相位差由 RFDC mixer 在数模转换前加入。
模块保留了 `tx_active` 和 `frame_start` 输出，但当前 BD 未将它们连接到外部引脚或
ILA 槽位。

### 接收链 IP 协作

```text
ADC10 J2
  -> RFDC ADC10 I/Q fine mixer
  -> m10_axis(I) + m11_axis(Q)
  -> dbpsk_adc_rx_0
  -> axis_data_fifo_rx CDC (184.32 -> 100 MHz)
  -> axi_fifo_mm_s_0 RX
  -> A53/UART
```

接收器将通过 ADC mixer 后约为 -10 MHz 的复信号再次数字下变频到基带，利用空闲
连续载波建立参考方向，再以相邻符号投影的符号变化完成非相干 DBPSK 判决。有效帧
输出格式为：

```text
word0 = 0xD5 | status | payload_length[15:0]
word1..N = payload byte，位于每个 32-bit word 的低 8 位
```

`status=1` 表示 CRC 正确，`status=0` 表示 CRC 失败。模块内部维护
`good_frame_count`/`bad_frame_count`，但当前 BD 没有将这两个计数输出连接到 AXI
寄存器或 ILA；软件当前使用 RX 包头状态进行统计。

### System ILA 槽位映射

| ILA 槽位 | 连接信号 | 用途 |
|---:|---|---|
| 0 | RFDC `m10_axis` | ADC10 I 数据 |
| 1 | RFDC `m11_axis` | ADC10 Q 数据 |
| 2 | RFDC `m12_axis` | ADC12 I 数据，第二接收通道观测 |
| 3 | RFDC `m13_axis` | ADC12 Q 数据，第二接收通道观测 |
| 4 | `dual_dac_dbpsk_tx_0/m1_axis` | 送往 DAC11 的 128-bit IQ 样点 |
| 5 | `dual_dac_dbpsk_tx_0/m0_axis` | 送往 DAC10 的 128-bit IQ 样点 |
| 6 | `dbpsk_adc_rx_0/m_axis` | 解调器状态头和 payload 输出 |
| 7 | `axis_data_fifo_0/M_AXIS` | PS/FIFO 发往调制器的字节流和 TLAST |

ILA 使用 184.32 MHz `clk_dac1` 采样。槽 4/5 能验证恒包络 `+A/-A` 数字样点，
但 `PASE` 和 `AMPL` 在 RFDC 内部 mixer/QMC 中实现，最终模拟幅相仍需通过
DAC10/DAC11 外部端口使用双通道示波器或 VSA 测量。

### AXI 地址映射

| 主端 | 从端 | 基地址 | 范围 | 用途 |
|---|---|---:|---:|---|
| PS A53 | RFDC `s_axi` | `0xA0000000` | 256 KiB | Tile、Block、mixer、NCO、QMC 和状态寄存器 |
| PS A53 | AXI FIFO MM-S | `0xA0040000` | 64 KiB | TX/RX FIFO 数据、长度、占用量和中断状态 |
| JTAG AXI | RFDC `s_axi` | `0xA0000000` | 256 KiB | Hardware Manager 直接调试 |
| JTAG AXI | AXI FIFO MM-S | `0xA0040000` | 64 KiB | Hardware Manager 直接调试 |

### `ps8_0_axi_periph` 内部自动生成 IP

这些单元位于 AXI Interconnect 层级内部，由 Vivado 自动插入，不承担调制或解调
算法，但保证不同主端能够正确访问两个 32-bit AXI 从设备：

| 层级实例 | IP | 功能 |
|---|---|---|
| `ps8_0_axi_periph/xbar` | AXI Crossbar | 3 个输入主端到 2 个输出从端的地址译码、仲裁和路由。 |
| `s00_couplers/auto_pc` | AXI Protocol Converter | 适配 PS HPM0 与 crossbar 的 AXI 协议属性。 |
| `s01_couplers/auto_pc` | AXI Protocol Converter | 适配 JTAG AXI 主端与 crossbar。 |
| `s02_couplers/auto_ds` | AXI Data Width Converter | 将 PS HPM1 的 128-bit AXI 数据宽度适配为内部/从端所需宽度。 |
| `s02_couplers/auto_pc` | AXI Protocol Converter | 完成 HPM1 路径的协议属性适配。 |

### 时钟与复位域总结

| 时钟域 | 频率 | 主要 IP | 复位来源 |
|---|---:|---|---|
| PS/AXI 控制域 | 约 100 MHz | PS HPM、AXI Interconnect、RFDC `s_axi`、AXI FIFO、JTAG AXI、两个异步 FIFO 的 PS 侧 | `proc_sys_reset_0` |
| DAC/DSP 流域 | 184.32 MHz | RFDC AXIS、双路 DBPSK TX、DBPSK RX、System ILA、异步 FIFO 的 RF 侧 | `proc_sys_reset_dac` |
| VIO 调试域 | 约 50 MHz | `vio_0` | 300 MHz 差分时钟经 `util_ds_buf_0` 和 `/6` 分频产生 |
| RF 采样域 | DAC 5.89824 GHz / ADC 2.94912 GHz | RFDC Tile1 模拟转换和数字插值/抽取链 | 外部 LMK/LMX 时钟，由裸机软件按 V9 已验证流程配置 |
