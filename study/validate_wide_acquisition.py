#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fixed-seed validation of QF256 acquisition through an ideal USB frontend.

This is a deliberately manual Monte Carlo harness. It is not part of the
strict test target: the registered calibration and check comprise 6,144 blind
receiver calls. Python 3 and NumPy are required. Each worker is a separate
process because libqf256 is not thread-safe within one process.
"""

import argparse
import csv
import ctypes as C
import math
import multiprocessing as mp
from pathlib import Path
import time

import numpy as np


FS = 12000
NOISE_CAPTURE = 180000
SIGNAL_CAPTURE = 125200
SIGNAL_FILTER_SAMPLES = 262144
SIGNAL_FILTER_PAD = (SIGNAL_FILTER_SAMPLES - SIGNAL_CAPTURE) // 2
FRAME = 116800
PAYLOAD_BITS = 77
SYNC_BY_PROFILE = {"wide": 1, "hf": 2}
CFO_LIMIT_BY_PROFILE = {"wide": 750.0, "hf": 125.0}
NOISE_LEVELS = (-24.0, -22.0, -20.0, -18.0, -16.0, -14.0)


class Result(C.Structure):
    _fields_ = [
        ("payload", C.c_int8 * PAYLOAD_BITS), ("reserved", C.c_int8 * 3),
        ("crc_ok", C.c_int32), ("accepted", C.c_int32),
        ("start_samples", C.c_int32), ("iterations", C.c_int32),
        ("start_seconds", C.c_double), ("cfo_hz", C.c_double),
        ("noise_variance", C.c_double), ("evidence", C.c_double),
        ("latency_ms", C.c_double), ("snr_2500_db", C.c_double),
        ("snr_valid", C.c_int32), ("reserved2", C.c_int32),
    ]


if C.sizeof(Result) != 152:
    raise RuntimeError(f"unexpected qf256_result size: {C.sizeof(Result)}")


def init_worker(lib_path, cutoff_hz, capture_samples, profile,
                frontend_offsets):
    global tx, rx, lp_masks, sample_index, sync_mode, cfo_limit
    lib = C.CDLL(lib_path)
    tx = lib.qf256_tx_cf32
    tx.argtypes = [C.POINTER(C.c_int8), C.POINTER(C.c_float), C.c_int32,
                   C.POINTER(C.c_int32), C.POINTER(C.c_int32)]
    tx.restype = None
    rx = lib.qf256_rx_cf32
    rx.argtypes = [C.POINTER(C.c_float), C.c_int32, C.c_int32,
                   C.POINTER(Result), C.POINTER(C.c_int32)]
    rx.restype = None
    frequencies = np.fft.fftfreq(capture_samples, 1 / FS)
    # The physical USB passband is centred at 1500 Hz.  A decoder centre
    # displaced by `offset` mixes its complex-baseband bounds to
    # [-cutoff-offset, +cutoff-offset].
    lp_masks = {
        offset: np.abs(frequencies + offset) <= cutoff_hz
        for offset in frontend_offsets
    }
    sample_index = np.arange(FRAME)
    sync_mode = SYNC_BY_PROFILE[profile]
    cfo_limit = CFO_LIMIT_BY_PROFILE[profile]


def call_rx(iq):
    interleaved = np.empty(2 * len(iq), np.float32)
    interleaved[0::2] = iq.real
    interleaved[1::2] = iq.imag
    result = Result()
    status = C.c_int32(-1)
    rx(interleaved.ctypes.data_as(C.POINTER(C.c_float)), len(iq),
       sync_mode, C.byref(result), C.byref(status))
    return status.value, result


def ideal_frontend(iq, frontend_offset_hz):
    return np.fft.ifft(np.fft.fft(iq) *
                       lp_masks[frontend_offset_hz]).astype(np.complex64)


def noise_chunk(spec):
    first, last, seed_base, frontend_offsets = spec
    rows = []
    for index in range(first, last):
        snr_db = NOISE_LEVELS[index % len(NOISE_LEVELS)]
        n0 = 1 / (2500 * 10 ** (snr_db / 10))
        sigma = np.sqrt(FS * n0 / 2)
        seed = seed_base + index
        frontend_offset = frontend_offsets[index % len(frontend_offsets)]
        rng = np.random.default_rng(seed)
        wide = sigma * (rng.standard_normal(NOISE_CAPTURE) +
                        1j * rng.standard_normal(NOISE_CAPTURE))
        status, result = call_rx(ideal_frontend(wide, frontend_offset))
        rows.append((index, snr_db, seed, status, int(result.crc_ok),
                     int(result.accepted), result.evidence,
                     result.noise_variance / FS / n0, result.start_samples,
                     result.cfo_hz, result.iterations, result.latency_ms,
                     frontend_offset))
    return rows


def signal_chunk(spec):
    snr_db, first, last, seed_base, frontend_offsets = spec
    rows = []
    n0 = 1 / (2500 * 10 ** (snr_db / 10))
    sigma = np.sqrt(FS * n0 / 2)
    corners = tuple(
        (start, cfo, frontend_offset)
        for start in (3600, 8400)
        for cfo in (-cfo_limit, cfo_limit)
        for frontend_offset in frontend_offsets
    )
    for index in range(first, last):
        seed = seed_base + index
        rng = np.random.default_rng(seed)
        bits = rng.integers(0, 2, PAYLOAD_BITS, dtype=np.int8)
        wave_iq = np.empty(2 * FRAME, np.float32)
        written = C.c_int32(-1)
        tx_status = C.c_int32(-1)
        tx(bits.ctypes.data_as(C.POINTER(C.c_int8)),
           wave_iq.ctypes.data_as(C.POINTER(C.c_float)), FRAME,
           C.byref(written), C.byref(tx_status))
        if tx_status.value != 0 or written.value != FRAME:
            raise RuntimeError((tx_status.value, written.value))
        wave = wave_iq[0::2].astype(np.complex64)
        wave.imag = wave_iq[1::2]
        if index < len(corners):
            start, cfo, frontend_offset = corners[index]
        else:
            start = int(rng.integers(3600, 8401))
            cfo = float(rng.uniform(-cfo_limit, cfo_limit))
            frontend_offset = frontend_offsets[index % len(frontend_offsets)]
        initial_phase = float(rng.uniform(-np.pi, np.pi))
        rotation = np.exp(1j * (initial_phase +
                                2 * np.pi * cfo * sample_index / FS))
        # Filter a longer continuous-noise context, then extract the receiver
        # capture. This keeps ideal-LP circular wrap 68,472 samples away from
        # both capture boundaries, including the exact start=8400 end corner.
        wide = sigma * (rng.standard_normal(SIGNAL_FILTER_SAMPLES) +
                        1j * rng.standard_normal(SIGNAL_FILTER_SAMPLES))
        first = SIGNAL_FILTER_PAD + start
        wide[first:first + FRAME] += wave * rotation
        filtered = ideal_frontend(wide, frontend_offset)
        capture = filtered[SIGNAL_FILTER_PAD:
                           SIGNAL_FILTER_PAD + SIGNAL_CAPTURE]
        status, result = call_rx(capture)
        decoded = np.ctypeslib.as_array(result.payload).copy()
        rows.append((snr_db, index, seed, start, cfo, initial_phase,
                     tx_status.value, status, int(result.crc_ok),
                     int(np.array_equal(decoded, bits)), int(result.accepted),
                     result.evidence, result.noise_variance / FS / n0,
                     result.start_samples, result.cfo_hz, result.iterations,
                     result.latency_ms, frontend_offset))
    return rows


def collect(pool, worker, specs, total):
    rows = []
    for part in pool.imap_unordered(worker, specs):
        rows.extend(part)
        if len(rows) % 32 == 0 or len(rows) == total:
            print(f"PROGRESS {len(rows)}/{total}", flush=True)
    rows.sort()
    return rows


def run_noise(args):
    if Path(args.output).exists():
        raise FileExistsError(f"output already exists: {args.output}")
    frontend_offsets = tuple(args.frontend_offset)
    specs = [(first, min(first + args.chunk, args.count), args.seed_base,
              frontend_offsets)
             for first in range(0, args.count, args.chunk)]
    started = time.time()
    with mp.get_context("fork").Pool(
            args.workers, initializer=init_worker,
            initargs=(args.lib, args.cutoff, NOISE_CAPTURE, args.profile,
                      frontend_offsets)) as pool:
        rows = collect(pool, noise_chunk, specs, args.count)
    with open(args.output, "x", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(("index", "snr_db", "seed", "status", "raw_crc",
                         "api_accepted", "evidence", "n0_ratio",
                         "start_samples", "cfo_hz", "iterations", "latency_ms",
                         "frontend_offset_hz"))
        writer.writerows(rows)
    print(f"DONE {len(rows)} wall_s={time.time() - started:.3f}", flush=True)


def run_signal(args):
    if Path(args.output).exists():
        raise FileExistsError(f"output already exists: {args.output}")
    specs = []
    frontend_offsets = tuple(args.frontend_offset)
    for level_index, snr_db in enumerate(args.snr):
        level_seed = args.seed_base + level_index * 1_000_000
        for first in range(0, args.count_per_level, args.chunk):
            specs.append((snr_db, first,
                          min(first + args.chunk, args.count_per_level),
                          level_seed, frontend_offsets))
    total = len(args.snr) * args.count_per_level
    started = time.time()
    with mp.get_context("fork").Pool(
            args.workers, initializer=init_worker,
            initargs=(args.lib, args.cutoff, SIGNAL_FILTER_SAMPLES,
                      args.profile, frontend_offsets)) as pool:
        rows = collect(pool, signal_chunk, specs, total)
    with open(args.output, "x", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(("snr_db", "index", "seed", "true_start", "true_cfo",
                         "initial_phase", "tx_status", "rx_status", "raw_crc",
                         "payload_match", "api_accepted", "evidence", "n0_ratio",
                         "estimated_start", "estimated_cfo", "iterations", "latency_ms",
                         "frontend_offset_hz"))
        writer.writerows(rows)
    print(f"DONE {len(rows)} wall_s={time.time() - started:.3f}", flush=True)


def type7(values, probability):
    ordered = np.sort(np.asarray(values, dtype=float))
    if len(ordered) == 0:
        raise ValueError("cannot summarize an empty sample")
    h = (len(ordered) - 1) * probability
    lower = math.floor(h)
    fraction = h - lower
    upper = min(lower + 1, len(ordered) - 1)
    return ((1 - fraction) * ordered[lower] + fraction * ordered[upper],
            lower, fraction, ordered[lower], ordered[upper])


def summarize_noise(args):
    with open(args.input, newline="") as stream:
        rows = list(csv.DictReader(stream))
    bad_status = [row for row in rows if int(row["status"]) != 0]
    if bad_status:
        raise ValueError(f"{len(bad_status)} receiver calls returned nonzero status")
    evidence = np.asarray([float(row["evidence"]) for row in rows])
    ratio = np.asarray([float(row["n0_ratio"]) for row in rows])
    contract = [int(row["raw_crc"]) and float(row["evidence"]) >= args.gate
                for row in rows]
    mismatch = [row for row, expected in zip(rows, contract)
                if bool(int(row["api_accepted"])) != bool(expected)]
    if mismatch:
        raise ValueError(f"{len(mismatch)} API acceptance values disagree with gate")
    quantile, lower, fraction, low_value, high_value = type7(evidence, 0.99)
    raw_crc = sum(int(row["raw_crc"]) for row in rows)
    accepted = sum(int(row["api_accepted"]) for row in rows)
    exceed = int(np.count_nonzero(evidence >= args.gate))
    print(f"samples={len(rows)}")
    print(f"p99_type7={quantile:.17g}")
    print(f"type7_lower_zero_based={lower}")
    print(f"type7_fraction={fraction:.17g}")
    print(f"type7_values={low_value:.17g},{high_value:.17g}")
    print(f"gate={args.gate:.17g}")
    print(f"evidence_ge_gate={exceed}")
    print(f"raw_crc={raw_crc}")
    print(f"accepted={accepted}")
    print(f"n0_ratio_min_median_max={ratio.min():.17g},"
          f"{np.median(ratio):.17g},{ratio.max():.17g}")
    print(f"evidence_max={evidence.max():.17g}")


def summarize_signal(args):
    with open(args.input, newline="") as stream:
        rows = list(csv.DictReader(stream))
    bad_status = [row for row in rows
                  if int(row["tx_status"]) != 0 or int(row["rx_status"]) != 0]
    if bad_status:
        raise ValueError(f"{len(bad_status)} TX/RX calls returned nonzero status")
    levels = sorted({float(row["snr_db"]) for row in rows})
    for level in levels:
        selected = [row for row in rows if float(row["snr_db"]) == level]
        contract = [int(row["raw_crc"]) and float(row["evidence"]) >= args.gate
                    for row in selected]
        mismatch = [row for row, expected in zip(selected, contract)
                    if bool(int(row["api_accepted"])) != bool(expected)]
        if mismatch:
            raise ValueError(f"{len(mismatch)} API acceptance values disagree with gate")
        raw = [row for row in selected
               if int(row["raw_crc"]) and int(row["payload_match"])]
        gated = [row for row in raw if float(row["evidence"]) >= args.gate]
        api_accepted = sum(int(row["api_accepted"]) for row in selected)
        evidence = np.asarray([float(row["evidence"]) for row in raw])
        if not len(evidence):
            print(f"snr_db={level:g} samples={len(selected)} raw_correct=0 "
                  f"gated_correct=0 api_accepted={api_accepted} "
                  "evidence_min_median_max=NA,NA,NA")
            continue
        print(f"snr_db={level:g} samples={len(selected)} raw_correct={len(raw)} "
              f"gated_correct={len(gated)} api_accepted={api_accepted} "
              "evidence_min_median_max="
              f"{evidence.min():.17g},{np.median(evidence):.17g},"
              f"{evidence.max():.17g}")


def add_run_options(parser, default_workers):
    parser.add_argument("--lib", default="lib/libqf256.so")
    parser.add_argument("--seed-base", type=int, required=True)
    parser.add_argument("--cutoff", type=float, default=1850.0)
    parser.add_argument("--profile", choices=tuple(SYNC_BY_PROFILE),
                        default="wide")
    parser.add_argument("--frontend-offset", type=float, nargs="+",
                        default=(0.0,))
    parser.add_argument("--workers", type=int, default=default_workers)
    parser.add_argument("--chunk", type=int, default=32)
    parser.add_argument("--output", required=True)


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    noise = commands.add_parser("noise")
    add_run_options(noise, 4)
    noise.add_argument("--count", type=int, required=True)
    noise.set_defaults(function=run_noise)
    signal = commands.add_parser("signal")
    add_run_options(signal, 8)
    signal.set_defaults(chunk=4)
    signal.add_argument("--count-per-level", type=int, default=128)
    signal.add_argument("--snr", type=float, nargs="+", default=(-20.0, -18.0))
    signal.set_defaults(function=run_signal)
    noise_summary = commands.add_parser("summarize-noise")
    noise_summary.add_argument("--input", required=True)
    noise_summary.add_argument("--gate", type=float, required=True)
    noise_summary.set_defaults(function=summarize_noise)
    signal_summary = commands.add_parser("summarize-signal")
    signal_summary.add_argument("--input", required=True)
    signal_summary.add_argument("--gate", type=float, required=True)
    signal_summary.set_defaults(function=summarize_signal)
    args = parser.parse_args()
    args.function(args)


if __name__ == "__main__":
    main()
