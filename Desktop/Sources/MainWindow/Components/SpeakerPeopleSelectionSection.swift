import SwiftUI

struct SpeakerPeopleSelectionSection: View {
    let people: [Person]
    @Binding var selectedTarget: SpeakerAssignmentTarget?
    @Binding var isAddingNewPerson: Bool
    @Binding var newPersonName: String
    @Binding var duplicateWarning: String?
    let canCreate: Bool
    let isCreating: Bool
    let showsCreationProgress: Bool
    let onNameChange: (String) -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who is this?")
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(OmiColors.textSecondary)

            FlowLayout(spacing: 8) {
                personChip(label: "You", isSelected: selectedTarget == .you) {
                    select(.you)
                }

                ForEach(people) { person in
                    personChip(label: person.name, isSelected: selectedTarget == .person(person.id)) {
                        select(.person(person.id))
                    }
                }

                personChip(label: "+ Add Person", isSelected: isAddingNewPerson, isAction: true) {
                    isAddingNewPerson = true
                    selectedTarget = nil
                    duplicateWarning = nil
                }
            }

            if isAddingNewPerson {
                VStack(alignment: .leading, spacing: 6) {
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
                            .onChange(of: newPersonName) { _, value in onNameChange(value) }
                            .onSubmit {
                                if canCreate {
                                    onCreate()
                                }
                            }

                        Button(action: onCreate) {
                            if isCreating && showsCreationProgress {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 14, height: 14)
                            } else {
                                Text(isCreating ? "Adding" : "Add")
                                    .scaledFont(size: 12, weight: .medium)
                            }
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
    }

    private func select(_ target: SpeakerAssignmentTarget) {
        selectedTarget = target
        isAddingNewPerson = false
        newPersonName = ""
        duplicateWarning = nil
    }

    private func personChip(
        label: String,
        isSelected: Bool,
        isAction: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .scaledFont(size: 13, weight: isSelected ? .semibold : .regular)
                .foregroundColor(chipForegroundColor(isSelected: isSelected, isAction: isAction))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(isSelected ? Color.white : OmiColors.backgroundTertiary))
                .overlay(
                    Capsule()
                        .stroke(chipBorderColor(isSelected: isSelected, isAction: isAction), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func chipForegroundColor(isSelected: Bool, isAction: Bool) -> Color {
        if isSelected { return .black }
        if isAction { return OmiColors.purplePrimary }
        return OmiColors.textPrimary
    }

    private func chipBorderColor(isSelected: Bool, isAction: Bool) -> Color {
        if isSelected { return OmiColors.border }
        if isAction { return OmiColors.purplePrimary.opacity(0.3) }
        return .clear
    }
}
