set script_dir [file dirname [file normalize [info script]]]
set rtl_dir [file normalize [file join $script_dir .. rtl]]
set part xczu28dr-ffvg1517-2-e
foreach top {fast_decoder_ip market_event_reorder order_book_engine_ip} {
  create_project -in_memory -part $part
  read_verilog -sv [file join $rtl_dir ${top}.v]
  synth_design -top $top -part $part -mode out_of_context
  puts "CORE_SYNTH_${top}=PASS"
  close_project
}
exit
