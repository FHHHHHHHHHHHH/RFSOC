"""Analyze the DACF=2400 MHz / ADCF=2390 MHz RFSoC ILA capture.

ILA mapping used by this project:

* slot 0: ADC10 I data (m10_axis), two signed 16-bit samples per beat
* slot 1: ADC10 Q data (m11_axis), two signed 16-bit samples per beat
* slot 2: ADC12 real data (m12_axis), two signed 16-bit samples per beat

The RF-ADC sample rate is 2949.12 MSPS and the decimation factor is 8,
therefore the decoded output sample rate is 368.64 MSPS.  With DACF=2400
MHz and ADCF=2390 MHz, the expected ADC10 complex baseband tone is -10 MHz
for the current mixer sign convention.

The script prints a numerical report and, unless --no-plot is specified,
writes a waveform/spectrum PNG next to the CSV file.  A text report is also
written next to the CSV file.
"""

from __future__ import annotations

import argparse
import csv
from itertools import chain
from pathlib import Path

import numpy as np


DEFAULT_CSV = Path(__file__).with_name("0715_DACF2400_ADCF2390_V2.csv")
ADC_SAMPLE_RATE_HZ = 2.94912e9
DECIMATION = 8
EXPECTED_IQ_FREQUENCY_HZ = -10.0e6
FULL_SCALE = 32768.0


def find_column(header: list[str], slot: int, signal: str) -> int:
    pattern = f"slot_{slot}_axis_{signal}".lower()
    for index, name in enumerate(header):
        if pattern in name.lower():
            return index
    raise KeyError(f"Cannot find {pattern} in the CSV header")


def parse_logic(value: str) -> bool:
    text = value.strip().lower()
    if text in {"1", "true", "active"}:
        return True
    if text in {"0", "false", "inactive", "_", ""}:
        return False
    try:
        return int(text, 0) != 0
    except ValueError:
        try:
            return int(text, 16) != 0
        except ValueError:
            return False


def parse_u32(value: str, radix: str) -> int:
    text = value.strip().replace("_", "")
    if not text:
        return 0
    radix = radix.upper()
    if "HEX" in radix:
        return int(text.removeprefix("0x"), 16) & 0xFFFFFFFF
    if "SIGNED" in radix or "UNSIGNED" in radix:
        return int(text, 10) & 0xFFFFFFFF
    base = 16 if text.lower().startswith("0x") else 10
    return int(text, base) & 0xFFFFFFFF


def unpack_s16_pairs(words: list[int], swap_samples: bool) -> np.ndarray:
    raw = np.asarray(words, dtype=np.uint64)
    low = (raw & 0xFFFF).astype(np.int32)
    high = ((raw >> 16) & 0xFFFF).astype(np.int32)
    low[low >= 0x8000] -= 0x10000
    high[high >= 0x8000] -= 0x10000
    if swap_samples:
        low, high = high, low
    samples = np.empty(2 * len(raw), dtype=np.float64)
    samples[0::2] = low
    samples[1::2] = high
    return samples


def read_capture(path: Path, swap_samples: bool) -> dict[str, object]:
    with path.open("r", encoding="utf-8-sig", errors="replace", newline="") as stream:
        reader = csv.reader(stream)
        header = next(reader)
        first_row = next(reader)

        if first_row and first_row[0].strip().lower().startswith("radix"):
            radix = first_row
        else:
            radix = [""] * len(header)
            reader = chain([first_row], reader)

        columns: dict[tuple[int, str], int] = {}
        for slot in (0, 1, 2):
            for signal in ("tdata", "tvalid", "tready"):
                columns[(slot, signal)] = find_column(header, slot, signal)

        i_words: list[int] = []
        q_words: list[int] = []
        r_words: list[int] = []
        captured_beats = 0
        iq_valid_beats = 0
        r_valid_beats = 0

        for row in reader:
            if not row:
                continue
            try:
                int(row[0])
            except (ValueError, IndexError):
                continue
            captured_beats += 1

            i_valid = parse_logic(row[columns[(0, "tvalid")]])
            i_ready = parse_logic(row[columns[(0, "tready")]])
            q_valid = parse_logic(row[columns[(1, "tvalid")]])
            q_ready = parse_logic(row[columns[(1, "tready")]])
            if i_valid and i_ready and q_valid and q_ready:
                i_col = columns[(0, "tdata")]
                q_col = columns[(1, "tdata")]
                i_words.append(parse_u32(row[i_col], radix[i_col]))
                q_words.append(parse_u32(row[q_col], radix[q_col]))
                iq_valid_beats += 1

            r_valid = parse_logic(row[columns[(2, "tvalid")]])
            r_ready = parse_logic(row[columns[(2, "tready")]])
            if r_valid and r_ready:
                r_col = columns[(2, "tdata")]
                r_words.append(parse_u32(row[r_col], radix[r_col]))
                r_valid_beats += 1

    i_data = unpack_s16_pairs(i_words, swap_samples)
    q_data = unpack_s16_pairs(q_words, swap_samples)
    r_data = unpack_s16_pairs(r_words, swap_samples)
    return {
        "iq": i_data + 1j * q_data,
        "r2r": r_data,
        "captured_beats": captured_beats,
        "iq_valid_beats": iq_valid_beats,
        "r_valid_beats": r_valid_beats,
    }


def complex_spectrum(signal: np.ndarray, sample_rate_hz: float):
    centered = signal - np.mean(signal)
    window = np.hanning(len(centered))
    spectrum = np.fft.fftshift(np.fft.fft(centered * window))
    frequency = np.fft.fftshift(np.fft.fftfreq(len(centered), 1.0 / sample_rate_hz))
    magnitude = np.abs(spectrum) / np.sum(window)
    dbfs = 20.0 * np.log10(np.maximum(magnitude / FULL_SCALE, 1e-15))
    return frequency, dbfs, window


def real_spectrum(signal: np.ndarray, sample_rate_hz: float):
    centered = signal - np.mean(signal)
    window = np.hanning(len(centered))
    spectrum = np.fft.rfft(centered * window)
    frequency = np.fft.rfftfreq(len(centered), 1.0 / sample_rate_hz)
    magnitude = 2.0 * np.abs(spectrum) / np.sum(window)
    dbfs = 20.0 * np.log10(np.maximum(magnitude / FULL_SCALE, 1e-15))
    return frequency, dbfs


def wrap_degrees(angle: float) -> float:
    return (angle + 180.0) % 360.0 - 180.0


def analyze(capture: dict[str, object], sample_rate_hz: float, expected_hz: float):
    iq = np.asarray(capture["iq"])
    r2r = np.asarray(capture["r2r"])
    if len(iq) < 16 or len(r2r) < 16:
        raise ValueError("Not enough valid samples in the capture")

    frequency, iq_dbfs, window = complex_spectrum(iq, sample_rate_hz)
    peak_index = int(np.argmax(iq_dbfs))
    peak_frequency_hz = float(frequency[peak_index])
    peak_dbfs = float(iq_dbfs[peak_index])
    image_index = int(np.argmin(np.abs(frequency + peak_frequency_hz)))
    image_dbfs = float(iq_dbfs[image_index])

    time_index = np.arange(len(iq))
    reference = np.exp(-2j * np.pi * peak_frequency_hz * time_index / sample_rate_hz)
    i_coefficient = np.sum((iq.real - np.mean(iq.real)) * window * reference)
    q_coefficient = np.sum((iq.imag - np.mean(iq.imag)) * window * reference)
    q_over_i = q_coefficient / i_coefficient
    amplitude_ratio = float(np.abs(q_over_i))
    amplitude_imbalance_db = float(20.0 * np.log10(amplitude_ratio))
    iq_phase_degrees = float(np.angle(q_over_i, deg=True))
    phase_error_degrees = wrap_degrees(iq_phase_degrees - (-90.0))

    r_frequency, r_dbfs = real_spectrum(r2r, sample_rate_hz)
    r_peak_index = int(np.argmax(r_dbfs[1:]) + 1)

    bin_width_hz = sample_rate_hz / len(iq)
    result = {
        "iq": iq,
        "r2r": r2r,
        "frequency": frequency,
        "iq_dbfs": iq_dbfs,
        "r_frequency": r_frequency,
        "r_dbfs": r_dbfs,
        "bin_width_hz": bin_width_hz,
        "peak_frequency_hz": peak_frequency_hz,
        "peak_dbfs": peak_dbfs,
        "frequency_error_hz": peak_frequency_hz - expected_hz,
        "image_dbfs": image_dbfs,
        "image_rejection_db": peak_dbfs - image_dbfs,
        "i_dc": float(np.mean(iq.real)),
        "q_dc": float(np.mean(iq.imag)),
        "i_rms": float(np.std(iq.real)),
        "q_rms": float(np.std(iq.imag)),
        "complex_rms": float(np.sqrt(np.mean(np.abs(iq - np.mean(iq)) ** 2))),
        "amplitude_ratio": amplitude_ratio,
        "amplitude_imbalance_db": amplitude_imbalance_db,
        "iq_phase_degrees": iq_phase_degrees,
        "phase_error_degrees": phase_error_degrees,
        "r_dc": float(np.mean(r2r)),
        "r_rms": float(np.std(r2r)),
        "r_peak_frequency_hz": float(r_frequency[r_peak_index]),
        "r_peak_dbfs": float(r_dbfs[r_peak_index]),
    }
    result["pass"] = bool(
        capture["iq_valid_beats"] == capture["captured_beats"]
        and abs(result["frequency_error_hz"]) <= bin_width_hz
        and abs(amplitude_imbalance_db) <= 0.5
        and abs(phase_error_degrees) <= 2.0
        and result["image_rejection_db"] >= 40.0
    )
    return result


def build_report(
    capture: dict[str, object], result: dict[str, object], sample_rate_hz: float, expected_hz: float
) -> str:
    status = "PASS" if result["pass"] else "CHECK"
    return "\n".join(
        [
            f"Overall result: {status}",
            f"ADC output sample rate: {sample_rate_hz / 1e6:.6f} MSPS",
            f"FFT bin width: {result['bin_width_hz'] / 1e3:.3f} kHz",
            (
                "AXIS valid beats: "
                f"ADC10 IQ={capture['iq_valid_beats']}/{capture['captured_beats']}, "
                f"ADC12 R2R={capture['r_valid_beats']}/{capture['captured_beats']}"
            ),
            "",
            "ADC10 IQ (Tile 1 / software block 0 / GUI ADC10):",
            f"  Expected complex frequency: {expected_hz / 1e6:.6f} MHz",
            f"  Measured complex frequency: {result['peak_frequency_hz'] / 1e6:.6f} MHz",
            f"  Frequency error: {result['frequency_error_hz'] / 1e3:.3f} kHz",
            f"  Main peak: {result['peak_dbfs']:.2f} dBFS",
            f"  I/Q DC: {result['i_dc']:.3f}, {result['q_dc']:.3f} LSB",
            f"  I/Q RMS: {result['i_rms']:.3f}, {result['q_rms']:.3f} LSB",
            f"  Complex RMS: {result['complex_rms']:.3f} LSB",
            f"  Q/I amplitude ratio: {result['amplitude_ratio']:.6f}",
            f"  I/Q amplitude imbalance: {result['amplitude_imbalance_db']:.4f} dB",
            f"  Q relative to I phase: {result['iq_phase_degrees']:.4f} deg",
            f"  Quadrature phase error: {result['phase_error_degrees']:.4f} deg",
            f"  Image peak: {result['image_dbfs']:.2f} dBFS",
            f"  Image rejection: {result['image_rejection_db']:.2f} dB",
            "",
            "ADC12 R2R (Tile 1 / software block 1 / GUI ADC12):",
            f"  DC: {result['r_dc']:.3f} LSB",
            f"  RMS: {result['r_rms']:.3f} LSB",
            f"  Strongest non-DC peak: {result['r_peak_frequency_hz'] / 1e6:.6f} MHz",
            f"  Strongest non-DC peak level: {result['r_peak_dbfs']:.2f} dBFS",
        ]
    )


def save_plot(
    result: dict[str, object], sample_rate_hz: float, expected_hz: float, path: Path
) -> bool:
    try:
        import matplotlib.pyplot as plt
    except ModuleNotFoundError:
        print("Plot skipped: matplotlib is not installed in this Python environment")
        return False

    iq = np.asarray(result["iq"])
    r2r = np.asarray(result["r2r"])
    display_count = min(500, len(iq))
    time_us = np.arange(display_count) / sample_rate_hz * 1e6

    figure, axes = plt.subplots(2, 2, figsize=(15, 9))
    axes[0, 0].plot(time_us, iq.real[:display_count], label="I", linewidth=1.0)
    axes[0, 0].plot(time_us, iq.imag[:display_count], label="Q", linewidth=1.0)
    axes[0, 0].set_title("ADC10 IQ waveform")
    axes[0, 0].set_xlabel("Time (us)")
    axes[0, 0].set_ylabel("16-bit LSB")
    axes[0, 0].legend()
    axes[0, 0].grid(True, alpha=0.25)

    axes[0, 1].plot(np.asarray(result["frequency"]) / 1e6, result["iq_dbfs"], linewidth=0.8)
    axes[0, 1].axvline(expected_hz / 1e6, color="tab:red", linestyle="--", label="Expected")
    axes[0, 1].set_xlim(-50, 50)
    axes[0, 1].set_ylim(-140, 0)
    axes[0, 1].set_title("ADC10 complex spectrum")
    axes[0, 1].set_xlabel("Frequency (MHz)")
    axes[0, 1].set_ylabel("dBFS")
    axes[0, 1].legend()
    axes[0, 1].grid(True, alpha=0.25)

    constellation_step = max(1, len(iq) // 3000)
    axes[1, 0].plot(
        iq.real[::constellation_step], iq.imag[::constellation_step], ".", markersize=1.5
    )
    axes[1, 0].set_aspect("equal", adjustable="box")
    axes[1, 0].set_title("ADC10 IQ trajectory")
    axes[1, 0].set_xlabel("I (LSB)")
    axes[1, 0].set_ylabel("Q (LSB)")
    axes[1, 0].grid(True, alpha=0.25)

    axes[1, 1].plot(np.asarray(result["r_frequency"]) / 1e6, result["r_dbfs"], linewidth=0.8)
    axes[1, 1].set_xlim(0, sample_rate_hz / 2e6)
    axes[1, 1].set_ylim(-140, 0)
    axes[1, 1].set_title("ADC12 R2R spectrum")
    axes[1, 1].set_xlabel("Frequency (MHz)")
    axes[1, 1].set_ylabel("dBFS")
    axes[1, 1].grid(True, alpha=0.25)

    figure.suptitle(
        f"DACF 2400 MHz / ADCF 2390 MHz - {('PASS' if result['pass'] else 'CHECK')}",
        fontsize=14,
    )
    figure.tight_layout()
    figure.savefig(path, dpi=180, bbox_inches="tight")
    plt.close(figure)
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", type=Path, default=DEFAULT_CSV)
    parser.add_argument("--adc-sample-rate", type=float, default=ADC_SAMPLE_RATE_HZ)
    parser.add_argument("--decimation", type=int, default=DECIMATION)
    parser.add_argument(
        "--expected-frequency-mhz", type=float, default=EXPECTED_IQ_FREQUENCY_HZ / 1e6
    )
    parser.add_argument("--swap-samples", action="store_true")
    parser.add_argument("--no-plot", action="store_true")
    args = parser.parse_args()

    csv_path = args.csv.resolve()
    sample_rate_hz = args.adc_sample_rate / args.decimation
    expected_hz = args.expected_frequency_mhz * 1e6
    report_path = csv_path.with_name(f"{csv_path.stem}_analysis.txt")
    plot_path = csv_path.with_name(f"{csv_path.stem}_analysis.png")

    capture = read_capture(csv_path, args.swap_samples)
    result = analyze(capture, sample_rate_hz, expected_hz)
    report = build_report(capture, result, sample_rate_hz, expected_hz)
    print(report)
    report_path.write_text(report + "\n", encoding="utf-8")
    print(f"\nText report: {report_path}")

    if not args.no_plot:
        if save_plot(result, sample_rate_hz, expected_hz, plot_path):
            print(f"Plot: {plot_path}")


if __name__ == "__main__":
    main()
