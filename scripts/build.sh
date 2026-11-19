#!/usr/bin/env bash
# Builds one static OpenSSL bundle.
#
#   build.sh <tag> <target> [apple-min-version]
#
# SRC_DIR      openssl source tree (required)
# OUT_DIR      output directory (default: ./out)
# ANDROID_API  API level for android-* targets (default: 24)
#
# <tag> may carry the openssl- prefix or omit it. The asset is
# openssl-<version>-<target>.tar.gz, unpacking into a directory of that name.
set -euo pipefail

tag=${1:?tag}
target=${2:?target}
minver=${3:-}

version=${tag#openssl-}
src=${SRC_DIR:?SRC_DIR must point at an openssl source tree}
out=${OUT_DIR:-$PWD/out}
asset="openssl-${version}-${target}"
stage="${out}/${asset}"

jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu)

# Everything Configure needs beyond tag and target is derived from the target.
case "${target}" in
  android-*) extra=(-D__ANDROID_API__="${ANDROID_API:-24}") ;;
  linux-aarch64) extra=(--cross-compile-prefix=aarch64-linux-gnu-) ;;
  linux-armv4) extra=(--cross-compile-prefix=arm-linux-gnueabihf-) ;;
  *) extra=() ;;
esac
if [ -n "${minver}" ]; then extra+=("${minver}"); fi

rm -rf "${stage}"
mkdir -p "${stage}"

cd "${src}"
perl Configure "${target}" \
  no-shared no-pinshared no-apps no-tests no-docs \
  --prefix="${stage}" --libdir=lib "${extra[@]}"

make -j"${jobs}" build_libs
make install

# The archive is the install tree as-is; nothing is pruned.

for lib in libcrypto.a libssl.a; do
  test -f "${stage}/lib/${lib}" || { echo "FAIL: lib/${lib} missing" >&2; exit 1; }
done

cat >"${stage}/build-info.json" <<JSON
{"version":"${version}","target":"${target}","args":"${extra[*]:-}","asset":"${asset}","host":"$(uname -srm)","built":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
JSON

cp "${src}/LICENSE.txt" "${stage}/LICENSE.txt"

tar -czf "${out}/${asset}.tar.gz" -C "${out}" "${asset}"

# Consumers extract with a plain tar, so the root entry must match the asset.
entries=$(tar -tzf "${out}/${asset}.tar.gz")
case "${entries}" in
  "${asset}/"*) ;;
  *) echo "FAIL: archive root is not ${asset}/" >&2; exit 1 ;;
esac

echo "built ${out}/${asset}.tar.gz ($(du -h "${out}/${asset}.tar.gz" | cut -f1))"
