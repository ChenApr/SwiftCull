import AppKit
import SwiftUI

struct WatermarkExportView: View {
    @ObservedObject var store: PhotoStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presetStore = WatermarkPresetStore()

    private enum Choice: Hashable {
        case builtIn(WatermarkPreset)
        case custom(UUID)
    }

    @State private var choice: Choice = .builtIn(.standard)
    @State private var matchPhotoOrientation = true
    @State private var preview: NSImage?
    @State private var previewError: String?
    @State private var outputDirectory: URL?
    @State private var editingConfiguration: WatermarkConfiguration?
    @State private var deleteConfirmation = false
    @State private var presetError: String?

    private var configuration: WatermarkConfiguration? {
        guard case .custom(let id) = choice else { return nil }
        return presetStore.configurations.first { $0.id == id }
    }

    private var preset: WatermarkPreset {
        switch choice {
        case .builtIn(let value): return value
        case .custom: return configuration?.basePreset ?? .standard
        }
    }

    private var previewKey: String {
        "\(choice)|\(matchPhotoOrientation)|\(configuration?.hashValue ?? 0)"
    }

    private var previewPhoto: PhotoEntry? {
        store.selectedPhotoEntries.first(where: { $0.hasJpg || $0.hasNef })
            ?? store.filteredPhotos.first(where: { $0.hasJpg || $0.hasNef })
    }

    private var imageCount: Int {
        store.filteredPhotos.filter { $0.hasJpg || $0.hasNef }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("水印导出").font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }
            }

            HStack(alignment: .top, spacing: 18) {
                Group {
                    if let preview {
                        Image(nsImage: preview)
                            .resizable()
                            .scaledToFit()
                    } else if let previewError {
                        ContentUnavailableView("预览失败", systemImage: "photo.badge.exclamationmark",
                                               description: Text(previewError))
                    } else {
                        ProgressView("正在生成预览…")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 320)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 14) {
                    Picker("水印预设", selection: $choice) {
                        Section("横拍模板") {
                            ForEach(WatermarkPreset.landscapePresets) { item in
                                Text(item.rawValue).tag(Choice.builtIn(item))
                            }
                        }
                        Section("竖拍模板") {
                            ForEach(WatermarkPreset.portraitPresets) { item in
                                Text(item.rawValue).tag(Choice.builtIn(item))
                            }
                        }
                        if !presetStore.configurations.isEmpty {
                            Section("自定义预设") {
                                ForEach(presetStore.configurations) { item in
                                    Text(item.name).tag(Choice.custom(item.id))
                                }
                            }
                        }
                    }
                    .frame(width: 250)

                    Toggle("按每张照片方向自动匹配", isOn: $matchPhotoOrientation)
                        .disabled(configuration != nil)
                        .help("混合横拍和竖拍时，自动选用相同风格的对应模板；独立的「尼康竖拍」始终固定")

                    Text(configuration == nil ? preset.detail : "自定义画布和组件，适用于横拍及竖拍")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("新建预设…") {
                            editingConfiguration = WatermarkConfiguration.draft(from: preset)
                        }
                        Button("编辑预设…") {
                            editingConfiguration = configuration ?? WatermarkConfiguration.draft(from: preset)
                        }
                    }
                    if configuration != nil {
                        Button("删除此预设", role: .destructive) { deleteConfirmation = true }
                    }

                    Divider()

                    Text("输出目录").font(.headline)
                    Text(outputDirectory?.path ?? "尚未选择")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)

                    Button("选择目录…") { chooseDirectory() }

                    Spacer()

                    Text("将输出 \(imageCount) 张 JPEG；RAW 源文件会生成 JPEG，视频不会加水印。原文件保持不变；同名输出会自动添加序号。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("导出水印照片") {
                        guard let outputDirectory else { return }
                        store.exportWatermarkedPhotos(preset: preset,
                                                      configuration: configuration,
                                                      matchOrientation: matchPhotoOrientation,
                                                      to: outputDirectory)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(outputDirectory == nil || imageCount == 0 || store.isExporting)
                }
                .frame(width: 250)
            }
        }
        .padding(20)
        .frame(width: 900, height: 610)
        .task(id: previewKey) { await loadPreview() }
        .sheet(item: $editingConfiguration) { current in
            WatermarkPresetEditorView(configuration: current, photo: previewPhoto,
                                      sourcePath: previewPhoto?.watermarkSourcePath(
                                        preferRaw: store.filterOptions.fileTypeFilter == .nefOnly
                                      )) { updated in
                try presetStore.save(updated)
                choice = .custom(updated.id)
            }
        }
        .confirmationDialog("删除自定义预设？", isPresented: $deleteConfirmation) {
            Button("删除预设", role: .destructive) {
                guard case .custom(let id) = choice else { return }
                do {
                    try presetStore.delete(id)
                    choice = .builtIn(.standard)
                } catch { presetError = error.localizedDescription }
            }
        }
        .alert("预设操作失败", isPresented: Binding(
            get: { presetError != nil }, set: { if !$0 { presetError = nil } }
        )) { Button("好") { presetError = nil } } message: { Text(presetError ?? "") }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择水印照片输出目录"
        panel.prompt = "使用此目录"
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            outputDirectory = panel.url
        }
    }

    private func loadPreview() async {
        preview = nil
        previewError = nil
        guard let photo = previewPhoto else {
            previewError = "筛选结果中没有可处理的照片"
            return
        }
        let selectedPreset = preset
        let selectedConfiguration = configuration
        let automatic = matchPhotoOrientation
        let sourcePath = photo.watermarkSourcePath(preferRaw: store.filterOptions.fileTypeFilter == .nefOnly)
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                if let selectedConfiguration {
                    return try WatermarkService.previewData(photo: photo,
                                                            configuration: selectedConfiguration,
                                                            sourcePath: sourcePath)
                }
                return try WatermarkService.previewData(photo: photo, preset: selectedPreset,
                                                        sourcePath: sourcePath,
                                                        matchOrientation: automatic)
            }.value
            guard !Task.isCancelled else { return }
            preview = NSImage(data: data)
        } catch {
            guard !Task.isCancelled else { return }
            previewError = error.localizedDescription
        }
    }
}
