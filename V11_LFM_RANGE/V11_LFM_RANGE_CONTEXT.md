# V11_LFM_RANGE project context

## Goal

Independent ZCU111 short-range LFM radar workspace derived from the verified V10 RFDC/clock baseline. V10 must remain unchanged. First milestone is coax + attenuator delay measurement; second is a 0.5–20 m moving single-target free-space test with a 30 dBm PA, directional coupler, circulator and one antenna. UART prints only the latest range.

## Fixed architecture

- DAC10: primary LFM transmitter.
- DAC11: identical LFM debug output; it may remain disconnected.
- ADC10 (`m10/m11`): echo complex I/Q.
- ADC12 (`m12/m13`): PA-output/reference-tap complex I/Q.
- DAC and ADC NCO defaults: 2400 MHz.
- LFM bandwidth: 400 MHz.
- PL timing/data clock: 184.32 MHz.
- ADC decimation/data width: 4/4, four 16-bit samples per I and Q beat.
- Complex sample rate: 737.28 MSPS.
- Pulse: 4096 samples = 1024 beats = 5.5556 us.
- Capture: 8192 samples = 2048 beats = 11.1111 us.
- PRF: 10 kHz.
- Search: 128 positive relative lags, approximately 0–26 m.
- Correlation: `echo[n+lag] * conj(reference[n])`, complex background subtracted per lag.
- Score: `abs(real) + abs(imaginary)`.
- Software interpolation: three-point parabolic estimate from left/peak/right scores.
- Raw range scale: 203.3094618 mm per lag sample.

## Why this differs from the reference thesis

The paper's ROM/timing/capture/pulse-compression partition is retained. Its half-duplex RF switch and long receive delay are not: they create a near-range blind zone incompatible with 0.5–20 m. V11 captures during transmission and uses an independent ADC12 reference, followed by complex static-leakage calibration.

## PL command protocol

One 32-bit AXI Stream packet from PS:

- `0x524E4701`: START.
- `0x524E4700`: STOP.
- `0x42474341`: BGCAL; the next processed capture becomes the complex background.

## PL result protocol

Six 32-bit AXI Stream words, TLAST on word 5:

1. `0x524E4731` magic.
2. `{sequence[15:0], peak_lag[15:0]}`.
3. peak score.
4. left-neighbor score.
5. right-neighbor score.
6. flags: bit0 enabled, bit1 calibration result, bit2 background valid.

Scores are correlation magnitudes shifted right 16 bits in PL.

## Software behavior

- Reuses the verified V10 `xrfdc_clk.c/.h` and RFDC Tile1 startup sequence without editing those board-support files.
- Configures LMK/LMX for 2949.12 MHz ADC and 5898.24 MHz DAC sample clocks.
- Configures both DAC and ADC NCOs to 2400 MHz.
- Does not auto-start RF transmission at boot.
- `BGCAL` starts the radar if necessary and waits for the calibration result.
- `RCAL <mm>` records the next accepted peak and sets a signed fixed range offset.
- Default threshold is 1000; default UART print divisor is 9.

## External RF defaults

- Circulator: 2.2–2.6 GHz, insertion loss <= 1 dB, isolation >= 20 dB.
- Antenna: 2.2–2.6 GHz, about 8 dBi, VSWR <= 2.
- Directional coupler: about 20 dB coupling after PA, directivity >= 20 dB, plus sufficient fixed attenuation/limiting before ADC12.
- PA output: 30 dBm maximum, initially tested at minimum power.
- Never connect PA output directly to any ADC.

## Key files

- `rtl/lfm_radar_core.v`: radar datapath/control.
- `mem/lfm_400mhz_4096.mem`: four-complex-samples-per-line waveform ROM.
- `scripts/gen_lfm_rom.py`: deterministic ROM generator.
- `scripts/update_v11_lfm_bd.tcl`: recreates the independent project by importing the verified V10 BD/XDC, localizing them, removing V10 modem blocks and adding the radar datapath.
- `sim/tb_lfm_radar_core.sv`: static leakage calibration plus a synthetic lag-7 target.
- `sw/src/main.c`: UART, RFDC setup and range conversion.

## Verification status on 2026-08-10

- V10 tracked files: no diff.
- V11 BD `validated=true` and target generation completed.
- RTL behavior simulation: PASS, background calibrated and lag-7 target detected.
- A53 C compile check: PASS with `-Wall -Wextra -Werror -O2` against the verified V10 standalone BSP headers.
- Synthesis/implementation: not completed because the local Vivado installation reports no Synthesis license for `xczu28dr`.

## Next hardware session

1. Run `scripts/build_v11_hardware.tcl` on a licensed Vivado 2020.2 installation.
2. Inspect synthesis utilization/timing. The capture banks use asynchronous reads and may map to distributed RAM; if utilization/timing is excessive, pipeline the correlator for synchronous BRAM reads before changing any RF behavior.
3. Create the Vitis workspace with `scripts/create_v11_vitis_workspace.tcl`.
4. Start with the coax splitter test and low DAC level.
5. Measure ADC10/ADC12 headroom, run BGCAL, then RCAL at a known delay.
6. Only after coax validation proceed to low-power free-space testing, then increase PA power gradually.

## 2026-08-11 BRAM inference correction

The original capture implementation used sixteen 2048x16 arrays written from
the asynchronous-reset control process and read through asynchronous indexing
functions. Vivado 2020.2 reported that all capture arrays, background arrays
and the score array were `dissolved into registers`, creating roughly 0.67
Mbit of register storage plus several very large address multiplexers.

The corrected core:

- packs the four I/Q lanes into one 2048x128 reference BRAM and one 2048x128
  echo BRAM;
- writes and synchronously reads those memories in a no-reset SDP RAM process;
- pipelines the correlator through registered `PROC_CORR_READ`,
  `PROC_CORR_MULT`, `PROC_CORR_ACCUM`, `PROC_CORR_DIFF`, `PROC_CORR_MAG` and
  `PROC_CORR_UPDATE` stages;
- stores complex calibration values in one synchronous 128x96 background RAM;
- removes `score_mem` and retains only the peak and its immediate neighbours;
- uses a synchronous block ROM and a portable ROM basename;
- explicitly keeps the ten-state processing FSM in sequential encoding, with
  six dedicated registered correlation stages.

The correlation engine uses three clocks per complex sample for READ, MULT and
ACCUM, followed by DIFF, MAG and UPDATE once per lag.  The nominal 128-lag
processing time is approximately 16.8 ms and the internal completed range-update
rate is approximately 59 Hz. This is still above the UART display requirement,
avoids the previous register/multiplexer explosion and removes the direct
`reference_mem`-to-`max_score` clock-enable timing path.
