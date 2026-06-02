#!/usr/bin/env bash
# Profile an OGRE3D build: time the compile + sidecar memory/page sampling.
# Pins to a release-tag SHA so reruns weeks later build the same source.
# Memstats sampler is identical to the caligula and chromium harnesses — see SPEC.md.
set -euo pipefail

# --- Defaults and flags ---
# Source tree location (~1 GB after clone, ~5-10 GB after full build).
OGRE_DIR="${OGRE_DIR:-$HOME/ogre}"
# v14.5.2 release tag SHA. Latest stable as of 2026-06-02. See SPEC.md §3 for re-pin guidance.
OGRE_REV="03ba0d900bc144f1f432abd0eff35dcb1675d9ef"
OGRE_TAG="v14.5.2"
# Heaviest end-to-end executable: pulls OgreMain + render systems + components + sample assets.
BUILD_TARGET="${BUILD_TARGET:-SampleBrowser}"
JOBS="${JOBS:-}"
MEMSTATS_INTERVAL="${MEMSTATS_INTERVAL:-1}"
CLEAN=1
CHECK_ONLY=0
RESCUE=1
MISSING=()
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
TS="$(date +%Y%m%d-%H%M%S)"

# --- Logging helpers (identical to caligula script) ---
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
confirm() { read -r -p "$1 [y/N] " r; [[ "${r:-}" =~ ^[Yy]$ ]]; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [--target NAME] [--jobs N] [--no-clean] [--check]
                       [--no-rescue] [--ogre-dir PATH] [-h|--help]

  --target NAME       cmake build target. Default: SampleBrowser (heaviest end-to-end).
                      Alternatives: OgreMain, Codec_Assimp. Env: BUILD_TARGET.
  --jobs N            Parallelism for cmake --build. Default: nproc --ignore 2 emulation.
                      Env: JOBS.
  --no-clean          Skip wipe of \$OGRE_DIR/build. Default cold-build wipes for comparability.
  --check             Run prerequisite checks only; skip fetch/configure/build.
  --no-rescue         Do not attempt to brew install missing prerequisites.
  --ogre-dir PATH     OGRE source tree. Default: \$HOME/ogre. Env: OGRE_DIR.
  -h, --help          Show this help.

Outputs (paired by timestamp):
  logs/build-<ts>.log     — full transcript, ends with 'Compile time: Hh Mm Ss'
  logs/memstats-<ts>.log  — per-second TSV of memory/paging state during compile

Pinned to OGRECave/ogre $OGRE_TAG (SHA $OGRE_REV).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)    BUILD_TARGET="$2"; shift 2 ;;
    --jobs)      JOBS="$2"; shift 2 ;;
    --no-clean)  CLEAN=0; shift ;;
    --check)     CHECK_ONLY=1; shift ;;
    --no-rescue) RESCUE=0; shift ;;
    --ogre-dir)  OGRE_DIR="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

[[ "$(uname)" == "Darwin" ]] || die "this script only runs on macOS (found: $(uname))"

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/build-${TS}.log"
exec > >(tee -a "$LOG_FILE") 2>&1
log "Logging to $LOG_FILE"
log "OGRE dir: $OGRE_DIR"
log "Pinned to $OGRE_TAG ($OGRE_REV)"
log "Target: $BUILD_TARGET"

# --- Verification helpers ---
need() { MISSING+=("$1"); warn "missing: $1"; }
check_bin() { if command -v "$1" >/dev/null 2>&1; then log "$1: OK ($(command -v "$1"))"; else need "$1"; fi; }

# Xcode CLT supplies Apple frameworks (Cocoa, Metal) that OGRE's macOS targets need at link time.
check_xcode_clt() {
  if xcode-select -p >/dev/null 2>&1; then log "Xcode CLT: OK ($(xcode-select -p))"; else need "xcode-clt"; fi
}

# Disk-space check — clone is small but build artifacts add up. 10 GB headroom covers both.
check_disk_space() {
  local parent; parent="$(dirname "$OGRE_DIR")"; mkdir -p "$parent"
  local free_gb; free_gb=$(( $(df -k "$parent" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
  if (( free_gb < 10 )); then warn "only ${free_gb} GB free on $parent; OGRE3D needs ~10 GB"; else log "Disk space: ${free_gb} GB free on $parent"; fi
}

verify() {
  log "=== Phase 1: verifying prerequisites ==="
  check_xcode_clt
  check_bin cmake
  check_bin ninja
  check_bin git
  check_bin brew
  check_disk_space
}

# --- Rescue: brew install anything check_bin flagged ---
rescue() {
  log "=== Phase 2: rescuing missing prerequisites ==="
  for item in "${MISSING[@]}"; do
    case "$item" in
      cmake|ninja|git)
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

# --- Resolve JOBS: explicit > emulated nproc --ignore 2 > sysctl ncpu - 2 (matches caligula) ---
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

# --- Phase 3: fetch source. Idempotent — skips clone if .git already exists. ---
fetch_source() {
  log "=== Phase 3: fetch OGRE source into $OGRE_DIR ==="
  mkdir -p "$(dirname "$OGRE_DIR")"
  if [[ -d "$OGRE_DIR/.git" ]]; then
    log "$OGRE_DIR/.git already present, skipping clone"
  else
    caffeinate -i git clone https://github.com/OGRECave/ogre.git "$OGRE_DIR"
  fi
}

# --- Phase 4: pin to the immutable release-tag SHA. ---
# Same pattern as chromium's pin_revision: shallow fetch the SHA, force-detach checkout.
pin_revision() {
  log "=== Phase 4: pinning to $OGRE_TAG ($OGRE_REV) ==="
  git -C "$OGRE_DIR" fetch --depth=1 origin "$OGRE_REV"
  git -C "$OGRE_DIR" checkout --force --detach "$OGRE_REV"
}

# --- Background memstats sampler (identical to caligula and chromium scripts). ---
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

# --- Phase 5: configure. Outside the timer. ---
# Heavy build per design choice (see SPEC.md §5): LTO + samples + all components + GL+Metal.
# Vulkan disabled to avoid Vulkan SDK dependency.
configure_phase() {
  log "=== Phase 5: cmake configure ==="
  local build_dir="$OGRE_DIR/build"
  if (( CLEAN == 1 )); then
    log "Cleaning $build_dir for cold-build comparability"
    rm -rf "$build_dir"
  fi
  if [[ -f "$build_dir/build.ninja" ]]; then
    log "build.ninja already present, skipping configure"
    return
  fi
  log "Running cmake configure (heavy build: LTO + samples + all components, no Vulkan; Xcode generator)"
  # Generator: Xcode, not Ninja. OGRE 1.x's macOS CMake unconditionally emits POST_BUILD rules
  # containing $(CONFIGURATION) — an Xcode-generator placeholder. Under Ninja, $( is a parse
  # error and the build fails before compilation starts. OGRE_BUILD_LIBS_AS_FRAMEWORKS=OFF
  # does NOT gate these rules (verified empirically — see SPEC §5.2a). Xcode generator is
  # OGRE's documented macOS path. Tradeoff: analyse.sh's link-share regex doesn't match
  # xcodebuild output, so link-share is omitted for OGRE3D too (same situation as Godot).
  #
  # LTO: -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON is ignored by the Xcode generator. Use
  # -DCMAKE_XCODE_ATTRIBUTE_LLVM_LTO=YES_THIN, which sets the equivalent Xcode build setting.
  #
  # CMAKE_BUILD_TYPE: ignored by multi-config Xcode generator. Selection happens at build time
  # via `cmake --build … --config Release` in build_phase().
  #
  # Why no -DOGRE_BUILD_COMPONENT_PHYSICS=ON: not a valid flag in OGRE 1.x; cmake silently
  # ignores it with a warning. Actual components are Bites/Mesh Lod/Overlay/Paging/Property/
  # RTShader/Terrain/Volume (all on by default in OGRE 1.x).
  cmake -S "$OGRE_DIR" -B "$build_dir" -G Xcode \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    -DCMAKE_XCODE_ATTRIBUTE_LLVM_LTO=YES_THIN \
    -DOGRE_BUILD_RENDERSYSTEM_GL=ON \
    -DOGRE_BUILD_RENDERSYSTEM_METAL=ON \
    -DOGRE_BUILD_RENDERSYSTEM_VULKAN=OFF \
    -DOGRE_BUILD_COMPONENT_TERRAIN=ON \
    -DOGRE_BUILD_SAMPLES=ON
}

# --- Phase 6: timed compile. Sampler + per-line [HH:MM:SS] prefix loop. ---
build_phase() {
  log "=== Phase 6: compile (target=$BUILD_TARGET, jobs=$JOBS, config=Release) ==="
  local build_dir="$OGRE_DIR/build"
  [[ -f "$build_dir/CMakeCache.txt" ]] || die "no CMakeCache.txt at $build_dir; configure failed?"

  ulimit -s 65520 2>/dev/null || warn "could not raise stack limit; continuing with default"
  log "Stack limit: $(ulimit -s) KB"

  local memstats_log="${LOG_DIR}/memstats-${TS}.log"
  local sampler_pid; sampler_pid=$(start_memstats_sampler "$memstats_log")
  # Each command needs its own `|| true` under set -e — see caligula script for why.
  trap "kill $sampler_pid 2>/dev/null || true; wait $sampler_pid 2>/dev/null || true" EXIT INT TERM
  log "Memstats sampler PID $sampler_pid → $memstats_log (interval=${MEMSTATS_INTERVAL}s)"

  local compile_start=$SECONDS
  # --config Release selects the build configuration on the multi-config Xcode generator.
  # cmake --build's --parallel N translates to xcodebuild -jobs N for the Xcode generator.
  caffeinate -i cmake --build "$build_dir" --config Release --parallel "$JOBS" --target "$BUILD_TARGET" 2>&1 \
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
configure_phase
build_phase
