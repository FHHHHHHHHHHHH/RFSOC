set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set project    [file join $repo_root V10_DPSK V10_DPSK.xpr]
set xsa_path   [file join $repo_root sw design_1_wrapper.xsa]

open_project $project
write_hw_platform -fixed -force -file $xsa_path
puts "WROTE_XSA_NO_BIT=$xsa_path"
close_project
exit 0

