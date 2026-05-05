# Activity Tab — Phase 0 Contract (FROZEN)

> Owner: Phase 0 contract-agent (issue #10).
> Consumers: Phase 1 streams A–I (issues TBD; see umbrella #9).
> Any change to this file requires a `stream 0-contract amendment` issue
> and a re-freeze; downstream streams must pause work until merged.

## Goals

In-app **Activity** tab giving the user:
1. Live process-tree CPU/memory + system-wide GPU.
2. Human-readable in-flight task list, one row per `WorkKind`.
3. Per-kind / per-capture **Pause for N min** with persistence across restart.
4. Honest explanation of *why* nothing is in-flight (idle gate vs battery
   vs thermal vs locked vs manual pause).

See `~/.claude/plans/for-ir-can-we-majestic-island.md` for full plan.

---

## REST surface

All routes auth via existing bearer token (`Authorization: Bearer <token>`).
All bodies + responses are JSON. Prefix: `/v1`.

```
GET  /v1/activity/snapshot                  → 200 ActivitySnapshot
POST /v1/activity/pause                     → 200 { "paused_until": "<iso8601>" }
POST /v1/activity/resume                    → 204
POST /v1/activity/_internal/inflight        → 204    (loopback only)
POST /v1/activity/_internal/gate-state      → 204    (loopback only, issue #32)
```

The `_internal/*` routes are Swift→Rust loopback. The daemon binds to
`127.0.0.1` only (`lib.rs`), so loopback is enforced by the listener; bearer
auth still applies via the `authed` middleware.

---

## JSON shapes

Field names are snake_case on the wire. Swift mirrors live in
`Desktop/Sources/Activity/ActivityModels.swift` (see `CodingKeys`).

### `ActivitySnapshot` (response of GET snapshot)

```json
{
  "kinds": [
    {
      "kind": "transcribe",
      "in_flight": { "label": "Transcribing 14:22:01→14:25:00 (en)",
                     "started_at": "2026-04-26T14:22:03.812Z" },
      "queued": 47,
      "failed": 0,
      "last_done_at": "2026-04-26T14:21:58.000Z",
      "paused_until": null
    }
  ],
  "capture": [
    { "kind": "audio",  "running": true,  "paused_until": null },
    { "kind": "screen", "running": true,  "paused_until": null }
  ],
  "resources": {
    "cpu_percent": 142.0,
    "mem_mb": 2342,
    "gpu_system_percent": 38.0,
    "thermal_state": "fair",
    "on_battery": false,
    "low_power": false,
    "process_breakdown": [
      { "name": "api",     "pid": 1234, "cpu_percent": 12.4, "mem_mb": 84,   "kind": "core" },
      { "name": "swift",   "pid": 1235, "cpu_percent": 51.2, "mem_mb": 760,  "kind": "core" },
      { "name": "mlx-lm",  "pid": 1236, "cpu_percent": 78.4, "mem_mb": 1498, "kind": "local_model" },
      { "name": "mlx-vlm", "pid": 1237, "cpu_percent": 14.0, "mem_mb": 1102, "kind": "local_model" }
    ]
  },
  "processing_gate": {
    "state":       "blocked",
    "reason":      "device_active",
    "since":       "2026-04-26T14:25:00.000Z",
    "waiting_for": { "type": "idle_for", "duration_secs": 120 }
  },
  "generated_at": "2026-04-26T14:25:30.512Z"
}
```

### `ProcessBreakdown.kind` — optional classifier

Each row in `resources.process_breakdown` may carry an optional `kind`
discriminator the UI uses to group rows (e.g. a "Local Models" subhead).

| Variant | Wire value | Meaning |
|---|---|---|
| `Core` | `"core"` | IR-spawned core process (`api`, `swift`). |
| `LocalModel` | `"local_model"` | IR-spawned local-model server (`mlx-lm`, `mlx-vlm`). |

The field is **optional in both directions**:

- An older daemon (pre-this-PR) emits no `kind` at all — newer clients must
  treat that as "unknown" and render the row in the default partition.
- An older client decoding a payload that contains `kind` must tolerate
  unknown future variants without throwing; the Swift mirror in
  `ActivityModels.swift` decodes anything outside the known set as
  `.unknown`.

Wire-level: serialised with `serde(default, skip_serializing_if = "Option::is_none")`,
so the field is silently absent when the daemon doesn't know the kind.

### `GateState` — sum type (issue #35)

`GateState` is an internally-tagged sum on the `state` field. The pre-#35
flat shape (`{allowed: bool, reason: enum, waiting_for: string?}`) is gone:
it permitted illegal combinations like `{allowed: true, reason: "locked"}`
and a stringly-typed `waiting_for`.

```json
// Allowed — work is draining. No `reason`/`waiting_for` (not meaningful).
{ "state": "allowed", "since": "2026-04-26T14:25:00.000Z" }

// Blocked — `reason` is a typed `BlockReason`, `waiting_for` is a typed
// `WaitCondition`. Both are required when `state == "blocked"`.
{
  "state":       "blocked",
  "reason":      "device_active",
  "since":       "2026-04-26T14:25:00.000Z",
  "waiting_for": { "type": "idle_for", "duration_secs": 120 }
}
```

`WaitCondition` is also an internally-tagged sum on `type`:

| Variant | Wire shape |
|---|---|
| `IdleFor(Duration)` | `{"type":"idle_for","duration_secs":<u64>}` |
| `AcPower` | `{"type":"ac_power"}` |
| `ThermalCooldown` | `{"type":"thermal_cooldown"}` |
| `Unlock` | `{"type":"unlock"}` |
| `Manual` | `{"type":"manual"}` |

### Enums (string-valued)

| Field | Allowed values |
|---|---|
| `KindRow.kind` / `WorkKind` | `transcribe`, `ocr`, `summarize`, `extract_memory`, `extract_action_items`, `extract_kg` |
| `CaptureRow.kind` / `CaptureKind` | `audio`, `screen` |
| `PauseRequest.target` / `ResumeRequest.target` / `PauseTargetId` | `kind`, `capture` (with typed `id` payload — see below) |
| `ResourceSample.thermal_state` / `ThermalState` | `nominal`, `fair`, `serious`, `critical` |
| `ProcessBreakdown.kind` / `ProcessKind` (optional) | `core`, `local_model`, `unknown` (field omitted when daemon doesn't classify; both Rust and Swift decoders fold any future wire value into `unknown` for forward-compat) |
| `GateState` (variant tag on `state`) | `allowed`, `blocked` |
| `GateState.reason` / `BlockReason` (only when `state="blocked"`) | `device_active`, `on_battery`, `thermal`, `locked`, `initializing` (issue #128: `manual_pause` pruned — no producer existed) |

### `PauseRequest` / `ResumeRequest`

```json
// POST /v1/activity/pause
{ "target": "kind", "id": "ocr", "minutes": 15 }

// POST /v1/activity/resume
{ "target": "capture", "id": "audio" }
```

For `target: "kind"`, `id` is a `WorkKind` snake_case string.
For `target: "capture"`, `id` is `"audio"` or `"screen"`.

`minutes` MUST be `> 0` (Rust enforces via `NonZeroU32` at the serde layer; a
zero or negative value is rejected with `400 Bad Request` before any handler
runs). Any `(target, id)` combo not in the matrix above is also rejected at
the serde layer — `target` and `id` form a typed sum (`PauseTargetId`) so
`{"target":"kind","id":"audio"}` is unrepresentable on both sides.

### `InflightUpdate` (Swift → Rust loopback)

```json
// POST /v1/activity/_internal/inflight
{ "kind": "transcribe",
  "in_flight": { "label": "Transcribing 14:22:01→14:25:00 (en)",
                 "started_at": "2026-04-26T14:22:03.812Z" } }

// Clearing the slot:
{ "kind": "transcribe", "in_flight": null }
```

### `GateState` POST (Swift → Rust loopback, issue #32)

The Swift `ProcessingGateReporter` polls OS signals (CGEvent idle seconds,
screen lock state, power source / low-power-mode, thermal pressure) every
~3s and POSTs the resulting `GateState` here when (and only when) the value
changes. Body shape is exactly `GateState` — see above for both variants.

```json
// POST /v1/activity/_internal/gate-state
// (Allowed)
{ "state": "allowed", "since": "2026-04-26T14:25:00.000Z" }

// (Blocked — every Blocked POST must include reason + waiting_for.)
{ "state": "blocked",
  "reason": "device_active",
  "since": "2026-04-26T14:25:00.000Z",
  "waiting_for": { "type": "idle_for", "duration_secs": 120 } }
```

`BridgedProcessingGate` (the production `ProcessingGate` impl) seeds itself
with `Blocked { reason: "initializing", waiting_for: { "type": "manual" } }` on
daemon startup and overwrites that on the first POST. The `initializing` window
is typically ~3s.

---

## Internal Rust traits

Stream A wires; B/C/D and the idle-gate agent implement.

```rust
trait PauseStore : Send + Sync {
    fn paused_until(&self, target: &PauseTargetId) -> Option<DateTime<Utc>>;
    fn pause       (&self, target: &PauseTargetId, minutes: NonZeroU32)
                       -> Result<DateTime<Utc>, PauseStoreError>;
    fn resume      (&self, target: &PauseTargetId) -> Result<bool, PauseStoreError>;
}

trait InflightRegistry : Send + Sync {
    fn snapshot(&self) -> HashMap<WorkKind, InFlight>;
    fn update  (&self, kind: WorkKind, in_flight: Option<InFlight>);
}

trait ResourceSampler : Send + Sync {
    fn sample(&self) -> ResourceSample;     // expected to cache ~1s
}

trait ProcessingGate : Send + Sync {
    fn current(&self) -> GateState;
}
```

`AppState` extended with:
```rust
pub pause_store:     Arc<dyn PauseStore>,
pub inflight:        Arc<dyn InflightRegistry>,
pub resource_sampler:Arc<dyn ResourceSampler>,
pub processing_gate: Arc<dyn ProcessingGate>,
```

Stream A owns the AppState mutation. B/C/D do not edit `state.rs`.

---

## File ownership map

| Stream | Owns (new) | Touches (append-only) |
|---|---|---|
| 0 (this PR) | `activity/{mod,types,traits,pause_store,resources,inflight}.rs`, `activity/contract.md`, `routes/activity.rs`, `Desktop/Sources/Activity/{ActivityModels,ActivityMonitorService,ActivityPage,WorkLabels,CapturePauseGate}.swift` | `main.rs`, `routes/mod.rs` (registers `mod activity` only) |
| A | `routes/activity.rs` (flesh out) | `routes/mod.rs` (`// === activity routes ===` block), `state.rs`, `main.rs` |
| B | `activity/pause_store.rs` (flesh out), `migrations/NNNN_paused_work.sql` | — |
| C | `activity/resources.rs` (flesh out) | `Cargo.toml` (add `libproc`) |
| D | `activity/inflight.rs` (flesh out) | — |
| E | `Activity/ActivityPage.swift` (flesh out), `Activity/WorkLabels.swift` (flesh out) | `MainWindow/SidebarView.swift`, `MainWindow/DesktopHomeView.swift`, `OmiApp.swift` |
| F | `Activity/ActivityMonitorService.swift` (flesh out), `Activity/ActivityModels.swift` (already shipped) | `APIClient.swift` (append-only) |
| G | — | `Power/BatteryAwareScheduler.swift` |
| H | `Activity/CapturePauseGate.swift` (flesh out) | `AudioCaptureService.swift`, `ScreenCaptureService.swift` |
| I | `Backend-Rust/tests/activity_endpoints.rs`, `Desktop/Tests/ActivityModelsTests.swift`, `e2e/activity-tab.md` | — |

All append-only edits MUST use bracket comments:
```
// === activity:<stream> ===
...
// === /activity:<stream> ===
```
to keep merge conflicts to single-line resolutions.

---

## Notification names + UserDefaults keys

Defined in `Desktop/Sources/Activity/ActivityModels.swift`:

| Constant | Value | Owner |
|---|---|---|
| `ActivityNotifications.pauseChanged` | `"activityPauseChanged"` | H posts; H/G observe |
| `ActivityDefaultsKeys.lastGateStateJSON` | `"activity.lastGateStateJSON"` | F |

---

## Coordination notes

- **Idle-gate agent.** A separate agent ships the device-idle/locked
  processing gate. The `ProcessingGate` trait + `GateState` struct in this
  contract are the seam. If their work lands first with a different
  `GateState` shape, Stream A is responsible for an adapter — but the
  on-the-wire `GateState` JSON in this contract MUST NOT change without an
  amendment.
- **Pause semantics.** Pause stops the *next* claim; in-flight handler
  runs to completion (no cancellation refactor in scope). Pause + idle gate
  AND together (whichever is later wins).
- **Capture pause** triggers a confirm sheet in the UI ("recording will
  stop"); the pause itself just stops the running capture and refuses
  restart until `paused_until` passes.
- **Pause persistence.** SQLite table `paused_work` (Stream B) keyed by
  `(target, id)` with absolute `resume_at` unix-seconds.
- **Hidden window** suspends polling (Stream F). UI MUST NOT poll the
  Rust daemon while `NSWindow.didResignKey`.
