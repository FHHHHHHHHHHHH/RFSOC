#!/usr/bin/env python3
"""Offline software-DPD and hardware MP-DPD workflow for ZCU111 V20.

The model follows the indirect-learning architecture (ILA) used in the
reference thesis: align PA input/feedback, normalize complex gain, identify a
memory-polynomial postdistorter, then reuse its coefficients as a predistorter.
The same coefficients are converted to the four 4096-entry Q1.14 gain LUTs
consumed by dpd_mp_4lane_core.sv.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import pathlib
import re
import sys
from dataclasses import dataclass
from typing import Iterable, Sequence

import numpy as np


DEFAULT_ORDERS = (1, 3, 5, 7)
DEFAULT_TAPS = 4
LUT_DEPTH = 4096
Q14_SCALE = 1 << 14
LABD_RE = re.compile(r"^LABD\s+(\d+)\s+([0-9a-fA-F]{1,8})\s+([0-9a-fA-F]{1,8})")


@dataclass
class Capture:
    tx: np.ndarray
    feedback: np.ndarray


def _signed16(value: int) -> int:
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def unpack_iq(word: int) -> complex:
    """Decode RTL packing {Q[15:0], I[15:0]} to a normalized complex sample."""
    return complex(_signed16(word), _signed16(word >> 16)) / 32768.0


def pack_iq(sample: complex) -> int:
    """Quantize a normalized complex sample to RTL {Q,I} packing."""
    i = int(np.clip(np.rint(sample.real * 32768.0), -32768, 32767)) & 0xFFFF
    q = int(np.clip(np.rint(sample.imag * 32768.0), -32768, 32767)) & 0xFFFF
    return (q << 16) | i


def load_capture(path: pathlib.Path) -> Capture:
    """Load either LABD UART output or CSV tx_i,tx_q,fb_i,fb_q columns."""
    text = path.read_text(encoding="utf-8", errors="replace")
    tx_words: list[int] = []
    fb_words: list[int] = []
    for line in text.splitlines():
        match = LABD_RE.match(line.strip())
        if match:
            tx_words.append(int(match.group(2), 16))
            fb_words.append(int(match.group(3), 16))
    if tx_words:
        return Capture(
            np.asarray([unpack_iq(word) for word in tx_words], dtype=np.complex128),
            np.asarray([unpack_iq(word) for word in fb_words], dtype=np.complex128),
        )

    data = np.genfromtxt(path, delimiter=",", names=True, dtype=float, encoding="utf-8")
    names = set(data.dtype.names or ())
    required = {"tx_i", "tx_q", "fb_i", "fb_q"}
    if not required.issubset(names):
        raise ValueError(f"capture CSV needs columns {sorted(required)}, got {sorted(names)}")
    tx = np.atleast_1d(data["tx_i"]) + 1j * np.atleast_1d(data["tx_q"])
    fb = np.atleast_1d(data["fb_i"]) + 1j * np.atleast_1d(data["fb_q"])
    scale = 32768.0 if max(np.max(np.abs(tx)), np.max(np.abs(fb))) > 2.0 else 1.0
    return Capture(tx / scale, fb / scale)


def load_waveform(path: pathlib.Path) -> np.ndarray:
    data = np.genfromtxt(path, delimiter=",", names=True, dtype=float, encoding="utf-8")
    names = set(data.dtype.names or ())
    if {"i", "q"}.issubset(names):
        waveform = np.atleast_1d(data["i"]) + 1j * np.atleast_1d(data["q"])
    elif {"tx_i", "tx_q"}.issubset(names):
        waveform = np.atleast_1d(data["tx_i"]) + 1j * np.atleast_1d(data["tx_q"])
    else:
        raise ValueError("waveform CSV needs i,q or tx_i,tx_q columns")
    scale = 32768.0 if np.max(np.abs(waveform)) > 2.0 else 1.0
    return waveform / scale


def save_waveform(path: pathlib.Path, waveform: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(("i", "q", "packed_hex"))
        for sample in waveform:
            writer.writerow((f"{sample.real:.12g}", f"{sample.imag:.12g}", f"{pack_iq(sample):08X}"))


def align_capture(capture: Capture, max_lag: int = 1024) -> tuple[Capture, int]:
    """Integer-sample alignment; positive lag means feedback arrived later."""
    tx = np.asarray(capture.tx, dtype=np.complex128)
    fb = np.asarray(capture.feedback, dtype=np.complex128)
    length = min(len(tx), len(fb))
    if length < 16:
        raise ValueError("at least 16 capture samples are required")
    tx = tx[:length] - np.mean(tx[:length])
    fb = fb[:length] - np.mean(fb[:length])
    limit = min(max_lag, length - 8)
    lags = np.arange(-limit, limit + 1)
    scores = np.empty(len(lags), dtype=float)
    for index, lag in enumerate(lags):
        if lag >= 0:
            a, b = tx[: length - lag], fb[lag:]
        else:
            a, b = tx[-lag:], fb[: length + lag]
        denominator = math.sqrt(float(np.vdot(a, a).real * np.vdot(b, b).real))
        scores[index] = abs(np.vdot(a, b)) / denominator if denominator else 0.0
    lag = int(lags[int(np.argmax(scores))])
    if lag >= 0:
        return Capture(tx[: length - lag], fb[lag:]), lag
    return Capture(tx[-lag:], fb[: length + lag]), lag


def normalize_feedback(capture: Capture) -> tuple[Capture, complex]:
    """Remove the feedback path's constant complex gain relative to PA input."""
    denominator = np.vdot(capture.feedback, capture.feedback)
    if abs(denominator) < 1e-18:
        raise ValueError("feedback capture has zero power")
    gain = np.vdot(capture.feedback, capture.tx) / denominator
    return Capture(capture.tx, capture.feedback * gain), complex(gain)


def mp_basis(signal: np.ndarray, taps: int, orders: Sequence[int]) -> np.ndarray:
    """Return tap-major MP basis x[n-m]|x[n-m]|^(p-1)."""
    signal = np.asarray(signal, dtype=np.complex128)
    basis = np.zeros((len(signal), taps * len(orders)), dtype=np.complex128)
    for tap in range(taps):
        delayed = np.zeros_like(signal)
        if tap == 0:
            delayed[:] = signal
        else:
            delayed[tap:] = signal[:-tap]
        magnitude = np.abs(delayed)
        for order_index, order in enumerate(orders):
            basis[:, tap * len(orders) + order_index] = delayed * magnitude ** (order - 1)
    return basis


def apply_mp(signal: np.ndarray, coefficients: np.ndarray, taps: int,
             orders: Sequence[int]) -> np.ndarray:
    return mp_basis(signal, taps, orders) @ np.asarray(coefficients).reshape(-1)


def nmse_db(reference: np.ndarray, estimate: np.ndarray) -> float:
    error = np.asarray(reference) - np.asarray(estimate)
    return 10.0 * math.log10(float(np.vdot(error, error).real / np.vdot(reference, reference).real))


def acpr_db(signal: np.ndarray, sample_rate: float, main_bandwidth: float,
            adjacent_offset: float) -> dict[str, float]:
    """Windowed-FFT ACPR for equal-width lower/upper adjacent channels."""
    signal = np.asarray(signal, dtype=np.complex128)
    nfft = 1 << max(12, (len(signal) - 1).bit_length())
    window = np.hanning(len(signal))
    spectrum = np.abs(np.fft.fftshift(np.fft.fft(signal * window, nfft))) ** 2
    frequency = np.fft.fftshift(np.fft.fftfreq(nfft, 1.0 / sample_rate))

    def channel_power(center: float) -> float:
        mask = np.abs(frequency - center) <= main_bandwidth / 2.0
        return float(np.sum(spectrum[mask]))

    main = channel_power(0.0)
    lower = channel_power(-adjacent_offset)
    upper = channel_power(adjacent_offset)
    if main <= 0.0:
        raise ValueError("main-channel power is zero")
    return {
        "lower_acpr_db": 10.0 * math.log10(max(lower, 1e-300) / main),
        "upper_acpr_db": 10.0 * math.log10(max(upper, 1e-300) / main),
    }


def identify_ila(capture: Capture, taps: int = DEFAULT_TAPS,
                 orders: Sequence[int] = DEFAULT_ORDERS,
                 regularization: float = 1e-8,
                 max_lag: int = 1024) -> dict[str, object]:
    aligned, lag = align_capture(capture, max_lag=max_lag)
    normalized, feedback_gain = normalize_feedback(aligned)
    basis = mp_basis(normalized.feedback, taps, orders)
    start = taps - 1
    train_basis = basis[start:]
    target = normalized.tx[start:]
    gram = train_basis.conj().T @ train_basis
    ridge = regularization * float(np.trace(gram).real / max(1, gram.shape[0]))
    coefficients = np.linalg.solve(
        gram + ridge * np.eye(gram.shape[0], dtype=np.complex128),
        train_basis.conj().T @ target,
    )
    estimate = basis @ coefficients
    return {
        "coefficients": coefficients,
        "taps": taps,
        "orders": np.asarray(orders, dtype=np.int32),
        "lag": lag,
        "feedback_gain": feedback_gain,
        "identification_nmse_db": nmse_db(normalized.tx[start:], estimate[start:]),
        "samples": len(normalized.tx),
    }


def save_model(path: pathlib.Path, model: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    np.savez(
        path,
        coefficients=np.asarray(model["coefficients"]),
        taps=np.int32(model["taps"]),
        orders=np.asarray(model["orders"], dtype=np.int32),
        lag=np.int32(model.get("lag", 0)),
        feedback_gain=np.complex128(model.get("feedback_gain", 1.0 + 0.0j)),
        identification_nmse_db=np.float64(model.get("identification_nmse_db", np.nan)),
        samples=np.int32(model.get("samples", 0)),
    )


def load_model(path: pathlib.Path) -> dict[str, object]:
    with np.load(path) as data:
        return {
            "coefficients": data["coefficients"],
            "taps": int(data["taps"]),
            "orders": tuple(int(value) for value in data["orders"]),
            "lag": int(data["lag"]),
            "feedback_gain": complex(data["feedback_gain"]),
            "identification_nmse_db": float(data["identification_nmse_db"]),
            "samples": int(data["samples"]),
        }


def coefficients_to_luts(model: dict[str, object]) -> np.ndarray:
    """Create packed {gain_q,gain_i} LUTs exactly matching the RTL address law."""
    taps = int(model["taps"])
    orders = tuple(int(value) for value in model["orders"])
    coefficients = np.asarray(model["coefficients"]).reshape(taps, len(orders))
    power = (np.arange(LUT_DEPTH, dtype=float) + 0.5) / 2048.0
    gains = np.zeros((taps, LUT_DEPTH), dtype=np.complex128)
    for tap in range(taps):
        for order_index, order in enumerate(orders):
            gains[tap] += coefficients[tap, order_index] * power ** ((order - 1) // 2)
    gain_i = np.clip(np.rint(gains.real * Q14_SCALE), -32768, 32767).astype(np.int64)
    gain_q = np.clip(np.rint(gains.imag * Q14_SCALE), -32768, 32767).astype(np.int64)
    return ((gain_q & 0xFFFF) << 16 | (gain_i & 0xFFFF)).astype(np.uint32)


def save_luts(directory: pathlib.Path, luts: np.ndarray) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    for tap, table in enumerate(luts):
        (directory / f"tap{tap}.hex").write_text(
            "".join(f"{int(word):08X}\n" for word in table), encoding="ascii"
        )
    metadata = {"format": "Q1.14 complex {Q,I}", "taps": int(luts.shape[0]), "depth": LUT_DEPTH}
    (directory / "lut_manifest.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")


def emit_waveform_commands(waveform: np.ndarray, chunk: int = 64) -> Iterable[str]:
    if len(waveform) > LUT_DEPTH:
        raise ValueError("LAB waveform memory is limited to 4096 samples")
    yield "LABP 0"
    words = [f"{pack_iq(sample):08X}" for sample in waveform]
    for start in range(0, len(words), chunk):
        yield f"LABW {start} " + " ".join(words[start:start + chunk])
    if len(words) >= 4:
        yield f"LABL {len(words) - (len(words) % 4)}"


def emit_lut_commands(luts: np.ndarray, bank: int, chunk: int = 64) -> Iterable[str]:
    for tap, table in enumerate(luts):
        for start in range(0, len(table), chunk):
            words = " ".join(f"{int(word):08X}" for word in table[start:start + chunk])
            yield f"DPDW {bank} {tap} {start} {words}"


def synthetic_pa(signal: np.ndarray) -> np.ndarray:
    delayed = np.concatenate(([0j], signal[:-1]))
    return (signal * (1.0 - 0.32 * np.abs(signal) ** 2 + 0.10 * np.abs(signal) ** 4)
            + delayed * (0.08 + 0.05 * np.abs(delayed) ** 2))


def run_selftest() -> dict[str, float]:
    rng = np.random.default_rng(20260814)
    raw = rng.normal(size=8192) + 1j * rng.normal(size=8192)
    shaped = np.convolve(raw, np.ones(9) / 9.0, mode="same")
    desired = 0.78 * shaped / np.max(np.abs(shaped))
    feedback = synthetic_pa(desired)
    feedback = np.concatenate((np.zeros(17, dtype=complex), feedback[:-17])) * (0.74 * np.exp(0.31j))
    model = identify_ila(Capture(desired, feedback), max_lag=64)
    predistorted = apply_mp(desired, model["coefficients"], int(model["taps"]), model["orders"])
    peak = np.max(np.abs(predistorted))
    if peak > 0.98:
        predistorted *= 0.98 / peak
    baseline_nmse = nmse_db(desired[32:], synthetic_pa(desired)[32:])
    dpd_nmse = nmse_db(desired[32:], synthetic_pa(predistorted)[32:])
    luts = coefficients_to_luts(model)
    if luts.shape != (DEFAULT_TAPS, LUT_DEPTH):
        raise AssertionError("unexpected LUT shape")
    if int(model["lag"]) != 17:
        raise AssertionError(f"alignment failed: expected lag 17, got {model['lag']}")
    if dpd_nmse >= baseline_nmse - 1.0:
        raise AssertionError(f"DPD improvement too small: baseline={baseline_nmse:.2f}, dpd={dpd_nmse:.2f}")
    return {"baseline_nmse_db": baseline_nmse, "dpd_nmse_db": dpd_nmse,
            "improvement_db": baseline_nmse - dpd_nmse}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    identify = sub.add_parser("identify", help="identify an ILA MP model from LAB capture")
    identify.add_argument("capture", type=pathlib.Path)
    identify.add_argument("model", type=pathlib.Path)
    identify.add_argument("--max-lag", type=int, default=1024)
    identify.add_argument("--regularization", type=float, default=1e-8)

    predistort = sub.add_parser("predistort", help="create a phase-1 software-DPD waveform")
    predistort.add_argument("model", type=pathlib.Path)
    predistort.add_argument("waveform", type=pathlib.Path)
    predistort.add_argument("output", type=pathlib.Path)
    predistort.add_argument("--peak", type=float, default=0.95)

    lut = sub.add_parser("lut", help="create phase-2 hardware gain LUTs")
    lut.add_argument("model", type=pathlib.Path)
    lut.add_argument("output_dir", type=pathlib.Path)

    commands = sub.add_parser("commands", help="emit UART commands for waveform or LUT loading")
    commands.add_argument("kind", choices=("waveform", "lut"))
    commands.add_argument("input", type=pathlib.Path)
    commands.add_argument("output", type=pathlib.Path)
    commands.add_argument("--bank", type=int, choices=(0, 1), default=1)
    commands.add_argument("--chunk", type=int, default=64)

    evaluate = sub.add_parser("evaluate", help="measure aligned capture NMSE and optional ACPR")
    evaluate.add_argument("capture", type=pathlib.Path)
    evaluate.add_argument("--max-lag", type=int, default=1024)
    evaluate.add_argument("--sample-rate", type=float)
    evaluate.add_argument("--main-bandwidth", type=float)
    evaluate.add_argument("--adjacent-offset", type=float)

    sub.add_parser("selftest", help="run deterministic numerical regression")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "identify":
        model = identify_ila(load_capture(args.capture), max_lag=args.max_lag,
                             regularization=args.regularization)
        save_model(args.model, model)
        print(json.dumps({key: value for key, value in model.items()
                          if key not in ("coefficients", "orders")}, default=str, indent=2))
    elif args.command == "predistort":
        model = load_model(args.model)
        waveform = load_waveform(args.waveform)
        result = apply_mp(waveform, model["coefficients"], int(model["taps"]), model["orders"])
        peak = float(np.max(np.abs(result)))
        if peak > args.peak:
            result *= args.peak / peak
        save_waveform(args.output, result)
        print(f"wrote {len(result)} predistorted samples to {args.output}")
    elif args.command == "lut":
        luts = coefficients_to_luts(load_model(args.model))
        save_luts(args.output_dir, luts)
        print(f"wrote {luts.shape[0]} x {luts.shape[1]} LUT words to {args.output_dir}")
    elif args.command == "commands":
        if args.kind == "waveform":
            lines = emit_waveform_commands(load_waveform(args.input), args.chunk)
        else:
            tables = np.vstack([
                np.loadtxt(args.input / f"tap{tap}.hex", dtype=np.uint32,
                           converters={0: lambda value: int(value, 16)})
                for tap in range(DEFAULT_TAPS)
            ])
            lines = emit_lut_commands(tables, args.bank, args.chunk)
        args.output.write_text("\n".join(lines) + "\n", encoding="ascii")
        print(f"wrote UART command file {args.output}")
    elif args.command == "evaluate":
        aligned, lag = align_capture(load_capture(args.capture), max_lag=args.max_lag)
        normalized, feedback_gain = normalize_feedback(aligned)
        result = {
            "lag": lag,
            "feedback_gain": str(feedback_gain),
            "samples": len(normalized.tx),
            "nmse_db": nmse_db(normalized.tx, normalized.feedback),
        }
        acpr_arguments = (args.sample_rate, args.main_bandwidth, args.adjacent_offset)
        if any(value is not None for value in acpr_arguments):
            if any(value is None for value in acpr_arguments):
                raise ValueError("ACPR requires sample-rate, main-bandwidth and adjacent-offset")
            result.update(acpr_db(normalized.feedback, *acpr_arguments))
        print(json.dumps(result, indent=2))
    else:
        print(json.dumps(run_selftest(), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
