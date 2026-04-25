import Foundation

/// Stores the list of app bundle IDs whose system audio should be excluded from
/// the global Process Tap. Persisted as a comma-separated string in UserDefaults
/// so it round-trips through `@AppStorage` cleanly. Bundle IDs cannot contain
/// commas, so CSV is safe.
///
/// Apps already running when audio capture starts are excluded by PID. Apps
/// launched after capture starts are NOT excluded until the user toggles
/// Audio Recording off and on again.
enum AudioExclusionStore {
    static let userDefaultsKey = "excludedAudioBundleIDs"

    /// Notification posted when the exclusion list changes — observers (mainly
    /// AppState) can use this to know capture should be restarted to apply.
    static let didChange = Notification.Name("audioExclusionListDidChange")

    static func currentBundleIDs() -> [String] {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        return decode(raw)
    }

    static func setBundleIDs(_ ids: [String]) {
        let cleaned = ids
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        UserDefaults.standard.set(encode(cleaned), forKey: userDefaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func add(_ bundleID: String) {
        var ids = currentBundleIDs()
        let trimmed = bundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !ids.contains(trimmed) else { return }
        ids.append(trimmed)
        setBundleIDs(ids)
    }

    static func remove(_ bundleID: String) {
        let ids = currentBundleIDs().filter { $0 != bundleID }
        setBundleIDs(ids)
    }

    // MARK: - CSV codec

    private static func encode(_ ids: [String]) -> String {
        ids.joined(separator: ",")
    }

    private static func decode(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
