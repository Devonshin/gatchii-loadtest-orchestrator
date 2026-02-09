#!/usr/bin/env bash

# Sample Docker container resource usage via `docker stats --no-stream` into a CSV.
# Intended to correlate per-phase container resource usage with k6 phases.
#
# Required env vars:
#   CONTAINER   Container name or id
# Optional env vars:
#   INTERVAL_SECONDS  (default: 1)
#   DURATION_SECONDS  (default: run until Ctrl-C)
#   OUT               (default: ./docker_container_metrics_<timestamp>.csv)

set -u

CONTAINER="${CONTAINER:-}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-1}"
DURATION_SECONDS="${DURATION_SECONDS:-}"

if [[ -z "$CONTAINER" ]]; then
  echo "ERROR: Missing required env var: CONTAINER" >&2
  exit 1
fi

TS_FILE_TS="$(date +%Y%m%d_%H%M%S)"
OUT="${OUT:-./docker_container_metrics_${TS_FILE_TS}.csv}"

# Header
{
  echo "ts,container,cpu_pct,mem_used,mem_limit,net_rx,net_tx,block_read,block_write,pids"
} > "$OUT"

echo "Writing Docker container metrics to: $OUT (container=$CONTAINER)" >&2

start_epoch="$(date +%s)"

while true; do
  now_epoch="$(date +%s)"
  if [[ -n "$DURATION_SECONDS" ]]; then
    if (( now_epoch - start_epoch >= DURATION_SECONDS )); then
      break
    fi
  fi

  ts="$(date -Iseconds)"

  # Example fields:
  # Name, CPUPerc, MemUsage, NetIO, BlockIO, PIDs
  # MemUsage: "12.3MiB / 1GiB"
  # NetIO: "1.2MB / 3.4MB"
  # BlockIO: "0B / 0B"
  line="$(docker stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.NetIO}},{{.BlockIO}},{{.PIDs}}" "$CONTAINER" 2>/dev/null || true)"

  if [[ -z "$line" ]]; then
    echo "$ts,$CONTAINER" >> "$OUT"
    sleep "$INTERVAL_SECONDS"
    continue
  fi

  name="${line%%,*}"
  rest="${line#*,}"

  cpu="${rest%%,*}"; rest="${rest#*,}"
  mem="${rest%%,*}"; rest="${rest#*,}"
  net="${rest%%,*}"; rest="${rest#*,}"
  blk="${rest%%,*}"; rest="${rest#*,}"
  pids="$rest"

  # Split "a / b" pairs.
  mem_used="${mem%% /*}"; mem_limit="${mem#*/ }"
  net_rx="${net%% /*}"; net_tx="${net#*/ }"
  blk_read="${blk%% /*}"; blk_write="${blk#*/ }"

  # Keep values as raw strings; numeric parsing is done in the report script.
  echo "$ts,$name,$cpu,$mem_used,$mem_limit,$net_rx,$net_tx,$blk_read,$blk_write,$pids" >> "$OUT"

  sleep "$INTERVAL_SECONDS"
done

echo "Done." >&2
