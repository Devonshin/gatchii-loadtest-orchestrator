#!/usr/bin/env python3
"""Compare two run directories (baseline vs current) and generate a markdown report.

This repository historically compared two ports (8890 vs 9890). For the platform use-case,
we instead compare the *same variant/runId* across two different executions (baseline vs current).

Inputs are directories like:
  .idea/.project-docs/<date>/runs/k6-mysql-<ts>/<variant>/
containing phase artifacts such as:
  - <phase>-k6.log
  - <phase>-app.summary.md
  - <phase>-mysql.summary.md
  - <phase>-mysql.digest.summary.md

This script intentionally avoids external dependencies.
"""

from __future__ import annotations

import argparse
import json
import os
import re
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple


@dataclass(frozen=True)
class K6Metrics:
    http_reqs: Optional[int] = None
    http_req_failed_rate: Optional[float] = None  # 0..1
    dropped_iterations: Optional[int] = None
    http_req_duration_avg_ms: Optional[float] = None
    http_req_duration_p95_ms: Optional[float] = None
    http_req_duration_p99_ms: Optional[float] = None


@dataclass(frozen=True)
class AppMetrics:
    cpu_avg_pct: Optional[float] = None
    cpu_max_pct: Optional[float] = None
    mem_avg_mib: Optional[float] = None
    mem_max_mib: Optional[float] = None


@dataclass(frozen=True)
class MysqlMetrics:
    threads_connected_avg: Optional[float] = None
    threads_running_avg: Optional[float] = None
    queries_rate_per_s: Optional[float] = None


@dataclass(frozen=True)
class MysqlDigest:
    total_sum_timer_ms: Optional[float] = None
    top1_sum_ms: Optional[float] = None
    top1_count: Optional[int] = None
    top1_digest_text: Optional[str] = None


@dataclass(frozen=True)
class PhaseData:
    phase: str
    k6: K6Metrics
    app: AppMetrics
    mysql: MysqlMetrics
    digest: MysqlDigest
    meta: Dict[str, str]


def _read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def _read_json(path: str) -> dict:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return json.load(f)


def _find_files_by_suffix(dir_path: str, suffix: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    for name in os.listdir(dir_path):
        if not name.endswith(suffix):
            continue
        # phase is the prefix before suffix, e.g. avg-k6.log -> avg
        phase = name[: -len(suffix)]
        out[phase] = os.path.join(dir_path, name)
    return out


_duration_re = re.compile(r"(?P<num>[0-9]+(?:\.[0-9]+)?)\s*(?P<unit>ns|µs|us|ms|s|m|h)")


def parse_duration_to_ms(raw: str) -> Optional[float]:
    s = (raw or "").strip()
    if not s:
        return None

    m = _duration_re.fullmatch(s)
    if not m:
        return None

    num = float(m.group("num"))
    unit = m.group("unit")

    if unit == "ns":
        return num / 1_000_000.0
    if unit in ("µs", "us"):
        return num / 1_000.0
    if unit == "ms":
        return num
    if unit == "s":
        return num * 1000.0
    if unit == "m":
        return num * 60_000.0
    if unit == "h":
        return num * 3_600_000.0

    return None


def _as_ms_from_summary_value(v: Optional[float]) -> Optional[float]:
    if v is None:
        return None
    # k6 summary-export duration values are typically seconds.
    # Use a conservative heuristic: if value looks like seconds (<= 10_000), convert to ms.
    if v <= 10_000:
        return v * 1000.0
    return v


def _parse_k6_summary_export(path: str) -> K6Metrics:
    obj = _read_json(path)
    metrics = obj.get("metrics") or {}

    def metric_values(name: str) -> dict:
        m = metrics.get(name) or {}
        return (m.get("values") or {})

    # http_req_duration
    dur = metric_values("http_req_duration")
    avg_ms = _as_ms_from_summary_value(dur.get("avg"))
    p95_ms = _as_ms_from_summary_value(dur.get("p(95)"))
    p99_ms = _as_ms_from_summary_value(dur.get("p(99)"))

    # counters
    http_reqs = metric_values("http_reqs").get("count")
    dropped = metric_values("dropped_iterations").get("count")

    # rates
    failed_rate = metric_values("http_req_failed").get("rate")

    return K6Metrics(
        http_reqs=int(http_reqs) if http_reqs is not None else None,
        http_req_failed_rate=float(failed_rate) if failed_rate is not None else None,
        dropped_iterations=int(dropped) if dropped is not None else None,
        http_req_duration_avg_ms=float(avg_ms) if avg_ms is not None else None,
        http_req_duration_p95_ms=float(p95_ms) if p95_ms is not None else None,
        http_req_duration_p99_ms=float(p99_ms) if p99_ms is not None else None,
    )


def _parse_k6_log_metrics(text: str) -> K6Metrics:
    # Example lines (k6 summary section):
    # dropped_iterations.............: 7184    29.529501/s
    # http_req_failed................: 0.00%   ✓ 0          ✗ 64817
    # http_req_duration..............: avg=3.77s ... p(95)=4.81s p(99)=...
    # http_reqs......................: 64817   266.427294/s

    def find_int(pattern: str) -> Optional[int]:
        m = re.search(pattern, text, flags=re.MULTILINE)
        if not m:
            return None
        try:
            return int(m.group(1))
        except ValueError:
            return None

    def find_float(pattern: str) -> Optional[float]:
        m = re.search(pattern, text, flags=re.MULTILINE)
        if not m:
            return None
        try:
            return float(m.group(1))
        except ValueError:
            return None

    # dropped_iterations (total count)
    dropped = find_int(r"^\s*dropped_iterations\.+:\s+([0-9]+)\b")

    # http_reqs (total)
    http_reqs = find_int(r"^\s*(?:[✓✗]?\s*)?http_reqs\.+:\s+([0-9]+)\b")

    # http_req_failed rate
    failed_pct = find_float(r"^\s*(?:[✓✗]?\s*)?http_req_failed\.+:\s+([0-9]+(?:\.[0-9]+)?)%")
    failed_rate = failed_pct / 100.0 if failed_pct is not None else None

    # http_req_duration avg/p95/p99
    avg_ms = None
    p95_ms = None
    p99_ms = None

    line_m = re.search(
        r"^\s*(?:[✓✗]?\s*)?http_req_duration\.+:\s+.*$",
        text,
        flags=re.MULTILINE,
    )
    if line_m:
        line = line_m.group(0)
        m_avg = re.search(r"avg=([^\s]+)", line)
        m_p95 = re.search(r"p\(95\)=([^\s]+)", line)
        m_p99 = re.search(r"p\(99\)=([^\s]+)", line)

        if m_avg:
            avg_ms = parse_duration_to_ms(m_avg.group(1))
        if m_p95:
            p95_ms = parse_duration_to_ms(m_p95.group(1))
        if m_p99:
            p99_ms = parse_duration_to_ms(m_p99.group(1))

    return K6Metrics(
        http_reqs=http_reqs,
        http_req_failed_rate=failed_rate,
        dropped_iterations=dropped,
        http_req_duration_avg_ms=avg_ms,
        http_req_duration_p95_ms=p95_ms,
        http_req_duration_p99_ms=p99_ms,
    )


def _parse_app_summary(text: str) -> AppMetrics:
    # Example:
    # ## CPU (%)
    # - min=78.91%, avg=100.28%, max=134.01%
    # ## Memory used
    # - min=259.50 MiB, avg=388.79 MiB, max=402.90 MiB

    cpu_m = re.search(r"^\s*-\s*min=.*?,\s*avg=([0-9]+(?:\.[0-9]+)?)%,\s*max=([0-9]+(?:\.[0-9]+)?)%\s*$", text, flags=re.MULTILINE)
    mem_m = re.search(r"^\s*-\s*min=.*?,\s*avg=([0-9]+(?:\.[0-9]+)?)\s*MiB,\s*max=([0-9]+(?:\.[0-9]+)?)\s*MiB\s*$", text, flags=re.MULTILINE)

    return AppMetrics(
        cpu_avg_pct=float(cpu_m.group(1)) if cpu_m else None,
        cpu_max_pct=float(cpu_m.group(2)) if cpu_m else None,
        mem_avg_mib=float(mem_m.group(1)) if mem_m else None,
        mem_max_mib=float(mem_m.group(2)) if mem_m else None,
    )


def _parse_mysql_summary(text: str) -> MysqlMetrics:
    # Example:
    # - Threads_connected: min=4, avg=11.96, max=12
    # - Threads_running: min=2, avg=2.25, max=4
    # - Queries: start=..., end=..., delta=..., rate=1150.24/s

    tc = re.search(r"Threads_connected: min=[^,]+, avg=([0-9]+(?:\.[0-9]+)?), max=", text)
    tr = re.search(r"Threads_running: min=[^,]+, avg=([0-9]+(?:\.[0-9]+)?), max=", text)
    qr = re.search(r"^\s*-\s*Queries: .*?rate=([0-9]+(?:\.[0-9]+)?)/s\s*$", text, flags=re.MULTILINE)

    return MysqlMetrics(
        threads_connected_avg=float(tc.group(1)) if tc else None,
        threads_running_avg=float(tr.group(1)) if tr else None,
        queries_rate_per_s=float(qr.group(1)) if qr else None,
    )


def _parse_mysql_digest_summary(text: str) -> MysqlDigest:
    # Example:
    # - total delta SUM_TIMER_WAIT: 63604.21 ms
    # ## Top ...
    # - sum=30246.56 ms, count=64816, ...
    #   - digest_text=SELECT ...

    total = re.search(r"total delta SUM_TIMER_WAIT: ([0-9]+(?:\.[0-9]+)?) ms", text)
    top1 = re.search(r"^\s*-\s*sum=([0-9]+(?:\.[0-9]+)?) ms, count=([0-9]+),", text, flags=re.MULTILINE)

    # Grab the first digest_text that appears after the first top line (best-effort).
    top_text = None
    if top1:
        # Find the digest_text line following the first top entry.
        m = re.search(r"^\s*-\s*digest_text=(.*)$", text, flags=re.MULTILINE)
        if m:
            top_text = m.group(1).strip()

    return MysqlDigest(
        total_sum_timer_ms=float(total.group(1)) if total else None,
        top1_sum_ms=float(top1.group(1)) if top1 else None,
        top1_count=int(top1.group(2)) if top1 else None,
        top1_digest_text=top_text,
    )


def _fmt_ms(x: Optional[float]) -> str:
    if x is None:
        return "-"
    if x >= 1000:
        return f"{x/1000.0:.2f}s"
    return f"{x:.2f}ms"


def _fmt_pct(x: Optional[float]) -> str:
    if x is None:
        return "-"
    return f"{x*100:.2f}%"


def _fmt_num(x: Optional[float]) -> str:
    if x is None:
        return "-"
    if abs(x - round(x)) < 1e-9:
        return str(int(round(x)))
    return f"{x:.2f}"


def _delta_pct(cur: Optional[float], base: Optional[float]) -> str:
    if cur is None or base is None:
        return "-"
    if base == 0:
        return "-"
    return f"{((cur - base) / base) * 100.0:+.1f}%"


def _aggregate_peak_steps(phases: Dict[str, PhaseData]) -> Dict[str, PhaseData]:
    """Aggregate peak-* phases into a single 'peak' phase.

    We keep avg/breakpoint untouched.
    Aggregation strategy (pragmatic for UI):
    - k6:
      - http_reqs / dropped_iterations: sum
      - http_req_failed_rate: weighted by http_reqs when possible
      - durations: worst (max) across steps
    - app:
      - cpu/mem: worst (max) across steps
    - mysql:
      - gauges/rates: worst (max) across steps
    - digest:
      - total_sum_timer_ms: sum
      - top1_sum_ms: max
    """

    peak_items: List[Tuple[int, PhaseData]] = []
    kept: Dict[str, PhaseData] = {}

    for name, pd in phases.items():
        m = re.match(r"^peak-(\d+)$", name)
        if m:
            peak_items.append((int(m.group(1)), pd))
        else:
            kept[name] = pd

    if not peak_items:
        return kept

    peak_items.sort(key=lambda x: x[0])
    steps = [r for r, _ in peak_items]

    def max_opt(vals: List[Optional[float]]) -> Optional[float]:
        xs = [v for v in vals if v is not None]
        return max(xs) if xs else None

    def sum_int(vals: List[Optional[int]]) -> Optional[int]:
        xs = [v for v in vals if v is not None]
        return int(sum(xs)) if xs else None

    # k6
    step_k6 = [pd.k6 for _, pd in peak_items]
    sum_reqs = sum_int([k.http_reqs for k in step_k6])
    sum_dropped = sum_int([k.dropped_iterations for k in step_k6])

    # weighted error rate
    weighted_fail = None
    if sum_reqs is not None and sum_reqs > 0:
        acc = 0.0
        have = False
        for k in step_k6:
            if k.http_reqs is None or k.http_req_failed_rate is None:
                continue
            acc += float(k.http_reqs) * float(k.http_req_failed_rate)
            have = True
        if have:
            weighted_fail = acc / float(sum_reqs)

    peak_k6 = K6Metrics(
        http_reqs=sum_reqs,
        dropped_iterations=sum_dropped,
        http_req_failed_rate=weighted_fail,
        http_req_duration_avg_ms=max_opt([k.http_req_duration_avg_ms for k in step_k6]),
        http_req_duration_p95_ms=max_opt([k.http_req_duration_p95_ms for k in step_k6]),
        http_req_duration_p99_ms=max_opt([k.http_req_duration_p99_ms for k in step_k6]),
    )

    # app/mysql/digest
    step_app = [pd.app for _, pd in peak_items]
    peak_app = AppMetrics(
        cpu_avg_pct=max_opt([a.cpu_avg_pct for a in step_app]),
        cpu_max_pct=max_opt([a.cpu_max_pct for a in step_app]),
        mem_avg_mib=max_opt([a.mem_avg_mib for a in step_app]),
        mem_max_mib=max_opt([a.mem_max_mib for a in step_app]),
    )

    step_mysql = [pd.mysql for _, pd in peak_items]
    peak_mysql = MysqlMetrics(
        threads_connected_avg=max_opt([m.threads_connected_avg for m in step_mysql]),
        threads_running_avg=max_opt([m.threads_running_avg for m in step_mysql]),
        queries_rate_per_s=max_opt([m.queries_rate_per_s for m in step_mysql]),
    )

    step_digest = [pd.digest for _, pd in peak_items]
    peak_digest = MysqlDigest(
        total_sum_timer_ms=(
            sum(d.total_sum_timer_ms for d in step_digest if d.total_sum_timer_ms is not None)
            if any(d.total_sum_timer_ms is not None for d in step_digest)
            else None
        ),
        top1_sum_ms=max_opt([d.top1_sum_ms for d in step_digest]),
        top1_count=None,
        top1_digest_text=None,
    )

    meta = {
        "peak_steps": " ".join(str(s) for s in steps),
        "peak_min": str(steps[0]),
        "peak_max": str(steps[-1]),
        "peak_step_count": str(len(steps)),
    }

    kept["peak"] = PhaseData(phase="peak", k6=peak_k6, app=peak_app, mysql=peak_mysql, digest=peak_digest, meta=meta)
    return kept


def load_phase_data(dir_path: str) -> Dict[str, PhaseData]:
    k6_logs = _find_files_by_suffix(dir_path, "-k6.log")
    k6_summaries = _find_files_by_suffix(dir_path, "-k6.summary.json")
    app_summaries = _find_files_by_suffix(dir_path, "-app.summary.md")
    mysql_summaries = _find_files_by_suffix(dir_path, "-mysql.summary.md")
    digest_summaries = _find_files_by_suffix(dir_path, "-mysql.digest.summary.md")

    phases = sorted(
        set(k6_logs.keys())
        | set(k6_summaries.keys())
        | set(app_summaries.keys())
        | set(mysql_summaries.keys())
        | set(digest_summaries.keys())
    )

    out: Dict[str, PhaseData] = {}
    for phase in phases:
        k6 = K6Metrics()
        app = AppMetrics()
        mysql = MysqlMetrics()
        digest = MysqlDigest()
        meta: Dict[str, str] = {}

        if phase in k6_summaries:
            try:
                k6 = _parse_k6_summary_export(k6_summaries[phase])
                meta["k6_source"] = "summary-export"
            except Exception:
                # Fallback to log parsing
                meta["k6_source"] = "summary-export-failed"

        if (k6 == K6Metrics()) and phase in k6_logs:
            k6 = _parse_k6_log_metrics(_read_text(k6_logs[phase]))
            meta["k6_source"] = meta.get("k6_source", "log")

        if phase in app_summaries:
            app = _parse_app_summary(_read_text(app_summaries[phase]))
        if phase in mysql_summaries:
            mysql = _parse_mysql_summary(_read_text(mysql_summaries[phase]))
        if phase in digest_summaries:
            digest = _parse_mysql_digest_summary(_read_text(digest_summaries[phase]))

        out[phase] = PhaseData(phase=phase, k6=k6, app=app, mysql=mysql, digest=digest, meta=meta)

    return _aggregate_peak_steps(out)


def render_report(baseline_dir: str, current_dir: str) -> str:
    base = load_phase_data(baseline_dir)
    cur = load_phase_data(current_dir)

    # Desired ordering for UI-like reading
    order = {"avg": 0, "peak": 1, "breakpoint": 2}
    phases = sorted(set(base.keys()) | set(cur.keys()), key=lambda x: (order.get(x, 9), x))

    lines: List[str] = []
    lines.append("# Run comparison report")
    lines.append("")
    lines.append(f"- baseline_dir: `{baseline_dir}`")
    lines.append(f"- current_dir: `{current_dir}`")
    lines.append("")

    if not phases:
        lines.append("- (no phases found)")
        return "\n".join(lines) + "\n"

    for phase in phases:
        b = base.get(phase)
        c = cur.get(phase)
        lines.append(f"## Phase: {phase}")
        # peak meta (steps)
        meta = (c.meta if c else None) or (b.meta if b else None) or {}
        if phase == "peak" and meta.get("peak_steps"):
            lines.append("")
            lines.append(f"- peak_steps: {meta.get('peak_steps')}")
        lines.append("")

        # k6 table
        lines.append("### HTTP (k6)")
        lines.append("")
        lines.append("| Metric | Baseline | Current | Delta |")
        lines.append("|---|---:|---:|---:|")

        def row_ms(label: str, get: str) -> None:
            bv = getattr(b.k6, get) if b else None
            cv = getattr(c.k6, get) if c else None
            lines.append(f"| {label} | {_fmt_ms(bv)} | {_fmt_ms(cv)} | {_delta_pct(cv, bv)} |")

        row_ms("http_req_duration avg", "http_req_duration_avg_ms")
        row_ms("http_req_duration p95", "http_req_duration_p95_ms")
        row_ms("http_req_duration p99", "http_req_duration_p99_ms")

        b_dropped = float(b.k6.dropped_iterations) if (b and b.k6.dropped_iterations is not None) else None
        c_dropped = float(c.k6.dropped_iterations) if (c and c.k6.dropped_iterations is not None) else None
        lines.append(
            f"| dropped_iterations | {int(b_dropped) if b_dropped is not None else '-'} | {int(c_dropped) if c_dropped is not None else '-'} | {_delta_pct(c_dropped, b_dropped)} |"
        )

        b_reqs = float(b.k6.http_reqs) if (b and b.k6.http_reqs is not None) else None
        c_reqs = float(c.k6.http_reqs) if (c and c.k6.http_reqs is not None) else None
        lines.append(
            f"| http_reqs | {int(b_reqs) if b_reqs is not None else '-'} | {int(c_reqs) if c_reqs is not None else '-'} | {_delta_pct(c_reqs, b_reqs)} |"
        )

        b_fail = b.k6.http_req_failed_rate if b else None
        c_fail = c.k6.http_req_failed_rate if c else None
        # for error rate, show delta in percentage points
        if b_fail is not None and c_fail is not None:
            delta_pp = (c_fail - b_fail) * 100.0
            delta_txt = f"{delta_pp:+.2f}%p"
        else:
            delta_txt = "-"
        lines.append(f"| http_req_failed | {_fmt_pct(b_fail)} | {_fmt_pct(c_fail)} | {delta_txt} |")

        lines.append("")

        # App summary
        lines.append("### App container")
        lines.append("")
        lines.append("| Metric | Baseline | Current | Delta |")
        lines.append("|---|---:|---:|---:|")

        def row_num(label: str, bval: Optional[float], cval: Optional[float], unit: str = "") -> None:
            btxt = _fmt_num(bval) + unit if bval is not None else "-"
            ctxt = _fmt_num(cval) + unit if cval is not None else "-"
            lines.append(f"| {label} | {btxt} | {ctxt} | {_delta_pct(cval, bval)} |")

        row_num("cpu avg", b.app.cpu_avg_pct if b else None, c.app.cpu_avg_pct if c else None, "%")
        row_num("cpu max", b.app.cpu_max_pct if b else None, c.app.cpu_max_pct if c else None, "%")
        row_num("mem avg", b.app.mem_avg_mib if b else None, c.app.mem_avg_mib if c else None, " MiB")
        row_num("mem max", b.app.mem_max_mib if b else None, c.app.mem_max_mib if c else None, " MiB")

        lines.append("")

        # MySQL summary
        lines.append("### MySQL")
        lines.append("")
        lines.append("| Metric | Baseline | Current | Delta |")
        lines.append("|---|---:|---:|---:|")
        row_num("Threads_connected avg", b.mysql.threads_connected_avg if b else None, c.mysql.threads_connected_avg if c else None)
        row_num("Threads_running avg", b.mysql.threads_running_avg if b else None, c.mysql.threads_running_avg if c else None)
        row_num("Queries rate", b.mysql.queries_rate_per_s if b else None, c.mysql.queries_rate_per_s if c else None, "/s")

        lines.append("")

        # Digest summary
        lines.append("### MySQL digest delta")
        lines.append("")
        lines.append("| Metric | Baseline | Current | Delta |")
        lines.append("|---|---:|---:|---:|")
        row_num("total SUM_TIMER_WAIT", b.digest.total_sum_timer_ms if b else None, c.digest.total_sum_timer_ms if c else None, " ms")
        row_num("top1 sum", b.digest.top1_sum_ms if b else None, c.digest.top1_sum_ms if c else None, " ms")

        b_top_cnt = b.digest.top1_count if b else None
        c_top_cnt = c.digest.top1_count if c else None
        lines.append(f"| top1 count | {b_top_cnt if b_top_cnt is not None else '-'} | {c_top_cnt if c_top_cnt is not None else '-'} | - |")

        # Show top1 query text as a note
        top_txt = (c.digest.top1_digest_text if c else None) or (b.digest.top1_digest_text if b else None)
        if top_txt:
            lines.append("")
            lines.append("#### Top query (digest_text excerpt)")
            lines.append("")
            lines.append(f"- {top_txt}")

        lines.append("")

    return "\n".join(lines) + "\n"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--baseline", required=True, help="Baseline run directory (e.g. .../k6-mysql-<ts>/<variant>)")
    p.add_argument("--current", required=True, help="Current run directory (e.g. .../k6-mysql-<ts>/<variant>)")
    p.add_argument("--out", required=False, help="Output markdown file path (default: stdout)")
    args = p.parse_args()

    out = render_report(args.baseline, args.current)

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(out)
    else:
        print(out, end="")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
