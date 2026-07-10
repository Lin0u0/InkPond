#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture_root="$repo_root/Tools/M0/Fixtures"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/inkpond-m0-bench.XXXXXX")"

cleanup() {
    rm -rf "$work_root"
}
trap cleanup EXIT INT TERM

cd "$repo_root"
swift Tools/M0/FixtureGenerator.swift --check >/dev/null

print "tool,$(typst --version)"
print "hardware,$(sysctl -n machdep.cpu.brand_string)"
print "fixture,median_seconds,output_bytes,runs"

for name in \
    source-020000-utf16 \
    source-100000-utf16 \
    source-500000-utf16 \
    headings-100 \
    headings-500 \
    preview-300-pages; do
    timings=()
    output="$work_root/$name.pdf"
    for run in 1 2 3; do
        time_file="$work_root/$name-$run.time"
        /usr/bin/time -p -o "$time_file" \
            typst compile \
            --root "$fixture_root" \
            "$fixture_root/$name.typ" \
            "$output"
        timings+=("$(awk '/^real / { print $2 }' "$time_file")")
    done
    median="$(print -l -- "${timings[@]}" | sort -n | sed -n '2p')"
    output_bytes="$(stat -f '%z' "$output")"
    print "$name,$median,$output_bytes,${(j:;:)timings}"
done

print "cleanup,temporary PDFs and timing files deleted"
