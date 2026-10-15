import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

private struct RenderedWatermarkPreview: @unchecked Sendable {
    // The bitmap is only read after its detached rendering task has completed.
    let bitmap: NSBitmapImageRep
}

struct WatermarkPresetEditorView: View {
    let photo: PhotoEntry?
    let sourcePath: String?
    let onSave: (WatermarkConfiguration) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WatermarkConfiguration
    @State private var preview: NSImage?
    @State private var previewError: String?
    @State private var previewPreparation: Task<WatermarkCustomRenderer.PreparedSource, Error>?
    @State private var saveError: String?

    init(configuration: WatermarkConfiguration, photo: PhotoEntry?, sourcePath: String?,
         onSave: @escaping (WatermarkConfiguration) throws -> Void) {
        self.photo = photo
        self.sourcePath = sourcePath
        self.onSave = onSave
        _draft = State(initialValue: configuration)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑水印预设").font(.title2.bold())
                Spacer()
                Button("取消") { dismiss() }
                Button("保存预设") { save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(18)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                previewPane
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        nameSection
                        canvasSection
                        componentsSection
                    }
                    .padding(18)
                }
                .frame(width: 385)
            }
        }
        .frame(width: 1050, height: 720)
        .task(id: draft) { await loadPreview() }
        .alert("无法保存预设", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) { Button("好") { saveError = nil } } message: { Text(saveError ?? "") }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("实时预览").font(.headline)
            Group {
                if let preview {
                    Image(nsImage: preview).resizable().scaledToFit()
                } else if let previewError {
                    ContentUnavailableView("无法预览", systemImage: "photo.badge.exclamationmark",
                                           description: Text(previewError))
                } else {
                    ProgressView("生成预览…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var nameSection: some View {
        GroupBox("预设") {
            VStack(alignment: .leading) {
                TextField("名称", text: $draft.name)
                Text("基于：\(draft.basePreset.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 5)
        }
    }

    private var canvasSection: some View {
        GroupBox("画布与照片") {
            VStack(alignment: .leading, spacing: 12) {
                if draft.templateLayout == true &&
                    (draft.basePreset.layout == .cornerParameters || draft.basePreset.layout == .folderAndDate) {
                    Text("此模板直接在照片上叠加组件，画布尺寸与原图一致。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("背景", selection: $draft.background) {
                        ForEach(WatermarkConfiguration.Background.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    ColorPicker("背景颜色", selection: Binding(
                        get: { Color(nsColor: NSColor.watermarkHex(draft.backgroundHex) ?? .white) },
                        set: { draft.backgroundHex = NSColor($0).watermarkHexString }
                    ))
                    valueSlider(draft.templateLayout == true ? "额外画布留白" : "画布留白",
                                value: $draft.paddingPercent, range: 0...20)
                    valueSlider(draft.templateLayout == true ? "增加底栏高度" : "底栏高度",
                                value: $draft.footerPercent, range: 0...35)
                    valueSlider(draft.templateLayout == true ? "增加照片圆角" : "照片圆角",
                                value: $draft.cornerRadiusPercent, range: 0...10)
                    Toggle("照片阴影", isOn: $draft.shadow)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 5)
        }
    }

    private var componentsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ForEach($draft.components) { $component in
                    componentCard($component)
                }
                Menu {
                    ForEach(WatermarkComponent.Kind.allCases) { kind in
                        Button(kind.rawValue) {
                            draft.components.append(WatermarkComponent(
                                kind: kind,
                                position: draft.templateLayout == true || draft.footerPercent > 0
                                    ? .footerLeft : .bottomLeft,
                                text: kind == .customText ? "自定义文字" : "",
                                colorHex: draft.templateLayout == true || draft.footerPercent > 0
                                    ? "#202020" : "#FFFFFF"
                            ))
                        }
                    }
                } label: {
                    Label("添加组件", systemImage: "plus")
                }
                .disabled(draft.components.count >= 32)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 5)
        } label: {
            Text("水印组件")
        }
    }

    private func componentCard(_ component: Binding<WatermarkComponent>) -> some View {
        let id = component.wrappedValue.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(component.wrappedValue.kind.rawValue).font(.subheadline.bold())
                Spacer()
                Button { move(id, by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(!canMove(id, by: -1))
                Button { move(id, by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(!canMove(id, by: 1))
                Button(role: .destructive) { draft.components.removeAll { $0.id == id } }
                    label: { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless)
            Picker("内容", selection: component.kind) {
                ForEach(WatermarkComponent.Kind.allCases) { kind in Text(kind.rawValue).tag(kind) }
            }
            .onChange(of: component.wrappedValue.kind) { _, newKind in
                if newKind != .logo, [.footerLogo, .centerLogo].contains(component.wrappedValue.slot) {
                    component.wrappedValue.slot = nil
                }
            }
            if component.wrappedValue.kind == .customText {
                TextField("显示文字", text: component.text)
            }
            if component.wrappedValue.kind == .logo {
                HStack(spacing: 10) {
                    if let data = component.wrappedValue.imageData, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 82, height: 42)
                    } else {
                        Text("自动匹配相机品牌 Logo").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("选择图片…") { chooseLogo(for: id) }
                    if component.wrappedValue.imageData != nil {
                        Button("恢复自动") { component.wrappedValue.imageData = nil }
                    }
                }
            }
            Picker("位置", selection: component.position) {
                ForEach(WatermarkComponent.Position.allCases) { position in
                    Text(position.rawValue).tag(position)
                }
            }
            HStack {
                Text(component.wrappedValue.kind == .logo ? "大小" : "字号")
                Slider(value: component.fontPercent,
                       in: component.wrappedValue.kind == .logo ? 0.5...15 : 0.5...8, step: 0.1)
                Text(String(format: "%.1f%%", component.wrappedValue.fontPercent))
                    .monospacedDigit().frame(width: 48)
            }
            if component.wrappedValue.kind != .logo {
                Picker("字体", selection: component.fontID) {
                    Text("原样（系统字体）").tag(String?.none)
                    Section("常用字体") {
                        ForEach(Array(WatermarkFont.bundled.prefix(5))) { option in
                            Text(option.name).tag(Optional(option.id))
                        }
                    }
                    Section("艺术字体") {
                        ForEach(Array(WatermarkFont.bundled.dropFirst(5))) { option in
                            Text(option.name).tag(Optional(option.id))
                        }
                    }
                    Section("本机字体") {
                        ForEach(WatermarkFont.local) { option in
                            Text(option.name + (WatermarkFont.isAvailable(option) ? "" : "（未安装）"))
                                .tag(Optional(option.id))
                                .disabled(!WatermarkFont.isAvailable(option))
                        }
                    }
                }
                if let id = component.wrappedValue.fontID,
                   let option = (WatermarkFont.bundled + WatermarkFont.local).first(where: { $0.id == id }) {
                    Text("SwiftCull  光影留痕")
                        .font(.custom(option.family, size: 18))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    ColorPicker("文字颜色", selection: Binding(
                        get: { Color(nsColor: NSColor.watermarkHex(component.wrappedValue.colorHex) ?? .black) },
                        set: { component.wrappedValue.colorHex = NSColor($0).watermarkHexString }
                    ))
                    Toggle("加粗", isOn: component.bold)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: 0.5)
            Text(String(format: "%.1f%%", value.wrappedValue))
                .monospacedDigit().frame(width: 48)
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = draft.components.firstIndex(where: { $0.id == id }),
              let target = adjacentComponentIndex(to: index, by: offset) else { return }
        draft.components.swapAt(index, target)
    }

    private func canMove(_ id: UUID, by offset: Int) -> Bool {
        guard let index = draft.components.firstIndex(where: { $0.id == id }) else { return false }
        return adjacentComponentIndex(to: index, by: offset) != nil
    }

    private func adjacentComponentIndex(to index: Int, by offset: Int) -> Int? {
        let position = draft.components[index].position
        var candidate = index + offset
        while draft.components.indices.contains(candidate) {
            if draft.components[candidate].position == position { return candidate }
            candidate += offset
        }
        return nil
    }

    private func save() {
        do {
            try onSave(draft)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func chooseLogo(for id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024
              ] as CFDictionary),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              let index = draft.components.firstIndex(where: { $0.id == id }) else {
            saveError = "无法读取所选 Logo 图片"
            return
        }
        draft.components[index].imageData = data
    }

    private func loadPreview() async {
        previewError = nil
        try? await Task.sleep(nanoseconds: 35_000_000)
        guard !Task.isCancelled else { return }
        guard let photo else {
            previewError = "筛选结果中没有可处理的照片"
            return
        }
        if previewPreparation == nil {
            previewPreparation = Task.detached(priority: .userInitiated) {
                try WatermarkCustomRenderer.prepare(photo: photo, sourcePath: sourcePath,
                                                    maxPixelSize: 1200)
            }
        }
        let current = draft
        do {
            let prepared = try await previewPreparation!.value
            guard !Task.isCancelled else { return }
            let renderTask = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try RenderedWatermarkPreview(bitmap: WatermarkCustomRenderer.render(
                    prepared: prepared, configuration: current))
            }
            let rendered = try await withTaskCancellationHandler {
                try await renderTask.value
            } onCancel: {
                renderTask.cancel()
            }
            guard !Task.isCancelled else { return }
            let bitmap = rendered.bitmap
            let image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            image.addRepresentation(bitmap)
            preview = image
        } catch {
            guard !Task.isCancelled else { return }
            previewError = error.localizedDescription
        }
    }
}
