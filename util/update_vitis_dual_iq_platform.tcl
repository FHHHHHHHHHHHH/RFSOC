# Update the existing Vitis 2020.2 platform from the current XSA.

set project_root [file normalize [file join [file dirname [info script]] ..]]
set workspace_path [file join $project_root ws]
set xsa_path [file join $project_root design_1_wrapper.xsa]

setws $workspace_path
platform active ZCU111
platform config -updatehw $xsa_path
platform write

domain active standalone_domain
bsp reload
if {[catch {bsp regenerate} message]} {
    puts "ERROR: standalone_domain BSP regenerate failed: $message"
    exit 2
}

domain active zynqmp_fsbl
bsp reload
if {[catch {bsp regenerate} message]} {
    puts "ERROR: zynqmp_fsbl BSP regenerate failed: $message"
    exit 3
}

platform generate -domains standalone_domain,zynqmp_fsbl
puts "RESULT: PASS"
exit 0
