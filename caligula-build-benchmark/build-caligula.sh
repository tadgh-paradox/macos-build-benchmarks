#!/usr/bin/env bash
# Profile a Caligula (Victoria 3) build: time the compile + sidecar memory/page sampling.
# Clones Caligula + cw from internal GitLab (VPN required), pins both to hardcoded SHAs,
# then invokes cmake --build directly. Memstats sampler identical to the other harnesses.
set -euo pipefail

# --- Defaults and flags ---
CALIGULA_DIR="${CALIGULA_DIR:-$HOME/projects/Caligula}"
# CW_DIR defaults to a sibling of CALIGULA_DIR named "cw"; can override via env or --cw-dir.
CW_DIR="${CW_DIR:-}"
# Pinned commits. Update these constants when re-pinning to a new Caligula commit.
# pin_revision() force-checks-out these SHAs — local working-tree edits will be discarded.
CALIGULA_REV="898f07d3bb140d9554b91da5f7a04d494523b4bd"
CW_REV="b9905ff34a25adcba34cdf9d2a5f452b7056d06d"
# Internal GitLab SSH URLs. SSH access (via key in your ~/.ssh) to gitlab.build.paradox-interactive.com
# is required; the script doesn't authenticate, it just runs `git clone` and lets git/ssh handle it.
CALIGULA_REPO="git@gitlab.build.paradox-interactive.com:gsg/caligula/caligula.git"
CW_REPO="git@gitlab.build.paradox-interactive.com:gsg/tech/cw.git"
# Preset must end in -Debug/-DebugOpt/-Release/-ReleaseOpt/-ReleaseLto; build.sh derives target from this suffix.
# Default is the buildserver-* variant, which exists in canonical CMakePresets.json and is what CI uses.
# The developer-only `osx-clang-ReleaseLto` was previous default but only exists in a per-user
# CMakeUserPresets.json — fresh clones (test machines, CI runners) don't have it.
PRESET="${PRESET:-buildserver-osx-clang-ReleaseLto}"
# Parallelism for cmake --build. Empty = emulate Caligula's build.sh default: nproc --ignore 2.
JOBS="${JOBS:-}"
# Memstats sampling interval in seconds; 1s is fine-grained enough for per-second pageout rate analysis.
MEMSTATS_INTERVAL="${MEMSTATS_INTERVAL:-1}"
# Cold-build by default (wipe build/<preset>/ for run-over-run comparability).
CLEAN=1
CHECK_ONLY=0
RESCUE=1
MISSING=()
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
# Single timestamp for both log/memstats artifacts so pairing is trivial (chromium script gives them separate ts).
TS="$(date +%Y%m%d-%H%M%S)"

# --- Logging helpers ---
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
confirm() { read -r -p "$1 [y/N] " r; [[ "${r:-}" =~ ^[Yy]$ ]]; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [--preset NAME] [--jobs N] [--no-clean] [--check]
                       [--no-rescue] [--caligula-dir PATH] [--cw-dir PATH] [-h|--help]

  --preset NAME       CMake preset; suffix must be Debug/DebugOpt/Release/ReleaseOpt/ReleaseLto.
                      Default: osx-clang-ReleaseLto. Env: PRESET.
  --jobs N            Parallelism for cmake --build. Default: nproc --ignore 2 emulation.
                      Env: JOBS.
  --no-clean          Skip wipe of build/<preset>/. Default cold-build wipes for comparability.
  --check             Run prerequisite checks only; skip configure and build.
  --no-rescue         Do not attempt to brew install missing prerequisites.
  --caligula-dir PATH Caligula source tree (created if absent). Default: \$HOME/projects/Caligula.
                      Env: CALIGULA_DIR.
  --cw-dir PATH       Clausewitz engine sibling (created if absent). Default: \$CALIGULA_DIR/../cw.
                      Env: CW_DIR.
  -h, --help          Show this help.

Pinned commits (force-checked-out — local working-tree edits will be DISCARDED):
  Caligula: $CALIGULA_REV
  cw:       $CW_REV

Outputs (paired by timestamp):
  logs/build-<ts>.log     — full transcript, ends with 'Compile time: Hh Mm Ss'
  logs/memstats-<ts>.log  — per-second TSV of memory/paging state during compile
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset)       PRESET="$2"; shift 2 ;;
    --jobs)         JOBS="$2"; shift 2 ;;
    --no-clean)     CLEAN=0; shift ;;
    --check)        CHECK_ONLY=1; shift ;;
    --no-rescue)    RESCUE=0; shift ;;
    --caligula-dir) CALIGULA_DIR="$2"; shift 2 ;;
    --cw-dir)       CW_DIR="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

[[ "$(uname)" == "Darwin" ]] || die "this script only runs on macOS (found: $(uname))"

# Default CW_DIR is sibling of CALIGULA_DIR
[[ -n "$CW_DIR" ]] || CW_DIR="$(dirname "$CALIGULA_DIR")/cw"

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/build-${TS}.log"
exec > >(tee -a "$LOG_FILE") 2>&1
log "Logging to $LOG_FILE"
log "Caligula dir: $CALIGULA_DIR"
log "Clausewitz dir: $CW_DIR"
log "Preset: $PRESET"

# --- Verification helpers ---
need() { MISSING+=("$1"); warn "missing: $1"; }
check_bin() { if command -v "$1" >/dev/null 2>&1; then log "$1: OK ($(command -v "$1"))"; else need "$1"; fi; }

# Preset suffix gates which cmake target we build (replicates build.sh logic).
check_preset() {
  local build_type="${PRESET##*-}"
  case "$build_type" in
    Debug|DebugOpt|Release|ReleaseOpt|ReleaseLto) log "Preset build-type: $build_type" ;;
    *) die "preset '$PRESET' has unsupported build-type suffix '$build_type'; must end in Debug/DebugOpt/Release/ReleaseOpt/ReleaseLto" ;;
  esac
}

# Caligula's configure.sh uses `readlink -m` (GNU coreutils extension). macOS's BSD readlink has
# no -m flag; silent failure leaves CW_DIR empty and conan tries to install from /clausewitz/...
# If brew coreutils is installed, its gnubin/ provides GNU readlink/realpath/sha1sum without the
# g-prefix — prepending it to PATH makes configure.sh's existing shebang-zsh invocation work.
prepend_coreutils_gnubin() {
  local gnubin=""
  for candidate in /opt/homebrew/opt/coreutils/libexec/gnubin /usr/local/opt/coreutils/libexec/gnubin; do
    if [[ -d "$candidate" ]]; then gnubin="$candidate"; break; fi
  done
  if [[ -z "$gnubin" ]] && command -v brew >/dev/null 2>&1; then
    local prefix; prefix="$(brew --prefix coreutils 2>/dev/null)" || true
    if [[ -n "$prefix" && -d "$prefix/libexec/gnubin" ]]; then gnubin="$prefix/libexec/gnubin"; fi
  fi
  if [[ -n "$gnubin" ]]; then
    export PATH="$gnubin:$PATH"
    log "Prepended coreutils gnubin to PATH: $gnubin"
  fi
}

# Verifies readlink -m works (which it does after prepend_coreutils_gnubin if coreutils is installed).
check_gnu_readlink() {
  if readlink -m /tmp >/dev/null 2>&1; then log "readlink -m: OK ($(command -v readlink))"
  else need "coreutils (readlink -m unavailable; Caligula's configure.sh requires GNU coreutils)"
  fi
}

verify() {
  log "=== Phase 1: verifying prerequisites ==="
  check_bin cmake
  check_bin ninja
  check_bin conan
  check_bin python3
  check_bin git
  check_bin brew
  check_gnu_readlink
  # sha1sum used by configure.sh's compdb logic; provided by coreutils on macOS.
  if command -v sha1sum >/dev/null 2>&1; then log "sha1sum: OK ($(command -v sha1sum))"; else need "coreutils"; fi
  check_preset
}

# --- Rescue: brew install anything check_bin flagged. Prompts before each install. ---
rescue() {
  log "=== Phase 2: rescuing missing prerequisites ==="
  for item in "${MISSING[@]}"; do
    case "$item" in
      cmake|ninja|python3|git|conan|coreutils)
        confirm "brew install $item?" || die "cannot proceed without $item"
        brew install "$item"
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

# --- Phase 3: clone Caligula + cw from internal GitLab if not already present. ---
# Requires SSH access to gitlab.build.paradox-interactive.com (VPN). Idempotent:
# skips the clone if .git already exists at the target path.
fetch_source() {
  log "=== Phase 3: fetch source from internal GitLab ==="
  mkdir -p "$(dirname "$CALIGULA_DIR")"
  if [[ -d "$CALIGULA_DIR/.git" ]]; then
    log "$CALIGULA_DIR/.git already present, skipping Caligula clone"
  else
    log "Cloning $CALIGULA_REPO → $CALIGULA_DIR"
    caffeinate -i git clone "$CALIGULA_REPO" "$CALIGULA_DIR"
  fi
  mkdir -p "$(dirname "$CW_DIR")"
  if [[ -d "$CW_DIR/.git" ]]; then
    log "$CW_DIR/.git already present, skipping cw clone"
  else
    log "Cloning $CW_REPO → $CW_DIR"
    caffeinate -i git clone "$CW_REPO" "$CW_DIR"
  fi
}

# --- Phase 4: pin both trees to the hardcoded SHAs. ---
# Force-checkout: any local working-tree edits in $CALIGULA_DIR or $CW_DIR will be DISCARDED.
# This is correct for benchmark reproducibility but destructive for a dev workflow — if you have
# in-progress edits in either tree, stash them before running this harness.
pin_revision() {
  log "=== Phase 4: pinning Caligula to $CALIGULA_REV ==="
  warn "force-checkout: any local working-tree edits in $CALIGULA_DIR will be discarded"
  git -C "$CALIGULA_DIR" fetch --depth=1 origin "$CALIGULA_REV"
  git -C "$CALIGULA_DIR" checkout --force --detach "$CALIGULA_REV"
  log "=== Phase 4: pinning cw to $CW_REV ==="
  warn "force-checkout: any local working-tree edits in $CW_DIR will be discarded"
  git -C "$CW_DIR" fetch --depth=1 origin "$CW_REV"
  git -C "$CW_DIR" checkout --force --detach "$CW_REV"
}

# --- Map preset suffix to the cmake target name (mirrors Caligula's build.sh case statement) ---
derive_target() {
  local build_type="${PRESET##*-}"
  case "$build_type" in
    Release)    BUILD_TARGET="victoria3_R" ;;
    ReleaseOpt) BUILD_TARGET="victoria3_R_opt" ;;
    ReleaseLto) BUILD_TARGET="victoria3" ;;
    Debug)      BUILD_TARGET="victoria3_D" ;;
    DebugOpt)   BUILD_TARGET="victoria3_D_opt" ;;
  esac
  log "Build target: $BUILD_TARGET"
}

# --- Resolve JOBS: explicit > emulated nproc --ignore 2 > sysctl ncpu - 2 ---
# Caligula's build.sh uses `nproc --ignore 2` (GNU coreutils). On macOS without coreutils,
# we fall through to sysctl. Matching this default keeps the benchmark concurrency-comparable
# to what Caligula CI uses on similar-cored runners.
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
  log "JOBS auto: $JOBS (matches Caligula build.sh: nproc --ignore 2)"
}

# --- Background sampler: emit one TSV row per $MEMSTATS_INTERVAL seconds. Identical to chromium script. ---
# Subshell closes inherited stdout/stderr so the outer $() capture can EOF cleanly.
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

# --- Configure (outside the timer; conan install + cmake generate live here) ---
# Cold-build by default wipes build/<preset>/ so neither stale build_cache nor incremental ninja
# state can shorten a run-over-run comparison. Mirrors chromium SPEC §8 decision #13.
#
# Why we don't just call ./configure.sh: macOS canonicalization APIs disagree on case-insensitive
# APFS volumes. bash's `pwd -P` and `stat -f %R` return one case; GNU realpath, python's realpath,
# and cmake's internal canonicalization return the other. configure.sh uses `pwd -P` + `readlink -m`,
# so its -DPDX_BUILD_CACHE_DIRECTORY arg leaks the bash-canonical case into the PCH machinery while
# cmake records everything else in its own canonical case — clang's -Werror -Wnonportable-include-path
# then rejects the mismatched #include. Inlining configure.sh's two commands with GNU-realpath'd
# paths keeps every path on cmake's side of the disagreement.
configure_phase() {
  log "=== Phase 5: configure (preset=$PRESET) ==="
  local caligula_canonical cw_canonical build_dir
  caligula_canonical="$(realpath "$CALIGULA_DIR")"
  cw_canonical="$(realpath "$CW_DIR")"
  build_dir="$caligula_canonical/build/$PRESET"

  if (( CLEAN == 1 )); then
    log "Cleaning $build_dir for cold-build comparability"
    rm -rf "$build_dir"
  fi
  if [[ -f "$build_dir/build.ninja" ]]; then
    log "build.ninja already present, skipping configure"
    return
  fi

  log "Canonical Caligula path:  $caligula_canonical"
  log "Canonical Clausewitz path: $cw_canonical"

  # Step 1 of configure.sh: install Clausewitz's conan profile.
  log "conan config install $cw_canonical/clausewitz/conan/config/"
  conan config install "$cw_canonical/clausewitz/conan/config/" -t dir

  # Step 2 of configure.sh: cmake configure. Identical flags except:
  #   - all paths are GNU-canonical (see comment above);
  #   - PDX_ENABLE_AUDIT_DEPRECATED=ON disables clausewitz's project-wide -Werror (see
  #     cw/clausewitz/build3/include/warnings.cmake). Needed because macOS APFS case-insensitive
  #     canonicalization APIs disagree on case in a way that triggers -Wnonportable-include-path
  #     on PCH headers; the warning itself is fine, but -Werror promotes it to fatal. Compile
  #     time is unchanged — warnings cost no cycles.
  log "cmake configure (preset=$PRESET, -G Ninja, -DPDX_ENABLE_AUDIT_DEPRECATED=ON)"
  cmake -S "$caligula_canonical" -B "$build_dir" \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=On \
        -DPDX_BUILD_CACHE_DIRECTORY="$build_dir/build_cache" \
        -DADDITIONAL_BASE_DIR="$cw_canonical" \
        -DPDX_ENABLE_AUDIT_DEPRECATED=ON \
        --preset "$PRESET" -G Ninja
}

# --- Timed compile phase ---
# Pipes cmake --build output through a per-line shell read that prepends [HH:MM:SS].
# The chromium script doesn't do this; ninja's [N/M] is a step counter, not a clock.
# Without timestamps on each line, link-share analysis can't correlate the LTO link
# start with memstats samples. Per-line `date` adds ~ms; over a 35-min build, negligible.
build_phase() {
  log "=== Phase 6: compile (target=$BUILD_TARGET, jobs=$JOBS) ==="
  local build_dir="$CALIGULA_DIR/build/$PRESET"
  [[ -f "$build_dir/build.ninja" ]] || die "no build.ninja at $build_dir; configure failed?"

  # Defensive stack raise — same as chromium script, harmless on Caligula but matches our reference rig.
  ulimit -s 65520 2>/dev/null || warn "could not raise stack limit; continuing with default"
  log "Stack limit: $(ulimit -s) KB"

  local memstats_log="${LOG_DIR}/memstats-${TS}.log"
  local sampler_pid; sampler_pid=$(start_memstats_sampler "$memstats_log")
  # Each command needs its own `|| true` under set -e — without it, kill/wait on an already-dead
  # sampler (we manually kill it before the Compile time log) aborts the trap with non-zero,
  # which makes the script exit 1 even after a successful build. The chromium script has the
  # same pattern but always crashes before the trap fires, so the bug never surfaces there.
  trap "kill $sampler_pid 2>/dev/null || true; wait $sampler_pid 2>/dev/null || true" EXIT INT TERM
  log "Memstats sampler PID $sampler_pid → $memstats_log (interval=${MEMSTATS_INTERVAL}s)"

  local compile_start=$SECONDS
  # pipefail (set above) catches a cmake failure even though the read loop returns 0.
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
prepend_coreutils_gnubin
verify

if (( ${#MISSING[@]} > 0 )); then
  if (( RESCUE == 1 )); then rescue
  else die "missing prerequisites: ${MISSING[*]} (re-run without --no-rescue, or install manually)"
  fi
fi

derive_target
resolve_jobs

if (( CHECK_ONLY == 1 )); then
  log "Check-only mode: prerequisites satisfied. Exiting."
  exit 0
fi

fetch_source
pin_revision
configure_phase
build_phase
