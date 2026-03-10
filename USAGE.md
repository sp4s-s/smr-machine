# Usage Guide

## Preferred Workflow

```bash
./scripts/bootstrap_deps.sh --install
mkdir -p build
cd build
cmake .. -G Ninja -DSMR_MACHINE_ENABLE_CCACHE=ON -DSMR_MACHINE_ENABLE_DUNE_CACHE=ON
cmake --build . --target all_smr_machine
ctest --output-on-failure
cmake --build . --target integration
```

This keeps generated files inside `build/`, enables `ccache` when available, and enables dune cache for the OCaml build.

Dependency bootstrap options:

- `./scripts/bootstrap_deps.sh --install`
- `make bootstrap`
- `cmake --build build --target bootstrap_deps`

Check-only variants:

- `./scripts/bootstrap_deps.sh --check`
- `make deps-check`
- `cmake --build build --target deps_check`

The root `Makefile` still works if you want the old workflow.
If `cmake` is not installed on the host, use the root `Makefile`.

## Configure Once In `build/`

```bash
mkdir -p build
cd build
cmake .. -G Ninja -DSMR_MACHINE_ENABLE_CCACHE=ON -DSMR_MACHINE_ENABLE_DUNE_CACHE=ON
```

If you want `make` in `build/` instead of Ninja:

```bash
mkdir -p build
cd build
cmake .. -G "Unix Makefiles" -DSMR_MACHINE_ENABLE_CCACHE=ON -DSMR_MACHINE_ENABLE_DUNE_CACHE=ON
```

## Build Everything

From the repository root:

```bash
cmake --build build --target all_smr_machine
```

From inside `build/`:

```bash
cmake --build . --target all_smr_machine
```

If you configured with `Unix Makefiles`, `make -j` inside `build/` also works.

## Run Tests

From the repository root:

```bash
ctest --test-dir build --output-on-failure
```

From inside `build/`:

```bash
ctest --output-on-failure
```

## Run Cross-Language Integration Check

```bash
cmake --build build --target integration
```

This generates [generated_from_cpp.pr42](/Users/spass/ws/smr-machine/examples/generated_from_cpp.pr42) from the C++ ring-buffer pipeline and replays it through the OCaml engine.

## Root Makefile Compatibility

The legacy commands still work from the repository root:

```bash
make all
make test
make integration
```

The root Makefile now also enables dune cache automatically and uses `ccache` for C++ when available.

## Replay a Failure Scenario

```bash
./scripts/deterministic_cli.sh replay examples/loss_scenario.pr42 --checkpoint 2 --rollback-seq 6
```

Expected behavior:

- events are replayed sequentially;
- checkpoints are emitted every two commands;
- replay stops on the injected failure;
- rollback prints the last checkpoint at or before sequence `6`.

To continue until multiple failures are seen before stopping:

```bash
./scripts/deterministic_cli.sh \
  replay build/trading_terminal/replays/failure_1_lane_1.pr42 \
  --checkpoint 4 \
  --rollback-seq 12 \
  --max-failures 2
```

## Benchmark the SPSC Queue

```bash
./build/spsc_bench --messages 1000000 --capacity 1024
```

Key outputs:

- `elapsed_ns`: total wall-clock time.
- `ns_per_message`: coarse latency per transferred event.
- `throughput_mps`: throughput in millions of messages per second.

For sustained thermal pressure and graphable latency/throughput behavior on a multicore Mac:

```bash
./build/spsc_bench \
  --duration-sec 300 \
  --capacity 1024 \
  --lanes 4 \
  --stress-threads 2 \
  --stress-bytes 33554432 \
  --report-interval-ms 1000 \
  --timeline-csv build/m4_timeline.csv
```

Additional outputs:

- `latency_p50_ns`, `latency_p55_ns`, `latency_p90_ns`, `latency_p95_ns`, `latency_p99_ns`, `latency_p999_ns`, `latency_p9999_ns`
- `timeline_csv`: interval throughput samples for plotting throttling or burst patterns

Portable artifact options:

- `--latency-histogram-csv build/latency_histogram.csv`
- `--trace-event-json build/trace_event.json`

## Run Mixed Command Stress

```bash
./build/command_stress \
  --duration-sec 20 \
  --capacity 4096 \
  --lanes 8 \
  --stress-threads 4 \
  --stress-bytes 134217728 \
  --report-interval-ms 10 \
  --failure-limit 100000 \
  --replay-window 5000 \
  --submit-weight 28 \
  --modify-weight 30 \
  --cancel-weight 22 \
  --fill-weight 18 \
  --fail-weight 2 \
  --invalid-bps 15 \
  --seed 99 \
  --summary-json build/command_stress_artifacts/summary.json \
  --timeline-csv build/command_stress_artifacts/timeline.csv \
  --trace-event-json build/command_stress_artifacts/trace_event.json \
  --raw-events-jsonl build/command_stress_artifacts/raw_events.jsonl \
  --replay-dir build/command_stress_artifacts/replays
```

Key outputs:

- `summary_json`: structured metrics for latency mean/stddev, p50/p75/p90/p95/p99/p999, throughput, jitter, and dropped-after-threshold commands.
- `timeline_csv`: interval `produced/consumed/succeeded/failed/backlog/interval_mps/moving_avg_mps`.
- `trace_event_json`: portable trace for Perfetto and Magic Trace JSON upload paths.
- `raw_events_jsonl`: per-event live stream for terminal monitoring and post-run forensics.
- `replay_dir`: `.pr42` windows for the first failures, ready to replay via the OCaml CLI.

Useful knobs:

- `--messages N` or `--duration-sec SEC`
- `--failure-limit N`
- `--submit-weight`, `--modify-weight`, `--cancel-weight`, `--fill-weight`, `--fail-weight`
- `--invalid-bps` to inject bad cancels/fills/modifies
- `--seed` for deterministic randomized runs

The duration-based runner is intentionally less uniform than before:

- order sizes are volatile, ranging from micro lots to large bursts;
- price levels are asset-anchored and noisy;
- mixes shift over the life of the run, so open/session/cancel-storm phases are different;
- IDs are asset-prefixed, for example `AAPL-l3-18291`.

## Live Order Terminal

Primary monitor path:

```bash
lua scripts/order_terminal.lua \
  --event-log build/command_stress_artifacts/raw_events.jsonl \
  --refresh-ms 100
```

Monitor with status and prior-run history:

```bash
lua scripts/order_terminal.lua \
  --event-log build/trading_terminal/raw_events.jsonl \
  --event-stream-log build/trading_terminal/raw_events.stream.jsonl \
  --status-json build/trading_terminal/status.json \
  --run-history-jsonl build/trading_terminal/run_history.jsonl \
  --refresh-ms 100
```

This managed-monitor path now:

- auto-detects a fresh managed run from `status.json` and resets its in-memory state
- consumes `raw_events.stream.jsonl` for faster live movement while `raw_events.jsonl` remains the canonical full log
- renders a `RUN STATE` block with live generation parameters and `PROGRESS` counters from the runner

Keys:

- `q` or `x`: exit the monitor pane
- `Ctrl-X`: kill the whole tmux session from the monitor
- when the event log is truncated for a fresh run, the terminal now resets automatically

Status labels:

- `ACTIVE`: stress runner is currently executing.
- `IDLE`: no active run, last known run completed successfully.
- `ERROR`: last managed run exited non-zero or status file is invalid.
- `SYSTEM OFF`: no managed terminal status file is present.

## Tmux Trading Terminal

Start the full terminal with tmux windows:

```bash
chmod +x scripts/trading_terminal_tmux.sh
SESSION_NAME=trading-terminal \
ARTIFACT_DIR="$PWD/build/trading_terminal" \
AUTO_RUN=1 \
RUN_ARGS="--duration-sec 1800 --lanes 16 --stress-threads 10 --failure-limit 250000 --seed 123" \
./scripts/trading_terminal_tmux.sh start
```

Behavior:

- `start` now replaces any existing session with the same name
- artifacts under `ARTIFACT_DIR` are reset by default so reruns start fresh
- set `RESET_ARTIFACTS=0` if you want to preserve the previous run
- default tmux layout is monitor-only; set `AUTO_RUN=1` when you want the Lua runner to launch a managed stress run

What it opens:

- window `monitor`: Lua live order terminal over `raw_events.jsonl` plus `raw_events.stream.jsonl`
- window `runner`: managed Lua runner or a manual `command_stress` launch surface
- window `status`: live run config, live progress, stdout/stderr, and replay tail
- window `shell`: interactive shell in the repo
- window `replays`: continuously updated replay file listing

Deprecated:

- `scripts/order_terminal.py` is deprecated
- `scripts/run_trading_stress.py` is deprecated

Reattach later:

```bash
SESSION_NAME=trading-terminal ./scripts/trading_terminal_tmux.sh attach
```

Stop the tmux session:

```bash
SESSION_NAME=trading-terminal ./scripts/trading_terminal_tmux.sh stop
```

Run the managed stress runner without tmux:

```bash
lua scripts/run_trading_stress.lua \
  --artifact-dir build/trading_terminal \
  --duration-sec 1800 \
  --lanes 16 \
  --stress-threads 10 \
  --failure-limit 250000 \
  --seed 123
```

To verify both monitor surfaces against the same live generation run, start the managed tmux session and a second standalone terminal in parallel:

```bash
chmod +x scripts/trading_terminal_tmux.sh
SESSION_NAME=trading-terminal \
ARTIFACT_DIR="$PWD/build/trading_terminal" \
AUTO_RUN=1 \
RUN_ARGS="--duration-sec 1800 --lanes 16 --stress-threads 10 --failure-limit 250000 --seed 123" \
./scripts/trading_terminal_tmux.sh start
```

```bash
lua scripts/order_terminal.lua \
  --event-log build/trading_terminal/raw_events.jsonl \
  --event-stream-log build/trading_terminal/raw_events.stream.jsonl \
  --status-json build/trading_terminal/status.json \
  --run-history-jsonl build/trading_terminal/run_history.jsonl \
  --refresh-ms 100
```

Deprecated:

- this managed Python runner is being retired in favor of a Lua replacement

To capture a real macOS Time Profiler trace around the same workload:

```bash
xctrace record \
  --template "Time Profiler" \
  --output build/command_stress.trace \
  --launch -- ./build/command_stress \
    --duration-sec 30 \
    --lanes 4 \
    --failure-limit 3 \
    --summary-json build/command_stress_artifacts/summary.json \
    --timeline-csv build/command_stress_artifacts/timeline.csv \
    --trace-event-json build/command_stress_artifacts/trace_event.json \
    --raw-events-jsonl build/command_stress_artifacts/raw_events.jsonl \
    --replay-dir build/command_stress_artifacts/replays
```
New one if fails early
```bash
rm -rf build/command_stress.trace
xctrace record \
  --template "Time Profiler" \
  --output build/command_stress.trace \
  --launch -- ./build/command_stress \
    --duration-sec 30 \
    --lanes 4 \
    --failure-limit 99999999 \
    --summary-json build/command_stress_artifacts/summary.json \
    --timeline-csv build/command_stress_artifacts/timeline.csv \
    --trace-event-json build/command_stress_artifacts/trace_event.json \
    --raw-events-jsonl build/command_stress_artifacts/raw_events.jsonl \
    --replay-dir build/command_stress_artifacts/replays

# or use a fresh output path each time:
--output build/command_stress_$(date +%Y%m%d_%H%M%S).trace

```

Optional Plotly visualization:

```bash
python3 -m pip install plotly
python3 scripts/plot_stress_metrics.py \
  --summary-json build/command_stress_artifacts/summary.json \
  --timeline-csv build/command_stress_artifacts/timeline.csv \
  --output-html build/command_stress_artifacts/report.html
```

## Generate Benchmark Table

```bash
cmake --build build --target bench_report
```

The root Makefile equivalent is `make bench-report`.

This writes a small markdown report to [bench_results.md](/Users/spass/ws/smr-machine/docs/bench_results.md).

## Run Profiling Helper

```bash
./scripts/profile_bench.sh
```

On macOS, the script now generates:

- `xctrace` Time Profiler output for Instruments
- `samply` JSON for Firefox Profiler and flamegraph.com
- `trace_event.json` for portable timeline viewers

In restricted environments where Instruments cannot create its cache directories, the `xctrace` step may fail while the other artifacts still succeed.

Useful environment overrides:

- `PROFILE_DURATION_SEC=60` or `300`
- `PROFILE_LANES=4`
- `PROFILE_STRESS_THREADS=2`
- `PROFILE_STRESS_BYTES=33554432`
- `PROFILE_INTERVAL_MS=1000`
- `PROFILE_SAMPLE_RATE=4000`

See [flame.md](/Users/spass/ws/smr-machine/flame.md) for the full flamegraph workflow, including Instruments, Firefox Profiler, Magic Trace caveats, and flamegraph.com upload instructions.

## Generate Flamegraph Artifacts

```bash
cmake --build build --target flame_report
```

The root Makefile equivalent is `make flame-report`.

## Generate a Stress Report

```bash
cmake --build build --target stress_report
```

The root Makefile equivalent is `make stress-report`.

This writes:

- [stress_report.md](/Users/spass/ws/smr-machine/build/stress_report/stress_report.md): run summary with latency percentiles and reproduction command
- [raw_metrics.txt](/Users/spass/ws/smr-machine/build/stress_report/raw_metrics.txt): raw key/value metrics
- [timeline.csv](/Users/spass/ws/smr-machine/build/stress_report/timeline.csv): interval throughput data for charts

## Generate a Portable Performance Report

```bash
cmake --build build --target perf_report
```

The root Makefile equivalent is `make perf-report`.

This writes:

- [perf_report.md](/Users/spass/ws/smr-machine/build/perf_report/perf_report.md): run summary and reproduction command
- [raw_metrics.txt](/Users/spass/ws/smr-machine/build/perf_report/raw_metrics.txt): raw key/value metrics
- [timeline.csv](/Users/spass/ws/smr-machine/build/perf_report/timeline.csv): interval throughput samples
- [latency_histogram.csv](/Users/spass/ws/smr-machine/build/perf_report/latency_histogram.csv): latency distribution buckets
- [trace_event.json](/Users/spass/ws/smr-machine/build/perf_report/trace_event.json): Chrome/Perfetto-style event trace for off-host viewers

`trace_event.json` is the portable artifact to copy off the Mac. It should open in Perfetto and other Chrome trace viewers. Compatibility with Jane Street Magic Trace is not guaranteed from this macOS workflow, but this is the closest export path currently available in the project.

## Run DTrace Timing Probe

```bash
sudo dtrace -s scripts/profile_bench.bt -c "./build/spsc_bench --messages 2000000 --capacity 1024"
```

This prints an end-to-end runtime in nanoseconds from a DTrace probe attached to `main`.

## Docker

Build the Linux container:

```bash
docker build -t smr-machine .
```

Run an interactive shell with the workspace mounted:

```bash
docker run --rm -it -v "$PWD":/workspace -w /workspace smr-machine
```

Inside the container:

```bash
mkdir -p build
cd build
cmake .. -G Ninja -DSMR_MACHINE_ENABLE_CCACHE=ON -DSMR_MACHINE_ENABLE_DUNE_CACHE=ON
cmake --build . --target all_smr_machine
ctest --output-on-failure
```

The container enables `ccache` and dune cache by default.

## Event Script Format

One command per line:

```text
SUBMIT <ts_ns> <id> <trader> <BUY|SELL> <qty> <px>
MODIFY <ts_ns> <id> <qty> <px>
CANCEL <ts_ns> <id>
FILL <ts_ns> <id> <qty> <px>
FAIL <ts_ns> <reason...>
```

Comments begin with `#`.

## Typical Demo Flow

```bash
mkdir -p build
cd build
cmake .. -G Ninja -DSMR_MACHINE_ENABLE_CCACHE=ON -DSMR_MACHINE_ENABLE_DUNE_CACHE=ON
cmake --build . --target all_smr_machine
ctest --output-on-failure
cd ..
dune exec ./ocaml/bin/deterministic_cli.exe -- replay examples/loss_scenario.pr42 --checkpoint 2 --rollback-seq 4
cmake --build build --target integration
dune exec ./ocaml/bin/deterministic_cli.exe -- replay examples/generated_from_cpp.pr42 --checkpoint 2 --rollback-seq 4
cmake --build build --target bench_report
./scripts/profile_bench.sh
```
