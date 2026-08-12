#!/usr/bin/env python3
"""Generate the four-complex-samples-per-beat LFM ROM used by V11.

The RFDC DAC data path runs at 737.28 MSPS and accepts four complex samples
on every 184.32 MHz PL clock.  Each output line is one 128-bit AXI beat:

    {Q3,I3,Q2,I2,Q1,I1,Q0,I0}
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path


def signed16(value: float) -> int:
    quantized = max(-32768, min(32767, int(round(value))))
    return quantized & 0xFFFF


def generate(output: Path, samples: int, sample_rate: float,
             bandwidth: float, amplitude: float) -> None:
    if samples % 4:
        raise ValueError("sample count must be divisible by four")

    pulse_seconds = samples / sample_rate
    start_hz = -bandwidth / 2.0
    chirp_rate = bandwidth / pulse_seconds
    words: list[str] = []

    for beat in range(samples // 4):
        fields: list[int] = []
        for lane in range(4):
            n = beat * 4 + lane
            t = n / sample_rate
            phase = 2.0 * math.pi * (
                start_hz * t + 0.5 * chirp_rate * t * t
            )
            i_value = signed16(amplitude * math.cos(phase))
            q_value = signed16(amplitude * math.sin(phase))
            fields.append((q_value << 16) | i_value)

        packed = 0
        for lane, iq_word in enumerate(fields):
            packed |= iq_word << (lane * 32)
        words.append(f"{packed:032x}")

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(words) + "\n", encoding="ascii")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--samples", type=int, default=4096)
    parser.add_argument("--sample-rate", type=float, default=737.28e6)
    parser.add_argument("--bandwidth", type=float, default=400e6)
    parser.add_argument("--amplitude", type=float, default=20000.0)
    args = parser.parse_args()
    generate(args.output, args.samples, args.sample_rate,
             args.bandwidth, args.amplitude)


if __name__ == "__main__":
    main()
