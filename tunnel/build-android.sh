#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JNILIBS_DIR="${SCRIPT_DIR}/../voyager/android/app/src/main/jniLibs"

# Auto-detect NDK
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
    NDK_DIR=$(ls -d "$SDK_ROOT/ndk/"* 2>/dev/null | sort -V | tail -1)
    if [ -z "$NDK_DIR" ]; then
        echo "Error: No Android NDK found. Set ANDROID_NDK_HOME." >&2
        exit 1
    fi
    export ANDROID_NDK_HOME="$NDK_DIR"
fi
echo "Using NDK: $ANDROID_NDK_HOME"

# Use rustup's toolchain (Homebrew rustc doesn't have Android targets)
RUSTUP_CARGO="$(rustup which cargo 2>/dev/null || true)"
if [ -n "$RUSTUP_CARGO" ]; then
    RUSTUP_BIN="$(dirname "$RUSTUP_CARGO")"
    export PATH="$RUSTUP_BIN:$PATH"
    echo "Using rustup cargo: $RUSTUP_CARGO"
fi

cd "$SCRIPT_DIR"

build_target() {
    local target="$1"
    local abi="$2"
    echo "Building $target -> $abi ..."
    cargo ndk -t "$target" build --release
    mkdir -p "$JNILIBS_DIR/$abi"
    cp "target/$target/release/libtunnel.so" "$JNILIBS_DIR/$abi/"
}

build_target aarch64-linux-android arm64-v8a
build_target armv7-linux-androideabi armeabi-v7a
build_target x86_64-linux-android x86_64

echo "Done. Libraries copied to $JNILIBS_DIR"
