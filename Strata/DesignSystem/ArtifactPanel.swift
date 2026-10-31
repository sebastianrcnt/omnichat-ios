import SwiftUI

/// Opens an artifact in the panel beside the chat (the Mac window) instead of over it. Nil where there is no panel:
/// the cards open the artifact full screen, or as a sheet.
struct ArtifactPanel {
    let open: @MainActor (ArtifactRef) -> Void
}

private struct ArtifactPanelKey: EnvironmentKey { static let defaultValue: ArtifactPanel? = nil }

extension EnvironmentValues {
    var artifactPanel: ArtifactPanel? {
        get { self[ArtifactPanelKey.self] }
        set { self[ArtifactPanelKey.self] = newValue }
    }
}

extension View {
    /// The chat with its artifact panel: a resizable column on the trailing side, open while `artifact` is set.
    func artifactPanel(_ artifact: Binding<ArtifactRef?>) -> some View {
        environment(\.artifactPanel, ArtifactPanel { artifact.wrappedValue = $0 })
            .inspector(isPresented: Binding(get: { artifact.wrappedValue != nil },
                                            set: { if !$0 { artifact.wrappedValue = nil } })) {
                if let ref = artifact.wrappedValue {
                    ArtifactViewer(ref: ref, onClose: { artifact.wrappedValue = nil })
                        .id(ref) // another artifact, or a newer version: a fresh page
                        .inspectorColumnWidth(min: 360, ideal: 560, max: 1400)
                }
            }
    }
}
