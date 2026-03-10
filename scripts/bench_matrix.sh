#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
OUT_PATH="${1:-$ROOT_DIR/docs/bench_results.md}"
CAPACITIES=(256 1024 4096)
MESSAGES=(200000 1000000)

if [[ ! -x "$BUILD_DIR/spsc_bench" ]]; then
  echo "build/spsc_bench not found; run 'make cpp' first" >&2
  exit 1
fi

{
  echo "# Benchmark Results"
  echo
  echo "| messages | capacity | ns/message | throughput (M msg/s) |"
  echo "| --- | --- | ---: | ---: |"
  for messages in "${MESSAGES[@]}"; do
    for capacity in "${CAPACITIES[@]}"; do
      output="$("$BUILD_DIR/spsc_bench" --messages "$messages" --capacity "$capacity" 2>/dev/null)"
      ns_per_message="$(printf '%s\n' "$output" | awk -F= '/^ns_per_message=/{print $2}')"
      throughput="$(printf '%s\n' "$output" | awk -F= '/^throughput_mps=/{print $2}')"
      echo "| $messages | $capacity | $ns_per_message | $throughput |"
    done
  done
} >"$OUT_PATH"

echo "wrote=$OUT_PATH"

