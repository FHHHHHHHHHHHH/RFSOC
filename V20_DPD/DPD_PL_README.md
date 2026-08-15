# ZCU111 V20 DPD PL 设计说明

## 数据通路

当前工程在 V10 DBPSK 发射/接收链路中加入了软件闭环实验控制器和四路并行 Memory Polynomial DPD：

```text
DBPSK TX ─┐
          ├─> dpd_lab_0 ─> dpd_mp_0 ─> RFDC DAC10/DAC11
波形 RAM ─┘       ↑
                  │ TX 参考（DPD 输入）

RFDC ADC10 ─> AXIS Broadcaster ─┬─> 原 DBPSK RX
                                └─> dpd_lab_0 采集
RFDC ADC11 ─> AXIS Broadcaster ─┬─> 原 DBPSK RX
                                └─> dpd_lab_0 采集
```

- DAC 基带流：128 bit，每拍 4 个复样点，`TDATA[31:0]={Q0,I0}`。
- 数据时钟：184.32 MHz。
- ADC 反馈：每拍 2 个 I 样点和 2 个 Q 样点。
- 为匹配 ADC 采样率，采集器从四路 TX 中选择 lane 0 和 lane 2。
- DPD：4 个记忆 tap，每个 tap 4096 点复增益 LUT，复增益为 Q1.14 `{gain_q,gain_i}`。
- 双系数 Bank：软件完整写入非活动 Bank 后再 commit，避免在线逐项更新。
- 复位后 DPD 默认旁路，保留原 V10 发射行为。

## 地址映射

| 模块 | PS/JTAG AXI 基地址 | 范围 |
| --- | --- | --- |
| MP-DPD | `0xA0080000` | 256 KiB |
| DPD LAB | `0xA00C0000` | 256 KiB |

### MP-DPD

| 偏移 | 名称 | 说明 |
| --- | --- | --- |
| `0x00000` | CONTROL | bit0 enable；bit1 写 1 commit；bit2 写 1 清 clip counter |
| `0x00004` | STATUS | bit0 active bank；bit1 数据域 enable |
| `0x00008` | CLIP_COUNT | 出现输出饱和的有效数据拍数 |
| `0x0000C` | VERSION | `0x44504401` |

LUT 写地址：

```text
0x20000 | (bank << 16) | (tap << 14) | (lut_index << 2)
```

其中 `bank=0..1`、`tap=0..3`、`lut_index=0..4095`。

### DPD LAB

| 偏移 | 名称 | 说明 |
| --- | --- | --- |
| `0x00000` | CONTROL | bit0 playback；bit1 写 1 触发采集；bit2 写 1 清采集状态 |
| `0x00004` | STATUS | bit0 playback active；bit1 busy；bit2 done |
| `0x00008` | PLAYBACK_LENGTH | 4..4096，按 4 对齐 |
| `0x0000C` | CAPTURE_TARGET | 2..4096，按 2 对齐 |
| `0x00010` | CAPTURE_COUNT | 已采样点数 |
| `0x00014` | VERSION | `0x4C414202` |
| `0x10000` | WAVEFORM RAM | 4096×32 bit `{Q,I}` |
| `0x20000` | CAPTURE RAM | 每样点两个 32 bit word：TX 参考、ADC 反馈 |

## 验证

- `tb_dpd_mp_4lane_core.sv`：旁路、增益、Bank、饱和和 clip counter。
- `tb_axis_dpd_mp_4lane_dual.sv`：AXI-Lite、双输出和跨时钟控制。
- `tb_axis_dpd_lab_controller.sv`：波形 RAM、循环回放、采集 RAM 和寄存器。
- `scripts/verify_dpd_pl.tcl`：BD 连接、时钟、地址和 V10 外部依赖检查。
- `validate_bd_design` 已通过；工程原有 PS/AXI `AWUSER_WIDTH/ARUSER_WIDTH` 警告仍保留。
- 当前机器缺少 `xczu28dr` synthesis license，因此资源量和 184.32 MHz 时序仍需在有许可环境执行完整综合/实现后确认。

相关脚本：

- `scripts/integrate_dpd_pl.tcl`：可重复执行 PL 集成。
- `scripts/generate_dpd_bd.tcl`：生成 BD 输出产品和 wrapper。
- `scripts/verify_dpd_pl.tcl`：结构化检查连接与地址。
- `scripts/export_dpd_xsa.tcl`：导出不含 bitstream 的 V20 XSA，供 Vitis 更新 BSP。
