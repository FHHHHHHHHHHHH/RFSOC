set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set workspace  [file join $repo_root sw ws]
set source_dir [file join $repo_root sw RFSOC src]

setws $workspace
app config -name RFSOC -set linker-script [file join $source_dir lscript.ld]
app config -name RFSOC -set compiler-optimization {Optimize more (-O2)}
app build -name RFSOC
puts "RESULT=PASS"
exit 0

