#!/usr/bin/env bash
# Extract benchmark metrics from a paired build/memstats log.
# - Peak RAM, peak pageout rate, total pageouts: from memstats TSV alone.
# - LTO link-share: needs the build log with [HH:MM:SS] prefixes (build-caligula.sh adds these;
#   chromium's build-chromium.sh does not, so this section will skip on chromium logs).
set -euo pipefail

usage() { echo "Usage: $(basename "$0") logs/memstats-<ts>.log [logs/build-<ts>.log] [--link-target NAME]"; }

MEMSTATS=""
BUILDLOG=""
LINK_TARGET="victoria3"   # Caligula's ReleaseLto target; override via --link-target for other presets/projects

while [[ $# -gt 0 ]]; do
  case "$1" in
    --link-target) LINK_TARGET="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)
      if [[ -z "$MEMSTATS" ]]; then MEMSTATS="$1"
      elif [[ -z "$BUILDLOG" ]]; then BUILDLOG="$1"
      else usage >&2; exit 2
      fi
      shift ;;
  esac
done

[[ -n "$MEMSTATS" && -f "$MEMSTATS" ]] || { usage >&2; exit 2; }

# Memstats column layout (1-indexed for awk):
# 1=time 2=uptime_s 3=free 4=active 5=inactive 6=spec 7=wired 8=compressed
# 9=pageins 10=pageouts 11=swap_used 12=swap_total

echo "=== File: $MEMSTATS ==="
echo

# --- Sample-count + duration sanity check ---
samples=$(awk 'NR>1' "$MEMSTATS" | wc -l | tr -d ' ')
duration=$(awk -F'\t' 'NR>1 { last=$2 } END { print last }' "$MEMSTATS")
echo "Samples:   $samples"
echo "Duration:  ${duration}s"
echo

# --- Peak RAM used (active + wired + compressed) ---
# Free / inactive / speculative are reclaimable; not "used" in the pressure sense.
echo "--- Peak RAM (active + wired + compressed, MB) ---"
awk -F'\t' '
  NR>1 {
    used = $4 + $7 + $8
    if (used > max) { max = used; ts = $1 }
  }
  END { printf "  peak: %d MB at %s\n", max, ts }
' "$MEMSTATS"
echo

# --- Peak swap used (MB) ---
echo "--- Peak swap usage (MB) ---"
awk -F'\t' '
  NR>1 {
    if ($11 > max) { max = $11; ts = $1 }
  }
  END { printf "  peak: %d MB at %s\n", max, ts }
' "$MEMSTATS"
echo

# --- Pageouts: cumulative col 10. Diff between consecutive rows for per-second rate. ---
echo "--- Pageout rate (pages/sec) ---"
awk -F'\t' '
  NR>1 {
    if (prev != "") {
      r = $10 - prev
      if (r > max) { max = r; ts = $1 }
      sum += r
      n += 1
      if (r > 0) { non_zero += 1 }
    }
    prev = $10
  }
  END {
    if (n > 0) {
      printf "  peak: %d pages/sec at %s\n", max, ts
      printf "  mean: %.1f pages/sec (over %d intervals)\n", sum/n, n
      printf "  intervals with any pageout: %d / %d (%.1f%%)\n", non_zero, n, 100*non_zero/n
    } else {
      printf "  (insufficient samples)\n"
    }
  }
' "$MEMSTATS"
echo

echo "--- Total pages paged out (delta of cumulative col 10) ---"
awk -F'\t' '
  NR==2 { first = $10 }
  NR>1  { last = $10 }
  END   { printf "  total: %d pages (%.1f MB at 16 KiB pages)\n", last-first, (last-first)*16/1024 }
' "$MEMSTATS"
echo

# --- LTO link-share: best-effort. Requires HH:MM:SS-prefixed build log. ---
# Looks for the line `[HH:MM:SS] [N/M] Linking CXX executable <target>` (or similar).
# That's the start of the final link; the build's compile timer end gives us link duration.
if [[ -n "$BUILDLOG" && -f "$BUILDLOG" ]]; then
  echo "--- LTO link-share (target: $LINK_TARGET) ---"
  # cmake/ninja prints either bare target name or full path. Match both: "executable victoria3"
  # OR "executable /path/.../victoria3" (with optional .app bundle path before the basename).
  link_start_line=$(grep -E "^\[[0-9:]+\].*Linking (CXX|C) executable .*[/ ]${LINK_TARGET}([ /]|\$)" "$BUILDLOG" | head -1 || true)
  compile_line=$(grep -E "^\[[0-9:]+\] Compile time:" "$BUILDLOG" | head -1 || true)

  if [[ -z "$link_start_line" ]]; then
    echo "  (no '[HH:MM:SS] ... Linking ... executable $LINK_TARGET' line found in $BUILDLOG)"
    echo "  hint: pass --link-target with the actual cmake target name, or build with build-caligula.sh"
    echo "        (the chromium script doesn't prefix ninja output with [HH:MM:SS] so this won't work there)"
  elif [[ -z "$compile_line" ]]; then
    echo "  (no '[HH:MM:SS] Compile time:' line — build may not have completed successfully)"
  else
    link_start=$(echo "$link_start_line" | grep -oE '^\[[0-9:]+\]' | tr -d '[]')
    link_end=$(echo "$compile_line" | grep -oE '^\[[0-9:]+\]' | tr -d '[]')
    total_s=$(grep -oE 'Compile time:.*\(([0-9]+)s total\)' "$BUILDLOG" | head -1 | grep -oE '[0-9]+s total' | grep -oE '[0-9]+')

    # Compute link duration in seconds via date arithmetic. Both times are HH:MM:SS on same day.
    # If the build crosses midnight, this will go negative; we don't handle that case (unlikely for a single build).
    link_start_s=$(echo "$link_start" | awk -F: '{ print $1*3600 + $2*60 + $3 }')
    link_end_s=$(echo "$link_end"   | awk -F: '{ print $1*3600 + $2*60 + $3 }')
    link_duration=$(( link_end_s - link_start_s ))
    if (( link_duration < 0 )); then link_duration=$(( link_duration + 86400 )); fi

    if [[ -n "$total_s" && "$total_s" -gt 0 ]]; then
      share=$(awk "BEGIN { printf \"%.1f\", 100 * $link_duration / $total_s }")
      printf "  link starts: %s\n" "$link_start"
      printf "  build ends:  %s\n" "$link_end"
      printf "  link duration: %ds of %ds total = %s%%\n" "$link_duration" "$total_s" "$share"
    else
      echo "  (couldn't parse total compile time from $BUILDLOG)"
    fi
  fi
  echo
fi
