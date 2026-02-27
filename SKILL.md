---
name: backlink-excel-runner
description: Execute one-row-at-a-time backlink tasks from configurable XLSX files with resilient status transitions, lock/recovery, and fixed browser runtime (agent-browser + CDP 9222 + chrome_rdp_live profile). Use for reading rows, claiming work, running submission actions, and writing D/E results.
---

# backlink-excel-runner

Execute backlink tasks from XLSX safely and recoverably.

## Scope

- Input type: **xlsx only**
- Batch size: **1 row per run**
- State machine: fixed
  - `PENDING -> IN_PROGRESS -> DONE | SKIP | FAILED | NEED_HUMAN | RETRY_PENDING`
- Browser runtime: fixed
  - `google-chrome --remote-debugging-port=9222 --user-data-dir=/home/gc/.openclaw/workspace/chrome_rdp_live`
  - `agent-browser --cdp 9222 ...`

## Required config

Load `assets/task-template.json` (copy and fill):
- `filePath`, `sheetName`
- `columns.url/method/note/status/landing`
- `targetSite`
- `brandProfilePath` (recommended): material store for reusable copy blocks
- `runtime.lockTimeoutMinutes` (recommended default 5)
- `runtime.maxRetryPerRow` (recommended default 1)

## First-run bootstrap (mandatory)

Before first execution on a new target site:
1. Ask operator to confirm target site URL.
2. Fetch key pages (`/`, `/about`, product/features/pricing pages when available).
3. Build reusable profile and save to `brandProfilePath`:
   - one-liner pitch (CN/EN)
   - 50/100/200-word descriptions
   - comment/forum/blog snippets (neutral/natural style)
   - keyword/tag pool
   - approved anchor text variants
4. Reuse this profile across rows to keep copy consistent and natural.

## Run protocol (single row)

> Serial-only rule (mandatory): at any time, only **one** row may stay `IN_PROGRESS` for this worker. Do not claim a new row until the current row is finalized to `DONE/NEED_HUMAN/FAILED/RETRY_PENDING`.

1. Validate file/sheet/column mapping.
2. Before claiming, check existing `IN_PROGRESS` rows. If one exists for this worker, continue/finalize that row first (no new claim).
3. Resolve next row (or explicit row) where status is empty or `PENDING/RETRY_PENDING`.
4. Preflight:
   - URL empty/invalid => `SKIP | reason=empty_or_invalid_url`
4. Claim lock:
   - status = `IN_PROGRESS | runId=<id> | worker=<id> | row=<n> | ts=<iso>`
5. Ensure browser is ready with fixed profile and CDP 9222.
6. Check Google session quickly (open google.com and verify account button):
   - if not logged in, continue auth ladder in step 7 (do not stop immediately).
7. Execute site workflow (auth ladder is mandatory):
   - Prefer **Continue with Google** when supported.
   - If Google login is unavailable, fallback to email registration (`alexfefun1@gmail.com` + team standard password policy).
   - If email verification is required, run `gog` verification flow (mandatory):
     - search Gmail for verification mail (by recipient alias + sender/subject keywords)
     - if not found, click site resend once and search again
     - if mail arrives, open verification link and continue submission in same row
   - Do not mark `NEED_HUMAN` only because a page requires login/email verification.
   - Minimum attempts before manual gate: `google_login_attempted` OR `email_register_attempted` must be true.
   - Record auth evidence in log/checkpoint (which path was tried, blocker text, screenshot path if any).
   - Generate context-aware copy from page semantics (topic, language, tone, moderation cues) instead of fixed templates.
   - Apply mandatory writing QA in `references/content-generation.md` before publish/submit:
     - generate 3 title candidates, choose the best-fit one
     - run title/body quality gate (reject templated ad copy)
     - verify final outbound link is exactly target site URL (no broken newline encoding)
   - For rows requiring HTML-anchor comments, prefer:
     - `<a href="https://target-domain">anchor text</a>`
     - keep surrounding sentence natural and relevant to thread/post context.
   - Do not claim guaranteed dofollow. Only verify what is observable on published page.
8. Finalize row:
   - `DONE` + landing URL in landing column
   - `NEED_HUMAN` only for non-bypassable manual gates (captcha/manual review/paywall/invite-only/KYC/SMS-only verification)
   - `RETRY_PENDING` for auth-pending states (email verification not yet consumed, temporary login failures, recoverable 4xx/5xx)
   - `FAILED` for hard failures
9. Append run log checkpoint (`memory/backlink-runs/*.jsonl`).

## Recovery rules

- Maintain lightweight runtime index in `memory/active-tasks.md` (single block for this skill): current phase, row, runId, url, updatedAt, doneWhen.
- On startup or before each run, recycle stale locks:
  - `IN_PROGRESS` older than **lockTimeoutMinutes** (default 5) => `RETRY_PENDING | reason=lock_timeout | retry=<n>`
  - if `retry >= maxRetryPerRow` (default 1), force finalize `NEED_HUMAN | reason=retry_exceeded_after_lock_timeout` and continue next row.
- Keep row-level checkpoints:
  - `claimed`, `opened`, `auth_checked`, `submitted`, `finalized`
- Never overwrite another worker lock.

## Safety + manual gates

- CAPTCHA/human verification must not be bypassed automatically.
- Capture screenshot for operator context when captcha is detected.
- On captcha/manual gate: set `NEED_HUMAN` for that row, then continue with next row (up to bounded recursion in script).

## Auth gating policy (mandatory)

- Login/Register page detected => run auth ladder first (Google -> email register -> email verification consume).
- If auth ladder not completed in current run window, do **not** use `NEED_HUMAN` by default; use:
  - `RETRY_PENDING | reason=auth_flow_incomplete`
  - include concise next action in landing/note (e.g., `await verification mail`).
- For email-verification blockers, `NEED_HUMAN` is allowed only after `gog` flow is attempted and logged:
  - first Gmail search
  - resend action on site (if available)
  - second Gmail search after resend/wait
- `NEED_HUMAN` for auth is allowed only when blocker is non-automatable:
  - captcha/human verification
  - phone/SMS OTP without integrated channel
  - manual KYC / identity check
  - invite-only approval / paid upgrade wall
- If operator later provides credentials/session, re-run row from `RETRY_PENDING` first before claiming new rows.

## Writing quality policy (mandatory)

- For text-producing rows (forum/comment/blog/article/profile), follow `references/content-generation.md` in full.
- Never publish one-line promotional copy + naked URL.
- Never use generic template titles like `<Brand> for <generic benefit>`.
- If writing QA fails, rewrite once before submit; if still failing due platform constraints, set `RETRY_PENDING | reason=content_quality_retry` with note.

## Fixed report format

After each row, report:
- row number
- URL
- final D status
- E landing URL (or pending URL)
- duration seconds
- next suggestion
- if anchor link used: rendered anchor evidence (`href`, visible text, and `rel` attribute if present)
- if auth/email verification involved: auth evidence (`google/email attempted`, `gog search counts`, `resend clicked or not`)

## Automation scripts

- `scripts/bootstrap_brand_profile.sh <config.json>`: first-run target-site bootstrap; generates `brandProfilePath` materials.
- `scripts/run_one_row.sh <config.json>`: claim and execute one row.
  - Optional: `SITE_HOOK=/path/to/hook.sh` for domain-specific auto-finalization.
- `scripts/self_check.sh`: heartbeat self-check + auto-resume.
  - includes extra stuck detection: `RUNNING` but no active `agent-browser --cdp 9222` process for a grace window.
  - writes per-run summary to `memory/backlink-runs/last-status.txt`.
  - optional status push each run via `BACKLINK_NOTIFY_CMD`.
- `scripts/cron_install.sh`: install 5-min OpenClaw cron checker.
- `scripts/cron_remove.sh`: remove OpenClaw cron checker.
- `scripts/cleanup_task.sh`: fully remove current task runtime (cron + active-tasks section + temp state files, recoverable in `.trash/`).
- Cron auto-removal: self-check removes cron when all rows are finished.

### Cron policy (mandatory)

- After first successful run bootstrap, **must install OpenClaw cron** using `scripts/cron_install.sh`.
- If cron is missing, the run is considered incomplete and should be reported as a setup issue.
- Removing cron requires explicit operator instruction.

### Task cleanup capability (mandatory)

- On operator instruction like "delete current task", run `scripts/cleanup_task.sh`.
- Cleanup scope includes:
  - current task OpenClaw cron entry (`backlink-excel-runner-self-check`)
  - current task block in `memory/active-tasks.md`
  - runtime temp files under `memory/backlink-runs/`
  - skill-generated captcha screenshots (`downloads/captcha-row-*.png`)
- Cleanup should be recoverable by default (move files to `.trash/`), not hard delete.

## References

- State machine details: `references/state-machine.md`
- Excel mapping rules: `references/excel-mapping.md`
- Recovery and heartbeat/cron guidance: `references/recovery.md`
- Context-aware copy generation + href anchor rules: `references/content-generation.md`
- Gmail verification flow (mandatory when email verify appears): `references/auth-gog.md`
