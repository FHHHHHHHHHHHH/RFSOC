@echo off
cd /d "%~dp0\.."
call "E:\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source util/build_highband_bitstream.tcl -tclargs ZCU111_V9_adc.xpr -nojournal -log util/build_highband_bitstream.vivado.log > util\build_highband_bitstream.console.log 2> util\build_highband_bitstream.console.err
echo %ERRORLEVEL%> util\build_highband_bitstream.exitcode
