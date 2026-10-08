#!/usr/bin/env bash
# Upload a built tile tree to R2 (immutable, versioned paths => cache forever).
# usage: upload_r2.sh BUCKET DIR [SUBDIR]   (uploads DIR/SUBDIR/** as SUBDIR/**)
set -euo pipefail
export BUCKET=$1
cd "$2"
put() {
  case "$1" in *.webp) ct=image/webp ;; *) ct=application/octet-stream ;; esac
  npx --yes wrangler@4 r2 object put "$BUCKET/$1" --file "$1" --remote \
    --content-type "$ct" --cache-control "public, max-age=31536000, immutable" >/dev/null 2>&1 \
    && echo ok || echo "FAIL $1"
}
export -f put
find "${3:-v1}" -type f \( -name '*.webp' -o -name '*.tflite' \) -print0 |
  xargs -0 -P 8 -n 1 bash -c 'put "$0"' | sort | uniq -c
