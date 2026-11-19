# Prebuilt static OpenSSL

This branch builds and publishes **static** OpenSSL libraries (`libcrypto`, `libssl`) for a
fixed set of target triples. Sources always come from the OpenSSL release tag being built, so
the artifacts are unpatched upstream builds.

## Assets

| item | value |
| --- | --- |
| name | `openssl-<version>-<suffix>.tar.gz` |
| root directory | the file name without `.tar.gz` |
| contents | the complete `make install` tree: `include/`, `lib/`, `bin/`, `ssl/`, plus `build-info.json` and `LICENSE.txt` |
| not pruned | engines, modules, cmake/pkgconfig and `applink.c` ship as install produces them |

The root directory has to match the file name: consumers extract with a plain `tar -xzf` and
link against `<root>/lib`, with headers from `<root>/include`.

Headers ship inside each bundle because `Configure` generates them; `configuration.h` is the
one header that differs per triple, the rest are identical.

`SHA256SUMS` is published next to the assets.

## Targets

| suffix | configure target | runner |
| --- | --- | --- |
| `linux-x86_64` | `linux-x86_64` | ubuntu-24.04 |
| `linux-ia32` | `linux-x86` | ubuntu-24.04 (gcc-multilib) |
| `linux-aarch64` | `linux-aarch64` | ubuntu-24.04 (cross) |
| `linux-armv4` | `linux-armv4` | ubuntu-24.04 (cross) |
| `android-arm64` | `android-arm64` | ubuntu-24.04 + NDK r28c, `-D__ANDROID_API__=24` |
| `android-arm` | `android-arm` | same |
| `android-x86_64` | `android-x86_64` | same |
| `android-x86` | `android-x86` | same |
| `macos-arm64` | `darwin64-arm64` | macos-14, `-mmacos-version-min=11.0` |
| `macos-x86_64` | `darwin64-x86_64` | macos-14, `-mmacos-version-min=10.15` |
| `ios-arm64` | `ios64-xcrun` | macos-14, `-mios-version-min=12.0` |
| `ios-simulator-arm64` | `iossimulator-arm64-xcrun` | macos-14, `-mios-simulator-version-min=14.0` |
| `ios-simulator-x86_64` | `iossimulator-x86_64-xcrun` | macos-14, `-mios-simulator-version-min=12.0` |
| `windows-x64` | `VC-WIN64A` | windows-2022, NASM x64 |
| `windows-ia32` | `VC-WIN32` | windows-2022, NASM x86 |
| `windows-arm64` | `VC-WIN64-ARM` | windows-11-arm (only image with the ARM64 toolset; this target needs no NASM) |

Each Apple floor is the lowest that slice builds at, fixed in the workflow rather than derived
from any consumer setting. `macos-arm64` and `ios-simulator-arm64` cannot go lower: clang
raises anything beneath them to 11.0 and 14.0. Without the flag the archive would inherit the
SDK default instead — the runner's own OS version — which older apps cannot link against.

## Build steps

Every bundle is produced by the same three steps:

1. `perl Configure <target> no-shared no-pinshared no-apps no-tests no-docs --prefix=<stage> --libdir=lib`
   plus the platform flags from the table above.
2. `build_libs` in parallel — `make -j<n>`, or `jom /J <n>` with `CL=... /FS` on Windows so
   parallel `cl` calls do not collide on `ossl_static.pdb`.
3. `install` (`jom install /J 1` on Windows, because the install rules rewrite `makefile` and
   cannot run concurrently). That install tree is what gets archived, unmodified.

A one-line program is linked against `libcrypto` before packaging, so an unusable archive fails
in CI instead of at the consumer.

## Running it

Dispatch **prebuilt** with `tag` (OpenSSL tag to build, e.g. `openssl-3.5.9`) and `release`
(the release to publish under). Re-running with the same release replaces the assets in place.
A push to this branch that touches `scripts/` or the workflow file builds it too.

Repository settings that cannot be committed:

1. **Actions enabled.** GitHub turns workflows off on forks of repositories that use a lot of
   Actions, and a maintainer has to re-enable them from the Actions tab. This branch carries a
   single workflow, so pushing here schedules exactly one run.
2. **Settings → Actions → General → Workflow permissions**: *Read and write*, so the release
   step can upload assets with `GITHUB_TOKEN`.
3. **Default branch = `prebuilt`**, otherwise GitHub shows no *Run workflow* button
   (`workflow_dispatch` is only listed for files on the default branch).

## Local build

```sh
SRC_DIR=~/src/openssl OUT_DIR=$PWD/out ./scripts/build.sh 3.5.9 linux-x86_64 linux-x86_64
SRC_DIR=~/src/openssl OUT_DIR=$PWD/out SMOKE_CMD="xcrun -sdk macosx cc" \
  ./scripts/build.sh 3.5.9 darwin64-arm64 macos-arm64 -mmacos-version-min=11.0
```

```powershell
.\scripts\build.ps1 -Version 3.5.9 -Target VC-WIN64A -Suffix windows-x64 -VcArch x64 -SrcDir .\src
```

Requires `perl`, `make` (or `jom` + `cl` + NASM on Windows), and Xcode for Apple targets.
