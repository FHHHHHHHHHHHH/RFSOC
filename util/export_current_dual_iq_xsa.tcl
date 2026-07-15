# Export the already completed implementation as an XSA with bitstream.

if {$argc < 1} {
    puts "ERROR: usage: vivado -mode batch -source export_current_dual_iq_xsa.tcl -tclargs <project.xpr>"
    exit 2
}

set project_path [file normalize [lindex $argv 0]]
set project_root [file dirname $project_path]
open_project $project_path

set impl_run [get_runs impl_1]
set impl_status [get_property STATUS $impl_run]
set impl_progress [get_property PROGRESS $impl_run]
set impl_needs_refresh [get_property NEEDS_REFRESH $impl_run]
puts "impl_1 STATUS=$impl_status PROGRESS=$impl_progress NEEDS_REFRESH=$impl_needs_refresh"

if {![string match "*Complete*" $impl_status] || $impl_progress ne "100%" || $impl_needs_refresh} {
    puts "ERROR: impl_1 is not a current completed bitstream run; regenerate the bitstream first"
    close_project
    exit 3
}

open_run impl_1

set root_xsa [file join $project_root design_1_wrapper.xsa]
write_hw_platform -fixed -include_bit -force -file $root_xsa
puts "WROTE $root_xsa"

foreach relative_path {
    {ws/ZCU111/hw/design_1_wrapper.xsa}
    {ws/ZCU111/export/ZCU111/hw/design_1_wrapper.xsa}
} {
    set destination [file join $project_root $relative_path]
    file mkdir [file dirname $destination]
    file copy -force $root_xsa $destination
    puts "COPIED $destination"
}

close_project
puts "RESULT: PASS"
exit 0
