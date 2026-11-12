import SwiftUI

/// Opens an artifact in the panel beside the chat (the Mac window) instead of over it. Nil where there is no panel:
/// the cards open the artifact full screen, or as a sheet.
struct ArtifactPanel {
    let open: @MainActor (ArtifactRef) -> Void
    /// Shows an artifact still being written (`ArtifactDraftViewer`); the stored artifact takes its place.
    let openDraft: @MainActor (ArtifactDraftRequest) -> Void
}

private struct ArtifactPanelKey: EnvironmentKey { static let defaultValue: ArtifactPanel? = nil }

extension EnvironmentValues {
    var artifactPanel: ArtifactPanel? {
        get { self[ArtifactPanelKey.self] }
        set { self[ArtifactPanelKey.self] = newValue }
    }
}

extension View {
    /// The chat with its artifact panel: a resizable column on the trailing side, open while `artifact` is set, or
    /// `draft` (an artifact still being written).
    func artifactPanel(_ artifact: Binding<ArtifactRef?>, draft: Binding<ArtifactDraftRequest?>) -> some View {
        environment(\.artifactPanel, ArtifactPanel(
            open: { draft.wrappedValue = nil; artifact.wrappedValue = $0 },
            openDraft: { artifact.wrappedValue = nil; draft.wrappedValue = $0 }))
            .inspector(isPresented: Binding(get: { artifact.wrappedValue != nil || draft.wrappedValue != nil },
                                            set: { if !$0 { artifact.wrappedValue = nil; draft.wrappedValue = nil } })) {
                if let request = draft.wrappedValue {
                    ArtifactDraftViewer(request: request,
                                        onStored: { artifact.wrappedValue = $0; draft.wrappedValue = nil },
                                        onClose: { draft.wrappedValue = nil })
                        .id(request.id)
                        .inspectorColumnWidth(min: 360, ideal: 560, max: 1400)
                } else if let ref = artifact.wrappedValue {
                    ArtifactViewer(ref: ref, onClose: { artifact.wrappedValue = nil })
                        .id(ref) // another artifact, or a newer version: a fresh page
                        .inspectorColumnWidth(min: 360, ideal: 560, max: 1400)
                }
            }
    }
}
