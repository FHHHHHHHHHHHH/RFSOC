set script_dir [file dirname [file normalize [info script]]]
set rtl_dir [file normalize [file join $script_dir .. rtl]]
set part xczu28dr-ffvg1517-2-e

# 限制多线程占用以防止内存溢出
set_param general.maxThreads 1

foreach top {fast_decoder_ip market_event_reorder quant_stream_mux nn_decision_engine_ip order_book_engine_ip} {
  puts "=========================================================="
  puts ">>> Testing Synthesis for Module: $top"
  puts "=========================================================="
  create_project -in_memory -part $part
  read_verilog -sv [file join $rtl_dir ${top}.v]
  synth_design -top $top -part $part -mode out_of_context
  puts "CORE_SYNTH_${top}=PASS"
  close_project
}
puts "ALL_CORE_RTL_SYNTHESIS_PASS"
exit
