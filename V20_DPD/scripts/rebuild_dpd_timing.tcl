set script_dir [file dirname [file normalize [info script]]]
set project_dir [file dirname $script_dir]
set project_file [file join $project_dir V20_DPD.xpr]
set report_dir [file join $project_dir reports full_timing_fix]
file mkdir $report_dir

open_project $project_file
update_compile_order -fileset sources_1

set clock_xdc [file join $project_dir V20_DPD.srcs constrs_1 new dpd_clock_groups.xdc]
if {[llength [get_files -quiet $clock_xdc]] == 0} {
    error "DPD clock-domain constraint file is not in constrs_1: $clock_xdc"
}
set_property used_in_synthesis false [get_files $clock_xdc]
set_property used_in_implementation true [get_files $clock_xdc]

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "DPD_SYNTH_STATUS=$synth_status"
if {![string match "*Complete*" $synth_status]} {
    error "Top-level synthesis failed: $synth_status"
}

open_run synth_1
report_utilization -file [file join $report_dir utilization_synth.rpt]
close_design

reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "DPD_IMPL_STATUS=$impl_status"
if {![string match "*Complete*" $impl_status]} {
    error "Top-level implementation failed: $impl_status"
}

open_run impl_1
report_timing_summary -delay_type max -max_paths 50 \
    -file [file join $report_dir timing_summary_routed.rpt]
report_clock_interaction \
    -file [file join $report_dir clock_interaction_routed.rpt]
report_bus_skew -warn_on_violation \
    -file [file join $report_dir bus_skew_routed.rpt]
report_cdc -details \
    -file [file join $report_dir cdc_routed.rpt]
report_utilization -hierarchical -hierarchical_depth 4 \
    -file [file join $report_dir utilization_routed_hier.rpt]
report_methodology \
    -file [file join $report_dir methodology_routed.rpt]

puts "DPD_FULL_TIMING_REBUILD_COMPLETE"
close_project
