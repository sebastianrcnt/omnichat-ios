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

/// The gauge's sheet (a popover on a Mac). With one connection it lists that connection's models; with several it shows
/// the recent models (one tap to switch back) and a row per connection that opens its list. Effort and search engine
/// come last.
struct ModelPickerSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.connectionStore) private var connections
    @Environment(\.appSettings) private var settings
    @Environment(\.dismiss) private var dismiss

    let selectedConnectionID: UUID?
    let selectedModelID: String?
    let effort: Effort
    let onSelectModel: (UUID, String) -> Void
    let onSelectEffort: (Effort) -> Void
    let onOpenSettings: () -> Void

    @State private var page: Page = .root
    @State private var currentEffort: Effort
    @State private var renaming: ModelRenameTarget?
    @State private var query = ""

    enum Page: Equatable { case root, provider(UUID), effort, search }

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
            case .provider(let id): providerPage(id)
            case .effort: effortPage
            case .search: searchPage
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .modelRenameAlert($renaming)
        .task { await connections.fetchMissingAccountModels() }
    }

    private var groups: [ModelPickerCatalog.Group] {
        ModelPickerCatalog.groups(connections: connections.connections,
                                  currentConnectionID: selectedConnectionID, currentModelID: selectedModelID)
    }

    private var root: some View {
        let groups = groups
        // Connections with nothing to pick yet (signed out, or models not fetched): listed so they don't just vanish.
        let unset = connections.connections.filter { c in !groups.contains { $0.connectionID == c.id } }
        return SheetScaffold(title: "Select model") {
            if groups.isEmpty {
                GroupedSection(footer: "Add a connection in Settings, then fetch its models or add one by hand.") {
                    SettingsRow(title: "No models yet")
                }
            } else if groups.count == 1, unset.isEmpty, let only = groups.first {
                modelList(only)
            } else {
                let recent = ModelPickerCatalog.recent(groups: groups, recentKeys: settings.recentModels,
                                                       currentConnectionID: selectedConnectionID, currentModelID: selectedModelID)
                if !recent.isEmpty {
                    GroupedSection(header: "Recent") {
                        ForEach(recent) { item in
                            let provider = groups.first { $0.connectionID == item.connectionID }?.name ?? ""
                            modelRow(item, subtitle: [provider, item.limits].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                }
                GroupedSection(header: "Providers") {
                    ForEach(groups) { group in
                        SettingsRow(title: "", value: group.items.count == 1
                                        ? String(localized: "1 model") : String(localized: "\(group.items.count) models"),
                                    showsChevron: true, verbatimTitle: group.name) {
                            query = ""
                            withAnimation(DS.Motion.snappy) { page = .provider(group.connectionID) }
                        }
                    }
                    ForEach(unset) { c in
                        SettingsRow(title: "", value: String(localized: "Set up"), showsChevron: true, verbatimTitle: c.name,
                                    action: onOpenSettings)
                    }
                }
            }
            settingsSections
        }
    }

    private func providerPage(_ id: UUID) -> some View {
        let group = groups.first { $0.connectionID == id }
        return SheetScaffold(title: LocalizedStringKey(group?.name ?? ""),
                             leading: .back({ withAnimation(DS.Motion.snappy) { page = .root } })) {
            if let group { modelList(group) }
        }
    }

    /// A connection's models, with a search field when the list is long and a footer naming what they all share.
    @ViewBuilder private func modelList(_ group: ModelPickerCatalog.Group) -> some View {
        if group.items.count >= ModelPickerCatalog.searchThreshold {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textSecondary)
                TextField("Search \(group.items.count) models", text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.Typography.ui)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        let items = ModelPickerCatalog.filter(group.items, query: query)
        if items.isEmpty {
            GroupedSection { SettingsRow(title: "No models match") }
        } else {
            GroupedSection(footer: query.isEmpty ? group.footer.map { LocalizedStringKey($0) } : nil) {
                ForEach(items) { item in modelRow(item, subtitle: item.limits) }
            }
        }
    }

    private func modelRow(_ item: ModelPickerCatalog.Item, subtitle: String?) -> some View {
        SettingsRow(modelID: item.modelID, alias: item.subtitle == nil ? nil : item.title,
                    subtitle: subtitle?.isEmpty == true ? nil : subtitle,
                    isChecked: item.connectionID == selectedConnectionID && item.modelID == selectedModelID) {
            settings.recentModels = RecentModels.noting(item.connectionID, item.modelID, in: settings.recentModels)
            onSelectModel(item.connectionID, item.modelID)
            dismiss()
        }
        .contextMenu {
            Button("Rename…", systemImage: "pencil") {
                renaming = ModelRenameTarget(connectionID: item.connectionID, modelID: item.modelID)
            }
            if item.subtitle != nil {
                Button("Reset name", systemImage: "arrow.counterclockwise") {
                    connections.setModelAlias(nil, connectionID: item.connectionID, modelID: item.modelID)
                }
            }
        }
    }

    @ViewBuilder private var settingsSections: some View {
        GroupedSection {
            if selectedModel?.supportsEffort == true {
                SettingsRow(title: "Effort", value: currentEffort.resolved(in: selectedModel?.effortLevels(effortStyle) ?? []).title,
                            showsChevron: true) {
                    withAnimation(DS.Motion.snappy) { page = .effort }
                }
            }
            SettingsRow(title: "Search engine", value: settings.searchEngine.label, showsChevron: true) {
                withAnimation(DS.Motion.snappy) { page = .search }
            }
        }
        GroupedSection {
            SettingsRow(systemImage: "slider.horizontal.3", title: "Manage connections", showsChevron: true, action: onOpenSettings)
        }
    }

    private var effortStyle: EffortStyle { connections.connection(selectedConnectionID)?.effortStyle ?? .tokenCaps }

    private var effortPage: some View {
        let style = effortStyle
        let levels = selectedModel?.effortLevels(style) ?? []
        return SheetScaffold(title: "Effort", leading: .back({ withAnimation(DS.Motion.snappy) { page = .root } })) {
            GroupedSection(footer: style == .tokenCaps
                           ? "Higher effort lets the model think longer. It costs more time and tokens. Limits are the engine's thinking-token caps."
                           : "Higher effort lets the model think longer. It costs more time and plan usage. The model decides how long to think; there is no token cap.") {
                ForEach(levels) { e in
                    SettingsRow(title: LocalizedStringKey(e.isRecommended ? String(localized: "\(e.title) (recommended)") : e.title),
                                subtitle: e.hint(style), isChecked: e == currentEffort.resolved(in: levels)) {
                        currentEffort = e
                        onSelectEffort(e)
                    }
                }
            }
        }
    }

    private var searchPage: some View {
        SheetScaffold(title: "Search engine", leading: .back({ withAnimation(DS.Motion.snappy) { page = .root } })) {
            GroupedSection(footer: "Auto searches Naver for Korean queries and Bing otherwise. If the engine fails or finds nothing, the next one is tried.") {
                ForEach(SearchEnginePreference.allCases) { engine in
                    SettingsRow(title: LocalizedStringKey(engine.label), isChecked: engine == settings.searchEngine) {
                        settings.searchEngine = engine
                    }
                }
            }
        }
    }
}

/// The effort levels as menu items with a check on the current one and the thinking-token cap underneath.
/// Used by the settings sheet and by the gauge's long-press menu.
struct EffortMenuItems: View {
    let levels: [Effort]
    let selected: Effort
    var style: EffortStyle = .tokenCaps
    let onSelect: (Effort) -> Void

    var body: some View {
        ForEach(levels) { e in
            Toggle(isOn: Binding(get: { e == selected }, set: { _ in onSelect(e) })) {
                Text(e.title)
                Text(e.isRecommended ? String(localized: "Recommended · \(e.hint(style))") : e.hint(style))
            }
        }
    }
}

// MARK: - Model rename

/// A model whose display name is being edited.
struct ModelRenameTarget: Identifiable, Equatable {
    var connectionID: UUID
    var modelID: String
    var id: String { "\(connectionID.uuidString)/\(modelID)" }
}

/// Asks for a model's display name. Saving blank text removes the alias.
private struct ModelRenameAlert: ViewModifier {
    @Environment(\.connectionStore) private var connections
    @Binding var target: ModelRenameTarget?
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename model", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                   presenting: target) { t in
                TextField("Display name", text: $text, prompt: Text(verbatim: t.modelID))
                Button("Save") {
                    connections.setModelAlias(text, connectionID: t.connectionID, modelID: t.modelID)
                    target = nil
                }
                Button("Cancel", role: .cancel) { target = nil }
            } message: { t in
                Text("Shown in place of \(t.modelID). Requests still use the real model id. Leave empty to use the id.")
            }
            .onChange(of: target) { _, t in
                guard let t else { return }
                text = connections.connection(t.connectionID)?.alias(forModel: t.modelID) ?? ""
            }
    }
}

extension View {
    func modelRenameAlert(_ target: Binding<ModelRenameTarget?>) -> some View {
        modifier(ModelRenameAlert(target: target))
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
            // Clipping hides a scaled-to-fill photo's overflow but still hit-tests it: a wide photo would take taps
            // meant for the tile before it.
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
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
