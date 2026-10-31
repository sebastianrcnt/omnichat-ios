import Foundation

/// One answer as text for the share sheet (Messages, KakaoTalk, Mail): what Copy copies, with each link's address
/// written out and the answer's sources listed after it, so its [1] markers lead somewhere outside the app.
enum AnswerShare {
    static func text(markdown: String, sources: [SourceInfo]) -> String {
        let answer = MarkdownPlain.text(from: markdown, showingLinks: true).trimmingCharacters(in: .whitespacesAndNewlines)
        let listed = sources.filter { !$0.url.isEmpty }
        guard !listed.isEmpty else { return answer }
        let lines = listed.map { source in
            let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(source.id)] " + (title.isEmpty ? source.url : "\(title)\n\(source.url)")
        }
        return answer + "\n\n" + String(localized: "Sources") + "\n" + lines.joined(separator: "\n")
    }
}
