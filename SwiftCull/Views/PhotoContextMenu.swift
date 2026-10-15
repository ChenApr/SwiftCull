import AppKit
import SwiftUI

struct WatermarkPhotoSelection: Identifiable {
    let id = UUID()
    let photos: [PhotoEntry]
}

/// The actions available on a photo in both the grid and the zoomable preview.
struct PhotoContextMenu: View {
    @ObservedObject var store: PhotoStore
    let photo: PhotoEntry
    var useSelection = true
    let onWatermark: ([PhotoEntry]) -> Void

    private var targets: [PhotoEntry] { store.contextPhotos(clicked: photo, useSelection: useSelection) }
    private var isBatch: Bool { targets.count > 1 }

    private var sourceFiles: [URL] {
        targets.flatMap { entry in
            [entry.jpgPath, entry.nefPath, entry.movPath]
                .compactMap { $0.map { URL(fileURLWithPath: $0) } }
        }
    }

    private var watermarkable: [PhotoEntry] { targets.filter { $0.hasJpg || $0.hasNef } }

    var body: some View {
        Menu {
            Button {
                store.contextSetRating(0, clicked: photo, useSelection: useSelection)
            } label: {
                Label("清除评分", systemImage: targets.allSatisfy { $0.rating == 0 }
                      ? "checkmark.circle.fill" : "star.slash")
            }
            ForEach(1...5, id: \.self) { rating in
                Button {
                    store.contextSetRating(rating, clicked: photo, useSelection: useSelection)
                } label: {
                    Label("\(rating) 星", systemImage: targets.allSatisfy { $0.rating == rating }
                          ? "checkmark.circle.fill" : "star")
                }
            }
        } label: {
            Label(isBatch ? "给所选 \(targets.count) 张评分" : "评分", systemImage: "star")
        }

        Menu {
            ForEach(store.availableTags) { tag in
                Button {
                    store.contextToggleTag(tag.name, clicked: photo, useSelection: useSelection)
                } label: {
                    Label(tag.displayName,
                          systemImage: targets.allSatisfy { $0.tags.contains(tag.name) }
                            ? "checkmark.circle.fill" : "tag")
                }
            }
            Button("清除所有标签") { store.contextClearTags(clicked: photo, useSelection: useSelection) }
                .disabled(targets.allSatisfy { $0.tags.isEmpty })
        } label: {
            Label(isBatch ? "给所选 \(targets.count) 张设标签" : "Finder 标签", systemImage: "tag")
        }

        Divider()

        if !isBatch && photo.movPath != nil {
            Button { store.enterVideoPlaybackMode(for: photo) } label: {
                Label("播放视频 (V)", systemImage: "play.rectangle")
            }
        }

        if !isBatch && !photo.isVideoOnly {
            Button { store.editCrop(photo) } label: {
                Label("裁剪 / 编辑版本…", systemImage: "crop.rotate")
            }
            if store.versionCount(for: photo) > 1 {
                Menu {
                    ForEach(store.versions(for: photo)) { version in
                        Button(version.isVersionCopy ? version.displayName : "主版本") {
                            store.expandedVersionSources.insert(photo.sourceID)
                            store.applyFilters()
                            store.selectPhoto(version)
                        }
                    }
                } label: {
                    Label("切换裁剪版本", systemImage: "square.stack.3d.up")
                }
            }
            if photo.isVersionCopy {
                Button(role: .destructive) { store.removeVersion(photo) } label: {
                    Label("删除此裁剪版本", systemImage: "square.stack.3d.up.slash")
                }
            }
        }

        Button {
            store.copyOriginalFiles(clicked: photo, useSelection: useSelection)
        } label: {
            Label(isBatch ? "复制所选版本（\(targets.count) 张）" :
                  (photo.cropRect == nil ? "复制原文件（所有格式）" : "复制裁剪版本（所有格式）"),
                  systemImage: "document.on.document")
        }
        .disabled(sourceFiles.isEmpty)

        Button {
            NSWorkspace.shared.activateFileViewerSelecting(sourceFiles)
        } label: {
            Label(isBatch ? "在 Finder 中显示所选文件" : "在 Finder 中显示", systemImage: "folder")
        }
        .disabled(sourceFiles.isEmpty)

        Button {
            if isBatch { store.exportSelectedPhotos() }
            else { store.exportOriginalPhoto(photo) }
        } label: {
            Label(isBatch ? "导出所选 \(targets.count) 张照片…" :
                  (photo.cropRect == nil ? "导出原文件（所有格式）…" : "导出裁剪版本（所有格式）…"),
                  systemImage: "square.and.arrow.up")
        }
        .disabled(sourceFiles.isEmpty || store.isExporting)

        Button { onWatermark(watermarkable) } label: {
            Label(isBatch ? "所选 \(watermarkable.count) 张加水印并导出…" : "单张加水印并导出…",
                  systemImage: "photo.badge.plus")
        }
        .disabled(watermarkable.isEmpty || store.isExporting)

        Divider()

        Button(role: .destructive) {
            if isBatch { store.requestDeleteSelected() }
            else { store.requestDelete(photo) }
        } label: {
            Label(isBatch ? "将所选 \(targets.count) 张移至废纸篓" : "移至废纸篓（所有格式）",
                  systemImage: "trash")
        }
    }
}
