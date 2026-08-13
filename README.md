# ZCU111 V11 LFM short-range radar

本分支实现基于 ZCU111 RFSoC 的 2.4 GHz、400 MHz 带宽短距 LFM 测距系统。
工程从已经过板级验证的 V10 RFDC、LMK/LMX 时钟和 A53 裸机控制基线演进，
新增双通道参考/回波采集、复相关、静态背景扣除、峰值搜索和距离输出。

V11 的完整工程位于 [`V11_LFM_RANGE/`](V11_LFM_RANGE/)，详细使用说明见
[`V11_LFM_RANGE/README.md`](V11_LFM_RANGE/README.md)。

## 当前状态

- DAC10/DAC11 输出相同的 4096 点、400 MHz LFM 波形；
- ADC10 采集回波 I/Q，ADC12 采集发射参考 I/Q；
- 支持 128 个正 lag 的复相关和复数静态背景扣除；
- 相关器采用 BRAM 存储以及
  `READ/MULT/ACCUM/DIFF/MAG/UPDATE` 六级寄存化结构；
- 软件使用峰值左右邻点进行三点抛物线亚采样插值；
- 支持 `BGCAL`、`RCAL`、门限、打印分频及 RFDC NCO 控制；
- RTL 仿真、A53 编译、综合、布局布线和 XSA 生成均已完成；
- 同轴线实测已经验证 lag 和输出距离随线缆长度单调变化。

## 默认参数

| 参数 | 数值 |
|---|---:|
| 射频中心频率 | 2400 MHz |
| LFM 带宽 | 400 MHz |
| DAC 采样率 | 5898.24 MSPS |
| ADC 采样率 | 2949.12 MSPS |
| ADC 有效复采样率 | 737.28 MSPS |
| PL 时钟 | 184.32 MHz |
| 脉冲长度 | 4096 点，约 5.556 us |
| 捕获窗口 | 8192 点，约 11.111 us |
| PRF | 10 kHz |
| 搜索范围 | 128 个正 lag |
| 理论双目标距离分辨率 | 约 0.375 m |
| 整数 lag 距离步距 | 约 203.31 mm |
| 当前内部结果率 | 约 59 Hz |

400 MHz 带宽决定约 0.375 m 的双目标分辨率；单个强目标的峰中心可以通过
高信噪比相关和抛物线插值估计到小于一个距离采样点，但显示到毫米不代表
系统具有毫米级绝对精度。

## 信号链

```text
LFM ROM -> DAC10/DAC11

ADC12 reference I/Q --+
                      +-> complex correlation -> background subtraction
ADC10 echo I/Q -------+                         -> peak + neighbours
                                                -> A53 interpolation/calibration
                                                -> UART range
```

## BRAM 与六级流水优化

初版采集数组使用异步读取并与异步复位控制混合，Vivado 将大容量存储拆成
寄存器和大规模地址 MUX。当前实现将 reference、echo 和 background 改成
标准同步 Block RAM 模板，并删除不必要的完整 `score_mem`。

相关计算在 BRAM、乘法、累加、背景相减、幅度和峰值更新之间设置寄存边界，
消除了 `reference_mem` 到 `max_score` D/CE 的长组合依赖。验证结果包括：

| 检查项 | 结果 |
|---|---:|
| Block RAM Tile | 16.5 / 1080 |
| DSP48E2 | 4 / 4272 |
| 独立核 setup WNS | +1.984 ns |
| `max_score` D slack | +4.044 ns |
| `max_score` CE slack | +3.813 ns |
| 完整 routed setup WNS | +0.828 ns |
| 完整 routed hold WHS | +0.010 ns |

完整问题分析、处理过程、周期复算和后续优化建议见
[`V11_LFM_RANGE/LFM_BRAM_PIPELINE_OPTIMIZATION_ANALYSIS.md`](V11_LFM_RANGE/LFM_BRAM_PIPELINE_OPTIMIZATION_ANALYSIS.md)。

## 当前吞吐边界

六级结构解决的是存储推断和时序，不等于每拍启动一个新样点。当前 FSM 对
每个相关样点依次执行 `READ/MULT/ACCUM`，因此一次完整处理约为：

```text
128 x (3 x 8064 + 3) = 3,096,960 correlation cycles
包含采集和输出约 16.8 ms/帧，即约 59 results/s
```

若需要更高结果率，推荐依次实施：

1. 将单 lane 相关数据通路改成真正 `II=1` 的重叠流水；
2. 利用每个 128-bit BRAM word 的四个复数样点实现 4-lane MAC；
3. 根据目标结果率增加 lag engine、BRAM banking 和 ping-pong capture；
4. 对严格 10 kHz 逐脉冲处理比较多 engine 时域相关和 FFT 脉压。

三乘法复数乘法可以节省 25% DSP，但当前 DSP 使用率很低；现阶段 BRAM
读带宽、流水启动间隔和并行存储结构的优先级更高。

## 快速验证

重新生成并核对 LFM ROM：

```powershell
python V11_LFM_RANGE\mem\generate_lfm_400mhz_4096.py
```

运行 RTL 回归仿真：

```powershell
E:\Xilinx\Vivado\2020.2\bin\vivado.bat -mode batch `
  -source V11_LFM_RANGE\scripts\run_rtl_sim.tcl -nolog -nojournal
```

生成 bitstream 和 XSA：

```powershell
E:\Xilinx\Vivado\2020.2\bin\vivado.bat -mode batch `
  -source V11_LFM_RANGE\scripts\build_v11_hardware.tcl
```

## 安全提示

不得把 30 dBm PA 输出直接连接到 RFSoC ADC。使用 PA、定向耦合器或同轴
环回测试时，必须通过衰减器、限幅器和功率测量确认 ADC 输入处于板卡允许范围。
