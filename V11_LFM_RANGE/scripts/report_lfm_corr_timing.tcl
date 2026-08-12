set script_dir [file dirname [file normalize [info script]]]
set v11_root [file normalize [file join $script_dir ..]]
set output_dir [file join $v11_root output core_synth]

open_checkpoint [file join $output_dir lfm_radar_core.dcp]

set max_score_d_pins [get_pins -hier -filter {
    NAME =~ *max_score_reg*/D
}]
set max_score_ce_pins [get_pins -hier -filter {
    NAME =~ *max_score_reg*/CE
}]

puts "max_score D pins: [llength $max_score_d_pins]"
puts "max_score CE pins: [llength $max_score_ce_pins]"

report_timing -delay_type max -max_paths 20 -to $max_score_d_pins \
    -file [file join $output_dir max_score_d_timing.rpt]
report_timing -delay_type max -max_paths 20 -to $max_score_ce_pins \
    -file [file join $output_dir max_score_ce_timing.rpt]

exit 0
