import SwiftUI
import Combine

/// Per-task chat state with persisted message history.
///
/// Infinite Recall fork: previously routed through agent bridge (Node.js Claude
/// SDK harness). That runtime has been deleted along with `agent/`. Send is now
/// a no-op that surfaces an error; UI surface is preserved so callers compile.
/// A future change will route this through the local mlx-lm endpoint.
@MainActor
class TaskChatState: ObservableObject {
    let taskId: String

    @Published var messages: [ChatMessage] = []
    @Published var isSending = false
    @Published var isStopping = false
    @Published var draftText = ""
    @Published var errorMessage: String?
    @Published var chatMode: ChatMode = .act

    /// Workspace path for file-system tools
    let workspacePath: String

    @Published var currentSessionId: String?

    /// Closure to build system prompt from ChatProvider's cached data
    var systemPromptBuilder: (() -> String)?

    /// Follow-up chaining
    private var pendingFollowUpText: String?

    /// Whether persisted messages have been loaded from GRDB
    private var hasLoadedFromStorage = false

    init(taskId: String, workspacePath: String) {
        self.taskId = taskId
        self.workspacePath = workspacePath
    }

    // MARK: - Persistence

    /// Load persisted messages from GRDB (called once when chat is opened)
    func loadPersistedMessages() async {
        guard !hasLoadedFromStorage else { return }
        hasLoadedFromStorage = true

        do {
            let records = try await TaskChatMessageStorage.shared.getMessages(forTaskId: taskId)
            guard !records.isEmpty else { return }

            messages = records.map { $0.toChatMessage() }

            if let sessionId = try? await TaskChatMessageStorage.shared.getACPSessionId(forTaskId: taskId) {
                currentSessionId = sessionId
            }

            log("TaskChatState[\(taskId)]: Loaded \(records.count) persisted messages")
        } catch {
            logError("TaskChatState[\(taskId)]: Failed to load persisted messages", error: error)
        }
    }

    /// Persist a message to GRDB (fire-and-forget)
    private func persistMessage(_ message: ChatMessage) {
        let taskId = self.taskId
        let sessionId = self.currentSessionId
        Task.detached {
            do {
                try await TaskChatMessageStorage.shared.saveMessage(message, taskId: taskId, acpSessionId: sessionId)
            } catch {
                logError("TaskChatState[\(taskId)]: Failed to persist message \(message.id)", error: error)
            }
        }
    }

    // MARK: - Send Message (stub)

    /// Send a message — currently a no-op in the local-first fork.
    /// Persists the user message and an error AI response so the UI behaves predictably.
    func sendMessage(_ text: String, isFollowUp: Bool = false, taskContext: String? = nil) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        guard !isSending else { return }

        isSending = true
        errorMessage = "Task agent chat is disabled in the local-first build (agent bridge removed)."

        if !isFollowUp {
            let userMessage = ChatMessage(
                id: UUID().uuidString,
                text: trimmedText,
                sender: .user
            )
            messages.append(userMessage)
            persistMessage(userMessage)
        }

        log("TaskChatState[\(taskId)]: sendMessage skipped — agent bridge removed in local-first build")

        isSending = false
        isStopping = false

        if let followUp = pendingFollowUpText {
            pendingFollowUpText = nil
            await sendMessage(followUp, isFollowUp: true)
        }
    }

    // MARK: - Follow-Up

    func sendFollowUp(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, isSending else { return }

        let userMessage = ChatMessage(
            id: UUID().uuidString,
            text: trimmedText,
            sender: .user
        )
        messages.append(userMessage)
        persistMessage(userMessage)

        pendingFollowUpText = trimmedText
        log("TaskChatState[\(taskId)]: follow-up queued (no-op — bridge removed)")
    }

    // MARK: - Stop

    func stopAgent() {
        guard isSending else { return }
        isStopping = true
    }
}
