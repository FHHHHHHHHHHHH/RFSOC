set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set project    [file join $repo_root V10_DPSK V10_DPSK.xpr]
set output_dir [file join $repo_root sw hardware]
set bit_path   [file join $output_dir design_1_wrapper.bit]
set xsa_path   [file join $repo_root sw design_1_wrapper.xsa]

file mkdir $output_dir
set_param general.maxThreads 4

open_project $project
add_files -fileset sources_1 -norecurse [list \
    [file join $repo_root V10_DPSK V10_DPSK.srcs sources_1 new dual_dac_dbpsk_tx.v] \
    [file join $repo_root V10_DPSK V10_DPSK.srcs sources_1 new dbpsk_adc_rx.v]]
set_property used_in_synthesis true [get_files -of_objects [get_filesets sources_1] *dbpsk*.v]
update_compile_order -fileset sources_1

puts "DIRECT_STAGE=SYNTHESIS"
synth_design -top design_1_wrapper -part xczu28dr-ffvg1517-2-e
write_checkpoint -force [file join $output_dir post_synth.dcp]
report_utilization -file [file join $output_dir utilization_synth.rpt]

puts "DIRECT_STAGE=OPT_DESIGN"
opt_design
write_checkpoint -force [file join $output_dir post_opt.dcp]

puts "DIRECT_STAGE=PLACE_DESIGN"
place_design
phys_opt_design
write_checkpoint -force [file join $output_dir post_place.dcp]
report_utilization -file [file join $output_dir utilization_placed.rpt]

puts "DIRECT_STAGE=ROUTE_DESIGN"
route_design
write_checkpoint -force [file join $output_dir routed.dcp]
report_route_status -file [file join $output_dir route_status.rpt]
report_drc -file [file join $output_dir drc_routed.rpt]
report_timing_summary -warn_on_violation -max_paths 20 \
    -file [file join $output_dir timing_summary_routed.rpt]
write_debug_probes -force [file join $output_dir design_1_wrapper.ltx]

puts "DIRECT_STAGE=BITSTREAM"
write_bitstream -force $bit_path
puts "WROTE_BIT=$bit_path"

# write_hw_platform in Vivado 2020.2 does not accept the direct in-memory
# project state after write_bitstream. Reopen the routed checkpoint so the
# design is explicitly classified as a checkpoint design, then package it.
close_project
open_project $project
open_checkpoint [file join $output_dir routed.dcp]
write_hw_platform -fixed -include_bit -force -file $xsa_path
puts "WROTE_XSA=$xsa_path"
close_project
exit 0
