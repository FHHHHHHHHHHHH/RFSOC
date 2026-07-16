# -------------------------------------------------------------------------
# 1. 忽略 VIO 到 相位累加器 以及 幅度控制模块 的跨时钟域路径 (修复新引入的时序错误)
# -------------------------------------------------------------------------
# 1. 全局忽略 VIO 调试信号的跨时钟域路径（动态相位、动态幅度因子等）
set_false_path -from [get_cells -hierarchical -filter {NAME =~ "*Probe_out_reg*"}]


# -------------------------------------------------------------------------
# 2. 忽略 proc_sys_reset_0 到 DDS Adapter 的跨时钟域复位路径
# 注：如果你已经按照上一步提示在 BD 里加了专用的复位同步器，此条约束会自动失效或可删去
# -------------------------------------------------------------------------
#set_false_path -from [get_cells -hierarchical -filter {NAME =~ "*proc_sys_reset_0*ACTIVE_LOW_PR_OUT_DFF*"}] -to [get_cells -hierarchical -filter {NAME =~ "*dds_mixer_adapter*"}]


# -------------------------------------------------------------------------
# 原有约束保持不变
# -------------------------------------------------------------------------
set_false_path -from [get_clocks RFDAC1_CLK] -to [get_clocks -of_objects [get_pins {design_1_i/util_ds_buf_1/U0/USE_BUFGCE_DIV2.GEN_BUFGCE_DIV2[0].BUFGCE_DIV2_I/O}]]
set_false_path -from [get_clocks clk_pl_0] -to [get_clocks -of_objects [get_pins {design_1_i/util_ds_buf_1/U0/USE_BUFGCE_DIV2.GEN_BUFGCE_DIV2[0].BUFGCE_DIV2_I/O}]]

set_property C_CLK_INPUT_FREQ_HZ 184320000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets clk]