#!/bin/bash
set -euo pipefail

# Build for all Apple targets and create XCFramework
# Targets: aarch64-apple-ios, aarch64-apple-ios-sim, aarch64-apple-darwin, x86_64-apple-darwin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR="$SCRIPT_DIR/target"
FRAMEWORK_NAME="BlackholeWG"
HEADER="$SCRIPT_DIR/include/blackhole_wg.h"

# Build each target
echo "Building aarch64-apple-ios..."
IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-13.0}" \
  cargo build --release --target aarch64-apple-ios

echo "Building aarch64-apple-ios-sim..."
IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-13.0}" \
  cargo build --release --target aarch64-apple-ios-sim

echo "Building aarch64-apple-darwin..."
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.14}" \
  cargo build --release --target aarch64-apple-darwin

echo "Building x86_64-apple-darwin..."
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.14}" \
  cargo build --release --target x86_64-apple-darwin

# Create macOS universal binary
echo "Creating macOS universal binary..."
mkdir -p "$BUILD_DIR/universal-macos"
lipo -create \
    "$BUILD_DIR/aarch64-apple-darwin/release/libblackhole_wg.a" \
    "$BUILD_DIR/x86_64-apple-darwin/release/libblackhole_wg.a" \
    -output "$BUILD_DIR/universal-macos/libblackhole_wg.a"

# Create module.modulemap for each platform
create_modulemap() {
    local dir="$1"
    mkdir -p "$dir/Headers"
    cp "$HEADER" "$dir/Headers/"
    cat > "$dir/Headers/module.modulemap" << 'MODULEMAP'
module BlackholeWG {
    header "blackhole_wg.h"
    export *
}
MODULEMAP
}

# Prepare framework directories
IOS_DIR="$BUILD_DIR/framework-ios"
IOS_SIM_DIR="$BUILD_DIR/framework-ios-sim"
MACOS_DIR="$BUILD_DIR/framework-macos"

rm -rf "$IOS_DIR" "$IOS_SIM_DIR" "$MACOS_DIR"
mkdir -p "$IOS_DIR" "$IOS_SIM_DIR" "$MACOS_DIR"

cp "$BUILD_DIR/aarch64-apple-ios/release/libblackhole_wg.a" "$IOS_DIR/libblackhole_wg.a"
create_modulemap "$IOS_DIR"

cp "$BUILD_DIR/aarch64-apple-ios-sim/release/libblackhole_wg.a" "$IOS_SIM_DIR/libblackhole_wg.a"
create_modulemap "$IOS_SIM_DIR"

cp "$BUILD_DIR/universal-macos/libblackhole_wg.a" "$MACOS_DIR/libblackhole_wg.a"
create_modulemap "$MACOS_DIR"

# Create XCFramework
XCFRAMEWORK="$BUILD_DIR/$FRAMEWORK_NAME.xcframework"
rm -rf "$XCFRAMEWORK"

xcodebuild -create-xcframework \
    -library "$IOS_DIR/libblackhole_wg.a" -headers "$IOS_DIR/Headers" \
    -library "$IOS_SIM_DIR/libblackhole_wg.a" -headers "$IOS_SIM_DIR/Headers" \
    -library "$MACOS_DIR/libblackhole_wg.a" -headers "$MACOS_DIR/Headers" \
    -output "$XCFRAMEWORK"

echo "XCFramework created at: $XCFRAMEWORK"
