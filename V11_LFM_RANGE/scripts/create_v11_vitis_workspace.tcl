set script_dir [file dirname [file normalize [info script]]]
set v11_root   [file normalize [file join $script_dir ..]]
set workspace  [file join $v11_root sw ws]
set xsa_path   [file join $v11_root sw design_1_wrapper.xsa]
set source_dir [file join $v11_root sw src]

if {![file exists $xsa_path]} {
    puts "ERROR: missing XSA: $xsa_path"
    exit 2
}

setws $workspace
platform create -name V11_LFM_Platform -hw $xsa_path \
    -proc psu_cortexa53_0 -os standalone
platform write
platform generate

app create -name V11_LFM_RANGE -platform V11_LFM_Platform \
    -domain standalone_domain -template {Empty Application}
importsources -name V11_LFM_RANGE -path $source_dir -soft-link
app config -name V11_LFM_RANGE -set linker-script [file join $source_dir lscript.ld]
app config -name V11_LFM_RANGE -set compiler-optimization {Optimize more (-O2)}
app build -name V11_LFM_RANGE

puts "RESULT=PASS"
puts "WORKSPACE=$workspace"
exit 0
