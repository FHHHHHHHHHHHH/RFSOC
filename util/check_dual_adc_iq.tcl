# Validate the current dual-IQ ADC configuration without running synthesis.

if {$argc < 1} {
    puts "ERROR: usage: vivado -mode batch -source check_dual_adc_iq.tcl -tclargs <project.xpr>"
    exit 2
}

set project_path [file normalize [lindex $argv 0]]
open_project $project_path
open_bd_design [get_files */design_1.bd]

set rfdc [get_bd_cells usp_rf_data_converter_0]
if {[llength $rfdc] != 1} {
    puts "ERROR: RFDC cell usp_rf_data_converter_0 was not found"
    exit 3
}

puts "=== RFDC ADC Tile1 ==="
foreach property_name {
    CONFIG.ADC1_Enable
    CONFIG.ADC1_Sampling_Rate
    CONFIG.ADC1_Refclk_Freq
    CONFIG.ADC1_Decimation
    CONFIG.ADC_Slice10_Enable
    CONFIG.ADC_Slice11_Enable
    CONFIG.ADC_Slice12_Enable
    CONFIG.ADC_Slice13_Enable
    CONFIG.ADC_Mixer_Mode10
    CONFIG.ADC_Mixer_Mode11
    CONFIG.ADC_Mixer_Mode12
    CONFIG.ADC_Mixer_Mode13
    CONFIG.ADC_Mixer_Type10
    CONFIG.ADC_Mixer_Type11
    CONFIG.ADC_Mixer_Type12
    CONFIG.ADC_Mixer_Type13
    CONFIG.ADC_NCO_Freq10
    CONFIG.ADC_NCO_Freq12
} {
    puts "$property_name=[get_property $property_name $rfdc]"
}

set expected_connections {
    m10_axis SLOT_0_AXIS
    m11_axis SLOT_1_AXIS
    m12_axis SLOT_2_AXIS
    m13_axis SLOT_3_AXIS
}

puts "=== ILA connections ==="
set connection_error 0
foreach {rfdc_port ila_port} $expected_connections {
    set rfdc_intf [get_bd_intf_pins usp_rf_data_converter_0/$rfdc_port]
    set ila_intf [get_bd_intf_pins system_ila_1/$ila_port]
    set rfdc_net [get_bd_intf_nets -of_objects $rfdc_intf]
    set ila_net [get_bd_intf_nets -of_objects $ila_intf]
    puts "$rfdc_port -> $ila_port : RFDC_NET=$rfdc_net ILA_NET=$ila_net"
    if {$rfdc_net eq "" || $ila_net eq "" || $rfdc_net ne $ila_net} {
        puts "ERROR: $rfdc_port is not connected to $ila_port"
        set connection_error 1
    }
}

puts "=== Validate BD ==="
validate_bd_design

if {$connection_error} {
    puts "RESULT: FAIL"
    close_project
    exit 4
}

puts "RESULT: PASS"
close_project
exit 0
