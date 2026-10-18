import AppKit
import SwiftUI
import ImageIO

private struct CachedWatermarkBase: @unchecked Sendable {
    // Rendering finishes before the bitmap is read by another task.
    let canvas: SemiWatermarkRenderer.RenderedCanvas
}

struct WatermarkExportView: View {
    @ObservedObject var store: PhotoStore
    /// Nil reviews the filtered batch; a supplied array reviews only those photos.
    let photos: [PhotoEntry]?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presetStore: WatermarkPresetStore

    @ObservedObject private var fontDownloads = WatermarkFontDownloads.shared

    @State private var items: [WatermarkReviewItem] = []
    @State private var currentIndex = 0
    @State private var preview: NSImage?
    @State private var previewError: String?
    @State private var previewPreparation: Task<WatermarkCustomRenderer.PreparedSource, Error>?
    @State private var preparedPhotoID: String?
    @State private var previewBase: Task<CachedWatermarkBase, Error>?
    @State private var preparedBaseKey: String?
    @State private var outputDirectory: URL?
    @State private var editingConfiguration: WatermarkConfiguration?
    @State private var editingOverlayID: UUID?
    @State private var deleteConfirmation = false
    @State private var presetError: String?
    @State private var showOverlays = false
    @State private var isRendering = false
    @State private var nativePhotoSize: CGSize?
    @State private var batchStatus: String?

    init(store: PhotoStore, photos: [PhotoEntry]? = nil, presetDirectory: URL? = nil) {
        self.store = store
        self.photos = photos
        _presetStore = StateObject(wrappedValue: WatermarkPresetStore(directory: presetDirectory))
    }

    private var currentItem: WatermarkReviewItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    private var selectedCount: Int { items.filter(\.include).count }

    private var currentConfiguration: WatermarkConfiguration? {
        guard let currentItem, case .custom(let id) = currentItem.choice else { return nil }
        if let draft = currentItem.customDraft, draft.id == id { return draft }
        return presetStore.configurations.first { $0.id == id }
    }

    private var currentPreset: WatermarkPreset {
        guard let currentItem else { return .standard }
        switch currentItem.choice {
        case .border: return .standard
        case .builtIn(let preset): return preset
        case .custom: return currentConfiguration?.basePreset ?? .standard
        }
    }

    private var presetForEditor: WatermarkPreset {
        guard let currentItem,
              currentConfiguration?.matchOrientation == true ||
                (currentConfiguration == nil && currentItem.matchOrientation),
              let size = nativePhotoSize else { return currentPreset }
        return currentPreset.resolved(isPortrait: size.height > size.width, matchOrientation: true)
    }

    private var primaryKey: String {
        guard let currentItem else { return "empty" }
        return "\(currentItem.id)|\(currentItem.choice)|\(currentItem.matchOrientation)|\(currentConfiguration?.hashValue ?? 0)|\(currentItem.border.hashValue)|\(fontDownloads.revision)"
    }

    private var previewKey: String {
        guard let currentItem else { return "empty" }
        let overlayKey = currentItem.overlays.map { layer in
            let configurationHash = configuration(for: layer.choice)?.hashValue ?? 0
            return "\(layer.id)|\(layer.choice)|\(layer.matchOrientation)|\(configurationHash)"
        }.joined(separator: ";")
        return "\(primaryKey)|\(overlayKey)|\(fontDownloads.revision)"
    }

    private var choiceBinding: Binding<WatermarkExportChoice> {
        Binding(get: { currentItem?.choice ?? .builtIn(.standard) },
                set: {
                    guard items.indices.contains(currentIndex) else { return }
                    items[currentIndex].choice = $0
                    items[currentIndex].customDraft = nil
                    if $0 == .border || configuration(for: $0)?.border != nil { items[currentIndex].borderChoice = $0 }
                    else { items[currentIndex].watermarkChoice = $0 }
                })
    }

    private var orientationBinding: Binding<Bool> {
        Binding(get: { currentItem?.matchOrientation ?? true },
                set: { if items.indices.contains(currentIndex) { items[currentIndex].matchOrientation = $0 } })
    }

    private var includeBinding: Binding<Bool> {
        Binding(get: { currentItem?.include ?? false },
                set: { if items.indices.contains(currentIndex) { items[currentIndex].include = $0 } })
    }

    private var isBorderMode: Bool { currentItem?.choice == .border || currentConfiguration?.border != nil }

    private var outputSizeText: String? {
        guard isBorderMode, let size = nativePhotoSize else { return nil }
        let layout = borderBinding.wrappedValue.layout(photoSize: size)
        return "导出 \(Int(layout.canvas.width)) × \(Int(layout.canvas.height)) px · JPEG"
    }

    private var borderBinding: Binding<PhotoBorderConfiguration> {
        Binding(get: { currentConfiguration?.border ?? currentItem?.border ?? PhotoBorderConfiguration() },
                set: { value in
                    guard items.indices.contains(currentIndex) else { return }
                    items[currentIndex].border = value
                    if var configuration = currentConfiguration, configuration.border != nil {
                        configuration.border = value
                        items[currentIndex].customDraft = configuration
                    } else {
                        items[currentIndex].choice = .border
                    }
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    previewPanel.padding(20)
                    if items.count > 1 {
                        Divider()
                        photoList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                controls.frame(width: 316)
            }
            if !missingFonts.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("所用字体尚未就绪，请下载字体或在预设中改用系统字体。").font(.caption)
                        ForEach(missingFonts) { WatermarkFontDownloadStatus(option: $0) }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                }
                .frame(maxHeight: 130)
            }
            Divider()
            exportBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: photos?.count == 1 ? 980 : 1100, height: 740)
        .onAppear(perform: prepareReview)
        .task(id: previewKey) { await loadPreview() }
        .onChange(of: previewKey) { _, _ in batchStatus = nil }
        .onChange(of: selectedCount) { _, _ in batchStatus = nil }
        .onDisappear {
            previewPreparation?.cancel()
            previewBase?.cancel()
        }
        .sheet(item: $editingConfiguration) { configuration in
            WatermarkPresetEditorView(configuration: configuration, photo: currentItem?.photo,
                                      sourcePath: currentItem?.sourcePath) { updated in
                try presetStore.save(updated)
                if items.indices.contains(currentIndex) {
                    if let editingOverlayID,
                       let index = items[currentIndex].overlays.firstIndex(where: { $0.id == editingOverlayID }) {
                        items[currentIndex].overlays[index].choice = .custom(updated.id)
                    } else {
                        items[currentIndex].choice = .custom(updated.id)
                        items[currentIndex].customDraft = nil
                    }
                }
                editingOverlayID = nil
            }
        }
        .confirmationDialog("删除自定义预设？", isPresented: $deleteConfirmation) {
            Button("删除预设", role: .destructive) { deleteCurrentPreset() }
        }
        .alert("无法完成操作", isPresented: Binding(
            get: { presetError != nil }, set: { if !$0 { presetError = nil } }
        )) { Button("好") { presetError = nil } } message: { Text(presetError ?? "") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.artframe")
                .font(.system(size: 20)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("边框与水印").font(.system(size: 17, weight: .semibold))
                Text(items.count > 1 ? "调整当前照片，或将样式应用到已勾选照片" : "选择样式，预览后导出")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if items.count > 1 {
                Text("已勾选 \(selectedCount) / \(items.count) 张")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("关闭")
            .accessibilityLabel("关闭边框与水印")
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var photoList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("照片").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Button("将当前样式应用到已勾选的 \(selectedCount) 张") { applyCurrentStyleToAll() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(selectedCount == 0)
                    .help("同步边框、水印与叠加层，跳过未勾选照片")
                Spacer()
                Button("全选") { setAllIncluded(true) }
                Button("全不选") { setAllIncluded(false) }
            }
            .font(.caption).buttonStyle(.borderless)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(items.indices, id: \.self) { index in
                            reviewRow(index).id(index)
                        }
                    }
                    .padding(3)
                }
                .scrollIndicators(.hidden)
                .onChange(of: currentIndex) { _, index in proxy.scrollTo(index, anchor: .center) }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(height: 132)
    }

    private func reviewRow(_ index: Int) -> some View {
        let item = items[index]
        return VStack(spacing: 5) {
            Button { currentIndex = index } label: {
                AsyncThumbnailView(photoId: item.photo.id, imagePath: item.sourcePath, size: 70,
                                   crop: item.photo.cropRect)
                    .frame(width: 76, height: 60).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .opacity(item.include ? 1 : 0.4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(index == currentIndex ? Color.accentColor : .clear, lineWidth: 2)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(item.photo.displayName)
            Toggle(isOn: $items[index].include) {
                Text(item.photo.displayName).font(.system(size: 10)).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .help("勾选此照片以导出")
        }
        .frame(width: 82)
    }

    private var previewPanel: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentItem?.photo.displayName ?? "没有可处理的照片")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(isBorderMode ? "完整照片 · 居中留白" : "实时预览")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if items.count > 1 {
                    Button { currentIndex -= 1 } label: { Image(systemName: "chevron.left") }
                        .disabled(currentIndex == 0)
                    Text("\(currentIndex + 1) / \(items.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button { currentIndex += 1 } label: { Image(systemName: "chevron.right") }
                        .disabled(currentIndex >= items.count - 1)
                }
            }
            .buttonStyle(.borderless)
            ZStack {
                Color.primary.opacity(0.035)
                if let preview {
                    Image(nsImage: preview).resizable().scaledToFit().padding(24)
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
                } else if let previewError {
                    ContentUnavailableView("预览失败", systemImage: "photo.badge.exclamationmark",
                                           description: Text(previewError))
                } else if items.isEmpty {
                    ContentUnavailableView("没有可处理的照片", systemImage: "photo",
                                           description: Text("请选择 JPEG、HEIC、TIFF 或 RAW 照片。"))
                } else {
                    ProgressView("正在生成预览…")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                if isRendering, preview != nil {
                    ProgressView().controlSize(.small).padding(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(previewError ?? outputSizeText ?? "预览使用缩小图像，导出保留照片分辨率")
                    .font(.caption).foregroundStyle(previewError == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                Spacer()
                if currentItem != nil {
                    Toggle("导出此照片", isOn: includeBinding).toggleStyle(.checkbox).font(.caption)
                }
            }
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("样式", selection: Binding(
                    get: { isBorderMode },
                    set: setBorderMode
                )) {
                    Text("边框").tag(true)
                    Text("水印").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityLabel("边框或水印")

                if isBorderMode {
                    editorSection("边框", subtitle: "只增加留白，不裁切照片") {
                        PhotoBorderControls(configuration: borderBinding)
                    }
                } else {
                    editorSection("水印样式", subtitle: "横竖照片自动匹配，无需逐张选择") {
                        Picker("样式", selection: choiceBinding) { presetChoices }
                            .labelsHidden()
                        Toggle("自动匹配横竖方向", isOn: orientationBinding)
                            .font(.caption).disabled(currentConfiguration != nil)
                        Text(currentConfiguration == nil ? currentPreset.detail : "使用已保存的画布与组件")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !presetStore.configurations.isEmpty || currentConfiguration != nil {
                    editorSection("我的预设") {
                        Picker("已保存", selection: choiceBinding) {
                            if currentConfiguration == nil {
                                Text(isBorderMode ? "当前边框" : "当前水印").tag(currentItem?.choice ?? .border)
                            }
                            ForEach(presetStore.configurations) { configuration in
                                Text(configuration.name).tag(WatermarkExportChoice.custom(configuration.id))
                            }
                        }
                        .labelsHidden()
                        if currentConfiguration != nil {
                            HStack {
                                Button("编辑…") { editCurrentPreset(copy: false) }
                                Spacer()
                                Button("删除", role: .destructive) { deleteConfirmation = true }
                            }
                            .font(.caption).buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    Button("保存为预设…") { editCurrentPreset(copy: true) }
                    if !isBorderMode, currentConfiguration == nil {
                        Spacer()
                        Button("自定义…") { editCurrentPreset(copy: false) }
                    }
                }
                .font(.caption).buttonStyle(.borderless)

                Divider()
                DisclosureGroup("进阶 · 叠加文字与 Logo", isExpanded: $showOverlays) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("可在照片或留白上叠加水印；叠加层不改变画布。")
                            .font(.caption).foregroundStyle(.secondary)
                        if let currentItem {
                            ForEach(Array(currentItem.overlays.enumerated()), id: \.element.id) { index, overlay in
                                overlayControls(overlay, index: index, count: currentItem.overlays.count)
                            }
                        }
                        Menu {
                            Button("右下角拍摄参数") { addOverlay(.builtIn(.cornerParameters)) }
                            Button("文件夹与日期") { addOverlay(.builtIn(.folderAndDate)) }
                            Divider()
                            Section("更多水印") {
                                ForEach(WatermarkPreset.landscapePresets) { preset in
                                    Button(preset.rawValue) { addOverlay(.builtIn(preset)) }
                                }
                            }
                            if !presetStore.configurations.isEmpty {
                                Section("我的预设") {
                                    ForEach(presetStore.configurations) { configuration in
                                        Button(configuration.name) { addOverlay(.custom(configuration.id)) }
                                    }
                                }
                            }
                        } label: { Label("添加叠加层", systemImage: "plus") }
                        .disabled((currentItem?.overlays.count ?? 0) >= 8)
                    }
                    .padding(.top, 10)
                }
                .font(.subheadline.weight(.medium))
                .tint(.secondary)

            }
            .padding(20)
        }
        .disabled(currentItem == nil)
    }

    private func editorSection<Content: View>(_ title: String, subtitle: String? = nil,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exportBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(outputDirectory?.lastPathComponent ?? "选择导出位置")
                    .font(.subheadline).lineLimit(1)
                Text(outputDirectory?.path ?? "导出 JPEG，保留原文件")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(outputDirectory == nil ? "选择…" : "更改…") { chooseDirectory() }
                .font(.caption).buttonStyle(.borderless)
            Spacer(minLength: 12)
            if let batchStatus {
                Text(batchStatus).font(.caption).foregroundStyle(.secondary)
            }
            Button(outputDirectory == nil ? "选择目录并导出 \(selectedCount) 张…" : "导出 \(selectedCount) 张") {
                if outputDirectory == nil { chooseDirectory() }
                if outputDirectory != nil { exportCheckedPhotos() }
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(selectedCount == 0 || store.isExporting || items.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func editCurrentPreset(copy: Bool) {
        editingOverlayID = nil
        if isBorderMode {
            editingConfiguration = currentConfiguration ?? WatermarkConfiguration(
                name: "居中边框", basePreset: .standard, components: [], border: borderBinding.wrappedValue)
        } else {
            editingConfiguration = currentConfiguration?.adapted(to: presetForEditor)
                ?? WatermarkConfiguration.draft(from: presetForEditor)
            if currentConfiguration == nil { editingConfiguration?.matchOrientation = currentItem?.matchOrientation }
        }
        if copy {
            editingConfiguration?.id = UUID()
            editingConfiguration?.name += " · 副本"
        }
    }

    private func setBorderMode(_ enabled: Bool) {
        guard items.indices.contains(currentIndex), enabled != isBorderMode else { return }
        if isBorderMode {
            items[currentIndex].borderChoice = items[currentIndex].choice
        } else {
            items[currentIndex].watermarkChoice = items[currentIndex].choice
        }
        items[currentIndex].choice = enabled ? items[currentIndex].borderChoice : items[currentIndex].watermarkChoice
    }

    @ViewBuilder private var presetChoices: some View {
        Section("横拍模板") {
            ForEach(WatermarkPreset.landscapePresets) { preset in
                Text(preset.rawValue).tag(WatermarkExportChoice.builtIn(preset))
            }
        }
        Section("竖拍模板") {
            ForEach(WatermarkPreset.portraitPresets) { preset in
                Text(preset.rawValue).tag(WatermarkExportChoice.builtIn(preset))
            }
        }
        if !presetStore.configurations.isEmpty {
            Section("自定义预设") {
                ForEach(presetStore.configurations) { configuration in
                    Text(configuration.name).tag(WatermarkExportChoice.custom(configuration.id))
                }
            }
        }
    }

    private func overlayControls(_ overlay: WatermarkOverlayChoice, index: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("第 \(index + 2) 层").font(.caption.weight(.semibold))
                Spacer()
                Button { moveOverlay(overlay.id, by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0)
                    .help("上移叠加层")
                Button { moveOverlay(overlay.id, by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == count - 1)
                    .help("下移叠加层")
                Button(role: .destructive) { removeOverlay(overlay.id) } label: {
                    Image(systemName: "trash")
                }
                .help("移除叠加层")
            }
            .buttonStyle(.borderless)
            Picker("预设", selection: overlayChoiceBinding(overlay.id)) { presetChoices }
            Toggle("按照片方向匹配", isOn: overlayOrientationBinding(overlay.id))
                .disabled(configuration(for: overlay.choice) != nil)
            Button("编辑此预设…") { editOverlay(overlay) }
                .font(.caption)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func configuration(for choice: WatermarkExportChoice) -> WatermarkConfiguration? {
        guard case .custom(let id) = choice else { return nil }
        return presetStore.configurations.first { $0.id == id }
    }

    private func overlayChoiceBinding(_ id: UUID) -> Binding<WatermarkExportChoice> {
        Binding(get: {
            currentItem?.overlays.first(where: { $0.id == id })?.choice ?? .builtIn(.standard)
        }, set: { choice in
            guard items.indices.contains(currentIndex),
                  let index = items[currentIndex].overlays.firstIndex(where: { $0.id == id }) else { return }
            items[currentIndex].overlays[index].choice = choice
        })
    }

    private func overlayOrientationBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: {
            currentItem?.overlays.first(where: { $0.id == id })?.matchOrientation ?? true
        }, set: { enabled in
            guard items.indices.contains(currentIndex),
                  let index = items[currentIndex].overlays.firstIndex(where: { $0.id == id }) else { return }
            items[currentIndex].overlays[index].matchOrientation = enabled
        })
    }

    private func addOverlay(_ choice: WatermarkExportChoice) {
        guard items.indices.contains(currentIndex), items[currentIndex].overlays.count < 8 else { return }
        items[currentIndex].overlays.append(WatermarkOverlayChoice(choice: choice))
    }

    private func removeOverlay(_ id: UUID) {
        guard items.indices.contains(currentIndex) else { return }
        items[currentIndex].overlays.removeAll { $0.id == id }
    }

    private func moveOverlay(_ id: UUID, by offset: Int) {
        guard items.indices.contains(currentIndex),
              let index = items[currentIndex].overlays.firstIndex(where: { $0.id == id }),
              items[currentIndex].overlays.indices.contains(index + offset) else { return }
        items[currentIndex].overlays.swapAt(index, index + offset)
    }

    private func editOverlay(_ overlay: WatermarkOverlayChoice) {
        let saved = configuration(for: overlay.choice)
        let preset: WatermarkPreset
        switch overlay.choice {
        case .border: return
        case .builtIn(let selected): preset = selected
        case .custom: preset = saved?.basePreset ?? .standard
        }
        let matchOrientation = saved?.matchOrientation ?? overlay.matchOrientation
        let selected: WatermarkPreset
        if matchOrientation, let size = nativePhotoSize {
            selected = preset.resolved(isPortrait: size.height > size.width, matchOrientation: true)
        } else {
            selected = preset
        }
        editingOverlayID = overlay.id
        editingConfiguration = saved?.adapted(to: selected) ?? WatermarkConfiguration.draft(from: selected)
        editingConfiguration?.matchOrientation = matchOrientation
    }

    private func prepareReview() {
        guard items.isEmpty else { return }
        let candidates = photos ?? store.filteredPhotos
        let preferRaw = store.filterOptions.fileTypeFilter == .nefOnly
        items = candidates.compactMap { photo in
            guard let sourcePath = photo.watermarkSourcePath(preferRaw: preferRaw) else { return nil }
            return WatermarkReviewItem(photo: photo, sourcePath: sourcePath)
        }
        if let selectedID = store.selectedPhoto?.id,
           let index = items.firstIndex(where: { $0.id == selectedID }) {
            currentIndex = index
        }
    }

    private func setAllIncluded(_ included: Bool) {
        for index in items.indices { items[index].include = included }
    }

    private func applyCurrentStyleToAll() {
        guard let currentItem else { return }
        WatermarkReviewPlan.applyStyle(from: currentItem, to: &items)
        batchStatus = "已同步到 \(selectedCount) 张照片"
    }

    private func deleteCurrentPreset() {
        guard let currentItem, case .custom(let id) = currentItem.choice else { return }
        let fallback: WatermarkExportChoice = isBorderMode ? .border : .builtIn(.standard)
        do {
            try presetStore.delete(id)
            for index in items.indices {
                if items[index].choice == .custom(id) {
                    items[index].choice = fallback
                }
                if items[index].borderChoice == .custom(id) { items[index].borderChoice = .border }
                if items[index].watermarkChoice == .custom(id) { items[index].watermarkChoice = .builtIn(.standard) }
                if items[index].customDraft?.id == id { items[index].customDraft = nil }
                items[index].overlays.removeAll { $0.choice == .custom(id) }
            }
        } catch { presetError = error.localizedDescription }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择照片输出目录"
        panel.prompt = "使用此目录"
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { outputDirectory = panel.url }
    }

    private var missingFonts: [WatermarkFont] {
        let configurations = items.filter { $0.include || $0.id == currentItem?.id }.flatMap { item -> [WatermarkConfiguration] in
            guard let request = try? WatermarkReviewPlan.request(for: item, configurations: presetStore.configurations) else { return [] }
            return ([request.style] + request.overlays.map(\.style)).compactMap {
                if case .custom(let configuration) = $0 { return configuration }
                return nil
            }
        }
        return WatermarkFont.missing(in: Array(Set(configurations)))
    }

    private func exportCheckedPhotos() {
        guard let outputDirectory else { return }
        do {
            let requests = try WatermarkReviewPlan.requests(from: items,
                                                            configurations: presetStore.configurations)
            let configurations = requests.flatMap { request in
                ([request.style] + request.overlays.map(\.style)).compactMap { style -> WatermarkConfiguration? in
                    if case .custom(let configuration) = style { return configuration }
                    return nil
                }
            }
            try WatermarkFont.requireAvailable(in: Array(Set(configurations)))
            store.exportWatermarkedPhotos(requests, to: outputDirectory)
            dismiss()
        } catch {
            presetError = error.localizedDescription
        }
    }

    private func loadPreview() async {
        let key = previewKey
        isRendering = true
        defer { if previewKey == key { isRendering = false } }
        previewError = nil
        guard let currentItem else { return }
        if preparedPhotoID != currentItem.id {
            previewPreparation?.cancel()
            previewBase?.cancel()
            preparedPhotoID = currentItem.id
            previewPreparation = nil
            previewBase = nil
            preparedBaseKey = nil
            preview = nil
            nativePhotoSize = nil
        }
        do {
            try await Task.sleep(for: .milliseconds(90))
            let request = try WatermarkReviewPlan.request(for: currentItem,
                                                          configurations: presetStore.configurations)
            if previewPreparation == nil {
                previewPreparation = Task.detached(priority: .userInitiated) {
                    try WatermarkCustomRenderer.prepare(photo: currentItem.photo,
                                                        sourcePath: currentItem.sourcePath,
                                                        maxPixelSize: 1200)
                }
            }
            let prepared = try await previewPreparation!.value
            guard !Task.isCancelled else { return }
            nativePhotoSize = prepared.nativePixelSize
            let baseKey = primaryKey
            if preparedBaseKey != baseKey {
                previewBase?.cancel()
                previewBase = nil
                preparedBaseKey = baseKey
            }
            if previewBase == nil {
                previewBase = Task.detached(priority: .userInitiated) {
                    let canvas = try WatermarkService.renderBase(prepared: prepared, style: request.style,
                                                                  matchOrientation: request.matchOrientation)
                    return CachedWatermarkBase(canvas: canvas)
                }
            }
            let base = try await previewBase!.value
            guard !Task.isCancelled else { return }
            let renderTask = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try WatermarkService.previewData(prepared: prepared, base: base.canvas,
                                                         overlays: request.overlays)
            }
            let data = try await withTaskCancellationHandler {
                try await renderTask.value
            } onCancel: {
                renderTask.cancel()
            }
            guard !Task.isCancelled else { return }
            preview = NSImage(data: data)
        } catch {
            guard !Task.isCancelled else { return }
            preview = nil
            previewError = error.localizedDescription
        }
    }
}
