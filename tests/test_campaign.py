#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Negative tests for campaign provenance, resumption and publication."""

import copy
import csv
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("qf256_run_campaign", ROOT / "study/run_campaign.py")
CAMPAIGN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAMPAIGN)


def write_record(path, fields, row):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerow(row)


def signal_row(channel=2, constraint="average", point=1, trial=1):
    condition = (channel - 1) * 6 + point
    row = {field: "0" for field in CAMPAIGN.SIGNAL_FIELDS}
    row.update({
        "channel_id": str(channel),
        "constraint": constraint,
        "snr_db": str(-26 + 2 * point),
        "trial": str(trial),
        "payload_seed": str(20271011 + condition * 100003 + trial * 101),
        "channel_seed": str(120271011 + condition * 200003 + trial * 307),
        "noise_seed": str(220271011 + condition * 300007 + trial * 911),
        "source77_hex": "00000000000000000000",
        "accepted": "0",
        "correct_payload": "0",
        "decoded_wrong": "0",
        "average_power": "1",
        "peak_power": "1.2",
        "energy": "9.7",
        "papr_db": "0.8",
        "bw99_hz": "1992",
        "snr_average_db": str(-26 + 2 * point),
        "ebn0_77_db": "0",
        "start_true_s": "0.5",
        "start_estimated_s": "0.5",
        "cfo_true_hz": "0",
        "cfo_estimated_hz": "0",
        "iterations": "1",
        "evidence": "0",
        "peak_convergence_db": "0.01",
    })
    return row


def noise_row(index=1, phase="noise-check"):
    point = (index - 1) % 6 + 1
    trial = (index - 1) // 6 + 1
    base = 40271011 if phase == "noise-diagnostic" else 60271011
    snr = -26 + 2 * point
    variance = 12000 / (2500 * 10 ** (snr / 10))
    row = {field: "0" for field in CAMPAIGN.NOISE_FIELDS}
    row.update({
        "phase": phase,
        "global_index": str(index),
        "point": str(point),
        "trial": str(trial),
        "snr_reference_db": str(snr),
        "actual_noise_seed": str(base + point * 300007 + trial * 911 + 29),
        "raw_crc_accepted": "0",
        "accepted": "0",
        "evidence": "0",
        "true_noise_variance": repr(variance),
        "estimated_noise_variance": repr(variance),
        "start_estimated_s": "0.5",
        "cfo_estimated_hz": "0",
        "iterations": "1",
        "gate_enabled": "1",
        "gate": repr(CAMPAIGN.GATE),
    })
    return row


class IndexedRecordTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="qf256-campaign-row-")
        self.directory = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def signal_job(self, channel=2, constraint="average", point=1, trial=1):
        path = self.directory / "S01-0001.csv"
        return path, ["unused-reproduce", "signal", str(channel), constraint,
                      str(point), str(trial), str(path)]

    def noise_job(self, index=1, phase="noise-check"):
        path = self.directory / "S07-0001.csv"
        return path, ["unused-reproduce", phase, str(index), str(path)]

    def test_valid_signal_and_noise_rows_match_their_jobs(self):
        for channel in (2, 3, 4):
            with self.subTest(channel=channel):
                signal = self.signal_job(channel=channel)
                write_record(signal[0], CAMPAIGN.SIGNAL_FIELDS, signal_row(channel=channel))
                self.assertEqual(CAMPAIGN.read_and_validate(signal)["channel_id"], str(channel))

        noise = self.noise_job()
        write_record(noise[0], CAMPAIGN.NOISE_FIELDS, noise_row())
        self.assertEqual(CAMPAIGN.read_and_validate(noise)["actual_noise_seed"], noise_row()["actual_noise_seed"])

    def test_reordered_schema_is_rejected(self):
        job = self.signal_job()
        fields = list(CAMPAIGN.SIGNAL_FIELDS)
        fields[0], fields[1] = fields[1], fields[0]
        write_record(job[0], fields, signal_row())
        with self.assertRaisesRegex(ValueError, "unexpected raw CSV header"):
            CAMPAIGN.read_and_validate(job)

    def test_valid_row_from_another_trial_is_rejected_on_resume(self):
        job = self.signal_job(point=1, trial=1)
        write_record(job[0], CAMPAIGN.SIGNAL_FIELDS, signal_row(point=1, trial=2))
        with self.assertRaisesRegex(ValueError, "trial=.*expected"):
            CAMPAIGN.read_and_validate(job)

    def test_valid_row_from_another_profile_is_rejected_on_resume(self):
        job = self.signal_job(channel=2)
        write_record(job[0], CAMPAIGN.SIGNAL_FIELDS, signal_row(channel=4))
        with self.assertRaisesRegex(ValueError, "channel_id=.*expected"):
            CAMPAIGN.read_and_validate(job)

    def test_noise_seed_gate_and_nonfinite_values_are_rejected(self):
        job = self.noise_job()
        changes = {
            "actual_noise_seed": "1",
            "gate": "29",
            "estimated_noise_variance": "NaN",
        }
        for field, value in changes.items():
            with self.subTest(field=field):
                row = noise_row()
                row[field] = value
                write_record(job[0], CAMPAIGN.NOISE_FIELDS, row)
                with self.assertRaises(ValueError):
                    CAMPAIGN.read_and_validate(job)


class CampaignDesignTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="qf256-campaign-design-")
        self.directory = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_design_and_all_indexed_source_roles_are_exact(self):
        design = CAMPAIGN.design()
        self.assertEqual(design["signal_records"], 4608)
        self.assertEqual(design["paired_cases"], 2304)
        self.assertEqual(design["channels"], {
            "quiet": {"id": 2, "delays_ms": [0, .5], "doppler_width_hz": .1},
            "moderate": {"id": 3, "delays_ms": [0, 1], "doppler_width_hz": .5},
            "disturbed": {"id": 4, "delays_ms": [0, 2], "doppler_width_hz": 1},
        })
        self.assertEqual(design["snr_validation_rows"], 15)

        jobs = CAMPAIGN.tasks(self.directory)
        self.assertEqual(len(jobs), 10752)
        self.assertEqual(len({path.name for path, _ in jobs}), len(jobs))
        by_source = {}
        for path, command in jobs:
            by_source.setdefault(path.name[:3], []).append((path, command))

        signal_roles = (
            ("S01", 2, "average"), ("S02", 3, "average"),
            ("S03", 4, "average"), ("S04", 2, "peak"),
            ("S05", 3, "peak"), ("S06", 4, "peak"),
        )
        for source, channel, constraint in signal_roles:
            records = by_source[source]
            self.assertEqual(len(records), 768)
            observed = set()
            for path, command in records:
                self.assertEqual(command[1:4], ["signal", str(channel), constraint])
                point, trial = map(int, command[4:6])
                self.assertEqual(path.name, f"{source}-{(point - 1) * 128 + trial:04}.csv")
                observed.add((point, trial))
            self.assertEqual(observed, {(point, trial) for point in range(1, 7)
                                        for trial in range(1, 129)})

        noise_roles = (
            ("S07", "noise-diagnostic", 1, 1024),
            ("S08", "noise-diagnostic", 1025, 2048),
            ("S09", "noise-check", 1, 2048),
            ("S10", "noise-check", 2049, 4096),
        )
        for source, phase, first, last in noise_roles:
            records = by_source[source]
            self.assertEqual(len(records), last - first + 1)
            indices = []
            for row, (path, command) in enumerate(records, 1):
                self.assertEqual(command[1], phase)
                self.assertEqual(path.name, f"{source}-{row:04}.csv")
                indices.append(int(command[2]))
            self.assertEqual(indices, list(range(first, last + 1)))

    def test_rng_stream_domains_are_disjoint_and_power_cases_remain_paired(self):
        payload, channel, signal_noise = set(), set(), set()
        case_seeds = {}
        for channel_id in (2, 3, 4):
            for point in range(1, 7):
                condition = (channel_id - 1) * 6 + point
                for trial in range(1, 129):
                    seeds = (
                        20271011 + condition * 100003 + trial * 101,
                        120271011 + condition * 200003 + trial * 307,
                        220271011 + condition * 300007 + trial * 911 + 29,
                    )
                    case_seeds[channel_id, point, trial] = seeds
                    payload.add(seeds[0])
                    channel.add(seeds[1])
                    signal_noise.add(seeds[2])

        self.assertEqual(len(payload), 2304)
        self.assertEqual(len(channel), 2304)
        self.assertEqual(len(signal_noise), 2304)

        diagnostic, independent = set(), set()
        for phase, count, base, target in (
                ("noise-diagnostic", 2048, 40271011, diagnostic),
                ("noise-check", 4096, 60271011, independent)):
            for index in range(1, count + 1):
                point = (index - 1) % 6 + 1
                trial = (index - 1) // 6 + 1
                target.add(base + point * 300007 + trial * 911 + 29)
            self.assertEqual(len(target), count, phase)

        snr_awgn = {70701011 + 1000 * level + trial
                    for level in range(1, 7) for trial in range(1, 129)}
        snr_channel = {80701011 + 10000 * level + trial
                       for level in range(1, 10) for trial in range(1, 129)}
        snr_noise = {90701011 + 10000 * level + trial
                     for level in range(1, 10) for trial in range(1, 129)}
        domains = (payload, channel, signal_noise, diagnostic, independent,
                   snr_awgn, snr_channel, snr_noise)
        for left in range(len(domains)):
            for right in range(left + 1, len(domains)):
                self.assertTrue(domains[left].isdisjoint(domains[right]),
                                f"RNG domains {left} and {right} overlap")

        for channel_id in (2, 3, 4):
            for point in range(1, 7):
                for trial in (1, 64, 128):
                    average = signal_row(channel_id, "average", point, trial)
                    peak = signal_row(channel_id, "peak", point, trial)
                    self.assertEqual(
                        tuple(average[key] for key in ("payload_seed", "channel_seed", "noise_seed")),
                        tuple(peak[key] for key in ("payload_seed", "channel_seed", "noise_seed")),
                    )
                    expected = case_seeds[channel_id, point, trial]
                    self.assertEqual(int(average["payload_seed"]), expected[0])
                    self.assertEqual(int(average["channel_seed"]), expected[1])
                    self.assertEqual(int(average["noise_seed"]) + 29, expected[2])


class BuildIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="qf256-campaign-id-")
        cls.root = Path(cls.temporary.name)
        cls.build = cls.root / "study/build"
        for relative in CAMPAIGN.SOURCES:
            path = cls.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, path)
        flags = "-O0 -std=f2008 -ffree-line-length-none -Wall -Wextra -Werror"
        cls.record = CAMPAIGN.build_identity("gfortran", flags, root=cls.root, build_dir=cls.build)
        cls.pristine_sources = {relative: (cls.root / relative).read_bytes()
                                for relative in CAMPAIGN.SOURCES}
        cls.pristine_executables = {name: (cls.build / name).read_bytes()
                                    for name in CAMPAIGN.PROGRAMS}
        cls.pristine_record = (cls.build / "BUILD.json").read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        for relative, content in self.pristine_sources.items():
            (self.root / relative).write_bytes(content)
        for name, content in self.pristine_executables.items():
            (self.build / name).write_bytes(content)
        (self.build / "BUILD.json").write_bytes(self.pristine_record)
        self.assertEqual(CAMPAIGN.identity(root=self.root, build_dir=self.build), self.record)

    def test_source_changed_after_build_is_rejected(self):
        path = self.root / "study/reproduce.f90"
        path.write_text(path.read_text() + "changed\n")
        with self.assertRaisesRegex(ValueError, "source differs"):
            CAMPAIGN.identity(root=self.root, build_dir=self.build)

    def test_executable_changed_after_build_is_rejected(self):
        path = self.build / "reproduce"
        path.write_bytes(path.read_bytes() + b"changed")
        with self.assertRaisesRegex(ValueError, "executable differs"):
            CAMPAIGN.identity(root=self.root, build_dir=self.build)

    def test_recorded_flags_must_match_the_actual_build_argv(self):
        record = copy.deepcopy(self.record)
        record["compiler_flags"] += " -fcheck=bounds"
        with self.assertRaisesRegex(ValueError, "compiler flags/argv mismatch"):
            CAMPAIGN.identity_from_record(record, root=self.root, build_dir=self.build)


class PromotionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="qf256-campaign-promote-")
        root = Path(self.temporary.name)
        self.stage = root / "stage"
        self.destination = root / "canonical"
        self.stage.mkdir()
        self.destination.mkdir()
        for relative in CAMPAIGN.PROMOTED_OUTPUTS:
            staged = self.stage / relative
            staged.parent.mkdir(parents=True, exist_ok=True)
            staged.write_text(f"new:{relative}\n")
            target = self.destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(f"old:{relative}\n")
        self.expected_identity = {"identity": "fixed"}
        self.true = Path(shutil.which("true"))
        self.false = Path(shutil.which("false"))

    def tearDown(self):
        self.temporary.cleanup()

    def assert_canonical_unchanged(self):
        for relative in CAMPAIGN.PROMOTED_OUTPUTS:
            self.assertEqual((self.destination / relative).read_text(), f"old:{relative}\n")

    def test_validator_failure_does_not_change_canonical_outputs(self):
        with self.assertRaises(subprocess.CalledProcessError):
            CAMPAIGN.promote_validated(
                self.stage, self.destination, self.expected_identity,
                analyzer=self.false, summarizer=self.true,
                identity_fn=lambda: self.expected_identity,
            )
        self.assert_canonical_unchanged()

    def test_copy_failure_does_not_partially_promote(self):
        real_copy = shutil.copyfile
        calls = 0

        def fail_second_copy(source, target):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("injected copy failure")
            return real_copy(source, target)

        with mock.patch.object(CAMPAIGN.shutil, "copyfile", side_effect=fail_second_copy):
            with self.assertRaisesRegex(OSError, "injected copy failure"):
                CAMPAIGN.promote_validated(
                    self.stage, self.destination, self.expected_identity,
                    analyzer=self.true, summarizer=self.true,
                    identity_fn=lambda: self.expected_identity,
                )
        self.assert_canonical_unchanged()


if __name__ == "__main__":
    unittest.main()
