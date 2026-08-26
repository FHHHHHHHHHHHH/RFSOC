set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set workspace  [file join $repo_root sw ws]
set xsa_path   [file join $repo_root sw design_1_wrapper.xsa]
set source_dir [file join $repo_root sw RFSOC src]

if {![file exists $xsa_path]} {
    puts "ERROR: missing XSA: $xsa_path"
    exit 2
}

setws $workspace

platform create -name V10_Platform -hw $xsa_path \
    -proc psu_cortexa53_0 -os standalone
platform write
platform generate

app create -name RFSOC -platform V10_Platform \
    -domain standalone_domain -template {Empty Application}
importsources -name RFSOC -path $source_dir -soft-link
app config -name RFSOC -set linker-script [file join $source_dir lscript.ld]
app config -name RFSOC -set compiler-optimization {Optimize more (-O2)}
app build -name RFSOC

puts "RESULT=PASS"
puts "WORKSPACE=$workspace"
exit 0

