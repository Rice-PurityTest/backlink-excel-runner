#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${WORKDIR:-/home/gc/.openclaw/workspace}"
JOB_NAME="backlink-excel-runner-self-check"
JOB_META="$WORKDIR/memory/backlink-runs/cron-job.json"

resolve_openclaw_bin() {
  if [[ -n "${OPENCLAW_BIN:-}" ]]; then
    echo "$OPENCLAW_BIN"
    return 0
  fi
  local bin
  bin="$(command -v openclaw 2>/dev/null || true)"
  if [[ -n "$bin" ]]; then
    echo "$bin"
    return 0
  fi
  if [[ -x "$HOME/.npm-global/bin/openclaw" ]]; then
    echo "$HOME/.npm-global/bin/openclaw"
    return 0
  fi
  if [[ -x "/home/gc/.npm-global/bin/openclaw" ]]; then
    echo "/home/gc/.npm-global/bin/openclaw"
    return 0
  fi
  echo ""
}

OPENCLAW_BIN_RESOLVED="$(resolve_openclaw_bin)"
if [[ -z "$OPENCLAW_BIN_RESOLVED" ]]; then
  echo "WARN: openclaw not found; cannot remove cron." >&2
  exit 0
fi

remove_id() {
  local id="$1"
  if [[ -n "$id" ]]; then
    "$OPENCLAW_BIN_RESOLVED" cron rm "$id" >/dev/null 2>&1 || true
  fi
}

# 1) Try removing saved job id.
if [[ -f "$JOB_META" ]]; then
  job_id="$(python3 - <<'PY' "$JOB_META"
import json,sys
try:
    print(json.load(open(sys.argv[1],'r',encoding='utf-8')).get('id',''))
except Exception:
    print('')
PY
)"
  remove_id "$job_id"
  rm -f "$JOB_META"
fi

# 2) Remove any remaining jobs with the same name.
jobs_json="$("$OPENCLAW_BIN_RESOLVED" cron list --json 2>/dev/null || echo '[]')"
ids="$(python3 - <<'PY' "$jobs_json" "$JOB_NAME"
import json,sys
data=json.loads(sys.argv[1]) if sys.argv[1].strip() else []
name=sys.argv[2]
jobs=data
if isinstance(data, dict):
    jobs=data.get('jobs') or data.get('items') or []
ids=[j.get('id','') for j in jobs if j.get('name')==name and j.get('id')]
print("\n".join(ids))
PY
)"
if [[ -n "$ids" ]]; then
  while IFS= read -r id; do
    remove_id "$id"
  done <<<"$ids"
fi

# 3) Backward-compat: remove legacy user crontab entries installed directly.
current_crontab="$(crontab -l 2>/dev/null || true)"
if [[ -n "$current_crontab" ]]; then
  filtered="$(printf '%s\n' "$current_crontab" | grep -v "$JOB_NAME" | grep -v "skills/backlink-excel-runner/scripts/self_check.sh" || true)"
  tmpfile="$(mktemp)"
  printf '%s\n' "$filtered" > "$tmpfile"
  crontab "$tmpfile"
  rm -f "$tmpfile"
fi

echo "removed openclaw cron + legacy crontab: name=$JOB_NAME"
