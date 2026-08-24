

# ZCU111 RFSoC DBPSK & MP-DPD Laboratory

本项目是一个基于 Xilinx/AMD Zynq UltraScale+ RFSoC (ZCU111 V20) 的软硬协同通信与数字预失真 (DPD) 实验平台。系统集成了 DBPSK 基带收发链路、基于 AXI-Stream 的高速硬件数据通路，以及基于间接学习架构 (ILA) 的记忆多项式 (MP-DPD) 自适应数字预失真算法。

## 🎯 最近更新 (Current Progress)

* **打通无 PA 纯软件仿真闭环 (No-PA Simulation Loop)**：在缺少真实功率放大器硬件的情况下，通过 Python 脚本建立了包含非线性压缩和记忆效应的 PA 数学模型，生成了 4096 深度的仿真测试数据 (`pa_sim_data.h`)。
* **DPD 核心算法 C 语言实现**：在 ARM PS 端实现了基于 64-bit 双精度复数的最小二乘法 (LS) 求解器 (`dpd_algorithm.c`)，可稳定提取 M=2, K=1,3,5 阶的 6 个复数预失真系数。
* **动态 LUT 映射与无缝切换**：实现了将宏观数学系数向 4096 深度微观查找表 (LUT) 的映射与定点化 (Q2.14)。支持双 Bank（乒乓）缓存操作，实现了在不中断数据流情况下的 DPD 系数原子级切换。

---

## 🏗️ 系统架构 (System Architecture)

项目分为 **PL（可编程逻辑）** 和 **PS（处理系统）** 两大部分：

### PL 端 (Hardware Data Path)

* **`axis_broadcaster_128`**：处理基带数据，执行 1 转 4 并行化，并包含 18 倍增益补偿及关键的饱和截断逻辑，防止波形反相撕裂。
* **`axis_dpd_lab_controller`**：实验室数据枢纽，拥有独立的 256KB AXI-Lite 空间。提供 4096 深度的波形注入 (Playback) 与高速 ADC 反馈抓取 (Capture) 功能，是连接软硬件的数据桥梁。
* **`dpd_mp_4lane_core`**：4 通道并行 MP-DPD 硬件执行引擎。基于输入的复数功率 ($I^2+Q^2$) 寻址，执行流水线查表计算，并将校正后的数据双发至 RFDC DAC。

### PS 端 (Software Control & Algorithm)

* 运行于裸机/FreeRTOS 环境，负责 LMK/LMX 时钟芯片和 RFDC 射频瓦片的初始化。
* 通过 AXI-Stream FIFO 调度 DBPSK 报文收发，处理 CRC16 校验。
* 提供 UART 命令行接口，管理 DPD 的状态监控、硬件 LUT 烧写以及算法触发。

---

## 💻 核心工作流与命令指南 (CLI Guide)

系统启动后，可通过串口终端进行交互控制。目前支持一套完整的自闭环测试流程：

### 命令级数据流 (Command Data Flow)

本文中的“16 位数据”指一个有符号 I 或 Q 分量。一个复数样点由 `I[15:0]` 和 `Q[15:0]` 组成，在 AXI-Lite 存储器和 BRAM 中打包为 32 位 `{Q[15:0], I[15:0]}`。LAB 高速输出每拍并行传输 4 个复数样点，因此 AXI-Stream `TDATA` 总宽度为 128 位。

| 执行命令 | 16 位数据从哪里发送到哪里 | 数据格式与作用 |
| --- | --- | --- |
| `SIML` | PS DDR/ROM 中 `pa_sim_data.h` 的 `tx_ref_i/q[]` → PS AXI-Lite 主口 → LAB `WAVEFORM RAM` (`0xA00C0000 + 0x10000`) → LAB 循环回放器 → MP-DPD 输入 → RFDC DAC10/DAC11 | I/Q 各 16 位，写 RAM 时打包为 `{Q,I}` 32 位。命令同时设置回放长度为 4096 并启用循环回放。DPD 是处理还是旁路由 `DPDE` 决定。 |
| `CALIB` | PS DDR/ROM 中 `rx_distorted_i/q[]` 作为 LS 输入，`tx_ref_i/q[]` 作为 LS 期望输出 → PS `dpd_algorithm` 双精度复数求解器 → 6 个复数系数 → 4096 点 LUT 展开器 → PS AXI-Lite 主口 → MP-DPD 非激活 Bank | 原始 TX/RX 数据的 I/Q 各为 16 位。LUT 增益量化后的实部/虚部各为 16 位 Q2.14，打包为 `{gain_q,gain_i}` 32 位写入。当前命令使用静态仿真 RX 数据，不从 LAB Capture RAM 读取实时 ADC 数据。 |
| `DPDE 1` | LAB/DBPSK 的 I/Q 各 16 位样点 → MP-DPD 当前激活 LUT Bank → 复数乘加和饱和截断 → RFDC DAC10/DAC11 | 启用硬件 DPD；输出仍为 I/Q 各 16 位。`DPDE 0` 时数据经延迟匹配旁路送往 DAC。 |
| `DPDW b t start ...` | UART 中的 LUT 十六进制字 → PS 命令解析器 → PS AXI-Lite 主口 → MP-DPD 指定 Bank/Tap/LUT 地址 | 每个 32 位字为 `{gain_q[15:0],gain_i[15:0]}`。数据应先完整写入非激活 Bank，再执行 `DPDC`。 |
| `DPDC` | PS 控制位 → MP-DPD Bank commit 跨时钟脉冲 → PL 激活 Bank 翻转 | 不传输样点数据，只原子切换之后的 16 位复增益查表来源。 |
| `LABW start ...` | UART 中的波形十六进制字 → PS 命令解析器 → PS AXI-Lite 主口 → LAB `WAVEFORM RAM` | 每个 32 位字包含 I/Q 各 16 位。执行 `LABP 1` 后，波形才从 RAM 发送到 MP-DPD/DAC 数据链。 |
| `LABC count` | LAB 的 DPD 前 TX 参考 I/Q 各 16 位，以及 RFDC ADC 反馈 I/Q 各 16 位 → LAB Capture RAM (`0xA00C0000 + 0x20000`) | 每个采集样点保存两个 32 位字：TX `{Q,I}` 和 ADC 反馈 `{Q,I}`。 |
| `LABR start count` | LAB Capture RAM 中的 TX/ADC I/Q 各 16 位数据 → PS AXI-Lite 读取 → UART 终端 | 以 `LABD index tx_hex feedback_hex` 输出，便于 PC 端保存、对齐和辨识 PA 模型。 |

`SIML` 与 `CALIB` 的建议执行顺序及主数据流为：

```text
SIML
  tx_ref_i/q (PS，I/Q 各 16 bit)
      -> AXI-Lite -> LAB Waveform RAM
      -> 4 复样点/拍 AXI-Stream
      -> MP-DPD（当前由 DPDE 选择旁路或处理）
      -> RFDC DAC10/DAC11

CALIB
  rx_distorted_i/q + tx_ref_i/q (PS，I/Q 各 16 bit)
      -> ILA/LS 求解 6 个复数系数
      -> 4 x 4096 LUT（本模型使用 tap 0/1，tap 2/3 写零）
      -> Q2.14 {gain_q[15:0], gain_i[15:0]}
      -> AXI-Lite -> MP-DPD 非激活 Bank
      -> commit 切换激活 Bank

DPDE 1
  LAB/DBPSK I/Q 各 16 bit -> MP-DPD 新 LUT -> I/Q 各 16 bit -> RFDC DAC10/DAC11
```

### 1. 注入测试波形 (Waveform Injection)

在无 PA 模式下，将硬编码的理想基带参考信号直接注入发射 BRAM：

* `SIML` : 将 `pa_sim_data.h` 中的仿真发送数据载入 LAB 模块，并自动配置为回放模式 (等效于自动执行 `LABP 1` 和 `LABL 4096`)。

### 2. DPD 校准与系数更新 (Calibration & Update)

* `CALIB` : 触发 PS 端的 LS 算法。当前实现直接使用 `pa_sim_data.h` 中的 4096 点静态 TX/RX 仿真数据，计算出 6 个 MP-DPD 复数系数；它尚未从 LAB Capture RAM 读取实时 ADC 反馈。随后，系统会自动将这些系数展开为 Q2.14 格式的查找表，写入非激活的 BRAM Bank，并发出 Bank commit 切换请求。

### 3. 状态监控 (Status Monitoring)

* `DPDS` : 打印 DPD 硬件核心的版本号、使能状态、当前活跃的 Bank (0 或是 1)，以及极为重要的 **Clip Count (饱和裁切计数)**。如果 `CALIB` 后 Clip Count 保持为 0，说明 LUT 映射成功且未发生溢出。
* `LABS` : 打印 LAB 模块当前的回放/捕获状态及缓冲区深度。
* `STAT` : 查看底层 RFDC 的时钟、PLL 锁定状态及各混频器 (Mixer) 的工作频率。

### 其他实用命令

* `DPDE <0|1>` : 禁用或使能硬件 MP-DPD 处理。
* `DPDX` : 清零 DPD 饱和裁切计数器。
* `DACF <MHz>` / `ADCF <MHz>` : 动态调整 DAC 或 ADC 的 NCO 本振频率。

---

## 🚀 下一步计划 (Future Work)

1. **接入真实 RF 硬件**：外接实际的微波功率放大器 (PA) 和射频衰减器。
2. **切换数据源**：将 `CALIB` 算法的数据源从静态头文件 (`pa_sim_data.h`) 切换为从 AXI-Lite 总线 (`LAB_CAPTURE_OFFSET` 0x20000) 实时抓取的 RFDC ADC 真实反馈数据。
3. **闭环连续自适应**：实现定时器驱动的自动后台轮询，持续抓取数据、计算系数并动态更新 LUT，抵抗 PA 的温漂和老化效应。
