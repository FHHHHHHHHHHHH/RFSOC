set script_dir [file dirname [file normalize [info script]]]
set v11_root [file normalize [file join $script_dir ..]]
set output_dir [file join $v11_root output core_synth]
file mkdir $output_dir
cd $v11_root

read_verilog [file join $v11_root rtl lfm_radar_core.v]
read_mem [file join $v11_root mem lfm_400mhz_4096.mem]
synth_design -top lfm_radar_core -part xczu28dr-ffvg1517-2-e
set clk_period_ns [expr {1000000000.0 / 184320000.0}]
create_clock -name clk -period $clk_period_ns [get_ports clk]
report_utilization -file [file join $output_dir utilization.rpt]
report_timing_summary -file [file join $output_dir timing.rpt]
write_checkpoint -force [file join $output_dir lfm_radar_core.dcp]
exit 0
