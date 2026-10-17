import AppKit
import SwiftUI
import ImageIO

struct WatermarkExportView: View {
    @ObservedObject var store: PhotoStore
    /// Nil reviews the filtered batch; a supplied array reviews only those photos.
    let photos: [PhotoEntry]?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presetStore = WatermarkPresetStore()

    @State private var items: [WatermarkReviewItem] = []
    @State private var currentIndex = 0
    @State private var preview: NSImage?
    @State private var previewError: String?
    @State private var outputDirectory: URL?
    @State private var editingConfiguration: WatermarkConfiguration?
    @State private var deleteConfirmation = false
    @State private var presetError: String?

    init(store: PhotoStore, photos: [PhotoEntry]? = nil) {
        self.store = store
        self.photos = photos
    }

    private var currentItem: WatermarkReviewItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    private var selectedCount: Int { items.filter(\.include).count }

    private var currentConfiguration: WatermarkConfiguration? {
        guard let currentItem, case .custom(let id) = currentItem.choice else { return nil }
        return presetStore.configurations.first { $0.id == id }
    }

    private var currentPreset: WatermarkPreset {
        guard let currentItem else { return .standard }
        switch currentItem.choice {
        case .builtIn(let preset): return preset
        case .custom: return currentConfiguration?.basePreset ?? .standard
        }
    }

    private var presetForEditor: WatermarkPreset {
        guard let currentItem,
              currentConfiguration?.matchOrientation == true ||
                (currentConfiguration == nil && currentItem.matchOrientation),
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: currentItem.sourcePath) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 128
              ] as CFDictionary) else { return currentPreset }
        return currentPreset.resolved(isPortrait: image.height > image.width, matchOrientation: true)
    }

    private var previewKey: String {
        guard let currentItem else { return "empty" }
        return "\(currentItem.id)|\(currentItem.choice)|\(currentItem.matchOrientation)|\(currentConfiguration?.hashValue ?? 0)"
    }

    private var choiceBinding: Binding<WatermarkExportChoice> {
        Binding(get: { currentItem?.choice ?? .builtIn(.standard) },
                set: { if items.indices.contains(currentIndex) { items[currentIndex].choice = $0 } })
    }

    private var orientationBinding: Binding<Bool> {
        Binding(get: { currentItem?.matchOrientation ?? true },
                set: { if items.indices.contains(currentIndex) { items[currentIndex].matchOrientation = $0 } })
    }

    private var includeBinding: Binding<Bool> {
        Binding(get: { currentItem?.include ?? false },
                set: { if items.indices.contains(currentIndex) { items[currentIndex].include = $0 } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(photos?.count == 1 ? "单张水印导出预览" : "批量水印导出预览")
                        .font(.title2.bold())
                    Text("逐张检查水印，选择样式并决定是否导出")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("已勾选 \(selectedCount) / \(items.count) 张")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("关闭") { dismiss() }
            }

            HStack(alignment: .top, spacing: 14) {
                if items.count > 1 { photoList.frame(width: 228) }
                previewPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
                    .frame(width: 270)
            }
        }
        .padding(18)
        .frame(width: photos?.count == 1 ? 880 : 1120, height: 690)
        .onAppear(perform: prepareReview)
        .task(id: previewKey) { await loadPreview() }
        .sheet(item: $editingConfiguration) { configuration in
            WatermarkPresetEditorView(configuration: configuration, photo: currentItem?.photo,
                                      sourcePath: currentItem?.sourcePath) { updated in
                try presetStore.save(updated)
                if items.indices.contains(currentIndex) {
                    items[currentIndex].choice = .custom(updated.id)
                }
            }
        }
        .confirmationDialog("删除自定义预设？", isPresented: $deleteConfirmation) {
            Button("删除预设", role: .destructive) { deleteCurrentPreset() }
        }
        .alert("预设操作失败", isPresented: Binding(
            get: { presetError != nil }, set: { if !$0 { presetError = nil } }
        )) { Button("好") { presetError = nil } } message: { Text(presetError ?? "") }
    }

    private var photoList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("待处理照片").font(.headline)
                Spacer()
                Button("全选") { setAllIncluded(true) }.font(.caption)
                Button("全不选") { setAllIncluded(false) }.font(.caption)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(items.indices, id: \.self) { index in
                            reviewRow(index)
                                .id(index)
                        }
                    }
                }
                .onChange(of: currentIndex) { _, index in
                    withAnimation { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }
    }

    private func reviewRow(_ index: Int) -> some View {
        let item = items[index]
        return HStack(spacing: 7) {
            Toggle("导出 \(item.photo.displayName)", isOn: $items[index].include)
                .labelsHidden()
            Button {
                currentIndex = index
            } label: {
                HStack(spacing: 7) {
                    AsyncThumbnailView(photoId: item.photo.id, imagePath: item.sourcePath, size: 46)
                        .frame(width: 46, height: 46)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.photo.displayName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(label(for: item.choice))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(5)
        .background(index == currentIndex ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7))
    }

    private var previewPanel: some View {
        VStack(spacing: 9) {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let preview {
                    Image(nsImage: preview).resizable().scaledToFit().padding(12)
                } else if let previewError {
                    ContentUnavailableView("预览失败", systemImage: "photo.badge.exclamationmark",
                                           description: Text(previewError))
                } else {
                    ProgressView("正在生成预览…")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let currentItem {
                HStack(spacing: 8) {
                    Button { currentIndex -= 1 } label: { Image(systemName: "chevron.left") }
                        .disabled(currentIndex == 0)
                    Text("\(currentIndex + 1) / \(items.count) · \(currentItem.photo.displayName)")
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                    Button { currentIndex += 1 } label: { Image(systemName: "chevron.right") }
                        .disabled(currentIndex == items.count - 1)
                    Spacer()
                    Text(currentItem.include ? "将导出" : "已跳过")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(currentItem.include ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 11) {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    Text("当前照片").font(.headline)
                    Toggle("导出这张照片", isOn: includeBinding)

                    Picker("水印预设", selection: choiceBinding) {
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

                    Toggle("按照片方向匹配", isOn: orientationBinding)
                        .disabled(currentConfiguration != nil)
                    Text(currentConfiguration == nil ? currentPreset.detail : "自定义画布和组件")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("将此预设应用到全部照片") { applyCurrentStyleToAll() }
                        .disabled(items.count < 2)

                    HStack {
                        Button("新建预设…") {
                            editingConfiguration = WatermarkConfiguration.draft(from: presetForEditor)
                            editingConfiguration?.matchOrientation = currentConfiguration == nil
                                ? currentItem?.matchOrientation : currentConfiguration?.matchOrientation
                        }
                        Button("编辑预设…") {
                            editingConfiguration = currentConfiguration?.adapted(to: presetForEditor)
                                ?? WatermarkConfiguration.draft(from: presetForEditor)
                            if currentConfiguration == nil {
                                editingConfiguration?.matchOrientation = currentItem?.matchOrientation
                            }
                        }
                    }
                    if currentConfiguration != nil {
                        Button("删除此预设", role: .destructive) { deleteConfirmation = true }
                    }
                }
            }

            Divider()
            Text("输出目录").font(.headline)
            Text(outputDirectory?.path ?? "尚未选择")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            Button("选择目录…") { chooseDirectory() }
            Text("仅导出已勾选照片为 JPEG；RAW 源文件会生成 JPEG。原文件保持不变。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("导出 \(selectedCount) 张水印照片") { exportCheckedPhotos() }
                .buttonStyle(.borderedProminent)
                .disabled(outputDirectory == nil || selectedCount == 0 || store.isExporting)
        }
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

    private func label(for choice: WatermarkExportChoice) -> String {
        switch choice {
        case .builtIn(let preset): return preset.rawValue
        case .custom(let id):
            return presetStore.configurations.first(where: { $0.id == id })?.name ?? "自定义预设"
        }
    }

    private func setAllIncluded(_ included: Bool) {
        for index in items.indices { items[index].include = included }
    }

    private func applyCurrentStyleToAll() {
        guard let currentItem else { return }
        for index in items.indices {
            items[index].choice = currentItem.choice
            items[index].matchOrientation = currentItem.matchOrientation
        }
    }

    private func deleteCurrentPreset() {
        guard let currentItem, case .custom(let id) = currentItem.choice else { return }
        do {
            try presetStore.delete(id)
            for index in items.indices where items[index].choice == .custom(id) {
                items[index].choice = .builtIn(.standard)
            }
        } catch { presetError = error.localizedDescription }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择水印照片输出目录"
        panel.prompt = "使用此目录"
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { outputDirectory = panel.url }
    }

    private func exportCheckedPhotos() {
        guard let outputDirectory else { return }
        do {
            let requests = try WatermarkReviewPlan.requests(from: items,
                                                            configurations: presetStore.configurations)
            store.exportWatermarkedPhotos(requests, to: outputDirectory)
            dismiss()
        } catch {
            presetError = error.localizedDescription
        }
    }

    private func loadPreview() async {
        preview = nil
        previewError = nil
        guard let currentItem else { return }
        let configuration = currentConfiguration
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                if let configuration {
                    return try WatermarkService.previewData(photo: currentItem.photo,
                                                            configuration: configuration,
                                                            sourcePath: currentItem.sourcePath)
                }
                let preset: WatermarkPreset
                switch currentItem.choice {
                case .builtIn(let selected): preset = selected
                case .custom: throw WatermarkError.unreadableImage
                }
                return try WatermarkService.previewData(photo: currentItem.photo, preset: preset,
                                                        sourcePath: currentItem.sourcePath,
                                                        matchOrientation: currentItem.matchOrientation)
            }.value
            guard !Task.isCancelled else { return }
            preview = NSImage(data: data)
        } catch {
            guard !Task.isCancelled else { return }
            previewError = error.localizedDescription
        }
    }
}
