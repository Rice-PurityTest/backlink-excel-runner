#!/usr/bin/env bash
set -euo pipefail

WORKDIR="/home/gc/.openclaw/workspace"
CRON_REMOVE="$WORKDIR/skills/backlink-excel-runner/scripts/cron_remove.sh"
ACTIVE_TASKS="$WORKDIR/memory/active-tasks.md"
RUN_DIR="$WORKDIR/memory/backlink-runs"
DL_DIR="$WORKDIR/downloads"
TS="$(date +%Y%m%d-%H%M%S)"
TRASH_DIR="$WORKDIR/.trash/backlink-task-cleanup-$TS"
mkdir -p "$TRASH_DIR"

# 1) remove cron (idempotent)
bash "$CRON_REMOVE" >/dev/null 2>&1 || true

# 2) remove backlink section in active-tasks.md (or archive whole file if simple)
if [[ -f "$ACTIVE_TASKS" ]]; then
  python3 - <<'PY' "$ACTIVE_TASKS" "$TRASH_DIR"
import sys, pathlib, re, shutil
p=pathlib.Path(sys.argv[1]); trash=pathlib.Path(sys.argv[2])
text=p.read_text(encoding='utf-8')
pat=re.compile(r'(?ms)^## backlink-excel-runner\n(?:- .*\n)*')
new=pat.sub('', text).strip()
if new==text.strip():
    # no section found, still archive a copy for traceability
    shutil.copy2(p, trash / 'active-tasks.md.bak')
else:
    shutil.copy2(p, trash / 'active-tasks.md.bak')
    if new:
        p.write_text(new+'\n', encoding='utf-8')
    else:
        p.unlink(missing_ok=True)
PY
fi

# 3) move runtime temp files to trash (recoverable)
if [[ -d "$RUN_DIR" ]]; then
  shopt -s nullglob
  for f in "$RUN_DIR"/*; do
    mv "$f" "$TRASH_DIR/"
  done
fi

# 4) move captcha screenshots for this skill
if [[ -d "$DL_DIR" ]]; then
  shopt -s nullglob
  for f in "$DL_DIR"/captcha-row-*.png; do
    mv "$f" "$TRASH_DIR/"
  done
fi

# 5) kill related local processes best-effort
pkill -f "skills/backlink-excel-runner/scripts/run_one_row.sh" >/dev/null 2>&1 || true
pkill -f "skills/backlink-excel-runner/scripts/self_check.sh" >/dev/null 2>&1 || true

# report
left_cron="$(crontab -l 2>/dev/null | grep -c 'backlink-excel-runner-self-check' || true)"
echo "cleanup_done trash=$TRASH_DIR cron_left=$left_cron"
ls -1 "$TRASH_DIR" 2>/dev/null || true
