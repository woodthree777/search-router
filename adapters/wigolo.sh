#!/usr/bin/env bash
# wigolo — optional adapter for a self-hosted wigolo instance (HTTP mode).
#
#   docker run -p 3333:3333 -v wigolo-data:/data \
#     -e WIGOLO_API_TOKEN=*** ghcr.io/knockoutez/wigolo serve --host 0.0.0.0
#
#   export WIGOLO_URL=http://127.0.0.1:3333
#   export WIGOLO_TOKEN=***
#
# Modes:  search (default) | fetch | cache
#
# IMPORTANT — to get page text back you must send BOTH:
#     include_content: true          (go fetch the page)
#     include_full_markdown: true    (and actually return it)
# Sending only include_content fetches the text and then silently drops it.
. "$(dirname "$0")/_lib.sh"

URL="${WIGOLO_URL:-http://127.0.0.1:3333}"

sr_token() { printf '%s' "${WIGOLO_TOKEN:-}"; }

probe() {
  local t; t="$(sr_token)"
  local hdr=()
  [ -n "$t" ] && hdr=(-H "Authorization: Bearer $t")
  curl -fsSL --max-time 10 "${hdr[@]}" "$URL/health" >/dev/null 2>&1 || {
    echo "no wigolo at $URL"; return 126
  }
  echo "found: $URL"
}

if [ "${1:-}" = "--probe" ]; then probe; exit $?; fi

QUERY="${*:-${SR_QUERY:-}}"
[ -z "$QUERY" ] && { echo "usage: wigolo <query|url>" >&2; exit 2; }
require_cmd curl
[ -n "${SR_PY:-}" ] || { echo "python3 required" >&2; exit 126; }

TOKEN="$(sr_token)"
HDR=(-H "Content-Type: application/json")
[ -n "$TOKEN" ] && HDR+=(-H "Authorization: Bearer $TOKEN")

api() {
  local ep="$1" payload="$2" tmp
  tmp="$(sr_tmpfile .json)" || { echo "cannot create temp file" >&2; return 1; }
  printf '%s' "$payload" > "$tmp"
  # --data-binary keeps the UTF-8 bytes intact; a bare -d mangles
  # non-ASCII queries on some shells (classic GBK corruption bug).
  curl -fsSL --max-time "${SR_TIMEOUT:-60}" "${HDR[@]}" \
    -X POST "$URL$ep" --data-binary "@$tmp" 2>/dev/null
  local rc=$?
  rm -f "$tmp"
  return $rc
}

case "$SR_MODE" in
  fetch)
    case "$QUERY" in http://*|https://*) ;; *) echo "not a URL" >&2; exit 1 ;; esac
    JSON="$(api /v1/fetch "$(printf '{"url":"%s"}' "$QUERY")")" || { echo "fetch failed" >&2; exit 1; }
    printf '%s' "$JSON" | "$SR_PY" -c '
import sys, json
d = json.load(sys.stdin)
md = d.get("markdown") or d.get("markdown_content") or d.get("content") or ""
if not md.strip(): sys.exit(1)
print(md[:20000])
' ;;
  cache)
    JSON="$(api /v1/cache "$(printf '{"query":"%s"}' "$QUERY")")" || { echo "cache lookup failed" >&2; exit 1; }
    printf '%s' "$JSON" ;;
  *)
    JSON="$(api /v1/search "$(printf '{"query":"%s","max_results":%s,"include_content":true,"include_full_markdown":true}' "$QUERY" "$SR_COUNT")")" || {
      echo "search failed" >&2; exit 1
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
for i, r in enumerate(rs, 1):
    title = (r.get("title") or "").strip()
    url = r.get("url") or ""
    if not title and not url:
        continue
    body = r.get("markdown_content") or r.get("content") or r.get("snippet") or ""
    body = " ".join(str(body).split())
    date = (r.get("published_date") or r.get("date") or "")[:10]
    print("\t".join(["[%d] %s" % (i, title), url, body[:250], date]))
' | emit_records ;;
esac
