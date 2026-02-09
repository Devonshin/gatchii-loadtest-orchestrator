#!/usr/bin/env bash

# MySQL metrics sampler for load tests.
# Writes a CSV time series that can be correlated with k6 stages.
#
# Required env vars:
#   DB_DOCKER_HOST  MySQL container name/id (e.g. fontradar_v2_api_mysql)
#   DB_PORT         MySQL port inside container (default: 3306)
#   DB_USER         MySQL username
#   DB_PASSWORD     MySQL password
#
# Optional env vars:
#   INTERVAL_SECONDS  Sampling interval in seconds (default: 1)
#   DURATION_SECONDS  Stop after N seconds (default: run until Ctrl-C)
#   OUT               Output CSV path (default: ./mysql_metrics_<timestamp>.csv)

set -u

DB_PORT="${DB_PORT:-3306}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-1}"
DURATION_SECONDS="${DURATION_SECONDS:-}"

if [[ -z "${DB_DOCKER_HOST:-}" || -z "${DB_USER:-}" || -z "${DB_PASSWORD:-}" ]]; then
  echo "ERROR: Missing required env vars: DB_DOCKER_HOST, DB_USER, DB_PASSWORD" >&2
  exit 1
fi

TS_FILE_TS="$(date +%Y%m%d_%H%M%S)"
OUT="${OUT:-./mysql_metrics_${TS_FILE_TS}.csv}"

# Variables we want to sample every tick.
# Counters are monotonically increasing; compute deltas in post-processing.
STATUS_VARS=(
  Threads_connected
  Threads_running
  Max_used_connections
  Connections
  Aborted_connects
  Queries
  Questions
  Com_select
  Com_insert
  Com_update
  Com_delete
  Innodb_rows_read
  Innodb_rows_inserted
  Innodb_rows_updated
  Innodb_rows_deleted
  Innodb_row_lock_waits
  Innodb_row_lock_time
  Innodb_buffer_pool_read_requests
  Innodb_buffer_pool_reads
)

# Query a batch of status variables in one mysql invocation.
# Output format: TSV -> "Variable_name\tValue" per line.
fetch_status_tsv() {
  docker exec -e MYSQL_PWD="$DB_PASSWORD" "$DB_DOCKER_HOST" \
    mysql -u"$DB_USER" -P"$DB_PORT" -N -e \
    "SHOW GLOBAL STATUS WHERE Variable_name IN ('$(IFS=','; echo "${STATUS_VARS[*]}" | sed "s/,/','/g")');" \
    2>/dev/null
}

# Build a CSV row in a stable column order.
# If a variable is missing, write empty.
# For Queries/Questions: prefer Queries if present; else use Questions.
format_csv_row() {
  local ts="$1"
  local tsv="$2"

  # Use awk to map var->value and emit values in the desired order.
  # NOTE: Keep this awk compatible with macOS default awk.
  echo "$tsv" | awk -v ts="$ts" '
    BEGIN {
      FS="\t";
      # Define output order
      n=0;
      order[++n]="Threads_connected";
      order[++n]="Threads_running";
      order[++n]="Max_used_connections";
      order[++n]="Connections";
      order[++n]="Aborted_connects";
      order[++n]="Queries";
      order[++n]="Questions";
      order[++n]="Com_select";
      order[++n]="Com_insert";
      order[++n]="Com_update";
      order[++n]="Com_delete";
      order[++n]="Innodb_rows_read";
      order[++n]="Innodb_rows_inserted";
      order[++n]="Innodb_rows_updated";
      order[++n]="Innodb_rows_deleted";
      order[++n]="Innodb_row_lock_waits";
      order[++n]="Innodb_row_lock_time";
      order[++n]="Innodb_buffer_pool_read_requests";
      order[++n]="Innodb_buffer_pool_reads";
    }
    {
      if ($1 != "" ) {
        v[$1] = $2;
      }
    }
    END {
      # Prefer Queries over Questions when available.
      q = v["Queries"];
      if (q == "" && v["Questions"] != "") {
        q = v["Questions"];
      }

      out = ts;
      for (i = 1; i <= n; i++) {
        key = order[i];
        val = v[key];
        if (key == "Queries") {
          val = q;
        }
        # Basic CSV escaping is not needed (numeric values), but keep empty as empty.
        out = out "," val;
      }
      print out;
    }
  '
}

# Write header
{
  echo -n "ts"
  echo -n ",Threads_connected"
  echo -n ",Threads_running"
  echo -n ",Max_used_connections"
  echo -n ",Connections"
  echo -n ",Aborted_connects"
  echo -n ",Queries"
  echo -n ",Questions"
  echo -n ",Com_select"
  echo -n ",Com_insert"
  echo -n ",Com_update"
  echo -n ",Com_delete"
  echo -n ",Innodb_rows_read"
  echo -n ",Innodb_rows_inserted"
  echo -n ",Innodb_rows_updated"
  echo -n ",Innodb_rows_deleted"
  echo -n ",Innodb_row_lock_waits"
  echo -n ",Innodb_row_lock_time"
  echo -n ",Innodb_buffer_pool_read_requests"
  echo ",Innodb_buffer_pool_reads"
} > "$OUT"

echo "Writing MySQL metrics to: $OUT" >&2

start_epoch="$(date +%s)"

while true; do
  now_epoch="$(date +%s)"
  if [[ -n "$DURATION_SECONDS" ]]; then
    if (( now_epoch - start_epoch >= DURATION_SECONDS )); then
      break
    fi
  fi

  ts="$(date -Iseconds)"
  tsv="$(fetch_status_tsv || true)"

  # If the query fails, still write a line with timestamp only.
  if [[ -z "$tsv" ]]; then
    echo "$ts" >> "$OUT"
  else
    format_csv_row "$ts" "$tsv" >> "$OUT"
  fi

  sleep "$INTERVAL_SECONDS"
done

echo "Done." >&2
