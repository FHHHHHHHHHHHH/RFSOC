set script_dir [file dirname [file normalize [info script]]]
set output_dir [file join $script_dir ooc_output]
set mem_dir [file join $script_dir mem]
file mkdir $output_dir

read_verilog [file join $script_dir lfm_radar_core.v]
read_mem [file join $mem_dir lfm_400mhz_4096.mem]
cd $mem_dir

synth_design -top lfm_radar_core -part xczu28dr-ffvg1517-2-e \
    -flatten_hierarchy none

report_utilization -hierarchical -file [file join $output_dir utilization.rpt]
report_timing_summary -file [file join $output_dir timing.rpt]
write_checkpoint -force [file join $output_dir lfm_radar_core.dcp]

puts "OOC_SYNTH=PASS"
puts "BRAM36=[llength [get_cells -hier -filter {PRIMITIVE_TYPE =~ BLOCKRAM.bram.*}]]"
puts "REGISTER_COUNT=[llength [get_cells -hier -filter {PRIMITIVE_TYPE =~ FLOP_LATCH.*}]]"
exit 0
