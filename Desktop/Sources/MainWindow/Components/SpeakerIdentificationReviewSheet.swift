import AVFoundation
import SwiftUI

struct SpeakerReviewSample: Identifiable, Equatable {
    let id: String
    let segmentIndex: Int
    let start: Double
    let end: Double
    let text: String
}

struct SpeakerReviewQueueItem: Identifiable, Equatable {
    let id: String
    let speakerKey: String
    let speakerId: Int
    let suggestedPersonId: String?
    let suggestedSimilarity: Double?
    let segmentIndices: [Int]
    let samples: [SpeakerReviewSample]

    var isSuggested: Bool { suggestedPersonId != nil }
}

enum SpeakerReviewQueueBuilder {
    static let minimumReviewableDuration: Double = 1.2
    static let minimumSampleDuration: Double = 3.0
    static let maximumSampleDuration: Double = 8.0

    static func makeQueue(from segments: [TranscriptSegment]) -> [SpeakerReviewQueueItem] {
        let assignable = segments.enumerated().filter { _, segment in
            segment.personId == nil && !segment.isUser
        }
        let reviewable = assignable.filter { _, segment in
            isReviewable(segment)
        }
        let assignableBySpeaker = Dictionary(grouping: assignable) { _, segment in
            speakerKey(for: segment)
        }
        let reviewableBySpeaker = Dictionary(grouping: reviewable) { _, segment in
            speakerKey(for: segment)
        }

        return reviewableBySpeaker.compactMap { key, reviewableEntries in
            let allEntries = assignableBySpeaker[key] ?? reviewableEntries
            let sorted = reviewableEntries.sorted { lhs, rhs in
                let leftDuration = lhs.element.end - lhs.element.start
                let rightDuration = rhs.element.end - rhs.element.start
                if leftDuration == rightDuration {
                    return lhs.element.start < rhs.element.start
                }
                return leftDuration > rightDuration
            }
            let samples = sorted.prefix(5).map { index, segment in
                sample(for: segment, index: index)
            }
            guard !samples.isEmpty, let first = allEntries.sorted(by: { $0.offset < $1.offset }).first?.element else {
                return nil
            }
            let suggestion = suggestedCandidate(from: allEntries)
            return SpeakerReviewQueueItem(
                id: key,
                speakerKey: key,
                speakerId: first.speakerId,
                suggestedPersonId: suggestion?.suggestedPersonId,
                suggestedSimilarity: suggestion?.suggestedSimilarity,
                segmentIndices: allEntries.map(\.offset).sorted(),
                samples: samples
            )
        }
        .sorted { lhs, rhs in
            if lhs.isSuggested != rhs.isSuggested {
                return lhs.isSuggested && !rhs.isSuggested
            }
            return lhs.speakerId < rhs.speakerId
        }
    }

    static func isReviewable(_ segment: TranscriptSegment) -> Bool {
        let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard segment.end - segment.start >= minimumReviewableDuration else { return false }
        return !isNoiseOnly(trimmed)
    }

    static func isNoiseOnly(_ text: String) -> Bool {
        let lowered = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return true }

        let noiseWords = [
            "music", "gentle music", "background music", "noise", "silence",
            "applause", "laughter", "inaudible", "static", "beep", "tone"
        ]
        if noiseWords.contains(lowered) { return true }
        return noiseWords.contains { lowered == "[\($0)]" || lowered == "(\($0))" }
    }

    private static func suggestedCandidate(
        from entries: [(offset: Int, element: TranscriptSegment)]
    ) -> TranscriptSegment? {
        entries
            .filter { $0.element.suggestedPersonId != nil }
            .sorted { lhs, rhs in
                let leftSimilarity = lhs.element.suggestedSimilarity ?? -Double.infinity
                let rightSimilarity = rhs.element.suggestedSimilarity ?? -Double.infinity
                if leftSimilarity == rightSimilarity {
                    return lhs.offset < rhs.offset
                }
                return leftSimilarity > rightSimilarity
            }
            .first?
            .element
    }

    private static func speakerKey(for segment: TranscriptSegment) -> String {
        if let speaker = segment.speaker, !speaker.isEmpty {
            return speaker
        }
        return String(format: "SPEAKER_%02d", segment.speakerId)
    }

    private static func sample(for segment: TranscriptSegment, index: Int) -> SpeakerReviewSample {
        let duration = max(0, segment.end - segment.start)
        let targetDuration = min(max(duration, minimumSampleDuration), maximumSampleDuration)
        let midpoint = (segment.start + segment.end) * 0.5
        let start = max(0, midpoint - targetDuration * 0.5)
        return SpeakerReviewSample(
            id: segment.id,
            segmentIndex: index,
            start: start,
            end: start + targetDuration,
            text: segment.text
        )
    }
}

struct SpeakerIdentificationReviewSheet: View {
    let conversationId: String
    let segments: [TranscriptSegment]
    let people: [Person]
    let onAssign: (_ segmentIndices: [Int], _ personId: String?, _ isUser: Bool) async -> Bool
    let onCreatePerson: (_ name: String) async -> Person?
    let onDismiss: () -> Void

    @State private var queue: [SpeakerReviewQueueItem]
    @State private var currentIndex = 0
    @State private var currentSampleIndex = 0
    @State private var selectedTarget: SpeakerAssignmentTarget?
    @State private var isAddingNewPerson = false
    @State private var newPersonName = ""
    @State private var duplicateWarning: String?
    @State private var isSaving = false
    @State private var isCreating = false
    @State private var isLoadingAudio = false
    @State private var audioPlayer: AVAudioPlayer?

    init(
        conversationId: String,
        segments: [TranscriptSegment],
        people: [Person],
        onAssign: @escaping (_ segmentIndices: [Int], _ personId: String?, _ isUser: Bool) async -> Bool,
        onCreatePerson: @escaping (_ name: String) async -> Person?,
        onDismiss: @escaping () -> Void
    ) {
        self.conversationId = conversationId
        self.segments = segments
        self.people = people
        self.onAssign = onAssign
        self.onCreatePerson = onCreatePerson
        self.onDismiss = onDismiss
        _queue = State(initialValue: SpeakerReviewQueueBuilder.makeQueue(from: segments))
    }

    private var currentItem: SpeakerReviewQueueItem? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    private var currentSample: SpeakerReviewSample? {
        guard let item = currentItem, item.samples.indices.contains(currentSampleIndex) else { return nil }
        return item.samples[currentSampleIndex]
    }

    private var canSave: Bool {
        selectedTarget != nil && !isSaving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(OmiColors.border)

            if let item = currentItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        speakerSummary(item)
                        sampleSection
                        peopleSelectionSection
                    }
                    .padding(20)
                }
                footer(item)
            } else {
                emptyState
            }
        }
        .frame(width: 460, height: 560)
        .background(OmiColors.backgroundPrimary)
        .onAppear(perform: resetSelectionForCurrentSpeaker)
    }

    private var header: some View {
        HStack {
            Text("Identify Speakers")
                .scaledFont(size: 16, weight: .semibold)
                .foregroundColor(OmiColors.textPrimary)
            Spacer()
            if !queue.isEmpty {
                Text("\(currentIndex + 1) of \(queue.count)")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundColor(OmiColors.textTertiary)
            }
            DismissButton(action: onDismiss)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private func speakerSummary(_ item: SpeakerReviewQueueItem) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(item.isSuggested ? OmiColors.purplePrimary.opacity(0.28) : OmiColors.backgroundQuaternary)
                .frame(width: 34, height: 34)
                .overlay(
                    Text(String(item.speakerId))
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundColor(OmiColors.textPrimary)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text("Speaker \(item.speakerId)")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(OmiColors.textPrimary)
                Text(item.isSuggested ? "Suggested match needs review" : "Unknown speaker")
                    .scaledFont(size: 12)
                    .foregroundColor(OmiColors.textSecondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(OmiColors.backgroundSecondary))
    }

    private var sampleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sample")
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(OmiColors.textSecondary)

            Text(currentSample?.text ?? "")
                .scaledFont(size: 13)
                .foregroundColor(OmiColors.textPrimary)
                .lineLimit(4)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(OmiColors.backgroundSecondary))

            HStack(spacing: 8) {
                Button(action: { Task { await playCurrentSample() } }) {
                    HStack(spacing: 6) {
                        Image(systemName: isLoadingAudio ? "hourglass" : "play.fill")
                            .scaledFont(size: 11, weight: .semibold)
                        Text("Play")
                            .scaledFont(size: 12, weight: .medium)
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                .disabled(isLoadingAudio || currentSample == nil)

                Button("Another Sample") {
                    guard let item = currentItem, item.samples.count > 1 else { return }
                    currentSampleIndex = (currentSampleIndex + 1) % item.samples.count
                }
                .buttonStyle(.plain)
                .foregroundColor(OmiColors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Capsule().fill(OmiColors.backgroundTertiary))
                .disabled((currentItem?.samples.count ?? 0) < 2)
            }
        }
    }

    private var peopleSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who is this?")
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(OmiColors.textSecondary)

            FlowLayout(spacing: 8) {
                personChip(label: "You", isSelected: selectedTarget == .you) {
                    selectedTarget = .you
                    isAddingNewPerson = false
                    newPersonName = ""
                    duplicateWarning = nil
                }

                ForEach(people) { person in
                    personChip(label: person.name, isSelected: selectedTarget == .person(person.id)) {
                        selectedTarget = .person(person.id)
                        isAddingNewPerson = false
                        newPersonName = ""
                        duplicateWarning = nil
                    }
                }

                personChip(label: "+ Add Person", isSelected: isAddingNewPerson, isAction: true) {
                    isAddingNewPerson = true
                    selectedTarget = nil
                    duplicateWarning = nil
                }
            }

            if isAddingNewPerson {
                HStack(spacing: 8) {
                    TextField("Person name", text: $newPersonName)
                        .textFieldStyle(.plain)
                        .scaledFont(size: 13)
                        .foregroundColor(OmiColors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(OmiColors.backgroundSecondary))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(duplicateWarning != nil ? OmiColors.error : OmiColors.border, lineWidth: 1)
                        )
                        .onChange(of: newPersonName) { _, value in validateName(value) }
                        .onSubmit { Task { await createAndSelect() } }

                    Button(action: { Task { await createAndSelect() } }) {
                        Text(isCreating ? "Adding" : "Add")
                            .scaledFont(size: 12, weight: .medium)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(canCreate ? .black : OmiColors.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(canCreate ? Color.white : OmiColors.backgroundTertiary))
                    .disabled(!canCreate || isCreating)
                }

                if let duplicateWarning {
                    Text(duplicateWarning)
                        .scaledFont(size: 11)
                        .foregroundColor(OmiColors.error)
                }
            }
        }
    }

    private func footer(_ item: SpeakerReviewQueueItem) -> some View {
        VStack(spacing: 0) {
            Divider().background(OmiColors.border)
            HStack {
                Button("Skip") {
                    skipCurrent()
                }
                .buttonStyle(.plain)
                .foregroundColor(OmiColors.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                Spacer()

                Button(action: { Task { await saveCurrent(item) } }) {
                    Text(isSaving ? "Saving" : "Confirm")
                        .scaledFont(size: 12, weight: .medium)
                }
                .buttonStyle(.plain)
                .foregroundColor(canSave ? .black : OmiColors.textTertiary)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Capsule().fill(canSave ? Color.white : OmiColors.backgroundTertiary))
                .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.2.wave.2")
                .scaledFont(size: 36)
                .foregroundColor(OmiColors.textTertiary.opacity(0.7))
            Text("No speakers need review")
                .scaledFont(size: 14, weight: .medium)
                .foregroundColor(OmiColors.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canCreate: Bool {
        let trimmed = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && duplicateWarning == nil
    }

    private func validateName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        duplicateWarning = people.contains { $0.name.lowercased() == trimmed.lowercased() }
            ? "A person with this name already exists"
            : nil
    }

    private func createAndSelect() async {
        guard canCreate else { return }
        isCreating = true
        let trimmed = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let person = await onCreatePerson(trimmed) {
            selectedTarget = .person(person.id)
            isAddingNewPerson = false
            newPersonName = ""
        }
        isCreating = false
    }

    private func saveCurrent(_ item: SpeakerReviewQueueItem) async {
        guard let target = selectedTarget else { return }
        isSaving = true
        let success = await onAssign(item.segmentIndices, target.personId, target.isUser)
        isSaving = false
        if success {
            queue.remove(at: currentIndex)
            if currentIndex >= queue.count {
                currentIndex = max(0, queue.count - 1)
            }
            resetSelectionForCurrentSpeaker()
            if queue.isEmpty {
                onDismiss()
            }
        }
    }

    private func skipCurrent() {
        guard !queue.isEmpty else { return }
        queue.remove(at: currentIndex)
        if currentIndex >= queue.count {
            currentIndex = max(0, queue.count - 1)
        }
        if queue.isEmpty {
            onDismiss()
            return
        }
        resetSelectionForCurrentSpeaker()
    }

    private func resetSelectionForCurrentSpeaker() {
        currentSampleIndex = 0
        selectedTarget = currentItem?.suggestedPersonId.map { .person($0) }
        isAddingNewPerson = false
        newPersonName = ""
        duplicateWarning = nil
    }

    private func playCurrentSample() async {
        guard let sample = currentSample else { return }
        isLoadingAudio = true
        let data = await AudioPersistenceService.shared.reviewAudioWAV(
            conversationId: conversationId,
            startTime: sample.start,
            endTime: sample.end
        )
        isLoadingAudio = false
        guard let data, !data.isEmpty else { return }
        do {
            let player = try AVAudioPlayer(data: data)
            audioPlayer = player
            player.prepareToPlay()
            player.play()
        } catch {
            logError("Identify Speakers: failed to play review sample", error: error)
        }
    }

    private func personChip(label: String, isSelected: Bool, isAction: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .scaledFont(size: 13, weight: isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .black : (isAction ? OmiColors.purplePrimary : OmiColors.textPrimary))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(isSelected ? Color.white : OmiColors.backgroundTertiary))
                .overlay(
                    Capsule()
                        .stroke(isSelected ? OmiColors.border : (isAction ? OmiColors.purplePrimary.opacity(0.3) : Color.clear), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
