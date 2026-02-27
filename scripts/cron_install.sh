#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${WORKDIR:-/home/gc/.openclaw/workspace}"
SELF_CHECK="$WORKDIR/skills/backlink-excel-runner/scripts/self_check.sh"
DEFAULT_CFG="$WORKDIR/skills/backlink-excel-runner/assets/task-template.json"
RUNTIME_CFG="$WORKDIR/memory/backlink-runs/task.json"
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
  echo "ERROR: openclaw not found; cannot install cron." >&2
  exit 1
fi

CFG="$DEFAULT_CFG"
if [[ -f "$RUNTIME_CFG" ]]; then
  CFG="$RUNTIME_CFG"
fi

# Remove existing cron with same name (idempotent).
"$WORKDIR/skills/backlink-excel-runner/scripts/cron_remove.sh" >/dev/null 2>&1 || true

MESSAGE="/skill backlink-excel-runner self_check --cfg $CFG"

"$OPENCLAW_BIN_RESOLVED" cron add \
  --name "$JOB_NAME" \
  --cron "*/5 * * * *" \
  --session main \
  --system-event "$MESSAGE" >/dev/null

# Save job id for later removal.
jobs_json="$("$OPENCLAW_BIN_RESOLVED" cron list --json 2>/dev/null || echo '[]')"
job_id="$(python3 - <<'PY' "$jobs_json" "$JOB_NAME"
import json,sys
data=json.loads(sys.argv[1]) if sys.argv[1].strip() else []
name=sys.argv[2]
jobs=data
if isinstance(data, dict):
    jobs=data.get('jobs') or data.get('items') or []

def key(j):
    return j.get('createdAt') or j.get('created_at') or j.get('updatedAt') or ''

matched=[j for j in jobs if j.get('name')==name]
if not matched:
    print('')
    raise SystemExit(0)
matched=sorted(matched, key=key)
print(matched[-1].get('id',''))
PY
)"

if [[ -n "$job_id" ]]; then
  python3 - <<'PY' "$JOB_META" "$job_id" "$JOB_NAME"
import json,sys,os
p,job_id,name=sys.argv[1:4]
os.makedirs(os.path.dirname(p),exist_ok=True)
json.dump({"id":job_id,"name":name}, open(p,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
PY
fi

echo "installed openclaw cron: name=$JOB_NAME id=${job_id:-unknown}"
