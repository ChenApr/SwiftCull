import AppKit
import UniformTypeIdentifiers

@main
enum PreviewResolutionSmoke {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCull-Resolution-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("large.jpg")
        autoreleasepool {
            let context = CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 4000))
            context.setFillColor(NSColor.blue.cgColor)
            context.fill(CGRect(x: 3000, y: 0, width: 3000, height: 4000))
            let output = CGImageDestinationCreateWithURL(path as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(output, context.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(output))
        }
        let service = PhotoPreviewService()
        let date = Date()
        let photo = PhotoEntry(baseName: "large", jpgPath: path.path, nefPath: nil, movPath: nil,
            jpgFileSize: nil, nefFileSize: nil, movFileSize: nil, fileDate: date, modificationDate: date)
        let start = ProcessInfo.processInfo.systemUptime
        let fit = await service.image(for: photo, pixels: 2048)!
        let fitMS = (ProcessInfo.processInfo.systemUptime-start)*1000
        precondition(fit.size.width == 2048 && abs(fit.size.height / fit.size.width - 2.0/3.0) < 0.001)
        precondition(service.cached(for: photo, pixels: 2048) === fit)
        let full = await service.image(for: photo, pixels: 8192)!
        precondition(full.size == NSSize(width: 6000, height: 4000), "Zoom must retain original detail")
        let cropped = photo.asVersion(CropVersion(id: UUID(), name: "blue half",
            crop: CropRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        let crop = await service.image(for: cropped, pixels: 2048)!
        precondition(crop.size == NSSize(width: 1536, height: 2048))
        var rect = CGRect(origin: .zero, size: crop.size)
        let bitmap = NSBitmapImageRep(cgImage: crop.cgImage(forProposedRect: &rect, context: nil, hints: nil)!)
        let color = bitmap.colorAt(x: 768, y: 1024)!.usingColorSpace(.deviceRGB)!
        precondition(color.blueComponent > 0.8 && color.redComponent < 0.2, "Scaled preview must respect the selected crop")
        var changed = photo
        changed.fileDate = date.addingTimeInterval(100)
        precondition(PhotoPreviewService.sourceKey(for: changed) == PhotoPreviewService.sourceKey(for: photo),
                     "Date index arrival must not restart the image decode")
        let cancelled = Task { await service.image(for: photo, pixels: 10000) }
        cancelled.cancel()
        let cancelledValue = await cancelled.value
        precondition(cancelledValue == nil)
        let fitBytes = fit.size.width * fit.size.height * 4
        print(String(format: "Preview resolution passed: 6000x4000 -> %.0fx%.0f fit, %.2f MiB vs 91.55 MiB original, decode %.1fms; original detail on zoom, compact crop/colors, cache reuse, cancellation, metadata-stable key", fit.size.width, fit.size.height, fitBytes/1048576, fitMS))
    }
}
