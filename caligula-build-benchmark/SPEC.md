# `build-caligula.sh` — Specification

## 1. Intent

Produce a reproducible Caligula (Victoria 3) build profile on macOS for cross-machine benchmarking. The script wraps the user's existing Caligula source tree, runs `cmake` + `ninja` directly (bypassing `./configure.sh` for reasons documented in §5), times only the compile phase, and emits two artifacts: a build log ending with `Compile time: Hh Mm Ss` and a per-second TSV of memory/page state during the compile.

**This harness's role is special.** Caligula is the proprietary game we actually want to benchmark, but its source is internal — we can't ship it to a rented cloud Mac. So this harness exists to produce the **ground-truth reference profile** that the publishable OGRE3D and Godot harnesses are tuned against. Whichever of those two lands closest to Caligula's measured profile (peak RAM + total wall-time + paging regime) becomes the publishable proxy for cross-provider benchmarking.

See `~/projects/ogre3d-build-benchmark/SPEC.md` and `~/projects/godot-build-benchmark/SPEC.md` for the candidate stand-ins.

## 2. Executive summary

- **What it does**: invokes `cmake configure` + `cmake --build` on a local Caligula source tree at the `osx-clang-ReleaseLto` preset (default), times the compile phase, samples memory state every second.
- **Reference profile** (measured 2026-06-01 on a 14-core / 24 GB Apple Silicon Mac at JOBS=12):

  | Metric | Value |
  |---|---|
  | Wall time | **1593s (26m 33s)** |
  | Peak RAM (active+wired+compressed) | **19.5 GB / 24 GB** |
  | Peak swap usage | 7.1 GB |
  | Peak pageout rate | 380 pages/sec |
  | Mean pageout rate | 5.1 pages/sec |
  | Intervals with any pageouts | 38.1% |
  | Total pages paged out | ~7800 (121 MB) |
  | LTO link share | **0.1% (2s of 1593s)** |

- **Run it**: `./build-caligula.sh` from this directory. Source tree must already be cloned at `$CALIGULA_DIR` (default `$HOME/projects/Caligula`), with the `cw` (Clausewitz engine) sibling at `$HOME/projects/cw`. No fetch phase — this is a local tree the user owns.
- **Outputs**: `logs/build-<ts>.log` (transcript) and `logs/memstats-<ts>.log` (TSV). Paired by timestamp.
- **Analyse it**: `./analyse.sh logs/memstats-<ts>.log logs/build-<ts>.log` extracts the metrics in the table above.

## 3. Technical onboarding

Skip ahead to §4 if you've built C++ projects with CMake before, know what page faults are, and don't care about the project background.

### 3.1 What is Caligula?

**Caligula is the internal codename for Victoria 3**, Paradox's grand-strategy game (2022 release). The C++ source tree at `$HOME/projects/Caligula` contains the game-specific code (`source/`); the engine code lives in the sibling tree `$HOME/projects/cw` ("Clausewitz" engine). The build produces `bin/binaries/Victoria 3.app` or similar.

**Why "Caligula" and not "Victoria 3"** — internal Paradox naming convention. The CI configs, build scripts, and source paths all use the codename.

### 3.2 The existing build flow (what we wrap)

Caligula already has its own build orchestration: `configure.sh` and `build.sh` at the repo root. Engineers run those interactively. The flow is:

1. **`./configure.sh <preset>`** — runs `conan config install` (installs Conan's per-team config from `cw/clausewitz/conan/config/`), then `cmake -S … -B … --preset <preset> -G Ninja`. This downloads ~150 Conan packages on first run, then generates `build.ninja`.
2. **`./build.sh <preset>`** — runs `cmake --build build/<preset> --parallel $(nproc --ignore 2) --target <derived-from-preset>`.

**Our harness bypasses both.** See §5 design decisions for why.

### 3.3 What's a "preset"?

CMake 3.19+ supports **presets** — named configurations stored in `CMakePresets.json` that bundle generator + cache variables + toolchain. Caligula defines presets like `osx-clang-ReleaseLto`, `osx-clang-DebugOpt`, `buildserver-osx-clang-ReleaseLto`. The suffix after the last dash is the build-type (`Debug` / `DebugOpt` / `Release` / `ReleaseOpt` / `ReleaseLto`), which determines which cmake target gets built:

| Preset suffix | cmake target | Meaning |
|---|---|---|
| `Debug` | `victoria3_D` | Unoptimised, full debug symbols |
| `DebugOpt` | `victoria3_D_opt` | `-O1` with debug symbols (common dev setting) |
| `Release` | `victoria3_R` | `-O2/3` no debug |
| `ReleaseOpt` | `victoria3_R_opt` | Optimised Release variant |
| `ReleaseLto` | `victoria3` | Release + Link-Time Optimization (CI target) |

This harness defaults to `osx-clang-ReleaseLto` — the same preset CI uses for the macOS shipping binary.

### 3.4 What's a "harness"?

A wrapper script that runs the real build and records measurements alongside. Three things happen each run:

1. **Prerequisites are checked**. cmake, ninja, conan, python3, git, brew, GNU coreutils, plus the Caligula and Clausewitz source trees.
2. **Configure-then-build happens with our paths**. We don't call Caligula's `configure.sh` — see §5 — but we replicate its two essential commands (conan + cmake configure) with paths we canonicalize ourselves.
3. **The compile is timed and instrumented**. A background process samples `vm_stat` and `sysctl vm.swapusage` every second while CMake/Ninja builds. The compile timer wraps only the build step (not configure, not conan install).

### 3.5 What the memstats sidecar measures

Identical schema to the chromium, ogre3d, and godot harnesses. One TSV row per second to `logs/memstats-<ts>.log`. Columns:

- `time`, `uptime_s` — wall-clock + seconds since sampler start.
- `free_mb`, `active_mb`, `inactive_mb`, `spec_mb`, `wired_mb` — RAM partitions from `vm_stat`.
- `compressed_mb` — macOS WKdm compressor pool occupancy.
- `pageins`, `pageouts` — cumulative since boot. Diff successive rows for per-second rate.
- `swap_used_mb`, `swap_total_mb` — disk swap state from `sysctl vm.swapusage`.

See `~/projects/chromium-build-benchmark-for-mac/SPEC.md` §6 and §9 for the canonical analysis recipes and the VM-tier failure-mode treatment.

### 3.6 LTO, briefly, with a twist

Link-Time Optimization (LTO) lets the linker re-optimise across the whole program by retaining compiler IR in each `.o`. The classic LTO downside is a long sequential link phase — Chromium's LTO link can take tens of minutes.

**Caligula's measured LTO link share is 0.1%** — 2 seconds out of 1593. This was surprising. Explanation: modern thin-LTO distributes the heavy work across the per-library link steps rather than concentrating it in the final exec link. The static library links (e.g. `libgame_databases.a` at 34s) absorb the LTO work. So "ReleaseLto" doesn't mean "long final link" the way it does in Chromium — it means LTO is happening, but it's amortised across the compile graph.

## 4. Source pin

**Caligula is not pinned by this script.** Unlike chromium/ogre3d/godot harnesses which clone upstream repos and pin to release tags, Caligula uses the user's local working tree at `$CALIGULA_DIR` (default `$HOME/projects/Caligula`). The user controls which Caligula revision is checked out — they `git checkout <branch>` or `git checkout <sha>` interactively before running this harness.

**Why no pin**: the user owns the source. They're not benchmarking a frozen revision — they're benchmarking *the build* on different hardware, possibly across multiple Caligula revisions over time. Pinning would constrain their workflow.

**For reproducible cross-machine comparison**, the user should record which Caligula commit was checked out at measurement time (`git -C $CALIGULA_DIR rev-parse HEAD`) and re-checkout the same SHA on the comparison machine.

## 5. Design decisions

Substantive choices, recorded so that a later reviewer (or yourself, six months from now) understands the trail. Some of these were corrections to broken first attempts — flagged where applicable.

### 5.1 Bypass `configure.sh`, replicate its two commands inline

Caligula's `configure.sh` derives paths via `pwd -P` and `readlink -m`. On case-insensitive APFS, these return one canonical case (lowercase `caligula`) while cmake's internal canonicalization returns the other (uppercase `Caligula`). The mixed case leaks into the cmake cache — one variable lowercase, all others uppercase — and then into the PCH (Pre-Compiled Header) machinery, which trips clang's `-Wnonportable-include-path` warning, which Caligula's `-Werror` promotes to fatal.

**The harness inlines `configure.sh`'s two essential commands** (conan config install + cmake configure) with paths canonicalized via GNU coreutils `realpath`, matching cmake's side of the disagreement. See `build-caligula.sh:152-191` (configure_phase) and the long comment at `:152-160`.

**Tradeoff**: we no longer auto-pick up future changes to `configure.sh`. If Paradox adds a new step there (e.g. an additional codegen pass), the harness misses it and the measured build is slightly different from the real workflow. Acceptable for benchmark purposes; flag for review if `configure.sh` grows substantially.

### 5.2 The case-insensitive APFS canonicalization saga

This is the most non-obvious gotcha in the harness. Worth documenting in full because it will bite again.

**The setup**: APFS on macOS is case-insensitive by default (and was for HFS+ before it). A directory created as `caligula` can be accessed as `Caligula`, `CALIGULA`, etc. — all resolve to the same inode.

**The problem**: different POSIX-ish canonicalization APIs disagree on what the "canonical" case of such a directory is:

| API | Returns on this user's machine |
|---|---|
| bash builtin `pwd -P` | `/Users/tadghwagstaff/projects/caligula` |
| `/bin/pwd -P` (external) | `/Users/tadghwagstaff/projects/caligula` |
| macOS BSD `stat -f %R` | `/Users/tadghwagstaff/projects/caligula` |
| python `os.path.realpath()` | `/Users/tadghwagstaff/projects/Caligula` |
| GNU coreutils `readlink -f` | `/Users/tadghwagstaff/projects/Caligula` |
| GNU coreutils `realpath` | `/Users/tadghwagstaff/projects/Caligula` |
| cmake's internal canonicalization | `Caligula` (uppercase) |

The "winner" depends on the kernel namecache state, which is volatile across shell sessions. The user's interactive zsh shell happens to land in a consistent state (all-uppercase) so Caligula builds fine there. A fresh bash subshell from Claude Code's harness lands in an inconsistent state, where some derived paths are lowercase and others uppercase. Then cmake's PCH machinery emits an `#include` directive with one case while clang's own file lookup returns the other, and `-Wnonportable-include-path -Werror` makes the mismatch fatal.

**The fix in `build-caligula.sh`**: invoke `realpath` (coreutils version, prepended to PATH via `prepend_coreutils_gnubin`) on `CALIGULA_DIR` and `CW_DIR` inside `configure_phase`, so cmake receives the "cmake-side" canonical case. All downstream paths agree. Plus disable `-Werror` via `-DPDX_ENABLE_AUDIT_DEPRECATED=ON` as belt-and-suspenders — if any case still slips through, we get a warning rather than a fatal error.

**A more principled fix** would be to rename the directory on disk to a single canonical case (e.g., `mv caligula _tmp; mv _tmp Caligula`) so the filesystem stores one case consistently. The user opted not to do this because it touches their working tree and might surprise other tools that have cached the existing case. Worth revisiting if this disagreement bites again elsewhere.

### 5.3 `-DPDX_ENABLE_AUDIT_DEPRECATED=ON` disables `-Werror`

Caligula's `cw/clausewitz/build3/include/warnings.cmake` gates `-Werror` on `NOT PDX_ENABLE_AUDIT_DEPRECATED`. Setting the flag to `ON` keeps warnings as warnings rather than fatal errors. Used as defence-in-depth against §5.2's case-canonicalization disagreement leaking through.

**Tradeoff**: a real engineering build would want `-Werror` on so that warnings don't accumulate. For benchmark purposes we just want the build to complete — warning-count is irrelevant to compile time.

### 5.4 Prepend coreutils gnubin to PATH

Caligula's `configure.sh` uses `readlink -m`, which is a GNU coreutils extension; macOS BSD `readlink` doesn't have `-m`. The user has coreutils installed via Homebrew, but the gnubin (`/opt/homebrew/opt/coreutils/libexec/gnubin/`) isn't on PATH in our bash subshell — the user's interactive zsh shell adds it via `.zshrc`, but that doesn't propagate.

`prepend_coreutils_gnubin()` at `build-caligula.sh:111-124` finds gnubin in the standard locations (Apple Silicon and Intel paths) and prepends it. After this, `readlink -m`, `realpath`, `sha1sum`, etc. all resolve to GNU versions. We keep the helper even though we no longer call `configure.sh` directly, because (a) our inlined `cmake configure` uses `realpath` from coreutils, and (b) the verify step's `check_gnu_readlink` is a useful diagnostic.

### 5.5 Cold-build default (`--clean`)

Each run wipes `$CALIGULA_DIR/build/<preset>` so neither stale `build_cache/` nor incremental ninja state can shorten a run-over-run comparison. Mirrors chromium SPEC §8 decision #13. The cost is a sub-5-second extra `cmake gen` plus whatever conan needs to do to re-instantiate the build dir. Override with `--no-clean` for development iteration.

### 5.6 Compile timer covers `cmake --build` only

The timer wraps `cmake --build` only — not `cmake configure`, not `conan config install`. Configure includes network operations (conan downloading packages on first run) that we don't want contaminating the time. Matches chromium SPEC §8 decision #12.

**Consequence**: the user's interactive "Caligula builds in 35 min" includes conan + configure; our measurement is "26 min" because we time only the compile. The 9-minute delta is configure overhead.

### 5.7 EXIT trap with `|| true` on each command

The chromium script's EXIT trap is `trap "kill $sampler_pid 2>/dev/null; wait $sampler_pid 2>/dev/null; true" EXIT INT TERM`. Under `set -e`, if `kill` fails (sampler already killed manually before the trap fires), the trap aborts with non-zero exit, and the script exits 1 — even after a successful build.

Chromium has the bug too but never hits it because Chromium always crashes before reaching the trap (see chromium SPEC §9). Caligula's first successful build did reach the trap and exited 1 despite logging `Compile time: 0h 26m 33s`. The fix in `build-caligula.sh:218-222` adds `|| true` to each command in the trap.

### 5.8 Per-line `[HH:MM:SS]` timestamping of build output

Caligula's build runs as `cmake --build … | while IFS= read -r line; do printf '[%s] %s\n' "$(date +%H:%M:%S)" "$line"; done`. Every ninja step output gets a wall-clock prefix.

**Why**: ninja's `[N/M]` is a step counter, not a clock. Without `[HH:MM:SS]` prefixes, you can't correlate a memstats spike at 13:23:38 with what ninja was doing at that moment, and `analyse.sh`'s link-share extraction can't compute durations. The chromium script doesn't do this, which is why its link-share section gracefully skips on chromium logs.

**Cost**: per-line `date` invocation — sub-millisecond, negligible over a 26-minute build.

### 5.9 No source pin

See §4. The user owns the source tree; pinning is their responsibility.

### 5.10 Single timestamp variable shared between log files

The chromium script generates `build-<ts>.log` and `memstats-<ts>.log` with separate `date` calls; they can disagree if the build crosses a second boundary between the two. Caligula uses a single `TS="$(date +%Y%m%d-%H%M%S)"` at script start. Guarantees pairing. Trivial improvement.

## 6. Output contract

Two files per run, paired by a single `TS`:

- `logs/build-<ts>.log` — every line prefixed with `[HH:MM:SS]`. Ends with `[HH:MM:SS] Compile time: Hh Mm Ss (NNNs total)` on success.
- `logs/memstats-<ts>.log` — TSV header + N rows. Column schema in §3.5, identical to chromium / ogre3d / godot scripts.

## 7. Methodology caveats

### 7.1 The 26 min vs 35 min gap

The user's interactive build is ~35 min; this harness measures ~26 min. The 9-minute delta is `configure.sh` + `conan config install` + cmake generate, which run outside our timer. Don't confuse these numbers when comparing to interactive timings.

### 7.2 Reference profile preconditions

The reference profile in §2 was measured under specific conditions:

- 14-core / 24 GB Apple Silicon Mac (M-series)
- macOS 15.7.x
- JOBS=12 (auto-resolved from `nproc --ignore 2`)
- Caligula at the commit checked out on 2026-06-01 (record this per measurement)
- Conan packages already cached locally (first-ever run would take longer)
- Cold-build (`--clean`)

To compare another machine's profile against this baseline, match these conditions. Specifically: same arch, same JOBS, same Caligula commit, same preset. Mismatched arch (Intel vs Apple Silicon) renders the comparison meaningless.

### 7.3 Page-rate caveat

Caligula's measured peak pageout rate is 380 pages/sec — well above Chromium's 95 pages/sec at its JOBS=3 crash, yet Caligula survives. The threshold for "imminent SIGSEGV from disk-pager saturation" suggested in chromium SPEC §9 (~1000 pages/sec) is consistent with Caligula's survival — Caligula peaks burstily but doesn't sustain. If you see Caligula's pageout rate climb above ~800 pages/sec on a different machine, expect instability and lower JOBS.

### 7.4 LTO link share is 0.1% — don't over-index on it

Caligula's measured LTO link share is essentially zero. Thin-LTO distributes the work across per-library link steps; the final exec link is 2 seconds out of 1593. **Implication for machine ranking**: link throughput (single-thread CPU, disk IO) is NOT a meaningful differentiator for Caligula-class builds. Compile parallelism is. A machine optimised for fast LTO links but slow compile parallelism would rank poorly on this workload despite being "fast at linking" in isolation.

### 7.5 What this harness is NOT for

- Not for measuring whether a *given* Caligula commit compiles correctly (use the user's interactive `./build.sh` for that — it picks up `compdb` regeneration which we skip).
- Not for measuring conan-install performance — that's outside the timer.
- Not for shipping binaries — `-DPDX_ENABLE_AUDIT_DEPRECATED=ON` is set, so warnings aren't fatal. A real release build should run with `-Werror` on.

## 8. Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Phase 1 reports missing `cmake`/`ninja`/`conan` | Fresh machine | Allow rescue (omit `--no-rescue`) |
| Phase 1 reports `readlink -m: missing` | Coreutils not installed or not findable | `brew install coreutils` |
| Phase 1 reports `Caligula tree: missing` | `$CALIGULA_DIR` doesn't have a `CMakeLists.txt` | Pass `--caligula-dir <path>` or set `CALIGULA_DIR` env var |
| Phase 1 reports `Clausewitz tree: missing` | `$CW_DIR` doesn't have a `clausewitz/` subdir | Pass `--cw-dir <path>` or set `CW_DIR` env var |
| Configure fails: `conan config install … No such directory: '/clausewitz/conan/config/'` | `readlink -m` returned empty path | Coreutils gnubin missing from PATH — verify `prepend_coreutils_gnubin` ran (`Prepended coreutils gnubin to PATH` log line should appear) |
| Compile fails: `non-portable path to file '"…/caligula/…"'; specified path differs in case from file name on disk` | Case-canonicalization disagreement; the `-DPDX_ENABLE_AUDIT_DEPRECATED=ON` fallback didn't engage | See §5.2; verify the flag is being passed in `configure_phase` (check `build-<ts>.log` for `cmake configure (preset=..., -G Ninja, -DPDX_ENABLE_AUDIT_DEPRECATED=ON)`) |
| Build completes but script exits 1 | EXIT trap calls `kill`/`wait` on dead sampler under `set -e` | Already fixed in `build-caligula.sh:218-222`; if it recurs, verify each trap command has `\|\| true` |
| `clang frontend command failed with exit code 139` at JOBS=12 | VM-tier throughput failure (chromium SPEC §9) | Caligula reliably builds at JOBS=12 / 24 GB on this hardware; if you see this, you're likely on a smaller-RAM machine — lower JOBS |
| `Compile time:` line missing from log | Build phase didn't reach the end successfully | Check the log for `FAILED:` lines; common cause is conan package mismatch — try removing `~/.conan2/p/` and re-running |

## 9. Comparison summary (this is the BASELINE)

This harness's measurements ARE the comparison baseline. Both `ogre3d-build-benchmark/SPEC.md` §9 and `godot-build-benchmark/SPEC.md` §9 compare against these numbers:

| Metric | Caligula (this baseline) |
|---|---|
| Wall time | 26m 33s (1593s) |
| Peak RAM | 19.5 GB / 24 GB |
| Peak pageout rate | 380 pages/sec |
| Total pages paged | ~7800 (121 MB) |
| LTO link share | 0.1% |

When OGRE3D and Godot harnesses run, fill in their §9 tables with measured numbers and pick the better stand-in.

## 10. Repo layout

```
caligula-build-benchmark/
├── build-caligula.sh   # The script
├── analyse.sh          # Metrics extractor; default --link-target=victoria3
├── SPEC.md             # This document
└── logs/               # Created on first run
    ├── build-YYYYMMDD-HHMMSS.log
    └── memstats-YYYYMMDD-HHMMSS.log
```

Caligula source tree lives at `$CALIGULA_DIR` (default `$HOME/projects/Caligula`); Clausewitz engine at `$CW_DIR` (default `$HOME/projects/cw`). Neither is part of this repo. The user owns those trees and is responsible for checking out the Caligula revision under benchmark.

## 11. Relation to the other harnesses

| Harness | Source | Pin | Purpose |
|---|---|---|---|
| `caligula-build-benchmark/` | Local working tree (proprietary) | User-controlled (no script pin) | **Ground-truth reference profile** |
| `ogre3d-build-benchmark/` | `OGRECave/ogre` clone | v14.5.2 | Lighter publishable proxy candidate |
| `godot-build-benchmark/` | `godotengine/godot` clone | 4.6.3-stable | Heavier publishable proxy candidate |
| `chromium-build-benchmark-for-mac/` | `chromium/src` clone | Per-target SHAs | Earlier attempt; failed because Chromium's VM-tier pressure crashes at JOBS≥2 on 24 GB |

The chromium harness is archived — it crashes reliably at JOBS≥2 on the reference 24 GB machine, making cross-machine comparison infeasible. Its SPEC.md (`~/projects/chromium-build-benchmark-for-mac/SPEC.md`) remains the canonical document on macOS VM-tier failure modes (§9), which the other three SPECs reference rather than duplicate.
