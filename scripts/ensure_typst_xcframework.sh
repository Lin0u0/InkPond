#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_MARKER="$REPO_ROOT/Frameworks/typst_ios.xcframework/Info.plist"

EXPECTED_OUTPUTS=(
  "$OUTPUT_MARKER"
  "$REPO_ROOT/Frameworks/typst_ios.xcframework/ios-arm64/libtypst_ios.a"
  "$REPO_ROOT/Frameworks/typst_ios.xcframework/ios-arm64_x86_64-simulator/libtypst_ios.a"
)

for output in "${EXPECTED_OUTPUTS[@]}"; do
  if [[ ! -f "$output" ]]; then
    echo "typst_ios.xcframework is missing or incomplete. Building Rust FFI..."
    "$REPO_ROOT/rust-ffi/build-ios.sh"
    exit 0
  fi
done

if [[ -n "${CI:-}" || -n "${CI_XCODE_CLOUD:-}" ]]; then
  echo "Using committed typst_ios.xcframework in CI."
  exit 0
fi

if find \
  "$REPO_ROOT/rust-ffi/src" \
  "$REPO_ROOT/rust-ffi/Cargo.toml" \
  "$REPO_ROOT/rust-ffi/Cargo.lock" \
  "$REPO_ROOT/rust-ffi/build-ios.sh" \
  "$REPO_ROOT/InkPond/Bridging/typst_ffi.h" \
  -newer "$OUTPUT_MARKER" \
  -print -quit | grep -q .; then
  echo "Rust FFI inputs changed. Rebuilding typst_ios.xcframework..."
  "$REPO_ROOT/rust-ffi/build-ios.sh"
else
  echo "typst_ios.xcframework is up to date."
fi
