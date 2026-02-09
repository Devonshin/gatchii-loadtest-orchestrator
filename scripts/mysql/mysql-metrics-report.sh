#!/usr/bin/env bash

# Summarize mysql-metrics.sh CSV output into a readable report.
#
# Usage:
#   ./scripts/mysql/mysql-metrics-report.sh <csv_path> [--interval <seconds>] [--title <text>] [--out <path>]
#
# Notes:
# - Interval is used to estimate duration (duration ~= (rows-1)*interval).
# - Counters are summarized as start/end/delta and per-second rate.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <csv_path> [--interval <seconds>] [--title <text>] [--out <path>]" >&2
  exit 1
fi

CSV_PATH="$1"
shift

INTERVAL_SECONDS=1
TITLE=""
OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      INTERVAL_SECONDS="$2"; shift 2 ;;
    --title)
      TITLE="$2"; shift 2 ;;
    --out)
      OUT="$2"; shift 2 ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$CSV_PATH" ]]; then
  echo "ERROR: CSV not found: $CSV_PATH" >&2
  exit 1
fi

if [[ -z "$OUT" ]]; then
  OUT="${CSV_PATH%.csv}.summary.md"
fi

# Use awk for portability (macOS default awk).
awk -v interval="$INTERVAL_SECONDS" -v title="$TITLE" '
  function idx(name) { return col[name]; }
  function have(name) { return (idx(name) > 0); }
  function to_num(s) {
    # Empty -> NaN-like sentinel
    if (s == "") return "";
    return s + 0;
  }
  function upd_gauge(name, val) {
    if (val == "") return;
    if (!(name in g_min) || val < g_min[name]) g_min[name] = val;
    if (!(name in g_max) || val > g_max[name]) g_max[name] = val;
    g_sum[name] += val;
  }
  function upd_counter(name, val) {
    if (val == "") return;
    if (!(name in c_first)) c_first[name] = val;
    c_last[name] = val;
  }
  function fmt_num(x) {
    if (x == "") return "";
    # integer-like
    if (x == int(x)) return sprintf("%d", x);
    return sprintf("%.2f", x);
  }
  function fmt_rate(x) {
    if (x == "") return "";
    return sprintf("%.2f/s", x);
  }
  function print_gauge(name, unit) {
    if (!(name in g_sum)) return;
    avg = g_sum[name] / rows;
    printf("- %s: min=%s, avg=%s, max=%s%s\n", name, fmt_num(g_min[name]), fmt_num(avg), fmt_num(g_max[name]), unit);
  }
  function print_counter(name, unit) {
    if (!(name in c_last)) return;
    d = c_last[name] - c_first[name];
    r = (dur_s > 0) ? d / dur_s : "";
    printf("- %s: start=%s, end=%s, delta=%s%s, rate=%s\n", name, fmt_num(c_first[name]), fmt_num(c_last[name]), fmt_num(d), unit, fmt_rate(r));
  }

  BEGIN {
    FS=",";
    rows=0;
  }

  NR==1 {
    for (i=1; i<=NF; i++) {
      col[$i] = i;
    }
    next;
  }

  {
    # Skip empty/partial lines
    if (NF < 2) next;
    rows++;

    # Gauges
    upd_gauge("Threads_connected", to_num($(idx("Threads_connected"))));
    upd_gauge("Threads_running", to_num($(idx("Threads_running"))));

    # Counters
    upd_counter("Connections", to_num($(idx("Connections"))));
    upd_counter("Aborted_connects", to_num($(idx("Aborted_connects"))));

    # Queries: prefer Queries, else Questions
    qv = "";
    if (have("Queries")) qv = to_num($(idx("Queries")));
    if (qv == "" && have("Questions")) qv = to_num($(idx("Questions")));
    upd_counter("Queries", qv);

    upd_counter("Com_select", to_num($(idx("Com_select"))));
    upd_counter("Com_insert", to_num($(idx("Com_insert"))));
    upd_counter("Com_update", to_num($(idx("Com_update"))));
    upd_counter("Com_delete", to_num($(idx("Com_delete"))));

    upd_counter("Innodb_rows_read", to_num($(idx("Innodb_rows_read"))));
    upd_counter("Innodb_rows_inserted", to_num($(idx("Innodb_rows_inserted"))));
    upd_counter("Innodb_rows_updated", to_num($(idx("Innodb_rows_updated"))));
    upd_counter("Innodb_rows_deleted", to_num($(idx("Innodb_rows_deleted"))));

    upd_counter("Innodb_row_lock_waits", to_num($(idx("Innodb_row_lock_waits"))));
    upd_counter("Innodb_row_lock_time", to_num($(idx("Innodb_row_lock_time"))));

    upd_counter("Innodb_buffer_pool_read_requests", to_num($(idx("Innodb_buffer_pool_read_requests"))));
    upd_counter("Innodb_buffer_pool_reads", to_num($(idx("Innodb_buffer_pool_reads"))));
  }

  END {
    dur_s = (rows > 1) ? (rows - 1) * interval : 0;

    if (title == "") {
      title = "MySQL metrics summary";
    }

    print "# " title;
    print "";
    print "## Sampling";
    printf("- rows: %d\n", rows);
    printf("- interval_seconds: %s\n", interval);
    printf("- approx_duration_seconds: %d\n", dur_s);
    print "";

    print "## Connection / concurrency (gauges)";
    print_gauge("Threads_connected", "");
    print_gauge("Threads_running", "");
    print "";

    print "## Connection churn / errors (counters)";
    print_counter("Connections", "");
    print_counter("Aborted_connects", "");
    print "";

    print "## Query volume (counters)";
    print_counter("Queries", "");
    print_counter("Com_select", "");
    print_counter("Com_insert", "");
    print_counter("Com_update", "");
    print_counter("Com_delete", "");
    print "";

    print "## InnoDB row activity (counters)";
    print_counter("Innodb_rows_read", "");
    print_counter("Innodb_rows_inserted", "");
    print_counter("Innodb_rows_updated", "");
    print_counter("Innodb_rows_deleted", "");
    print "";

    print "## Lock waits (counters)";
    print_counter("Innodb_row_lock_waits", "");
    print_counter("Innodb_row_lock_time", " (ms)");

    # Average lock time per wait (if any)
    if (("Innodb_row_lock_waits" in c_last) && ("Innodb_row_lock_time" in c_last)) {
      dw = c_last["Innodb_row_lock_waits"] - c_first["Innodb_row_lock_waits"];
      dt = c_last["Innodb_row_lock_time"] - c_first["Innodb_row_lock_time"];
      if (dw > 0) {
        printf("- avg_lock_time_per_wait: %.2f ms\n", dt / dw);
      }
    }
    print "";

    print "## Buffer pool read efficiency (counters)";
    if (("Innodb_buffer_pool_read_requests" in c_last) && ("Innodb_buffer_pool_reads" in c_last)) {
      rr = c_last["Innodb_buffer_pool_read_requests"] - c_first["Innodb_buffer_pool_read_requests"];
      r = c_last["Innodb_buffer_pool_reads"] - c_first["Innodb_buffer_pool_reads"];
      print_counter("Innodb_buffer_pool_read_requests", "");
      print_counter("Innodb_buffer_pool_reads", "");
      if (rr > 0) {
        hit = 1.0 - (r / rr);
        if (hit < 0) hit = 0;
        if (hit > 1) hit = 1;
        printf("- approx_buffer_pool_hit_ratio: %.4f\n", hit);
      }
    }
  }
' "$CSV_PATH" > "$OUT"

echo "Wrote: $OUT" >&2
