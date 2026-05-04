# Conversations

The Conversations page is where you browse, search, and manage everything Infinite Recall has recorded. Each conversation is a fully transcribed audio session — complete with speaker labels, per-segment timestamps, and metadata like title, summary, and folder assignment. This is the primary surface for reviewing what was said, who said it, and when.

## What you see

The left panel shows a date-grouped list of conversations — Today, Yesterday, then descending calendar dates. A search bar sits at the top. Below it, optional filter chips let you narrow the list: starred conversations only, a specific folder, or a custom date range picked from a calendar popover.

Selecting a conversation opens the detail view on the right. It shows the full transcript broken into speaker-labeled segments, each with a timestamp. A notes field at the bottom lets you attach free-text context. The toolbar above the transcript exposes speaker management and other per-conversation actions.

## What you can do

- Search conversations live. Queries are debounced at 250 ms so the list updates as you type without hammering the store on every keystroke.
- Multi-select rows for bulk actions: move to a folder, delete, or merge several conversations into one.
- Create, rename, and delete folders. Drag conversations into them, or use the move action from the context menu.
- Filter by starred status. Star any conversation from the detail view or the list row's context menu.
- Merge conversations. Useful when a single session was split by a recording gap — select two or more rows and merge them into one continuous transcript.
- Jump to any date or range using the date picker filter chip.
- Open a conversation to read the full transcript, see per-segment speaker labels, and click any timestamp to navigate within the session.
- Identify speakers. Assign real names to speaker IDs, correct mis-attributed segments, and save voice profiles so future sessions auto-identify the same speakers.
- Toggle between compact and expanded list view. The preference persists across launches.
- Delete conversations locally. Deletion is permanent; there is no cloud backup to recover from.

## States

- **Loading** — a spinner appears while the conversation list is being fetched from the local store on launch or after a filter change.
- **Error** — a banner describes the failure if the store query fails (e.g., the database is locked or corrupted).
- **Empty** — shown when no conversations have been recorded yet. Prompts you to start recording.
- **No results** — shown when a search query or active filter matches nothing in the store. Distinct from the empty state so you know whether the list is genuinely empty or just filtered out.

## Behind the scenes

Conversations are the final output of a multi-stage pipeline: audio capture, transcription, speaker diarisation, session grouping, and enrichment. Each stage runs independently on its own schedule.

### Audio capture

Microphone audio is captured via a CoreAudio IOProc callback at 16 kHz mono PCM. System audio — app sounds, video call output, browser tabs — is captured on a separate tap and mixed with the mic stream in real time. The combined stream is buffered and flushed into 30-second chunks that land in a local SQLite store.

Before any chunk is written to disk, the app checks the excluded-apps list (configured in Settings > General > Excluded Apps). Audio originating from an excluded app is silently dropped before persistence — it never touches disk. Relevant files: `AudioCaptureService.swift`, `AudioMixer.swift`, `AudioPersistenceService.swift`, `AudioExclusionStore.swift`.

### Transcription

Persisted audio chunks are queued in a `pending_work` table and picked up by the transcription service, which runs WhisperKit locally — Apple's Core ML port of OpenAI Whisper. No audio or text is sent to any cloud service; everything runs on-device.

Transcription is lightweight enough to run while you are actively using the Mac, as long as it is plugged into AC power. On battery, `BatteryAwareScheduler` pauses the queue to avoid draining the battery on background work; when you plug back in, the queue resumes and catches up. Relevant files: `TranscriptionService.swift`, `BatteryAwareScheduler.swift`, `PowerWorkBridge.swift`.

### Speaker diarisation

In parallel with transcription, a separate service determines who is speaking in each segment. The default backend is a lightweight speaker-embedding extractor that averages MFCC features per segment and clusters them with cosine similarity (threshold ~0.65) — fast, low power, no extra model download required. For higher accuracy, an optional pyannote-community-1 model (packaged as SpeakerKit) can be enabled; it requires a one-time model download.

Each transcript segment is tagged with a speaker ID. When a speaker ID matches a saved voice profile or a name you have assigned manually, the label resolves to that name automatically. Corrections made in the detail view are persisted back to the embedding store and influence future sessions. Relevant files: `Diarization/SpeakerDiarizationService.swift`, `SpeakerEmbeddingStore.swift`, `MFCCExtractor.swift`, `PyannoteLifecycleManager.swift`.

### Conversation grouping

As transcription and diarisation produce segments, they are accumulated against a single recording session row (`TranscriptionSessionRecord`) identified by a stable `local-N` ID. While recording is active, the session stays open. When you stop recording, `finishConversation()` closes the session, and the Conversations list re-queries the store to render all segments under a single row. The preview text shown in the list is drawn from the first few segments of the session. Relevant files: `TranscriptionStorage.swift`, `AppState.swift`.

### Enrichment — titles, summaries, knowledge graphs

The heaviest work happens last and on a deferred schedule. Generating a human-readable title, a short summary, and extracting a structured knowledge graph all require a local LLM pass. These tasks are only dispatched when the gate is open: AC power connected and the Mac idle. During active use, the queue sits and waits; when conditions are met, it drains. This keeps the UI fast during work hours and lets the machine catch up overnight or whenever it is idle at the charger. See the Activity doc for the full gating model.

## Source

- `Desktop/Sources/MainWindow/Pages/ConversationsPage.swift`
- `Desktop/Sources/MainWindow/Components/ConversationListView.swift`
- `Desktop/Sources/MainWindow/Pages/ConversationDetailView.swift`
- Capture: `Desktop/Sources/AudioCaptureService.swift`, `AudioMixer.swift`, `AudioPersistenceService.swift`, `AudioExclusionStore.swift`
- Transcription: `Desktop/Sources/TranscriptionService.swift`, `Power/BatteryAwareScheduler.swift`, `PowerWorkBridge.swift`
- Diarisation: `Desktop/Sources/Diarization/`
