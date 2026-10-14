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
            if width > height {
                let nikonInput = directory.appendingPathComponent("synthetic-nikon.jpg")
                guard let destination = CGImageDestinationCreateWithURL(
                    nikonInput as CFURL, "public.jpeg" as CFString, 1, nil
                ), let image = bitmap.cgImage else { fatalError("Cannot create EXIF fixture") }
                CGImageDestinationAddImage(destination, image, [
                    kCGImagePropertyTIFFDictionary: [
                        kCGImagePropertyTIFFMake: "NIKON CORPORATION",
                        kCGImagePropertyTIFFModel: "NIKON Z50_2"
                    ]
                ] as CFDictionary)
                precondition(CGImageDestinationFinalize(destination))
                let branded = try WatermarkService.render(photo: photo, preset: .standard,
                                                          sourcePath: nikonInput.path)
                let hasYellowLogo = stride(from: 0, to: branded.pixelsWide, by: 4).contains { x in
                    stride(from: 0, to: branded.pixelsHigh, by: 4).contains { y in
                        guard let color = branded.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                        return color.redComponent > 0.9 && color.greenComponent > 0.6
                            && color.blueComponent < 0.3
                    }
                }
                precondition(hasYellowLogo, "Bundled Nikon logo was not rendered")
                for preset in [WatermarkPreset.standard, .nikonPortrait, .centerBrand] {
                    let builtIn = try WatermarkService.render(photo: photo, preset: preset,
                                                              sourcePath: nikonInput.path)
                    let editor = try WatermarkCustomRenderer.render(
                        photo: photo, configuration: .draft(from: preset), sourcePath: nikonInput.path)
                    precondition(editor.tiffRepresentation == builtIn.tiffRepresentation,
                                 "Nikon editor rendering differs from \(preset.rawValue)")
                }
                var uploaded = WatermarkConfiguration.draft(from: .centerBrand)
                precondition(uploaded.components.count == 1 && uploaded.components[0].kind == .logo)
                uploaded.components[0].imageData = bitmap.representation(using: .png, properties: [:])
                let changed = try WatermarkCustomRenderer.render(photo: photo, configuration: uploaded,
                                                                 sourcePath: nikonInput.path)
                let originalBrand = try WatermarkService.render(photo: photo, preset: .centerBrand,
                                                                sourcePath: nikonInput.path)
                precondition(changed.tiffRepresentation != originalBrand.tiffRepresentation,
                             "Uploaded Logo was not rendered")
                let encoded = try JSONEncoder().encode(uploaded)
                let decoded = try JSONDecoder().decode(WatermarkConfiguration.self, from: encoded)
                precondition(decoded.components[0].imageData == uploaded.components[0].imageData,
                             "Uploaded Logo was not persisted")
            }
            for preset in WatermarkPreset.allCases {
                let image = try WatermarkService.render(photo: photo, preset: preset)
                let draft = WatermarkConfiguration.draft(from: preset)
                let editorImage = try WatermarkCustomRenderer.render(photo: photo, configuration: draft)
                precondition(editorImage.pixelsWide == image.pixelsWide && editorImage.pixelsHigh == image.pixelsHigh,
                             "Editor canvas differs from \(preset.rawValue)")
                precondition(editorImage.tiffRepresentation == image.tiffRepresentation,
                             "Initial editor rendering differs from \(preset.rawValue)")
                let preview = try WatermarkService.previewData(photo: photo, preset: preset)
                let exported = try WatermarkService.jpegData(photo: photo, preset: preset)
                let exportedSource = CGImageSourceCreateWithData(exported as CFData, nil)!
                let exportedImage = CGImageSourceCreateImageAtIndex(exportedSource, 0, nil)!
                precondition(!preview.isEmpty && exportedImage.width == image.pixelsWide)
                precondition(exportedImage.height == image.pixelsHigh)
                if [.cornerParameters, .folderAndDate].contains(preset.layout) {
                    precondition(image.pixelsHigh == height)
                } else {
                    precondition(image.pixelsHigh > height)
                }
                if [.blur, .nikonBlur].contains(preset.layout) {
                    precondition(image.pixelsWide == Int(Double(width) * 1.35))
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
            precondition(customImage.pixelsWide == width && customImage.pixelsHigh > height)
            precondition(!customPreview.isEmpty)
            if width > height, let previewPath = ProcessInfo.processInfo.environment["SWIFTCULL_SMOKE_PREVIEW"] {
                try customPreview.write(to: URL(fileURLWithPath: previewPath))
            }
            let customExport = try WatermarkService.export(photo: photo, configuration: custom,
                                                            sourcePath: input.path, to: outputDirectory)
            precondition(FileManager.default.fileExists(atPath: customExport.path))

            if width > height {
                var first = WatermarkReviewItem(photo: photo, sourcePath: input.path)
                first.choice = .builtIn(.blur)
                var second = WatermarkReviewItem(photo: photo, sourcePath: input.path)
                second.include = false
                second.choice = .custom(custom.id)
                var requests = try WatermarkReviewPlan.requests(from: [first, second],
                                                                 configurations: [custom])
                precondition(requests.count == 1)
                guard case .preset(.blur) = requests[0].style else {
                    fatalError("Per-photo preset was lost")
                }
                second.include = true
                second.matchOrientation = false
                requests = try WatermarkReviewPlan.requests(from: [first, second],
                                                            configurations: [custom])
                precondition(requests.count == 2 && !requests[1].matchOrientation)
                guard case .custom(let saved) = requests[1].style, saved.id == custom.id else {
                    fatalError("Per-photo custom preset was lost")
                }
                second.choice = .custom(UUID())
                precondition((try? WatermarkReviewPlan.requests(from: [first, second],
                                                                configurations: [custom])) == nil,
                             "Deleted custom preset should block export")
            }
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
            precondition(reopened.configurations.first?.components.count == 6)
            try reopened.delete(config.id)
            precondition(reopened.configurations.isEmpty)
        }
        let old = WatermarkConfiguration(name: "旧预设", basePreset: .standard, components: [])
        let oldData = try JSONEncoder().encode(old)
        let decodedOld = try JSONDecoder().decode(WatermarkConfiguration.self, from: oldData)
        precondition(decodedOld.templateLayout == nil && decodedOld.components.isEmpty,
                     "Existing custom presets must remain readable")
        if let path = ProcessInfo.processInfo.environment["SWIFTCULL_SEMI_SAMPLE"] {
            let sample = PhotoEntry(baseName: "sample", jpgPath: path, nefPath: nil, movPath: nil,
                                    jpgFileSize: 0, nefFileSize: nil, movFileSize: nil,
                                    fileDate: Date(), modificationDate: Date())
            for preset in WatermarkPreset.allCases {
                let builtIn = try SemiWatermarkRenderer.render(photo: sample, preset: preset,
                                                               sourcePath: path, matchOrientation: false,
                                                               maxPixelSize: 1200)
                let editing = try WatermarkCustomRenderer.render(photo: sample,
                                                                  configuration: .draft(from: preset),
                                                                  sourcePath: path, maxPixelSize: 1200)
                precondition(editing.tiffRepresentation == builtIn.tiffRepresentation,
                             "Real photo editor rendering differs from \(preset.rawValue)")
            }
        }
        print("Watermark smoke test passed: 15 presets × landscape/portrait, Nikon logo, custom layout, persistence, JPEG export")
    }
}
