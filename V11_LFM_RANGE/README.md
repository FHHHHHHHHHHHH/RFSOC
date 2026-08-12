# ZCU111 V11_LFM_RANGE

V11 是在已验证的 V10 RFDC、时钟和 PS 控制基础上建立的独立短距 LFM 测距工程。它不会修改 `V10_DPSK`，目标是先完成“同轴线 + 功分器/衰减器”的延迟测量，再接入 PA、耦合器、环行器和天线进行 0.5–20 m 单目标自由空间测试。

核心实现参考《机载分布式雷达数据采集系统实现》中“PL 定时—波形 ROM—ADC 采集—脉冲压缩”的结构，但没有照搬论文中的收发开关和半双工时序。论文方案存在约 1.5 km 近距盲区，不适合本项目；V11 改为发射和接收同时进行，并用 ADC12 的发射参考消除固定通道延迟和静态泄漏。

## 默认配置

| 项目 | 默认值 |
|---|---:|
| 射频中心频率 | 2400 MHz |
| LFM 扫频带宽 | 400 MHz |
| DAC 采样率 | 5898.24 MSPS |
| DAC 插值 | 8 |
| ADC 采样率 | 2949.12 MSPS |
| ADC 抽取 | 4 |
| ADC 复数输出率 | 737.28 MSPS |
| PL 时钟 | 184.32 MHz |
| 每个 PL beat 的复样点数 | 4 |
| 单脉冲长度 | 4096 点，约 5.556 us |
| PRF | 10 kHz |
| 捕获窗口 | 8192 点，约 11.111 us |
| 搜索范围 | 128 个相对延迟点，约 0–26.0 m |
| 理论距离分辨率 | `c/(2B) = 0.375 m` |
| 距离采样间隔 | 约 203.31 mm |
| 串口默认输出速率 | 每 9 个结果输出 1 次 |

相关处理当前采用单标量复相关引擎。一次 128-lag 搜索约需 5.6 ms，因此有效内部测距更新率约 178 Hz；串口默认降采样后约 20 Hz，与运动单目标显示需求匹配。三点抛物线插值可以改善峰值位置读数，但不能突破 400 MHz 带宽决定的双目标分辨能力。

## 信号链

```text
LFM ROM/timing
      |-----------------------> DAC10 -> 被测发射链路
      `-----------------------> DAC11 -> 同步调试输出，可不接

PA 后耦合参考 -----------------> ADC12 I/Q (RFDC m12/m13)
环行器接收/同轴延迟通道 --------> ADC10 I/Q (RFDC m10/m11)

ADC10 × conj(ADC12)
      -> 每个 lag 的复相关
      -> 无目标背景复相关扣除
      -> 最大峰 + 左右邻点
      -> PS 抛物线插值、通道零点校准
      -> UART 最近目标距离
```

这种相对 ADC12 参考通道测距方式会自动抵消 DAC 发射时刻、NCO 相位、PA 和大部分公共时钟抖动；仍需用 `RCAL` 消除功分器、耦合器、线缆和 ADC 模拟通道之间的固定差分延迟。

## 三项射频器件默认假设

在用户选择“使用默认值”后，本工程文档采用以下起始假设。它们是选型和实验配置基线，不是对现有实物的测量值：

1. 环行器：2.2–2.6 GHz，插损不大于 1 dB，隔离度不小于 20 dB。
2. 天线：覆盖 2.2–2.6 GHz，约 8 dBi 增益，驻波比不大于 2，单天线经环行器收发。
3. PA 参考耦合：PA 输出端使用约 20 dB 定向耦合器，方向性不小于 20 dB；ADC12 前继续串联固定衰减器，使任何时刻的 RFSoC ADC 输入均处于板卡手册允许范围内。

PA 输出为 30 dBm。严禁把 PA 输出、耦合器主路或环行器发射端直接连接到 ADC。ADC10 接收链也应加入限幅器、可调整衰减和必要的带通滤波；首次上电必须从信号源/PA 的最低功率开始，用功率计或频谱仪确认电平后逐级提高。

## 推荐验证顺序

### 1. 同轴延迟验证

建议先不接 PA：

```text
DAC10 -> 功分器
  路1 -> 衰减器 -> ADC12（参考）
  路2 -> 已知长度同轴线 -> 衰减器 -> ADC10（测量）
```

两路衰减必须保证 ADC 安全，且尽量让 ADC10/ADC12 的幅度处在相近数量级。先用短线作为零点，执行 `BGCAL`；插入已知延迟线后执行 `RCAL <已知毫米>`。改变同轴线长度，检查串口距离变化是否与电长度一致。注意同轴中的传播速度约为 `VF × c`，如果要把同轴物理长度换算为“等效自由空间单程距离”，必须使用线缆速度因子，并考虑雷达距离公式中的往返系数。

### 2. 低功率自由空间验证

```text
DAC10 -> PA（最低功率）-> 定向耦合器 -> 环行器 -> 天线
                         |耦合端
                         `-> 衰减/限幅 -> ADC12
环行器 RX -> 限幅/衰减/滤波 -> ADC10
```

移除目标后执行 `BGCAL`，再放置大金属板或角反射器。推荐先从 3–5 m 开始，因为 0.5 m 处的目标回波只有约 3.34 ns 往返延迟，容易与环行器泄漏、天线振铃及近场耦合重叠。稳定后再逐步测试 0.5–20 m。

### 3. 30 dBm 测试

只有在低功率状态下确认 ADC10、ADC12 峰值均有足够余量后才提高 PA 功率。每次改变 PA 增益、衰减器、线缆、耦合器或天线连接，都要重新执行 `BGCAL`；改变参考通道路径长度后还要重新执行 `RCAL`。

## 串口命令

| 命令 | 功能 |
|---|---|
| `BGCAL` | 请求下一帧作为无目标静态泄漏/背景复相关；若尚未启动会自动启动 |
| `START` | 启动 LFM 脉冲发射和测距 |
| `STOP` | 停止脉冲发射 |
| `RCAL <mm>` | 把下一个有效峰标定为给定距离，计算固定距离偏置 |
| `CALCLR` | 清除距离偏置 |
| `THRE <score>` | 设置最小峰值门限，默认 1000 |
| `PRINT <N>` | 每 N 个有效结果打印一次，默认 9 |
| `DACF <MHz>` | 设置 DAC10/DAC11 NCO |
| `ADCF <MHz>` | 设置 ADC10/ADC12 NCO |
| `DACR` / `ADCR` | 查看混频器配置 |
| `STAT` | 查看 RFDC、时钟和测距状态 |
| `HELP` | 显示帮助 |

典型操作：

```text
BGCAL
# 等待 [BGCAL] complete，背景采集期间不要放目标
RCAL 3000
# 在 3 m 标准位置放置目标，等待 [RCAL] complete
START
```

串口输出示例：

```text
[RANGE] 3.012 m  (3012 mm) peak=184520 lag=15 seq=38
```

如果没有输出，先执行 `STAT`，再临时用 `THRE 0` 判断是否只是门限过高。若峰值总在 lag 0 或搜索边界，优先检查参考/回波接反、固定延迟未校准、泄漏过强或搜索窗不足。

## 工程构建

环境为 Vivado/Vitis 2020.2。

重新生成 LFM ROM：

```powershell
python V11_LFM_RANGE/scripts/gen_lfm_rom.py `
  V11_LFM_RANGE/mem/lfm_400mhz_4096.mem
```

从 V10 已验证 BD 基线重新创建独立 V11 工程并校验 BD：

```powershell
E:/Xilinx/Vivado/2020.2/bin/vivado.bat -mode batch `
  -source V11_LFM_RANGE/scripts/update_v11_lfm_bd.tcl
```

运行 RTL 行为仿真：

```powershell
E:/Xilinx/Vivado/2020.2/bin/vivado.bat -mode batch `
  -source V11_LFM_RANGE/scripts/run_rtl_sim.tcl -nolog -nojournal
```

生成 bitstream 和含 bit 的 XSA：

```powershell
E:/Xilinx/Vivado/2020.2/bin/vivado.bat -mode batch `
  -source V11_LFM_RANGE/scripts/build_v11_hardware.tcl
```

创建 Vitis workspace 并编译程序：

```powershell
E:/Xilinx/Vitis/2020.2/bin/xsct.bat `
  V11_LFM_RANGE/scripts/create_v11_vitis_workspace.tcl
```

仅进行 C 代码编译检查：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File V11_LFM_RANGE/scripts/compile_check_sw.ps1
```

当前机器的 BD 生成和 RTL 仿真均已通过；A53 软件也已用 `-Wall -Wextra -Werror` 编译通过。本机当前没有 `xczu28dr` 的 Vivado Synthesis 许可证，因此未在本次会话中生成 bitstream/XSA。取得许可证后运行 `build_v11_hardware.tcl` 即可继续。

## 目录说明

```text
V11_LFM_RANGE/
├─ V11_LFM_RANGE.xpr             独立 Vivado 工程
├─ rtl/lfm_radar_core.v          发射、采集、背景扣除和相关测距核心
├─ mem/lfm_400mhz_4096.mem       400 MHz LFM ROM
├─ sim/tb_lfm_radar_core.sv      可重复的延迟 7 点自检仿真
├─ scripts/                       ROM、BD、仿真、综合和 Vitis 脚本
├─ sw/src/main.c                 RFDC 启动、命令和距离显示程序
└─ V11_LFM_RANGE_CONTEXT.md      设计参数、接口和后续开发上下文
```

## Block Design IP 功能分析

| BD 模块 | V11 中的作用 |
|---|---|
| `zynq_ultra_ps_e_0` | A53 裸机程序运行平台；通过 AXI-Lite 配置 RFDC 和 AXI FIFO，通过 UART 接收命令、显示距离 |
| `usp_rf_data_converter_0` | DAC Tile1 Block0/1 产生 2.4 GHz LFM；ADC Tile1 Block0/1 分别接收回波和 PA 发射参考，并完成 R2C 数字下变频及 4 倍抽取 |
| `lfm_radar_core_0` | V11 自定义核心；ROM 读出 LFM、10 kHz 定时、同步 ADC 捕获、128-lag 复相关、背景复相关扣除、最大峰搜索和结果打包 |
| `axi_fifo_mm_s_0` | PS 与 PL 的双向消息通道；TX 方向发送 START/STOP/BGCAL，RX 方向接收 6-word 测距结果包 |
| `axis_data_fifo_0` | 把 PS 发出的 AXI FIFO 控制 packet 缓冲到 184.32 MHz 雷达时钟域 |
| `axis_data_fifo_rx` | 把雷达结果从 184.32 MHz 域异步跨到 100 MHz PS/AXI FIFO 域 |
| `system_ila_1` | 在线观察 ADC10 I/Q、ADC12 I/Q、两路 DAC 数据、测距结果和控制命令 |
| `jtag_axi_0` | 无软件时通过 JTAG 直接访问 AXI 地址空间，便于 RFDC/FIFO 寄存器调试 |
| `vio_0` | 保留的在线虚拟输入/输出调试模块，可查看或驱动少量控制状态 |
| `proc_sys_reset_0` | 生成 100 MHz PS AXI 控制域复位 |
| `proc_sys_reset_dac` | 生成 184.32 MHz RFDC/雷达数据域复位 |
| `ps8_0_axi_periph` | PS 主 AXI 到 RFDC 和 AXI FIFO 从接口的地址译码与互连 |
| `util_ds_buf_0/1` | ZCU111 板级差分参考时钟输入缓冲 |
| `xlconstant_0` | 为固定控制端口提供常量电平 |

## 当前边界和下一步

- 当前只输出最大相关峰，即单目标“最近/最强候选”模式；多目标 CFAR、速度估计和目标跟踪不在 V11 第一阶段范围内。
- 静态背景扣除能消除稳定泄漏，但不能完全抑制 PA 相位噪声、环行器随温漂变化的泄漏或动态多径。自由空间测试时应定期重新 `BGCAL`。
- 0.5 m 是高风险近距端点。能否达到取决于环行器隔离、天线振铃、ADC 不饱和以及标定稳定性，而不只取决于数字算法。
- 后续如需更高更新率，可把标量相关器改为多 lane/FFT 脉压；如需更低误差，可加入多帧相干/非相干积累、峰形拟合和温漂校准。
