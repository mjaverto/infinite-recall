import Foundation

enum SpeakerContentFilter {
    private static let noiseWords: Set<String> = [
        "music", "gentle music", "background music", "noise", "silence",
        "applause", "laughter", "inaudible", "static", "beep", "tone"
    ]

    static func isNoiseOnly(_ text: String) -> Bool {
        let lowered = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !lowered.isEmpty else { return true }
        return noiseWords.contains(lowered)
    }
}
