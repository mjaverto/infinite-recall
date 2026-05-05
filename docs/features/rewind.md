# Rewind

Rewind is a visual timeline of your screen activity. Scrub through screenshots chronologically, search across what was on-screen and what was said, and jump back to any moment in your day. Everything runs locally — no frames or transcripts leave your device.

## What you see

- An interactive timeline along the bottom of the view, showing screenshot thumbnails arranged in chronological order.
- A large preview pane displaying the selected screenshot at full fidelity.
- A transcript area (expandable) showing what was being said at the moment the current frame was captured.
- A search bar that queries screen content (OCR text and vision-model summaries) as well as transcript text simultaneously.
- A date picker for jumping to a specific day's activity.
- A capture-status indicator — a pulsing purple dot when screen recording is active.

## What you can do

- Scrub the timeline by dragging or clicking to land on any recorded moment.
- Search by keyword; results highlight inline on the timeline or open a full-screen results view depending on your current search mode.
- Switch search modes between timeline-with-highlights and the full-screen results view.
- Expand the transcript to read the complete conversation context associated with a frame.
- Add personal notes to a conversation, tied to the current view.
- Finish the current conversation — a confirmation step lets you save or discard it; a minimum-length requirement is enforced before saving.
- Select a speaker segment in the transcript and assign or correct the speaker name.
- Toggle screen recording on or off without leaving Rewind.

## States

- Loading spinner while screenshots are being fetched from disk.
- Error banner when data is unavailable (permission failure, disk error, etc.).
- Empty state when no screenshots have been captured yet.
- "No results" state when a search query returns no matching frames.
- Recording status: animated purple pulse shown when capture is active.
- Recovery banner if the local database was restored from a corrupted state.
- Expanded transcript mode, which overlays the timeline panel.

## Behind the scenes

### Screen capture

Every approximately one second, the app uses macOS `ScreenCaptureKit` to capture the visible window at up to 3000×3000 px. Frames are not written individually as JPEGs; instead they are appended to a rolling H.265 fragmented-MP4 chunk by `VideoChunkEncoder` at ~1 fps. Each chunk caps at 60 seconds and is then finalized to disk under:

```
~/Library/Application Support/Omi/users/{userId}/Videos/YYYY-MM-DD/chunk_HHmmss.mp4
```

Per-frame metadata (timestamp, app name, window title, OCR results) is written to the SQLite `screenshots` table with `videoChunkPath` pointing at the chunk file and `frameOffset` selecting the frame inside it. Date-bucketed folders keep the directory tree manageable and make retention cleanup efficient. Capture automatically pauses for any app on Rewind's excluded list (Settings → Rewind → Excluded Apps). Password managers and incognito windows are excluded by default.

A legacy single-JPEG path (`RewindStorage.saveScreenshot`, `screenshots.imagePath`) remains in the codebase for older databases that still reference per-frame JPEGs on disk; the live capture pipeline does not exercise it.

### OCR

Captured frames flow into `RewindOCRService`, which runs Apple's Vision framework `VNRecognizeTextRequest` on roughly every third frame. The frequency gate limits CPU impact during continuous recording. Extracted text — including bounding boxes and confidence scores — is stored in an `ocr_texts` table in the local database.

OCR scheduling is gated by `BatteryAwareScheduler`. When the device is on battery or in low-power mode, OCR pauses and incoming frames queue up; on AC reconnect, the queue drains. This behavior corresponds to the "Battery Optimization" toggle in Settings.

### Vision-model sampling

Not every frame contains distinct new content. A perceptual hash (8×8 dHash) is computed for each frame and compared against the most recently sampled frame. A new sample is triggered when any of these conditions is true:

- The Hamming distance between the current frame and the last sampled frame exceeds ~12 bits.
- The active app has changed.
- More than 60 seconds have elapsed since the last sample.

When sampling is triggered, the frame is sent to the local Qwen3-VL-8B vision model (default; configurable at Settings → AI / Models → Vision Model) running on `127.0.0.1:8081`. The model returns a one-to-two sentence scene description such as "User editing a Figma design file, blue header visible." This adaptive sampling keeps inference load manageable on modest hardware while preserving meaningful coverage.

### Indexing for search

Each sampled frame produces a row in the `visual_activity` table (backed by GRDB SQLite). The row captures the app name, window title, the vision-model summary, and a snapshot of the OCR text for that frame. SQLite FTS triggers maintain a full-text-search index across these columns. That index is what powers the Rewind search bar — fuzzy keyword queries run across both what was visible on screen and what was readable as text.

### Retention

On app launch, screenshots and `visual_activity` rows older than the configured retention window are pruned (Settings → Rewind → Data Retention; default 7 days, with options up to 30). There is also a soft cap of 30,000 rows in `visual_activity`; rows above that threshold are trimmed oldest-first automatically. When every frame referencing a given video chunk has been deleted, the orphaned `Videos/YYYY-MM-DD/chunk_HHmmss.mp4` file is removed from disk as well (`RewindIndexer.runCleanup` → `RewindStorage.deleteVideoChunk`). Any legacy per-frame JPEGs still referenced by `screenshots.imagePath` are deleted alongside their rows.

### Transcript context

The transcript shown alongside a frame comes from the Conversations pipeline. See [conversations.md](conversations.md) for how audio becomes labeled transcript segments. Rewind cross-references those segments by timestamp to surface the right context for each frame.

### Capture toggle

The on/off switch on the Rewind page calls into the same capture service used at app startup. Pausing from here is equivalent to using the global pause control and is reflected consistently on the Activity page.

## Source

- `Desktop/Sources/Rewind/UI/RewindPage.swift`
- `Desktop/Sources/ScreenCaptureService.swift`
- `Desktop/Sources/Rewind/Core/VideoChunkEncoder.swift`
- `Desktop/Sources/Rewind/Core/RewindOCRService.swift`
- `Desktop/Sources/AI/VisionLLMClient.swift`
- `Desktop/Sources/Rewind/Services/VisualActivitySampler.swift`
- `Desktop/Sources/Rewind/Services/VisualActivityIndexer.swift`
- `Desktop/Sources/Rewind/Services/RewindIndexer.swift`
- `Desktop/Sources/Rewind/Core/RewindDatabase.swift`
- `Desktop/Sources/Rewind/Core/RewindStorage.swift`
- `Desktop/Sources/Power/BatteryAwareScheduler.swift`
