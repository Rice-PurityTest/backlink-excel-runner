#!/usr/bin/env bash
set -euo pipefail

WORKDIR="/home/gc/.openclaw/workspace"
CFG="${1:-$WORKDIR/skills/backlink-excel-runner/assets/task-template.json}"
STATE="$WORKDIR/memory/backlink-runs/worker-state.json"
MAX_DEPTH="${MAX_DEPTH:-3}"
DEPTH="${DEPTH:-0}"
MODE="${2:-run}"
ACTIVE_TASKS="$WORKDIR/memory/active-tasks.md"

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
  python3 - "$@" <<'PY'
import json, zipfile, xml.etree.ElementTree as ET, re, datetime, sys, os, tempfile, shutil
mode=sys.argv[1]
cfg_path=sys.argv[2]

with open(cfg_path,'r',encoding='utf-8') as f:
    cfg=json.load(f)

xlsx=cfg['filePath']
sheet_name=cfg['sheetName']
col=cfg['columns']
status_col=col['status']; url_col=col['url']; landing_col=col['landing']
worker=cfg.get('worker','openclaw-main')

ns={'x':'http://schemas.openxmlformats.org/spreadsheetml/2006/main','r':'http://schemas.openxmlformats.org/officeDocument/2006/relationships'}
ET.register_namespace('', ns['x']); ET.register_namespace('r', ns['r'])

def col_idx(c):
    n=0
    for ch in c: n=n*26+(ord(ch)-64)
    return n

def sst_values(sst):
    return [''.join(t.text or '' for t in si.findall('.//x:t',ns)) for si in sst.findall('x:si',ns)]

def cell_val(c,sst):
    if c is None: return ''
    v=c.find('x:v',ns)
    if v is None: return ''
    raw=v.text or ''
    if c.attrib.get('t')=='s':
        vals=sst_values(sst)
        try: return vals[int(raw)]
        except: return raw
    return raw

def set_shared(cell,text,sst):
    vals=sst_values(sst)
    try:i=vals.index(text)
    except ValueError:
        i=len(vals)
        si=ET.Element('{%s}si'%ns['x'])
        t=ET.SubElement(si,'{%s}t'%ns['x']); t.text=text
        sst.append(si)
    cell.attrib['t']='s'
    v=cell.find('x:v',ns)
    if v is None: v=ET.SubElement(cell,'{%s}v'%ns['x'])
    v.text=str(i)

def load():
    zin=zipfile.ZipFile(xlsx,'r')
    wb=ET.fromstring(zin.read('xl/workbook.xml'))
    rel=ET.fromstring(zin.read('xl/_rels/workbook.xml.rels'))
    relmap={x.attrib['Id']:x.attrib['Target'] for x in rel}
    rid=None
    for s in wb.findall('.//x:sheets/x:sheet',ns):
        if s.attrib.get('name')==sheet_name:
            rid=s.attrib.get('{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id'); break
    if not rid: raise SystemExit(f'sheet not found: {sheet_name}')
    target=relmap[rid]
    if not target.startswith('xl/'): target='xl/'+target
    sh=ET.fromstring(zin.read(target))
    sst=ET.fromstring(zin.read('xl/sharedStrings.xml')) if 'xl/sharedStrings.xml' in zin.namelist() else ET.Element('{%s}sst'%ns['x'])
    return zin,target,sh,sst

def save(zin,target,sh,sst):
    vals=sst_values(sst)
    sst.attrib['count']=str(len(vals)); sst.attrib['uniqueCount']=str(len(vals))
    fd,tmp=tempfile.mkstemp(suffix='.xlsx'); os.close(fd)
    with zipfile.ZipFile(xlsx,'r') as zin2, zipfile.ZipFile(tmp,'w',compression=zipfile.ZIP_DEFLATED) as zout:
        for item in zin2.infolist():
            data=zin2.read(item.filename)
            if item.filename==target: data=ET.tostring(sh,encoding='utf-8',xml_declaration=True)
            elif item.filename=='xl/sharedStrings.xml': data=ET.tostring(sst,encoding='utf-8',xml_declaration=True)
            zout.writestr(item,data)
    shutil.move(tmp,xlsx)

if mode=='claim_next':
    zin,target,sh,sst=load()
    sheetData=sh.find('x:sheetData',ns)

    # serial-only guard + stale lock recycle
    lock_timeout_min=int(cfg.get('runtime',{}).get('lockTimeoutMinutes',10))
    max_retry_per_row=int(cfg.get('runtime',{}).get('maxRetryPerRow',1))
    now_dt=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))

    for row in sheetData.findall('x:row',ns):
        r=int(row.attrib.get('r','0'))
        if r<=1: continue
        m={re.sub(r'\d','',c.attrib.get('r','')): c for c in row.findall('x:c',ns)}
        url=str(cell_val(m.get(url_col),sst)).strip()
        st_raw=str(cell_val(m.get(status_col),sst)).strip()
        st=st_raw.upper()
        if not url: continue
        if st.startswith('IN_PROGRESS'):
            # parse worker + ts + retry from status text
            mw=re.search(r'worker=([^|]+)', st_raw)
            mts=re.search(r'ts=([^|]+)', st_raw)
            mr_retry=re.search(r'retry=(\d+)', st_raw)
            lock_worker=(mw.group(1).strip() if mw else '')
            lock_ts_raw=(mts.group(1).strip() if mts else '')
            lock_retry=(int(mr_retry.group(1)) if mr_retry else 0)

            # never overwrite another worker lock
            if lock_worker and lock_worker != worker:
                print(json.dumps({'ok':True,'message':'in_progress_exists','row':r,'url':url,'status':st_raw}, ensure_ascii=False)); raise SystemExit(0)

            # recycle stale lock -> RETRY_PENDING
            stale=False
            if lock_ts_raw:
                try:
                    lock_dt=datetime.datetime.fromisoformat(lock_ts_raw)
                    if lock_dt.tzinfo is None:
                        lock_dt=lock_dt.replace(tzinfo=datetime.timezone(datetime.timedelta(hours=8)))
                    age_sec=(now_dt-lock_dt).total_seconds()
                    if age_sec >= lock_timeout_min*60:
                        stale=True
                except Exception:
                    stale=False

            if stale:
                ref=f'{status_col}{r}'
                c=None
                for cc in row.findall('x:c',ns):
                    if cc.attrib.get('r')==ref: c=cc
                if c is None:
                    c=ET.SubElement(row,'{%s}c'%ns['x'],{'r':ref})
                ts=now_dt.isoformat(timespec='seconds')
                next_retry=lock_retry+1
                if next_retry >= max_retry_per_row:
                    set_shared(c,f'NEED_HUMAN | reason=retry_exceeded_after_lock_timeout | retry={next_retry} | ts={ts}',sst)
                else:
                    set_shared(c,f'RETRY_PENDING | reason=lock_timeout | retry={next_retry} | ts={ts}',sst)
                save(zin,target,sh,sst)
                # continue scan after recycle/finalize
                continue

            print(json.dumps({'ok':True,'message':'in_progress_exists','row':r,'url':url,'status':st_raw}, ensure_ascii=False)); raise SystemExit(0)

    picked=None
    for row in sheetData.findall('x:row',ns):
        r=int(row.attrib.get('r','0'))
        if r<=1: continue
        m={re.sub(r'\d','',c.attrib.get('r','')): c for c in row.findall('x:c',ns)}
        url=str(cell_val(m.get(url_col),sst)).strip()
        st_raw=str(cell_val(m.get(status_col),sst)).strip()
        st=st_raw.upper()
        if not url: continue

        # hard-stop rows that exceeded retry budget
        if st.startswith('RETRY_PENDING'):
            mr_retry=re.search(r'retry=(\d+)', st_raw)
            retry_val=(int(mr_retry.group(1)) if mr_retry else 1)
            if retry_val >= max_retry_per_row:
                ref=f'{status_col}{r}'
                c=None
                for cc in row.findall('x:c',ns):
                    if cc.attrib.get('r')==ref: c=cc
                if c is None:
                    c=ET.SubElement(row,'{%s}c'%ns['x'],{'r':ref})
                ts=now_dt.isoformat(timespec='seconds')
                set_shared(c,f'NEED_HUMAN | reason=retry_exceeded | retry={retry_val} | ts={ts}',sst)
                save(zin,target,sh,sst)
                continue

        if st=='' or st.startswith('PENDING') or st.startswith('RETRY_PENDING'):
            picked=(row,r,url,st_raw); break
    if not picked:
        print(json.dumps({'ok':True,'message':'no_pending_rows'})); raise SystemExit(0)

    row,r,url,prev_status_raw=picked
    # invalid URL fast skip
    if not re.match(r'^https?://',url,re.I):
        c=None
        ref=f'{status_col}{r}'
        for cc in row.findall('x:c',ns):
            if cc.attrib.get('r')==ref: c=cc
        if c is None:
            c=ET.SubElement(row,'{%s}c'%ns['x'],{'r':ref})
        set_shared(c,'SKIP | reason=empty_or_invalid_url',sst)
        save(zin,target,sh,sst)
        print(json.dumps({'ok':True,'row':r,'url':url,'status':'SKIP | reason=empty_or_invalid_url'})); raise SystemExit(0)

    run_id='run-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    ts=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(timespec='seconds')
    prev_retry=0
    if prev_status_raw.upper().startswith('RETRY_PENDING'):
        mr_retry=re.search(r'retry=(\d+)', prev_status_raw)
        prev_retry=(int(mr_retry.group(1)) if mr_retry else 1)
    status=f'IN_PROGRESS | runId={run_id} | worker={worker} | row={r} | retry={prev_retry} | ts={ts}'
    ref=f'{status_col}{r}'
    c=None
    for cc in row.findall('x:c',ns):
        if cc.attrib.get('r')==ref: c=cc
    if c is None: c=ET.SubElement(row,'{%s}c'%ns['x'],{'r':ref})
    set_shared(c,status,sst)
    save(zin,target,sh,sst)
    print(json.dumps({'ok':True,'row':r,'url':url,'runId':run_id,'status':status},ensure_ascii=False))

elif mode=='set_final':
    row_num=int(sys.argv[3]); status_text=sys.argv[4]; landing=sys.argv[5] if len(sys.argv)>5 else ''
    zin,target,sh,sst=load(); sheetData=sh.find('x:sheetData',ns)
    row=None
    for rr in sheetData.findall('x:row',ns):
        if int(rr.attrib.get('r','0'))==row_num: row=rr; break
    if row is None: row=ET.SubElement(sheetData,'{%s}row'%ns['x'],{'r':str(row_num)})

    for colname,text in [(status_col,status_text),(landing_col,landing)]:
        ref=f'{colname}{row_num}'; c=None
        for cc in row.findall('x:c',ns):
            if cc.attrib.get('r')==ref: c=cc
        if c is None: c=ET.SubElement(row,'{%s}c'%ns['x'],{'r':ref})
        set_shared(c,text,sst)
    save(zin,target,sh,sst)
    print(json.dumps({'ok':True,'row':row_num,'status':status_text,'landing':landing},ensure_ascii=False))

elif mode=='pending_count':
    zin,target,sh,sst=load(); sheetData=sh.find('x:sheetData',ns)
    cnt=0
    for row in sheetData.findall('x:row',ns):
        r=int(row.attrib.get('r','0'))
        if r<=1: continue
        m={re.sub(r'\d','',c.attrib.get('r','')): c for c in row.findall('x:c',ns)}
        url=str(cell_val(m.get(url_col),sst)).strip()
        st=str(cell_val(m.get(status_col),sst)).strip().upper()
        if not url: continue
        if st=='' or st.startswith('PENDING') or st.startswith('RETRY_PENDING') or st.startswith('IN_PROGRESS'):
            cnt+=1
    print(cnt)

else:
    raise SystemExit('unknown mode')
PY
}

if [[ "$MODE" == "--pending-count" ]]; then
  py_helper pending_count "$CFG"
  exit 0
fi

# claim
claim_json="$(py_helper claim_next "$CFG")"
echo "$claim_json"

if echo "$claim_json" | grep -q 'no_pending_rows'; then
  python3 - <<'PY' "$STATE"
import json,sys,os,time
p=sys.argv[1]
os.makedirs(os.path.dirname(p),exist_ok=True)
json.dump({'status':'IDLE','lastHeartbeatTs':int(time.time())}, open(p,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
PY
  update_active_task "idle_all_done" "" "" "" "0"
  exit 0
fi

if echo "$claim_json" | grep -q 'in_progress_exists'; then
  python3 - <<'PY' "$STATE"
import json,sys,os,time
p=sys.argv[1]
os.makedirs(os.path.dirname(p),exist_ok=True)
json.dump({'status':'RUNNING','phase':'blocked_by_existing_in_progress','lastHeartbeatTs':int(time.time())}, open(p,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
PY
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

# heartbeat state
python3 - <<'PY' "$STATE" "$row" "$url" "$run_id"
import json,sys,os,time
p,row,url,run_id=sys.argv[1],int(sys.argv[2]),sys.argv[3],sys.argv[4]
os.makedirs(os.path.dirname(p),exist_ok=True)
json.dump({'status':'RUNNING','activeRunId':run_id,'activeRow':row,'phase':'claimed','lastHeartbeatTs':int(time.time()),'url':url}, open(p,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
PY
update_active_task "claimed" "$row" "$url" "$run_id"

# open page and detect captcha-like gate
agent-browser --cdp 9222 open "$url" >/dev/null 2>&1 || true
text_json="$(agent-browser --cdp 9222 eval "(() => ({url:location.href,text:(document.body?.innerText||'').slice(0,4000)}))()" 2>/dev/null || echo '{}')"

# optional site worker hook: if provided and returns JSON with finalStatus/finalLanding, write final directly
# hook contract example output: {"finalStatus":"DONE | type=profile | note=ok","finalLanding":"https://example.com/profile"}
if [[ -n "${SITE_HOOK:-}" && -x "${SITE_HOOK}" ]]; then
  hook_out="$(${SITE_HOOK} "$url" "$row" "$CFG" 2>/dev/null || true)"
  if [[ -n "$hook_out" ]]; then
    final_status="$(python3 - <<'PY' "$hook_out"
import json,sys
try:d=json.loads(sys.argv[1]); print(d.get('finalStatus',''))
except: print('')
PY
)"
    final_landing="$(python3 - <<'PY' "$hook_out"
import json,sys
try:d=json.loads(sys.argv[1]); print(d.get('finalLanding',''))
except: print('')
PY
)"
    if [[ -n "$final_status" ]]; then
      py_helper set_final "$CFG" "$row" "$final_status" "$final_landing" >/dev/null
      python3 - <<'PY' "$STATE"
import json,sys,time
p=sys.argv[1]
json.dump({'status':'IDLE','lastHeartbeatTs':int(time.time()),'note':'finalized_by_site_hook'}, open(p,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
PY
      update_active_task "finalized_by_hook" "$row" "$url" "$run_id"
      echo "finalized_by_hook row=$row status=$final_status landing=$final_landing"
      exit 0
    fi
  fi
fi

is_captcha="$(python3 - <<'PY' "$text_json"
import json,sys,re
try:d=json.loads(sys.argv[1])
except: d={}
t=(d.get('text') or '').lower()
keys=['captcha','turnstile','recaptcha','verify you are human','human verification','验证码','人机验证']
print('1' if any(k in t for k in keys) else '0')
PY
)"

if [[ "$is_captcha" == "1" ]]; then
  ts=$(date +%Y%m%d-%H%M%S)
  shot="/home/gc/.openclaw/workspace/downloads/captcha-row-${row}-${ts}.png"
  agent-browser --cdp 9222 screenshot "$shot" >/dev/null 2>&1 || true
  py_helper set_final "$CFG" "$row" "NEED_HUMAN | reason=captcha_gate" "$url (pending captcha)" >/dev/null
  python3 - <<'PY' "$STATE"
import json,sys,time
p=sys.argv[1]
json.dump({'status':'IDLE','lastHeartbeatTs':int(time.time()),'note':'captcha_skipped'}, open(p,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
PY
  update_active_task "need_human_captcha" "$row" "$url" "$run_id"
  echo "captcha_detected row=$row -> NEED_HUMAN, screenshot=$shot"

  if (( DEPTH < MAX_DEPTH )); then
    DEPTH=$((DEPTH+1)) MAX_DEPTH="$MAX_DEPTH" "$0" "$CFG"
  fi
  exit 0
fi

# leave row in progress for manual site-specific worker continuation
python3 - <<'PY' "$STATE"
import json,sys,time
p=sys.argv[1]
d=json.load(open(p,'r',encoding='utf-8')) if True else {}
d['phase']='opened'
d['lastHeartbeatTs']=int(time.time())
json.dump(d, open(p,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
PY
update_active_task "opened" "$row" "$url" "$run_id"

# generic attempt chain (no SITE_HOOK required): try form/comment fill + submit once
payload_json="$(python3 - <<'PY' "$CFG"
import json,sys,os
cfg=json.load(open(sys.argv[1],'r',encoding='utf-8'))
target=(cfg.get('targetSite') or '').strip() or 'https://exactstatement.com/'
brand_path=cfg.get('brandProfilePath','')
name='Alex'
email='alexfefun1@gmail.com'
title='Useful option for PDF bank statement to CSV/Excel'
body='I tested this workflow recently. If you need to convert PDF bank statements into CSV/Excel for bookkeeping import, this was useful: '+target
if brand_path and os.path.exists(brand_path):
    try:
        bp=json.load(open(brand_path,'r',encoding='utf-8'))
        title=(bp.get('summary',{}).get('oneLinerEN') or title)[:120]
        body=(bp.get('commentTemplates',{}).get('forumNaturalEN') or body)
        if target not in body:
            body=f"{body} {target}".strip()
    except Exception:
        pass
out={
  'name':name,
  'email':email,
  'title':title,
  'body':body,
  'target':target,
  'website':target,
}
print(json.dumps(out,ensure_ascii=False))
PY
)"

attempt_json="$(agent-browser --cdp 9222 eval "(() => {
  const payload = ${payload_json};
  const visible = (el) => {
    if (!el) return false;
    const s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden') return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };
  const setVal = (el, val) => {
    if (!el || el.disabled || el.readOnly || !visible(el)) return false;
    el.focus();
    el.value = val;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return true;
  };

  const forms = [...document.querySelectorAll('form')];
  let filled = 0;
  let submitted = false;
  let hasPasswordField = false;
  let foundActionableForm = false;

  const matchKey = (el) => ((el.name||'') + ' ' + (el.id||'') + ' ' + (el.placeholder||'') + ' ' + (el.getAttribute('aria-label')||'')).toLowerCase();

  for (const form of forms) {
    const controls = [...form.querySelectorAll('textarea,input,select')];
    if (!controls.length) continue;
    let localFilled = 0;

    for (const el of controls) {
      const tag = el.tagName.toLowerCase();
      const type = (el.type || '').toLowerCase();
      const key = matchKey(el);

      if (type === 'password') hasPasswordField = true;
      if (type === 'hidden' || type === 'file' || type === 'submit' || type === 'button' || type === 'reset') continue;
      if (type === 'checkbox' || type === 'radio') {
        if (/(agree|consent|terms|policy|i\s*accept)/.test(key) && !el.checked) {
          el.click();
        }
        continue;
      }

      let val = '';
      if (tag === 'textarea' || /(comment|message|content|body|detail|description)/.test(key)) {
        val = payload.body;
      } else if (/(title|subject|headline)/.test(key)) {
        val = payload.title;
      } else if (type === 'email' || /email/.test(key)) {
        val = payload.email;
      } else if (type === 'url' || /(url|website|site|link|homepage)/.test(key)) {
        val = payload.website;
      } else if (/(name|author|username|nickname|nick)/.test(key)) {
        val = payload.name;
      } else if (type === 'text') {
        val = payload.body;
      }

      if (val && setVal(el, val)) {
        localFilled += 1;
      }
    }

    if (localFilled > 0) {
      foundActionableForm = true;
      filled += localFilled;
      const submitEl = form.querySelector('button[type=\"submit\"],input[type=\"submit\"],button:not([type]),button[type=\"button\"].submit');
      if (submitEl && visible(submitEl)) {
        submitEl.click();
        submitted = true;
        break;
      }
    }
  }

  // fallback: textarea + nearby button (outside form layouts)
  if (!submitted) {
    const ta = [...document.querySelectorAll('textarea')].find(visible);
    if (ta && setVal(ta, payload.body)) {
      foundActionableForm = true;
      filled += 1;
      const btn = [...document.querySelectorAll('button,input[type=\"submit\"]')].find(el => visible(el) && /(post|reply|submit|publish|send|comment|发布|提交|回复)/i.test((el.innerText||el.value||el.getAttribute('aria-label')||'')));
      if (btn) {
        btn.click();
        submitted = true;
      }
    }
  }

  return {
    attempted: foundActionableForm,
    filled,
    submitted,
    hasPasswordField,
    forms: forms.length,
    url: location.href,
    title: document.title || ''
  };
})()" 2>/dev/null || echo '{}')"

agent-browser --cdp 9222 wait 3000 >/dev/null 2>&1 || true
post_json="$(agent-browser --cdp 9222 eval "(() => ({url:location.href,title:document.title||'',text:(document.body?.innerText||'').slice(0,5000)}))()" 2>/dev/null || echo '{}')"

decision_json="$(python3 - <<'PY' "$attempt_json" "$post_json" "$url"
import json,sys
try:a=json.loads(sys.argv[1])
except: a={}
try:p=json.loads(sys.argv[2])
except: p={}
start_url=(sys.argv[3] or '').strip()
text=(p.get('text') or '').lower()
cur=(p.get('url') or start_url or '').strip()
submitted=bool(a.get('submitted'))
attempted=bool(a.get('attempted'))
filled=int(a.get('filled') or 0)
has_password=bool(a.get('hasPasswordField'))

captcha_keys=['captcha','turnstile','recaptcha','verify you are human','human verification','验证码','人机验证']
success_keys=['thank you','thanks for','submitted','submission received','pending review','posted','published','comment is awaiting','审核','已提交','发布成功']
login_keys=['sign in','log in','login','register','create account','登录','注册']

if any(k in text for k in captcha_keys):
    print(json.dumps({'status':'NEED_HUMAN | reason=captcha_gate_after_submit','landing':cur or start_url})); raise SystemExit(0)

if submitted and (cur != start_url or any(k in text for k in success_keys)):
    print(json.dumps({'status':'DONE | reason=auto_submit_success','landing':cur or start_url})); raise SystemExit(0)

if submitted:
    print(json.dumps({'status':'RETRY_PENDING | reason=submitted_no_confirmation','landing':cur or start_url})); raise SystemExit(0)

if has_password or any(k in text for k in login_keys):
    print(json.dumps({'status':'RETRY_PENDING | reason=auth_required_or_login_wall','landing':cur or start_url})); raise SystemExit(0)

if attempted and filled>0:
    print(json.dumps({'status':'RETRY_PENDING | reason=form_filled_no_submit_control','landing':cur or start_url})); raise SystemExit(0)

print(json.dumps({'status':'RETRY_PENDING | reason=no_actionable_form_detected','landing':cur or start_url}))
PY
)"

final_status="$(python3 - <<'PY' "$decision_json"
import json,sys
print(json.loads(sys.argv[1]).get('status','RETRY_PENDING | reason=decision_parse_failed'))
PY
)"
final_landing="$(python3 - <<'PY' "$decision_json"
import json,sys
print(json.loads(sys.argv[1]).get('landing',''))
PY
)"

py_helper set_final "$CFG" "$row" "$final_status" "$final_landing" >/dev/null
python3 - <<'PY' "$STATE"
import json,sys,time
p=sys.argv[1]
json.dump({'status':'IDLE','lastHeartbeatTs':int(time.time()),'note':'finalized_generic_attempt'}, open(p,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
PY
update_active_task "finalized_generic_attempt" "$row" "$url" "$run_id"
echo "finalized_generic_attempt row=$row status=$final_status landing=$final_landing"
