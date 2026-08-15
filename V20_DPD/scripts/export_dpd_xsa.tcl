set script_dir [file dirname [file normalize [info script]]]
set project_dir [file dirname $script_dir]
set repo_dir [file dirname $project_dir]
set output_dir [file join $repo_dir sw hardware]
set output_file [file join $output_dir zcu111_v20_dpd.xsa]

file mkdir $output_dir
open_project [file join $project_dir V20_DPD.xpr]
set bd_file [get_files [file join $project_dir V20_DPD.srcs sources_1 bd design_1 design_1.bd]]
open_bd_design $bd_file
validate_bd_design
generate_target all $bd_file
make_wrapper -files $bd_file -top
update_compile_order -fileset sources_1

# This handoff intentionally excludes the bitstream so software/BSP work can
# proceed on machines without the xczu28dr synthesis license.
write_hw_platform -fixed -force -file $output_file
close_project

puts "DPD_XSA_EXPORTED=$output_file"
