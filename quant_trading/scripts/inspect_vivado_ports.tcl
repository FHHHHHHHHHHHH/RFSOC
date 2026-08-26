create_project -force inspect_tmp [file join [pwd] quant_trading inspect_tmp] -part xczu28dr-ffvg1517-2-e
set_property board_part xilinx.com:zcu111:part0:1.4 [current_project]
create_bd_design inspect
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.3 ps]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
set_property CONFIG.PSU__USE__S_AXI_GP2 1 $ps
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 dma]
set br [create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 br]
set bc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 bc]
set af [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 af]
puts "PS_INTF=[get_bd_intf_pins $ps/*]"
puts "PS_PINS=[get_bd_pins $ps/*]"
puts "DMA_INTF=[get_bd_intf_pins $dma/*]"
puts "DMA_PINS=[get_bd_pins $dma/*]"
puts "BR_INTF=[get_bd_intf_pins $br/*]"
puts "BC_INTF=[get_bd_intf_pins $bc/*]"
puts "BC_PINS=[get_bd_pins $bc/*]"
puts "AF_PINS=[get_bd_pins $af/*]"
puts "PS_CONFIG=[lsort [list_property $ps CONFIG.*]]"
puts "DMA_CONFIG=[lsort [list_property $dma CONFIG.*]]"
puts "PS_HP_CONFIG=[lsort [lsearch -all -inline [list_property $ps CONFIG.*] *HP*]]"
close_project
