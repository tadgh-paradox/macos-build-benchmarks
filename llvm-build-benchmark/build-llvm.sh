#!/usr/bin/env bash
# Profile an LLVM build: time the compile + sidecar memory/page sampling.
# Pins to a release-tag SHA so reruns weeks later build the same source.
# Memstats sampler identical to caligula / ogre3d / godot harnesses — see SPEC.md.
set -euo pipefail

# --- Defaults and flags ---
# Source tree location. LLVM's full history is ~10 GB; we use a shallow init+fetch (Phase 3) to avoid it.
LLVM_DIR="${LLVM_DIR:-$HOME/llvm-project}"
# llvmorg-22.1.7 release tag SHA. Latest stable as of 2026-06-02. See SPEC.md §4 for re-pin guidance.
LLVM_REV="7979ad438a4904e5ff57dc85e962992242f81688"
LLVM_TAG="llvmorg-22.1.7"
# Default config matches the canonical published benchmark (SPEC §9): clang;lld;mlir + target=all.
# Measured at 2049s wall / 16.9 GB peak on a 14-core/24 GB Apple Silicon Mac at JOBS=12 — Caligula-class.
# Override for quick smoke tests: --projects 'clang;lld' --target clang lands in ~6 min.
LLVM_PROJECTS="${LLVM_PROJECTS:-clang;lld;mlir}"
BUILD_TARGET="${BUILD_TARGET:-all}"
JOBS="${JOBS:-}"
# Concurrent LTO link cap. Default 4 on this branch (`64`) — tuned for ≥64 GB hosts.
# `main` runs uncapped (matches production CI). Other tiers: `24` (=1, safe baseline), `32` (=2).
# See SPEC §7.3.
LINK_JOBS="${LINK_JOBS:-4}"
MEMSTATS_INTERVAL="${MEMSTATS_INTERVAL:-1}"
CLEAN=1
CHECK_ONLY=0
RESCUE=1
MISSING=()
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
TS="$(date +%Y%m%d-%H%M%S)"

# --- Logging helpers (identical across all benchmark harnesses) ---
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
confirm() { read -r -p "$1 [y/N] " r; [[ "${r:-}" =~ ^[Yy]$ ]]; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [--target NAME] [--projects LIST] [--jobs N] [--no-clean]
                       [--check] [--no-rescue] [--llvm-dir PATH] [-h|--help]

  --target NAME       cmake build target. Default: all (full canonical benchmark — ~34 min).
                      For a quick smoke test (~6 min): --target clang --projects 'clang;lld'.
                      Env: BUILD_TARGET.
  --projects LIST     Semicolon-separated LLVM subprojects. Default: 'clang;lld;mlir'.
                      MLIR adds the tablegen-heavy compile graph that makes the build Caligula-class.
                      For lighter: 'clang;lld'. To scale up: append 'libcxx;libcxxabi;compiler-rt'.
                      Env: LLVM_PROJECTS.
  --jobs N            Parallelism for cmake --build. Default on this branch (\`64\`):
                      nproc --ignore 2 emulation. Env: JOBS.
  --link-jobs N       Concurrent LTO link cap (-DLLVM_PARALLEL_LINK_JOBS). Default on this
                      branch (\`64\`): 4 — tuned for ≥64 GB hosts. \`main\` runs uncapped
                      (matches production CI). Other tiers: \`24\` (=1, safe baseline),
                      \`32\` (=2). See SPEC §7.3. Env: LINK_JOBS.
  --no-clean          Skip wipe of \$LLVM_DIR/build. Default cold-build wipes for comparability.
  --check             Run prerequisite checks only; skip fetch/configure/build.
  --no-rescue         Do not attempt to brew install missing prerequisites.
  --llvm-dir PATH     LLVM source tree. Default: \$HOME/llvm-project. Env: LLVM_DIR.
  -h, --help          Show this help.

Outputs (paired by timestamp):
  logs/build-<ts>.log     — full transcript, ends with 'Compile time: Hh Mm Ss'
  logs/memstats-<ts>.log  — per-second TSV of memory/paging state during compile

Pinned to llvm/llvm-project $LLVM_TAG (SHA $LLVM_REV).
Projects: $LLVM_PROJECTS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)    BUILD_TARGET="$2"; shift 2 ;;
    --projects)  LLVM_PROJECTS="$2"; shift 2 ;;
    --jobs)      JOBS="$2"; shift 2 ;;
    --link-jobs) LINK_JOBS="$2"; shift 2 ;;
    --no-clean)  CLEAN=0; shift ;;
    --check)     CHECK_ONLY=1; shift ;;
    --no-rescue) RESCUE=0; shift ;;
    --llvm-dir)  LLVM_DIR="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

[[ "$(uname)" == "Darwin" ]] || die "this script only runs on macOS (found: $(uname))"

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/build-${TS}.log"
exec > >(tee -a "$LOG_FILE") 2>&1
log "Logging to $LOG_FILE"
log "LLVM dir: $LLVM_DIR"
log "Pinned to $LLVM_TAG ($LLVM_REV)"
log "Projects: $LLVM_PROJECTS"
log "Target: $BUILD_TARGET"
log "Link jobs: $LINK_JOBS"

# --- Verification helpers ---
need() { MISSING+=("$1"); warn "missing: $1"; }
check_bin() { if command -v "$1" >/dev/null 2>&1; then log "$1: OK ($(command -v "$1"))"; else need "$1"; fi; }

check_xcode_clt() {
  if xcode-select -p >/dev/null 2>&1; then log "Xcode CLT: OK ($(xcode-select -p))"; else need "xcode-clt"; fi
}

# Disk-space check — LLVM source (shallow) ~1 GB + build at thin-LTO Release ~10-20 GB. 30 GB headroom.
check_disk_space() {
  local parent; parent="$(dirname "$LLVM_DIR")"; mkdir -p "$parent"
  local free_gb; free_gb=$(( $(df -k "$parent" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
  if (( free_gb < 30 )); then warn "only ${free_gb} GB free on $parent; LLVM needs ~30 GB"; else log "Disk space: ${free_gb} GB free on $parent"; fi
}

verify() {
  log "=== Phase 1: verifying prerequisites ==="
  check_xcode_clt
  check_bin cmake
  check_bin ninja
  check_bin python3   # LLVM build invokes python for tablegen, lit, etc.
  check_bin git
  check_bin brew
  check_disk_space
}

# --- Rescue: brew install anything check_bin flagged ---
rescue() {
  log "=== Phase 2: rescuing missing prerequisites ==="
  for item in "${MISSING[@]}"; do
    case "$item" in
      cmake|ninja|python3|git)
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

# --- Resolve JOBS: explicit > emulated nproc --ignore 2 > sysctl ncpu - 2 ---
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

# --- Phase 3: shallow init+fetch. ---
# LLVM's full history is ~10 GB; a normal `git clone` would download all of it. We instead
# init an empty repo, add the remote, and fetch only the pinned SHA at depth=1. github.com
# supports arbitrary-SHA shallow fetches via uploadpack.allowReachableSHA1InWant=true.
fetch_source() {
  log "=== Phase 3: shallow fetch LLVM source into $LLVM_DIR (SHA-targeted, depth=1) ==="
  mkdir -p "$(dirname "$LLVM_DIR")"
  if [[ -d "$LLVM_DIR/.git" ]]; then
    log "$LLVM_DIR/.git already present, skipping init"
  else
    git init "$LLVM_DIR" >/dev/null
    git -C "$LLVM_DIR" remote add origin https://github.com/llvm/llvm-project.git
  fi
  caffeinate -i git -C "$LLVM_DIR" fetch --depth=1 origin "$LLVM_REV"
}

# --- Phase 4: pin to the immutable release-tag SHA. ---
pin_revision() {
  log "=== Phase 4: pinning to $LLVM_TAG ($LLVM_REV) ==="
  git -C "$LLVM_DIR" checkout --force --detach "$LLVM_REV"
}

# --- Background memstats sampler (identical across all benchmark harnesses) ---
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

# --- Phase 5: cmake configure. Outside the timer. ---
# LLVM's CMakeLists.txt lives at $LLVM_DIR/llvm (not the repo root — it's a monorepo).
# LLVM_ENABLE_LTO=Thin enables thin-LTO across the build, matching Caligula's shape.
# LLVM_INCLUDE_{TESTS,BENCHMARKS,EXAMPLES}=OFF skips ancillary code we don't need to benchmark.
# LLVM_TARGETS_TO_BUILD=AArch64 restricts codegen targets to Apple Silicon's arch; building
# all 25+ LLVM backends adds compile time but isn't a fair test (we don't ship x86 codegen).
# LLVM_PARALLEL_LINK_JOBS caps concurrent LTO links (each eats 3-5 GB). Default 1 is the parity
# baseline (safe for <32 GB). Bump via --link-jobs N for max-capacity runs on bigger hosts;
# the `32` and `64` git branches set tier-appropriate defaults. See SPEC.md §7.3.
configure_phase() {
  log "=== Phase 5: cmake configure ==="
  local build_dir="$LLVM_DIR/build"
  if (( CLEAN == 1 )); then
    log "Cleaning $build_dir for cold-build comparability"
    rm -rf "$build_dir"
  fi
  if [[ -f "$build_dir/build.ninja" ]]; then
    log "build.ninja already present, skipping configure"
    return
  fi
  log "Running cmake configure (projects=$LLVM_PROJECTS, LTO=Thin, ninja)"
  cmake -S "$LLVM_DIR/llvm" -B "$build_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    -DLLVM_ENABLE_PROJECTS="$LLVM_PROJECTS" \
    -DLLVM_ENABLE_LTO=Thin \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_TARGETS_TO_BUILD=AArch64 \
    -DLLVM_PARALLEL_COMPILE_JOBS="$JOBS" \
    -DLLVM_PARALLEL_LINK_JOBS="$LINK_JOBS"
}

# --- Phase 6: timed compile. Sampler + per-line [HH:MM:SS] prefix loop. ---
build_phase() {
  log "=== Phase 6: compile (target=$BUILD_TARGET, jobs=$JOBS) ==="
  local build_dir="$LLVM_DIR/build"
  [[ -f "$build_dir/build.ninja" ]] || die "no build.ninja at $build_dir; configure failed?"

  ulimit -s 65520 2>/dev/null || warn "could not raise stack limit; continuing with default"
  log "Stack limit: $(ulimit -s) KB"

  local memstats_log="${LOG_DIR}/memstats-${TS}.log"
  local sampler_pid; sampler_pid=$(start_memstats_sampler "$memstats_log")
  trap "kill $sampler_pid 2>/dev/null || true; wait $sampler_pid 2>/dev/null || true" EXIT INT TERM
  log "Memstats sampler PID $sampler_pid → $memstats_log (interval=${MEMSTATS_INTERVAL}s)"

  local compile_start=$SECONDS
  caffeinate -i cmake --build "$build_dir" --parallel "$JOBS" --target "$BUILD_TARGET" 2>&1 \
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
