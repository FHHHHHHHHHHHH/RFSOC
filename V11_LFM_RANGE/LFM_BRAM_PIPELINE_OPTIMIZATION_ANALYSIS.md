# ZCU111 V11 LFM 相关器 BRAM 与六级流水优化问题分析及处理记录

## 1. 文档目的

本文记录 `lfm_radar_core` 已完成的两次关键 RTL 优化：

1. 将采集缓存、背景缓存和波形 ROM 改写为 Vivado 2020.2 可稳定推断的 Block RAM 模板；
2. 将相关运算拆分为 `READ/MULT/ACCUM/DIFF/MAG/UPDATE` 六个寄存级，消除
   `reference_mem` 到 `max_score` 时钟使能端的超长组合路径。

本文同时复核当前架构的处理吞吐、DSP 三乘法复数乘法以及 48 bit 绝对值逻辑，给出后续优化优先级。分析基于以下当前配置：

| 参数 | 当前值 |
|---|---:|
| PL 时钟 | 184.32 MHz |
| PRF | 10 kHz |
| PRF 周期 | 18,432 个 PL 时钟，即 100 us |
| 发射脉冲 | 4096 个复数样点 |
| 采集长度 | 8192 个复数样点 |
| 最大搜索 lag 数 | 128 |
| 每个 lag 的相关样点数 | `8192 - 128 = 8064` |
| ADC/DAC 数据宽度 | 每个 128 bit beat 含 4 个复数样点 |
| 复数有效采样率 | 737.28 MSPS |

## 2. 优化前问题一：采集存储未能推断为 BRAM

### 2.1 问题表现

初版相关器把 I/Q 四个 lane 分散在多个数组中，并通过异步索引函数读取；这些数组还受到带异步复位的控制过程影响。Vivado 2020.2 无法把该访问方式匹配到 UltraScale+ BRAM 模板，综合时将采集数组、背景数组和 `score_mem` 拆散为寄存器和大规模地址选择器。

原始存储规模约为：

- reference：8192 个复数样点；
- echo：8192 个复数样点；
- 每个复数样点为 16 bit I + 16 bit Q；
- 两路采集数据合计 `2 x 8192 x 32 = 524,288 bit`；
- 再加背景复数相关值、score 缓存及控制寄存器，总寄存存储量约 0.67 Mbit。

这种实现会导致：

- FF/LUT 数量异常增长；
- 读地址后产生宽而深的多级 MUX；
- BRAM 读数据、乘法器、累加器、峰值比较器被连入同一条长组合路径；
- 布线拥塞和时序收敛困难；
- 后续增加并行相关核几乎不可行。

### 2.2 根因

问题不在 `ram_style="block"` 属性本身，而在 RTL 端口语义不能映射到物理 BRAM：

1. UltraScale+ BRAM 是同步读存储器，异步数组读取无法直接映射；
2. 在带异步复位的控制 always 块中混合存储器写入，破坏标准 RAM 推断模板；
3. 多个独立 lane 数组增加了端口和读取组合逻辑；
4. `score_mem` 保存所有 lag 分数，但最终只需要最大峰及左右邻点，存储需求大于算法实际需求。

### 2.3 处理方法

当前 RTL 在 [rtl/lfm_radar_core.v](rtl/lfm_radar_core.v) 中采用以下结构。

#### 2.3.1 将四 lane 打包为宽 BRAM

采集数据按 RFDC 每拍的数据结构保存：

```verilog
(* ram_style = "block" *) reg [127:0] reference_mem [0:CAPTURE_BEATS-1];
(* ram_style = "block" *) reg [127:0] echo_mem      [0:CAPTURE_BEATS-1];
```

其中 `CAPTURE_BEATS = 8192 / 4 = 2048`。每个 BRAM 逻辑字保存四个 I 样点和四个 Q 样点，避免把同一 ADC beat 拆成多个小数组。

#### 2.3.2 使用独立的无复位同步 RAM 过程

存储器只在单独的时钟过程内读写，不对 RAM 内容和读端口施加复位：

```verilog
always @(posedge clk) begin
    if (capture_write_enable) begin
        reference_mem[capture_beat_index] <= {ref_q_axis_tdata, ref_i_axis_tdata};
        echo_mem[capture_beat_index]      <= {echo_q_axis_tdata, echo_i_axis_tdata};
    end

    reference_read_data <= reference_mem[reference_read_address];
    echo_read_data      <= echo_mem[echo_read_address];
end
```

数据有效性由 FSM 管理，而不是依赖 RAM 清零。

#### 2.3.3 背景相关值改为同步 BRAM

每个 lag 保存 48 bit 实部和 48 bit 虚部：

```verilog
(* ram_style = "block" *) reg [95:0] background_mem [0:MAX_LAG-1];
```

背景校准在 `DIFF` 阶段写入已完成并注册的相关和；正常扫描则同步读取背景并在后续寄存级相减。

#### 2.3.4 删除完整 score_mem

峰值搜索只保留：

- 当前最大值 `max_score`；
- 最大值 lag `max_lag_index`；
- 最大值左邻点 `max_left_score`；
- 最大值右邻点 `max_right_score`；
- 上一个 lag 的分数 `previous_score`。

这样仍可在软件端执行三点抛物线插值，但不需要保存全部 128 个 score。

#### 2.3.5 波形 ROM 使用同步 Block ROM

`lfm_400mhz_4096.mem` 以同步 ROM 方式读取，并提前一拍准备 DAC 输出，保持 AXI 数据序列不重复、不遗漏。

### 2.4 BRAM 优化结果

独立 `lfm_radar_core` 综合报告显示：

| 资源 | 使用量 | 器件可用量 | 使用率 |
|---|---:|---:|---:|
| Block RAM Tile | 16.5 | 1080 | 1.53% |
| RAMB36E2 | 15 | 1080 | 1.39% |
| RAMB18E2 | 3 | 2160 | 0.14% |
| DSP48E2 | 4 | 4272 | 0.09% |
| LUT | 3329 | 425280 | 0.78% |
| Register | 1013 | 850560 | 0.12% |

综合日志明确报告 `reference_mem_reg` 和 `echo_mem_reg` 被实现为 Block RAM cascade，证明存储器推断问题已经解决。报告位置：

- `output/core_synth/utilization.rpt`
- `V11_LFM_RANGE.runs/synth_1/runme.log`

## 3. 优化前问题二：reference_mem 到 max_score CE 的关键路径

### 3.1 问题表现

BRAM 化以后，相关器必须接受同步读延迟。如果仍在一个状态或一个组合表达式中完成：

```text
BRAM输出 -> lane选择 -> 复数乘法 -> 复数累加 -> 背景相减
         -> 绝对值 -> 幅度相加 -> 最大值比较 -> max_score写使能
```

那么 `max_score` 的 D/CE 逻辑会间接依赖 `reference_mem` 和 `echo_mem` 读口。尤其峰值比较结果通常被综合为大量寄存器的时钟使能，容易形成高扇出 CE 路径。

这类路径的问题不仅是算术层级深，还包括：

- BRAM 输出和 lane MUX 延迟；
- 四个 16x16 乘法；
- 33/48 bit 加法与累加；
- 96 bit 背景数据读取与减法；
- 两个 48 bit 绝对值；
- 49 bit 幅度求和和比较；
- 最大峰、左右邻点等多个寄存器的高扇出 CE。

### 3.2 六级流水处理方法

当前实现把相关器拆成六个具有明确寄存器边界的状态。

| 阶段 | 主要操作 | 关键寄存器/输出 |
|---|---|---|
| READ | 发起同步 BRAM 读取，保存 reference/echo lane 号 | BRAM 注册输出、lane selector |
| MULT | 选择 I/Q lane，执行四个 16x16 乘法 | 四个 32 bit 乘积寄存器 |
| ACCUM | 组成复数乘积并累加；最后一个样点锁存完整相关和 | `corr_sum_re_pipe/im_pipe` |
| DIFF | 正常模式减背景；校准模式保存原始相关和 | `corr_diff_re_pipe/im_pipe` |
| MAG | 计算 `abs(real) + abs(imag)` | `magnitude_pipe` |
| UPDATE | 峰值及左右邻点更新 | `max_score` 等峰值寄存器 |

数据依赖变为：

```text
BRAM -> READ reg -> MULT reg -> ACCUM reg -> DIFF reg -> MAG reg -> UPDATE reg
```

`max_score` 只由已注册的 `magnitude_pipe` 驱动，不再直接依赖采集 BRAM、乘法器、累加器或背景 BRAM。

### 3.3 六级流水验证结果

#### 3.3.1 行为仿真

`sim/tb_lfm_radar_core.sv` 完成以下回归：

1. 采集静态泄漏并完成背景校准；
2. 注入带静态泄漏的 lag-7 合成目标；
3. 校准背景被正确相减；
4. 最终峰值检测为 lag 7。

RTL 仿真结果为 PASS。

#### 3.3.2 独立相关核时序

在 5.425 ns（约 184.32 MHz）时钟约束下：

| 检查项 | 结果 |
|---|---:|
| Setup WNS | +1.984 ns |
| `max_score` D slack | +4.044 ns |
| `max_score` CE slack | +3.813 ns |
| `max_score` D/CE 的起点 | `magnitude_pipe` 寄存器 |

独立综合的 -0.070 ns hold 是未布局网表的估算结果，不应作为最终 sign-off。

#### 3.3.3 完整工程实现时序

完整 routed timing summary 显示：

| 检查项 | 结果 |
|---|---:|
| Setup WNS | +0.828 ns |
| Hold WHS | +0.010 ns |
| TNS/THS | 0 |
| 结论 | 所有用户时序约束满足 |

报告位置：`V11_LFM_RANGE.runs/impl_1/design_1_wrapper_timing_summary_routed.rpt`。

#### 3.3.4 同轴线硬件验证

参考线固定为 0.3 m，改变测量线长度后获得：

| 测量线 | 相对线长 | lag | 输出等效距离 | peak |
|---:|---:|---:|---:|---:|
| 1.0 m | 0.7 m | 2 | 0.469 m | 725050 |
| 2.0 m | 1.7 m | 6 | 1.195 m | 719964 |
| 2.3 m | 2.0 m | 7 | 1.431 m | 551169 |
| 3.0 m | 2.7 m | 9 | 1.893 m | 565585 |

结果随线长单调变化，并与同轴线速度因子约 0.70 的传播模型吻合。这证明优化后的采集 BRAM、相关累加、峰值输出和软件亚采样插值已经形成物理闭环。

## 4. 当前主要瓶颈：六级状态机改善 Fmax，但未改善吞吐

### 4.1 必须区分流水延迟和启动间隔

当前名字虽然是“六级流水”，但它由一个 FSM 串行推进。对相关主体的每一个复数样点，都依次占用：

```text
READ 1拍 -> MULT 1拍 -> ACCUM 1拍
```

因此当前样点启动间隔不是 `II=1`，而是 `II=3`。只有一个样点完成 ACCUM 后，下一个样点才进入 READ。`DIFF/MAG/UPDATE` 则在每个 lag 结束时各增加一拍。

### 4.2 当前精确周期估算

每个 lag 的周期数约为：

```text
C_lag = 3 x CORR_SAMPLES + DIFF + MAG + UPDATE
      = 3 x 8064 + 3
      = 24,195 cycles
```

128 个 lag 的相关处理周期为：

```text
C_corr = 128 x 24,195
       = 3,096,960 cycles
```

再加 2048 拍采集和少量 finalize/output 开销：

```text
C_total ~= 3,099,015 cycles
T_total ~= 3,099,015 / 184.32 MHz
        ~= 16.813 ms
```

与 100 us PRF 周期比较：

```text
16.813 ms / 100 us ~= 168.1
```

由于新采集只在 `proc_state == PROC_IDLE` 时启动，系统不会把 168 帧全部排队；它继续按 10 kHz 产生 DAC 脉冲，但只会在相关器回到 IDLE 后接受下一次 ADC 采集。考虑 PRF 边界量化，约每 169 个发射脉冲接受一次采集，完成结果率约为：

```text
10,000 / 169 ~= 59.2 results/s
```

这与工程上下文中约 59 Hz 的结果率一致。

因此，对“`128 x 8064 = 1,032,192` 周期，是 PRF 的 56 倍”的判断需要修正：

- 若乘加数据通路是真正 `II=1`，该估算基本成立；
- 对当前 FSM 实现，实际是约 3,096,960 个相关周期，即约 168 个 PRF 周期；
- 当前系统不是离线存储后由软件处理，而是在线、低帧率地选择部分脉冲进行 PL 相关处理；
- 它适合约 59 Hz 的当前短距单目标显示，但不能对每个 10 kHz 脉冲都输出独立距离。

## 5. 对三个后续优化建议的技术评估

### 5.1 多核并行相关器：方向正确，但不应直接从 56 个 FSM 核开始

如果要求每个 10 kHz 脉冲都完成 128 lag 的全长时域相关，则算力需求为：

```text
128 x 8064 x 10,000
= 10.32192 G complex MAC/s
```

当前 184.32 MHz、一个复数 MAC 数据通路的理论上限为 184.32 M complex MAC/s；如果每核是 `II=1`，至少需要：

```text
10.32192 G / 184.32 M = 56 个并行复数 MAC lane
```

但当前 FSM 核是 `II=3`，直接复制它需要约 168 核才能达到每脉冲实时，而且会复制控制和存储读口问题。因此正确顺序应为：

1. 先把 READ/MULT/ACCUM 从互斥状态改成 valid/address 流水，使新样点可以每拍进入，即 `II=1`；
2. 利用当前 BRAM 每拍已经输出 128 bit、包含四个复数样点的结构，评估四 lane 并行复数 MAC；
3. 再按目标结果率复制 lag engine 或按 lag 分组；
4. 同时设计采集 ping-pong buffer，否则计算和下一脉冲采集仍不能重叠；
5. 解决 BRAM 端口带宽，不能假定大量核心可以同时任意读取同一对双口 BRAM。

#### 不同架构的近似处理时间

| 架构 | 每个 lag 主体周期 | 128 lag 相关时间 | 约需跨越的 PRF 周期 |
|---|---:|---:|---:|
| 当前 FSM，单 lane，II=3 | 24,192 | 16.80 ms | 168 |
| 单 lane 真流水，II=1 | 8064 | 5.60 ms | 56 |
| 4 lane 真流水 | 2016 | 1.40 ms | 14 |
| 4 lane x 16 个 lag engine | 2016 | 约 87.5 us 主体 | 可接近每脉冲实时 |

最后一行假定 16 个 engine 各负责 8 个 lag，且存储带宽、流水填充、采集和输出均被妥善处理。它不是仅靠复制 RTL 就能自动实现的结果。

#### BRAM 带宽是多核方案的关键约束

每个并行 lag engine 每拍都需要 reference 和 echo 数据。可选方法包括：

- 为各 lag engine 复制 reference BRAM；
- 对 echo 数据按 bank 交错，支持多个偏移地址并行读取；
- 广播 reference，复制/分 bank echo；
- 将四个相邻样点作为一个向量，在一个 128 bit BRAM 读周期内并行计算；
- 用 URAM、RAM replication 或专门的 shift-register/window 结构提高读带宽。

因此“至少 56 个复数 MAC lane”是算力下界，不等于“例化 56 个现有模块”就是完整方案。

### 5.2 三乘法复数乘法：数学可行，但当前不是第一优先级

当前相关使用：

```text
echo x conj(reference)
(a + jb)(c - jd)
real = ac + bd
imag = bc - ad
```

四乘法实现需要 `ac`、`bd`、`bc`、`ad` 共四个 16x16 乘法。三乘法形式可写为：

```text
p1 = a x c
p2 = b x d
p3 = (a + b) x (c - d)
real = p1 + p2
imag = p3 - p1 + p2
```

它将每个复数乘法从 4 个乘法器降为 3 个，但需要注意：

- `a+b` 和 `c-d` 是 17 bit；`p3` 是 34 bit，位宽必须正确扩展；
- 增加了预加法、后加法和扇出；
- 必须重新确认截位、符号扩展和累加结果与当前四乘法实现逐 bit 一致；
- 三乘法可能改变 DSP48E2 映射和最高频率，不能只按 DSP 数量判断收益。

当前独立核心只使用 4/4272 个 DSP，DSP 使用率 0.09%，所以单核阶段没有必要为节省一个 DSP 增加数值和时序风险。

在并行化后，三乘法才有明显价值。例如 64 个复数 MAC lane：

| 实现 | DSP 数量 |
|---|---:|
| 四乘法 | 256 |
| 三乘法 | 192 |
| 节省 | 64 DSP，25% |

即使四乘法 256 DSP 也只约占 XCZU28DR 的 6%。因此在本器件上，更可能先受 BRAM 读带宽、路由、累加结构和功耗限制，而不是 DSP 总数限制。建议先完成 II=1/多 lane 架构原型并综合，再决定是否采用三乘法。

### 5.3 abs48 绝对值：可继续优化，但当前没有关键路径证据

当前 MAG 级为：

```verilog
magnitude_pipe <=
    {1'b0, abs48(corr_diff_re_pipe)} +
    {1'b0, abs48(corr_diff_im_pipe)};
```

其中负数绝对值会形成 48 bit 取反加一，再进行 49 bit 求和。理论上它可能形成较长 carry chain，但当前报告显示：

- 独立核心 setup WNS 为 +1.984 ns；
- 已报告的最慢 setup 路径是 `reference_mem -> lane mux -> DSP multiplier`；
- `max_score` D/CE 余量分别为 +4.044 ns 和 +3.813 ns；
- 完整实现 WNS 为 +0.828 ns，所有 setup/hold 约束满足。

因此目前不能把 `abs48` 定义为已经发生的关键时序故障。

#### 方法 A：写成 `-value`

```verilog
abs_value = value[47] ? -value : value;
```

这主要提高可读性，综合后通常仍是相同或相近的补码进位逻辑，不能保证改善 Fmax。

#### 方法 B：增加 ABS 寄存级

将符号处理和两路绝对值注册，再在下一拍求和。这是最可预测的时序优化方法，但会把现有六级相关尾部扩成七级或更多。每个 lag 只增加一拍，对总吞吐影响很小；真正收益应由针对 MAG 端点的 timing report 证明。

#### 方法 C：把符号选择并入求和

根据实部、虚部符号选择：

```text
|re| + |im| = (+/- re) + (+/- im)
```

可尝试用加/减选择和 DSP ALU 合并，但 RTL 可读性、DSP 映射和边界值 `-2^47` 行为必须验证。它更适合在并行 MAC 架构确定后统一设计，而不建议现在单独改动。

建议新增专门报告：

```tcl
report_timing -delay_type max -to [get_pins -hier -filter {NAME =~ *magnitude_pipe_reg*/D}]
```

只有当该路径成为 WNS 或余量明显不足时，再优先插入 ABS 级。

## 6. 推荐的后续优化路线

### 阶段 0：保持当前版本作为已验证基线

当前版本已经具备：

- BRAM 正确推断；
- 六级寄存边界；
- RTL 仿真 PASS；
- 完整实现时序通过；
- 同轴线实测通过；
- 约 59 Hz 在线距离结果。

任何吞吐优化都必须回归 lag、peak、左右邻点、背景校准和同轴线结果。

### 阶段 1：增加可观测性

建议先增加：

- 发射脉冲计数；
- 被接受的 capture 计数；
- 因处理忙而跳过的 capture 计数；
- 单帧处理周期计数；
- peak/lag 跳变统计。

当前软件的 `dropped` 只统计 PS 接收结果包的问题，不代表 PL 因 `proc_state != IDLE` 而跳过的脉冲。

### 阶段 2：将单 lane 数据通路改成真正 II=1

保留寄存边界，但用 valid shift register 和流水地址代替互斥 FSM：

```text
cycle n:   READ sample n
cycle n+1: MULT sample n,   READ sample n+1
cycle n+2: ACCUM sample n,  MULT sample n+1, READ sample n+2
```

此步骤可把单核计算时间从约 16.8 ms 降到约 5.6 ms，同时保留当前 Fmax 优势。

### 阶段 3：一次 BRAM beat 处理四个样点

当前 BRAM 一次已经读出四个复数样点。若把四个 lane 同时复数乘并通过加法树合并到累加器，可把每个 lag 的主循环从 8064 拍降低到 2016 拍，单引擎全 128 lag 时间约 1.4 ms。

需处理 echo 的非 4 对齐 lag。推荐使用相邻两个 128 bit echo word 拼接成滑动窗口，再按 `lag[1:0]` 选择连续四个 echo 样点。

### 阶段 4：按目标结果率并行 lag engine

并行数量应由系统需求决定，而不是固定追求 10 kHz 全帧率：

| 目标结果率 | 允许处理时间 | 对 4-lane 架构的建议量级 |
|---:|---:|---:|
| 100 Hz | 10 ms | 单 engine 已足够 |
| 500 Hz | 2 ms | 单 engine 接近满足 |
| 1 kHz | 1 ms | 约 2 个 engine |
| 10 kHz | 0.1 ms | 约 15～16 个 engine，并需要 ping-pong capture |

以上是算术量级估算，最终必须包含 BRAM bank、流水填充、峰值归并和采集重叠开销。

### 阶段 5：评估 FFT 脉冲压缩

若需求确实是 8192 点采集、128 lag、每个 10 kHz 脉冲都输出，建议比较频域相关：

```text
FFT(echo) x conj(FFT(reference)) -> IFFT -> 取前128个lag
```

reference 波形固定，其频谱可以预先计算。FFT 方案复杂度从 `O(N x MAX_LAG)` 转向约 `O(N log N)`，通常比复制大量时域相关核更有扩展性，但会引入 FFT IP、块浮点/定点缩放、帧缓存和额外延迟。

## 7. 当前结论

1. BRAM 优化已经解决原始寄存器膨胀和大 MUX 问题，综合证据明确；
2. 六级寄存化已经解决 `reference_mem` 到 `max_score` D/CE 的 setup 时序问题，并通过完整实现时序；
3. 当前最大问题是吞吐，不是 Fmax：约 16.8 ms 处理一帧，约 59 Hz 结果率；
4. 原“56 倍”估算适用于 II=1 单 lane；当前 FSM 实际约为 168 倍；
5. 优先将单核改成真正 II=1，再利用 128 bit BRAM 做 4-lane 计算，最后按目标结果率并行 lag engine；
6. 三乘法复数乘法可节省 25% DSP，但当前 DSP 资源并不紧张，应在并行架构确定后评估；
7. `abs48` 有进一步流水化空间，但当前不是已证实的关键路径，不应先于吞吐和 BRAM 带宽优化；
8. 若要求严格 10 kHz 每脉冲实时，应同时评估 4-lane 多 engine 和 FFT 脉冲压缩两条路线。

## 8. 验证与报告入口

| 内容 | 文件/命令 |
|---|---|
| 核心 RTL | `rtl/lfm_radar_core.v` |
| RTL 仿真 | `scripts/run_rtl_sim.tcl` |
| 独立综合 | `scripts/synth_lfm_core.tcl` |
| max_score D/CE 时序 | `scripts/report_lfm_corr_timing.tcl` |
| 独立核资源 | `output/core_synth/utilization.rpt` |
| 独立核时序 | `output/core_synth/timing.rpt` |
| 完整 routed 时序 | `V11_LFM_RANGE.runs/impl_1/design_1_wrapper_timing_summary_routed.rpt` |
| 工程背景 | `V11_LFM_RANGE_CONTEXT.md` |

