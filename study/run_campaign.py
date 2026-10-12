#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build, execute, validate and publish one fixed-design numerical campaign.

The exact compiler argv and source/binary hashes are recorded before trials.
Resume accepts only matching builds and validates each row against its job.
Both complete-table validators run in staging before canonical files change.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import csv
from datetime import datetime, timezone
import hashlib
import io
import json
import math
from pathlib import Path
import shlex
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
FLAGS = "-O3 -std=f2008 -ffree-line-length-none -Wall -Wextra -Werror"
CORE = ["src/core/numerics.f90", "src/core/waveform_metrics.f90",
        "src/core/qra_soft.f90", "src/core/mfsk_iq.f90", "src/qf256_api.f90"]
CHANNEL = ["study/channel.f90", "study/frontend.f90"]
SOURCES = CORE + CHANNEL + ["study/reproduce.f90", "study/validate_snr.f90",
                            "study/analyze.f90", "study/summarize_physical.f90",
                            "study/run_campaign.py", "Makefile"]
PROGRAMS = {
    "reproduce": CORE + CHANNEL + ["study/reproduce.f90"],
    "validate_snr": CORE + CHANNEL + ["study/validate_snr.f90"],
    "analyze": ["study/analyze.f90"],
    "summarize_physical": ["study/summarize_physical.f90"],
}
SIGNAL_FIELDS = ("channel_id,constraint,snr_db,trial,payload_seed,channel_seed,noise_seed,"
                 "source77_hex,accepted,correct_payload,decoded_wrong,average_power,peak_power,energy,"
                 "papr_db,bw99_hz,snr_average_db,ebn0_77_db,start_true_s,start_estimated_s,"
                 "cfo_true_hz,cfo_estimated_hz,iterations,evidence,peak_convergence_db").split(",")
NOISE_FIELDS = ("phase,global_index,point,trial,snr_reference_db,actual_noise_seed,"
                "raw_crc_accepted,accepted,evidence,true_noise_variance,estimated_noise_variance,"
                "start_estimated_s,cfo_estimated_hz,iterations,gate_enabled,gate").split(",")
CANONICAL_SIGNAL = ("source_id,source_row,channel,power_constraint,snr_reference_db,trial,payload_seed,"
                    "channel_seed,noise_seed,message77_hex,correct_accepted,accepted,accepted_wrong,"
                    "average_power,peak_power,energy,papr_db,bw99_hz,snr_average_db,ebn0_77_db,"
                    "start_true_s,start_estimated_s,cfo_true_hz,cfo_estimated_hz,iterations,evidence").split(",")
CANONICAL_NOISE = ("source_id,source_row,lot,global_index,point,trial,snr_reference_db,noise_seed,"
                   "raw_fec_accepted,recorded_accepted,evidence,false_messages,noise_variance_expected,"
                   "noise_variance_estimated,start_estimated_s,cfo_estimated_hz,iterations,"
                   "gate_enabled,gate_recorded").split(",")
PHYSICAL_FIELDS = ("channel_id,constraint,snr_db,trial,payload_seed,channel_seed,noise_seed,"
                   "source77_hex,average_power,peak_power,energy,papr_db,bw99_hz,"
                   "snr_average_db,ebn0_77_db,start_true_s,cfo_true_hz").split(",")
SNR_FIELDS = "channel,target_snr_db,valid_cases,bias_db,rmse_db".split(",")
GATE = 30.220758775848424
PROMOTED_OUTPUTS = ("confirmation.csv", "noise.csv", "SNR_VALIDATION.csv", "DATA_SOURCES.csv",
                    "physical/confirmation_physical.csv", "physical/summary.csv",
                    "physical/bw99_cdf.csv", "physical/papr_cdf.csv", "RESULTS.txt",
                    "cells.csv", "aggregate.csv", "thresholds.csv",
                    "noise_summary.csv", "publication-cells.tex", "publication-thresholds.tex")


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def utc():
    return datetime.now(timezone.utc).isoformat()


def source_hashes(root=ROOT):
    return {p: sha(root / p) for p in SOURCES}


def compiler_identity(compiler):
    resolved = shutil.which(compiler)
    if not resolved:
        raise ValueError(f"compiler not found: {compiler}")
    resolved = str(Path(resolved).resolve())
    return {"path": resolved, "sha256": sha(resolved),
            "version": subprocess.check_output([resolved, "--version"], text=True).splitlines()[0]}


def build_identity(compiler="gfortran", flags=FLAGS, *, root=ROOT, build_dir=None):
    root = Path(root)
    build_dir = Path(build_dir) if build_dir is not None else root / "study/build"
    before = source_hashes(root)
    toolchain = compiler_identity(compiler)
    commands = {}
    for name, sources in PROGRAMS.items():
        modules = build_dir / f"{name}-mod"
        modules.mkdir(parents=True, exist_ok=True)
        executable = build_dir / name
        actual_flags = shlex.split(flags)
        if name in ("analyze", "summarize_physical"):
            actual_flags += ["-fcheck=all"]
        command = [toolchain["path"], *actual_flags, f"-J{modules}", f"-I{modules}",
                   *sources, "-o", str(executable)]
        subprocess.run(command, cwd=root, check=True)
        commands[name] = command
    if source_hashes(root) != before or compiler_identity(toolchain["path"]) != toolchain:
        raise ValueError("source/compiler changed while building")
    record = {"sources_sha256": before, "compiler": toolchain, "compiler_flags": flags,
              "build_commands": commands, "executables_sha256":
              {f"study/build/{name}": sha(build_dir / name) for name in PROGRAMS}}
    path = build_dir / "BUILD.json"
    path.write_text(json.dumps(record, indent=2) + "\n")
    return identity(root=root, build_dir=build_dir)


def identity(root=ROOT, build_dir=None):
    build_dir = Path(build_dir) if build_dir is not None else root / "study/build"
    record = json.loads((build_dir / "BUILD.json").read_text())
    return identity_from_record(record, root=root, build_dir=build_dir)


def identity_from_record(record, *, root=ROOT, build_dir=None):
    build_dir = Path(build_dir) if build_dir is not None else root / "study/build"
    if record["sources_sha256"] != source_hashes(root):
        raise ValueError("source differs from actual build")
    if record["compiler"] != compiler_identity(record["compiler"]["path"]):
        raise ValueError("compiler differs from actual build")
    for name, sources in PROGRAMS.items():
        modules = build_dir / f"{name}-mod"
        flags = shlex.split(record["compiler_flags"])
        if name in ("analyze", "summarize_physical"):
            flags += ["-fcheck=all"]
        expected = [record["compiler"]["path"], *flags, f"-J{modules}", f"-I{modules}",
                    *sources, "-o", str(build_dir / name)]
        if record["build_commands"].get(name) != expected:
            raise ValueError("recorded compiler flags/argv mismatch")
    if set(record["executables_sha256"]) != {f"study/build/{name}" for name in PROGRAMS}:
        raise ValueError("missing/unknown executable identity")
    for path, expected in record["executables_sha256"].items():
        if sha(build_dir / Path(path).name) != expected:
            raise ValueError(f"executable differs from actual build: {path}")
    return record


def verify_identity(expected):
    if identity() != expected:
        raise ValueError("source/executable/toolchain identity changed")


def design():
    return {"receiver": "blind", "cfo_search_hz": [-125, 125],
            "gate": GATE, "gate_selection": "fixed project constant; no retuning",
            "signal_records": 4608, "paired_cases": 2304,
            "payload_bits": 77, "payload_distribution": "uniform all input bits",
            "snr_reference_hz": 2500, "snr_grid_db": [-24, -22, -20, -18, -16, -14],
            "trials_per_cell": 128, "constraints": ["average", "peak"],
            "channel_parameters_reference": "ITU-R F.1487 Annex 3 sections 3.1--3.3, mid-latitude",
            "channel_model": "two independent equal-ensemble-power Gaussian-scatter paths, 64 tones each",
            "channels": {"quiet": {"id": 2, "delays_ms": [0, .5], "doppler_width_hz": .1},
                         "moderate": {"id": 3, "delays_ms": [0, 1], "doppler_width_hz": .5},
                         "disturbed": {"id": 4, "delays_ms": [0, 2], "doppler_width_hz": 1}},
            "frontend": "ideal USB 300..2700 Hz about centre 1500; padded continuous noise context",
            "signal_cfo_hz": [-2, 2], "signal_start_s": [.4, .6], "capture_samples": 180000,
            "payload_seed_base": 20271011, "channel_seed_base": 120271011,
            "signal_noise_seed_base": 220271011, "signal_noise_seed_offset": 29,
            "seed_condition": "(channel_id-1)*6+point",
            "noise_diagnostic_seed_base": 40271011,
            "noise_check_seed_base": 60271011, "diagnostic_captures": 2048,
            "independent_check_captures": 4096, "snr_validation_rows": 15,
            "snr_validation_trials_per_row": 128,
            "snr_awgn_seed_base": 70701011, "snr_channel_seed_base": 80701011,
            "snr_noise_seed_base": 90701011}


def tasks(directory):
    jobs = []
    for source_id, (constraint, channel) in enumerate(
            (("average", 2), ("average", 3), ("average", 4),
             ("peak", 2), ("peak", 3), ("peak", 4)), 1):
        for point in range(1, 7):
            for trial in range(1, 129):
                row = (point - 1) * 128 + trial
                path = directory / f"S{source_id:02}-{row:04}.csv"
                jobs.append((path, [str(ROOT / "study/build/reproduce"), "signal",
                                   str(channel), constraint, str(point), str(trial), str(path)]))
    for phase, count, first_id, shard_size in (("noise-diagnostic", 2048, 7, 1024),
                                              ("noise-check", 4096, 9, 2048)):
        for index in range(1, count + 1):
            source_id = first_id + (index - 1) // shard_size
            row = (index - 1) % shard_size + 1
            path = directory / f"S{source_id:02}-{row:04}.csv"
            jobs.append((path, [str(ROOT / "study/build/reproduce"), phase, str(index), str(path)]))
    return jobs


def validate_row(job, row):
    path, command = job
    phase = command[1]
    fields = SIGNAL_FIELDS if phase == "signal" else NOISE_FIELDS
    if list(row) != fields or None in row.values():
        raise ValueError(f"unexpected schema: {path}")
    text_fields = {"constraint", "source77_hex", "phase"}
    for key, value in row.items():
        if key not in text_fields and not math.isfinite(float(value)):
            raise ValueError(f"nonfinite {key}: {path}")
    expected = {}
    if phase == "signal":
        channel, constraint, point, trial = int(command[2]), command[3], int(command[4]), int(command[5])
        condition = (channel - 1) * 6 + point
        expected = {"channel_id": channel, "constraint": constraint, "snr_db": -26 + 2 * point,
                    "trial": trial, "payload_seed": 20271011 + condition * 100003 + trial * 101,
                    "channel_seed": 120271011 + condition * 200003 + trial * 307,
                    "noise_seed": 220271011 + condition * 300007 + trial * 911}
        token = row["source77_hex"]
        if len(token) != 20 or token[0] not in "01" or any(c not in "0123456789ABCDEF" for c in token):
            raise ValueError(f"invalid 77-bit source token: {path}")
        accepted, correct, wrong = (int(row[k]) for k in ("accepted", "correct_payload", "decoded_wrong"))
        if any(v not in (0, 1) for v in (accepted, correct, wrong)) or correct + wrong != accepted:
            raise ValueError(f"inconsistent signal flags: {path}")
        if accepted and float(row["evidence"]) < GATE:
            raise ValueError(f"accepted below gate: {path}")
        if not .4 <= float(row["start_true_s"]) <= .6 or abs(float(row["cfo_true_hz"])) > 2:
            raise ValueError(f"out-of-design signal truth: {path}")
        if any(float(row[k]) <= 0 for k in ("average_power", "peak_power", "energy", "bw99_hz")):
            raise ValueError(f"nonpositive waveform measurement: {path}")
        if not 0 <= float(row["peak_convergence_db"]) <= .05:
            raise ValueError(f"unconverged peak reference: {path}")
    else:
        if phase not in ("noise-diagnostic", "noise-check"):
            raise ValueError(f"unknown phase {phase}")
        index = int(command[2])
        point, trial = (index - 1) % 6 + 1, (index - 1) // 6 + 1
        base = 40271011 if phase == "noise-diagnostic" else 60271011
        expected = {"phase": phase, "global_index": index, "point": point, "trial": trial,
                    "snr_reference_db": -26 + 2 * point,
                    "actual_noise_seed": base + point * 300007 + trial * 911 + 29,
                    "gate_enabled": 1, "gate": GATE}
        raw, accepted = (int(row[k]) for k in ("raw_crc_accepted", "accepted"))
        if raw not in (0, 1) or accepted not in (0, 1) or accepted != int(raw and float(row["evidence"]) >= GATE):
            raise ValueError(f"inconsistent noise flags: {path}")
        variance = 12000 / (2500 * 10 ** ((-26 + 2 * point) / 10))
        if not math.isclose(float(row["true_noise_variance"]), variance, rel_tol=1e-12):
            raise ValueError(f"incorrect pre-frontend noise variance: {path}")
        if float(row["estimated_noise_variance"]) <= 0:
            raise ValueError(f"nonpositive estimated N0: {path}")
    for key, value in expected.items():
        actual = row[key] if isinstance(value, str) else float(row[key])
        if actual != value:
            raise ValueError(f"{path}: {key}={actual!r}, expected {value!r}")
    if not .3 <= float(row["start_estimated_s"]) <= .7 or abs(float(row["cfo_estimated_hz"])) > 125:
        raise ValueError(f"acquisition result outside bounds: {path}")
    if not 1 <= int(row["iterations"]) <= 100:
        raise ValueError(f"invalid iteration count: {path}")


def read_and_validate(job):
    path, command = job
    with path.open(newline="") as stream:
        reader = csv.DictReader(stream)
        expected = SIGNAL_FIELDS if command[1] == "signal" else NOISE_FIELDS
        if reader.fieldnames != expected:
            raise ValueError(f"unexpected raw CSV header: {path}")
        rows = list(reader)
    if len(rows) != 1:
        raise ValueError(f"expected exactly one record: {path}")
    validate_row(job, rows[0])
    return rows[0]


def execute(job):
    path, command = job
    if not path.exists():
        subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True)
    read_and_validate(job)
    return path.name


def write_csv(path, fields, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".pending")
    with temporary.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    temporary.replace(path)


def collect(directory, destination):
    signal_rows, noise_rows, physical_rows, sources = [], [], [], []
    jobs = dict((path.name, (path, command)) for path, command in tasks(directory))
    signal_map = {"channel": "channel_id", "power_constraint": "constraint",
                  "snr_reference_db": "snr_db", "message77_hex": "source77_hex",
                  "correct_accepted": "correct_payload", "accepted_wrong": "decoded_wrong"}
    noise_map = {"noise_seed": "actual_noise_seed", "raw_fec_accepted": "raw_crc_accepted",
                 "recorded_accepted": "accepted", "false_messages": "accepted",
                 "noise_variance_expected": "true_noise_variance",
                 "noise_variance_estimated": "estimated_noise_variance", "gate_recorded": "gate"}
    for source_id in range(1, 11):
        paths = sorted(directory.glob(f"S{source_id:02}-*.csv"))
        expected = 768 if source_id <= 6 else (1024 if source_id <= 8 else 2048)
        if len(paths) != expected:
            raise ValueError(f"incomplete S{source_id:02}: {len(paths)}/{expected}")
        raw = []
        for index, path in enumerate(paths, 1):
            if path.name not in jobs:
                raise ValueError(f"unexpected indexed record {path}")
            row = read_and_validate(jobs[path.name])
            raw.append(row)
            normalized = {"source_id": f"S{source_id:02}", "source_row": index}
            if source_id <= 6:
                for key in CANONICAL_SIGNAL[2:]:
                    normalized[key] = row[signal_map.get(key, key)]
                normalized["channel"] = {"2": "quiet", "3": "moderate", "4": "disturbed"}[row["channel_id"]]
                signal_rows.append(normalized)
                physical_rows.append({key: row[key] for key in PHYSICAL_FIELDS})
            else:
                normalized["lot"] = "diagnostic" if source_id <= 8 else "independent"
                for key in CANONICAL_NOISE[3:]:
                    normalized[key] = row[noise_map.get(key, key)]
                noise_rows.append(normalized)
        shard = directory / f"S{source_id:02}.csv"
        write_csv(shard, list(raw[0]), raw)
        sources.append({"source_id": f"S{source_id:02}", "record_role":
                        (f"signal_{raw[0]['channel_id']}_{raw[0]['constraint']}" if source_id <= 6
                         else raw[0]["phase"]), "rows": expected, "raw_source_sha256": sha(shard)})
    write_csv(destination / "confirmation.csv", CANONICAL_SIGNAL, signal_rows)
    write_csv(destination / "noise.csv", CANONICAL_NOISE, noise_rows)
    write_csv(destination / "physical/confirmation_physical.csv", PHYSICAL_FIELDS, physical_rows)
    write_csv(destination / "DATA_SOURCES.csv", list(sources[0]), sources)


def snr_row(index):
    data = subprocess.check_output([str(ROOT / "study/build/validate_snr"), str(index)], text=True)
    reader = csv.DictReader(io.StringIO(data))
    rows = list(reader)
    if reader.fieldnames != SNR_FIELDS or len(rows) != 1:
        raise ValueError(f"invalid SNR validation row {index}")
    row = rows[0]
    expected_channel = "awgn" if index <= 6 else ("quiet", "moderate", "disturbed")[(index-7)//3]
    expected_snr = -26 + 2 * index if index <= 6 else -18 + 2 * ((index - 7) % 3)
    if row["channel"] != expected_channel or float(row["target_snr_db"]) != expected_snr:
        raise ValueError(f"SNR row index mismatch {index}")
    if not 1 <= int(row["valid_cases"]) <= 128 or (index <= 6 and int(row["valid_cases"]) != 128):
        raise ValueError(f"invalid SNR case count {index}")
    if not all(math.isfinite(float(row[key])) for key in ("bias_db", "rmse_db")) or float(row["rmse_db"]) < 0:
        raise ValueError(f"nonfinite SNR summary {index}")
    return row


def promote_validated(stage, destination, expected_identity, *, analyzer, summarizer, identity_fn=identity):
    subprocess.run([str(analyzer), "summarize", str(stage)], cwd=ROOT, check=True)
    subprocess.run([str(summarizer), str(stage)], cwd=ROOT, check=True)
    if identity_fn() != expected_identity:
        raise ValueError("identity changed before promotion")
    files = [stage / name for name in PROMOTED_OUTPUTS]
    if any(not path.is_file() for path in files):
        raise ValueError("validated stage lacks required outputs")
    pending = []
    for path in files:
        target = destination / path.relative_to(stage)
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(target.suffix + ".pending")
        shutil.copyfile(path, temporary)
        pending.append((temporary, target))
    if identity_fn() != expected_identity:
        raise ValueError("identity changed while preparing promotion")
    for temporary, target in pending:
        temporary.replace(target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--output", type=Path, default=ROOT / "study/build/campaign")
    parser.add_argument("--compiler", default="gfortran")
    parser.add_argument("--flags", default=FLAGS)
    args = parser.parse_args()
    if not 1 <= args.workers <= 8:
        parser.error("use 1..8 independent workers")
    directory = args.output.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    metadata_path = directory / "CAMPAIGN.json"
    current = build_identity(args.compiler, args.flags)
    if metadata_path.exists():
        metadata = json.loads(metadata_path.read_text())
        if metadata["identity"] != current or metadata["design"] != design():
            raise ValueError("refusing to resume with changed executable/source/design")
    else:
        metadata = {"started_utc": utc(), "identity": current, "design": design(),
                    "workers": args.workers, "git_head_before_run": subprocess.check_output(
                        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()}
        metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")
    started = time.monotonic()
    jobs = tasks(directory)
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for count, _ in enumerate(pool.map(execute, jobs), 1):
            if count % 128 == 0 or count == len(jobs):
                print(f"completed {count}/{len(jobs)} wall_s={time.monotonic()-started:.1f}", flush=True)
        snr = list(pool.map(snr_row, range(1, 16)))
    verify_identity(current)
    stage = directory / "validated"
    stage.mkdir(exist_ok=True)
    collect(directory, stage)
    write_csv(stage / "SNR_VALIDATION.csv", SNR_FIELDS, snr)
    promote_validated(stage, ROOT / "study", current,
                      analyzer=ROOT / "study/build/analyze",
                      summarizer=ROOT / "study/build/summarize_physical")
    metadata["completed_utc"] = utc()
    metadata["wall_seconds"] = time.monotonic() - started
    metadata["outputs_sha256"] = {str(path.relative_to(ROOT)): sha(path) for path in
                                  (ROOT / "study" / name for name in PROMOTED_OUTPUTS)}
    text = json.dumps(metadata, indent=2) + "\n"
    metadata_path.write_text(text)
    (ROOT / "study/CAMPAIGN.json").write_text(text)
    print(f"complete: {len(jobs)} indexed calls plus 1920 SNR cases", flush=True)


if __name__ == "__main__":
    main()
