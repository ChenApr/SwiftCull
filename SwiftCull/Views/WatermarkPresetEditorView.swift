import AppKit
import SwiftUI

struct WatermarkPresetEditorView: View {
    let photo: PhotoEntry?
    let sourcePath: String?
    let onSave: (WatermarkConfiguration) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WatermarkConfiguration
    @State private var preview: NSImage?
    @State private var previewError: String?
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
            Text("拖动控件或修改文字后自动更新")
                .font(.caption).foregroundStyle(.secondary)
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
                Picker("背景", selection: $draft.background) {
                    ForEach(WatermarkConfiguration.Background.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                ColorPicker("背景颜色", selection: Binding(
                    get: { Color(nsColor: NSColor.watermarkHex(draft.backgroundHex) ?? .white) },
                    set: { draft.backgroundHex = NSColor($0).watermarkHexString }
                ))
                valueSlider("画布留白", value: $draft.paddingPercent, range: 0...20)
                valueSlider("底栏高度", value: $draft.footerPercent, range: 0...35)
                valueSlider("照片圆角", value: $draft.cornerRadiusPercent, range: 0...10)
                Toggle("照片阴影", isOn: $draft.shadow)
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
                                position: draft.footerPercent > 0 ? .footerLeft : .bottomLeft,
                                text: kind == .customText ? "自定义文字" : "",
                                colorHex: draft.footerPercent > 0 ? "#202020" : "#FFFFFF"
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
            Text("文字组件")
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
            if component.wrappedValue.kind == .customText {
                TextField("显示文字", text: component.text)
            }
            Picker("位置", selection: component.position) {
                ForEach(WatermarkComponent.Position.allCases) { position in
                    Text(position.rawValue).tag(position)
                }
            }
            HStack {
                Text("字号")
                Slider(value: component.fontPercent, in: 0.5...8, step: 0.1)
                Text(String(format: "%.1f%%", component.wrappedValue.fontPercent))
                    .monospacedDigit().frame(width: 48)
            }
            HStack {
                ColorPicker("文字颜色", selection: Binding(
                    get: { Color(nsColor: NSColor.watermarkHex(component.wrappedValue.colorHex) ?? .black) },
                    set: { component.wrappedValue.colorHex = NSColor($0).watermarkHexString }
                ))
                Toggle("加粗", isOn: component.bold)
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

    private func loadPreview() async {
        preview = nil
        previewError = nil
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard !Task.isCancelled else { return }
        guard let photo else {
            previewError = "筛选结果中没有可处理的照片"
            return
        }
        let current = draft
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try WatermarkService.previewData(photo: photo, configuration: current, sourcePath: sourcePath)
            }.value
            guard !Task.isCancelled else { return }
            preview = NSImage(data: data)
        } catch {
            guard !Task.isCancelled else { return }
            previewError = error.localizedDescription
        }
    }
}
