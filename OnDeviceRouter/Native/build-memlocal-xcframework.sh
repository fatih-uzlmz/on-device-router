#!/bin/sh
set -eu

NATIVE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY_ROOT=$(CDPATH= cd -- "$NATIVE_DIR/../.." && pwd)
MEMLOCAL_BUILD_ROOT=${MEMLOCAL_BUILD_ROOT:-/tmp/on-device-router-memlocal-build}
IOS_MINIMUM=${IOS_MINIMUM:-26.0}
CARGO_TARGET_DIR="$MEMLOCAL_BUILD_ROOT/cargo-target"
XCFRAMEWORK_OUTPUT="$MEMLOCAL_BUILD_ROOT/MemlocalCore.xcframework"
SHIM_INCLUDE="$NATIVE_DIR/memlocal_swift_shim/include"

mkdir -p "$MEMLOCAL_BUILD_ROOT"
export CARGO_TARGET_DIR
cd "$NATIVE_DIR"

IPHONEOS_DEPLOYMENT_TARGET="$IOS_MINIMUM" cargo build \
    --locked --release \
    --manifest-path "$NATIVE_DIR/memlocal_swift_shim/Cargo.toml" \
    --target aarch64-apple-ios

IPHONEOS_DEPLOYMENT_TARGET="$IOS_MINIMUM" cargo build \
    --locked --release \
    --manifest-path "$NATIVE_DIR/memlocal_swift_shim/Cargo.toml" \
    --target aarch64-apple-ios-sim

rm -rf "$XCFRAMEWORK_OUTPUT"
xcodebuild -create-xcframework \
    -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libmemlocal_swift_shim.a" \
    -headers "$SHIM_INCLUDE" \
    -library "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/libmemlocal_swift_shim.a" \
    -headers "$SHIM_INCLUDE" \
    -output "$XCFRAMEWORK_OUTPUT"

mkdir -p "$REPOSITORY_ROOT/OnDeviceRouter/Frameworks"
rm -rf "$REPOSITORY_ROOT/OnDeviceRouter/Frameworks/MemlocalCore.xcframework"
cp -R "$XCFRAMEWORK_OUTPUT" "$REPOSITORY_ROOT/OnDeviceRouter/Frameworks/MemlocalCore.xcframework"
