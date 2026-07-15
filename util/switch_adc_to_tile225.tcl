# Switch the receive path from the low-band ADC tile 224 (ADC00/ADC02)
# to the high-band ADC tile 225 (ADC10/ADC12).
#
# ILA mapping after this script:
#   SLOT_0 = ADC10 I (m10_axis)
#   SLOT_1 = ADC10 Q (m11_axis)
#   SLOT_2 = ADC12 I (m12_axis)
#   SLOT_3 = ADC12 Q (m13_axis)
# DAC10/DAC11 and the transmit datapath are intentionally unchanged.

set project_path [file normalize [lindex $argv 0]]
if {$project_path eq ""} {
    error "Usage: vivado -mode batch -source switch_adc_to_tile225.tcl -tclargs <project.xpr>"
}

proc require_one {objects description} {
    if {[llength $objects] != 1} {
        error "Expected one $description, got [llength $objects]"
    }
    return [lindex $objects 0]
}

proc disconnect_intf_pin_if_connected {pin} {
    set nets [get_bd_intf_nets -quiet -of_objects $pin]
    foreach net $nets {
        disconnect_bd_intf_net $net $pin
    }
}

proc disconnect_pin_if_connected {pin} {
    set nets [get_bd_nets -quiet -of_objects $pin]
    foreach net $nets {
        disconnect_bd_net $net $pin
    }
}

open_project $project_path
open_bd_design [require_one [get_files -quiet design_1.bd] "design_1.bd file"]

set rfdc [require_one [get_bd_cells -quiet usp_rf_data_converter_0] "RF Data Converter cell"]

# Configure the high-band ADC tile first while the old tile is still present.
# Tile 225 uses calibration Mode2 on this RFSoC generation.
set_property -dict [list \
    CONFIG.ADC1_Enable {1} \
    CONFIG.ADC1_PLL_Enable {false} \
    CONFIG.ADC1_Sampling_Rate {2.94912} \
    CONFIG.ADC1_Refclk_Freq {2949.120} \
    CONFIG.ADC1_Outclk_Freq {92.160} \
    CONFIG.ADC1_Fabric_Freq {184.320} \
    CONFIG.ADC_CalOpt_Mode10 {1} \
    CONFIG.ADC_CalOpt_Mode11 {1} \
    CONFIG.ADC_CalOpt_Mode12 {1} \
    CONFIG.ADC_CalOpt_Mode13 {1} \
    CONFIG.ADC_Data_Type10 {1} \
    CONFIG.ADC_Data_Type11 {1} \
    CONFIG.ADC_Data_Type12 {1} \
    CONFIG.ADC_Data_Type13 {1} \
    CONFIG.ADC_Data_Width10 {2} \
    CONFIG.ADC_Data_Width11 {2} \
    CONFIG.ADC_Data_Width12 {2} \
    CONFIG.ADC_Data_Width13 {2} \
    CONFIG.ADC_Decimation_Mode10 {8} \
    CONFIG.ADC_Decimation_Mode11 {8} \
    CONFIG.ADC_Decimation_Mode12 {8} \
    CONFIG.ADC_Decimation_Mode13 {8} \
    CONFIG.ADC_Mixer_Mode10 {0} \
    CONFIG.ADC_Mixer_Mode11 {0} \
    CONFIG.ADC_Mixer_Mode12 {0} \
    CONFIG.ADC_Mixer_Mode13 {0} \
    CONFIG.ADC_Mixer_Type10 {2} \
    CONFIG.ADC_Mixer_Type11 {2} \
    CONFIG.ADC_Mixer_Type12 {2} \
    CONFIG.ADC_Mixer_Type13 {2} \
    CONFIG.ADC_NCO_Freq10 {0.2} \
    CONFIG.ADC_NCO_Freq12 {0.2} \
    CONFIG.ADC_NCO_Phase10 {0} \
    CONFIG.ADC_NCO_Phase12 {0} \
    CONFIG.ADC_Nyquist10 {1} \
    CONFIG.ADC_Nyquist11 {1} \
    CONFIG.ADC_Nyquist12 {1} \
    CONFIG.ADC_Nyquist13 {1} \
    CONFIG.ADC_Slice10_Enable {true} \
    CONFIG.ADC_Slice11_Enable {true} \
    CONFIG.ADC_Slice12_Enable {true} \
    CONFIG.ADC_Slice13_Enable {true} \
] $rfdc

# Check that enabling tile 225 produced the expected high-speed ADC ports.
foreach pin_name {adc1_clk vin1_01 vin1_23 m10_axis m11_axis m12_axis m13_axis} {
    require_one [get_bd_intf_pins -quiet $rfdc/$pin_name] "$rfdc/$pin_name interface pin"
}
require_one [get_bd_pins -quiet $rfdc/m1_axis_aclk] "$rfdc/m1_axis_aclk pin"

# Move the four receive ILA slots from tile 224 to tile 225.
foreach {slot_name adc_pin_name} {
    SLOT_0_AXIS m10_axis
    SLOT_1_AXIS m11_axis
    SLOT_2_AXIS m12_axis
    SLOT_3_AXIS m13_axis
} {
    set slot [require_one [get_bd_intf_pins -quiet system_ila_1/$slot_name] "system ILA $slot_name pin"]
    disconnect_intf_pin_if_connected $slot
    connect_bd_intf_net [get_bd_intf_pins $rfdc/$adc_pin_name] $slot
}

# The ADC output rate is 184.32 MHz, matching the existing DAC fabric clock.
set fabric_clock_net [require_one \
    [get_bd_nets -quiet -of_objects [get_bd_pins $rfdc/clk_dac1]] \
    "184.32 MHz RFDC fabric clock net"]
set m1_aclk [require_one [get_bd_pins -quiet $rfdc/m1_axis_aclk] "$rfdc/m1_axis_aclk pin"]
disconnect_pin_if_connected $m1_aclk
connect_bd_net -net $fabric_clock_net $m1_aclk

# Remove the old low-band ADC external connections before disabling tile 224.
foreach old_pin_name {adc0_clk vin0_01 vin0_23} {
    set old_pin [get_bd_intf_pins -quiet $rfdc/$old_pin_name]
    if {[llength $old_pin] == 1} {
        disconnect_intf_pin_if_connected $old_pin
    }
}
set old_m0_aclk [get_bd_pins -quiet $rfdc/m0_axis_aclk]
if {[llength $old_m0_aclk] == 1} {
    disconnect_pin_if_connected $old_m0_aclk
}

# Disable all four logical slices belonging to the two high-speed ADC inputs
# on tile 224.  Paired slices 00/01 and 02/03 form ADC00 and ADC02.
set_property -dict [list \
    CONFIG.ADC_Slice00_Enable {false} \
    CONFIG.ADC_Slice01_Enable {false} \
    CONFIG.ADC_Slice02_Enable {false} \
    CONFIG.ADC_Slice03_Enable {false} \
] $rfdc

foreach old_port_name {adc0_clk_0 vin0_01_0 vin0_23_0} {
    set old_port [get_bd_intf_ports -quiet $old_port_name]
    if {[llength $old_port] == 1} {
        delete_bd_objs $old_port
    }
}

# Export the tile 225 reference clock and both high-band analog inputs.
foreach new_pin_name {adc1_clk vin1_01 vin1_23} {
    set pin [require_one [get_bd_intf_pins -quiet $rfdc/$new_pin_name] "$rfdc/$new_pin_name interface pin"]
    if {[llength [get_bd_intf_nets -quiet -of_objects $pin]] == 0} {
        make_bd_intf_pins_external $pin
    }
}

validate_bd_design
save_bd_design
generate_target all [get_files design_1.bd]
make_wrapper -files [get_files design_1.bd] -top

puts "ADC receive path switched to tile 225: ADC10 IQ + ADC12 IQ"
puts "ILA mapping: slot0=m10(I), slot1=m11(Q), slot2=m12(I), slot3=m13(Q)"
puts "Physical XM500 inputs: ADC10=J2, ADC12=J1"
close_project
