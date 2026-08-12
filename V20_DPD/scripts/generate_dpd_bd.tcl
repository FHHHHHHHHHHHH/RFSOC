set script_dir [file dirname [file normalize [info script]]]
set project_dir [file dirname $script_dir]

open_project [file join $project_dir V20_DPD.xpr]
set bd_file [get_files [file join $project_dir V20_DPD.srcs sources_1 bd design_1 design_1.bd]]
open_bd_design $bd_file
validate_bd_design
save_bd_design
generate_target all $bd_file
make_wrapper -files $bd_file -top
update_compile_order -fileset sources_1
close_project

puts "DPD_BD_GENERATION_COMPLETE"
