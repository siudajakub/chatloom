#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Idle performance snapshot of the installed ChatLoom app on an Android device.
#
#   scripts/android/perf-snapshot.sh [-s SERIAL] [-p PACKAGE] [-t SECONDS] [--perf]
#
#   -s SERIAL   adb device serial (default: the only/first connected device)
#   -p PACKAGE  package to inspect (default: applicationId read from
#               android/app/build.gradle.kts)
#   -t SECONDS  idle window, default 30
#   --perf      inspect the benchmark build (applicationId + ".perf")
#
# Start the app, open the screen to measure, leave the phone untouched with
# the screen on, then run the script. During the idle window it counts:
#   * Flutter frames: frames SurfaceFlinger received from the app's layers
#     (`dumpsys SurfaceFlinger --timestats`, fallback `--latency`; Flutter
#     draws into a SurfaceView, which HWUI's gfxinfo does not see);
#   * HWUI frames: `dumpsys gfxinfo <pkg> reset`, then `framestats`;
#   * CPU: process utime+stime from /proc over the window, plus `top -n 1`.
# Then it prints `dumpsys meminfo <pkg>` (App Summary, PSS/RSS) and a
# `dumpsys batterystats --charged <pkg>` summary (CPU time, wakeup alarms and
# wake locks as totals). An idle app should show 0 frames and ~0 % CPU.
#
# Output is aggregate numbers only: no message content, no layer, wake lock,
# alarm or job names, no user, uid or device identifiers beyond the package
# name. It changes nothing on the device except resetting the app's gfxinfo
# counters and briefly enabling SurfaceFlinger time stats (disabled again
# on exit). It never launches, stops or clears the app.
set -euo pipefail
cd "$(dirname "$0")/../.."

usage() { sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit "${1:-2}"; }

serial=""
package=""
seconds=30
perf=0
while [ $# -gt 0 ]; do
  case "$1" in
    -s) serial=${2:?}; shift 2 ;;
    -p) package=${2:?}; shift 2 ;;
    -t) seconds=${2:?}; shift 2 ;;
    --perf) perf=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done
case "$seconds" in ''|*[!0-9]*) echo "-t needs whole seconds" >&2; exit 2 ;; esac
[ "$seconds" -ge 1 ] || { echo "-t needs at least 1 second" >&2; exit 2; }

if [ -z "$package" ]; then
  gradle=$(ls android/app/build.gradle.kts android/app/build.gradle 2>/dev/null | head -1 || true)
  [ -n "$gradle" ] || { echo "android/app/build.gradle(.kts) not found; pass -p." >&2; exit 1; }
  package=$(sed -n 's/^[[:space:]]*applicationId[[:space:]]*=\{0,1\}[[:space:]]*"\([^"]*\)".*/\1/p' "$gradle" | head -1)
  [ -n "$package" ] || { echo "No applicationId in $gradle; pass -p." >&2; exit 1; }
  [ "$perf" -eq 1 ] && package="$package.perf"
fi

command -v adb >/dev/null || { echo "adb not found on PATH." >&2; exit 1; }
if [ -z "$serial" ]; then
  serial=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')
  [ -n "$serial" ] || { echo "No Android device connected." >&2; exit 1; }
fi
sh_() { adb -s "$serial" shell "$@" | tr -d '\r'; }

sh_ pm path "$package" 2>/dev/null | grep -q '^package:' ||
  { echo "$package is not installed on the device." >&2; exit 1; }
pid=$(sh_ pidof "$package" 2>/dev/null | awk '{ print $1 }' || true)
[ -n "$pid" ] || { echo "$package is not running; start it and open the screen to measure." >&2; exit 1; }

foreground=no
if sh_ dumpsys window 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' | grep -qF "$package/"; then
  foreground=yes
fi
screen=$(sh_ dumpsys power 2>/dev/null | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -1)

# CPU ticks (utime + stime, fields 14 and 15 of /proc/PID/stat; the command
# name in field 2 may contain spaces, so cut after the closing parenthesis).
ticks() {
  sh_ cat "/proc/$pid/stat" 2>/dev/null |
    awk '{ sub(/^.*\) /, ""); print $12 + $13 }' || true
}
hz=$(sh_ getconf CLK_TCK 2>/dev/null || true)
case "$hz" in ''|*[!0-9]*) hz=100 ;; esac

# SurfaceFlinger frame counters. timestats keeps every frame (Android 10+);
# --latency keeps the last 127 frames of one layer.
timestats=0
cleanup() {
  [ "$timestats" -eq 1 ] && sh_ dumpsys SurfaceFlinger --timestats -disable >/dev/null 2>&1 || true
}
trap cleanup EXIT
if sh_ dumpsys SurfaceFlinger --timestats -enable -clear >/dev/null 2>&1; then
  timestats=1
fi
layers=$(sh_ dumpsys SurfaceFlinger --list 2>/dev/null | grep -F "$package" | grep 'SurfaceView' || true)
if [ -n "$layers" ]; then
  printf '%s\n' "$layers" | while IFS= read -r layer; do
    sh_ dumpsys SurfaceFlinger --latency-clear "$layer" >/dev/null 2>&1 || true
  done
fi

sh_ dumpsys gfxinfo "$package" reset >/dev/null
t0=$(ticks)
echo "Measuring $package for ${seconds}s idle (foreground: $foreground, screen: ${screen:-unknown})…" >&2
sleep "$seconds"
t1=$(ticks)

# ------------------------------------------------------------------ frames
sf_frames=""
if [ "$timestats" -eq 1 ]; then
  sf_frames=$(sh_ dumpsys SurfaceFlinger --timestats -dump 2>/dev/null | awk -v pkg="$package" '
    /^[[:space:]]*layerName = / { mine = index($0, pkg) > 0 }
    /^[[:space:]]*packageName = / && index($0, pkg) > 0 { mine = 1 }
    /^[[:space:]]*totalFrames = / && mine { sum += $3; seen = 1 }
    END { if (seen) print sum }')
fi
sf_source="timestats"
if [ -z "$sf_frames" ] && [ -n "$layers" ]; then
  sf_source="latency (max 127 per layer)"
  sf_frames=$(printf '%s\n' "$layers" | while IFS= read -r layer; do
    sh_ dumpsys SurfaceFlinger --latency "$layer" 2>/dev/null |
      awk 'NR > 1 && NF == 3 && $2 != 0 && $2 < 9e18 { n++ } END { print n + 0 }'
  done | awk '{ s += $1 } END { print s + 0 }')
fi

gfx=$(sh_ dumpsys gfxinfo "$package" framestats)
hwui_total=$(printf '%s\n' "$gfx" | sed -n 's/^Total frames rendered: *\([0-9]*\).*/\1/p' | head -1)
hwui_janky=$(printf '%s\n' "$gfx" | sed -n 's/^Janky frames: *\(.*\)$/\1/p' | head -1)
hwui_p50=$(printf '%s\n' "$gfx" | sed -n 's/^50th percentile: *\(.*\)$/\1/p' | head -1)
hwui_p90=$(printf '%s\n' "$gfx" | sed -n 's/^90th percentile: *\(.*\)$/\1/p' | head -1)
hwui_rows=$(printf '%s\n' "$gfx" | awk '
  /^---PROFILEDATA---/ { inside = !inside; next }
  inside && /^[0-9]/ { split($0, f, ","); if (f[1] == 0) n++ }
  END { print n + 0 }')

# --------------------------------------------------------------------- CPU
cpu_window="n/a"
if [ -n "$t0" ] && [ -n "$t1" ]; then
  cpu_window=$(awk -v a="$t0" -v b="$t1" -v hz="$hz" -v s="$seconds" \
    'BEGIN { printf "%.2f %% of one core (%.2f s CPU)", (b - a) * 100 / hz / s, (b - a) / hz }')
fi
top_line=$(sh_ top -b -n 1 -p "$pid" -o %CPU,RES,S,TIME+ 2>/dev/null | awk 'NF && $1 ~ /^[0-9.]+$/ { print; exit }' || true)

# ------------------------------------------------------------------ memory
mem=$(sh_ dumpsys meminfo "$package")
# App Summary rows: "Label:  PSS  [RSS]" (columns as dumpsys prints them).
mem_summary=$(printf '%s\n' "$mem" | awk '
  /App Summary/ { on = 1; next }
  on && /TOTAL/ { exit }
  on && /:/ {
    split($0, part, ":"); label = part[1]; gsub(/^[[:space:]]+/, "", label)
    rest = part[2]; gsub(/[[:space:]]+/, " ", rest)
    printf "  %-15s%s\n", label ":", rest
  }')
mem_total=$(printf '%s\n' "$mem" | sed -n 's/^ *TOTAL PSS: *\([0-9]*\).*TOTAL RSS: *\([0-9]*\).*/PSS \1 kB, RSS \2 kB/p' | head -1)
if [ -z "$mem_total" ]; then
  mem_total=$(printf '%s\n' "$mem" | awk '$1 == "TOTAL" && $2 ~ /^[0-9]+$/ { print "PSS " $2 " kB"; exit }')
fi

# ----------------------------------------------------------------- battery
bat=$(sh_ dumpsys batterystats --charged "$package" 2>/dev/null || true)
bat_summary=$(printf '%s\n' "$bat" | awk '
  /Total cpu time:/ && !cpu { sub(/^[[:space:]]+/, ""); cpu = $0 }
  /Wakeup alarm / { if (match($0, /[0-9]+ times/)) { alarms += substr($0, RSTART, RLENGTH) + 0 } }
  /Wake lock / && /partial/ {
    locks++
    if (match($0, /\(([0-9]+) times\)/)) { lockn += substr($0, RSTART + 1, RLENGTH - 8) + 0 }
  }
  /Foreground services?:/ && !fg { sub(/^[[:space:]]+/, ""); fg = $0 }
  /Total running:/ && !run { sub(/^[[:space:]]+/, ""); run = $0 }
  END {
    print "  " (cpu ? cpu : "Total cpu time: n/a")
    print "  Wakeup alarms: " alarms + 0
    print "  Partial wake locks: " locks + 0 " tags, " lockn + 0 " acquisitions"
    if (run) print "  " run
  }')

# ----------------------------------------------------------------- summary
cat <<EOF

ChatLoom perf snapshot: $package (pid present, foreground: $foreground, screen: ${screen:-unknown})
Idle window: ${seconds}s
Frames
  Flutter surface frames: ${sf_frames:-n/a}${sf_frames:+ via $sf_source}
  HWUI frames (gfxinfo): ${hwui_total:-n/a} rendered, ${hwui_rows} in framestats, janky ${hwui_janky:-n/a}, p50 ${hwui_p50:-n/a}, p90 ${hwui_p90:-n/a}
CPU
  Over the window: $cpu_window
  top -n 1 (%CPU RES S TIME+): ${top_line:-n/a}
Memory (dumpsys meminfo App Summary, kB: PSS RSS)
  Total: ${mem_total:-n/a}
$mem_summary
Battery since last charge (dumpsys batterystats --charged)
$bat_summary
EOF
if [ "$foreground" != yes ]; then
  echo "Note: the app was not in the foreground; frame counts only mean something with the screen on and the app visible." >&2
fi
