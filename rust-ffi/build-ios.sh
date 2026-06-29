#!/usr/bin/env bash
# build-ios.sh — compile Typst FFI static library for iOS & iOS Simulator,
# then package into an XCFramework under Frameworks/ at the repo root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBS_DIR="$REPO_ROOT/Frameworks"
mkdir -p "$LIBS_DIR"

# ── Check prerequisites ──────────────────────────────────────────────────────
if ! command -v cargo &>/dev/null && [ -f "$HOME/.cargo/env" ]; then
  # Load Rust toolchain path for non-interactive shells.
  source "$HOME/.cargo/env"
fi

if ! command -v cargo &>/dev/null; then
  echo "ERROR: cargo not found. Install Rust: https://rustup.rs" >&2
  exit 1
fi

echo "▸ Installing required Rust targets..."
rustup target add aarch64-apple-ios
rustup target add aarch64-apple-ios-sim
rustup target add x86_64-apple-ios

# ── Build ────────────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

export IPHONEOS_DEPLOYMENT_TARGET=17.0

if [[ -n "${CARGO_BUILD_JOBS:-}" ]]; then
  echo "▸ Using cargo parallel jobs: $CARGO_BUILD_JOBS"
  CARGO_ARGS=(build --release -j "$CARGO_BUILD_JOBS")
else
  CARGO_ARGS=(build --release)
fi

echo "▸ Building for aarch64-apple-ios (device)..."
cargo "${CARGO_ARGS[@]}" --target aarch64-apple-ios

echo "▸ Building for aarch64-apple-ios-sim (simulator)..."
cargo "${CARGO_ARGS[@]}" --target aarch64-apple-ios-sim

echo "▸ Building for x86_64-apple-ios (simulator)..."
cargo "${CARGO_ARGS[@]}" --target x86_64-apple-ios

DEVICE_LIB="$SCRIPT_DIR/target/aarch64-apple-ios/release/libtypst_ios.a"
SIM_ARM64_LIB="$SCRIPT_DIR/target/aarch64-apple-ios-sim/release/libtypst_ios.a"
SIM_X86_64_LIB="$SCRIPT_DIR/target/x86_64-apple-ios/release/libtypst_ios.a"
SIM_UNIVERSAL_LIB="$SCRIPT_DIR/target/ios-simulator-universal/release/libtypst_ios.a"

STRIP_TOOL="$(xcrun -sdk iphoneos -f strip 2>/dev/null || true)"
if [[ -z "$STRIP_TOOL" ]]; then
  STRIP_TOOL="$(command -v strip || true)"
fi

strip_static_library() {
  local lib="$1"

  if [[ -z "$STRIP_TOOL" ]]; then
    echo "warning: strip tool not found; keeping unstripped library: $lib" >&2
    return
  fi

  echo "▸ Stripping static library symbols: $lib"
  "$STRIP_TOOL" -S -x "$lib"
}

mkdir -p "$(dirname "$SIM_UNIVERSAL_LIB")"

strip_static_library "$DEVICE_LIB"
strip_static_library "$SIM_ARM64_LIB"
strip_static_library "$SIM_X86_64_LIB"

echo "▸ Creating universal simulator static library (arm64 + x86_64)..."
lipo -create "$SIM_ARM64_LIB" "$SIM_X86_64_LIB" -output "$SIM_UNIVERSAL_LIB"

# ── XCFramework ──────────────────────────────────────────────────────────────
XCFW_DIR="$LIBS_DIR/typst_ios.xcframework"
rm -rf "$XCFW_DIR"

echo "▸ Creating XCFramework..."
xcodebuild -create-xcframework \
  -library "$DEVICE_LIB" \
  -library "$SIM_UNIVERSAL_LIB" \
  -output "$XCFW_DIR"

echo "▸ Cleaning Rust intermediate build artifacts..."
rm -rf "$SCRIPT_DIR/target"

echo ""
echo "✅ Done! XCFramework at: $XCFW_DIR"
echo ""
echo "Next steps:"
echo "  1. In Xcode → InkPond target → General → Frameworks, Libraries,"
echo "     and Embedded Content → click + → Add Other → Add Files..."
echo "     and select Frameworks/typst_ios.xcframework"
echo "  2. Or open InkPond.xcodeproj and the xcframework will be"
echo "     linked automatically if OTHER_LDFLAGS already contains -ltypst_ios"
