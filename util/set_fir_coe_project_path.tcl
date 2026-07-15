# Rebind both FIR Compiler instances to the COE file stored in this project.
# Run from Vivado 2020.2:
#   vivado -mode batch -source util/set_fir_coe_project_path.tcl \
#     -tclargs ZCU111_V9_adc.xpr

if {$argc < 1} {
    puts "ERROR: usage: set_fir_coe_project_path.tcl <project.xpr>"
    exit 2
}

set project_path [file normalize [lindex $argv 0]]
set project_dir [file dirname $project_path]
set coe_relative_path {util/rrc_filter_10Mbps_alpha08.coe}
set coe_absolute_path [file join $project_dir $coe_relative_path]

if {![file exists $coe_absolute_path]} {
    puts "ERROR: FIR coefficient file not found: $coe_absolute_path"
    exit 3
}

cd $project_dir
open_project $project_path
open_bd_design [get_files */design_1.bd]

foreach cell_name {fir_compiler_0 fir_compiler_1} {
    set cell [get_bd_cells -quiet $cell_name]
    if {[llength $cell] != 1} {
        puts "ERROR: FIR cell not found: $cell_name"
        close_project
        exit 4
    }
    set_property CONFIG.CoefficientSource {COE_File} $cell
    # FIR Compiler 7.2 validates this parameter immediately and requires an
    # absolute path. The script derives it from the selected project so it can
    # be rerun after cloning the repository into a different directory.
    set_property CONFIG.Coefficient_File $coe_absolute_path $cell
}

validate_bd_design
save_bd_design
generate_target all [get_files */design_1.bd]

# Remove stale source-set entries left by older workspaces. The FIR IP keeps
# its own relative dependency after save_bd_design; the project source list
# should contain only the COE file from the current repository.
foreach source_file [get_files -quiet *rrc_filter_10Mbps_alpha08.coe] {
    set source_path [file normalize [get_property NAME $source_file]]
    if {![string equal -nocase $source_path [file normalize $coe_absolute_path]]} {
        puts "Removing stale FIR COE source entry: $source_path"
        remove_files $source_file
    }
}
if {[llength [get_files -quiet $coe_absolute_path]] == 0} {
    add_files -norecurse $coe_absolute_path
}

puts "FIR COE path rebound to: $coe_absolute_path"
close_project
exit 0
