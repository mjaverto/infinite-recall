import Foundation

/// Background drain loop for the local integration outbox.
///
/// Single in-process consumer. Driven by:
/// - `start()` once at app launch (idempotent),
/// - `LocalIntegrationOutboxDelegate.outboxDidEnqueue(_:)` from the storage
///   actor right after a write commits,
/// - `kick()` from anywhere (including the dispatcher's defensive kick).
///
/// State machine is simple:
///   idle → kick() → running [→ rerun-after if kick()'d mid-pass] → idle/sleep.
/// Concurrency is the actor isolation of `@MainActor` — there is exactly one
/// drain task at a time, and the `rerunAfter` flag coalesces extra kicks.
/// Sleeps between passes (when the outbox has rows but none due yet) are
/// implemented as a stored `Task` we can cancel from `kick()`.
@MainActor
final class LocalIntegrationDrainService: LocalIntegrationOutboxDelegate {
  static let shared = LocalIntegrationDrainService()
  private init() {}

  /// Posted on the main thread after every per-row outcome is applied
  /// (success/retry/permanentFailure). UI surfaces (e.g. `MyAppsSection`)
  /// listen so pending-count badges and `lastError` reflect drain progress
  /// without polling.
  static let progressNotification = Notification.Name("LocalIntegrationDrainServiceProgress")

  // MARK: - Backoff schedule
  // 30s, 1m, 5m, 15m, 1h, 1h, 1h, … (cap at 1h, no max attempts).
  private static let backoffSchedule: [TimeInterval] = [30, 60, 5 * 60, 15 * 60, 60 * 60]

  /// Permanent-failure rows park 30 days out. Manual "Retry now" still works.
  private static let permanentFailureSleep: TimeInterval = 30 * 24 * 60 * 60

  /// Per-pass row cap — keeps a single tick bounded so `kick()` stays
  /// responsive even with a huge backlog. Matches the storage default.
  private static let drainBatchLimit = 50

  // MARK: - Drain state

  /// The currently-running drain `Task`, if any. Used both for "is a drain
  /// already running" detection and so future cancel paths can reach it.
  private var runningTask: Task<Void, Never>?

  /// If `kick()` arrives while a drain is running, set this flag so the
  /// drain runs one more pass after the current one completes. This catches
  /// the race where new enqueues commit between `fetchDue` and pass-end.
  private var rerunAfter: Bool = false

  /// Pending sleep-until-next-due task, so `kick()` can cancel a sleep and
  /// drain immediately.
  private var pendingWakeTask: Task<Void, Never>?

  /// Idempotent flag for `start()`.
  private var didStart: Bool = false

  // MARK: - Public API

  /// Call once at app launch (after `RewindDatabase.shared.initialize()`).
  /// Registers as the outbox delegate and triggers an initial drain so any
  /// rows left over from a previous session start moving immediately.
  func start() async {
    if didStart { return }
    didStart = true
    await LocalIntegrationOutboxStorage.shared.setDelegate(self)
    log("LocalIntegrationDrainService: started")
    kick()
  }

  /// Manual / post-enqueue trigger. Cheap, idempotent, safe to call from
  /// any `@MainActor` context. Coalesces concurrent calls.
  func kick() {
    // Cancel any pending sleep — we want to drain now.
    pendingWakeTask?.cancel()
    pendingWakeTask = nil

    if runningTask != nil {
      // A drain is already active. Mark "run again afterwards" and let it
      // finish; the trailing run will pick up whatever was just enqueued.
      rerunAfter = true
      return
    }

    runningTask = Task { @MainActor [weak self] in
      await self?.drainLoop()
    }
  }

  // MARK: - LocalIntegrationOutboxDelegate

  /// Called from the outbox actor's serial executor after an enqueue
  /// commits. Hop to MainActor and kick.
  nonisolated func outboxDidEnqueue(_ storage: LocalIntegrationOutboxStorage) {
    Task { @MainActor [weak self] in
      self?.kick()
    }
  }

  // MARK: - Drain loop

  /// One drain "session". Loops over passes until: (a) outbox is empty
  /// (idle), or (b) outbox has rows but none are due (schedule sleep).
  /// Any `rerunAfter` flag set during a pass forces another immediate pass.
  private func drainLoop() async {
    defer {
      runningTask = nil
    }

    repeat {
      rerunAfter = false
      let result = await runOnePass()
      // Trailing kick takes priority over sleeping.
      if rerunAfter {
        continue
      }
      switch result {
      case .empty:
        // Nothing left in the outbox at all — go fully idle.
        return
      case .moreImmediately:
        // Hit the batch limit; drain again with no delay.
        continue
      case .scheduleAt(let wakeAt):
        // Outbox non-empty but nothing currently due. Schedule a wake.
        scheduleWake(at: wakeAt)
        return
      }
    } while true
  }

  private enum PassResult {
    /// Outbox is empty — drain can idle.
    case empty
    /// Batch limit hit, more due rows likely waiting. Drain again now.
    case moreImmediately
    /// Outbox non-empty but nothing due now; wake at this time.
    case scheduleAt(Date)
  }

  /// One drain pass: fetch due batch, dispatch each row, return next-step.
  private func runOnePass() async -> PassResult {
    let now = Date()

    let due: [LocalIntegrationOutboxRecord]
    do {
      due = try await LocalIntegrationOutboxStorage.shared.fetchDue(
        now: now,
        limit: Self.drainBatchLimit
      )
    } catch {
      logError("LocalIntegrationDrainService: fetchDue failed", error: error)
      // Treat as transient — back off briefly so we don't busy-loop on a
      // broken DB.
      return .scheduleAt(now.addingTimeInterval(60))
    }

    if due.isEmpty {
      // No due rows. Find out if the outbox is empty (idle) or just
      // waiting (schedule).
      return await scheduleAfterEmptyDue(now: now)
    }

    log("LocalIntegrationDrainService: pass start dueCount=\(due.count)")

    // Snapshot registry once for the whole pass.
    let allIntegrations: [LocalIntegrationRecord]
    let enabledIntegrations: [LocalIntegrationRecord]
    do {
      allIntegrations = try await LocalIntegrationStorage.shared.listAll()
      enabledIntegrations = try await LocalIntegrationStorage.shared.listEnabled()
    } catch {
      logError("LocalIntegrationDrainService: registry snapshot failed", error: error)
      return .scheduleAt(now.addingTimeInterval(60))
    }

    let validIds: Set<String> = Set(allIntegrations.map(\.id))
    var enabledById: [String: LocalIntegrationRecord] = [:]
    for integration in enabledIntegrations {
      enabledById[integration.id] = integration
    }

    var sawOrphan = false

    for row in due {
      // Orphaned (integration row deleted)? Skip; sweep at end of pass.
      if !validIds.contains(row.integrationId) {
        sawOrphan = true
        log("LocalIntegrationDrainService: row id=\(row.id ?? -1) orphan integration=\(row.integrationId)")
        continue
      }

      // Disabled (but not deleted)? Leave the row in place. Don't touch
      // nextRetryAt — when the user re-enables, the existing nextRetryAt
      // is already in the past so the next drain picks it up.
      guard let integration = enabledById[row.integrationId] else {
        log("LocalIntegrationDrainService: row id=\(row.id ?? -1) integration=\(row.integrationId) disabled, skipping")
        continue
      }

      await dispatch(row: row, integration: integration, now: now)
    }

    if sawOrphan {
      do {
        let removed = try await LocalIntegrationOutboxStorage.shared.deleteOrphans(
          validIntegrationIds: validIds
        )
        if removed > 0 {
          log("LocalIntegrationDrainService: swept \(removed) orphan row(s)")
        }
      } catch {
        logError("LocalIntegrationDrainService: deleteOrphans failed", error: error)
      }
    }

    // If we hit the batch limit, more rows are likely due — drain again.
    if due.count >= Self.drainBatchLimit {
      return .moreImmediately
    }

    // Otherwise figure out next wake.
    return await scheduleAfterEmptyDue(now: Date())
  }

  /// Decide how the loop should idle when no rows are currently due.
  /// Re-queries the outbox so we react to rows we just rescheduled.
  private func scheduleAfterEmptyDue(now: Date) async -> PassResult {
    // Look one second ahead — fetchDue uses `<= now`, so anything we just
    // pushed to `now + backoff` is by definition NOT due.
    let stillDue: [LocalIntegrationOutboxRecord]
    do {
      stillDue = try await LocalIntegrationOutboxStorage.shared.fetchDue(now: now, limit: 1)
    } catch {
      logError("LocalIntegrationDrainService: fetchDue (post-pass) failed", error: error)
      return .scheduleAt(now.addingTimeInterval(60))
    }

    if !stillDue.isEmpty {
      // Something became due during the pass — drain again now.
      return .moreImmediately
    }

    // No due rows. Find the soonest pending row, if any. We re-use
    // fetchDue with a far-future "now" to grab the row with the smallest
    // nextRetryAt. (Storage doesn't expose a dedicated "min" query; one
    // small read is fine.)
    let farFuture = now.addingTimeInterval(Self.permanentFailureSleep + 60)
    let upcoming: [LocalIntegrationOutboxRecord]
    do {
      upcoming = try await LocalIntegrationOutboxStorage.shared.fetchDue(now: farFuture, limit: 1)
    } catch {
      logError("LocalIntegrationDrainService: fetchDue (upcoming) failed", error: error)
      return .scheduleAt(now.addingTimeInterval(60))
    }

    guard let next = upcoming.first else {
      // Outbox is empty.
      return .empty
    }
    return .scheduleAt(next.nextRetryAt)
  }

  // MARK: - Per-row dispatch

  private func dispatch(
    row: LocalIntegrationOutboxRecord,
    integration: LocalIntegrationRecord,
    now: Date
  ) async {
    let outcome: DispatchOutcome

    switch integration.kindEnum {
    case .webhook:
      // Force-unwrap matches spec; payloadJson is UTF-8 by construction
      // (encodedJSON() ⇒ String(data:utf8) ⇒ persisted). Defend anyway.
      let bodyData = row.payloadJson.data(using: .utf8) ?? Data()
      outcome = await WebhookSender.send(
        payload: bodyData,
        to: integration.webhookURL ?? ""
      )

    case .filesystem:
      // Rebuild MemoryPayload from the snapshot (NOT from APIClient — the
      // outbox row is authoritative).
      let bodyData = row.payloadJson.data(using: .utf8) ?? Data()
      let bookmark = integration.folderBookmark ?? Data()
      if bookmark.isEmpty {
        outcome = .permanentFailure(reason: "no folder bookmark")
        break
      }
      let payload: MemoryPayload
      do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        payload = try decoder.decode(MemoryPayload.self, from: bodyData)
      } catch {
        // Snapshot is unparseable — never going to work. Permanent.
        outcome = .permanentFailure(reason: "payload decode failed: \(error.localizedDescription)")
        break
      }
      let result = await FilesystemWriter.write(
        payload: payload,
        payloadJSON: bodyData,
        format: integration.formatEnum ?? .json,
        bookmark: bookmark
      )
      // Persist the refreshed bookmark before processing the outcome so a
      // crash here doesn't lose the new bookmark.
      if let refreshed = result.refreshedBookmark {
        var updated = integration
        updated.folderBookmark = refreshed
        do {
          try await LocalIntegrationStorage.shared.update(updated)
        } catch {
          logError("LocalIntegrationDrainService: persist refreshed bookmark failed integration=\(integration.id)", error: error)
        }
      }
      outcome = result.outcome

    case .none:
      // Unknown kind raw value — treat as permanent so the row doesn't
      // spin forever.
      outcome = .permanentFailure(reason: "unknown integration kind: \(integration.kind)")
    }

    await applyOutcome(outcome, row: row, integrationId: integration.id, now: now)
  }

  private func applyOutcome(
    _ outcome: DispatchOutcome,
    row: LocalIntegrationOutboxRecord,
    integrationId: String,
    now: Date
  ) async {
    guard let rowId = row.id else {
      logError("LocalIntegrationDrainService: outbox row missing id (memory=\(row.memoryId)), skipping")
      return
    }
    switch outcome {
    case .success:
      // markSuccess (DELETE row) FIRST so a successful delivery can't
      // re-fire on the next pass even if the integration-row update fails.
      // If the DELETE itself fails, push the row out via markFailure so we
      // don't busy-loop redelivering.
      var deletedRow = false
      do {
        try await LocalIntegrationOutboxStorage.shared.markSuccess(id: rowId)
        deletedRow = true
      } catch {
        logError("LocalIntegrationDrainService: markSuccess failed id=\(rowId) — pushing row out to avoid duplicate delivery", error: error)
        let nextRetry = now.addingTimeInterval(backoff(forAttempts: row.attempts + 1))
        try? await LocalIntegrationOutboxStorage.shared.markFailure(
          id: rowId,
          error: "post-success cleanup failed: \(error.localizedDescription)",
          nextRetryAt: nextRetry
        )
      }
      do {
        try await LocalIntegrationStorage.shared.recordSuccess(id: integrationId, at: now)
      } catch {
        logError("LocalIntegrationDrainService: recordSuccess failed integration=\(integrationId)", error: error)
      }
      log("LocalIntegrationDrainService: row id=\(rowId) integration=\(integrationId) success deletedRow=\(deletedRow)")
      NotificationCenter.default.post(name: Self.progressNotification, object: nil)

    case .retry(let reason):
      let newAttempts = row.attempts + 1
      let nextRetry = now.addingTimeInterval(backoff(forAttempts: newAttempts))
      do {
        try await LocalIntegrationOutboxStorage.shared.markFailure(
          id: rowId,
          error: reason,
          nextRetryAt: nextRetry
        )
      } catch {
        logError("LocalIntegrationDrainService: markFailure (retry) failed id=\(rowId)", error: error)
      }
      do {
        try await LocalIntegrationStorage.shared.recordFailure(id: integrationId, error: reason)
      } catch {
        logError("LocalIntegrationDrainService: recordFailure (retry) failed integration=\(integrationId)", error: error)
      }
      log("LocalIntegrationDrainService: row id=\(rowId) integration=\(integrationId) retry attempts=\(newAttempts) reason=\(reason) nextRetryAt=\(nextRetry)")
      NotificationCenter.default.post(name: Self.progressNotification, object: nil)

    case .permanentFailure(let reason):
      let nextRetry = now.addingTimeInterval(Self.permanentFailureSleep)
      do {
        try await LocalIntegrationOutboxStorage.shared.markFailure(
          id: rowId,
          error: reason,
          nextRetryAt: nextRetry
        )
      } catch {
        logError("LocalIntegrationDrainService: markFailure (permanent) failed id=\(rowId)", error: error)
      }
      do {
        try await LocalIntegrationStorage.shared.recordFailure(id: integrationId, error: reason)
      } catch {
        logError("LocalIntegrationDrainService: recordFailure (permanent) failed integration=\(integrationId)", error: error)
      }
      log("LocalIntegrationDrainService: row id=\(rowId) integration=\(integrationId) permanentFailure reason=\(reason) nextRetryAt=\(nextRetry)")
      NotificationCenter.default.post(name: Self.progressNotification, object: nil)
    }
  }

  /// Map post-increment attempts (1 = first failure) to a backoff seconds
  /// value off the schedule, capping on the last entry.
  private func backoff(forAttempts attempts: Int) -> TimeInterval {
    let idx = min(max(attempts - 1, 0), Self.backoffSchedule.count - 1)
    return Self.backoffSchedule[idx]
  }

  // MARK: - Sleep / wake

  /// Schedule the next drain pass at `wakeAt`. Stored task so `kick()` can
  /// cancel and drain immediately.
  private func scheduleWake(at wakeAt: Date) {
    pendingWakeTask?.cancel()
    let delay = max(wakeAt.timeIntervalSinceNow, 0)
    log("LocalIntegrationDrainService: idle until \(wakeAt) (in \(Int(delay))s)")
    pendingWakeTask = Task { @MainActor [weak self] in
      let nanos = UInt64(delay * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanos)
      // If cancelled, kick() already triggered the next drain.
      if Task.isCancelled { return }
      self?.pendingWakeTask = nil
      self?.kick()
    }
  }
}
