set script_dir [file dirname [file normalize [info script]]]
set project_dir [file dirname $script_dir]
set project_file [file join $project_dir V20_DPD.xpr]
set rtl_dir [file join $project_dir V20_DPD.srcs sources_1 new]
set sim_dir [file join $project_dir V20_DPD.srcs sim_1 new]

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
        [file join $rtl_dir axis_dpd_mp_4lane_dual.v]] {
    if {[llength [get_files -quiet $rtl_file]] == 0} {
        add_files -norecurse -fileset sources_1 $rtl_file
    }
    if {[file extension $rtl_file] eq ".sv"} {
        set_property file_type SystemVerilog [get_files $rtl_file]
    }
}
update_compile_order -fileset sources_1

foreach sim_file [list \
        [file join $sim_dir tb_dpd_mp_4lane_core.sv] \
        [file join $sim_dir tb_axis_dpd_mp_4lane_dual.sv]] {
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
# Add a third AXI master port to the existing PS interconnect for DPD control.
set_property -dict [list CONFIG.NUM_MI {3}] [get_bd_cells ps8_0_axi_periph]

foreach tx_pin [list dual_dac_dbpsk_tx_0/m0_axis dual_dac_dbpsk_tx_0/m1_axis] {
    foreach existing_net [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $tx_pin]] {
        if {[get_property NAME $existing_net] ne "dpd_input_axis"} {
            delete_bd_objs $existing_net
        }
    }
}

# Legacy DBPSK remains the initial source.  The DPD wrapper defaults to bypass,
# so the pre-existing RF behavior is preserved until software loads a table and
# enables the core.
ensure_bd_intf_net dpd_input_axis [list \
    dual_dac_dbpsk_tx_0/m0_axis \
    dpd_mp_0/s_axis \
    system_ila_1/SLOT_5_AXIS]

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

ensure_bd_scalar_net usp_rf_data_converter_0_clk_dac1 dpd_mp_0/axis_clk
ensure_bd_scalar_net proc_sys_reset_dac_peripheral_aresetn dpd_mp_0/axis_resetn

ensure_bd_scalar_net zynq_ultra_ps_e_0_pl_clk0 ps8_0_axi_periph/M02_ACLK
ensure_bd_scalar_net zynq_ultra_ps_e_0_pl_clk0 dpd_mp_0/s_axi_aclk
ensure_bd_scalar_net proc_sys_reset_0_peripheral_aresetn ps8_0_axi_periph/M02_ARESETN
ensure_bd_scalar_net proc_sys_reset_0_peripheral_aresetn dpd_mp_0/s_axi_aresetn

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
}

validate_bd_design
save_bd_design
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
close_project

puts "DPD_PL_INTEGRATION_COMPLETE"
