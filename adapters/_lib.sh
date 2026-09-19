#!/usr/bin/env bash
# shared helpers for adapters. Source it:  . "$(dirname "$0")/_lib.sh"
set -uo pipefail

: "${SR_COUNT:=10}"
: "${SR_MODE:=}"
: "${SR_VERSION:=0.1.0}"
: "${SR_UA:=search-router/$SR_VERSION (+https://github.com/woodthree777/search-router)}"
: "${SR_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Detect a python interpreter for adapters that parse JSON. Default to
# python3 (absent on some minimal hosts); callers (e.g. `s`) may override.
if [ -z "${SR_PY:-}" ]; then
  for _c in python3 python py; do
    if command -v "$_c" >/dev/null 2>&1; then
      SR_PY="$_c"; break
    fi
  done
fi
export SR_PY

# json_get <key-path>   — read stdin JSON, print a dotted path.
# Uses python when present, else a crude grep fallback.
json_get() {
  local path="$1"
  if [ -n "${SR_PY:-}" ] && command -v "$SR_PY" >/dev/null 2>&1; then
    "$SR_PY" -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
for k in sys.argv[1].split("."):
    if k == "": continue
    if k.isdigit():
        d = d[int(k)] if isinstance(d, list) and len(d) > int(k) else None
    else:
        d = d.get(k) if isinstance(d, dict) else None
    if d is None: break
if d is None: sys.exit(3)
if isinstance(d, (dict, list)): print(json.dumps(d, ensure_ascii=False))
else: print(d)
' "$path"
  else
    return 3
  fi
}

# Pretty-print a list of records.
# emit_records  — newline-delimited fields, records separated by a blank line
# Each record: title<TAB>url<TAB>snippet<TAB>date
emit_records() {
  local n=0 title url snip date
  while IFS=$'\t' read -r title url snip date; do
    [ -z "${title:-}" ] && continue
    n=$((n + 1))
    printf '\n%s%s%s\n' "${C_B:-}" "$n. $title" "${C_Z:-}"
    [ -n "${url:-}" ]  && printf '   %s\n' "$url"
    [ -n "${date:-}" ] && printf '   %sdate: %s%s\n' "${C_D:-}" "$date" "${C_Z:-}"
    [ -n "${snip:-}" ] && printf '   %s\n' "$snip"
  done
  if [ "$n" = 0 ]; then return 1; fi
  printf '\n%s(%d results)%s\n' "${C_D:-}" "$n" "${C_Z:-}"
  return 0
}

# Colors for adapter output (stdout may be piped — keep them only on a tty)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_B=$'\033[1m'; C_D=$'\033[2m'; C_Z=$'\033[0m'; C_C=$'\033[36m'
else
  C_B=; C_D=; C_Z=; C_C=
fi

# HTTP GET with sane defaults. Prints body to stdout, returns non-zero on error.
http_get() {
  local url="$1"
  curl -fsSL --max-time "${SR_TIMEOUT:-25}" \
       -A "${SR_UA:-search-router/$SR_VERSION (+https://github.com/woodthree777/search-router)}" \
       ${SR_INSECURE:+--insecure} \
       "$url" 2>/dev/null
}

# URL-encode stdin (query strings). Needs python; falls back to a minimal
# pure-bash encoder good enough for ASCII + spaces.
urlencode() {
  if [ -n "${SR_PY:-}" ] && command -v "$SR_PY" >/dev/null 2>&1; then
    "$SR_PY" -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))'
  else
    local s; s="$(cat)"
    s="${s// /%20}"; s="${s//&/%26}"; s="${s//\#/%23}"; s="${s//\?/%3F}"
    printf '%s' "$s"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 126; }
}

# Create a temp file whose path NATIVE tools can open.
# mktemp returns an MSYS path like /tmp/x, which Windows binaries
# (python.exe, node.exe) cannot resolve — translate to C:/… first.
sr_native_path() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p" 2>/dev/null && return 0
  fi
  case "$p" in
    /[a-zA-Z]/*) printf '%s' "$p" | sed -E 's|^/([a-zA-Z])/|\1:/|' ;;
    *) printf '%s' "$p" ;;
  esac
}

sr_tmpfile() {
  local suffix="${1:-}" dir nat f
  for dir in "${SR_TMPDIR:-}" "${TEMP:-}" "${TMPDIR:-}" "${LOCALAPPDATA:-}/Temp" /tmp; do
    [ -z "$dir" ] && continue
    [ -d "$dir" ] || continue
    nat="$(sr_native_path "$dir")"
    f="${nat%/}/sr_$$_${RANDOM}${suffix}"
    if : > "$f" 2>/dev/null; then
      # Prove a native interpreter can read it back; otherwise skip.
      if [ -n "${SR_PY:-}" ] && command -v "$SR_PY" >/dev/null 2>&1; then
        if ! "$SR_PY" -c 'import sys; open(sys.argv[1]).close()' "$f" >/dev/null 2>&1; then
          rm -f "$f" 2>/dev/null
          continue
        fi
      fi
      printf '%s' "$f"
      return 0
    fi
  done
  return 1
}
