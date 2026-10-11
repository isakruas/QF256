# QF256

QF256 is a Fortran modem for 77-bit payloads, using 256-tone continuous-phase FSK and QRA error correction over GF(256). It provides command-line transmitters and receivers, a Fortran API, and a C ABI.

Each frame contains 60 data symbols and 16 synchronization symbols at 0.128 s per symbol. The sample rate is 12,000 complex samples/s; the complete filtered frame contains 116,800 samples and lasts 9.733333 s.

## Build

Install GNU Fortran, GNU Make, binutils (`ar`), and the GNU Fortran runtime libraries. Tests use Bash and standard command-line utilities; the C ABI test also requires `cc`.

Run these commands from the QF256 project directory:

```sh
make -j4
make test
make test-c-api
```

Outputs are `bin/qf256`, `bin/qf256-tx`, `bin/qf256-rx`, `lib/libqf256.a`, and `lib/libqf256.so`. `make clean` removes generated build, binary, library, and study-build directories.

For a clean verification with compiler warnings treated as errors, run `make strict`. It builds the modem tools, libraries, tests and study programs, then runs the regression tests, documented examples and study analysis. This target also needs GNUplot with `pdfcairo` and `pngcairo` support; `GNUPLOT=/path/to/gnuplot` can select its executable. Build the PDF separately with `make report`.

## Generate and decode

Choose unused output paths; the writers reject existing files.

```sh
mkdir -p examples/run
bin/qf256 tx --hex 0123456789ABCDEF0123 \
  --iq examples/run/message.cf32 --wav examples/run/message.wav
bin/qf256 rx --iq examples/run/message.cf32
bin/qf256 rx --wav examples/run/message.wav --center-hz 1500
```

`qf256-tx` is equivalent to `qf256 tx`; `qf256-rx` is equivalent to `qf256 rx`.

`--hex` accepts exactly 20 hexadecimal digits, most significant first. The first digit must be 0 or 1: the 80-bit representation contains three leading zero padding bits followed by the 77-bit payload. Alternatively, pass exactly 77 binary characters with `--bits`.

TX defaults to a 15 s capture with the transmission starting at 0.5 s. `--start-seconds` accepts 0.3 to 0.7 s. Use `--frame-only` for the active frame:

```sh
bin/qf256-tx --hex 0123456789ABCDEF0123 --frame-only \
  --iq examples/run/burst.cf32 --wav examples/run/burst.wav
bin/qf256-rx --iq examples/run/burst.cf32 --sync known
bin/qf256-rx --wav examples/run/burst.wav --sync known
```

Supply one capture window per RX call:

| Synchronization | Minimum samples | Start and carrier frequency offset (CFO) |
|---|---:|---|
| `known` | 116,800 | Frame starts at sample zero; CFO is zero. |
| `blind` (default) | 125,200 | Searches starts from 0.3 to 0.7 s and complex-baseband CFO from −750 to +750 Hz. |
| `blind-hf` | 125,200 | Uses the same timing search and a conventional-HF CFO range from −125 to +125 Hz. |

The maximum is 180,000 samples (15 s) in either mode. Larger files are rejected before capture allocation or FFT processing. Reported sample offsets are zero-based.

## Files and results

- **IQ:** headerless IEEE 754 little-endian `float32`, interleaved `I0,Q0,I1,Q1,…`, at 12,000 pairs/s and centered at zero. Active-frame average complex power is 1. A full capture contains 180,000 pairs; `--frame-only` produces 116,800 pairs.
- **WAV:** RIFF PCM16 little-endian, mono, 12,000 Hz, with playback peak near −3 dBFS. The default center is 1,500 Hz, placing the zero-CFO tones at approximately 504–2,496 Hz. `--center-hz` accepts 1,100–4,500 Hz; use the same center at RX. The wide ±750 Hz contract applies to complex IQ and requires a correspondingly wide audio passband. The `blind-hf` profile is the validated choice for a 300–2,700 Hz USB frontend with centres 1,475–1,525 Hz. WAV conversion and noise handling are described in [docs/API.md](docs/API.md#file-interfaces-and-noise-fields).
- **RX:** one JSON line with acceptance, raw CRC status, payload, start offset, CFO, selected noise estimate, SNR, evidence, gate, iteration count, and CPU time. `payload77`, `payload_hex`, and the 2500 Hz-referenced `snr_db` are populated for an accepted decode; they are `null` otherwise. `doppler_spread_hz` remains unavailable and is always `null`.
- **Exit status:** 0 for success, 1 for a valid capture without an accepted message, and 2 for an invalid argument or file. Errors produce JSON on standard output; the runtime may also print a stop code on standard error. `--help` produces text; `info` produces JSON.

Acceptance requires valid CRC/FEC **and** `evidence >= 30.220758775848424`. Evidence is pilot energy divided by the selected N0 estimate, minus 16. Field definitions are in the [API reference](docs/API.md).

## Integration

See [docs/API.md](docs/API.md) for the Fortran API, C ABI, memory requirements, and status codes, and [include/qf256.h](include/qf256.h) for the C declarations. Fortran modules are built in `build/mod`.

The sample rate, payload size, waveform, and acceptance gate are fixed. Each RX call returns at most one message. Calls share an FFT cache and must be serialized within a process; separate processes can run concurrently.

## Technical report and current validation

The [wide-acquisition validation](docs/WIDE-ACQUISITION-VALIDATION.txt) records the fixed-seed tests for the current receiver: the ±750 Hz search, recalibrated evidence gate, filtered-audio noise fallback, and boundary-CFO regressions.

The additive [HF acquisition validation](docs/HF-ACQUISITION-VALIDATION.txt)
records the fixed-seed LP1200 tests for `blind-hf`: ±125 Hz CFO, the two
worst-case 1,475/1,525 Hz centres, and the unchanged evidence gate. The wide
`blind` mode and its ±750 Hz contract remain available.

The [PDF report](docs/report/qf256-report.pdf), its [LaTeX source](docs/report/qf256-report.tex), and the bundled HF study are preserved v1.0 evidence. They describe the earlier ±10 Hz blind search, guard-only N0 estimator, and old gate; they are not presented as validation of the expanded receiver.

The [study directory](study/README.md) contains the individual records, Fortran analysis, channel model, indexed reproduction harness, and GNUplot sources. Analyze the preserved records and rebuild the article with pdfLaTeX:

```sh
make study-analysis
make report
```

`study-analysis` analyzes the included historical measurements. Reproducing those trials or `make snr-validation` exactly requires the v1.0.0 source identified by the historical manifests; compiling either harness against the current core is a new experiment. Report dependencies are listed in [docs/report/README.txt](docs/report/README.txt).

## Tests and license

`make test` checks source hashes, code and waveform fixtures, IQ/WAV roundtrips, the SNR result, and invalid inputs. `make test-c-api` checks the 152-byte C result layout and its SNR fields.

QF256 is distributed under GPL-3.0-or-later. See [LICENSE](LICENSE) and the QRA authorship and provenance notices in [licenses/QRA-NOTICE.txt](licenses/QRA-NOTICE.txt).

The repository includes source code, regression fixtures, the technical report, and the study records and figures. Compiled programs, libraries, temporary files, and generated example captures are excluded from version control. Before rebuilding generated study files, verify the checked-in files with:

```sh
sha256sum -c docs/DELIVERY.sha256
```
