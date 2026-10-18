import SwiftUI

struct WatermarkFontPicker: View {
    @Binding var fontID: String?
    @ObservedObject private var downloads = WatermarkFontDownloads.shared

    private var selected: WatermarkFont? { WatermarkFont.all.first { $0.id == fontID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("字体", selection: $fontID) {
                Text("系统字体（默认）").tag(String?.none)
                Section("内置字体") {
                    ForEach(WatermarkFont.bundled) { Text($0.name).tag(Optional($0.id)) }
                }
                Section("可选字体") {
                    ForEach(WatermarkFont.downloadable) { option in
                        Text(downloads.label(for: option)).tag(Optional(option.id))
                    }
                }
                Section("本机字体") {
                    ForEach(WatermarkFont.local) { option in
                        Text(option.name + (WatermarkFont.isAvailable(option) ? "" : "（未安装）"))
                            .tag(Optional(option.id)).disabled(!WatermarkFont.isAvailable(option))
                    }
                }
            }
            if let selected {
                WatermarkFontDownloadStatus(option: selected)
                if WatermarkFont.isAvailable(selected) {
                    Text("SwiftCull  光影留痕").font(.custom(selected.family, size: 18))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onChange(of: fontID) { _, _ in
            // Only an explicit selection initiates a download. Opening an older
            // preset displays its missing-font action without network activity.
            if let selected, selected.download != nil, !WatermarkFont.isAvailable(selected) {
                downloads.download(selected)
            }
        }
    }
}

struct WatermarkFontDownloadStatus: View {
    let option: WatermarkFont
    @ObservedObject private var downloads = WatermarkFontDownloads.shared

    var body: some View {
        if !WatermarkFont.isAvailable(option), option.download != nil {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if downloads.states[option.id] == .downloading {
                        ProgressView().controlSize(.small)
                        Text("正在下载 \(option.name)…").font(.caption)
                        Spacer(minLength: 0)
                        Button("取消") { downloads.cancel(option) }
                    } else {
                        let size = ByteCountFormatter.string(fromByteCount: Int64(option.download?.bytes ?? 0), countStyle: .file)
                        Text("\(option.name) · \(size)").font(.caption)
                        Spacer(minLength: 0)
                        Button("下载字体") { downloads.download(option) }
                    }
                }
                .buttonStyle(.borderless)
                if case .failed(let message) = downloads.states[option.id] {
                    Text(message).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("下载后可离线使用").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
