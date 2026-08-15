set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file dirname $script_dir]
set workspace_dir [file join $script_dir ws]
set xsa_file [file join $script_dir hardware zcu111_v20_dpd.xsa]
set source_dir [file join $script_dir RFSOC src]

if {![file exists $xsa_file]} {
    error "Missing $xsa_file; run V20_DPD/scripts/export_dpd_xsa.tcl first"
}

setws $workspace_dir

set platform_name zcu111_v20_dpd_platform
set app_name RFSOC_DPD
set platform_created 0
if {[lsearch -exact [getprojects] $platform_name] < 0} {
    platform create -name $platform_name -hw $xsa_file
    platform active $platform_name
    domain create -name standalone_domain -os standalone -proc psu_cortexa53_0
    set platform_created 1
} else {
    platform active $platform_name
}
set platform_file [file join $workspace_dir $platform_name export $platform_name ${platform_name}.xpfm]
if {$platform_created || ![file exists $platform_file]} {
    platform generate
}

if {[lsearch -exact [getprojects] $app_name] < 0} {
    app create -name $app_name -platform $platform_name \
        -domain standalone_domain -template {Empty Application}
}
importsources -name $app_name -path $source_dir
# Vitis 2020.2 records a directory-imported linker script as an external
# source but still generates a make dependency on ../src/lscript.ld.
file copy -force [file join $source_dir lscript.ld] \
    [file join $workspace_dir $app_name src lscript.ld]
app build -name $app_name

# Vitis 2020.2 starts the managed build asynchronously.  Wait for the ELF so
# batch mode does not close the workspace while the final link is pending.
set elf_file [file join $workspace_dir $app_name Debug ${app_name}.elf]
for {set wait_count 0} {$wait_count < 120 && ![file exists $elf_file]} {incr wait_count} {
    after 1000
}
if {![file exists $elf_file]} {
    error "Timed out waiting for $elf_file"
}

puts "VITIS_DPD_BUILD_COMPLETE"
