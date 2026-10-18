import AppKit

/// Screen-size previews and zoom detail share a bounded cache. Original-size
/// decoding is requested only when the visible zoom needs that many pixels.
actor PhotoPreviewService {
    static let shared = PhotoPreviewService()
    private nonisolated let cache = PreviewCache()

    nonisolated static func pixelTier(viewport: CGSize, displayScale: CGFloat, zoom: CGFloat) -> Int {
        let edge = max(viewport.width, viewport.height) * max(1, displayScale) * max(1, zoom)
        return max(1024, Int((min(65536, max(0, edge)) / 512).rounded(.up)) * 512)
    }

    nonisolated static func sourceKey(for photo: PhotoEntry) -> String {
        "\(photo.primaryFilePath)|\(photo.modificationDate.timeIntervalSince1970)|\(photo.totalFileSize)|\(String(describing: photo.cropRect))"
    }

    nonisolated func cached(for photo: PhotoEntry, pixels: Int) -> NSImage? {
        cache.image(key: "\(Self.sourceKey(for: photo))|\(pixels)")
    }

    func image(for photo: PhotoEntry, pixels: Int) -> NSImage? {
        guard !Task.isCancelled, !photo.isVideoOnly else { return nil }
        if let cached = cached(for: photo, pixels: pixels) { return cached }
        return autoreleasepool {
            guard let dimensions = try? CropImageService.orientedDimensions(path: photo.primaryImagePath) else { return nil }
            let crop = photo.cropRect?.normalized ?? .full
            let nativeEdge = Double(max(dimensions.width, dimensions.height))
            let visibleEdge = max(Double(dimensions.width) * crop.width, Double(dimensions.height) * crop.height)
            guard visibleEdge > 0 else { return nil }
            let sourcePixels = Int(min(nativeEdge, (Double(pixels) * nativeEdge / visibleEdge).rounded(.up)))
            guard let decoded = try? CropImageService.image(path: photo.primaryImagePath, crop: photo.cropRect,
                                                            maxPixelSize: sourcePixels), !Task.isCancelled else { return nil }
            // Compact crops so the cache cannot retain a much larger parent bitmap.
            let rendered: CGImage
            if photo.cropRect != nil {
                guard let context = CGContext(data: nil, width: decoded.width, height: decoded.height,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: decoded.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
                guard let compact = context.makeImage() else { return nil }
                rendered = compact
            } else {
                rendered = decoded
            }
            let image = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
            let cost = rendered.bytesPerRow * rendered.height
            if !Task.isCancelled {
                cache.insert(image, key: "\(Self.sourceKey(for: photo))|\(pixels)", cost: cost)
            }
            return image
        }
    }
}

private final class PreviewCache: @unchecked Sendable {
    private let images = NSCache<NSString, NSImage>()
    private let limit = 144 * 1024 * 1024

    init() { images.countLimit = 12; images.totalCostLimit = limit }
    func image(key: String) -> NSImage? { images.object(forKey: key as NSString) }
    func insert(_ image: NSImage, key: String, cost: Int) {
        if cost <= limit { images.setObject(image, forKey: key as NSString, cost: cost) }
    }
}
