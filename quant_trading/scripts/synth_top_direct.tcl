set script_dir [file dirname [file normalize [info script]]]
set proj_dir   [file normalize [file join $script_dir ..]]
set proj_file  [file join $proj_dir QUANT_TRADING.xpr]
set bd_name    design_quant
set top_name   design_quant_wrapper
set part       xczu28dr-ffvg1517-2-e

set_param general.maxThreads 1
puts ">>> 打开工程并以 Non-Project In-Memory 模式进行顶层综合验证..."
open_project $proj_file

set bd_file [get_files */${bd_name}.bd]
open_bd_design $bd_file

# 生成 BD 输出目标
generate_target all $bd_file

# 综合
synth_design -top $top_name -part $part -mode default

puts "=========================================================="
puts ">>> TOP BD SYNTHESIS SUCCESS!"
puts "=========================================================="

report_utilization
close_project
exit
