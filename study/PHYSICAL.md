# Physical waveform records

The CSV files in `physical/` contain recorded transmit-waveform measurements
and their statistical summaries. The source measurements retain their recorded
decimal values; source identities are in `physical_sources.tsv`.

## Waveform definition

The waveform uses continuous-phase 256-FSK with 7.8125 Hz tone spacing,
tone centers −996.09375 to +996.09375 Hz, and symbol duration 0.128 s. Its
76 symbols occupy 9.728 s before filtering. A unit-DC-gain linear Kaiser FIR,
beta 8.6 and cutoff 2000 Hz, has support ±2.6666667 ms. Its tap counts are
65, 257 and 1025 at 12, 48 and 192 kHz. Full convolution retains the complete
tails, giving 9.733333333333333 s at all three rates. The 12 kHz frame is
normalized after filtering to unit average power.

## Included tables

| File | Rows | Content |
|---|---:|---|
| `filter_audit.csv` | 24 | Two fixed cutoffs, 1300 and 2000 Hz, on the same 12 arbitrary 77-bit messages |
| `selected_waveform.csv` | 12 | Selected 2000 Hz filter, with complete-frame energy and rate-specific PAPR |
| `confirmation_physical.csv` | 3072 | Physical values and source/channel/noise seeds for every signal-confirmation trial |
| `confirmation_summary.csv` | 2 | Previously recorded aggregate physical values, one row per power constraint |
| `summary.csv` | 2 | Fortran summaries recomputed from all retained physical records |
| `bw99_cdf.csv`, `papr_cdf.csv` | 1536 each | Sorted physical values and empirical cumulative proportions, with duplicate power cases removed |

The 12 physical-audit messages use seed `493021 + 104729 × message`, then
77 draws `int(2 × U)`. They are distinct from the confirmation's restricted
71-random-bit source ensemble. Filter selection considered only these physical
measurements: use the 2000 Hz cutoff if it lowers the maximum reconstructed
peak while maximum BW99 stays at or below 2500 Hz.

| Cutoff | Maximum validated peak/12 kHz mean | Maximum BW99 | Maximum 48/192 kHz peak difference |
|---|---:|---:|---:|
| 1300 Hz | 1.516391 dB | 1994.235011 Hz | 0.010683 dB |
| 2000 Hz | 0.710921 dB | 1994.606992 Hz | 0.004176 dB |

These measurements selected the 2000 Hz filter before signal-error trials.

For `filter_audit.csv`, the columns named `papr48_db` and `papr192_db` are
10 log10(high-rate peak power / 12 kHz frame mean power). These are the
normalization used for the validated peak constraint. In
`selected_waveform.csv`, the same column names divide by each high-rate
waveform's own mean, producing its rate-specific PAPR. The mean-power
difference is explicitly retained in `energy48_relative_db` and
`energy192_relative_db`; identical frame durations make this also the
complete-frame energy ratio. The selected audit's maximum absolute 192/12 kHz
energy difference is approximately 0.000101 dB.

`peak_reference` is the larger of the 48 and 192 kHz peak powers under the
12 kHz mean normalization. `peak_convergence_db` is
abs(10 log10(peak192/peak48)); the registered tolerance is 0.05 dB. Waveforms
and kernels are regenerated directly at each sample rate rather than
interpolating the 12 kHz samples. The table's 12 kHz PAPR alone is not the
reference used for peak scaling.

Across the 1,536 confirmation transmissions per power constraint, the
recorded mean validated PAPR is 0.710905 dB and maximum is 0.710951 dB. Mean
BW99 is 1958.731469 Hz and maximum is 1998.723922 Hz. Average and peak rows
reuse the same source messages, so their bandwidth and PAPR values are the
same; scaling changes energy, mean power and average SNR. These are empirical
values for the supplied messages, not extrema over every 77-bit payload.

BW99 is the distance between the 0.5% and 99.5% two-sided spectral-energy
quantiles of the complete filtered IQ frame. The calculation applies no
extra window, pads to the next power of two at least four times the sample
count, and interpolates within bins. At 12 kHz this uses 524,288 FFT points.

The confirmation physical table records `start_true_s` before rounding to
sample indices; channel insertion uses `nint(start_true_s × 12000)`. The
`noise_seed` column is the expanded seed before adding 29. SNR, average/peak
power and Eb/N0 conventions are specified in `MODEL.md`.

Recompute the descriptive summaries and CDFs from the included measurements:

```sh
make -f study/Makefile.reproduce physical-summary
```

`summarize_physical.f90` validates all channel/SNR/trial/constraint keys, the
three seed formulas, finite values and average/peak scaling. It verifies that
paired power cases share source, bandwidth, PAPR, start and CFO, then uses
the 1,536 average-power rows once for the waveform distributions. Each CDF
contains sorted values x_i and proportions i/1536; ties are retained. Separate
summary rows give power and energy under each constraint. This target performs
descriptive calculations on existing records and generates no transmissions.
