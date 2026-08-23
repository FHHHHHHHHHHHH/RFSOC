# ECW_SE1100 编码模式参考手册（AI 辅助编程专用）

> **用途**：当编写 Zynq PL（SystemVerilog）或 PS（C/μC-OS）代码时，遇到以下场景，直接参考 ECW_SE1100 中的对应实现模式。
> **原则**：本手册只记录"怎么做"和"在哪里找"，不解释业务逻辑。

---

## 一、PL 端（SystemVerilog / Xilinx FPGA）

### 1. 乒乓缓冲（Ping-Pong Buffer）—— 采集-传输解耦

**适用场景**：ADC 连续采集数据，DMA 间歇搬运到 DDR。写入和读取速度不匹配，需要无数据丢失的缓冲。

**参考文件**：
- `sources_hw/design_sources/sample/sample_packing.sv`（写入/读取仲裁状态机）
- `sources_hw/design_sources/sample/sample_ppbuffer.sv`（单个 buffer 状态机）
- `sources_hw/design_sources/waveform_gen/waveform_gen.sv`（另一种乒乓 buffer 实现）

**核心模式**：三层状态机解耦

```
第1层 state_ppbuffer_w：仲裁写入哪个 buffer（A/B交替）
第2层 state_ppbuffer_r：仲裁读取哪个 buffer（A/B交替）
第3层 state：控制 DMA 传输的启停
```

**关键代码模板**（照抄自 `sample_packing.sv`）：

```systemverilog
// 写入仲裁状态机
localparam S_W_IDLE = 3'd0, S_W_WAITING_A = 3'd1, S_W_CAPTURING_A = 3'd2,
           S_W_WAITING_B = 3'd3, S_W_CAPTURING_B = 3'd4;
logic [2:0] state_ppbuffer_w = S_W_IDLE;

always_ff @(posedge clk)
    if(rst)
        state_ppbuffer_w <= S_W_IDLE;
    else
        case(state_ppbuffer_w)
            S_W_IDLE:       state_ppbuffer_w <= S_W_WAITING_A;
            S_W_WAITING_A:  if(flag_ppbuffer_idle_a)    // 必须等buffer空闲
                                state_ppbuffer_w <= S_W_CAPTURING_A;
            S_W_CAPTURING_A:if(flag_ppbuffer_write_end_a)
                                state_ppbuffer_w <= S_W_WAITING_B;
            S_W_WAITING_B:  if(flag_ppbuffer_idle_b)
                                state_ppbuffer_w <= S_W_CAPTURING_B;
            S_W_CAPTURING_B:if(flag_ppbuffer_write_end_b)
                                state_ppbuffer_w <= S_W_WAITING_A;
            default: state_ppbuffer_w <= state_ppbuffer_w;
        endcase

// 激活信号
assign flag_ppbuffer_activate_a = (state_ppbuffer_w == S_W_CAPTURING_A);
assign flag_ppbuffer_activate_b = (state_ppbuffer_w == S_W_CAPTURING_B);
```

**TODO**：你写代码时，把 `flag_ppbuffer_idle_a` 替换为你 buffer 的空闲标志，`flag_ppbuffer_write_end_a` 替换为写完成标志。

---

### 2. 跨时钟域同步（CDC）—— 单bit/多bit信号

**适用场景**：PL 内部有多个时钟域（如 100MHz 逻辑 ↔ FCLK_CLK0），或 PS GPIO 信号进入 PL 需要同步。

**参考文件**：
- `sources_hw/design_sources/general/shift_register.sv`

**核心模式**：参数化移位寄存器，统一所有 CDC 需求

**模板**（直接复用 `shift_register.sv`）：

```systemverilog
module shift_register #(
    parameter WIDTH = 1,   // 信号位宽
    parameter DEPTH = 1    // 同步级数，建议 2~4
)(
    input  logic                 clk,
    input  logic [WIDTH-1:0] sr_in,
    output logic [WIDTH-1:0] sr_out
);

genvar i;
generate
    for(i = 0; i <= DEPTH-1; i = i+1) begin : SR
        logic [WIDTH-1:0] shift_reg = 0;
        logic [WIDTH-1:0] sr_q;
        assign sr_q = shift_reg;
    end
endgenerate

genvar k;
generate
    for(k = 1; k <= DEPTH-1; k = k+1) begin
        always_ff @(posedge clk)
            SR[k].shift_reg <= SR[k-1].sr_q;
    end
endgenerate

always_ff @(posedge clk)
    SR[0].shift_reg <= sr_in;

assign sr_out = SR[DEPTH-1].sr_q;
endmodule
```

**实例化方式**：

```systemverilog
// 单bit控制信号：DEPTH=3~4
shift_register #(.WIDTH(1), .DEPTH(4)) u_sync_ctrl(
    .clk(target_clk), .sr_in(src_signal), .sr_out(synced_signal));

// 多bit GPIO总线：DEPTH=4
shift_register #(.WIDTH(32), .DEPTH(4)) u_sync_gpio(
    .clk(clk_100m), .sr_in(GPIO_ZYNQ_OUT), .sr_out(gpio_zynq_out_cdc));

// 复位信号：DEPTH=4
shift_register #(.WIDTH(1), .DEPTH(4)) u_sync_rst(
    .clk(FCLK_CLK0), .sr_in(rst_sample), .sr_out(rst_cdc));
```

**注意**：多bit 总线 CDC 仅适用于"数据变化慢于目标时钟 2 倍"或"配合 valid 信号握手"的场景。高速连续数据流请用异步 FIFO。

---

### 3. 上升沿检测（可配置去抖）

**适用场景**：检测控制信号的上升沿，并产生单周期脉冲。需要抗毛刺能力。

**参考文件**：
- `sources_hw/design_sources/general/posedge_detect.sv`

**模板**：

```systemverilog
module posedge_detect #(
    parameter INIT  = 1'b0,   // 初始值
    parameter STAGE = 1       // 需要连续几个周期为高才判定为上升沿
)(
    input  logic clk,
    input  logic i_sig,
    output logic o_pulse
);

logic [2*STAGE-1:0] sig_reg = {(2*STAGE){INIT}};

always_ff @(posedge clk)
    sig_reg[0] <= i_sig;

genvar i;
generate
    for(i = 1; i < 2*STAGE; i = i+1) begin
        always_ff @(posedge clk)
            sig_reg[i] <= sig_reg[i-1];
    end
endgenerate

logic pulse_reg = 0;
always_ff @(posedge clk)
    if(sig_reg == {{STAGE{1'b0}}, {STAGE{1'b1}}})
        pulse_reg <= 1;
    else
        pulse_reg <= 0;

assign o_pulse = pulse_reg;
endmodule
```

**实例化**：
```systemverilog
// 快速响应（无去抖）
posedge_detect #(.STAGE(1)) u_detect(.clk(clk), .i_sig(sig), .o_pulse(pulse));

// 带 3 周期去抖
posedge_detect #(.STAGE(3)) u_detect(.clk(clk), .i_sig(sig), .o_pulse(pulse));
```

---

### 4. ADC 高速串行数据接收（LVDS → 并行）

**适用场景**：AD7626 等高速 SAR ADC，LVDS 接口，DCO 时钟伴随数据。

**参考文件**：
- `sources_hw/design_sources/interface/ad7626_control.sv`（顶层：原语 + 脉冲展宽）
- `sources_hw/design_sources/interface/ad7626_driver.sv`（驱动：串并转换 + 时序控制）

**核心模式**：

```
ad7626_control.sv:    IBUFGDS/IBUFDS → BUFR → ad7626_driver → 脉冲展宽CDC
ad7626_driver.sv:     300MHz域计数器 → CNV时序 → DCO边沿捕获 → 串并转换
```

**关键技巧 1 — 脉冲展宽跨时钟域**（`ad7626_control.sv`）：

```systemverilog
// 300MHz 域的 1-cycle 脉冲展宽到 3 cycles，确保 100MHz 域能采样到
localparam STRETCH_WIDTH = 3;
logic adc_data_tvalid_300m_stretch = 0;
logic [1:0] cnt_stretch = STRETCH_WIDTH-1;

always_ff @(posedge clk_300m)
    if(adc_data_tvalid_300m) begin
        adc_data_tvalid_300m_stretch <= 1;
        cnt_stretch <= 0;
    end
    else if(cnt_stretch < STRETCH_WIDTH-1) begin
        adc_data_tvalid_300m_stretch <= 1;
        cnt_stretch <= cnt_stretch + 1;
    end
    else begin
        adc_data_tvalid_300m_stretch <= 0;
        cnt_stretch <= cnt_stretch;
    end

// 100MHz 域采样
always_ff @(posedge clk_100m)
    if(adc_data_tvalid_300m_stretch) begin
        adc_data_tvalid_100m <= 1;
        adc_data_100m <= adc_data_300m;
    end
    else begin
        adc_data_tvalid_100m <= 0;
        adc_data_100m <= adc_data_100m;
    end
```

**关键技巧 2 — DCO 边沿捕获串并转换**（`ad7626_driver.sv`）：

```systemverilog
// 直接用 DCO 时钟捕获数据（DCO 来自 ADC，与数据同步）
logic [15:0] adc_data_shift = 0;
always_ff @(posedge adc_dco)
    adc_data_shift <= {adc_data_shift[14:0], adc_d};

// 在 300MHz 域计数器末尾锁存并行数据
always_ff @(posedge clk_300m)
    if(cnt == 5'd29) begin
        adc_data <= adc_data_shift;
        adc_data_tvalid <= 1;
    end
    else begin
        adc_data <= adc_data;
        adc_data_tvalid <= 0;
    end
```

**IBUFGDS/IBUFDS 原语模板**：

```systemverilog
IBUFGDS #(.DIFF_TERM("TRUE")) u_ibufgds_dco (
    .I  (PIN_ADC_DCO_P), .IB (PIN_ADC_DCO_N), .O  (dco_ibufgds));
BUFR u_bufr_dco (
    .I  (dco_ibufgds), .O  (dco_bufr), .CE (1'b1), .CLR(1'b0));
IBUFDS #(.DIFF_TERM("TRUE")) u_ibufds_d (
    .I  (PIN_ADC_D_P), .IB (PIN_ADC_D_N), .O  (d_ibufgds));
OBUFDS u_obufds_clk(
    .I  (adc_clk_oddr), .O  (PIN_ADC_CLK_P), .OB (PIN_ADC_CLK_N));
```

---

### 5. AXI Stream DMA 数据发送（S2MM / MM2S）

**适用场景**：PL 通过 AXI Stream 接口向 PS 的 DMA 发送数据（S2MM），或从 DMA 接收数据（MM2S）。

**参考文件**：
- `sources_hw/design_sources/sample/sample_transfer.sv`（S2MM 发送）
- `sources_hw/design_sources/waveform_gen/waveform_gen.sv`（MM2S 接收 + 乒乓）

**S2MM 发送模板**（照抄 `sample_transfer.sv`）：

```systemverilog
// 状态机
localparam S_IDLE = 2'd0, S_INTR = 2'd1, S_READING = 2'd2, S_FINISH = 2'd3;
logic [1:0] state = S_IDLE;

always_ff @(posedge FCLK_CLK0)
    if(rst_ps)
        state <= S_IDLE;
    else
        case(state)
            S_IDLE:    if(intr_ppbuffer)               // buffer准备好
                           state <= S_INTR;
            S_INTR:    if(S_AXIS_S2MM_SAMPLE_tready)   // DMA准备好
                           state <= S_READING;
            S_READING: if(~intr_ppbuffer)              // 传输完成
                           state <= S_FINISH;
            S_FINISH:      state <= S_IDLE;
        endcase

// 发送中断（IRQ_F2P）
always_ff @(posedge FCLK_CLK0)
    if(rst_ps | intr_clear_sample_ps)
        IRQ_SAMPLE <= 0;
    else
        case(state)
            S_IDLE: if(intr_ppbuffer) IRQ_SAMPLE <= 1;
            default: IRQ_SAMPLE <= IRQ_SAMPLE;
        endcase

// 读取计数
logic [PP_ADDR_W-1:0] cnt_read = 0;
always_ff @(posedge FCLK_CLK0)
    if(rst_ps) cnt_read <= 0;
    else case(state)
        S_READING: if(S_AXIS_S2MM_SAMPLE_tready & (~(cnt_read == transfer_depth)))
                        cnt_read <= cnt_read + 1;
        default: cnt_read <= 0;
    endcase

// tvalid, tlast 控制
always_ff @(posedge FCLK_CLK0)
    if(rst_ps) S_AXIS_S2MM_SAMPLE_tvalid <= 0;
    else case(state)
        S_READING: S_AXIS_S2MM_SAMPLE_tvalid <= 1;
        default:   S_AXIS_S2MM_SAMPLE_tvalid <= 0;
    endcase

always_ff @(posedge FCLK_CLK0)
    if(rst_ps) S_AXIS_S2MM_SAMPLE_tlast <= 0;
    else case(state)
        S_READING: if(S_AXIS_S2MM_SAMPLE_tready & (cnt_read == transfer_depth))
                        S_AXIS_S2MM_SAMPLE_tlast <= 1;
        default: S_AXIS_S2MM_SAMPLE_tlast <= 0;
    endcase

// tready 反压处理：tready=0 时保持上一个数据
logic [31:0] ppbuffer_dout_hold = 0;
logic S_AXIS_S2MM_SAMPLE_tready_delay = 0;
always_ff @(posedge FCLK_CLK0)
    if(rst_ps)
        S_AXIS_S2MM_SAMPLE_tready_delay <= 0;
    else
        S_AXIS_S2MM_SAMPLE_tready_delay <= S_AXIS_S2MM_SAMPLE_tready;

always_ff @(posedge FCLK_CLK0)
    if(rst_ps)
        ppbuffer_dout_hold <= 0;
    else if({S_AXIS_S2MM_SAMPLE_tready, S_AXIS_S2MM_SAMPLE_tready_delay} == 2'b01)
        ppbuffer_dout_hold <= ppbuffer_dout;  // tready下降沿保存当前数据

always_comb
    if({S_AXIS_S2MM_SAMPLE_tready, S_AXIS_S2MM_SAMPLE_tready_delay} == 2'b11)
        S_AXIS_S2MM_SAMPLE_tdata = ppbuffer_dout;
    else
        S_AXIS_S2MM_SAMPLE_tdata = ppbuffer_dout_hold;

assign S_AXIS_S2MM_SAMPLE_tkeep = 4'b1111;
```

**MM2S 接收模板**（照抄 `waveform_gen.sv`）：

```systemverilog
// tready 控制：仅在写入buffer时拉高
always_ff @(posedge FCLK_CLK0)
    if(rst_ps) begin
        ppbuffer_a_wea <= 0; ppbuffer_b_wea <= 0;
    end else begin
        ppbuffer_a_wea <= (state_ppbuffer_w == S_W_CAPTURING_A) && (~M_AXIS_MM2S_WAVE_tlast);
        ppbuffer_b_wea <= (state_ppbuffer_w == S_W_CAPTURING_B) && (~M_AXIS_MM2S_WAVE_tlast);
    end

assign M_AXIS_MM2S_WAVE_tready = ppbuffer_a_wea | ppbuffer_b_wea;
```

---

### 6. PS-PL BRAM 寄存器接口（AXI BRAM → 寄存器映射）

**适用场景**：PS 通过 AXI BRAM Controller 读写 PL 中的寄存器（控制和状态）。

**参考文件**：
- `sources_hw/design_sources/interface/bram/bram_polling_control.sv`
- `sources_hw/design_sources/interface/bram/bram_read_ctrl.sv`
- `sources_hw/design_sources/interface/bram/bram_write_ctrl.sv`
- `sources_hw/design_sources/interface/user_interface.sv`（`blk_mem_bus` interface 定义）
- `sources_hw/design_sources/interface/pspl_connect_define.vh`（寄存器地址映射）

**核心模式**：定义一个 SystemVerilog `interface` 封装 BRAM 总线，PL 端用轮询计数器将 BRAM 地址映射到 `logic [31:0] reg_array[63:0]`。

**`blk_mem_bus` interface 定义**（`user_interface.sv`）：

```systemverilog
interface blk_mem_bus;
    logic [31:0] addr;
    logic        clk;
    logic [31:0] din;
    logic [31:0] dout;
    logic        en;
    logic        rst;
    logic        rst_busy;
    logic [3:0]  we;

    modport master(
        input  rst_busy, dout,
        output clk, en, rst, addr, din, we
    );

    modport slave(
        input  clk, en, rst, addr, din, we,
        output rst_busy, dout
    );
endinterface
```

**寄存器映射定义**（`pspl_connect_define.vh`）：

```systemverilog
// PS → PL 控制寄存器（ZYNQ OUT）
localparam BRAM_OUT0_ADDR = 0;
wire [1:0]  sample_mode        = bram_zynq_out0[BRAM_OUT0_ADDR+4][1:0];
wire [7:0]  sample_i_range     = bram_zynq_out0[BRAM_OUT0_ADDR+4][15:8];
wire [12:0] sample_num         = bram_zynq_out0[BRAM_OUT0_ADDR+5][12:0];
wire [13:0] transfer_depth     = bram_zynq_out0[BRAM_OUT0_ADDR+5][29:16];

// PL → PS 状态寄存器（ZYNQ IN）
localparam BRAM_IN0_ADDR = 0;
assign bram_zynq_in0[BRAM_IN0_ADDR+2][31:0] = $signed(adc_data_e_block);
assign bram_zynq_in0[BRAM_IN0_ADDR+63][11:0] = pl_version;
```

**TODO**：你写代码时，只需修改 `pspl_connect_define.vh` 中的地址偏移和位域定义。

---

### 7. PS 端 GPIO 控制（脉冲信号生成）

**适用场景**：PS 通过 GPIO 向 PL 发送脉冲控制信号（如触发、复位、中断清除）。

**参考文件**：
- `sources_hw/design_sources/interface/pspl_connect_define.vh`（GPIO 位定义）
- PS 端：`system_control.c`、`data_acquisition_control.c`

**PS 端脉冲生成模板**：

```c
// 写 1 再写 0 产生一个上升沿脉冲
void system_ctrl_trigger_bram(void) {
   gpiopl_control_bit_write(GPIO_CONTROL_TRIG_BRAM_UPDATE, 1);
   gpiopl_control_bit_write(GPIO_CONTROL_TRIG_BRAM_UPDATE, 0);
}

void daq_control_waveform_start_set(void) {
    gpiopl_control_bit_write(GPIO_CONTROL_WAVE_START, 1);
    gpiopl_control_bit_write(GPIO_CONTROL_WAVE_START, 0);
}
```

**PL 端 GPIO 位定义模板**（`pspl_connect_define.vh`）：

```systemverilog
// 注意：GPIO 从 PS 来，PL 端需要 CDC 同步
wire rst_mmcm0      = gpio_zynq_out_cdc[0];   // bit0: MMCM复位
wire trig_bram_update = gpio_zynq_out_cdc[3];  // bit3: BRAM更新触发
wire wave_start     = gpio_zynq_out_cdc[8];   // bit8: 波形开始
wire wave_pause     = gpio_zynq_out_cdc[9];   // bit9: 波形暂停
wire wave_abort     = gpio_zynq_out_cdc[10];  // bit10: 波形中止
```

---

### 8. AXI Stream 接口的 tready 反压处理

**适用场景**：AXI Stream 从设备需要正确处理 tready=0 的反压情况，不能丢失数据。

**参考文件**：
- `sources_hw/design_sources/sample/sample_transfer.sv`（tready 下降沿数据保持）

**模板**：

```systemverilog
// 方案：检测 tready 下降沿，保存当前数据
logic [31:0] data_hold = 0;
logic        tready_delay = 0;

always_ff @(posedge clk)
    if(rst) tready_delay <= 0;
    else    tready_delay <= tready;

always_ff @(posedge clk)
    if(rst) data_hold <= 0;
    else if({tready, tready_delay} == 2'b01)  // 下降沿
        data_hold <= data_in;

always_comb
    if({tready, tready_delay} == 2'b11)        // 连续ready
        tdata = data_in;
    else
        tdata = data_hold;                     // 使用hold值
```

---

### 9. 帧头同步字设计（自描述数据帧）

**适用场景**：DMA 传输的数据帧需要帧边界检测和错误恢复能力。

**参考文件**：
- `sources_hw/design_sources/sample/sample_ppbuffer.sv`（帧头写入逻辑）

**模板**：

```systemverilog
// 帧头定义（16 字节）
S_WRITE_FRAME_H1 :  ppbuffer_din <= 32'h5AA5_AA55;  // 同步字
S_WRITE_FRAME_H2 :  ppbuffer_din <= {16'h0000, frame_length};  // 帧长
S_WRITE_FRAME_H3 :  ppbuffer_din <= {version, mode, config};   // 参数
S_WRITE_FRAME_H4 :  ppbuffer_din <= {16'h0401, 16'h0000};      // 保留

// 帧体：按采样点依次写入
S_WRITE_AWG   :  ppbuffer_din <= {12'd0, overload_flags, awg_data};
S_WRITE_IADC  :  ppbuffer_din <= {adc_i_data, 13'd0};
S_WRITE_EADC  :  ppbuffer_din <= {adc_e_data, 13'd0};
```

**PS 端帧同步恢复模板**：

```c
// 搜索 0x5AA5AA55 同步字来定位帧头
#define SYNC_WORD 0x5AA5AA55
u32 find_frame_header(u32 *buf, u32 buf_len) {
    for(u32 i = 0; i < buf_len - 4; i++) {
        if(buf[i] == SYNC_WORD) {
            u32 frame_len = (buf[i+2] & 0x0000FFFF);
            return i;  // 返回帧头偏移
        }
    }
    return 0xFFFFFFFF;  // 未找到
}
```

---

### 10. 时钟与复位管理

**适用场景**：Zynq PL 端需要多时钟域，需要统一的复位策略。

**参考文件**：
- `sources_hw/design_sources/ECW_top.sv`（时钟和复位顶层）

**模板**：

```systemverilog
// 时钟：差分输入 → IBUFGDS → MMCM
wire ibufgds_glblclk;
IBUFGDS u_ibuf_glblclk(
    .I (PIN_CLK_FPGA_GLBCLK_P), .IB(PIN_CLK_FPGA_GLBCLK_N), .O(ibufgds_glblclk));

wire clk_100m, clk_300m, locked_mmcm0;
clk_wiz_mmcm0 u_clk_wiz_mmcm0(
    .clk_in1(ibufgds_glblclk), .reset(1'b0),
    .clk_out1(clk_100m), .clk_out2(clk_300m), .locked(locked_mmcm0));

// 复位：MMCM locked 取反 = 全局复位
wire rst;
assign rst = ~locked_mmcm0;

// PS 端复位通过 CDC 传入
wire rst_ps;
shift_register #(.WIDTH(1), .DEPTH(4)) u_sync_rst(
    .clk(FCLK_CLK0), .sr_in(rst_sample), .sr_out(rst_cdc));
assign rst_ps = rst_cdc | (~FCLK_RESET0_N);
```

---

## 二、PS 端（C / μC-OS / Xilinx SDK）

### 11. 中断链式 DMA 传输（IRQ → DMA → IRQ 循环）

**适用场景**：PL 产生数据就绪中断，PS 启动 DMA，DMA 完成后重新使能中断，形成链式自动传输。

**参考文件**：
- `ECW_SE1100_ucos/src/main/system_interrupt.c`
- `ECW_SE1100_ucos/src/control/data_acquisition/data_acquisition_control.c`

**核心模式**：

```
PL IRQ → PS handler: 关中断 → 清PL标志 → 启动DMA → 返回
DMA完成 → PS handler: 计数+1 → 如果未完成，重开PL中断
```

**中断初始化模板**（`system_interrupt.c`）：

```c
void system_interrupt_init(void) {
    UCOS_IntSrcDis (IRQ_F2P_SAMPLE_ID);
    UCOS_IntTypeSet(IRQ_F2P_SAMPLE_ID, UCOS_INT_TYPE_EDGE);  // 边沿触发
    UCOS_IntVectSet(IRQ_F2P_SAMPLE_ID,
                    IRQ_F2P_SAMPLE_PRIO,
                    0u,
                    (UCOS_INT_FNCT_PTR)interrupt_sample_handler,
                    &Axidma_Inst);

    // DMA 完成中断
    UCOS_IntSrcDis (IRQ_F2P_SAMPLE_DMA_RX_ID);
    UCOS_IntTypeSet(IRQ_F2P_SAMPLE_DMA_RX_ID, UCOS_INT_TYPE_EDGE);
    UCOS_IntVectSet(IRQ_F2P_SAMPLE_DMA_RX_ID,
                    IRQ_F2P_SAMPLE_DMA_RX_PRIO,
                    0u,
                    (UCOS_INT_FNCT_PTR)interrupt_sample_dma_rx_handler,
                    &Axidma_Inst);
}
```

**中断处理模板**（两个 handler 配合）：

```c
// PL 中断 → 启动 DMA
void interrupt_sample_handler(void *callback) {
    XAxiDma *axidma = (XAxiDma *)callback;
    UCOS_IntSrcDis(IRQ_F2P_SAMPLE_ID);  // 1. 先关中断，防止重入

    // 2. 清PL中断标志（脉冲方式）
    gpiopl_control_bit_write(GPIO_CONTROL_INTR_CLEAR_SAMPLE, 1);
    gpiopl_control_bit_write(GPIO_CONTROL_INTR_CLEAR_SAMPLE, 0);

    // 3. 启动DMA
    if(DAQ_Control_Inst.sample_count < DAQ_Control_Inst.waveform_point_num) {
        u8 *addr = (u8*)((u32)Transfer_Buffer +
                    DAQ_Transfer_Inst.frame_write_count * DAQ_Transfer_Inst.frame_length);
        u32 len  = DAQ_Transfer_Inst.frame_length;
        XAxiDma_SimpleTransfer(axidma, (u32)addr, len, XAXIDMA_DEVICE_TO_DMA);
    }
}

// DMA 完成中断 → 重开 PL 中断
void interrupt_sample_dma_rx_handler(void *callback) {
    XAxiDma *axidma = (XAxiDma *)callback;
    u32 irq_status = XAxiDma_IntrGetIrq(axidma, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_IntrAckIrq(axidma, irq_status, XAXIDMA_DEVICE_TO_DMA);

    if(!(irq_status & XAXIDMA_IRQ_ALL_MASK)) return;

    if(irq_status & XAXIDMA_IRQ_ERROR_MASK) {
        axidma_error = 1;
        XAxiDma_Reset(axidma);
        int timeout = RESET_TIMEOUT_COUNTER;
        while(timeout) {
            if(XAxiDma_ResetIsDone(axidma)) break;
            timeout--;
        }
        return;
    }

    if(irq_status & XAXIDMA_IRQ_IOC_MASK) {
        DAQ_Control_Inst.sample_count += DAQ_Control_Inst.sample_num;
        DAQ_Transfer_Inst.frame_write_count += 1;

        if(DAQ_Control_Inst.sample_count < DAQ_Control_Inst.waveform_point_num)
            UCOS_IntSrcEn(IRQ_F2P_SAMPLE_ID);  // 4. 重开中断，形成链
        else
            DAQ_Control_Inst.flag_sample_end = TRUE;
    }
}
```

**中断使能/禁用**（`data_acquisition_control.c`）：

```c
void daq_control_interrupt_enable(void) {
    UCOS_IntSrcEn(IRQ_F2P_SAMPLE_DMA_RX_ID);  // DMA RX 中断
    XAxiDma_IntrEnable(&Axidma_Inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
    UCOS_IntSrcEn(IRQ_F2P_SAMPLE_ID);         // PL 采样中断

    UCOS_IntSrcEn(IRQ_F2P_WAVE_DMA_TX_ID);    // DMA TX 中断
    XAxiDma_IntrEnable(&Axidma_Inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    UCOS_IntSrcEn(IRQ_F2P_WAVE_ID);           // PL 波形中断
}

void daq_control_interrupt_disable(void) {
    UCOS_IntSrcDis(IRQ_F2P_WAVE_ID);
    UCOS_IntSrcDis(IRQ_F2P_WAVE_DMA_TX_ID);
    XAxiDma_IntrDisable(&Axidma_Inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    UCOS_IntSrcDis(IRQ_F2P_SAMPLE_ID);
    UCOS_IntSrcDis(IRQ_F2P_SAMPLE_DMA_RX_ID);
    XAxiDma_IntrDisable(&Axidma_Inst, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
}
```

---

### 12. BRAM 寄存器读写（PS 端驱动层）

**适用场景**：PS 通过 AXI BRAM 读写 PL 中的控制/状态寄存器。

**参考文件**：
- `ECW_SE1100_ucos/src/driver/bram/bram_interface.h`
- `ECW_SE1100_ucos/src/driver/bram/bram_interface.c`
- `ECW_SE1100_ucos/src/driver/bram/bram_parameters.h`

**完整模板**：

```c
// ===== bram_parameters.h: 寄存器地址和位域定义 =====
#define BRAM_ZYNQ_IN0_BASEADDR     XPAR_BRAM_0_BASEADDR
#define BRAM_ZYNQ_OUT0_BASEADDR    XPAR_BRAM_1_BASEADDR

// 控制寄存器地址（字节偏移）
#define FPGA_CONTROL_REG4_ADDR     (uint32_t)16
    #define SAMPLE_MODE_ADDR         (uint32_t)0
    #define SAMPLE_MODE_MASK         (uint32_t)0x00000003
#define FPGA_CONTROL_REG5_ADDR     (uint32_t)20
    #define SAMPLE_NUM_ADDR          (uint32_t)0
    #define SAMPLE_NUM_MASK          (uint32_t)0x00001FFF

// 状态寄存器地址
#define FPGA_STATUS_REG63_ADDR     (uint32_t)252
    #define PL_VERSION_NUMBER_ADDR   (uint32_t)0
    #define PL_VERSION_NUMBER_MASK   (uint32_t)0x00000FFF

// ===== bram_interface.h: 宏封装 =====
#define BRAM_CTRLBIT_SAMPLE_MODE   FPGA_CONTROL_REG4_ADDR, SAMPLE_MODE_ADDR, SAMPLE_MODE_MASK
#define BRAM_CTRLBIT_SAMPLE_NUM    FPGA_CONTROL_REG5_ADDR, SAMPLE_NUM_ADDR, SAMPLE_NUM_MASK
#define BRAM_CTRLREG_WAVE_INTERVAL FPGA_CONTROL_REG6_ADDR

// ===== bram_interface.c: 函数实现 =====

// 读状态寄存器（位域）
uint32_t bram_reg_status_read(uint32_t addr_offset, uint32_t bits_addr, uint32_t bits_mask) {
    uint32_t status_reg = Xil_In32(BRAM_ZYNQ_IN0_BASEADDR + addr_offset);
    return ((status_reg & bits_mask) >> bits_addr);
}

// 读完整 32bit
uint32_t bram_reg_read(uint32_t addr) {
    return Xil_In32(BRAM_ZYNQ_IN0_BASEADDR + addr);
}

// 读 64bit（两寄存器拼接）
uint64_t bram_reg_read_u64(uint32_t addr) {
    uint32_t addr_offset = 4;
    uint64_t data_low  = (u64)(Xil_In32(BRAM_ZYNQ_IN0_BASEADDR + addr)) & 0x00000000FFFFFFFF;
    uint64_t data_high = ((u64)(Xil_In32(BRAM_ZYNQ_IN0_BASEADDR + addr + addr_offset)) << 32)
                         & 0xFFFFFFFF00000000;
    return data_low + data_high;
}

// 写控制寄存器（位域，读-修改-写）
void bram_reg_control_write(uint32_t addr_offset, uint32_t bits_addr,
                             uint32_t bits_mask, uint32_t bits) {
    uint32_t orig_data = Xil_In32(BRAM_ZYNQ_OUT0_BASEADDR + addr_offset);
    orig_data &= ~(bits_mask);
    bits     <<= bits_addr;
    bits      &= bits_mask;
    bits      |= orig_data;
    Xil_Out32(BRAM_ZYNQ_OUT0_BASEADDR + addr_offset, bits);
}

// 写完整 32bit
void bram_reg_write(uint32_t addr, uint32_t data) {
    Xil_Out32(BRAM_ZYNQ_OUT0_BASEADDR + addr, data);
}

// 写 64bit
void bram_reg_write_u64(uint32_t addr, uint64_t data) {
    uint32_t addr_offset = 4;
    Xil_Out32(BRAM_ZYNQ_OUT0_BASEADDR + addr, (u32)(data & 0x00000000FFFFFFFF));
    Xil_Out32(BRAM_ZYNQ_OUT0_BASEADDR + addr + addr_offset,
              (u32)((data & 0xFFFFFFFF00000000) >> 32));
}

// ===== 调用示例 =====
// 读 PL 版本号
u32 version = bram_reg_status_read(BRAM_STATBIT_PL_VERSION_NUMBER);

// 写采样模式
bram_reg_control_write(BRAM_CTRLBIT_SAMPLE_MODE, 0x2);

// 写 64bit 采样间隔
bram_reg_write_u64(BRAM_CTRLREG_WAVE_INTERVAL, 100ULL);
```

---

### 13. DMA 缓冲区管理（静态分配 + Cache 一致性）

**适用场景**：DMA 传输的大缓冲区需要静态分配，且需要处理 Data Cache 一致性问题。

**参考文件**：
- `ECW_SE1100_ucos/src/control/data_acquisition/data_acquisition_control.h`
- `ECW_SE1100_ucos/src/control/data_acquisition/data_acquisition_control.c`

**模板**：

```c
// ===== 头文件：缓冲区定义 =====
#define WAVEFORM_BUFFER_LENGTH   0x00100000  // 2MB = 1Mpt
#define TRANSFER_BUFFER_LENGTH   0x01000000  // 64MB，可容纳1024帧

// 全局静态变量，编译时固定地址
volatile s16 Waveform_Buffer[WAVEFORM_BUFFER_LENGTH];
volatile u32 Transfer_Buffer[TRANSFER_BUFFER_LENGTH];

// DMA 传输结构体
typedef struct {
    u32 frame_num;              // 总帧数
    u32 frame_length;           // 每帧字节数
    volatile u32 frame_write_count;   // 写入计数（中断中递增）
    volatile u32 frame_read_count;    // 读取计数（发送后递增）
    bool transfer_buffer_error;      // 溢出标志
} daq_transfer_param;

// ===== Cache 一致性处理 =====
// 发送数据前 Invalidate DCache
s32 daq_transfer_inwaiting_frame(void) {
    s32 inwaiting = frame_write_count - frame_read_count;
    if(inwaiting > 0) {
        u32 transfer_num  = inwaiting * frame_length;
        u8 *transfer_addr = (u8*)((u32)Transfer_Buffer + frame_read_count * frame_length);
        Xil_DCacheInvalidateRange((u32)transfer_addr, transfer_num);  // 关键！
        communication_send(transfer_addr, transfer_num);
        frame_read_count += inwaiting;
    }
    return 0;
}
```

---

### 14. 参数化配置表（采样间隔 → 帧参数映射）

**适用场景**：根据用户设定的采样率/间隔，自动选择合适的帧大小和传输深度。

**参考文件**：
- `ECW_SE1100_ucos/src/control/data_acquisition/data_acquisition_control.c`（`daq_control_param_set` 函数）

**模板**：

```c
s32 daq_control_param_set(u64 real_sample_interval, u64 total_point_num) {
    u32 sample_num, transfer_depth;

    if(real_sample_interval <= 10)       { sample_num = 5000; transfer_depth = 16384; }
    else if(real_sample_interval <= 100) { sample_num = 500;  transfer_depth = 2048;  }
    else if(real_sample_interval <= 1000){ sample_num = 50;   transfer_depth = 256;   }
    else if(real_sample_interval <= 10000){ sample_num = 5;   transfer_depth = 32;    }
    else                                 { sample_num = 1;    transfer_depth = 16;    }

    // 写入 PL 寄存器
    bram_reg_write_u64(BRAM_CTRLREG_WAVE_INTERVAL, real_sample_interval);
    bram_reg_control_write(BRAM_CTRLBIT_SAMPLE_NUM, sample_num);
    bram_reg_control_write(BRAM_CTRLBIT_TRANSFER_DEPTH, transfer_depth - 1);

    // 计算帧数 = ceil(total_point_num / sample_num)
    u32 frame_num = (total_point_num + sample_num - 1) / sample_num;
    // ...
}
```

---

### 15. 枚举列表宏（X-Macro 模式）

**适用场景**：需要同时维护枚举值、数值和字符串描述的映射表。

**参考文件**：
- `ECW_SE1100_ucos/src/control/technique/hardware_settings_enum_list.h`

**模板**：

```c
// 定义列表（在头文件中）
#define PST_MODE_OPTION_LIST \
    X(POTENTIOSTAT,  0, "POT")    \
    X(GALVANOSTAT,   1, "GAL")    \
    X(OCP,           2, "OCP")    \
    X(EIS,           3, "EIS")

// 生成枚举（在 .c 文件中）
enum {
#define X(def, val, str) PST_##def = val,
    PST_MODE_OPTION_LIST
#undef X
};

// 生成字符串查找表（在需要的地方）
const char* pst_mode_str[] = {
#define X(def, val, str) [val] = str,
    PST_MODE_OPTION_LIST
#undef X
};
```

---

### 16. 数据采集复位/初始化流程

**适用场景**：每次测试开始前，需要完整复位 PL 的采样/波形模块和 DMA。

**参考文件**：
- `ECW_SE1100_ucos/src/control/data_acquisition/data_acquisition_control.c`

**模板**：

```c
s32 daq_control_sample_reset(void) {
    // 1. 复位波形发生模块（脉冲方式）
    daq_control_waveform_abort_set();

    // 2. 复位数据采样模块
    gpiopl_control_bit_write(GPIO_CONTROL_RST_SAMPLE, 1);
    gpiopl_control_bit_write(GPIO_CONTROL_RST_SAMPLE, 0);

    // 3. 复位 DMA
    XAxiDma_Reset(&Axidma_Inst);
    while(XAxiDma_ResetIsDone(&Axidma_Inst) == 0);

    return 0;
}

s32 daq_transfer_reset(void) {
    DAQ_Transfer_Inst.frame_write_count = 0;
    DAQ_Transfer_Inst.frame_read_count  = 0;
    DAQ_Transfer_Inst.transfer_buffer_error = FALSE;
    return 0;
}
```

---

## 三、快速查找索引

| 你在找什么 | 去哪里看 |
|-----------|---------|
| 乒乓缓冲 | `sample/sample_packing.sv` |
| 单个 buffer 状态机 | `sample/sample_ppbuffer.sv` |
| AXI Stream S2MM 发送 | `sample/sample_transfer.sv` |
| AXI Stream MM2S 接收 | `waveform_gen/waveform_gen.sv` |
| CDC 同步器 | `general/shift_register.sv` |
| 上升沿检测 | `general/posedge_detect.sv` |
| ADC 驱动 (AD7626) | `interface/ad7626_control.sv`, `ad7626_driver.sv` |
| DAC 驱动 (DAC8811) | `interface/dac8811_driver.sv` |
| DAC 驱动 (AD9707) | `interface/ad9707_driver.sv` |
| BRAM 寄存器接口 (PL) | `interface/bram/bram_polling_control.sv`, `bram_read_ctrl.sv` |
| BRAM 寄存器接口 (PS) | `driver/bram/bram_interface.c`, `bram_parameters.h` |
| GPIO 控制 (PS→PL) | `interface/pspl_connect_define.vh` |
| 中断处理 (PS) | `main/system_interrupt.c` |
| DMA 初始化/控制 (PS) | `control/data_acquisition/data_acquisition_control.c` |
| 解调器 (DDS+PSD) | `demodulator/demodulator.sv`, `psd.sv` |
| IIR 滤波器 | `demodulator/iir_filter_shift.sv` |
| 采样平均滤波器 | `sample/sample_average_filter.sv` |
| 过载检测 | `sample/sample_ovld_detecter.sv` |
| 波形发生器 | `waveform_generator/` |
| Zynq PS 封装 | `interface/zynq_wrapper.sv` |
| 顶层 | `ECW_top.sv` |
| 约束文件 | `constraints/ECW_pins.xdc`, `ECW_timming.xdc` |

---

> **版本**：基于 ECW_SE1100 代码库（2024-2025）提取。新增模式时请更新此文档。