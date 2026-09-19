#!/usr/bin/env bash
# searxng — optional adapter for a SearXNG instance (self-hosted or public).
#
#   docker run -d -p 8888:8080 searxng/searxng
#   export SEARXNG_URL=http://127.0.0.1:8888
#
# The instance must allow the JSON API — in settings.yml:
#     search:
#       formats:
#         - html
#         - json
#
# Public instances frequently sit behind anti-bot challenges and will fail
# here; a self-hosted instance is the reliable path.
. "$(dirname "$0")/_lib.sh"

URL="${SEARXNG_URL:-http://127.0.0.1:8888}"

probe() {
  local r
  r="$(curl -fsSL --max-time 12 "$URL/search?q=test&format=json" 2>/dev/null)" || {
    echo "no SearXNG at $URL (or JSON API disabled)"; return 126
  }
  printf '%s' "$r" | grep -q '"results"' || { echo "$URL did not return JSON"; return 126; }
  echo "found: $URL"
}

if [ "${1:-}" = "--probe" ]; then probe; exit $?; fi

QUERY="${*:-${SR_QUERY:-}}"
[ -z "$QUERY" ] && { echo "usage: searxng <query>" >&2; exit 2; }
require_cmd curl
[ -n "${SR_PY:-}" ] || { echo "python3 required" >&2; exit 126; }

ENC="$(printf '%s' "$QUERY" | urlencode)"
EXTRA=""
[ -n "${SEARXNG_LANG:-}" ]  && EXTRA="$EXTRA&language=${SEARXNG_LANG}"
[ -n "${SEARXNG_CATS:-}" ]  && EXTRA="$EXTRA&categories=${SEARXNG_CATS}"

JSON="$(curl -fsSL --max-time "${SR_TIMEOUT:-25}" \
  -A "Mozilla/5.0 (compatible; search-router)" \
  "$URL/search?q=${ENC}&format=json&safesearch=0${EXTRA}" 2>/dev/null)" || {
  echo "searxng request failed (JSON API disabled?)" >&2; exit 1
}

printf '%s' "$JSON" | "$SR_PY" -c '
import sys, json
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
    if not title:
        continue
    snip = " ".join(str(r.get("content") or "").split())[:220]
    date = (r.get("publishedDate") or "")[:10]
    eng = r.get("engine") or ""
    if eng:
        snip = "[%s] %s" % (eng, snip)
    print("\t".join([title, url, snip, date]))
' | emit_records
