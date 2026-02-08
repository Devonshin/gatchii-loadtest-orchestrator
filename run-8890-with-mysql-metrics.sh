#!/usr/bin/env bash

# Wrapper: run k6 + MySQL metrics for port 8890 only.
#
# Prereq env vars:
#   DB_DOCKER_HOST, DB_USER, DB_PASSWORD (and optionally DB_PORT)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PORTS="8890" "$SCRIPT_DIR/run-k6-with-mysql-metrics.sh"
