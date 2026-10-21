import SwiftUI

// Skills in the UI: the sheet that asks before a model-written skill is saved, and Settings > Browser > Skills, where
// the built-in skills can be read and saved ones edited or deleted.

/// "Save skill?": the whole skill as it would be saved, and the user's answer.
struct SkillApprovalSheet: View {
    @Environment(\.theme) private var theme
    let request: SkillApprovals.Request
    let onAnswer: (Bool) -> Void

    var body: some View {
        SheetScaffold(title: "Save skill?") {
            Text("The assistant wants to save this skill. Its name and description will be listed in new chats, and the assistant will follow it when it loads it. Web pages can contain instructions meant to mislead the assistant: save it only if it looks right to you.")
                .font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if request.replaces != nil {
                Label("It replaces your saved skill with the same name.", systemImage: "exclamationmark.triangle")
                    .font(DS.Typography.uiSmall).foregroundStyle(theme.warning)
            }
            SkillContent(skill: request.skill)
            HStack(spacing: DS.Spacing.md) {
                Button { onAnswer(false) } label: {
                    Text("Don't Save")
                        .font(DS.Typography.uiEmphasis).foregroundStyle(theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
                        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button { onAnswer(true) } label: {
                    Text("Save")
                        .font(DS.Typography.uiEmphasis).foregroundStyle(theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(theme.accent, in: RoundedRectangle(cornerRadius: DS.Radius.md))
                        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                }
                .buttonStyle(.plain)
            }
        }
        .interactiveDismissDisabled()
        .presentationDetents([.large])
        // Closing the sheet any other way (its close button) is a "no"; an answer already given stands.
        .onDisappear { onAnswer(false) }
    }
}

/// A skill's name, description and full text, as typed.
struct SkillContent: View {
    @Environment(\.theme) private var theme
    let skill: Skill

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(verbatim: skill.name).font(DS.Typography.title).foregroundStyle(theme.textPrimary)
                Text(verbatim: skill.description).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: skill.body)
                .font(DS.Typography.monoSmall)
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.md)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        }
    }
}

/// Settings > Browser > Skills.
struct SkillsSettingsView: View {
    @Environment(\.theme) private var theme
    private var store: SkillStore { .shared }

    var body: some View {
        let _ = SkillsVersion.shared.value // redraw when a skill is saved or deleted
        let skills = store.all
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                GroupedSection(header: "Built in", footer: "Skills that come with OpenChat. They can't be changed.") {
                    ForEach(skills.filter(\.isBuiltIn)) { skill in
                        NavigationLink { SkillDetailView(skill: skill) } label: { row(skill) }.buttonStyle(.plain)
                    }
                }
                GroupedSection(header: "Saved", footer: "Skills the assistant saved with your approval. New chats list them; a chat keeps the list it started with.") {
                    let saved = skills.filter { !$0.isBuiltIn }
                    if saved.isEmpty {
                        SettingsRow(title: "No saved skills")
                    }
                    ForEach(saved) { skill in
                        NavigationLink { SkillEditor(skill: skill) } label: { row(skill) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Skills")
        .inlineNavigationTitle()
    }

    private func row(_ skill: Skill) -> some View {
        SettingsRow(title: "", subtitle: skill.description, showsChevron: true, verbatimTitle: skill.name)
    }
}

/// A built-in skill, read only.
struct SkillDetailView: View {
    @Environment(\.theme) private var theme
    let skill: Skill

    var body: some View {
        ScrollView {
            SkillContent(skill: skill).padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(Text(verbatim: skill.name))
        .inlineNavigationTitle()
    }
}

/// A saved skill: its description and text can be edited, or the skill deleted.
struct SkillEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let skill: Skill
    @State private var description: String
    @State private var text: String
    @State private var error: String?
    @State private var confirmDelete = false

    init(skill: Skill) {
        self.skill = skill
        _description = State(initialValue: skill.description)
        _text = State(initialValue: skill.body)
    }

    private var changed: Bool { description != skill.description || text != skill.body }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                GroupedSection(header: "Description", footer: "One line, listed to the assistant in new chats.") {
                    TextField("", text: $description, prompt: Text("What the skill is for"))
                        .font(DS.Typography.ui)
                        .foregroundStyle(theme.textPrimary)
                        .unbezeledField()
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.md)
                }
                GroupedSection(header: "Instructions") {
                    TextField("", text: $text, axis: .vertical)
                        .lineLimit(8...)
                        .font(DS.Typography.monoSmall)
                        .foregroundStyle(theme.textPrimary)
                        .unbezeledField()
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.md)
                }
                if let error {
                    Text(error).font(DS.Typography.uiCaption).foregroundStyle(theme.destructive)
                }
                GroupedSection {
                    SettingsRow(systemImage: "trash", title: "Delete Skill", isDestructive: true) { confirmDelete = true }
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle(Text(verbatim: skill.name))
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .trailingBar) {
                Button("Save", action: save).disabled(!changed)
            }
        }
        .confirmationDialog("Delete this skill?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                SkillStore.shared.delete(named: skill.name)
                dismiss()
            }
        } message: {
            Text("Chats that already list it keep the name, but it can no longer be loaded.")
        }
    }

    private func save() {
        do {
            try SkillStore.shared.save(Skill(name: skill.name, description: description, body: text))
            error = nil
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
