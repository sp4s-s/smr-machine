# State Replication Machine Walkthrough

## 1. Configure and build

Run from the repository root:

```bash
mkdir -p build
cmake -S . -B build -G Ninja -DSMR_MACHINE_ENABLE_CCACHE=ON -DSMR_MACHINE_ENABLE_DUNE_CACHE=ON
cmake --build build --target all_smr_machine
ctest --test-dir build --output-on-failure
```

This generates:

- `build/spsc_bench`
- `build/command_stress`
- `build/generate_scenario`
- `_build/default/ocaml/bin/deterministic_cli.exe`

## 2. Replay the deterministic incident

Use the wrapper so the command works from the repo root or from `build/`:

```bash
bash scripts/deterministic_cli.sh replay examples/loss_scenario.pr42 --checkpoint 2 --rollback-seq 6
```

What it does:

- replays the scenario
- checkpoints every 2 commands
- stops at the injected failure
- rolls back to sequence 6

## 3. Run the low-level SPSC benchmark with live movement

`spsc_bench` does not generate market orders. It now emits live `progress_*` counters during the run so you can watch real throughput and backlog from the actual workload.

```bash
./build/spsc_bench \
  --duration-sec 10 \
  --capacity 1024 \
  --lanes 4 \
  --stress-threads 2 \
  --stress-bytes 33554432 \
  --report-interval-ms 250 \
  --timeline-csv build/spsc_bench.timeline.csv \
  --latency-histogram-csv build/spsc_bench.latency_histogram.csv \
  --trace-event-json build/spsc_bench.trace_event.json
```

During the run you will see:

- `progress_elapsed_ms`
- `progress_produced`
- `progress_consumed`
- `progress_backlog`
- `progress_interval_mps`

## 4. Run the mixed market stress with real live order flow

This is the full market-style workload. It emits real order lifecycle events, failures, replay bundles, latency metrics, and portable traces.

```bash
lua scripts/run_trading_stress.lua \
  --artifact-dir build/trading_terminal \
  --duration-sec 60 \
  --capacity 4096 \
  --lanes 12 \
  --stress-threads 8 \
  --stress-bytes 134217728 \
  --report-interval-ms 250 \
  --failure-limit 250 \
  --replay-window 5000 \
  --submit-weight 28 \
  --modify-weight 30 \
  --cancel-weight 22 \
  --fill-weight 18 \
  --fail-weight 2 \
  --invalid-bps 15 \
  --seed 123
```

Important behavior:

- the artifact directory is reset first, so reruns start clean
- stdout/stderr are captured live into the artifact logs
- `status.json` is updated while the run is active and now includes the live run configuration plus progress counters
- `raw_events.jsonl` remains the canonical full log for the terminal
- `raw_events.stream.jsonl` is the fast incremental feed used by the live monitor while generation is running

## 5. Watch the live order terminal

In another shell:

```bash
lua scripts/order_terminal.lua \
  --event-log build/trading_terminal/raw_events.jsonl \
  --event-stream-log build/trading_terminal/raw_events.stream.jsonl \
  --status-json build/trading_terminal/status.json \
  --run-history-jsonl build/trading_terminal/run_history.jsonl \
  --refresh-ms 100
```

Keys:

- `q` or `x`: exit the monitor
- `Ctrl-X`: kill the whole tmux session from the monitor window

If the stress run truncates the event log for a fresh start, the terminal resets automatically instead of carrying old counters forward.

While the run is active, the monitor now renders:

- `RUN STATE`: lanes, stress threads, capacity, duration, failure limit, seed, and weights
- `PROGRESS`: elapsed time, produced/consumed counts, succeeded/failed counts, backlog, and instant/moving-average throughput
- live order-flow tables fed by the incremental stream log instead of waiting for the full log scan alone

## 6. Start the tmux trading terminal

```bash
chmod +x scripts/trading_terminal_tmux.sh
SESSION_NAME=trading-terminal \
ARTIFACT_DIR="$PWD/build/trading_terminal" \
AUTO_RUN=1 \
RUN_ARGS="--duration-sec 1800 --lanes 16 --stress-threads 10 --failure-limit 250000 --seed 123" \
./scripts/trading_terminal_tmux.sh start
```

What opens:

- `monitor` window: Lua order terminal over the full log plus the fast stream log
- `runner` window: managed Lua runner or manual `command_stress` launch
- `status` window: live run config, live progress, status/log tail
- `shell` window: repo shell
- `replays` window: replay bundle list

Operational notes:

- starting again with the same `SESSION_NAME` replaces the old session
- artifacts are wiped by default for a fresh run
- set `RESET_ARTIFACTS=0` to preserve previous outputs
- default tmux mode is monitor-only; set `AUTO_RUN=1` when you want the Lua runner to start `command_stress`
- set `ATTACH_ON_START=0` to launch detached, then attach later

Attach or stop later:

```bash
SESSION_NAME=trading-terminal ./scripts/trading_terminal_tmux.sh attach
SESSION_NAME=trading-terminal ./scripts/trading_terminal_tmux.sh stop
```

Deprecated note:

- `scripts/order_terminal.py` and `scripts/run_trading_stress.py` remain only as deprecated reference implementations

## 7. Replay one of the generated failures

After a stress run:

```bash
find build/trading_terminal/replays -name '*.pr42' | sort -V | tail
bash scripts/deterministic_cli.sh replay build/trading_terminal/replays/failure_1_lane_0.pr42 --checkpoint 4 --rollback-seq 12 --max-failures 2
```

Some remaining 
```
lua scripts/order_terminal.lua \
  --event-log build/trading_terminal/raw_events.jsonl \
  --status-json build/trading_terminal/status.json \
  --run-history-jsonl build/trading_terminal/run_history.jsonl \
  --refresh-ms 100

chmod +x scripts/trading_terminal_tmux.sh
SESSION_NAME=trading-terminal \
ARTIFACT_DIR="$PWD/build/trading_terminal" \
AUTO_RUN=1 \
RUN_ARGS="--duration-sec 1800 --lanes 16 --stress-threads 10 --failure-limit 250000 --seed 123" \
./scripts/trading_terminal_tmux.sh start
```

## 8. Profiling and trace upload targets

For the full file map and which outputs go to Perfetto, Magic Trace, and Instruments, see [artifact_reference.md](/Users/spass/ws/smr-machine/docs/artifact_reference.md).
