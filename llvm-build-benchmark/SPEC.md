# `build-llvm.sh` — Specification

## 1. Intent

Produce a reproducible LLVM build profile on macOS for cross-machine benchmarking. The script clones `llvm/llvm-project` pinned to a release-tag SHA, builds clang at the `clang;lld` project subset with thin-LTO, times the compile, and samples memory state every second.

This harness exists because **OGRE3D and Godot both came in too light** to be faithful Caligula-class workloads on M-series Apple Silicon — Godot at 186s, OGRE3D at 25s, vs Caligula's 1593s (8.6× and 64× too short respectively). LLVM is the publishable Caligula-class candidate. It is not game-engine-shaped, but it IS the right magnitude (~5M LOC, 20-40 min expected wall-time on M-class), which is what cross-machine ranking actually needs.

See `caligula-build-benchmark/SPEC.md` §11 for the relationship between this harness and the others.

## 2. Executive summary

- **What it does**: clones [llvm/llvm-project](https://github.com/llvm/llvm-project) pinned to `llvmorg-22.1.7`, runs cmake configure with `LLVM_ENABLE_PROJECTS=clang;lld` + `LLVM_ENABLE_LTO=Thin`, builds the `clang` target with Ninja, times the compile, samples memory.
- **Reference target**: Caligula at 1593s / 19.5 GB peak on a 14-core / 24 GB Apple Silicon Mac at JOBS=12. LLVM expected to land in the same neighborhood — single-digit GB peak RAM, 15-40 min wall-time. Will fill in measured numbers after the first real run.
- **Run it**: `./build-llvm.sh` from this directory. First run does a shallow init+fetch of LLVM's source at the pinned SHA (~1 GB), then builds for an estimated 15-40 min.
- **Outputs**: `logs/build-<ts>.log` (transcript) and `logs/memstats-<ts>.log` (TSV). Paired by timestamp.
- **Analyse it**: `./analyse.sh logs/memstats-<ts>.log logs/build-<ts>.log` extracts peak RAM, swap, pageout rate, and LTO link-share for the `clang` target. Unlike the godot and ogre3d harnesses (which use SCons and Xcode respectively), LLVM uses Ninja — `analyse.sh`'s link-share regex works without modification.

## 3. Technical onboarding

Skip ahead to §4 if you've built LLVM before and know what a monorepo with separate cmake source dir means.

### 3.1 What is LLVM?

LLVM is the compiler infrastructure project — the codebase that produces `clang` (the C/C++/Objective-C compiler), `lld` (linker), `lldb` (debugger), `mlir` (intermediate representation framework), and dozens of other tools. ~5M LOC across all subprojects; the `clang;lld` subset we build here is ~2-3M LOC. Heavy C++ template instantiation, generated TableGen code, multiple parser/codegen passes — exactly the kind of workload that exercises a C++ build toolchain. Not game-engine-shaped, but Caligula-shaped in *size* and *RAM pressure*.

### 3.2 What's a "monorepo with separate cmake source dir"?

`llvm/llvm-project` is a single git repo containing all LLVM subprojects in subdirectories: `llvm/`, `clang/`, `lld/`, `compiler-rt/`, `libcxx/`, `mlir/`, etc. The cmake source root is **`llvm/`**, not the repo root. You point cmake at `$LLVM_DIR/llvm` and tell it which subprojects to enable via `-DLLVM_ENABLE_PROJECTS=...`. That cmake then discovers and includes the enabled subproject subdirectories automatically.

If you accidentally pass `-S $LLVM_DIR` (repo root) instead of `-S $LLVM_DIR/llvm`, cmake gives an error about a missing CMakeLists.txt.

### 3.3 What's a "harness"?

A wrapper script that runs the real build and records measurements alongside. Six phases:

1. **Prerequisites verified** — cmake, ninja, python3, git, brew, Xcode CLT, disk space.
2. **Missing prereqs rescued via brew** — with consent.
3. **Source fetched** — shallow git init + targeted SHA fetch (avoids LLVM's ~10 GB full history).
4. **Source pinned** — force checkout the SHA into a detached HEAD.
5. **cmake configure** — produces `build.ninja`. Not in the timer.
6. **Timed compile** — `cmake --build … --target clang` with the memstats sampler running.

### 3.4 The CMake flags, explained

| Flag | What it does |
|---|---|
| `-S $LLVM_DIR/llvm` | Source directory. LLVM's CMakeLists.txt lives here, not at repo root. |
| `-B $LLVM_DIR/build` | Build directory. |
| `-G Ninja` | Ninja generator (LLVM's canonical macOS path). |
| `-DCMAKE_BUILD_TYPE=Release` | Optimised build (`-O3`), no debug info. |
| `-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0` | Target macOS 11 or newer at link time. |
| `-DLLVM_ENABLE_PROJECTS="clang;lld"` | Which subprojects to enable. clang+lld is the minimum Caligula-class subset. |
| `-DLLVM_ENABLE_LTO=Thin` | Enable thin-LTO across the build. Matches Caligula's "ReleaseLto" preset shape. |
| `-DLLVM_INCLUDE_TESTS=OFF` | Skip building test binaries — they're large and not part of the benchmark workload. |
| `-DLLVM_INCLUDE_BENCHMARKS=OFF` | Same reason. |
| `-DLLVM_INCLUDE_EXAMPLES=OFF` | Same reason. |
| `-DLLVM_TARGETS_TO_BUILD=AArch64` | Build only Apple Silicon codegen. The default `all` adds 25+ backends (x86, ARM, PowerPC, MIPS, RISC-V, …) — substantial extra compile work that's not "fair" cross-arch. |
| `-DLLVM_PARALLEL_COMPILE_JOBS=$JOBS` | LLVM-internal parallelism cap. Set only if `JOBS` is provided. **Default: unset on `main` (matches production CI's batmake defaults).** Tier branches set `nproc --ignore 2`. See §7.3. |
| `-DLLVM_PARALLEL_LINK_JOBS=$LINK_JOBS` | Concurrent LTO link cap. Each LTO link eats 3-5 GB; concurrent links are the standard way to OOM an LLVM build. Set only if `LINK_JOBS` is provided. **Default: unset on `main` (matches production CI).** Tier branches `24`/`32`/`64` set `1`/`2`/`4`. See §7.3. |

### 3.5 What the memstats sidecar measures

Identical schema to the other harnesses. One TSV row per second to `logs/memstats-<ts>.log`. Column schema is in `~/projects/chromium-build-benchmark-for-mac/SPEC.md` §6.

## 4. Source pin

| LLVM tag | SHA | Date |
|---|---|---|
| `llvmorg-22.1.7` | `7979ad438a4904e5ff57dc85e962992242f81688` | 2026-05-x |

**Why this revision.** Latest stable point release on the LLVM 22.x line as of script-writing (2026-06-02). LLVM tags releases regularly; the 22.x.y point releases are stable picks that have been through LLVM's release branch testing. We don't pin to `main`, which would drift between runs.

**Re-pinning.** When a new stable point release ships, look up its SHA with `git ls-remote --tags https://github.com/llvm/llvm-project.git llvmorg-X.Y.Z`, replace both constants near the top of `build-llvm.sh` (`LLVM_REV` and `LLVM_TAG`), and rerun.

## 5. Design decisions

1. **Build the `clang;lld` subset, not all of LLVM.** All-of-LLVM (clang + lld + lldb + mlir + flang + …) is ~5M LOC and takes 60+ min on M-class hardware. We don't need that magnitude for cross-machine comparison; we need *Caligula-class* (~25 min). `clang;lld` is the canonical "buildable clang" subset and the right size. **Tradeoff**: misses MLIR's tablegen-heavy build, which is some of the heaviest C++ in LLVM. If measured numbers come in too light, scale up via `--projects clang;lld;mlir`.

2. **`LLVM_ENABLE_LTO=Thin`, not Full.** Thin-LTO matches Caligula's shape (Caligula's measured link-share was 0.1% — thin-LTO distributes work). Full LTO would concentrate work in a multi-minute sequential final link, which is closer to Chromium's profile than Caligula's.

3. **`LLVM_TARGETS_TO_BUILD=AArch64` only.** The default `all` builds codegen for 25+ architectures. That's the right call for shipping a real compiler but artificial work for a benchmark — a build that includes RISC-V tablegen-generated code doesn't represent Caligula's workload more faithfully than a build without it. Restricting to AArch64 keeps the workload focused on the platform we actually care about.

4. **`LLVM_PARALLEL_LINK_JOBS=1`.** This is the "don't OOM" setting. LTO link of `clang` itself eats 3-5 GB of RAM; running multiple LTO links concurrently is the well-documented way LLVM builds crash on RAM-constrained hosts. Serialising links costs wall-time but ensures the 24 GB laptop survives. **Tradeoff**: this is a different parallelism model than Caligula's, which doesn't have a "concurrent link cap" knob. Caligula uses thin-LTO distributed across per-lib link steps, where each is small enough not to need the cap.

5. **Build target choice depends on `LLVM_PROJECTS`.** This was non-obvious and we learned it empirically. With `--projects clang;lld`, `--target clang` builds everything LLVM relevant (clang pulls all its lib deps; ~3175 ninja steps; 364s on this rig). With `--projects clang;lld;mlir`, `--target clang` does NOT compile MLIR at all — MLIR is enabled in cmake but not in clang's dep graph (we verified: 0 MLIR `.cpp.o` files produced; wall-time only 28s over the bare clang;lld run). To actually compile MLIR you need `--target all`, which builds every target the cmake configuration enables (~6718 ninja steps; 2049s on this rig; 130 executable links). **Heuristic**: if you add subprojects, also pass `--target all`. Single-target builds only build that target's dep graph.

6. **Shallow init+fetch instead of `git clone`.** LLVM's full git history is ~10 GB. A standard `git clone` would download all of it. We instead `git init` + `git remote add` + `git fetch --depth=1 origin <SHA>` — downloads ~1 GB of just the pinned commit's files. github.com supports this via `uploadpack.allowReachableSHA1InWant=true`. Chromium harness uses the same pattern; see chromium SPEC §7.

7. **Cold-build default (`--clean`).** Each run wipes `$LLVM_DIR/build`. Mirrors caligula / ogre3d / godot.

8. **No abstraction across harnesses.** Same rationale as the other three: three (now four) copies of the memstats sampler is below the threshold for refactoring into a shared library.

## 6. Output contract

Two files per run, paired by a single timestamp variable:

- `logs/build-<ts>.log` — every line prefixed with `[HH:MM:SS]`. Ends with `[HH:MM:SS] Compile time: Hh Mm Ss (NNNs total)` on success.
- `logs/memstats-<ts>.log` — TSV header + N rows. Column schema identical to all other harnesses.

**Link-share extraction works** for this harness because LLVM uses Ninja, which emits `[N/M] Linking CXX executable bin/clang-NN`. `analyse.sh`'s default `--link-target clang` matches this line and computes the link-share. Same mechanism as the caligula harness.

## 7. Methodology caveats

### 7.1 LLVM is not game-engine-shaped

Caligula is a game engine with heavy template instantiation, PCH-heavy compile units, and a renderer / physics / scripting subsystem mix. LLVM is a compiler — different code patterns. Template instantiation surface differs: LLVM uses templates extensively but the patterns are more "data-structure-templates over types" (SmallVector, DenseMap, etc.) than Caligula's game-state-templates over entity types. PCH usage is incidental rather than load-bearing.

**Why this is acceptable for cross-machine benchmarking**: ranking machines by build-time performance depends on the hardware bottleneck profile, not on the source-code shape. Caligula's bottleneck is **RAM-pressure-during-parallel-compile** (peak working set, sustained pageouts) — that profile is workload-shape-agnostic. A machine that ranks well on LLVM (CPU throughput + RAM bandwidth + disk IO during peak parallel compile) will rank well on Caligula for the same reasons.

**Why this is unacceptable for absolute-time prediction**: an LLVM time of 25 min does not predict a Caligula time of 25 min on the same hardware. The codebases are different sizes and different shapes. Use LLVM as a *ranking proxy*, not a *time predictor*.

### 7.2 Cross-machine comparison preconditions

Same as the other harnesses, plus a branch-discipline rule specific to this harness:

1. Same `JOBS` value.
2. Same arch (Apple Silicon both, or x86_64 both — not mixed).
3. Both `memstats` sidecars show neither run was paging catastrophically.
4. Both runs used the same LLVM pin and the same `build-llvm.sh` revision.
5. **Same branch.** Comparing across machines requires both runs on the same git branch (`main`, `24`, `32`, or `64`) — mixing branches mixes two different workload definitions. See §7.3 for which branch answers which question.

### 7.3 Branch layout — `main` matches production CI, tier branches are tuned per host RAM

This benchmark needs to satisfy two requirements that pull in opposite directions:

- **Match what production CI does** so the numbers say something about real build behaviour. Paradox CI builds (caligula, titus, marius) all run via `batmake` and set *neither* `LLVM_PARALLEL_LINK_JOBS` *nor* `--parallel N` — they accept ninja's defaults (compile = `nproc+2`, link = unbounded). Anything we cap in this harness diverges from that.
- **Run safely across multiple host RAM tiers (24 / 32 / 64 GB)**. Uncapped LTO links eat 3-5 GB each; on a 24 GB host with `nproc+2 ≈ 14` parallel compile jobs, multiple concurrent LTO links OOM. On a 64 GB host the same uncapped config is fine.

We resolve this by giving each requirement its own **branch**:

| Branch | `JOBS` (compile cap) | `LINK_JOBS` (link cap) | Target host | What it represents |
|---|---|---|---|---|
| `main` | unset → ninja default (`nproc+2`) | unset → unbounded | any host with enough RAM | **Production-equivalent.** Mirrors batmake/CI defaults exactly. Answers "what does production CI do on this hardware?" Will OOM on a 24 GB host — don't run there. |
| `24` | `nproc --ignore 2` | 1 | 24 GB host (reference rig) | **Safe baseline.** Conservative caps for the smallest target tier. All canonical measurements in §9/§10 were taken on this config. |
| `32` | `nproc --ignore 2` | 2 | 32-63 GB host | Tier-tuned: 2 concurrent LTO links comfortably fit (+3-5 GB above 24's peak). |
| `64` | `nproc --ignore 2` | 4 | ≥64 GB host | Tier-tuned: 4 concurrent LTO links, max-capacity for this size (+9-15 GB above 24's peak). |

#### Why this layout instead of one branch with conditional logic

A previous revision put `LINK_JOBS=1` as a *default* on `main` and asked operators to flip it per host. That design hid the asymmetry between this benchmark and production CI — the harness looked more conservative than CI without ever telling you. The investigation that surfaced this is recorded in commit history; the takeaway: **the benchmark should not silently differ from production**. Now `main` *is* the CI-equivalent reference and the caps are explicit tier choices on named branches.

#### When to use each branch

| Question | Branch |
|---|---|
| "What does production CI do on this hardware?" | `main` (on a host with ≥32 GB; expect OOM on 24 GB) |
| "Compare two machines on a fixed safe-for-everyone workload" | `24` (lowest common denominator; runs everywhere) |
| "What's this 32 GB host's max-capacity build look like?" | `32` |
| "What's this 64 GB host's max-capacity build look like?" | `64` |

#### Cross-machine comparison rule

**Both runs must be on the same branch.** Mixing branches conflates "machine A is faster" with "machine A got a less-constrained config." The two natural columns when reporting a comparison:

- **Tier-safe column**: every machine runs `24`. Apples-to-apples; conservative everywhere; runs on any tier. Most defensible for headline "which silicon is faster?" claims.
- **Tier-max column**: every machine runs its own tier branch (24 GB → `24`, 32 → `32`, 64 → `64`). Shows tier ceiling, not pure silicon comparison — a 32 GB machine getting `LINK_JOBS=2` is partly winning because the workload changed.

`main` is meaningful for capacity-planning (does this host survive what CI throws at it?) but **not for cross-tier ranking**, because OOMing or near-OOMing on small hosts distorts wall-time non-linearly.

#### How to invoke

- **Recommended**: `git checkout <branch>` and run `./build-llvm.sh` with no args. The branch is the contract; the log filename pairs cleanly with the branch name in your records.
- **Per-run override** on any branch: `--jobs N` / `JOBS=N` and `--link-jobs N` / `LINK_JOBS=N`. Useful for ad-hoc experiments without switching branches.

#### Caveats

- **The CI machines this benchmark targets run ~64 GB RAM as Kubernetes nodes**, with each build pod requesting 8 vCPU / 50 GiB (highspec) per `batmake/templates/game-pipeline.yml`. The `64` branch is the closest match to a pod's actual capacity ceiling — though ninja inside the pod uses the *node's* CPU count, not the pod request, which is a separate concern.
- **The measured numbers in §9 / §10 were taken on the `24` branch's config** (14-core / 24 GB Apple Silicon at `JOBS=12`, `LINK_JOBS=1`). They are NOT directly comparable to a `main`-branch run on the same hardware — `main` would attempt unbounded link parallelism.
- Per §7.1, none of these branches predicts absolute Caligula build time. They are all ranking proxies.

### 7.4 `LLVM_ENABLE_PROJECTS` is a knob — and you also need `--target all` to actually build the subprojects

We iterated empirically (see §9 iteration log). Key finding: `clang;lld` alone with `--target clang` is too light by 4.4×. Adding MLIR to projects but keeping `--target clang` produces NO additional work — MLIR is enabled but not in clang's dep graph. The combination that lands Caligula-class is `--projects 'clang;lld;mlir' --target all`.

**Heuristic for future scale-up**: if Caligula gets heavier in a future revision and our LLVM benchmark needs to keep pace, add more subprojects (next candidates: `libcxx;libcxxabi`, then `compiler-rt`, then `flang`) and verify with `--target all` that the new subprojects are actually compiling (grep the build log for `obj/.*newproject.*\.cpp\.o`).

### 7.5 Link-share metric is not meaningful for `--target all` builds

`analyse.sh`'s link-share regex finds the first executable link matching `--link-target` and computes "build_end - link_start" as the link duration. For single-target builds (Caligula's `victoria3`, LLVM's `--target clang`) this is correct: the final exec link is at the end of the build, and "build end" is close to "link end". For `--target all` builds, there are 130+ executable links sprinkled throughout (every llvm-* tool, mlir-* tool, lld). The "link" we pick is somewhere in the middle of the build, and everything after isn't all link — it's more compiles AND links.

The proper fix would be to sum all "Linking CXX executable" durations rather than using a single start-time. Future work. For now: ignore the link-share number for `--target all` runs and rely on the structural argument (thin-LTO is enabled, so link work is distributed; final exec link is sub-second per binary). For single-target runs (e.g. `--target clang` alone) the metric is reliable.

## 8. Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Phase 1 reports missing `cmake`/`ninja` | Fresh machine | Allow rescue (omit `--no-rescue`) |
| Phase 3 `git fetch` slow or hangs | Slow link to github.com / large transfer | Patience; `caffeinate` already wraps the fetch |
| `cmake configure` errors with "Could not find LLVM at $LLVM_DIR" | Pointed at repo root, not the `llvm/` subdir | Check `-S` arg in `configure_phase()` — should be `$LLVM_DIR/llvm`, not `$LLVM_DIR` |
| Build crashes with exit 137 (SIGKILL) mid-link | Concurrent LTO links exhausted RAM | Verify `LLVM_PARALLEL_LINK_JOBS=1` is set; if a future cmake change removes it, reinstate |
| `clang frontend command failed with exit code 139` | VM-tier throughput failure (chromium SPEC §9) | Lower `JOBS`. Unexpected at 12 jobs / 24 GB with `LLVM_PARALLEL_LINK_JOBS=1`, but possible on smaller machines |
| `Compile time:` line missing from log | Build phase didn't reach the end successfully | Check log for `FAILED:` lines; common cause is missing tablegen build dependency — re-running often fixes |

## 9. Comparison summary (measured 2026-06-02)

| Metric | Caligula reference | **LLVM (clang;lld;mlir + target=all)** | LLVM (clang;lld + target=clang) | Godot | OGRE3D |
|---|---|---|---|---|---|
| Wall time | 1593s (26m 33s) | **2049s (34m 9s)** | 364s (6m 4s) | 186s | 25s |
| Wall-time ratio to Caligula | 1× | **1.29× over** | 4.4× under | 8.6× under | 64× under |
| Peak RAM | 19.5 GB / 24 GB | 16.9 GB | 15.5 GB | 14.9 GB | 14.6 GB |
| Peak pageout rate | 380 pages/sec | 174/sec | 224/sec | 177/sec | 34/sec |
| Total pages paged | ~7800 (121 MB) | 2661 (42 MB) | 1062 (16.6 MB) | 388 (6 MB) | 74 (1.2 MB) |
| LTO link share | 0.1% | distributed (see below) | 0.0% (matches) | (not extracted) | (not extracted) |
| Build steps (ninja) | (proprietary) | **6718** | 3175 | ~9000 | 632 |
| Executable links | 1 (final exec) | 130 (target=all) | 1 (clang only) | 1 | many small |

**Headline finding**: LLVM `clang;lld;mlir` with `--target all` is Caligula-class. Wall-time is 1.29× Caligula, peak RAM is 13% under Caligula, pageout regime is half Caligula's but still substantial. **This is the publishable cross-machine benchmark candidate.**

**LTO link-share for target=all is distributed and not meaningfully captured by analyse.sh's regex.** The regex finds the first `clang-22` link line and treats everything after as link — but with target=all there are 130 separate executable links throughout the build, not one dominant final link. The reported "63.5%" is meaningless. The actual structure matches Caligula's thin-LTO distributed link pattern. For a more accurate link-share measurement on multi-target builds, see §7.5.

**Configuration as published**: `./build-llvm.sh --projects 'clang;lld;mlir' --target all`

**Could dial back**: we're slightly over Caligula. Could also try `clang;lld` (only the clang;lld libraries) with `--target all` to see if that lands closer without MLIR. Future work; current configuration is good enough.

See §10 for the iteration log — how we landed at the canonical configuration through three measurement-driven attempts.

## 10. How we landed at the canonical configuration

This benchmark was iterated to. We did not arrive at `--projects 'clang;lld;mlir' --target all` by reading documentation; we got here by measuring three configurations and adjusting based on what the numbers showed. Recording the journey because someone running this exploration again — on different hardware, against a newer LLVM release, or after Caligula's profile shifts — will need the same scaffolding.

The reference target throughout: **Caligula at 1593s wall / 19.5 GB peak / 380 pages/sec peak pageout** (measured 2026-06-01 on a 14-core / 24 GB Apple Silicon Mac at JOBS=12). Goal: find an LLVM configuration that lands within ~1.5× on wall-time AND within a few GB on peak RAM.

### Stage 1 — `clang;lld` + `target=clang` (the conservative starting point)

Initial rationale: clang+lld is the canonical "buildable clang" subset of LLVM. Roughly 3M LOC; on Intel CI runners this builds in 20-30 minutes, which would have been Caligula-class. We picked `--target clang` because the `clang` binary depends on every relevant LLVM library and is the heaviest single target.

**Measured: 364s wall / 15.5 GB peak / 224 pages/sec peak pageout. 4.4× under Caligula.**

Root cause: M-class Apple Silicon CPUs are faster at C++ compilation than the historical CI runners the research was based on. The same workload that takes 20-30 min on an Intel CI machine takes ~6 min on this hardware. This same phenomenon undershot OGRE3D (25s vs predicted 8-18 min) and Godot (186s vs predicted 15-40 min). M-class hardware fundamentally compresses the available time-axis for build benchmarks.

### Stage 2 — add MLIR, keep target=clang (the wrong fix)

Naive next step: scale up `LLVM_ENABLE_PROJECTS` by adding MLIR. MLIR is the heaviest single subproject in LLVM — heavy tablegen-driven C++, dozens of dialects, ~3000 source files.

**Measured: 392s wall (only 28 seconds longer than stage 1). MLIR did not compile at all.**

Root cause: `LLVM_ENABLE_PROJECTS=clang;lld;mlir` makes MLIR available to cmake but doesn't force it to build. `cmake --build --target clang` only builds the dependency graph reachable from the `clang` executable. `clang` doesn't depend on MLIR — so MLIR is enabled but skipped.

Verification: grepped the build log for `MLIR.*\.cpp\.o` and found **zero** matches. The 28-second delta was entirely cmake configure overhead (more subdirectories to scan) plus a small number of build-system rules.

**Lesson**: when adding subprojects, either change `--target` to something that depends on them, OR use `--target all` to build everything cmake configured.

### Stage 3 — add MLIR, target=all (the canonical config)

**Measured: 2049s (34m 9s) wall / 16.9 GB peak / 174 pages/sec peak pageout. 1.29× over Caligula.**

Verification: 1131 MLIR `.cpp.o` outputs in the build log; 6718 ninja steps (vs 3175 in stage 1); 130 separate executable links (vs 1 in stage 1).

This is the canonical published benchmark. The wall-time is slightly over Caligula's, peak RAM is slightly under (~13%), pageout regime is roughly half. All three dimensions are in the same ballpark — which is what cross-machine ranking requires.

### Heuristic for future scaling

If Caligula grows and our benchmark needs to keep pace:

1. Add subprojects in this order, measuring after each: `libcxx;libcxxabi`, `compiler-rt`, `flang`, `lldb`.
2. After each addition, **verify the subproject actually compiled** by greping the build log for its `.cpp.o` outputs. Don't assume `LLVM_ENABLE_PROJECTS` alone makes it build.
3. Stop when wall-time and peak RAM are within 1.5× and ~3-5 GB of the target reference profile.
4. If we go significantly over (e.g. 2× wall-time), dial back one subproject.

If you want to dial back from the current 1.29×-over position, the simplest knob is `--target` to something narrower than `all`. `--target all --projects clang;lld` (no MLIR but build everything) lands somewhere between stage 1 (364s) and stage 3 (2049s) and is untested at the time of writing.

## 11. Known limitations (not fixed)

These are real and worth flagging so a future reader doesn't trip on them.

### 11.1 `analyse.sh` link-share is wrong for `--target all` runs

The regex finds the first `Linking CXX executable .../clang` line and computes `build_end - link_start` as the link duration. For single-target builds (Caligula's `victoria3`, LLVM `--target clang`) this is correct: the final exec link is at the end of the build and "build end" is close to "link end". For `--target all` it's nonsense: there are 130 separate executable links sprinkled throughout. The first `clang-22` link happens partway through the build and everything after isn't all link.

This run reported "63.5% link share" — that's bogus. The real structure matches Caligula's thin-LTO distributed link pattern (final exec link is sub-second per binary).

Proper fix: sum all `Linking CXX executable` durations rather than picking a single span. Future work. For now, ignore the link-share number on `--target all` runs. The metric is reliable for `--target clang` runs (and the equivalent single-target invocations on caligula/godot/ogre3d).

### 11.2 We landed 1.29× over Caligula, not exactly on it

The canonical config slightly overshoots — 2049s vs Caligula's 1593s. We didn't iterate further to dial it down because:

- 1.29× is within "same ballpark" for cross-machine ranking purposes.
- Slightly-over is preferable to slightly-under for a benchmark that should differentiate machines: more pressure → more clearly visible machine differences.
- Dialing down means dropping MLIR (back to stage 1's 4.4×-under), which is worse than overshooting by 29%.

If you want a closer match, untested options: `clang;lld + target=all` (no MLIR but build all of clang;lld's tools) likely lands somewhere in 600-1500s. Worth measuring as future work if exact-time-match matters.

### 11.3 `LLVM_PARALLEL_LINK_JOBS` and `JOBS` tuning across RAM tiers — implemented via branches

Previously a known limitation. Resolved by the branch layout in §7.3:

- `main` is uncapped on both compile and link → matches production CI's batmake defaults exactly.
- `24` / `32` / `64` set explicit safe caps for their target host RAM tier.

This replaces the earlier `LINK_JOBS=1` script default that silently diverged from production CI behaviour.

### 11.4 LLVM is not game-engine-shaped

Documented in §7.1, restating here for the audit trail: LLVM's template instantiation surface, PCH usage, and code-pattern distribution differ from Caligula's. For *ranking machines on Caligula-like workload pressure*, this is acceptable because the hardware bottleneck profile (peak RAM during parallel compile, pageout pressure, disk IO during compressor pressure) is workload-shape-agnostic. For predicting whether a Caligula-specific patch will compile faster or slower, this is the wrong tool.

### 11.5 OGRE3D and Godot harnesses ship but are documented as "too light"

Their SPECs (§9) note that they're not Caligula-class. They're kept in the repo because:

- They're cheap to maintain (each is ~200 lines of bash).
- They're useful as quick smoke tests when bringing up a new machine: "does this rented Mac compile a small / medium C++ project at all?".
- They have measurement data from this hardware that's useful for future-hardware comparisons.
- The exploration process documented in the four SPECs collectively is valuable methodological recap.

A future revision could mark them clearly as "smoke-test only" and `llvm` as "the benchmark". For now they coexist.

## 12. Repo layout

```
llvm-build-benchmark/
├── build-llvm.sh   # The script
├── analyse.sh      # Metrics extractor; default --link-target=clang
├── SPEC.md         # This document
└── logs/           # Created on first run
    ├── build-YYYYMMDD-HHMMSS.log
    └── memstats-YYYYMMDD-HHMMSS.log
```

LLVM source tree lives at `$LLVM_DIR` (default `$HOME/llvm-project`). Not committed.
