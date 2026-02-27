# State Machine (fixed)

Transitions:
- `PENDING -> IN_PROGRESS`
- `IN_PROGRESS -> DONE | SKIP | FAILED | NEED_HUMAN | RETRY_PENDING`

Status text conventions:
- `IN_PROGRESS | runId=<id> | worker=<id> | row=<n> | ts=<iso>`
- `DONE | type=<nav|forum|profile|blog> | note=<short>`
- `SKIP | reason=<why>`
- `FAILED | reason=<error>`
- `NEED_HUMAN | reason=<captcha|manual_review|paywall|...>`
- `RETRY_PENDING | reason=<retry_cause> | ts=<iso>`

Landing column:
- DONE: final public landing URL
- NEED_HUMAN: pending URL + ` (pending)` if useful
- SKIP/FAILED/RETRY_PENDING: usually empty
