# Recovery / Self-check

## Lock timeout
- If row status is `IN_PROGRESS` and timestamp older than `lockTimeoutMinutes` (default 5m):
  - increment retry counter and set `RETRY_PENDING | reason=lock_timeout | retry=<n> | ts=<iso>`
- If retry counter reaches `maxRetryPerRow` (default 1):
  - set `NEED_HUMAN | reason=retry_exceeded_after_lock_timeout | retry=<n> | ts=<iso>`
  - continue with next row (do not block the queue)

## Checkpoint log
Write JSONL to `memory/backlink-runs/<date>.jsonl`:
- runId, row, url
- phase (`claimed/opened/auth_checked/submitted/finalized`)
- status before/after
- ts

## Self-check cadence
Recommended: heartbeat or cron every 10-15 minutes:
1. Scan for stale `IN_PROGRESS`
2. Count `RETRY_PENDING`
3. Verify Chrome/CDP health
4. Verify Google login presence

## Cron vs heartbeat
- Use cron when exact cadence matters
- Use heartbeat when batching multiple checks in one pass
