import SwiftUI

/// Informational-only badge for the AI / Models settings panel.
/// Surfaces "N visual activity entries indexed today" so the user has some
/// visible feedback that the visual recall pipeline is running. Updates
/// every 30 seconds while the panel is visible.
struct VisualActivityStatusBanner: View {
    @StateObject private var sampler = VisualActivitySampler.shared

    @State private var todayCount: Int = 0
    @State private var totalCount: Int = 0
    @State private var refreshTimer: Timer?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.circle")
                .scaledFont(size: 16)
                .foregroundColor(OmiColors.purplePrimary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text("Visual Activity")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundColor(OmiColors.textPrimary)
                Text(statusLine)
                    .scaledFont(size: 12)
                    .foregroundColor(OmiColors.textSecondary)
            }

            Spacer()

            if sampler.samplesQueued > 0 {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(OmiColors.purplePrimary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(OmiColors.purplePrimary.opacity(0.25), lineWidth: 1)
        )
        .onAppear { startRefreshing() }
        .onDisappear { stopRefreshing() }
    }

    private var statusLine: String {
        let entries = todayCount == 1 ? "entry" : "entries"
        return "\(todayCount) \(entries) indexed today (\(totalCount) total)"
    }

    private func startRefreshing() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            refresh()
        }
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        Task {
            let today = (try? await RewindDatabase.shared.visualActivityCount(forDayContaining: Date())) ?? 0
            let total = (try? await RewindDatabase.shared.visualActivityCount()) ?? 0
            await MainActor.run {
                self.todayCount = today
                self.totalCount = total
            }
        }
    }
}
