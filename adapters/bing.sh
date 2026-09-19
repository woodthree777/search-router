#!/usr/bin/env bash
# bing — zero-key web search by scraping the Bing SERP.
# Uses cn.bing.com by default (reachable from mainland China); override
# with BING_HOST if you are elsewhere (e.g. www.bing.com).
. "$(dirname "$0")/_lib.sh"

BING_HOST="${BING_HOST:-cn.bing.com}"

# Bing gates its result markup on the User-Agent: a sparse/bot-ish UA gets
# a shell page with no <li class="b_algo"> blocks at all, which looks like
# "the site is broken". Always send a real browser UA for Bing.
BING_UA="${BING_UA:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36}"

bing_fetch() {
  local url="$1"
  # Bing is region-locked (cn.bing.com is meant for mainland China); it must
  # NOT go through a global proxy. Force a direct connection by clearing the
  # proxy env vars for this single curl invocation.
  env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    curl -fsSL --max-time "${SR_TIMEOUT:-25}" \
    -A "$BING_UA" \
    -H "Accept-Language: zh-CN,zh;q=0.9,en;q=0.8" \
    -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
    ${SR_INSECURE:+--insecure} \
    "$url" 2>/dev/null
}

probe() {
  # Bing's SERP is region-locked and its anti-bot sometimes serves a CAPTCHA
  # to the very first request of a fresh session, so an automated probe is
  # unreliable. Reachability is instead verified by the live search call, which
  # retries on CAPTCHA. We declare the adapter available here.
  echo "zero-key · ${BING_HOST} (SERP scrape; probe skipped — Bing CAPTCHA-gates probes)"
}

if [ "${1:-}" = "--probe" ]; then probe; exit $?; fi

QUERY="${*:-${SR_QUERY:-}}"
[ -z "$QUERY" ] && { echo "usage: bing <query>" >&2; exit 2; }
require_cmd curl

ENC="$(printf '%s' "$QUERY" | urlencode)"
# setlang/mkt matter: leaving them default gives English-biased results
# for Chinese queries. BING_MKT lets you pin the market.
MKT="${BING_MKT:-}"
URL="https://${BING_HOST}/search?q=${ENC}"
[ -n "$MKT" ] && URL="$URL&mkt=${MKT}&setlang=${BING_SETLANG:-zh-CN}"

BODY="$(bing_fetch "$URL")" || { echo "bing request failed" >&2; exit 1; }

# Bing sometimes answers with a CAPTCHA/interstitial page that contains no
# organic results. It is usually the *first* request of a fresh session that
# gets risk-checked, so retry a few times with benign warm-up queries first.
if printf '%s' "$BODY" | grep -qiE 'Slide jigsaw|complete verification|are you a human|unusual traffic'; then
  _warmups=(weather news sports "open ai")
  _ok=0
  for _w in "${_warmups[@]}"; do
    bing_fetch "https://${BING_HOST}/search?q=$(urlencode "$_w")" >/dev/null 2>&1
    BODY="$(bing_fetch "$URL")" || { echo "bing request failed" >&2; exit 1; }
    if ! printf '%s' "$BODY" | grep -qiE 'Slide jigsaw|complete verification|are you a human|unusual traffic'; then
      _ok=1; break
    fi
  done
  if [ "$_ok" -ne 1 ]; then
    echo "bing returned a CAPTCHA page (retry later)" >&2
    exit 1
  fi
fi

printf '%s' "$BODY" | "$SR_PY" -c '
import sys, re, html, urllib.parse
raw = sys.stdin.read()
# Each organic result lives in <li class="b_algo">…</li>
items = re.findall(r"(?is)<li class=\"b_algo\".*?</li>", raw)
if not items:
    sys.exit(1)
c = 0
for it in items:
    m = re.search(r"(?is)<h2[^>]*>\s*<a[^>]+href=\"([^\"]+)\"[^>]*>(.*?)</a>", it)
    if not m:
        continue
    url, title = m.group(1), m.group(2)
    title = html.unescape(re.sub(r"(?s)<[^>]+>", "", title)).strip()
    # Bing wraps some links in a redirector; unwrap it when possible.
    if "bing.com/ck/a" in url:
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        if q.get("u"):
            v = q["u"][0]
            if v.startswith("a1"):
                v = v[2:]
            try:
                pad = "=" * (-len(v) % 4)
                url = urllib.parse.unquote_plus(
                    __import__("base64").urlsafe_b64decode(v + pad).decode("utf-8", "replace"))
            except Exception:
                pass
    # Snippet text lives in a <p> inside the result block.
    sm = re.search(r"(?is)<p[^>]*>(.*?)</p>", it)
    snip = ""
    if sm:
        snip = html.unescape(re.sub(r"(?s)<[^>]+>", "", sm.group(1)))
        snip = " ".join(snip.split())[:220]
    # Skip Bing CAPTCHA/interstitial noise that sometimes leaks into a block.
    if re.search(r"(?i)slide jigsaw|complete verification|are you a human", title + " " + snip):
        continue
    if not title or not url.startswith("http"):
        continue
    # Skip Bing internal links.
    if re.search(r"//(www\.)?bing\.com", url):
        continue
    c += 1
    print("\t".join([title, url, snip, ""]))
    if c >= int(sys.argv[1] if len(sys.argv) > 1 else 10):
        break
if c == 0:
    sys.exit(1)
' "$SR_COUNT" | emit_records
