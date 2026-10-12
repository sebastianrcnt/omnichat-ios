import SwiftUI
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
    @Environment(\.connectionStore) private var connections
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
    @Environment(\.connectionStore) private var connections
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
                          caption: usage == nil
                            ? String(localized: "No messages yet")
                            : String(localized: "\(TokenFormat.short(used)) of \(TokenFormat.short(contextLength)) tokens used"))
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

// MARK: - Attach (iPhone: camera, recent photos, library; a Mac attaches from a file panel, see MacAttachments)

#if os(iOS)
import PhotosUI
import Photos

struct AttachSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let supportsImages: Bool
    var modelName: String?
    let onPick: ([Data]) -> Void
    /// Turns on "Supports images" for the selected model.
    var onEnableImages: () -> Void = {}

    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var loading = false

    private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        SheetScaffold(title: "Add photos") {
            if !supportsImages {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    HStack(alignment: .top, spacing: DS.Spacing.sm) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(theme.warning)
                        Text("This model can't read images. Turn on \"Supports images\" for it in Settings > Connections.")
                            .font(DS.Typography.uiSmall).foregroundStyle(theme.textPrimary)
                    }
                    Button("Turn on image support", action: onEnableImages).buttonStyle(.glass)
                }
                .padding(DS.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .disabled(!supportsImages)

                // Recent photos: tapping one attaches it. (The system inline PhotosPicker breaks sheet
                // presentation, so this is a small PhotoKit strip.)
                RecentPhotosStrip(enabled: supportsImages) { data in
                    onPick([data])
                    dismiss()
                }
                .frame(height: DS.IconSize.cameraTile)
            }
            .opacity(supportsImages ? 1 : 0.45)
            GroupedSection {
                SettingsRow(systemImage: "photo.on.rectangle", title: "Add photo", showsChevron: true) { showLibrary = true }
                    .disabled(!supportsImages)
                    .opacity(supportsImages ? 1 : 0.45)
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .photosPicker(isPresented: $showLibrary, selection: $libraryItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: libraryItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await load(items) }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                dismiss()
                // Resizing a full camera frame takes tens of milliseconds: not on the main thread.
                Task {
                    if let data = await Task.detached(priority: .userInitiated, operation: { ImageProcessor.jpegData(from: image) }).value {
                        onPick([data])
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    private func load(_ picked: [PhotosPickerItem]) async {
        guard !loading else { return }
        loading = true
        var out: [Data] = []
        for item in picked {
            if let data = try? await item.loadTransferable(type: Data.self),
               let jpeg = await Task.detached(operation: { ImageProcessor.jpegData(from: data) }).value {
                out.append(jpeg)
            }
        }
        loading = false
        libraryItems = []
        if !out.isEmpty { onPick(out) }
        dismiss()
    }
}

/// Horizontal strip of the most recent photos, read through PhotoKit.
struct RecentPhotosStrip: View {
    @Environment(\.theme) private var theme
    let enabled: Bool
    let onPick: (Data) -> Void

    @State private var assets: [PHAsset] = []
    @State private var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var body: some View {
        Group {
            if status == .denied || status == .restricted {
                Text("Photo access is off. Use Add photo below.")
                    .font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: DS.Spacing.sm) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            PhotoTile(asset: asset) { pick(asset) }
                        }
                    }
                }
            }
        }
        .disabled(!enabled)
        .task { await prepare() }
    }

    private func prepare() async {
        var current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .notDetermined { current = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        status = current
        guard current == .authorized || current == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 30
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var out: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in out.append(asset) }
        assets = out
        #if DEBUG
        if DebugHooks.autoPickRecent, let first = out.first { pick(first) }
        #endif
    }

    private func pick(_ asset: PHAsset) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            guard let data else { return }
            Task {
                if let jpeg = await Task.detached(operation: { ImageProcessor.jpegData(from: data) }).value {
                    await MainActor.run { onPick(jpeg) }
                }
            }
        }
    }
}

private struct PhotoTile: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var scale
    let asset: PHAsset
    let action: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: action) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() } else { theme.surface }
            }
            .frame(width: DS.IconSize.cameraTile, height: DS.IconSize.cameraTile)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Photo"))
        .task {
            let side = DS.IconSize.cameraTile * scale
            image = await withCheckedContinuation { cont in
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = true
                var resumed = false
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                      contentMode: .aspectFill, options: options) { image, _ in
                    if !resumed { resumed = true; cont.resume(returning: image) }
                }
            }
        }
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
#endif
