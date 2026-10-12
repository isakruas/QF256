# Current campaign model

The design is fixed before the first receiver call in `CAMPAIGN.json`.
The acceptance gate is the existing project constant
30.220758775848424. It is not fitted to this campaign, and the diagnostic
99th percentile is not claimed to derive that constant.

## Signal grid and channel

There are 128 trials at each reference SNR −24, −22, −20, −18, −16 and −14 dB,
for three channels and two power constraints: 36 cells and 4,608 records,
representing 2,304 cases paired across average and peak power.
The receiver observes 180,000
complex samples at 12,000 samples/s.

| Channel ID | Name | Delays | Ensemble path powers | Doppler width B_D |
|---|---|---|---|---|
| 2 | quiet | 0, 0.5 ms | 1/2, 1/2 | 0.1 Hz |
| 3 | moderate | 0, 1 ms | 1/2, 1/2 | 0.5 Hz |
| 4 | disturbed | 0, 2 ms | 1/2, 1/2 | 1 Hz |

These are the mid-latitude quiet, moderate and disturbed profiles specified
by [ITU-R F.1487-0, Annex 3, sections 3.1-3.3](https://www.itu.int/rec/R-REC-F.1487-0-200005-I/en).
The Doppler spread B_D is twice the Gaussian spectrum's standard deviation,
not its full width at half maximum. Both paths have zero mean Doppler,
as specified in Annex 3. The common CFO sampled over [-2,2) Hz is an
additional tuning offset for this receiver experiment, not Doppler spread
or a parameter of the ITU profile.

The noise-free signal is
`r(t)=exp(j2π CFO t) Σ_p sqrt(P_p) g_p(t) x(t−delay_p)`.
Each independent path has
`g_p(t)=Σ_(k=1)^64 a_pk exp(j2π f_pk t)`,
`a_pk~CN(0,1/64)`, `f_pk~N(0,(B_D/2)²)`.
Its ensemble mean power is one and correlation is
`exp(−π² B_D² Δt²/2)`. The finite 64-line spectrum is a Monte Carlo
approximation, not an exact continuous-spectrum realization. Neither path
gains nor faded frames are normalized by their realized power. Selecting
these profile parameters does not establish compliance with the complete
ITU test procedure: this study measures frame acceptance over 128 frames
per cell, not the recommendation's BER endpoint and prescribed test duration.

Oscillators advance by recurrence and reset phases every 4,096 samples.
Delays are exact 6/12/24-sample shifts at 12 kHz; the simulator's fractional
delay branch is not used. Time zero for fading/CFO is the first frame sample;
frequency drift is zero. The retained channel suffix includes maximum delay
plus eight samples.

## Receiver frontend

The principal, noise and SNR experiments apply an ideal rectangular
300..2700 Hz USB frontend around centre 1500 Hz: complex baseband ±1200 Hz.
`frontend.f90` generates additive Gaussian noise throughout a context whose
power-of-two length is at least twice the receiver capture length, inserts the
faded signal at its true start, filters by FFT, then retains the central
capture. For a 180,000-sample capture the context is 524,288 samples and each
padding side is 172,144 samples. Thus the periodic FFT seam is far from the
observed frame. Filtering is not followed by power renormalization.

There is no transition band, ripple, audio conversion, hardware quantization,
AGC, interference, impulsive noise or antenna model. This is a mathematical
receiver-input model. It must not be equated to physical HF measurements.

## Power, SNR and energy

The complete filtered TX frame contains 116,800 samples, duration
9.733333333333333 s. Each of 76 symbols lasts 0.128 s; full shaping tails
contribute the remaining duration. The average constraint normalizes this
complete frame to unit average power. The peak constraint divides the same
IQ frame by sqrt(P_ref), where P_ref is the greater regenerated peak power
at 48 and 192 kHz, referenced to the original 12 kHz frame mean. The two
peak estimates must agree within 0.05 dB.

```text
N0 = 1 / (2500 × 10^(reference_SNR_dB/10))
E|w[n]|² before frontend = fs × N0
Var(Re w) = Var(Im w) = fs × N0 / 2
SNR_average_dB = reference_SNR_dB + 10 log10(P_average)
Eb/N0_dB = reference_SNR_dB + 10 log10(2500 × E_frame / 77)
```

Noise N0 is identical in paired constraints. Peak-limited mean power and
the corresponding offset from the reference SNR axis are measured per frame.
Noise is never scaled to instantaneous fading or occupied bandwidth. After
the frontend, stationary noise power is approximately 2400×N0; the CSV
`noise_variance_expected` remains the pre-frontend fs×N0 normalization.
The decoder's reported noise variance also means fs×estimated N0, not the
observed post-filter sample variance.

## Payload and random streams

Every payload bit is uniform over the complete 77-bit input domain.
Twenty uniform draws produce a one-bit first hexadecimal digit and nineteen
four-bit digits, MSB first, retaining a 20-character `source77_hex` token.
No bits are fixed. For channel c, one-based SNR point p and trial t:

```text
condition = (c − 1) × 6 + p
payload_seed = 20271011 + condition × 100003 + t × 101
channel_seed = 120271011 + condition × 200003 + t × 307
noise_seed = 220271011 + condition × 300007 + t × 911
```

After the twenty source draws, two further uniforms set
`start_s=.5+.2×(U−.5)` and `CFO=4×(U−.5)` Hz.
Starts therefore lie in [.4,.6] s and CFO in [−2,2] Hz.
Insertion uses nint(start_s×12000). The channel stream is reset to
channel_seed and the noise stream separately to noise_seed+29.
Average and peak runs deliberately share these streams.

`seed_rng` fills compiler random_seed element i with
modulo(seed+104729×i, huge(default_integer)−1).
Normals use sqrt(−2 log U1) cos(2πU2), consuming two uniforms each.
Exact streams depend on the compiler/runtime; the recorded compiler is GNU
Fortran 14.2.0. The five role sets (payload, fading, signal noise, diagnostic
noise and check noise) have no numeric seed overlaps. This is not a proof
of independence of a finite pseudorandom generator.

## Acquisition and acceptance

The single public blind receiver searches first-frame offset [.3,.7] s and
CFO [−125,125] Hz. Coarse steps are 96 samples/3.90625 Hz, middle steps
16 samples/0.244140625 Hz, and final steps four samples/0.0244140625 Hz,
bounded at every refinement. Synchronization uses 16 public pilot tones.
The receiver gets only IQ and public modem configuration, not payload truth,
random seeds, SNR, channel realization or true start/CFO.

Noise density normally uses Hann-spectrum guard bands ±2500..5000 Hz.
When guard N0 is below half the robust in-band estimate, the receiver uses
the latter. That estimate uses the middle two of 256 tone projections in
each data symbol. The ideal frontend suppresses the external guards.
Public `qf256_decode` decides acceptance: CRC/FEC success and evidence at
least the fixed gate. Evidence is pilot energy/N0 minus 16, not SNR or a
probability. Truth is used only afterward to identify accepted-correct or
accepted-wrong payloads. Drift/Doppler are not estimated.

## Noise diagnostic and independent check

The 2,048 diagnostic and 4,096 independent check captures use only noise
through the same ideal frontend. Both use the fixed public gate; neither
changes it. The diagnostic quantile is descriptive. For one-based index g:

```text
p = mod(g−1,6)+1; t = floor((g−1)/6)+1
seed = base + p×300007 + t×911 + 29
base = 40271011 (diagnostic), 60271011 (independent check)
noise_amplitude_label_dB = −26 + 2×p
```

These labels set N0, not a signal-to-noise ratio in a signal-free capture.
Seed sets are disjoint. Independent-check false acceptance has a one-sided
95% exact bound; diagnostic outcomes have descriptive summaries only.

## SNR-estimator validation

A single known 77-bit payload is formed by Park–Miller state 783271 and
77 thresholded draws. AWGN rows use 128 noise realizations at each
−24..−14 dB point, known timing/CFO and known payload, independent of decoder
success. They apply the same frontend and in-band N0 fallback as the receiver.
Noise seeds are 70701011+1000×level+trial.

Fading rows cover quiet/moderate/disturbed at −18, −16 and −14 dB,
128 realizations each, CFO 3.2 Hz and start .5 s. Channel/noise seeds are respectively
80701011+10000×level+trial and 90701011+10000×level+trial, levels 1..9.
Levels 1..3 are quiet, 4..6 moderate and 7..9 disturbed, in increasing SNR
order within each profile. These seed sets and the AWGN seed set have no
numeric overlaps with one another or with the five principal role sets.
Together the six AWGN rows and nine fading rows contain 1,920 attempted
estimates; the fading valid-case denominator can be smaller than 128.
Only public accepted-correct decodes contribute reported bias/RMSE; their
valid-case counts and selection bias are explicit. Reference remains unit
TX power, not realized receive power. No empirical bias correction is fitted.

## Separate acquisition-boundary experiment

`validate_acquisition.py` calls the public float32 C API in independent
processes. The frontend has the same physical bounds, with decoder centres
1475/1525 Hz (baseband shifts −25/+25 Hz). At each of −20, −18 and −4 dB
there are 128 independent random 77-bit payload/noise cases. The first eight
cover start3600/8400 × CFO−125/+125 × centre offsets−25/+25; the remainder
sample starts/CFO uniformly and alternate centre offsets. Initial phase is
uniform. Signal noise is generated over 262,144 samples; the central
125,200-sample minimum capture is retained after ideal FFT filtering.

Signal seeds are 9107101100+1000000×level_index+case_index.
Noise-check seeds are 9106101100+case_index for 4,096 captures of 180,000
samples. Noise levels cycle through −24..−14 and centre offsets alternate.
NumPy default_rng and its version are recorded in JSON sidecars.
The recorded latency_ms is CPU-time dependent; reproducible numerical
comparisons exclude that field. CSV hashes identify the particular execution.
This AWGN boundary experiment complements, not replaces, the fading grid.
