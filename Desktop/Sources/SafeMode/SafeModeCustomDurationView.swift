import AppKit
import SwiftUI

// MARK: - Custom Duration Sheet

struct SafeModeCustomDurationView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var minutes: Double = 60  // default to 1 hour

  let onConfirm: (Int) -> Void

  // 5-minute steps, 5–240 min.
  private let minMinutes: Double = 5
  private let maxMinutes: Double = 240
  private let stepMinutes: Double = 5

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Pause Safe Mode for…")
        .font(.headline)

      Text(formatted(Int(minutes)))
        .font(.system(size: 28, weight: .semibold, design: .rounded))
        .frame(maxWidth: .infinity, alignment: .center)

      Slider(
        value: $minutes,
        in: minMinutes...maxMinutes,
        step: stepMinutes
      ) {
        Text("Minutes")
      } minimumValueLabel: {
        Text("5m").font(.caption2).foregroundColor(.secondary)
      } maximumValueLabel: {
        Text("4h").font(.caption2).foregroundColor(.secondary)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button("Pause") {
          onConfirm(Int(minutes) * 60)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 360)
  }

  private func formatted(_ mins: Int) -> String {
    if mins < 60 { return "\(mins) min" }
    let h = mins / 60
    let m = mins % 60
    if m == 0 { return "\(h) hr" }
    return "\(h) hr \(m) min"
  }
}

// MARK: - Window helper

/// Presents the custom-duration picker as a small floating window. We use a
/// standalone NSWindow (not a sheet) because the menu bar has no parent
/// window context.
@MainActor
final class SafeModeCustomDurationWindow {
  static let shared = SafeModeCustomDurationWindow()

  private var window: NSWindow?

  func show() {
    if let existing = window {
      existing.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let view = SafeModeCustomDurationView { [weak self] seconds in
      SafeModeController.shared.pause(forSeconds: seconds)
      self?.close()
    }
    let hosting = NSHostingController(rootView: view)
    let win = NSWindow(contentViewController: hosting)
    win.title = "Safe Mode"
    win.styleMask = [.titled, .closable]
    win.isReleasedWhenClosed = false
    win.center()
    win.level = .floating
    self.window = win
    win.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func close() {
    window?.close()
    window = nil
  }
}
