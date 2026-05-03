# Descript-Style Speaker Identification

Issue: #112

## UX Scenarios

- [x] From a transcript, Mike can click any speaker label or avatar, including the purple `Y`, to correct who is speaking.
- [x] From a transcript, Mike can open an `Identify Speakers` flow that reviews each unknown/suggested speaker cluster one at a time.
- [x] For each detected speaker, Mike hears a short representative audio sample before choosing an existing person or creating a new one.
- [x] If the sample is unclear, Mike can play another sample from the same speaker cluster.
- [x] Once Mike identifies a speaker, IR labels matching segments in that conversation and updates the local voice profile.
- [x] Over time, confirmed profiles let IR suggest or auto-apply names across newly recorded conversations.
- [x] Raw mixed mic+system audio is retained locally only for a configurable review window, defaulting to 7 days, then deleted while embeddings and transcript labels remain.
- [x] After a recording finishes, IR prompts Mike to identify speakers when unknown or suggested speakers exist.

## Current State

- [x] Voice profiles and conservative known/suggested/unknown identity decisions exist from #111.
- [x] Transcript speaker picker exists, but `isUser` / `You` bubbles are not clickable.
- [x] `audio_chunks` schema already exists for local PCM storage.
- [x] `AudioPersistenceService` already exists, but the current live audio path does not appear wired to append mixed audio chunks.

## Plan

- [x] Make speaker labels and avatars clickable for every segment, including `You`.
  - Existing code gates taps in `TranscriptDetailView`, `ConversationDetailView.transcriptBubblesContent`, and `SpeakerBubbleView`.
- [x] Update `NameSpeakerSheet` so reassignment from `You` to a person is first-class, not blocked by `isUser`.
  - Existing same-speaker filters exclude `isUser`; remove that exclusion while still saving `isUser=false` for normal people.
- [x] Add an `Identify Speakers` entry point in the transcript header or speaker count pill.
  - Use the drawer header because unknown/suggested state is visible while reviewing transcript detail.
- [x] Build a review queue grouped by session speaker cluster and suggested/unknown identity state.
  - Use `TranscriptSegment.speakerId`, `personId`, and suggested metadata; exclude already named known speakers from the default queue.
- [x] Select good playback samples per speaker: prefer clear speech, 3-8 seconds, enough duration, no music/noise-only text, avoid very short turns.
  - Add deterministic sample-selection helpers so tests can cover the filter without SwiftUI.
- [x] Wire live mixed audio into `AudioPersistenceService` and link chunks to `transcriptionSessionId`.
  - Existing tee in `AppState.startMicrophoneAudioCapture` sends mono mix to WhisperKit and diarization only.
- [x] Add audio fetch APIs for a session/time range and convert PCM to playable audio for review.
  - Add this to `AudioPersistenceService` near existing chunk writes; UI can play a temporary WAV file via `AVAudioPlayer`.
- [x] Add a configurable local retention policy for `audio_chunks`; default to 7 days and purge on app launch and periodically.
  - Store the setting in `UserDefaults` and purge from `RewindDatabase.performInitialization` plus service timer/explicit calls.
- [x] Confirmed speaker identification should update transcript segments plus speaker embeddings for the selected sample ranges.
  - Existing `PeopleStore.assignSegments` already backfills embeddings by segment time range; review flow should call the same assignment path.
- [x] Cross-conversation behavior should apply automatically when confidence is high; do not add a second broad-apply confirmation step.
- [x] Keep wrong-name risk low with strict thresholds, sample-count gates, and no training from excluded samples.
- [x] Exclude short/music/noise-only segments like `(gentle music)` from speaker review and voice training.
- [x] Add tests for clickable-user reassignment, audio retention purge, sample selection, and assignment backfill by sample range.

## Decisions

- [x] Retain mixed mic+system audio only; no separate mic/system channel storage for this feature.
- [x] Make retention a setting, with 7 days as the default.
- [x] Show the Identify Speakers prompt automatically after a recording when reviewable speakers exist.
- [x] Do not require a second cross-conversation apply confirmation.
- [x] Exclude short/music/noise segments from speaker review and voice training.

## References

- Descript flow: detect speakers, then identify by listening to samples and assigning names.
- Descript docs: https://help.descript.com/hc/en-us/articles/10249423506061-Detect-and-label-speakers-in-your-transcript
- Descript speaker labels docs: https://help.descript.com/hc/en-us/articles/10164803814285-Speakers

## Open Questions

- When one speaker cluster has multiple possible people, should the UI require review before applying any name, or show suggested names inline?
