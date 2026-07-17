# ZCU111 V10 恒包络 DBPSK 收发工程

最后更新：2026-07-15

## 当前架构

```text
PS UART SEND/TRAS
  -> AXI FIFO MM-S TX
  -> asynchronous AXIS FIFO
  -> dual_dac_dbpsk_tx
       -> DAC10 identical constant-envelope DBPSK
       -> DAC11 identical constant-envelope DBPSK
  -> RFDC C2R fine mixer, default 2400 MHz

DAC10 J7 -> ADC10 J2
  -> RFDC R2C IQ, default ADC NCO 2390 MHz
  -> complex IF approximately -10 MHz
  -> dbpsk_adc_rx_v10
  -> asynchronous AXIS FIFO
  -> AXI FIFO MM-S RX
  -> PS UART decoded payload
```

DAC10/DAC11 use exactly the same digital DBPSK state. The PS `PASE` command
sets symmetric RFDC phases:

```text
DAC10 phase = -phase_difference / 2
DAC11 phase = +phase_difference / 2
```

No RRC FIR is used. Idle output is a continuous positive-I carrier. During a
symbol the output remains at `+32767` or `-32767`, so each DAC branch is
constant envelope.

## Frame format

One byte is carried in the low eight bits of each AXI FIFO word. Bits are sent
MSB first.

```text
FF FF FF FF
D3 91 C5 A7
payload length, 16-bit big endian
payload, 0..256 bytes
CRC16-CCITT, big endian
```

CRC initial value is `FFFF`, polynomial `1021`, calculated over the two length
bytes and payload.

## Receiver

ADC I and Q each provide two signed 16-bit samples per 32-bit AXIS beat. The
receiver uses sample 0, so its processing rate is 184.32 MSPS.

The receiver contains:

- a complex NCO for the measured `-10 MHz` ADC IQ convention;
- pipelined complex downconversion;
- idle-carrier phase-reference estimation;
- phase-transition based symbol-clock acquisition;
- differential bit decisions at 10 Mbps;
- sync-word, length and CRC checking;
- a 256-byte payload buffer;
- AXIS packet output to the PS-side FIFO.

Functional simulation uses an ideal DAC/NCO/cable/ADC model and decodes
`HELLO` with `good_frame_count=1`, `bad_frame_count=0`.

## UART commands

```text
SEND Hello RFSoC
LOOP RFSOC
STOP
TRAS 01010101
DACF 2400
ADCF 2390
PASE 60
AMPL 1.0
DACR
ADCR
STAT
HELP
```

The receiver currently expects:

```text
DAC NCO - ADC NCO = +10 MHz
```

## Important files

```text
V10_DPSK/V10_DPSK.srcs/sources_1/new/dual_dac_dbpsk_tx.v
V10_DPSK/V10_DPSK.srcs/sources_1/new/dbpsk_adc_rx.v
sim/tb_dbpsk_loopback.sv
sw/RFSOC/src/main.c
scripts/update_v10_dbpsk_bd.tcl
scripts/build_v10_direct.tcl
scripts/export_v10_xsa_nobit.tcl
scripts/create_v10_vitis_workspace.tcl
```

## Build status

- Block Design validation: PASS.
- End-to-end RTL functional simulation: PASS.
- Full synthesis, placement and routing: PASS.
- Timing: PASS, WNS `+0.563 ns`, TNS `0 ns`.
- Routing: 27258/27258 routable nets fully routed, 0 routing errors.
- DRC: 0 errors; warnings are DSP pipeline recommendations and existing
  FIFO/no-load advisories.
- `sw/hardware/design_1_wrapper.bit`: generated.
- `sw/hardware/design_1_wrapper.ltx`: generated for ILA/VIO probes.
- `sw/design_1_wrapper.xsa`: generated and verified to contain
  `design_1_wrapper.bit`.
- V10 standalone Platform/BSP: generated.
- `sw/build/RFSOC.elf`: generated using the V10 BSP.
- Final hardware and software artifacts were regenerated from the same V10
  design on 2026-07-16.
- Board validation: PASS. RFDC Tile1 startup, UART commands, AXI FIFO TX/RX,
  `SEND Hello RFSoC`, `TRAS 01010101` and DAC10-to-ADC10 DBPSK demodulation
  were confirmed on hardware.
- `LOOP <text>` and `STOP` continuous framed-transmission commands were added
  after the board validation above and pass AArch64 compile/link verification;
  their final continuous-mode counters still require board confirmation.

To rebuild the complete hardware:

```powershell
E:\Xilinx\Vivado\2020.2\bin\vivado.bat -mode batch `
  -source scripts\build_v10_direct.tcl
```

The script writes the bitstream and reports under `sw/hardware` and replaces
`sw/design_1_wrapper.xsa` with an XSA that includes the bitstream.

## Board startup diagnostic (2026-07-16)

The first V10 board launch reached clock programming but reported the generic
`[FATAL] RFDC startup failed` message. The known FSBL message
`PMU-FW is not running` is also present in the verified V9 flow and is not
treated as the RFDC startup root cause.

An initial experiment added strict checks to the copied Xilinx clock example.
It exposed a transient failure on the second ADC LMX write, but this behavior
is also ignored by the verified V9 example. At the user's request, the V10
copies of `xrfdc_clk.c/.h` were restored byte-for-byte to the V9 versions; the
installed Xilinx sources were never modified.

The retained diagnostics are confined to the application layer:

- DAC/ADC tile state, power state, PLL state and block mask are printed before
  startup and after any startup failure;
- the failing tile and `XRFdc_StartUp()` return code are printed.

The current V10 diagnostic application is:

```text
sw/codex_build/RFSOC1_v9clock_diag.elf
```

It is an AArch64 ELF64 image compiled against the V10 platform BSP. The FPGA
bitstream does not need to be rebuilt for this diagnostic.

The verified V9 application was copied without modification for A/B startup
testing:

```text
sw/codex_build/RFSOC_V9_reference.elf
```

The application-layer root cause was then identified. In the 2020.2 RFDC
driver, `XRFdc_GetIPStatus()` sets `IsEnabled` for enabled tiles but does not
clear `IsEnabled` for disabled tiles. The V10 stack happened to contain a
non-zero value for DAC Tile0, causing the application to call
`XRFdc_StartUp()` on disabled DAC Tile0 even though DAC Tile1 and ADC Tile1
were already reported in state `0xF`.

The fix does not modify the Xilinx driver or clock example:

- zero-initialize every `XRFdc_IPStatus` structure before status readback;
- start only the explicitly configured `DAC_TILE_ID=1` and `ADC_TILE_ID=1`.

The resulting board-test ELF is:

```text
sw/codex_build/RFSOC1_tile1_fix.elf
```

After RFDC startup was fixed, the first command prompt could not accept UART
input. UART0 input/output addresses were confirmed identical (`0xFF000000`).
The cause was the application loop polling the receive FIFO before the UART
without first checking that a complete RX packet existed. The FIFO poll could
therefore prevent the UART poll from running.

The application now:

- polls UART before the receive FIFO;
- reads the receive FIFO only when `XLlFifo_IsRxDone()` is asserted;
- clears stale FIFO interrupt flags after initialization and after a packet.

The resulting ELF is:

```text
sw/codex_build/RFSOC1_uart_fix.elf
```
