#!/usr/bin/env bash
set -euo pipefail
WORKDIR="/home/gc/.openclaw/workspace"
SELF_CHECK="$WORKDIR/skills/backlink-excel-runner/scripts/self_check.sh"
MARK="# backlink-excel-runner-self-check"
LINE="*/5 * * * * PATH=/home/gc/.npm-global/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin OPENCLAW_BIN=/home/gc/.npm-global/bin/openclaw BACKLINK_NOTIFY_MODE=feishu-direct BACKLINK_NOTIFY_TARGET=chat:oc_701ab7626ccf14f8e5504b669dea9008 BACKLINK_NOTIFY_MIN_INTERVAL_SEC=300 bash $SELF_CHECK $MARK"

(tmp=$(mktemp) && crontab -l 2>/dev/null | grep -v "$MARK" > "$tmp" || true; echo "$LINE" >> "$tmp"; crontab "$tmp"; rm -f "$tmp")
echo "installed cron: $LINE"