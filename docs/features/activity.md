# Activity

The Activity page is a live dashboard of what Infinite Recall is doing at any given moment. It shows capture status, which jobs are running, what is queued, why processing might be paused, and how much CPU, memory, and GPU the pipelines are consuming. If you are wondering "why isn't it processing?" or "what is it doing right now?", this is the page to check.

## What you see

**Processing-gate banner.** A color-coded banner at the top of the page states whether the processing gate is open or paused, and if paused, exactly why. No guessing required.

**Resource cards.** A row of cards shows current system load. The CPU card displays overall usage and can be expanded to break out the Swift app, the Rust daemon (`infinite-recall-api`), and the `mlx-lm.server` model process individually. A memory card shows total usage in MB across those same processes. A GPU card shows system-wide GPU utilization so you can see what the vision model is doing.

**In-flight section.** One row per work kind currently executing — for example "Transcribing audio", "OCR", "Memory extraction", "Summarising conversation". If nothing is running, this section is empty.

**Live capture section.** Shows the current state of audio capture and screen capture, each with a pause/resume toggle.

**Queued section.** Pending and failed work counts per job kind. Lets you see how much has accumulated while processing was paused.

**Run now button.** Forces a single drain pass against the queue, bypassing the idle requirement. Not available under thermal cooldown, when the screen is locked, or when you have manually paused processing.

**Unload model memory button.** Evicts the loaded text and vision models from RAM. Useful when you need that memory back immediately. The model restarts automatically on its next call.

**Error banner.** A dismissible banner appears when a pause, resume, or snapshot action fails, so you know when something did not go through.

## What you can do

- Read the gate banner to understand exactly why processing is paused.
- Pause or resume audio capture.
- Pause or resume screen capture.
- Force queued work to run immediately by pressing Run now (subject to the restrictions below).
- Free the local LLM from memory by pressing Unload model memory; launchd restarts it within seconds when it is next needed.
- Dismiss error toasts after a failed action.

## States

The processing gate can be in one of these states:

| State | Meaning |
|---|---|
| Open | Processing is running normally. |
| Thermal cooldown | The Mac is too hot; pipelines are throttled until it cools. |
| Waiting for AC power | The device is on battery or in low-power mode; queued work will drain when you plug in. |
| Screen locked | The screen is locked; processing pauses on the assumption you may have stepped away intentionally. |
| Device active | Only relevant for the subset of jobs that require idle time; lightweight jobs continue regardless. |
| Manual pause | You explicitly paused processing. |
| Initialising | The app is starting up and the gate is not yet ready. |

## Behind the scenes

**The processing gate.** `ProcessingGateReporter` aggregates state from the OS — idle time, screen lock status, AC vs. battery, low-power mode, and thermal pressure — alongside the app's own pause flags. It exposes a single signal: gate open, or gate denied with a reason code. The Activity page renders that signal directly; it does not make its own scheduling decisions.

**What runs on AC vs. idle+AC.** Not every job needs you to step away from the machine. Lightweight, latency-sensitive work — transcription, OCR, memory extraction, and action-item extraction — starts as soon as the device is on AC power, even while you are actively typing. Heavier work — full conversation summarisation and knowledge-graph extraction — waits until the Mac is also idle (no mouse or keyboard input for roughly 60 seconds). This split keeps the UI responsive: a 32B-parameter LLM inference pass should not stutter your cursor mid-sentence.

**Battery and low-power gating.** `BatteryAwareScheduler` pauses all pipeline work except the real-time UI when the device is on battery or macOS low-power mode is active. Work accumulates in a `pending_work` table and drains automatically when AC power is restored.

**Live polling.** While the Activity tab is visible, the page polls the capture services, the gate reporter, and the process metrics every couple of seconds. Polling stops when you navigate away to avoid unnecessary overhead.

**Resource cards.** CPU and memory figures are sampled from three processes: the Swift app, `infinite-recall-api` (the local Rust daemon), and `mlx-lm.server`. The expandable CPU card breaks these out per process. The GPU card reflects system-wide usage rather than per-process, which is sufficient to see whether the vision model is active.

**Run now.** Triggering this button forces one drain pass against the pending queue, bypassing the idle requirement. It deliberately refuses to override hard blockers: thermal cooldown (continuing would risk damaging the hardware), screen lock (you may have walked away), and manual pause (you explicitly said stop). Overriding idle-only gating is safe; overriding those three is not.

**Unload model memory.** This calls `IdleAIController` to evict the loaded text and vision models from RAM — roughly 13–17 GB combined, depending on which models you have selected. The next call to either model triggers an automatic launchd restart within seconds, so there is no manual reload step.

## Source

- `Desktop/Sources/Activity/ActivityPage.swift`
- `Desktop/Sources/Activity/ProcessingGateReporter.swift`
- `Desktop/Sources/Power/BatteryAwareScheduler.swift`
- `Desktop/Sources/PowerWorkBridge.swift`
- `Desktop/Sources/AI/IdleAIController.swift`
