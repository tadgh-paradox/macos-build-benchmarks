# macos-build-benchmarks

A set of build-time benchmark harnesses for ranking macOS hosting options (rented cloud Macs, self-hosted hardware, Docker-OSX vs bare metal) on a Caligula-class C++ compile workload. Caligula (Victoria 3) is the ground-truth reference profile; LLVM is the publishable proxy that can run on any cloud Mac without VPN access. OGRE3D and Godot were measured but came in too light to be faithful Caligula stand-ins on M-class Apple Silicon — kept as smoke tests.

## How the harnesses work

1. Each harness pins its source to an immutable revision — release-tag SHAs for LLVM/OGRE3D/Godot (cloned from public upstream), hardcoded commit SHAs for Caligula + cw (cloned from internal GitLab; VPN required). Each then runs `cmake`/`scons` configure and a timed build at a chosen target.
2. A 1-Hz background sampler records `vm_stat` + `sysctl vm.swapusage` to a TSV alongside the build log for the entire compile phase; only the compile is timed (not configure, fetch, or conan install).
3. Outputs are paired by timestamp: `logs/build-<ts>.log` + `logs/memstats-<ts>.log`. The included `analyse.sh` extracts peak RAM / peak swap / pageout regime / LTO link-share from the pair.

Per-harness `SPEC.md` files document each project's source pin, design decisions, methodology caveats, failure modes, and the measured comparison numbers below.

## Measured profiles

Reference rig for the numbers below: 14-core / 24 GB Apple Silicon Mac, macOS 15.7.x, JOBS=12 (`nproc --ignore 2`). Measurements 2026-06-01 (Caligula) and 2026-06-02 (LLVM, Godot, OGRE3D).

### Caligula — `buildserver-osx-clang-ReleaseLto` (ground-truth reference)

| Wall time | Peak RAM | Peak pageout | Total paged | LTO link share |
|---|---|---|---|---|
| **1593s (26m 33s)** | 19.5 GB / 24 GB | 380 pages/sec | ~7800 pages (121 MB) | 0.1% |

### LLVM — `llvmorg-22.1.7` (publishable benchmark)

Three configurations measured; the third is the canonical config (`./build-llvm.sh` defaults).

| Stage | `LLVM_PROJECTS` | `--target` | Wall | Peak RAM | Peak pageout | Total paged | vs Caligula |
|---|---|---|---|---|---|---|---|
| 1 | `clang;lld` | `clang` | 364s (6m 4s) | 15.5 GB | 224 pages/sec | 1062 (17 MB) | 4.4× under |
| 2 | `clang;lld;mlir` | `clang` | 392s (6m 32s) | 15.6 GB | 116 pages/sec | 947 (15 MB) | MLIR didn't compile |
| **3 (canonical)** | `clang;lld;mlir` | `all` | **2049s (34m 9s)** | 16.9 GB | 174 pages/sec | 2661 (42 MB) | **1.29× over** |

Stage 2 was a false start: `LLVM_ENABLE_PROJECTS=...;mlir` makes MLIR available to cmake but the `--target clang` dep graph doesn't reach it, so MLIR's 1131 source files were skipped. `--target all` is required to actually build subprojects you've added. See `llvm-build-benchmark/SPEC.md` §10 for the full iteration log.

### Godot — `4.6.3-stable` (too light by 8.6×; kept as smoke test)

| Wall time | Peak RAM | Peak pageout | Total paged | LTO link share |
|---|---|---|---|---|
| 186s (3m 6s) | 14.9 GB | 177 pages/sec | 388 pages (6 MB) | not extracted (SCons) |

Config: `platform=macos arch=arm64 target=editor production=yes vulkan=no num_jobs=12`. SCons toolchain rather than CMake+Ninja means `analyse.sh`'s link-share regex doesn't apply; documented as intentional in the SPEC.

### OGRE3D — `v14.5.2` (too light by 64×; kept as smoke test)

| Wall time | Peak RAM | Peak pageout | Total paged | LTO link share |
|---|---|---|---|---|
| 25s | 14.6 GB | 34 pages/sec | 74 pages (1.2 MB) | not extracted (Xcode generator) |

Config: `-G Xcode` (the Ninja generator hits OGRE 1.x's unconditional `$(CONFIGURATION)` POST_BUILD rules), `CMAKE_XCODE_ATTRIBUTE_LLVM_LTO=YES_THIN`, samples + all components + GL/Metal render systems, no Vulkan. See `ogre3d-build-benchmark/SPEC.md` §5.2 for the Ninja-vs-Xcode generator saga.

## Headline finding

M-class Apple Silicon eats C++ compilation fast enough that the popular open-source game engines (OGRE3D, Godot) can't fill the time-axis required to match a real game engine like Caligula. LLVM at `clang;lld;mlir` with `--target all` is the only publishable workload we found that lands Caligula-class on wall-time and peak RAM. **Run `./llvm-build-benchmark/build-llvm.sh` on the matching tier branch (see below), compare the `Compile time:` line and `analyse.sh` output against another Mac, that's the cross-machine benchmark.**

## LLVM benchmark branches

The LLVM harness ships its build configuration via git branches — pick the one that matches the host RAM. The branch is the contract: check it out, run `./llvm-build-benchmark/build-llvm.sh` with no args, the resulting log pairs cleanly with the branch name.

| Branch | Compile jobs (`-j`) | Concurrent LTO links | Use on | What it represents |
|---|---|---|---|---|
| `main` | ninja default (`nproc+2`) | unbounded | hosts with ≥32 GB RAM | **Production-equivalent.** Mirrors what Paradox CI's `batmake` does (no caps anywhere). Will OOM on 24 GB hosts — don't run there. |
| `24` | `nproc --ignore 2` | 1 | 24 GB host (the reference rig) | Safe baseline. All canonical numbers in this README and `llvm-build-benchmark/SPEC.md` were measured on this branch. |
| `32` | `nproc --ignore 2` | 2 | 32-63 GB host | Tier-tuned for moderate RAM. |
| `64` | `nproc --ignore 2` | 4 | ≥64 GB host | Tier-tuned for the CI-pod-sized class. |

**Cross-machine comparison rule**: both runs must be on the same branch. Mixing branches mixes two different workloads. See `llvm-build-benchmark/SPEC.md` §7.3 for the full methodology, including which branch answers which question.

The other three harnesses (caligula, godot, ogre3d) do not have tier branches — their parallelism settings are not RAM-bound at this scale.
