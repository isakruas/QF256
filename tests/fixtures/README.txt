QF256 regression fixtures

payload77.txt contains one 77-bit message. codeword65.txt contains all 65 GF256
encoded symbols, including shortened information symbols and CRC bytes.
iq_subset.txt stores 36 one-based complex sample references across the complete
116800-sample frame, including filter tails and symbol boundaries. Float64
sample comparisons use an absolute tolerance of 2e-10.

Full-frame IQ format:
  IEEE 754 float32 little-endian, interleaved I,Q
  116800 complex samples at 12000 complex samples/s
  934400 bytes
  SHA256: 209319139b3d0bf609323e047c2554077d90900b74cb3fcca268389956c46b90

iq_f32.sha256 checks the frame produced by test_core. check_cli.sh checks the
CLI frame-only output against the same digest.

reference_audio.wav contains the same message and frame as mono PCM16LE at
12000 Hz, translated to 1500 Hz and scaled to -3 dBFS peak before quantization.
It has 116800 PCM samples and 233644 bytes.
SHA256: 1f062c0f0605c41fca79034bb68cfe062bdedad8204326faf233e239cf2cd0aa

test_core reconstructs and compares every reference PCM sample exactly.
The audio fixture is the original reference export. Current core source
identities are recorded in docs/CORE.sha256.

Reference platform: little-endian Linux, GNU Fortran 14.2, -O3 without fast-math.
Exact hashes depend on the recorded toolchain and floating-point behavior.
For other platforms, inspect numerical differences against iq_subset.txt
before changing reference values.

tests/create_fixtures.f90 generates the payload, codeword, IQ subset and full
IQ digest. It is run explicitly and refuses to overwrite expected files.
Normal tests read the fixtures without regenerating them. FIXTURES.sha256
covers the payload, codeword, IQ subset, audio and IQ-digest files.
