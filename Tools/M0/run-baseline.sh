#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
runtime_id="${INKPOND_M0_RUNTIME_ID:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}"
device_type="${INKPOND_M0_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}"
artifact_root="$(mktemp -d "${TMPDIR:-/tmp}/inkpond-m0.XXXXXX")"
derived_data="$artifact_root/DerivedData"
result_bundle="$artifact_root/InkPondTests.xcresult"
product_benchmark_result_bundle="$artifact_root/M0ProductBenchmark.xcresult"
fixture_copy="$artifact_root/Fixtures"
simulator_name="InkPond-M0-$(date +%Y%m%d-%H%M%S)-$$"
simulator_id=""

cleanup() {
    if [[ -n "$simulator_id" ]]; then
        DEVELOPER_DIR="$developer_dir" xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
        DEVELOPER_DIR="$developer_dir" xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
    fi
    rm -rf "$artifact_root"
}
trap cleanup EXIT INT TERM

if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
    print -u2 "Stable Xcode not found at $developer_dir"
    exit 1
fi

export DEVELOPER_DIR="$developer_dir"

cd "$repo_root"
mkdir -p "$derived_data"
ditto InkPondTests/M0Fixtures "$fixture_copy"

print "M0_ARTIFACT_ROOT=$artifact_root"
xcodebuild -version
INKPOND_M0_FIXTURE_DIR="$fixture_copy" swift Tools/M0/FixtureGenerator.swift --check
swiftc -parse-as-library \
    Tools/M0/Diff3Spike.swift \
    Tools/M0/Diff3SpikeTests.swift \
    -o "$artifact_root/diff3-tests"
"$artifact_root/diff3-tests"

simulator_id="$(xcrun simctl create "$simulator_name" "$device_type" "$runtime_id")"
print "M0_SIMULATOR_ID=$simulator_id"
print "M0_SIMULATOR_PROFILE=$device_type@$runtime_id"
xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b

print "M0_ICLOUD_SYNC_TRIGGER_BEGIN"
if xcrun simctl icloud_sync "$simulator_id"; then
    print "M0_ICLOUD_SYNC_TRIGGER=accepted"
else
    print "M0_ICLOUD_SYNC_TRIGGER=unavailable"
fi
print "M0_ICLOUD_SYNC_TRIGGER_END"

xcodebuild \
    -quiet \
    -project InkPond.xcodeproj \
    -scheme InkPond \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived_data/build" \
    build

xcodebuild test \
    -quiet \
    -project InkPond.xcodeproj \
    -scheme InkPond \
    -only-testing:InkPondTests \
    -skip-testing:InkPondTests/M0ProductBenchmarkTests \
    -destination "id=$simulator_id" \
    -parallel-testing-enabled NO \
    -derivedDataPath "$derived_data/tests" \
    -resultBundlePath "$result_bundle"

print "M0_XCRESULT_SUMMARY_BEGIN"
xcrun xcresulttool get test-results summary --path "$result_bundle"
print "M0_XCRESULT_SUMMARY_END"

xcodebuild test \
    -quiet \
    -project InkPond.xcodeproj \
    -scheme InkPond \
    -only-testing:InkPondTests/M0ProductBenchmarkTests \
    -destination "id=$simulator_id" \
    -parallel-testing-enabled NO \
    -derivedDataPath "$derived_data/tests" \
    -resultBundlePath "$product_benchmark_result_bundle"

print "M0_PRODUCT_BENCHMARK_SUMMARY_BEGIN"
xcrun xcresulttool get test-results summary --path "$product_benchmark_result_bundle"
print "M0_PRODUCT_BENCHMARK_SUMMARY_END"

cargo test --manifest-path rust-ffi/Cargo.toml -- --test-threads=1
cargo fmt --manifest-path rust-ffi/Cargo.toml --check
git diff --check
plutil -lint InkPond/Info.plist InkPond/InkPond.entitlements
mkdir -p "$artifact_root/xcstrings"
xcrun xcstringstool compile \
    --dry-run \
    --output-directory "$artifact_root/xcstrings" \
    InkPond/Resources/Localization/Localizable.xcstrings
xcrun xcstringstool compile \
    --dry-run \
    --output-directory "$artifact_root/xcstrings" \
    InkPond/Resources/Localization/InfoPlist.xcstrings
Tools/M0/run-benchmarks.sh

print "M0_CLEANUP=temporary simulator, DerivedData, result bundle, and fixture copy will be deleted"
