// Infinite Recall fork: on-device speaker diarization lifecycle. No cloud calls.
//
// PyannoteLifecycleManager — owns the SpeakerKit instance for the pyannote
// diarization backend. Mirrors the structure of MLXLifecycleManager: holds a
// single shared instance, provides `loadIfNeeded()` / `unload()` entry points,
// and is safe to call from any async context.
//
// Model download: lazy on first `loadIfNeeded()` call. SpeakerKit pulls
// ~80–120 MB of CoreML weights from `argmaxinc/speakerkit-coreml` the first
// time. Subsequent calls are no-ops if models are already on disk. Storage
// lands under the ArgmaxCore/Hub default location (same tree as WhisperKit
// models under Application Support).
//
// The SpeakerKit public API changed between the design-doc description and the
// actual checked-out source: the top-level entry point is `SpeakerKit(config:)`,
// which internally creates the `PyannoteDiarizer`. We hold the `SpeakerKit`
// instance directly.

import Foundation
import SpeakerKit

@available(macOS 13, *)
@MainActor
final class PyannoteLifecycleManager: ObservableObject {

    // MARK: - Singleton

    static let shared = PyannoteLifecycleManager()

    // MARK: - Published state

    /// Non-nil once models are downloaded and the instance is ready to diarize.
    @Published private(set) var speakerKit: SpeakerKit?

    /// True while an async load or download is in progress.
    @Published private(set) var isLoading: Bool = false

    /// Last error surfaced during load, if any (for diagnostic logging).
    @Published private(set) var lastError: String?

    // MARK: - Internals

    private var loadTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Ensure the SpeakerKit instance is initialized and models are ready.
    ///
    /// Idempotent: if already loaded the call returns immediately. If a load
    /// is already in-flight the caller awaits that same task (no duplicate
    /// downloads). Safe to call from any actor context.
    func loadIfNeeded() async {
        guard speakerKit == nil else { return }
        if let existing = loadTask {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            await self?.performLoad() ?? ()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    /// Release the SpeakerKit instance and unload CoreML models from memory.
    ///
    /// Called by `IdleAIController` after 60 s of no audio. Next `loadIfNeeded()`
    /// reloads models from disk (~600–900 ms ANE compile on first launch,
    /// much faster thereafter from the compiled cache).
    func unload() async {
        if let kit = speakerKit {
            await kit.unloadModels()
        }
        speakerKit = nil
        log("PyannoteLifecycleManager: models unloaded")
    }

    // MARK: - Private

    private func performLoad() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            // PyannoteConfig defaults:
            //   download: true  — pulls models from argmaxinc/speakerkit-coreml on HF
            //   load: false     — defers ANE model compile to first diarize() call
            //
            // concurrentEmbedderWorkers: 1 — conservative start; increase after
            // profiling to avoid contention with WhisperKit's ANE passes.
            let config = PyannoteConfig(
                download: true,
                load: false,
                verbose: false,
                concurrentEmbedderWorkers: 1
            )
            let kit = try await SpeakerKit(config)
            self.speakerKit = kit
            log("PyannoteLifecycleManager: SpeakerKit ready")
        } catch {
            lastError = error.localizedDescription
            logError("PyannoteLifecycleManager: load failed", error: error)
        }
    }
}
