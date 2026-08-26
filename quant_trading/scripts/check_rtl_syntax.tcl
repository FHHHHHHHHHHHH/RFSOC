set rtl_dir [file normalize [file join [file dirname [file normalize [info script]]] .. rtl]]
foreach f {fast_decoder_ip.v market_event_reorder.v order_book_engine_ip.v nn_decision_engine_ip.v quant_stream_mux.v} {
  read_verilog -sv [file join $rtl_dir $f]
}
puts "RTL_SYNTAX_CHECK=PASS"
exit
