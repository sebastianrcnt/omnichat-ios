import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The live input level as a row of accent bars, newest on the right. With Reduce Motion the bars stand still.
struct DictationWaveform: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var levels: [Float]

    private static let barWidth: CGFloat = 3
    private static let minHeight: CGFloat = 4
    private static let maxHeight: CGFloat = 20
    /// The still shape shown with Reduce Motion.
    private static let still: [CGFloat] = [0.3, 0.55, 0.8, 1, 0.8, 0.55, 0.3]

    var body: some View {
        HStack(spacing: DS.Spacing.xxs) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(theme.accent)
                    .frame(width: Self.barWidth, height: height(at: i))
            }
        }
        .frame(height: Self.maxHeight + DS.Spacing.xs)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }

    private func height(at i: Int) -> CGFloat {
        let fraction = reduceMotion ? Self.still[i % Self.still.count] : CGFloat(levels[i])
        return Self.minHeight + (Self.maxHeight - Self.minHeight) * fraction
    }
}

/// Elapsed dictation time, "0:04". Stops at `end` when listening ended on its own.
struct DictationElapsed: View {
    @Environment(\.theme) private var theme
    var start: Date?
    var end: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = start.map { max(0, Int((end ?? context.date).timeIntervalSince($0))) } ?? 0
            Text(verbatim: String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(DS.Typography.uiCaption)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)
        }
        .accessibilityHidden(true)
    }
}

/// "Preparing dictation…" while the language model downloads (`.preparing`), or why dictation could not start
/// (`.failed`).
struct DictationStatusLine: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    var phase: DictationController.Phase

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            switch phase {
            case .failed(let failure):
                Text(Self.message(for: failure))
                    .font(DS.Typography.uiSmall)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if failure.opensSettings, let url = Self.settingsURL(for: failure) {
                    Button { openURL(url) } label: {
                        Text("Settings")
                            .font(DS.Typography.capsule)
                            .foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, DS.Spacing.md)
                            .frame(minHeight: DS.IconSize.compactControlDiameter - DS.Spacing.sm)
                            .glassEffect(.regular.interactive(), in: Capsule())
                            .contentShape(Capsule().inset(by: -DS.Spacing.xs))
                    }
                    .buttonStyle(.plain)
                }
            default:
                ProgressView().controlSize(.small)
                Text("Preparing dictation…")
                    .font(DS.Typography.uiSmall)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    static func message(for failure: DictationController.Failure) -> LocalizedStringKey {
        #if os(macOS)
        switch failure {
        case .microphoneDenied: "Microphone access is off. Turn it on in System Settings."
        case .speechDenied: "Speech recognition is off. Turn it on in System Settings."
        case .unsupportedLocale: "Dictation isn't available for this language on this device."
        case .assetUnavailable: "The dictation model couldn't be downloaded. Try again later."
        case .microphoneUnavailable: "No microphone is available."
        case .notConfigured: "Dictation is set to use an API, but no connection or model is chosen. Pick them in Settings > Chats > Dictation."
        case .network: "Couldn't reach the transcription service. Check your connection and try again."
        case .timedOut: "Transcription took too long. Try again."
        case .unauthorized: "The transcription service rejected the API key. Check the connection in Settings."
        case .tooLong: "The recording is too long to transcribe. Try a shorter one."
        case .service(let detail): "Transcription failed: \(detail)"
        case .failed: "Dictation stopped unexpectedly."
        }
        #else
        switch failure {
        case .microphoneDenied: "Microphone access is off. Turn it on in Settings."
        case .speechDenied: "Speech recognition is off. Turn it on in Settings."
        case .unsupportedLocale: "Dictation isn't available for this language on this device."
        case .assetUnavailable: "The dictation model couldn't be downloaded. Try again later."
        case .microphoneUnavailable: "No microphone is available."
        case .notConfigured: "Dictation is set to use an API, but no connection or model is chosen. Pick them in Settings > Chats > Dictation."
        case .network: "Couldn't reach the transcription service. Check your connection and try again."
        case .timedOut: "Transcription took too long. Try again."
        case .unauthorized: "The transcription service rejected the API key. Check the connection in Settings."
        case .tooLong: "The recording is too long to transcribe. Try a shorter one."
        case .service(let detail): "Transcription failed: \(detail)"
        case .failed: "Dictation stopped unexpectedly."
        }
        #endif
    }

    static func settingsURL(for failure: DictationController.Failure) -> URL? {
        #if os(macOS)
        let pane = failure == .microphoneDenied ? "Privacy_Microphone" : "Privacy_SpeechRecognition"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        #else
        return URL(string: UIApplication.openSettingsURLString)
        #endif
    }
}

/// The accent check that ends dictation and puts the words into the field.
struct DictationConfirmButton: View {
    @Environment(\.theme) private var theme
    var enabled = true
    let action: () -> Void

    var body: some View {
        let d = DS.IconSize.compactControlDiameter
        Button(action: action) {
            Image(systemName: "checkmark").font(.system(size: DS.IconSize.composerIcon, weight: .bold))
                .foregroundStyle(enabled ? theme.onAccent : theme.textSecondary)
                .frame(width: d, height: d)
                .background { Circle().fill(enabled ? theme.accent : theme.fillTertiary) }
                .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text("Done dictating"))
        .accessibilityHint(Text("Puts the words into the message"))
    }
}

#Preview("Light · Purple") { DictationPreview().previewStyle(.light) }
#Preview("Dark · Purple") { DictationPreview().previewStyle(.dark) }
#Preview("Dark · Orange") { DictationPreview().previewStyle(.dark, accent: Color(hex: "#F97316")) }

private struct DictationPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            HStack(spacing: DS.Spacing.sm) {
                GlassIconButton(systemName: "xmark", label: "Cancel dictation", diameter: DS.IconSize.compactControlDiameter,
                                iconSize: DS.IconSize.composerIcon) {}
                DictationWaveform(levels: [0.1, 0.4, 0.8, 0.6, 0.9, 0.3, 0.5])
                DictationElapsed(start: .now.addingTimeInterval(-4))
                DictationConfirmButton {}
            }
            DictationStatusLine(phase: .preparing)
            DictationStatusLine(phase: .failed(.microphoneDenied))
        }
        .padding()
    }
}
