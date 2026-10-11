# QF256 integration API

The modem profile is fixed:
12,000 complex samples/s, 77 payload bits, 116,800 transmitted complex samples
(9.733333333333333 seconds, including filter tails), and acceptance threshold
`30.220758775848424`. Encoding normalizes the complete frame to mean complex
power one. The encode/decode API operates on complex IQ at the specified rate;
file conversion is handled separately.

## Fortran

Use module `qf256_api`; real and imaginary components use `real64`:

```fortran
use iso_fortran_env, only: real64
use qf256_api
integer :: bits(77), status
complex(real64), allocatable :: iq(:)
type(sc_result) :: result
logical :: accepted
character(160) :: message
! Initialize bits to 0 or 1 before this call.
call qf256_encode(bits, iq, status, message)
if (status == qf256_ok) then
  call qf256_decode(iq, 'known', result, accepted, status, message)
end if
```

`qf256_encode(bits(:), iq, status, message)` accepts exactly 77 default-kind
integers in `{0,1}` and allocates its `complex(real64)` output. On a validation
error `iq` is unallocated. `qf256_decode(iq(:), sync, result, accepted, status,
message)` accepts `known`, `blind`, or `blind-hf`. Both routines have an optional output
character argument `message`; a short caller buffer truncates it normally.
Constants exported by the module include `qf256_sample_rate`,
`qf256_frame_samples`, `qf256_payload_bits`, `qf256_blind_min_samples`,
`qf256_max_samples`, `qf256_gate`, `qf256_blind_cfo_limit_hz`,
`qf256_blind_hf_cfo_limit_hz`,
`qf256_snr_reference_hz`, synchronization values and status codes.

`sc_result` is re-exported from the core. Its payload and `crc_ok` describe the
raw decode. The separate `accepted` output additionally applies the fixed
evidence threshold. Deliver payload bits only when `status == qf256_ok` and
`accepted` is true. Failure to decode is a normal outcome with status zero;
status codes indicate invalid API input, not channel success. Validation errors
reset `result` to its default values and set `accepted` false.
For a CRC-valid decode, `result%snr_valid` indicates whether the finite,
positive-power SNR calculation succeeded and `result%snr_2500_db` contains the
estimate defined below.

## Capture and synchronization contract

| Mode | Minimum complex samples | Meaning |
|---|---:|---|
| `known` / `QF256_SYNC_KNOWN` | 116800 | Frame starts at offset zero; residual CFO is assumed zero. |
| `blind` / `QF256_SYNC_BLIND` | 125200 | Search frame starts from 0.3 through 0.7 seconds and complex-baseband CFO from −750 through +750 Hz. |
| `blind-hf` / `QF256_SYNC_BLIND_HF` | 125200 | Same timing search, with complex-baseband CFO from −125 through +125 Hz for a conventional USB channel. |

The maximum length is 180000 complex samples (15 seconds) in every mode.
The blind minimum accommodates the whole filtered frame at the latest searched
start. Provide one capture window per call. Surrounding samples within the
accepted length contribute to the guard-band noise estimate; the selected N0
may instead use the aligned in-band tone projections as described below.
Sample offsets are zero-based.

Every IQ component must be finite. Fortran `real64` components above `1e90` in
absolute value are rejected to avoid arithmetic overflow;
all finite float32 inputs are within this numerical safety bound. IQ scaling is
otherwise caller-controlled; the decoder uses that scale directly.

## C ABI

Include `qf256.h` and link the Fortran library/runtime using the project build.
The two exported symbols use `bind(C)`, with no compiler-specific name mangling:

```c
void qf256_tx_cf32(const int8_t payload77[77], float *iq_interleaved,
                   int32_t capacity_complex, int32_t *written, int32_t *status);
void qf256_rx_cf32(const float *iq_interleaved, int32_t ncomplex,
                   int32_t sync_mode, qf256_result *result, int32_t *status);
```

`QF256_SYNC_BLIND_HF == 2` is additive; the function signatures, API version 1,
and 152-byte result layout are unchanged. Existing callers using
`QF256_SYNC_BLIND == 1` retain the full ±750 Hz search.

IQ is float32 interleaved `[I0,Q0,I1,Q1,...]`. Counts are complex samples, passed
by value. Allocate at least `2*capacity_complex` floats for TX and `2*ncomplex`
floats for RX; the adapter cannot discover the size of a C allocation. TX writes
exactly `2*QF256_FRAME_SAMPLES` floats on success and reports complex sample count
through `written`. On errors, `written` is zero and TX does not change IQ memory.
RX initializes the result to zero before input validation. No output pointer may
alias any other argument's memory. All pointers are required; a null pointer
returns `QF256_INVALID_ARGUMENT` if status storage exists. With a null status
pointer the function returns immediately and does not access other arguments.

The result uses fixed-width integer flags rather than C/Fortran logicals. Its
layout is defined by the header and interoperable Fortran `qf256_result_c`:

| Field | C type | Meaning |
|---|---|---|
| `payload` | `int8_t[77]` | Raw decoded bits; usable only when `accepted == 1`. |
| `reserved` | `int8_t[3]` | Zero-filled alignment bytes; keep them in the struct. |
| `crc_ok`, `accepted` | `int32_t` each | Raw check and fixed gated acceptance. |
| `start_samples`, `iterations` | `int32_t` each | Zero-based capture offset and FEC iterations. |
| `start_seconds` | `double` | `start_samples / 12000`. |
| `cfo_hz` | `double` | Estimated residual frequency offset. |
| `noise_variance` | `double` | Selected complex sample noise-power estimate, `fs*N0`. |
| `evidence` | `double` | Pilot energy / estimated `N0` minus 16. |
| `latency_ms` | `double` | Core process CPU time, excluding adapter conversion/validation. |
| `snr_2500_db` | `double` | Active-frame signal-to-noise estimate referenced to 2500 Hz. |
| `snr_valid` | `int32_t` | One when `snr_2500_db` is valid, otherwise zero. |
| `reserved2` | `int32_t` | Zero-filled space reserved for future extension. |

Do not pack the struct. The tested C ABI gives 152 bytes, with the first double
at byte offset 96, `snr_2500_db` at byte 136, and `snr_valid` at byte 144. The
header is the integration contract; do not substitute a C complex-number array
or reinterpret interleaved floats as Fortran complex. The Fortran C wrapper
converts float32 input to the core's float64 arithmetic.

| Status | Value | Meaning |
|---|---:|---|
| `QF256_OK` | 0 | Call completed; inspect `accepted` separately. |
| `QF256_INVALID_BITS` | 1 | Wrong payload size or a bit outside `{0,1}`. |
| `QF256_INVALID_SYNC` | 2 | Unknown synchronization mode. |
| `QF256_INVALID_LENGTH` | 3 | Capture is outside the mode's sample limits. |
| `QF256_NONFINITE` | 4 | NaN or infinity in IQ. |
| `QF256_BUFFER_TOO_SMALL` | 5 | Insufficient TX capacity, including a negative capacity. |
| `QF256_INVALID_ARGUMENT` | 6 | Required C pointer is null. |
| `QF256_NUMERIC_RANGE` | 7 | Fortran float64 input exceeds the numerical safety bound. |

## SNR estimate

The SNR result is computed only after the decoder produces a CRC-valid payload.
Let \(\hat t_j\) be the decoded tone for data symbol \(j\),
\(E_{\hat t_j,j}\) its received matched-projection energy, and \(\widehat N_0\)
the selected N0 estimate. The receiver regenerates the decoded payload as a
clean, complete frame with mean complex power one and measures its corresponding
correct-bin energies \(E^{(1)}_{\hat t_j,j}\). It then evaluates

\[
\widehat P =
\frac{\sum_{j=1}^{60}(E_{\hat t_j,j}-\widehat N_0)}
     {\sum_{j=1}^{60}E^{(1)}_{\hat t_j,j}}, \qquad
\widehat{\mathrm{SNR}}_{2500} =
10\log_{10}\!\left(\frac{\widehat P}{2500\widehat N_0}\right).
\]

Under aligned static AWGN, each correct-bin projection has expected energy
\(P E^{(1)}_{\hat t_j,j}+N_0\); subtracting one noise contribution per data
symbol therefore gives an unbiased signal-power estimate before the logarithm.
`snr_valid` is one only when the CRC is valid and all terms produce a finite,
positive power estimate. The estimate is separate from `evidence`, which is the
pilot acquisition statistic and is not an SNR.

The following fixed-seed results are retained from the v1.0 guard-only
receiver and are historical rather than a validation of the current expanded
acquisition. `study/validate_snr.f90` used 128 cases per point.
Across AWGN levels −24 through −14 dB, bias ranged from −0.080 to −0.023 dB and
RMSE from 0.892 to 0.234 dB. On CRC-valid decodes in the official moderate HF
profile at −18/−16/−14 dB, the valid counts were 115/127/128, bias
−0.166/−0.250/−0.226 dB, and RMSE 0.925/1.029/1.002 dB. In the hard profile the
corresponding values were 104/128/128, −0.764/−0.963/−1.009 dB, and
1.049/1.318/1.270 dB. Multipath and Doppler move signal energy out of the
nominal decoded-tone projections, producing the observed negative bias; no
empirical correction is applied. The receiver does not estimate SNDR or Doppler
spread. In the Fortran result, `selected_bd == -1` denotes unavailable Doppler
spread, and `used_osd` is false.

Calls are not thread-safe: the FFT implementation has a shared saved
cache. Serialize all calls within a process, including other direct users of
the core; use separate processes for concurrency. The adapters validate public
inputs but cannot recover from allocation failures or internal core invariant
failures.

## File interfaces and noise fields

The CLI accepts headerless CF32LE IQ or RIFF PCM16LE mono WAV at 12,000 samples/s.
CF32LE stores interleaved IEEE 754 float32 `I0,Q0,I1,Q1,...`; each pair is one
complex sample. Writers require a new output path. The CLI enforces the same
capture length limits as the API. Readers reject malformed headers, partial samples,
unsupported WAV formats, and nonfinite IQ.

WAV export computes `sqrt(2)*Re(IQ*exp(j*2*pi*center_hz*t))`, applies one constant
gain for a peak near −3 dBFS, and rounds `32767*audio` to PCM16. WAV input divides
PCM values by 32768, constructs the analytic signal with a zero-padded FFT,
divides by `sqrt(2)`, and mixes by `-center_hz`. Both conversions retain the
sample count. The default center is 1,500 Hz; supported centers are 1,100–4,500 Hz.

The receiver first estimates N0 from IQ guard bands −5,000 to −2,500 Hz and
2,500 to 5,000 Hz. It also forms an in-band estimate from the 256 data-tone
projections: for each of 60 data symbols it averages order statistics 128 and
129, divides by the exact unit-exponential expectation
`0.6951041202281072`, then averages the symbols. Guards remain preferred when
present. If `guard_n0 < 0.5 * tone_n0`, the receiver selects the robust in-band
estimate, which prevents a filtered frontend from supplying a near-zero N0 to
the soft decoder.

WAV analytic conversion keeps the positive-frequency audio spectrum before
translation, so it does not supply the same guards as full-band complex IQ.
The fallback makes such filtered input decodable, but its selected noise, SNR,
and evidence can still differ from the corresponding full-band IQ capture.
The ±750 Hz acquisition interval of `blind` is an IQ contract. Because QF256 tones extend
to ±996.09375 Hz, a real 0..6000 Hz WAV path needs a center approximately in
the range 1746.09375..4253.90625 Hz for full ±750 Hz coverage, plus a frontend
passband that actually retains those frequencies. The 1500 Hz default covers
the nominal zero-CFO waveform but not the complete negative-CFO limit.

`blind-hf` is the bounded real-audio profile. With a physical USB passband of
300–2,700 Hz, an audio centre from 1,475 through 1,525 Hz, and residual CFO no
larger than ±125 Hz, the outer tone centres occupy 353.90625–2,646.09375 Hz.
That leaves 53.90625 Hz to each limiting passband edge in the worst Cartesian
corner. This numerical contract assumes the frontend retains those tone
centres; real transition-band attenuation remains a system-level check. The
guard bands are absent in this frontend, so the decoder normally selects its
in-band tone N0 estimate.

RX JSON reports `accepted`, `crc_ok`, `payload77`, `payload_hex`, `start_sample`,
`start_s`, `cfo_hz`, `noise_variance`, `estimated_n0`, `evidence`, `gate`,
`iterations`, and CPU time. Payload fields are `null` unless acceptance succeeds.
`snr_db` is the accepted-frame estimate above and
`snr_reference_bandwidth_hz` is 2500; `snr_db` is `null` when no accepted valid
estimate is available. `doppler_spread_hz` is always `null`. `estimated_n0`
equals `noise_variance/12000`. `reference_iq_layout` is true for IQ input with
180,000 complex samples and blind synchronization.

The acceptance rule is valid CRC/FEC and
`evidence >= 30.220758775848424`. Evidence is a dimensionless detection statistic,
not a probability or signal SNR.

CLI exit status is 0 for success, 1 for a valid capture with no accepted message,
and 2 for invalid input. Errors produce JSON on standard output; the runtime
may also print a stop code on standard error. `--help` is text and `info` is JSON.

## License

The library is distributed under [GPL-3.0-or-later](../LICENSE). QRA authorship
and provenance are recorded in [licenses/QRA-NOTICE.txt](../licenses/QRA-NOTICE.txt).
