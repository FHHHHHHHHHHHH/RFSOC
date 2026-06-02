# -------------------------------------------------------------------------
# 1. 忽略 VIO 到相位累加器 phase_reg 的跨时钟域路径 (修复图1)
# -------------------------------------------------------------------------
set_false_path -from [get_cells -hierarchical -filter {NAME =~ "*vio_0*Probe_out_reg*"}] -to [get_cells -hierarchical -filter {NAME =~ "*dds_mixer_adapter*phase_reg*"}]

# -------------------------------------------------------------------------
# 2. 忽略 proc_sys_reset_0 到 DDS Adapter 的跨时钟域复位路径 (修复图2)
# 注：更规范的做法是在 BD 中添加同源时钟的复位同步器
# -------------------------------------------------------------------------
set_false_path -from [get_cells -hierarchical -filter {NAME =~ "*proc_sys_reset_0*ACTIVE_LOW_PR_OUT_DFF*"}] -to [get_cells -hierarchical -filter {NAME =~ "*dds_mixer_adapter*"}]


# -------------------------------------------------------------------------
# 原有约束保持不变
# -------------------------------------------------------------------------
set_false_path -from [get_clocks RFDAC1_CLK] -to [get_clocks -of_objects [get_pins {design_1_i/util_ds_buf_1/U0/USE_BUFGCE_DIV2.GEN_BUFGCE_DIV2[0].BUFGCE_DIV2_I/O}]]
set_false_path -from [get_clocks clk_pl_0] -to [get_clocks -of_objects [get_pins {design_1_i/util_ds_buf_1/U0/USE_BUFGCE_DIV2.GEN_BUFGCE_DIV2[0].BUFGCE_DIV2_I/O}]]

set_property C_CLK_INPUT_FREQ_HZ 184320000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets clk]