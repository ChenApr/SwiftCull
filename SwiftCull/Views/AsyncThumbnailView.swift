import SwiftUI
import AVKit

struct AsyncThumbnailView: View {
    let photoId: String
    let imagePath: String
    let size: CGFloat
    let isVideo: Bool
    let crop: CropRect?

    init(photoId: String, imagePath: String, size: CGFloat, isVideo: Bool = false, crop: CropRect? = nil) {
        self.photoId = photoId
        self.imagePath = imagePath
        self.size = size
        self.isVideo = isVideo
        self.crop = crop
    }

    @State private var image: NSImage?
    @State private var loadTask: Task<Void, Never>?

    private var renderSize: CGFloat {
        CGFloat(ThumbnailService.quantizedSize(size))
    }

    private var cacheId: String {
        "\(imagePath)|\(ThumbnailService.quantizedSize(size))|\(String(describing: crop))"
    }

    var body: some View {
        Group {
            if let image = image {
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                    if isVideo {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 2)
                                    .padding(4)
                            }
                        }
                    }
                }
            } else if isVideo {
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    Image(systemName: "video.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            } else {
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear {
            loadThumbnail()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
        .onChange(of: cacheId) { _, _ in
            // 保留旧缩略图，待新尺寸就绪后再替换，缩放时不闪烁
            loadTask?.cancel()
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        loadTask?.cancel()
        let service = ThumbnailService.shared

        if crop == nil, let cached = service.getCached(cacheId) {
            self.image = cached
            return
        }

        guard !imagePath.isEmpty else { return }

        let requestCacheId = cacheId
        let requestPath = imagePath
        let requestSize = renderSize
        let requestCrop = crop
        loadTask = Task { @MainActor in
            let newImage: NSImage?
            if let requestCrop {
                let cgImage = await Task.detached(priority: .userInitiated) {
                    try? CropImageService.image(path: requestPath, crop: requestCrop,
                                                maxPixelSize: Int(requestSize * 3))
                }.value
                newImage = cgImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            } else {
                newImage = await service.thumbnail(path: requestPath, id: requestCacheId, size: requestSize)
            }
            guard !Task.isCancelled else { return }
            guard cacheId == requestCacheId, let newImage else { return }
            self.image = newImage
        }
    }
}

struct DetailThumbnailView: View {
    let photo: PhotoEntry
    var targetSize: CGFloat = 1000
    @State private var image: NSImage?

    private var cacheId: String {
        "detail|\(photo.primaryFilePath)|\(Int(targetSize.rounded()))|\(String(describing: photo.cropRect))"
    }

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if photo.isVideoOnly {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    Image(systemName: "video.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    ProgressView()
                        .scaleEffect(0.8)
                }
            } else {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .id(cacheId)
        .task(id: cacheId) {
            await loadDetailImage()
        }
    }

    private func loadDetailImage() async {
        let path = photo.primaryImagePath.isEmpty ? (photo.movPath ?? "") : photo.primaryImagePath
        guard !path.isEmpty else { return }

        let requestPath = path
        let isVideo = photo.isVideoOnly
        let loaded = await loadDetailImageBackground(path: requestPath, isVideo: isVideo,
                                                     crop: photo.cropRect, targetPixels: Int(targetSize * 2))

        guard !Task.isCancelled else { return }
        self.image = loaded
    }

    /// Background image loading; isolated to avoid NSImage Sendable issues on older SDKs.
    private nonisolated func loadDetailImageBackground(path: String, isVideo: Bool,
                                                       crop: CropRect?, targetPixels: Int) async -> NSImage? {
        if isVideo {
            let service = ThumbnailService.shared
            // Use withCheckedContinuation to avoid NSImage Sendable requirement in task groups
            return await withCheckedContinuation { continuation in
                service.generateThumbnail(path: path, id: "detail|\(path)", size: 800) { image in
                    continuation.resume(returning: image)
                }
            }
        }
        if let crop {
            guard let cgImage = try? CropImageService.image(path: path, crop: crop,
                                                            maxPixelSize: targetPixels) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let origW = properties?[kCGImagePropertyPixelWidth] as? CGFloat ?? 6000
        let origH = properties?[kCGImagePropertyPixelHeight] as? CGFloat ?? 4000
        let maxDim = max(origW, origH)

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

