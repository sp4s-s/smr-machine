
import argparse
import csv
import json
from pathlib import Path

import plotly.graph_objects as go
from plotly.subplots import make_subplots


def load_timeline(path: Path):
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def main() -> int:
    parser = argparse.ArgumentParser(description="Render command_stress metrics as a Plotly HTML report.")
    parser.add_argument("--summary-json", required=True, help="Path to command_stress summary JSON")
    parser.add_argument("--timeline-csv", required=True, help="Path to command_stress timeline CSV")
    parser.add_argument("--output-html", required=True, help="Path to output HTML file")
    args = parser.parse_args()

    summary_path = Path(args.summary_json)
    timeline_path = Path(args.timeline_csv)
    output_path = Path(args.output_html)

    summary = json.loads(summary_path.read_text())
    timeline = load_timeline(timeline_path)

    elapsed_ms = [float(row["elapsed_ms"]) for row in timeline]
    interval_mps = [float(row["interval_mps"]) for row in timeline]
    moving_avg_mps = [float(row["moving_avg_mps"]) for row in timeline]
    backlog = [int(row["backlog"]) for row in timeline]
    failed = [int(row["failed"]) for row in timeline]
    succeeded = [int(row["succeeded"]) for row in timeline]

    figure = make_subplots(
        rows=3,
        cols=1,
        shared_xaxes=True,
        subplot_titles=("Throughput", "Backlog / Failures", "Cumulative Outcomes"),
        vertical_spacing=0.08,
    )
    figure.add_trace(
        go.Scatter(x=elapsed_ms, y=interval_mps, mode="lines+markers", name="Interval MPS"),
        row=1,
        col=1,
    )
    figure.add_trace(
        go.Scatter(x=elapsed_ms, y=moving_avg_mps, mode="lines", name="Moving Avg MPS"),
        row=1,
        col=1,
    )
    figure.add_trace(
        go.Bar(x=elapsed_ms, y=backlog, name="Backlog"),
        row=2,
        col=1,
    )
    figure.add_trace(
        go.Scatter(x=elapsed_ms, y=failed, mode="lines+markers", name="Failures"),
        row=2,
        col=1,
    )
    figure.add_trace(
        go.Scatter(x=elapsed_ms, y=succeeded, mode="lines", name="Succeeded"),
        row=3,
        col=1,
    )
    figure.add_annotation(
        xref="paper",
        yref="paper",
        x=0.0,
        y=1.1,
        showarrow=False,
        align="left",
        text=(
            "messages={messages} | throughput_mps={throughput:.3f} | p99_ns={p99} | failures={failures} | "
            "dropped_after_limit={dropped}"
        ).format(
            messages=summary["throughput"]["messages"],
            throughput=summary["throughput"]["throughput_mps"],
            p99=summary["latency"]["p99_ns"],
            failures=len(summary["failures"]),
            dropped=summary["throughput"].get("dropped_after_failure_limit", 0),
        ),
    )
    figure.update_layout(
        title="command_stress metrics",
        template="plotly_white",
        height=950,
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="left", x=0),
    )
    figure.update_xaxes(title_text="Elapsed ms", row=3, col=1)
    figure.update_yaxes(title_text="MPS", row=1, col=1)
    figure.update_yaxes(title_text="Count", row=2, col=1)
    figure.update_yaxes(title_text="Count", row=3, col=1)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    figure.write_html(output_path, include_plotlyjs="cdn")
    print(f"wrote={output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
