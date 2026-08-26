# Vivado 2020.2 - ZCU111 Stage-2 quantitative trading PL framework
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir .. ..]]
set proj_dir   [file join $root_dir quant_trading]
set proj_name  QUANT_TRADING
set part       xczu28dr-ffvg1517-2-e
set board      xilinx.com:zcu111:part0:1.4

file mkdir $proj_dir
create_project -force $proj_name $proj_dir -part $part
set_property board_part $board [current_project]
set_property target_language Verilog [current_project]

set rtl_dir [file join $proj_dir rtl]
file mkdir $rtl_dir
foreach f {fast_decoder_ip.v market_event_reorder.v order_book_engine_ip.v nn_decision_engine_ip.v quant_stream_mux.v} {
    add_files -norecurse [file join $rtl_dir $f]
}

create_bd_design design_quant
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.3 zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
set_property -dict [list \
    CONFIG.PSU__USE__IRQ0 {1} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {250} \
] $ps

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]
set sc  [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smartconnect_ctrl]
set_property -dict [list CONFIG.NUM_MI {5} CONFIG.NUM_SI {1}] $sc
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_quant]
set_property -dict [list CONFIG.c_include_sg {0} CONFIG.c_m_axi_s2mm_data_width {256} CONFIG.c_s_axis_s2mm_tdata_width {256} CONFIG.c_include_mm2s {0} CONFIG.c_include_s2mm {1}] $dma
set dwidth [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dwidth_converter:2.1 axi_dwidth_dma]
set_property -dict [list CONFIG.SI_DATA_WIDTH {256} CONFIG.MI_DATA_WIDTH {128}] $dwidth
set fifo [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 axis_fifo_snapshot]
set_property -dict [list CONFIG.TDATA_NUM_BYTES {32} CONFIG.FIFO_DEPTH {1024}] $fifo
set broadcaster [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_broadcaster:1.1 axis_broadcaster_snapshot]
set_property -dict [list CONFIG.NUM_MI {2}] $broadcaster
set bram [create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 blk_mem_kvs]
set_property -dict [list \
    CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.Write_Width_A {64} CONFIG.Read_Width_A {64} \
    CONFIG.Write_Depth_A {1024} \
    CONFIG.Write_Width_B {64} CONFIG.Read_Width_B {64} \
] $bram
set bramc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 axi_bram_ctrl_kvs]
set_property -dict [list CONFIG.DATA_WIDTH {64} CONFIG.SINGLE_PORT_BRAM {0}] $bramc

foreach {ref name} {fast_decoder_ip fast_decoder_ip_0 market_event_reorder market_event_reorder_0 order_book_engine_ip order_book_engine_ip_0 nn_decision_engine_ip nn_decision_engine_ip_0 quant_stream_mux quant_stream_mux_0} {
    create_bd_cell -type module -reference $ref $name
}
set_property -dict [list CONFIG.BRAM_ADDR_WIDTH {32} CONFIG.BRAM_DATA_WIDTH {64}] [get_bd_cells order_book_engine_ip_0]

# Clock/reset backbone.
connect_bd_net [get_bd_pins $ps/pl_clk0] [get_bd_pins $rst/slowest_sync_clk] [get_bd_pins $sc/aclk] [get_bd_pins $dma/s_axi_lite_aclk] [get_bd_pins $dma/m_axi_s2mm_aclk] [get_bd_pins $fifo/s_axis_aclk] [get_bd_pins fast_decoder_ip_0/aclk] [get_bd_pins market_event_reorder_0/aclk] [get_bd_pins order_book_engine_ip_0/aclk] [get_bd_pins nn_decision_engine_ip_0/aclk] [get_bd_pins quant_stream_mux_0/aclk] [get_bd_pins axi_bram_ctrl_kvs/s_axi_aclk] [get_bd_pins axis_broadcaster_snapshot/aclk] [get_bd_pins $dwidth/s_axi_aclk]
connect_bd_net [get_bd_pins $ps/pl_clk0] [get_bd_pins $ps/maxihpm0_fpd_aclk] [get_bd_pins $ps/maxihpm1_fpd_aclk] [get_bd_pins $ps/saxihp0_fpd_aclk]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $rst/ext_reset_in]
connect_bd_net [get_bd_pins $rst/peripheral_aresetn] [get_bd_pins fast_decoder_ip_0/aresetn] [get_bd_pins market_event_reorder_0/aresetn] [get_bd_pins order_book_engine_ip_0/aresetn] [get_bd_pins nn_decision_engine_ip_0/aresetn] [get_bd_pins quant_stream_mux_0/aresetn] [get_bd_pins axis_broadcaster_snapshot/aresetn]
connect_bd_net [get_bd_pins $rst/peripheral_aresetn] [get_bd_pins $dma/axi_resetn]
connect_bd_net [get_bd_pins $rst/peripheral_aresetn] [get_bd_pins $dwidth/s_axi_aresetn]
connect_bd_net [get_bd_pins $rst/peripheral_aresetn] [get_bd_pins $fifo/s_axis_aresetn]
connect_bd_net [get_bd_pins $rst/peripheral_aresetn] [get_bd_pins $bramc/s_axi_aresetn]

# External raw STEP/FAST source.  Replace this top-level AXIS port with the
# selected 10/25/40G MAC/UDP/TOE adapter in the board-level design.
set raw_axis [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 S_AXIS_RAW]
set_property -dict [list CONFIG.TDATA_NUM_BYTES {64} CONFIG.HAS_TKEEP {0} CONFIG.HAS_TSTRB {0} CONFIG.FREQ_HZ {249997498}] $raw_axis
connect_bd_intf_net [get_bd_intf_ports S_AXIS_RAW] [get_bd_intf_pins fast_decoder_ip_0/s_axis_raw]
# Connect the order-book mirror to BRAM port B.  Port A remains owned by the
# AXI BRAM controller for PS access.
connect_bd_net [get_bd_pins order_book_engine_ip_0/bram_clk] \
    [get_bd_pins $bram/clkb]
connect_bd_net [get_bd_pins order_book_engine_ip_0/bram_en] \
    [get_bd_pins $bram/enb]
connect_bd_net [get_bd_pins order_book_engine_ip_0/bram_addr] \
    [get_bd_pins $bram/addrb]
connect_bd_net [get_bd_pins order_book_engine_ip_0/bram_wrdata] \
    [get_bd_pins $bram/dinb]
connect_bd_net [get_bd_pins $bram/doutb] \
    [get_bd_pins order_book_engine_ip_0/bram_rddata]
connect_bd_net [get_bd_pins order_book_engine_ip_0/bram_we] \
    [get_bd_pins $bram/web]
connect_bd_net [get_bd_pins $rst/peripheral_reset] \
    [get_bd_pins $bram/rstb]

# AXI-Lite/control and memory: PS HPM and DMA S2MM feed SmartConnect. The
# latter routes the write stream into the BRAM-backed sink on this ZCU111
# framework; a PS HP DDR endpoint can be substituted when enabled by the
# installed PS IP/board preset.
# the three custom IP register banks. Exact address assignment is deferred to
# the board design review; assign_bd_address below creates deterministic maps.
connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] [get_bd_intf_pins $sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M00_AXI] [get_bd_intf_pins $dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins $sc/M01_AXI] [get_bd_intf_pins $bramc/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc/M02_AXI] [get_bd_intf_pins fast_decoder_ip_0/s_axi_ctrl]
connect_bd_intf_net [get_bd_intf_pins $sc/M03_AXI] [get_bd_intf_pins order_book_engine_ip_0/s_axi_ctrl]
connect_bd_intf_net [get_bd_intf_pins $sc/M04_AXI] [get_bd_intf_pins nn_decision_engine_ip_0/s_axi_ctrl]
connect_bd_intf_net [get_bd_intf_pins $bramc/BRAM_PORTA] [get_bd_intf_pins $bram/BRAM_PORTA]

# DMA writes snapshots/signals into PS DDR through HP0.
connect_bd_intf_net [get_bd_intf_pins $fifo/M_AXIS] [get_bd_intf_pins $dma/S_AXIS_S2MM]
connect_bd_intf_net [get_bd_intf_pins $dma/M_AXI_S2MM] [get_bd_intf_pins $dwidth/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $dwidth/M_AXI] [get_bd_intf_pins $ps/S_AXI_HP0_FPD]
connect_bd_net [get_bd_pins $dma/s2mm_introut] [get_bd_pins $ps/pl_ps_irq0]

# Dataflow: decoder -> order book -> NN -> signal mux -> DMA FIFO.
connect_bd_intf_net [get_bd_intf_pins fast_decoder_ip_0/m_axis_decoded] [get_bd_intf_pins market_event_reorder_0/s_axis]
connect_bd_intf_net [get_bd_intf_pins market_event_reorder_0/m_axis] [get_bd_intf_pins order_book_engine_ip_0/s_axis_decoded]
connect_bd_intf_net [get_bd_intf_pins order_book_engine_ip_0/m_axis_snapshot] [get_bd_intf_pins $broadcaster/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins $broadcaster/M00_AXIS] [get_bd_intf_pins nn_decision_engine_ip_0/s_axis_feat]
connect_bd_intf_net [get_bd_intf_pins $broadcaster/M01_AXIS] [get_bd_intf_pins quant_stream_mux_0/s_snapshot]
connect_bd_intf_net [get_bd_intf_pins nn_decision_engine_ip_0/m_axis_signal] [get_bd_intf_pins quant_stream_mux_0/s_signal]
connect_bd_intf_net [get_bd_intf_pins quant_stream_mux_0/m_axis] [get_bd_intf_pins $fifo/S_AXIS]

assign_bd_address
validate_bd_design
save_bd_design
make_wrapper -files [get_files [file join $proj_dir $proj_name.srcs sources_1 bd design_quant design_quant.bd]] -top
add_files -norecurse [file join $proj_dir $proj_name.gen sources_1 bd design_quant hdl design_quant_wrapper.v]
update_compile_order -fileset sources_1
set_property top design_quant_wrapper [current_fileset]
close_project
puts "QUANT_TRADING_PROJECT_CREATED=$proj_dir"
