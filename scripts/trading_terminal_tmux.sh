#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SESSION_NAME="${SESSION_NAME:-trading-terminal}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/build/trading_terminal}"
RUN_ARGS="${RUN_ARGS:-}"
RESET_ARTIFACTS="${RESET_ARTIFACTS:-1}"
ATTACH_ON_START="${ATTACH_ON_START:-1}"
AUTO_RUN="${AUTO_RUN:-0}"

usage() {
  cat <<EOF
usage: scripts/trading_terminal_tmux.sh <start|attach|stop>

Environment overrides:
  SESSION_NAME   tmux session name (default: trading-terminal)
  ARTIFACT_DIR   artifact directory (default: \$ROOT_DIR/build/trading_terminal)
  RUN_ARGS       extra args forwarded to scripts/run_trading_stress.lua
  RESET_ARTIFACTS  1 resets prior artifacts before start (default: 1)
  ATTACH_ON_START  1 attaches after start, 0 leaves session detached (default: 1)
  AUTO_RUN       1 starts managed stress in the runner window, 0 monitor-only layout (default: 0)

Windows:
  monitor  — live order terminal (order_terminal.lua) with latency/PnL/positions
  runner   — stress runner or manual command entry
  status   — rolling status.json + tail of stdout/stderr logs
  shell    — interactive shell at project root
  replays  — list of generated .pr42 replay files
EOF
}

quote() {
  printf '%q' "$1"
}

reset_artifacts() {
  if [[ "$RESET_ARTIFACTS" != "1" ]]; then
    return
  fi
  rm -f \
    "$ARTIFACT_DIR/status.json" \
    "$ARTIFACT_DIR/run_history.jsonl" \
    "$ARTIFACT_DIR/summary.json" \
    "$ARTIFACT_DIR/timeline.csv" \
    "$ARTIFACT_DIR/trace_event.json" \
    "$ARTIFACT_DIR/raw_events.jsonl" \
    "$ARTIFACT_DIR/raw_events.stream.jsonl" \
    "$ARTIFACT_DIR/raw_events.stream.fifo" \
    "$ARTIFACT_DIR/stress.stdout.log" \
    "$ARTIFACT_DIR/stress.stderr.log"
  rm -rf "$ARTIFACT_DIR/replays"
}

start_session() {
  mkdir -p "$ARTIFACT_DIR"
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    tmux kill-session -t "$SESSION_NAME"
  fi
  reset_artifacts

  local root_q artifact_q run_args_q
  root_q="$(quote "$ROOT_DIR")"
  artifact_q="$(quote "$ARTIFACT_DIR")"
  run_args_q="$RUN_ARGS"

  # ── window 0: monitor ──
  tmux new-session -d -s "$SESSION_NAME" -n monitor
  tmux set-option -t "$SESSION_NAME:monitor" history-limit 20
  tmux send-keys -t "$SESSION_NAME:monitor" \
    "cd $root_q && exec lua scripts/order_terminal.lua --event-log $artifact_q/raw_events.jsonl --event-stream-log $artifact_q/raw_events.stream.jsonl --status-json $artifact_q/status.json --run-history-jsonl $artifact_q/run_history.jsonl --refresh-ms 100 --scan-lines-per-tick 40000 --latency-window 10000" C-m

  # ── window 1: runner ──
  tmux new-window -t "$SESSION_NAME" -n runner
  if [[ "$AUTO_RUN" == "1" ]]; then
    tmux send-keys -t "$SESSION_NAME:runner" \
      "cd $root_q && exec lua scripts/run_trading_stress.lua --artifact-dir $artifact_q $run_args_q" C-m
  else
    tmux send-keys -t "$SESSION_NAME:runner" \
      "cd $root_q && printf 'State Machine Replication Trading Terminal — Runner Pane\n\nRun stress test:\n  lua scripts/run_trading_stress.lua --artifact-dir $artifact_q\n\nOr run command_stress directly:\n  ./build/command_stress --duration-sec 10 --capacity 4096 --lanes 4 --stress-threads 2 \\\\\n    --raw-events-jsonl $artifact_q/raw_events.jsonl \\\\\n    --summary-json $artifact_q/summary.json \\\\\n    --timeline-csv $artifact_q/timeline.csv \\\\\n    --trace-event-json $artifact_q/trace_event.json \\\\\n    --replay-dir $artifact_q/replays\n'" C-m
  fi

  # ── window 2: status ──
  tmux new-window -t "$SESSION_NAME" -n status
  tmux set-option -t "$SESSION_NAME:status" history-limit 20
  tmux send-keys -t "$SESSION_NAME:status" \
    "cd $root_q && while true; do clear; printf '\\033[1;36m=== STATUS ===\\033[0m\\n'; test -f $artifact_q/status.json && python3 -c \"import json; import pathlib; p=pathlib.Path('$ARTIFACT_DIR/status.json'); d=json.loads(p.read_text()) if p.exists() else None; cfg=(d or {}).get('run_config', {}); prog=(d or {}).get('progress', {}); print(f'state={(d or {}).get(\\\"state\\\",\\\"off\\\")} label={(d or {}).get(\\\"label\\\",\\\"OFF\\\")} started={(d or {}).get(\\\"started_at\\\",\\\"-\\\")} ended={(d or {}).get(\\\"ended_at\\\",\\\"-\\\")}'); print(f'lanes={cfg.get(\\\"lanes\\\",\\\"-\\\")} stress_threads={cfg.get(\\\"stress_threads\\\",\\\"-\\\")} capacity={cfg.get(\\\"capacity\\\",\\\"-\\\")} duration_sec={cfg.get(\\\"duration_sec\\\",\\\"-\\\")} failure_limit={cfg.get(\\\"failure_limit\\\",\\\"-\\\")} seed={cfg.get(\\\"seed\\\",\\\"-\\\")}'); print(f'weights submit={cfg.get(\\\"submit_weight\\\",\\\"-\\\")} modify={cfg.get(\\\"modify_weight\\\",\\\"-\\\")} cancel={cfg.get(\\\"cancel_weight\\\",\\\"-\\\")} fill={cfg.get(\\\"fill_weight\\\",\\\"-\\\")} fail={cfg.get(\\\"fail_weight\\\",\\\"-\\\")} invalid_bps={cfg.get(\\\"invalid_bps\\\",\\\"-\\\")}'); print(f'progress elapsed_ms={prog.get(\\\"elapsed_ms\\\",\\\"-\\\")} produced={prog.get(\\\"produced\\\",\\\"-\\\")} consumed={prog.get(\\\"consumed\\\",\\\"-\\\")} succeeded={prog.get(\\\"succeeded\\\",\\\"-\\\")} failed={prog.get(\\\"failed\\\",\\\"-\\\")} backlog={prog.get(\\\"backlog\\\",\\\"-\\\")} inst_mps={prog.get(\\\"interval_mps\\\",\\\"-\\\")} avg_mps={prog.get(\\\"moving_avg_mps\\\",\\\"-\\\")}')\" 2>/dev/null || (test -f $artifact_q/status.json && cat $artifact_q/status.json || echo 'no status.json'); echo; printf '\\033[1;36m=== SUMMARY ===\\033[0m\\n'; test -f $artifact_q/summary.json && python3 -c \"import json; d=json.load(open('$ARTIFACT_DIR/summary.json')); lat=d.get('latency',{}); print(f'  messages={d[\\\"throughput\\\"][\\\"messages\\\"]}  eps={d[\\\"throughput\\\"][\\\"throughput_mps\\\"]:.3f}M'); print(f'  p50={lat[\\\"p50_ns\\\"]}ns  p90={lat[\\\"p90_ns\\\"]}ns  p99={lat[\\\"p99_ns\\\"]}ns  p999={lat[\\\"p999_ns\\\"]}ns  max={lat[\\\"max_ns\\\"]}ns'); print(f'  jitter={d[\\\"throughput\\\"][\\\"throughput_jitter_mps\\\"]:.4f}  cv={lat.get(\\\"coefficient_of_variation\\\",0):.4f}')\" 2>/dev/null || echo 'no summary.json yet'; echo; printf '\\033[1;33m=== STDOUT (last 15) ===\\033[0m\\n'; tail -n 15 $artifact_q/stress.stdout.log 2>/dev/null || echo '-'; echo; printf '\\033[1;31m=== STDERR (last 10) ===\\033[0m\\n'; tail -n 10 $artifact_q/stress.stderr.log 2>/dev/null || echo '-'; echo; printf '\\033[1;32m=== LAST 10 REPLAYS ===\\033[0m\\n'; ls -1 $artifact_q/replays 2>/dev/null | tail -n 10 || echo '-'; sleep 1; done" C-m

  # ── window 3: shell ──
  tmux new-window -t "$SESSION_NAME" -n shell
  tmux send-keys -t "$SESSION_NAME:shell" "cd $root_q" C-m

  # ── window 4: replays ──
  tmux new-window -t "$SESSION_NAME" -n replays
  tmux set-option -t "$SESSION_NAME:replays" history-limit 20
  tmux send-keys -t "$SESSION_NAME:replays" \
    "cd $root_q && while true; do clear; printf '\\033[1;36m=== REPLAY FILES ===\\033[0m\\n'; find $artifact_q/replays -name '*.pr42' 2>/dev/null | sort -V | tail -n 60 || echo 'no replays'; sleep 2; done" C-m

  # select the monitor window
  tmux select-window -t "$SESSION_NAME:monitor"
  if [[ "$ATTACH_ON_START" == "1" ]]; then
    tmux attach-session -t "$SESSION_NAME"
  else
    echo "started detached session: $SESSION_NAME"
  fi
}

case "${1:-}" in
  start)
    start_session
    ;;
  attach)
    exec tmux attach-session -t "$SESSION_NAME"
    ;;
  stop)
    exec tmux kill-session -t "$SESSION_NAME"
    ;;
  *)
    usage
    exit 1
    ;;
esac
