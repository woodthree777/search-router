#!/usr/bin/env bash
# ───────────────────────────────────────────────────────────────────────
#  search-router · `s`
#
#  One command for every search tool on your machine, automatically
#  routed by what you type.
#
#    s "kubernetes pod scheduling"    → your fast general search
#    s 600519                         → stock quote adapter
#    s https://example.com/post       → fetch adapter
#    s deep "低空经济政策"             → search, then fetch full text
#
#  https://github.com/woodthree777/search-router        MIT
# ───────────────────────────────────────────────────────────────────────
set -uo pipefail

SR_VERSION="0.1.0"

# Resolve our own directory so adapters are found from any cwd.
# Use readlink -f so a symlink in PATH still resolves to the real script dir.
_SR_SELF="${BASH_SOURCE[0]:-$0}"
SR_ROOT="$(cd "$(dirname "$(readlink -f "$_SR_SELF" 2>/dev/null || printf '%s' "$_SR_SELF")")" && pwd)"
export SR_ROOT
unset _SR_SELF
SR_ADAPTERS="$SR_ROOT/adapters"
SR_CONFIG="${SR_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/search-router/config}"

SR_COUNT="${SR_COUNT:-10}"
SR_MODE=""
SR_VERBOSE=0
SR_DRYRUN=0
SR_FORCE=""

# ── colors (respects NO_COLOR) ────────────────────────────────────────
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  D=$'\033[2m'; B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; Z=$'\033[0m'
else
  D=; B=; G=; Y=; R=; C=; Z=
fi
say()  { if [ "$SR_VERBOSE" = 1 ]; then printf '%s\n' "${D}→ $*${Z}" >&2; fi; }
info() { printf '%s\n' "${D}$*${Z}" >&2; }
warn() { printf '%s\n' "${Y}! $*${Z}" >&2; }
err()  { printf '%s\n' "${R}✗ $*${Z}" >&2; }

# ── python detection (adapters use it for JSON) ───────────────────────
SR_PY=""
for _c in python3 python py; do
  if command -v "$_c" >/dev/null 2>&1 && "$_c" -c 'import json' >/dev/null 2>&1; then
    SR_PY="$_c"; break
  fi
done
export SR_PY

# ── routing table ─────────────────────────────────────────────────────
# Format:  <extended-regex>  →  <adapter-chain>
# The regex and the chain are separated by '=>' (or a tab / 2+ spaces),
# so regexes may contain single spaces. `> ` is also accepted.
# First match wins. `*` matches anything and should be last.
# `|` separates fallbacks — the first adapter that succeeds wins.
# `name:mode` passes a mode to the adapter (see adapters/*.sh).
SR_DEFAULT_ROUTES='
^https?://.*                     => http | wigolo:fetch | crawl4ai:fetch
^[0-9]{6}$                       => anysearch:stock | bing | hackernews
股价|行情|市值|财报|市盈|开盘        => anysearch:quote | bing | hackernews
论文|文献|期刊|DOI|arXiv|PMID      => anysearch:academic | bing | hackernews
法条|判例|司法解释|法规|条例          => anysearch:legal | bing | hackernews
汇率|外汇|货币                     => anysearch:forex | hackernews
加密货币|比特币|以太坊|BTC|ETH       => anysearch:crypto | hackernews
*                                => anysearch | bing | searxng | tavily | hackernews | wikipedia
'

# Split one route line into SR_RL_MATCH / SR_RL_CHAIN.
# Accepts '\t', '=>', '>' or 2+ spaces as the separator so that regexes
# containing a single space still work.
sr_split_route() {
  local line="$1"
  SR_RL_MATCH=""
  SR_RL_CHAIN=""
  case "$line" in
    *$'\t'*)
      SR_RL_MATCH="${line%%$'\t'*}"
      SR_RL_CHAIN="${line#*$'\t'}"
      ;;
    *'=> '*)
      SR_RL_MATCH="${line%%=> *}"
      SR_RL_CHAIN="${line##*=> }"
      ;;
    *' => '*)
      SR_RL_MATCH="${line%% => *}"
      SR_RL_CHAIN="${line##* => }"
      ;;
    *)
      # fall back to 2+ spaces, then to a single space
      if printf '%s' "$line" | grep -qE '  +'; then
        SR_RL_MATCH="$(printf '%s' "$line" | sed -E 's/  +.*$//')"
        SR_RL_CHAIN="$(printf '%s' "$line" | sed -E 's/^.*  +//')"
      else
        SR_RL_MATCH="${line%% *}"
        SR_RL_CHAIN="${line#* }"
      fi
      ;;
  esac
  # trim
  SR_RL_MATCH="$(printf '%s' "$SR_RL_MATCH" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  SR_RL_CHAIN="$(printf '%s' "$SR_RL_CHAIN" | tr -d '[:space:]')"
}

sr_routes() {
  if [ -f "$SR_CONFIG" ]; then
    grep -vE '^[[:space:]]*(#|$)' "$SR_CONFIG"
  else
    printf '%s\n' "$SR_DEFAULT_ROUTES" | grep -vE '^[[:space:]]*(#|$)'
  fi
}

# sr_resolve <input> → prints the adapter chain to use
sr_resolve() {
  local input="$1" line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    sr_split_route "$line"
    [ -z "$SR_RL_CHAIN" ] && continue
    if [ "$SR_RL_MATCH" = "*" ]; then printf '%s' "$SR_RL_CHAIN"; return 0; fi
    [ -z "$SR_RL_MATCH" ] && continue
    if [[ "$input" =~ $SR_RL_MATCH ]]; then printf '%s' "$SR_RL_CHAIN"; return 0; fi
  done < <(sr_routes)
  return 1
}

# ── adapter execution ─────────────────────────────────────────────────
# An adapter is adapters/<name>.sh. Contract:
#   --probe          exit 0 if usable; print a short note to stdout
#   <query...>       print results to stdout; exit 0 on success
#   env: SR_QUERY SR_COUNT SR_MODE SR_PY SR_ROOT
# Exit codes: 127 = adapter file missing, 126 = not installed/usable.
sr_adapter_path() { printf '%s/%s.sh' "$SR_ADAPTERS" "$1"; }

sr_run_one() {
  local spec="$1"; shift
  local name="${spec%%:*}" mode="" ap
  case "$spec" in *:*) mode="${spec#*:}" ;; esac
  ap="$(sr_adapter_path "$name")"
  if [ ! -f "$ap" ]; then
    err "adapter file missing: $ap"
    return 127
  fi
  SR_MODE="$mode" SR_QUERY="$*" SR_COUNT="$SR_COUNT" \
    bash "$ap" "$@"
}

sr_run_chain() {
  local chain="$1"; shift
  local spec out rc oldifs
  oldifs="$IFS"; IFS='|'
  for spec in $chain; do
    IFS="$oldifs"
    [ -z "$spec" ] && continue
    say "trying '$spec'"
    out="$(sr_run_one "$spec" "$@" 2>&1)"; rc=$?
    case $rc in
      0)
        if [ -n "$out" ]; then
          printf '%s\n' "$out"
          say "served by '$spec'"
          return 0
        fi
        warn "'$spec' returned nothing, trying next"
        ;;
      126) warn "'$spec' not available, trying next" ;;
      127) warn "adapter '$spec' missing, trying next" ;;
      *)   warn "'$spec' failed (exit $rc), trying next" ;;
    esac
    IFS='|'
  done
  IFS="$oldifs"
  return 1
}

# ── --check : probe every adapter ─────────────────────────────────────
sr_check() {
  local ap name note ok
  printf '%s\n' "${B}search-router${Z} $SR_VERSION"
  if [ -f "$SR_CONFIG" ]; then
    printf '%s\n' "config: $SR_CONFIG"
  else
    printf '%s\n' "config: ${D}(none — using built-in defaults)${Z}"
  fi
  printf '\n%s\n' "${B}adapters${Z}"
  for ap in "$SR_ADAPTERS"/*.sh; do
    [ -f "$ap" ] || continue
    name="$(basename "$ap" .sh)"
    case "$name" in _*) continue ;; esac
    if note="$(bash "$ap" --probe 2>&1)" && [ $? -eq 0 ]; then
      printf '  %s✓%s %-16s %s\n' "$G" "$Z" "$name" "${D}$note${Z}"
    else
      printf '  %s✗%s %-16s %s\n' "$R" "$Z" "$name" "${D}${note:-unavailable}${Z}"
    fi
  done
  printf '\n%s\n' "${B}routing${Z}"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    sr_split_route "$line"
    [ -z "$SR_RL_CHAIN" ] && continue
    printf '  %-32s → %s\n' "$SR_RL_MATCH" "$SR_RL_CHAIN"
  done < <(sr_routes)
  printf '\n%s\n' "${D}legend: name:mode passes a mode to the adapter${Z}"
}

# ── deep: search, then fetch the top N result pages ───────────────────
sr_deep() {
  local query="$1" n="${2:-2}" hits urls u i
  printf '%s\n' "${B}【1/2】search${Z}" >&2
  hits="$(sr_run_chain "$(sr_resolve "$query")" "$query")" || {
    err "search stage failed"; return 1
  }
  printf '%s\n' "$hits"
  urls="$(printf '%s\n' "$hits" | grep -oE 'https?://[^ )"<>]+' | grep -v '^https\?://$' | head -n "$n")"
  if [ -z "$urls" ]; then
    warn "no fetchable URLs found in results"; return 0
  fi
  printf '\n%s\n' "${B}【2/2】fetch full text${Z}" >&2
  i=0
  while IFS= read -r u; do
    i=$((i + 1))
    printf '\n%s\n' "${C}─── [$i] $u${Z}"
    sr_run_chain "$(sr_resolve "$u")" "$u" || warn "could not fetch $u"
  done <<EOF
$urls
EOF
}

# ── help ──────────────────────────────────────────────────────────────
sr_help() {
  cat <<EOF
${B}search-router${Z} $SR_VERSION — one command, every search tool

${B}USAGE${Z}
  s <query>                  route by content, search
  s deep <query> [N]         search, then fetch the top N pages in full
  s <url>                    fetch a page as text

${B}OPTIONS${Z}
  -a, --adapter <spec>       force an adapter (e.g. -a wikipedia)
  -n, --count <N>            number of results (default $SR_COUNT)
  -v, --verbose              show routing decisions
  -D, --dry-run              show which adapter would run, then exit
      --check                list adapters and their availability
      --routes               show the routing table
      --config               print the config file path
      --init                 write a default config file
  -h, --help                 this text
  -V, --version              version

${B}ROUTING${Z}
  Rules live in the config file (see --config). Each line is:
      <extended-regex>   <adapter-chain>
  First match wins. Use '|' for fallbacks. Example:
      ^[0-9]{6}\$         anysearch:stock | wikipedia
      *                  anysearch | wikipedia | hackernews

${B}ADAPTERS${Z}
  Built in, no API key needed : wikipedia, hackernews, github-repos, http
  Bring your own             : anysearch, wigolo, crawl4ai, tavily, searxng
  Run ${B}s --check${Z} to see what is available on this machine.

${B}EXAMPLES${Z}
  s "postgres index bloat"
  s 600519
  s https://example.com/article
  s deep "低空经济政策" 3
  s -a hackernews -n 5 "rust async"
EOF
}

# ── argument parsing ──────────────────────────────────────────────────
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)     sr_help; exit 0 ;;
    -V|--version)  printf 'search-router %s\n' "$SR_VERSION"; exit 0 ;;
    -v|--verbose)  SR_VERBOSE=1; shift ;;
    -D|--dry-run)  SR_DRYRUN=1; shift ;;
    -a|--adapter)  SR_FORCE="${2:-}"; shift 2 ;;
    -n|--count)    SR_COUNT="${2:-10}"; shift 2 ;;
    --check)       sr_check; exit 0 ;;
    --init)
      mkdir -p "$(dirname "$SR_CONFIG")"
      if [ -f "$SR_CONFIG" ]; then
        err "config already exists: $SR_CONFIG"; exit 1
      fi
      printf '%s\n' "$SR_DEFAULT_ROUTES" | grep -vE '^[[:space:]]*$' > "$SR_CONFIG"
      printf '%s\n' "${G}✓${Z} wrote $SR_CONFIG"
      exit 0 ;;
    --config)      printf '%s\n' "$SR_CONFIG"; exit 0 ;;
    --routes)
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        sr_split_route "$line"
        [ -z "$SR_RL_CHAIN" ] && continue
        printf '  %-32s → %s\n' "$SR_RL_MATCH" "$SR_RL_CHAIN"
      done < <(sr_routes)
      exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    -*) err "unknown option: $1"; printf '\n'; sr_help; exit 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [ ${#ARGS[@]} -eq 0 ]; then sr_help; exit 0; fi

# ── dispatch ──────────────────────────────────────────────────────────
if [ "${ARGS[0]}" = "deep" ] || [ "${ARGS[0]}" = "d" ]; then
  if [ ${#ARGS[@]} -lt 2 ]; then err "usage: s deep <query> [N]"; exit 2; fi
  sr_deep "${ARGS[1]}" "${ARGS[2]:-2}"
  exit $?
fi

QUERY="${ARGS[*]}"

if [ -n "$SR_FORCE" ]; then
  CHAIN="$SR_FORCE"
else
  CHAIN="$(sr_resolve "$QUERY")" || { err "no route matched: $QUERY"; exit 1; }
fi

if [ "$SR_DRYRUN" = 1 ]; then
  printf 'input : %s\n' "$QUERY"
  printf 'chain : %s\n' "$CHAIN"
  IFS='|' read -r first _ <<EOF
$CHAIN
EOF
  printf 'would run: %s\n' "$first"
  exit 0
fi

sr_run_chain "$CHAIN" "$QUERY"
rc=$?
if [ $rc -ne 0 ]; then
  err "all adapters in the chain failed"
  printf '%s\n' "${D}hint: run 's --check' to see what is installed${Z}" >&2
  exit 1
fi
exit 0
