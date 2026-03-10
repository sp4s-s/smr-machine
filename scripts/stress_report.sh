#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/stress_report}"
BENCH_BIN="$BUILD_DIR/spsc_bench"

DURATION_SEC="${DURATION_SEC:-60}"
CAPACITY="${CAPACITY:-1024}"
LANES="${LANES:-4}"
STRESS_THREADS="${STRESS_THREADS:-2}"
STRESS_BYTES="${STRESS_BYTES:-33554432}"
REPORT_INTERVAL_MS="${REPORT_INTERVAL_MS:-1000}"
LATENCY_BUCKET_NS="${LATENCY_BUCKET_NS:-100}"
LATENCY_MAX_NS="${LATENCY_MAX_NS:-100000000}"

mkdir -p "$OUT_DIR"

if [[ ! -x "$BENCH_BIN" ]]; then
  echo "build/spsc_bench not found; run 'make cpp' first" >&2
  exit 1
fi

RAW_METRICS="$OUT_DIR/raw_metrics.txt"
TIMELINE_CSV="$OUT_DIR/timeline.csv"
REPORT_MD="$OUT_DIR/stress_report.md"

"$BENCH_BIN" \
  --duration-sec "$DURATION_SEC" \
  --capacity "$CAPACITY" \
  --lanes "$LANES" \
  --stress-threads "$STRESS_THREADS" \
  --stress-bytes "$STRESS_BYTES" \
  --report-interval-ms "$REPORT_INTERVAL_MS" \
  --timeline-csv "$TIMELINE_CSV" \
  --latency-bucket-ns "$LATENCY_BUCKET_NS" \
  --latency-max-ns "$LATENCY_MAX_NS" \
  >"$RAW_METRICS"

metric() {
  awk -F= -v key="$1" '$1 == key { print $2 }' "$RAW_METRICS"
}

HOSTNAME_VALUE="$(hostname)"
UNAME_VALUE="$(uname -a)"
MACOS_VERSION="$(sw_vers 2>/dev/null | tr '\n' '; ' || true)"
CPU_VALUE="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"

cat >"$REPORT_MD" <<EOF
# Stress Test Report

## Environment

- host: $HOSTNAME_VALUE
- cpu: $CPU_VALUE
- uname: $UNAME_VALUE
- macOS: $MACOS_VERSION

## Run Configuration

- duration_sec: $DURATION_SEC
- capacity: $CAPACITY
- lanes: $LANES
- stress_threads: $STRESS_THREADS
- stress_bytes: $STRESS_BYTES
- report_interval_ms: $REPORT_INTERVAL_MS
- latency_bucket_ns: $LATENCY_BUCKET_NS
- latency_max_ns: $LATENCY_MAX_NS

## Throughput

- messages: $(metric messages)
- elapsed_ns: $(metric elapsed_ns)
- ns_per_message: $(metric ns_per_message)
- throughput_mps: $(metric throughput_mps)

## Latency Percentiles

- min_ns: $(metric latency_min_ns)
- mean_ns: $(metric latency_mean_ns)
- p50_ns: $(metric latency_p50_ns)
- p55_ns: $(metric latency_p55_ns)
- p90_ns: $(metric latency_p90_ns)
- p95_ns: $(metric latency_p95_ns)
- p99_ns: $(metric latency_p99_ns)
- p99.9_ns: $(metric latency_p999_ns)
- p99.99_ns: $(metric latency_p9999_ns)
- max_ns: $(metric latency_max_ns)

## Artifacts

- raw metrics: $RAW_METRICS
- timeline csv: $TIMELINE_CSV

## Reproduction

\`\`\`bash
make cpp
$BENCH_BIN \\
  --duration-sec $DURATION_SEC \\
  --capacity $CAPACITY \\
  --lanes $LANES \\
  --stress-threads $STRESS_THREADS \\
  --stress-bytes $STRESS_BYTES \\
  --report-interval-ms $REPORT_INTERVAL_MS \\
  --timeline-csv $TIMELINE_CSV \\
  --latency-bucket-ns $LATENCY_BUCKET_NS \\
  --latency-max-ns $LATENCY_MAX_NS
\`\`\`

## Notes

- This benchmark preserves SPSC semantics by using one producer and one consumer per lane.
- Background stress threads add memory and scheduler pressure without violating the queue contract.
- Use the timeline CSV to graph throughput drift, thermal throttling, or burst patterns over time.
EOF

echo "raw_metrics=$RAW_METRICS"
echo "timeline_csv=$TIMELINE_CSV"
echo "report_md=$REPORT_MD"
