#!/usr/bin/env bash
# Checks run before any Android build and before a tag can be released (Otaku ADR-0034 §3, §4, §8).
# Run by the workflow only (job `checks`), on the host toolchain; nothing is installed on a
# workstation. A failure stops the workflow: the build jobs depend on this one.
#   1. Cargo.lock of the patched upstream resolves as is (--locked); otherwise the minimal change
#      cargo would make is printed, for the patch, and the check fails.
#   2. cargo test of the backup primitives (official vectors, Otaku fixtures, refusals, erasure).
#   3. Dependency trees for the phone (union of the targets): the three crates of the backup primitives resolve to one
#      version each and digest to the versions already locked upstream (no new duplicate).
#   4. cargo audit on the lock file: a vulnerability of a crate linked for the phone fails;
#      warnings (unmaintained, yanked, or crates not linked for the phone) are printed.
# Output: checks/ (dependency trees and the audit report, uploaded as an artifact).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$here/UPSTREAM.env"
src="$here/upstream"
report="$here/checks"

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

rm -rf "$report"
mkdir -p "$report"
cd "$src"
export CARGO_TERM_COLOR=never RUSTUP_TOOLCHAIN="$RUST_VERSION"

# 1. The lock file of the patches is complete.
cp Cargo.lock "$report/Cargo.lock.patched"
if ! cargo fetch --locked; then
  echo "::error::Cargo.lock of the patches does not resolve with --locked"
  # Diagnostic only (this run fails anyway): what cargo would change, to fix the patch.
  cargo fetch >/dev/null 2>&1 || true
  diff -u "$report/Cargo.lock.patched" Cargo.lock || true
  exit 1
fi
export CARGO_NET_OFFLINE=true

# 2. Vectors of the backup primitives, optimised (Argon2id of 64 and 128 MiB), with the debug
# assertions and overflow checks of a test build.
CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS=true CARGO_PROFILE_RELEASE_OVERFLOW_CHECKS=true \
  cargo test --locked --release -p matrix-sdk-crypto-ffi --lib backup_primitives -- --test-threads=1

# 3. Dependency trees of the library for the phone, for every shipped target (TARGETS: arm64 and
# armv7); the crates linked for the phone are the union of both (published by build.sh too).
: >"$report/linked-crates.unsorted"
for target in $TARGETS; do
  dep_tree() { cargo tree --locked -p matrix-sdk-crypto-ffi --target "$target" "$@"; }
  dep_tree -e normal >"$report/cargo-tree-$target-normal.txt"
  dep_tree -e features >"$report/cargo-tree-$target-features.txt"
  for crate in argon2 blake2 chacha20poly1305 digest; do
    # Fails when a crate has several versions (cargo asks for a version), which is reported below.
    dep_tree -e normal -i "$crate" >"$report/cargo-tree-$target-inverted-$crate.txt" 2>&1 || true
  done
  dep_tree -e normal --prefix none --format '{p}' | sed -E 's/ \(.*\)$//' \
    >>"$report/linked-crates.unsorted"
done
LC_ALL=C sort -u "$report/linked-crates.unsorted" >"$report/linked-crates.txt"
rm "$report/linked-crates.unsorted"
# Expected versions: one for each crate of the primitives, and only the two versions of digest
# already locked upstream (0.10.7 by sha2 0.10, 0.11.2 by sha2 and hmac 0.11/0.13).
declare -A expected=(
  [argon2]="v0.6.0"
  [blake2]="v0.11.0"
  [chacha20poly1305]="v0.11.0"
  [digest]="v0.10.7 v0.11.2"
)
status=0
for crate in "${!expected[@]}"; do
  found="$(awk -v c="$crate" '$1 == c { print $2 }' "$report/linked-crates.txt" | LC_ALL=C sort -u | xargs)"
  allowed="${expected[$crate]}"
  for version in $found; do
    case " $allowed " in
      *" $version "*) ;;
      *) echo "::error::$crate $version is linked for the phone (allowed: $allowed)"; status=1 ;;
    esac
  done
  case "$crate" in
    digest) ;;
    *) [ "$found" = "$allowed" ] || { echo "::error::$crate: found '$found', expected '$allowed'"; status=1; } ;;
  esac
  echo "$crate: $found"
done
[ "$status" -eq 0 ] || exit 1

# 4. Advisories (RustSec database, fetched now: the latest advisories, not a pinned copy).
# cargo-audit fetches its database itself: the offline mode of cargo is lifted for it only.
unset CARGO_NET_OFFLINE
cargo audit --version
audit_status=0
cargo audit --json >"$report/cargo-audit.json" || audit_status=$?
cargo audit --no-fetch || true
python3 -I "$here/scripts/audit-verdict.py" "$report/cargo-audit.json" "$report/linked-crates.txt" \
  "$audit_status" "$here/scripts/audit-exceptions.txt"
