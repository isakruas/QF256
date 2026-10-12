# QF256

QF256 is a fixed-profile modem for 77-bit messages. It combines 256-tone continuous-phase FSK with QRA error correction over GF(256), and supplies command-line tools, a Fortran API, and a C ABI.

Each frame contains 60 data symbols and 16 synchronization symbols at 0.128 s per symbol. The tone centers span 1,992.1875 Hz. The sample rate is 12,000 complex samples/s; the complete filtered frame contains 116,800 samples and lasts 9.733333 s.

## Build

Install GNU Fortran, GNU Make, binutils (`ar`), and the GNU Fortran runtime libraries. Tests use Bash, Python 3 (standard library only), and standard command-line utilities; the C ABI test also requires `cc`.

Run these commands from the QF256 project directory:

```sh
make -j4
make test
make test-c-api
```

Outputs are `bin/qf256`, `bin/qf256-tx`, `bin/qf256-rx`, `lib/libqf256.a`, and `lib/libqf256.so`. `make clean` removes generated build, binary, library, and study-build directories.

For a rebuild with compiler warnings treated as errors, run `make strict`. It rebuilds the modem tools, libraries, tests, and study analyzers, then runs the regression tests, documented examples, and study analysis without clearing campaign directories. This target also needs GNUplot with `pdfcairo` and `pngcairo` support; `GNUPLOT=/path/to/gnuplot` can select its executable. Build the PDF separately with `make report`.

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

TX defaults to a 15 s capture with the transmission starting at 0.5 s. `--start-seconds` accepts 0.3 to 0.7 s. RX uses one automatic acquisition mode, `blind`. For tests with a frame already aligned at sample zero and zero residual carrier offset, use `--frame-only` and the diagnostic `known` synchronization setting:

```sh
bin/qf256-tx --hex 0123456789ABCDEF0123 --frame-only \
  --iq examples/run/burst.cf32 --wav examples/run/burst.wav
bin/qf256-rx --iq examples/run/burst.cf32 --sync known
bin/qf256-rx --wav examples/run/burst.wav --sync known
```

Supply one capture window per RX call:

| Synchronization | Minimum samples | Start and carrier frequency offset (CFO) |
|---|---:|---|
| `blind` (default) | 125,200 | Searches starts from 0.3 to 0.7 s and residual complex-baseband CFO from −125 to +125 Hz, inclusive. |
| `known` (aligned-input test) | 116,800 | Frame starts at sample zero; CFO is zero. No acquisition search. |

The maximum is 180,000 samples (15 s) in either mode. Larger files are rejected before capture allocation or FFT processing. Reported sample offsets are zero-based.

## Files and results

- **IQ:** headerless IEEE 754 little-endian `float32`, interleaved `I0,Q0,I1,Q1,…`, at 12,000 pairs/s and centered at zero. Active-frame average complex power is 1. A full capture contains 180,000 pairs; `--frame-only` produces 116,800 pairs.
- **WAV:** RIFF PCM16 little-endian, mono, 12,000 Hz, with playback peak near −3 dBFS. The default center is 1,500 Hz, placing the zero-CFO tones at approximately 504–2,496 Hz. `--center-hz` accepts 1,100–4,500 Hz; use the same center at RX. With a 300–2,700 Hz passband, centers from 1,475 through 1,525 Hz keep the tone centers inside the band throughout the ±125 Hz acquisition interval. Real filter transition bands and attenuation still matter. WAV conversion and noise handling are described in [docs/API.md](docs/API.md#file-interfaces-and-noise-fields).
- **RX:** one JSON line with acceptance, raw CRC status, payload, start offset, CFO, selected noise estimate, SNR, evidence, gate, iteration count, and CPU time. `payload77`, `payload_hex`, and the 2500 Hz-referenced `snr_db` are populated for an accepted decode; they are `null` otherwise. `doppler_spread_hz` remains unavailable and is always `null`.
- **Exit status:** 0 for success, 1 for a valid capture without an accepted message, and 2 for an invalid argument or file. Errors produce JSON on standard output; the runtime may also print a stop code on standard error. `--help` produces text; `info` produces JSON.

Acceptance requires valid CRC/FEC **and** `evidence >= 30.220758775848424`. Evidence is pilot energy divided by the selected N0 estimate, minus 16. Field definitions are in the [API reference](docs/API.md).

## Integration

See [docs/API.md](docs/API.md) for the Fortran API, C ABI, memory requirements, and status codes, and [include/qf256.h](include/qf256.h) for the C declarations. Fortran modules are built in `build/mod`.

The sample rate, payload size, waveform, and acceptance gate are fixed. Each RX call returns at most one message. Calls share an FFT cache and must be serialized within a process; separate processes can run concurrently.

## Measurements and technical report

The [technical report](docs/report/qf256-report.pdf) specifies the modem and evaluates the included implementation. The [study](study/README.md) contains the channel model, per-trial records, statistical analysis, reproduction harnesses, and figure sources. Its three fading settings are the quiet, moderate and disturbed mid-latitude profiles specified by ITU-R F.1487-0; the finite simulation and frame-acceptance experiment do not claim compliance with the recommendation's complete BER/test-duration procedure. Fading performance, noise-only acceptance, and acquisition-boundary tests are evaluated separately. These controlled measurements do not guarantee an on-air decoding probability or establish superiority over another modem.

Recompute statistics and figures from the published records, then build the article with pdfLaTeX:

```sh
make study-analysis
make report
```

`study-analysis` does not rerun channel trials. Complete campaign commands are in [study/README.md](study/README.md), and report dependencies are in [docs/report/README.txt](docs/report/README.txt). Build and validation results are summarized in [docs/VALIDATION.txt](docs/VALIDATION.txt).

## Tests and license

`make test` checks source hashes, code and waveform fixtures, IQ/WAV roundtrips, the SNR result, invalid inputs, channel/frontend invariants, and study-record integrity. `make test-c-api` checks the 152-byte C result layout and its SNR fields. Full acquisition campaigns additionally require NumPy; ordinary regression tests do not.

QF256 is distributed under GPL-3.0-or-later. See [LICENSE](LICENSE) and the QRA authorship and provenance notices in [licenses/QRA-NOTICE.txt](licenses/QRA-NOTICE.txt).

The repository includes source code, regression fixtures, the technical report, and the study records and figures. Compiled programs, libraries, temporary files, and generated example captures are excluded from version control. Before rebuilding generated study files, verify the checked-in files with:

```sh
sha256sum -c docs/DELIVERY.sha256
```
