#!/usr/bin/env python3
"""Summarize docker container metrics CSV.

Input: CSV from docker-container-metrics.sh
Output: Markdown with min/avg/max for cpu_pct, mem_used bytes, pids.

We parse size strings like:
- 12.3MiB, 1GiB, 900kB, 123B
- CPU like: 12.34%
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from typing import List, Optional, Tuple


def parse_cpu_pct(s: str) -> Optional[float]:
    s = (s or "").strip()
    if not s:
        return None
    if s.endswith("%"):
        s = s[:-1]
    try:
        return float(s)
    except ValueError:
        return None


def parse_bytes(s: str) -> Optional[float]:
    s = (s or "").strip()
    if not s:
        return None

    # Normalize
    s = s.replace(" ", "")

    # Split number + unit
    num = ""
    unit = ""
    for ch in s:
        if ch.isdigit() or ch == ".":
            num += ch
        else:
            unit += ch

    if num == "":
        return None

    try:
        v = float(num)
    except ValueError:
        return None

    unit = unit or "B"

    # Decimal units
    dec = {
        "B": 1,
        "kB": 1e3,
        "MB": 1e6,
        "GB": 1e9,
        "TB": 1e12,
    }
    # Binary units
    binu = {
        "KiB": 1024,
        "MiB": 1024**2,
        "GiB": 1024**3,
        "TiB": 1024**4,
    }

    if unit in dec:
        return v * dec[unit]
    if unit in binu:
        return v * binu[unit]

    # Some docker versions may use "k" style (rare) or lowercase.
    unit_u = unit.upper()
    if unit_u == "KB":
        return v * 1e3
    if unit_u == "MB":
        return v * 1e6
    if unit_u == "GB":
        return v * 1e9

    return None


def fmt_bytes(n: Optional[float]) -> str:
    if n is None:
        return ""
    # Use MiB for readability
    mib = n / (1024**2)
    return f"{mib:.2f} MiB"


def fmt_num(n: Optional[float]) -> str:
    if n is None:
        return ""
    if abs(n - round(n)) < 1e-9:
        return str(int(round(n)))
    return f"{n:.2f}"


@dataclass
class Stats:
    count: int = 0
    sum: float = 0.0
    min: Optional[float] = None
    max: Optional[float] = None

    def add(self, v: Optional[float]) -> None:
        if v is None:
            return
        self.count += 1
        self.sum += v
        self.min = v if self.min is None else min(self.min, v)
        self.max = v if self.max is None else max(self.max, v)

    def avg(self) -> Optional[float]:
        if self.count == 0:
            return None
        return self.sum / self.count


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("csv", help="Path to docker container metrics CSV")
    p.add_argument("--title", default="Docker container metrics")
    p.add_argument("--out", required=True)
    args = p.parse_args(argv)

    cpu = Stats()
    mem = Stats()
    pids = Stats()

    container = ""
    rows = 0

    with open(args.csv, "r", encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            rows += 1
            container = container or (r.get("container") or "")
            cpu.add(parse_cpu_pct(r.get("cpu_pct") or ""))
            mem.add(parse_bytes(r.get("mem_used") or ""))
            try:
                pids.add(float((r.get("pids") or "").strip()))
            except ValueError:
                pass

    lines: List[str] = []
    lines.append(f"# {args.title}")
    lines.append("")
    lines.append(f"- csv: `{args.csv}`")
    if container:
        lines.append(f"- container: `{container}`")
    lines.append(f"- rows: {rows}")

    lines.append("")
    lines.append("## CPU (%)")
    lines.append(f"- min={fmt_num(cpu.min)}%, avg={fmt_num(cpu.avg())}%, max={fmt_num(cpu.max)}%")

    lines.append("")
    lines.append("## Memory used")
    lines.append(f"- min={fmt_bytes(mem.min)}, avg={fmt_bytes(mem.avg())}, max={fmt_bytes(mem.max)}")

    lines.append("")
    lines.append("## PIDs")
    lines.append(f"- min={fmt_num(pids.min)}, avg={fmt_num(pids.avg())}, max={fmt_num(pids.max)}")

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
