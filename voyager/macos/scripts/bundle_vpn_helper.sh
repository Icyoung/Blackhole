#!/bin/sh
# Bundle voyager-vpn-helper into Voyager.app. Invoked from the Xcode
# "Build voyager-vpn-helper" phase. Prefer a prebuilt universal lipo
# (CI); otherwise cargo-build the host binary (local / fallback).
set -eu

if [ -z "${SRCROOT:-}" ] || [ -z "${BUILT_PRODUCTS_DIR:-}" ] || [ -z "${PRODUCT_NAME:-}" ]; then
  echo "error: SRCROOT, BUILT_PRODUCTS_DIR, and PRODUCT_NAME must be set (Xcode build phase)" >&2
  exit 1
fi

DAEMON_DIR="${SRCROOT}/../../horizon/daemon"
RESOURCES_DIR="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources"
UNIVERSAL="${DAEMON_DIR}/target/release/voyager-vpn-helper-universal"

if [ -x "/opt/homebrew/opt/rustup/bin/cargo" ] && [ -x "/opt/homebrew/opt/rustup/bin/rustc" ]; then
  export PATH="/opt/homebrew/opt/rustup/bin:${PATH}"
  CARGO_BIN="/opt/homebrew/opt/rustup/bin/cargo"
elif [ -x "${HOME}/.cargo/bin/cargo" ]; then
  export PATH="${HOME}/.cargo/bin:${PATH}"
  CARGO_BIN="${HOME}/.cargo/bin/cargo"
else
  CARGO_BIN="cargo"
fi

if [ -f "$UNIVERSAL" ]; then
  HELPER_SRC="$UNIVERSAL"
  echo "Using prebuilt universal voyager-vpn-helper at ${UNIVERSAL}"
else
  if [ ! -d "$DAEMON_DIR" ]; then
    echo "error: daemon directory not found at ${DAEMON_DIR}" >&2
    exit 1
  fi
  echo "Building voyager-vpn-helper because ${UNIVERSAL} is missing..."
  if [ "${CONFIGURATION:-Release}" = "Release" ]; then
    (cd "$DAEMON_DIR" && "$CARGO_BIN" build --release --bin voyager-vpn-helper)
    HELPER_SRC="${DAEMON_DIR}/target/release/voyager-vpn-helper"
  else
    (cd "$DAEMON_DIR" && "$CARGO_BIN" build --bin voyager-vpn-helper)
    HELPER_SRC="${DAEMON_DIR}/target/debug/voyager-vpn-helper"
  fi
fi

if [ ! -f "$HELPER_SRC" ]; then
  echo "error: voyager-vpn-helper not found at ${HELPER_SRC}" >&2
  exit 1
fi

mkdir -p "$RESOURCES_DIR"
cp -f "$HELPER_SRC" "${RESOURCES_DIR}/voyager-vpn-helper"
chmod 755 "${RESOURCES_DIR}/voyager-vpn-helper"
echo "Bundled voyager-vpn-helper from ${HELPER_SRC} into ${RESOURCES_DIR}"
