# Desktop — Testing & Coverage

The Desktop target is a SwiftPM package (`Package.swift`, no Xcode project).
Tests live under `Tests/`.

## Run the test suite

```bash
swift test --parallel --package-path Desktop
```

## Run with code coverage

Swift's built-in coverage uses LLVM profiling data:

```bash
swift test --enable-code-coverage --parallel --package-path Desktop
```

The instrumented profile and binary land under `Desktop/.build/`:

- Profile: `Desktop/.build/<config>/codecov/default.profdata`
- Test bundle: `Desktop/.build/<config>/<TargetName>PackageTests.xctest/Contents/MacOS/<TargetName>PackageTests`

Replace `<config>` with `debug` (default) or `release`.

## Inspect the coverage report

Use `xcrun llvm-cov` against the profile + test binary:

```bash
# Locate paths once (run after swift test has produced .build/)
BIN_PATH="$(swift test --show-bin-path --package-path Desktop)"
PROF="$BIN_PATH/codecov/default.profdata"
XCTEST="$(find "$BIN_PATH" -name '*PackageTests.xctest' -print -quit)"
BIN="$XCTEST/Contents/MacOS/$(basename "$XCTEST" .xctest)"

# Plain-text per-file summary
xcrun llvm-cov report "$BIN" -instr-profile "$PROF"

# Annotated source listing for a single file
xcrun llvm-cov show "$BIN" -instr-profile "$PROF" Desktop/Sources/<Path>/<File>.swift

# Export as LCOV (for CI tooling, e.g. Codecov)
xcrun llvm-cov export -format=lcov "$BIN" -instr-profile "$PROF" > Desktop/.build/coverage.lcov
```

## Notes

- `swift test --enable-code-coverage` adds compile-time instrumentation, so the
  first run after toggling the flag will rebuild the package.
- Coverage data under `Desktop/.build/` is already gitignored at the repo root
  (`.build/`).
- Filter noise (system frameworks, generated code) by passing
  `-ignore-filename-regex='.build|Tests/'` to `llvm-cov report`/`show`/`export`.
