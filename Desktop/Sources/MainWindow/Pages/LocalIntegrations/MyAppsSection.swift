import SwiftUI

/// "My Apps" section shown on the Apps page above the remote-catalog
/// Integrations grid.
///
/// Lists user-installed local integrations (webhook + filesystem) sourced from
/// `LocalIntegrationStorage`. Each row exposes enable/disable, retry-now,
/// edit, and delete affordances. Section header has a trailing "+ Add" button
/// that presents `AddLocalAppSheet` for creating new integrations.
struct MyAppsSection: View {
  // MARK: - State

  @State private var integrations: [LocalIntegrationRecord] = []
  @State private var pendingCounts: [String: Int] = [:]

  @State private var isAddSheetPresented = false
  @State private var editing: LocalIntegrationRecord? = nil

  /// Pending delete confirmation target (held separately from `editing` so
  /// the alert + edit sheet don't fight over a single binding).
  @State private var pendingDelete: LocalIntegrationRecord? = nil

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      if integrations.isEmpty {
        emptyState
      } else {
        VStack(spacing: 8) {
          ForEach(integrations) { record in
            row(for: record)
          }
        }
      }
    }
    .task {
      await reload()
    }
    .onReceive(NotificationCenter.default.publisher(for: LocalIntegrationDrainService.progressNotification)) { _ in
      Task { await reload() }
    }
    .sheet(isPresented: $isAddSheetPresented, onDismiss: {
      Task { await reload() }
    }) {
      AddLocalAppSheet(editing: nil)
    }
    .sheet(item: $editing, onDismiss: {
      Task { await reload() }
    }) { record in
      AddLocalAppSheet(editing: record)
    }
    .alert(item: $pendingDelete) { record in
      Alert(
        title: Text("Delete \(record.name)?"),
        message: Text("This removes the integration and any pending deliveries. This can't be undone."),
        primaryButton: .destructive(Text("Delete")) {
          Task { await delete(record) }
        },
        secondaryButton: .cancel()
      )
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text("My Apps")
        .scaledFont(size: 18, weight: .semibold)
        .foregroundColor(OmiColors.textPrimary)

      Spacer()

      Button(action: { isAddSheetPresented = true }) {
        HStack(spacing: 4) {
          Image(systemName: "plus")
            .scaledFont(size: 11, weight: .semibold)
          Text("Add")
            .scaledFont(size: 13, weight: .medium)
        }
        .foregroundColor(OmiColors.textSecondary)
      }
      .buttonStyle(.plain)
    }
  }

  // MARK: - Empty state

  private var emptyState: some View {
    HStack {
      Text("No local apps yet — add one to send memories to a webhook or local folder.")
        .scaledFont(size: 13)
        .foregroundColor(OmiColors.textTertiary)
        .multilineTextAlignment(.leading)
      Spacer()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(OmiColors.backgroundSecondary)
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  // MARK: - Row

  @ViewBuilder
  private func row(for record: LocalIntegrationRecord) -> some View {
    let pending = pendingCounts[record.id] ?? 0

    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(record.name)
              .scaledFont(size: 14, weight: .semibold)
              .foregroundColor(OmiColors.textPrimary)
              .lineLimit(1)

            kindBadge(for: record)

            if pending > 0 {
              pendingBadge(count: pending)
            }
          }

          subline(for: record)

          if let lastFiredAt = record.lastFiredAt {
            Text("Last fired: \(relativeString(from: lastFiredAt))")
              .scaledFont(size: 11)
              .foregroundColor(OmiColors.textTertiary)
              .lineLimit(1)
          }

          if let lastError = record.lastError, !lastError.isEmpty {
            Text(lastError)
              .scaledFont(size: 11)
              .foregroundColor(.red)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }

        Spacer(minLength: 8)

        controls(for: record, pending: pending)
      }
    }
    .padding(12)
    .background(OmiColors.backgroundSecondary)
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  @ViewBuilder
  private func subline(for record: LocalIntegrationRecord) -> some View {
    switch record.kindEnum {
    case .webhook:
      Text(truncatedMiddle(record.webhookURL ?? ""))
        .scaledFont(size: 12)
        .foregroundColor(OmiColors.textSecondary)
        .lineLimit(1)
    case .filesystem:
      HStack(spacing: 6) {
        Text(record.folderDisplayPath ?? "—")
          .scaledFont(size: 12)
          .foregroundColor(OmiColors.textSecondary)
          .lineLimit(1)
          .truncationMode(.middle)
        if let format = record.formatEnum {
          Text("·")
            .scaledFont(size: 12)
            .foregroundColor(OmiColors.textTertiary)
          Text(format == .json ? "JSON" : "Markdown")
            .scaledFont(size: 12)
            .foregroundColor(OmiColors.textTertiary)
        }
      }
    case .none:
      Text(record.kind)
        .scaledFont(size: 12)
        .foregroundColor(OmiColors.textTertiary)
    }
  }

  @ViewBuilder
  private func controls(for record: LocalIntegrationRecord, pending: Int) -> some View {
    HStack(spacing: 8) {
      Toggle(
        "",
        isOn: Binding(
          get: { record.enabled },
          set: { newValue in
            Task { await setEnabled(record, newValue) }
          }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)

      if pending > 0 {
        Button("Retry now") {
          Task { await retryNow(record) }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
      }

      Button("Edit") {
        editing = record
      }
      .buttonStyle(.borderless)
      .controlSize(.small)

      Button("Delete") {
        pendingDelete = record
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .foregroundColor(.red)
    }
  }

  // MARK: - Badges

  private func kindBadge(for record: LocalIntegrationRecord) -> some View {
    let label: String
    switch record.kindEnum {
    case .webhook: label = "Webhook"
    case .filesystem: label = "Filesystem"
    case .none: label = record.kind.capitalized
    }
    return Text(label)
      .scaledFont(size: 10, weight: .medium)
      .foregroundColor(OmiColors.textSecondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(OmiColors.backgroundTertiary)
      .clipShape(Capsule())
  }

  private func pendingBadge(count: Int) -> some View {
    Text("\(count) pending")
      .scaledFont(size: 10, weight: .medium)
      .foregroundColor(.orange)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Color.orange.opacity(0.15))
      .clipShape(Capsule())
  }

  // MARK: - Reload / mutations

  /// Refresh the integration list and pending counts. Pending counts are
  /// fetched in parallel via `withTaskGroup` so a slow outbox query for one
  /// integration doesn't serialize the rest.
  private func reload() async {
    do {
      let list = try await LocalIntegrationStorage.shared.listAll()
      let counts = await loadPendingCounts(for: list)
      await MainActor.run {
        self.integrations = list
        self.pendingCounts = counts
      }
    } catch {
      log("MyAppsSection: reload failed: \(error.localizedDescription)")
    }
  }

  private func loadPendingCounts(for list: [LocalIntegrationRecord]) async -> [String: Int] {
    await withTaskGroup(of: (String, Int).self) { group in
      for record in list {
        group.addTask {
          do {
            let count = try await LocalIntegrationOutboxStorage.shared.pendingCount(forIntegrationId: record.id)
            return (record.id, count)
          } catch {
            log("MyAppsSection: pendingCount failed for \(record.id): \(error.localizedDescription)")
            return (record.id, 0)
          }
        }
      }
      var result: [String: Int] = [:]
      for await (id, count) in group {
        result[id] = count
      }
      return result
    }
  }

  /// User pressed "Retry now": reschedule any future-dated rows for this
  /// integration to be due immediately, then kick the drain. Without
  /// `resetForRetry`, rows parked at +30 days by a permanent-failure
  /// outcome would remain parked.
  private func retryNow(_ record: LocalIntegrationRecord) async {
    do {
      _ = try await LocalIntegrationOutboxStorage.shared.resetForRetry(forIntegrationId: record.id)
    } catch {
      log("MyAppsSection: resetForRetry failed for \(record.id): \(error.localizedDescription)")
    }
    await MainActor.run {
      LocalIntegrationDrainService.shared.kick()
    }
  }

  private func setEnabled(_ record: LocalIntegrationRecord, _ enabled: Bool) async {
    do {
      try await LocalIntegrationStorage.shared.setEnabled(id: record.id, enabled)
      await reload()
    } catch {
      log("MyAppsSection: setEnabled failed: \(error.localizedDescription)")
    }
  }

  private func delete(_ record: LocalIntegrationRecord) async {
    do {
      try await LocalIntegrationOutboxStorage.shared.clearAll(forIntegrationId: record.id)
      try await LocalIntegrationStorage.shared.delete(id: record.id)
      await reload()
    } catch {
      log("MyAppsSection: delete failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Formatting helpers

  private func relativeString(from date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  /// Truncate a URL string with an ellipsis in the middle so both the host
  /// and the trailing path are visible at a glance.
  private func truncatedMiddle(_ s: String, max: Int = 64) -> String {
    guard s.count > max else { return s }
    let keep = (max - 1) / 2
    let start = s.prefix(keep)
    let end = s.suffix(keep)
    return "\(start)…\(end)"
  }
}
