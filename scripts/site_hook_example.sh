#!/usr/bin/env bash
# Usage: site_hook_example.sh <url> <row> <config>
# Print JSON only when you can confidently finalize the row.
# Example output:
# {"finalStatus":"DONE | type=profile | note=auto","finalLanding":"https://example.com/profile"}

set -euo pipefail
url="${1:-}"

# demo rule: never finalize by default
# You can customize per domain with agent-browser checks here.
if [[ "$url" == *"example.com"* ]]; then
  echo '{"finalStatus":"DONE | type=profile | note=auto","finalLanding":"https://example.com/profile"}'
  exit 0
fi

# no decision
exit 0
