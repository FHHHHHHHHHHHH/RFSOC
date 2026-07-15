# ZCU111 RFSoC 项目背景、Debug 过程与当前状态

> 最后更新：2026-07-15
>
> 工程根目录：`E:\Vivado_prj\ZCU111_V9_ADC\ZCU111_V9_adc`
>
> Vivado / Vitis：2020.2
> 本文档是当前项目的上下文与配置“唯一可信入口”。根目录原有 `README.md` 内容较旧且存在乱码，其中 ADC00/ADC02、1.47456 GSPS 等描述已经过时，不应作为当前配置依据。

## 1. 给后续 GPT 的快速结论

本项目的目标是在 ZCU111 RFSoC 上完成双路 DAC 输出、DAC NCO、ADC 高频通道接收、ADC NCO 下变频以及 ILA 数据验证。

项目曾长时间出现“DAC 示波器输出正常，但 ADC I/Q 像乱码”的现象。最终确认：

1. RFSoC ADC/DAC 硬件、射频回路和 NCO 本身没有故障。
2. 最关键的问题是 Vivado 硬件配置已经切换到 ADC Tile1、2949.12 MSPS，但 Vitis 应用一度仍链接旧 standalone BSP；旧 BSP 把 ADC Tile1 描述为未使能、采样率 2.0 GSPS。
3. 因此 PS 端 `XRFdc_SetMixerSettings()` 曾按 2.0 GSPS 计算 ADC NCO 调谐字，导致 `DACF 2400 / ADCF 2390` 得到约 29.385 MHz，而不是理论上的约 10 MHz。
4. 更新 XSA、Platform、standalone BSP 并重编译应用后，串口和硬件采样率统一为 2949.12 MSPS，ILA 得到 `-9.990 MHz`，I/Q 正交误差约 `0.0013°`，镜像抑制约 `87.85 dB`，验证通过。
5. 当前 PL 固定 DAC 复数输入已提高为 `Q=0, I=32767`；2026-07-15 18:17 的当前 bitstream 晚于该源码修改，已经包含该满幅数字输入。
6. 2026-07-15 后续修改已把 ADC Tile1 的两个软件 Block 都配置为 IQ/R2C：Block0 输出 `m10/m11`，Block1 输出 `m12/m13`。PS、XSA 和 Vitis BSP 已同步更新，但双路 IQ 的新硬件回路数据尚待上板采集验证。

如果新任务只需要快速恢复上下文，优先阅读本文档的第 3、4、8、10、12 节。

## 2. 工程目标与参考工程

### 2.1 当前主工程

- Vivado 工程：`ZCU111_V9_adc.xpr`
- Block Design：`ZCU111_V9_adc.srcs/sources_1/bd/design_1/design_1.bd`
- Vitis workspace：`ws`
- PS 应用：`ws/RFSOC/src/helloworld.c`
- 当前 XSA：`design_1_wrapper.xsa`

### 2.2 曾用于交叉验证的小工程

以下工程不在当前 workspace 内，但曾用来证明板卡、DDS、DAC 和 ADC 基本硬件正常：

- `E:\Vivado_prj\dds_ila_v2\dds_ila_v2\dds_ila_v2.xpr`
- `E:\vivado2020_2_dds_ila_project\vivado2020_2_dds_ila_project\vv.xpr`

小工程曾实现：

```text
DDS -> DAC -> 射频线缆 -> ADC IQ -> ILA
```

DDS 10 MHz、60 MHz 以及 DAC/ADC NCO 组合测试均能得到可解释的正弦或复数基带结果，因此旧主工程的问题被定位为工程集成和配置同步问题，而不是 RFSoC 模拟硬件损坏。

### 2.3 本地文档

`deco` 目录保存 ZCU111、RF Data Converter、原理图和 RF 采样相关 PDF，主要包括：

- `deco/ug1309-rf-data-converter-interface.pdf`
- `deco/ug1271-zcu111-eval-bd.pdf`
- `deco/SCH_ZCU111_REV1_0_07122018.pdf`
- `deco/ug1287-zcu111-rfsoc-eval-tool.pdf`
- `deco/zcu111-dds-ila-2020p21769439289984.pdf`

## 3. 当前 RFDC 时钟与数据率

| 项目 | 当前值 |
|---|---:|
| DAC Tile | 软件 Tile 1 / GUI Tile 229 |
| DAC 采样率 | 5.89824 GSPS |
| DAC 外部参考/采样时钟 | 5898.240 MHz |
| ADC Tile | 软件 Tile 1 / GUI Tile 225 |
| ADC 采样率 | 2.94912 GSPS |
| ADC 外部参考/采样时钟 | 2949.120 MHz |
| ADC 抽取 | 8 |
| ADC 抽取后样点率 | 368.64 MSPS |
| ADC AXIS/Fabric 时钟 | 184.32 MHz |
| ADC AXIS 数据宽度 | 每个通道 32 bit |
| 每个 32-bit ADC TDATA | 两个连续的 signed 16-bit 样本 |

RFDC 使用外部时钟，RFDC 内部 PLL 关闭。因此串口中的：

```text
pll_enable=0
pll_lock=0
```

在当前配置下是正常现象，不表示时钟失锁。

## 4. 当前通道与软件 Block 映射

### 4.1 DAC

| 软件目标 | GUI 通道 | 模式 | 控制命令 |
|---|---|---|---|
| DAC Tile1 Block0 | DAC10 | C2R fine mixer | `DACF` |
| DAC Tile1 Block1 | DAC11 | C2R fine mixer | `DACF` |

`DACF` 会同时更新 DAC Block0 和 Block1，并统一触发 mixer update event。

### 4.2 高速 ADC

ZCU111 的 ADC Tile 224/225 是高速 ADC 架构。软件 Block 编号不能简单等同于 GUI 中连续的 ADC00/ADC01/ADC02/ADC03 名称。

当前使用 ADC Tile1（GUI Tile 225）：

| 软件目标 | GUI/物理含义 | 当前模式 | AXIS 输出 |
|---|---|---|---|
| ADC Tile1 Block0 | ADC10/ADC11 高速配对 | R2C IQ fine mixer、Decimation 8 | I=`m10_axis`，Q=`m11_axis` |
| ADC Tile1 Block1 | ADC12/ADC13 高速配对 | R2C IQ fine mixer、Decimation 8 | I=`m12_axis`，Q=`m13_axis` |

关键理解：

- 将软件 Block0 配成 IQ/R2C 后，会使用高速 ADC 配对资源。
- `m10_axis` 和 `m11_axis` 是同一个软件 Block0 的 I/Q 数字输出，不应把它们理解成两个可以独立配置 NCO 的普通 ADC Block。
- 软件 Block1 对应另一组高速 ADC 配对，当前同样为 IQ/R2C。
- PS 中 `ADCF` 依次配置软件 Block0 和 Block1，然后发出一次 Tile 级 mixer update event。

### 4.3 ILA slot 映射

| ILA slot | 当前信号 |
|---|---|
| 0 | ADC10 I，`m10_axis` |
| 1 | ADC10 Q，`m11_axis` |
| 2 | ADC12 I，`m12_axis` |
| 3 | ADC12 Q，`m13_axis` |
| 4 | DAC11 固定复数输入 |
| 5 | FIR1 输出 |
| 6 | DPSK TX1 输出 |
| 7 | TX1 baseband input，`axis_broadcaster_0/M01_AXIS` |

分析 ADC10 IQ 时组合 slot0 和 slot1；分析 ADC12 IQ 时组合 slot2 和 slot3。

## 5. 当前物理回路

高频主回路：

```text
DAC10 J7 -> ADC10 J2
```

第二路：

```text
DAC11 J8 -> ADC12 J1
```

两根射频线都连接时，ADC10 IQ（slot0/1）和 ADC12 IQ（slot2/3）应在相同 `ADCF` 设置下得到相同量级的基带频率；幅度和相位可能因模拟路径而不同。

## 6. 当前 DAC 固定输入状态

文件：`ZCU111_V9_adc.srcs/sources_1/new/axis_broadcaster_128.v`

当前输出为固定复数直流：

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

含义：

- RFDC DAC 的 C2R mixer 将固定复数直流搬移到 DAC NCO 频率。
- `32767` 是 signed 16-bit 最大正值。
- `16'sd65536` 是错误写法；65536 超出 16-bit signed 范围，截断后低 16 位为 0。
- 从原来的 `I=8192` 提高到 `I=32767`，理论电压幅度提高约 4 倍，固定负载下功率提高约 12 dB。
- 当前固定输出完全绕开上游实际 `s_axis_tdata/s_axis_tvalid`，因此在恢复原始 DPSK/FIR 数据链之前，`TRAS`、`COST` 和上游 FIR 数据不会改变 DAC 波形。
- `AMPL` 是 RFDC QMC 增益控制，仍可作用于 DAC；最大值使用 `AMPL 1.0`。

当前 2026-07-15 18:17 生成的 bitstream 已晚于 `I=32767` 源码修改，并已被封装进 20:03 导出的 XSA。板卡是否已经下载该版本仍需通过下载记录和示波器确认。

若还要追求理论最大模拟功率，应进一步确认 `XRFdc_Mixer_Settings.FineMixerScale` 是否为 `XRFDC_MIXER_SCALE_1P0`；当前 `ConfigNCO()` 没有显式强制该字段。由于 Q=0，设置 1.0 通常不会产生 I/Q 合成溢出，但修改前仍应检查 DAC 输出是否削顶。

## 7. PS 串口程序

主要文件：`ws/RFSOC/src/helloworld.c`

关键宏：

```c
#define DAC_TARGET_TILE_ID  1
#define ADC_TARGET_TILE_ID  1
#define ADC_TARGET_BLOCK_ID_0  0
#define ADC_TARGET_BLOCK_ID_1  1
```

主要命令：

| 命令 | 功能 |
|---|---|
| `DACF <MHz>` | 同时设置 DAC Tile1 Block0/1 NCO |
| `ADCF <MHz>` | 同时设置 ADC Tile1 Block0/1 NCO |
| `DACR` | 回读两路 DAC mixer |
| `ADCR` | 回读 ADC Tile1 Block0/1 mixer |
| `STAT` | 输出 Tile、Block、时钟、FIFO 和数字路径状态 |
| `AMPL <0..1>` | 通过 DAC QMC 设置两路 DAC 增益 |
| `PASE <deg>` | 修改 DAC Block1 相对相位 |
| `TRAS <bits>` | 向 AXI FIFO 发送有限长度二进制数据 |
| `COST <bits>` | 重复发送二进制数据 |

`ConfigNCO()` 当前行为：

- 从 `RFdcInst.*_Tile[Tile_Id].PLL_Settings.SampleRate` 获取驱动认为的采样率。
- 目标频率超过 Fs/2 时选择 Nyquist Zone 2，并使用负频率进行当前项目的第二奈奎斯特区符号补偿。
- DAC 使用 C2R fine mixer。
- ADC 使用 R2C fine mixer。
- mixer event 在外层统一触发，以保持双 DAC 相位同步。

## 8. Debug 时间线

### 阶段 1：ADC ILA 数据像乱码

最初设置 `DACF 600 / ADCF 500` 等回路测试时，ILA 数据直接观察不像正弦。曾怀疑：

- DAC 输入 `TVALID` 只有约 2.7%。
- FIR 或 DAC 输入数据格式错误。
- DAC 输出幅度太小，ADC 无法接收。
- ADC IQ 使用两个 ADC 后通道资源冲突。
- NCO 配置或符号错误。

### 阶段 2：修复连续 TVALID

`axis_broadcaster_128.v` 改为固定 IQ 并强制：

```verilog
assign m_axis_tvalid = 1'b1;
```

这消除了早期稀疏 TVALID 问题，但 ADC 仍未得到预期频率，因此 TVALID 不是最终根因。

曾出现过一次综合错误：

```text
[Synth 8-2329] missing compiler directive
```

原因与 Verilog 中错误的预处理符号/反引号有关，后续固定 IQ 代码已替代相关问题部分。

### 阶段 3：用 DDS 小工程证明硬件正常

新建 DDS-DAC-ADC 小工程后：

- DDS 10 MHz 可通过 DAC-ADC 被 ADC IQ 正确采集。
- ADC NCO 40/50/90 MHz 等组合能看到合理频移。
- DDS 60 MHz、DAC NCO 100 MHz 时示波器约 160 MHz。
- DDS、DAC NCO、ADC NCO 组合结果可以解释。

因此确认 RFSoC 硬件、DAC、ADC、NCO 和 ILA 基本工作正常，问题集中在旧主工程。

### 阶段 4：确认 ILA 数据打包方式

RFDC ADC 32-bit TDATA 不是一个 signed 32-bit ADC 样本，而是：

```text
TDATA[15:0]  = sample 0, signed 16-bit
TDATA[31:16] = sample 1, signed 16-bit
```

直接把 CSV 整列当 signed 32-bit 波形会看起来像乱码。`util/ila_data.py` 和 `ILA_DATA/analyze_0715_dacf2400_adcf2390_v2.py` 已按两个 16-bit 样本拆包。

### 阶段 5：ADC 软件 Block 与 GUI 通道映射混淆

旧工程使用 ADC Tile0 的 ADC00/ADC02，而目标频率后来提高到 2.4 GHz。为使用高频输入通道，PL 被切换到 ADC Tile1/GUI ADC10。

脚本：`util/switch_adc_to_tile225.tcl`

该脚本完成了：

- `ADC0_Enable=0`
- `ADC1_Enable=1`
- ADC1 采样率 2.94912 GSPS
- ADC10/11 配成 IQ/R2C
- ADC12/13 配成 real/R2R
- Decimation 8
- ILA slot0/1/2 改接 `m10_axis/m11_axis/m12_axis`
- 外部 ADC 时钟和模拟口从 `adc0/vin0_*` 切换为 `adc1/vin1_*`

### 阶段 6：BD 改了，但工程 wrapper 没同步

Vivado 生成的新 wrapper 位于：

```text
ZCU111_V9_adc.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v
```

但工程实际引用的是 imported wrapper：

```text
ZCU111_V9_adc.srcs/sources_1/imports/design_1_wrapper.v
```

一度生成 wrapper 已是 `adc1_clk/vin1_*`，而 imported wrapper 仍是 `adc0_clk/vin0_*`。后续已同步修正。当前两个 wrapper 均使用：

```text
adc1_clk_0
vin1_01_0
vin1_23_0
```

### 阶段 7：PS Tile ID 修改，但 standalone BSP 仍是旧的

`helloworld.c` 已改成 ADC Tile1，串口也能显示 ADC Tile1 startup OK。但第一次高频测试出现：

```text
[CLOCK] ADC T1 ... sample=2949 MHz
[BLOCK] ADC T1 B0 fs=2000 MHz
[System] Sample Rate of ADC Tile 1 is 2000000 kHz
```

这表明：

- 硬件时钟和 RFDC IP 实际运行在 2949.12 MHz。
- 应用中的 `RFdcInst` 仍由旧 BSP 初始化为 2.0 GSPS。

当时应用 BSP 中还包含：

```text
ADC1_ENABLE=0
ADC1_SAMPLING_RATE=2.0
ADC1_REFCLK_FREQ=2000
ADC_SLICE10_ENABLE=0
ADC_DATA_WIDTH10=8
ADC_DECIMATION_MODE10=0
```

因此 `ADCF 2390` 的调谐字按错误的 2.0 GSPS 归一化。第一次 CSV 的 ADC10 IQ 主峰约为 29.385 MHz，而不是 10 MHz。

对应文件：

```text
ILA_DATA/0715_DACF2400_ADCF2390.csv
```

该数据并非纯乱码，实际上 I/Q 相位差约 -90°、幅度匹配良好，只是 NCO 频率错误。

### 阶段 8：重新生成 Platform/BSP 后通过

执行正确的 XSA/Platform/BSP 更新和应用重编译后，串口变为：

```text
[CLOCK] ADC T1 pll_enable=0 ref=2949 MHz sample=2949 MHz
[BLOCK] ADC T1 B0 fs=2949 MHz ... fifo_alarm=0
[BLOCK] ADC T1 B1 fs=2949 MHz ... fifo_alarm=0
[System] Sample Rate of ADC Tile 1 is 2949120 kHz
```

当前以下三套 xparameters 均已确认一致：

```text
ws/ZCU111/export/ZCU111/sw/ZCU111/standalone_domain/bspinclude/include/xparameters.h
ws/ZCU111/psu_cortexa53_0/standalone_domain/bsp/psu_cortexa53_0/include/xparameters.h
ws/ZCU111/zynqmp_fsbl/zynqmp_fsbl_bsp/psu_cortexa53_0/include/xparameters.h
```

当前值均为：

```text
ADC1_ENABLE=1
ADC1_SAMPLING_RATE=2.94912
ADC1_REFCLK_FREQ=2949.120
ADC_SLICE10_ENABLE=1
ADC_DATA_WIDTH10=2
ADC_DECIMATION_MODE10=8
ADC_MIXER_TYPE10=2
```

### 阶段 9：第二组 ADC12/ADC13 切换为 IQ

2026-07-15 后续将 ADC Tile1 的第二个高速软件 Block 也切换为 R2C IQ：

```text
Block0: ADC10/ADC11 -> m10(I), m11(Q) -> ILA slot0/1
Block1: ADC12/ADC13 -> m12(I), m13(Q) -> ILA slot2/3
```

PS 已修改为 `ADCF` 同时调用 `ConfigNCO()` 配置软件 Block0/1，`ADCR` 同时回读两组 mixer。Vivado BD 验证和连接检查通过。

新 XSA 已从 `impl_1` 的当前完成 bitstream 导出，并重新生成 standalone/FSBL BSP。三处 BSP 当前均确认：

```text
ADC_MIXER_MODE10/11/12/13 = 0
ADC_MIXER_TYPE10/11/12/13 = 2
ADC_DATA_WIDTH10/11/12/13 = 2
ADC_DECIMATION_MODE10/11/12/13 = 8
```

`RFSOC.elf` 已在新 BSP 上 Clean Build 通过。尚缺双路射频线同时连接后的新 ILA CSV 验证。

## 9. 最终通过的串口测试

命令：

```text
DACF 2400
ADCF 2390
DACR
ADCR
STAT
```

关键回读：

```text
DAC T1 B0/B1 NCO ≈ 2399/2400 MHz
ADC T1 B0 NCO = -2390 MHz
DAC sample = 5898 MHz
ADC sample = 2949 MHz
ADC fifo_alarm = 0
```

ADC 读回负 NCO 是当前第二奈奎斯特区和符号补偿逻辑的结果，不代表配置失败。

## 10. 最终 ILA 验证结果

通过数据：

- CSV：`ILA_DATA/0715_DACF2400_ADCF2390_V2.csv`
- 专用分析脚本：`ILA_DATA/analyze_0715_dacf2400_adcf2390_v2.py`
- 数值报告：`ILA_DATA/0715_DACF2400_ADCF2390_V2_analysis.txt`

结果：

| 指标 | 结果 |
|---|---:|
| 判定 | PASS |
| ADC 输出样点率 | 368.64 MSPS |
| FFT bin | 22.5 kHz |
| ADC10 IQ 有效拍 | 8192/8192 |
| 当时 ADC12 R2R 有效拍 | 8192/8192 |
| 理论复数频率 | -10.000 MHz |
| 实测复数频率 | -9.990 MHz |
| 频率误差 | 10 kHz，小于 FFT bin |
| 主峰 | -34.22 dBFS |
| I/Q 幅度比 | 0.999922 |
| I/Q 幅度不平衡 | -0.0007 dB |
| Q 相对 I 相位 | -89.9987° |
| 正交相位误差 | 0.0013° |
| 镜像抑制 | 87.85 dB |
| 当时 ADC12 RMS | 21.04 LSB，接近噪声/带外残留 |

结论：

```text
DAC10 2400 MHz
  -> 物理高频回路
  -> ADC10 高速采样
  -> ADC NCO 2390 MHz
  -> Decimation 8
  -> ADC10 IQ 基带约 -10 MHz
```

该 V2 文件验证了 ADC10 IQ 链路。它采集于 ADC12 仍是 R2R 的历史版本，不能作为当前第二组 ADC12 IQ 的验证文件；当前双 IQ 配置需要重新采集四个 slot 的 CSV。

## 11. ILA 数据分析方法

通用脚本：

```text
util/ila_data.py
```

运行示例：

```powershell
E:\Xilinx\Vitis\2020.2\tps\win64\python-3.8.3\python.exe util\ila_data.py `
  --csv ILA_DATA\0715_DACF2400_ADCF2390_V2.csv `
  --expected-iq-frequency=-10e6 `
  --no-plot
```

专用 V2 脚本：

```powershell
E:\Xilinx\Vitis\2020.2\tps\win64\python-3.8.3\python.exe `
  ILA_DATA\analyze_0715_dacf2400_adcf2390_v2.py
```

Vitis 自带 Python 已有 NumPy，但没有 matplotlib。专用脚本在没有 matplotlib 时仍会输出 TXT 报告，只跳过 PNG。

分析时必须：

1. 丢弃 CSV 的 Radix 行。
2. 只采纳 `TVALID && TREADY` 的 beat。
3. 每个 32-bit word 拆成两个 signed 16-bit 样本。
4. slot0 + j*slot1 形成 ADC10 复数 IQ。
5. 使用 ADC 抽取后样点率 368.64 MSPS，而不是 ILA 时钟 184.32 MHz；因为每拍包含两个样本。

## 12. 强制重建顺序

修改 RFDC、BD、wrapper、HDL 或 ADC/DAC 参数后，必须按以下顺序：

### Vivado

1. 打开 `ZCU111_V9_adc.xpr`。
2. 如果改了自定义 HDL 端口，执行 Refresh Changed Modules。
3. 打开 `design_1.bd`，执行 Validate Design。
4. Generate Output Products。
5. 确认工程实际 wrapper 与生成 wrapper 端口一致。
6. Run Synthesis。
7. Run Implementation。
8. Generate Bitstream。
9. Export Hardware，必须包含 bitstream，更新 `design_1_wrapper.xsa`。

### Vitis

1. 使用最新 XSA 更新 Platform Hardware Specification。
2. 重新生成/更新 standalone domain BSP。
3. 检查 application domain 的 `xparameters.h`，不能只检查 FSBL BSP。双 IQ 当前要求 ADC12/13 的 `MIXER_MODE=0`、`MIXER_TYPE=2`。
4. Clean Platform。
5. Build Platform。
6. Clean `RFSOC` application。
7. Build `RFSOC.elf`。
8. 如使用 BOOT.BIN，重新生成 boot image，确保 bitstream、FSBL、ELF 都是同一版本。

仅重新生成 bitstream 不足以修复 RFDC 软件配置；仅重新编译 `helloworld.c` 也不足以修复旧 RFDC BSP。XSA、Platform、BSP、ELF 必须作为同一套版本更新。

## 13. 每次上板后的最小检查

上电后先执行：

```text
STAT
```

必须确认：

```text
DAC Tile1 enabled=1
ADC Tile1 enabled=1
DAC sample ≈ 5898 MHz
ADC sample ≈ 2949 MHz
ADC Block0 fs ≈ 2949 MHz
ADC Block1 fs ≈ 2949 MHz
data_clk=1
fifo_alarm=0
```

然后执行：

```text
DACF 2400
ADCF 2390
DACR
ADCR
STAT
```

期望 ADC10 IQ 频率约为 ±10 MHz。当前已验证版本是 `-9.990 MHz`。

## 14. 已确认不是最终根因的事项

### DAC 输出幅度小

旧版本示波器曾只看到 60～100 mV，而 DDS 小工程可达数伏。幅度差异与 DAC 数字输入幅度、C2R mixer scale、QMC、模拟输出电流、变压器和示波器端接有关。

最终 V2 在约 -34.22 dBFS 主峰下仍得到极高质量 IQ，因此“输入功率太小导致 ADC 完全无法识别”不是最终根因。

### TVALID

早期 TVALID 稀疏确实不合理，但固定 IQ + `TVALID=1` 后仍存在错误频率。最终 V2 的 8192/8192 beat 全部有效，说明当前 AXIS 握手正常。

### NCO 硬件

DDS 小工程和最终 V2 都证明 DAC/ADC NCO 正常。错误来自驱动用错采样率，不是 NCO 电路失效。

### ADC IQ 的 Q 为直流

在某些 DDS、ADC NCO=0 或输入为实数的测试中，I 为正弦、Q 接近 0/直流可以是合理结果，不能单独据此判断 IQ 配置错误。

### PMU-FW warning

串口出现：

```text
PMU-FW is not running, certain applications may not be supported.
```

当前 RFDC 回路验证仍然正常，该提示不是本次 NCO/ILA 问题的根因。

## 15. 关键文件索引

| 文件 | 作用 |
|---|---|
| `ZCU111_V9_adc.xpr` | Vivado 工程入口 |
| `ZCU111_V9_adc.srcs/sources_1/bd/design_1/design_1.bd` | 当前 Block Design |
| `ZCU111_V9_adc.srcs/sources_1/imports/design_1_wrapper.v` | 工程实际引用的 imported wrapper |
| `ZCU111_V9_adc.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v` | Vivado 生成 wrapper，用于对照 |
| `ZCU111_V9_adc.srcs/sources_1/new/axis_broadcaster_128.v` | 当前固定 DAC IQ 和强制 TVALID |
| `ZCU111_V9_adc.srcs/sources_1/new/dpsk_stream_tx.v` | DPSK 数据流模块 |
| `ws/RFSOC/src/helloworld.c` | PS 串口控制、时钟、RFDC NCO/QMC/status |
| `util/switch_adc_to_tile225.tcl` | 将接收端切换到 ADC Tile1/ADC10 的 Vivado 脚本 |
| `util/LOOPBACK_TEST.md` | 高频回路测试步骤 |
| `util/ila_data.py` | 通用 ILA CSV 分析 |
| `ILA_DATA/analyze_0715_dacf2400_adcf2390_v2.py` | 最终 V2 专用分析脚本 |
| `ILA_DATA/0715_DACF2400_ADCF2390_V2_analysis.txt` | 最终 PASS 数值报告 |
| `util/build_highband_bitstream.tcl` | 自动 build/export 尝试脚本；此前未作为最终成功构建依据 |
| `design_1_wrapper.xsa` | 当前硬件平台描述 |

## 16. 当前未完成/后续任务

1. 当前 bitstream 已包含 `I=32767` 固定输入；仍需下载该版本并用示波器确认实际最大输出幅度。
2. 若继续优化最大 DAC 功率，检查/设置 DAC `FineMixerScale=1.0`，并观察是否削顶或产生杂散。
3. 当前固定 IQ 绕开 DPSK/FIR 数据；若后续恢复通信链路，需要把 `axis_broadcaster_128.v` 切回 `{final_q, final_i}` 和合适的 TVALID/握手机制。
4. ADC12/ADC13 已切换为 IQ/R2C，ILA slot2/3 已接通，但尚未用新 CSV 验证第二路频率、幅度、相位和镜像抑制。
5. 工程工作树已有大量历史修改和生成文件，不能使用 `git reset --hard` 或批量覆盖。修改前先检查 `git status`，保留用户现有改动。

## 17. 后续 GPT 的工作规则建议

开始新任务时：

1. 先读本文档。
2. 再读 `util/LOOPBACK_TEST.md` 和与任务直接相关的源码。
3. 不要再假设当前 ADC 是 Tile0/ADC00。
4. 不要把 32-bit ILA TDATA 当成一个 ADC 样本。
5. 看到串口时同时比较 `[CLOCK] sample`、`[BLOCK] fs` 和 `ConfigNCO` 打印的采样率；三者不一致时优先检查 XSA/BSP。
6. RFDC/BD 修改后必须同步 XSA、Platform、BSP、ELF。
7. 当前最终可信基准是 V2 测试的 `-9.990 MHz` 和 87.85 dB 镜像抑制结果。
