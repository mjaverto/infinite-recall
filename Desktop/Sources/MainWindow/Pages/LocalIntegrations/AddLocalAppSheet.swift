import AppKit
import SwiftUI

/// Modal sheet for creating or editing a `LocalIntegrationRecord`.
///
/// The same sheet is reused for both flows — pass `editing: nil` for "Add",
/// pass a populated record for "Edit". When editing, the kind picker is
/// disabled (changing kind would invalidate the existing webhook/filesystem
/// fields and there's no clean migration path); the existing folder path
/// is preserved unless the user explicitly re-picks a folder.
struct AddLocalAppSheet: View {
  // MARK: - Inputs

  /// `nil` for create, populated for edit.
  let editing: LocalIntegrationRecord?

  @Environment(\.dismiss) private var dismiss

  // MARK: - Form state

  @State private var name: String = ""
  @State private var kind: LocalIntegrationKind = .webhook
  @State private var webhookURL: String = ""
  @State private var format: LocalIntegrationFormat = .json

  /// Path string for the chosen folder. Initialized from the editing record
  /// so simply pressing Save preserves the existing path.
  @State private var folderDisplayPath: String? = nil

  @State private var saveError: String? = nil
  @State private var isSaving = false

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      title

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          nameField
          kindField

          switch kind {
          case .webhook:
            webhookFields
          case .filesystem:
            filesystemFields
          }

          if let saveError {
            Text(saveError)
              .scaledFont(size: 12)
              .foregroundColor(.red)
          }
        }
        .padding(20)
      }

      Divider()

      footer
    }
    .frame(width: 480, height: 460)
    .background(OmiColors.backgroundPrimary)
    .onAppear { hydrateFromEditing() }
  }

  // MARK: - Title

  private var title: some View {
    HStack {
      Text(editing == nil ? "Add app" : "Edit app")
        .scaledFont(size: 16, weight: .semibold)
        .foregroundColor(OmiColors.textPrimary)
      Spacer()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }

  // MARK: - Fields

  private var nameField: some View {
    VStack(alignment: .leading, spacing: 6) {
      fieldLabel("Name")
      TextField("My webhook", text: $name)
        .textFieldStyle(.roundedBorder)
    }
  }

  private var kindField: some View {
    VStack(alignment: .leading, spacing: 6) {
      fieldLabel("Kind")
      Picker("", selection: $kind) {
        Text("Webhook").tag(LocalIntegrationKind.webhook)
        Text("Filesystem").tag(LocalIntegrationKind.filesystem)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .disabled(editing != nil)
      if editing != nil {
        Text("Kind can't be changed after creation.")
          .scaledFont(size: 11)
          .foregroundColor(OmiColors.textTertiary)
      }
    }
  }

  @ViewBuilder
  private var webhookFields: some View {
    VStack(alignment: .leading, spacing: 6) {
      fieldLabel("Webhook URL")
      TextField("https://example.com/hook", text: $webhookURL)
        .textFieldStyle(.roundedBorder)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(webhookURLValid || webhookURL.isEmpty ? Color.clear : Color.red, lineWidth: 1)
        )
      if !webhookURL.isEmpty && !webhookURLValid {
        Text("URL must start with http:// or https://")
          .scaledFont(size: 11)
          .foregroundColor(.red)
      }
    }
  }

  @ViewBuilder
  private var filesystemFields: some View {
    VStack(alignment: .leading, spacing: 6) {
      fieldLabel("Folder")
      HStack {
        Button("Choose folder…") {
          chooseFolder()
        }
        Spacer()
      }
      if let folderDisplayPath {
        Text(folderDisplayPath)
          .scaledFont(size: 12)
          .foregroundColor(OmiColors.textSecondary)
          .lineLimit(1)
          .truncationMode(.middle)
      } else {
        Text("No folder chosen")
          .scaledFont(size: 12)
          .foregroundColor(OmiColors.textTertiary)
      }
    }

    VStack(alignment: .leading, spacing: 6) {
      fieldLabel("Format")
      Picker("", selection: $format) {
        Text("JSON").tag(LocalIntegrationFormat.json)
        Text("Markdown").tag(LocalIntegrationFormat.markdown)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
  }

  private func fieldLabel(_ text: String) -> some View {
    Text(text)
      .scaledFont(size: 12, weight: .medium)
      .foregroundColor(OmiColors.textSecondary)
  }

  // MARK: - Footer

  private var footer: some View {
    HStack {
      Spacer()
      Button("Cancel") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)

      Button(editing == nil ? "Save" : "Update") {
        Task { await save() }
      }
      .keyboardShortcut(.defaultAction)
      .disabled(!isValid || isSaving)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  // MARK: - Validation

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var webhookURLValid: Bool {
    let lower = webhookURL.lowercased()
    return lower.hasPrefix("http://") || lower.hasPrefix("https://")
  }

  private var isValid: Bool {
    guard !trimmedName.isEmpty else { return false }
    switch kind {
    case .webhook:
      return webhookURLValid
    case .filesystem:
      return !(folderDisplayPath ?? "").isEmpty
    }
  }

  // MARK: - Actions

  private func hydrateFromEditing() {
    guard let editing else { return }
    name = editing.name
    if let k = editing.kindEnum { kind = k }
    webhookURL = editing.webhookURL ?? ""
    folderDisplayPath = editing.folderDisplayPath
    if let f = editing.formatEnum { format = f }
  }

  /// Open `NSOpenPanel` to choose a folder and store its path. The app is
  /// non-sandboxed, so the path string is the I/O source of truth — TCC
  /// handles permission, no security-scoped bookmark needed.
  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    folderDisplayPath = url.path
  }

  private func save() async {
    saveError = nil
    isSaving = true
    defer { isSaving = false }

    let now = Date()
    let record: LocalIntegrationRecord
    switch kind {
    case .webhook:
      record = LocalIntegrationRecord(
        id: editing?.id ?? UUID().uuidString,
        name: trimmedName,
        kind: LocalIntegrationKind.webhook.rawValue,
        enabled: editing?.enabled ?? true,
        webhookURL: webhookURL,
        folderBookmark: nil,
        folderDisplayPath: nil,
        format: nil,
        createdAt: editing?.createdAt ?? now,
        lastFiredAt: editing?.lastFiredAt,
        lastError: editing?.lastError
      )
    case .filesystem:
      record = LocalIntegrationRecord(
        id: editing?.id ?? UUID().uuidString,
        name: trimmedName,
        kind: LocalIntegrationKind.filesystem.rawValue,
        enabled: editing?.enabled ?? true,
        webhookURL: nil,
        folderBookmark: nil,
        folderDisplayPath: folderDisplayPath,
        format: format.rawValue,
        createdAt: editing?.createdAt ?? now,
        lastFiredAt: editing?.lastFiredAt,
        lastError: editing?.lastError
      )
    }

    do {
      if editing == nil {
        _ = try await LocalIntegrationStorage.shared.create(record)
      } else {
        try await LocalIntegrationStorage.shared.update(record)
      }
      await MainActor.run { dismiss() }
    } catch {
      await MainActor.run {
        saveError = error.localizedDescription
      }
    }
  }
}
