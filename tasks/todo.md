# Voice Fingerprinting For Transcript Speaker Identity

Issue: #111

## Implementation Checklist

- [x] Confirm current speaker diarization, assignment, and people flows
- [x] Add voice-profile metadata migrations for speaker embedding samples
- [x] Replace raw optional person match with conservative known/suggested/unknown result
- [x] Make speaker assignment apply to all same-session speaker segments by default
- [x] Persist confirmed assignment metadata and backfill matching speaker embeddings
- [x] Surface confidence/suggestion metadata to transcript models where needed
- [x] Add People voice-profile management primitives for reset/delete/merge basics
- [x] Add focused tests for assignment and matcher behavior
- [x] Run Swift build/tests
- [x] Review diff, update docs if API/UX behavior changed

## Verification

- [x] `xcrun swift build -c debug --package-path Desktop`
- [x] `xcrun swift test --package-path Desktop --filter TranscriptSpeakerAssignmentTests`
- [x] Delegate read-only review of recent session changes to at least 3 subagents
- [x] Aggregate review feedback and identify actionable findings
- [x] Delegate fixes for actionable findings; issues were addressed
- [x] Adjudicate questionable single-agent findings; only consensus fixes were delegated for implementation
- [x] Delegate local CI-equivalent workflow run for `.github/workflows/*`; Swift build/tests, Rust cargo tests, and diff check passed
- [ ] Review all user commands from this session and confirm completion
- [ ] Close exit-gate items from the default workflow
- [ ] Commit completed work
- [ ] Merge completed work to main
- [ ] Cleanup branch/worktree artifacts
- [ ] Verify GitHub Actions on main are passing green

## Results

- First-pass voice identity backbone landed: conservative matching states, voice-profile sample metadata, assignment backfill hardening, and focused tests.
- Adjudication round completed: consensus fixes are migration append-ordering, short/noisy manual-sample gating, and separating suggested/unknown confidence from applied identities.
- Final CI-equivalent verification completed after all fixes: `xcrun swift build`, full Swift tests, Rust tests with/without `activity_test_wiring`, and `git diff --check` passed.
- `test-install.yml` was checked with non-mutating equivalents; full install flow was not run because it writes to `/Applications`, mounts a DMG, launches the GUI app, and deletes the app.
- Read-only release lookup found latest Omi release assets `omi.dmg` and `Omi.zip`, while `test-install.yml` currently looks for `Omi.Beta.dmg`.
- People management UI remains a follow-up layer on top of the new reset/delete/merge store primitives.

## Review Notes

- Optimize for fewer wrong names over faster auto-labeling.
- Store embeddings only; do not retain raw audio snippets for voice identity.
- Treat Mike as a normal person profile, not a special `You` identity.
