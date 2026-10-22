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

# Reproducibility (D-238): the first run on two runners gave different .so files with identical
# Kotlin sources, so every known source of variation is pinned here, not only the timestamps.
# - Clean environment: the build runs under `env -i` with an explicit list of variables, so that
#   no runner-specific value (GITHUB_*, RUNNER_*, ImageVersion, CI...) can reach an env!() or
#   option_env!() of a crate or a build script.
# - Path remapping (rustc --remap-path-prefix, clang -ffile-prefix-map) for the work directory,
#   $CARGO_HOME, $RUSTUP_HOME and the NDK: the binary no longer depends on where the runner put them.
# - Frozen release profile through CARGO_PROFILE_RELEASE_* (overrides the upstream workspace
#   profile; values listed below), codegen-units=1, no incremental state. Rustc only strips debug
#   info: UniFFI reads its metadata from the symbol table of target/.../*.so to generate Kotlin.
#   The copies in out/jniLibs are stripped afterwards with the pinned NDK llvm-strip.
# - No build-id note (the default sha1 note only mirrors the other bytes, and hides where they differ).
# - SOURCE_DATE_EPOCH from the pinned upstream commit, TZ=UTC, C locale, fixed umask.
# RUSTFLAGS and CARGO_ENCODED_RUSTFLAGS stay unset: they would replace the upstream
# [target.aarch64-linux-android] rustflags. The per-target variables below are merged by cargo with
# that table; the upstream arm64 flags are repeated anyway so they hold even if it were not merged,
# and the table is checked unchanged so that a new pin cannot silently drift.
expected_arm64_flags='rustflags = ["-C", "target-feature=+neon,+aes,+sha2,+pmuv3"]'
grep -qxF "$expected_arm64_flags" "$src/.cargo/config.toml" || {
  echo "upstream .cargo/config.toml arm64 rustflags changed: review build.sh" >&2
  exit 1
}

cargo_home="${CARGO_HOME:-$HOME/.cargo}"
rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
ndk_home="${ANDROID_NDK_HOME:?ANDROID_NDK_HOME is required}"
# Most specific last: rustc and clang apply the last matching prefix.
remaps=(
  "$ndk_home=/ndk"
  "$rustup_home=/rustup"
  "$cargo_home=/cargo"
  "$here=/build"
  "$src=/build/upstream"
)
rustflags=()
cflags=()
for remap in "${remaps[@]}"; do
  rustflags+=("--remap-path-prefix=$remap")
  cflags+=("-ffile-prefix-map=$remap")
done
# lld on one thread (its output does not depend on threads, but it removes one variable); the
# Cortex-A53 erratum 843419 fix that NDK clang enables on arm64 is kept (old phones need it).
rustflags+=(-C link-arg=-Wl,--build-id=none -C link-arg=-Wl,--threads=1)
# NDK clang (>= 18) also takes __DATE__/__TIME__ from SOURCE_DATE_EPOCH.

SOURCE_DATE_EPOCH="$(git -C "$src" log -1 --format=%ct)"
umask 0022

# Variables passed to the build, nothing else (no secret exists in this repository anyway).
build_env=(
  HOME="$HOME"
  PATH="$cargo_home/bin:/usr/local/bin:/usr/bin:/bin"
  CARGO_HOME="$cargo_home"
  RUSTUP_HOME="$rustup_home"
  RUSTUP_TOOLCHAIN="$RUST_VERSION" # the pinned toolchain wins over any rust-toolchain file
  ANDROID_NDK_HOME="$ndk_home"
  LANG=C.UTF-8
  LC_ALL=C.UTF-8
  TZ=UTC
  SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"
  CARGO_INCREMENTAL=0
  CARGO_TERM_COLOR=never
  # Frozen release profile (the defaults of cargo's release profile, made explicit, plus
  # codegen-units=1). strip=debuginfo, not symbols: UniFFI needs the symbol table.
  CARGO_PROFILE_RELEASE_OPT_LEVEL=3
  CARGO_PROFILE_RELEASE_DEBUG=0
  CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS=false
  CARGO_PROFILE_RELEASE_OVERFLOW_CHECKS=false
  CARGO_PROFILE_RELEASE_LTO=false
  CARGO_PROFILE_RELEASE_PANIC=unwind
  CARGO_PROFILE_RELEASE_INCREMENTAL=false
  CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
  CARGO_PROFILE_RELEASE_STRIP=debuginfo
  CARGO_PROFILE_RELEASE_SPLIT_DEBUGINFO=off
  CARGO_PROFILE_RELEASE_RPATH=false
)
for target in $TARGETS; do
  upper="$(echo "$target" | tr 'a-z-' 'A-Z_')"
  lower="$(echo "$target" | tr '-' '_')"
  # Link map (diagnostic only: placement and size of every input section, to name the function
  # whose code differs). It is written beside the build, never into out/.
  flags=("${rustflags[@]}" -C "link-arg=-Wl,-Map=$here/diag/link-$target.map")
  if [ "$target" = aarch64-linux-android ]; then
    flags=(-C target-feature=+neon,+aes,+sha2,+pmuv3 "${flags[@]}")
  fi
  # Space-separated list form of cargo (no flag contains a space: checked below).
  build_env+=("CARGO_TARGET_${upper}_RUSTFLAGS=${flags[*]}")
  # cargo-ndk prepends its --target to this value; the cc crate (bundled SQLite) reads it.
  build_env+=("CFLAGS_${lower}=${cflags[*]}")
done
for remap in "${remaps[@]}"; do
  case "$remap" in *" "*) echo "path with a space: $remap" >&2; exit 1 ;; esac
done
run() { env -i "${build_env[@]}" "$@"; }

# What the build sees, for the comparison job (no secret: paths and pins only).
mkdir -p "$here/diag"
{
  echo "## env"
  printf '%s\n' "${build_env[@]}" | sed -E "s#$HOME#\$HOME#g" | LC_ALL=C sort
  echo "## tools"
  run rustc -vV
  run cargo -V
  run cargo ndk --version
  echo "## toolchain files"
  ( cd "$ndk_home/toolchains/llvm/prebuilt/linux-x86_64/bin" && sha256sum clang-[0-9]* ld.lld lld llvm-ar llvm-strip 2>/dev/null || true )
  # Pinned toolchain only (the runner image preinstalls other toolchains, which made the first
  # version of this digest differ between runners), one line per target, contents only.
  toolchain_dir="$rustup_home/toolchains/$RUST_VERSION-x86_64-unknown-linux-gnu"
  for t in x86_64-unknown-linux-gnu $TARGETS; do
    ( cd "$toolchain_dir/lib/rustlib/$t/lib" && find . -name '*.rlib' -type f -print0 | LC_ALL=C sort -z \
      | xargs -0 sha256sum | sha256sum | sed "s/-\$/std rlibs $t/" )
  done
} >"$here/diag/TOOLCHAIN.txt"

cd "$src"
# Everything resolved from the upstream Cargo.lock only.
run cargo fetch --locked
# The xtask (cargo run) and cargo-ndk do not pass --locked: offline mode forbids any new
# resolution after the fetch, and the lock file is checked unchanged at the end.
build_env+=(CARGO_NET_OFFLINE=true)
rm -rf "$out"
for target in $TARGETS; do
  # The xtask of matrix-rust-sdk: cargo ndk build (profile above; cargo-ndk 4.1.2 copies the
  # unstripped file to out/jniLibs) + UniFFI Kotlin generation from target/<triple>/release.
  run cargo xtask kotlin build-android-library --package crypto-sdk --release \
    --only-target "$target" --src-dir "$out"
done

# uniffi_bindgen must not be compiled for the phone any more (patch 0002).
for target in $TARGETS; do
  if ls "$src/target/$target/release/deps/" | grep -q '^libuniffi_bindgen-'; then
    echo "uniffi_bindgen was compiled for $target: check patches/0002" >&2
    exit 1
  fi
done

# Diagnostic: digests of every object and archive member the link consumed (one line per crate
# object), and the compressed link maps. Compared only when the libraries differ.
for target in $TARGETS; do
  python3 -I "$here/scripts/object-digests.py" "$src/target/$target/release" >"$here/diag/objects-$target.txt"
  if [ -f "$here/diag/link-$target.map" ]; then gzip -n -9 -f "$here/diag/link-$target.map"; fi
done

# Kotlin is generated: nothing reads the symbol table any more. Strip the shipped copies only, with
# the llvm-strip of the pinned NDK (deterministic: no timestamp, same input = same output). The
# exported JNI/UniFFI functions stay in .dynsym, which --strip-all keeps.
llvm_strip="$ndk_home/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
for so in "$out"/jniLibs/*/*.so; do
  run "$llvm_strip" --strip-all "$so"
done

# Licences of the crates actually linked for Android (for the third-party licence list).
run cargo tree --locked -p matrix-sdk-crypto-ffi --target aarch64-linux-android -e normal \
  --prefix none --format '{p} {l}' | LC_ALL=C sort -u >"$out/THIRD_PARTY_CRATES.txt"

git -C "$src" diff --exit-code --stat -- Cargo.lock || {
  echo "Cargo.lock changed during the build" >&2
  exit 1
}

# Section by section digests of each library: only read when the two builds differ.
for so in "$out"/jniLibs/*/*.so; do
  abi="$(basename "$(dirname "$so")")"
  python3 -I "$here/scripts/elf-sections.py" "$so" >"$here/diag/sections-$abi.txt"
done
# Same fixed modes as the archive, then digests in a fixed order (C collation).
find "$out" -type d -exec chmod 0755 {} +
find "$out" -type f -exec chmod 0644 {} +
( cd "$out" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ) >"$here/SHA256SUMS.build"
cat "$here/SHA256SUMS.build"
