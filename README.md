# Prebuilt static OpenSSL

This branch builds and publishes **static** OpenSSL libraries (`libcrypto`, `libssl`) for a
fixed set of targets. Sources always come from the OpenSSL release tag being built, so the
artifacts are unpatched upstream builds.

## Assets

| item | value |
| --- | --- |
| release | tag `openssl-3.5.9` becomes release tag `v3.5.9`, titled `OpenSSL v3.5.9` |
| asset | `openssl-<version>-<suffix>.tar.gz`, unpacking into a directory of that name |
| contents | the complete `make install` tree, nothing pruned: `include/`, `lib/` (libraries with pkgconfig and cmake metadata), `ssl/`, plus `build-info.json` and `LICENSE.txt` |
| checksums | `SHA256SUMS` next to the assets |

The archive root matches the file name, so consumers unpack with `tar -xzf` and link against
`<root>/lib` with headers from `<root>/include`. Headers ship inside every bundle because
`Configure` generates them; only `configuration.h` differs per target. A bundle holds no
`openssl` CLI: `no-apps` is passed to `Configure`, so there is nothing for `bin/` to carry.

## Targets

| suffix | configure target | runner |
| --- | --- | --- |
| `linux-x86_64` | `linux-x86_64` | ubuntu-latest |
| `linux-ia32` | `linux-x86` | ubuntu-latest (gcc-multilib) |
| `linux-aarch64` | `linux-aarch64` | ubuntu-latest (cross) |
| `linux-armv4` | `linux-armv4` | ubuntu-latest (cross) |
| `android-arm64` | `android-arm64` | ubuntu-latest + NDK r28c, `-D__ANDROID_API__=24` |
| `android-arm` | `android-arm` | same |
| `android-x86_64` | `android-x86_64` | same |
| `android-x86` | `android-x86` | same |
| `macos-arm64` | `darwin64-arm64` | macos-latest, `-mmacos-version-min=10.15` |
| `macos-x86_64` | `darwin64-x86_64` | macos-latest, `-mmacos-version-min=10.15` |
| `ios-arm64` | `ios64-xcrun` | macos-latest, `-mios-version-min=12.0` |
| `ios-simulator-arm64` | `iossimulator-arm64-xcrun` | macos-latest, `-mios-simulator-version-min=12.0` |
| `ios-simulator-x86_64` | `iossimulator-x86_64-xcrun` | macos-latest, `-mios-simulator-version-min=12.0` |
| `windows-x64` | `VC-WIN64A` | windows-latest, NASM x64 |
| `windows-ia32` | `VC-WIN32` | windows-latest, NASM x86 |
| `windows-arm64` | `VC-WIN64-ARM` | windows-11-arm (no ARM64 MSVC toolset elsewhere; this target needs no NASM) |

Each Apple platform gets one floor: iOS 12.0, macOS 10.15. `macos-arm64` and
`ios-simulator-arm64` cannot be built that low, so clang raises them to 11.0 and 14.0 and
`LC_BUILD_VERSION` records the raised value. Without the flags every object would inherit the
SDK default, i.e. the runner's own OS version.

## Build steps

Every bundle comes from the same three steps:

1. `perl Configure <target> no-shared no-pinshared no-apps no-tests no-docs --prefix=<stage> --libdir=lib`
   plus the platform flags from the table above.
2. `build_libs` in parallel — `make -j<n>`, or `jom /J <n>` with `CL=... /FS` on Windows so
   parallel `cl` calls do not collide on `ossl_static.pdb`.
3. `install` (`jom install /J 1` on Windows, because the install rules rewrite `makefile` and
   cannot run concurrently). That install tree is archived unmodified.

A one-line program is linked against `libcrypto` before packaging, so an unusable archive fails
in CI instead of at the consumer. The version in the asset name is the tag without its
`openssl-` prefix.

## Running it

The workflow takes a single input, `tag` — the OpenSSL tag to build, default `openssl-3.5.9`.
It publishes to the release `v<version>` titled `OpenSSL v<version>`, so re-running with the
same tag replaces the assets in place.

```sh
# UI     Actions -> release -> Run workflow (pick the branch, override the tag if needed)
# CLI
gh workflow run release.yml --ref release -f tag=openssl-3.5.9
# REST
curl -X POST -H "Authorization: Bearer $TOKEN" \
  https://api.github.com/repos/invictus-dart/openssl/actions/workflows/release.yml/dispatches \
  -d '{"ref":"release","inputs":{"tag":"openssl-3.5.9"}}'
```

Only `workflow_dispatch` starts this workflow; pushing to the branch does not.

Repository settings that cannot be committed:

1. **Actions enabled.** GitHub turns workflows off on forks of repositories that use a lot of
   Actions, and a maintainer has to re-enable them from the Actions tab.
2. **Workflow permissions = Read and write** (*Settings → Actions → General*). The publish job
   creates the release with `GITHUB_TOKEN`, which is read-only otherwise; an organization
   policy above the repository can block this setting.
3. **Default branch = `release`**, otherwise GitHub shows no *Run workflow* button
   (`workflow_dispatch` is only listed for files on the default branch).

## Local build

```sh
SRC_DIR=~/src/openssl OUT_DIR=$PWD/out ./scripts/build.sh 3.5.9 linux-x86_64 linux-x86_64
SRC_DIR=~/src/openssl OUT_DIR=$PWD/out SMOKE_CMD="xcrun -sdk macosx cc" \
  ./scripts/build.sh openssl-3.5.9 darwin64-arm64 macos-arm64 -mmacos-version-min=10.15
```

```powershell
.\scripts\build.ps1 -Tag openssl-3.5.9 -Target VC-WIN64A -Suffix windows-x64 -VcArch x64 -SrcDir .\src
```

Unix needs `perl` and `make`. On Windows OpenSSL's `VC-*` targets invoke MSVC's `cl` directly,
so `cl` plus its `INCLUDE`/`LIB` environment has to be present: run
`VsDevCmd.bat -arch=<arch>` from a Visual Studio installation — the same script behind the
"Developer Command Prompt" shortcut — and install `jom`, plus NASM for the x86/x64 targets.
Apple targets need Xcode.
