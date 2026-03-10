set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/perf_report}"
BENCH_BIN="$BUILD_DIR/spsc_bench"

DURATION_SEC="${DURATION_SEC:-30}"
CAPACITY="${CAPACITY:-1024}"
LANES="${LANES:-4}"
STRESS_THREADS="${STRESS_THREADS:-2}"
STRESS_BYTES="${STRESS_BYTES:-33554432}"
REPORT_INTERVAL_MS="${REPORT_INTERVAL_MS:-250}"
LATENCY_BUCKET_NS="${LATENCY_BUCKET_NS:-100}"
LATENCY_MAX_NS="${LATENCY_MAX_NS:-100000000}"

mkdir -p "$OUT_DIR"

if [[ ! -x "$BENCH_BIN" ]]; then
  echo "build/spsc_bench not found; run 'make cpp' first" >&2
  exit 1
fi

RAW_METRICS="$OUT_DIR/raw_metrics.txt"
TIMELINE_CSV="$OUT_DIR/timeline.csv"
LATENCY_HISTOGRAM_CSV="$OUT_DIR/latency_histogram.csv"
TRACE_EVENT_JSON="$OUT_DIR/trace_event.json"
REPORT_MD="$OUT_DIR/perf_report.md"

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
  --latency-histogram-csv "$LATENCY_HISTOGRAM_CSV" \
  --trace-event-json "$TRACE_EVENT_JSON" \
  >"$RAW_METRICS"

metric() {
  awk -F= -v key="$1" '$1 == key { print $2 }' "$RAW_METRICS"
}

HOSTNAME_VALUE="$(hostname)"
UNAME_VALUE="$(uname -a)"
MACOS_VERSION="$(sw_vers 2>/dev/null | tr '\n' '; ' || true)"
CPU_VALUE="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"

cat >"$REPORT_MD" <<EOF
# Performance Report

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
- latency histogram csv: $LATENCY_HISTOGRAM_CSV
- trace event json: $TRACE_EVENT_JSON

## Viewers

- Perfetto UI: open \`trace_event.json\`
- Chrome trace viewers: open \`trace_event.json\`
- Jane Street Magic Trace: compatibility is not guaranteed from macOS-generated artifacts, but this JSON is the portable trace to try first
- xctrace / sample: still useful locally for true sampled stacks and flamegraph-style hotspot inspection

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
  --latency-max-ns $LATENCY_MAX_NS \\
  --latency-histogram-csv $LATENCY_HISTOGRAM_CSV \\
  --trace-event-json $TRACE_EVENT_JSON
\`\`\`

## Notes

- \`trace_event.json\` is a portable event trace, not a sampled call-stack flamegraph.
- For stack flamegraphs on macOS, keep using \`xctrace\` or \`sample\`; those traces are not directly interchangeable with Linux perf or Magic Trace captures.
- The timeline and histogram CSVs are intended for plotting throughput drift, backlog growth, and latency distribution in external tools.
EOF

echo "raw_metrics=$RAW_METRICS"
echo "timeline_csv=$TIMELINE_CSV"
echo "latency_histogram_csv=$LATENCY_HISTOGRAM_CSV"
echo "trace_event_json=$TRACE_EVENT_JSON"
echo "report_md=$REPORT_MD"
