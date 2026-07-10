# M0 reproducibility tools

These files are feasibility artifacts for issue #25. They are not production sync or compiler code.

## Fixed corpus

`FixtureGenerator.swift` owns the committed corpus and its SHA-256 manifest:

```bash
swift Tools/M0/FixtureGenerator.swift --check
```

Use `--write` only when deliberately revising the corpus. The fixtures pin 20k/100k/500k UTF-16 sources, 100 and 500 headings, 100 project cards, and a Typst document that produces 300 pages.

## Baseline validation

```bash
Tools/M0/run-baseline.sh
```

The script pins `/Applications/Xcode.app`, iOS 26.5, and iPhone 17. It creates a uniquely named temporary simulator plus private DerivedData, result bundle, and fixture copy under one temporary root. Its exit trap deletes the simulator by UUID and removes all temporary paths on success, failure, or interruption. Override the device profile only with `INKPOND_M0_RUNTIME_ID` and `INKPOND_M0_DEVICE_TYPE` so any deviation is explicit in the evidence.

## Diff3 spike

```bash
swiftc -parse-as-library \
  Tools/M0/Diff3Spike.swift \
  Tools/M0/Diff3SpikeTests.swift \
  -o /tmp/inkpond-m0-diff3-tests
/tmp/inkpond-m0-diff3-tests
rm -f /tmp/inkpond-m0-diff3-tests
```

The spike is a deterministic line-oriented feasibility implementation. It has no third-party dependency and is intentionally not linked into the app.

## Relative compiler baseline

```bash
Tools/M0/run-benchmarks.sh
```

This records three independent Typst 0.15 CLI compiles per text, heading, and 300-page fixture and prints the median. The script deletes all generated PDFs and timing files on exit. These numbers are relative evidence tied to the pinned corpus and machine; they are not universal performance promises.
