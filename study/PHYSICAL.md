# Transmitted-waveform measurements

The physical tables are generated during all 4,608 signal trials.
Their source hashes and seed design
are in `CAMPAIGN.json`; `physical/confirmation_physical.csv` retains every
case's payload, channel/noise seed labels and physical values.

QF256 is continuous-phase 256-FSK with 7.8125 Hz spacing, tone centres
−996.09375..996.09375 Hz, 0.128 s symbols and 76 symbols per frame.
The selected shaping filter is a unit-DC-gain Kaiser FIR with beta 8.6,
cutoff 2000 Hz and support ±2.6666667 ms. It has 65/257/1025 taps at
12/48/192 kHz. The complete 12 kHz waveform is normalized to unit mean
power after full convolution. Filter selection is fixed, not optimized
from this study's outcomes.

Duration including filter tails is 116800/12000=9.733333333333333 s.
Energy is sum(|IQ|²)/fs over that full frame. Mean and peak fields are powers,
not amplitudes. BW99 is the distance between the 0.5% and 99.5% two-sided
spectral-energy quantiles, with no extra window, next-power-of-two FFT length
at least four times frame length, and interpolation within bins. The 12 kHz
FFT therefore has 524,288 points.

For the peak reference, waveforms and kernels are regenerated directly at
48 and 192 kHz, rather than interpolating 12 kHz samples. Their peaks are
divided by the original 12 kHz waveform mean. The larger power is P_ref;
their difference must be below 0.05 dB. Validated PAPR is
10 log10(P_ref/P_average). The peak-constrained waveform divides the
unit-average frame by sqrt(P_ref); this changes mean power/energy but not
bandwidth or PAPR.

The two constraints use identical payloads. `summarize_physical.f90` validates
every grid key, seed formula, finite/positive measurement, paired source,
bandwidth, PAPR, start/CFO, and power/energy scaling. It uses each of the 2,304
unit-average source cases once to form empirical CDFs; these messages are not
an exhaustive search over 77-bit inputs. Results are in
`physical/summary.csv`, `physical/bw99_cdf.csv` and `physical/papr_cdf.csv`.
Plots autoscale from all current observations.

`make study-analysis` recomputes summaries from existing measurements.
`make study` regenerates both the transmissions and their measurements.
No calibrated RF watts or joules are inferred from dimensionless simulation
power; the SNR and Eb/N0 conventions are defined in `MODEL.md`.
