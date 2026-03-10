#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/flame}"
PROFILE_BIN="${PROFILE_BIN:-$BUILD_DIR/spsc_bench}"
PROFILE_NAME="${PROFILE_NAME:-$(basename "$PROFILE_BIN")}"
PROFILE_DURATION_SEC="${PROFILE_DURATION_SEC:-30}"
PROFILE_LANES="${PROFILE_LANES:-4}"
PROFILE_STRESS_THREADS="${PROFILE_STRESS_THREADS:-2}"
PROFILE_STRESS_BYTES="${PROFILE_STRESS_BYTES:-33554432}"
PROFILE_INTERVAL_MS="${PROFILE_INTERVAL_MS:-250}"
PROFILE_CAPACITY="${PROFILE_CAPACITY:-1024}"
PROFILE_SAMPLE_RATE="${PROFILE_SAMPLE_RATE:-1000}"
PROFILE_TIMELINE="${PROFILE_TIMELINE:-$OUT_DIR/${PROFILE_NAME}.timeline.csv}"
PROFILE_TRACE_EVENT_JSON="${PROFILE_TRACE_EVENT_JSON:-$OUT_DIR/${PROFILE_NAME}.trace_event.json}"
PROFILE_RAW_METRICS="${PROFILE_RAW_METRICS:-$OUT_DIR/${PROFILE_NAME}.raw_metrics.txt}"
XCTRACE_OUTPUT="${XCTRACE_OUTPUT:-$OUT_DIR/${PROFILE_NAME}.trace}"
XCTRACE_LOG="${XCTRACE_LOG:-$OUT_DIR/${PROFILE_NAME}.xctrace.log}"
SAMPLY_OUTPUT="${SAMPLY_OUTPUT:-$OUT_DIR/${PROFILE_NAME}.samply.json.gz}"
SAMPLY_LOG="${SAMPLY_LOG:-$OUT_DIR/${PROFILE_NAME}.samply.log}"
SAMPLE_OUTPUT="${SAMPLE_OUTPUT:-$OUT_DIR/${PROFILE_NAME}.sample.txt}"
PROFILE_EXTRA_ARGS="${PROFILE_EXTRA_ARGS:-}"

if [[ ! -x "$PROFILE_BIN" ]]; then
  echo "$PROFILE_BIN not found; run 'make cpp' first or override PROFILE_BIN" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

benchmark_args() {
  local -a args=(
    --duration-sec "$PROFILE_DURATION_SEC"
    --capacity "$PROFILE_CAPACITY"
    --lanes "$PROFILE_LANES"
    --stress-threads "$PROFILE_STRESS_THREADS"
    --stress-bytes "$PROFILE_STRESS_BYTES"
    --report-interval-ms "$PROFILE_INTERVAL_MS"
  )
  if [[ -n "$PROFILE_EXTRA_ARGS" ]]; then
    local -a extra_args=()
    # PROFILE_EXTRA_ARGS is intentionally shell-like so callers can append flags quickly.
    read -r -a extra_args <<<"$PROFILE_EXTRA_ARGS"
    args+=("${extra_args[@]}")
  fi
  printf '%s\n' "${args[@]}"
}

collect_benchmark_args() {
  local -a args=()
  while IFS= read -r line; do
    args+=("$line")
  done < <(benchmark_args)
  printf '%s\n' "${args[@]}"
}

run_plain_trace() {
  local -a args=()
  while IFS= read -r line; do
    args+=("$line")
  done < <(collect_benchmark_args)
  "$PROFILE_BIN" \
    "${args[@]}" \
    --timeline-csv "$PROFILE_TIMELINE" \
    --trace-event-json "$PROFILE_TRACE_EVENT_JSON" \
    >"$PROFILE_RAW_METRICS"
}

run_xctrace() {
  if ! command -v xctrace >/dev/null 2>&1; then
    echo "xctrace not found; skipping Instruments capture" >&2
    return 1
  fi

  local -a args=()
  while IFS= read -r line; do
    args+=("$line")
  done < <(collect_benchmark_args)
  rm -rf "$XCTRACE_OUTPUT"
  rm -f "$XCTRACE_LOG"

  if xctrace record \
    --template "Time Profiler" \
    --output "$XCTRACE_OUTPUT" \
    --time-limit "${PROFILE_DURATION_SEC}s" \
    --launch -- "$PROFILE_BIN" "${args[@]}" \
    >"$XCTRACE_LOG" 2>&1; then
    echo "xctrace_trace=$XCTRACE_OUTPUT"
    echo "xctrace_log=$XCTRACE_LOG"
    return 0
  fi

  echo "xctrace failed; see $XCTRACE_LOG" >&2
  return 1
}

run_samply() {
  if ! command -v samply >/dev/null 2>&1; then
    echo "samply not found; skipping Firefox Profiler capture" >&2
    return 1
  fi

  local -a args=()
  while IFS= read -r line; do
    args+=("$line")
  done < <(collect_benchmark_args)
  rm -f "$SAMPLY_OUTPUT" "$SAMPLY_LOG"

  if samply record \
    --save-only \
    --no-open \
    --rate "$PROFILE_SAMPLE_RATE" \
    --output "$SAMPLY_OUTPUT" \
    "$PROFILE_BIN" "${args[@]}" \
    >"$SAMPLY_LOG" 2>&1; then
    echo "samply_profile=$SAMPLY_OUTPUT"
    echo "samply_log=$SAMPLY_LOG"
    return 0
  fi

  echo "samply failed; see $SAMPLY_LOG" >&2
  return 1
}

run_sample_fallback() {
  if ! command -v sample >/dev/null 2>&1; then
    return 1
  fi

  local -a args=()
  while IFS= read -r line; do
    args+=("$line")
  done < <(collect_benchmark_args)
  "$PROFILE_BIN" "${args[@]}" &
  local pid=$!
  sleep 1
  if sample "$pid" 3 -file "$SAMPLE_OUTPUT"; then
    echo "sample_snapshot=$SAMPLE_OUTPUT"
  else
    echo "sample failed to attach cleanly; benchmark still completed" >&2
  fi
  wait "$pid"
}

run_plain_trace
echo "raw_metrics=$PROFILE_RAW_METRICS"
echo "timeline_csv=$PROFILE_TIMELINE"
echo "trace_event_json=$PROFILE_TRACE_EVENT_JSON"

xctrace_ok=0
samply_ok=0

if run_xctrace; then
  xctrace_ok=1
fi

if run_samply; then
  samply_ok=1
fi

if [[ "$samply_ok" -eq 0 ]]; then
  run_sample_fallback || true
fi

if [[ "$xctrace_ok" -eq 0 && "$samply_ok" -eq 0 ]]; then
  echo "no sampled profile was captured; plain trace artifacts were still generated in $OUT_DIR" >&2
fi
