# 
# Usage: To re-create this platform project launch xsct with below options.
# xsct E:\Vivado_prj\ZCU111_V9_ADC\ZCU111_V9_adc\ws\ZCU111\platform.tcl
# 
# OR launch xsct and run below command.
# source E:\Vivado_prj\ZCU111_V9_ADC\ZCU111_V9_adc\ws\ZCU111\platform.tcl
# 
# To create the platform in a different location, modify the -out option of "platform create" command.
# -out option specifies the output directory of the platform project.

platform create -name {ZCU111}\
-hw {E:\Vivado_prj\ZCU111_V9_ADC\ZCU111_V9_adc\design_1_wrapper.xsa}\
-proc {psu_cortexa53_0} -os {standalone} -arch {64-bit} -fsbl-target {psu_cortexa53_0} -out {E:/Vivado_prj/ZCU111_V9_ADC/ZCU111_V9_adc/ws}

platform write
platform generate -domains 
platform active {ZCU111}
domain active {zynqmp_fsbl}
bsp reload
bsp setlib -name libmetal -ver 2.1
bsp write
bsp reload
catch {bsp regenerate}
platform generate
platform generate
