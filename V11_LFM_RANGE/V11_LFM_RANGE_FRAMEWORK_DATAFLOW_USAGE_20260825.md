# ZCU111 V11 LFM 测距工程：框架、数据流程与使用说明

## 1. 文档目的

本文总结截至 2026-08-25 的 V11 LFM 测距工程，包括：

- 当前硬件、PL、PS 和软件框架；
- 发射、采集、相关、背景扣除、CFAR 和结果输出的数据流程；
- 本次新增的 `II=1` 相关流水原型与 CA-CFAR 多目标检测；
- 工程构建、仿真、上板和串口使用方法；
- 当前验证状态、限制和后续注意事项。

本文是使用说明和设计上下文，不替代射频安全规范、ZCU111 用户手册或 Vivado/Vitis 工程约束。

## 2. 当前版本概览

V11 是基于 ZCU111 RFSoC 的 2.4 GHz 短距 LFM 相对延迟测距工程。系统使用一个 ADC 通道接收回波，另一个 ADC 通道接收 PA 输出耦合参考，通过相对复相关抵消发射时刻、NCO 相位和大部分公共时钟抖动。

默认参数如下：

| 参数 | 当前值 |
|---|---:|
| 射频中心频率 | 2400 MHz |
| LFM 带宽 | 400 MHz |
| DAC 采样率 | 5898.24 MSPS |
| ADC 采样率 | 2949.12 MSPS |
| ADC 复数输出率 | 737.28 MSPS |
| PL 时钟 | 184.32 MHz |
| 每个 128 bit beat | 4 个复数样点 |
| LFM 脉冲长度 | 4096 个复数样点，约 5.556 us |
| 捕获长度 | 8192 个复数样点，约 11.111 us |
| PRF | 10 kHz |
| 搜索 lag 数 | 128 |
| 理论距离分辨率 | `c/(2B) ≈ 0.375 m` |
| 距离采样间隔 | 约 203.31 mm |
| 最大 CFAR 输出目标数 | 1 |

## 3. 本次更新内容

### 3.1 单 lane `II=1` 相关流水

原有六级结构已经解决了 BRAM 推断和关键路径问题，但 `READ/MULT/ACCUM` 仍通过互斥 FSM 每个样点占用 3 拍。本次改为单 lane valid/address 流水：

```text
地址发起：每拍发送一个样点地址
BRAM 读取：同步读延迟
复数乘法：注册乘积
累加退休：流水填充后每拍退休一个复乘结果
```

新增的主要内部控制寄存器为：

- `corr_read_valid`：BRAM 读取请求有效；
- `corr_product_valid`：复数乘积流水有效；
- `corr_accum_count`：当前 lag 的已退休样点计数。

该实现是单 lane `II=1` 原型，不是 4-lane 并行，也没有达到 10 kHz 每脉冲实时处理。`DIFF/MAG/UPDATE` 和 128 个 lag 之间的串行调度仍然存在。

### 3.2 一维单目标 CA-CFAR

相关器不再保存全部 128 个 lag 的幅度分数，而是用固定 7 点滑动窗口流式评估：

```text
每个 lag 的幅度
    -> 7 点滑动窗口
    -> 左右训练单元求和
    -> 自适应门限
    -> 局部峰值判定
    -> 保留最强单个候选
```

默认参数：

- 每侧 2 个训练单元；
- 1 个保护单元；
- 门限约为训练单元均值的 2 倍；
- 仍保留软件 `THRE` 作为最低绝对分数门限；
- 只输出 1 个最强有效目标；
- 背景校准结果包的目标数为 0。

CFAR 当前是资源可控的串行原型：每个窗口中心使用两侧各 2 个训练单元和
1 个保护单元，门限约为训练单元均值的 2 倍，并附加固定绝对底限。没有候选
时回退到相关最大峰。它不改变 400 MHz 带宽决定的物理距离分辨率。

### 3.3 结果包和软件更新

PL 到 PS 的测距结果保持固定 6 words：

| Word | 内容 |
|---:|---|
| 0 | `RESULT_MAGIC = 0x524e4731` |
| 1 | `{sequence, peak_lag}` |
| 2 | 峰值分数（Q16 缩放） |
| 3 | 峰值左邻点分数（Q16 缩放） |
| 4 | 峰值右邻点分数（Q16 缩放） |
| 5 | 状态标志，`TLAST=1` |

A53 软件会：

- 检查结果 magic；
- 用单目标峰值和左右邻点执行 `RCAL` 和三点抛物线插值；
- 按 `THRE` 过滤并打印当前目标；
- 继续支持原有 `BGCAL`、`RCAL`、`CALCLR`、`THRE` 和 `PRINT` 命令。

## 4. 工程目录和模块职责

```text
V11_LFM_RANGE/
├─ V11_LFM_RANGE.xpr
├─ V11_LFM_RANGE.srcs/             Vivado BD、XCI、XDC 等工程源文件
├─ rtl/lfm_radar_core.v            发射、采集、相关、CFAR、结果打包
├─ mem/lfm_400mhz_4096.mem         400 MHz LFM 波形 ROM
├─ mem/lfm_sim_64.mem              仿真用短 ROM
├─ sim/tb_lfm_radar_core.sv        背景校准和单目标 RTL 自检
├─ scripts/                        BD、仿真、综合、硬件和 Vitis 脚本
├─ sw/src/                         A53 裸机程序和 RFDC/FIFO 控制
├─ README.md                       项目快速说明
├─ V11_LFM_RANGE_CONTEXT.md        接口、参数和设计上下文
├─ LFM_BRAM_PIPELINE_OPTIMIZATION_ANALYSIS.md
│                                  BRAM、流水、吞吐和优化记录
└─ artifacts/                      发布用 bitstream/XSA（Git 版本中）
```

### 4.1 Block Design 主要模块

| 模块 | 作用 |
|---|---|
| `zynq_ultra_ps_e_0` | A53 裸机运行平台、AXI-Lite 和 UART |
| `usp_rf_data_converter_0` | DAC 产生 LFM，ADC 接收回波和发射参考 |
| `lfm_radar_core_0` | PL 定时、采集、复相关、背景扣除、CFAR 和结果输出 |
| `axi_fifo_mm_s_0` | PS/PL 双向控制和结果 FIFO |
| `axis_data_fifo_0` | 控制 packet 的时钟域缓冲 |
| `axis_data_fifo_rx` | 测距结果从 PL 域跨到 PS/AXI 域 |
| `system_ila_1` | 观察 ADC、DAC、控制和结果信号 |
| `jtag_axi_0` | 无软件时调试 AXI 寄存器 |
| `vio_0` | 在线少量控制和状态调试 |

## 5. 端到端数据处理流程

### 5.1 发射链

```text
LFM ROM
  -> 10 kHz PRF 定时
  -> DAC10/DAC11 128 bit beat
  -> RFDC DAC Tile1 Block0/1
  -> 2.4 GHz 模拟发射链路
```

DAC10 是主发射输出，DAC11 是同步调试输出，可不连接。

### 5.2 射频和 ADC 输入

```text
PA 输出
  -> 定向耦合器耦合端 -> 衰减/限幅 -> ADC12 I/Q（参考）
  -> 环行器/天线/目标
  -> 环行器接收端 -> 滤波/衰减/限幅 -> ADC10 I/Q（回波）
```

第一次上电必须从低功率开始，确认 ADC 输入不超限。PA 主路、环行器发射端和耦合器主路不得直接连接 ADC。

### 5.3 PL 处理链

```text
ADC10 回波 + ADC12 参考
        -> 8192 点采集 BRAM
        -> 每个 lag 的同步 BRAM 读取
        -> echo × conj(reference)
        -> II=1 单 lane 复数乘法/累加流水
        -> 背景复相关扣除
        -> abs(real) + abs(imag)
        -> 7 点滑动 CA-CFAR + 局部峰
        -> 保留一个最强目标
        -> 6-word AXI 结果 packet
```

背景校准时，PL 保存每个 lag 的静态复相关值；正常测量时从当前复相关中扣除该背景。结果目标 0 的左右分数继续用于 PS 亚采样插值。

### 5.4 PS 和串口流程

```text
AXI FIFO RX
  -> A53 PollRangeFifo()
  -> 检查 magic/version/flags
  -> 第一目标 RCAL/抛物线插值
  -> THRE 过滤
  -> UART 输出最近目标和其它目标
```

## 6. 构建和仿真

工程默认使用 Vivado/Vitis 2020.2。

### 6.1 生成 ROM

```powershell
python V11_LFM_RANGE/scripts/gen_lfm_rom.py `
  V11_LFM_RANGE/mem/lfm_400mhz_4096.mem
```

### 6.2 RTL 仿真

推荐先使用项目脚本：

```powershell
E:/Xilinx/Vivado/2020.2/bin/vivado.bat -mode batch `
  -source V11_LFM_RANGE/scripts/run_rtl_sim.tcl -nolog -nojournal
```

如果 Vivado batch 因本机 `librdi_coretasks` 或缓存问题异常退出，可以在 `sim` 目录使用独立仿真库，避免旧 `xsim.dir` 快照污染：

```powershell
cd V11_LFM_RANGE/sim
E:/Xilinx/Vivado/2020.2/bin/xvlog.bat -sv `
  -work final_cfar_lib=final_cfar_lib `
  ../rtl/lfm_radar_core.v tb_lfm_radar_core.sv
E:/Xilinx/Vivado/2020.2/bin/xelab.bat -L final_cfar_lib `
  final_cfar_lib.tb_lfm_radar_core -snapshot tb_cfar_final_sim
E:/Xilinx/Vivado/2020.2/bin/xsim.bat tb_cfar_final_sim -runall
```

通过时应看到类似：

```text
PASS: calibrated background and detected target lags 7 and 11
```

### 6.3 硬件构建

```powershell
E:/Xilinx/Vivado/2020.2/bin/vivado.bat -mode batch `
  -source V11_LFM_RANGE/scripts/build_v11_hardware.tcl
```

该步骤生成无 ILA 发布版 bitstream/XSA。当前已完成一次完整综合、实现、布线
和 bitstream 生成，结果为：setup WNS `+1.150 ns`、hold WHS `+0.011 ns`，
无失败端点。产物位于 `V11_LFM_RANGE.runs/impl_1/design_1_wrapper.bit` 和
`sw/design_1_wrapper.xsa`；构建脚本同时将 XSA 同步到 Git 跟踪的
`design_1_wrapper.xsa`。

### 6.4 软件编译检查

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File V11_LFM_RANGE/scripts/compile_check_sw.ps1
```

也可以使用 Vitis/XSCT 创建 workspace：

```powershell
E:/Xilinx/Vitis/2020.2/bin/xsct.bat `
  V11_LFM_RANGE/scripts/create_v11_vitis_workspace.tcl
```

## 7. 上板使用步骤

### 7.1 同轴线验证

建议连接：

```text
DAC10 -> 功分器
  ├─ 衰减器 -> ADC12 参考
  └─ 已知长度同轴线 -> 衰减器 -> ADC10 回波
```

操作顺序：

1. 下载与当前硬件构建对应的 bitstream/XSA；
2. 启动 A53 裸机程序并打开 UART；
3. 短线或无目标状态下发送 `BGCAL`；
4. 放入已知长度延迟线；
5. 发送 `RCAL <等效毫米>`；
6. 发送 `START`；
7. 改变同轴长度，检查 lag 和距离是否单调变化。

同轴物理长度需要乘以速度因子 `VF`，并注意雷达距离公式中的往返关系。不要直接把线缆物理长度当作自由空间距离。

### 7.2 低功率自由空间验证

推荐使用 3–5 m 和大金属板/角反射器作为第一组测试。确认 ADC10/ADC12 不饱和、峰值不长期固定在 lag 0 后，再逐步扩大到 0.5–20 m。

每次改变 PA 增益、衰减器、线缆、耦合器或天线连接，都应重新执行：

```text
BGCAL
```

改变参考通道路径长度后还应重新执行 `RCAL`。

### 7.3 串口命令

| 命令 | 用法 |
|---|---|
| `BGCAL` | 下一帧采集无目标静态背景 |
| `START` | 启动 LFM 发射和测距 |
| `STOP` | 停止发射 |
| `RCAL <mm>` | 用下一次有效第一目标设置距离偏置 |
| `CALCLR` | 清除距离偏置 |
| `THRE <score>` | 设置软件输出最低分数 |
| `PRINT <N>` | 每 N 个有效结果打印一次 |
| `DACF <MHz>` | 设置 DAC NCO |
| `ADCF <MHz>` | 设置 ADC NCO |
| `DACR` / `ADCR` | 查看 NCO 配置 |
| `STAT` | 查看 RFDC、时钟和测距状态 |
| `HELP` | 显示命令帮助 |

典型命令序列：

```text
BGCAL
RCAL 3000
START
PRINT 1
```

其中 `RCAL 3000` 表示把下一次有效目标作为 3000 mm 标准距离，并使用峰值左右邻点做亚样点插值。

## 8. 验证结果和当前限制

已完成或确认：

- BRAM 存储模板和六级寄存边界；
- 单 lane `II=1` RTL 原型；
- 单目标 CA-CFAR RTL 仿真，检测 `lag 7`；
- A53 软件 `-Wall -Wextra -Werror` 编译检查；
- 原有同轴线闭环验证：lag 随线缆长度变化，并符合约 0.70 速度因子；
- 已有 bitstream/XSA 归档到 `artifacts/`。

当前限制：

1. `II=1` 只针对单 lane 相关内循环，尚未实现 4-lane MAC、多个 lag engine 或 ping-pong 采集缓存。
2. 相关器仍不是 10 kHz 每脉冲实时输出，当前系统级结果率仍受完整 lag 扫描和空闲调度限制。
3. CFAR 是一维距离 CFAR，不包含角度、速度、Doppler 或目标跟踪。
4. `THRE` 主要由软件用于结果显示过滤；PL CFAR 还有固定的绝对门限和自适应门限。
5. 静态背景扣除不能完全抑制 PA 相位噪声、温漂、多径和动态泄漏。
6. 0.5 m 近距端主要受环行器隔离、天线振铃、近场耦合和 ADC 饱和影响。
7. Git 中归档的 bit/XSA 尚未包含本次 RTL 修改；要在硬件上使用新功能，必须重新运行硬件构建并下载新工件。

## 9. 后续建议

建议按以下顺序继续：

1. 对 II=1 版本做综合和时序检查；
2. 利用 128 bit BRAM 实现 4-lane MAC；
3. 增加 ping-pong 采集缓存，实现采集和计算重叠；
4. 按目标结果率增加 lag engine；
5. 如果需要严格 10 kHz 每脉冲处理，比较时域多核和 FFT 脉压；
6. 后续再考虑多通道相干采集、距离-角度图、速度估计和通信波束对准。

---

文档结尾日期：20260825
