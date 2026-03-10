# Profiling Notes

## Local Constraints

This workspace is running on macOS, so the profiling workflow should be mac-native. The project uses:

- `xctrace` for Time Profiler captures;
- `samply` for sampled flamegraphs in Firefox Profiler and browser upload workflows;
- `sample` as a lightweight fallback snapshot;
- `dtrace` for simple timing probes;
- portable CSV and trace-event exports for off-host inspection.

## Benchmark Command

```bash
./build/spsc_bench --messages 2000000 --capacity 1024
```

## `xctrace`

```bash
xctrace record \
  --template "Time Profiler" \
  --output build/spsc_bench.trace \
  --launch -- ./build/spsc_bench --messages 2000000 --capacity 1024
```

Use this to inspect:

- time spent in producer/consumer hot paths;
- scheduler artifacts;
- unexpected library overhead.

The main target is still to show that queue transfer overhead stays comfortably within a sub-microsecond envelope per message under load.

## `samply`

```bash
samply record --save-only --no-open -o build/flame/spsc_bench.samply.json.gz \
  ./build/spsc_bench --duration-sec 30 --capacity 1024 --lanes 4
```

Load it locally with:

```bash
samply load build/flame/spsc_bench.samply.json.gz
```

This gives you sampled stacks in the Firefox Profiler UI and a JSON artifact you can upload to flamegraph.com. The upstream project is [mstange/samply](https://github.com/mstange/samply).

## `sample`

```bash
./build/spsc_bench --messages 20000000 --capacity 1024 &
sample $! 3 -file build/spsc_bench.sample.txt
```

This is less precise than `xctrace`, but useful for a fast sanity check that the benchmark is dominated by queue traffic rather than I/O or allocation.
If the benchmark exits before `sample` attaches, rerun with a larger `--messages` value or use `PROFILE_MESSAGES` / `SAMPLE_MESSAGES` with `scripts/profile_bench.sh`.
On some macOS configurations, `sample` may need elevated permissions to inspect the target process.

## Portable Artifacts

```bash
./build/spsc_bench \
  --duration-sec 30 \
  --capacity 1024 \
  --lanes 4 \
  --stress-threads 2 \
  --stress-bytes 33554432 \
  --report-interval-ms 250 \
  --timeline-csv build/perf_timeline.csv \
  --latency-histogram-csv build/perf_histogram.csv \
  --trace-event-json build/perf_trace_event.json
```

These files are meant for copying off the Mac:

- `timeline.csv`: interval throughput and backlog plots;
- `latency_histogram.csv`: latency distribution plots;
- `trace_event.json`: a Chrome/Perfetto-style event trace for portable viewers.

This JSON trace is portable, but it is not a sampled call-stack flamegraph. For true hot-stack inspection, use `xctrace`, `samply`, or `sample`.

## `dtrace`

End-to-end timing probe:

```bash
sudo dtrace -s scripts/profile_bench.bt -c "./build/spsc_bench --messages 2000000 --capacity 1024"
```

For deeper analysis, expose named producer/consumer routines in the benchmark and attach probes to those symbols.

## Magic Trace Compatibility

`xctrace` bundles, `samply` JSON, and `sample` output are not native Jane Street Magic Trace captures.

If you want the best current off-host export from this project on macOS, use `--trace-event-json` for timeline viewing and `samply` for flamegraphs. If you need a real Magic Trace capture, run the benchmark on a supported Linux/Intel host and capture `trace.fxt.gz` with `magic-trace`.

## Reporting Guidance

For a technical interview or write-up, report:

- CPU model and kernel version;
- compiler and optimization flags;
- message count and ring capacity;
- median and tail results across repeated runs;
- a brief interpretation of hot-stack concentration and scheduler noise.
