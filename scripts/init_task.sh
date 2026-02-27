#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${WORKDIR:-/home/gc/.openclaw/workspace}"
DEFAULT_CFG="$WORKDIR/skills/backlink-excel-runner/assets/task-template.json"
RUNTIME_CFG="$WORKDIR/memory/backlink-runs/task.json"

TEMPLATE="${1:-$DEFAULT_CFG}"

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

write_task_cfg() {
  local template="$1"
  local out="$2"
  local file_path="$3"
  local sheet_name="$4"
  local target_site="$5"
  local brand_path="$6"
  local url_col="$7"
  local method_col="$8"
  local note_col="$9"
  local status_col="${10}"
  local landing_col="${11}"
  local worker="${12}"
  python3 - "$template" "$out" "$file_path" "$sheet_name" "$target_site" "$brand_path" \
    "$url_col" "$method_col" "$note_col" "$status_col" "$landing_col" "$worker" <<'PY'
import json,sys,os
tpl,out,file_path,sheet_name,target_site,brand_path,url_col,method_col,note_col,status_col,landing_col,worker=sys.argv[1:13]
cfg=json.load(open(tpl,'r',encoding='utf-8'))
if file_path: cfg['filePath']=file_path
if sheet_name: cfg['sheetName']=sheet_name
if target_site: cfg['targetSite']=target_site
if brand_path: cfg['brandProfilePath']=brand_path
cols=cfg.get('columns',{}) or {}
if url_col: cols['url']=url_col
if method_col: cols['method']=method_col
if note_col: cols['note']=note_col
if status_col: cols['status']=status_col
if landing_col: cols['landing']=landing_col
cfg['columns']=cols
if worker: cfg['worker']=worker
os.makedirs(os.path.dirname(out),exist_ok=True)
with open(out,'w',encoding='utf-8') as f:
    json.dump(cfg,f,ensure_ascii=False,indent=2)
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

discover_session_params() {
  local output
  output="$("$OPENCLAW_BIN_RESOLVED" channels status --probe 2>/dev/null || "$OPENCLAW_BIN_RESOLVED" channels status 2>/dev/null || true)"
  python3 - "$output" <<'PY'
import re,sys,json
text=sys.argv[1] or ''
session_key=''
reply_to=''

pat=re.search(r'(agent:[A-Za-z0-9_-]+:feishu:(?:group|channel):[A-Za-z0-9_-]+)', text)
if pat:
    session_key=pat.group(1).strip().strip('",')

chat=re.search(r'chat:([A-Za-z0-9_-]+)', text)
if chat:
    reply_to='chat:'+chat.group(1)

if not reply_to and session_key:
    reply_to='chat:'+session_key.split(':')[-1]

print(json.dumps({'sessionKey':session_key,'replyTo':reply_to},ensure_ascii=False))
PY
}

if [[ ! -t 0 ]]; then
  echo "ERROR: init requires an interactive TTY." >&2
  exit 1
fi

defaults_json="$(python3 - <<'PY' "$TEMPLATE"
import json,sys
cfg=json.load(open(sys.argv[1],'r',encoding='utf-8'))
print(json.dumps({
  "filePath": cfg.get("filePath",""),
  "sheetName": cfg.get("sheetName",""),
  "targetSite": cfg.get("targetSite",""),
  "brandProfilePath": cfg.get("brandProfilePath",""),
  "worker": cfg.get("worker","openclaw-main"),
  "columns": cfg.get("columns",{}) or {},
}, ensure_ascii=False))
PY
)"

def_file="$(python3 - <<'PY' "$defaults_json"
import json,sys; print(json.loads(sys.argv[1]).get('filePath',''))
PY
)"
def_sheet="$(python3 - <<'PY' "$defaults_json"
import json,sys; print(json.loads(sys.argv[1]).get('sheetName',''))
PY
)"
def_target="$(python3 - <<'PY' "$defaults_json"
import json,sys; print(json.loads(sys.argv[1]).get('targetSite',''))
PY
)"
def_brand="$(python3 - <<'PY' "$defaults_json"
import json,sys; print(json.loads(sys.argv[1]).get('brandProfilePath',''))
PY
)"
def_worker="$(python3 - <<'PY' "$defaults_json"
import json,sys; print(json.loads(sys.argv[1]).get('worker',''))
PY
)"
def_url="$(python3 - <<'PY' "$defaults_json"
import json,sys; print((json.loads(sys.argv[1]).get('columns') or {}).get('url','A'))
PY
)"
def_method="$(python3 - <<'PY' "$defaults_json"
import json,sys; print((json.loads(sys.argv[1]).get('columns') or {}).get('method','B'))
PY
)"
def_note="$(python3 - <<'PY' "$defaults_json"
import json,sys; print((json.loads(sys.argv[1]).get('columns') or {}).get('note','C'))
PY
)"
def_status="$(python3 - <<'PY' "$defaults_json"
import json,sys; print((json.loads(sys.argv[1]).get('columns') or {}).get('status','D'))
PY
)"
def_landing="$(python3 - <<'PY' "$defaults_json"
import json,sys; print((json.loads(sys.argv[1]).get('columns') or {}).get('landing','E'))
PY
)"

read -r -p "Excel 文件路径 [${def_file}]: " file_path
read -r -p "Sheet 名称 [${def_sheet}]: " sheet_name
read -r -p "目标网站 URL [${def_target}]: " target_site
read -r -p "品牌素材文件路径(可空) [${def_brand}]: " brand_path
read -r -p "Worker 名称 [${def_worker}]: " worker
read -r -p "URL 列 [${def_url}]: " url_col
read -r -p "Method 列 [${def_method}]: " method_col
read -r -p "Note 列 [${def_note}]: " note_col
read -r -p "Status 列 [${def_status}]: " status_col
read -r -p "Landing 列 [${def_landing}]: " landing_col

file_path="${file_path:-$def_file}"
sheet_name="${sheet_name:-$def_sheet}"
target_site="${target_site:-$def_target}"
brand_path="${brand_path:-$def_brand}"
worker="${worker:-$def_worker}"
url_col="${url_col:-$def_url}"
method_col="${method_col:-$def_method}"
note_col="${note_col:-$def_note}"
status_col="${status_col:-$def_status}"
landing_col="${landing_col:-$def_landing}"

write_task_cfg "$TEMPLATE" "$RUNTIME_CFG" "$file_path" "$sheet_name" "$target_site" "$brand_path" \
  "$url_col" "$method_col" "$note_col" "$status_col" "$landing_col" "$worker"

OPENCLAW_BIN_RESOLVED="$(resolve_openclaw_bin)"
if [[ -z "$OPENCLAW_BIN_RESOLVED" ]]; then
  echo "WARN: openclaw not found; skip session routing init." >&2
  exit 1
fi

cand_json="$(discover_session_params)"
cand_session="$(python3 - <<'PY' "$cand_json"
import json,sys
print(json.loads(sys.argv[1]).get('sessionKey',''))
PY
)"
cand_reply="$(python3 - <<'PY' "$cand_json"
import json,sys
print(json.loads(sys.argv[1]).get('replyTo',''))
PY
)"

if [[ -n "$cand_session" || -n "$cand_reply" ]]; then
  echo "Detected OpenClaw session routing:"
  echo "  sessionKey: ${cand_session:-<empty>}"
  echo "  replyTo:    ${cand_reply:-<empty>}"
  read -r -p "Use these values and write to $RUNTIME_CFG ? [Y/n] " ans
  if [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]; then
    session_key="$cand_session"
    reply_to="$cand_reply"
  fi
fi

if [[ -z "${session_key:-}" || -z "${reply_to:-}" ]]; then
  read -r -p "Enter sessionKey (agent:...): " session_key
  read -r -p "Enter replyTo (chat:...): " reply_to
fi

if [[ -z "${session_key:-}" || -z "${reply_to:-}" ]]; then
  echo "ERROR: sessionKey/replyTo required to route agent calls." >&2
  exit 1
fi

write_runtime_cfg "$RUNTIME_CFG" "$RUNTIME_CFG" "$session_key" "$reply_to" "feishu" "default" "backlink-excel-runner"

echo "初始化完成: $RUNTIME_CFG"
