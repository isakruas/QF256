#!/usr/bin/env bash
# Functional CLI regressions. Run only the installed-in-tree QF256 executables.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
[[ -x bin/qf256 ]] || { printf '%s\n' 'Build bin/qf256 before running CLI tests.' >&2; exit 1; }
mkdir -p build/test
scratch=$(mktemp -d build/test/cli.XXXXXX)
trap 'status=$?; if [[ $status -eq 0 ]]; then rm -r -- "$scratch"; else printf "CLI test artifacts retained in %s\n" "$scratch" >&2; fi' EXIT
IFS= read -r bits < tests/fixtures/payload77.txt
checks=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
json_object() {
  [[ $(wc -l < "$1") -eq 1 ]] || fail "expected one JSON line in $1"
  grep -Eq '^\{.*\}$' "$1" || fail "expected a JSON object in $1"
  grep -Eq '"modem"[[:space:]]*:[[:space:]]*"QF256"' "$1" || fail "missing modem identity in $1"
}
accepted_decode() {
  json_object "$1"
  grep -Eq '"accepted"[[:space:]]*:[[:space:]]*true' "$1" || fail 'clean waveform was not accepted'
  grep -Eq '"payload77"[[:space:]]*:[[:space:]]*"'"$bits"'"' "$1" || fail 'decoded payload differs'
  grep -Eq '"snr_db"[[:space:]]*:[[:space:]]*[-+0-9.]' "$1" || fail 'accepted decode lacks numeric SNR'
  grep -Eq '"snr_reference_bandwidth_hz"[[:space:]]*:[[:space:]]*2500' "$1" || fail 'wrong SNR reference bandwidth'
  grep -Eq '"cfo_hz"[[:space:]]*:[[:space:]]*[-+0-9.]' "$1" || fail 'missing frequency estimate'
  grep -Eq '"start_s"[[:space:]]*:[[:space:]]*[-+0-9.]' "$1" || fail 'missing timing estimate'
  grep -Eq '"noise_variance"[[:space:]]*:[[:space:]]*[-+0-9.]' "$1" || fail 'missing noise estimate'
  grep -Eq '"evidence"[[:space:]]*:[[:space:]]*[-+0-9.]' "$1" || fail 'missing evidence'
  checks=$((checks+1))
}
expect_error() {
  local label=$1 status
  shift
  set +e
  "$@" > "$scratch/error.json" 2> "$scratch/error.stderr"
  status=$?
  set -e
  [[ $status -eq 2 ]] || fail "$label returned $status instead of 2"
  json_object "$scratch/error.json"
  grep -Eq '"error"[[:space:]]*:[[:space:]]*"' "$scratch/error.json" || fail "$label omitted JSON error"
  checks=$((checks+1))
}

sha256sum -c tests/fixtures/FIXTURES.sha256 > "$scratch/fixtures.log"
./bin/qf256 info > "$scratch/info.json"
json_object "$scratch/info.json"
grep -Eq '"payload_bits"[[:space:]]*:[[:space:]]*77' "$scratch/info.json" || fail 'wrong payload size'
grep -Eq '"version"[[:space:]]*:[[:space:]]*"1\.2\.0"' "$scratch/info.json" || fail 'wrong software version'
grep -Eq '"api_version"[[:space:]]*:[[:space:]]*1' "$scratch/info.json" || fail 'wrong API version'
grep -Eq '"blind_cfo_limit_hz"[[:space:]]*:[[:space:]]*1\.25000000000000000E\+002' "$scratch/info.json" || fail 'wrong blind CFO limit'
if grep -Eq '"blind_hf_cfo_limit_hz"' "$scratch/info.json"; then
  fail 'removed blind-HF limit still reported'
fi
grep -Eq '"gate"[[:space:]]*:[[:space:]]*3\.02207587758484237E\+001' "$scratch/info.json" || fail 'wrong evidence gate'
grep -Eq '"snr_estimate_available"[[:space:]]*:[[:space:]]*true' "$scratch/info.json" || fail 'SNR capability missing'
checks=$((checks+1))

./bin/qf256 tx --bits "$bits" --iq "$scratch/capture.cf32" --wav "$scratch/capture.wav" > "$scratch/tx.json"
json_object "$scratch/tx.json"
[[ $(wc -c < "$scratch/capture.cf32") -eq 1440000 ]] || fail 'default IQ capture must contain 180000 complex samples'
[[ $(wc -c < "$scratch/capture.wav") -eq 360044 ]] || fail 'default mono PCM16 capture length'
./bin/qf256 rx --iq "$scratch/capture.cf32" > "$scratch/iq_rx.json"
accepted_decode "$scratch/iq_rx.json"
grep -Eq '"sync"[[:space:]]*:[[:space:]]*"blind"' "$scratch/iq_rx.json" || fail 'default blind sync not reported'
./bin/qf256 rx --wav "$scratch/capture.wav" > "$scratch/wav_rx.json"
accepted_decode "$scratch/wav_rx.json"

./bin/qf256 tx --bits "$bits" --iq "$scratch/frame.cf32" --wav "$scratch/frame.wav" --frame-only > "$scratch/frame_tx.json"
[[ $(wc -c < "$scratch/frame.cf32") -eq 934400 ]] || fail 'frame-only IQ sample count'
cmp tests/fixtures/reference_audio.wav "$scratch/frame.wav" || fail 'CLI frame WAV differs from preserved audio fixture'
IFS=' ' read -r expected_hash ignored < tests/fixtures/iq_f32.sha256
actual_hash=$(sha256sum "$scratch/frame.cf32"); actual_hash=${actual_hash%% *}
[[ $actual_hash == "$expected_hash" ]] || fail 'CLI frame IQ differs from frozen raw-IQ hash'
dd if="$scratch/capture.cf32" of="$scratch/frame_from_capture.cf32" bs=8 skip=6000 count=116800 status=none
cmp "$scratch/frame.cf32" "$scratch/frame_from_capture.cf32" || fail 'default start/padding changed the transmitted frame'
cmp -n 48000 "$scratch/capture.cf32" /dev/zero || fail 'default capture prefix is not zero'
dd if="$scratch/capture.cf32" of="$scratch/suffix.cf32" bs=8 skip=122800 status=none
cmp -n 457600 "$scratch/suffix.cf32" /dev/zero || fail 'default capture suffix is not zero'
./bin/qf256 rx --iq "$scratch/frame.cf32" --sync known > "$scratch/frame_rx.json"
accepted_decode "$scratch/frame_rx.json"
./bin/qf256 rx --wav "$scratch/frame.wav" --sync known > "$scratch/frame_wav_rx.json"
accepted_decode "$scratch/frame_wav_rx.json"
checks=$((checks+1))

# The equivalent 20-digit representation preserves all 77 bits, MSB first.
hex=$(sed -n 's/.*"payload_hex":"\([0-9A-F]*\)".*/\1/p' "$scratch/tx.json")
[[ ${#hex} -eq 20 ]] || fail 'TX must provide a 20-digit hexadecimal payload'
./bin/qf256 tx --hex "$hex" --iq "$scratch/hex.cf32" --frame-only > "$scratch/hex_tx.json"
cmp "$scratch/frame.cf32" "$scratch/hex.cf32" || fail 'hex and binary inputs encode differently'
checks=$((checks+1))

# Exercise the explicit audio-center option independently of its default.
./bin/qf256 tx --bits "$bits" --wav "$scratch/center1800.wav" --center-hz 1800 > "$scratch/center_tx.json"
./bin/qf256 rx --wav "$scratch/center1800.wav" --center-hz 1800 > "$scratch/center_rx.json"
accepted_decode "$scratch/center_rx.json"

# Valid zero input is a rejected decode (exit1), not an invalid-file error.
dd if=/dev/zero of="$scratch/zero.cf32" bs=8 count=180000 status=none
set +e
./bin/qf256 rx --iq "$scratch/zero.cf32" > "$scratch/zero_rx.json" 2> "$scratch/zero_rx.stderr"
status=$?
set -e
[[ $status -eq 1 ]] || fail 'zero capture must return no-decode exit1'
json_object "$scratch/zero_rx.json"
grep -Eq '"accepted"[[:space:]]*:[[:space:]]*false' "$scratch/zero_rx.json" || fail 'zero capture accepted'
grep -Eq '"payload77"[[:space:]]*:[[:space:]]*null' "$scratch/zero_rx.json" || fail 'rejected payload must be null'
grep -Eq '"snr_db"[[:space:]]*:[[:space:]]*null' "$scratch/zero_rx.json" || fail 'rejected decode must not expose SNR'
checks=$((checks+1))

head -c 9 "$scratch/capture.cf32" > "$scratch/truncated.cf32"
head -c 8 "$scratch/capture.cf32" > "$scratch/short.cf32"
head -c 100 "$scratch/capture.wav" > "$scratch/truncated.wav"
cp "$scratch/capture.wav" "$scratch/bad_rate.wav"
printf '\200\273\000\000' | dd of="$scratch/bad_rate.wav" bs=1 seek=24 conv=notrunc status=none
printf '\000\000\300\177\000\000\000\000' > "$scratch/nonfinite.cf32"
dd if=/dev/zero of="$scratch/oversized.cf32" bs=8 count=180001 status=none
cp "$scratch/capture.wav" "$scratch/oversized.wav"
printf '\000\000' >> "$scratch/oversized.wav"
# RIFF size = 360038; data size = 360002 for 180001 PCM16 mono samples.
printf '\146\176\005\000' | dd of="$scratch/oversized.wav" bs=1 seek=4 conv=notrunc status=none
printf '\102\176\005\000' | dd of="$scratch/oversized.wav" bs=1 seek=40 conv=notrunc status=none
expect_error 'short payload' ./bin/qf256 tx --bits "${bits:0:76}" --iq "$scratch/bad.cf32"
expect_error 'nonbinary payload' ./bin/qf256 tx --bits "2${bits:1}" --iq "$scratch/bad.cf32"
expect_error 'oversized hexadecimal payload' ./bin/qf256 tx --hex 20000000000000000000 --iq "$scratch/bad.cf32"
expect_error 'both payload forms' ./bin/qf256 tx --bits "$bits" --hex "$hex" --iq "$scratch/bad.cf32"
expect_error 'absent IQ file' ./bin/qf256 rx --iq "$scratch/absent.cf32"
expect_error 'absent WAV file' ./bin/qf256 rx --wav "$scratch/absent.wav"
expect_error 'partial IQ record' ./bin/qf256 rx --iq "$scratch/truncated.cf32"
expect_error 'short capture' ./bin/qf256 rx --iq "$scratch/short.cf32"
expect_error 'nonfinite IQ' ./bin/qf256 rx --iq "$scratch/nonfinite.cf32"
expect_error 'oversized IQ capture' ./bin/qf256 rx --iq "$scratch/oversized.cf32"
expect_error 'truncated WAV' ./bin/qf256 rx --wav "$scratch/truncated.wav"
expect_error 'unsupported WAV rate' ./bin/qf256 rx --wav "$scratch/bad_rate.wav"
expect_error 'oversized WAV capture' ./bin/qf256 rx --wav "$scratch/oversized.wav"
expect_error 'invalid audio center' ./bin/qf256 rx --wav "$scratch/capture.wav" --center-hz 9000
expect_error 'nonnumeric audio center' ./bin/qf256 rx --wav "$scratch/capture.wav" --center-hz bad
expect_error 'nonfinite audio center' ./bin/qf256 rx --wav "$scratch/capture.wav" --center-hz NaN
expect_error 'audio center with extra number' ./bin/qf256 rx --wav "$scratch/capture.wav" --center-hz '1500 2'
expect_error 'unknown option' ./bin/qf256 rx --iq "$scratch/capture.cf32" --unknown value
expect_error 'missing option argument' ./bin/qf256 rx --iq
expect_error 'duplicate input option' ./bin/qf256 rx --iq "$scratch/capture.cf32" --iq "$scratch/capture.cf32"
expect_error 'two RX inputs' ./bin/qf256 rx --iq "$scratch/capture.cf32" --wav "$scratch/capture.wav"
expect_error 'invalid synchronization' ./bin/qf256 rx --iq "$scratch/capture.cf32" --sync wrong
expect_error 'removed blind-HF synchronization' ./bin/qf256 rx --iq "$scratch/capture.cf32" --sync blind-hf
expect_error 'synchronization with trailing garbage' ./bin/qf256 rx --iq "$scratch/capture.cf32" --sync 'known           garbage'
printf -v long_arg '%05000d' 0
expect_error 'oversized argument' ./bin/qf256 tx --bits "$long_arg" --iq "$scratch/bad.cf32"
expect_error 'TX-only RX option' ./bin/qf256 rx --iq "$scratch/capture.cf32" --bits "$bits"
expect_error 'RX-only TX option' ./bin/qf256 tx --bits "$bits" --iq "$scratch/bad.cf32" --sync known
expect_error 'invalid start window' ./bin/qf256 tx --bits "$bits" --iq "$scratch/bad.cf32" --start-seconds 0.9
expect_error 'conflicting frame timing' ./bin/qf256 tx --bits "$bits" --iq "$scratch/bad.cf32" --frame-only --start-seconds 0.5
expect_error 'same IQ and WAV path' ./bin/qf256 tx --bits "$bits" --iq "$scratch/bad.cf32" --wav "$scratch/bad.cf32"
before=$(sha256sum "$scratch/capture.cf32")
expect_error 'existing output' ./bin/qf256 tx --bits "$bits" --iq "$scratch/capture.cf32"
after=$(sha256sum "$scratch/capture.cf32")
[[ $before == "$after" ]] || fail 'existing output changed after rejected overwrite'
printf 'PASS: %d QF256 CLI regression checks\n' "$checks"
