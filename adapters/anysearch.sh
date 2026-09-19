#!/usr/bin/env bash
# anysearch — optional adapter for a local anysearch CLI install.
#
# Configure one of:
#   ANYSEARCH_CLI   absolute path to the CLI script
#   ANYSEARCH_DIR   directory containing scripts/anysearch_cli.py
#
# Modes (mode:name):  stock | quote | forex | crypto | academic | legal
# Vertical search returns structured fields (prices, macro data) rather
# than page snippets, which is why this adapter is worth wiring up.
. "$(dirname "$0")/_lib.sh"

sr_cli() {
  if [ -n "${ANYSEARCH_CLI:-}" ] && [ -f "$ANYSEARCH_CLI" ]; then
    printf '%s' "$ANYSEARCH_CLI"; return 0
  fi
  if [ -n "${ANYSEARCH_DIR:-}" ] && [ -f "$ANYSEARCH_DIR/scripts/anysearch_cli.py" ]; then
    printf '%s' "$ANYSEARCH_DIR/scripts/anysearch_cli.py"; return 0
  fi
  return 1
}

sr_run_cli() {
  local cli="$1"; shift
  local dir; dir="$(cd "$(dirname "$cli")/.." && pwd)"
  local py; py="$(sr_python)"
  # The CLI reads its .env from the skill directory, so run inside it.
  ( cd "$dir" && "$py" "$cli" "$@" )
}

sr_python() {
  local c
  for c in "${ANYSEARCH_PY:-}" python3 python py; do
    [ -z "$c" ] && continue
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json' >/dev/null 2>&1; then
      printf '%s' "$c"; return 0
    fi
  done
  return 1
}

probe() {
  local cli; cli="$(sr_cli)" || { echo "install anysearch, or set ANYSEARCH_DIR"; return 126; }
  local py;  py="$(sr_python)"  || { echo "no python3 found"; return 126; }
  echo "found: $cli (python: $py)"
}

if [ "${1:-}" = "--probe" ]; then probe; exit $?; fi

CLI="$(sr_cli)" || { echo "anysearch not configured (set ANYSEARCH_DIR)" >&2; exit 126; }
PY="$(sr_python)" || { echo "python3 required" >&2; exit 126; }

QUERY="${*:-${SR_QUERY:-}}"
[ -z "$QUERY" ] && { echo "usage: anysearch <query>" >&2; exit 2; }

case "$SR_MODE" in
  stock)
    # A-share codes get .SS/.SZ; anything else is passed through.
    sym="$QUERY"
    case "$QUERY" in
      *.*|*[A-Za-z]*) ;;                 # already qualified or a ticker
      6*) sym="$QUERY.SS" ;;
      0*|3*) sym="$QUERY.SZ" ;;
    esac
    sr_run_cli "$CLI" search "$sym" --max_results "$SR_COUNT" \
      --tag finance.quote --params "type=stock,symbol=$sym,cn_code=" ;;
  quote)
    code="$(printf '%s' "$QUERY" | grep -oE '[0-9]{6}' | head -1)"
    sym="${code:-$QUERY}"
    case "$sym" in
      6*) [ "${sym#*.}" = "$sym" ] && sym="$sym.SS" ;;
      0*|3*) [ "${sym#*.}" = "$sym" ] && sym="$sym.SZ" ;;
    esac
    sr_run_cli "$CLI" search "$sym" --max_results "$SR_COUNT" \
      --tag finance.quote --params "type=stock,symbol=$sym,cn_code=" ;;
  forex)   sr_run_cli "$CLI" search "$QUERY" --max_results "$SR_COUNT" \
             --tag finance.quote --params "type=forex,symbol=$QUERY,cn_code=" ;;
  crypto)
    sym="$QUERY"; case "$sym" in *USD|*USDT) ;; *) sym="${sym}USD" ;; esac
    sr_run_cli "$CLI" search "$QUERY" --max_results "$SR_COUNT" \
      --tag finance.quote --params "type=crypto,symbol=$sym,cn_code=" ;;
  academic) sr_run_cli "$CLI" search "$QUERY" --max_results "$SR_COUNT" --tag academic.search ;;
  legal)    sr_run_cli "$CLI" search "$QUERY" --max_results "$SR_COUNT" --tag legal.statute ;;
  *)        sr_run_cli "$CLI" search "$QUERY" --max_results "$SR_COUNT" ;;
esac
