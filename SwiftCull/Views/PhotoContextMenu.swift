import AppKit
import SwiftUI

/// The actions available on a photo in both the grid and the zoomable preview.
struct PhotoContextMenu: View {
    @ObservedObject var store: PhotoStore
    let photo: PhotoEntry
    let onWatermark: () -> Void

    private var sourceFiles: [URL] {
        [photo.jpgPath, photo.nefPath, photo.movPath]
            .compactMap { $0.map { URL(fileURLWithPath: $0) } }
    }

    private var copyCount: Int {
        store.photosToCopy(clicked: photo).count
    }

    var body: some View {
        Menu {
            Button {
                store.setRating(0, for: photo)
            } label: {
                Label("清除评分", systemImage: photo.rating == 0 ? "checkmark.circle.fill" : "star.slash")
            }
            ForEach(1...5, id: \.self) { rating in
                Button {
                    store.setRating(rating, for: photo)
                } label: {
                    Label("\(rating) 星", systemImage: photo.rating == rating ? "checkmark.circle.fill" : "star")
                }
            }
        } label: {
            Label("评分", systemImage: "star")
        }

        Menu {
            ForEach(store.availableTags) { tag in
                Button {
                    if photo.tags.contains(tag.name) {
                        store.removeTag(tag.name, from: photo)
                    } else {
                        store.addTag(tag.name, to: photo)
                    }
                } label: {
                    Label(tag.displayName,
                          systemImage: photo.tags.contains(tag.name) ? "checkmark.circle.fill" : "tag")
                }
            }
            Button("清除所有标签") { store.clearTags(for: photo) }
                .disabled(photo.tags.isEmpty)
        } label: {
            Label("Finder 标签", systemImage: "tag")
        }

        Divider()

        Button {
            store.copyOriginalFiles(clicked: photo)
        } label: {
            Label(copyCount > 1 ? "复制所选原文件（\(copyCount) 张）" : "复制原文件（所有格式）",
                  systemImage: "document.on.document")
        }
        .disabled(sourceFiles.isEmpty)

        Button {
            NSWorkspace.shared.activateFileViewerSelecting(sourceFiles)
        } label: {
            Label("在 Finder 中显示", systemImage: "folder")
        }
        .disabled(sourceFiles.isEmpty)

        Button {
            store.exportOriginalPhoto(photo)
        } label: {
            Label("导出原文件（所有格式）…", systemImage: "square.and.arrow.up")
        }
        .disabled(sourceFiles.isEmpty || store.isExporting)

        Button(action: onWatermark) {
            Label("单张加水印并导出…", systemImage: "photo.badge.plus")
        }
        .disabled((!photo.hasJpg && !photo.hasNef) || store.isExporting)

        Divider()

        Button(role: .destructive) {
            store.requestDelete(photo)
        } label: {
            Label("移至废纸篓（所有格式）", systemImage: "trash")
        }
    }
}
