import AppKit
import ImageIO

enum PhotoBorderSmoke {
    private static func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> NSColor {
        // colorAt reports calibrated RGB even for tagged sRGB bitmaps on macOS.
        // Interpret the raw samples in the bitmap's actual profile before comparing.
        var values = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&values, atX: x, y: y)
        let maximum = CGFloat((1 << bitmap.bitsPerSample) - 1)
        var components = values.map { CGFloat($0) / maximum }
        if !bitmap.hasAlpha { components.append(1) }
        return NSColor(colorSpace: bitmap.colorSpace, components: &components,
                       count: bitmap.colorSpace.numberOfColorComponents + 1).usingColorSpace(.sRGB)!
    }

    static func run(in directory: URL) async throws {
        // Integer geometry must preserve every source pixel and symmetric margins,
        // including odd dimensions, zero-width borders and mixed orientations.
        for size in [CGSize(width: 6000, height: 4000), CGSize(width: 4001, height: 6001),
                     CGSize(width: 1320, height: 100), CGSize(width: 81, height: 121)] {
            for aspect in PhotoBorderConfiguration.Aspect.allCases {
                for percent in [0.0, PhotoBorderConfiguration().widthPercent, 15.0] {
                    let config = PhotoBorderConfiguration(aspect: aspect, widthPercent: percent)
                    let layout = config.layout(photoSize: size)
                    precondition(layout.photoRect.size == size)
                    precondition(layout.photoRect.minX == layout.canvas.width - layout.photoRect.maxX)
                    precondition(layout.photoRect.minY == layout.canvas.height - layout.photoRect.maxY)
                    if let ratio = aspect.ratio {
                        precondition(abs(layout.canvas.width - layout.canvas.height * ratio) <= 3)
                    } else {
                        precondition(layout.photoRect.minX == layout.photoRect.minY)
                    }
                }
            }
        }
        let reference = PhotoBorderConfiguration(aspect: .square).layout(photoSize: CGSize(width: 1208, height: 800))
        precondition(reference.canvas == CGSize(width: 1320, height: 1320))
        precondition(reference.photoRect.minX == 56)

        let context = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 400, width: 1200, height: 400))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
        let image = context.makeImage()!
        let source = directory.appendingPathComponent("border-source.jpg")
        let destination = CGImageDestinationCreateWithURL(source as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        let photo = PhotoEntry(baseName: "border-source", jpgPath: source.path, nefPath: nil, movPath: nil,
                               jpgFileSize: nil, nefFileSize: nil, movFileSize: nil,
                               fileDate: Date(), modificationDate: Date())
        let sourceData = try Data(contentsOf: source)
        let prepared = try WatermarkCustomRenderer.prepare(photo: photo)
        precondition(prepared.nativePixelSize == CGSize(width: 800, height: 1200))
        precondition(prepared.semi.image.width == 800 && prepared.semi.image.height == 1200)
        for aspect in PhotoBorderConfiguration.Aspect.allCases {
            var item = WatermarkReviewItem(photo: photo, sourcePath: source.path)
            item.choice = .border
            item.border = PhotoBorderConfiguration(aspect: aspect, widthPercent: 5, colorHex: "#CCDBC7")
            let request = try WatermarkReviewPlan.request(for: item, configurations: [])
            let base = try WatermarkService.renderBase(prepared: prepared, style: request.style, matchOrientation: false)
            let layout = item.border.layout(photoSize: prepared.nativePixelSize)
            precondition(base.bitmap.pixelsWide == Int(layout.canvas.width))
            precondition(base.bitmap.pixelsHigh == Int(layout.canvas.height))
            precondition(base.photoRect.size == CGSize(width: 800, height: 1200))
            let margin = pixel(base.bitmap, x: 0, y: 0)
            let expectedMargin = item.border.color
            precondition(abs(margin.redComponent - expectedMargin.redComponent) < 0.02)
            precondition(abs(margin.greenComponent - expectedMargin.greenComponent) < 0.02)
            precondition(abs(margin.blueComponent - expectedMargin.blueComponent) < 0.02)
            var roundTrip = item.border
            roundTrip.setColor(roundTrip.color)
            precondition(roundTrip.colorHex == item.border.colorHex)
            // Sample both sides of the upright source after EXIF rotation; the
            // native photo must be unchanged, including its color orientation.
            let native = NSBitmapImageRep(cgImage: prepared.semi.image)
            for point in [(100, 100), (700, 1100)] {
                let original = pixel(native, x: point.0, y: point.1)
                let actual = pixel(base.bitmap, x: point.0 + Int(layout.photoRect.minX),
                                   y: point.1 + Int(layout.photoRect.minY))
                precondition(abs(original.redComponent - actual.redComponent) < 0.02)
                precondition(abs(original.blueComponent - actual.blueComponent) < 0.02)
            }
            let preview = try WatermarkService.previewData(request: request, prepared: prepared)
            let fromBase = try WatermarkService.previewData(prepared: prepared, base: base, overlays: [])
            precondition(preview == fromBase)
            let export = try WatermarkService.export(request: request, to: directory)
            let export2 = try WatermarkService.export(request: request, to: directory)
            precondition(export != export2 && export.lastPathComponent.contains("_border"))
            let exportedSource = CGImageSourceCreateWithURL(export as CFURL, nil)!
            let exported = CGImageSourceCreateImageAtIndex(exportedSource, 0, nil)!
            precondition(exported.width == base.bitmap.pixelsWide && exported.height == base.bitmap.pixelsHigh)
            let exportedMargin = pixel(NSBitmapImageRep(cgImage: exported), x: 0, y: 0)
            precondition(abs(exportedMargin.redComponent - expectedMargin.redComponent) < 0.025)
            precondition(abs(exportedMargin.greenComponent - expectedMargin.greenComponent) < 0.025)
            precondition(abs(exportedMargin.blueComponent - expectedMargin.blueComponent) < 0.025)

            var preset = WatermarkConfiguration(name: "边框 \(aspect.title)", basePreset: .standard,
                                                components: [], border: item.border)
            preset.components = [WatermarkComponent(kind: .customText, position: .bottomCenter,
                                                     text: "Signature", colorHex: "#FFFFFF")]
            let folder = directory.appendingPathComponent("border-presets")
            let presetToSave = preset
            let saved = try await MainActor.run {
                let store = WatermarkPresetStore(directory: folder)
                try store.save(presetToSave)
                return WatermarkPresetStore(directory: folder).configurations.first { $0.id == presetToSave.id }!
            }
            let configured = try WatermarkCustomRenderer.render(prepared: prepared, configuration: saved)
            item.choice = .custom(saved.id)
            let configuredRequest = try WatermarkReviewPlan.request(for: item, configurations: [saved])
            let configuredRender = try WatermarkService.render(prepared: prepared, request: configuredRequest)
            precondition(configured.tiffRepresentation == configuredRender.tiffRepresentation)

            // Changing one photo's saved border keeps its signature and leaves the saved preset alone.
            var draft = saved
            draft.border?.colorHex = "#000000"
            item.customDraft = draft
            let edited = try WatermarkReviewPlan.request(for: item, configurations: [saved])
            guard case .custom(let editedConfig) = edited.style else { fatalError("Lost per-photo draft") }
            precondition(editedConfig.border?.colorHex == "#000000" && editedConfig.components == saved.components)
            precondition(saved.border?.colorHex == "#CCDBC7")

            var excluded = item
            excluded.include = false
            excluded.choice = .builtIn(.blur)
            var batch = [item, excluded, WatermarkReviewItem(photo: photo, sourcePath: source.path)]
            WatermarkReviewPlan.applyStyle(from: item, to: &batch)
            precondition(batch[1].choice == .builtIn(.blur) && !batch[1].include)
            precondition(batch[2].choice == item.choice && batch[2].customDraft == draft)
            let requests = try WatermarkReviewPlan.requests(from: batch, configurations: [saved])
            precondition(requests.count == 2)
        }
        var cropped = photo
        cropped.cropRect = CropRect(x: 0.25, y: 0, width: 0.5, height: 1)
        let cropSource = try WatermarkCustomRenderer.prepare(photo: cropped)
        precondition(cropSource.nativePixelSize == CGSize(width: 400, height: 1200))
        let cropBase = try PhotoBorderRenderer.render(image: cropSource.semi.image, configuration: .init())
        precondition(cropBase.photoRect.width == 400 && cropBase.photoRect.height == 1200)
        let noMargin = try PhotoBorderRenderer.render(image: image,
            configuration: .init(aspect: .original, widthPercent: 0))
        precondition(noMargin.photoRect == CGRect(x: 0, y: 0, width: 1200, height: 800))
        precondition((try? PhotoBorderRenderer.render(image: image,
            configuration: .init(widthPercent: .nan))) == nil)
        precondition((try? PhotoBorderRenderer.render(image: image,
            configuration: .init(colorHex: "invalid"))) == nil)
        let sourceAfterExport = try Data(contentsOf: source)
        precondition(sourceAfterExport == sourceData, "Border export modified the source")
        print("Border smoke passed: seven ratios, exact centering, EXIF rotation, native pixels, crop, color, presets, per-photo drafts, checked-only sync, preview/export")
    }
}
