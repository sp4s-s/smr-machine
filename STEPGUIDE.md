# Step Guide

## 1. Configure

```bash
cmake -S . -B build -G Ninja -DSMR_MACHINE_ENABLE_CCACHE=ON -DSMR_MACHINE_ENABLE_DUNE_CACHE=OFF
```

Output:

```text
-- Configuring done
-- Generating done
-- Build files have been written to: /Users/spass/ws/smr-machine/build
```

## 2. Build everything

```bash
cmake --build build --target all_smr_machine
```

Output:

```text
[1/4] Building CXX object CMakeFiles/spsc_bench.dir/cpp/src/spsc_bench.cpp.o
[2/4] Linking CXX executable spsc_bench
[3/4] Building CXX object CMakeFiles/command_stress.dir/cpp/src/command_stress.cpp.o
[4/4] Linking CXX executable command_stress
```

## 3. Run tests

```bash
ctest --test-dir build --output-on-failure
```

Output:

```text
1/3 Test #1: cpp_spsc_tests ........ Passed
2/3 Test #2: ocaml_dune_runtest .... Passed
3/3 Test #3: integration_replay .... Passed
100% tests passed, 0 tests failed out of 3
```

## 4. Replay the sample incident

```bash
bash scripts/deterministic_cli.sh replay examples/loss_scenario.pr42 --checkpoint 2 --rollback-seq 6
```

Output:

```text
failure: seq=7 reason=venue-disconnect-loss-check
rollback:
snapshot seq=6 hash=005a868354d39e3e7d4b3e924ff1fa5b
```

## 5. Run the raw benchmark with live counters

```bash
./build/spsc_bench --duration-sec 1 --capacity 1024 --lanes 2 --stress-threads 1 --stress-bytes 1048576 --report-interval-ms 100 --timeline-csv /tmp/spsc-bench.timeline.csv --latency-histogram-csv /tmp/spsc-bench.hist.csv --trace-event-json /tmp/spsc-bench.trace.json
```

Output:

```text
progress_elapsed_ms=105.013
progress_produced=1076396
progress_consumed=1074360
progress_backlog=2036
progress_interval_mps=10.764
```

## 6. Run mixed market stress directly

```bash
./build/command_stress --duration-sec 1 --lanes 2 --stress-threads 1 --failure-limit 5 --report-interval-ms 100 --summary-json /tmp/command-stress.summary.json --timeline-csv /tmp/command-stress.timeline.csv --trace-event-json /tmp/command-stress.trace.json --raw-events-jsonl /tmp/command-stress.events.jsonl --replay-dir /tmp/command-stress.replays
```

Output:

```text
progress_elapsed_ms=105.009
progress_produced=1899
progress_succeeded=83
progress_failed=5
raw_events_jsonl=/tmp/command-stress.events.jsonl
```

## 7. Watch the order terminal against an existing event file

```bash
lua scripts/order_terminal.lua --event-log /tmp/command-stress.events.jsonl --refresh-ms 100
```

Use `q` or `x` to close the pane. Use `Ctrl-X` from tmux to kill the full session.

## 8. Managed live runner with status/history

```bash
lua scripts/run_trading_stress.lua --artifact-dir build/trading_terminal --duration-sec 60 --lanes 12 --stress-threads 8 --failure-limit 250 --report-interval-ms 250 --seed 123
```

Alternative monitor command:

```bash
lua scripts/order_terminal.lua --event-log build/trading_terminal/raw_events.jsonl --status-json build/trading_terminal/status.json --run-history-jsonl build/trading_terminal/run_history.jsonl --refresh-ms 100
```

For the fast live feed during generation, include the stream log as well:

```bash
lua scripts/order_terminal.lua --event-log build/trading_terminal/raw_events.jsonl --event-stream-log build/trading_terminal/raw_events.stream.jsonl --status-json build/trading_terminal/status.json --run-history-jsonl build/trading_terminal/run_history.jsonl --refresh-ms 100
```

## 9. Tmux monitor-only layout

```bash
SESSION_NAME=trading-terminal ARTIFACT_DIR="$PWD/build/trading_terminal" AUTO_RUN=0 ./scripts/trading_terminal_tmux.sh start
```

This opens separate tmux windows for the monitor, runner, status, shell, and replays. Start `./build/command_stress ...` or `lua scripts/run_trading_stress.lua ...` manually in the `runner` window.

## 10. Tmux managed-run layout

```bash
SESSION_NAME=trading-terminal ARTIFACT_DIR="$PWD/build/trading_terminal" AUTO_RUN=1 RUN_ARGS="--duration-sec 1800 --lanes 16 --stress-threads 10 --failure-limit 250000 --seed 123" ./scripts/trading_terminal_tmux.sh start
```

The tmux monitor now renders live run parameters and progress, and the status window shows the same generation config and counters from `status.json`.

Reattach / stop:

```bash
SESSION_NAME=trading-terminal ./scripts/trading_terminal_tmux.sh attach
SESSION_NAME=trading-terminal ./scripts/trading_terminal_tmux.sh stop
```

## 11. Interrupt a managed run once

Use `Ctrl-X` from the monitor window to tear down the tmux session quickly. The Lua runner writes `status.json`, `run_history.jsonl`, and the standard artifact set on normal completion.

## 12. Artifact reference

See [artifact_reference.md](/Users/spass/ws/smr-machine/docs/artifact_reference.md) for what each file is for and which ones go to Perfetto, Magic Trace, and macOS Instruments.

For sampled flamegraphs with `xctrace` and `samply`, see [flame.md](/Users/spass/ws/smr-machine/flame.md).
