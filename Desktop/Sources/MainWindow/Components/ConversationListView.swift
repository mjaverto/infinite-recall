import SwiftUI

/// List view showing conversations grouped by date
struct ConversationListView: View {
  let conversations: [ServerConversation]
  let isLoading: Bool
  let error: String?
  let folders: [Folder]
  var isCompactView: Bool = true
  let onSelect: (ServerConversation) -> Void
  let onRefresh: () -> Void
  let onMoveToFolder: (String, String?) async -> Void

  // Multi-select support
  var isMultiSelectMode: Bool = false
  var selectedIds: Set<String> = []
  var onToggleSelection: ((String) -> Void)? = nil

  /// When true, renders without its own ScrollView (for embedding in an outer ScrollView)
  var embedded: Bool = false

  var appState: AppState

  /// True when any filter chip is active (issue #142). Used to show a
  /// "no matching conversations" panel instead of the brand-new-user empty
  /// state when a filter excludes every row.
  private var hasActiveFilter: Bool {
    appState.showStarredOnly
      || appState.selectedDateFilter != nil
      || appState.selectedFolderId != nil
      || appState.showDiscardedOnly
  }

  /// Caller-action that clears all chip filters at once. Wired through
  /// `appState.clearFilters()`; rendered only when a filter is active.
  private func clearFilters() {
    Task { await appState.clearFilters() }
  }

  private static let groupDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d, yyyy"
    return f
  }()

  /// Flat list item — either a section header or a conversation row.
  /// Using a single flat ForEach avoids nested ForEach attribute graph depth which can cause
  /// SwiftUI layout comparison hangs (AG::LayoutDescriptor::compare) on refresh.
  private enum ListItem: Identifiable {
    case header(key: String, isFirst: Bool)
    case conversation(ServerConversation)

    var id: String {
      switch self {
      case .header(let key, _): return "header_\(key)"
      case .conversation(let c): return c.id
      }
    }
  }

  /// Flat ordered list of headers + conversations, grouped by date.
  private var flatListItems: [ListItem] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let formatter = Self.groupDateFormatter

    var groups: [String: [ServerConversation]] = [:]
    var groupDates: [String: Date] = ["Today": today, "Yesterday": yesterday]

    for conversation in conversations {
      let conversationDate = calendar.startOfDay(for: conversation.createdAt)
      let groupKey: String

      if conversationDate == today {
        groupKey = "Today"
      } else if conversationDate == yesterday {
        groupKey = "Yesterday"
      } else {
        groupKey = formatter.string(from: conversation.createdAt)
        groupDates[groupKey] = conversationDate
      }

      groups[groupKey, default: []].append(conversation)
    }

    // Sort groups: Today first, then Yesterday, then by date descending
    let sortedKeys = groups.keys.sorted { key1, key2 in
      if key1 == "Today" { return true }
      if key2 == "Today" { return false }
      if key1 == "Yesterday" { return true }
      if key2 == "Yesterday" { return false }
      let date1 = groupDates[key1] ?? .distantPast
      let date2 = groupDates[key2] ?? .distantPast
      return date1 > date2
    }

    var items: [ListItem] = []
    for (index, key) in sortedKeys.enumerated() {
      guard let convos = groups[key] else { continue }
      items.append(.header(key: key, isFirst: index == 0))
      for conv in convos {
        items.append(.conversation(conv))
      }
    }
    return items
  }

  var body: some View {
    Group {
      if isLoading && conversations.isEmpty {
        loadingView
      } else if let error = error, conversations.isEmpty {
        errorView(error)
      } else if conversations.isEmpty {
        // Issue #142: distinguish a genuinely empty store from a filter
        // that happens to match nothing.
        if hasActiveFilter {
          noFilterResultsView
        } else {
          emptyView
        }
      } else {
        conversationList
      }
    }
  }

  private var loadingView: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.2)
        .tint(OmiColors.purplePrimary)

      Text("Loading conversations...")
        .scaledFont(size: 14)
        .foregroundColor(OmiColors.textTertiary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func errorView(_ error: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle")
        .scaledFont(size: 40)
        .foregroundColor(OmiColors.warning)

      Text("Failed to load conversations")
        .scaledFont(size: 16, weight: .medium)
        .foregroundColor(OmiColors.textPrimary)

      Text(error)
        .scaledFont(size: 14)
        .foregroundColor(OmiColors.textTertiary)
        .multilineTextAlignment(.center)

      Button(action: onRefresh) {
        Text("Try Again")
          .scaledFont(size: 14, weight: .medium)
          .foregroundColor(OmiColors.textPrimary)
          .padding(.horizontal, 20)
          .padding(.vertical, 10)
          .omiControlSurface(fill: OmiColors.userBubble, radius: OmiChrome.chipRadius)
      }
      .buttonStyle(.plain)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }

  private var emptyView: some View {
    VStack(spacing: 16) {
      Image(systemName: "bubble.left.and.bubble.right")
        .scaledFont(size: 48)
        .foregroundColor(OmiColors.textTertiary)

      Text("No Conversations")
        .scaledFont(size: 18, weight: .semibold)
        .foregroundColor(OmiColors.textPrimary)

      Text("Start recording to capture your first conversation")
        .scaledFont(size: 14)
        .foregroundColor(OmiColors.textTertiary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }

  /// Shown when the store has rows but the active filter excludes all of
  /// them (issue #142). Distinct from `emptyView` so the user knows the
  /// list is filtered, not genuinely empty.
  private var noFilterResultsView: some View {
    VStack(spacing: 16) {
      Image(systemName: "line.3.horizontal.decrease.circle")
        .scaledFont(size: 48)
        .foregroundColor(OmiColors.textTertiary)

      Text("No matching conversations")
        .scaledFont(size: 18, weight: .semibold)
        .foregroundColor(OmiColors.textPrimary)

      Text(activeFilterDescription)
        .scaledFont(size: 14)
        .foregroundColor(OmiColors.textTertiary)
        .multilineTextAlignment(.center)

      Button(action: clearFilters) {
        Text("Clear filters")
          .scaledFont(size: 13, weight: .medium)
          .foregroundColor(OmiColors.textPrimary)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .omiControlSurface(fill: OmiColors.userBubble, radius: OmiChrome.chipRadius)
      }
      .buttonStyle(.plain)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }

  /// Human-readable summary of the active filter chips for the no-results
  /// panel. Reads `appState` rather than receiving the filter set as
  /// parameters so the description stays in sync with `hasActiveFilter`.
  private var activeFilterDescription: String {
    var parts: [String] = []
    if appState.showStarredOnly { parts.append("starred only") }
    if appState.showDiscardedOnly { parts.append("discarded only") }
    if let date = appState.selectedDateFilter {
      let formatter = DateFormatter()
      formatter.dateFormat = "MMM d, yyyy"
      parts.append("on \(formatter.string(from: date))")
    }
    if let folderId = appState.selectedFolderId,
       let folder = folders.first(where: { $0.id == folderId })
    {
      parts.append("in \"\(folder.name)\"")
    } else if appState.selectedFolderId != nil {
      parts.append("in selected folder")
    }
    if parts.isEmpty {
      return "No conversations match the current filters."
    }
    return "No conversations match: " + parts.joined(separator: ", ") + "."
  }

  private var conversationListContent: some View {
    let items = flatListItems
    return LazyVStack(alignment: .leading, spacing: 12) {
      ForEach(items) { item in
        switch item {
        case .header(let key, let isFirst):
          Text(key)
            .scaledFont(size: 13, weight: .semibold)
            .foregroundColor(OmiColors.textTertiary)
            .padding(.top, isFirst ? 0 : 18)
            .padding(.bottom, 6)
        case .conversation(let conversation):
          ConversationRowView(
            conversation: conversation,
            onTap: { onSelect(conversation) },
            folders: folders,
            onMoveToFolder: onMoveToFolder,
            isCompactView: isCompactView,
            isMultiSelectMode: isMultiSelectMode,
            isSelected: selectedIds.contains(conversation.id),
            onToggleSelection: { onToggleSelection?(conversation.id) },
            appState: appState
          )
        }
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 20)
  }

  private var conversationList: some View {
    Group {
      if embedded {
        conversationListContent
      } else {
        ScrollView {
          conversationListContent
        }
        .refreshable {
          onRefresh()
        }
      }
    }
  }
}

#Preview {
  ConversationListView(
    conversations: [],
    isLoading: false,
    error: nil,
    folders: [],
    onSelect: { _ in },
    onRefresh: {},
    onMoveToFolder: { _, _ in },
    appState: AppState()
  )
  .frame(width: 400, height: 600)
  .background(OmiColors.backgroundSecondary)
}
