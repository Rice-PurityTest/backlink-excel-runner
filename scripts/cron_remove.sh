#!/usr/bin/env bash
set -euo pipefail
MARK="# backlink-excel-runner-self-check"
(tmp=$(mktemp) && crontab -l 2>/dev/null | grep -v "$MARK" > "$tmp" || true; crontab "$tmp"; rm -f "$tmp")
echo "removed cron marker: $MARK"