set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set project    [file join $repo_root V10_DPSK V10_DPSK.xpr]
set routed_dcp [file join $repo_root sw hardware routed.dcp]
set bit_path   [file join $repo_root sw hardware design_1_wrapper.bit]
set xsa_path   [file join $repo_root sw design_1_wrapper.xsa]

open_project $project
open_checkpoint $routed_dcp
write_bitstream -force $bit_path
write_hw_platform -fixed -include_bit -force -file $xsa_path
puts "WROTE_FINAL_XSA=$xsa_path"
close_project
exit 0

