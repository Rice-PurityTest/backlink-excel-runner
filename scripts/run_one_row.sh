#!/usr/bin/env bash
set -euo pipefail

# Workspace defaults (can be overridden by env).
WORKDIR="${WORKDIR:-/home/gc/.openclaw/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DEFAULT_CFG="$WORKDIR/skills/backlink-excel-runner/assets/task-template.json"
RUNTIME_CFG="$WORKDIR/memory/backlink-runs/task.json"

# Mode/args:
#   run_one_row.sh [cfg.json] [mode]
MODE="${2:-run}"
CFG="${1:-$DEFAULT_CFG}"

# Prefer current runtime config when default template is used (not in init mode).
if [[ "$CFG" == "$DEFAULT_CFG" && -f "$RUNTIME_CFG" ]]; then
  CFG="$RUNTIME_CFG"
fi
STATE="$WORKDIR/memory/backlink-runs/worker-state.json"
ACTIVE_TASKS="$WORKDIR/memory/active-tasks.md"
XLSX_OPS="$SCRIPT_DIR/xlsx_ops.py"

update_active_task() {
  local phase="$1"
  local row="${2:-}"
  local url="${3:-}"
  local run_id="${4:-}"
  local pending="${5:-}"
  local now
  now="$(date -Is)"
  mkdir -p "$(dirname "$ACTIVE_TASKS")"
  {
    echo "## backlink-excel-runner"
    echo "- task: $(basename "$CFG")"
    echo "- phase: $phase"
    echo "- row: ${row:-none}"
    echo "- runId: ${run_id:-none}"
    echo "- url: ${url:-none}"
    echo "- pending: ${pending:-unknown}"
    echo "- updatedAt: $now"
    echo "- doneWhen: pending=0"
  } > "$ACTIVE_TASKS"
}

py_helper() {
  python3 "$XLSX_OPS" "$@"
}

write_state() {
  local status="$1"
  local phase="${2:-}"
  local row="${3:-}"
  local url="${4:-}"
  local run_id="${5:-}"
  local note="${6:-}"
  python3 - "$STATE" "$status" "$phase" "$row" "$url" "$run_id" "$note" <<'PY'
import json,sys,os,time
p,status,phase,row,url,run_id,note=sys.argv[1:8]
os.makedirs(os.path.dirname(p),exist_ok=True)
try:
    d=json.load(open(p,'r',encoding='utf-8'))
except Exception:
    d={}

d['status']=status
if phase:
    d['phase']=phase
if row:
    try:
        d['activeRow']=int(row)
    except Exception:
        d['activeRow']=row
if url:
    d['url']=url
if run_id:
    d['activeRunId']=run_id
if note:
    d['note']=note

d['lastHeartbeatTs']=int(time.time())
json.dump(d, open(p,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
PY
}

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

cfg_read_runtime() {
  local cfg_path="$1"
  python3 - "$cfg_path" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1],'r',encoding='utf-8'))
rt=cfg.get('runtime',{}) or {}
print(rt.get('sessionKey',''))
print(rt.get('replyTo',''))
print(rt.get('replyChannel','feishu'))
print(rt.get('replyAccountId','default'))
print(rt.get('skillName','backlink-excel-runner'))
PY
}

write_runtime_cfg() {
  local src="$1"
  local dst="$2"
  local session_key="$3"
  local reply_to="$4"
  local reply_channel="${5:-feishu}"
  local reply_account="${6:-default}"
  local skill_name="${7:-backlink-excel-runner}"
  python3 - "$src" "$dst" "$session_key" "$reply_to" "$reply_channel" "$reply_account" "$skill_name" <<'PY'
import json,sys,os
src,dst,session_key,reply_to,reply_channel,reply_account,skill_name=sys.argv[1:8]
cfg=json.load(open(src,'r',encoding='utf-8'))
rt=cfg.get('runtime',{}) or {}
if session_key:
    rt['sessionKey']=session_key
if reply_to:
    rt['replyTo']=reply_to
rt['replyChannel']=reply_channel or rt.get('replyChannel','feishu')
rt['replyAccountId']=reply_account or rt.get('replyAccountId','default')
rt['skillName']=skill_name or rt.get('skillName','backlink-excel-runner')
cfg['runtime']=rt
os.makedirs(os.path.dirname(dst),exist_ok=True)
with open(dst,'w',encoding='utf-8') as f:
    json.dump(cfg,f,ensure_ascii=False,indent=2)
PY
}

ensure_runtime_session() {
  local cfg_src="$CFG"
  local session_key reply_to
  local -a rt_vals
  mapfile -t rt_vals < <(cfg_read_runtime "$cfg_src")
  session_key="${rt_vals[0]:-}"
  reply_to="${rt_vals[1]:-}"

  if [[ -n "$session_key" && -n "$reply_to" ]]; then
    return 0
  fi

  echo "ERROR: missing runtime.sessionKey/replyTo. Run: scripts/init_task.sh" >&2
  return 1
}

# Compute retry-aware status when AI did not finalize the row.
mark_retry_or_need_human() {
  local row="$1"
  local reason="$2"
  local landing="${3:-}"
  local cur_status
  cur_status="$(py_helper get_status "$CFG" "$row")"
  local next_status
  next_status="$(python3 - <<'PY' "$CFG" "$cur_status" "$reason"
import json,sys,re,datetime
cfg_path,cur_status,reason=sys.argv[1:4]
cfg=json.load(open(cfg_path,'r',encoding='utf-8'))
max_retry=int(cfg.get('runtime',{}).get('maxRetryPerRow',1))
if max_retry <= 0:
    max_retry = 1

m=re.search(r'retry=(\d+)', cur_status)
prev_retry=int(m.group(1)) if m else 0
next_retry=prev_retry+1

now_dt=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
ts=now_dt.isoformat(timespec='seconds')

if next_retry >= max_retry:
    status=f"NEED_HUMAN | reason={reason} | retry={next_retry} | ts={ts}"
else:
    status=f"RETRY_PENDING | reason={reason} | retry={next_retry} | ts={ts}"
print(status)
PY
)"
  py_helper set_final "$CFG" "$row" "$next_status" "$landing" >/dev/null
  echo "$next_status"
}

build_agent_prompt() {
  local row="$1"
  local url="$2"
  local run_id="$3"
  local context_json
  local skill_name

  skill_name="$(python3 - <<'PY' "$CFG"
import json,sys
cfg=json.load(open(sys.argv[1],'r',encoding='utf-8'))
print((cfg.get('runtime',{}) or {}).get('skillName') or 'backlink-excel-runner')
PY
)"

  context_json="$(python3 - <<'PY' "$CFG" "$row" "$url" "$run_id" "$XLSX_OPS"
import json,sys,os
cfg_path,row,url,run_id,xlsx_ops=sys.argv[1:6]
row=int(row)

cfg=json.load(open(cfg_path,'r',encoding='utf-8'))

out={
  "cfgPath": cfg_path,
  "row": row,
  "url": url,
  "runId": run_id,
  "sheetName": cfg.get("sheetName"),
  "filePath": cfg.get("filePath"),
  "columns": cfg.get("columns"),
  "targetSite": cfg.get("targetSite"),
  "brandProfilePath": cfg.get("brandProfilePath"),
  "xlsxOps": xlsx_ops,
  "browser": cfg.get("browser", {}),
  "skillName": (cfg.get("runtime",{}) or {}).get("skillName") or "backlink-excel-runner",
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
)"

  cat <<EOF
/skill ${skill_name}
你是 OpenClaw 的自动化 agent，负责处理 ${skill_name} 的单行任务。

任务上下文 (JSON):
$context_json

关键要求:
1. 使用 agent-browser + CDP 9222 的浏览器会话完成任务（需要登录/注册时请走完整流程）。
2. 生成的文案要贴合页面主题与语气，不要模板化硬广。
3. 必须在结束时写回 Excel 状态：
   python3 "$XLSX_OPS" set_final "$CFG" $row "<STATUS>" "<LANDING_URL>"
   - STATUS 示例：
     - DONE | reason=... 
     - NEED_HUMAN | reason=captcha_gate
     - RETRY_PENDING | reason=auth_flow_incomplete
     - FAILED | reason=hard_error
   - LANDING_URL 为最终落地页（或可继续处理的页面）。
4. 禁止留下 IN_PROGRESS 状态不处理。
5. 如果遇到无法自动绕过的门槛（验证码/短信/人工审核/付费墙），直接 NEED_HUMAN。
6. 如果只是等待邮箱验证或需要稍后继续，用 RETRY_PENDING 并写清下一步。

开始执行。
EOF
}

run_openclaw_agent() {
  local prompt="$1"
  local run_id="$2"

  local params_json
  params_json="$(python3 - <<'PY' "$CFG" "$prompt" "$run_id"
import json,sys
cfg_path,message,run_id=sys.argv[1:4]
cfg=json.load(open(cfg_path,'r',encoding='utf-8'))
rt=cfg.get('runtime',{}) or {}
session_key=(rt.get('sessionKey') or '').strip()
reply_to=(rt.get('replyTo') or '').strip()
reply_channel=(rt.get('replyChannel') or 'feishu').strip()
reply_account=(rt.get('replyAccountId') or 'default').strip()

if not session_key or not reply_to:
    raise SystemExit("missing sessionKey/replyTo")

params={
  "message": message,
  "sessionKey": session_key,
  "deliver": True,
  "replyChannel": reply_channel,
  "replyTo": reply_to,
  "replyAccountId": reply_account,
  "idempotencyKey": f"backlink-{run_id}",
}
print(json.dumps(params,ensure_ascii=False))
PY
)" || return 1

  "$OPENCLAW_BIN_RESOLVED" gateway call agent --params "$params_json"
}

# pending count only
if [[ "$MODE" == "--pending-count" ]]; then
  py_helper pending_count "$CFG"
  exit 0
fi

RESUME=0
if [[ "$MODE" == "--resume" || "$MODE" == "resume" ]]; then
  RESUME=1
fi

row=""
url=""
run_id=""

# If resume mode: try to reuse existing IN_PROGRESS row (this worker only).
if (( RESUME == 1 )); then
  in_progress_json="$(py_helper in_progress_info "$CFG")"
  msg="$(python3 - <<'PY' "$in_progress_json"
import json,sys
print(json.loads(sys.argv[1]).get('message',''))
PY
)"

  if [[ "$msg" == "in_progress" ]]; then
    in_worker="$(python3 - <<'PY' "$in_progress_json"
import json,sys
print(json.loads(sys.argv[1]).get('worker',''))
PY
)"
    expected_worker="$(python3 - <<'PY' "$in_progress_json"
import json,sys
print(json.loads(sys.argv[1]).get('expectedWorker',''))
PY
)"

    # Never override another worker lock.
    if [[ -n "$in_worker" && "$in_worker" != "$expected_worker" ]]; then
      write_state "RUNNING" "blocked_by_existing_in_progress" "" "" "" "other_worker_in_progress"
      blocked_row="$(python3 - <<'PY' "$in_progress_json"
import json,sys
print(json.loads(sys.argv[1]).get('row',''))
PY
)"
      blocked_url="$(python3 - <<'PY' "$in_progress_json"
import json,sys
print(json.loads(sys.argv[1]).get('url',''))
PY
)"
      update_active_task "blocked_existing_in_progress" "$blocked_row" "$blocked_url"
      echo "serial_guard: existing IN_PROGRESS row found (worker=$in_worker), skip resume"
      exit 0
    fi

    # If stale, let claim_next recycle it to RETRY_PENDING first.
    stale="$(python3 - <<'PY' "$in_progress_json"
import json,sys
print('1' if json.loads(sys.argv[1]).get('stale') else '0')
PY
)"

    if [[ "$stale" == "0" ]]; then
      row="$(python3 - <<'PY' "$in_progress_json"
import json,sys
print(json.loads(sys.argv[1]).get('row',''))
PY
)"
      url="$(python3 - <<'PY' "$in_progress_json"
import json,sys
print(json.loads(sys.argv[1]).get('url',''))
PY
)"
      run_id="$(python3 - <<'PY' "$in_progress_json"
import json,sys
print(json.loads(sys.argv[1]).get('runId',''))
PY
)"
    fi
  fi
fi

# Auto-init when no runtime task exists (first run).
if [[ "$CFG" == "$DEFAULT_CFG" && ! -f "$RUNTIME_CFG" ]]; then
  if [[ -t 0 ]]; then
    if ! "$SCRIPT_DIR/init_task.sh" "$DEFAULT_CFG"; then
      echo "init failed; abort run" >&2
      exit 1
    fi
    CFG="$RUNTIME_CFG"
  else
    echo "No runtime task config. Run: $SCRIPT_DIR/init_task.sh" >&2
    exit 1
  fi
fi

# Check AI availability before claiming new rows.
OPENCLAW_BIN_RESOLVED="$(resolve_openclaw_bin)"
if [[ -z "$OPENCLAW_BIN_RESOLVED" ]]; then
  if [[ -n "$row" ]]; then
    echo "openclaw not found; mark row retry_pending"
    final_status="$(mark_retry_or_need_human "$row" "ai_unavailable" "$url")"
    write_state "IDLE" "ai_unavailable" "$row" "$url" "$run_id" "ai_unavailable"
    update_active_task "ai_unavailable" "$row" "$url" "$run_id"
    echo "ai_unavailable row=$row status=$final_status"
  else
    write_state "IDLE" "ai_unavailable" "" "" "" "openclaw_not_found"
    update_active_task "ai_unavailable" "" ""
    echo "openclaw not found; skip claim"
  fi
  exit 1
fi

# Ensure session routing info exists for gateway delivery.
if ! ensure_runtime_session; then
  if [[ -n "$row" ]]; then
    final_status="$(mark_retry_or_need_human "$row" "missing_session_routing" "$url")"
    write_state "IDLE" "missing_session_routing" "$row" "$url" "$run_id" "missing_session_routing"
    update_active_task "missing_session_routing" "$row" "$url" "$run_id"
    echo "missing_session_routing row=$row status=$final_status"
  else
    write_state "IDLE" "missing_session_routing" "" "" "" "missing_session_routing"
    update_active_task "missing_session_routing" "" ""
    echo "missing_session_routing: sessionKey/replyTo required"
  fi
  exit 1
fi

# If no resume row, claim a new row.
if [[ -z "$row" ]]; then
  claim_json="$(py_helper claim_next "$CFG")"
  echo "$claim_json"

  if echo "$claim_json" | grep -q 'no_pending_rows'; then
    write_state "IDLE" "idle_all_done" "" "" "" "all_done"
    update_active_task "idle_all_done" "" "" "" "0"
    exit 0
  fi

  if echo "$claim_json" | grep -q 'in_progress_exists'; then
    write_state "RUNNING" "blocked_by_existing_in_progress" "" "" "" "in_progress_exists"
    blocked_row="$(python3 - <<'PY' "$claim_json"
import json,sys
print(json.loads(sys.argv[1]).get('row',''))
PY
)"
    blocked_url="$(python3 - <<'PY' "$claim_json"
import json,sys
print(json.loads(sys.argv[1]).get('url',''))
PY
)"
    update_active_task "blocked_existing_in_progress" "$blocked_row" "$blocked_url"
    echo "serial_guard: existing IN_PROGRESS row found, skip new claim"
    exit 0
  fi

  row="$(python3 - <<'PY' "$claim_json"
import json,sys
print(json.loads(sys.argv[1]).get('row',''))
PY
)"
  url="$(python3 - <<'PY' "$claim_json"
import json,sys
print(json.loads(sys.argv[1]).get('url',''))
PY
)"
  run_id="$(python3 - <<'PY' "$claim_json"
import json,sys
print(json.loads(sys.argv[1]).get('runId',''))
PY
)"
fi

# Keep a non-empty run id for logging/session continuity.
if [[ -z "$run_id" ]]; then
  run_id="run-$(date +%Y%m%d-%H%M%S)-resume"
fi

# Optional site worker hook: allow domain-specific fast-path.
# Hook contract output: {"finalStatus":"...","finalLanding":"..."}
if [[ -n "${SITE_HOOK:-}" && -x "${SITE_HOOK}" ]]; then
  hook_out="$(${SITE_HOOK} "$url" "$row" "$CFG" 2>/dev/null || true)"
  if [[ -n "$hook_out" ]]; then
    final_status="$(python3 - <<'PY' "$hook_out"
import json,sys
try:
    d=json.loads(sys.argv[1]); print(d.get('finalStatus',''))
except Exception:
    print('')
PY
)"
    final_landing="$(python3 - <<'PY' "$hook_out"
import json,sys
try:
    d=json.loads(sys.argv[1]); print(d.get('finalLanding',''))
except Exception:
    print('')
PY
)"
    if [[ -n "$final_status" ]]; then
      py_helper set_final "$CFG" "$row" "$final_status" "$final_landing" >/dev/null
      write_state "IDLE" "finalized_by_site_hook" "$row" "$url" "$run_id" "finalized_by_site_hook"
      update_active_task "finalized_by_hook" "$row" "$url" "$run_id"
      echo "finalized_by_hook row=$row status=$final_status landing=$final_landing"
      exit 0
    fi
  fi
fi

write_state "RUNNING" "ai_running" "$row" "$url" "$run_id" "ai_start"
update_active_task "ai_running" "$row" "$url" "$run_id"

prompt="$(build_agent_prompt "$row" "$url" "$run_id")"

ai_ok=1
if ! run_openclaw_agent "$prompt" "$run_id"; then
  ai_ok=0
fi

# After AI finishes, verify the row is no longer IN_PROGRESS.
status_after="$(py_helper get_status "$CFG" "$row")"
status_upper="$(echo "$status_after" | tr '[:lower:]' '[:upper:]')"

if [[ "$status_upper" == IN_PROGRESS* ]]; then
  final_status="$(mark_retry_or_need_human "$row" "ai_no_final_status" "$url")"
  write_state "IDLE" "ai_no_final_status" "$row" "$url" "$run_id" "ai_no_final_status"
  update_active_task "ai_no_final_status" "$row" "$url" "$run_id"
  echo "ai_no_final_status row=$row status=$final_status"
  exit 0
fi

if (( ai_ok == 0 )); then
  # AI failed but row was finalized by AI anyway; keep status.
  write_state "IDLE" "ai_failed_but_finalized" "$row" "$url" "$run_id" "ai_failed_but_finalized"
  update_active_task "ai_failed_but_finalized" "$row" "$url" "$run_id"
  echo "ai_failed_but_finalized row=$row status=$status_after"
  exit 0
fi

write_state "IDLE" "ai_finished" "$row" "$url" "$run_id" "ai_finished"
update_active_task "ai_finished" "$row" "$url" "$run_id"

echo "ai_finished row=$row status=$status_after"
