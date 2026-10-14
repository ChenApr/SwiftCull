import AppKit
import ImageIO

@main
struct WatermarkServiceSmoke {
    static func main() async throws {
        precondition(WatermarkPreset.landscapePresets.count == 7)
        precondition(WatermarkPreset.portraitPresets.count == 8)
        precondition(WatermarkPreset.allCases.count == 15)
        precondition(WatermarkPreset.standard.resolved(isPortrait: true, matchOrientation: true) == .standardPortrait)
        precondition(WatermarkPreset.standardPortrait.resolved(isPortrait: false, matchOrientation: true) == .standard)
        precondition(WatermarkPreset.nikonPortrait.resolved(isPortrait: false, matchOrientation: true) == .nikonPortrait)
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
                if [.standard, .card, .nikonCard, .centerBrand].contains(preset.layout) {
                    precondition(image.pixelsHigh > height)
                } else {
                    precondition(image.pixelsHigh == height)
                }
            }
            let automatic = try WatermarkService.render(photo: photo, preset: .standard,
                                                         matchOrientation: true)
            let expected = try WatermarkService.render(photo: photo,
                                                        preset: height > width ? .standardPortrait : .standard)
            precondition(automatic.pixelsWide == expected.pixelsWide)
            precondition(automatic.pixelsHigh == expected.pixelsHigh)
            let outputDirectory = directory.appendingPathComponent("exports-\(width)x\(height)")
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let first = try WatermarkService.export(photo: photo, preset: .standard,
                                                     sourcePath: input.path, matchOrientation: true,
                                                     to: outputDirectory)
            let firstData = try Data(contentsOf: first)
            let second = try WatermarkService.export(photo: photo, preset: .standard,
                                                      sourcePath: input.path, matchOrientation: true,
                                                      to: outputDirectory)
            let firstDataAfterSecondExport = try Data(contentsOf: first)
            let secondData = try Data(contentsOf: second)
            precondition(first.lastPathComponent == "source-\(width)x\(height)_watermark.jpg")
            precondition(second.lastPathComponent == "source-\(width)x\(height)_watermark_2.jpg")
            precondition(!firstData.isEmpty && !secondData.isEmpty)
            precondition(firstData == firstDataAfterSecondExport, "Existing export changed")
            let unchanged = try Data(contentsOf: input)
            precondition(unchanged == original, "Source image changed")

            var custom = WatermarkConfiguration.draft(from: .standard)
            custom.name = "测试布局"
            custom.background = .blurred
            custom.components.append(WatermarkComponent(kind: .customText, position: .topCenter,
                                                         text: "SwiftCull", colorHex: "#FFFFFF", bold: true))
            let customImage = try WatermarkCustomRenderer.render(photo: photo, configuration: custom)
            let customPreview = try WatermarkService.previewData(photo: photo, configuration: custom)
            precondition(customImage.pixelsWide > width && customImage.pixelsHigh > height)
            precondition(!customPreview.isEmpty)
            if width > height, let previewPath = ProcessInfo.processInfo.environment["SWIFTCULL_SMOKE_PREVIEW"] {
                try customPreview.write(to: URL(fileURLWithPath: previewPath))
            }
            let customExport = try WatermarkService.export(photo: photo, configuration: custom,
                                                            sourcePath: input.path, to: outputDirectory)
            precondition(FileManager.default.fileExists(atPath: customExport.path))
        }
        let presetsDirectory = directory.appendingPathComponent("saved-presets")
        try await MainActor.run {
            let store = WatermarkPresetStore(directory: presetsDirectory)
            var config = WatermarkConfiguration.draft(from: .standard)
            config.name = "保存的预设"
            try store.save(config)
            precondition(store.configurations == [config])
            let reopened = WatermarkPresetStore(directory: presetsDirectory)
            precondition(reopened.configurations == [config])
            config.components.append(WatermarkComponent(kind: .customText, position: .footerCenter,
                                                         text: "新组件"))
            try reopened.save(config)
            precondition(reopened.configurations.first?.components.count == 5)
            try reopened.delete(config.id)
            precondition(reopened.configurations.isEmpty)
        }
        print("Watermark smoke test passed: 15 presets × landscape/portrait, custom layout, persistence, JPEG export")
    }
}
