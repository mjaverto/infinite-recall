import Foundation

/// Fan-out point from the `memory_created` WebSocket event and from the
/// Layer-2 atomic-memory insert path to the local integration outbox.
///
/// In this fork the `memory_created` event actually delivers a finished
/// CONVERSATION (legacy Omi naming). The dispatcher resolves the
/// conversation by ID via `APIClient.getConversation(id:)`, serializes one
/// canonical `MemoryPayload` JSON snapshot, and enqueues one outbox row per
/// enabled integration. The outbox actor's post-commit delegate kicks the
/// drain service automatically; we also kick it defensively here so a
/// fresh launch with no pre-existing rows still drains immediately.
///
/// Layer-2 atomic memories (extracted by FocusAssistant / MemoryAssistant /
/// InsightAssistant via `MemoryStorage.insertLocalMemory`) follow the same
/// fan-out via `enqueueDispatch(memory:)` — they share the same payload
/// shape and outbox row format so integrations can't tell the two layers
/// apart at the wire level.
///
/// Never throws — every error path logs and returns. A `memory_created`
/// event must not fail the WebSocket handler, and a memory insert must
/// never fail because an integration sender choked.
actor LocalIntegrationDispatcher {
  static let shared = LocalIntegrationDispatcher()
  private init() {}

  /// Resolve the conversation, snapshot the payload, and enqueue one row
  /// per enabled integration. Idempotent at the WebSocket layer is the
  /// caller's responsibility — this method always enqueues.
  func enqueueDispatch(conversationId: String) async {
    // Resolve the conversation. On any error, log and bail — there is
    // nothing to enqueue without a payload.
    let conversation: ServerConversation
    do {
      conversation = try await APIClient.shared.getConversation(id: conversationId)
    } catch {
      logError("LocalIntegrationDispatcher: getConversation failed for id=\(conversationId)", error: error)
      return
    }

    await enqueue(payload: MemoryPayload(from: conversation))
  }

  /// Snapshot the payload and enqueue one row per enabled integration for
  /// a Layer-2 atomic memory. Caller (`MemoryStorage.insertLocalMemory`)
  /// already filtered out the `ONBOARDING_SENTINEL` so we don't re-check.
  func enqueueDispatch(memory record: MemoryRecord) async {
    await enqueue(payload: MemoryPayload(from: record))
  }

  /// Shared tail used by both entry points: serialize the payload, snapshot
  /// enabled integrations, enqueue per integration, and defensively kick
  /// the drain. Per-integration errors are surfaced via `recordFailure` so
  /// the user sees them in the settings UI rather than a silent drop.
  private func enqueue(payload: MemoryPayload) async {
    // Build + serialize the canonical payload exactly once.
    let payloadData: Data
    do {
      payloadData = try payload.encodedJSON()
    } catch {
      logError("LocalIntegrationDispatcher: encodedJSON failed for memory=\(payload.id)", error: error)
      return
    }
    guard let payloadJson = String(data: payloadData, encoding: .utf8) else {
      logError("LocalIntegrationDispatcher: payload data not utf8 for memory=\(payload.id)")
      return
    }

    // Snapshot enabled integrations.
    let enabled: [LocalIntegrationRecord]
    do {
      enabled = try await LocalIntegrationStorage.shared.listEnabled()
    } catch {
      logError("LocalIntegrationDispatcher: listEnabled failed", error: error)
      return
    }
    if enabled.isEmpty {
      // No subscribers — silent no-op.
      return
    }

    log("LocalIntegrationDispatcher: enqueueing memory=\(payload.id) to \(enabled.count) integration(s)")

    // One outbox row per enabled integration. Per-integration errors are
    // logged and skipped so one bad row never blocks the rest.
    let now = Date()
    for integration in enabled {
      do {
        _ = try await LocalIntegrationOutboxStorage.shared.enqueue(
          integrationId: integration.id,
          memoryId: payload.id,
          payloadJson: payloadJson,
          at: now
        )
      } catch {
        logError(
          "LocalIntegrationDispatcher: enqueue failed integration=\(integration.id) memory=\(payload.id)",
          error: error
        )
        // Surface enqueue failure on the integration row so the user sees
        // the error in the settings UI rather than a silent drop.
        do {
          try await LocalIntegrationStorage.shared.recordFailure(
            id: integration.id,
            error: "enqueue failed: \(error.localizedDescription)"
          )
        } catch {
          logError(
            "LocalIntegrationDispatcher: recordFailure failed integration=\(integration.id)",
            error: error
          )
        }
      }
    }

    // Defensive kick — the outbox delegate fires after each enqueue
    // commit, but kicking once at the end is cheap and guarantees the
    // drain runs even if the delegate wasn't wired (e.g. very-early
    // boot path before `start()` ran).
    await MainActor.run {
      LocalIntegrationDrainService.shared.kick()
    }
  }
}
