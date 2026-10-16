import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
enum ThumbnailPipelineSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftCull-ThumbnailSmoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 600, y: 0, width: 600, height: 800))
        let source = root.appendingPathComponent("photo.jpg")
        let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))

        let service = ThumbnailService.shared
        let key = ThumbnailService.cacheKey(path: source.path, size: 128)
        precondition(key == ThumbnailService.cacheKey(path: source.path, size: 127))
        let crop = CropRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let cropKey = ThumbnailService.cacheKey(path: source.path, size: 128, crop: crop)
        precondition(key != cropKey)

        let normal = await service.thumbnail(path: source.path, id: key, size: 128)
        precondition(normal != nil && normal!.size.width <= 256)
        let cropped = await service.thumbnail(path: source.path, id: cropKey, size: 128, crop: crop)
        precondition(cropped != nil && cropped!.size.width >= 200)
        precondition(service.getCached(cropKey) != nil)

        // Cancelling all requests must release every continuation, including queued requests.
        let tasks = (0..<40).map { index in
            Task {
                await service.thumbnail(path: source.path, id: "cancel-\(index)", size: 512)
            }
        }
        try? await Task.sleep(for: .milliseconds(10))
        service.cancelPending()
        for task in tasks { _ = await task.value }
        print("Thumbnail pipeline smoke passed: shared keys, downsampling, crop cache, cancellation")
    }
}
