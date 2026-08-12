set script_dir [file dirname [file normalize [info script]]]
set v11_root   [file normalize [file join $script_dir ..]]
set project    [file join $v11_root V11_LFM_RANGE.xpr]
set rtl_dir    [file join $v11_root rtl]
set mem_dir    [file join $v11_root mem]
set repo_root  [file normalize [file join $v11_root ..]]
set v10_bd     [file join $repo_root V10_DPSK V10_DPSK.srcs sources_1 bd design_1 design_1.bd]
set v10_xdc    [file join $repo_root V10_DPSK V10_DPSK.srcs constrs_1 imports new top.xdc]

create_project -force V11_LFM_RANGE $v11_root -part xczu28dr-ffvg1517-2-e
set_property board_part xilinx.com:zcu111:part0:1.4 [current_project]
set_property board_part_repo_paths {E:/Xilinx/Vivado/2020.2/data/boards/board_files} [current_project]

# Import only the verified V10 board design and constraints. Generated V10
# run/cache metadata is deliberately not copied into the independent project.
add_files -fileset sources_1 -norecurse $v10_bd
import_files -force -fileset sources_1 [get_files design_1.bd]
add_files -fileset constrs_1 -norecurse $v10_xdc
import_files -force -fileset constrs_1 [get_files top.xdc]
add_files -fileset sources_1 -norecurse [file join $rtl_dir lfm_radar_core.v]
add_files -fileset sources_1 -norecurse [file join $mem_dir lfm_400mhz_4096.mem]
set_property FILE_TYPE {Memory File} [get_files lfm_400mhz_4096.mem]
update_compile_order -fileset sources_1

open_bd_design [get_files design_1.bd]

# ADC10 is the echo channel and ADC12 is the PA/reference coupler channel.
# Decimation by four exposes four consecutive complex samples per 184.32 MHz
# PL beat, giving a 737.28 MSPS complex stream and enough margin for 400 MHz.
set rfdc [get_bd_cells usp_rf_data_converter_0]
set_property -dict [list \
    CONFIG.ADC_Decimation_Mode10 {4} \
    CONFIG.ADC_Decimation_Mode12 {4} \
    CONFIG.ADC_Data_Width10 {4} \
    CONFIG.ADC_Data_Width12 {4} \
    CONFIG.ADC1_Outclk_Freq {184.320}] $rfdc

foreach cell_name {
    axis_broadcaster_0
    dpsk_stream_tx_0
    dpsk_stream_tx_1
    fir_compiler_0
    fir_compiler_1
    axis_broadcaster_128_0
    axis_broadcaster_128_1
    dual_dac_dbpsk_tx_0
    dbpsk_adc_rx_0
    lfm_radar_core_0
    axis_data_fifo_rx
} {
    set cell [get_bd_cells -quiet $cell_name]
    if {[llength $cell]} {
        delete_bd_objs $cell
    }
}

create_bd_cell -type module -reference lfm_radar_core lfm_radar_core_0
create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 axis_data_fifo_rx
set_property -dict [list \
    CONFIG.IS_ACLK_ASYNC {1} \
    CONFIG.FIFO_DEPTH {1024} \
    CONFIG.HAS_TLAST {1}] [get_bd_cells axis_data_fifo_rx]

# Common 184.32 MHz RF/DSP clock domain.
connect_bd_net [get_bd_pins usp_rf_data_converter_0/clk_dac1] \
               [get_bd_pins lfm_radar_core_0/clk]
connect_bd_net [get_bd_pins proc_sys_reset_dac/peripheral_aresetn] \
               [get_bd_pins lfm_radar_core_0/rst_n]

# PS command FIFO -> radar control stream.
connect_bd_intf_net [get_bd_intf_pins axis_data_fifo_0/M_AXIS] \
                    [get_bd_intf_pins lfm_radar_core_0/s_axis_ctrl]

# LFM DAC outputs. DAC10 is the primary transmitter; DAC11 mirrors it for
# oscilloscope/VSA debug and can remain physically disconnected.
connect_bd_intf_net [get_bd_intf_pins lfm_radar_core_0/m0_axis] \
                    [get_bd_intf_pins usp_rf_data_converter_0/s10_axis]
connect_bd_intf_net [get_bd_intf_pins lfm_radar_core_0/m1_axis] \
                    [get_bd_intf_pins usp_rf_data_converter_0/s11_axis]

# ADC10 echo I/Q and ADC12 transmit-reference I/Q.
connect_bd_intf_net [get_bd_intf_pins usp_rf_data_converter_0/m10_axis] \
                    [get_bd_intf_pins lfm_radar_core_0/echo_i_axis]
connect_bd_intf_net [get_bd_intf_pins usp_rf_data_converter_0/m11_axis] \
                    [get_bd_intf_pins lfm_radar_core_0/echo_q_axis]
connect_bd_intf_net [get_bd_intf_pins usp_rf_data_converter_0/m12_axis] \
                    [get_bd_intf_pins lfm_radar_core_0/ref_i_axis]
connect_bd_intf_net [get_bd_intf_pins usp_rf_data_converter_0/m13_axis] \
                    [get_bd_intf_pins lfm_radar_core_0/ref_q_axis]

# Radar result packet crosses back to the 100 MHz PS AXI domain.
connect_bd_net [get_bd_pins usp_rf_data_converter_0/clk_dac1] \
               [get_bd_pins axis_data_fifo_rx/s_axis_aclk]
connect_bd_net [get_bd_pins proc_sys_reset_dac/peripheral_aresetn] \
               [get_bd_pins axis_data_fifo_rx/s_axis_aresetn]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
               [get_bd_pins axis_data_fifo_rx/m_axis_aclk]
connect_bd_intf_net [get_bd_intf_pins lfm_radar_core_0/m_axis_result] \
                    [get_bd_intf_pins axis_data_fifo_rx/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins axis_data_fifo_rx/M_AXIS] \
                    [get_bd_intf_pins axi_fifo_mm_s_0/AXI_STR_RXD]

# Preserve raw ADC monitoring and replace the four V10-specific ILA slots.
foreach slot {4 5 6 7} {
    set pin [get_bd_intf_pins system_ila_1/SLOT_${slot}_AXIS]
    set net [get_bd_intf_nets -quiet -of_objects $pin]
    if {[llength $net]} {
        disconnect_bd_intf_net $net $pin
    }
}
connect_bd_intf_net [get_bd_intf_pins lfm_radar_core_0/m1_axis] \
                    [get_bd_intf_pins system_ila_1/SLOT_4_AXIS]
connect_bd_intf_net [get_bd_intf_pins lfm_radar_core_0/m0_axis] \
                    [get_bd_intf_pins system_ila_1/SLOT_5_AXIS]
connect_bd_intf_net [get_bd_intf_pins lfm_radar_core_0/m_axis_result] \
                    [get_bd_intf_pins system_ila_1/SLOT_6_AXIS]
connect_bd_intf_net [get_bd_intf_pins axis_data_fifo_0/M_AXIS] \
                    [get_bd_intf_pins system_ila_1/SLOT_7_AXIS]

assign_bd_address
validate_bd_design
save_bd_design
generate_target all [get_files design_1.bd]
set wrapper [make_wrapper -files [get_files design_1.bd] -top]
add_files -norecurse $wrapper
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1
close_project
exit 0
