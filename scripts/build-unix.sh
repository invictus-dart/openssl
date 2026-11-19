#!/usr/bin/env bash
# Builds one prebuilt OpenSSL bundle for a single target triple.
#
# Usage: build-unix.sh <version> <configure-target> <asset-suffix> [configure args...]
#
# Result: $OUT_DIR/openssl-<version>-<asset-suffix>.tar.gz whose root directory
# carries the same name, holding include/openssl/*.h, lib/libcrypto.a,
# lib/libssl.a, build-info.json and LICENSE.txt.
#
# Environment:
#   SRC_DIR    openssl source tree (required)
#   OUT_DIR    output directory (default: ./out)
#   CC/AR/RANLIB   cross toolchain overrides; unset means the target's defaults
#   SMOKE_CMD      shell command that compiles the smoke test, e.g.
#                  "xcrun -sdk iphoneos cc -arch arm64" (default: CC or cc)
#   SMOKE_LDFLAGS  extra flags appended to the smoke link line
#   SMOKE_RUN      "1" links *and* runs the smoke test (native builds only)
set -euo pipefail

version=${1:?version}
target=${2:?configure target}
suffix=${3:?asset suffix}
shift 3

src=${SRC_DIR:?SRC_DIR must point at an openssl source tree}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out=${OUT_DIR:-$PWD/out}
asset="openssl-${version}-${suffix}"
stage="${out}/${asset}"

jobs=$( { sysctl -n hw.ncpu 2>/dev/null || nproc; } )

rm -rf "${stage}"
mkdir -p "${stage}"

cd "${src}"
perl Configure "${target}" \
  no-shared no-pinshared no-apps no-tests no-docs \
  --prefix="${stage}" --libdir=lib \
  "$@"

make -j"${jobs}" build_libs
# `install` is what the mars hook runs, so the bundle mirrors its tree exactly
# (install = install_sw + install_ssldirs; docs are disabled by no-docs).
make install

# Windows-only helper that `install` also copies; irrelevant to static consumers.
rm -f "${stage}/include/openssl/applink.c"
# `install` also lays down runtime bits — programs, loadable engines/modules and
# the ssl config tree — which an FFI consumer that links the .a files never
# reads. Dropping them keeps a bundle at a few hundred kilobytes per library.
rm -rf "${stage}/bin" "${stage}/ssl" "${stage}"/lib/engines-* "${stage}/lib/ossl-modules"
# Build-system scaffolding with absolute CI paths baked in; not consumed by FFI.
rm -rf "${stage}/lib/cmake" "${stage}/lib/pkgconfig"

# --- assertions -----------------------------------------------------------
test -f "${stage}/include/openssl/configuration.h" \
  || { echo "FAIL: generated configuration.h missing" >&2; exit 1; }
test -f "${stage}/include/openssl/crypto.h" \
  || { echo "FAIL: generated crypto.h missing" >&2; exit 1; }

for lib in libcrypto.a libssl.a; do
  test -f "${stage}/lib/${lib}" || { echo "FAIL: ${lib} missing" >&2; exit 1; }
done

# MD5 and RAND_bytes are the only OpenSSL entry points mars links against.
# Captured first, then grepped without a pipe: under `pipefail` a `grep -q`
# that exits early turns `nm | grep` into a false negative via SIGPIPE.
# Darwin prefixes C symbols with an underscore, ELF does not.
symbols=$(nm -g --defined-only "${stage}/lib/libcrypto.a" 2>/dev/null || true)
for sym in MD5 RAND_bytes; do
  grep -qE " T _?${sym}\$" <<<"${symbols}" \
    || { echo "FAIL: libcrypto.a does not define ${sym}" >&2; exit 1; }
done

# --- smoke test ----------------------------------------------------------
cp "${script_dir}/smoke.c" "${stage}/smoke.c"
# SMOKE_CMD is a shell command string so cross setups like
# "xcrun -sdk iphoneos cc -arch arm64" fit without word-splitting surprises.
smoke_cmd=${SMOKE_CMD:-${SMOKE_CC:-${CC:-cc}}}
# shellcheck disable=SC2086
sh -c "${smoke_cmd} -I'${stage}/include' '${stage}/smoke.c' -L'${stage}/lib' -lcrypto ${SMOKE_LDFLAGS:-} -o '${stage}/smoke'" \
  || { echo "FAIL: smoke test does not link against libcrypto.a" >&2; exit 1; }
rm -f "${stage}/smoke.c"

if [ "${SMOKE_RUN:-0}" = "1" ]; then
  "${stage}/smoke" >/dev/null || { echo "FAIL: smoke test crashed" >&2; exit 1; }
fi
rm -f "${stage}/smoke"

# --- metadata ------------------------------------------------------------
cat >"${stage}/build-info.json" <<JSON
{
  "openssl_version": "${version}",
  "configure_target": "${target}",
  "configure_args": "no-shared no-pinshared no-apps no-tests no-docs $*",
  "asset": "${asset}",
  "build_host": "$(uname -srm)",
  "compiler": "$(sh -c "${smoke_cmd} --version 2>/dev/null" | head -1)",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

cp "${src}/LICENSE.txt" "${stage}/LICENSE.txt"

# --- archive -------------------------------------------------------------
tar -czf "${out}/${asset}.tar.gz" -C "${out}" "${asset}"

# Root directory must equal the asset base name: the mars hook infers the
# extracted directory from the asset name.
tar -tzf "${out}/${asset}.tar.gz" >"${out}/.entries"
[ "$(head -1 "${out}/.entries")" = "${asset}/" ] \
  || { echo "FAIL: archive root is not ${asset}/" >&2; exit 1; }
rm -f "${out}/.entries"

echo "OK ${out}/${asset}.tar.gz $(du -h "${out}/${asset}.tar.gz" | cut -f1)"
