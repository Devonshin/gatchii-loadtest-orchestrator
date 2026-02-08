#!/usr/bin/env bash

# Orchestrate k6 runs and MySQL metric sampling.
#
# - Runs avg/peak/breakpoint profiles per port.
# - For each profile, starts scripts/mysql-metrics.sh in the background and stops it after k6 completes.
# - Writes logs/CSVs under .idea/.project-docs/<YYYY-MM-DD>/runs/.
#
# Required env vars (DB):
#   DB_DOCKER_HOST, DB_USER, DB_PASSWORD
# Optional (DB):
#   DB_PORT (default: 3306)
#
# Optional (targets):
#   PORTS (default: "8890 9890")
#   URL_PATH (default: "/license/assistance/Typofonderie-AiglonPro")
#
# Optional (profiles):
#   AVG_RPS (default: 300)
#   AVG_DURATION (default: 4m)
#
#   # Peak can be executed as multiple constant-arrival-rate steps.
#   # To keep total runtime predictable, the default runs a single peak step.
#   PEAK_STEPS (default: "400")
#   PEAK_DURATION (default: 4m)
#
#   # Backward-compatible: PEAK_RPS is still supported by rps-peak.js, but the orchestrator prefers PEAK_STEPS.
#   PEAK_RPS (default: 400)
#
#   # Breakpoint total: 4 steps + ramp-down = 6m24s (default)
#   BP_START_RPS (default: 200)
#   BP_STEP_1_RPS (default: 200)
#   BP_STEP_2_RPS (default: 300)
#   BP_STEP_3_RPS (default: 400)
#   BP_STEP_4_RPS (default: 500)
#   BP_STEP_DURATION (default: 1m12s)
#   BP_RAMP_DOWN (default: 1m36s)
#
# Optional (behavior):
#   STOP_POLICY (default: "stop-on-next-failure")
#     - "never": run all phases even if failures occur
#     - "stop-on-first-failure": stop remaining phases for that port after first non-zero exit
#     - "stop-on-next-failure": allow one failing phase, stop if a subsequent phase fails
#
# Optional (sampling):
#   MYSQL_INTERVAL_SECONDS (default: 1)
#   MYSQL_STOP_BUFFER_SECONDS (default: 20)  # extend sampling beyond k6 duration
#
# Optional (timeline artifacts):
#   K6_JSON_OUTPUT (default: "true")  # writes per-phase k6 JSON stream as <phase>-k6.json
#   TIMELINE_TOP (default: 20)
#   TIMELINE_SPIKE_THRESHOLD (default: 10)
#
# Optional (DB digest snapshots via performance_schema):
#   MYSQL_DIGEST_SNAPSHOT (default: "true")
#   MYSQL_DIGEST_LIMIT (default: 50)
#   MYSQL_DIGEST_TOP (default: 20)
#
# Optional (app container resource metrics via docker stats):
#   APP_METRICS (default: "true")
#   APP_METRICS_INTERVAL_SECONDS (default: 1)
#   # You can provide explicit container names/ids per port:
#   APP_CONTAINER_8890, APP_CONTAINER_9890, ...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve runner root by walking up until we find runner/scripts.
# This makes the script resilient to layout changes (e.g., previously under runner/projects/<id>/).
find_runner_dir() {
  local start_dir="$1"
  local dir="$start_dir"

  for _ in 1 2 3 4 5 6; do
    if [[ -d "$dir/scripts" && -f "$dir/scripts/mysql-metrics.sh" ]]; then
      echo "$dir"
      return 0
    fi

    local parent
    parent="$(cd "$dir/.." && pwd)"
    if [[ "$parent" == "$dir" ]]; then
      break
    fi
    dir="$parent"
  done

  echo ""  # not found
  return 1
}

RUNNER_DIR="$(find_runner_dir "$SCRIPT_DIR")"
if [[ -z "$RUNNER_DIR" ]]; then
  echo "ERROR: Failed to locate runner root (expected scripts/mysql-metrics.sh near $SCRIPT_DIR)" >&2
  exit 1
fi

PROJECT_ROOT="$(cd "$RUNNER_DIR/.." && pwd)"
SCRIPTS_DIR="$RUNNER_DIR/scripts"

MONITOR_SCRIPT="$SCRIPTS_DIR/mysql-metrics.sh"
REPORT_SCRIPT="$SCRIPTS_DIR/mysql-metrics-report.sh"
TIMELINE_SCRIPT="$SCRIPTS_DIR/k6-timeline.py"
DIGEST_SNAPSHOT_SCRIPT="$SCRIPTS_DIR/mysql-ps-digest-snapshot.sh"
DIGEST_REPORT_SCRIPT="$SCRIPTS_DIR/mysql-ps-digest-report.py"

APP_METRICS_SCRIPT="$SCRIPTS_DIR/docker-container-metrics.sh"
APP_METRICS_REPORT_SCRIPT="$SCRIPTS_DIR/docker-container-metrics-report.py"

# Load orchestrator environment variables if present.
# This allows running the script without manually exporting variables.
ENV_FILE="$PROJECT_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

CURRENT_MON_PID=""
cleanup() {
  if [[ -n "$CURRENT_MON_PID" ]]; then
    kill "$CURRENT_MON_PID" 2>/dev/null || true
    wait "$CURRENT_MON_PID" 2>/dev/null || true
    CURRENT_MON_PID=""
  fi
}
trap cleanup EXIT INT TERM

if [[ ! -x "$MONITOR_SCRIPT" ]]; then
  echo "ERROR: MySQL monitor script not found or not executable: $MONITOR_SCRIPT" >&2
  exit 1
fi

if [[ ! -x "$REPORT_SCRIPT" ]]; then
  echo "ERROR: MySQL report script not found or not executable: $REPORT_SCRIPT" >&2
  exit 1
fi

if [[ -z "${DB_DOCKER_HOST:-}" || -z "${DB_USER:-}" || -z "${DB_PASSWORD:-}" ]]; then
  echo "ERROR: Missing required env vars: DB_DOCKER_HOST, DB_USER, DB_PASSWORD" >&2
  exit 1
fi

DB_PORT="${DB_PORT:-3306}"
PORTS="${PORTS:-8000}"
URL_PATH="${URL_PATH:-/}"

AVG_RPS="${AVG_RPS:-300}"
AVG_DURATION="${AVG_DURATION:-4m}"

# Peak steps
# - Default: from AVG_RPS to PEAK_TO_RPS, step=PEAK_STEP_RPS (100)
# - You can override with explicit space-separated steps: PEAK_STEPS="400 500 600"
PEAK_RPS="${PEAK_RPS:-400}"          # backward-compatible (legacy max)
PEAK_TO_RPS="${PEAK_TO_RPS:-$PEAK_RPS}"
PEAK_STEP_RPS="${PEAK_STEP_RPS:-100}"
PEAK_STEPS="${PEAK_STEPS:-}"
PEAK_DURATION="${PEAK_DURATION:-4m}"

BP_START_RPS="${BP_START_RPS:-200}"
BP_STEP_1_RPS="${BP_STEP_1_RPS:-200}"
BP_STEP_2_RPS="${BP_STEP_2_RPS:-300}"
BP_STEP_3_RPS="${BP_STEP_3_RPS:-400}"
BP_STEP_4_RPS="${BP_STEP_4_RPS:-500}"
BP_STEP_DURATION="${BP_STEP_DURATION:-1m12s}"
BP_RAMP_DOWN="${BP_RAMP_DOWN:-1m36s}"

STOP_POLICY="${STOP_POLICY:-stop-on-next-failure}"
MYSQL_INTERVAL_SECONDS="${MYSQL_INTERVAL_SECONDS:-1}"
MYSQL_STOP_BUFFER_SECONDS="${MYSQL_STOP_BUFFER_SECONDS:-20}"

K6_JSON_OUTPUT="${K6_JSON_OUTPUT:-true}"
K6_SUMMARY_EXPORT="${K6_SUMMARY_EXPORT:-true}"  # writes per-phase k6 summary JSON as <phase>-k6.summary.json
TIMELINE_TOP="${TIMELINE_TOP:-20}"
TIMELINE_SPIKE_THRESHOLD="${TIMELINE_SPIKE_THRESHOLD:-10}"

MYSQL_DIGEST_SNAPSHOT="${MYSQL_DIGEST_SNAPSHOT:-true}"
MYSQL_DIGEST_LIMIT="${MYSQL_DIGEST_LIMIT:-50}"
MYSQL_DIGEST_TOP="${MYSQL_DIGEST_TOP:-20}"

APP_METRICS="${APP_METRICS:-true}"
APP_METRICS_INTERVAL_SECONDS="${APP_METRICS_INTERVAL_SECONDS:-1}"

# Convert a duration string like "7m30s" or "45s" or "3m" or "1h2m3s" to seconds.
duration_to_seconds() {
  local input="$1"
  local rest="$input"
  local total=0

  while [[ "$rest" =~ ^([0-9]+)(h|m|s)(.*)$ ]]; do
    local val="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"
    rest="${BASH_REMATCH[3]}"

    case "$unit" in
      h) total=$((total + val * 3600)) ;;
      m) total=$((total + val * 60)) ;;
      s) total=$((total + val)) ;;
      *) echo "ERROR: Unsupported duration unit in '$input'" >&2; return 1 ;;
    esac
  done

  if [[ -n "$rest" ]]; then
    echo "ERROR: Failed to parse duration '$input'" >&2
    return 1
  fi

  echo "$total"
}

build_peak_steps() {
  local from="$AVG_RPS"
  local to="$PEAK_TO_RPS"
  local step="$PEAK_STEP_RPS"

  if [[ ! "$from" =~ ^[0-9]+$ || ! "$to" =~ ^[0-9]+$ || ! "$step" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Peak steps must be integers (from=$from to=$to step=$step)" >&2
    return 1
  fi
  if (( step <= 0 )); then
    echo "ERROR: PEAK_STEP_RPS must be > 0" >&2
    return 1
  fi
  if (( from > to )); then
    echo "ERROR: Peak range invalid (AVG_RPS=$from > PEAK_TO_RPS=$to)" >&2
    return 1
  fi

  local out=""
  local r
  for ((r = from; r <= to; r += step)); do
    out+="$r "
  done

  # Trim trailing space
  out="${out%% }"
  echo "$out"
}

if [[ -z "$PEAK_STEPS" ]]; then
  PEAK_STEPS="$(build_peak_steps)"
fi

K6_AVG_SECONDS="$(duration_to_seconds "$AVG_DURATION")"
K6_PEAK_SECONDS="$(duration_to_seconds "$PEAK_DURATION")"
BP_STEP_SECONDS="$(duration_to_seconds "$BP_STEP_DURATION")"
BP_RAMP_DOWN_SECONDS="$(duration_to_seconds "$BP_RAMP_DOWN")"
# ramping-arrival-rate stages in rps-breakpoint.js: 4 step stages + ramp-down stage
K6_BP_SECONDS=$((BP_STEP_SECONDS * 4 + BP_RAMP_DOWN_SECONDS))

DATE_DIR="$(date +%F)"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$PROJECT_ROOT/.idea/.project-docs/$DATE_DIR/runs/k6-mysql-$RUN_TS"
mkdir -p "$RUN_DIR"

write_info() {
  echo "[$(date -Iseconds)] $*" >&2
}

# Resolve the app container for a given port.
# Priority:
# 1) env var APP_CONTAINER_<port>
# 2) docker ps port mapping ("0.0.0.0:<port>->" or "::<port>->")
resolve_app_container_for_port() {
  local port="$1"

  local env_name="APP_CONTAINER_${port}"
  # Indirect expansion is safe here.
  local explicit="${!env_name:-}"
  if [[ -n "$explicit" ]]; then
    echo "$explicit"
    return 0
  fi

  # Best-effort detection.
  local line
  line="$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | awk -v p=":${port}->" 'index($0, p) {print $1; exit 0} END{ }')"
  if [[ -n "$line" ]]; then
    echo "$line"
    return 0
  fi

  echo ""
}

# Start MySQL sampler in background.
# Writes CSV to the given path.
start_mysql_monitor() {
  local out_csv="$1"
  local duration_seconds="$2"
  local out_log="$3"

  DB_DOCKER_HOST="$DB_DOCKER_HOST" \
  DB_PORT="$DB_PORT" \
  DB_USER="$DB_USER" \
  DB_PASSWORD="$DB_PASSWORD" \
  OUT="$out_csv" \
  INTERVAL_SECONDS="$MYSQL_INTERVAL_SECONDS" \
  DURATION_SECONDS="$duration_seconds" \
  "$MONITOR_SCRIPT" >"$out_log" 2>&1 &

  echo $!
}

stop_mysql_monitor() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

run_k6_with_mysql() {
  local port="$1"
  local phase="$2"
  local k6_seconds="$3"
  local k6_cmd="$4"

  local port_dir="$RUN_DIR/$port"
  mkdir -p "$port_dir"

  local mysql_csv="$port_dir/${phase}-mysql.csv"
  local mysql_log="$port_dir/${phase}-mysql.monitor.log"
  local k6_log="$port_dir/${phase}-k6.log"
  local k6_json="$port_dir/${phase}-k6.json"
  local k6_summary="$port_dir/${phase}-k6.summary.json"
  local timeline_md="$port_dir/${phase}-k6.timeline.md"

  local digest_start_tsv="$port_dir/${phase}-mysql.digest.start.tsv"
  local digest_end_tsv="$port_dir/${phase}-mysql.digest.end.tsv"
  local digest_md="$port_dir/${phase}-mysql.digest.summary.md"

  local app_csv="$port_dir/${phase}-app.csv"
  local app_md="$port_dir/${phase}-app.summary.md"
  local app_monitor_log="$port_dir/${phase}-app.monitor.log"
  local app_mon_pid=""

  # Always create the k6 log file early so missing logs indicate where it failed.
  : > "$k6_log"

  local monitor_seconds=$((k6_seconds + MYSQL_STOP_BUFFER_SECONDS))

  if [[ "$MYSQL_DIGEST_SNAPSHOT" == "true" && -x "$DIGEST_SNAPSHOT_SCRIPT" ]]; then
    write_info "PORT=$port PHASE=$phase snapshotting performance_schema digests (start)"
    DB_DOCKER_HOST="$DB_DOCKER_HOST" \
    DB_PORT="$DB_PORT" \
    DB_USER="$DB_USER" \
    DB_PASSWORD="$DB_PASSWORD" \
    OUT="$digest_start_tsv" \
    LIMIT="$MYSQL_DIGEST_LIMIT" \
    "$DIGEST_SNAPSHOT_SCRIPT" >/dev/null 2>&1 || true
  fi

  if [[ "$APP_METRICS" == "true" && -x "$APP_METRICS_SCRIPT" ]]; then
    local app_container
    app_container="$(resolve_app_container_for_port "$port")"
    if [[ -n "$app_container" ]]; then
      write_info "PORT=$port PHASE=$phase starting app container metrics (container=$app_container)"
      CONTAINER="$app_container" \
      OUT="$app_csv" \
      INTERVAL_SECONDS="$APP_METRICS_INTERVAL_SECONDS" \
      DURATION_SECONDS="$monitor_seconds" \
      "$APP_METRICS_SCRIPT" >"$app_monitor_log" 2>&1 &
      app_mon_pid="$!"
    else
      write_info "PORT=$port PHASE=$phase app container not resolved (set APP_CONTAINER_${port})"
    fi
  fi

  write_info "PORT=$port PHASE=$phase starting MySQL monitor (${monitor_seconds}s) -> $mysql_csv"
  local mon_pid
  mon_pid="$(start_mysql_monitor "$mysql_csv" "$monitor_seconds" "$mysql_log")"
  CURRENT_MON_PID="$mon_pid"

  # k6 outputs
  # - JSON stream: time-series friendly, but large
  # - summary-export: compact, stable for UI parsing and comparisons
  # IMPORTANT: k6 CLI options must appear before the script path.

  if [[ "$k6_cmd" =~ ^(.*)[[:space:]]+([^[:space:]]+\.js)([[:space:]]*)$ ]]; then
    local prefix="${BASH_REMATCH[1]}"
    local script_path="${BASH_REMATCH[2]}"

    if [[ "$K6_JSON_OUTPUT" == "true" ]]; then
      prefix="$prefix --out json=$k6_json"
    fi

    if [[ "$K6_SUMMARY_EXPORT" == "true" ]]; then
      prefix="$prefix --summary-export $k6_summary"
    fi

    k6_cmd="$prefix $script_path"
  else
    if [[ "$K6_JSON_OUTPUT" == "true" ]]; then
      k6_cmd="$k6_cmd --out json=$k6_json"
    fi

    if [[ "$K6_SUMMARY_EXPORT" == "true" ]]; then
      k6_cmd="$k6_cmd --summary-export $k6_summary"
    fi
  fi

  write_info "PORT=$port PHASE=$phase running k6: $k6_cmd"
  set +e
  bash -lc "$k6_cmd" 2>&1 | tee -a "$k6_log"
  local ec=${PIPESTATUS[0]}
  set -e

  write_info "PORT=$port PHASE=$phase k6 finished (exit=$ec)"

  write_info "PORT=$port PHASE=$phase stopping MySQL monitor (pid=$mon_pid)"
  stop_mysql_monitor "$mon_pid"
  CURRENT_MON_PID=""

  if [[ -n "$app_mon_pid" ]]; then
    write_info "PORT=$port PHASE=$phase stopping app metrics (pid=$app_mon_pid)"
    if kill -0 "$app_mon_pid" 2>/dev/null; then
      kill "$app_mon_pid" 2>/dev/null || true
      wait "$app_mon_pid" 2>/dev/null || true
    fi

    if [[ -f "$app_csv" && -f "$APP_METRICS_REPORT_SCRIPT" ]]; then
      python3 "$APP_METRICS_REPORT_SCRIPT" "$app_csv" --title "App container metrics (${port} ${phase})" --out "$app_md" >/dev/null 2>&1 || true
    fi
  fi

  # Generate a human-readable summary for the CSV.
  # Interval is the sampler interval; duration is approximated from row count.
  "$REPORT_SCRIPT" "$mysql_csv" --interval "$MYSQL_INTERVAL_SECONDS" --title "MySQL metrics (${port} ${phase})" >/dev/null 2>&1 || true

  if [[ "$MYSQL_DIGEST_SNAPSHOT" == "true" && -x "$DIGEST_SNAPSHOT_SCRIPT" ]]; then
    write_info "PORT=$port PHASE=$phase snapshotting performance_schema digests (end)"
    DB_DOCKER_HOST="$DB_DOCKER_HOST" \
    DB_PORT="$DB_PORT" \
    DB_USER="$DB_USER" \
    DB_PASSWORD="$DB_PASSWORD" \
    OUT="$digest_end_tsv" \
    LIMIT="$MYSQL_DIGEST_LIMIT" \
    "$DIGEST_SNAPSHOT_SCRIPT" >/dev/null 2>&1 || true

    if [[ -f "$digest_start_tsv" && -f "$digest_end_tsv" && -f "$DIGEST_REPORT_SCRIPT" ]]; then
      python3 "$DIGEST_REPORT_SCRIPT" \
        --start "$digest_start_tsv" \
        --end "$digest_end_tsv" \
        --out "$digest_md" \
        --title "MySQL digest delta (${port} ${phase})" \
        --top "$MYSQL_DIGEST_TOP" \
        >/dev/null 2>&1 || true
    fi
  fi

  # Generate a k6 timeline report (Insufficient VUs + dropped spike seconds).
  if [[ "$K6_JSON_OUTPUT" == "true" && -f "$k6_json" && -f "$TIMELINE_SCRIPT" ]]; then
    python3 "$TIMELINE_SCRIPT" \
      --json "$k6_json" \
      --log "$k6_log" \
      --title "k6 timeline (${port} ${phase})" \
      --top "$TIMELINE_TOP" \
      --spike-threshold "$TIMELINE_SPIKE_THRESHOLD" \
      --out "$timeline_md" \
      >/dev/null 2>&1 || true
  fi

  echo "$ec"
}

should_stop_after_failure() {
  local fail_count="$1"
  case "$STOP_POLICY" in
    never) return 1 ;;
    stop-on-first-failure)
      [[ "$fail_count" -ge 1 ]]
      ;;
    stop-on-next-failure)
      [[ "$fail_count" -ge 2 ]]
      ;;
    *)
      echo "ERROR: Unknown STOP_POLICY: $STOP_POLICY" >&2
      return 0
      ;;
  esac
}

# Write a run manifest for traceability.
{
  echo "run_ts=$RUN_TS"
  echo "ports=$PORTS"
  echo "url_path=$URL_PATH"
  echo "stop_policy=$STOP_POLICY"
  echo "avg_rps=$AVG_RPS avg_duration=$AVG_DURATION"
  echo "peak_steps=$PEAK_STEPS peak_to_rps=$PEAK_TO_RPS peak_step_rps=$PEAK_STEP_RPS peak_duration=$PEAK_DURATION"
  echo "bp_start=$BP_START_RPS bp_steps=$BP_STEP_1_RPS,$BP_STEP_2_RPS,$BP_STEP_3_RPS,$BP_STEP_4_RPS bp_step_duration=$BP_STEP_DURATION bp_ramp_down=$BP_RAMP_DOWN"
  echo "mysql_interval_seconds=$MYSQL_INTERVAL_SECONDS mysql_stop_buffer_seconds=$MYSQL_STOP_BUFFER_SECONDS"
} > "$RUN_DIR/manifest.txt"

write_info "Run directory: $RUN_DIR"

# Ensure k6 script relative paths resolve even if the caller's CWD is different.
cd "$SCRIPT_DIR"

for port in $PORTS; do
  write_info "========== PORT $port =========="

  port_dir="$RUN_DIR/$port"
  mkdir -p "$port_dir"

  # Preflight
  curl -s -o /dev/null -w "preflight ${port} %{http_code} %{time_total}\\n" "http://localhost:${port}${URL_PATH}" > "$port_dir/preflight.txt" || true
  write_info "PORT=$port preflight: $(cat "$port_dir/preflight.txt" 2>/dev/null || true)"

  fail_count=0

  # AVG
  avg_ec="$(run_k6_with_mysql "$port" "avg" "$K6_AVG_SECONDS" \
    "k6 run -e AVG_RPS=${AVG_RPS} -e DURATION=${AVG_DURATION} -e PRE_ALLOCATED_VUS=80 -e MAX_VUS=1200 -e TARGET_URL=http://localhost:${port}${URL_PATH} rps-load.js")"
  echo "avg_exit_code=$avg_ec" >> "$RUN_DIR/$port/summary.txt"
  if [[ "$avg_ec" -ne 0 ]]; then
    fail_count=$((fail_count + 1))
    write_info "PORT=$port avg failed (exit=$avg_ec)"
    if should_stop_after_failure "$fail_count"; then
      write_info "PORT=$port stopping after failure policy (fail_count=$fail_count)"
      continue
    fi
  fi

  # PEAK (steps)
  # Default: AVG_RPS -> PEAK_TO_RPS (step=PEAK_STEP_RPS).
  # Override with explicit list: PEAK_STEPS="400 500 600"
  last_peak_ec=0
  for step_rps in $PEAK_STEPS; do
    phase_name="peak-${step_rps}"
    peak_ec="$(run_k6_with_mysql "$port" "$phase_name" "$K6_PEAK_SECONDS" \
      "k6 run -e TARGET_RPS=${step_rps} -e PEAK_RPS=${PEAK_RPS} -e DURATION=${PEAK_DURATION} -e PRE_ALLOCATED_VUS=200 -e MAX_VUS=3000 -e TARGET_URL=http://localhost:${port}${URL_PATH} rps-peak.js")"

    echo "${phase_name}_exit_code=$peak_ec" >> "$RUN_DIR/$port/summary.txt"
    last_peak_ec="$peak_ec"

    if [[ "$peak_ec" -ne 0 ]]; then
      fail_count=$((fail_count + 1))
      write_info "PORT=$port ${phase_name} failed (exit=$peak_ec)"
      if should_stop_after_failure "$fail_count"; then
        write_info "PORT=$port stopping after failure policy (fail_count=$fail_count)"
        break
      fi
    fi
  done

  if should_stop_after_failure "$fail_count"; then
    continue
  fi

  # BREAKPOINT
  bp_ec="$(run_k6_with_mysql "$port" "breakpoint" "$K6_BP_SECONDS" \
    "k6 run -e START_RPS=${BP_START_RPS} -e STEP_1_RPS=${BP_STEP_1_RPS} -e STEP_2_RPS=${BP_STEP_2_RPS} -e STEP_3_RPS=${BP_STEP_3_RPS} -e STEP_4_RPS=${BP_STEP_4_RPS} -e STEP_DURATION=${BP_STEP_DURATION} -e RAMP_DOWN=${BP_RAMP_DOWN} -e PRE_ALLOCATED_VUS=200 -e MAX_VUS=4000 -e ABORT_ON_FAIL=true -e TARGET_URL=http://localhost:${port}${URL_PATH} rps-breakpoint.js")"
  echo "breakpoint_exit_code=$bp_ec" >> "$RUN_DIR/$port/summary.txt"
  if [[ "$bp_ec" -ne 0 ]]; then
    fail_count=$((fail_count + 1))
    write_info "PORT=$port breakpoint failed (exit=$bp_ec)"
    if should_stop_after_failure "$fail_count"; then
      write_info "PORT=$port stopping after failure policy (fail_count=$fail_count)"
      continue
    fi
  fi

  write_info "PORT=$port completed all phases"
done

write_info "All done. Artifacts: $RUN_DIR"
