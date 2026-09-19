#!/usr/bin/env bash
# crossref — zero-key DOI / scholarly metadata via the Crossref REST API.
# No API key required (polite pool recommends a mail param; set CROSSREF_MAIL).
. "$(dirname "$0")/_lib.sh"

CROSSREF_MAIL="${CROSSREF_MAIL:-}"

probe() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "https://api.crossref.org/works?rows=1")"
  if [ "${code:-000}" = "200" ]; then
    echo "zero-key · api.crossref.org (DOI / paper metadata)"
  else
    echo "crossref unreachable (HTTP ${code:-timeout})"
    return 126
  fi
}

if [ "${1:-}" = "--probe" ]; then probe; exit $?; fi

QUERY="${*:-${SR_QUERY:-}}"
[ -z "$QUERY" ] && { echo "usage: crossref <query|DOI>" >&2; exit 2; }
require_cmd curl

MAIL_PARAM=""
[ -n "$CROSSREF_MAIL" ] && MAIL_PARAM="&mailto=$(urlencode "$CROSSREF_MAIL")"

# If the query looks like a bare DOI, query by DOI directly.
if printf '%s' "$QUERY" | grep -qE '^10\.[0-9]{4,9}/'; then
  URL="https://api.crossref.org/works/$(urlencode "$QUERY")"
else
  URL="https://api.crossref.org/works?query.bibliographic=$(urlencode "$QUERY")&rows=${SR_COUNT}${MAIL_PARAM}"
fi

RESP="$(env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  curl -fsSL --max-time "${SR_TIMEOUT:-25}" "$URL" 2>/dev/null)" || { echo "crossref request failed" >&2; exit 1; }

printf '%s' "$RESP" | "$SR_PY" -c '
import sys, json, re
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    sys.exit(1)
items = data.get("message", {}).get("items") or []
if not items and "message" in data and isinstance(data["message"], dict) and "DOI" in data["message"]:
    items = [data["message"]]
if not items:
    sys.exit(1)
c = 0
for it in items:
    title = it.get("title")
    title = title[0] if isinstance(title, list) and title else ""
    if not title:
        continue
    doi = it.get("DOI", "")
    url = "https://doi.org/" + doi if doi else it.get("URL", "")
    # Build a short citation line.
    year = ""
    if it.get("published") and it["published"].get("date-parts"):
        dp = it["published"]["date-parts"][0]
        year = str(dp[0]) if dp else ""
    authors = []
    for a in (it.get("author") or [])[:3]:
        gn = a.get("given", "")
        fn = a.get("family", "")
        if gn or fn:
            authors.append((fn + " " + gn).strip())
    cit = ", ".join(authors)
    if year:
        cit += (" (" + year + ")") if cit else year
    snip = cit
    if not url.startswith("http"):
        continue
    c += 1
    print("\t".join([title, url, snip, ""]))
    if c >= int(sys.argv[1] if len(sys.argv) > 1 else 10):
        break
if c == 0:
    sys.exit(1)
' "$SR_COUNT" | emit_records
