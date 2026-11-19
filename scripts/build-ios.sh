#!/usr/bin/env bash
# Builds one static OpenSSL bundle for iOS or its simulator with Xcode.
#
#   build-ios.sh <tag> <target> <version> <src-dir> <out-dir>
#
# The asset is openssl-<version>-<target>.tar.gz. <version> is the deployment
# floor, e.g. 12.0; the target decides whether it applies to the device or the
# simulator build.
set -euo pipefail

tag=${1:?tag}
target=${2:?target}
floor=${3:?version}
src=${4:?src-dir}
out=${5:?out-dir}

case "${target}" in
  ios64-*) min="-mios-version-min=${floor}" ;;
  iossimulator-*) min="-mios-simulator-version-min=${floor}" ;;
  *) echo "FAIL: ${target} is not an iOS target" >&2; exit 1 ;;
esac

version=${tag#openssl-}
asset="openssl-${version}-${target}"
stage="${out}/${asset}"

jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu)

rm -rf "${stage}"
mkdir -p "${stage}"

cd "${src}"
perl Configure "${target}" \
  no-shared no-pinshared no-apps no-tests no-docs \
  --prefix="${stage}" --libdir=lib "${min}"
make -j"${jobs}" build_libs
make install

# The archive is the install tree as-is; nothing is pruned.

for lib in libcrypto.a libssl.a; do
  test -f "${stage}/lib/${lib}" || { echo "FAIL: lib/${lib} missing" >&2; exit 1; }
done

cat >"${stage}/build-info.json" <<JSON
{"version":"${version}","target":"${target}","min-os":"${floor}","asset":"${asset}","host":"$(uname -srm)","built":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
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
