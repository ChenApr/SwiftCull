import SwiftUI
import Quartz

class QuickLookPreviewItem: NSObject, QLPreviewItem {
    var previewItemURL: URL?
    var previewItemTitle: String?

    init(url: URL, title: String? = nil) {
        self.previewItemURL = url
        self.previewItemTitle = title
    }
}

class QuickLookHelper: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated(unsafe) static let shared = QuickLookHelper()
    private var currentItem: QuickLookPreviewItem?
    private var panel: QLPreviewPanel?

    @MainActor func preview(_ url: URL) {
        currentItem = QuickLookPreviewItem(url: url)

        if let panel = panel {
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let panel = QLPreviewPanel.shared() {
                    panel.dataSource = self
                    panel.delegate = self
                    panel.makeKeyAndOrderFront(nil)
                    self.panel = panel
                }
            }
        }
    }

    @MainActor func closePanel() {
        panel?.close()
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        1
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        currentItem ?? QuickLookPreviewItem(url: URL(fileURLWithPath: "/"))
    }
}

struct PhotoDetailView: View {
    @EnvironmentObject var store: PhotoStore
    var showsPreview = true
    @State private var exifInfo: PhotoExifInfo?
    @State private var exifTask: Task<Void, Never>?
    @State private var watermarkSelection: WatermarkPhotoSelection?
    @State private var versionNameDraft = ""

    private var photo: PhotoEntry? {
        store.selectedPhoto
    }

    private let panelPadding: CGFloat = 12

    var body: some View {
        if let photo {
            VStack(spacing: 0) {
                if showsPreview {
                    imageSection(photo)
                }
                ScrollView {
                    VStack(spacing: 10) {
                        infoSection(photo)
                        versionSection(photo)
                        exifSection(photo)
                        ratingSection(photo)
                        tagSection(photo)
                        actionSection(photo)
                    }
                    .padding(panelPadding)
                    .subtleScrollbars()
                }
                .scrollIndicators(.automatic)
            }
            .background(detailBackground)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear {
                loadExif(for: photo)
                versionNameDraft = photo.displayName
            }
            .onDisappear {
                exifTask?.cancel()
                exifTask = nil
            }
            .onChange(of: photo.id) { _, _ in
                loadExif(for: photo)
                versionNameDraft = photo.displayName
            }
            .sheet(item: $watermarkSelection) { selection in
                WatermarkExportView(store: store, photos: selection.photos)
            }
        } else {
            VStack {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("选择一张照片查看详情")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func imageSection(_ photo: PhotoEntry) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.black.opacity(0.04))
                .overlay {
                    InspectorThumbnailView(photo: photo)
                        .padding(.vertical, 5)
                }
                .frame(height: 220)
                .clipped()
                .contextMenu {
                    PhotoContextMenu(store: store, photo: photo, useSelection: false) { photos in
                        watermarkSelection = WatermarkPhotoSelection(photos: photos)
                    }
                }

            HStack {
                fileTypePill(photo)
                Spacer()
                if photo.movPath != nil {
                    Button {
                        store.toggleVideoPlaybackMode(for: photo)
                    } label: {
                        Label(store.isVideoPlaybackMode && store.selectedPhoto?.id == photo.id
                              ? "退出播放" : "播放视频",
                              systemImage: store.isVideoPlaybackMode && store.selectedPhoto?.id == photo.id
                              ? "stop.circle" : "play.rectangle")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .help(store.isVideoPlaybackMode && store.selectedPhoto?.id == photo.id
                          ? "退出播放 (V)" : "播放视频 (V)")
                }
                Button {
                    openQuickLook(photo)
                } label: {
                    Label("查看大图", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, panelPadding)
            .padding(.vertical, 7)
            .background(.bar)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 0.5)
            }
        }
    }

    private func openQuickLook(_ photo: PhotoEntry) {
        store.previewPhoto(photo)
    }

    @ViewBuilder
    private func versionSection(_ photo: PhotoEntry) -> some View {
        // Ordinary photos need no full-library scan on each inspector update.
        let versions = store.versionCount(for: photo) > 1 ? store.versions(for: photo) : []
        if versions.count > 1 || photo.cropRect != nil {
            DetailCard(title: "裁剪版本", systemImage: "square.stack.3d.up") {
                VStack(alignment: .leading, spacing: 8) {
                    if versions.count > 1 {
                        Menu {
                            ForEach(versions) { version in
                                Button(version.isVersionCopy ? version.displayName : "主版本") {
                                    store.expandedVersionSources.insert(photo.sourceID)
                                    store.applyFilters()
                                    store.selectPhoto(version)
                                }
                            }
                        } label: {
                            Label(photo.isVersionCopy ? photo.displayName : "主版本", systemImage: "square.stack")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if photo.isVersionCopy {
                        HStack {
                            TextField("版本名称", text: $versionNameDraft)
                            Button("重命名") { store.renameVersion(photo, to: versionNameDraft) }
                        }
                        Button("删除此版本", role: .destructive) { store.removeVersion(photo) }
                    }
                }
            }
        }
    }

    private func infoSection(_ photo: PhotoEntry) -> some View {
        DetailCard(title: "文件信息", systemImage: "info.circle") {
            VStack(spacing: 5) {
                detailRow("文件名", photo.displayName, canSelect: true)
                detailRow("类型") {
                    fileTypePill(photo)
                }
                detailRow("大小", photo.formattedSize)
                detailRow(store.captureDatesReady ? "拍摄时间" : "文件日期", photo.formattedCaptureDate)
                detailRow("最后修改", photo.formattedModificationDate)
            }
        }
    }

    private func exifSection(_ photo: PhotoEntry) -> some View {
        DetailCard(title: "EXIF 信息", systemImage: "camera.aperture") {
            if let exif = exifInfo, exif.hasAnyValue {
                VStack(spacing: 6) {
                    detailRow("相机", exif.camera ?? "未提供", canSelect: true)
                    detailRow("镜头", exif.lens ?? "未提供", canSelect: true)
                    HStack(spacing: 6) {
                        metricPill(title: "焦距", value: exif.focalLength ?? "-")
                        metricPill(title: "光圈", value: exif.aperture ?? "-")
                    }
                    HStack(spacing: 6) {
                        metricPill(title: "快门", value: exif.shutterSpeed ?? "-")
                        metricPill(title: "ISO", value: exif.iso ?? "-")
                    }
                    detailRow("拍摄时间", exif.capturedAt ?? "未提供", canSelect: true)
                }
            } else if exifInfo == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.65)
                    Text("正在读取 EXIF...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                emptyHint("未读取到 EXIF 信息")
            }
        }
    }

    private func loadExif(for photo: PhotoEntry) {
        exifTask?.cancel()
        exifInfo = nil

        let photoID = photo.id
        let path = photo.primaryImagePath
        let fallbackDate = photo.fileDate
        let revision = "\(photo.modificationDate.timeIntervalSince1970)|\(photo.totalFileSize)"

        exifTask = Task {
            let info = await PhotoExifCache.shared.info(for: path, fallbackDate: fallbackDate, revision: revision)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard store.selectedPhoto?.id == photoID else { return }
                exifInfo = info
            }
        }
    }

    private func ratingSection(_ photo: PhotoEntry) -> some View {
        DetailCard(title: "评分", systemImage: "star") {
            RatingView(rating: photo.rating) { newRating in
                store.contextSetRating(newRating, clicked: photo, useSelection: false)
            }
        }
    }

    private func tagSection(_ photo: PhotoEntry) -> some View {
        DetailCard(title: "标签", systemImage: "tag") {
            VStack(alignment: .leading, spacing: 8) {
                if !photo.tags.isEmpty {
                    HStack(alignment: .top) {
                        FlowLayout(spacing: 6) {
                            ForEach(photo.tags, id: \.self) { tag in
                                TagChip(tag: tag) {
                                    store.contextToggleTag(tag, clicked: photo, useSelection: false)
                                }
                            }
                        }
                        Spacer(minLength: 6)
                        Button {
                            store.contextClearTags(clicked: photo, useSelection: false)
                        } label: {
                            Image(systemName: "tag.slash")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(.thinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("清除所有标签")
                    }
                } else if !store.areTagsLoaded(for: photo) {
                    emptyHint("正在读取标签…")
                } else {
                    emptyHint("尚未添加标签")
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("添加标签")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(store.availableTags.filter { !photo.tags.contains($0.name) }) { tag in
                            Button {
                                store.contextToggleTag(tag.name, clicked: photo, useSelection: false)
                            } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(tag.color)
                                        .frame(width: 9, height: 9)
                                    Text(tag.displayName)
                                        .font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(tag.color.opacity(0.13), in: Capsule())
                                .overlay(Capsule().stroke(tag.color.opacity(0.18), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func actionSection(_ photo: PhotoEntry) -> some View {
        DetailCard(title: "操作", systemImage: "slider.horizontal.3") {
            VStack(spacing: 6) {
                let allFiles = [photo.jpgPath, photo.nefPath, photo.movPath]
                    .compactMap { $0.map { URL(fileURLWithPath: $0) } }

                if !allFiles.isEmpty {
                    if photo.movPath != nil {
                        Button { store.toggleVideoPlaybackMode(for: photo) } label: {
                            actionLabel(store.isVideoPlaybackMode && store.selectedPhoto?.id == photo.id
                                        ? "退出播放" : "播放视频",
                                        systemImage: store.isVideoPlaybackMode && store.selectedPhoto?.id == photo.id
                                        ? "stop.circle" : "play.rectangle")
                        }
                        .buttonStyle(InspectorActionButtonStyle())
                        .help(store.isVideoPlaybackMode && store.selectedPhoto?.id == photo.id
                              ? "退出播放 (V)" : "播放视频 (V)")
                        Button { store.openLivePhotoEditor(for: photo) } label: {
                            actionLabel("制作实况照片…", systemImage: "livephoto")
                        }
                        .buttonStyle(InspectorActionButtonStyle())
                    }
                    if !photo.hasMov {
                        Button { store.editCrop(photo) } label: {
                            actionLabel("裁剪 / 编辑版本…", systemImage: "crop.rotate")
                        }
                        .buttonStyle(InspectorActionButtonStyle())
                        .help("裁剪 / 编辑版本 (C)")
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(allFiles)
                    } label: {
                        actionLabel("在 Finder 中显示", systemImage: "folder")
                    }
                    .buttonStyle(InspectorActionButtonStyle())

                    Button {
                        store.exportOriginalPhoto(photo)
                    } label: {
                        actionLabel(photo.cropRect == nil ? "导出此照片原文件…" : "导出此裁剪版本…",
                                    systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(InspectorActionButtonStyle())
                    .disabled(store.isExporting)
                }

                if photo.hasJpg || photo.hasNef {
                    Button {
                        watermarkSelection = WatermarkPhotoSelection(photos: [photo])
                    } label: {
                        actionLabel("边框与水印…", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(InspectorActionButtonStyle())
                    .disabled(store.isExporting)
                }

                Button(role: .destructive) {
                    store.requestDelete(photo)
                } label: {
                    actionLabel("移至废纸篓 (此照片所有格式)", systemImage: "trash")
                }
                .buttonStyle(InspectorActionButtonStyle(isDestructive: true))
            }
        }
    }

    private var detailBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .controlBackgroundColor).opacity(0.72)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func detailRow(_ title: String, _ value: String, canSelect: Bool = false) -> some View {
        detailRow(title) {
            if canSelect {
                Text(value)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func detailRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            Spacer(minLength: 6)
            content()
        }
        .frame(minHeight: 18)
    }

    private func fileTypePill(_ photo: PhotoEntry) -> some View {
        Text(photo.fileTypeBadge)
            .font(.caption2.weight(.bold))
            .foregroundStyle(photo.fileTypeBadgeColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(photo.fileTypeBadgeColor.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(photo.fileTypeBadgeColor.opacity(0.2), lineWidth: 0.5))
    }

    private func metricPill(title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .leading)
            Spacer(minLength: 6)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 28)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.5)
        )
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18)
        }
        .labelStyle(.titleAndIcon)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}
