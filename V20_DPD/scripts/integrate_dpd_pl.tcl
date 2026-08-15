set script_dir [file dirname [file normalize [info script]]]
set project_dir [file dirname $script_dir]
set project_file [file join $project_dir V20_DPD.xpr]
set rtl_dir [file join $project_dir V20_DPD.srcs sources_1 new]
set sim_dir [file join $project_dir V20_DPD.srcs sim_1 new]
set constr_dir [file join $project_dir V20_DPD.srcs constrs_1 new]

proc ensure_bd_intf_net {net_name pin_names} {
    set pin_objects {}
    set needs_connection 0
    foreach pin_name $pin_names {
        set pin_object [get_bd_intf_pins $pin_name]
        lappend pin_objects $pin_object
        set existing_nets [get_bd_intf_nets -quiet -of_objects $pin_object]
        if {[llength $existing_nets] == 0} {
            set needs_connection 1
        } elseif {[get_property NAME $existing_nets] ne $net_name} {
            error "Interface pin $pin_name is connected to [get_property NAME $existing_nets], expected $net_name"
        }
    }

    if {$needs_connection} {
        eval connect_bd_intf_net -intf_net $net_name $pin_objects
    }
}

# Vivado 2020.2 treats System ILA monitor slots specially: include the AXIS
# master anchor when adding a monitor to an existing functional connection.
proc ensure_bd_intf_monitor_on_net {net_name anchor_name pin_name} {
    set anchor [get_bd_intf_pins $anchor_name]
    set pin_object [get_bd_intf_pins $pin_name]
    set existing_nets [get_bd_intf_nets -quiet -of_objects $pin_object]
    if {[llength $existing_nets] == 0} {
        connect_bd_intf_net -intf_net $net_name $anchor $pin_object
    } elseif {[get_property NAME $existing_nets] ne $net_name} {
        error "Monitor pin $pin_name is connected to [get_property NAME $existing_nets], expected $net_name"
    }
}

proc ensure_bd_scalar_net {net_name pin_name} {
    set pin_object [get_bd_pins $pin_name]
    set existing_nets [get_bd_nets -quiet -of_objects $pin_object]
    if {[llength $existing_nets] == 0} {
        connect_bd_net -net $net_name $pin_object
    } elseif {[get_property NAME $existing_nets] ne $net_name} {
        error "Scalar pin $pin_name is connected to [get_property NAME $existing_nets], expected $net_name"
    }
}

open_project $project_file

foreach rtl_file [list \
        [file join $rtl_dir dpd_mp_4lane_core.sv] \
        [file join $rtl_dir axis_dpd_mp_4lane_dual.sv] \
        [file join $rtl_dir axis_dpd_mp_4lane_dual.v] \
        [file join $rtl_dir axis_dpd_lab_controller.sv] \
        [file join $rtl_dir axis_dpd_lab_controller.v]] {
    if {[llength [get_files -quiet $rtl_file]] == 0} {
        add_files -norecurse -fileset sources_1 $rtl_file
    }
    if {[file extension $rtl_file] eq ".sv"} {
        set_property file_type SystemVerilog [get_files $rtl_file]
    }
}
update_compile_order -fileset sources_1

set dpd_clock_constraints [file join $constr_dir dpd_clock_groups.xdc]
if {[llength [get_files -quiet $dpd_clock_constraints]] == 0} {
    add_files -norecurse -fileset constrs_1 $dpd_clock_constraints
}
set_property used_in_synthesis false [get_files $dpd_clock_constraints]
set_property used_in_implementation true [get_files $dpd_clock_constraints]

foreach sim_file [list \
        [file join $sim_dir tb_dpd_mp_4lane_core.sv] \
        [file join $sim_dir tb_axis_dpd_mp_4lane_dual.sv] \
        [file join $sim_dir tb_axis_dpd_lab_controller.sv]] {
    if {[llength [get_files -quiet $sim_file]] == 0} {
        add_files -norecurse -fileset sim_1 $sim_file
    }
    set_property file_type SystemVerilog [get_files $sim_file]
}
update_compile_order -fileset sim_1

open_bd_design [file join $project_dir V20_DPD.srcs sources_1 bd design_1 design_1.bd]

if {[llength [get_bd_cells -quiet dpd_mp_0]] == 0} {
    create_bd_cell -type module -reference axis_dpd_mp_4lane_dual dpd_mp_0
}
if {[llength [get_bd_cells -quiet dpd_lab_0]] == 0} {
    create_bd_cell -type module -reference axis_dpd_lab_controller dpd_lab_0
}
# Module-reference refresh expects the generated IP object, not the BD cell.
# This keeps the BD pin set synchronized when the LAB wrapper RTL changes.
set lab_module_ips [get_ips -quiet -all -filter {NAME =~ "*dpd_lab_0*"}]
if {[llength $lab_module_ips] != 0} {
    update_module_reference $lab_module_ips
}
foreach broadcaster_name [list adc_i_broadcaster adc_q_broadcaster] {
    if {[llength [get_bd_cells -quiet $broadcaster_name]] == 0} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:axis_broadcaster:1.1 $broadcaster_name
    }
    set_property -dict [list CONFIG.NUM_MI {2}] [get_bd_cells $broadcaster_name]
}
# M02 controls the MP-DPD and M03 controls waveform playback/capture.
set_property -dict [list CONFIG.NUM_MI {4}] [get_bd_cells ps8_0_axi_periph]

# Migrate the former direct DBPSK-to-DPD net to the lab controller topology.
if {[llength [get_bd_intf_nets -quiet dpd_input_axis]] != 0} {
    delete_bd_objs [get_bd_intf_nets dpd_input_axis]
}
# Insert the LAB controller in both ADC paths.  This replaces the legacy direct
# RFDC-to-receiver nets while keeping the ILA as a passive monitor.
foreach legacy_adc_net [list \
        usp_rf_data_converter_0_m10_axis \
        usp_rf_data_converter_0_m11_axis] {
    if {[llength [get_bd_intf_nets -quiet $legacy_adc_net]] != 0} {
        delete_bd_objs [get_bd_intf_nets $legacy_adc_net]
    }
}

# Legacy DBPSK remains the initial source.  The DPD wrapper defaults to bypass,
# so the pre-existing RF behavior is preserved until software loads a table and
# enables the core.
ensure_bd_intf_net dbpsk_to_dpd_lab [list \
    dual_dac_dbpsk_tx_0/m0_axis \
    dpd_lab_0/s_dbpsk_axis]

ensure_bd_intf_net dpd_lab_to_dpd [list \
    dpd_lab_0/m_tx_axis \
    dpd_mp_0/s_axis]
ensure_bd_intf_monitor_on_net dpd_lab_to_dpd dpd_lab_0/m_tx_axis system_ila_1/SLOT_5_AXIS

ensure_bd_intf_net dpd_dac0_axis [list \
    dpd_mp_0/m0_axis \
    usp_rf_data_converter_0/s10_axis]

ensure_bd_intf_net dpd_dac1_axis [list \
    dpd_mp_0/m1_axis \
    usp_rf_data_converter_0/s11_axis \
    system_ila_1/SLOT_4_AXIS]

ensure_bd_intf_net ps8_0_axi_periph_M02_AXI [list \
    ps8_0_axi_periph/M02_AXI \
    dpd_mp_0/S_AXI]

ensure_bd_intf_net ps8_0_axi_periph_M03_AXI [list \
    ps8_0_axi_periph/M03_AXI \
    dpd_lab_0/S_AXI]

ensure_bd_intf_net adc_i_from_rfdc [list \
    usp_rf_data_converter_0/m10_axis \
    adc_i_broadcaster/S_AXIS]
ensure_bd_intf_net adc_i_to_dpd_lab [list \
    adc_i_broadcaster/M01_AXIS \
    dpd_lab_0/s_adc_i_axis]
ensure_bd_intf_net adc_i_to_rx [list \
    adc_i_broadcaster/M00_AXIS \
    dbpsk_adc_rx_0/adc_i_axis]
ensure_bd_intf_monitor_on_net adc_i_to_rx adc_i_broadcaster/M00_AXIS system_ila_1/SLOT_0_AXIS

ensure_bd_intf_net adc_q_from_rfdc [list \
    usp_rf_data_converter_0/m11_axis \
    adc_q_broadcaster/S_AXIS]
ensure_bd_intf_net adc_q_to_dpd_lab [list \
    adc_q_broadcaster/M01_AXIS \
    dpd_lab_0/s_adc_q_axis]
ensure_bd_intf_net adc_q_to_rx [list \
    adc_q_broadcaster/M00_AXIS \
    dbpsk_adc_rx_0/adc_q_axis]
ensure_bd_intf_monitor_on_net adc_q_to_rx adc_q_broadcaster/M00_AXIS system_ila_1/SLOT_1_AXIS

ensure_bd_scalar_net usp_rf_data_converter_0_clk_dac1 dpd_mp_0/axis_clk
ensure_bd_scalar_net proc_sys_reset_dac_peripheral_aresetn dpd_mp_0/axis_resetn
ensure_bd_scalar_net usp_rf_data_converter_0_clk_dac1 dpd_lab_0/axis_clk
ensure_bd_scalar_net proc_sys_reset_dac_peripheral_aresetn dpd_lab_0/axis_resetn
ensure_bd_scalar_net usp_rf_data_converter_0_clk_dac1 adc_i_broadcaster/aclk
ensure_bd_scalar_net proc_sys_reset_dac_peripheral_aresetn adc_i_broadcaster/aresetn
ensure_bd_scalar_net usp_rf_data_converter_0_clk_dac1 adc_q_broadcaster/aclk
ensure_bd_scalar_net proc_sys_reset_dac_peripheral_aresetn adc_q_broadcaster/aresetn

ensure_bd_scalar_net zynq_ultra_ps_e_0_pl_clk0 ps8_0_axi_periph/M02_ACLK
ensure_bd_scalar_net zynq_ultra_ps_e_0_pl_clk0 dpd_mp_0/s_axi_aclk
ensure_bd_scalar_net proc_sys_reset_0_peripheral_aresetn ps8_0_axi_periph/M02_ARESETN
ensure_bd_scalar_net proc_sys_reset_0_peripheral_aresetn dpd_mp_0/s_axi_aresetn
ensure_bd_scalar_net zynq_ultra_ps_e_0_pl_clk0 ps8_0_axi_periph/M03_ACLK
ensure_bd_scalar_net zynq_ultra_ps_e_0_pl_clk0 dpd_lab_0/s_axi_aclk
ensure_bd_scalar_net proc_sys_reset_0_peripheral_aresetn ps8_0_axi_periph/M03_ARESETN
ensure_bd_scalar_net proc_sys_reset_0_peripheral_aresetn dpd_lab_0/s_axi_aresetn

assign_bd_address

# Keep the DPD aperture aligned and separate from the existing RFDC and FIFO.
foreach address_space [list \
        [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
        [get_bd_addr_spaces jtag_axi_0/Data]] {
    set matching_segments [get_bd_addr_segs -quiet -of_objects $address_space \
        -filter {NAME =~ "*dpd_mp_0*"}]
    foreach segment $matching_segments {
        set_property offset 0xA0080000 $segment
        set_property range 256K $segment
    }
    set lab_segments [get_bd_addr_segs -quiet -of_objects $address_space \
        -filter {NAME =~ "*dpd_lab_0*"}]
    foreach segment $lab_segments {
        set_property offset 0xA00C0000 $segment
        set_property range 256K $segment
    }
}

validate_bd_design
save_bd_design
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
close_project

puts "DPD_PL_INTEGRATION_COMPLETE"
