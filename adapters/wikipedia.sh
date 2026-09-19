#!/usr/bin/env bash
# wikipedia — zero-key search via the MediaWiki API.
# Works anywhere, no signup. Great for concepts, definitions, background.
. "$(dirname "$0")/_lib.sh"

probe() {
  local r
  r="$(http_get "https://${WIKI_LANG:-en}.wikipedia.org/w/api.php?action=query&list=search&srsearch=test&format=json&srlimit=1")" || return 1
  printf '%s' "$r" | grep -q '"search"' || return 1
  echo "zero-key · ${WIKI_LANG:-en}.wikipedia.org"
}

if [ "${1:-}" = "--probe" ]; then probe; exit $?; fi

QUERY="${*:-${SR_QUERY:-}}"
[ -z "$QUERY" ] && { echo "usage: wikipedia <query>" >&2; exit 2; }
require_cmd curl

# Chinese queries default to the Chinese Wikipedia.
LANG_CODE="${WIKI_LANG:-}"
if [ -z "$LANG_CODE" ]; then
  if printf '%s' "$QUERY" | grep -qP '[\x{4e00}-\x{9fff}]' 2>/dev/null; then
    LANG_CODE=zh
  else
    LANG_CODE=en
  fi
fi

ENC="$(printf '%s' "$QUERY" | urlencode)"
API="https://${LANG_CODE}.wikipedia.org/w/api.php"
JSON="$(http_get "${API}?action=query&list=search&srsearch=${ENC}&format=json&srlimit=${SR_COUNT}&srprop=snippet|timestamp")" || {
  echo "wikipedia request failed" >&2; exit 1
}

printf '%s' "$JSON" | "$SR_PY" -c '
import sys, json, re, html
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
hits = (d.get("query") or {}).get("search") or []
if not hits:
    sys.exit(1)
lang = sys.argv[1]
for h in hits:
    title = h.get("title", "")
    snip = re.sub(r"<[^>]+>", "", h.get("snippet", ""))
    snip = html.unescape(snip).strip()
    date = (h.get("timestamp") or "")[:10]
    url = "https://%s.wikipedia.org/wiki/%s" % (lang, title.replace(" ", "_"))
    print("\t".join([title, url, snip[:200], date]))
' "$LANG_CODE" | emit_records
