set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set workspace  [file join $repo_root sw ws]
set xsa_path   [file join $repo_root sw design_1_wrapper.xsa]

setws $workspace
platform active V10_Platform
platform config -updatehw $xsa_path
platform write

domain active standalone_domain
bsp reload
bsp regenerate
platform generate -domains standalone_domain

puts "RESULT=PASS"
exit 0

