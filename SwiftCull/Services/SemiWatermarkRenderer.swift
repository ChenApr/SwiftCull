import AppKit
import Accelerate
import ImageIO

/// Native implementation of the bundled semi-utils layouts. Dimensions and placements follow
/// the corresponding templates in semi-utils/config/templates (Apache-2.0).
enum SemiWatermarkRenderer {
    static func render(photo: PhotoEntry, preset: WatermarkPreset, sourcePath: String?,
                       matchOrientation: Bool, maxPixelSize: Int?) throws -> NSBitmapImageRep {
        guard let path = sourcePath ?? photo.watermarkSourcePath(preferRaw: false),
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            throw WatermarkError.unreadableImage
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        if let maxPixelSize {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        } else {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            options[kCGImageSourceThumbnailMaxPixelSize] = max(width, height)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw WatermarkError.unreadableImage
        }
        let metadata = Metadata(path: path, source: source, fallbackDate: photo.fileDate)
        let selected = preset.resolved(isPortrait: image.height > image.width,
                                       matchOrientation: matchOrientation)
        switch selected.layout {
        case .standard, .card, .nikonCard, .centerBrand:
            return try bordered(image, metadata: metadata, preset: selected)
        case .blur, .nikonBlur:
            return try blurred(image, metadata: metadata, nikon: selected.layout == .nikonBlur)
        case .cornerParameters:
            return try overlay(image) { canvas in
                let short = CGFloat(min(image.width, image.height))
                let height = selected.isPortraitPreset ? short * 0.03 : CGFloat(image.height) * 0.03
                let inset = CGFloat(image.height) * 0.05
                draw(metadata.parameters, x: canvas.width - inset, bottom: inset,
                     height: height, color: .white, weight: .bold, alignment: .right,
                     maxWidth: canvas.width * 0.9)
            }
        case .folderAndDate:
            return try overlay(image) { canvas in
                let short = CGFloat(min(image.width, image.height))
                let height = selected.isPortraitPreset ? short * 0.03 : CGFloat(image.height) * 0.03
                draw("\(metadata.folder)    \(metadata.date)", x: canvas.width * 0.93,
                     bottom: canvas.height * 0.02, height: height,
                     color: NSColor(calibratedRed: 232 / 255, green: 141 / 255,
                                    blue: 52 / 255, alpha: 1), weight: .regular,
                     alignment: .right, maxWidth: canvas.width * 0.85)
            }
        }
    }

    private static func bordered(_ image: CGImage, metadata: Metadata,
                                 preset: WatermarkPreset) throws -> NSBitmapImageRep {
        let portrait = preset.isPortraitPreset
        let short = CGFloat(min(image.width, image.height))
        let imageHeight = CGFloat(image.height)
        let isCard = preset.layout == .card || preset.layout == .nikonCard
        let isLogoOnly = preset.layout == .centerBrand
        let shadowRadius: CGFloat = isCard ? pixel(portrait ? short * 0.027 : 100) : 0
        let shadowPadding = shadowRadius * 2
        let shadowHeight = imageHeight + shadowPadding * 2
        let sideMargin: CGFloat = isCard ? (portrait && preset.layout == .card ? pixel(short * 0.027) : 100)
            : (isLogoOnly ? pixel(portrait ? short * 0.02 : imageHeight * 0.02) : 0)
        let topMargin: CGFloat = isCard ? sideMargin : 0
        let footer = pixel(portrait ? short * 0.13 : shadowHeight * 0.12)
        let finalBottomMargin: CGFloat = isCard ? pixel((portrait ? short : imageHeight) * 0.02) : 0
        let canvasWidth = CGFloat(image.width) + shadowPadding * 2 + sideMargin * 2
        let canvasHeight = shadowHeight + topMargin + footer + finalBottomMargin
        let canvasSize = CGSize(width: Int(canvasWidth), height: Int(canvasHeight))

        return try bitmap(size: canvasSize) { canvas in
            NSColor.white.setFill()
            canvas.fill()
            let photoRect = CGRect(x: sideMargin + shadowPadding,
                                   y: finalBottomMargin + footer + shadowPadding,
                                   width: CGFloat(image.width), height: CGFloat(image.height))
            let radius: CGFloat = isCard ? (portrait ? short * 0.01 : imageHeight * 0.01) : 0
            drawPhoto(image, in: photoRect, radius: radius,
                      shadowRadius: shadowRadius, shadowColor: .black)

            guard let logo = logo(for: metadata.make) else {
                drawFooterText(canvas: canvas, image: image, metadata: metadata,
                               portrait: portrait, card: isCard, logoRect: nil,
                               footer: footer, sideMargin: sideMargin,
                               bottomMargin: finalBottomMargin, logoOnly: isLogoOnly)
                return
            }
            if isLogoOnly {
                let height = portrait ? short * 0.09 : footer
                let aspect = logo.size.width / max(logo.size.height, 1)
                let rect = CGRect(x: canvas.midX - height * aspect / 2,
                                  y: finalBottomMargin + (footer - height) / 2,
                                  width: height * aspect, height: height)
                logo.draw(in: rect)
            } else {
                drawFooterText(canvas: canvas, image: image, metadata: metadata,
                               portrait: portrait, card: isCard, logoRect: logo,
                               footer: footer, sideMargin: sideMargin,
                               bottomMargin: finalBottomMargin, logoOnly: false)
            }
        }
    }

    private static func drawFooterText(canvas: CGRect, image: CGImage, metadata: Metadata,
                                       portrait: Bool, card: Bool, logoRect logo: NSImage?,
                                       footer: CGFloat, sideMargin: CGFloat,
                                       bottomMargin: CGFloat, logoOnly: Bool) {
        guard !logoOnly else { return }
        let short = CGFloat(min(image.width, image.height))
        let line = portrait ? short * 0.03 : footer * 0.3
        let gap = portrait ? short * 0.008 : footer * 0.05
        let boldLine = line * 1.13
        let fontScale: CGFloat = portrait ? 0.57 : 0.75
        let elementHeight = max(boldLine + line, boldLine + line) + gap
        let elementMargin = (footer - elementHeight) / 2
        let commonSpacing = canvas.width * 0.02
        let leftX = sideMargin + commonSpacing
        let rightEnd = canvas.width - sideMargin - commonSpacing
        let lowerBottom = bottomMargin + elementMargin
        let upperBottom = lowerBottom + line + gap

        draw(metadata.camera, x: leftX, bottom: upperBottom, height: boldLine * fontScale,
             color: .black, weight: .bold, alignment: .left,
             maxWidth: canvas.width * 0.44)
        draw(metadata.lens, x: leftX, bottom: lowerBottom, height: line * fontScale,
             color: darkText, weight: .light, alignment: .left,
             maxWidth: canvas.width * 0.44)

        let rightFont = font(size: boldLine * fontScale, weight: .bold)
        let rightBottomFont = font(size: line * fontScale, weight: .light)
        let rightWidth = max(measure(metadata.parameters, font: rightFont),
                             measure(metadata.date, font: rightBottomFont))
        let rightStart = rightEnd - rightWidth
        let rightAlignment: NSTextAlignment = (!card && !portrait) ? .left : .right
        let rightAnchor = rightAlignment == .left ? rightStart : rightEnd
        draw(metadata.parameters, x: rightAnchor, bottom: upperBottom, height: boldLine * fontScale,
             color: darkText, weight: .bold, alignment: rightAlignment,
             maxWidth: canvas.width * 0.44)
        draw(metadata.date, x: rightAnchor, bottom: lowerBottom, height: line * fontScale,
             color: darkText, weight: .light, alignment: rightAlignment,
             maxWidth: canvas.width * 0.44)

        if let logo {
            let delimiterWidth = max(1, CGFloat(image.width) * 0.003)
            let delimiterX = canvas.width - sideMargin - rightWidth
                - 2 * commonSpacing - delimiterWidth
            if !card {
                NSColor(calibratedRed: 216 / 255, green: 216 / 255,
                        blue: 214 / 255, alpha: 1).setFill()
                CGRect(x: delimiterX, y: bottomMargin + elementMargin - elementHeight * 0.05,
                       width: delimiterWidth, height: elementHeight * 1.1).fill()
            }
            let logoSize = elementHeight
            let rect = CGRect(x: delimiterX - commonSpacing - logoSize,
                              y: bottomMargin + elementMargin,
                              width: logoSize, height: logoSize)
            logo.draw(in: rect)
        }
    }

    private static func blurred(_ image: CGImage, metadata: Metadata,
                                nikon: Bool) throws -> NSBitmapImageRep {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let short = min(width, height)
        let canvasSize = CGSize(width: Int(width * 1.35), height: Int(height * 1.35))
        let blurRadius = short * 0.03
        let roundedRadius = short * 0.02
        let shadowRadius = short * 0.01
        let shadowPadding = shadowRadius * 2
        let cameraHeight = short * 0.04
        let parameterHeight = short * 0.03
        let spacing = short * 0.03
        let compositeHeight = height + shadowPadding * 2 + cameraHeight
            + parameterHeight + spacing * 2
        let bottom = (canvasSize.height - compositeHeight) / 2 - short * 0.03

        return try bitmap(size: canvasSize) { canvas in
            if let background = softBackground(image, radius: blurRadius) {
                background.draw(in: CGRect(x: (canvas.width - width * 2) / 2,
                                           y: (canvas.height - height * 2) / 2,
                                           width: width * 2, height: height * 2))
            }
            let photoRect = CGRect(x: (canvas.width - width) / 2,
                                   y: bottom + parameterHeight + cameraHeight
                                       + spacing * 2 + shadowPadding,
                                   width: width, height: height)
            drawPhoto(image, in: photoRect, radius: roundedRadius,
                      shadowRadius: shadowRadius, shadowColor: .black)
            let textCenter = canvas.midX
            let parameterBottom = bottom + shadowPadding
            let cameraBottom = parameterBottom + parameterHeight + spacing
            if nikon, let range = metadata.camera.range(of: "Z") {
                let before = String(metadata.camera[..<range.lowerBound])
                let after = String(metadata.camera[range.upperBound...])
                drawRichCamera(before: before, after: after, x: textCenter,
                               bottom: cameraBottom, height: cameraHeight * 0.75,
                               maxWidth: canvas.width * 0.85)
            } else {
                draw(metadata.camera, x: textCenter, bottom: cameraBottom,
                     height: cameraHeight * 0.75, color: .white, weight: .bold,
                     alignment: .center, maxWidth: canvas.width * 0.85)
            }
            draw(metadata.parameters, x: textCenter, bottom: parameterBottom,
                 height: parameterHeight * 0.75, color: .white, weight: .light,
                 alignment: .center, maxWidth: canvas.width * 0.85)
        }
    }

    private static func overlay(_ image: CGImage,
                                drawContent: (CGRect) -> Void) throws -> NSBitmapImageRep {
        try bitmap(size: CGSize(width: image.width, height: image.height)) { canvas in
            NSImage(cgImage: image, size: canvas.size).draw(in: canvas)
            drawContent(canvas)
        }
    }

    private static func bitmap(size: CGSize, drawContent: (CGRect) -> Void) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw WatermarkError.encodingFailed
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        drawContent(CGRect(origin: .zero, size: size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private static func drawPhoto(_ image: CGImage, in rect: CGRect,
                                  radius: CGFloat, shadowRadius: CGFloat,
                                  shadowColor: NSColor) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        if shadowRadius > 0 {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = shadowColor.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = shadowRadius
            shadow.shadowOffset = .zero
            shadow.set()
            NSColor.white.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSImage(cgImage: image, size: rect.size).draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func softBackground(_ image: CGImage, radius: CGFloat) -> NSImage? {
        // Blur a scaled image with vImage, then enlarge it behind the sharp photo.
        // This preserves the smooth semi-utils background without allocating a huge CI image.
        let scale = min(1, 900 / CGFloat(max(image.width, image.height)))
        let sampleWidth = max(1, Int(CGFloat(image.width) * scale))
        let sampleHeight = max(1, Int(CGFloat(image.height) * scale))
        guard let sourceBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: sampleWidth, pixelsHigh: sampleHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let targetBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: sampleWidth, pixelsHigh: sampleHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: sourceBitmap),
              let sourceData = sourceBitmap.bitmapData,
              let targetData = targetBitmap.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
            .draw(in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        var sourceBuffer = vImage_Buffer(data: sourceData, height: vImagePixelCount(sampleHeight),
                                         width: vImagePixelCount(sampleWidth),
                                         rowBytes: sourceBitmap.bytesPerRow)
        var targetBuffer = vImage_Buffer(data: targetData, height: vImagePixelCount(sampleHeight),
                                         width: vImagePixelCount(sampleWidth),
                                         rowBytes: targetBitmap.bytesPerRow)
        let suggested = max(3, Int(radius * scale * 4))
        let kernel = UInt32(suggested % 2 == 0 ? suggested + 1 : suggested)
        let result = vImageTentConvolve_ARGB8888(&sourceBuffer, &targetBuffer, nil, 0, 0,
                                                 kernel, kernel, nil,
                                                 vImage_Flags(kvImageEdgeExtend))
        guard result == kvImageNoError, let blurred = targetBitmap.cgImage else { return nil }
        return NSImage(cgImage: blurred, size: CGSize(width: image.width, height: image.height))
    }

    private static func pixel(_ value: CGFloat) -> CGFloat { CGFloat(Int(value)) }

    private static let darkText = NSColor(calibratedWhite: 0.14, alpha: 1)

    private static func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: max(7, size), weight: weight)
    }

    private static func measure(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func draw(_ text: String, x: CGFloat, bottom: CGFloat,
                             height: CGFloat, color: NSColor, weight: NSFont.Weight,
                             alignment: NSTextAlignment, maxWidth: CGFloat) {
        guard !text.isEmpty else { return }
        let targetFont = font(size: height, weight: weight)
        let measured = measure(text, font: targetFont)
        let adjustedFont = measured > maxWidth
            ? font(size: height * maxWidth / measured, weight: weight)
            : targetFont
        let attributes: [NSAttributedString.Key: Any] = [.font: adjustedFont, .foregroundColor: color]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let origin: CGFloat
        switch alignment {
        case .right: origin = x - textSize.width
        case .center: origin = x - textSize.width / 2
        default: origin = x
        }
        (text as NSString).draw(at: CGPoint(x: origin, y: bottom), withAttributes: attributes)
    }

    private static func drawRichCamera(before: String, after: String, x: CGFloat,
                                       bottom: CGFloat, height: CGFloat, maxWidth: CGFloat) {
        let fragments = [(before, NSColor.white), ("Z", NSColor.systemRed), (after, NSColor.white)]
        let targetFont = font(size: height, weight: .bold)
        let fullWidth = fragments.reduce(CGFloat.zero) { $0 + measure($1.0, font: targetFont) }
        let fittedFont = fullWidth > maxWidth ? font(size: height * maxWidth / fullWidth, weight: .bold) : targetFont
        let spacing = height * 0.05
        let width = fragments.reduce(CGFloat.zero) { $0 + measure($1.0, font: fittedFont) } + spacing * 2
        var currentX = x - width / 2
        for (fragment, color) in fragments {
            (fragment as NSString).draw(at: CGPoint(x: currentX, y: bottom),
                                        withAttributes: [.font: fittedFont, .foregroundColor: color])
            currentX += measure(fragment, font: fittedFont) + spacing
        }
    }

    private static func logo(for make: String) -> NSImage? {
        let known = ["nikon", "canon", "fujifilm", "sony", "leica_logo", "hasselblad",
                     "panasonic", "pentax", "ricoh", "olympus_blue_gold", "apple", "DJI", "xmage"]
        guard let name = known.first(where: {
            let token = $0.components(separatedBy: "_")[0].lowercased()
            return make.lowercased().contains(token)
        }) else { return nil }
        let file = name == "DJI" ? "DJI.jpg" : "\(name).png"
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("WatermarkLogos/\(file)"),
            Bundle.main.resourceURL?.appendingPathComponent(file),
            ProcessInfo.processInfo.environment["SWIFTCULL_WATERMARK_LOGOS_DIR"]
                .map { URL(fileURLWithPath: $0).appendingPathComponent(file) }
        ]
        return candidates.compactMap { $0 }.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            .flatMap(NSImage.init(contentsOf:))
    }

    private struct Metadata {
        let make: String
        let camera: String
        let lens: String
        let parameters: String
        let date: String
        let folder: String

        init(path: String, source: CGImageSource, fallbackDate: Date) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
            make = tiff?[kCGImagePropertyTIFFMake] as? String ?? ""
            let model = tiff?[kCGImagePropertyTIFFModel] as? String ?? "-"
            camera = model.replacingOccurrences(of: "_", with: "")
            lens = exif?[kCGImagePropertyExifLensModel] as? String ?? "-"

            let focal = Self.number(exif?["FocalLenIn35mmFilm" as CFString])
                ?? Self.number(exif?[kCGImagePropertyExifFocalLength]) ?? 0
            let focalText = focal > 0 ? "\(Int(focal.rounded()))mm" : "-"
            let aperture = Self.number(exif?[kCGImagePropertyExifFNumber]) ?? 0
            let apertureText = aperture > 0 ? String(format: "%.1f", aperture) : "-"
            let seconds = Self.number(exif?[kCGImagePropertyExifExposureTime]) ?? 0
            let shutterText: String
            if seconds > 0 && seconds < 1 {
                shutterText = "1/\(Int((1 / seconds).rounded()))"
            } else if seconds > 0 {
                shutterText = String(format: "%.1f", seconds)
            } else { shutterText = "-" }
            let iso: Int
            if let values = exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber] {
                iso = values.first?.intValue ?? 0
            } else { iso = 0 }
            parameters = "\(focalText) f/\(apertureText) \(shutterText)s ISO\(iso)"

            let rawDate = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
                ?? tiff?[kCGImagePropertyTIFFDateTime] as? String
            if let rawDate, rawDate.count >= 16 {
                let start = rawDate.prefix(10).replacingOccurrences(of: ":", with: "-")
                date = "\(start) \(rawDate.dropFirst(11).prefix(5))"
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                date = formatter.string(from: fallbackDate)
            }
            folder = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        }

        private static func number(_ value: Any?) -> Double? {
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String { return Double(string) }
            return nil
        }
    }
}
