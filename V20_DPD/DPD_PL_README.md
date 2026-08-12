# ZCU111 V20 DPD PL 说明

## 当前实现

V20 在原 V10 DBPSK 发射链路中加入了四路并行 Memory Polynomial DPD：

`dual_dac_dbpsk_tx → dpd_mp_0 → RFDC s10/s11`

- AXI-Stream 数据宽度：128 bit，每拍 4 个复数样点。
- 样点时钟：184.32 MHz。
- 样点排列：`TDATA[31:0]={Q0,I0}`，之后依次为样点 1、2、3。
- 记忆深度：4 个 tap，即当前样点加 3 个历史样点。
- 每个 tap 的幅度查找表：4096 项。
- 系数格式：复数 Q1.14，32 bit 写数据为 `{gain_q[15:0], gain_i[15:0]}`。
- 双系数 Bank：软件写非活动 Bank，再通过一次 commit 原子切换。
- 复位后 DPD 默认关闭，采用与 DPD 等延迟的旁路，未装载系数时不会破坏原 V10 发射功能。
- 当前同一份 DPD 输出复制到 DAC0 和 DAC1，保留 V10 的双 DAC 输出结构。

按当前结构估算，数据通路包含 64 个复乘实乘单元和 8 个幅度平方乘法，约使用 72 个 DSP48；双 Bank、四路复制 LUT 约占 4 Mbit 存储。最终资源量和 184.32 MHz 时序必须以有许可证的综合/实现报告为准。

## AXI-Lite 地址

DPD 控制空间同时映射到 PS 和 JTAG AXI：

- 基地址：`0xA0080000`
- 范围：256 KiB，结束地址 `0xA00BFFFF`

寄存器偏移：

| 偏移 | 名称 | 说明 |
| --- | --- | --- |
| `0x00000` | CONTROL | bit0 enable；bit1 写 1 触发 Bank commit；bit2 写 1 清零削顶计数 |
| `0x00004` | STATUS | bit0 活动 Bank；bit1 数据时钟域中的 DPD enable |
| `0x00008` | CLIP_COUNT | 发生输出饱和的有效数据拍数量 |
| `0x0000C` | CORE_VERSION | 固定为 `0x44504401` |

系数写地址的局部偏移为：

```text
0x20000 | (bank << 16) | (tap << 14) | (lut_address << 2)
```

其中 `bank=0/1`、`tap=0..3`、`lut_address=0..4095`。系数存储当前设计为只写；写入前应在软件中保存并校验系数表。

推荐装载顺序：

1. 保持 CONTROL.enable 为 0。
2. 完整写入非活动 Bank 的 4×4096 个复系数。BRAM 上电内容未定义，不应只写部分地址后直接启用。
3. 向 CONTROL 写 bit1=1，等待 STATUS.active_bank 改变。
4. 向 CONTROL 写 bit0=1，启动 DPD。
5. 运行时更新另一 Bank，完成后再次 commit，可避免输出流中逐项更新系数。

## Block Design 连接

- `dual_dac_dbpsk_tx_0/m0_axis` → `dpd_mp_0/s_axis`，同时由 `system_ila_1/SLOT_5_AXIS` 观测。
- `dpd_mp_0/m0_axis` → `usp_rf_data_converter_0/s10_axis`。
- `dpd_mp_0/m1_axis` → `usp_rf_data_converter_0/s11_axis`，同时由 `system_ila_1/SLOT_4_AXIS` 观测。
- `ps8_0_axi_periph/M02_AXI` → `dpd_mp_0/S_AXI`。
- DPD 数据时钟/复位来自 RFDC DAC1 的 184.32 MHz 时钟域。
- AXI-Lite 时钟/复位来自 PS `pl_clk0` 的 99.999001 MHz 时钟域。

## 验证状态

- `tb_dpd_mp_4lane_core.sv`：已通过旁路、恒等系数、Bank 切换、正负饱和及削顶计数测试。
- `tb_axis_dpd_mp_4lane_dual.sv`：已通过 AXI-Lite 寄存器、系数写入复制、跨时钟状态、Bank commit、计数清零和双路旁路测试。
- `validate_bd_design`：通过；仍有原工程已有的 PS/AXI interconnect `AWUSER_WIDTH/ARUSER_WIDTH` 警告。
- `generate_target all`：通过，已生成包含 `dpd_mp_0` 的 BD HDL 和 IP 输出产品。
- OOC 综合：本机缺少 `xczu28dr` Synthesis 许可证，尚不能给出资源利用率和时序结论。

相关脚本：

- `scripts/integrate_dpd_pl.tcl`：重复执行 PL 集成。
- `scripts/generate_dpd_bd.tcl`：校验并生成 BD 输出产品。
- `scripts/verify_dpd_pl.tcl`：检查 DPD 连接、时钟、地址和 V10 编译路径依赖。
