# Reproducible QF256 study

This directory contains the receiver's complete fixed-design numerical
study. There is one operational synchronization mode, `blind`, with residual
CFO search ±125 Hz. The waveform and project acceptance gate
30.220758775848424 are fixed; no gate or waveform parameter is selected from
this campaign's outcomes.

All commands run from the repository root. Dependencies are GNU Fortran, Make,
Python 3, NumPy, and GNUplot with pdfcairo/pngcairo terminals. The measured run
uses GNU Fortran 14.2.0, `-O3`, no fast-math, and eight independent workers.

## Complete experiment

```sh
make study STUDY_WORKERS=8
```

This builds the local harnesses, executes 4,608 fading-channel signal trials,
2,048 diagnostic and 4,096 independent noise captures, and 1,920 SNR-estimator
cases. It then executes the separate acquisition-boundary experiment:
384 AWGN signal cases and 4,096 independent noise captures. These simulations
do not operate RF hardware.

Runtime depends on the host and worker count. Each Fortran process
handles an indexed trial. A matching interrupted campaign can resume from
`study/build/campaign`; incompatible source/executable hashes are rejected.
For a fresh rerun, supply an unused `STUDY_RUN_DIR`; a complete rerun replaces
the canonical result CSVs. Changing code after starting a campaign invalidates
its final source identity check. Do not clean or rebuild running harnesses.

`CAMPAIGN.json` records the source and executable hashes, actual compiler
version, compiler flags, fixed design, seeds, times, and output hashes.
The Git revision is contextual only: per-file hashes identify the executed
source even when the checkout is uncommitted.

## Analyze and reproduce

```sh
make study-analysis
make snr-validation
study/build/reproduce signal 3 average 3 1 study/build/one-signal.csv
study/build/reproduce noise-check 1 study/build/one-noise.csv
make acquisition-validation
```

Indexed reproduction refuses to overwrite a file. Signal indices are channels
2/3/4 (quiet/moderate/disturbed), constraints average/peak, SNR points 1..6,
trials 1..128. Noise phases are
`noise-diagnostic` (1..2048) and `noise-check` (1..4096).
`make study-analysis` performs only deterministic statistics/plot generation;
it does not run channel trials. `make snr-validation` reruns all estimator
cases and compares their deterministic printed results to the included CSV.

Every indexed row is checked against its exact schema, trial parameters,
seeds and acceptance rules, including resumed rows. The complete tables are
then validated by `analyze.f90` and `summarize_physical.f90` in a staging
directory. Canonical files are replaced only after both validators and the
source/executable identity checks pass. The compiler commands and all
promoted table hashes are retained in `CAMPAIGN.json`.

## Included evidence

| File | Content |
|---|---|
| `confirmation.csv` | 4,608 signal outcomes, 2,304 paired source/channel/noise cases |
| `noise.csv` | Diagnostic and independent noise records, with fixed public gate |
| `RESULTS.txt`, `cells.csv`, `thresholds.csv` | Counts, Wilson intervals, crossings and conservative grid brackets |
| `SNR_VALIDATION.csv` | Known-payload AWGN and accepted-correct fading SNR bias/RMSE |
| `physical/confirmation_physical.csv` | Power, bandwidth, PAPR and energy for every signal case |
| `physical/summary.csv`, `physical/*_cdf.csv` | Physical summaries and empirical distributions |
| `acquisition/noise.csv`, `acquisition/signals.csv` | Independent AWGN acquisition-boundary experiment |
| `acquisition/*.json` | Boundary source/library hashes, seed arguments and NumPy version |
| `DATA_SOURCES.csv`, `DATA.sha256`, `PHYSICAL.sha256` | Record/shard identities and checksums |
| `MODEL.md`, `PHYSICAL.md`, `ANALYSIS_METHODS.txt` | Complete measurement and statistical definitions |

The channel settings are the quiet, moderate and disturbed mid-latitude
profiles specified by [ITU-R F.1487-0, Annex 3, sections 3.1-3.3](https://www.itu.int/rec/R-REC-F.1487-0-200005-I/en).
The study uses 128 frames per cell and a finite 64-line fading approximation;
it does not claim compliance with the recommendation's complete BER and
test-duration procedure. The precise implementation is in `MODEL.md`.

The signal source is uniform over all 77 input bits. Both power constraints
share payload/channel/noise draws; they are not independent repetitions.
SNR is referenced to transmitted unit power and 2500 Hz, not instantaneous
faded receive power or the 2400 Hz frontend width. The narrow ideal frontend
has no passband ripple, transition region, AGC, quantization, interference or
hardware impairments. Simulation success is not an on-air probability.

Licensing follows
[GPL-3.0-or-later](../LICENSE) and the retained [QRA notice](../licenses/QRA-NOTICE.txt).
