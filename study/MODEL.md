# Channel and reproduction configuration

The completed confirmation contains 128 trials at each reference SNR of
−24, −22, −20, −18, −16 and −14 dB, for each of two channels and two power
constraints. Each constraint therefore has 1,536 trials. The signal receiver
uses a 15 s, 180,000-sample complex capture at 12,000 samples/s.

## HF channel

| Channel ID | Name | Path delays | Ensemble path powers | Doppler width B_D |
|---|---|---|---|---|
| 3 | moderate | 0, 1 ms | 1/2, 1/2 | 1 Hz |
| 4 | hard | 0, 2 ms | 1/2, 1/2 | 4 Hz |

The signal before additive noise is

```text
r(t) = exp(j 2 pi f_offset t) sum_p sqrt(P_p) g_p(t) x(t - delay_p)
g_p(t) = sum_(k=1)^64 a_pk exp(j 2 pi f_pk t)
f_pk ~ N(0, (B_D/2)^2),  a_pk ~ CN(0, 1/64).
```

Frequencies, coefficients and the two paths are independent. Each path has
unit ensemble power before multiplication by sqrt(P_p). The ensemble
correlation is exp(−pi² B_D² Δt²/2). The finite 64-line spectrum is a Monte
Carlo approximation to a continuous Gaussian Doppler spectrum; it is not an
exact continuous-spectrum realization. Neither fading gains nor faded frames
are normalized by their realized power. These are the study's named channel
settings, rather than an assertion of compliance with a standardized profile.

The simulator advances each complex oscillator by recurrence and recomputes
its phase every 4,096 samples. At the study sample rate, the delayed paths are
exact shifts of 12 or 24 samples. The general simulator also supplies a
16-tap Kaiser-windowed sinc fractional delay, beta 6, with unit DC gain and
no energy renormalization; this interpolation branch is not used by these
two profiles at 12 kHz.

Time zero for fading and carrier phase is the first frame sample. The harness
uses zero frequency drift. It generates the faded signal without additive
noise, retaining a suffix of maximum delay plus eight samples. It places that
signal at round(12,000 × start_s) within the capture and adds independent
complex Gaussian noise to every capture sample.

## Power, SNR and bit energy

The complete filtered transmission has 116,800 samples and duration
T = 116800/12000 = 9.733333333333333 s. `average` uses its post-filter average
power of one. `peak` divides that same IQ frame by sqrt(P_ref), where P_ref is
the maximum regenerated waveform power at 48 and 192 kHz, both referenced
to the unnormalized 12 kHz frame average. The two peak estimates must agree
within 0.05 dB. Filter tails count in power, energy and duration.

The horizontal SNR coordinate in the records is the **unit-reference SNR**:

```text
N0 = 1 / (2500 × 10^(snr_db/10))
E|w[n]|² = fs × N0
Var(Re w[n]) = Var(Im w[n]) = fs × N0 / 2
SNR_average_dB = snr_db + 10 log10(P_average)
Eb/N0_dB(K) = snr_db + 10 log10(2500 × E_frame / K).
```

Noise uses the same N0 in both constraints. Thus the peak constraint has
average power about 0.849 and average SNR about 0.711 dB below its reference
label. Noise is not scaled to received fading power or occupied bandwidth.
The physical records give both reference and average SNR, and bit-energy
figures for K=77 input bits and K=71 sampled random bits.

## Source, seed sequence and acquisition

The measured source ensemble uses 71 random bits followed by fixed bits
`101000`. It is a subset of the modem's 77-bit input space. Sampling consumes
18 uniform variates: one three-bit digit and 17 four-bit digits, packed most
significant bit first. The retained 18-digit hexadecimal field describes the
71-bit portion; it may omit leading zeroes in the historical records.

For one-based SNR point p and trial t:

```text
base = 20261201
condition = (channel_id - 1) × 6 + p
payload_seed = base + condition × 100003 + t × 101
channel_seed = base + condition × 200003 + t × 307
noise_seed = base + condition × 300007 + t × 911
```

Immediately after those 18 payload draws, two further uniform draws set
`start_s = 0.5 + 0.2 × (U − 0.5)` and `CFO = 4 × (U − 0.5)` Hz. Thus starts
lie in [0.4, 0.6] s and CFO in [−2, 2] Hz. The channel RNG is reset to
`channel_seed`; the sample-noise RNG is separately reset to `noise_seed + 29`.
Average and peak trials share these seeds and therefore are paired, not
independent repetitions of each other.

`seed_rng` initializes the compiler's `random_seed` vector with element i
equal to modulo(seed + 104729 × i, huge(default_integer) − 1). `rng_normal`
uses sqrt(−2 log U1) cos(2 pi U2), drawing two uniforms for every normal.
Exact stream reproduction is compiler/runtime dependent. The recorded runs
and the included deterministic checks used GNU Fortran 14.2.0 on little-endian
Linux, with optimization `-O3` and no fast-math option.

The blind receiver searches first-frame-sample offsets [0.3, 0.7] s and CFO
[−10, 10] Hz. Coarse increments are 96 samples and 0.5 Hz; a single fine search
uses four-sample and 0.025 Hz increments within the public bounds. Acquisition
uses only the 16 public pilot tones. The receiver receives IQ and public modem
configuration, without the transmitted bits, seeds, SNR, delay/gain realization
or actual synchronization values. Truth is used only after reception to score
the decoded payload. The waveform has 16 pilots and 60 data symbols, each
lasting 1,536 samples.

Noise density is estimated from received samples using 512-point Hann spectra
and the public guard bands −5000 to −2500 Hz and 2500 to 5000 Hz. Operational
acceptance requires the decoder's CRC/FEC checks and
`evidence >= 22.644583913858970`, where evidence is pilot energy divided by
estimated N0, minus 16. The evidence is neither an SNR estimate nor a
probability. Drift and Doppler spread are not estimated by this receiver.

## Gate calibration and independent noise captures

The registration recorded at 2026-10-10 22:55:43 UTC specified 2,048 noise-only
calibration captures before confirmation outcome inspection, followed by an
independent 4,096-capture check. The gate was recorded at 22:59:02 UTC as
22.644583913858970. Original record identities are in `physical_sources.tsv`;
the QF256 calibration and check data are included in this study.

Calibration base is 20263401 and check base is 20263501. For global index g:

```text
point = mod(g − 1, 6) + 1
trial = floor((g − 1)/6) + 1
actual_noise_seed = base + point × 300007 + trial × 911 + 29
reference_SNR = −26 + 2 × point dB.
```

Every capture contains only 180,000 complex Gaussian noise samples at the
variance above; the SNR field is solely a noise-amplitude label. The receiver
uses the same blind search and receives no true variance. The gate is the
type-7 99th percentile of all calibration evidence values: h=2027.53, hence
0.47 × sorted_value(2027) + 0.53 × sorted_value(2028). The independent check
uses that fixed gate. Signal confirmation uses the same gate.

## Reproduction commands

From the project root, build with GNU Fortran and Make:

```sh
make -f study/Makefile.reproduce
study/build/reproduce signal 3 average 1 1 study/build/signal.csv
study/build/reproduce noise-cal 1 study/build/calibration.csv
study/build/reproduce noise-check 1 study/build/check.csv
```

Each invocation produces one trial and refuses an existing output file. A
signal invocation accepts channel 3 or 4, `average` or `peak`, point 1–6 and
trial 1–128. Noise indices are 1–2048 for calibration and 1–4096 for check.
No simulation runs during compilation. Repeating all registered index
combinations regenerates the corresponding experiment; the bundled measured
tables can be analyzed without regeneration. Only project-local source and
standard Fortran are required.

`channel.f90` implements the fading, delay, frequency-offset and noise models
defined above. `reproduce.f90` combines that channel with the QF256 encoder and
receiver, using the recorded seed initialization and random-draw order for
one indexed trial per invocation. `REPRODUCTION_CHECK.txt` gives commands and
expected values for two deterministic record matches. Licensing follows the
project's GPL-3.0-or-later license and QRA attribution.
