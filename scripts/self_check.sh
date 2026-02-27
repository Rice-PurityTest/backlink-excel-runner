#!/usr/bin/env bash
set -euo pipefail

WORKDIR="/home/gc/.openclaw/workspace"
STATE="$WORKDIR/memory/backlink-runs/worker-state.json"
LOG="$WORKDIR/memory/backlink-runs/self-check.log"
STATUS_TXT="$WORKDIR/memory/backlink-runs/last-status.txt"
RUN_ONE="$WORKDIR/skills/backlink-excel-runner/scripts/run_one_row.sh"
CFG="$WORKDIR/memory/backlink-runs/task.json"
if [[ ! -f "$CFG" ]]; then
  CFG="$WORKDIR/skills/backlink-excel-runner/assets/task-template.json"
fi
CRON_REMOVE="$WORKDIR/skills/backlink-excel-runner/scripts/cron_remove.sh"
HEARTBEAT_TIMEOUT_SEC=300
RUNNING_WITHOUT_AGENT_BROWSER_SEC=120
# Optional notifier command. If BACKLINK_NOTIFY_MODE=cmd, it will be executed as:
#   <BACKLINK_NOTIFY_CMD> "<summary_text>"
BACKLINK_NOTIFY_CMD="${BACKLINK_NOTIFY_CMD:-}"
# Notify mode: off | system-event | feishu-direct | cmd
BACKLINK_NOTIFY_MODE="${BACKLINK_NOTIFY_MODE:-off}"
# Minimum interval between same-state notifications (seconds)
BACKLINK_NOTIFY_MIN_INTERVAL_SEC="${BACKLINK_NOTIFY_MIN_INTERVAL_SEC:-900}"
# For feishu-direct mode, set a chat target such as: chat:oc_xxx
BACKLINK_NOTIFY_TARGET="${BACKLINK_NOTIFY_TARGET:-}"
NOTIFY_META="$WORKDIR/memory/backlink-runs/notify-state.meta"
OPENCLAW_BIN="${OPENCLAW_BIN:-$(command -v openclaw 2>/dev/null || true)}"
if [[ -z "$OPENCLAW_BIN" ]]; then
  if [[ -x "$HOME/.npm-global/bin/openclaw" ]]; then
    OPENCLAW_BIN="$HOME/.npm-global/bin/openclaw"
  elif [[ -x "/home/gc/.npm-global/bin/openclaw" ]]; then
    OPENCLAW_BIN="/home/gc/.npm-global/bin/openclaw"
  fi
fi
HEADED_SERVICE="${HEADED_SERVICE:-openclaw-headed-browser.service}"
INSTALL_HEADED_SERVICE="$WORKDIR/skills/backlink-excel-runner/scripts/install_headed_browser_service.sh"

ensure_user_bus() {
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
}

restart_headed_browser_service() {
  ensure_user_bus
  if systemctl --user restart "$HEADED_SERVICE" >/dev/null 2>&1; then
    echo "[$(date -Is)] auto-recover: restarted $HEADED_SERVICE" >> "$LOG"
    actions+=("restart_headed_service")
    return 0
  fi

  if [[ -x "$INSTALL_HEADED_SERVICE" ]]; then
    echo "[$(date -Is)] auto-recover: install/start $HEADED_SERVICE" >> "$LOG"
    if "$INSTALL_HEADED_SERVICE" "$HEADED_SERVICE" >> "$LOG" 2>&1; then
      actions+=("install_headed_service")
      return 0
    fi
  fi

  return 1
}

start_headed_direct() {
  echo "[$(date -Is)] auto-recover: direct headed launch fallback" >> "$LOG"
  pkill -f 'google-chrome.*remote-debugging-port=9222' >/dev/null 2>&1 || true
  DISPLAY=:0 XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" \
    google-chrome \
      --remote-debugging-port=9222 \
      --remote-debugging-address=127.0.0.1 \
      --user-data-dir=/home/gc/.openclaw/workspace/chrome_rdp_live \
      --no-first-run \
      --no-default-browser-check \
      --disable-dev-shm-usage \
      >> "$WORKDIR/memory/backlink-runs/chrome.log" 2>&1 &
  actions+=("start_headed_direct")
}

recover_cdp() {
  if restart_headed_browser_service; then
    sleep 2
  else
    warns+=("headed_service_unavailable")
    echo "[$(date -Is)] WARN unable to use $HEADED_SERVICE, fallback direct launch" >> "$LOG"
    start_headed_direct
    sleep 3
  fi

  for wait_s in 1 2 3; do
    if agent-browser --cdp 9222 get url >/dev/null 2>&1; then
      cdp_ok=1
      actions+=("cdp_recovered")
      echo "[$(date -Is)] auto-recover: cdp 9222 recovered" >> "$LOG"
      return 0
    fi
    sleep "$wait_s"
  done

  warns+=("cdp_recover_failed")
  echo "[$(date -Is)] WARN cdp recovery failed after retries" >> "$LOG"
  return 1
}

notify_progress_if_needed() {
  local summary="$1"
  local sig="$2"

  local now_ts
  now_ts="$(date +%s)"

  local last_ts=0
  local last_sig=""
  if [[ -f "$NOTIFY_META" ]]; then
    IFS='|' read -r last_ts last_sig < "$NOTIFY_META" || true
    [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0
  fi

  local elapsed=$((now_ts-last_ts))
  local changed=0
  [[ "$sig" != "$last_sig" ]] && changed=1

  local should_notify=0
  if (( changed == 1 || elapsed >= BACKLINK_NOTIFY_MIN_INTERVAL_SEC )); then
    should_notify=1
  fi

  if (( should_notify == 0 )); then
    return 0
  fi

  case "$BACKLINK_NOTIFY_MODE" in
    system-event)
      if [[ -x "$OPENCLAW_BIN" ]]; then
        "$OPENCLAW_BIN" system event --mode now --text "$summary" >> "$LOG" 2>&1 || echo "[$(date -Is)] WARN system-event notify failed (bin=$OPENCLAW_BIN)" >> "$LOG"
      else
        echo "[$(date -Is)] WARN system-event notify skipped (openclaw bin not found)" >> "$LOG"
      fi
      ;;
    feishu-direct)
      if [[ -x "$OPENCLAW_BIN" ]] && [[ -n "$BACKLINK_NOTIFY_TARGET" ]]; then
        "$OPENCLAW_BIN" message send --channel feishu --target "$BACKLINK_NOTIFY_TARGET" --message "$summary" >> "$LOG" 2>&1 || echo "[$(date -Is)] WARN feishu-direct notify failed (target=$BACKLINK_NOTIFY_TARGET)" >> "$LOG"
      else
        echo "[$(date -Is)] WARN feishu-direct notify skipped (bin/target missing)" >> "$LOG"
      fi
      ;;
    cmd)
      if [[ -n "$BACKLINK_NOTIFY_CMD" ]]; then
        "$BACKLINK_NOTIFY_CMD" "$summary" >> "$LOG" 2>&1 || echo "[$(date -Is)] WARN notify cmd failed" >> "$LOG"
      fi
      ;;
    *)
      # off
      return 0
      ;;
  esac

  printf '%s|%s\n' "$now_ts" "$sig" > "$NOTIFY_META"
}

mkdir -p "$(dirname "$STATE")"

echo "[$(date -Is)] self-check start" >> "$LOG"

warns=()
actions=()
cdp_ok=0
google_ok=0
agent_browser_active=0

# browser / google quick check
if agent-browser --cdp 9222 get url >/dev/null 2>&1; then
  cdp_ok=1
  if agent-browser --cdp 9222 open https://www.google.com >/dev/null 2>&1; then
    if agent-browser --cdp 9222 eval "(() => ({loggedIn: !![...document.querySelectorAll('button,a')].find(e=>(e.textContent||'').includes('Google 账号') || (e.getAttribute('aria-label')||'').includes('@'))}))()" 2>/dev/null | grep -q 'true'; then
      google_ok=1
      echo "[$(date -Is)] google session ok" >> "$LOG"
    else
      warns+=("google_not_logged_in")
      echo "[$(date -Is)] WARN google not logged in (please login once)" >> "$LOG"
    fi
  fi
else
  warns+=("cdp_not_reachable")
  echo "[$(date -Is)] WARN cdp 9222 not reachable" >> "$LOG"
  recover_cdp || true
fi

# whether agent-browser process exists (excluding this checker)
agent_browser_count="$(pgrep -af 'agent-browser --cdp 9222' | grep -v 'self_check.sh' | wc -l | tr -d ' ' || true)"
if [[ "${agent_browser_count:-0}" =~ ^[0-9]+$ ]] && (( agent_browser_count > 0 )); then
  agent_browser_active=1
fi

now=$(date +%s)
need_resume=0
status="IDLE"
hb=0
age=0
if [[ -f "$STATE" ]]; then
  read -r status hb <<<"$(python3 - <<'PY' "$STATE"
import json,sys
try:
 d=json.load(open(sys.argv[1],'r',encoding='utf-8'))
 print(d.get('status','IDLE'), int(d.get('lastHeartbeatTs',0)))
except:
 print('IDLE 0')
PY
)"
  age=$((now-hb))
  if [[ "$status" == "RUNNING" ]]; then
    if (( age > HEARTBEAT_TIMEOUT_SEC )); then
      warns+=("stale_running_${age}s")
      echo "[$(date -Is)] stale RUNNING detected age=${age}s -> resume" >> "$LOG"
      need_resume=1
    fi
    # note: run_one_row is short-lived, so no active agent-browser process is normal between checks.
    # avoid noisy warnings here; rely on stale RUNNING timeout for recovery.
  else
    need_resume=1
  fi
else
  need_resume=1
fi

if (( need_resume == 1 )); then
  echo "[$(date -Is)] resume: run_one_row" >> "$LOG"
  actions+=("resume_run_one_row")
  bash "$RUN_ONE" "$CFG" --resume >> "$LOG" 2>&1 || {
    warns+=("run_one_row_failed")
    echo "[$(date -Is)] run_one_row failed" >> "$LOG"
  }
fi

# if all done -> remove cron
pending="$(bash "$RUN_ONE" "$CFG" --pending-count 2>/dev/null || echo 1)"

if [[ "$pending" =~ ^0+$ ]]; then
  echo "[$(date -Is)] all tasks finished -> removing cron" >> "$LOG"
  actions+=("all_done_remove_cron")
  bash "$CRON_REMOVE" >> "$LOG" 2>&1 || true
fi

actions_str="${actions[*]:-none}"
warns_str="${warns[*]:-none}"
summary="[backlink self-check] status=${status} hb_age=${age}s pending=${pending} cdp_ok=${cdp_ok} google_ok=${google_ok} agent_browser_active=${agent_browser_active} actions=${actions_str} warns=${warns_str}"
echo "$summary" >> "$LOG"
printf '%s\n' "$summary" > "$STATUS_TXT"

notify_text="$(python3 - <<'PY' "$status" "$pending" "$cdp_ok" "$google_ok" "$actions_str" "$warns_str" "$age"
import sys
status,pending,cdp_ok,google_ok,actions,warns,age=sys.argv[1:8]
status_cn={'RUNNING':'运行中','IDLE':'空闲'}.get(status,status)
cdp_cn='正常' if cdp_ok=='1' else '异常（自动恢复中）'
google_cn='已登录' if google_ok=='1' else '未登录/不可用'

def map_action(a):
    m={
      'none':'无',
      'resume_run_one_row':'恢复执行1行',
      'restart_headed_service':'重启有头浏览器服务',
      'install_headed_service':'安装并启动有头服务',
      'start_headed_direct':'直接拉起有头浏览器',
      'cdp_recovered':'CDP已恢复',
      'all_done_remove_cron':'任务完成并移除cron'
    }
    return m.get(a,a)

def map_warn(w):
    if w=='none': return '无'
    if w.startswith('running_but_no_agent_browser_'):
        return '无活跃浏览器执行进程（自动恢复）'
    if w.startswith('stale_running_'):
        return '运行状态超时（自动恢复）'
    m={
      'cdp_not_reachable':'浏览器CDP不可达',
      'cdp_recover_failed':'CDP恢复失败',
      'google_not_logged_in':'Google未登录',
      'run_one_row_failed':'执行一行失败',
      'headed_service_unavailable':'有头浏览器服务不可用'
    }
    return m.get(w,w)

actions_cn='、'.join(map_action(x) for x in actions.split()) if actions else '无'
warns_cn='、'.join(map_warn(x) for x in warns.split()) if warns else '无'
msg=(
f"📌 Backlink 定时进展\n"
f"• 状态：{status_cn}\n"
f"• 剩余待处理：{pending} 条\n"
f"• 浏览器连接：{cdp_cn}\n"
f"• Google登录：{google_cn}\n"
f"• 本轮动作：{actions_cn}\n"
f"• 风险提示：{warns_cn}\n"
f"• 心跳间隔：{age}s"
)
print(msg)
PY
)"

# hb_age changes each run; use stable signature for throttled progress notify
notify_sig="status=${status};pending=${pending};cdp_ok=${cdp_ok};google_ok=${google_ok};agent_browser_active=${agent_browser_active};actions=${actions_str};warns=${warns_str}"
notify_progress_if_needed "$notify_text" "$notify_sig"

echo "[$(date -Is)] self-check end" >> "$LOG"
