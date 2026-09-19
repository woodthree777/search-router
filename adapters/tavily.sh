#!/usr/bin/env bash
# tavily — optional adapter for the Tavily search API.
#   export TAVILY_API_KEY=tvly-...
# Free tier available. Returns long page bodies, which is its main draw.
. "$(dirname "$0")/_lib.sh"

probe() {
  [ -n "${TAVILY_API_KEY:-}" ] || { echo "set TAVILY_API_KEY"; return 126; }
  echo "api key present"
}

if [ "${1:-}" = "--probe" ]; then probe; exit $?; fi

[ -n "${TAVILY_API_KEY:-}" ] || { echo "TAVILY_API_KEY not set" >&2; exit 126; }

QUERY="${*:-${SR_QUERY:-}}"
[ -z "$QUERY" ] && { echo "usage: tavily <query>" >&2; exit 2; }
require_cmd curl
[ -n "${SR_PY:-}" ] || { echo "python3 required" >&2; exit 126; }

TMP="$(sr_tmpfile .json)" || { echo "cannot create temp file" >&2; exit 1; }
trap 'rm -f "$TMP"' EXIT
"$SR_PY" -c '
import json, sys
json.dump({
    "query": sys.argv[1],
    "max_results": int(sys.argv[2]),
    "include_answer": False,
    "search_depth": "basic",
}, open(sys.argv[3], "w", encoding="utf-8"), ensure_ascii=False)
' "$QUERY" "$SR_COUNT" "$TMP"

JSON="$(curl -fsSL --max-time "${SR_TIMEOUT:-40}" \
  -X POST "https://api.tavily.com/search" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TAVILY_API_KEY" \
  --data-binary "@$TMP" 2>/dev/null)" || { echo "tavily request failed" >&2; exit 1; }

printf '%s' "$JSON" | "$SR_PY" -c '
import sys, json, datetime
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
rs = d.get("results") or []
if not rs:
    sys.exit(1)
for r in rs:
    title = (r.get("title") or "").strip()
    url = r.get("url") or ""
    body = " ".join(str(r.get("content") or "").split())
    print("\t".join([title, url, body[:250], ""]))
' | emit_records
