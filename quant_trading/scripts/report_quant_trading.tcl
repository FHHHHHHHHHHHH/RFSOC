set script_dir [file dirname [file normalize [info script]]]
set proj [file join [file normalize [file join $script_dir ..]] QUANT_TRADING.xpr]
open_project $proj
puts "SYNTH_STATUS=[get_property STATUS [get_runs synth_1]]"
puts "SYNTH_PROG=[get_property PROGRESS [get_runs synth_1]]"
close_project
