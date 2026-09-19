# search-router

**One command for every search tool on your machine — routed automatically by
what you type.**

You install a new search tool every time the last one fails at something. Then
you can't remember which one to use. `search-router` fixes that: one entry
point, `s`, that inspects your query and picks the right backend.

```console
$ s "postgres index bloat"          # → your general web search
$ s 600519                          # → stock-quote adapter
$ s https://example.com/article     # → fetch adapter, returns text
$ s deep "低空经济政策" 2            # → search, then fetch the top 2 pages
```

Works out of the box with **zero API keys**, and gets better as you wire up the
tools you already run.

---

## Why this exists

I measured four search tools on the same queries. The ranking quality was
**the same** — 4.7 to 5.0 keyword hits out of 10. The differences that actually
mattered were elsewhere:

| Capability | Who has it |
|---|---|
| Returns a **publication date** per result | almost nobody (one tool: 10/10) |
| Gives **numbered citations** for sourcing | one tool |
| One call returns **full page text** | most, but not all |
| **Screenshots** / CSS-field extraction / whole-site crawl | one tool |
| Works with **no API key at all** | the ones below |

So choosing a search tool is not "which is most accurate". It's "which
capability do I need right now". That's a routing problem, and it's silly to
solve it by hand every time.

## Install

```bash
git clone https://github.com/woodthree777/search-router.git
cd search-router
./install.sh                 # symlinks `s` into ~/.local/bin
```

Or manually — it's just a shell script:

```bash
chmod +x s adapters/*.sh
ln -s "$PWD/s" ~/.local/bin/s
```

Requirements: `bash`, `curl`, and `python3` (for JSON parsing). That's it.

Then check what's wired up on your machine:

```console
$ s --check
search-router 0.1.0

adapters
  ✓ github-repos     github.com · anonymous (10/min — set GITHUB_TOKEN)
  ✓ hackernews       zero-key · hn.algolia.com
  ✓ http             curl + python html-to-text
  ✓ wikipedia        zero-key · en.wikipedia.org
  ✗ crawl4ai         pip install crawl4ai (or set CRAWL4AI_PY)
  ✗ tavily           set TAVILY_API_KEY
  ...
```

**Anything marked ✗ is simply skipped** — the router falls through to the next
adapter in the chain. Nothing breaks.

## Deploy on a China / no-VPN host

On servers inside mainland China without a proxy/VPN, `wikipedia` is **blocked**
and heavy tools (crawl4ai/Playwright/Chromium, Docker) are best avoided on
tight disks. This repo ships a zero-key profile that uses only what is directly
reachable from China:

| Backend | Reachable from CN? | Notes |
|---|---|---|
| `bing` (cn.bing.com SERP scrape) | ✅ | Chinese-capable; zero-key; occasional CAPTCHA (auto-retried) |
| `hackernews` (Algolia API) | ✅ | English/tech only |
| `github-repos` | ✅ | anonymous 10/min |
| `crossref` | ✅ | DOI / paper metadata |
| `tavily` | ✅ (needs key) | optional |
| `wikipedia` | ❌ blocked | excluded |
| `anysearch` / `searxng` / `wigolo` | ❌ not deployed | excluded |
| `crawl4ai` | ⚠️ optional | skipped by default for disk space |

```bash
git clone https://github.com/woodthree777/search-router.git
cd search-router
./install.sh
# use the China/no-VPN config (no wikipedia, bing-first)
cp config.remote-example ~/.config/search-router/config
s --check          # bing / hackernews / github-repos / crossref should be ✓
```

Bing sometimes serves a CAPTCHA to a fresh session's first request; the adapter
retries automatically (up to 3× with warm-up queries). If a search still fails,
just re-run it.


## Adapters

Each adapter is a small standalone shell script in `adapters/`. That's the
whole extension mechanism: drop in a file, add a route rule, done.

### Zero-key — work immediately, no signup

| Adapter | What it's good for |
|---|---|
| `wikipedia` | concepts, definitions, background. Auto-switches to the Chinese Wikipedia for Chinese queries. |
| `hackernews` | engineering discussion, real-world debugging threads, tech news |
| `github-repos` | finding libraries and prior art |
| `http` | fetch any URL as plain text (curl + a tag stripper) |

### Bring your own — optional, auto-detected

| Adapter | Setup |
|---|---|
| `anysearch` | `ANYSEARCH_DIR=/path/to/anysearch` — vertical search: stocks, FX, macro, academic, legal. Returns **structured fields**, not page snippets. |
| `wigolo` | self-hosted: `docker run -p 3333:3333 ghcr.io/knockoutez/wigolo serve`. Set `WIGOLO_URL`, `WIGOLO_TOKEN`. Adds citation numbering and an offline cache. |
| `crawl4ai` | `pip install crawl4ai && crawl4ai-setup`. Set `CRAWL4AI_PY` if it's not your default python. Adds screenshots, CSS-field extraction, BFS crawling. |
| `searxng` | self-hosted SearXNG with the JSON API enabled. Set `SEARXNG_URL`. |
| `tavily` | `TAVILY_API_KEY` — free tier available |

## Routing

Rules live in a plain-text config file. Print the path with `s --config`, or
create one with `s --init`:

```
<extended-regex>    <adapter-chain>
```

First match wins. `|` separates fallbacks — the first adapter that produces
output wins, the rest are skipped.

```
^https?://.*                    http | wigolo:fetch | crawl4ai:fetch
^[0-9]{6}$                      anysearch:stock | wikipedia | hackernews
股价|行情|市值|财报                anysearch:quote | wikipedia | hackernews
论文|文献|期刊|DOI|arXiv           anysearch:academic | wikipedia
法条|判例|司法解释|法规             anysearch:legal | wikipedia | hackernews
*                               anysearch | searxng | tavily | wikipedia | hackernews
```

`name:mode` passes a mode to an adapter (`wigolo:fetch`, `crawl4ai:shot`).
See `s --routes` for the active table.

## Usage

```console
# basic
s "how to debug a memory leak"        # route by content
s -n 5 "rust async runtime"           # result count
s -a hackernews "database internals"  # force one adapter

# fetching
s https://example.com/post            # → readable text
s -a crawl4ai:shot https://example.com   # → screenshot, prints the PNG path
s -a crawl4ai:crawl https://example.com  # → BFS crawl (SR_DEPTH, SR_PAGES)

# two-stage: search, then fetch the top results in full
s deep "低空经济政策" 3

# inspect
s --check                             # adapter availability
s --routes                            # routing table
s -D "some query"                     # show which adapter would run
s -v "some query"                     # show routing decisions as it goes
```

Run `s --help` for everything.

## Writing an adapter

An adapter is a script at `adapters/<name>.sh` with two behaviours:

```bash
#!/usr/bin/env bash
. "$(dirname "$0")/_lib.sh"

probe() {                     # exit 0 if usable; print a one-line note
  echo "my-service · configured"
}
if [ "${1:-}" = "--probe" ]; then probe; exit $?; fi

QUERY="${*:-${SR_QUERY:-}}"
# ... fetch, then print records to stdout via emit_records
```

Contract:

- `--probe` → exit `0` if usable (`126` if not installed/configured)
- otherwise → print results to stdout, exit `0` on success
- environment: `SR_QUERY`, `SR_COUNT`, `SR_MODE`, `SR_PY`, `SR_ROOT`
- result format: newline-delimited `title<TAB>url<TAB>snippet<TAB>date`,
  one record per line — feed it to `emit_records` to pretty-print

Exit code `126` means "not available"; the router treats it as a skip and
moves to the next adapter in the chain.

`adapters/_lib.sh` gives you `http_get`, `urlencode`, `emit_records`,
`sr_tmpfile` and `sr_native_path`. Use `sr_tmpfile` rather than `mktemp` if a
native binary will read the file — see the pitfalls below.

## Pitfalls worth knowing

These are all real bugs I hit while building this, and they're the reason
several functions look more defensive than they need to.

**Getting page text from wigolo requires *two* flags.** `include_content: true`
fetches the page, then the response silently discards the body unless you also
send `include_full_markdown: true`. Sending only the first looks exactly like a
broken feature:

```js
if (!input.include_full_markdown) {
  for (const r of items) r.markdown_content = void 0;   // silently dropped
}
```

**`mktemp` on Windows/git-bash returns a path native binaries cannot open.**
`python.exe` and `node.exe` do not understand `/tmp/x`. Use `sr_tmpfile`,
which translates through `cygpath` and verifies a native interpreter can
actually read the file back.

**Don't run python with `-s` to "isolate" it.** `-s` excludes *user*
site-packages — which is precisely where pip installs things like `crawl4ai`
when you're not in a virtualenv. The import then fails and looks like a
missing install.

**Never pipe `curl` directly into `grep -q` in a probe.** `grep` exits the
moment it matches, the pipe closes, and curl reports
`Failed writing body` — so a perfectly good service looks broken. Capture
into a variable first.

**Send non-ASCII query bodies as raw bytes.** Inline `curl -d "中文"` can
transcode to the local codepage (GBK on Windows) and deliver garbage. Write
the JSON to a file and use `--data-binary @file`. The adapter library does
this for you.

**`degraded: true` from a multi-engine backend is not automatically a
failure.** Check the healthy-engine count before concluding anything. I once
wrote up a "search is completely broken" report that turned out to be my own
test harness corrupting the query encoding.

## Project layout

```
s                     the router (single bash script)
adapters/
  _lib.sh             shared helpers — sourced by every adapter
  wikipedia.sh        zero-key
  hackernews.sh       zero-key
  github-repos.sh     zero-key
  http.sh             zero-key
  anysearch.sh        optional
  wigolo.sh           optional
  crawl4ai.sh         optional
  searxng.sh          optional
  tavily.sh           optional
install.sh            symlink `s` onto your PATH
config.example        annotated routing table
```

## License

MIT

## Credits

`wigolo` is [KnockOutEZ/wigolo](https://github.com/KnockOutEZ/wigolo).
`crawl4ai` is [unclecode/crawl4ai](https://github.com/unclecode/crawl4ai).
This project only wires existing tools together.
