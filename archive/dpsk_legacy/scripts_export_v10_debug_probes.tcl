set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set routed_dcp [file join $repo_root sw hardware routed.dcp]
set ltx_path   [file join $repo_root sw hardware design_1_wrapper.ltx]

open_checkpoint $routed_dcp
write_debug_probes -force $ltx_path
puts "WROTE_LTX=$ltx_path"
exit 0

