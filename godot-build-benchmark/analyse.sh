#!/usr/bin/env bash
# Extract benchmark metrics from a paired build/memstats log.
# - Peak RAM, peak pageout rate, total pageouts: from memstats TSV alone.
# - LTO link-share: needs the build log with [HH:MM:SS] prefixes (build-caligula.sh adds these;
#   chromium's build-chromium.sh does not, so this section will skip on chromium logs).
set -euo pipefail

usage() { echo "Usage: $(basename "$0") logs/memstats-<ts>.log [logs/build-<ts>.log] [--link-target NAME]"; }

MEMSTATS=""
BUILDLOG=""
LINK_TARGET=""   # Unused for Godot — see link-share section below for why

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

# --- LTO link-share: NOT EXTRACTED for Godot. ---
# Godot uses SCons, which emits "Linking Program <path> ..." rather than cmake/ninja's
# "Linking CXX executable <path>". A SCons-aware regex would be straightforward to add,
# but it's deliberately omitted here because:
#   - The Caligula reference measured link-share at 0.1% (2s of 1593s). The metric is not
#     load-bearing for cross-machine ranking — see godot-build-benchmark/SPEC.md §5.
#   - Generalising analyse.sh to detect SCons vs cmake/ninja output adds complexity for
#     marginal value, given the metric's negligible weight in the comparison.
# The other metrics above (peak RAM, swap, pageouts) work identically for any build that
# emits the memstats TSV — they don't depend on the build-log format.
if [[ -n "$BUILDLOG" && -f "$BUILDLOG" ]]; then
  echo "--- LTO link-share (target: <skipped for SCons builds>) ---"
  echo "  (SCons builds emit 'Linking Program ...' rather than ninja's 'Linking CXX executable ...';"
  echo "   link-share is intentionally not extracted here. Caligula's link-share was 0.1%,"
  echo "   so this metric is not load-bearing for ranking. See SPEC.md §5.)"
  echo
fi
