#!/usr/bin/env python3
"""performance_schema digest delta report.

Reads TSV snapshots produced by mysql-ps-digest-snapshot.sh (start/end) and writes a markdown report:
- Top digests by delta SUM_TIMER_WAIT
- Basic counts and totals

Timers are assumed to be in picoseconds (ps).
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple


@dataclass(frozen=True)
class DigestRow:
    digest: str
    count_star: int
    sum_timer_wait: int
    avg_timer_wait: int
    sum_rows_examined: int
    sum_rows_sent: int
    digest_text: str


def _to_int(s: str) -> int:
    s = (s or "").strip()
    if s == "":
        return 0
    try:
        return int(float(s))
    except ValueError:
        return 0


def read_snapshot(path: str) -> Tuple[Optional[str], Dict[str, DigestRow]]:
    rows: Dict[str, DigestRow] = {}
    ts: Optional[str] = None

    with open(path, "r", encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for r in reader:
            ts = ts or (r.get("ts") or None)
            digest = (r.get("DIGEST") or "").strip()
            if not digest:
                continue
            rows[digest] = DigestRow(
                digest=digest,
                count_star=_to_int(r.get("COUNT_STAR") or "0"),
                sum_timer_wait=_to_int(r.get("SUM_TIMER_WAIT") or "0"),
                avg_timer_wait=_to_int(r.get("AVG_TIMER_WAIT") or "0"),
                sum_rows_examined=_to_int(r.get("SUM_ROWS_EXAMINED") or "0"),
                sum_rows_sent=_to_int(r.get("SUM_ROWS_SENT") or "0"),
                digest_text=(r.get("DIGEST_TEXT") or "").strip(),
            )

    return ts, rows


def ps_to_ms(ps: int) -> float:
    # 1 ms = 1e9 ps
    return ps / 1_000_000_000.0


@dataclass(frozen=True)
class Delta:
    digest: str
    delta_sum_ps: int
    delta_count: int
    delta_rows_examined: int
    delta_rows_sent: int
    digest_text: str


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--start", required=True)
    p.add_argument("--end", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--title", default="MySQL performance_schema digest delta")
    p.add_argument("--top", type=int, default=20)
    args = p.parse_args(argv)

    start_ts, start = read_snapshot(args.start)
    end_ts, end = read_snapshot(args.end)

    deltas: List[Delta] = []

    all_digests = set(start.keys()) | set(end.keys())
    for d in all_digests:
        s = start.get(d)
        e = end.get(d)
        if e is None:
            continue

        ds = (e.sum_timer_wait - (s.sum_timer_wait if s else 0))
        dc = (e.count_star - (s.count_star if s else 0))
        dre = (e.sum_rows_examined - (s.sum_rows_examined if s else 0))
        drs = (e.sum_rows_sent - (s.sum_rows_sent if s else 0))

        if ds <= 0 and dc <= 0:
            continue

        deltas.append(
            Delta(
                digest=d,
                delta_sum_ps=ds,
                delta_count=dc,
                delta_rows_examined=dre,
                delta_rows_sent=drs,
                digest_text=e.digest_text,
            )
        )

    deltas.sort(key=lambda x: x.delta_sum_ps, reverse=True)
    top = deltas[: args.top]

    total_sum_ps = sum(d.delta_sum_ps for d in deltas)
    total_count = sum(d.delta_count for d in deltas)

    lines: List[str] = []
    lines.append(f"# {args.title}")
    lines.append("")
    lines.append(f"- start: `{args.start}` ({start_ts or 'unknown'})")
    lines.append(f"- end: `{args.end}` ({end_ts or 'unknown'})")
    lines.append("")
    lines.append(f"- total delta SUM_TIMER_WAIT: {ps_to_ms(total_sum_ps):.2f} ms")
    lines.append(f"- total delta COUNT_STAR: {total_count}")

    lines.append("")
    lines.append(f"## Top {len(top)} digests by delta SUM_TIMER_WAIT")
    if not top:
        lines.append("- (no deltas)")
    else:
        for d in top:
            text = d.digest_text.replace("\n", " ")
            if len(text) > 240:
                text = text[:240] + "…"
            lines.append(
                "- "
                + f"sum={ps_to_ms(d.delta_sum_ps):.2f} ms"
                + f", count={d.delta_count}"
                + f", rows_examined={d.delta_rows_examined}"
                + f", rows_sent={d.delta_rows_sent}"
                + f"\n  - digest={d.digest}"
                + (f"\n  - digest_text={text}" if text else "")
            )

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
