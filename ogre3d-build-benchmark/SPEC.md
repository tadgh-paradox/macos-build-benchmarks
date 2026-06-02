# `build-ogre3d.sh` — Specification

## 1. Intent

Produce a reproducible OGRE3D build profile on macOS for cross-machine benchmarking. The script clones OGRE pinned to a release-tag SHA, compiles a heavy end-to-end configuration, and emits two artifacts: a build log ending with `Compile time: Hh Mm Ss` and a per-second TSV of memory/page state during the compile. Together these let us compare different macOS hosting solutions (bare-metal, rented cloud Macs, virtualised) on the same game-engine-shaped workload — without needing access to proprietary Paradox source.

OGRE3D is one of two candidate stand-ins for Caligula (the proprietary Victoria 3 source we can't publish). The other is Godot; see `~/projects/godot-build-benchmark/SPEC.md`.

## 2. Executive summary

- **What it does**: clones [OGRECave/ogre](https://github.com/OGRECave/ogre) pinned to `v14.5.2`, configures a heavy CMake+Ninja build (LTO + samples + all components + GL/Metal render systems), times the compile, samples memory state every second.
- **Reference target**: Caligula's measured profile is 1593s wall-time and 19.5 GB peak RAM at JOBS=12 on a 14-core / 24 GB Apple Silicon Mac. OGRE3D is expected to be lighter — research suggests 8-18 min and 4-8 GB at stock settings, which is why this harness deliberately builds the heaviest possible configuration to push toward Caligula-class numbers.
- **Run it**: `./build-ogre3d.sh` from this directory. Defaults pull ~1 GB of source on first run, then build for an estimated 15-25 min.
- **Outputs**: `logs/build-<ts>.log` (transcript) and `logs/memstats-<ts>.log` (TSV). Paired by timestamp.
- **Analyse it**: `./analyse.sh logs/memstats-<ts>.log logs/build-<ts>.log` extracts peak RAM, swap usage, pageout rate, and LTO link-share against the `SampleBrowser` target.

## 3. Technical onboarding

Skip ahead to §4 if you've built C++ projects with CMake before and know what page faults are.

### 3.1 What is OGRE3D?

OGRE3D ("Object-Oriented Graphics Rendering Engine") is a mature open-source C++ game engine first released in 2005. ~600k LOC, template-heavy, multiple render-system backends (OpenGL, Metal, D3D, Vulkan), and a plugin/component architecture. It's used in production by serious projects (Gazebo robotics simulator, Stunt Rally, several MMOs). For our purposes it's a stand-in for "what a real game-engine codebase looks like" — comparable shape to Caligula but with publishable source.

Two flavours exist upstream: the classic 1.x line (this harness) and `ogre-next` (2.x/3.x rewrite). We pin 1.x because it's more mature on macOS and its template-instantiation surface is closer to Caligula's.

### 3.2 What's a "harness"?

A wrapper script that runs the real build for you and records measurements alongside. Three things happen each run:

1. **Prerequisites are checked and (with consent) installed**. The script doesn't assume your machine is already set up.
2. **Source is fetched and pinned** to an exact commit SHA. Re-running the script tomorrow builds the same source as today, regardless of upstream changes.
3. **The compile is timed and instrumented**. A background process samples `vm_stat` and `sysctl vm.swapusage` every second while CMake builds. The compile timer wraps only the build step — not the source fetch or CMake configure phases — so the recorded wall-time is what we'd actually want to compare across machines.

### 3.3 What CMake and Xcode are doing

CMake doesn't compile your code. It reads `CMakeLists.txt` files and *generates* build files for another tool to consume. We tell CMake to generate **Xcode** project files (`-G Xcode`); `cmake --build … --config Release` then invokes `xcodebuild` against the generated `.xcodeproj`. xcodebuild parses the project, schedules compiles, and invokes clang.

**Why Xcode and not Ninja?** OGRE 1.x's macOS CMake unconditionally emits POST_BUILD rules containing `$(CONFIGURATION)` — an Xcode-generator placeholder. Under the Ninja generator that's a literal `$(`, which Ninja rejects as a parse error. See §5.2 for the full saga. caligula and chromium harnesses use Ninja; godot uses SCons; this OGRE3D harness uses Xcode. Three different generators across four harnesses — each is the right native choice for its project.

You'll see lines like `CompileC <object> <source> normal arm64 c++ com.apple.compilers.llvm.clang.1_0.compiler` during the build. That's xcodebuild's verbose-but-uniform output. There's no `[N/M]` step counter; xcodebuild prints `=== BUILD TARGET … ===` between targets.

**Parallelism caveat.** Our harness passes `--parallel 12` to `cmake --build`, which translates to `xcodebuild -jobs 12`. But Xcode also respects the user-default preference `IDEBuildOperationMaxNumberOfConcurrentCompileTasks`, which on a stock macOS install equals `nproc` (14 on this hardware). For dependent sub-builds (OGRE bundles its own freetype, zlib, etc. as separate xcodeproj-driven sub-projects), the sub-`xcodebuild` invocations may use the user-default rather than our `-jobs` value. The main OGRE build does honor `-jobs 12`. Net effect: short bursts of N=14 parallelism during dep sub-builds; sustained N=12 during the main compile. Acceptable for our benchmark — dependency sub-builds are a small fraction of total wall time — but flag for review if measured numbers look anomalous.

### 3.4 The CMake flags, explained

| Flag | What it does |
|---|---|
| `-S $HOME/ogre` | Source directory. Where `CMakeLists.txt` lives. |
| `-B $HOME/ogre/build` | Build directory. Where the generated `OGRE.xcodeproj` and `.o`s go. |
| `-G Xcode` | Use Xcode generator (multi-config; see §3.3 for why not Ninja). |
| `-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0` | Target macOS 11 or newer at link time. |
| `-DCMAKE_XCODE_ATTRIBUTE_LLVM_LTO=YES_THIN` | Enable thin-LTO via Xcode's build setting (Ninja-style `CMAKE_INTERPROCEDURAL_OPTIMIZATION` is ignored under the Xcode generator). See §3.6. |
| `-DOGRE_BUILD_RENDERSYSTEM_GL=ON` | Build OpenGL render-system backend. |
| `-DOGRE_BUILD_RENDERSYSTEM_METAL=ON` | Build Metal render-system backend (native to Apple Silicon). |
| `-DOGRE_BUILD_RENDERSYSTEM_VULKAN=OFF` | Skip Vulkan to avoid the Vulkan SDK install dependency. |
| `-DOGRE_BUILD_COMPONENT_TERRAIN=ON` | Include the terrain rendering component (~50 source files). |
| `-DOGRE_BUILD_SAMPLES=ON` | Build the sample applications (heavy — many TUs). |

Note: `CMAKE_BUILD_TYPE=Release` is **not** set at configure time. The Xcode generator is multi-config (Debug, Release, RelWithDebInfo, MinSizeRel all generated), and selection happens at build time via `cmake --build … --config Release`.

Each of these adds compile work, which is what we want — a lightweight default OGRE3D build is too small to be a Caligula stand-in.

### 3.5 What the memstats sidecar measures

A background loop writes one TSV row per second to `logs/memstats-<ts>.log` during the compile. Columns (see also chromium SPEC §6):

- `time`: wall-clock — matches the `[HH:MM:SS]` prefix in `build-<ts>.log`.
- `free_mb`, `active_mb`, `inactive_mb`, `spec_mb`, `wired_mb`: RAM partitions from `vm_stat`. "Active + wired + compressed" is the load-bearing "RAM in use" figure.
- `compressed_mb`: macOS WKdm compressor pool. Pages compressed in-RAM before being written to disk swap.
- `pageins`, `pageouts`: cumulative since boot. Diff successive rows to get per-second rate.
- `swap_used_mb`, `swap_total_mb`: actual disk swap state from `sysctl vm.swapusage`.

`analyse.sh` extracts the headline numbers from this TSV.

### 3.6 LTO (Link-Time Optimization), briefly

When you compile C++ without LTO, each `.cpp` file becomes a `.o` independently, and the linker just concatenates them. With LTO, each `.o` contains intermediate representation (LLVM IR), and the linker re-optimises across the full program. Result: better runtime performance, but **much** slower link step. Caligula's "ReleaseLto" preset enables it; we enable it here too so we're comparing like with like.

Heads-up: Caligula's measured LTO link share was only 0.1% (the actual final exec link took 2 seconds out of 26 minutes). This was surprising — see Caligula's analyse.sh output. So "LTO" in modern thin-LTO builds doesn't necessarily mean a long sequential link phase.

## 4. Source pin

| OGRE tag | SHA | Date |
|---|---|---|
| `v14.5.2` | `03ba0d900bc144f1f432abd0eff35dcb1675d9ef` | 2026-01-31 |

**Why this revision.** Latest stable release tag as of script-writing (2026-06-02). Release tags are immutable on `OGRECave/ogre` and represent revisions the upstream maintainers verified end-to-end against macOS. An arbitrary main-branch commit is a bet that nothing landed half-broken that day; a release tag is not.

**Re-pinning.** When OGRE ships a new stable release, look up its SHA with `git ls-remote --tags https://github.com/OGRECave/ogre.git <new-tag>`, replace both constants near the top of `build-ogre3d.sh` (`OGRE_REV` and `OGRE_TAG`), and rerun. Don't pin to `main`.

## 5. Design decisions

These were the substantive choices made when designing this harness. Recorded here so that a later reviewer (or yourself, six months from now) understands the trail.

1. **Heavy build over default.** Stock `cmake -S . -B build` against OGRE produces an ~8-18 min build at ~4-8 GB peak RAM. That's too small to be a Caligula stand-in (26 min, 19 GB). We enable LTO, all components, both render systems, and the samples binary to push the profile up. **Tradeoff**: builds take longer, but the goal is *cross-machine comparison*, not *fast iteration*, so this is correct. Alternative considered: build OGRE3D twice in parallel (or pre-tune with extra LTO targets). Rejected as too synthetic — we want a real build, just a heavy one.

2. **Vulkan disabled.** OGRE supports a Vulkan render-system backend, but enabling it requires the Vulkan SDK (~150 MB download + system installer via `install_vulkan_sdk_macos.sh`). Skipped to keep the harness setup as light as possible. Metal + GL together cover the macOS rendering surface adequately. **Tradeoff**: missing a small chunk of cross-API code-gen work. Acceptable.

   **2a. Switched from Ninja generator to Xcode generator after a failed Ninja attempt.** Initial design used `-G Ninja` for consistency with caligula. First build attempt crashed at the Ninja-parse step: `bad $-escape (literal $ must be written as $$)` at `build.ninja:2408`. Root cause: OGRE 1.x's macOS CMake unconditionally emits POST_BUILD rules containing `$(CONFIGURATION)` — an Xcode-generator placeholder. Ninja sees a literal `$(` and treats it as a malformed variable. Setting `OGRE_BUILD_LIBS_AS_FRAMEWORKS=OFF` did NOT gate these rules (verified empirically — the second attempt at line 2408 produced identical errors despite FRAMEWORKS being off). The output path was also mangled: `…/build/lib//Applications/Xcode.app/…/SDKs/MacOSX15.4.sdk/$(CONFIGURATION)/Ogre.framework/…`. **OGRE 1.x on macOS is `-G Xcode`-only**; the Ninja generator is not a supported path for OGRE on macOS at this revision. Switched to `-G Xcode` for the third attempt, which worked. **Tradeoff**: `analyse.sh`'s link-share regex doesn't match xcodebuild output (it matches ninja's "Linking CXX executable …"). Same situation as the Godot harness with SCons; link-share is intentionally omitted (Caligula's was 0.1%, not load-bearing).

   **2b. `OGRE_BUILD_COMPONENT_PHYSICS=ON` rejected: not a valid flag in OGRE 1.x.** Was suggested by the initial research agent. cmake silently warns and ignores it. The actual OGRE 1.x components are Bites / MeshLodGenerator / Overlay / Overlay-Imgui / Paging / Property / RTShader / RTShader-Shaders / Terrain / Volume — all on by default at this configuration; no explicit flag needed for most.

   **2c. LTO enable mechanism switched.** Under Ninja generator we'd have used `-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON`. The Xcode generator ignores that. The Xcode-native way is `-DCMAKE_XCODE_ATTRIBUTE_LLVM_LTO=YES_THIN`, which sets the `LLVM_LTO` Xcode build setting to enable thin-LTO. Functionally equivalent — both produce thin-LTO `.o`s and link-time optimisation.

3. **Pin via release-tag SHA, not the tag name directly.** Tags are theoretically movable; SHAs are not. The pin in `build-ogre3d.sh` is the SHA. The `OGRE_TAG` variable is documentation only — it tells you which release the SHA corresponds to.

4. **Cold-build default (`--clean`).** Each run wipes `$OGRE_DIR/build` so ninja's incremental state can't shorten a run-over-run comparison. Mirrors chromium SPEC §8 #13. The cost is a sub-5-second extra `cmake gen`; the benefit is comparable wall-times across runs. Override with `--no-clean` for development iteration.

5. **Target `SampleBrowser`, not `OgreMain`.** `OgreMain` is the core library — building only it would skip half the work. `SampleBrowser` is the heaviest executable; it depends on `OgreMain`, all render systems, all components, and the sample assets, so building it pulls everything in. **Tradeoff**: if sample-asset compilation dominates wall-time, we're measuring asset processing rather than C++ compilation. Untested at the time of writing; flag for review once we have a real measurement.

6. **No shared library across the three harnesses.** Each of `build-caligula.sh`, `build-ogre3d.sh`, `build-godot.sh` is self-contained. The memstats sampler is ~40 lines duplicated verbatim. Worth abstracting? Per repo conventions (CLAUDE.md): "Don't add features, refactor, or introduce abstractions beyond what the task requires." Three copies of one function is below the abstraction threshold.

## 6. Output contract

Two files per run, paired by a single timestamp variable:

- `logs/build-<ts>.log` — every line prefixed with `[HH:MM:SS]`. Ends with `[HH:MM:SS] Compile time: Hh Mm Ss (NNNs total)` on success.
- `logs/memstats-<ts>.log` — TSV header + N rows. Column schema documented in §3.5 and identical to caligula and chromium scripts.

The `[HH:MM:SS]` prefix on the build log is useful for correlating memstats spikes with what xcodebuild was doing at that moment. **LTO link-share is NOT extracted** for this harness — xcodebuild's link output (`Ld <output> normal`) doesn't match `analyse.sh`'s ninja-style regex, and Caligula's link-share was 0.1% (not load-bearing for ranking — see godot SPEC §5 design decision 3 for the same reasoning).

## 7. Methodology caveats

### 7.1 OGRE3D IS too light even with heavy-build flags — measured, confirmed (2026-06-02)

The research-stage estimate (8-18 min, 4-8 GB at stock) was an order of magnitude wrong. **Measured wall time at the heavy configuration: 25 seconds.** Source has 703 `.cpp` files; the build produced 632 `.o`s — we compiled ~90% of the engine. This is a 64× shortfall against Caligula's 1593s. Peak RAM grew about 0.7 GB above the machine's pre-existing baseline (most of the 14.6 GB measured peak was unrelated to OGRE — already in use by other processes).

**Verdict**: OGRE3D 1.x at this revision is NOT a viable Caligula stand-in. Even with thin-LTO + all components + samples + both render systems, the entire engine compiles too quickly on M-series hardware to put the build system under measurable pressure. The fallback candidate is Godot (see `godot-build-benchmark/SPEC.md`); Godot's ~1.5M LOC and Vulkan-class subsystem may land closer to Caligula's profile.

**Why our research was wrong**: the agent estimated based on LOC and historical build times on CI infrastructure, not on M-series Apple Silicon. M-class CPUs compile small/medium C++ files very fast; OGRE 1.x is mature, lean, and not template-heavy in the way Caligula is. The estimate may have been right for a 2018 Intel macOS CI runner; it's wrong by orders of magnitude for a 14-core M-class machine.

**What's still useful from this harness**:

- It's a working OGRE3D build harness under Xcode generator with full memstats sidecar — re-runnable on demand.
- The 25-second wall-time number is itself a data point: it confirms that "small open-source game engine" is a strictly different category from "Caligula-shaped game engine".
- The harness pattern (verify → fetch → pin → configure → build with memstats sampler) is identical to caligula and godot harnesses; reuse the pattern for any future Caligula-proxy candidates.

### 7.2 Cross-machine comparison preconditions

A `Compile time:` measurement on machine A is meaningfully comparable to machine B only if:

1. Both runs used the same `JOBS` value.
2. Both runs were on Apple Silicon (or both on Intel — don't mix arches).
3. Both `memstats` sidecars show neither run was paging catastrophically (paging latency contaminates the time — see chromium SPEC §9 for the full treatment).
4. Both runs used the same OGRE pin and the same `build-ogre3d.sh` revision.

### 7.3 macOS case-insensitive APFS gotcha

The caligula harness hit a class of bug where different macOS canonicalization APIs disagree on the case of a path on case-insensitive APFS, leading to clang's `-Wnonportable-include-path` firing fatally. OGRE3D's build flags don't include `-Werror` by default, so this should not be a problem here. If you see `nonportable-include-path` errors in a future run, see caligula's `build-caligula.sh:139-159` for the workaround.

### 7.4 Toolchain provenance

The pin produces identical source. Bit-identical *binaries* additionally require freezing Xcode version, the system clang revision, and macOS minor version — all of which contribute to compile and link output. For cross-machine comparison we don't care about binary identity; we care about *time-to-build the same source*. So this caveat is informational only.

## 8. Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Phase 1 reports missing `cmake`/`ninja` | Fresh machine | Allow rescue (omit `--no-rescue`) |
| `xcode-select --install` opens a GUI then exits | Expected — installer blocks until clicked through | Run the installer, re-invoke |
| `git clone` slow or hangs | Slow link to github.com | Patience; `caffeinate` already wraps the clone |
| `cmake configure` fails with "Could NOT find …" | Missing optional dep (e.g. SDL2 for samples) | Either `brew install` the named dep or disable the offending `OGRE_BUILD_*` flag |
| `ninja: error: build.ninja:NNNN: bad $-escape` | OGRE framework POST_BUILD rule under Ninja generator — see §5.2a | Already addressed: the harness uses `-G Xcode`. If you switch back to Ninja, expect this error |
| xcodebuild reports concurrency higher than `JOBS` (e.g. 14 instead of 12) | User-default `IDEBuildOperationMaxNumberOfConcurrentCompileTasks` overrides on sub-builds (e.g. freetype, zlib bundled deps) | See §3.3 parallelism caveat. Brief bursts only; main OGRE build honors `-jobs N` |
| `ninja` fails citing missing SDK symbol | Xcode CLT too old | Update Xcode to current; OGRE 1.x targets work back to Xcode 13 in principle |
| `clang frontend command failed with exit code 139` | VM-tier throughput failure (chromium SPEC §9 has the full diagnosis) | Lower `JOBS`. Not expected at 12 jobs / 24 GB for OGRE3D, but possible if running on a smaller-RAM machine |

## 9. Comparison summary (measured 2026-06-02)

| Metric | Caligula reference | OGRE3D measured | Verdict |
|---|---|---|---|
| Wall time | 26m 33s (1593s) | **25s** | **64× too light** |
| Peak RAM | 19.5 GB / 24 GB | 14.6 GB (≈ 0.7 GB above baseline) | Not meaningfully comparable — OGRE's actual delta is tiny |
| Peak pageout rate | 380 pages/sec | 34 pages/sec | Below interesting threshold |
| Total pages paged | ~7800 (121 MB) | 74 pages (1.2 MB) | 100× lower |
| LTO link share | 0.1% | (not extracted, Xcode generator) | — |
| Source TUs | unknown (proprietary) | 703 in source, 632 built (90% coverage) | — |
| Concurrency tested | JOBS=12 | JOBS=12 (with sub-build bursts to 14) | — |

**Judgment**: OGRE3D is not a viable Caligula stand-in. The wall-time ratio alone (64×) makes it useless for cross-machine performance ranking of Caligula-class workloads — a slow machine running OGRE3D for 35s vs a fast machine running it for 20s is dominated by build-system overhead and process startup, not the kind of sustained compile pressure that differentiates real game-engine builds.

**Recommendation**: pivot to Godot as the primary candidate. If Godot also lands too light, we'd have to either accept a smaller benchmark workload or build a synthetic replacement (see Caligula SPEC for "what would a synthetic Caligula-shape benchmark need to do").

## 10. Repo layout

```
ogre3d-build-benchmark/
├── build-ogre3d.sh   # The script
├── analyse.sh        # Metrics extractor; default --link-target=SampleBrowser
├── SPEC.md           # This document
└── logs/             # Created on first run
    ├── build-YYYYMMDD-HHMMSS.log
    └── memstats-YYYYMMDD-HHMMSS.log
```

OGRE3D source tree lives outside the project at `$HOME/ogre` (default; override with `--ogre-dir`). Not committed.
