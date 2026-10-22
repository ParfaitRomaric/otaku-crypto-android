#!/usr/bin/env bash
# Deterministic archive of out/: same input files = same archive bytes (sorted names, fixed
# owner and dates, gzip without name nor timestamp). Usage: package.sh <version>
set -euo pipefail

version="$1"
# Same format as the tag checked by the workflow (no shell metacharacter can reach a path).
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-otaku\.[0-9]+)?$ ]] || {
  echo "invalid version: $version" >&2
  exit 1
}
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="otaku-crypto-android-${version}"
mtime="@$(git -C "$here" log -1 --format=%ct)"

cd "$here"
rm -rf "dist" && mkdir -p "dist/$name"
cp -R out/. "dist/$name/"
cp UPSTREAM.env "dist/$name/"
cp -R patches "dist/$name/"
cp SHA256SUMS.build "dist/$name/"
# Fixed modes too: artifacts downloaded between jobs do not keep file permissions.
tar --sort=name --mtime="$mtime" --owner=0 --group=0 --numeric-owner --mode='u=rwX,go=rX' \
  --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
  -C dist -cf - "$name" | gzip -n -9 >"dist/$name.tar.gz"
( cd dist && sha256sum "$name.tar.gz" >"$name.tar.gz.sha256" )
cat "dist/$name.tar.gz.sha256"
