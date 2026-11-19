#!/usr/bin/env bash
# Builds one static OpenSSL bundle.
#
#   build.sh <tag> <target> [extra configure args...]
#
# SRC_DIR        openssl source tree (required)
# OUT_DIR        output directory (default: ./out)
# SMOKE_CMD      command that compiles the link check, e.g.
#                "xcrun -sdk iphoneos cc -arch arm64" (default: CC or cc)
# SMOKE_LDFLAGS  extra flags for the link check
#
# <tag> may carry the openssl- prefix or omit it.
set -euo pipefail

tag=${1:?tag}
target=${2:?target}
shift 2

# 3.5.9 and openssl-3.5.9 both end up as an asset named openssl-<version>-<suffix>.
version=${tag#openssl-}

src=${SRC_DIR:?SRC_DIR must point at an openssl source tree}
out=${OUT_DIR:-$PWD/out}
asset="openssl-${version}-${target}"
stage="${out}/${asset}"

jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu)

rm -rf "${stage}"
mkdir -p "${stage}"

cd "${src}"
perl Configure "${target}" \
  no-shared no-pinshared no-apps no-tests no-docs \
  --prefix="${stage}" --libdir=lib "$@"

make -j"${jobs}" build_libs
make install

# The archive is the install tree as-is; nothing is pruned.

for lib in libcrypto.a libssl.a; do
  test -f "${stage}/lib/${lib}" || { echo "FAIL: lib/${lib} missing" >&2; exit 1; }
done

# Link one tiny program so a broken archive fails here instead of in a consumer.
smoke_cmd=${SMOKE_CMD:-${CC:-cc}}
printf '#include <openssl/rand.h>\nint main(void){unsigned char b[16];return RAND_bytes(b,16)==1?0:1;}\n' \
  >"${stage}/t.c"
# shellcheck disable=SC2086
sh -c "${smoke_cmd} -I'${stage}/include' '${stage}/t.c' -L'${stage}/lib' -lcrypto ${SMOKE_LDFLAGS:-} -o '${stage}/t'" \
  || { echo "FAIL: libcrypto.a does not link" >&2; exit 1; }
rm -f "${stage}/t.c" "${stage}/t"

cat >"${stage}/build-info.json" <<JSON
{"version":"${version}","target":"${target}","args":"${*:-}","asset":"${asset}","host":"$(uname -srm)","built":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
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
