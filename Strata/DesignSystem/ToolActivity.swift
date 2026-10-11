import SwiftUI

/// Collapsible "Searched the web, read N pages" row listing queries and URLs.
struct ToolActivityRow: View {
    @Environment(\.theme) private var theme
    let calls: [ToolCallRecord]
    var pending: [PendingToolCall] = []
    @State private var expanded = false

    private var searches: Int { calls.filter { $0.name == ToolNames.webSearch }.count }
    private var pages: Int { calls.filter { $0.name == ToolNames.webFetch }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Button {
                withAnimation(DS.Motion.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "globe").font(.system(size: DS.IconSize.md)).foregroundStyle(theme.textSecondary)
                    Text(Self.summary(searches: searches, pages: pages, running: pending.first))
                        .font(DS.Typography.uiSmall)
                        .foregroundStyle(pending.isEmpty ? theme.textSecondary : theme.accent)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: DS.IconSize.sm, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    ForEach(calls) { call in
                        detail(call: call)
                    }
                    ForEach(pending) { p in
                        HStack(spacing: DS.Spacing.sm) {
                            ProgressView().controlSize(.mini)
                            Text(p.primaryArgument).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary).lineLimit(1)
                        }
                    }
                }
                .padding(.leading, DS.Spacing.xl)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func detail(call: ToolCallRecord) -> some View {
        let arg = call.primaryArgument
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
            Image(systemName: call.name == ToolNames.webSearch ? "magnifyingglass" : "doc.text")
                .font(.system(size: DS.IconSize.sm))
                .foregroundStyle(call.isError ? theme.warning : theme.textTertiary)
            if call.name == ToolNames.webFetch, let url = URL(string: arg) {
                SourceChip(title: url.host(percentEncoded: false) ?? arg, url: url)
            } else {
                Text(arg).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
            }
        }
    }

    static func summary(searches: Int, pages: Int, running: PendingToolCall?) -> String {
        if let running {
            return running.name == ToolNames.webSearch ? String(localized: "Searching the web…") : String(localized: "Reading page…")
        }
        switch (searches > 0, pages > 0) {
        case (true, true): return String(localized: "Searched the web, read \(pages) pages")
        case (true, false): return String(localized: "Searched the web")
        case (false, true): return String(localized: "Read \(pages) pages")
        default: return String(localized: "Used tools")
        }
    }
}

#Preview("Light · Purple") { toolPreview.previewStyle(.light) }
#Preview("Dark · Purple") { toolPreview.previewStyle(.dark) }
#Preview("Dark · Orange") { toolPreview.previewStyle(.dark, accent: Color(hex: "#F97316")) }

@MainActor private var toolPreview: some View {
    VStack(alignment: .leading, spacing: DS.Spacing.lg) {
        ToolActivityRow(calls: [
            .init(id: "1", name: "web_search", arguments: "{\"query\":\"swiftui liquid glass\"}", result: "", isError: false),
            .init(id: "2", name: "web_fetch", arguments: "{\"url\":\"https://developer.apple.com/documentation\"}", result: "", isError: false),
        ])
        ToolActivityRow(calls: [], pending: [.init(id: "3", name: "web_search", primaryArgument: "latest news")])
    }
    .padding()
}
