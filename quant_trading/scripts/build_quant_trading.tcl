# Vivado 2020.2 stable synthesis flow for the ZCU111 quantitative-trading PL.
# Custom RTL blocks in this BD are module references, not packaged IPs.  Using
# global synthesis avoids the Vivado 2020.2 config_ip_cache failure seen when
# an OOC run calls get_ips on a module reference.

set script_dir [file dirname [file normalize [info script]]]
set proj_dir   [file normalize [file join $script_dir ..]]
set proj_file  [file join $proj_dir QUANT_TRADING.xpr]
set bd_name    design_quant
set top_name   design_quant_wrapper
set report_dir [file join $proj_dir reports synthesis]

proc qt_abort {message} {
    puts stderr "QT_SYNTH_ERROR=$message"
    catch {close_project}
    return -code error $message
}

proc qt_run_status {run_name} {
    set run_obj [get_runs -quiet $run_name]
    if {[llength $run_obj] == 0} { return "RUN_NOT_FOUND" }
    return [get_property STATUS $run_obj]
}

proc qt_connect_bd_pins {driver_name sink_name} {
    set driver [get_bd_pins -quiet $driver_name]
    set sink   [get_bd_pins -quiet $sink_name]
    if {[llength $driver] != 1 || [llength $sink] != 1} {
        qt_abort "Cannot connect $driver_name to $sink_name: pin not found"
    }

    set driver_net [get_bd_nets -quiet -of_objects $driver]
    set sink_net   [get_bd_nets -quiet -of_objects $sink]
    if {[llength $driver_net] == 1 && [llength $sink_net] == 1 && \
        $driver_net eq $sink_net} {
        return
    }
    if {[llength $driver_net] != 0 || [llength $sink_net] != 0} {
        qt_abort "Cannot connect $driver_name to $sink_name: one pin is already on another net"
    }
    connect_bd_net $driver $sink
}

if {![file exists $proj_file]} {
    qt_abort "Project file does not exist: $proj_file"
}

# The host has 16 GB RAM; individual Zynq/AXI runs can consume 2.5-3.5 GB.
set_param general.maxThreads 2
puts "QT_SYNTH_PROJECT=$proj_file"
puts "QT_SYNTH_MAX_THREADS=2"
open_project $proj_file

set bd_files [get_files -quiet */${bd_name}.bd]
if {[llength $bd_files] == 0} {
    set bd_path [file join $proj_dir QUANT_TRADING.srcs sources_1 bd \
        $bd_name ${bd_name}.bd]
    set bd_files [get_files -quiet $bd_path]
}
if {[llength $bd_files] != 1} {
    qt_abort "Expected one ${bd_name}.bd file, found [llength $bd_files]"
}
set bd_file [lindex $bd_files 0]
puts "QT_SYNTH_BD=$bd_file"

# Keep module references in the top-level synthesis flow, not OOC IP cache.
set_property SYNTH_CHECKPOINT_MODE None $bd_file
puts "QT_SYNTH_BD_MODE=[get_property SYNTH_CHECKPOINT_MODE $bd_file]"

open_bd_design $bd_file

# Apply the BRAM fixes to an existing project as well as to newly-created
# projects.  Delete the old constant that forced all BRAM reads to zero, then
# attach the order-book mirror to true-dual-port BRAM port B.
set ob_cell   [get_bd_cells -quiet order_book_engine_ip_0]
set bram_cell [get_bd_cells -quiet blk_mem_kvs]
set rst_cell  [get_bd_cells -quiet proc_sys_reset_0]
if {[llength $ob_cell] != 1 || [llength $bram_cell] != 1 || \
    [llength $rst_cell] != 1} {
    qt_abort "Required order-book, BRAM or reset BD cell is missing"
}
set_property -dict [list CONFIG.BRAM_ADDR_WIDTH {32} \
    CONFIG.BRAM_DATA_WIDTH {64}] $ob_cell
set_property -dict [list CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.Write_Width_A {64} CONFIG.Read_Width_A {64} \
    CONFIG.Write_Depth_A {1024} CONFIG.Write_Width_B {64} \
    CONFIG.Read_Width_B {64}] $bram_cell

set old_bram_constant [get_bd_cells -quiet bram_rd_0]
if {[llength $old_bram_constant] == 1} {
    delete_bd_objs $old_bram_constant
}
# Removing a BD cell can leave its old scalar net object behind.  Delete any
# existing nets on the six module-reference/BRAM pins before reconnecting them.
foreach pin_name {
    order_book_engine_ip_0/bram_clk order_book_engine_ip_0/bram_en
    order_book_engine_ip_0/bram_addr order_book_engine_ip_0/bram_wrdata
    order_book_engine_ip_0/bram_rddata order_book_engine_ip_0/bram_we
    blk_mem_kvs/clkb blk_mem_kvs/enb blk_mem_kvs/addrb blk_mem_kvs/dinb
    blk_mem_kvs/doutb blk_mem_kvs/web blk_mem_kvs/rstb
} {
    set old_nets [get_bd_nets -quiet -of_objects [get_bd_pins -quiet $pin_name]]
    if {[llength $old_nets] != 0} {
        delete_bd_objs $old_nets
    }
}
qt_connect_bd_pins order_book_engine_ip_0/bram_clk blk_mem_kvs/clkb
qt_connect_bd_pins order_book_engine_ip_0/bram_en blk_mem_kvs/enb
qt_connect_bd_pins order_book_engine_ip_0/bram_addr blk_mem_kvs/addrb
qt_connect_bd_pins order_book_engine_ip_0/bram_wrdata blk_mem_kvs/dinb
qt_connect_bd_pins blk_mem_kvs/doutb order_book_engine_ip_0/bram_rddata
qt_connect_bd_pins order_book_engine_ip_0/bram_we blk_mem_kvs/web
qt_connect_bd_pins proc_sys_reset_0/peripheral_reset blk_mem_kvs/rstb

if {[catch {validate_bd_design} validate_msg]} {
    qt_abort "BD validation failed: $validate_msg"
}
save_bd_design
if {[catch {generate_target all $bd_file} generate_msg]} {
    qt_abort "BD output-product generation failed: $generate_msg"
}

set wrapper_files [get_files -quiet */${top_name}.v]
if {[llength $wrapper_files] == 0} {
    if {[catch {make_wrapper -files $bd_file -top} wrapper_msg]} {
        qt_abort "Wrapper generation failed: $wrapper_msg"
    }
    set wrapper_path [file join $proj_dir QUANT_TRADING.gen sources_1 bd \
        $bd_name hdl ${top_name}.v]
    if {![file exists $wrapper_path]} {
        qt_abort "Generated wrapper was not found: $wrapper_path"
    }
    add_files -norecurse $wrapper_path
}
set_property top $top_name [current_fileset]
update_compile_order -fileset sources_1

if {[llength [get_runs -quiet synth_1]] != 1} {
    qt_abort "synth_1 run was not found in the project"
}

# SYNTH_CHECKPOINT_MODE=None makes the BD part of the global top-level
# synthesis.  Remove stale hierarchical OOC runs left by the earlier flow;
# merely resetting synth_1 is insufficient because Vivado refuses to launch a
# parent run while any recorded child run remains in an error state.
set stale_impl_runs [get_runs -quiet design_quant_*_impl_1]
foreach stale_run $stale_impl_runs {
    puts "QT_DELETE_STALE_RUN=[get_property NAME $stale_run]"
    if {[catch {delete_runs $stale_run} delete_msg]} {
        qt_abort "Unable to delete stale implementation run: $delete_msg"
    }
}
set stale_synth_runs [get_runs -quiet design_quant_*_synth_1]
foreach stale_run $stale_synth_runs {
    puts "QT_DELETE_STALE_RUN=[get_property NAME $stale_run]"
    if {[catch {delete_runs $stale_run} delete_msg]} {
        qt_abort "Unable to delete stale synthesis run: $delete_msg"
    }
}

reset_run synth_1
puts "QT_SYNTH_START=[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
if {[catch {launch_runs synth_1 -jobs 1} launch_msg]} {
    qt_abort "Unable to launch synth_1: $launch_msg"
}
set wait_rc [catch {wait_on_run synth_1} wait_msg]
set synth_status [qt_run_status synth_1]
set synth_progress [get_property PROGRESS [get_runs synth_1]]
puts "QT_SYNTH_STATUS=$synth_status"
puts "QT_SYNTH_PROGRESS=$synth_progress"
set synth_dcp [file join $proj_dir QUANT_TRADING.runs synth_1 ${top_name}.dcp]
if {$wait_rc != 0 || ![string match -nocase "*Complete*" $synth_status] || \
    ![file exists $synth_dcp]} {
    set run_log [file join $proj_dir QUANT_TRADING.runs synth_1 runme.log]
    qt_abort "Synthesis did not complete successfully; status='$synth_status'; inspect $run_log"
}

file mkdir $report_dir
if {[catch {
    open_run synth_1
    report_utilization -file [file join $report_dir utilization_synth.rpt]
    report_timing_summary -delay_type max -max_paths 20 \
        -file [file join $report_dir timing_summary_synth.rpt]
} report_msg]} {
    puts stderr "QT_SYNTH_REPORT_WARNING=$report_msg"
}
puts "QT_SYNTH_DCP=$synth_dcp"
puts "QT_SYNTH_REPORT_DIR=$report_dir"
puts "QT_SYNTH_END=[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
puts "QT_SYNTH_RESULT=PASS"
close_project
