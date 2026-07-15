# ZCU111 RFSoC Dual-IQ DAC/ADC Loopback

这是一个基于 Xilinx ZCU111 RFSoC、Vivado/Vitis 2020.2 的双通道射频收发与调试工程。

当前版本使用 DAC10/DAC11 输出两路 NCO 信号，并使用 ADC10/ADC12 两组高速 ADC IQ 通道接收。PS 端通过串口动态控制 DAC/ADC NCO、DAC 增益和通道相位，PL 端通过 System ILA 采集两组 ADC I/Q 数据。

项目的完整 Debug 历史、根因分析和交接信息见 [RFSOC_PROJECT_CONTEXT.md](RFSOC_PROJECT_CONTEXT.md)。

## 当前状态

- Vivado Block Design 验证通过。
- DAC Tile1、ADC Tile1 均使用外部采样时钟。
- ADC Tile1 的两个高速软件 Block 均配置为 R2C IQ fine mixer。
- ILA 已连接 ADC10 和 ADC12 两组完整 I/Q。
- PS 端 `ADCF`、`ADCR` 已同时支持两个 ADC 软件 Block。
- XSA、Vitis Platform、standalone BSP、FSBL BSP 和 RFSOC 应用已同步更新。
- `RFSOC.elf` 已在新 BSP 上 Clean Build 通过。
- ADC10 单路高频回路已验证得到约 `-9.990 MHz` 基带信号；双路 IQ 的新 CSV 仍需继续上板验证。

## 工程配置

| 项目 | 当前值 |
|---|---:|
| FPGA/RFSoC | XCZU28DR，ZCU111 |
| Vivado/Vitis | 2020.2 |
| DAC Tile | 软件 Tile1 / GUI Tile 229 |
| DAC 通道 | DAC10、DAC11 |
| DAC 采样率 | 5.89824 GSPS |
| ADC Tile | 软件 Tile1 / GUI Tile 225 |
| ADC 通道 | ADC10/11、ADC12/13 高速配对 |
| ADC 采样率 | 2.94912 GSPS |
| ADC 抽取 | 8 |
| ADC 输出样点率 | 368.64 MSPS |
| ADC AXIS 时钟 | 184.32 MHz |

RFDC 使用外部采样时钟，因此状态中的 `pll_enable=0`、`pll_lock=0` 是正常现象。

## RFDC 软件映射

| 软件目标 | GUI/物理通道 | 模式 | AXIS 输出 |
|---|---|---|---|
| DAC Tile1 Block0 | DAC10 | C2R fine mixer | `s10_axis` |
| DAC Tile1 Block1 | DAC11 | C2R fine mixer | `s11_axis` |
| ADC Tile1 Block0 | ADC10/ADC11 | R2C IQ fine mixer | I=`m10_axis`，Q=`m11_axis` |
| ADC Tile1 Block1 | ADC12/ADC13 | R2C IQ fine mixer | I=`m12_axis`，Q=`m13_axis` |

高速 ADC 模式下，软件 Block0/1 分别代表两组高速 ADC 配对，不应把 ADC10、ADC11、ADC12、ADC13 当成四个可以独立配置 NCO 的普通软件 Block。

## ILA 映射

| ILA slot | 信号 |
|---|---|
| 0 | ADC10 I，`m10_axis` |
| 1 | ADC10 Q，`m11_axis` |
| 2 | ADC12 I，`m12_axis` |
| 3 | ADC12 Q，`m13_axis` |
| 4 | DAC11 固定复数输入 |
| 5 | FIR1 输出 |
| 6 | DPSK TX1 输出 |
| 7 | TX1 baseband input |

每个 ADC 32-bit TDATA 包含两个连续的 signed 16-bit 样本：

```text
TDATA[15:0]  = sample 0
TDATA[31:16] = sample 1
```

因此分析时应使用 368.64 MSPS，而不是直接把 184.32 MHz ILA 时钟当成样点率。

## 当前 DAC 固定输入

`axis_broadcaster_128.v` 当前输出固定复数直流：

```verilog
wire signed [15:0] test_q = 16'sd0;
wire signed [15:0] test_i = 16'sd32767;

assign m_axis_tdata = {
    test_q, test_i,
    test_q, test_i,
    test_q, test_i,
    test_q, test_i
};

assign m_axis_tvalid = 1'b1;
```

RFDC DAC 的 C2R mixer 将该固定复数直流搬移到 DAC NCO 频率。当前固定输入绕开了上游 DPSK/FIR 实际数据，主要用于最大幅度的 NCO 回路测试。

## 物理回路

```text
DAC10 J7 -> ADC10 J2
DAC11 J8 -> ADC12 J1
```

若只验证第一路，可只连接 DAC10 到 ADC10。

## 串口命令

| 命令 | 功能 |
|---|---|
| `DACF <MHz>` | 同时设置 DAC Tile1 Block0/1 NCO |
| `ADCF <MHz>` | 同时设置 ADC Tile1 Block0/1 NCO |
| `DACR` | 回读两组 DAC mixer |
| `ADCR` | 回读两组 ADC mixer |
| `STAT` | 输出 RFDC Tile、Block、时钟和 FIFO 状态 |
| `AMPL <0..1>` | 设置两路 DAC QMC 增益 |
| `PASE <deg>` | 设置 DAC11 相对 DAC10 的 mixer 相位 |
| `TRAS <bits>` | 向 PL 发送有限长度二进制数据 |
| `COST <bits>` | 重复发送二进制数据 |

推荐高频回路测试：

```text
DACF 2400
ADCF 2390
DACR
ADCR
STAT
```

预期：

```text
DAC T1 B0/B1 NCO ≈ 2400 MHz
ADC T1 B0/B1 NCO ≈ -2390 MHz
ADC10 IQ 基带 ≈ -10 MHz
ADC12 IQ 基带 ≈ -10 MHz（连接第二根射频线时）
```

## 目录结构

```text
ZCU111_V9_adc.xpr
    Vivado 工程入口

ZCU111_V9_adc.srcs/
    Block Design、RFDC IP 配置、自定义 Verilog 和约束

ws/RFSOC/src/
    PS 裸机应用源代码

design_1_wrapper.xsa
    当前包含 bitstream 的硬件平台文件

util/
    Vivado/Vitis 自动化脚本、ILA 分析工具和测试说明

ILA_DATA/
    保留分析脚本和文本报告；原始 CSV 默认不提交

RFSOC_PROJECT_CONTEXT.md
    项目背景、Debug 时间线和后续任务交接文档
```

## Vivado 构建

1. 使用 Vivado 2020.2 打开 `ZCU111_V9_adc.xpr`。
2. 打开 `design_1.bd` 并执行 Validate Design。
3. Generate Output Products。
4. Run Synthesis。
5. Run Implementation。
6. Generate Bitstream。
7. Export Hardware，勾选 Include bitstream。

也可以使用工程中的 Tcl 脚本：

```powershell
E:\Xilinx\Vivado\2020.2\bin\vivado.bat -mode batch `
  -source util\check_dual_adc_iq.tcl `
  -tclargs ZCU111_V9_adc.xpr
```

如果工程被克隆到新目录，或 FIR Compiler 报告 COE 文件路径无效，先执行：

```powershell
E:\Xilinx\Vivado\2020.2\bin\vivado.bat -mode batch `
  -source util\set_fir_coe_project_path.tcl `
  -tclargs ZCU111_V9_adc.xpr
```

该脚本会从当前工程目录定位 `util/rrc_filter_10Mbps_alpha08.coe`，并让 Vivado 将两个 FIR IP 的依赖保存为相对路径。

导出当前已完成 implementation 的 XSA：

```powershell
E:\Xilinx\Vivado\2020.2\bin\vivado.bat -mode batch `
  -source util\export_current_dual_iq_xsa.tcl `
  -tclargs ZCU111_V9_adc.xpr
```

## Vitis Platform 和应用构建

RFDC 配置发生变化后，不能只重新编译 `helloworld.c`。必须同步更新 XSA、Platform 和 BSP，否则驱动会使用错误的采样率、Mixer Mode 或通道配置。

更新平台：

```powershell
E:\Xilinx\Vitis\2020.2\bin\xsct.bat `
  util\update_vitis_dual_iq_platform.tcl
```

重新编译应用：

```powershell
cd ws\RFSOC\Debug
E:\Xilinx\Vitis\2020.2\gnuwin\bin\make.exe clean
E:\Xilinx\Vitis\2020.2\gnuwin\bin\make.exe all
```

当前双 IQ BSP 应满足：

```text
ADC_MIXER_MODE10/11/12/13 = 0
ADC_MIXER_TYPE10/11/12/13 = 2
ADC_DATA_WIDTH10/11/12/13 = 2
ADC_DECIMATION_MODE10/11/12/13 = 8
```

## ILA CSV 分析

通用双 IQ 分析工具：

```powershell
E:\Xilinx\Vitis\2020.2\tps\win64\python-3.8.3\python.exe `
  util\ila_data.py `
  --csv <ILA CSV> `
  --expected-iq-frequency=-10e6 `
  --no-plot
```

默认映射为：

```text
ADC10 I/Q = slot0/slot1
ADC12 I/Q = slot2/slot3
```

## 已确认的关键问题

项目最重要的历史故障是硬件与 BSP 不一致：

```text
硬件 ADC 采样率 = 2949.12 MSPS
旧 BSP ADC 采样率 = 2000 MSPS
```

这会使 ADC NCO 调谐字错误。出现以下矛盾时，应立即检查 XSA/BSP：

```text
[CLOCK] ADC sample=2949 MHz
[BLOCK] ADC fs=2000 MHz
```

完整过程见 [RFSOC_PROJECT_CONTEXT.md](RFSOC_PROJECT_CONTEXT.md)。

## 当前待验证事项

- 同时连接两根射频线，采集 slot0～slot3 的新 ILA CSV。
- 对比两组 IQ 的频率、幅度、相位和镜像抑制。
- 使用示波器确认 `I=32767` 时的实际 DAC 最大输出幅度。
- 如需进一步提高 DAC 输出，检查 `FineMixerScale=1.0` 并确认没有削顶。
- 若恢复 DPSK/FIR 通信数据，需要取消固定 IQ 测试源并恢复正确的 AXIS 握手。
