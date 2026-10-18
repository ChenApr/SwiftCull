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

        service.preloadThumbnails(paths: [(path: source.path, crop: nil)], size: 128)
        let normal = await service.thumbnail(path: source.path, id: key, size: 128)
        precondition(normal != nil && normal!.size.width <= 256)
        service.preloadThumbnails(paths: [(path: source.path, crop: crop)], size: 128)
        let cropped = await service.thumbnail(path: source.path, id: cropKey, size: 128, crop: crop)
        precondition(cropped != nil && cropped!.size.width >= 200)
        precondition(cropped!.size.width == cropped!.size.height, "Grid crops must match the visible center square")
        precondition(service.getCached(cropKey) != nil)

        try await checkInspectorPreviews(in: root, service: service)
        try await checkPreheatWindows(in: root, source: source, service: service)

        // Cancelling all requests must release every continuation, including queued requests.
        let tasks = (0..<40).map { index in
            Task {
                await service.thumbnail(path: source.path, id: "cancel-\(index)", size: 512)
            }
        }
        try? await Task.sleep(for: .milliseconds(10))
        service.cancelPending()
        for task in tasks { _ = await task.value }
        print("Thumbnail pipeline smoke passed: shared keys, downsampling, crop cache, cancellation, inspector previews, scrolling preheat windows")
    }

    private static func checkPreheatWindows(in root: URL, source: URL, service: ThumbnailService) async throws {
        // Rapid scrolls alternate overlapping windows and distant jumps while
        // visible cards request some of the same images. No waiter may be stranded.
        service.clearInMemoryCache()
        let paths = try (0..<96).map { index -> String in
            let url = root.appendingPathComponent("scroll-\(index).jpg")
            try FileManager.default.linkItem(at: source, to: url)
            return url.path
        }
        var visible: [Task<NSImage?, Never>] = []
        for start in [0, 8, 16, 48, 40, 32, 8, 0] {
            let window = paths[start..<start + 32].map { (path: $0, crop: Optional<CropRect>.none) }
            service.preloadThumbnails(paths: window, size: 128)
            for path in paths[start..<start + 4] {
                visible.append(Task {
                    await service.thumbnail(path: path, id: ThumbnailService.cacheKey(path: path, size: 128), size: 128)
                })
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        for request in visible {
            let result = await request.value
            precondition(result != nil, "Moving the preheat window must not cancel visible requests")
        }
        service.preloadThumbnails(paths: [], size: 128)
    }

    private static func checkInspectorPreviews(in root: URL, service: ThumbnailService) async throws {
        let source = root.appendingPathComponent("large.jpg")
        let context = CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 4000))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 3000, y: 0, width: 3000, height: 4000))
        let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let date = Date()
        let photo = PhotoEntry(baseName: "large", jpgPath: source.path, nefPath: nil, movPath: nil,
                               jpgFileSize: nil, nefFileSize: nil, movFileSize: nil,
                               fileDate: date, modificationDate: date)

        let start = CFAbsoluteTimeGetCurrent()
        let loaded = await service.inspectorThumbnail(for: photo)
        let coldMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let preview = try requireImage(loaded)
        precondition(preview.width == 960 && preview.height == 640)
        let key = ThumbnailService.inspectorCacheKey(for: photo)
        precondition(key != ThumbnailService.cacheKey(path: source.path, size: 480))

        // Identical callers must share the same cached render, including reopening the inspector.
        let requests = (0..<12).map { _ in Task { await service.inspectorThumbnail(for: photo) } }
        for request in requests {
            let cached = await request.value
            precondition(cached === loaded)
        }

        // A tall, very narrow crop must retain enough vertical resolution without
        // keeping the original 6000x4000 backing buffer in the cached result.
        let crop = CropRect(x: 0.75, y: 0, width: 0.01, height: 1)
        let version = photo.asVersion(CropVersion(id: UUID(), name: "strip", crop: crop))
        precondition(ThumbnailService.inspectorCacheKey(for: version) != key)
        let cropped = try requireImage(await service.inspectorThumbnail(for: version))
        precondition(cropped.width <= 15 && cropped.height == 960)
        precondition(cropped.bytesPerRow * cropped.height < 100_000)
        let pixel = NSBitmapImageRep(cgImage: cropped).colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
        precondition(pixel.blueComponent > 0.9 && pixel.redComponent < 0.1)

        let gridKey = ThumbnailService.cacheKey(path: source.path, size: 128, crop: crop)
        let gridCrop = try requireImage(await service.thumbnail(path: source.path, id: gridKey, size: 128, crop: crop))
        precondition(gridCrop.width == gridCrop.height && gridCrop.width <= 384)
        precondition(gridCrop.bytesPerRow * gridCrop.height <= 384 * 384 * 4)
        let gridPixel = NSBitmapImageRep(cgImage: gridCrop).colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
        precondition(gridPixel.blueComponent > 0.9 && gridPixel.redComponent < 0.1)

        // EXIF rotation precedes crop coordinates, just as it does in the full-size preview.
        let rotatedSource = root.appendingPathComponent("rotated.jpg")
        let rotatedDestination = CGImageDestinationCreateWithURL(rotatedSource as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(rotatedDestination, context.makeImage()!,
                                  [kCGImagePropertyOrientation: 6] as CFDictionary)
        precondition(CGImageDestinationFinalize(rotatedDestination))
        var rotated = PhotoEntry(baseName: "rotated", jpgPath: rotatedSource.path, nefPath: nil, movPath: nil,
                                 jpgFileSize: nil, nefFileSize: nil, movFileSize: nil,
                                 fileDate: date, modificationDate: date)
        let rotatedImage = try requireImage(await service.inspectorThumbnail(for: rotated))
        precondition(rotatedImage.width == 640 && rotatedImage.height == 960)
        rotated.cropRect = CropRect(x: 0, y: 0.5, width: 1, height: 0.5)
        let rotatedCrop = try requireImage(await service.inspectorThumbnail(for: rotated))
        precondition(rotatedCrop.width == 960 && rotatedCrop.height == 720)

        // Concurrent cold callers are coalesced, rather than starting twelve decodes.
        service.clearInMemoryCache()
        let concurrent = (0..<12).map { _ in Task { await service.inspectorThumbnail(for: photo) } }
        let first = await concurrent[0].value
        precondition(first != nil)
        for request in concurrent {
            let result = await request.value
            precondition(result === first)
        }

        // Fast switching / closing cancels the await even if decoding is already underway.
        service.clearInMemoryCache()
        let cancelled = Task { await service.inspectorThumbnail(for: photo) }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        precondition(cancelledResult == nil)

        // A warm preview remains usable without reopening the source file.
        let warm = await service.inspectorThumbnail(for: photo)
        try FileManager.default.removeItem(at: source)
        let cached = await service.inspectorThumbnail(for: photo)
        precondition(cached != nil && cached === warm)
        print(String(format: "Inspector 6000x4000 -> %dx%d: cold %.1f ms, bitmap %.2f MiB (source %.2f MiB)",
                     preview.width, preview.height, coldMilliseconds,
                     Double(preview.bytesPerRow * preview.height) / 1_048_576,
                     Double(6000 * 4000 * 4) / 1_048_576))
    }

    private static func requireImage(_ image: NSImage?) throws -> CGImage {
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "ThumbnailPipelineSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Expected decoded inspector preview"])
        }
        return cgImage
    }
}
