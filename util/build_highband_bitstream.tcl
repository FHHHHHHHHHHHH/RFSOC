set xpr_path [lindex $argv 0]
if {$xpr_path eq ""} {
    set xpr_path "ZCU111_V9_adc.xpr"
}

open_project $xpr_path
update_compile_order -fileset sources_1

puts "Resetting synthesis and implementation runs..."
reset_run synth_1

puts "Launching synthesis..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "synth_1 status: $synth_status"
if {![string match "*Complete*" $synth_status]} {
    error "synth_1 did not complete successfully"
}

puts "Launching implementation through bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "impl_1 status: $impl_status"
if {![string match "*Complete*" $impl_status]} {
    error "impl_1/write_bitstream did not complete successfully"
}

open_run impl_1

set root_xsa [file normalize "design_1_wrapper.xsa"]
puts "Writing hardware platform: $root_xsa"
write_hw_platform -fixed -include_bit -force -file $root_xsa

foreach dst {
    "ws/ZCU111/hw/design_1_wrapper.xsa"
    "ws/ZCU111/export/ZCU111/hw/design_1_wrapper.xsa"
} {
    set dst_path [file normalize $dst]
    file mkdir [file dirname $dst_path]
    file copy -force $root_xsa $dst_path
    puts "Copied XSA to $dst_path"
}

puts "High-band ADC bitstream and XSA export completed."
