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
    @Environment(\.openURL) private var openURL

    let selectedConnectionID: UUID?
    let selectedModelID: String?
    let effort: Effort
    let onSelectModel: (UUID, String) -> Void
    let onSelectEffort: (Effort) -> Void
    let onOpenSettings: () -> Void
    /// Opens "Add a connection" where the sheet was shown from; nil falls back to Settings.
    let onAddConnection: (() -> Void)?

    @State private var page: Page = .root
    @State private var currentEffort: Effort
    @State private var renaming: ModelRenameTarget?
    @State private var query = ""
    #if os(iOS)
    @State private var detent: PresentationDetent = Self.initialDetent
    #endif

    enum Page: Equatable { case root, provider(UUID), search }

    init(selectedConnectionID: UUID?, selectedModelID: String?, effort: Effort,
         onSelectModel: @escaping (UUID, String) -> Void, onSelectEffort: @escaping (Effort) -> Void,
         onOpenSettings: @escaping () -> Void, onAddConnection: (() -> Void)? = nil) {
        self.selectedConnectionID = selectedConnectionID
        self.selectedModelID = selectedModelID
        self.effort = effort
        self.onSelectModel = onSelectModel
        self.onSelectEffort = onSelectEffort
        self.onOpenSettings = onOpenSettings
        self.onAddConnection = onAddConnection
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
            case .search: searchPage
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        #endif
        .modelRenameAlert($renaming)
        .task {
            // Not tied to the sheet: a quick pick that closes it mustn't cancel the refresh halfway.
            Task { await connections.refreshStaleModels() }
            await connections.fetchMissingAccountModels()
        }
    }

    #if os(iOS)
    /// Medium; `-StrataSheetDetent large` (Debug) opens it full height, for screenshots.
    private static var initialDetent: PresentationDetent {
        #if DEBUG
        if DebugHooks.value("StrataSheetDetent") == "large" { return .large }
        #endif
        return .medium
    }
    #endif

    private var groups: [ModelPickerCatalog.Group] {
        ModelPickerCatalog.groups(connections: connections.connections,
                                  currentConnectionID: selectedConnectionID, currentModelID: selectedModelID)
    }

    private var root: some View {
        let groups = groups
        // Connections with nothing to pick yet (signed out, or models not fetched): listed so they don't just vanish.
        let unset = connections.connections.filter { c in !groups.contains { $0.connectionID == c.id } }
        return SheetScaffold(title: "Select model") {
            effortSection
            planUsageSection
            if groups.isEmpty && unset.isEmpty {
                // Nothing connected yet: the ways to start, here, instead of a pointer to Settings.
                GroupedSection(header: "No models yet",
                               footer: "Sign in with your ChatGPT plan, or add an API key or a server on your network.") {
                    if OnDevice.system.availability.isSupported {
                        SettingsRow(systemImage: "apple.intelligence", title: "Use Apple Intelligence (free, on device)") {
                            connections.addOnDeviceConnection()
                        }
                    }
                    SettingsRow(systemImage: "plus", title: "Add a connection", showsChevron: true, action: onAddConnection ?? onOpenSettings)
                }
            } else if groups.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    GroupedSection(footer: "Finish setting up a connection, then pick one of its models.") {
                        ForEach(unset) { c in
                            SettingsRow(title: "", value: String(localized: "Set up"), showsChevron: true, verbatimTitle: c.name) {
                                SettingsRoute.shared.connection = c.id
                                onOpenSettings()
                            }
                        }
                    }
                    ModelRefreshFooter(connectionIDs: unset.map(\.id))
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
                        SettingsRow(title: "", value: String(localized: "Set up"), showsChevron: true, verbatimTitle: c.name) {
                            SettingsRoute.shared.connection = c.id // Settings opens on this connection, not its top
                            onOpenSettings()
                        }
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
        // Above the list, so a long one doesn't hide it: refreshing is a provider's own business, one at a time.
        ModelRefreshFooter(connectionIDs: [group.connectionID])
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if items.isEmpty {
                GroupedSection { SettingsRow(title: "No models match") }
            } else {
                GroupedSection(footer: query.isEmpty ? group.footer.map { LocalizedStringKey($0) } : nil) {
                    ForEach(items) { item in modelRow(item, subtitle: item.limits) }
                }
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

    /// While the chat's model is on a ChatGPT connection: "Using ChatGPT plan" with the "Manage usage" link, which
    /// OpenAI's guidelines put near the composer or the model selector. First in the selector, where the model is
    /// chosen, rather than on the composer itself.
    @ViewBuilder private var planUsageSection: some View {
        if connections.connection(selectedConnectionID)?.isChatGPT == true {
            GroupedSection {
                SettingsRow(systemImage: "chart.bar", title: "Using ChatGPT plan", value: String(localized: "Manage usage"),
                            showsChevron: true) { openURL(ChatGPTOAuth.usageURL) }
            }
        }
    }

    @ViewBuilder private var settingsSections: some View {
        if !connections.connections.isEmpty { // nothing to search with until there's a model
            GroupedSection {
                SettingsRow(title: "Search engine", value: settings.searchEngine.label, showsChevron: true) {
                    withAnimation(DS.Motion.snappy) { page = .search }
                }
            }
        }
        GroupedSection {
            SettingsRow(systemImage: "slider.horizontal.3", title: "Manage connections", showsChevron: true, action: onOpenSettings)
        }
    }

    private var effortStyle: EffortStyle { connections.connection(selectedConnectionID)?.effortStyle ?? .tokenCaps }

    /// The model's effort levels, first in the sheet: the composer's chip shows the effort next to the model, so tapping
    /// it to change the effort lands right on it, one tap per level.
    @ViewBuilder private var effortSection: some View {
        let style = effortStyle
        let levels = selectedModel?.effortLevels(style) ?? []
        if !levels.isEmpty { // the same test as the composer's chip
            let current = currentEffort.resolved(in: levels)
            GroupedSection(header: "Effort", footer: LocalizedStringKey(current.hint(style))) {
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(levels) { e in
                        let selected = e == current
                        Button {
                            currentEffort = e
                            onSelectEffort(e)
                        } label: {
                            Text(e.title)
                                .font(DS.Typography.uiSmall.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(selected ? theme.textPrimary.opacity(0.12) : .clear, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(DS.Spacing.xs)
                .animation(DS.Motion.snappy, value: current)
            }
        }
    }

    private var searchPage: some View {
        SheetScaffold(title: "Search engine", leading: .back({ withAnimation(DS.Motion.snappy) { page = .root } })) {
            GroupedSection(footer: "Auto searches Naver for Korean queries while you're in Korea, and Bing otherwise. If the engine fails or finds nothing, the next one is tried.") {
                ForEach(SearchEnginePreference.allCases) { engine in
                    SettingsRow(title: LocalizedStringKey(engine.label), isChecked: engine == settings.searchEngine) {
                        settings.searchEngine = engine
                    }
                }
            }
        }
    }
}

// MARK: - Model list refresh

/// "Can't find a model?" under the picker's list: refreshes the lists of `connectionIDs` (all at once), says when they
/// last came in, and takes a model id by hand for a server without a model list. Hidden when none of them has a list to
/// fetch (Apple's on-device model, accounts signed out).
private struct ModelRefreshFooter: View {
    @Environment(\.theme) private var theme
    @Environment(\.connectionStore) private var connections
    let connectionIDs: [UUID]

    /// The last refresh tapped here, when it failed.
    @State private var error: String?
    @State private var adding: UUID?
    @State private var newModelID = ""

    private var refreshable: [Connection] {
        connectionIDs.compactMap { connections.connection($0) }.filter { connections.canRefreshModels($0) }
    }
    private var running: Bool { refreshable.contains { connections.modelFetches[$0.id]?.running == true } }
    /// The oldest of the lists, so "Updated" never claims more than all of them.
    private var updated: Date? { refreshable.compactMap { connections.modelsFetchedAt[$0.id] }.min() }

    var body: some View {
        let refreshable = refreshable
        if !refreshable.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS.Spacing.xs) {
                    Text("Can't find a model?").foregroundStyle(theme.textSecondary)
                    if let updated {
                        TimelineView(.everyMinute) { context in
                            Text(verbatim: "· " + ModelListRefresh.updatedText(updated, now: context.date))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
                .font(DS.Typography.uiCaption)
                .padding(.top, DS.Spacing.xs)
                HStack(spacing: DS.Spacing.lg) {
                    Button { refresh(refreshable) } label: {
                        if running {
                            Label { Text("Refreshing…") } icon: { ProgressView().controlSize(.mini) }
                        } else {
                            Label("Refresh models", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.quietLink(.accent))
                    .disabled(running)
                    addButton(refreshable.filter { connections.canAddModelID($0) })
                }
                if let error {
                    Text(verbatim: error).font(DS.Typography.uiCaption).foregroundStyle(theme.destructive)
                        .lineLimit(3)
                        .padding(.bottom, DS.Spacing.xs)
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .alert("Add model ID", isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })) {
                TextField("model-id", text: $newModelID)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("Add") {
                    if let adding { connections.addManualModel(newModelID, connectionID: adding) }
                    adding = nil
                }
                Button("Cancel", role: .cancel) { adding = nil }
            } message: {
                Text("For a server that doesn't list its models. The ID is sent exactly as typed.")
            }
        }
    }

    /// One target: a link. Several: a menu of them.
    @ViewBuilder private func addButton(_ targets: [Connection]) -> some View {
        if targets.count == 1, let only = targets.first {
            Button { startAdding(only.id) } label: { Label("Add model ID", systemImage: "plus") }
                .buttonStyle(.quietLink(.secondary))
        } else if targets.count > 1 {
            Menu {
                ForEach(targets) { c in Button { startAdding(c.id) } label: { Text(verbatim: c.name) } }
            } label: {
                Label("Add model ID", systemImage: "plus")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.quietLink(.secondary))
            .fixedSize()
        }
    }

    private func startAdding(_ id: UUID) {
        newModelID = ""
        adding = id
    }

    private func refresh(_ targets: [Connection]) {
        error = nil
        Task {
            let errors = await connections.refreshModels(of: targets.map(\.id))
            let failed = targets.filter { errors[$0.id] != nil }
            if failed.count == 1, let c = failed.first, let message = errors[c.id] {
                error = String(localized: "Couldn't refresh \(c.name): \(message)")
            } else if !failed.isEmpty {
                error = String(localized: "Couldn't refresh \(failed.map(\.name).formatted(.list(type: .and))).")
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
                        Text("This model can't read images. If it can, turn image support on.")
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
            .animation(DS.Motion.snappy, value: supportsImages) // turning support on brings the tiles up in place
            GroupedSection {
                SettingsRow(systemImage: "photo.on.rectangle", title: "Add photo", showsChevron: true) { showLibrary = true }
                    .disabled(!supportsImages)
                    .opacity(supportsImages ? 1 : 0.45)
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .photosPicker(isPresented: $showLibrary, selection: $libraryItems, maxSelectionCount: 10, matching: .images)
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
