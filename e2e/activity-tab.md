# Activity Tab — Manual Smoke Checklist

> Owner: Stream I.
> Source plan: `~/.claude/plans/for-ir-can-we-majestic-island.md` §Verification.
> Companion automated tests:
> - `Backend-Rust/tests/activity_endpoints.rs` (Rust integration)
> - `Desktop/Tests/ActivityModelsTests.swift` (Swift Codable round-trip)
>
> Run this checklist after every PR that touches the Activity surface
> (streams A–H) plus the post-merge sanity pass for the umbrella issue.
> Each item maps to a numbered §Verification step from the plan.

---

## Setup (once per session)

```bash
# 1. Build the daemon
cd ~/src/infinite-recall
cd Backend-Rust && cargo build --release && cd ..

# 2. Start the daemon (point at a clean DB so pause-state assertions are deterministic)
export INFINITE_RECALL_DB="$HOME/Library/Application Support/Omi/users/anonymous/omi.db"
./Backend-Rust/target/release/infinite-recall-api &
DAEMON_PID=$!

# 3. Capture the bearer token + bound port
TOKEN="$(cat "$HOME/Library/Application Support/InfiniteRecall/api-token.txt")"
PORT=7331   # default; check INFINITE_RECALL_BIND if overridden

# 4. Build + launch the Swift app
IR_APP_NAME="Infinite Recall" \
  IR_SKIP_BACKEND=1 IR_SKIP_AUTH=1 IR_SKIP_TUNNEL=1 IR_SKIP_PYTHON=1 \
  ./run.sh --yolo
```

Daemon logs go to stderr; app logs to `/private/tmp/omi-dev.log`.

Tear down at the end:

```bash
kill "$DAEMON_PID" 2>/dev/null
osascript -e 'tell application "Infinite Recall" to quit'
```

---

## Checklist

### Build sanity (Verification §1, §2)

- [ ] **§1** Swift package compiles clean.
  ```bash
  xcrun swift build -c debug --package-path Desktop
  ```
  Expected: `Build complete!`. Zero errors. Warnings are fine but not new ones from the activity Swift files.

- [ ] **§2** Rust activity tests pass.
  ```bash
  cd Backend-Rust && cargo test --features activity_test_wiring activity_endpoints
  ```
  Expected (post-Stream-A merge): all tests in `activity_endpoints.rs` pass; `0 ignored`. If any are still ignored, the printed reason names the missing stream.

### App launches with Activity tab (Verification §3, §4)

- [ ] **§3** App launches with the dev `run.sh` invocation (see Setup).
  Expected: window opens straight to main UI; no auth prompts; no Sentry/Firebase activity in console.

- [ ] **§4** `agent-swift` connects and Cmd+7 opens Activity.
  ```bash
  agent-swift connect --bundle-id com.omi.infinite-recall
  ```
  Press `Cmd+7`. Expected: sidebar selects the **Activity** row (icon
  `gauge.with.dots.needle.50percent`); main pane renders the Activity page
  with three stat cards, an In-flight section, a Live capture section, and
  an Empty state placeholder for the Queued section.

### In-flight populates ≤1s after work starts (Verification §5)

- [ ] **§5** Trigger a transcription job and confirm an in-flight row appears
      within ~1 second.
  Repro: speak into the mic for ~5s while audio capture is on, then stop.
  When the scheduler picks the segment up:
  - Activity tab's "In flight" section shows
    `Transcribing HH:MM:SS→HH:MM:SS (en)` (or the active locale).
  - The row appears within one 1-second tick of the scheduler claiming the
    work — not on next-window-focus.
  - When the handler completes, the row disappears within one tick.

### Snapshot endpoint shape over the wire (Verification §6)

- [ ] **§6** `curl` returns the full snapshot shape.
  ```bash
  curl -s -H "Authorization: Bearer $TOKEN" \
    "http://127.0.0.1:$PORT/v1/activity/snapshot" | jq .
  ```
  Expected fields (exact JSON keys, all required):
  - `kinds[]` — one row per `WorkKind`. Every row has
    `kind, in_flight, queued, failed, last_done_at, paused_until`.
  - `capture[]` — exactly two rows: `audio` and `screen`. Each has
    `kind, running, paused_until`.
  - `resources` — `cpu_percent (number), rss_mb (int), gpu_system_percent
    (number|null), thermal_state (one of nominal/fair/serious/critical),
    on_battery (bool), low_power (bool), process_breakdown[] (array of
    {name, pid, cpu_percent, rss_mb})`.
  - `processing_gate` — sum type tagged on `state` (issue #35):
    `{state: "allowed", since: iso8601}` OR
    `{state: "blocked", reason: <BlockReason>, since: iso8601,
      waiting_for: <WaitCondition>}` where `BlockReason` is one of
    `device_active|on_battery|thermal|locked|manual_pause` and
    `WaitCondition` is `{type: "idle_for", duration_secs: u64}` or
    `{type: "ac_power"|"thermal_cooldown"|"unlock"|"manual"}`.
  - `generated_at` — iso8601.

  Sample (truncated):
  ```json
  {
    "kinds": [
      { "kind": "transcribe", "in_flight": null, "queued": 0, "failed": 0,
        "last_done_at": "2026-04-26T14:21:58.000Z", "paused_until": null },
      ...
    ],
    "capture": [
      { "kind": "audio",  "running": true, "paused_until": null },
      { "kind": "screen", "running": true, "paused_until": null }
    ],
    "resources": { "cpu_percent": 12.4, "rss_mb": 256,
      "gpu_system_percent": 33.3, "thermal_state": "nominal",
      "on_battery": false, "low_power": false,
      "process_breakdown": [ {"name":"infinite-recall-api","pid":4242,
        "cpu_percent":12.4,"rss_mb":256} ] },
    "processing_gate": { "state": "allowed",
      "since": "2026-04-26T14:25:00Z" },
    "generated_at": "2026-04-26T14:25:30.512Z"
  }
  ```

### Pause OCR routes around the OCR drain (Verification §7)

- [ ] **§7a** Click "Pause OCR · 1 min" in the UI.
  Expected: row dims; countdown `Resumes HH:MM` appears; UI updates
  optimistically without waiting on the next 1s tick.

- [ ] **§7b** Confirm the daemon log skips OCR while paused.
  ```bash
  tail -f /private/tmp/omi-dev.log | grep -i ocr
  ```
  Expected for ~60s: no new `claim ocr` / `dispatch ocr` lines. Other kinds
  (transcribe, summarize) continue to drain normally.

- [ ] **§7c** After ~60s, OCR resumes automatically.
  Expected: countdown disappears; OCR drain lines reappear in the log
  within one tick.

### Pause Audio capture (Verification §8)

- [ ] **§8a** Click "Pause Audio · 5 min" in the UI.
  Expected: a confirm sheet appears: "Pausing audio will stop recording
  until <time>. Continue?" (wording may vary; sheet must mention the
  recording-stop side-effect).

- [ ] **§8b** Confirm the sheet.
  Expected:
  - Mic indicator stops; sidebar `AudioLevelNavItem` flatlines.
  - Capture section row for `audio` shows `running: false` with a
    `paused_until` countdown.
  - `curl .../v1/activity/snapshot | jq '.capture[] | select(.kind=="audio")'`
    returns the same `running: false` + `paused_until`.

- [ ] **§8c** Cancel the sheet.
  Expected: nothing changes; capture continues.

### Pause persistence across daemon restart (Verification §9)

- [ ] **§9** Pause OCR for 30 minutes via UI; quit IR (and the daemon);
      relaunch ~10 minutes later. Expected:
  - Activity tab opens with the OCR row already paused.
  - Countdown shows ~20 minutes remaining (original wall-time, not 30 from
    relaunch).
  - `curl` confirms `paused_until` is the same iso8601 timestamp it was
    pre-quit (within clock skew).

### Hidden-window polling suspends (Verification §10)

- [ ] **§10a** While Activity tab is visible, observe daemon access log:
  ```bash
  tail -f ~/Library/Logs/InfiniteRecall/access.log 2>/dev/null \
    || RUST_LOG=tower_http=debug ./Backend-Rust/target/release/infinite-recall-api 2>&1 \
       | grep --line-buffered '/v1/activity/snapshot'
  ```
  Expected: roughly one `GET /v1/activity/snapshot` per second.

- [ ] **§10b** Hide the IR window (`Cmd+H` or click another app).
      Wait 30 seconds.
      Expected: zero new snapshot fetches in that window.

- [ ] **§10c** Bring the window back to focus.
      Expected: snapshot fetches resume within one second.

### Empty-state and gate messaging (Plan §UX scenarios 5, 6, 7)

- [ ] **UX 2 (most common)** With keyboard activity within last 2 minutes:
      banner reads `Waiting for idle — N items queued. Resumes after 2 min idle.`
      No new in-flight rows appear while gate is `device_active`.

- [ ] **UX 5** Empty queue + idle: banner reads
      `Up to date — 0 queued.` (or similar).

- [ ] **UX 7** On battery: banner reads
      `Waiting for AC power — N items queued.` and `processing_gate.reason`
      from `curl` is `on_battery`.

### Loopback `_internal/inflight` is reachable (sanity)

- [ ] Manually POST a fake in-flight update and confirm the snapshot updates.
  ```bash
  curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
       -H "Content-Type: application/json" \
       -d '{"kind":"transcribe","in_flight":{"label":"manual probe","started_at":"2026-04-26T14:22:03.812Z"}}' \
       "http://127.0.0.1:$PORT/v1/activity/_internal/inflight" -o /dev/null -w "%{http_code}\n"
  # Expected: 204
  curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/v1/activity/snapshot" \
    | jq '.kinds[] | select(.kind=="transcribe") | .in_flight'
  # Expected: { "label": "manual probe", "started_at": "..." }
  ```
  Then clear it:
  ```bash
  curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
       -H "Content-Type: application/json" \
       -d '{"kind":"transcribe","in_flight":null}' \
       "http://127.0.0.1:$PORT/v1/activity/_internal/inflight" -o /dev/null -w "%{http_code}\n"
  # Expected: 204; subsequent snapshot has transcribe.in_flight == null
  ```

### Auth (defensive)

- [ ] Activity routes 401 without a bearer.
  ```bash
  curl -s -o /dev/null -w "%{http_code}\n" \
    "http://127.0.0.1:$PORT/v1/activity/snapshot"
  # Expected: 401
  ```

- [ ] Activity routes 401 with a wrong bearer.
  ```bash
  curl -s -o /dev/null -w "%{http_code}\n" \
    -H "Authorization: Bearer wrong-token" \
    "http://127.0.0.1:$PORT/v1/activity/snapshot"
  # Expected: 401
  ```

---

## Sign-off

- [ ] All boxes above checked.
- [ ] No new errors in `/private/tmp/omi-dev.log` during the run
      (ignore pre-existing noise).
- [ ] Tester: ___________________________  Date: ___________
- [ ] PR / commit SHA: __________________
