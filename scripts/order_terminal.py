import argparse
import json
import os
import select
import subprocess
import sys
import termios
import time
import tty
from collections import Counter, defaultdict, deque
from pathlib import Path


def safe_int(value, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def rel_time_ms(ns: int | None, origin_ns: int | None) -> str:
    if ns is None or origin_ns is None:
        return "-"
    if ns < origin_ns:
        return "-"
    return f"{(ns - origin_ns) / 1_000_000:.3f}ms"


class InputWatcher:
    def __init__(self):
        self.stdin_fd = sys.stdin.fileno() if sys.stdin.isatty() else None

    def read_key(self) -> str | None:
        if self.stdin_fd is None:
            return None
        readable, _, _ = select.select([sys.stdin], [], [], 0)
        if not readable:
            return None
        return sys.stdin.read(1)


def exit_monitor() -> int:
    if os.environ.get("TMUX"):
        try:
            session = subprocess.check_output(
                ["tmux", "display-message", "-p", "#S"],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
            if session:
                subprocess.run(["tmux", "kill-session", "-t", session], check=False)
        except Exception:
            pass
    return 0


class MonitorState:
    def __init__(self, recent_limit: int):
        self.recent_limit = recent_limit
        self.reset()

    def reset(self) -> None:
        self.total = 0
        self.failed = 0
        self.dropped = 0
        self.by_type = Counter()
        self.by_asset = defaultdict(lambda: {"events": 0, "fills": 0, "buy_qty": 0, "sell_qty": 0, "open_orders": 0})
        self.by_lane = Counter()
        self.by_trader = Counter()
        self.open_orders = {}
        self.failures = deque(maxlen=12)
        self.recent = deque(maxlen=self.recent_limit)
        self.positions = defaultdict(lambda: {"qty": 0, "cash": 0.0, "last_px": 0, "fills": 0})
        self.last_px_by_asset = {}
        self.total_open_notional = 0.0
        self.total_open_qty = 0
        self.start_observed_ns = None
        self.last_observed_ns = None

    def apply(self, event: dict) -> None:
        self.total += 1
        status = event.get("status", "")
        event_type = event.get("type", "")
        asset = event.get("asset", "UNKNOWN")
        trader = event.get("trader", "unknown")
        lane = event.get("lane", -1)
        order_id = event.get("id", "")
        qty = safe_int(event.get("qty", 0))
        px = safe_int(event.get("px", 0))
        remaining = safe_int(event.get("remaining_qty", 0))
        side = event.get("side", "BUY")
        observed_ns = safe_int(event.get("observed_ns"), None)
        ts_ns = safe_int(event.get("ts_ns"), None)

        if observed_ns is not None:
            self.last_observed_ns = observed_ns
            if self.start_observed_ns is None:
                self.start_observed_ns = observed_ns

        self.by_type[event_type] += 1
        self.by_lane[lane] += 1
        if trader:
            self.by_trader[trader] += 1
        self.by_asset[asset]["events"] += 1

        if status == "failed":
            self.failed += 1
            self.failures.appendleft(event)
        elif status == "dropped":
            self.dropped += 1

        if status == "ok":
            if event_type == "SUBMIT":
                stored = dict(event)
                stored["submitted_ns"] = ts_ns
                stored["remaining_qty"] = remaining or qty
                self.open_orders[order_id] = stored
            elif event_type == "MODIFY":
                if order_id in self.open_orders:
                    self.open_orders[order_id].update(dict(event))
                    self.open_orders[order_id]["remaining_qty"] = remaining
            elif event_type == "FILL":
                self.by_asset[asset]["fills"] += 1
                self.last_px_by_asset[asset] = px
                if side == "BUY":
                    self.by_asset[asset]["buy_qty"] += qty
                    self.positions[asset]["qty"] += qty
                    self.positions[asset]["cash"] -= qty * px
                else:
                    self.by_asset[asset]["sell_qty"] += qty
                    self.positions[asset]["qty"] -= qty
                    self.positions[asset]["cash"] += qty * px
                self.positions[asset]["last_px"] = px
                self.positions[asset]["fills"] += 1
                if remaining > 0:
                    if order_id in self.open_orders:
                        self.open_orders[order_id].update(dict(event))
                        self.open_orders[order_id]["remaining_qty"] = remaining
                    else:
                        stored = dict(event)
                        stored["submitted_ns"] = ts_ns
                        self.open_orders[order_id] = stored
                else:
                    self.open_orders.pop(order_id, None)
            elif event_type == "CANCEL":
                self.open_orders.pop(order_id, None)

        self.by_asset[asset]["open_orders"] = sum(
            1 for order in self.open_orders.values() if order.get("asset") == asset
        )
        self.total_open_notional = sum(
            safe_int(order.get("remaining_qty", 0)) * safe_int(order.get("px", 0)) for order in self.open_orders.values()
        )
        self.total_open_qty = sum(safe_int(order.get("remaining_qty", 0)) for order in self.open_orders.values())
        self.recent.appendleft(event)

    def throughput_eps(self) -> float:
        if self.start_observed_ns is None or self.last_observed_ns is None or self.last_observed_ns <= self.start_observed_ns:
            return 0.0
        elapsed_sec = (self.last_observed_ns - self.start_observed_ns) / 1_000_000_000
        return self.total / elapsed_sec if elapsed_sec > 0 else 0.0

    def mark_to_market(self) -> tuple[float, float, float, int]:
        profit = 0.0
        loss = 0.0
        net = 0.0
        gross_inventory = 0
        for asset, position in self.positions.items():
            last_px = self.last_px_by_asset.get(asset, position["last_px"])
            mtm = position["cash"] + (position["qty"] * last_px)
            net += mtm
            gross_inventory += abs(position["qty"])
            if mtm >= 0:
                profit += mtm
            else:
                loss += -mtm
        return profit, loss, net, gross_inventory


def tail_events(path: Path, state: MonitorState, offset: int) -> tuple[int, bool]:
    if not path.exists():
        return offset, False
    size = path.stat().st_size
    if size < offset:
        state.reset()
        offset = 0
    with path.open("r", encoding="utf-8") as handle:
        handle.seek(offset)
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            state.apply(event)
        new_offset = handle.tell()
        return new_offset, new_offset != offset


def render_lines(state: MonitorState, event_log: Path, status: dict, last_runs: list[dict]) -> list[str]:
    width = os.get_terminal_size().columns if os.isatty(1) else 120
    left_width = max(40, width // 2 - 2)
    right_width = max(40, width - left_width - 3)
    profit, loss, net_pnl, gross_inventory = state.mark_to_market()

    header = [
        f"order_terminal  log={event_log}",
        "keys: q/ctrl-x/r/ctrl-c close pane",
        f"STATUS={status.get('label', 'SYSTEM OFF')}",
        (
            f"events={state.total} failed={state.failed} dropped={state.dropped} "
            f"open_orders={len(state.open_orders)} eps={state.throughput_eps():.1f}"
        ),
        (
            f"inventory={gross_inventory} open_qty={state.total_open_qty} "
            f"in_trade_notional={state.total_open_notional:.0f} profit={profit:.0f} "
            f"loss={loss:.0f} net={net_pnl:.0f}"
        ),
        ""
    ]

    asset_lines = ["ASSETS"]
    for asset, stats in sorted(state.by_asset.items(), key=lambda kv: (-kv[1]["events"], kv[0]))[:12]:
        asset_lines.append(
            f"{asset:<6} ev={stats['events']:<6} open={stats['open_orders']:<4} "
            f"in={stats['buy_qty']:<6} out={stats['sell_qty']:<6} fills={stats['fills']:<4}"
        )
    if len(asset_lines) == 1:
        asset_lines.append("waiting for live events")

    lane_lines = ["LANES / TRADERS / BOOK"]
    for lane, count in state.by_lane.most_common(8):
        lane_lines.append(f"lane {lane:<2} events={count}")
    lane_lines.append("")
    for trader, count in state.by_trader.most_common(8):
        lane_lines.append(f"{trader:<8} events={count}")
    lane_lines.append("")
    lane_lines.append("POSITIONS")
    for asset, position in sorted(state.positions.items(), key=lambda kv: (-abs(kv[1]["qty"]), kv[0]))[:8]:
        mtm = position["cash"] + (position["qty"] * state.last_px_by_asset.get(asset, position["last_px"]))
        lane_lines.append(
            f"{asset:<6} qty={position['qty']:<6} last={state.last_px_by_asset.get(asset, position['last_px']):<5} "
            f"cash={position['cash']:<9.0f} mtm={mtm:<8.0f}"
        )

    recent_lines = ["RECENT EVENTS"]
    for event in list(state.recent)[:16]:
        event_time = rel_time_ms(safe_int(event.get("observed_ns"), None), state.start_observed_ns)
        recent_lines.append(
            f"{event_time:>9} {event.get('status','?'):<7} {event.get('type','?'):<6} "
            f"{event.get('asset','?'):<6} {event.get('id',''):<22.22} "
            f"q={event.get('qty',0):<4} px={event.get('px',0):<4} rem={event.get('remaining_qty',0):<4}"
        )
    if len(recent_lines) == 1:
        recent_lines.append("no events observed in current run")

    open_order_lines = ["WORKING ORDERS"]
    for order in sorted(
        state.open_orders.values(),
        key=lambda row: safe_int(row.get("submitted_ns", 0)),
        reverse=True,
    )[:10]:
        submitted = rel_time_ms(safe_int(order.get("submitted_ns"), None), state.start_observed_ns)
        open_order_lines.append(
            f"{submitted:>9} {order.get('asset','?'):<6} {order.get('side','?'):<4} "
            f"{order.get('id',''):<18.18} rem={order.get('remaining_qty',0):<6} px={order.get('px',0):<5}"
        )
    if len(open_order_lines) == 1:
        open_order_lines.append("no working orders")

    failure_lines = ["FAILURES"]
    for event in list(state.failures)[:10]:
        failure_lines.append(
            f"lane={event.get('lane','?'):<2} seq={event.get('seq','?'):<6} "
            f"{event.get('type','?'):<6} {event.get('reason','')}"
        )
    if len(failure_lines) == 1:
        failure_lines.append("no failures captured")

    last_run_lines = ["LAST RUNS"]
    for run in last_runs[:6]:
        last_run_lines.append(
            f"{run.get('ended_at','?'):<19} {run.get('state','?'):<5} "
            f"msg={run.get('messages','?'):<8} fail={run.get('failures','?'):<6} "
            f"mps={run.get('throughput_mps','?')}"
        )
    if len(last_run_lines) == 1:
        last_run_lines.append("no managed runs recorded yet")

    left = asset_lines + [""] + recent_lines + [""] + open_order_lines
    right = lane_lines + [""] + failure_lines + [""] + last_run_lines

    rows = max(len(left), len(right))
    lines = header
    for i in range(rows):
        lhs = left[i] if i < len(left) else ""
        rhs = right[i] if i < len(right) else ""
        lines.append(f"{lhs[:left_width]:<{left_width}} | {rhs[:right_width]:<{right_width}}")
    return lines


def load_status(path: Path | None) -> dict:
    if path is None or not path.exists():
        return {"label": "SYSTEM OFF", "state": "off"}
    try:
        payload = json.loads(path.read_text())
    except Exception:
        return {"label": "ERROR", "state": "error", "message": "invalid status file"}
    state = payload.get("state", "idle")
    if state == "active":
        payload["label"] = "ACTIVE"
    elif state == "error":
        payload["label"] = "ERROR"
    else:
        payload["label"] = "IDLE"
    return payload


def load_last_runs(path: Path | None, limit: int = 6) -> list[dict]:
    if path is None or not path.exists():
        return []
    rows = deque(maxlen=limit)
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        return []
    return list(reversed(rows))


def main() -> int:
    parser = argparse.ArgumentParser(description="Tail command_stress raw events and render a live order terminal.")
    parser.add_argument("--event-log", required=True, help="Path to raw event JSONL emitted by command_stress")
    parser.add_argument("--status-json", help="Optional status JSON written by the trading terminal runner")
    parser.add_argument("--run-history-jsonl", help="Optional JSONL history of prior runs")
    parser.add_argument("--refresh-ms", type=int, default=500, help="Refresh period in milliseconds")
    parser.add_argument("--recent-limit", type=int, default=64, help="Buffered recent event count")
    args = parser.parse_args()

    event_log = Path(args.event_log)
    status_json = Path(args.status_json) if args.status_json else None
    run_history_jsonl = Path(args.run_history_jsonl) if args.run_history_jsonl else None
    state = MonitorState(recent_limit=args.recent_limit)
    watcher = InputWatcher()
    offset = 0
    fd = None
    original_termios = None

    if sys.stdin.isatty():
        fd = sys.stdin.fileno()
        original_termios = termios.tcgetattr(fd)
        tty.setcbreak(fd)

    try:
        needs_render = True
        wait_chunk_sec = 0.05
        last_status_mtime_ns = None
        last_history_mtime_ns = None
        while True:
            if needs_render:
                offset, changed = tail_events(event_log, state, offset)
                status = load_status(status_json)
                last_runs = load_last_runs(run_history_jsonl)
                print("\x1b[2J\x1b[H", end="")
                print("\n".join(render_lines(state, event_log, status, last_runs)))
                sys.stdout.flush()
                needs_render = False
            key = watcher.read_key()
            if key in {"q", "Q", "\x18", "r", "R"}:
                return exit_monitor()

            time.sleep(wait_chunk_sec)
            event_changed = False
            offset, event_changed = tail_events(event_log, state, offset)
            status_mtime_ns = status_json.stat().st_mtime_ns if status_json and status_json.exists() else None
            history_mtime_ns = (
                run_history_jsonl.stat().st_mtime_ns if run_history_jsonl and run_history_jsonl.exists() else None
            )
            status_changed = status_mtime_ns != last_status_mtime_ns
            history_changed = history_mtime_ns != last_history_mtime_ns
            last_status_mtime_ns = status_mtime_ns
            last_history_mtime_ns = history_mtime_ns
            if event_changed or status_changed or history_changed:
                needs_render = True
    except KeyboardInterrupt:
        return exit_monitor()
    finally:
        if fd is not None and original_termios is not None:
            termios.tcsetattr(fd, termios.TCSADRAIN, original_termios)


if __name__ == "__main__":
    raise SystemExit(main())
