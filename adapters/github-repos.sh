#!/usr/bin/env bash
# github-repos — zero-key search of GitHub repositories.
# Set GITHUB_TOKEN to raise the unauthenticated 10 req/min limit.
. "$(dirname "$0")/_lib.sh"

probe() {
  local hdr=() body
  [ -n "${GITHUB_TOKEN:-}" ] && hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
  # Capture first, then test — piping curl straight into grep aborts the
  # transfer and prints "curl: Failed writing body".
  body="$(curl -fsSL --max-time 15 "${hdr[@]}" \
    "https://api.github.com/search/repositories?q=test&per_page=1" 2>/dev/null)" || return 126
  printf '%s' "$body" | grep -q '"items"' || return 126
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "github.com · authenticated (5000/hr)"
  else
    echo "github.com · anonymous (10/min — set GITHUB_TOKEN)"
  fi
}

if [ "${1:-}" = "--probe" ]; then probe; exit $?; fi

QUERY="${*:-${SR_QUERY:-}}"
[ -z "$QUERY" ] && { echo "usage: github-repos <query>" >&2; exit 2; }
require_cmd curl

ENC="$(printf '%s' "$QUERY" | urlencode)"
SORT="${GITHUB_SORT:-stars}"
HDR=(-H "Accept: application/vnd.github+json")
[ -n "${GITHUB_TOKEN:-}" ] && HDR+=(-H "Authorization: Bearer $GITHUB_TOKEN")

JSON="$(curl -fsSL --max-time "${SR_TIMEOUT:-25}" "${HDR[@]}" \
  "https://api.github.com/search/repositories?q=${ENC}&sort=${SORT}&order=desc&per_page=${SR_COUNT}" 2>/dev/null)" || {
  echo "github search failed (rate limited? set GITHUB_TOKEN)" >&2; exit 1
}

printf '%s' "$JSON" | "$SR_PY" -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
items = d.get("items") or []
if not items:
    sys.exit(1)
for r in items:
    name = r.get("full_name", "")
    url = r.get("html_url", "")
    stars = r.get("stargazers_count", 0)
    lang = r.get("language") or "-"
    desc = (r.get("description") or "").replace("\t", " ").strip()
    snip = "★%d · %s · %s" % (stars, lang, desc[:150])
    date = (r.get("pushed_at") or "")[:10]
    print("\t".join([name, url, snip, date]))
' | emit_records
