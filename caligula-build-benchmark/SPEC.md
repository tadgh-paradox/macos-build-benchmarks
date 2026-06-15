# `build-caligula.sh` — Specification

## 1. Intent

Produce a reproducible Caligula (Victoria 3) build profile on macOS for cross-machine benchmarking. The script clones Caligula + cw from internal Paradox GitLab (SSH access required — VPN), pins both to hardcoded commit SHAs, runs `cmake` + `ninja` directly (bypassing `./configure.sh` for reasons documented in §5), times only the compile phase, and emits two artifacts: a build log ending with `Compile time: Hh Mm Ss` and a per-second TSV of memory/page state during the compile.

**This harness's role is special.** Caligula is the proprietary game we actually want to benchmark, but its source is internal — we can't ship it to a rented cloud Mac without VPN access. So this harness exists to produce the **ground-truth reference profile** that the publishable LLVM (and lighter OGRE3D / Godot) harnesses are tuned against, on test machines that DO have VPN access. LLVM is the no-VPN benchmark used on rented Macs; this Caligula harness runs only on VPN-trusted machines.

See `llvm-build-benchmark/SPEC.md` (canonical publishable benchmark), `ogre3d-build-benchmark/SPEC.md` and `godot-build-benchmark/SPEC.md` (lighter candidates).

## 2. Executive summary

- **What it does**: clones Caligula + cw from internal GitLab if absent, force-checks-out the pinned SHAs (§4), then invokes `cmake configure` + `cmake --build` at the `buildserver-osx-clang-ReleaseLto` preset (default — the CI-canonical macOS LTO preset). Times the compile phase, samples memory state every second.
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

- **Run it**: `./build-caligula.sh` from this directory. The harness will `git clone` both repos via SSH from `gitlab.build.paradox-interactive.com` if `$CALIGULA_DIR` (default `$HOME/projects/Caligula`) and `$CW_DIR` (default `$HOME/projects/cw`) don't already have `.git/`. Then it force-checks-out the pinned SHAs from §4. **Local working-tree edits in either repo will be discarded by the force-checkout** — stash them first if you have in-progress work.
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

This harness defaults to **`buildserver-osx-clang-ReleaseLto`** — the preset CI uses for the macOS shipping binary, defined in canonical `CMakePresets.json` and therefore available on any fresh clone. (The previous default, the developer-only `osx-clang-ReleaseLto`, lives in a per-user `CMakeUserPresets.json` and isn't present on fresh checkouts; see §7.2 for the consequence.)

### 3.4 What's a "harness"?

A wrapper script that fetches+pins the source, runs the real build, and records measurements alongside. Six phases per run:

1. **Prerequisites verified**. cmake, ninja, conan, python3, git, brew, GNU coreutils.
2. **Missing prereqs rescued via brew** with consent.
3. **Source cloned** if absent. Two `git clone` invocations against `git@gitlab.build.paradox-interactive.com:gsg/caligula/caligula.git` and `…:gsg/tech/cw.git`. Idempotent — skips clone if `.git` exists.
4. **Source pinned** to the SHAs in §4 via `git fetch --depth=1 origin <SHA>` + `git checkout --force --detach <SHA>`. Force-checkout discards local working-tree edits.
5. **Configure** — we don't call Caligula's `configure.sh` (see §5.1), but we replicate its two essential commands (conan + cmake configure) with paths canonicalized via GNU `realpath`. Not in the timer.
6. **Timed compile**. `cmake --build` with the memstats sampler running. The compile timer wraps only this step.

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

Both repos are pinned to hardcoded SHAs in `build-caligula.sh`. Force-checked-out on every run — the local working tree's previous state is irrelevant to the pin.

| Repo | SHA | Pinned commit context |
|---|---|---|
| Caligula | `898f07d3bb140d9554b91da5f7a04d494523b4bd` | Merge of `fix/filters-journal-panel` into `develop` (2026-06-02) |
| cw | `b9905ff34a25adcba34cdf9d2a5f452b7056d06d` | Merge of `caligula/fix/nojira-wrong-conanfile` into `caligula/develop` (2026-06-02) |

**Clone URLs**:
- `git@gitlab.build.paradox-interactive.com:gsg/caligula/caligula.git`
- `git@gitlab.build.paradox-interactive.com:gsg/tech/cw.git`

**Why pin**: cross-machine numbers are only comparable if the source is identical. Pinning removes one variable from the comparison. When the benchmark is re-run weeks later, the same compile workload is exercised.

**Re-pinning.** When you want to benchmark a different Caligula commit (e.g. after a major feature lands), pick the matching cw commit and update both `CALIGULA_REV` and `CW_REV` constants near the top of `build-caligula.sh`. Commit + push. Subsequent runs on any test machine will fetch and use the new pin.

**Choosing matching cw commits**: cw has a `caligula/develop` branch tracking Caligula's `develop`. When picking a new Caligula commit, use the cw commit that was Caligula's tip-of-`caligula/develop` at the time the Caligula commit was created. The two branches are co-developed — usually you can read the cw commit from Caligula's `cw_version.txt` or similar pin file, or from the conan lockfile.

**Caveat**: this script's pin doesn't verify cw and Caligula are version-compatible. If you point at mismatched commits, the conan install or cmake configure will fail loudly during Phase 5.

## 5. Design decisions

Substantive choices, recorded so that a later reviewer (or yourself, six months from now) understands the trail. Some of these were corrections to broken first attempts — flagged where applicable.

### 5.0 Fetch + pin from internal GitLab (revised 2026-06-02)

**This harness was originally designed to wrap a local working tree** without fetching. The rationale was: the user owns the source, doesn't want their working-tree forcibly modified, and pinning would constrain their workflow.

**That design didn't survive the test-machine use case.** A test machine inside the VPN doesn't have Caligula source on disk and has no convenient way to get it — engineers shouldn't have to manually clone before running a benchmark harness. So as of 2026-06-02 the harness clones from internal GitLab (`gsg/caligula/caligula` and `gsg/tech/cw`) on first run and pins both to hardcoded SHAs.

**Implications**:

- **VPN is now a hard requirement.** Without SSH access to `gitlab.build.paradox-interactive.com`, Phase 3 fails. This is documented in §1 / §7.
- **Force-checkout discards local edits.** If you run this harness on your dev laptop while you have working-tree changes in `$CALIGULA_DIR` or `$CW_DIR`, those changes will be lost. The harness `warn`s before each force-checkout. If you need to preserve dev edits, run `git stash` in both trees first, or run the benchmark on a separate machine.
- **Cross-machine comparisons are now first-class.** Any machine with VPN access can run the harness and produce numbers directly comparable to other machines — same source, same pin, same flags.

The previous "no source pin" design (§4 in the prior SPEC revision) is gone. See git history of `build-caligula.sh` if you need to recover the pre-clone behavior.

### 5.0a Relationship to batmake (the canonical CI build flow)

Caligula and the rest of the Paradox game pipeline are normally built via **batmake** (`gsg/build/batmake`), a Python `invoke`-based build orchestrator. The `.gitlab-ci.yml` calls `batmake build` and batmake does the heavy lifting: clone cw, set environment variables, run cmake configure + build, archive, sign binaries, upload symbols, post Slack notifications. The `-D` flags / `$env{...}` substitutions / preset choices that make a CI build succeed mostly come from batmake's orchestration, not from the user typing them by hand.

**batmake's compile-relevant flow:**

1. **`batmake environment.set_vars`** (`batmake/tasks/environment.py:47-54`) — sets these env vars before cmake is invoked:
   - `EXTERNAL_LIBS_PATH` (feeds `NEW_EXTERNAL_LIBS_DIR=$env{EXTERNAL_LIBS_PATH}`)
   - `BINARY_OUTPUT_DIR` (feeds `PDX_BUILD_OUTPUT_DIRECTORY=$env{BINARY_OUTPUT_DIR}`)
   - `CC=clang` / `CXX=clang++` on Linux/Darwin
2. **`batmake build.generate`** — `cmake -S <workspace> --preset <configure-preset> -L` plus any `BATMAKE_CMAKE_FLAGS` env appended.
3. **`batmake build.build`** — `cmake --build --preset <build-preset>`. Uses **build presets** (the separate `buildPresets` section in `CMakePresets.json`), which carry parallelism and target settings.

Once the env vars are set, `buildserver-vars`'s `$env{...}` substitutions resolve to real paths, the rest of the cw bootstrap chain works without complaint, and no manual `-D` overrides are needed (in CI's controlled environment).

**Why this harness sidesteps batmake:**

- **Compile-timer scope.** We time only `cmake --build`. batmake's timer would include configure, conan install, archive, symbol upload, etc. We deliberately exclude those — see §5.6.
- **Memstats correlation.** We need every line of compile output prefixed `[HH:MM:SS]` for the sampler to be analysable (§5.8). batmake's logging format doesn't add per-line wall-clock.
- **No archive / symbol / Slack steps.** batmake does a lot of post-build work we don't want for a benchmark.
- **Direct parallelism control.** batmake reads parallelism from the build preset; we want a uniform `JOBS` knob across all four harnesses.

**Net effect of bypassing batmake**: the harness has to perform the env-var setup batmake would have done, AND it has to override several preset cache variables that `buildserver-vars` assumes were filled in by env-var substitution OR that CI's controlled host environment happens to satisfy. The current overrides break down like this:

| Mechanism | What it does | batmake equivalent | Why we still need it on top of batmake's parity |
|---|---|---|---|
| `export BINARY_OUTPUT_DIR` env | Feeds the preset's `$env{BINARY_OUTPUT_DIR}` substitution | `batmake/tasks/environment.py:47` sets the same env | — fully aligned with batmake |
| `export EXTERNAL_LIBS_PATH` env | Feeds `$env{EXTERNAL_LIBS_PATH}` substitution | `environment.py:48` sets the same env | — aligned; no-op under conan |
| `export CC=clang` / `CXX=clang++` env | Makes the toolchain explicit | `environment.py:53-54` sets the same env on macOS/Linux | — aligned |
| `-DCW_BASE_DIR=<relative>` | Override `buildserver-vars`'s `CW_BASE_DIR=cw` default | batmake doesn't override; CI checks cw out as a subdir of the workspace so the preset's default works | We clone cw as a sibling, not a subdir — different layout (§5.2b) |
| `-DPDX_ENABLE_AUDIT_DEPRECATED=ON` | Disables clausewitz's `-Werror` | batmake doesn't set this; CI runs with `-Werror` on | macOS APFS case-insensitivity disagreement (§5.2) |
| `-DCMAKE_POLICY_DEFAULT_CMP0148=OLD` | Restores legacy `FindPythonInterp` module | batmake doesn't set this; CI uses an older cmake | CMake 3.27+ default removes the legacy module (§5.2e) |
| `-DPYTHON_EXECUTABLE=$(command -v python3)` | Skip cw's `find_package(PythonInterp)` lookup | batmake doesn't set this; CI runners have `python` on PATH | Modern macOS only ships `python3`, not `python` (§5.2e) |
| `-DPDX_CONAN_UPLOAD=Off` | Disable conan-upload-after-install | batmake doesn't override; CI's runners are authenticated against artifactory and the buildserver-vars default `On` is correct | We don't publish from a benchmark machine and don't have artifactory creds set up (§5.2f) |

The four `-D` overrides that remain after the env-var alignment reflect host-configuration differences between CI runners and the typical engineer's macOS host — they're real workarounds, not architectural bypasses.

**When this section gets shorter**: when the cw pin moves to a commit whose recipes/cmake are tolerant of (a) sibling vs subdir cw, (b) case-insensitive APFS, (c) cmake 3.27+ defaults, (d) macOS systems without a `python` symlink. Until then, the four remaining overrides are the cost of running a benchmark outside batmake.

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

### 5.2b `-DCW_BASE_DIR=<relative-cw-path>` overrides preset-family default

Caligula's `ClausewitzBootstrap.cmake:73-74` does:
```cmake
set( CMAKE_PROJECT_INCLUDE_BEFORE ${CW_BASE_DIR}/clausewitz/build3/pre-project.cmake )
set( CMAKE_PROJECT_INCLUDE        ${CW_BASE_DIR}/clausewitz/build3/post-project.cmake )
```

`CW_BASE_DIR` is set by the chosen preset's parent-vars block:

| Preset family | parent `*-vars` | `CW_BASE_DIR` | Implied layout |
|---|---|---|---|
| `osx-clang-*` (user-presets variants) | `local-vars` | `../cw` | cw is a sibling of `$CALIGULA_DIR` |
| `buildserver-osx-clang-*` | `buildserver-vars` | `cw` | cw is a subdir of `$CALIGULA_DIR` |

Our harness clones cw as a sibling (default `$HOME/projects/cw`, sibling of `$HOME/projects/Caligula`) regardless of preset. Under the buildserver preset the default `cw` is wrong — cmake fails with `project could not find requested file: cw/clausewitz/build3/pre-project.cmake` before `project()` even runs.

Fix: pass `-DCW_BASE_DIR="<relative-path>"` on the cmake command line, computed via `realpath --relative-to="$caligula_canonical" "$cw_canonical"`. For the standard sibling layout that's `../cw`; for other layouts it's whatever path traverses from `$CALIGULA_DIR` to `$CW_DIR`. The relative form satisfies two consumers that disagree on whether `CW_BASE_DIR` is absolute or relative:

- **`ClausewitzBootstrap.cmake:73`** — `set(CMAKE_PROJECT_INCLUDE_BEFORE ${CW_BASE_DIR}/...)`. CMake 3.27+ resolves relative `CMAKE_PROJECT_INCLUDE_BEFORE` paths against `CMAKE_SOURCE_DIR`. Both absolute and relative work here.
- **Caligula's `conanfile.py`** — does `f"{caligula_source}/{CW_BASE_DIR}"` (string interpolation, NOT `os.path.join`). With an absolute `CW_BASE_DIR` this produces a malformed double-rooted path like `/Users/.../Caligula//Users/.../cw/` and conan reports "Clausewitz dir not found". A relative `CW_BASE_DIR` concatenates correctly to a real path.

We initially passed the absolute `$cw_canonical`, which satisfied cmake but broke the conanfile. The current relative form satisfies both.

**Why this is fragile**: any code path that joins `CW_BASE_DIR` with a *different* anchor than CALIGULA's source dir would compute the wrong location. If a future cw revision starts using `CW_BASE_DIR` somewhere new and that new use case expects an absolute path, we'll have to split the variable. For now the single relative value works.

Aside: `ADDITIONAL_BASE_DIR` is set by `configure.sh` and our harness copies that line, but **no cmake code in the tree actually reads `ADDITIONAL_BASE_DIR`** as of the pinned cw commit. It's dead pass-through. Left in place defensively in case a future cw revision reintroduces a consumer; safe to remove.

### 5.2c `export BINARY_OUTPUT_DIR` (and friends) before invoking cmake

**Historical note** (revised after reading batmake's source, see §5.0a): this section originally documented a `-DPDX_BUILD_OUTPUT_DIRECTORY` `-D` override that worked around a broken cmake-cache fallback. The proper fix — and the one this harness now uses — is to set the **environment variable** the preset expects, matching what `batmake/tasks/environment.py:47-54` does in CI. The end result is identical (`PDX_BUILD_OUTPUT_DIRECTORY` ends up as a real path) but takes the batmake-canonical path rather than going around the preset.

`buildserver-vars` defines `PDX_BUILD_OUTPUT_DIRECTORY=$env{BINARY_OUTPUT_DIR}`. CI sets `BINARY_OUTPUT_DIR`, so the preset substitutes a real path. Our harness sets the same env var (`export BINARY_OUTPUT_DIR="$caligula_canonical/build"`) before invoking cmake. Plus `EXTERNAL_LIBS_PATH` and `CC`/`CXX` for completeness — matches batmake's three sets exactly.

**Original failure mode this prevents**: without `BINARY_OUTPUT_DIR` set, the preset substitutes an empty string into the cmake cache. `post-project.cmake:48-49` tries to fall back via `if (NOT VAR) set(VAR ... CACHE STRING ...)`, but cmake's `set(... CACHE STRING ...)` without `FORCE` doesn't overwrite an existing-but-empty cache entry. The variable stays empty. Then `post-project.cmake:95` does `get_filename_component( PDX_BUILD_OUTPUT_DIRECTORY ${PDX_BUILD_OUTPUT_DIRECTORY} REALPATH )` and the empty `${...}` expansion leaves only two args, which cmake rejects with `incorrect number of arguments`. Setting `BINARY_OUTPUT_DIR` env keeps the path non-empty all the way through.

**Why the env-var path is preferred over a `-D` override**: feeding the preset what it expects rather than overriding its derived variable means we ride on the same substitution machinery CI uses. If cw changes how `PDX_BUILD_OUTPUT_DIRECTORY` is computed (different formula, different cache type, different fallback), the env-var approach continues to work; the `-D` approach would need to be re-aligned.

### 5.2d Conan version range: pinned cw needs Conan ≤ 2.16-ish

The pinned cw commit (`b9905ff3…`) references `pdx_conanrecipes/6.1.2@internal`, which contains lines like:

```python
from conans.errors import ConanException
```

That's the **Conan 1.x** module namespace (`conans` with a trailing 's'). Conan 2.x renamed everything to `conan.*` (no 's') and shipped a deprecation-period compatibility shim that kept `conans.*` working for several minor versions. The shim was **removed around Conan 2.17**. Newer Conan 2 — including the current Homebrew default (2.29.0 as of writing) — fails with:

```
ModuleNotFoundError: No module named 'conans.errors'
```

The harness can't patch the pinned cw recipe (that would defeat the SHA pin), so the user-side workaround is to pin Conan version.

| Conan version | Status |
|---|---|
| 1.x | Native — works (no compat shim needed) |
| 2.0 – ~2.16 | Compat shim active — works |
| 2.17+ (incl. 2.29.0 / Homebrew default) | Compat shim removed — breaks |

**Known working**: 2.4.1 (the dev laptop's version). **Known broken**: 2.29.0 (the test iMac Pro's brew-installed version).

**Fix on the consumer side**:

```sh
brew uninstall conan
pip3 install --user conan==2.4.1
# or: pipx install conan==2.4.1
```

The harness `verify()` step warns when the installed conan version looks problematic (Conan 2.17+) but does not fail or auto-install at that point. If conan is **completely missing**, the `rescue()` step does offer to `pip3 install --user conan==2.4.1` (after confirmation) — but explicitly does NOT offer `brew install conan` for this dep, because the current Homebrew conan formula is exactly the broken-on-our-recipes version. Auto-installing python tooling has more side effects than `brew install`, hence the confirmation prompt.

**PATH detection for pip-user installs**: `pip3 install --user` puts the `conan` binary in `~/Library/Python/X.Y/bin/`, which is **not** on the default macOS PATH. The harness handles this via `prepend_python_user_bin()` which runs `python3 -m site --user-base` to find the canonical user-install prefix and prepends `<prefix>/bin` to PATH at script start. Without this, `check_bin conan` would still report "missing" after a successful `pip install --user conan`, leading to the confusing rescue loop seen on the iMac Pro test machine where the user pip-installed conan but the harness then asked to brew install it.

**When to revisit**: when the cw pin moves forward to a commit whose `pdx_conanrecipes` version is conan-2-clean (no `conans.*` imports), this constraint goes away. Until then, the conan version is part of the benchmark's input contract.

### 5.2e Python-find-package compatibility: two overrides side by side

cw's `clausewitz/build3/include/clausewitz_tokens.cmake:1-7` does:

```cmake
if ( NOT PYTHON_EXECUTABLE )
    find_package( PythonInterp QUIET )
    if ( NOT PYTHON_EXECUTABLE )
        PdxFatalMessage( "TokenGeneration requires Python to be installed." )
    endif()
endif()
```

Two independent reasons this can fail on modern macOS:

1. **CMP0148 (CMake 3.27+ policy)** — under NEW behavior the legacy `FindPythonInterp` / `FindPythonLibs` modules are **removed entirely**. `find_package(PythonInterp)` errors before searching. The dev laptop's slightly-older cmake didn't trigger this; the iMac Pro's Homebrew cmake did.

2. **No `python` binary on PATH** — legacy `FindPythonInterp` looks for an executable named `python` (no version suffix). Modern macOS only ships `python3`. pyenv adds a `python` shim, which is why the dev laptop builds work; the iMac Pro has only `/usr/bin/python3` and `where python` returns nothing.

The harness applies two `-D` overrides:

- `-DCMAKE_POLICY_DEFAULT_CMP0148=OLD` — restores the legacy module so `find_package(PythonInterp)` doesn't fail-fast.
- `-DPYTHON_EXECUTABLE="$(command -v python3)"` — sidesteps the find_package call entirely (the `if (NOT PYTHON_EXECUTABLE)` guard skips it when the variable is pre-set). Belt and suspenders.

Either alone might suffice on some machines; together they cover both failure modes regardless of cmake version or system Python layout.

**When this goes away**: when the cw pin moves forward to a commit whose token-generation cmake uses `find_package(Python3 COMPONENTS Interpreter)` (or similar), both overrides become unnecessary. Until then they're part of the harness's input contract.

### 5.2f `-DPDX_CONAN_UPLOAD=Off` skips the CI-only artifactory upload

`CMakePresets.json:67` (inside `buildserver-vars`) sets `PDX_CONAN_UPLOAD=On`. `pdx_conan.cmake:184` then guards a post-install block that:

1. Runs `conan list -f json -g conan-graph.json` against the just-installed dependency set.
2. Runs `conan upload --list conan-list.json -r artifactory-local-v2 -c` to push built packages back to the shared cache.

In CI this is desirable: the runner is Vault-authenticated against artifactory and uploading rebuilds keeps the shared cache warm for downstream pipelines. On a benchmark machine it's unwanted: we have no artifactory credentials, no need to publish, and the upload step fails with `Please log in to "artifactory-local-v2"` once it reaches the auth step.

`local-vars`-derived presets leave `PDX_CONAN_UPLOAD` at the `Off` default (declared in `cw/clausewitz/build3/include/pdx_conan.cmake:25`), which is why builds with the previous default preset (`osx-clang-ReleaseLto`, user-presets variant) didn't trip it.

Fix: `-DPDX_CONAN_UPLOAD=Off` on the cmake command line. The upload block's `if (PDX_CONAN_UPLOAD)` guard short-circuits; conan install completes normally; the build moves on to the compile step.

**Authentication reference (if you ever do need it)**: Vault path `shared/artifactory_api_key_cloud/token@bat`, field `conan_account_token` (see `batmake/batmake/pdx_artifactory.py:22-34`). Alternatively a personal API key from `https://pdx.jfrog.io` → User Profile → Generate API Key, then `conan remote login artifactory-local-v2 <paradox-username> -p <api-key>`. Both are out of scope for this benchmark harness.

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

### 5.9 Single timestamp variable shared between log files

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
- Caligula at the commit checked out on 2026-06-01 (now pinned at `898f07d3…`; see §4)
- Conan packages already cached locally (first-ever run would take longer)
- Cold-build (`--clean`)
- Preset: `osx-clang-ReleaseLto` (the developer-only `CMakeUserPresets.json` variant). The harness now defaults to `buildserver-osx-clang-ReleaseLto`, which is in canonical `CMakePresets.json` and is also what CI uses. The two presets compile the same source with the same flags — they differ only in build-output-dir conventions — so the workload is functionally identical. **Strictly speaking the §9 baseline numbers should be re-validated on the reference rig under the new default preset before being treated as canonical for the new harness.** Expected delta: <5%.

To compare another machine's profile against this baseline, match these conditions. Specifically: same arch, same JOBS, same Caligula commit, same preset. Mismatched arch (Intel vs Apple Silicon) renders the comparison meaningless.

### 7.3 Page-rate caveat

Caligula's measured peak pageout rate is 380 pages/sec — well above Chromium's 95 pages/sec at its JOBS=3 crash, yet Caligula survives. The threshold for "imminent SIGSEGV from disk-pager saturation" suggested in chromium SPEC §9 (~1000 pages/sec) is consistent with Caligula's survival — Caligula peaks burstily but doesn't sustain. If you see Caligula's pageout rate climb above ~800 pages/sec on a different machine, expect instability and lower JOBS.

### 7.4 LTO link share is 0.1% — don't over-index on it

Caligula's measured LTO link share is essentially zero. Thin-LTO distributes the work across per-library link steps; the final exec link is 2 seconds out of 1593. **Implication for machine ranking**: link throughput (single-thread CPU, disk IO) is NOT a meaningful differentiator for Caligula-class builds. Compile parallelism is. A machine optimised for fast LTO links but slow compile parallelism would rank poorly on this workload despite being "fast at linking" in isolation.

### 7.5 What this harness is NOT for

- Not for measuring whether a *given* Caligula commit compiles correctly (use the user's interactive `./build.sh` for that — it picks up `compdb` regeneration which we skip).
- Not for measuring conan-install performance — that's outside the timer.
- Not for shipping binaries — `-DPDX_ENABLE_AUDIT_DEPRECATED=ON` is set, so warnings aren't fatal. A real release build should run with `-Werror` on.
- **Not for running on machines outside the Paradox VPN.** SSH clone of internal GitLab fails. Use the LLVM harness on rented cloud Macs instead.
- **Not safe to run when you have in-progress edits in `$CALIGULA_DIR` or `$CW_DIR`.** Phase 4's `git checkout --force --detach` discards them. Stash first.

## 8. Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Phase 1 reports missing `cmake`/`ninja`/`conan` | Fresh machine | Allow rescue (omit `--no-rescue`) |
| Phase 1 reports `readlink -m: missing` | Coreutils not installed or not findable | `brew install coreutils` |
| Phase 3 `git clone` hangs or fails with `Permission denied (publickey)` | SSH key not configured for gitlab.build.paradox-interactive.com | Add your SSH key to your GitLab profile; verify with `ssh -T git@gitlab.build.paradox-interactive.com` |
| Phase 3 `git clone` fails with `Could not resolve hostname` | Not connected to Paradox VPN | Connect to VPN and re-run |
| Phase 4 fetch fails: `fatal: unable to access … <SHA> not our ref` | The pinned SHA isn't reachable from default branch | Verify the SHA is still in the remote (`git ls-remote origin \| grep <SHA-prefix>`); if not, re-pin |
| Phase 5 conan install fails: `…/clausewitz/conan/config/: No such directory` | cw clone or pin failed silently; cw tree is empty or mis-pinned | Re-run; if persistent, verify the cw commit matches Caligula's expected pin |
| Phase 5 conan install fails: `[Errno 13] Permission denied: '$HOME/.conan2/extensions/plugins/compatibility/compatibility.py'` | Specific to some Paradox virtual macOS CI runners: the gitlab-runner executor runs as **root** while operating inside the CI user's `$HOME`. The first conan invocation creates `~/.conan2/` files owned by root; subsequent non-root invocations (or a different CI user) can't write them during a migration step. Outside CI, the same symptom can come from a prior `sudo conan …` or `sudo pip install conan` | `sudo chmod -R u+rwX "$HOME/.conan2" && sudo chown -R $(whoami) "$HOME/.conan2"` and re-run. For CI, fix by configuring the runner to execute as the CI user (not root) or by chowning the conan cache in a pre-build step |
| `cmake configure` fails: `No such preset in …: "<name>"` and prints available presets | The preset isn't in canonical `CMakePresets.json` — it's a per-user `CMakeUserPresets.json` entry on the originating machine | Switch to a canonical preset (`buildserver-osx-clang-ReleaseLto` etc.) via `--preset` or env, or copy the matching `CMakeUserPresets.json` from the originating dev machine |
| `cmake configure` fails: `project could not find requested file: cw/clausewitz/build3/pre-project.cmake` | The preset's parent-vars block sets `CW_BASE_DIR=cw` (subdir layout) but our harness clones cw as a sibling. Should be overridden by `-DCW_BASE_DIR=<relative-cw-path>` in `configure_phase` | Verify `cmake configure …, -DCW_BASE_DIR=…` log line shows the relative path (`../cw` for the standard sibling layout). See §5.2b |
| `cmake configure` fails inside conan: `Clausewitz dir "/path/to/Caligula//path/to/cw/" not found` (note double-slash) | We initially passed `CW_BASE_DIR=<absolute>`, but the conanfile uses string interpolation `f"{source}/{CW_BASE_DIR}"` which produces double-rooted nonsense. Should be a relative path | Verify `cmake configure …, -DCW_BASE_DIR=<relative>` log line. See §5.2b |
| `cmake configure` fails inside `post-project.cmake` at line 95: `get_filename_component called with incorrect number of arguments` | `PDX_BUILD_OUTPUT_DIRECTORY` ended up empty in the cmake cache (from `buildserver-vars` referencing `$env{BINARY_OUTPUT_DIR}` which CI sets but local doesn't); the fallback in post-project.cmake:48-49 doesn't fire because `set(... CACHE STRING ...)` without FORCE can't overwrite an empty cache entry | Verify `cmake configure …, -DPDX_BUILD_OUTPUT_DIRECTORY=…` log line shows the absolute path. See §5.2c |
| Phase 5 conan install fails: `ModuleNotFoundError: No module named 'conans.errors'` | Pinned `pdx_conanrecipes/6.1.2` uses Conan-1-style imports (`conans.errors`); the compat shim was removed in newer Conan 2 versions (~2.17+); affects Homebrew's current conan (2.29.0 as of writing) | Pin conan to a version with the shim: `brew uninstall conan && pip3 install --user conan==2.4.1` (or `pipx install conan==2.4.1`). See §5.2d for the full version-range matrix |
| Phase 5 cmake fails: `[ERROR] TokenGeneration requires Python to be installed` (with a CMake Warning about CMP0148) | CMake 3.27+ defaults policy CMP0148 to NEW, which removes the legacy `FindPythonInterp` module that cw's token generator still calls | Already overridden in the harness via `-DCMAKE_POLICY_DEFAULT_CMP0148=OLD`. Verify the log line. See §5.2e |
| Phase 5 cmake fails: `[ERROR] TokenGeneration requires Python to be installed` (WITHOUT a CMP0148 warning) | Legacy `FindPythonInterp` is available but can't find an executable named `python` on PATH (system only has `python3`; no pyenv shim) | Already overridden via `-DPYTHON_EXECUTABLE=$(command -v python3)`. Verify the log line shows `-DPYTHON_EXECUTABLE=…`. See §5.2e |
| Phase 5 conan upload prompts for login: `Please log in to "artifactory-local-v2"` | `buildserver-vars` preset sets `PDX_CONAN_UPLOAD=On` expecting CI's Vault-derived artifactory auth | Already overridden via `-DPDX_CONAN_UPLOAD=Off`. Verify the cmake configure log line. See §5.2f for the auth-reference if you actually need to upload (rare for a benchmark) |
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

Caligula source tree lives at `$CALIGULA_DIR` (default `$HOME/projects/Caligula`); Clausewitz engine at `$CW_DIR` (default `$HOME/projects/cw`). Neither is part of this repo — they are cloned from internal GitLab by the harness on first run and force-checked-out to the pinned SHAs (see §4) on every subsequent run. If you keep a dev tree at either location, expect its working state to be discarded each time the harness runs.

## 11. Relation to the other harnesses

| Harness | Source | Pin | VPN required | Purpose |
|---|---|---|---|---|
| `caligula-build-benchmark/` | Internal GitLab clone (proprietary) | Hardcoded SHAs in script | **Yes** | **Ground-truth reference profile** |
| `llvm-build-benchmark/` | `llvm/llvm-project` clone | `llvmorg-22.1.7` | No | **Canonical publishable benchmark** |
| `ogre3d-build-benchmark/` | `OGRECave/ogre` clone | `v14.5.2` | No | Lighter smoke-test candidate (too light by 64×) |
| `godot-build-benchmark/` | `godotengine/godot` clone | `4.6.3-stable` | No | Heavier smoke-test candidate (too light by 8.6×) |
| `chromium-build-benchmark-for-mac/` | `chromium/src` clone | Per-target SHAs | No | Archived; crashes at JOBS≥2 on 24 GB |

The chromium harness is archived — it crashes reliably at JOBS≥2 on the reference 24 GB machine, making cross-machine comparison infeasible. Its SPEC.md (`~/projects/chromium-build-benchmark-for-mac/SPEC.md`) remains the canonical document on macOS VM-tier failure modes (§9), which the other three SPECs reference rather than duplicate.
