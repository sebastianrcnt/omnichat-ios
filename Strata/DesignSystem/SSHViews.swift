import SwiftUI

// SSH in the feed: one quiet line per call ("Ran uptime on nas"), its command and output under it when opened, and the
// cards that wait for the user (approve a command, answer a prompt) right under the call they belong to. Secrets
// (passwords, keys, passphrases, stdin, `ssh_credential_get`'s result) stay masked until tapped.

/// An SSH call as the UI reads it, from its arguments and result.
struct SSHCallDisplay: Equatable {
    var tool: String
    var args: SSHArguments
    var output: String

    init(tool: String, arguments: String, output: String) {
        self.tool = tool
        args = SSHArguments(json: arguments)
        self.output = output
    }

    /// The server's name, or `user@host`.
    var server: String {
        if let server = args.string("server") { return server }
        guard let host = args.string("host") else { return "" }
        return args.string("user").map { "\($0)@\(host)" } ?? host
    }

    var command: String { args.raw("command") ?? "" }
    var path: String { args.string("path") ?? "" }
    var name: String { args.string("name") ?? "" }

    var result: SSHResultLine? { SSHResultLine(output) }
    var declined: Bool { output.hasPrefix("Error: the user declined") }

    /// The command's first line, short.
    var shortCommand: String {
        let first = command.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? command
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        let short = trimmed.count > 60 ? String(trimmed.prefix(57)) + "…" : trimmed
        return command.contains("\n") && !short.hasSuffix("…") ? short + " …" : short
    }

    /// The line's words, with the command or path set in code.
    func title(running: Bool, failed: Bool) -> [(text: String, code: Bool)] {
        let on: [(text: String, code: Bool)] = server.isEmpty ? [] : [(String(localized: " on \(server)"), false)]
        switch tool {
        case SSHToolNames.exec:
            let verb = running ? String(localized: "Running ") : declined ? String(localized: "Didn't run ")
                : failed ? String(localized: "Couldn't run ") : String(localized: "Ran ")
            return [(verb, false), (shortCommand, true)] + on + (running ? [("…", false)] : [])
        case SSHToolNames.upload:
            let verb = running ? String(localized: "Uploading ") : declined ? String(localized: "Didn't upload ")
                : failed ? String(localized: "Couldn't upload ") : String(localized: "Uploaded ")
            return [(verb, false), (path, true), (server.isEmpty ? "" : String(localized: " to \(server)"), false), (running ? "…" : "", false)]
        case SSHToolNames.download:
            let verb = running ? String(localized: "Downloading ") : failed ? String(localized: "Couldn't download ") : String(localized: "Downloaded ")
            return [(verb, false), (path, true), (server.isEmpty ? "" : String(localized: " from \(server)"), false), (running ? "…" : "", false)]
        default:
            return [(Self.line(tool: tool, name: name, running: running, failed: failed, importing: args.raw("ssh_config") != nil), false)]
        }
    }

    static func line(tool: String, name: String, running: Bool, failed: Bool, importing: Bool) -> String {
        if failed {
            return switch tool {
            case SSHToolNames.output: String(localized: "Couldn't read more output")
            case SSHToolNames.keygen: String(localized: "Couldn't generate key \(name)")
            default: String(localized: "SSH: couldn't \(tool.replacingOccurrences(of: "ssh_", with: "").replacingOccurrences(of: "_", with: " "))")
            }
        }
        return switch tool {
        case SSHToolNames.output: running ? String(localized: "Reading more output…") : String(localized: "Read more output")
        case SSHToolNames.credentialSave: running ? String(localized: "Saving credential \(name)…") : String(localized: "Saved credential \(name)")
        case SSHToolNames.credentialList: String(localized: "Listed SSH credentials")
        case SSHToolNames.credentialGet: String(localized: "Read credential \(name)")
        case SSHToolNames.credentialDelete: String(localized: "Deleted credential \(name)")
        case SSHToolNames.serverSave:
            importing ? String(localized: "Imported servers from ssh_config") : String(localized: "Saved server \(name)")
        case SSHToolNames.serverList: String(localized: "Listed SSH servers")
        case SSHToolNames.serverDelete: String(localized: "Deleted server \(name)")
        case SSHToolNames.keygen: running ? String(localized: "Generating key \(name)…") : String(localized: "Generated key \(name)")
        default: tool
        }
    }

    /// Small print after the line: a non-zero exit code, a timeout, a refusal.
    func meta(running: Bool, failed: Bool) -> String? {
        if running { return nil }
        if declined { return String(localized: "Denied") }
        if failed { return String(localized: "Failed") }
        guard let result else { return nil }
        if result.timedOut { return String(localized: "Timed out") }
        if let signal = result.signal { return String(localized: "Killed (\(signal))") }
        if let code = result.exitCode, code != 0 { return String(localized: "Exit \(code)") }
        return nil
    }

    /// Secret arguments, masked in the detail.
    var secrets: [(label: String, value: String)] {
        let labels = ["password": String(localized: "Password"), "private_key": String(localized: "Private key"),
                      "passphrase": String(localized: "Passphrase"), "answers": String(localized: "Answers"),
                      "stdin": String(localized: "Input"), "certificate": String(localized: "Certificate")]
        return SSHMask.secretKeys.sorted().compactMap { key in args.raw(key).map { (labels[key] ?? key, $0) } }
    }
}

// MARK: - Feed

/// One SSH call in the feed. Exec and transfers open to their command and output; the other tools are one line.
struct SSHFeedCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.citations) private var citations
    let card: FeedCard
    let collapsed: Bool
    let onToggle: () -> Void
    var onDetails: () -> Void

    private var call: SSHCallDisplay {
        guard case .ssh(let tool, let arguments) = card.kind else { return SSHCallDisplay(tool: "", arguments: "", output: "") }
        return SSHCallDisplay(tool: tool, arguments: arguments, output: card.output)
    }

    var body: some View {
        let call = call
        let request = SSHRequests.shared.request(forCall: card.id, conversation: citations.conversationID)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                SSHLine(words: call.title(running: card.isRunning, failed: card.isError),
                        meta: call.meta(running: card.isRunning, failed: card.isError),
                        expanded: card.isRunning && request == nil ? nil : !collapsed) {
                    if card.isRunning && request == nil { FeedSpinner() }
                    else { FeedSymbol(name: "terminal", color: card.isError ? theme.warning : nil) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(collapsed ? "Collapsed" : "Expanded"))
            if let request {
                SSHRequestCard(request: request)
                    .padding(.leading, DS.Feed.textInset)
                    .padding(.vertical, DS.Spacing.xs)
                    .transition(.opacity)
            } else if !collapsed {
                SSHCallDetail(call: call, isRunning: card.isRunning, isError: card.isError)
                    .padding(.leading, DS.Feed.textInset)
                    .padding(.vertical, DS.Spacing.xs)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : ActivityFeedView.fold, value: collapsed)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: request?.id)
        .contextMenu {
            Button("Show Timeline", systemImage: "list.bullet.below.rectangle", action: onDetails)
        }
    }
}

/// The Timeline's row for an SSH call: the line, and the detail when the Timeline shows details.
struct SSHTimelineRow: View {
    @Environment(\.citations) private var citations
    let call: SSHCallDisplay
    let callID: String
    let isRunning: Bool
    let isError: Bool
    let showsDetail: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SSHLine(words: call.title(running: isRunning, failed: isError), meta: call.meta(running: isRunning, failed: isError), expanded: nil) {
                if isRunning { FeedSpinner() } else { FeedSymbol(name: "terminal") }
            }
            if let request = SSHRequests.shared.request(forCall: callID, conversation: citations.conversationID) {
                SSHRequestCard(request: request)
            } else if showsDetail {
                SSHCallDetail(call: call, isRunning: isRunning, isError: isError)
            }
        }
    }
}

/// A feed line whose title can set a command in code (`FeedLine`'s layout).
struct SSHLine<Icon: View>: View {
    @Environment(\.theme) private var theme
    let words: [(text: String, code: Bool)]
    var meta: String?
    var expanded: Bool?
    @ViewBuilder let icon: () -> Icon
    @ScaledMetric(relativeTo: .subheadline) private var midline: CGFloat = 5

    private var title: Text {
        var line = AttributedString()
        for word in words {
            var part = AttributedString(word.text)
            if word.code { part.font = .system(.subheadline, design: .monospaced) }
            line += part
        }
        return Text(line)
    }

    var body: some View {
        let midline = midline
        HStack(alignment: .firstTextBaseline, spacing: DS.Feed.iconGap) {
            icon()
                .frame(width: DS.Feed.iconColumn, height: DS.Feed.iconColumn)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + midline }
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs + DS.Spacing.xxs) {
                title
                    .font(DS.Typography.thought)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let meta {
                    Text(meta).font(DS.Typography.feedMeta).foregroundStyle(theme.warning).lineLimit(1).fixedSize()
                }
                if let expanded {
                    Image(systemName: "chevron.right")
                        .font(.system(size: DS.Feed.mark, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Spacing.xs)
        .frame(minHeight: DS.Feed.lineHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// What a call sent and got: the command, masked secrets, then stdout and stderr (the last lines first shown).
struct SSHCallDetail: View {
    @Environment(\.theme) private var theme
    let call: SSHCallDisplay
    var isRunning = false
    var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if call.tool == SSHToolNames.exec, !call.command.isEmpty {
                CodeBlockView(content: CodeBlockContent(language: "bash", code: call.command))
            }
            if !call.secrets.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    ForEach(call.secrets, id: \.label) { SSHSecretText(label: $0.label, value: $0.value) }
                }
            }
            if !isRunning {
                if call.tool == SSHToolNames.exec, call.result != nil {
                    let streams = SSHResultLine.streams(call.output)
                    if !streams.stdout.isEmpty { SSHOutputView(text: streams.stdout) }
                    if !streams.stderr.isEmpty { SSHOutputView(text: streams.stderr, isError: true) }
                    if streams.stdout.isEmpty && streams.stderr.isEmpty {
                        Text("No output").font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary)
                    }
                } else if SSHMask.resultIsSecret(call.tool) && !isError {
                    SSHSecretText(label: String(localized: "Credential"), value: call.output)
                } else if !call.output.isEmpty {
                    SSHOutputView(text: call.output, isError: isError)
                }
            }
        }
    }
}

/// Monospaced output, showing its last lines until "Show all" (the end of a command's output matters most).
struct SSHOutputView: View {
    @Environment(\.theme) private var theme
    let text: String
    var isError = false
    @State private var expanded = false

    static let foldedLines = 12

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let long = lines.count > Self.foldedLines + 3
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if long {
                Button(expanded ? "Show less" : "Show all \(lines.count) lines") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(DS.Typography.feedMeta)
                    .foregroundStyle(theme.textTertiary)
            }
            Text(verbatim: long && !expanded ? lines.suffix(Self.foldedLines).joined(separator: "\n") : text)
                .font(DS.Typography.monoSmall)
                .foregroundStyle(isError ? theme.warning : theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Spacing.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
    }
}

/// A secret, masked until tapped.
struct SSHSecretText: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: String
    @State private var revealed = false

    var body: some View {
        let masked = value == SSHMask.dots
        Button { if !masked { revealed.toggle() } } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                Text(verbatim: label).font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary)
                Text(verbatim: revealed ? value : SSHMask.dots)
                    .font(DS.Typography.monoSmall)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(revealed ? nil : 1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !masked {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .font(.system(size: DS.Feed.mark))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(revealed ? value : String(localized: "Hidden")))
        .accessibilityHint(Text(revealed ? "Hides it" : "Shows it"))
    }
}

// MARK: - Requests

/// The card a call waits on: approve a command, or answer the server's questions.
struct SSHRequestCard: View {
    let request: SSHRequests.Request

    var body: some View {
        switch request.kind {
        case .approval(let approval):
            SSHApprovalCard(approval: approval) { SSHRequests.shared.answer(request.id, .approval($0)) }
        case .prompt(let prompt):
            SSHPromptCard(prompt: prompt) { SSHRequests.shared.answer(request.id, .prompt($0)) }
        }
    }
}

/// "Run this on nas?" with the command, and Run / Always for this server / Deny.
struct SSHApprovalCard: View {
    @Environment(\.theme) private var theme
    let approval: SSHApproval
    let onAnswer: (SSHApprovalAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            switch approval.action {
            case .exec(let command):
                Text("Run this command on \(approval.server)?").font(DS.Typography.feedEmphasis).foregroundStyle(theme.textPrimary)
                CodeBlockView(content: CodeBlockContent(language: "bash", code: command))
            case .upload(let path, let bytes):
                Text("Write \(path) on \(approval.server)?").font(DS.Typography.feedEmphasis).foregroundStyle(theme.textPrimary)
                Text("\(bytes.formatted(.byteCount(style: .file))), replacing the file if it exists.")
                    .font(DS.Typography.feed).foregroundStyle(theme.textSecondary)
            }
            HStack(spacing: DS.Spacing.lg) {
                Button("Run") { onAnswer(.run) }.buttonStyle(.quietLink(.accent))
                Button("Always for \(approval.server)") { onAnswer(.always) }.buttonStyle(.quietLink(.secondary))
                Button("Deny") { onAnswer(.deny) }.buttonStyle(.quietLink(.secondary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The server's keyboard-interactive questions (a 2FA code, a password), answered here and sent once, never saved.
struct SSHPromptCard: View {
    @Environment(\.theme) private var theme
    let prompt: SSHPromptRequest
    let onAnswer: ([String]?) -> Void
    @State private var answers: [String]
    @FocusState private var focused: Int?

    init(prompt: SSHPromptRequest, onAnswer: @escaping ([String]?) -> Void) {
        self.prompt = prompt
        self.onAnswer = onAnswer
        _answers = State(initialValue: Array(repeating: "", count: prompt.prompts.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("\(prompt.hop) asks:").font(DS.Typography.feedEmphasis).foregroundStyle(theme.textPrimary)
            let intro = [prompt.name, prompt.instruction].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !intro.isEmpty {
                Text(verbatim: intro.joined(separator: "\n")).font(DS.Typography.feed).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(prompt.prompts.indices, id: \.self) { i in
                let label = prompt.prompts[i].text.trimmingCharacters(in: .whitespaces)
                Group {
                    if prompt.prompts[i].echo {
                        TextField("", text: $answers[i], prompt: Text(verbatim: label))
                    } else {
                        SecureField("", text: $answers[i], prompt: Text(verbatim: label))
                    }
                }
                .font(DS.Typography.ui)
                .plainTextInput(keyboard: .standard)
                .focused($focused, equals: i)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                .onSubmit { if i == prompt.prompts.count - 1 { onAnswer(answers) } else { focused = i + 1 } }
            }
            HStack(spacing: DS.Spacing.lg) {
                Button("Send") { onAnswer(answers) }.buttonStyle(.quietLink(.accent))
                Button("Cancel") { onAnswer(nil) }.buttonStyle(.quietLink(.secondary))
            }
            Text("Sent to the server once; not saved.").font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { focused = 0 }
    }
}
