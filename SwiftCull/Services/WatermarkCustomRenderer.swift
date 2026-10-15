import AppKit
import CoreImage
import ImageIO

enum WatermarkCustomRenderer {
    struct PreparedSource {
        let path: String
        let semi: SemiWatermarkRenderer.PreparedSource
        let exif: PhotoExifInfo
    }

    static func prepare(photo: PhotoEntry, sourcePath: String? = nil,
                        maxPixelSize: Int? = nil) throws -> PreparedSource {
        guard let path = sourcePath ?? photo.watermarkSourcePath(preferRaw: false) else {
            throw WatermarkError.unreadableImage
        }
        let semi = try SemiWatermarkRenderer.prepare(photo: photo, sourcePath: path,
                                                     maxPixelSize: maxPixelSize)
        return PreparedSource(path: path, semi: semi,
                              exif: PhotoExifInfo.load(from: path, fallbackDate: photo.fileDate))
    }

    static func render(photo: PhotoEntry, configuration: WatermarkConfiguration,
                       sourcePath: String? = nil, maxPixelSize: Int? = nil) throws -> NSBitmapImageRep {
        let prepared = try prepare(photo: photo, sourcePath: sourcePath, maxPixelSize: maxPixelSize)
        return try render(prepared: prepared, configuration: configuration)
    }

    static func render(prepared: PreparedSource,
                       configuration: WatermarkConfiguration) throws -> NSBitmapImageRep {
        if configuration.templateLayout == true {
            return try SemiWatermarkRenderer.render(prepared: prepared.semi,
                                                    preset: configuration.basePreset,
                                                    matchOrientation: configuration.matchOrientation == true,
                                                    configuration: configuration)
        }
        let path = prepared.path
        let cgImage = prepared.semi.image
        let exif = prepared.exif
        let short = CGFloat(min(cgImage.width, cgImage.height))
        let padding = max(0, short * CGFloat(configuration.paddingPercent / 100))
        let footer = max(0, short * CGFloat(configuration.footerPercent / 100))
        let width = cgImage.width + Int(padding * 2)
        let height = cgImage.height + Int(padding * 2 + footer)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw WatermarkError.encodingFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let color = NSColor.watermarkHex(configuration.backgroundHex) ?? .white
        color.setFill()
        canvas.fill()
        if configuration.background == .blurred {
            let blurred = CIImage(cgImage: cgImage).applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(8, short * 0.03)
            ])
            if let background = CIContext().createCGImage(blurred, from: CGRect(
                x: 0, y: 0, width: cgImage.width, height: cgImage.height
            )) {
                NSImage(cgImage: background, size: canvas.size).draw(in: canvas)
                color.withAlphaComponent(0.45).setFill()
                canvas.fill()
            }
        }

        let photoRect = CGRect(x: padding, y: padding + footer,
                               width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let radius = short * CGFloat(configuration.cornerRadiusPercent / 100)
        if configuration.shadow {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = max(6, short * 0.015)
            shadow.shadowOffset = NSSize(width: 0, height: -short * 0.004)
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: photoRect, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: photoRect, xRadius: radius, yRadius: radius).addClip()
        NSImage(cgImage: cgImage, size: photoRect.size).draw(in: photoRect)
        NSGraphicsContext.restoreGraphicsState()

        for position in WatermarkComponent.Position.allCases {
            let components = configuration.components.filter { $0.position == position }
            guard !components.isEmpty else { continue }
            draw(components, at: position, in: photoRect, canvas: canvas, footer: footer,
                 short: short, exif: exif, path: path)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private static func draw(_ components: [WatermarkComponent], at position: WatermarkComponent.Position,
                             in photoRect: CGRect, canvas: CGRect, footer: CGFloat, short: CGFloat,
                             exif: PhotoExifInfo, path: String) {
        let isFooter = position.isFooter
        guard !isFooter || footer > 0 else { return }
        let left = position == .topLeft || position == .bottomLeft || position == .footerLeft
        let right = position == .topRight || position == .bottomRight || position == .footerRight
        let alignment: NSTextAlignment = left ? .left : (right ? .right : .center)
        let x: CGFloat = left ? photoRect.minX + short * 0.025
            : (right ? photoRect.maxX - short * 0.025 : photoRect.midX)
        let maxWidth = isFooter ? canvas.width * (alignment == .center ? 0.85 : 0.43) : photoRect.width * 0.88
        let bottom = position == .bottomLeft || position == .bottomCenter || position == .bottomRight
        let anchor = isFooter ? photoRect.minY - footer + short * 0.015
            : (bottom ? photoRect.minY + short * 0.03 : photoRect.maxY - short * 0.03)
        let lines = components.compactMap { component -> (WatermarkComponent, String)? in
            let value = text(for: component, exif: exif, path: path)
            return value.isEmpty && component.kind != .logo ? nil : (component, value)
        }
        let totalHeight = lines.reduce(CGFloat.zero) { $0 + short * CGFloat($1.0.fontPercent / 100) * 1.32 }
        var y = (bottom || isFooter) ? anchor + totalHeight : anchor
        for (component, value) in lines {
            let size = max(7, short * CGFloat(component.fontPercent / 100))
            if component.kind == .logo {
                y -= size * 1.32
                let logo = component.imageData.flatMap(NSImage.init(data:))
                    ?? SemiWatermarkRenderer.logo(for: exif.camera ?? "")
                if let logo {
                    let aspect = logo.size.width / max(logo.size.height, 1)
                    let width = min(maxWidth, size * aspect)
                    let originX = left ? x : (right ? x - width : x - width / 2)
                    logo.draw(in: CGRect(x: originX, y: y, width: width, height: size))
                }
                continue
            }
            let weight: NSFont.Weight = component.bold ? .semibold : .regular
            let font = WatermarkFont.resolve(id: component.fontID, size: size, weight: weight)
            let color = NSColor.watermarkHex(component.colorHex) ?? (isFooter ? .black : .white)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let rawWidth = (value as NSString).size(withAttributes: attributes).width
            let fittedFont = rawWidth > maxWidth
                ? WatermarkFont.resolve(id: component.fontID, size: max(6, size * maxWidth / rawWidth), weight: weight)
                : font
            let fittedAttributes: [NSAttributedString.Key: Any] = [.font: fittedFont, .foregroundColor: color]
            let textSize = (value as NSString).size(withAttributes: fittedAttributes)
            let lineHeight = size * 1.32
            y -= lineHeight
            let originX = left ? x : (right ? x - textSize.width : x - textSize.width / 2)
            if !isFooter {
                let shadow = NSShadow()
                shadow.shadowColor = .black.withAlphaComponent(0.75)
                shadow.shadowBlurRadius = max(2, size * 0.25)
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                (value as NSString).draw(at: CGPoint(x: originX, y: y), withAttributes: fittedAttributes.merging([.shadow: shadow]) { _, new in new })
            } else {
                (value as NSString).draw(at: CGPoint(x: originX, y: y), withAttributes: fittedAttributes)
            }
        }
    }

    private static func text(for component: WatermarkComponent, exif: PhotoExifInfo, path: String) -> String {
        switch component.kind {
        case .camera: return exif.camera ?? "相机"
        case .lens: return exif.lens ?? ""
        case .parameters:
            return [exif.focalLength, exif.aperture, exif.shutterSpeed, exif.iso]
                .compactMap { $0 }.joined(separator: "  ").nilIfEmpty ?? "拍摄参数不可用"
        case .date: return exif.capturedAt ?? ""
        case .folder: return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        case .folderAndDate:
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            return "\(folder)    \(exif.capturedAt ?? "")"
        case .logo: return ""
        case .customText: return component.text
        }
    }
}

extension NSColor {
    static func watermarkHex(_ value: String) -> NSColor? {
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard hex.count == 6, let number = Int(hex, radix: 16) else { return nil }
        return NSColor(calibratedRed: CGFloat((number >> 16) & 0xff) / 255,
                       green: CGFloat((number >> 8) & 0xff) / 255,
                       blue: CGFloat(number & 0xff) / 255, alpha: 1)
    }

    var watermarkHexString: String {
        guard let rgb = usingColorSpace(.deviceRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255),
                      Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}
