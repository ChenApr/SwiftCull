import AppKit
import ImageIO

@main
struct WatermarkServiceSmoke {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (width, height) in [(1200, 800), (800, 1200)] {
            let input = directory.appendingPathComponent("source-\(width)x\(height).jpg")
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.systemRed.setFill()
            CGRect(x: 0, y: height / 2, width: width, height: height / 2).fill()
            NSColor.systemBlue.setFill()
            CGRect(x: 0, y: 0, width: width, height: height / 2).fill()
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            let original = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95])!
            try original.write(to: input)

            let photo = PhotoEntry(
                baseName: "source", jpgPath: input.path, nefPath: nil, movPath: nil,
                jpgFileSize: Int64(original.count), nefFileSize: nil, movFileSize: nil,
                fileDate: Date(), modificationDate: Date()
            )
            for preset in WatermarkPreset.allCases {
                let image = try WatermarkService.render(photo: photo, preset: preset)
                let preview = try WatermarkService.previewData(photo: photo, preset: preset)
                let exported = try WatermarkService.jpegData(photo: photo, preset: preset)
                let exportedSource = CGImageSourceCreateWithData(exported as CFData, nil)!
                let exportedImage = CGImageSourceCreateImageAtIndex(exportedSource, 0, nil)!
                precondition(!preview.isEmpty && exportedImage.width == image.pixelsWide)
                precondition(exportedImage.height == image.pixelsHigh)
                if [.standard, .standardCard, .centerBrand].contains(preset) {
                    precondition(image.pixelsHigh > height)
                } else {
                    precondition(image.pixelsHigh == height)
                }
            }
            let unchanged = try Data(contentsOf: input)
            precondition(unchanged == original, "Source image changed")
        }
        print("Watermark smoke test passed: 7 presets × landscape/portrait, JPEG and preview, source unchanged")
    }
}
