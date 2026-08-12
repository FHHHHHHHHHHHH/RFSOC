set script_dir [file dirname [file normalize [info script]]]
set project_dir [file dirname $script_dir]
set failures 0

proc check_equal {label actual expected} {
    upvar failures failures
    if {$actual ne $expected} {
        puts "ERROR: $label expected '$expected', got '$actual'"
        incr failures
    } else {
        puts "PASS: $label = $actual"
    }
}

proc interface_net_name {pin_name} {
    set nets [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $pin_name]]
    return [get_property NAME $nets]
}

proc scalar_net_name {pin_name} {
    set nets [get_bd_nets -quiet -of_objects [get_bd_pins $pin_name]]
    return [get_property NAME $nets]
}

open_project [file join $project_dir V20_DPD.xpr]
set bd_file [get_files [file join $project_dir V20_DPD.srcs sources_1 bd design_1 design_1.bd]]
open_bd_design $bd_file
validate_bd_design

check_equal "DPD module count" [llength [get_bd_cells -quiet dpd_mp_0]] "1"
check_equal "AXI interconnect master count" [get_property CONFIG.NUM_MI [get_bd_cells ps8_0_axi_periph]] "3"
check_equal "DPD input stream" [interface_net_name dpd_mp_0/s_axis] "dpd_input_axis"
check_equal "DPD DAC0 stream" [interface_net_name dpd_mp_0/m0_axis] "dpd_dac0_axis"
check_equal "DPD DAC1 stream" [interface_net_name dpd_mp_0/m1_axis] "dpd_dac1_axis"
check_equal "DPD AXI-Lite stream" [interface_net_name dpd_mp_0/S_AXI] "ps8_0_axi_periph_M02_AXI"
check_equal "DPD sample clock" [scalar_net_name dpd_mp_0/axis_clk] "usp_rf_data_converter_0_clk_dac1"
check_equal "DPD AXI clock" [scalar_net_name dpd_mp_0/s_axi_aclk] "zynq_ultra_ps_e_0_pl_clk0"

foreach address_space_name [list zynq_ultra_ps_e_0/Data jtag_axi_0/Data] {
    set address_space [get_bd_addr_spaces $address_space_name]
    set segments [get_bd_addr_segs -quiet -of_objects $address_space -filter {NAME =~ "*dpd_mp_0*"}]
    check_equal "$address_space_name DPD segment count" [llength $segments] "1"
    if {[llength $segments] == 1} {
        set offset_value [get_property OFFSET $segments]
        set range_value [get_property RANGE $segments]
        check_equal "$address_space_name DPD offset" [format "0x%08X" [expr $offset_value]] "0xA0080000"
        check_equal "$address_space_name DPD range" [format "0x%08X" [expr $range_value]] "0x00040000"
    }
}

update_compile_order -fileset sources_1
set v10_compile_files {}
foreach source_file [get_files -compile_order sources -used_in synthesis] {
    set source_name [string map {\\ /} [get_property NAME $source_file]]
    if {[string match -nocase "*ZCU111_V10_DPSK*" $source_name]} {
        lappend v10_compile_files $source_name
    }
}
check_equal "V10 synthesis-path dependency count" [llength $v10_compile_files] "0"
foreach source_name $v10_compile_files {
    puts "ERROR: external compile source: $source_name"
}

close_project

if {$failures != 0} {
    error "DPD PL verification failed with $failures error(s)"
}

puts "DPD_PL_VERIFICATION_COMPLETE"
