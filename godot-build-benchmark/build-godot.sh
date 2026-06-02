#!/usr/bin/env bash
# Profile a Godot Engine build: time the compile + sidecar memory/page sampling.
# Pins to a release-tag SHA so reruns weeks later build the same source.
# Memstats sampler is identical to the caligula, chromium, and ogre3d harnesses — see SPEC.md.
#
# NB: Godot uses SCons, not CMake+Ninja. This means there's no separate "configure" phase,
# and SCons output won't match analyse.sh's "Linking CXX executable" regex (see SPEC.md §5).
set -euo pipefail

# --- Defaults and flags ---
# Source tree location (~2 GB after clone, ~5-8 GB after full build).
GODOT_DIR="${GODOT_DIR:-$HOME/godot}"
# 4.6.3-stable release tag SHA. Latest stable as of 2026-06-02. See SPEC.md §4 for re-pin guidance.
GODOT_REV="7d41c59c457bd5a245092b4e7eb2d833e3b3f8c3"
GODOT_TAG="4.6.3-stable"
# Build target. 'editor' produces the full Godot editor binary — the heaviest standalone target.
SCONS_TARGET="${SCONS_TARGET:-editor}"
JOBS="${JOBS:-}"
MEMSTATS_INTERVAL="${MEMSTATS_INTERVAL:-1}"
CLEAN=1
CHECK_ONLY=0
RESCUE=1
MISSING=()
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
TS="$(date +%Y%m%d-%H%M%S)"

# --- Logging helpers (identical to caligula / ogre3d scripts) ---
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
confirm() { read -r -p "$1 [y/N] " r; [[ "${r:-}" =~ ^[Yy]$ ]]; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [--target NAME] [--jobs N] [--no-clean] [--check]
                       [--no-rescue] [--godot-dir PATH] [-h|--help]

  --target NAME       SCons target. Default: editor (full Godot editor — heaviest).
                      Alternatives: template_release, template_debug. Env: SCONS_TARGET.
  --jobs N            num_jobs for SCons. Default: nproc --ignore 2 emulation.
                      Env: JOBS.
  --no-clean          Skip wipe of \$GODOT_DIR/bin and .sconsign.dblite. Default cold-build wipes.
  --check             Run prerequisite checks only; skip fetch and build.
  --no-rescue         Do not attempt to brew install missing prerequisites.
  --godot-dir PATH    Godot source tree. Default: \$HOME/godot. Env: GODOT_DIR.
  -h, --help          Show this help.

Outputs (paired by timestamp):
  logs/build-<ts>.log     — full transcript, ends with 'Compile time: Hh Mm Ss'
  logs/memstats-<ts>.log  — per-second TSV of memory/paging state during compile

Pinned to godotengine/godot $GODOT_TAG (SHA $GODOT_REV).
Build args: platform=macos arch=arm64 target=$SCONS_TARGET production=yes vulkan=no num_jobs=\$JOBS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)    SCONS_TARGET="$2"; shift 2 ;;
    --jobs)      JOBS="$2"; shift 2 ;;
    --no-clean)  CLEAN=0; shift ;;
    --check)     CHECK_ONLY=1; shift ;;
    --no-rescue) RESCUE=0; shift ;;
    --godot-dir) GODOT_DIR="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

[[ "$(uname)" == "Darwin" ]] || die "this script only runs on macOS (found: $(uname))"

# Apple Silicon assumption — see SPEC.md §7. Intel hosts need different `arch=` flag.
HOST_ARCH="$(uname -m)"
[[ "$HOST_ARCH" == "arm64" ]] || warn "expected arm64 host; found $HOST_ARCH — SCons arch= flag is hardcoded to arm64"

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/build-${TS}.log"
exec > >(tee -a "$LOG_FILE") 2>&1
log "Logging to $LOG_FILE"
log "Godot dir: $GODOT_DIR"
log "Pinned to $GODOT_TAG ($GODOT_REV)"
log "SCons target: $SCONS_TARGET"

# --- Verification helpers ---
need() { MISSING+=("$1"); warn "missing: $1"; }
check_bin() { if command -v "$1" >/dev/null 2>&1; then log "$1: OK ($(command -v "$1"))"; else need "$1"; fi; }

check_xcode_clt() {
  if xcode-select -p >/dev/null 2>&1; then log "Xcode CLT: OK ($(xcode-select -p))"; else need "xcode-clt"; fi
}

# Disk-space check — Godot source + bin output is ~5-8 GB; 10 GB headroom is comfortable.
check_disk_space() {
  local parent; parent="$(dirname "$GODOT_DIR")"; mkdir -p "$parent"
  local free_gb; free_gb=$(( $(df -k "$parent" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
  if (( free_gb < 10 )); then warn "only ${free_gb} GB free on $parent; Godot needs ~10 GB"; else log "Disk space: ${free_gb} GB free on $parent"; fi
}

verify() {
  log "=== Phase 1: verifying prerequisites ==="
  check_xcode_clt
  check_bin python3
  check_bin scons
  check_bin git
  check_bin brew
  check_disk_space
}

# --- Rescue: brew install anything check_bin flagged ---
rescue() {
  log "=== Phase 2: rescuing missing prerequisites ==="
  for item in "${MISSING[@]}"; do
    case "$item" in
      python3|scons|git)
        confirm "brew install $item?" || die "cannot proceed without $item"
        brew install "$item"
        ;;
      xcode-clt)
        confirm "Install Xcode Command Line Tools? (opens GUI installer)" || die "cannot proceed without Xcode CLT"
        xcode-select --install || true
        log "Click through the installer, then re-run this script."
        exit 1
        ;;
      brew)
        die "Homebrew is required to rescue other deps; install from https://brew.sh first"
        ;;
      *) warn "no rescue handler for: $item" ;;
    esac
  done
  MISSING=()
  verify
  (( ${#MISSING[@]} == 0 )) || die "still missing after rescue: ${MISSING[*]}"
}

# --- Resolve JOBS (identical logic to caligula / ogre3d) ---
resolve_jobs() {
  if [[ -n "$JOBS" ]]; then log "JOBS explicit: $JOBS"; return; fi
  local n
  if command -v nproc >/dev/null 2>&1; then
    n=$(nproc --ignore 2 2>/dev/null) || n=$(nproc)
  elif command -v gnproc >/dev/null 2>&1; then
    n=$(gnproc --ignore 2)
  else
    n=$(sysctl -n hw.ncpu)
    n=$(( n > 2 ? n - 2 : 1 ))
  fi
  JOBS="$n"
  log "JOBS auto: $JOBS (matches caligula default: nproc --ignore 2)"
}

# --- Phase 3: fetch source. Idempotent. ---
fetch_source() {
  log "=== Phase 3: fetch Godot source into $GODOT_DIR ==="
  mkdir -p "$(dirname "$GODOT_DIR")"
  if [[ -d "$GODOT_DIR/.git" ]]; then
    log "$GODOT_DIR/.git already present, skipping clone"
  else
    caffeinate -i git clone https://github.com/godotengine/godot.git "$GODOT_DIR"
  fi
}

# --- Phase 4: pin to the immutable release-tag SHA. ---
pin_revision() {
  log "=== Phase 4: pinning to $GODOT_TAG ($GODOT_REV) ==="
  git -C "$GODOT_DIR" fetch --depth=1 origin "$GODOT_REV"
  git -C "$GODOT_DIR" checkout --force --detach "$GODOT_REV"
}

# --- Background memstats sampler (identical to caligula / ogre3d / chromium scripts) ---
start_memstats_sampler() {
  local out="$1"
  printf 'time\tuptime_s\tfree_mb\tactive_mb\tinactive_mb\tspec_mb\twired_mb\tcompressed_mb\tpageins\tpageouts\tswap_used_mb\tswap_total_mb\n' > "$out"
  (
    exec >/dev/null 2>&1
    local sampler_start=$SECONDS
    while true; do
      local stats swap
      stats=$(vm_stat | awk '
        BEGIN { ps=16384 }
        /page size of/ { for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\)?$/) { gsub(/\)/,"",$i); ps=$i+0; break } }
        function mb(p) { return int(p * ps / 1024 / 1024) }
        /^Pages free:/                       { free=mb($3+0) }
        /^Pages active:/                     { active=mb($3+0) }
        /^Pages inactive:/                   { inactive=mb($3+0) }
        /^Pages speculative:/                { spec=mb($3+0) }
        /^Pages wired down:/                 { wired=mb($4+0) }
        /^Pages occupied by compressor:/     { comp=mb($5+0) }
        /^Pageins:/                          { pi=$2+0 }
        /^Pageouts:/                         { po=$2+0 }
        END { printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d", free, active, inactive, spec, wired, comp, pi, po }
      ')
      swap=$(sysctl -n vm.swapusage | awk '{
        for(i=1;i<=NF;i++) {
          if($i=="used") { u=$(i+2); gsub(/[^0-9.]/,"",u) }
          if($i=="total") { t=$(i+2); gsub(/[^0-9.]/,"",t) }
        }
        printf "%.0f\t%.0f", u, t
      }')
      printf '%s\t%d\t%s\t%s\n' "$(date +%H:%M:%S)" "$((SECONDS - sampler_start))" "$stats" "$swap" >> "$out"
      sleep "$MEMSTATS_INTERVAL"
    done
  ) &
  echo $!
}

# --- Phase 5: cold-build cleanup (SCons has no separate configure phase). ---
# SCons stores its incremental state in .sconsign.dblite; wipe it (and bin/) for cold-build parity.
clean_phase() {
  log "=== Phase 5: cold-build cleanup ==="
  if (( CLEAN == 1 )); then
    log "Wiping $GODOT_DIR/bin and $GODOT_DIR/.sconsign.dblite for cold-build comparability"
    rm -rf "$GODOT_DIR/bin"
    rm -f "$GODOT_DIR/.sconsign.dblite"
  else
    log "Skipping cleanup per --no-clean"
  fi
}

# --- Phase 6: timed compile. Sampler + per-line [HH:MM:SS] prefix loop. ---
# vulkan=no skips the Vulkan SDK dependency (see SPEC.md §5 design decision 2).
# production=yes enables LTO/strip/optimisation flags — equivalent intent to Caligula's ReleaseLto.
build_phase() {
  log "=== Phase 6: compile (target=$SCONS_TARGET, num_jobs=$JOBS, vulkan=no, production=yes) ==="

  ulimit -s 65520 2>/dev/null || warn "could not raise stack limit; continuing with default"
  log "Stack limit: $(ulimit -s) KB"

  local memstats_log="${LOG_DIR}/memstats-${TS}.log"
  local sampler_pid; sampler_pid=$(start_memstats_sampler "$memstats_log")
  trap "kill $sampler_pid 2>/dev/null || true; wait $sampler_pid 2>/dev/null || true" EXIT INT TERM
  log "Memstats sampler PID $sampler_pid → $memstats_log (interval=${MEMSTATS_INTERVAL}s)"

  local compile_start=$SECONDS
  ( cd "$GODOT_DIR" && caffeinate -i scons \
      platform=macos \
      arch=arm64 \
      target="$SCONS_TARGET" \
      production=yes \
      vulkan=no \
      num_jobs="$JOBS" 2>&1 ) \
    | while IFS= read -r line; do
        printf '[%s] %s\n' "$(date +%H:%M:%S)" "$line"
      done
  local compile_elapsed=$(( SECONDS - compile_start ))

  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true

  local h=$(( compile_elapsed / 3600 )) m=$(( (compile_elapsed % 3600) / 60 )) s=$(( compile_elapsed % 60 ))
  log "Compile time: ${h}h ${m}m ${s}s (${compile_elapsed}s total)"
}

# --- Main flow ---
verify

if (( ${#MISSING[@]} > 0 )); then
  if (( RESCUE == 1 )); then rescue
  else die "missing prerequisites: ${MISSING[*]} (re-run without --no-rescue, or install manually)"
  fi
fi

resolve_jobs

if (( CHECK_ONLY == 1 )); then
  log "Check-only mode: prerequisites satisfied. Exiting."
  exit 0
fi

fetch_source
pin_revision
clean_phase
build_phase
