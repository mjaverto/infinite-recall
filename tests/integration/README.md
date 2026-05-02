# Integration tests

Black-box tests against the local Rust daemon (`infinite-recall-api`) via its
HTTP API. They exist to catch concrete regression classes — wrong DB path,
stale file handles, feature-gating bugs — that unit tests inside the crate
can't see. They do NOT cover Swift UI, performance, or end-to-end user flows.

## Quick start

```bash
# Build the daemon with the test feature
cd Backend-Rust && cargo build --locked -p infinite-recall-api --features test_introspection

# Run the integration suite
cd ../tests/integration && uv sync && uv run pytest -v
```

## What's covered

- `test_daemon_main_db_path_matches_user_dir` — daemon's resolved main DB
  path AND inode match the `INFINITE_RECALL_DB` we configured. Catches the
  bug where the daemon stays pinned to a stale file handle after the user
  dir is swapped.
- `test_build_endpoint_reports_test_feature` — sanity check that the daemon
  was actually compiled with `test_introspection` (otherwise everything else
  silently 404s).

## How it works

Three guards prevent test endpoints from ever shipping:
1. `#[cfg(feature = "test_introspection")]` — feature is off by default.
2. `IR_TEST_INTROSPECTION=1` runtime env var — even with the feature on,
   handlers 404 without this.
3. Bearer auth — same token gate as production endpoints.

The pytest fixture (`conftest.py`) spawns the daemon as a subprocess in a
`TemporaryDirectory`, configures it via env vars (`INFINITE_RECALL_DB`,
`INFINITE_RECALL_ACTIVITY_DB`, `INFINITE_RECALL_TOKEN_PATH`,
`INFINITE_RECALL_BIND` for port override), polls `/v1/_test/build` until
ready, yields connection info, and tears down the process group on exit.

## Adding a new test

When a new bug class hits, add an endpoint under `/v1/_test/*` (see
`Backend-Rust/api/src/routes/test_introspection.rs`), add a focused pytest
case here, and link the issue/PR in the test docstring. Don't generalize
prematurely — endpoints stay narrow until proven generic.

## What this is NOT

- Not a UI smoke harness. SwiftUI rendering regressions are a v1 concern.
  The current plan is `swift-snapshot-testing` against the existing
  `Omi ComputerTests` SwiftPM target — no Xcode project required. See
  <issue link TBD>.
- Not load/perf testing. Add a separate `tests/perf/` if/when needed.
- Not an end-to-end harness. We aren't seeding fixtures or simulating user
  flows yet.

## Running specific tests

```bash
uv run pytest test_db_path.py::test_daemon_main_db_path_matches_user_dir -v
```

## Debugging

If the daemon fails to start, run it manually and tail the logs:

```bash
INFINITE_RECALL_DB=/tmp/foo.db \
INFINITE_RECALL_ACTIVITY_DB=/tmp/foo-activity.db \
INFINITE_RECALL_TOKEN_PATH=/tmp/foo-token.txt \
IR_TEST_INTROSPECTION=1 \
RUST_LOG=debug \
cargo run --features test_introspection -p infinite-recall-api
```
