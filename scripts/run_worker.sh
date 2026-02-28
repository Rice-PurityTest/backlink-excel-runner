#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${WORKDIR:-/home/gc/.openclaw/workspace}"
RUN_BATCH="$WORKDIR/skills/backlink-excel-runner/scripts/run_batch.sh"
CFG_DEFAULT="$WORKDIR/memory/backlink-runs/task.json"
CFG_TEMPLATE="$WORKDIR/skills/backlink-excel-runner/assets/task-template.json"

CFG="${1:-$CFG_DEFAULT}"
MODE="${2:---resume}"

if [[ "$CFG" == "$CFG_DEFAULT" && ! -f "$CFG" ]]; then
  CFG="$CFG_TEMPLATE"
fi

STATE_DIR="$WORKDIR/memory/backlink-runs"
LOCK_FILE="$STATE_DIR/worker.lock"
PID_FILE="$STATE_DIR/worker.pid"
LOG_FILE="$STATE_DIR/worker.log"
LOOP_SLEEP_SEC="${WORKER_LOOP_SLEEP_SEC:-2}"

mkdir -p "$STATE_DIR"

cleanup() {
  rm -f "$PID_FILE" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Single-worker lock
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "worker_lock_held" >&2
  exit 0
fi

echo "$$" > "$PID_FILE"
echo "[$(date -Is)] worker_start pid=$$ cfg=$CFG mode=$MODE" >> "$LOG_FILE"

while true; do
  bash "$RUN_BATCH" "$CFG" "$MODE" >> "$LOG_FILE" 2>&1 || true

  pending="$(bash "$RUN_BATCH" "$CFG" --pending-count 2>/dev/null || echo 1)"
  if [[ "$pending" =~ ^0+$ ]]; then
    echo "[$(date -Is)] worker_exit all_done pending=0" >> "$LOG_FILE"
    exit 0
  fi

  sleep "$LOOP_SLEEP_SEC"
done
