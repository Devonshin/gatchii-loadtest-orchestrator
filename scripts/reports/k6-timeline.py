#!/usr/bin/env python3
"""k6 timeline report generator.

Reads k6 JSON output (line-delimited JSON objects emitted by `k6 run --out json=...`) and
optionally the k6 console log to extract:
- Insufficient VUs timestamps
- Threshold-crossed timestamps
- dropped_iterations spikes (per-second deltas)

This script intentionally avoids external dependencies.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple


def _parse_iso_time(s: str) -> dt.datetime:
    # k6 outputs RFC3339/ISO8601 with offset, e.g. 2026-01-10T22:50:38+01:00
    # It may also output Z; Python's fromisoformat doesn't accept 'Z'.
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return dt.datetime.fromisoformat(s)


def _floor_to_second(t: dt.datetime) -> dt.datetime:
    return t.replace(microsecond=0)


@dataclass(frozen=True)
class LogEvent:
    time: str
    kind: str
    message: str


def parse_k6_log_events(log_path: str) -> List[LogEvent]:
    events: List[LogEvent] = []

    # Examples:
    # time="2026-01-10T22:43:17+01:00" level=warning msg="Insufficient VUs, reached 3000 active VUs and cannot initialize more" ...
    # time="2026-01-10T22:50:38+01:00" level=error msg="thresholds on metrics 'http_req_duration' have been crossed"
    time_re = re.compile(r'time="([^"]+)"')

    def add(kind: str, line: str) -> None:
        m = time_re.search(line)
        if not m:
            return
        events.append(LogEvent(time=m.group(1), kind=kind, message=line.strip()))

    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if "Insufficient VUs" in line:
                add("insufficient_vus", line)
            elif "thresholds on metrics" in line and "have been crossed" in line:
                add("threshold_crossed", line)

    return events


def parse_k6_json_metrics(json_path: str) -> Tuple[Dict[dt.datetime, float], Dict[dt.datetime, float]]:
    """Return per-second series for dropped_iterations and vus.

    Notes:
    - In k6 JSON output, `dropped_iterations` is declared as a counter metric, but emitted Point values
      are typically *increments* (event-like) rather than a monotonically increasing total.
      So we aggregate dropped iterations by summing Point values per second.
    - For `vus` we keep the max value seen in each second.
    """

    dropped_count_by_sec: Dict[dt.datetime, float] = {}
    vus_by_sec: Dict[dt.datetime, float] = {}

    with open(json_path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError:
                continue

            if obj.get("type") != "Point":
                continue

            metric = obj.get("metric")
            data = obj.get("data") or {}
            time_s = data.get("time")
            value = data.get("value")
            if time_s is None or value is None:
                continue

            try:
                t = _floor_to_second(_parse_iso_time(str(time_s)))
            except Exception:
                continue

            try:
                v = float(value)
            except Exception:
                continue

            if metric == "dropped_iterations":
                # Treat Point values as increments; accumulate per second.
                dropped_count_by_sec[t] = dropped_count_by_sec.get(t, 0.0) + v
            elif metric == "vus":
                prev = vus_by_sec.get(t)
                if prev is None or v > prev:
                    vus_by_sec[t] = v

    return dropped_count_by_sec, vus_by_sec


@dataclass(frozen=True)
class DropSpike:
    sec: dt.datetime
    dropped: float
    vus: Optional[float]


def compute_dropped_spikes(
    dropped_count_by_sec: Dict[dt.datetime, float],
    vus_by_sec: Dict[dt.datetime, float],
) -> List[DropSpike]:
    """Return per-second dropped spikes.

    We treat dropped_count_by_sec as per-second counts (already aggregated).
    """
    spikes: List[DropSpike] = []
    for sec, cnt in dropped_count_by_sec.items():
        if cnt <= 0:
            continue
        spikes.append(DropSpike(sec=sec, dropped=cnt, vus=vus_by_sec.get(sec)))

    spikes.sort(key=lambda s: s.sec)
    return spikes


def format_dt(t: dt.datetime) -> str:
    # Preserve offset info if present (it will be in t.tzinfo).
    return t.isoformat()


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--json", required=True, help="Path to k6 JSON output file (from --out json=...)")
    p.add_argument("--log", required=False, help="Optional path to k6 console log file")
    p.add_argument("--title", required=False, default="k6 timeline", help="Report title")
    p.add_argument("--top", type=int, default=20, help="Top N dropped spikes to show")
    p.add_argument(
        "--spike-threshold",
        type=float,
        default=10.0,
        help="Per-second dropped_iterations delta threshold to form contiguous spike segments",
    )
    p.add_argument("--out", required=False, help="Output file path (defaults to stdout)")
    args = p.parse_args(argv)

    dropped_count_by_sec, vus_by_sec = parse_k6_json_metrics(args.json)
    spikes = compute_dropped_spikes(dropped_count_by_sec, vus_by_sec)

    events: List[LogEvent] = []
    if args.log:
        try:
            events = parse_k6_log_events(args.log)
        except FileNotFoundError:
            events = []

    # Compute totals + coverage
    total_dropped = sum(dropped_count_by_sec.values()) if dropped_count_by_sec else 0.0

    # Coverage window should not depend on dropped-only points.
    all_secs = sorted(set(dropped_count_by_sec.keys()) | set(vus_by_sec.keys()))
    first_time: Optional[dt.datetime] = all_secs[0] if all_secs else None
    last_time: Optional[dt.datetime] = all_secs[-1] if all_secs else None

    first_drop_sec: Optional[dt.datetime] = None
    if spikes:
        first_drop_sec = min(s.sec for s in spikes)

    # Compute top spikes (largest per-second dropped counts)
    top_spikes = sorted(spikes, key=lambda s: s.dropped, reverse=True)[: args.top]

    # Compute contiguous spike segments (per-second dropped >= threshold)
    segments: List[Tuple[dt.datetime, dt.datetime, float, float]] = []
    # (start, end, sum_dropped, max_dropped)
    threshold = float(args.spike_threshold)
    if spikes:
        spikes_by_sec = {s.sec: s for s in spikes if s.dropped >= threshold}
        secs = sorted(spikes_by_sec.keys())
        if secs:
            cur_start = secs[0]
            cur_end = secs[0]
            cur_sum = spikes_by_sec[secs[0]].dropped
            cur_max = spikes_by_sec[secs[0]].dropped

            for sec in secs[1:]:
                prev = cur_end
                if (sec - prev).total_seconds() <= 1:
                    cur_end = sec
                    d = spikes_by_sec[sec].dropped
                    cur_sum += d
                    cur_max = max(cur_max, d)
                else:
                    segments.append((cur_start, cur_end, cur_sum, cur_max))
                    cur_start = sec
                    cur_end = sec
                    cur_sum = spikes_by_sec[sec].dropped
                    cur_max = spikes_by_sec[sec].dropped

            segments.append((cur_start, cur_end, cur_sum, cur_max))

    lines: List[str] = []
    lines.append(f"# {args.title}")
    lines.append("")
    lines.append(f"- json: `{args.json}`")
    if args.log:
        lines.append(f"- log: `{args.log}`")
    if first_time and last_time:
        lines.append(f"- covered: {format_dt(first_time)} -> {format_dt(last_time)}")
    lines.append(f"- dropped_iterations total (approx): {int(total_dropped)}")
    if first_drop_sec:
        lines.append(f"- first dropped second: {format_dt(first_drop_sec)}")

    if events:
        lines.append("")
        lines.append("## Key log events")
        for e in events:
            # Keep it readable; the full line is included.
            lines.append(f"- {e.time} [{e.kind}] {e.message}")

    lines.append("")
    lines.append(f"## Top {len(top_spikes)} dropped spikes (per-second counts)")
    if not top_spikes:
        lines.append("- (no drops detected in JSON stream)")
    else:
        for s in top_spikes:
            vus_part = f", vus={int(s.vus)}" if s.vus is not None else ""
            lines.append(f"- {format_dt(s.sec)}: {int(s.dropped)} drops/s{vus_part}")

    lines.append("")
    lines.append(f"## Spike segments (per-second drops >= {int(threshold)} drops/s)")
    if not segments:
        lines.append("- (no spike segments)")
    else:
        for start, end, sum_dropped, max_dropped in segments:
            dur = int((end - start).total_seconds()) + 1
            lines.append(
                f"- {format_dt(start)} -> {format_dt(end)} ({dur}s): sum={int(sum_dropped)} drops, max={int(max_dropped)}/s"
            )

    out = "\n".join(lines) + "\n"

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(out)
    else:
        sys.stdout.write(out)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
