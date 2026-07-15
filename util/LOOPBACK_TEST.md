# DAC-ADC high-band loopback verification

This project now keeps the current DAC10/DAC11 transmit path and moves the ADC receive path to the high-band ADC tile.

## Current PL mapping

| ILA slot | Signal |
|---|---|
| 0 | ADC10 I (`m10_axis`) |
| 1 | ADC10 Q (`m11_axis`) |
| 2 | ADC12 I (`m12_axis`) |
| 3 | ADC12 Q (`m13_axis`) |
| 4 | DAC11 fixed complex input |
| 5 | FIR1 output |
| 6 | DPSK TX1 output |
| 7 | TX1 baseband input (`axis_broadcaster_0/M01_AXIS`) |

RFDC software mapping:

| Software target | GUI channel | Function |
|---|---|---|
| ADC tile 1 block 0 | ADC10 | R2C IQ, controlled by `ADCF` |
| ADC tile 1 block 1 | ADC12 | R2C IQ, controlled by `ADCF` |
| DAC tile 1 block 0 | DAC10 | C2R, controlled by `DACF` |
| DAC tile 1 block 1 | DAC11 | C2R, controlled by `DACF` |

Physical XM500 loopback for the high-band test:

- Main test: `DAC10 J7 -> ADC10 J2`
- Second IQ input: `DAC11 J8 -> ADC12 J1`

## Rebuild order

After changing the BD, run Validate Design, Generate Output Products, then Generate Bitstream. Export a new hardware platform/XSA that includes the new bitstream, and rebuild the Vitis application from that platform.

Do not reuse an old XSA/BSP that still has ADC tile 0 enabled. The PS program now targets ADC tile 1, so the RFDC config table must match the regenerated hardware.

## Serial check

After loading the new bitstream and ELF, the serial log should show:

```text
ADC sample clocks: 2949120 kHz (LMX RF1/RF2)
DAC sample clocks: 5898240 kHz (LMX RF3)
```

Run:

```text
STAT
```

Expected status:

- DAC Tile 1 enabled.
- ADC Tile 1 enabled.
- DAC sample rate about 5898 MHz.
- ADC sample rate about 2949 MHz.
- `pll_enable=0` is normal because the RF clocks are external.
- The used blocks should have `data_clk=1`.

## Recommended high-band NCO test

Use a high-band tone, not the old 100 MHz low-band test:

```text
DACF 2400
ADCF 2390
DACR
ADCR
STAT
```

Expected result:

- Oscilloscope on DAC10 should see about 2.4 GHz.
- `DACR` should read back DAC tile 1 blocks 0/1 near 2400 MHz.
- `ADCR` should read back ADC tile 1 blocks 0/1 near 2390 MHz. Depending on RFDC second-Nyquist handling, the readback may show a negative actual NCO.
- ADC10 IQ should contain a strong tone near 10 MHz after downconversion. The sign may be `+10 MHz` or `-10 MHz`; the magnitude is the primary check.
- With the second cable connected, ADC12 IQ in slot 2/3 should show the same baseband frequency.

## ILA CSV analysis

Example:

```powershell
E:\Xilinx\Vivado\2020.2\tps\win64\python-3.8.3\python.exe util\ila_data.py `
  --csv <new_csv_path> `
  --expected-iq-frequency=-10e6 `
  --no-plot
```

If the strongest ADC10 IQ peak is `+10 MHz` instead of `-10 MHz`, rerun with `--expected-iq-frequency=10e6`. That is a mixer/sign convention issue, not automatically a hardware failure.
