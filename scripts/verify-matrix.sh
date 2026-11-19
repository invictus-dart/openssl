#!/usr/bin/env bash
# Cross-checks the produced bundles before they are published.
#
# 1. Every archive extracts to a root directory named exactly like the asset
#    (the mars hook infers the source directory from the asset name).
# 2. Every bundle carries libcrypto + libssl and a generated configuration.h.
# 3. Static public headers are byte-identical across all triples (same version,
#    same configure flags); only the generated ones may differ.
# 4. configuration.h agrees with the pointer width of the triple.
#
# Usage: verify-matrix.sh <dist-dir>
set -euo pipefail

dist=${1:?dist dir}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

static_digest=""
count=0

for archive in "$dist"/openssl-*.tar.gz; do
  asset=$(basename "$archive" .tar.gz)
  count=$((count + 1))

  tar -xzf "$archive" -C "$work"
  test -d "$work/$asset" || { echo "FAIL: $asset has no matching root dir" >&2; exit 1; }

  # Windows ships .lib, unix ships .a.
  ls "$work/$asset/lib"/libcrypto.* >/dev/null 2>&1 \
    || { echo "FAIL: $asset has no libcrypto" >&2; exit 1; }
  ls "$work/$asset/lib"/libssl.* >/dev/null 2>&1 \
    || { echo "FAIL: $asset has no libssl" >&2; exit 1; }
  test -f "$work/$asset/include/openssl/configuration.h" \
    || { echo "FAIL: $asset has no generated configuration.h" >&2; exit 1; }
  test ! -f "$work/$asset/include/openssl/applink.c" \
    || { echo "FAIL: $asset still ships applink.c" >&2; exit 1; }

  # Pointer width sanity: the generated header must reflect the triple.
  case "$asset" in
    *64*|*aarch64*)
      grep -qE 'define (SIXTY_FOUR_BIT|SIXTY_FOUR_BIT_LONG)' \
        "$work/$asset/include/openssl/configuration.h" \
        || { echo "FAIL: $asset is not configured as 64-bit" >&2; exit 1; } ;;
    *ia32*|*armv4*|*-arm)
      grep -qE 'define THIRTY_TWO_BIT' \
        "$work/$asset/include/openssl/configuration.h" \
        || { echo "FAIL: $asset is not configured as 32-bit" >&2; exit 1; } ;;
  esac

  # Every public header except the generated configuration.h must be identical
  # across triples: same version and same configure flags.
  digest=$( cd "$work/$asset/include" \
            && find openssl -name '*.h' ! -name 'configuration.h' -type f -print0 \
               | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 )
  if [ -z "$static_digest" ]; then
    static_digest=$digest
  elif [ "$digest" != "$static_digest" ]; then
    echo "FAIL: $asset static headers differ from the first bundle" >&2
    exit 1
  fi
done

[ "$count" -gt 0 ] || { echo "FAIL: no bundles found in $dist" >&2; exit 1; }
echo "OK $count bundles, static header digest $static_digest"
