#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check that published-record analysis rejects damaged study inputs."""

import copy
import csv
import math
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class StudyRecordTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {}
        cls.fields = {}
        for name in ("confirmation.csv", "noise.csv"):
            with (ROOT / "study" / name).open(newline="") as stream:
                reader = csv.DictReader(stream)
                cls.fields[name] = reader.fieldnames
                cls.original[name] = list(reader)

    def setUp(self):
        self.rows = copy.deepcopy(self.original)

    def analyze(self):
        with tempfile.TemporaryDirectory(prefix="qf256-study-test-") as directory:
            for name, rows in self.rows.items():
                with (Path(directory) / name).open("w", newline="") as stream:
                    writer = csv.DictWriter(stream, fieldnames=self.fields[name])
                    writer.writeheader()
                    writer.writerows(rows)
            result = subprocess.run(
                [str(ROOT / "study/build/analyze"), "summarize", directory],
                capture_output=True, text=True, check=False,
            )
            if result.returncode == 0:
                with (Path(directory) / "cells.csv").open(newline="") as stream:
                    self.cells = list(csv.DictReader(stream))
                with (Path(directory) / "thresholds.csv").open(newline="") as stream:
                    self.thresholds = list(csv.DictReader(stream))
            return result

    def assert_rejected(self, message):
        result = self.analyze()
        self.assertNotEqual(result.returncode, 0, "damaged records were accepted")
        self.assertIn(message, result.stdout + result.stderr)

    def test_published_records_are_valid(self):
        result = self.analyze()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Validated 4608 signal records", result.stdout)

    def test_statistics_match_independent_calculation(self):
        result = self.analyze()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        grouped = {}
        for row in self.rows["confirmation.csv"]:
            key = (row["channel"], row["power_constraint"], float(row["snr_reference_db"]))
            grouped.setdefault(key, []).append(row)
        self.assertEqual(len(self.cells), 36)
        z = 1.959963984540054
        for cell in self.cells:
            key = (cell["channel"], cell["power_constraint"], float(cell["snr_reference_db"]))
            records = grouped[key]
            n = len(records)
            k = sum(int(row["correct_accepted"]) for row in records)
            self.assertEqual(n, 128)
            self.assertEqual(int(cell["correct_accepted"]), k)
            self.assertEqual(int(cell["accepted_wrong"]), sum(int(row["accepted_wrong"]) for row in records))
            self.assertEqual(int(cell["missed"]), sum(1-int(row["accepted"]) for row in records))
            rate, denominator = k/n, 1+z*z/n
            centre = (rate+z*z/(2*n))/denominator
            radius = z*math.sqrt(rate*(1-rate)/n+z*z/(4*n*n))/denominator
            self.assertAlmostEqual(float(cell["correct_rate"]), rate, places=12)
            self.assertAlmostEqual(float(cell["wilson95_low"]), max(0, centre-radius), places=12)
            self.assertAlmostEqual(float(cell["wilson95_high"]), min(1, centre+radius), places=12)
        self.assertEqual(len(self.thresholds), 6)
        for threshold in self.thresholds:
            key = (threshold["channel"], threshold["power_constraint"])
            grid = sorted(snr for channel, power, snr in grouped if (channel, power) == key)
            counts = [sum(int(row["correct_accepted"]) for row in grouped[key + (snr,)]) for snr in grid]
            crossing = next(left+(right-left)*(64-a)/(b-a)
                            for left, right, a, b in zip(grid, grid[1:], counts, counts[1:])
                            if a < 64 <= b)
            self.assertAlmostEqual(float(threshold["linear_50pct_crossing_db"]), crossing, places=12)

    def test_energy_snr_and_payload_domain(self):
        bits = []
        for row in self.rows["confirmation.csv"]:
            power, energy, snr = (float(row[key]) for key in ("average_power", "energy", "snr_reference_db"))
            self.assertAlmostEqual(energy, power*116800/12000, places=9)
            self.assertAlmostEqual(float(row["snr_average_db"]), snr+10*math.log10(power), places=9)
            self.assertAlmostEqual(float(row["ebn0_77_db"]), snr+10*math.log10(2500*energy/77), places=9)
            if row["power_constraint"] == "average":
                bits.append(format(int(row["message77_hex"], 16), "077b"))
        self.assertEqual(len(bits), 2304)
        self.assertEqual(len(set(bits)), 2304)
        self.assertTrue(all(len(word) == 77 for word in bits))
        for index in range(77):
            self.assertEqual({word[index] for word in bits}, {"0", "1"})

    def test_missing_signal_trial(self):
        self.rows["confirmation.csv"].pop()
        self.assert_rejected("Missing or duplicate signal grid records")

    def test_duplicate_signal_trial(self):
        rows = self.rows["confirmation.csv"]
        rows[-1] = {**rows[-2], "source_row": rows[-1]["source_row"]}
        self.assert_rejected("Signal source mapping mismatch")

    def test_changed_payload_seed(self):
        self.rows["confirmation.csv"][0]["payload_seed"] = "123"
        self.assert_rejected("Signal seed formula mismatch")

    def test_unpaired_payload(self):
        row = self.rows["confirmation.csv"][0]
        token = row["message77_hex"]
        row["message77_hex"] = ("1" if token[0] == "0" else "0") + token[1:]
        self.assert_rejected("Power constraints must have paired source cases")

    def test_acceptance_below_threshold(self):
        row = self.rows["confirmation.csv"][0]
        row.update(correct_accepted="1", accepted="1", accepted_wrong="0", evidence="0")
        self.assert_rejected("Accepted signal below gate")

    def test_nonfinite_evidence(self):
        self.rows["confirmation.csv"][0]["evidence"] = "NaN"
        self.assert_rejected("Nonfinite real in CSV")

    def test_signal_estimated_start_outside_search(self):
        self.rows["confirmation.csv"][0]["start_estimated_s"] = "0.9"
        self.assert_rejected("Signal estimated timing bounds")

    def test_signal_estimated_cfo_outside_search(self):
        self.rows["confirmation.csv"][0]["cfo_estimated_hz"] = "130"
        self.assert_rejected("Signal estimated frequency bounds")

    def test_signal_true_start_outside_design(self):
        self.rows["confirmation.csv"][0]["start_true_s"] = "0.9"
        self.assert_rejected("Signal true timing bounds")

    def test_changed_noise_threshold(self):
        self.rows["noise.csv"][0]["gate_recorded"] = "22.0"
        self.assert_rejected("Fixed project gate mismatch")

    def test_changed_noise_seed(self):
        self.rows["noise.csv"][0]["noise_seed"] = "123"
        self.assert_rejected("Noise seed mismatch")

    def test_noise_acceptance_without_decoder_success(self):
        row = self.rows["noise.csv"][0]
        row.update(raw_fec_accepted="0", recorded_accepted="1", false_messages="1")
        self.assert_rejected("Noise acceptance mismatch")


class PhysicalRecordTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with (ROOT / "study/physical/confirmation_physical.csv").open(newline="") as stream:
            reader = csv.DictReader(stream)
            cls.fields = reader.fieldnames
            cls.original = list(reader)

    def setUp(self):
        self.rows = copy.deepcopy(self.original)

    def analyze(self):
        with tempfile.TemporaryDirectory(prefix="qf256-physical-test-") as directory:
            physical = Path(directory) / "physical"
            physical.mkdir()
            with (physical / "confirmation_physical.csv").open("w", newline="") as stream:
                writer = csv.DictWriter(stream, fieldnames=self.fields)
                writer.writeheader()
                writer.writerows(self.rows)
            return subprocess.run(
                [str(ROOT / "study/build/summarize_physical"), directory],
                capture_output=True, text=True, check=False,
            )

    def assert_rejected(self, message):
        result = self.analyze()
        self.assertNotEqual(result.returncode, 0, "damaged physical records were accepted")
        self.assertIn(message, result.stdout + result.stderr)

    def test_published_records_are_valid(self):
        result = self.analyze()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Validated 4608 rows", result.stdout)

    def test_missing_physical_trial(self):
        self.rows.pop()
        self.assert_rejected("Incomplete physical table")

    def test_duplicate_physical_trial(self):
        self.rows[-1] = self.rows[-2].copy()
        self.assert_rejected("Duplicate physical key")

    def test_changed_seed(self):
        self.rows[0]["payload_seed"] = "123"
        self.assert_rejected("Unexpected payload seed")

    def test_nonfinite_measurement(self):
        self.rows[0]["bw99_hz"] = "NaN"
        self.assert_rejected("Nonfinite physical value")

    def test_nonpositive_energy(self):
        self.rows[0]["energy"] = "0"
        self.assert_rejected("Nonpositive power or energy")

    def test_unpaired_bandwidth(self):
        self.rows[0]["bw99_hz"] = "2001"
        self.assert_rejected("Power constraint changed PAPR or bandwidth")

    def test_unpaired_payload(self):
        token = self.rows[0]["source77_hex"]
        self.rows[0]["source77_hex"] = ("1" if token[0] == "0" else "0") + token[1:]
        self.assert_rejected("Power constraints have different source cases")

    def test_incorrect_peak_energy_scaling(self):
        row = next(row for row in self.rows if row["constraint"] == "peak")
        row["energy"] = str(float(row["energy"]) * 1.01)
        self.assert_rejected("Peak energy scaling mismatch")


if __name__ == "__main__":
    unittest.main()
