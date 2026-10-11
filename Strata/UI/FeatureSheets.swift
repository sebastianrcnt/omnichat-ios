import SwiftUI
import PhotosUI
import SwiftData

enum TokenFormat {
    /// 149_000 -> "149k", 1_250_000 -> "1.3M", 900 -> "900"
    static func short(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...: "\(Int((Double(n) / 1000).rounded()))k"
        case 1_000...: String(format: "%.1fk", Double(n) / 1000)
        default: "\(n)"
        }
    }
}

// MARK: - Model picker

struct ModelPickerSheet: View {
    @Environment(ConnectionStore.self) private var connections
    @Environment(\.dismiss) private var dismiss

    let selectedConnectionID: UUID?
    let selectedModelID: String?
    let effort: Effort
    let onSelectModel: (UUID, String) -> Void
    let onSelectEffort: (Effort) -> Void
    let onOpenSettings: () -> Void

    @State private var page: Page = .root
    @State private var currentEffort: Effort

    enum Page { case root, effort }

    init(selectedConnectionID: UUID?, selectedModelID: String?, effort: Effort,
         onSelectModel: @escaping (UUID, String) -> Void, onSelectEffort: @escaping (Effort) -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.selectedConnectionID = selectedConnectionID
        self.selectedModelID = selectedModelID
        self.effort = effort
        self.onSelectModel = onSelectModel
        self.onSelectEffort = onSelectEffort
        self.onOpenSettings = onOpenSettings
        _currentEffort = State(initialValue: effort)
    }

    private var selectedModel: ModelInfo? {
        connections.connection(selectedConnectionID)?.models.first { $0.id == selectedModelID }
    }

    var body: some View {
        Group {
            switch page {
            case .root: root
            case .effort: effortPage
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var root: some View {
        SheetScaffold(title: "Select model") {
            if connections.allModels.isEmpty {
                GroupedSection(footer: "Add a connection in Settings, then fetch its models or add one by hand.") {
                    SettingsRow(title: "No models yet")
                }
            }
            ForEach(connections.connections.filter { !$0.models.isEmpty }) { conn in
                GroupedSection(header: LocalizedStringKey(conn.name)) {
                    ForEach(conn.models) { model in
                        SettingsRow(title: LocalizedStringKey(model.id), subtitle: Self.capabilities(model),
                                    isChecked: conn.id == selectedConnectionID && model.id == selectedModelID) {
                            onSelectModel(conn.id, model.id)
                            dismiss()
                        }
                    }
                }
            }
            if selectedModel?.supportsEffort == true {
                GroupedSection {
                    SettingsRow(title: "Effort", value: currentEffort.title, showsChevron: true) {
                        withAnimation(DS.Motion.snappy) { page = .effort }
                    }
                }
            }
            GroupedSection {
                SettingsRow(systemImage: "slider.horizontal.3", title: "Manage connections", showsChevron: true, action: onOpenSettings)
            }
        }
    }

    private var effortPage: some View {
        SheetScaffold(title: "Effort", leading: .back({ withAnimation(DS.Motion.snappy) { page = .root } })) {
            GroupedSection(footer: "Higher effort lets the model think longer. It costs more time and tokens. Limits are the engine's thinking-token caps.") {
                ForEach(Effort.allCases) { e in
                    SettingsRow(title: LocalizedStringKey(e.isRecommended ? String(localized: "\(e.title) (recommended)") : e.title),
                                subtitle: e.hint, isChecked: e == currentEffort) {
                        currentEffort = e
                        onSelectEffort(e)
                    }
                }
            }
        }
    }

    static func capabilities(_ m: ModelInfo) -> String? {
        var parts: [String] = []
        if m.supportsImages { parts.append(String(localized: "Images")) }
        if m.supportsEffort { parts.append(String(localized: "Effort")) }
        if m.supportsTools { parts.append(String(localized: "Web tools")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Usage

struct UsageSheet: View {
    @Environment(ConnectionStore.self) private var connections
    let conversation: Conversation?
    let contextLength: Int
    let connection: Connection?
    var balanceProvider: any BalanceProviding = UnavailableBalanceProvider()

    @State private var balanceState: BalanceState = .loading

    enum BalanceState: Equatable { case loading, unavailable, loaded(BalanceInfo) }

    private var usage: Usage? { conversation?.lastUsage }

    var body: some View {
        SheetScaffold(title: "Usage", trailing: {
            GlassIconButton(systemName: "arrow.clockwise", label: "Refresh") { Task { await loadBalance() } }
        }) {
            GroupedSection(header: "Context") {
                let used = usage?.totalTokens ?? 0
                let pct = contextLength > 0 ? Double(used) / Double(contextLength) : 0
                UsageCard(title: "Context window",
                          valueText: String(localized: "\(Int((pct * 100).rounded()))% used"),
                          fraction: pct,
                          caption: String(localized: "\(TokenFormat.short(used)) of \(TokenFormat.short(contextLength)) tokens used"))
                    .padding(DS.Spacing.sm)
            }
            if let usage {
                GroupedSection(header: "Last request") {
                    SettingsRow(title: "Input tokens", value: usage.promptTokens.formatted())
                    SettingsRow(title: "Output tokens", value: usage.completionTokens.formatted())
                    if let r = usage.reasoningTokens { SettingsRow(title: "Reasoning tokens", value: r.formatted()) }
                    SettingsRow(title: "Cache hit", value: Self.cacheText(usage))
                }
            }
            if connection?.isStrata ?? true {
                GroupedSection(header: "Balance", footer: "Balance applies to the Strata connection only.") {
                    switch balanceState {
                    case .loading:
                        SettingsRow(title: "Balance", value: String(localized: "Loading…"))
                    case .unavailable:
                        SettingsRow(title: "Balance", value: String(localized: "Not available"))
                    case .loaded(let info):
                        SettingsRow(title: "Balance", value: Self.usd(info.balanceUSD))
                        SettingsRow(title: "This chat", value: Self.usd(info.chatCostUSD))
                        SettingsRow(title: "Today", value: Self.usd(info.todaySpendUSD))
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await loadBalance() }
    }

    private func loadBalance() async {
        guard let connection, connection.isStrata else { balanceState = .unavailable; return }
        balanceState = .loading
        do {
            let info = try await balanceProvider.balance(for: connection, apiKey: connections.apiKey(for: connection.id))
            balanceState = .loaded(info)
        } catch {
            balanceState = .unavailable
        }
    }

    static func cacheText(_ u: Usage) -> String {
        guard let cached = u.cachedTokens else { return String(localized: "Not reported") }
        guard u.promptTokens > 0 else { return String(localized: "None") }
        let pct = Int((Double(cached) / Double(u.promptTokens) * 100).rounded())
        return String(localized: "\(cached.formatted()) of \(u.promptTokens.formatted()) (\(pct)%)")
    }

    static func usd(_ v: Double?) -> String {
        v.map { $0.formatted(.currency(code: "USD")) } ?? String(localized: "Not available")
    }
}

// MARK: - Attach

struct AttachSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let supportsImages: Bool
    let onPick: ([Data]) -> Void

    @State private var items: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var loading = false

    private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        SheetScaffold(title: "Add photos") {
            if !supportsImages {
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(theme.warning)
                    Text("The selected model is not marked as supporting images. Pick a different model, or turn on image support for it in Settings > Connections.")
                        .font(DS.Typography.uiSmall).foregroundStyle(theme.textPrimary)
                }
                .padding(DS.Spacing.md)
                .background(theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.md))
            }
            HStack(spacing: DS.Spacing.md) {
                Button { showCamera = true } label: {
                    VStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "camera").font(.system(size: DS.IconSize.lg))
                        Text("Camera").font(DS.Typography.uiSmall)
                    }
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: DS.IconSize.cameraTile, height: DS.IconSize.cameraTile)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
                }
                .buttonStyle(.plain)
                .disabled(!supportsImages || !cameraAvailable)
                .opacity(cameraAvailable && supportsImages ? 1 : 0.45)

                PhotosPicker(selection: $items, maxSelectionCount: 4, matching: .images) { Color.clear }
                    .photosPickerStyle(.compact)
                    .photosPickerAccessoryVisibility(.hidden, edges: .all)
                    .frame(height: DS.IconSize.cameraTile)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
                    .disabled(!supportsImages)
                    .opacity(supportsImages ? 1 : 0.45)
            }
            GroupedSection {
                PhotosPicker(selection: $items, maxSelectionCount: 4, matching: .images) {
                    AddPhotoRowLabel()
                }
                .buttonStyle(.plain)
                .disabled(!supportsImages)
                .opacity(supportsImages ? 1 : 0.45)
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: items) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task { await load(newItems) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let data = ImageProcessor.jpegData(from: image) { onPick([data]) }
                dismiss()
            }
            .ignoresSafeArea()
        }
    }

    private func load(_ picked: [PhotosPickerItem]) async {
        loading = true
        var out: [Data] = []
        for item in picked {
            if let data = try? await item.loadTransferable(type: Data.self),
               let jpeg = await Task.detached(operation: { ImageProcessor.jpegData(from: data) }).value {
                out.append(jpeg)
            }
        }
        loading = false
        items = []
        if !out.isEmpty { onPick(out) }
        dismiss()
    }
}

private struct AddPhotoRowLabel: View {
    var body: some View {
        SettingsRow(systemImage: "photo.on.rectangle", title: "Add photo", showsChevron: true)
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            else { parent.dismiss() }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
