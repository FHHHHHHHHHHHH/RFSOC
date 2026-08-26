# 
# Usage: To re-create this platform project launch xsct with below options.
# xsct E:\Vivado_prj\ZCU111_V10_DPSK\sw\ws\RFSOC\platform.tcl
# 
# OR launch xsct and run below command.
# source E:\Vivado_prj\ZCU111_V10_DPSK\sw\ws\RFSOC\platform.tcl
# 
# To create the platform in a different location, modify the -out option of "platform create" command.
# -out option specifies the output directory of the platform project.

platform create -name {RFSOC}\
-hw {E:\Vivado_prj\ZCU111_V10_DPSK\sw\design_1_wrapper.xsa}\
-proc {psu_cortexa53_0} -os {standalone} -arch {64-bit} -fsbl-target {psu_cortexa53_0} -out {E:/Vivado_prj/ZCU111_V10_DPSK/sw/ws}

platform write
platform generate -domains 
platform active {RFSOC}
domain active {zynqmp_fsbl}
bsp reload
bsp setlib -name libmetal -ver 2.1
bsp write
bsp reload
catch {bsp regenerate}
platform generate
platform active {RFSOC}
platform generate -domains 
