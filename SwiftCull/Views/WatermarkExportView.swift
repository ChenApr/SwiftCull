import AppKit
import SwiftUI

struct WatermarkExportView: View {
    @ObservedObject var store: PhotoStore
    @Environment(\.dismiss) private var dismiss

    @State private var preset: WatermarkPreset = .standard
    @State private var matchPhotoOrientation = true
    @State private var preview: NSImage?
    @State private var previewError: String?
    @State private var outputDirectory: URL?

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
                    Picker("水印预设", selection: $preset) {
                        Section("横拍模板") {
                            ForEach(WatermarkPreset.landscapePresets) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        Section("竖拍模板") {
                            ForEach(WatermarkPreset.portraitPresets) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                    }
                    .frame(width: 250)

                    Toggle("按每张照片方向自动匹配", isOn: $matchPhotoOrientation)
                        .help("混合横拍和竖拍时，自动选用相同风格的对应模板；独立的「尼康竖拍」始终固定")

                    Text(preset.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
        .frame(width: 850, height: 520)
        .task(id: "\(preset.rawValue)|\(matchPhotoOrientation)") { await loadPreview() }
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
        let automatic = matchPhotoOrientation
        let sourcePath = photo.watermarkSourcePath(preferRaw: store.filterOptions.fileTypeFilter == .nefOnly)
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try WatermarkService.previewData(photo: photo, preset: selectedPreset,
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
