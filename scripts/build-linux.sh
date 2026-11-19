#!/usr/bin/env bash
# Builds one static OpenSSL bundle for Linux, native or cross.
#
#   build-linux.sh <tag> <target> <src-dir> <out-dir>
#
# The asset is openssl-<version>-<target>.tar.gz. Cross targets pick their
# toolchain from the conventional prefix already installed on the host.
set -euo pipefail

tag=${1:?tag}
target=${2:?target}
src=${3:?src-dir}
out=${4:?out-dir}

version=${tag#openssl-}
asset="openssl-${version}-${target}"
stage="${out}/${asset}"

case "${target}" in
  linux-aarch64) cross=(--cross-compile-prefix=aarch64-linux-gnu-) ;;
  linux-armv4) cross=(--cross-compile-prefix=arm-linux-gnueabihf-) ;;
  *) cross=() ;;
esac

jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu)

rm -rf "${stage}"
mkdir -p "${stage}"

cd "${src}"
perl Configure "${target}" \
  no-shared no-pinshared no-apps no-tests no-docs \
  --prefix="${stage}" --libdir=lib "${cross[@]}"
make -j"${jobs}" build_libs
make install

# The archive is the install tree as-is; nothing is pruned.

for lib in libcrypto.a libssl.a; do
  test -f "${stage}/lib/${lib}" || { echo "FAIL: lib/${lib} missing" >&2; exit 1; }
done

cat >"${stage}/build-info.json" <<JSON
{"version":"${version}","target":"${target}","asset":"${asset}","host":"$(uname -srm)","built":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
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
