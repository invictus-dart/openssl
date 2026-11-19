#!/usr/bin/env bash
# Builds one static OpenSSL bundle for Android.
#
#   build-android.sh <tag> <target> <api> <src-dir> <out-dir>
#
# The asset is openssl-<version>-<target>.tar.gz. The NDK toolchain has to be
# first on PATH; the API level is passed in rather than assumed.
set -euo pipefail

tag=${1:?tag}
target=${2:?target}
api=${3:?api}
src=${4:?src-dir}
out=${5:?out-dir}

version=${tag#openssl-}
asset="openssl-${version}-${target}"
stage="${out}/${asset}"

jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu)

rm -rf "${stage}"
mkdir -p "${stage}"

cd "${src}"
perl Configure "${target}" \
  no-shared no-pinshared no-apps no-tests no-docs \
  --prefix="${stage}" --libdir=lib -D__ANDROID_API__="${api}"
make -j"${jobs}" build_libs
make install

# The archive is the install tree as-is; nothing is pruned.

for lib in libcrypto.a libssl.a; do
  test -f "${stage}/lib/${lib}" || { echo "FAIL: lib/${lib} missing" >&2; exit 1; }
done

cat >"${stage}/build-info.json" <<JSON
{"version":"${version}","target":"${target}","api":"${api}","asset":"${asset}","host":"$(uname -srm)","built":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
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
