#!/usr/bin/env bash
# http — fetch a URL and print readable text. Zero key, zero dependencies
# beyond curl + python. Use it as the last-resort fetch adapter when
# crawl4ai / wigolo are not installed.
. "$(dirname "$0")/_lib.sh"

probe() {
  command -v curl >/dev/null 2>&1 || return 1
  echo "curl + python html-to-text"
}

if [ "${1:-}" = "--probe" ]; then probe; exit $?; fi

URL="${*:-${SR_QUERY:-}}"
[ -z "$URL" ] && { echo "usage: http <url>" >&2; exit 2; }
require_cmd curl

# Reject non-http input early.
case "$URL" in
  http://*|https://*) ;;
  *) echo "not a URL: $URL" >&2; exit 1 ;;
esac

BODY="$(curl -fsSL --max-time "${SR_TIMEOUT:-30}" -L \
  -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36" \
  "$URL" 2>/dev/null)" || {
  echo "fetch failed: $URL" >&2; exit 1
}

printf '%s' "$BODY" | "$SR_PY" -c '
import sys, re, html
raw = sys.stdin.read()
if not raw.strip():
    sys.exit(1)
# Drop script/style/nav blocks before stripping tags.
raw = re.sub(r"(?is)<(script|style|noscript|svg|head)[^>]*>.*?</\1>", " ", raw)
raw = re.sub(r"(?is)<br\s*/?>", "\n", raw)
raw = re.sub(r"(?is)</(p|div|li|h[1-6]|tr)>", "\n", raw)
txt = re.sub(r"(?s)<[^>]+>", " ", raw)
txt = html.unescape(txt)
txt = re.sub(r"[ \t\u00a0]+", " ", txt)
txt = re.sub(r"\n\s*\n\s*\n+", "\n\n", txt)
lines = [l.strip() for l in txt.split("\n")]
out, seen = [], set()
for l in lines:
    if len(l) < 2:
        continue
    if l in seen:            # drop the nav/footer repetition
        continue
    seen.add(l)
    out.append(l)
txt = "\n".join(out).strip()
if len(txt) < 50:
    sys.exit(1)
print(txt[:20000])
if len(txt) > 20000:
    sys.stderr.write("\n[truncated: %d chars total]\n" % len(txt))
'
