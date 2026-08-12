#!/usr/bin/env python3
"""Generate lfm_400mhz_4096.mem for the V11 LFM radar design.

The DAC interface carries four complex samples in every 128-bit word.  Each
output line is packed from MSB to LSB as:

    {Q3, I3, Q2, I2, Q1, I1, Q0, I0}

All fields are signed 16-bit two's-complement values.  The default waveform is
a 4096-sample, baseband -200 MHz to +200 MHz linear chirp at 737.28 MSPS.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path


DEFAULT_OUTPUT = Path(__file__).with_name("lfm_400mhz_4096.mem")


def signed16(value: float) -> int:
    """Quantize and return a signed value in 16-bit two's-complement form."""
    quantized = max(-32768, min(32767, int(round(value))))
    return quantized & 0xFFFF


def generate(
    output: Path,
    samples: int = 4096,
    sample_rate: float = 737.28e6,
    bandwidth: float = 400e6,
    amplitude: float = 20000.0,
) -> None:
    if samples <= 0 or samples % 4:
        raise ValueError("sample count must be positive and divisible by four")
    if sample_rate <= 0.0:
        raise ValueError("sample rate must be positive")
    if bandwidth <= 0.0 or bandwidth > sample_rate:
        raise ValueError("bandwidth must be positive and no greater than sample rate")
    if amplitude < 0.0 or amplitude > 32767.0:
        raise ValueError("amplitude must be between 0 and 32767")

    pulse_seconds = samples / sample_rate
    start_hz = -bandwidth / 2.0
    chirp_rate = bandwidth / pulse_seconds
    words: list[str] = []

    for beat in range(samples // 4):
        packed = 0
        for lane in range(4):
            sample_index = beat * 4 + lane
            time_seconds = sample_index / sample_rate
            phase = 2.0 * math.pi * (
                start_hz * time_seconds
                + 0.5 * chirp_rate * time_seconds * time_seconds
            )
            i_value = signed16(amplitude * math.cos(phase))
            q_value = signed16(amplitude * math.sin(phase))
            iq_word = (q_value << 16) | i_value
            packed |= iq_word << (lane * 32)

        words.append(f"{packed:032x}")

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(words) + "\n", encoding="ascii")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "output",
        nargs="?",
        type=Path,
        default=DEFAULT_OUTPUT,
        help="output MEM path (default: mem/lfm_400mhz_4096.mem)",
    )
    parser.add_argument("--samples", type=int, default=4096)
    parser.add_argument("--sample-rate", type=float, default=737.28e6)
    parser.add_argument("--bandwidth", type=float, default=400e6)
    parser.add_argument("--amplitude", type=float, default=20000.0)
    args = parser.parse_args()

    generate(
        args.output,
        samples=args.samples,
        sample_rate=args.sample_rate,
        bandwidth=args.bandwidth,
        amplitude=args.amplitude,
    )
    print(f"Generated {args.output.resolve()}")


if __name__ == "__main__":
    main()
