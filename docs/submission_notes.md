# Submission Notes

## What This Project Demonstrates

- low-latency systems programming in modern C++;
- deterministic state reconstruction and rollback in OCaml;
- cross-language system boundaries designed around reproducible artifacts;
- practical profiling discipline on macOS;
- portable performance artifacts for off-host inspection;
- engineering hygiene through tests, integration checks, and CI.

## Interview Framing

When presenting this project, lead with the system problem rather than the languages:

1. expensive-loss incidents need deterministic post-mortems;
2. hot-path event transport and audit-friendly replay have different design pressures;
3. C++ handles transfer latency, OCaml handles deterministic state evolution;
4. the shared incident script gives a stable bridge between the two.

## Defensible Tradeoffs

- SPSC rather than MPMC: chosen to keep the queue small, analyzable, and fast for a single ingest path.
- Snapshot checkpointing rather than delta logs only: chosen to make rollback immediate and easy to inspect.
- Text incident format rather than binary-first interchange: chosen for debuggability and portfolio readability, while leaving room for a binary capture format later.
- Weighted-average entry price model: chosen to keep replay accounting deterministic without implementing a full tax-lot engine.

## What To Say If Asked “What Would You Do Next?”

- add binary capture and zero-copy decoding between C++ and OCaml;
- persist checkpoints to mmap-backed storage;
- extend profiling with Linux perf or Magic Trace captures for true stack flamegraphs;
- introduce property tests for replay invariants.
