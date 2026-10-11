#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
mkdir -p build/test
example_dir=$(mktemp -d build/test/examples.XXXXXX)
trap 'rm -rf -- "$example_dir"' EXIT
for layout in capture frame; do
  args=()
  sync=blind
  if [[ $layout == frame ]]; then args=(--frame-only); sync=known; fi
  bin/qf256-tx --hex 0123456789ABCDEF0123 "${args[@]}" \
    --iq "$example_dir/$layout.cf32" --wav "$example_dir/$layout.wav" > "$example_dir/tx.json"
  for format in iq wav; do
    suffix=cf32
    if [[ $format == wav ]]; then suffix=wav; fi
    bin/qf256-rx --"$format" "$example_dir/$layout.$suffix" --sync "$sync" > "$example_dir/rx.json"
    grep -Eq '"accepted"[[:space:]]*:[[:space:]]*true' "$example_dir/rx.json"
    grep -Eq '"payload_hex"[[:space:]]*:[[:space:]]*"0123456789ABCDEF0123"' "$example_dir/rx.json"
  done
done
printf '%s\n' 'PASS: documented IQ/WAV examples with known and blind synchronization'
