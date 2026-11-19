# Prebuilt static OpenSSL

This branch builds and publishes **static** OpenSSL libraries (`libcrypto`, `libssl`) for a
fixed set of targets. Sources always come from the OpenSSL release tag being built, so the
artifacts are unpatched upstream builds.

## Assets

| item | value |
| --- | --- |
| release | tag `openssl-3.5.9` becomes release tag `v3.5.9`, titled `OpenSSL v3.5.9` |
| asset | `openssl-<version>-<target>.tar.gz`, unpacking into a directory of that name |
| contents | the complete `make install` tree, nothing pruned: `include/`, `lib/` (libraries with pkgconfig and cmake metadata), `ssl/`, plus `build-info.json` and `LICENSE.txt` |
| checksums | `SHA256SUMS` next to the assets |

The archive root matches the file name, so consumers unpack with `tar -xzf` and link against
`<root>/lib` with headers from `<root>/include`. Headers ship inside every bundle because
`Configure` generates them; only `configuration.h` differs per target. A bundle holds no
`openssl` CLI: `no-apps` is passed to `Configure`, so there is nothing for `bin/` to carry.

## Targets

| asset suffix = configure target | name on the platform | build notes |
| --- | --- | --- |
| `linux-x86_64` | `x86_64` (Rust `x86_64-unknown-linux-gnu`) | ubuntu-latest |
| `linux-x86` | `i686` (`i686-unknown-linux-gnu`) | ubuntu-latest, `gcc-multilib` |
| `linux-aarch64` | `aarch64` (`aarch64-unknown-linux-gnu`) | ubuntu-latest, `gcc-aarch64-linux-gnu` |
| `linux-armv4` | `armv7l` (`armv7-unknown-linux-gnueabihf`), built at the ARMv4 baseline | ubuntu-latest, `gcc-arm-linux-gnueabihf` |
| `android-arm64` | `arm64-v8a` (clang `aarch64-linux-android24`) | ubuntu-latest + NDK r28c |
| `android-arm` | `armeabi-v7a` (`armv7a-linux-androideabi24`) | same |
| `android-x86_64` | `x86_64` | same |
| `android-x86` | `x86` | same |
| `darwin64-arm64` | `arm64`, macOS | macos-latest, `-mmacos-version-min=10.15` |
| `darwin64-x86_64` | `x86_64`, macOS | macos-latest, same floor |
| `ios64-xcrun` | `arm64`, device | macos-latest, `-mios-version-min=12.0` |
| `iossimulator-arm64-xcrun` | `arm64`, simulator | macos-latest, `-mios-simulator-version-min=12.0` |
| `iossimulator-x86_64-xcrun` | `x86_64`, simulator | macos-latest, same floor |
| `VC-WIN64A` | `x64` | windows-latest, NASM x64 |
| `VC-WIN32` | `x86` / `Win32` | windows-latest, NASM x86 |
| `VC-WIN64-ARM` | `arm64` | windows-11-arm, no NASM |

The suffix is the Configure target verbatim, so Apple and Windows assets carry OpenSSL's own
vocabulary (`darwin64-arm64`, `ios64-xcrun`, `VC-WIN64A`) rather than a separate naming scheme.
The *name on the platform* column is what that platform's toolchain asks for, which is the
mapping a consumer needs: `linux-x86_64` is `x86_64`, `linux-x86` is `i686`, `android-arm` is
`armeabi-v7a`, `VC-WIN64A` is `x64`. Libraries are `libcrypto.a` and `libssl.a` everywhere
except Windows, where they are `libcrypto.lib` and `libssl.lib`.

Each Apple platform gets one floor: iOS 12.0, macOS 10.15. `darwin64-arm64` and
`iossimulator-arm64-xcrun` cannot be built that low, so clang raises them to 11.0 and 14.0 and
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

Nothing is compiled twice and nothing is pruned: a script configures, builds the libraries,
installs, then packs the install tree. One script per platform, every input on the command line:

| script | arguments |
| --- | --- |
| `scripts/build-linux.sh` | `<tag> <target> <src-dir> <out-dir>` |
| `scripts/build-android.sh` | `<tag> <target> <api> <src-dir> <out-dir>` |
| `scripts/build-macos.sh` | `<tag> <target> <version> <src-dir> <out-dir>` |
| `scripts/build-ios.sh` | `<tag> <target> <version> <src-dir> <out-dir>` |
| `scripts/build-windows.ps1` | `-Tag -Target -SrcDir -OutDir` |

What each script adds beyond the two inputs follows from its platform: Linux cross targets pass
their `--cross-compile-prefix`, Android passes the API level it was given, macOS passes
`-mmacos-version-min=`, iOS passes `-mios-version-min=` or `-mios-simulator-version-min=` by
looking at the target, and Windows picks the MSVC architecture from the target
(`VC-WIN32` → `x86`, `VC-WIN64A` → `x64`, `VC-WIN64-ARM` → `arm64`). In the workflow the
Android API level and the two Apple floors live in each job's `env` (`API`, `TARGET_VERSION`).

The version in the asset name is the tag without its `openssl-` prefix.

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
./scripts/build-linux.sh openssl-3.5.9 linux-x86_64 ~/src/openssl ./out
./scripts/build-android.sh openssl-3.5.9 android-arm64 24 ~/src/openssl ./out
./scripts/build-macos.sh openssl-3.5.9 darwin64-arm64 10.15 ~/src/openssl ./out
./scripts/build-ios.sh openssl-3.5.9 iossimulator-arm64-xcrun 12.0 ~/src/openssl ./out
```

```powershell
.\scripts\build-windows.ps1 -Tag openssl-3.5.9 -Target VC-WIN64A -SrcDir .\src -OutDir .\out
```

The runner image ships only a native `gcc`, so the three cross-compiled Linux targets install
their toolchain with `apt` first: `gcc-multilib`, `gcc-aarch64-linux-gnu`, `gcc-arm-linux-gnueabihf`.
Android compilers come from the NDK download; Apple targets use the preinstalled Xcode.

Unix needs `perl` and `make`. On Windows OpenSSL's `VC-*` targets invoke MSVC's `cl` directly,
so `cl` plus its `INCLUDE`/`LIB` environment has to be present: run
`VsDevCmd.bat -arch=<arch>` from a Visual Studio installation — the same script behind the
"Developer Command Prompt" shortcut — and install `jom`, plus NASM for the x86/x64 targets.
Apple targets need Xcode.
