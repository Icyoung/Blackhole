#!/bin/sh
set -euo pipefail
if [ -x "/opt/homebrew/opt/rustup/bin/cargo" ] && [ -x "/opt/homebrew/opt/rustup/bin/rustc" ]; then
  export PATH="/opt/homebrew/opt/rustup/bin:${PATH}"
  CARGO_BIN="/opt/homebrew/opt/rustup/bin/cargo"
  RUSTC_BIN="/opt/homebrew/opt/rustup/bin/rustc"
elif [ -x "${HOME}/.cargo/bin/cargo" ] && [ -x "${HOME}/.cargo/bin/rustc" ]; then
  export PATH="${HOME}/.cargo/bin:${PATH}"
  CARGO_BIN="${HOME}/.cargo/bin/cargo"
  RUSTC_BIN="${HOME}/.cargo/bin/rustc"
else
  CARGO_BIN="cargo"
  RUSTC_BIN="rustc"
fi
export RUSTC="$RUSTC_BIN"
if [ -z "${BH_RUST_TRIPLE:-}" ]; then
  echo "error: BH_RUST_TRIPLE is not set" >&2
  exit 1
fi
LIB_PATH="${SRCROOT}/../../blackhole-wg/target/${BH_RUST_TRIPLE}/release/libblackhole_wg.a"
RUST_ROOT="${SRCROOT}/../../blackhole-wg"
DYLIB_PATH="${SRCROOT}/../../blackhole-wg/target/${BH_RUST_TRIPLE}/release/libblackhole_wg.dylib"
DYLIB_DEPS_PATH="${SRCROOT}/../../blackhole-wg/target/${BH_RUST_TRIPLE}/release/deps/libblackhole_wg.dylib"
cleanup_stale_dylibs() {
  rm -f "$DYLIB_PATH" "$DYLIB_DEPS_PATH"
}
cleanup_stale_dylibs
if [ -f "$LIB_PATH" ]; then
  if ! find "$RUST_ROOT/src" "$RUST_ROOT/include" -type f -newer "$LIB_PATH" | grep -q . \
    && [ ! "$RUST_ROOT/Cargo.toml" -nt "$LIB_PATH" ] \
    && [ ! "$RUST_ROOT/Cargo.lock" -nt "$LIB_PATH" ]; then
    exit 0
  fi
fi
case "$BH_RUST_TRIPLE" in
  aarch64-apple-ios|aarch64-apple-ios-sim)
    export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-13.0}"
    ;;
  aarch64-apple-darwin|x86_64-apple-darwin)
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.14}"
    ;;
esac
"$CARGO_BIN" build --manifest-path "$RUST_ROOT/Cargo.toml" --release --target "$BH_RUST_TRIPLE"
cleanup_stale_dylibs

