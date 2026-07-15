"""Analyze the current ZCU111 RF-ADC ILA capture.

Current PL mapping (high-band ADC mode, ADC tile 225):

* software block 0 / GUI ADC10 is R2C IQ output
  * I -> ILA slot 0 (m10_axis)
  * Q -> ILA slot 1 (m11_axis)
* software block 1 / GUI ADC12 is R2C IQ output
  * I -> ILA slot 2 (m12_axis)
  * Q -> ILA slot 3 (m13_axis)

The ADC sample clock is 2.94912 GSPS and the decimation factor is 8, so
the output sample rate is 368.64 MSPS.  The AXIS clock is 184.32 MHz and
each 32-bit TDATA word carries two consecutive signed 16-bit samples.
"""

from __future__ import annotations

import argparse
import os
from dataclasses import dataclass

import numpy as np
import pandas as pd


ADC_SAMPLE_RATE_HZ = 2.94912e9
DECIMATION = 8
OUTPUT_SAMPLE_RATE_HZ = ADC_SAMPLE_RATE_HZ / DECIMATION


@dataclass
class SpectrumMetrics:
    dc: complex
    rms: float
    peak: float
    peak_frequency_hz: float
    peak_dbfs: float


def find_slot_column(columns, slot: int, signal: str) -> str:
    pattern = f"slot_{slot}_axis_{signal}".lower()
    column = next((name for name in columns if pattern in name.lower()), None)
    if column is None:
        raise KeyError(f"CSV 中找不到 {pattern} 对应的数据列")
    return column


def read_ila_csv(path: str) -> tuple[pd.DataFrame, dict[str, str]]:
    raw = pd.read_csv(path, dtype=str, low_memory=False)
    if raw.empty:
        raise ValueError("CSV 为空")

    radix: dict[str, str] = {}
    first_cell = str(raw.iloc[0, 0]).strip().lower()
    if first_cell.startswith("radix"):
        radix = {
            column: str(raw.iloc[0][column]).strip().upper()
            for column in raw.columns
        }

    sample_index = pd.to_numeric(raw.iloc[:, 0], errors="coerce")
    frame = raw.loc[sample_index.notna()].copy()
    if frame.empty:
        raise ValueError("CSV 中没有有效的 ILA 样点")
    return frame, radix


def parse_logic(value) -> bool:
    if pd.isna(value):
        return False
    text = str(value).strip().lower()
    if text in {"1", "true", "active"}:
        return True
    try:
        return int(text, 0) != 0
    except ValueError:
        try:
            return int(text, 16) != 0
        except ValueError:
            return False


def transfer_mask(frame: pd.DataFrame, slot: int) -> np.ndarray:
    valid_column = find_slot_column(frame.columns, slot, "tvalid")
    mask = frame[valid_column].map(parse_logic).to_numpy(dtype=bool)

    try:
        ready_column = find_slot_column(frame.columns, slot, "tready")
    except KeyError:
        return mask
    return mask & frame[ready_column].map(parse_logic).to_numpy(dtype=bool)


def parse_u32(value, radix: str) -> int:
    if pd.isna(value):
        return 0
    text = str(value).strip().replace("_", "")
    if not text:
        return 0

    radix = radix.upper()
    if "HEX" in radix:
        return int(text.removeprefix("0x"), 16) & 0xFFFFFFFF
    if "SIGNED" in radix or "UNSIGNED" in radix:
        return int(text, 10) & 0xFFFFFFFF

    if text.lower().startswith("0x") or any(c in "abcdefABCDEF" for c in text):
        return int(text, 16) & 0xFFFFFFFF
    return int(text, 10) & 0xFFFFFFFF


def decode_axis_column(
    series: pd.Series,
    radix: str = "SIGNED",
    swap_samples: bool = False,
) -> np.ndarray:
    samples = np.empty(2 * len(series), dtype=np.float64)
    for index, value in enumerate(series):
        raw = parse_u32(value, radix)
        sample0 = raw & 0xFFFF
        sample1 = (raw >> 16) & 0xFFFF
        if sample0 >= 0x8000:
            sample0 -= 0x10000
        if sample1 >= 0x8000:
            sample1 -= 0x10000
        if swap_samples:
            sample0, sample1 = sample1, sample0
        samples[2 * index] = sample0
        samples[2 * index + 1] = sample1
    return samples


def decode_slot(
    frame: pd.DataFrame,
    radix_map: dict[str, str],
    slot: int,
    row_mask: np.ndarray,
    swap_samples: bool,
) -> np.ndarray:
    column = find_slot_column(frame.columns, slot, "tdata")
    return decode_axis_column(
        frame.loc[row_mask, column],
        radix=radix_map.get(column, "SIGNED"),
        swap_samples=swap_samples,
    )


def load_capture(
    path: str,
    adc10_i_slot: int,
    adc10_q_slot: int,
    adc12_i_slot: int,
    adc12_q_slot: int,
    swap_samples: bool,
) -> dict[str, np.ndarray | int]:
    frame, radix = read_ila_csv(path)

    adc10_mask = transfer_mask(frame, adc10_i_slot) & transfer_mask(
        frame, adc10_q_slot
    )
    adc12_mask = transfer_mask(frame, adc12_i_slot) & transfer_mask(
        frame, adc12_q_slot
    )
    adc10_i = decode_slot(frame, radix, adc10_i_slot, adc10_mask, swap_samples)
    adc10_q = decode_slot(frame, radix, adc10_q_slot, adc10_mask, swap_samples)
    adc12_i = decode_slot(frame, radix, adc12_i_slot, adc12_mask, swap_samples)
    adc12_q = decode_slot(frame, radix, adc12_q_slot, adc12_mask, swap_samples)

    return {
        "adc10_iq": adc10_i + 1j * adc10_q,
        "adc12_iq": adc12_i + 1j * adc12_q,
        "adc10_valid_beats": int(np.count_nonzero(adc10_mask)),
        "adc12_valid_beats": int(np.count_nonzero(adc12_mask)),
        "captured_beats": len(frame),
    }


def spectrum(
    signal: np.ndarray,
    sample_rate_hz: float,
    real_signal: bool,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    signal = np.asarray(signal)
    centered = signal - np.mean(signal)
    window = np.hanning(len(centered))
    fft_data = np.fft.fftshift(np.fft.fft(centered * window))
    frequency = np.fft.fftshift(
        np.fft.fftfreq(len(centered), d=1.0 / sample_rate_hz)
    )
    magnitude = np.abs(fft_data) / np.sum(window)
    if real_signal:
        magnitude *= 2.0
    magnitude_dbfs = 20.0 * np.log10(
        np.maximum(magnitude / 32768.0, 1e-15)
    )
    return frequency, magnitude_dbfs, magnitude


def metrics(
    signal: np.ndarray,
    sample_rate_hz: float,
    real_signal: bool,
) -> SpectrumMetrics:
    frequency, magnitude_dbfs, magnitude = spectrum(
        signal, sample_rate_hz, real_signal
    )
    peak_index = int(np.argmax(magnitude))
    centered = signal - np.mean(signal)
    return SpectrumMetrics(
        dc=complex(np.mean(signal)),
        rms=float(np.sqrt(np.mean(np.abs(centered) ** 2))),
        peak=float(np.max(np.abs(centered))),
        peak_frequency_hz=float(frequency[peak_index]),
        peak_dbfs=float(magnitude_dbfs[peak_index]),
    )


def print_report(
    capture: dict[str, np.ndarray | int],
    sample_rate_hz: float,
    expected_iq_hz: float | None,
) -> None:
    adc10_iq = np.asarray(capture["adc10_iq"])
    adc12_iq = np.asarray(capture["adc12_iq"])
    adc10_metrics = metrics(adc10_iq, sample_rate_hz, real_signal=False)
    adc12_metrics = metrics(adc12_iq, sample_rate_hz, real_signal=False)

    print(f"ADC 输出采样率: {sample_rate_hz / 1e6:.6f} MSPS")
    print(
        "AXIS 有效拍数: "
        f"ADC10 IQ={capture['adc10_valid_beats']}/{capture['captured_beats']}, "
        f"ADC12 IQ={capture['adc12_valid_beats']}/{capture['captured_beats']}"
    )

    print("\nADC10 (software block 0, R2C IQ):")
    print(f"  I/Q DC: {adc10_metrics.dc.real:.3f}, {adc10_metrics.dc.imag:.3f} LSB")
    print(f"  RMS: {adc10_metrics.rms:.3f} LSB")
    print(f"  最强复数频率: {adc10_metrics.peak_frequency_hz / 1e6:.6f} MHz")
    print(f"  最强峰: {adc10_metrics.peak_dbfs:.2f} dBFS")
    if expected_iq_hz is not None:
        error_hz = adc10_metrics.peak_frequency_hz - expected_iq_hz
        print(
            f"  期望频率: {expected_iq_hz / 1e6:.6f} MHz, "
            f"误差: {error_hz / 1e3:.3f} kHz"
        )

    print("\nADC12 (software block 1, R2C IQ):")
    print(f"  I/Q DC: {adc12_metrics.dc.real:.3f}, {adc12_metrics.dc.imag:.3f} LSB")
    print(f"  RMS: {adc12_metrics.rms:.3f} LSB")
    print(f"  最强复数频率: {adc12_metrics.peak_frequency_hz / 1e6:.6f} MHz")
    print(f"  最强峰: {adc12_metrics.peak_dbfs:.2f} dBFS")
    if expected_iq_hz is not None:
        error_hz = adc12_metrics.peak_frequency_hz - expected_iq_hz
        print(
            f"  期望频率: {expected_iq_hz / 1e6:.6f} MHz, "
            f"误差: {error_hz / 1e3:.3f} kHz"
        )


def plot_capture(
    capture: dict[str, np.ndarray | int],
    sample_rate_hz: float,
    expected_iq_hz: float | None,
    display_samples: int,
    output_path: str,
    show: bool,
) -> None:
    import matplotlib.pyplot as plt

    adc10_iq = np.asarray(capture["adc10_iq"])
    adc12_iq = np.asarray(capture["adc12_iq"])
    figure, axes = plt.subplots(2, 2, figsize=(16, 9))

    count = min(display_samples, len(adc10_iq))
    time_us = np.arange(count) / sample_rate_hz * 1e6
    axes[0, 0].plot(time_us, adc10_iq.real[:count], label="I", linewidth=1.0)
    axes[0, 0].plot(time_us, adc10_iq.imag[:count], label="Q", linewidth=1.0)
    axes[0, 0].set_title("ADC10 R2C IQ 时域")
    axes[0, 0].set_xlabel("时间 (us)")
    axes[0, 0].set_ylabel("16-bit LSB")
    axes[0, 0].legend()

    frequency, dbfs, _ = spectrum(adc10_iq, sample_rate_hz, real_signal=False)
    axes[0, 1].plot(frequency / 1e6, dbfs, linewidth=0.8)
    if expected_iq_hz is not None:
        axes[0, 1].axvline(
            expected_iq_hz / 1e6, color="tab:red", linestyle="--", label="期望"
        )
    axes[0, 1].set_title("ADC10 复数双边频谱")
    axes[0, 1].set_xlabel("频率 (MHz)")
    axes[0, 1].set_ylabel("dBFS")
    axes[0, 1].set_xlim(-sample_rate_hz / 2e6, sample_rate_hz / 2e6)
    axes[0, 1].set_ylim(-140, 5)
    axes[0, 1].legend()

    count = min(display_samples, len(adc12_iq))
    time_us = np.arange(count) / sample_rate_hz * 1e6
    axes[1, 0].plot(time_us, adc12_iq.real[:count], label="I", linewidth=1.0)
    axes[1, 0].plot(time_us, adc12_iq.imag[:count], label="Q", linewidth=1.0)
    axes[1, 0].set_title("ADC12 R2C IQ 时域")
    axes[1, 0].set_xlabel("时间 (us)")
    axes[1, 0].set_ylabel("16-bit LSB")
    axes[1, 0].legend()

    frequency, dbfs, _ = spectrum(adc12_iq, sample_rate_hz, real_signal=False)
    axes[1, 1].plot(frequency / 1e6, dbfs, linewidth=0.8)
    if expected_iq_hz is not None:
        axes[1, 1].axvline(
            expected_iq_hz / 1e6, color="tab:red", linestyle="--", label="期望"
        )
    axes[1, 1].set_title("ADC12 复数双边频谱")
    axes[1, 1].set_xlabel("频率 (MHz)")
    axes[1, 1].set_ylabel("dBFS")
    axes[1, 1].set_xlim(-sample_rate_hz / 2e6, sample_rate_hz / 2e6)
    axes[1, 1].set_ylim(-140, 5)
    axes[1, 1].legend()

    figure.tight_layout()
    output_dir = os.path.dirname(os.path.abspath(output_path))
    os.makedirs(output_dir, exist_ok=True)
    figure.savefig(output_path, dpi=200, bbox_inches="tight")
    print(f"\n波形和频谱图已保存: {os.path.abspath(output_path)}")
    if show:
        plt.show()
    plt.close(figure)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="解析当前 RFSoC ADC ILA CSV")
    parser.add_argument("--csv", default=None, help="ILA CSV 文件路径")
    parser.add_argument(
        "--sample-rate",
        type=float,
        default=OUTPUT_SAMPLE_RATE_HZ,
        help="ADC 抽取后的样点率，默认 368.64e6 Hz",
    )
    parser.add_argument(
        "--expected-iq-frequency",
        type=float,
        default=None,
        help="ADC10 期望复数频率，单位 Hz；例如 DACF2400/ADCF2390 通常填 -10e6",
    )
    parser.add_argument(
        "--iq-i-slot",
        "--adc10-i-slot",
        "--adc0-i-slot",
        dest="adc10_i_slot",
        type=int,
        default=0,
    )
    parser.add_argument(
        "--iq-q-slot",
        "--adc10-q-slot",
        "--adc0-q-slot",
        dest="adc10_q_slot",
        type=int,
        default=1,
    )
    parser.add_argument(
        "--adc12-i-slot",
        type=int,
        default=2,
        help="ADC12 I 的 ILA slot，默认 2 (m12_axis)",
    )
    parser.add_argument(
        "--adc12-q-slot",
        type=int,
        default=3,
        help="ADC12 Q 的 ILA slot，默认 3 (m13_axis)",
    )
    parser.add_argument("--swap-samples", action="store_true")
    parser.add_argument("--display-samples", type=int, default=400)
    parser.add_argument("--output", default=None, help="输出 PNG 路径")
    parser.add_argument("--show", action="store_true")
    parser.add_argument(
        "--no-plot",
        action="store_true",
        help="只打印数值报告，不导入 matplotlib 或生成 PNG",
    )
    return parser


def main() -> None:
    args = build_arg_parser().parse_args()
    base_dir = os.path.dirname(os.path.abspath(__file__))
    csv_path = args.csv or os.path.join(
        base_dir, "iladata_0713_v2_dac300_adc200.csv"
    )
    output_path = args.output or os.path.join(
        base_dir, "output_waveforms", "adc10_iq_adc12_iq.png"
    )
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"找不到 CSV 文件: {csv_path}")

    capture = load_capture(
        csv_path,
        adc10_i_slot=args.adc10_i_slot,
        adc10_q_slot=args.adc10_q_slot,
        adc12_i_slot=args.adc12_i_slot,
        adc12_q_slot=args.adc12_q_slot,
        swap_samples=args.swap_samples,
    )
    print_report(capture, args.sample_rate, args.expected_iq_frequency)
    if not args.no_plot:
        plot_capture(
            capture,
            args.sample_rate,
            args.expected_iq_frequency,
            args.display_samples,
            output_path,
            args.show,
        )


if __name__ == "__main__":
    main()
