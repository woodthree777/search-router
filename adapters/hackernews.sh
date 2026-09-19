#!/usr/bin/env bash
# hackernews — zero-key search over HN via the Algolia API.
# Excellent for tech/startup discussion and real-world debugging threads.
. "$(dirname "$0")/_lib.sh"

probe() {
  local body
  body="$(http_get "https://hn.algolia.com/api/v1/search?query=test&hitsPerPage=1")" || return 126
  printf '%s' "$body" | grep -q '"hits"' || return 126
  echo "zero-key · hn.algolia.com"
}

if [ "${1:-}" = "--probe" ]; then probe; exit $?; fi

QUERY="${*:-${SR_QUERY:-}}"
[ -z "$QUERY" ] && { echo "usage: hackernews <query>" >&2; exit 2; }
require_cmd curl

ENC="$(printf '%s' "$QUERY" | urlencode)"
# search_by_date ranks by recency; for tech questions `search` ranks by relevance.
EP="${HN_ENDPOINT:-search}"
JSON="$(http_get "https://hn.algolia.com/api/v1/${EP}?query=${ENC}&hitsPerPage=${SR_COUNT}&tags=story")" || {
  echo "hackernews request failed" >&2; exit 1
}

printf '%s' "$JSON" | "$SR_PY" -c '
import sys, json, datetime
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
hits = d.get("hits") or []
if not hits:
    sys.exit(1)
for h in hits:
    title = h.get("title") or h.get("story_title") or ""
    if not title:
        continue
    url = h.get("url") or ("https://news.ycombinator.com/item?id=%s" % h.get("objectID", ""))
    date = (h.get("created_at") or "")[:10]
    pts = h.get("points") or 0
    cmt = h.get("num_comments") or 0
    snip = "%d points · %d comments" % (pts, cmt)
    print("\t".join([title, url, snip, date]))
' | emit_records
