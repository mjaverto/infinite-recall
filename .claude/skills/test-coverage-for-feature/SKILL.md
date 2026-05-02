---
name: test-coverage-for-feature
description: After shipping a feature in Infinite Recall, add test_introspection coverage that catches the bug class(es) the feature could regress. Use when the user invokes /test-coverage-for-feature, or proactively when a non-trivial feature has just been merged or implemented and no integration test was added alongside it.
---

# Adding test coverage for a new feature

The test harness in `tests/integration/` exists to catch **bug classes that don't fail unit tests** — stale state, path drift, queue stalls, lock deadlocks, missing migrations. It does this by exposing daemon ground-truth via read-only `/v1/_test/*` endpoints and asserting invariants in pytest.

The harness is **additive**. Every new feature that introduces a new bug class should add an endpoint + a test in the same PR.

## Step 1 — name the bug class

Before writing any code, answer in one sentence: **what would silently break if this feature regressed?** Examples:

- "The daemon would keep using the old DB path after a rename."
- "The migration would no-op on existing user dirs."
- "The diarization worker would deadlock on recursive lock acquisition."
- "Queue depth would grow unboundedly because failed jobs stop being reaped."

If you can't name a bug class, the feature probably doesn't need integration coverage — unit tests are enough. Stop here.

## Step 2 — decide layer

| Bug class lives in… | Add coverage via… |
|---|---|
| Rust daemon state, DB, queues, workers | `/v1/_test/*` endpoint + pytest case |
| Swift UI rendering, navigation | **Skipped in v0.** SwiftUI smoke tests are deferred. Add a unit test in `Omi ComputerTests` instead. |
| Both layers | Two PRs — daemon first, Swift second. Don't bundle. |

## Step 3 — expose the state (Rust side only)

Edit `Backend-Rust/api/src/routes/test_introspection.rs`. Add the smallest read-only endpoint that exposes whatever the test will assert against. Return `serde_json::Value` or a typed struct — match existing endpoint style.

Conventions:
- Path: `GET /v1/_test/<noun>` — singular, snake_case.
- Always return 200 with `null`/empty for absent state, not an error. The test driver wants to *see* absence, not get a 500.
- Both guards apply automatically: `#[cfg(feature = "test_introspection")]` on the file, runtime `IR_TEST_INTROSPECTION=1` check via `enabled()` helper at the top of every handler.
- New AppState fields go in `Backend-Rust/api/src/state.rs` and must be populated in `Backend-Rust/api/src/lib.rs` where AppState is built. Update both `tests/activity_endpoints.rs` and `tests/terminate_endpoint.rs` mock builders if you add a field.
- For per-worker error visibility, push to `state.worker_errors` (`Backend-Rust/api/src/worker_errors.rs`) — it's a no-op on default builds, so producers can call it unconditionally.

## Step 4 — write the pytest case

Add a new file `tests/integration/test_<feature>.py` (or extend an existing one if the feature is closely related).

Required structure:

```python
def test_<bug_class_name>(daemon):
    """Catch: <one-line description of the bug class this regresses>."""
    r = httpx.get(f"{daemon.base_url}/v1/_test/<endpoint>",
                  headers={"Authorization": f"Bearer {daemon.bearer_token}"},
                  timeout=5)
    r.raise_for_status()
    assert <invariant>, f"<actionable failure message with both expected and observed>"
```

Rules:
- One test = one bug class. Don't multiplex.
- Docstring leads with `Catch:` and names the regression. This is the test's reason for existing — it's load-bearing context for whoever sees the test fail later.
- Failure messages must include both the expected and observed value so the developer can diagnose without re-running locally.
- Reuse the `daemon` fixture from `conftest.py`. Don't add a new fixture unless you genuinely need a different daemon configuration (e.g. specific env vars). If you do, add it to `conftest.py`, not the test file.

## Step 5 — verify locally before push

Mirror every CI step. From the repo root, in order:

```bash
xcrun swift build -c debug --package-path Desktop
cd Backend-Rust
cargo test --locked -p infinite-recall-api
cargo test --locked -p infinite-recall-api --features activity_test_wiring
cargo test --locked -p infinite-recall-api --features test_introspection
cargo build --locked -p infinite-recall-api --features test_introspection
cd ../tests/integration
uv sync && uv run pytest -v
cd ..
actionlint .github/workflows/ci.yml  # if installed
```

Any failure: fix the root cause, do not skip or `--no-verify` anything. Re-run from the failed step.

## Step 6 — commit and open the PR

Atomic conventional commits. The pattern from the harness PR:

```
feat(api): expose <noun> state via /v1/_test/<noun>
test(integration): add regression test for <bug class>
```

If the feature itself was already merged, this is one PR. If you're adding the test alongside the feature in the same PR, prefer **one PR with both commits** — the test is part of the feature's definition of done.

PR body must include:
- Bug class this catches (one line — same as the test docstring).
- How it was caught before (manual repro? incident? code review?).
- Why a unit test wouldn't cover it.

## Anti-patterns to refuse

- **Generalizing the harness.** No "test framework", no fixture factories, no parameterized DSL until we have ≥3 tests asking for the same thing. Three similar lines is better than a premature abstraction.
- **Mocking the daemon.** Real subprocess, real HTTP, real SQLite. The whole point of integration tests is to catch the things mocks hide.
- **Adding test endpoints that aren't read-only.** Test endpoints never mutate state. If you need to mutate, do it via the public API and observe via the test endpoint.
- **Skipping the local CI mirror.** Pushing red CI burns reviewer trust and Actions minutes.
- **Bundling Swift UI smokes.** Deferred until SwiftPM gets a workable UI test story. Don't add `.xcodeproj` scaffolding for a single smoke.

## When the bug class doesn't fit the harness

If the regression you want to catch can't be expressed as a read-only HTTP assertion (e.g. timing, GUI rendering, audio pipeline correctness), **say so in the PR description and add a follow-up issue**. Don't bend the harness around it. The harness is narrow on purpose.
