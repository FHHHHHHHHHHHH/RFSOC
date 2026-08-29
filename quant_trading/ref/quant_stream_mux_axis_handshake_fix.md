# quant_stream_mux AXI-Stream 握手修复记录

## 1. 文档信息

- 工程：`ZCU111_CNN/quant_trading`
- 修复模块：`rtl/quant_stream_mux.v`
- 仿真器：Vivado Simulator 2020.2
- 目标器件：`xczu28dr-ffvg1517-2-e`
- 修复日期：2026-08-29

## 2. 修复目标

`quant_stream_mux` 用于在订单簿快照流 `snapshot` 和决策信号流 `signal` 之间进行仲裁，并输出统一的 256-bit AXI-Stream 数据流。仲裁策略保持为：

1. `signal` 优先级高于 `snapshot`。
2. 64-bit `signal` 输出时扩展到 256 bit，高位补零。
3. 任意输入只能在 `TVALID && TREADY` 同时为 1 的时钟沿被接收。
4. 下游反压期间，输出 `TDATA/TLAST/TVALID` 必须保持稳定。
5. 当旧输出在当前周期完成握手时，允许同周期接收下一拍，避免不必要的吞吐气泡。

## 3. 初始验证过程

工程原有以下三个 testbench：

- `sim/tb_fast_orderbook.sv`
- `sim/tb_market_sequence.sv`
- `sim/tb_quant_pipeline_top.sv`

首次运行时，两个定向 TB 通过，但全链路 TB 先后在场景 2 和场景 5 超时，并在 AXI-Lite 寄存器检查中出现一次失败。排查确认这些失败来自 testbench 本身：

### 3.1 广播器模型重复消费快照

全链路 TB 直接把同一个 `snapshot_tvalid` 同时送给 NN 和 MUX，并将两个 ready 简单相与。一个分支完成握手后，另一个分支被阻塞时，已完成分支仍会重复消费相同快照，导致 NN 持续产生 signal，并使 MUX 的 snapshot 分支持续饥饿。

修复方式是在 TB 中加入双分支 pending 状态。每个快照在 NN 和 MUX 分支上分别只能握手一次，两个分支都完成后才释放该快照。

### 3.2 哈希碰撞测试报文字段错位

场景 5 构造订单 ID 1066 时，quantity 覆盖了 price 的低字节，quantity 和 order_id 也整体提前了一个字节。FAST 解码器因此一直等待 order_id 的 stop-bit，无法输出完整帧。

正确字段位置为：

| 字段 | 位范围 | 编码 |
| --- | --- | --- |
| price 990 | `[87:72]` | `07 de` |
| quantity 7 | `[95:88]` | `87` |
| order_id 1066 | `[111:96]` | `08 aa` |

### 3.3 碰撞计数寄存器地址错误

`order_book_engine_ip` 的 `collision_count` 映射到 `araddr[7:2] == 2`，对应字节地址 `0x08`。原 TB 使用了 `0x0C`，实际读取的是 `offset_price`。

### 3.4 TB 端口位宽警告

修正了 AXI-Lite 常量端口的显式位宽，并将订单簿 BRAM 地址连线从 16 bit 改为模块默认的 32 bit。修正后 `xvlog/xelab` 不再报告相关位宽警告。

## 4. 真实 RTL 缺陷

修正 testbench 后，原有三个 TB 全部通过，但全链路 TB 对 MUX 的检查只验证“存在输出”，没有验证 AXI-Stream 输入是否完成握手。

新增隔离协议测试 `sim/tb_quant_stream_mux_protocol.sv` 后，旧 RTL 在 22 ns 报告：

```text
Fatal: AXIS violation: output emitted before an input handshake
```

旧实现的关键问题是：

```verilog
assign s_snapshot_tready = !m_axis_tvalid && !select_signal;
assign s_signal_tready   = !m_axis_tvalid &&  select_signal;

if (!m_axis_tvalid) begin
    if (s_signal_tvalid) begin
        // 未检查 s_signal_tready，直接锁存数据
    end else if (s_snapshot_tvalid) begin
        // 未检查 s_snapshot_tready，直接锁存数据
    end
end
```

当 `s_signal_tvalid=1`、`s_signal_tready=0` 时，模块仍然把 signal 写入输出寄存器。上游认为该 beat 尚未被接收，会继续保持 `TVALID` 和数据，MUX 随后可能再次输出同一 beat，造成重复数据。

snapshot 输入存在相同风险。

## 5. RTL 修复方案

### 5.1 输出寄存器可接收条件

```verilog
wire output_ready = !m_axis_tvalid || m_axis_tready;
```

以下两种情况可以接收新输入：

- 当前输出寄存器为空。
- 当前输出有效且下游 ready，旧数据会在本周期完成握手。

当 `m_axis_tvalid=1` 且 `m_axis_tready=0` 时，`output_ready=0`，两个输入 ready 均为 0，输出寄存器保持不变。

### 5.2 输入仲裁

```verilog
assign s_signal_tready   = output_ready;
assign s_snapshot_tready = output_ready && !s_signal_tvalid;
```

- signal 有效时获得输入通道。
- snapshot 仅在输出可接收且 signal 无效时获得输入通道。
- 两路同时有效时只允许 signal 握手，snapshot 必须保持到后续周期。

### 5.3 仅在握手后锁存数据

```verilog
if (s_signal_tvalid && s_signal_tready) begin
    // 锁存 signal
end else if (s_snapshot_tvalid && s_snapshot_tready) begin
    // 锁存 snapshot
end
```

修复后，输入接收、仲裁结果和输出数据更新使用同一个握手条件，不再出现 `TREADY=0` 时提前取数的问题。

## 6. 协议 TB 覆盖

新增 `sim/tb_quant_stream_mux_protocol.sv`，使用输入/输出计数器和数据记分板检查以下场景：

1. 单个 signal 只能产生一个输出 beat。
2. snapshot 在下游反压时只能被接收一次。
3. 反压期间输出数据必须保持稳定。
4. signal 和 snapshot 同时有效时 signal 优先。
5. 被延迟的 snapshot 必须在后续握手中正常输出。
6. 每个输出 beat 必须对应此前已完成的输入握手。
7. 输出数据必须与输入握手顺序一致。

修复后的测试结果：

```text
PASS AXIS mux accepted=4 emitted=4
```

## 7. 回归验证结果

| 验证项 | 结果 | 关键输出 |
| --- | --- | --- |
| MUX AXI-Stream 协议 TB | PASS | `accepted=4 emitted=4` |
| FAST 解码与订单簿定向 TB | PASS | 118 ns 完成 |
| 市场事件重排 TB | PASS | `snapshots=5 collisions=1` |
| 全链路 TB | PASS | `PASS=15, FAIL=0`，1570 ns 完成 |
| `quant_stream_mux` OOC 综合 | PASS | 0 error，0 critical warning，0 warning |
| 全部核心 RTL OOC 综合 | PASS | `ALL_CORE_RTL_SYNTHESIS_PASS` |

验证日志位于 `sim/test_runs/`，综合日志为：

```text
sim/test_runs/synth_core_rtl.log
```

## 8. 复现命令

以下命令假设 Vivado 2020.2 已加入 `PATH`。如果未加入，请使用 `E:/Xilinx/Vivado/2020.2/bin/` 下的对应批处理文件。

### 8.1 MUX 协议测试

从 `sim/test_runs/tb_quant_stream_mux_protocol` 目录执行：

```powershell
xvlog --sv ../../../rtl/quant_stream_mux.v ../../tb_quant_stream_mux_protocol.sv
xelab tb_quant_stream_mux_protocol -s tb_quant_stream_mux_protocol_sim --debug typical
xsim tb_quant_stream_mux_protocol_sim -runall
```

### 8.2 核心 RTL 综合

从 `quant_trading` 工程根目录执行：

```powershell
vivado -mode batch -source scripts/synth_core_rtl.tcl -nojournal -log sim/test_runs/synth_core_rtl.log
```

## 9. 修改文件

| 文件 | 修改内容 |
| --- | --- |
| `rtl/quant_stream_mux.v` | 修复 AXI-Stream 握手、signal 优先级仲裁和反压保持 |
| `sim/tb_quant_stream_mux_protocol.sv` | 新增 MUX 协议、数据顺序和反压测试 |
| `sim/tb_quant_pipeline_top.sv` | 修复广播模型、FAST 报文字段和寄存器地址 |
| `sim/tb_fast_orderbook.sv` | 修复端口常量和 BRAM 地址位宽 |
| `sim/tb_market_sequence.sv` | 修复 AXI-Lite 常量端口位宽 |

## 10. 最终结论

`quant_stream_mux` 已满足本次验证覆盖下的 AXI-Stream 握手要求：

- 输入仅在 `TVALID && TREADY` 时被接收。
- signal 优先级保持不变。
- 下游反压期间输出稳定。
- 不再提前输出或重复输出未握手的数据。
- 支持连续周期传输。
- 原有业务功能和全链路行为未发生回归。

## 11. GitHub 推送摘要

建议提交标题：

```text
fix: enforce AXI-Stream handshakes in quant stream mux
```

建议提交说明：

```text
- gate snapshot and signal acceptance with TVALID/TREADY handshakes
- preserve signal priority and output stability under backpressure
- support replacing a consumed output beat without an extra idle cycle
- add a protocol scoreboard test for duplicate and premature outputs
- correct full-pipeline TB broadcaster, FAST packet offsets, and AXI register address
- verify all simulation regressions and core RTL out-of-context synthesis
```

建议 PR 摘要：

```text
This change fixes an AXI-Stream protocol violation in quant_stream_mux where
valid input data could be latched even when the corresponding ready signal was
low. The mux now accepts data only on TVALID/TREADY handshakes, keeps signal
priority, holds output data stable during backpressure, and supports one beat
per cycle when the downstream is ready.

A dedicated protocol testbench was added to check premature output, duplicate
beats, backpressure stability, arbitration priority, and data ordering. The
existing end-to-end testbench issues were also corrected. All directed tests,
the 15-check full-pipeline regression, and core RTL OOC synthesis pass.
```
