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
RUST_TARGETS=(
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
)
RUST_TARGET_LABELS=(
  "device"
  "simulator arm64"
  "simulator x86_64"
)
rustup target add "${RUST_TARGETS[@]}"

# ── Build ────────────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

export IPHONEOS_DEPLOYMENT_TARGET=17.0

detect_cpu_count() {
  sysctl -n hw.logicalcpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
}

PARALLEL_SLICES="${RUST_FFI_PARALLEL_SLICES:-1}"
case "$PARALLEL_SLICES" in
  0|false|FALSE|no|NO|off|OFF)
    PARALLEL_SLICES=0
    ;;
  *)
    PARALLEL_SLICES=1
    ;;
esac

CARGO_ARGS=(build --release)
if [[ -n "${CARGO_BUILD_JOBS:-}" ]]; then
  echo "▸ Using cargo parallel jobs per slice: $CARGO_BUILD_JOBS"
  CARGO_ARGS=(build --release -j "$CARGO_BUILD_JOBS")
elif [[ "$PARALLEL_SLICES" == "1" ]]; then
  CPU_COUNT="$(detect_cpu_count)"
  JOBS_PER_SLICE="$(( CPU_COUNT / ${#RUST_TARGETS[@]} ))"
  if (( JOBS_PER_SLICE < 1 )); then
    JOBS_PER_SLICE=1
  fi
  echo "▸ Parallel slice builds enabled: ${#RUST_TARGETS[@]} slices, $JOBS_PER_SLICE cargo job(s) per slice"
  CARGO_ARGS=(build --release -j "$JOBS_PER_SLICE")
fi

BUILD_LOG_DIR="$SCRIPT_DIR/target/ios-build-logs"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

build_target() {
  local target="$1"
  local label="$2"
  local log_file="$BUILD_LOG_DIR/$target.log"

  echo "▸ Building for $target ($label)..."
  if cargo "${CARGO_ARGS[@]}" --target "$target" >"$log_file" 2>&1; then
    echo "  ✓ Built $target"
  else
    echo "ERROR: failed to build $target. Last log lines:" >&2
    tail -n 80 "$log_file" >&2
    return 1
  fi
}

if [[ "$PARALLEL_SLICES" == "1" ]]; then
  BUILD_PIDS=()
  for index in "${!RUST_TARGETS[@]}"; do
    build_target "${RUST_TARGETS[$index]}" "${RUST_TARGET_LABELS[$index]}" &
    BUILD_PIDS+=("$!")
  done

  BUILD_STATUS=0
  for index in "${!BUILD_PIDS[@]}"; do
    if ! wait "${BUILD_PIDS[$index]}"; then
      echo "ERROR: Rust build failed for ${RUST_TARGETS[$index]} (${RUST_TARGET_LABELS[$index]})." >&2
      BUILD_STATUS=1
    fi
  done

  if [[ "$BUILD_STATUS" != "0" ]]; then
    exit "$BUILD_STATUS"
  fi
else
  echo "▸ Parallel slice builds disabled."
  for index in "${!RUST_TARGETS[@]}"; do
    build_target "${RUST_TARGETS[$index]}" "${RUST_TARGET_LABELS[$index]}"
  done
fi

DEVICE_LIB="$SCRIPT_DIR/target/aarch64-apple-ios/release/libtypst_ios.a"
SIM_ARM64_LIB="$SCRIPT_DIR/target/aarch64-apple-ios-sim/release/libtypst_ios.a"
SIM_X86_64_LIB="$SCRIPT_DIR/target/x86_64-apple-ios/release/libtypst_ios.a"
PACKAGE_DIR="$SCRIPT_DIR/target/ios-xcframework-package"
DEVICE_PACKAGE_LIB="$PACKAGE_DIR/aarch64-apple-ios/libtypst_ios.a"
SIM_ARM64_PACKAGE_LIB="$PACKAGE_DIR/aarch64-apple-ios-sim/libtypst_ios.a"
SIM_X86_64_PACKAGE_LIB="$PACKAGE_DIR/x86_64-apple-ios/libtypst_ios.a"
SIM_UNIVERSAL_LIB="$PACKAGE_DIR/ios-simulator-universal/libtypst_ios.a"

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

copy_static_library_for_packaging() {
  local source_lib="$1"
  local packaged_lib="$2"

  mkdir -p "$(dirname "$packaged_lib")"
  cp -f "$source_lib" "$packaged_lib"
  strip_static_library "$packaged_lib"
}

rm -rf "$PACKAGE_DIR"
mkdir -p "$(dirname "$SIM_UNIVERSAL_LIB")"

copy_static_library_for_packaging "$DEVICE_LIB" "$DEVICE_PACKAGE_LIB"
copy_static_library_for_packaging "$SIM_ARM64_LIB" "$SIM_ARM64_PACKAGE_LIB"
copy_static_library_for_packaging "$SIM_X86_64_LIB" "$SIM_X86_64_PACKAGE_LIB"

echo "▸ Creating universal simulator static library (arm64 + x86_64)..."
lipo -create "$SIM_ARM64_PACKAGE_LIB" "$SIM_X86_64_PACKAGE_LIB" -output "$SIM_UNIVERSAL_LIB"

# ── XCFramework ──────────────────────────────────────────────────────────────
XCFW_DIR="$LIBS_DIR/typst_ios.xcframework"
rm -rf "$XCFW_DIR"

echo "▸ Creating XCFramework..."
xcodebuild -create-xcframework \
  -library "$DEVICE_PACKAGE_LIB" \
  -library "$SIM_UNIVERSAL_LIB" \
  -output "$XCFW_DIR"

CLEAN_RUST_TARGET="${CLEAN_RUST_TARGET:-0}"
case "$CLEAN_RUST_TARGET" in
  1|true|TRUE|yes|YES|on|ON)
    echo "▸ Cleaning Rust intermediate build artifacts..."
    rm -rf "$SCRIPT_DIR/target"
    ;;
  *)
    echo "▸ Keeping Rust build cache at: $SCRIPT_DIR/target"
    echo "  Set CLEAN_RUST_TARGET=1 to remove it after packaging."
    ;;
esac

echo ""
echo "✅ Done! XCFramework at: $XCFW_DIR"
echo ""
echo "Next steps:"
echo "  1. In Xcode → InkPond target → General → Frameworks, Libraries,"
echo "     and Embedded Content → click + → Add Other → Add Files..."
echo "     and select Frameworks/typst_ios.xcframework"
echo "  2. Or open InkPond.xcodeproj and the xcframework will be"
echo "     linked automatically if OTHER_LDFLAGS already contains -ltypst_ios"
