#!/usr/bin/env bash
# Builds the Kotlin binding of matrix-sdk-crypto-ffi for the pinned targets, from the pinned
# upstream commit with the patches of this repository. Run by the workflow only (no secret, no
# network after the dependency fetch). Output: out/jniLibs/<abi>/libmatrix_sdk_crypto_ffi.so,
# out/kotlin/** (UniFFI Kotlin sources), out/THIRD_PARTY_CRATES.txt.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$here/UPSTREAM.env"
src="$here/upstream"
out="$here/out"

actual="$(git -C "$src" rev-parse HEAD)"
if [ "$actual" != "$UPSTREAM_COMMIT" ]; then
  echo "upstream checkout is $actual, expected $UPSTREAM_COMMIT" >&2
  exit 1
fi

for patch in "$here"/patches/*.patch; do
  [ -e "$patch" ] || continue
  echo "-- applying $(basename "$patch")"
  git -C "$src" apply --check "$patch"
  git -C "$src" apply "$patch"
done

# Reproducibility: fixed timestamps, no incremental state. RUSTFLAGS is deliberately left unset:
# it would replace the arm64 flags of the upstream .cargo/config.toml (+neon,+aes,+sha2,+pmuv3).
# Both compared builds run under the same runner paths (/home/runner/work/...), so the paths
# embedded in panic messages are identical.
SOURCE_DATE_EPOCH="$(git -C "$src" log -1 --format=%ct)"
export SOURCE_DATE_EPOCH
export CARGO_INCREMENTAL=0
# The pinned toolchain wins over any rust-toolchain file (none at the pinned commit).
export RUSTUP_TOOLCHAIN="$RUST_VERSION"

cd "$src"
# Everything resolved from the upstream Cargo.lock only.
cargo fetch --locked
# The xtask (cargo run) and cargo-ndk do not pass --locked: offline mode forbids any new
# resolution after the fetch, and the lock file is checked unchanged at the end.
export CARGO_NET_OFFLINE=true
rm -rf "$out"
for target in $TARGETS; do
  # The xtask of matrix-rust-sdk: cargo ndk build (stripped) + UniFFI Kotlin generation.
  cargo xtask kotlin build-android-library --package crypto-sdk --release \
    --only-target "$target" --src-dir "$out"
done

# Licences of the crates actually linked for Android (for the third-party licence list).
cargo tree --locked -p matrix-sdk-crypto-ffi --target aarch64-linux-android -e normal \
  --prefix none --format '{p} {l}' | sort -u >"$out/THIRD_PARTY_CRATES.txt"

git -C "$src" diff --exit-code --stat -- Cargo.lock || {
  echo "Cargo.lock changed during the build" >&2
  exit 1
}

( cd "$out" && find . -type f | LC_ALL=C sort | xargs sha256sum ) >"$here/SHA256SUMS.build"
cat "$here/SHA256SUMS.build"
