$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$vivadoBin = 'E:\Xilinx\Vivado\2020.2\bin'
$work = Join-Path $root 'quant_trading\sim\work'
New-Item -ItemType Directory -Force -Path $work | Out-Null
Push-Location $work
& (Join-Path $vivadoBin 'xvlog.bat') -sv (Join-Path $root 'quant_trading\rtl\fast_decoder_ip.v') (Join-Path $root 'quant_trading\rtl\market_event_reorder.v') (Join-Path $root 'quant_trading\rtl\order_book_engine_ip.v') (Join-Path $root 'quant_trading\sim\tb_fast_orderbook.sv') (Join-Path $root 'quant_trading\sim\tb_market_sequence.sv')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& (Join-Path $vivadoBin 'xelab.bat') tb_fast_orderbook -s tb_fast_orderbook_sim
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& (Join-Path $vivadoBin 'xsim.bat') tb_fast_orderbook_sim -runall
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& (Join-Path $vivadoBin 'xelab.bat') tb_market_sequence -s tb_market_sequence_sim
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& (Join-Path $vivadoBin 'xsim.bat') tb_market_sequence_sim -runall
Pop-Location
