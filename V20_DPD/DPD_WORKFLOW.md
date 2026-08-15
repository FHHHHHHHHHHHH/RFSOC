# 从阶段 1 软件 DPD 闭环到阶段 2 硬件 MP-DPD

本流程采用论文中的间接学习结构（ILA）：先把 PA 输出反馈当作后置失真器输入，通过最小二乘辨识逆模型，再将同一组 Memory Polynomial 系数用于预失真。默认模型为 4 个 tap、奇数阶 1/3/5/7，共 16 个复系数。

## 0. 前提和安全设置

1. DAC 输出必须通过衰减、PA、耦合器和合适的反馈衰减后接入 ADC，禁止超过 ZCU111 ADC 输入范围。
2. 首次实验保持较低 DAC 幅度，确认频谱、反馈幅度和无削顶后再逐步增加功率。
3. DPD 初始保持关闭：`DPDE 0`。
4. UART 启动信息中的版本应为：DPD `44504401`、LAB `4c414202`。
5. 当前 LAB 最多回放/采集 4096 个复样点；训练波形建议正好使用 4096 点。

## 1. 准备训练波形

输入 CSV 使用归一化浮点列：

```csv
i,q
0.1,0.0
0.08,0.03
```

生成分块 UART 命令：

```powershell
python tools/dpd_workflow.py commands waveform training.csv training_uart.txt
```

把 `training_uart.txt` 逐行发送到板卡，然后执行：

```text
DPDE 0
LABP 1
LABS
```

`LABL` 会由命令文件设置。若波形长度不是 4 的整数倍，工具只回放前面按 4 对齐的部分。

## 2. 采集 PA 输入和反馈

```text
LABC 4096
LABS
LABR 0 4096
```

等待 `LABS` 显示 `done=1` 后再执行 `LABR`，将从 `LABD` 到 `LABE` 的输出保存为 `capture_baseline.txt`。

在 DPD 旁路状态下，LAB 的 TX 参考就是实际送往 PA 的数字基带输入。采集器把 TX lane 0/2 与同拍的 ADC 两个复样点配对；传播时延仍由 PC 工具通过互相关校正。

## 3. 阶段 1：软件 DPD 闭环

辨识 ILA 模型：

```powershell
python tools/dpd_workflow.py identify capture_baseline.txt model_iter1.npz --max-lag 1024
```

工具依次执行：

1. 去直流并做整数采样时延对齐；
2. 用复标量消除反馈链路固定增益和相位；
3. 建立 `x[n-m]|x[n-m]|^(p-1)` MP 矩阵；
4. 用带轻微正则化的复数最小二乘求解 16 个系数。

将模型应用到原始训练波形：

```powershell
python tools/dpd_workflow.py predistort model_iter1.npz training.csv training_pd_iter1.csv
python tools/dpd_workflow.py commands waveform training_pd_iter1.csv training_pd_uart.txt
```

加载新波形、保持 `DPDE 0`、重新采集并测量频谱。可把新采集再次用于辨识，通常迭代 2～4 次，直到 ACPR/NMSE 改善趋于稳定或输入峰值、ADC、PA 出现削顶。

对任意一次 `LABR` 记录做对齐 NMSE；如果已知采样率、主信道带宽和邻道中心偏移，也可同时计算左右 ACPR：

```powershell
python tools/dpd_workflow.py evaluate capture_hw.txt
python tools/dpd_workflow.py evaluate capture_hw.txt --sample-rate 368.64e6 --main-bandwidth 20e6 --adjacent-offset 20e6
```

注意：软件预失真阶段的 `capture TX` 是预失真后的 PA 输入；计算线性化 NMSE/EVM 时，应使用原始 `training.csv` 作为期望输出，而不是直接把 capture TX 当作期望波形。

## 4. 阶段 2：硬件 MP-DPD

把最终模型转换成硬件 LUT：

```powershell
python tools/dpd_workflow.py lut model_final.npz lut_final
python tools/dpd_workflow.py commands lut lut_final lut_bank1_uart.txt --bank 1
```

LUT 地址表示归一化功率：

```text
address = floor((I^2 + Q^2) / 2^19)
power_center = (address + 0.5) / 2048
```

对每个 tap，工具计算：

```text
h_m(power) = c_m,1 + c_m,3*power + c_m,5*power^2 + c_m,7*power^3
```

再量化为复数 Q1.14 `{gain_q,gain_i}`。加载顺序：

```text
DPDS                  # 先查看 active_bank
DPDE 0
<发送非活动 bank 的完整 4×4096 LUT 命令文件>
DPDC                  # 原子切换 bank
DPDX                  # 清削顶计数
DPDE 1
DPDS
```

如果 `DPDS` 显示 active bank 为 1，则下一次应生成/加载 bank 0。绝不能只写部分 LUT 后 commit，因为 BRAM 未写地址的上电内容未定义。

硬件 DPD 开启后，LAB 的 TX 参考位于 DPD 之前，因此它代表“期望线性波形”；这适合直接与 ADC 反馈做 NMSE/EVM 对比。实际送 DAC/PA 的预失真波形可由 ILA 的 DPD 输出监测，或在离线模型中重建。

## 5. 常用 UART 命令

| 命令 | 功能 |
| --- | --- |
| `DPDS` | DPD 版本、enable、active bank、clip count |
| `DPDE 0/1` | 关闭/开启硬件 DPD |
| `DPDW b t start words...` | 分块写 LUT |
| `DPDC` | 切换双 Bank |
| `DPDX` | 清输出削顶计数 |
| `LABS` | 回放和采集状态 |
| `LABW start words...` | 分块写回放波形 |
| `LABL count` | 设置回放长度 |
| `LABP 0/1` | 选择原 DBPSK 或波形 RAM |
| `LABC count` | 触发采集 |
| `LABR start count` | 输出采集记录 |

## 6. 验收标准

- 功能：DPD 旁路时原 DBPSK 链路行为不变；LAB 回放和 ADC 接收机能同时工作。
- 数值：离线 identification NMSE 稳定，系数不过度发散；预失真波形峰值不持续触顶。
- 硬件：`CLIP_COUNT` 应接近 0；若持续增长，先降低波形峰值或整体增益。
- RF：在相同 PA 平均输出功率下比较 DPD 开/关 ACPR、带内 EVM/NMSE；不能用降低输出功率造成的“伪改善”作为结论。

运行数值自测：

```powershell
python tools/dpd_workflow.py selftest
python -m unittest tools/test_dpd_workflow.py -v
```

导出/编译软件平台：

```powershell
vivado -mode batch -source scripts/export_dpd_xsa.tcl
cd ..\sw
xsct build_vitis_dpd.tcl
```

首次生成 BSP 会花费几分钟。硬件地址变化后应使用新的 XSA 重新建立 `sw/ws`；该目录和生成的 ELF 已由 `.gitignore` 排除。
