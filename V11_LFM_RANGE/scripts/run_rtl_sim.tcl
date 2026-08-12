set script_dir [file dirname [file normalize [info script]]]
set v11_root [file normalize [file join $script_dir ..]]
set sim_dir [file join $v11_root sim]

cd $sim_dir
set xvlog {E:/Xilinx/Vivado/2020.2/bin/xvlog.bat}
set xelab {E:/Xilinx/Vivado/2020.2/bin/xelab.bat}
set xsim  {E:/Xilinx/Vivado/2020.2/bin/xsim.bat}

exec $xvlog -sv \
    [file join $v11_root rtl lfm_radar_core.v] \
    [file join $sim_dir tb_lfm_radar_core.sv]
exec $xelab \
    tb_lfm_radar_core -s tb_lfm_radar_core_sim
set sim_output [exec $xsim tb_lfm_radar_core_sim -runall]
puts $sim_output
exit 0
