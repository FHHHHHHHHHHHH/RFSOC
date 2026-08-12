set script_dir [file dirname [file normalize [info script]]]
set v11_root   [file normalize [file join $script_dir ..]]
set workspace  [file join $v11_root sw ws]
set source_dir [file join $v11_root sw src]

setws $workspace
app config -name V11_LFM_RANGE -set linker-script [file join $source_dir lscript.ld]
app config -name V11_LFM_RANGE -set compiler-optimization {Optimize more (-O2)}
app build -name V11_LFM_RANGE
puts "RESULT=PASS"
exit 0
