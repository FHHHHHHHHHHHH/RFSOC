set script_dir [file dirname [file normalize [info script]]]
set project_dir [file dirname $script_dir]
set rtl_dir [file join $project_dir V20_DPD.srcs sources_1 new]
set report_dir [file join $project_dir reports dpd_lab_ooc]
file mkdir $report_dir

read_verilog -sv [file join $rtl_dir axis_dpd_lab_controller.sv]
read_verilog [file join $rtl_dir axis_dpd_lab_controller.v]

synth_design -mode out_of_context \
    -top axis_dpd_lab_controller \
    -part xczu28dr-ffvg1517-2-e

create_clock -name axis_clk -period 5.425 [get_ports axis_clk]
create_clock -name s_axi_aclk -period 10.000 [get_ports s_axi_aclk]
set_clock_groups -asynchronous \
    -group [get_clocks axis_clk] \
    -group [get_clocks s_axi_aclk]

report_utilization -file [file join $report_dir utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $report_dir timing_summary.rpt]
write_checkpoint -force [file join $report_dir axis_dpd_lab_controller_synth.dcp]

puts "DPD_LAB_OOC_SYNTH_COMPLETE"
