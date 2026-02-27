# Email Verification via gog (Mandatory)

Use this flow whenever a site asks for email verification.

## Preconditions
- `gog auth list` includes `gmail` scope for `alexfefun1@gmail.com`.
- Registration uses a traceable recipient (e.g. plus alias):
  - `alexfefun1+<site><date>@gmail.com`

## Flow
1. **Search #1 (before resend)**
   - Query with recipient alias + sender/subject keywords.
2. If no result, click **resend verification** on site (when available).
3. **Search #2 (after resend + short wait)**
   - Re-run query after 20-60s.
4. If mail found, open message and continue via verification link/code.
5. If still none after attempts, set:
   - `RETRY_PENDING | reason=verification_mail_not_received_after_gog_retries`
   - escalate to `NEED_HUMAN` only when operator action is required.

## Command patterns

Search by alias + sender/subject:

```bash
gog gmail messages search 'in:anywhere newer_than:2d (to:alexfefun1+foundr20260226@gmail.com OR from:foundr.ai OR subject:(verify OR verification))' --max 20 --account alexfefun1@gmail.com
```

Search broad fallback:

```bash
gog gmail messages search 'in:anywhere newer_than:2d (subject:(verify OR verification OR confirm) OR from:noreply)' --max 50 --account alexfefun1@gmail.com
```

## Logging requirements
For each verification attempt, log:
- recipient alias used
- search query used
- result count search #1 / search #2
- resend clicked (yes/no)
- final outcome (`verified` / `pending_mail` / `manual_required`)
