#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Idle performance snapshot of the running ChatLoom macOS app.
#
#   scripts/macos/perf-snapshot.sh [-n PROCESS] [-t SECONDS]
#
#   -n PROCESS  process name (default: ChatLoom, PRODUCT_NAME in
#               macos/Runner/Configs/AppInfo.xcconfig)
#   -t SECONDS  idle window, default 30 (one `top` sample per second)
#
# Leave the app untouched (focused, or in the background to check that it
# rests), then run the script. It prints `top -l` samples of CPU %, idle
# wakeups, Energy Impact (power) and memory, their averages over the window,
# and the memory summary of `footprint` (or `vmmap --summary`) when
# available. An idle app should average ~0 % CPU and few idle wakeups.
# Output is numbers only: no window titles, message content or identifiers.
set -euo pipefail
cd "$(dirname "$0")/../.."

usage() { sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit "${1:-2}"; }

name=""
seconds=30
while [ $# -gt 0 ]; do
  case "$1" in
    -n) name=${2:?}; shift 2 ;;
    -t) seconds=${2:?}; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done
case "$seconds" in ''|*[!0-9]*) echo "-t needs whole seconds" >&2; exit 2 ;; esac
[ "$seconds" -ge 1 ] || { echo "-t needs at least 1 second" >&2; exit 2; }
if [ -z "$name" ]; then
  name=$(sed -n 's/^PRODUCT_NAME *= *//p' macos/Runner/Configs/AppInfo.xcconfig 2>/dev/null | head -1)
  name=${name:-ChatLoom}
fi

[ "$(uname -s)" = Darwin ] || { echo "macOS only." >&2; exit 1; }
pid=$(pgrep -x "$name" | head -1 || true)
[ -n "$pid" ] || { echo "$name is not running." >&2; exit 1; }

echo "Measuring $name for ${seconds}s…" >&2
# One sample per second; the first `top -l` sample has no CPU delta, so take
# one extra and drop it.
samples=$(top -l $((seconds + 1)) -s 1 -pid "$pid" -stats pid,cpu,idlew,power,mem |
  awk -v pid="$pid" '$1 == pid { print $2, $3, $4, $5 }' | tail -n "$seconds")

# MEM is printed like 182M, 1024K or 1.2G (maybe with a +/- trend); convert to MB for the average.
summary=$(printf '%s\n' "$samples" | awk '
  function mb(v,  n, u) {
    gsub(/[+-]$/, "", v)
    n = v + 0; u = substr(v, length(v))
    if (u == "G") return n * 1024
    if (u == "K") return n / 1024
    if (u == "B") return n / 1048576
    return n
  }
  NF == 4 {
    k++; cpu += $1; idlew += $2; power += $3; mem = mb($4)
    if ($1 > maxcpu) maxcpu = $1
  }
  END {
    if (!k) { print "  no samples"; exit }
    printf "  CPU: avg %.2f %%, max %.2f %%\n", cpu / k, maxcpu
    printf "  Idle wakeups: avg %.1f per sample (%d samples)\n", idlew / k, k
    printf "  Energy Impact (power): avg %.2f\n", power / k
    printf "  Memory (top MEM): %.0f MB at the end\n", mem
  }')

cat <<EOF

ChatLoom perf snapshot: $name, ${seconds}s idle
top -l (CPU %, idle wakeups, power, mem per second)
$(printf '%s\n' "$samples" | sed 's/^/  /')
Averages
$summary
EOF

if command -v footprint >/dev/null 2>&1; then
  echo "Memory (footprint)"
  footprint "$pid" 2>/dev/null |
    awk '/[Ff]ootprint:|TOTAL|phys_footprint/ { sub(/^[[:space:]]+/, ""); print "  " $0 }' |
    grep -v -i 'path\|/' | head -8 || true
elif command -v vmmap >/dev/null 2>&1; then
  echo "Memory (vmmap --summary)"
  vmmap --summary "$pid" 2>/dev/null |
    awk '/^Physical footprint|^ReadOnly portion|^Writable regions|^TOTAL/ { print "  " $0 }' || true
fi
