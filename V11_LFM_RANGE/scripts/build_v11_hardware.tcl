set script_dir [file dirname [file normalize [info script]]]
set v11_root   [file normalize [file join $script_dir ..]]
set project    [file join $v11_root V11_LFM_RANGE.xpr]
set xsa_path   [file join $v11_root sw design_1_wrapper.xsa]
set tracked_xsa_path [file join $v11_root design_1_wrapper.xsa]

if {![file exists $project]} {
    puts "ERROR: missing project: $project"
    exit 2
}

open_project $project

set bd_path [file join $v11_root V11_LFM_RANGE.srcs sources_1 bd design_1 design_1.bd]
set bd_file [get_files -quiet $bd_path]
if {[llength $bd_file] != 1} {
    error "Cannot find Block Design source: $bd_path"
}

# Release builds temporarily remove the large System ILA.  Vivado may update
# the BD source while generating products, so protect and restore it even when
# a run fails.  V11_KEEP_ILA=1 performs a normal debug build and still uses the
# same recovery path.
set backup_dir [file join $v11_root .codex_build_backup]
set backup_bd  [file join $backup_dir design_1.bd]
set backup_ip_dir [file join $backup_dir ip]
file mkdir $backup_dir
file copy -force $bd_path $backup_bd

# Deleting a BD cell can also remove its source XCI.  Preserve all ILA XCI
# files by their original relative directory so the restored BD continues to
# reference the same source object after a release build.
set bd_ip_dir [file join [file dirname $bd_path] ip]
set backed_ip_files {}
foreach ila_xci [glob -nocomplain -type f -directory $bd_ip_dir *system_ila*.xci] {
    set ila_rel_dir [file tail [file dirname $ila_xci]]
    set ila_backup_dir [file join $backup_ip_dir $ila_rel_dir]
    file mkdir $ila_backup_dir
    set ila_backup [file join $ila_backup_dir [file tail $ila_xci]]
    file copy -force $ila_xci $ila_backup
    lappend backed_ip_files [list $ila_backup $ila_xci]
}

set build_code [catch {
    open_bd_design $bd_file

    set keep_ila 0
    if {[info exists ::env(V11_KEEP_ILA)]} {
        set keep_ila [string is true -strict $::env(V11_KEEP_ILA)]
    }
    if {!$keep_ila} {
        set ila_cell [get_bd_cells -quiet system_ila_1]
        if {[llength $ila_cell] == 1} {
            delete_bd_objs $ila_cell
            validate_bd_design
            puts "BUILD_MODE=release_no_ila"
        } else {
            error "Expected system_ila_1 for release build, but it was not found"
        }
    } else {
        puts "BUILD_MODE=debug_with_ila"
    }

    # Regenerate products before launching runs.  Register the generated OOC
    # XDC explicitly because a clean clone can have it on disk but absent from
    # Vivado's file-object database.
    generate_target all $bd_file

    set ooc_xdc [file join $v11_root V11_LFM_RANGE.gen sources_1 bd design_1 design_1_ooc.xdc]
    set ooc_file [get_files -quiet -all $ooc_xdc]
    if {[llength $ooc_file] == 0} {
        error "Block Design OOC constraint is not registered: $ooc_xdc"
    }

    update_compile_order -fileset sources_1

    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    set synth_status [get_property STATUS [get_runs synth_1]]
    puts "SYNTH_STATUS=$synth_status"
    if {![string match "*Complete*" $synth_status]} {
        error "synth_1 did not complete"
    }

    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
    set impl_status [get_property STATUS [get_runs impl_1]]
    puts "IMPL_STATUS=$impl_status"
    if {![string match "*Complete*" $impl_status]} {
        error "impl_1 did not complete through write_bitstream"
    }

    open_run impl_1
    file mkdir [file dirname $xsa_path]
    write_hw_platform -fixed -include_bit -force -file $xsa_path
    puts "WROTE_XSA=$xsa_path"
    file copy -force $xsa_path $tracked_xsa_path
    puts "WROTE_TRACKED_XSA=$tracked_xsa_path"
} build_error]

# Always close Vivado before restoring the source BD.  This prevents an open
# BD object from immediately writing the temporary release graph back again.
catch {close_project}
if {[file exists $backup_bd]} {
    file copy -force $backup_bd $bd_path
}
foreach ip_pair $backed_ip_files {
    lassign $ip_pair ila_backup ila_xci
    file mkdir [file dirname $ila_xci]
    file copy -force $ila_backup $ila_xci
}
catch {file delete -force $backup_dir}

if {$build_code != 0} {
    puts stderr $build_error
    exit 1
}
exit 0
