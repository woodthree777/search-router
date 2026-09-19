#!/usr/bin/env bash
# crawl4ai — optional adapter, wraps the crawl4ai Python library.
# Install:  pip install crawl4ai && crawl4ai-setup
# Note: crawl4ai must be importable by the python you point this at;
# if your default python lacks it, set CRAWL4AI_PY (see --probe).
#
# Modes:  fetch (default) | shot | crawl
#   fetch  page → markdown
#   shot   page → PNG (path printed)
#   crawl  BFS over the same domain; SR_DEPTH / SR_PAGES control size
. "$(dirname "$0")/_lib.sh"

sr_py() {
  local c
  for c in "${CRAWL4AI_PY:-}" python3 python py; do
    [ -z "$c" ] && continue
    command -v "$c" >/dev/null 2>&1 || continue
    # Must actually import it — a bare `command -v` check picks launchers
    # like Windows' `py` shim, which then cannot open MSYS temp paths.
    "$c" -c 'import crawl4ai' >/dev/null 2>&1 || continue
    # Verify it can also read a native temp path; some launchers cannot.
    local probe; probe="$(sr_tmpfile .py)" || continue
    printf 'pass\n' > "$probe" 2>/dev/null || { rm -f "$probe"; continue; }
    "$c" -c 'import sys; open(sys.argv[1]).read()' "$probe" >/dev/null 2>&1 || {
      rm -f "$probe"; continue
    }
    rm -f "$probe"
    printf '%s' "$c"; return 0
  done
  return 1
}

probe() {
  local p; p="$(sr_py)" || { echo "pip install crawl4ai (or set CRAWL4AI_PY)"; return 126; }
  local v
  v="$("$p" -c '
import importlib.metadata as m
try:
    print(m.version("crawl4ai"))
except Exception:
    print("installed")
' 2>/dev/null)"
  [ -z "$v" ] && v="installed"
  echo "importable by '$p' (v$v)"
}

if [ "${1:-}" = "--probe" ]; then probe; exit $?; fi

PY="$(sr_py)" || { echo "crawl4ai not importable (set CRAWL4AI_PY)" >&2; exit 126; }

URL="${*:-${SR_QUERY:-}}"
[ -z "$URL" ] && { echo "usage: crawl4ai <url>" >&2; exit 2; }
case "$URL" in http://*|https://*) ;; *) echo "not a URL: $URL" >&2; exit 1 ;; esac

TMP="$(sr_tmpfile .py)" || { echo "cannot create temp file" >&2; exit 1; }
trap 'rm -f "$TMP"' EXIT

case "$SR_MODE" in
  shot)
    OUT="${SR_OUT:-$(sr_tmpfile .png)}"
    cat > "$TMP" <<'PYEOF'
import sys, asyncio, base64
from crawl4ai import AsyncWebCrawler, CrawlerRunConfig
url, out = sys.argv[1], sys.argv[2]
async def main():
    cfg = CrawlerRunConfig(screenshot=True)
    async with AsyncWebCrawler(verbose=False) as c:
        r = await c.arun(url=url, config=cfg)
        data = getattr(r, "screenshot", None)
        if not data:
            print("screenshot unavailable", file=sys.stderr); sys.exit(1)
        if isinstance(data, str) and data.startswith("data:"):
            data = data.split(",", 1)[1]
        open(out, "wb").write(base64.b64decode(data))
        print(out)
asyncio.run(main())
PYEOF
    "$PY" "$TMP" "$URL" "$OUT" ;;
  crawl)
    cat > "$TMP" <<'PYEOF'
import sys, asyncio
from urllib.parse import urlparse
from crawl4ai import AsyncWebCrawler, CrawlerRunConfig
from crawl4ai.deep_crawling import BFSDeepCrawlStrategy
url, depth, pages = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
async def main():
    try:
        from crawl4ai.deep_crawling.filters import FilterChain, DomainFilter
        flt = FilterChain([DomainFilter(allowed_domains=[urlparse(url).netloc])])
    except Exception:
        flt = None
    strat = BFSDeepCrawlStrategy(max_depth=depth, max_pages=pages, filter_chain=flt)
    async with AsyncWebCrawler(verbose=False) as c:
        res = await c.arun(url=url, config=CrawlerRunConfig(deep_crawl_strategy=strat))
        if not isinstance(res, list):
            res = [res]
        print("PAGES=%d" % len(res))
        for i, r in enumerate(res, 1):
            md = getattr(getattr(r, "markdown", None), "raw_markdown", "") or ""
            print("\n%s\n[%d] %s (%d chars)" % ("=" * 60, i, r.url, len(md)))
            print(md[:1500])
asyncio.run(main())
PYEOF
    "$PY" "$TMP" "$URL" "${SR_DEPTH:-1}" "${SR_PAGES:-10}" ;;
  *)
    cat > "$TMP" <<'PYEOF'
import sys, asyncio
from crawl4ai import AsyncWebCrawler
url = sys.argv[1]
async def main():
    async with AsyncWebCrawler(verbose=False) as c:
        r = await c.arun(url=url)
        md = getattr(getattr(r, "markdown", None), "raw_markdown", "") or ""
        if not r.success or len(md.strip()) < 40:
            print("crawl4ai got %d chars (blocked?)" % len(md), file=sys.stderr)
            sys.exit(1)
        print(md[:20000])
asyncio.run(main())
PYEOF
    # crawl4ai logs progress to stderr — keep stdout clean.
    "$PY" "$TMP" "$URL" 2>/dev/null ;;
esac
