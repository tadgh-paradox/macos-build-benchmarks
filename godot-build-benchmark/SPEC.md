# `build-godot.sh` — Specification

## 1. Intent

Produce a reproducible Godot Engine build profile on macOS for cross-machine benchmarking. The script clones godotengine/godot pinned to a release-tag SHA, compiles the editor binary in production configuration, and emits two artifacts: a build log ending with `Compile time: Hh Mm Ss` and a per-second TSV of memory/page state during the compile. Together these let us compare different macOS hosting solutions on a game-engine-shaped workload that we can publish — without needing access to proprietary Paradox source.

Godot is the second candidate stand-in for Caligula (the proprietary Victoria 3 source we can't publish). The other is OGRE3D; see `~/projects/ogre3d-build-benchmark/SPEC.md`. Godot is intentionally larger (~1.5M LOC vs. OGRE's ~600k) to bracket the design space.

## 2. Executive summary

- **What it does**: clones [godotengine/godot](https://github.com/godotengine/godot) pinned to `4.6.3-stable`, builds the editor binary using SCons in production configuration with `vulkan=no`, times the compile, samples memory state every second.
- **Reference target**: Caligula's measured profile is 1593s wall-time and 19.5 GB peak RAM at JOBS=12 on a 14-core / 24 GB Apple Silicon Mac. Godot is expected to be somewhere between 15-40 min and 8-14 GB at production settings — closer to Caligula on time but likely lighter on RAM.
- **Run it**: `./build-godot.sh` from this directory. First run pulls ~2 GB of source, then builds for an estimated 20-40 min.
- **Outputs**: `logs/build-<ts>.log` (transcript) and `logs/memstats-<ts>.log` (TSV). Paired by timestamp, same format as the other two harnesses.
- **Analyse it**: `./analyse.sh logs/memstats-<ts>.log logs/build-<ts>.log` extracts peak RAM, swap usage, pageout rate, total pageouts. **Link-share is deliberately omitted** for Godot — SCons output doesn't match the cmake/ninja-shaped regex in `analyse.sh`, and Caligula's link-share was 0.1% anyway (not load-bearing for ranking).

## 3. Technical onboarding

Skip ahead to §4 if you've built a SCons-based project before and know what page faults are.

### 3.1 What is Godot?

Godot is an open-source game engine, used in production by many indie studios. ~1.5M LOC, C++ with embedded scripting languages (GDScript, C#), a node-based scene system, and renderers for Vulkan, OpenGL, and via translation layers, Metal. For our purposes it's a stand-in for "what a real game-engine codebase looks like" — comparable shape to Caligula, but with publishable source. Larger than OGRE3D.

The 4.x line is the current major release. We pin `4.6.3-stable` (the latest stable point release at script-writing time).

### 3.2 What's SCons, and why isn't this CMake?

Godot uses **SCons** as its build system, not CMake. SCons is a Python-based build orchestrator — its `SConstruct` and `SCsub` files are Python scripts that describe how to compile and link. There is no upstream CMake support for Godot. (Some community forks have explored it; none are stable or canonical.)

This is the main reason `build-godot.sh` differs structurally from `build-ogre3d.sh` and `build-caligula.sh`: SCons does configure-and-build in one step, so there's no separate `configure_phase`. The cold-build cleanup wipes SCons's incremental state (`.sconsign.dblite`) plus the `bin/` output directory.

For comparison:

| | OGRE3D / Caligula | Godot |
|---|---|---|
| Build system | CMake + Ninja | SCons |
| Configure step | Separate (`cmake -S ... -B ...`) | Inline with build |
| Parallelism flag | `--parallel N` | `num_jobs=N` |
| Progress output | `[N/M] Building ...` | `[NN%]` percentage + per-file lines |
| Incremental state | `build/` + `build_cache/` | `.sconsign.dblite` |

### 3.3 What's a "harness"?

A wrapper script that runs the real build for you and records measurements alongside. Three things happen each run:

1. **Prerequisites are checked and (with consent) installed**. The script doesn't assume your machine is already set up.
2. **Source is fetched and pinned** to an exact commit SHA. Re-running tomorrow builds the same source as today.
3. **The compile is timed and instrumented**. A background process samples `vm_stat` and `sysctl vm.swapusage` every second while SCons builds. The compile timer wraps only the build step.

### 3.4 The SCons flags, explained

The full invocation is:
```
scons platform=macos arch=arm64 target=editor production=yes vulkan=no num_jobs=12
```

| Flag | What it does |
|---|---|
| `platform=macos` | Build for macOS (vs. linux/windows/android/etc.) |
| `arch=arm64` | Build native Apple Silicon binaries (no universal). Hardcoded — see §5 decision 4 for caveat |
| `target=editor` | Build the full Godot editor binary, not export templates |
| `production=yes` | Enable optimisations equivalent to a release build (LTO, strip, etc.) |
| `vulkan=no` | Disable Vulkan rendering backend — avoids the Vulkan SDK install dependency |
| `num_jobs=12` | Parallelism. Matches Caligula's `nproc --ignore 2` default on a 14-core machine |

### 3.5 What the memstats sidecar measures

Identical to the other harnesses. A background loop writes one TSV row per second with `vm_stat` + `sysctl vm.swapusage` data. Column schema and analysis recipes are in `~/projects/chromium-build-benchmark-for-mac/SPEC.md` §6/§9. `analyse.sh` extracts the headline numbers from this TSV.

## 4. Source pin

| Godot tag | SHA | Date |
|---|---|---|
| `4.6.3-stable` | `7d41c59c457bd5a245092b4e7eb2d833e3b3f8c3` | 2026-05-20 |

**Why this revision.** Latest stable point release of the 4.x line as of script-writing (2026-06-02). Release tags are immutable on `godotengine/godot` and represent revisions the upstream maintainers verified end-to-end. We don't pin to `master`, which would drift between runs.

**Re-pinning.** When Godot ships a new stable, look up its SHA with `git ls-remote --tags https://github.com/godotengine/godot.git <new-tag>`, replace both constants near the top of `build-godot.sh` (`GODOT_REV` and `GODOT_TAG`), and rerun.

## 5. Design decisions

These were the substantive choices made when designing this harness. Recorded here so a later reviewer (or yourself, six months from now) understands the trail.

1. **`target=editor`, not `template_release`.** The editor binary is the heaviest single target — it bundles every subsystem (renderer, physics, scripting, asset import, GUI). Templates are stripped-down runtimes used to ship games; building one wouldn't exercise the full code-gen surface. **Tradeoff**: a developer optimising their game pipeline cares about template build times; we care about engine build times. Different use cases.

2. **`vulkan=no`.** Godot 4.x's Vulkan renderer is the default; enabling it requires the Vulkan SDK (~150 MB download via `misc/scripts/install_vulkan_sdk_macos.sh` — a network mutation plus system installer). We disable it to keep the harness's prerequisite surface as small as possible. **Tradeoff**: missing a chunk of Vulkan-specific code-gen work, so the measured profile is slightly lighter than a "full-featured" Godot build. Acceptable, since Godot is already expected to land closer to Caligula's profile than OGRE3D regardless of Vulkan inclusion.

3. **Link-share metric not extracted.** SCons emits `Linking Program <path> ...`, while my `analyse.sh` regex looks for cmake/ninja's `Linking CXX executable <path>`. A SCons-aware regex would be a few lines, but Caligula's measured link-share was 0.1% (2s of 1593s) — the metric is **not load-bearing for cross-machine ranking**. Generalising the parser for marginal value isn't worth the complexity. Godot's `analyse.sh` short-circuits the link-share section with an explanatory message. **Alternative considered**: extract link-share by counting all "Linking" output lines from SCons. Rejected — Caligula's number tells us the metric isn't useful.

4. **`arch=arm64` hardcoded.** Apple Silicon is assumed throughout this harness. The script warns if the host is x86_64 but proceeds. To benchmark on Intel Macs, edit the hardcoded `arch=arm64` to `arch=x86_64` in `build-godot.sh`. **Alternative considered**: `arch=$(uname -m)`. Rejected for now because the chromium and caligula harnesses also assume arm64 and a host-arch-aware abstraction across all three is more work than it's worth at this scale.

5. **Cold-build default (`--clean`).** Each run wipes `$GODOT_DIR/bin` and `$GODOT_DIR/.sconsign.dblite` so SCons's incremental state can't shorten a run-over-run comparison. Mirrors caligula and ogre3d behavior. Override with `--no-clean` for development iteration.

6. **Pin via release-tag SHA, not the tag name directly.** Tags are theoretically movable; SHAs are not. The pin in `build-godot.sh` is the SHA. The `GODOT_TAG` variable is documentation only.

7. **No shared library across the three harnesses.** Each of `build-caligula.sh`, `build-ogre3d.sh`, `build-godot.sh` is self-contained. The memstats sampler is ~40 lines duplicated verbatim. Worth abstracting? Per repo conventions (CLAUDE.md): "Don't add features, refactor, or introduce abstractions beyond what the task requires." Three copies of one function is below the abstraction threshold.

## 6. Output contract

Two files per run, paired by a single timestamp variable:

- `logs/build-<ts>.log` — every line prefixed with `[HH:MM:SS]`. Ends with `[HH:MM:SS] Compile time: Hh Mm Ss (NNNs total)` on success.
- `logs/memstats-<ts>.log` — TSV header + N rows. Column schema identical to caligula and chromium scripts.

The `[HH:MM:SS]` prefix on the build log is what *would* enable `analyse.sh`'s link-share extraction (the prefix supplies the wall-clock; SCons's percentage counter doesn't). For Godot it's still applied — it's useful for correlating any memstats spike with what SCons was doing at that moment — but the link-share section in `analyse.sh` short-circuits regardless.

## 7. Methodology caveats

### 7.1 Godot is too light by 8.6× vs Caligula — measured, confirmed (2026-06-02)

The research-stage estimate (15-40 min, 8-14 GB) was off by an order of magnitude on wall-time and by 5-10× on RAM. **Measured wall time at the heavy configuration: 186 seconds (3m 6s).** Peak RAM grew about 1 GB above the machine's pre-existing baseline. This is better than OGRE3D's 25s but still 8.6× short of Caligula's 1593s. RAM pressure barely registers above baseline.

**Why the research was wrong**: same root cause as OGRE3D's miscalibration. The agent estimated based on LOC and historical build times from CI infrastructure (Intel runners, slower CPUs). On M-class Apple Silicon, even 1.5M LOC of game-engine C++ compiles in single-digit minutes. The CI numbers don't transfer.

**Verdict**: Godot is closer to Caligula than OGRE3D but still not a faithful proxy. For absolute-time prediction it's unusable (you'd predict 3 min when reality is 26). For *cross-machine ranking*, it's marginal — the 3-minute wall-time is long enough that a faster machine will visibly complete it faster, so ranking probably correlates. But the RAM-pressure regime Caligula stresses (peak swap, sustained pageouts) is barely exercised by Godot. A machine with terrible disk-IO would not rank lower on Godot the way it would on Caligula.

**The fundamental finding**: there does not appear to be a popular open-source game engine that matches Caligula's compile-time and RAM-pressure profile on M-class Apple Silicon. The next options are: (a) accept Godot as a lighter proxy and document the limitation; (b) pivot to a non-game-engine build that's actually Caligula-sized (LLVM, V8 standalone); (c) build a synthetic from captured Caligula profile data.

### 7.2 Apple Silicon assumption

The `arch=arm64` flag is hardcoded. Cross-machine comparison across Intel and Apple Silicon hosts will produce incomparable numbers regardless — different ISA, different perf characteristics. Match arches when comparing.

### 7.3 Cross-machine comparison preconditions

A `Compile time:` measurement on machine A is meaningfully comparable to machine B only if:

1. Both runs used the same `JOBS` value.
2. Both runs were on the same arch (both arm64 or both x86_64).
3. Both `memstats` sidecars show neither run was paging catastrophically — see chromium SPEC §9 for the full treatment.
4. Both runs used the same Godot pin and the same `build-godot.sh` revision.

### 7.4 Vulkan SDK availability is not the gating dependency

The decision to set `vulkan=no` is not because the Vulkan SDK is hard to install — it's because we deliberately want the harness's prerequisite surface to be small. If a future user wants Vulkan-enabled measurements, the change is: `vulkan=yes` in `build-godot.sh` and run `misc/scripts/install_vulkan_sdk_macos.sh` from the Godot source tree manually before the build.

### 7.5 `production=yes` enables LTO

This is mentioned because the chromium SPEC §9 documents in detail how LTO link-time can become a bottleneck. SCons + LLD on macOS handles LTO via thin-LTO by default, which is fast (Caligula's measured 0.1% link share). Don't expect a long sequential link phase. If Godot's measured numbers show one anyway, that's an interesting datum worth flagging.

## 8. Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Phase 1 reports missing `scons` | Fresh machine | Allow rescue (omit `--no-rescue`) → `brew install scons` |
| Phase 1 reports missing `python3` | Fresh machine | Allow rescue → `brew install python3` |
| `xcode-select --install` opens a GUI then exits | Expected — installer blocks until clicked through | Run the installer, re-invoke |
| `git clone` slow or hangs | Slow link to github.com | Patience; `caffeinate` already wraps the clone |
| SCons fails with "VulkanSDK not found" | Vulkan inadvertently enabled | Confirm `vulkan=no` is passed; this script hardcodes it |
| SCons fails citing missing SDK symbol | Xcode CLT too old for Godot 4.6.3 | Update Xcode |
| `clang frontend command failed with exit code 139` | VM-tier throughput failure (chromium SPEC §9) | Lower `JOBS`. Not expected at 12 jobs / 24 GB for Godot, but possible on smaller-RAM machines |
| Build runs to completion but `bin/godot.macos.editor.arm64` missing | Wrong target name or arch mismatch | Verify with `ls $GODOT_DIR/bin/` after a run; SCons names binaries `godot.<platform>.<target>.<arch>` |

## 9. Comparison summary (measured 2026-06-02)

| Metric | Caligula reference | Godot measured | OGRE3D measured | Verdict |
|---|---|---|---|---|
| Wall time | 1593s (26m 33s) | **186s (3m 6s)** | 25s | Godot 8.6× too short; OGRE 64× too short |
| Peak RAM (raw) | 19.5 GB | 14.9 GB | 14.6 GB | Godot ~1 GB above baseline; OGRE ~0.7 GB |
| Peak pageout rate | 380 pages/sec | 177 pages/sec | 34 pages/sec | Godot exercises pageouts non-trivially; OGRE barely |
| Total pages paged | ~7800 (121 MB) | 388 (6 MB) | 74 (1.2 MB) | Godot 20× lower; OGRE 100× lower |
| LTO link share | 0.1% | *(not extracted)* | *(not extracted)* | Caligula's was already negligible |

**Judgment**: Godot is the better of the two candidates, but neither is Caligula-class. For *cross-machine ranking* Godot is usable with the limitation that it doesn't stress the same RAM/disk-IO bottleneck Caligula does — it'd rank machines on compile-CPU-throughput primarily. For *absolute-time prediction* it's not usable (predicts 3 min when Caligula is 26 min on the same hardware).

**Recommendations** for the next decision point:

1. **Accept Godot as a lighter proxy** and document the limitation. Useful for "is this rented Mac broken or working?" and "which Mac is faster at C++ compile work?" but not "how would Caligula behave on this Mac?".
2. **Try a non-game-engine Caligula-sized build** — LLVM (~5M LOC), V8 standalone, Boost-with-tests. Loses game-engine-shape similarity but lands much closer in wall-time and RAM pressure.
3. **Build a synthetic Caligula-shape benchmark** — generate N templated C++ TUs matching the Caligula reference profile's per-TU compile-time distribution. Most engineering effort but most faithful match. See Caligula SPEC §11.

## 10. Repo layout

```
godot-build-benchmark/
├── build-godot.sh    # The script
├── analyse.sh        # Metrics extractor; link-share section short-circuited (see §5 decision 3)
├── SPEC.md           # This document
└── logs/             # Created on first run
    ├── build-YYYYMMDD-HHMMSS.log
    └── memstats-YYYYMMDD-HHMMSS.log
```

Godot source tree lives outside the project at `$HOME/godot` (default; override with `--godot-dir`). Not committed.
