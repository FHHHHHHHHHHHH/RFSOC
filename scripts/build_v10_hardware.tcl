set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set project    [file join $repo_root V10_DPSK V10_DPSK.xpr]
set xsa_path   [file join $repo_root sw design_1_wrapper.xsa]

open_project $project
update_compile_order -fileset sources_1

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "SYNTH_STATUS=$synth_status"
if {![string match "*Complete*" $synth_status]} {
    error "synth_1 did not complete"
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "IMPL_STATUS=$impl_status"
if {![string match "*Complete*" $impl_status]} {
    error "impl_1 did not complete through write_bitstream"
}

open_run impl_1
file mkdir [file dirname $xsa_path]
write_hw_platform -fixed -include_bit -force -file $xsa_path
puts "WROTE_XSA=$xsa_path"
close_project
exit 0

