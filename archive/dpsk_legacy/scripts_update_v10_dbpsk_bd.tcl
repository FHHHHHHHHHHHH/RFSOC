set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set project    [file join $repo_root V10_DPSK V10_DPSK.xpr]
set source_dir [file join $repo_root V10_DPSK V10_DPSK.srcs sources_1 new]

open_project $project

add_files -fileset sources_1 -norecurse [list \
    [file join $source_dir dual_dac_dbpsk_tx.v] \
    [file join $source_dir dbpsk_adc_rx.v]]
set_property used_in_synthesis true [get_files -of_objects [get_filesets sources_1] *dbpsk*.v]
update_compile_order -fileset sources_1

open_bd_design [get_files design_1.bd]

# Remove the duplicated DPSK/FIR paths and the fixed-IQ DAC adapters. The
# asynchronous PS-to-DAC FIFO remains and now feeds one common transmitter.
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
    axis_data_fifo_rx
} {
    set cell [get_bd_cells -quiet $cell_name]
    if {[llength $cell]} {
        delete_bd_objs $cell
    }
}

if {[llength [get_bd_cells -quiet dual_dac_dbpsk_tx_0]] == 0} {
    create_bd_cell -type module -reference dual_dac_dbpsk_tx dual_dac_dbpsk_tx_0
}
if {[llength [get_bd_cells -quiet dbpsk_adc_rx_0]] == 0} {
    create_bd_cell -type module -reference dbpsk_adc_rx_v10 dbpsk_adc_rx_0
}
if {[llength [get_bd_cells -quiet axis_data_fifo_rx]] == 0} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 axis_data_fifo_rx
    set_property -dict [list \
        CONFIG.IS_ACLK_ASYNC {1} \
        CONFIG.FIFO_DEPTH {1024} \
        CONFIG.HAS_TLAST {1}] [get_bd_cells axis_data_fifo_rx]
}

# Shared DAC-clock-domain transmitter.
connect_bd_net [get_bd_pins usp_rf_data_converter_0/clk_dac1] \
               [get_bd_pins dual_dac_dbpsk_tx_0/clk]
connect_bd_net [get_bd_pins proc_sys_reset_dac/peripheral_aresetn] \
               [get_bd_pins dual_dac_dbpsk_tx_0/rst_n]
connect_bd_intf_net [get_bd_intf_pins axis_data_fifo_0/M_AXIS] \
                    [get_bd_intf_pins dual_dac_dbpsk_tx_0/s_axis]
connect_bd_intf_net [get_bd_intf_pins dual_dac_dbpsk_tx_0/m0_axis] \
                    [get_bd_intf_pins usp_rf_data_converter_0/s10_axis]
connect_bd_intf_net [get_bd_intf_pins dual_dac_dbpsk_tx_0/m1_axis] \
                    [get_bd_intf_pins usp_rf_data_converter_0/s11_axis]

# ADC10 I/Q receiver. ADC12/13 remain connected to ILA for second-channel
# observation and later dual-receiver expansion.
connect_bd_net [get_bd_pins usp_rf_data_converter_0/clk_dac1] \
               [get_bd_pins dbpsk_adc_rx_0/clk]
connect_bd_net [get_bd_pins proc_sys_reset_dac/peripheral_aresetn] \
               [get_bd_pins dbpsk_adc_rx_0/rst_n]
connect_bd_intf_net [get_bd_intf_pins usp_rf_data_converter_0/m10_axis] \
                    [get_bd_intf_pins dbpsk_adc_rx_0/adc_i_axis]
connect_bd_intf_net [get_bd_intf_pins usp_rf_data_converter_0/m11_axis] \
                    [get_bd_intf_pins dbpsk_adc_rx_0/adc_q_axis]

# Cross decoded packets from the 184.32 MHz RF domain into the PS AXI clock
# domain, then use the existing AXI FIFO MM-S receive channel.
connect_bd_net [get_bd_pins usp_rf_data_converter_0/clk_dac1] \
               [get_bd_pins axis_data_fifo_rx/s_axis_aclk]
connect_bd_net [get_bd_pins proc_sys_reset_dac/peripheral_aresetn] \
               [get_bd_pins axis_data_fifo_rx/s_axis_aresetn]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
               [get_bd_pins axis_data_fifo_rx/m_axis_aclk]
connect_bd_intf_net [get_bd_intf_pins dbpsk_adc_rx_0/m_axis] \
                    [get_bd_intf_pins axis_data_fifo_rx/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins axis_data_fifo_rx/M_AXIS] \
                    [get_bd_intf_pins axi_fifo_mm_s_0/AXI_STR_RXD]

# Refresh ILA slots while retaining the established ADC mapping.
foreach slot {4 5 6 7} {
    set pin [get_bd_intf_pins system_ila_1/SLOT_${slot}_AXIS]
    set net [get_bd_intf_nets -quiet -of_objects $pin]
    if {[llength $net]} {
        disconnect_bd_intf_net $net $pin
    }
}
connect_bd_intf_net [get_bd_intf_pins dual_dac_dbpsk_tx_0/m1_axis] \
                    [get_bd_intf_pins system_ila_1/SLOT_4_AXIS]
connect_bd_intf_net [get_bd_intf_pins dual_dac_dbpsk_tx_0/m0_axis] \
                    [get_bd_intf_pins system_ila_1/SLOT_5_AXIS]
connect_bd_intf_net [get_bd_intf_pins dbpsk_adc_rx_0/m_axis] \
                    [get_bd_intf_pins system_ila_1/SLOT_6_AXIS]
connect_bd_intf_net [get_bd_intf_pins axis_data_fifo_0/M_AXIS] \
                    [get_bd_intf_pins system_ila_1/SLOT_7_AXIS]

assign_bd_address
validate_bd_design
save_bd_design
generate_target all [get_files design_1.bd]
update_compile_order -fileset sources_1
close_project
