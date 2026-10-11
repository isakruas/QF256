# QF256 completed-record study

> **Historical v1.0 evidence.** The bundled measurements, expected replay
> values, and SNR-validation output belong to QF256 v1.0.0. Exact trial replay
> requires tag `v1.0.0`, commit
> `93405683da7fc6c1e5f886e4ccca30850c7d3875`. On the current HEAD, the record
> analysis below still analyzes the stored CSV files, but compiling and running
> the replay or SNR harness uses the current receiver and constitutes a new
> experiment; it is not expected to match the frozen v1.0 outputs.

This directory contains the QF256 confirmation and noise records, physical
waveform measurements, Fortran analysis, and a one-trial reproduction harness.
All commands below run from the project root.

## Analyze the included records

```sh
make -C study analysis
make -f study/Makefile.reproduce physical-summary
```

These commands calculate statistics from the bundled CSV files. They do not
generate channel trials. GNU Fortran and Make are required; targets use
`-Wall -Wextra -Werror`.

Render the two-panel acceptance and physical-distribution figures with GNUplot:

```sh
gnuplot study/plots.gp
```

GNUplot 6.0.2 with the `pdfcairo` and `pngcairo` terminals was used. The script
requires a serif font; the supplied style uses Liberation Serif. It writes
`acceptance.pdf`, `acceptance.png`, `physical.pdf` and `physical.png` under
`study/figures/`. The asymmetric confidence limits and empirical CDF values
come directly from the Fortran-generated tables. On Debian, the plotting
dependency is available in the `gnuplot-nox` package.

| File | Purpose |
|---|---|
| [confirmation.csv](confirmation.csv) | 3,072 signal records: 1,536 source/channel/noise cases paired across average and peak constraints |
| [noise.csv](noise.csv) | 2,048 calibration captures and 4,096 independent check captures |
| [RESULTS.txt](RESULTS.txt) | Signal and false-acceptance results |
| [ANALYSIS_METHODS.txt](ANALYSIS_METHODS.txt) | Statistical definitions and intervals |
| [cells.csv](cells.csv), [aggregate.csv](aggregate.csv), [thresholds.csv](thresholds.csv) | Numerical signal summaries |
| [noise_summary.csv](noise_summary.csv) | Noise-only acceptance and interval summary |
| [MODEL.md](MODEL.md) | Channel, power/SNR, source sampling, seeds, acquisition and gate configuration |
| [PHYSICAL.md](PHYSICAL.md) | Waveform definition, physical measurement conventions and table descriptions |
| [validate_snr.f90](validate_snr.f90), [SNR_VALIDATION.csv](SNR_VALIDATION.csv) | Fixed-seed AWGN and HF-channel validation of the receiver SNR estimator |
| [validate_wide_acquisition.py](validate_wide_acquisition.py) | Manual fixed-seed LP1850 calibration/check and boundary-signal harness for the current wide receiver |
| [physical/summary.csv](physical/summary.csv) | Bandwidth, PAPR, power and energy statistics |
| [physical/bw99_cdf.csv](physical/bw99_cdf.csv), [physical/papr_cdf.csv](physical/papr_cdf.csv) | Empirical distributions for 1,536 distinct source cases |

The confirmation source ensemble contains 71 random bits and six fixed bits
within the 77-bit modem input. Reference SNR uses unit transmitted power in a
2500 Hz reference bandwidth. Under the peak constraint, average transmitted
power is lower; the records retain its actual average SNR and energy.

## Validate the receiver SNR estimate

The retained [SNR_VALIDATION.csv](SNR_VALIDATION.csv) is a v1.0 result. To
reproduce it exactly, first check out the tag and commit identified above, then
run:

```sh
make snr-validation
```

This runs 128 fixed-seed cases at each AWGN, moderate, and hard channel point
listed in [SNR_VALIDATION.csv](SNR_VALIDATION.csv). AWGN validates the estimator
against a known payload without conditioning on decoder success. The fading rows use
the SNR returned by the receiver and include only CRC-valid correct decodes.
The measured negative bias under dispersive fading is retained without an
empirical correction.

## Reproduce an indexed trial

The following commands reproduce the frozen values only from the v1.0 source
identified above. Running them from the current HEAD measures the current
receiver instead.

```sh
make -f study/Makefile.reproduce
study/build/reproduce signal 3 average 1 1 study/build/signal.csv
study/build/reproduce noise-check 1 study/build/check.csv
```

Each command creates one new output file. [MODEL.md](MODEL.md) specifies the
complete index ranges, calibration command and compiler-dependent RNG details.
[REPRODUCTION_CHECK.txt](REPRODUCTION_CHECK.txt) records exact deterministic
matches for one existing signal trial and one noise-check trial.

## Validate the current wide receiver

The current +/-750 Hz acquisition and the USB 300..4000 Hz frontend model have
a separate, manual Monte Carlo harness. It requires Python 3 and NumPy and is
not run by `test` or `strict`:

```sh
make wide-validation
```

The target performs 6,400 blind receiver calls and writes generated CSV files
under `study/build/wide-acquisition`. Fixed seeds, the LP1850 mapping, summary
statistics, and the gate decision are recorded in
[WIDE-ACQUISITION-VALIDATION.txt](../docs/WIDE-ACQUISITION-VALIDATION.txt).

## Data identities

[DATA_SOURCES.csv](DATA_SOURCES.csv) and [DATA.sha256](DATA.sha256) identify the
signal/noise source records and extracted datasets.
[physical_sources.tsv](physical_sources.tsv) identifies the physical records,
channel source and configuration records by SHA256 and neutral source IDs.
[PHYSICAL.sha256](PHYSICAL.sha256) covers the physical extraction, model and
reproduction and plotting source files. Complete copies of physical CSV files
preserve their source hashes; extracted columns preserve the recorded
numerical text.

The current package retains the study data and analysis source. The exact
receiver source used to reproduce the stored trials is preserved by the v1.0.0
tag and commit identified at the top of this file.
Code licensing follows [GPL-3.0-or-later](../LICENSE), with the retained
[QRA attribution](../licenses/QRA-NOTICE.txt).
