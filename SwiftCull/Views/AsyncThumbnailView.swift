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
        ThumbnailService.cacheKey(path: imagePath, size: size, crop: crop)
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

        if let cached = service.getCached(cacheId) {
            self.image = cached
            return
        }

        guard !imagePath.isEmpty else { return }

        let requestCacheId = cacheId
        let requestPath = imagePath
        let requestSize = renderSize
        let requestCrop = crop
        loadTask = Task { @MainActor in
            let newImage = await service.thumbnail(path: requestPath, id: requestCacheId,
                                                   size: requestSize, crop: requestCrop)
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

        let loaded = await loadDetailImageBackground(
            path: path,
            isVideo: photo.isVideoOnly,
            crop: photo.cropRect,
            targetPixels: Int(targetSize * 2)
        )

        guard !Task.isCancelled else { return }
        self.image = loaded
    }

    /// 大图预览使用独立的高分辨率解码路径，不能复用网格缩略图服务的尺寸上限。
    /// 这样网格加载仍然受控，大图则可以按窗口尺寸和缩放级别读取足够的像素。
    private nonisolated func loadDetailImageBackground(path: String, isVideo: Bool,
                                                       crop: CropRect?, targetPixels: Int) async -> NSImage? {
        if isVideo {
            let service = ThumbnailService.shared
            return await withCheckedContinuation { continuation in
                service.generateThumbnail(path: path, id: "detail-video|\(path)", size: 800) { image in
                    continuation.resume(returning: image)
                }
            }
        }

        if let crop {
            // ImageIO applies maxPixelSize before the crop. Scale the source
            // request by the smallest crop dimension so the visible crop can
            // still reach the requested display resolution. The source size
            // remains the hard upper bound inside CropImageService.
            let fraction = max(0.001, min(crop.normalized.width, crop.normalized.height))
            let sourceMaxPixelSize = Int((Double(targetPixels) / fraction).rounded(.up))
            guard let cgImage = try? CropImageService.image(path: path, crop: crop,
                                                            maxPixelSize: sourceMaxPixelSize) else { return nil }
            return NSImage(cgImage: cgImage,
                           size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let originalWidth = properties?[kCGImagePropertyPixelWidth] as? CGFloat ?? 6000
        let originalHeight = properties?[kCGImagePropertyPixelHeight] as? CGFloat ?? 4000
        let maxPixelSize = max(originalWidth, originalHeight)
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

