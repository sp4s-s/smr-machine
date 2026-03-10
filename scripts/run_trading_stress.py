import argparse
import json
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n")


def append_jsonl(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload) + "\n")


def reset_artifacts(artifact_dir: Path) -> None:
    files_to_remove = (
        "status.json",
        "run_history.jsonl",
        "summary.json",
        "timeline.csv",
        "trace_event.json",
        "raw_events.jsonl",
        "stress.stdout.log",
        "stress.stderr.log",
    )
    for name in files_to_remove:
        path = artifact_dir / name
        if path.exists():
            path.unlink()
    replay_dir = artifact_dir / "replays"
    if replay_dir.exists():
        shutil.rmtree(replay_dir)


def parse_metrics(stdout: str) -> dict:
    metrics = {}
    for line in stdout.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        metrics[key.strip()] = value.strip()
    return metrics


def stream_pipe(
    pipe,
    log_path: Path,
    target,
    live_metrics: dict,
    status_json: Path,
    artifact_dir: Path,
    started_at: str,
) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as log_handle:
        for line in pipe:
            log_handle.write(line)
            log_handle.flush()
            target.write(line)
            target.flush()
            if target is sys.stdout and "=" in line:
                key, value = line.rstrip("\n").split("=", 1)
                live_metrics[key.strip()] = value.strip()
                if key.startswith("progress_"):
                    write_json(
                        status_json,
                        {
                            "state": "active",
                            "label": "ACTIVE",
                            "started_at": started_at,
                            "artifact_dir": str(artifact_dir),
                            "progress": {
                                "elapsed_ms": live_metrics.get("progress_elapsed_ms"),
                                "produced": live_metrics.get("progress_produced"),
                                "consumed": live_metrics.get("progress_consumed"),
                                "succeeded": live_metrics.get("progress_succeeded"),
                                "failed": live_metrics.get("progress_failed"),
                                "backlog": live_metrics.get("progress_backlog"),
                                "interval_mps": live_metrics.get("progress_interval_mps"),
                                "moving_avg_mps": live_metrics.get("progress_moving_avg_mps"),
                            },
                        },
                    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Run command_stress with trading-terminal status and history files.")
    parser.add_argument("--artifact-dir", required=True, help="Directory for status, logs, traces, and replays")
    parser.add_argument("--duration-sec", type=int, default=900)
    parser.add_argument("--capacity", type=int, default=4096)
    parser.add_argument("--lanes", type=int, default=12)
    parser.add_argument("--stress-threads", type=int, default=8)
    parser.add_argument("--stress-bytes", type=int, default=134217728)
    parser.add_argument("--report-interval-ms", type=int, default=10)
    parser.add_argument("--failure-limit", type=int, default=100000)
    parser.add_argument("--replay-window", type=int, default=5000)
    parser.add_argument("--submit-weight", type=int, default=28)
    parser.add_argument("--modify-weight", type=int, default=30)
    parser.add_argument("--cancel-weight", type=int, default=22)
    parser.add_argument("--fill-weight", type=int, default=18)
    parser.add_argument("--fail-weight", type=int, default=2)
    parser.add_argument("--invalid-bps", type=int, default=15)
    parser.add_argument("--seed", type=int, default=99)
    parser.add_argument("--command-stress-bin", default="./build/command_stress")
    parser.add_argument("extra", nargs="*", help="Extra flags appended to command_stress")
    args = parser.parse_args()

    artifact_dir = Path(args.artifact_dir)
    status_json = artifact_dir / "status.json"
    history_jsonl = artifact_dir / "run_history.jsonl"
    summary_json = artifact_dir / "summary.json"
    timeline_csv = artifact_dir / "timeline.csv"
    trace_json = artifact_dir / "trace_event.json"
    raw_events_jsonl = artifact_dir / "raw_events.jsonl"
    replay_dir = artifact_dir / "replays"
    stdout_log = artifact_dir / "stress.stdout.log"
    stderr_log = artifact_dir / "stress.stderr.log"
    reset_artifacts(artifact_dir)

    write_json(
        status_json,
        {
            "state": "active",
            "label": "ACTIVE",
            "started_at": now_iso(),
            "artifact_dir": str(artifact_dir),
        },
    )

    cmd = [
        args.command_stress_bin,
        "--duration-sec",
        str(args.duration_sec),
        "--capacity",
        str(args.capacity),
        "--lanes",
        str(args.lanes),
        "--stress-threads",
        str(args.stress_threads),
        "--stress-bytes",
        str(args.stress_bytes),
        "--report-interval-ms",
        str(args.report_interval_ms),
        "--failure-limit",
        str(args.failure_limit),
        "--replay-window",
        str(args.replay_window),
        "--submit-weight",
        str(args.submit_weight),
        "--modify-weight",
        str(args.modify_weight),
        "--cancel-weight",
        str(args.cancel_weight),
        "--fill-weight",
        str(args.fill_weight),
        "--fail-weight",
        str(args.fail_weight),
        "--invalid-bps",
        str(args.invalid_bps),
        "--seed",
        str(args.seed),
        "--summary-json",
        str(summary_json),
        "--timeline-csv",
        str(timeline_csv),
        "--trace-event-json",
        str(trace_json),
        "--raw-events-jsonl",
        str(raw_events_jsonl),
        "--replay-dir",
        str(replay_dir),
        *args.extra,
    ]

    started_at = now_iso()
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    live_metrics: dict[str, str] = {}
    stdout_thread = threading.Thread(
        target=stream_pipe,
        args=(proc.stdout, stdout_log, sys.stdout, live_metrics, status_json, artifact_dir, started_at),
    )
    stderr_thread = threading.Thread(
        target=stream_pipe,
        args=(proc.stderr, stderr_log, sys.stderr, live_metrics, status_json, artifact_dir, started_at),
    )
    stdout_thread.start()
    stderr_thread.start()
    interrupted = False
    try:
        returncode = proc.wait()
    except KeyboardInterrupt:
        interrupted = True
        if proc.poll() is None:
            proc.terminate()
            try:
                returncode = proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                returncode = proc.wait()
        else:
            returncode = proc.returncode
    stdout_thread.join()
    stderr_thread.join()
    metrics = dict(live_metrics)

    state = "idle" if returncode == 0 and not interrupted else "error"
    write_json(
        status_json,
        {
            "state": state,
            "label": "IDLE" if state == "idle" else "ERROR",
            "started_at": started_at,
            "ended_at": now_iso(),
            "returncode": returncode,
            "artifact_dir": str(artifact_dir),
            "messages": metrics.get("messages"),
            "failures": metrics.get("failures"),
            "throughput_mps": metrics.get("throughput_mps"),
            "interrupted": interrupted,
            "summary_json": str(summary_json),
            "raw_events_jsonl": str(raw_events_jsonl),
            "stderr_log": str(stderr_log),
        },
    )
    append_jsonl(
        history_jsonl,
        {
            "started_at": started_at,
            "ended_at": now_iso(),
            "state": state,
            "returncode": returncode,
            "messages": metrics.get("messages"),
            "failures": metrics.get("failures"),
            "throughput_mps": metrics.get("throughput_mps"),
            "artifact_dir": str(artifact_dir),
            "interrupted": interrupted,
        },
    )
    if interrupted:
        time.sleep(0.05)
    return returncode


if __name__ == "__main__":
    raise SystemExit(main())
