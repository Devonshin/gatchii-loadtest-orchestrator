#!/usr/bin/env bash

# Capture a snapshot of top statement digests from performance_schema.
#
# Required env vars:
#   DB_DOCKER_HOST, DB_USER, DB_PASSWORD
# Optional env vars:
#   DB_PORT (default: 3306)
#   OUT (default: ./mysql_ps_digest_<timestamp>.tsv)
#   LIMIT (default: 50)

set -euo pipefail

DB_PORT="${DB_PORT:-3306}"
LIMIT="${LIMIT:-50}"

if [[ -z "${DB_DOCKER_HOST:-}" || -z "${DB_USER:-}" || -z "${DB_PASSWORD:-}" ]]; then
  echo "ERROR: Missing required env vars: DB_DOCKER_HOST, DB_USER, DB_PASSWORD" >&2
  exit 1
fi

TS_FILE_TS="$(date +%Y%m%d_%H%M%S)"
OUT="${OUT:-./mysql_ps_digest_${TS_FILE_TS}.tsv}"

# NOTE:
# - performance_schema timers are typically in picoseconds.
# - We keep raw timer values and convert in post-processing.
QUERY=$(cat <<SQL
SELECT
  DIGEST,
  DIGEST_TEXT,
  COUNT_STAR,
  SUM_TIMER_WAIT,
  AVG_TIMER_WAIT,
  SUM_ROWS_EXAMINED,
  SUM_ROWS_SENT
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST IS NOT NULL
ORDER BY SUM_TIMER_WAIT DESC
LIMIT ${LIMIT};
SQL
)

# Header
{
  echo -e "ts\tDIGEST\tCOUNT_STAR\tSUM_TIMER_WAIT\tAVG_TIMER_WAIT\tSUM_ROWS_EXAMINED\tSUM_ROWS_SENT\tDIGEST_TEXT";
} > "$OUT"

# Data
now="$(date -Iseconds)"

docker exec -e MYSQL_PWD="$DB_PASSWORD" "$DB_DOCKER_HOST" \
  mysql -u"$DB_USER" -P"$DB_PORT" -N -e "$QUERY" \
  2>/dev/null \
  | awk -v ts="$now" 'BEGIN{FS="\t"; OFS="\t"} {print ts, $1, $3, $4, $5, $6, $7, $2}' \
  >> "$OUT"

echo "Wrote: $OUT" >&2
