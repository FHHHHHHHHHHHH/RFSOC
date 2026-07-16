# ZCU111 V10 恒包络 DBPSK DAC–ADC 回环

本工程基于 Xilinx ZCU111 RFSoC 和 Vivado/Vitis 2020.2，实现双路 DAC
恒包络 DBPSK 发射、对称 outphasing 相位控制，以及 ADC10 IQ 接收解调。

V10 在独立工程和软件工作区中开发，没有继续修改已验证的 V9 环境。完整的
实现记录、调试过程和文件索引见
[V10_DPSK_CONTEXT.md](V10_DPSK_CONTEXT.md)。

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
| DBPSK 符号率 | 10 Mbps |

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
