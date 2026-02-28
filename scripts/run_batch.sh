#!/usr/bin/env bash
set -euo pipefail

# Workspace defaults (can be overridden by env).
WORKDIR="${WORKDIR:-/home/gc/.openclaw/workspace}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DEFAULT_CFG="$WORKDIR/skills/backlink-excel-runner/assets/task-template.json"
RUNTIME_CFG="$WORKDIR/memory/backlink-runs/task.json"

# Mode/args:
#   run_batch.sh [cfg.json] [mode]
MODE="${2:-run}"
CFG="${1:-$DEFAULT_CFG}"

# Prefer current runtime config when default template is used (not in init mode).
if [[ "$CFG" == "$DEFAULT_CFG" && -f "$RUNTIME_CFG" ]]; then
  CFG="$RUNTIME_CFG"
fi

STATE="$WORKDIR/memory/backlink-runs/worker-state.json"
ACTIVE_TASKS="$WORKDIR/memory/active-tasks.md"
XLSX_OPS="$SCRIPT_DIR/xlsx_ops.py"
BATCH_SIZE=20

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

build_batch_prompt() {
  local rows_json="$1"
  local run_id="$2"
  local context_json
  local skill_name

  skill_name="$(python3 - <<'PY' "$CFG"
import json,sys
cfg=json.load(open(sys.argv[1],'r',encoding='utf-8'))
print((cfg.get('runtime',{}) or {}).get('skillName') or 'backlink-excel-runner')
PY
)"

  context_json="$(python3 - <<'PY' "$CFG" "$run_id" "$XLSX_OPS" "$rows_json"
import json,sys
cfg_path,run_id,xlsx_ops,rows_json=sys.argv[1:5]
rows=json.loads(rows_json)
cfg=json.load(open(cfg_path,'r',encoding='utf-8'))

out={
  "cfgPath": cfg_path,
  "runId": run_id,
  "sheetName": cfg.get("sheetName"),
  "filePath": cfg.get("filePath"),
  "columns": cfg.get("columns"),
  "targetSite": cfg.get("targetSite"),
  "brandProfilePath": cfg.get("brandProfilePath"),
  "xlsxOps": xlsx_ops,
  "browser": cfg.get("browser", {}),
  "skillName": (cfg.get("runtime",{}) or {}).get("skillName") or "backlink-excel-runner",
  "batchSize": len(rows),
  "rows": rows,
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
)"

  cat <<PROMPT_EOF
/skill ${skill_name}
你是 OpenClaw 的自动化 agent，负责批量处理 ${skill_name} 的行任务。

任务上下文 (JSON):
$context_json

关键要求:
1. 本次最多处理 20 行（JSON 中 rows 列表）。
2. 逐行锁：每处理一行前，先执行：
   python3 "$XLSX_OPS" claim_row "$CFG" <ROW>
   - 如果返回 message=claimed 才继续处理该行。
   - 如果返回 in_progress_exists/ already_in_progress/ skipped_* / need_human_retry_exceeded，则跳过此行。
3. 每行处理完成后，必须写回 Excel 状态：
   python3 "$XLSX_OPS" set_final "$CFG" <ROW> "<STATUS>" "<LANDING_URL>"
4. 禁止留下 IN_PROGRESS 状态。
5. 如果遇到无法自动绕过的门槛（验证码/短信/人工审核/付费墙），直接 NEED_HUMAN。
6. 如果只是等待邮箱验证或需要稍后继续，用 RETRY_PENDING 并写清下一步。
7. 生成文案需贴合页面语气，不要模板化硬广。
8. 使用 agent-browser + CDP 9222 的浏览器会话完成任务。

开始执行。
PROMPT_EOF
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
  "idempotencyKey": f"backlink-batch-{run_id}",
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

# Check AI availability before batch run.
OPENCLAW_BIN_RESOLVED="$(resolve_openclaw_bin)"
if [[ -z "$OPENCLAW_BIN_RESOLVED" ]]; then
  write_state "IDLE" "ai_unavailable" "" "" "" "openclaw_not_found"
  update_active_task "ai_unavailable" "" ""
  echo "openclaw not found; skip batch"
  exit 1
fi

# Ensure session routing info exists for gateway delivery.
if ! ensure_runtime_session; then
  write_state "IDLE" "missing_session_routing" "" "" "" "missing_session_routing"
  update_active_task "missing_session_routing" "" ""
  echo "missing_session_routing: sessionKey/replyTo required"
  exit 1
fi

rows_json="$(py_helper list_next_n "$CFG" "$BATCH_SIZE")"
msg="$(python3 - <<'PY' "$rows_json"
import json,sys
print(json.loads(sys.argv[1]).get('message',''))
PY
)"

if [[ "$msg" == "in_progress_exists" ]]; then
  blocked_row="$(python3 - <<'PY' "$rows_json"
import json,sys
print(json.loads(sys.argv[1]).get('row',''))
PY
)"
  blocked_url="$(python3 - <<'PY' "$rows_json"
import json,sys
print(json.loads(sys.argv[1]).get('url',''))
PY
)"
  write_state "RUNNING" "blocked_by_existing_in_progress" "$blocked_row" "$blocked_url" "" "in_progress_exists"
  update_active_task "blocked_existing_in_progress" "$blocked_row" "$blocked_url"
  echo "serial_guard: existing IN_PROGRESS row found, skip batch"
  exit 0
fi

if [[ "$msg" == "no_pending_rows" ]]; then
  write_state "IDLE" "idle_all_done" "" "" "" "all_done"
  update_active_task "idle_all_done" "" "" "" "0"
  exit 0
fi

rows_list="$(python3 - <<'PY' "$rows_json"
import json,sys
rows=json.loads(sys.argv[1]).get('rows',[])
print(json.dumps(rows, ensure_ascii=False))
PY
)"

if [[ -z "$rows_list" || "$rows_list" == "[]" ]]; then
  write_state "IDLE" "idle_no_rows" "" "" "" "no_rows"
  update_active_task "idle_no_rows" "" ""
  exit 0
fi

first_row="$(python3 - <<'PY' "$rows_list"
import json,sys
rows=json.loads(sys.argv[1])
print(rows[0].get('row','') if rows else '')
PY
)"
first_url="$(python3 - <<'PY' "$rows_list"
import json,sys
rows=json.loads(sys.argv[1])
print(rows[0].get('url','') if rows else '')
PY
)"

run_id="batch-$(date +%Y%m%d-%H%M%S)"

write_state "RUNNING" "ai_batch_running" "$first_row" "$first_url" "$run_id" "ai_batch_start"
update_active_task "ai_batch_running" "$first_row" "$first_url" "$run_id"

prompt="$(build_batch_prompt "$rows_list" "$run_id")"

if ! run_openclaw_agent "$prompt" "$run_id"; then
  write_state "IDLE" "ai_failed" "$first_row" "$first_url" "$run_id" "ai_failed"
  update_active_task "ai_failed" "$first_row" "$first_url" "$run_id"
  echo "ai_failed batch_run_id=$run_id"
  exit 1
fi

write_state "IDLE" "ai_batch_finished" "$first_row" "$first_url" "$run_id" "ai_batch_finished"
update_active_task "ai_batch_finished" "$first_row" "$first_url" "$run_id"

echo "ai_batch_finished batch_run_id=$run_id"
