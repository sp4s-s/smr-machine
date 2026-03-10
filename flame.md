# Flamegraph Workflow

## Purpose

Use this workflow when you want sampled stacks for `spsc_bench` on macOS.

- `xctrace` produces a native Instruments `.trace` bundle.
- `samply` produces a `profile.json.gz` file that opens in Firefox Profiler and uploads cleanly to [flamegraph.com](https://flamegraph.com/).
- `trace_event.json` remains the portable timeline artifact from this repo.

## Prerequisites

Build with debug info enabled so sampled stacks symbolize cleanly:

```bash
cmake -S . -B build -G Ninja -DSMR_MACHINE_ENABLE_DEBUG_INFO=ON
cmake --build build --target spsc_bench
```

Or with the Makefile:

```bash
make cpp
```

Confirm the profilers are present:

```bash
command -v xctrace
command -v samply
```

`xctrace` ships with Xcode / Xcode Command Line Tools. `samply` is documented at [mstange/samply](https://github.com/mstange/samply).

## One Command

```bash
./scripts/profile_bench.sh
```

Equivalent build targets:

```bash
make flame-report
cmake --build build --target flame_report
```

Default outputs land in `build/flame/`:

- `spsc_bench.trace`: `xctrace` Time Profiler bundle for Instruments
- `spsc_bench.samply.json.gz`: sampled profile for Firefox Profiler / flamegraph.com
- `spsc_bench.trace_event.json`: portable timeline trace from the benchmark itself
- `spsc_bench.timeline.csv`: interval throughput samples
- `spsc_bench.raw_metrics.txt`: benchmark summary metrics
- `spsc_bench.xctrace.log`: `xctrace` CLI log
- `spsc_bench.samply.log`: `samply` CLI log

Useful overrides:

```bash
PROFILE_DURATION_SEC=60 PROFILE_LANES=8 PROFILE_STRESS_THREADS=4 ./scripts/profile_bench.sh
OUT_DIR="$PWD/build/flame-heavy" PROFILE_SAMPLE_RATE=4000 ./scripts/profile_bench.sh
```

## View In Instruments

Open the native `.trace` bundle:

```bash
open build/flame/spsc_bench.trace
```

Or from the CLI:

```bash
xctrace examine build/flame/spsc_bench.trace
```

Inside Instruments, switch to the call tree or flame graph views to inspect hot stacks.

## View In Firefox Profiler

Load the `samply` profile locally:

```bash
samply load build/flame/spsc_bench.samply.json.gz
```

This serves the profile locally and opens the Firefox Profiler UI. `samply record` and `samply load` are documented in the [samply README](https://github.com/mstange/samply).

## View In flamegraph.com

Upload the `samply` output:

```text
build/flame/spsc_bench.samply.json.gz
```

[flamegraph.com](https://flamegraph.com/) accepts `pprof`, `json`, and collapsed formats, so the `samply` JSON profile is the correct artifact to upload there.

## View In Magic Trace

There are two different cases here:

### 1. Best-effort import from this macOS workflow

The only portable artifact from this repo that is even plausible to try in a Perfetto-style viewer is:

```text
build/flame/spsc_bench.trace_event.json
```

That file is a timeline trace, not a sampled stack flamegraph. It is useful for lanes, counters, backlog, and thread activity. If you want a reliable viewer for it, use [Perfetto UI](https://ui.perfetto.dev/).

### 2. Native Magic Trace capture

Native Magic Trace does **not** use `xctrace` bundles or `samply` JSON. The documented Magic Trace workflow captures a `trace.fxt.gz` file with `magic-trace`, and the upstream project documents that it is Linux-only and requires supported Intel hardware. See [janestreet/magic-trace](https://github.com/janestreet/magic-trace).

If you move this benchmark to a supported Linux host, the native workflow is:

```bash
./build/spsc_bench --duration-sec 300 --capacity 1024 --lanes 4 &
magic-trace attach -pid $!
# wait for steady state, then Ctrl-C magic-trace
```

That produces `trace.fxt.gz`, which opens in [magic-trace.org](https://magic-trace.org/).

## Notes

- `xctrace` and `samply` both perturb runtime. Use them for hotspot discovery, not final latency numbers.
- If `xctrace` fails with cache or permission errors, run it from a normal terminal session outside restricted sandboxes.
- On macOS, `samply` works best on binaries you built yourself; that matches this repo's C++ executables.
