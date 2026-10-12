#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify indexed replay and write checksums for the completed study evidence."""
import csv
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

if __package__:
    from .run_campaign import design, identity
else:
    from run_campaign import design, identity

ROOT = Path(__file__).resolve().parent.parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_rows(path):
    with path.open(newline="") as stream:
        return list(csv.DictReader(stream))


def main():
    metadata = json.loads((ROOT / "study/CAMPAIGN.json").read_text())
    if metadata.get("design") != design() or not metadata.get("completed_utc"):
        raise ValueError("canonical campaign design/completion mismatch")
    if identity(root=ROOT) != metadata["identity"]:
        raise ValueError("source/executable/toolchain differs from executed campaign")
    for path, expected in metadata["identity"]["sources_sha256"].items():
        if sha(ROOT / path) != expected:
            raise ValueError(f"source differs from executed campaign: {path}")
    for path, expected in metadata["outputs_sha256"].items():
        if sha(ROOT / path) != expected:
            raise ValueError(f"canonical record differs from completed campaign: {path}")
    for name, expected_count in (("noise", 4096), ("signals", 384)):
        path = ROOT / "study/acquisition" / f"{name}.csv"
        evidence = json.loads(path.with_suffix(".json").read_text())
        if evidence.get("receiver") != "blind" or evidence.get("cfo_limit_hz") != 125.0:
            raise ValueError("acquisition receiver contract mismatch")
        expected_arguments = {"cutoff": 1200.0, "frontend_offset": [-25.0, 25.0]}
        if name == "noise":
            expected_arguments.update(command="noise", seed_base=9106101100, count=4096)
        else:
            expected_arguments.update(command="signal", seed_base=9107101100,
                                      count_per_level=128, snr=[-20.0, -18.0, -4.0])
        for key, expected in expected_arguments.items():
            if evidence.get("arguments", {}).get(key) != expected:
                raise ValueError(f"acquisition design mismatch: {name}/{key}")
        if sha(path) != evidence["output_sha256"] or len(read_rows(path)) != expected_count:
            raise ValueError(f"acquisition record identity/count mismatch: {name}")
        for source, expected in evidence["source_sha256"].items():
            if sha(ROOT / source) != expected:
                raise ValueError(f"acquisition source differs: {source}")
        if sha(ROOT / "lib/libqf256.so") != evidence["library_sha256"]:
            raise ValueError("acquisition library differs from executed artifact")
        command = "summarize-noise" if name == "noise" else "summarize-signal"
        subprocess.run(["python3", str(ROOT / "study/validate_acquisition.py"), command,
                        "--input", str(path), "--gate", "30.220758775848424"], check=True, cwd=ROOT)
    signal = next(row for row in read_rows(ROOT / "study/confirmation.csv")
                  if row["source_id"] == "S01" and int(row["source_row"]) == 257)
    noise = next(row for row in read_rows(ROOT / "study/noise.csv")
                 if row["lot"] == "independent" and int(row["global_index"]) == 1)
    with tempfile.TemporaryDirectory(prefix="replay-", dir=ROOT / "study/build") as directory:
        directory = Path(directory)
        subprocess.run([str(ROOT / "study/build/reproduce"), "signal", "2", "average", "3", "1",
                        str(directory / "signal.csv")], check=True, cwd=ROOT)
        subprocess.run([str(ROOT / "study/build/reproduce"), "noise-check", "1",
                        str(directory / "noise.csv")], check=True, cwd=ROOT)
        replay_signal = read_rows(directory / "signal.csv")[0]
        replay_noise = read_rows(directory / "noise.csv")[0]
        signal_map = {"message77_hex": "source77_hex", "correct_accepted": "correct_payload",
                      "accepted_wrong": "decoded_wrong", "snr_reference_db": "snr_db",
                      "power_constraint": "constraint"}
        for key, value in signal.items():
            if key not in ("source_id", "source_row", "channel"):
                if value != replay_signal[signal_map.get(key, key)]:
                    raise ValueError(f"indexed signal replay mismatch: {key}")
        noise_map = {"noise_seed": "actual_noise_seed", "raw_fec_accepted": "raw_crc_accepted",
                     "recorded_accepted": "accepted", "false_messages": "accepted",
                     "noise_variance_expected": "true_noise_variance",
                     "noise_variance_estimated": "estimated_noise_variance", "gate_recorded": "gate"}
        for key, value in noise.items():
            if key not in ("source_id", "source_row", "lot"):
                if value != replay_noise[noise_map.get(key, key)]:
                    raise ValueError(f"indexed noise replay mismatch: {key}")
    report = ("QF256 deterministic indexed replay\n\n"
              "Both rows were regenerated from the campaign source and matched every retained field exactly.\n"
              "Signal: reproduce signal 2 average 3 1 NEW_SIGNAL.csv\n"
              "Noise: reproduce noise-check 1 NEW_NOISE.csv\n"
              f"Compiler: {metadata['identity']['compiler']['version']}\n"
              f"Signal payload: {signal['message77_hex']}\n"
              f"Signal correct/accepted: {signal['correct_accepted']}/{signal['accepted']}\n"
              f"Signal evidence: {signal['evidence']}\n"
              f"Noise raw/accepted: {noise['raw_fec_accepted']}/{noise['recorded_accepted']}\n"
              f"Noise evidence: {noise['evidence']}\n"
              f"Fixed gate: {noise['gate_recorded']}\n")
    (ROOT / "study/REPRODUCTION_CHECK.txt").write_text(report)
    data = ["study/confirmation.csv", "study/noise.csv", "study/SNR_VALIDATION.csv",
            "study/DATA_SOURCES.csv", "study/CAMPAIGN.json", "study/REPRODUCTION_CHECK.txt",
            "study/acquisition/noise.csv", "study/acquisition/signals.csv",
            "study/acquisition/noise.json", "study/acquisition/signals.json"]
    physical = [str(path.relative_to(ROOT)) for path in sorted((ROOT / "study/physical").glob("*.csv"))]
    physical += ["study/MODEL.md", "study/PHYSICAL.md", "study/frontend.f90", "study/reproduce.f90",
                 "study/summarize_physical.f90", "study/plots.gp", "study/analyze.f90"]
    for name, paths in (("DATA.sha256", data), ("PHYSICAL.sha256", physical)):
        (ROOT / "study" / name).write_text("".join(f"{sha(ROOT / path)}  {path}\n" for path in paths))
    print("Indexed signal/noise replays match; study evidence checksums written.")


if __name__ == "__main__":
    main()
