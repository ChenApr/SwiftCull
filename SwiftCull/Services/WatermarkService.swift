import AppKit
import CoreImage
import ImageIO

/// Native renditions of the 15 named templates in semi-utils/config/templates.
/// Keeping the drawing in Swift lets previews and exports use the same renderer.
enum WatermarkPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard = "标准水印"
    case standardCard = "标准水印2"
    case nikonBlur = "尼康专用背景模糊"
    case blur = "背景模糊"
    case cornerParameters = "右下角参数"
    case folderAndDate = "文件夹名+右下角参数"
    case centerBrand = "logo居中"
    case standardPortrait = "标准水印（竖拍）"
    case standardCardPortrait = "标准水印2（竖拍）"
    case nikonBlurPortrait = "尼康专用背景模糊（竖拍）"
    case nikonPortrait = "尼康竖拍"
    case blurPortrait = "背景模糊（竖拍）"
    case cornerParametersPortrait = "右下角参数（竖拍）"
    case folderAndDatePortrait = "文件夹名+右下角参数（竖拍）"
    case centerBrandPortrait = "logo居中（竖拍）"

    var id: String { rawValue }

    static let landscapePresets: [WatermarkPreset] = [
        .standard, .standardCard, .nikonBlur, .blur,
        .cornerParameters, .folderAndDate, .centerBrand
    ]
    static let portraitPresets: [WatermarkPreset] = [
        .standardPortrait, .standardCardPortrait, .nikonBlurPortrait, .nikonPortrait,
        .blurPortrait, .cornerParametersPortrait, .folderAndDatePortrait, .centerBrandPortrait
    ]

    enum Layout: Equatable, Sendable {
        case standard, card, nikonCard, nikonBlur, blur, cornerParameters, folderAndDate, centerBrand
    }

    var layout: Layout {
        switch self {
        case .standard, .standardPortrait: return .standard
        case .standardCard, .standardCardPortrait: return .card
        case .nikonPortrait: return .nikonCard
        case .nikonBlur, .nikonBlurPortrait: return .nikonBlur
        case .blur, .blurPortrait: return .blur
        case .cornerParameters, .cornerParametersPortrait: return .cornerParameters
        case .folderAndDate, .folderAndDatePortrait: return .folderAndDate
        case .centerBrand, .centerBrandPortrait: return .centerBrand
        }
    }

    var isPortraitPreset: Bool { Self.portraitPresets.contains(self) }

    func resolved(isPortrait: Bool, matchOrientation: Bool) -> WatermarkPreset {
        guard matchOrientation else { return self }
        switch layout {
        case .standard: return isPortrait ? .standardPortrait : .standard
        case .card: return isPortrait ? .standardCardPortrait : .standardCard
        case .nikonCard: return .nikonPortrait
        case .nikonBlur: return isPortrait ? .nikonBlurPortrait : .nikonBlur
        case .blur: return isPortrait ? .blurPortrait : .blur
        case .cornerParameters: return isPortrait ? .cornerParametersPortrait : .cornerParameters
        case .folderAndDate: return isPortrait ? .folderAndDatePortrait : .folderAndDate
        case .centerBrand: return isPortrait ? .centerBrandPortrait : .centerBrand
        }
    }

    var detail: String {
        switch layout {
        case .standard: return "白色边框，显示相机、镜头、拍摄参数与日期"
        case .card, .nikonCard: return "圆角照片与宽留白，显示 EXIF 信息"
        case .nikonBlur: return "模糊照片背景，红色尼康风格点缀"
        case .blur: return "模糊照片背景，居中显示拍摄信息"
        case .cornerParameters: return "在照片右下角叠加拍摄参数"
        case .folderAndDate: return "在照片右下角显示文件夹名和日期"
        case .centerBrand: return "白色边框，底部居中显示相机品牌"
        }
    }
}

enum WatermarkError: LocalizedError {
    case unreadableImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "无法读取照片图像"
        case .encodingFailed: return "无法生成 JPEG"
        }
    }
}

enum WatermarkService {
    static func render(photo: PhotoEntry, preset: WatermarkPreset, sourcePath: String? = nil,
                       matchOrientation: Bool = false, maxPixelSize: Int? = nil) throws -> NSBitmapImageRep {
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

        let exif = PhotoExifInfo.load(from: path, fallbackDate: photo.fileDate)
        let width = image.width
        let height = image.height
        let chosenPreset = preset.resolved(isPortrait: height > width, matchOrientation: matchOrientation)
        let layout = chosenPreset.layout
        let portrait = chosenPreset.isPortraitPreset
        let shorterSide = CGFloat(min(width, height))
        let scale = CGFloat(width) / 3000
        let footer = max(64, Int(portrait ? shorterSide * 0.13 : CGFloat(height) * 0.12))
        let inset = max(18, Int(portrait ? shorterSide * 0.025 : CGFloat(width) * 0.045))
        let isBorder = layout == .standard || layout == .card || layout == .nikonCard || layout == .centerBrand
        let isBlur = layout == .blur || layout == .nikonBlur
        let isCard = layout == .card || layout == .nikonCard
        let outer = isCard ? max(24, Int(portrait ? shorterSide * 0.027 : CGFloat(width) * 0.035)) : 0
        let extraBottom = isCard ? max(12, Int((portrait ? shorterSide : CGFloat(height)) * 0.02)) : 0
        let canvasWidth = width + outer * 2
        let canvasHeight = height + (isBorder ? footer + extraBottom : 0) + outer * 2

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: canvasWidth, pixelsHigh: canvasHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw WatermarkError.encodingFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let canvas = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        (isBlur ? NSColor(calibratedWhite: 0.13, alpha: 1) : .white).setFill()
        canvas.fill()

        let nsImage = NSImage(cgImage: image, size: NSSize(width: width, height: height))
        if isBlur {
            let blurred = CIImage(cgImage: image).applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(8, CGFloat(width) * 0.025)
            ])
            if let backgroundImage = CIContext().createCGImage(blurred, from: CGRect(x: 0, y: 0, width: width, height: height)) {
                NSImage(cgImage: backgroundImage, size: NSSize(width: width, height: height))
                    .draw(in: canvas, from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                nsImage.draw(in: canvas, from: .zero, operation: .sourceOver, fraction: 0.6)
            }
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: canvas).fill()
            let photoWidth = CGFloat(width) * 0.68
            let photoHeight = photoWidth * CGFloat(height) / CGFloat(width)
            let photoRect = CGRect(x: (CGFloat(width) - photoWidth) / 2,
                                   y: CGFloat(height) * 0.04,
                                   width: photoWidth, height: photoHeight)
            nsImage.draw(in: photoRect, from: .zero, operation: .sourceOver, fraction: 1)
            let title = exif.camera ?? photo.baseName
            let parameterLine = parameters(exif)
            draw(title, atTop: CGFloat(height) * 0.05, x: CGFloat(width) / 2,
                 fontSize: max(18, 50 * scale), color: .white, alignment: .center, canvasHeight: CGFloat(canvasHeight), bold: true)
            draw(parameterLine, atTop: CGFloat(height) * 0.13, x: CGFloat(width) / 2,
                 fontSize: max(13, 32 * scale), color: .white, alignment: .center, canvasHeight: CGFloat(canvasHeight))
            if layout == .nikonBlur, title.localizedCaseInsensitiveContains("Nikon") {
                draw("NIKON", atTop: CGFloat(height) * 0.025, x: CGFloat(width) / 2,
                     fontSize: max(12, 24 * scale), color: .systemRed, alignment: .center, canvasHeight: CGFloat(canvasHeight), bold: true)
            }
            if layout == .nikonBlur {
                NSColor.systemRed.setFill()
                CGRect(x: CGFloat(width) * 0.46, y: CGFloat(height) * 0.83,
                       width: CGFloat(width) * 0.08, height: max(3, CGFloat(height) * 0.006)).fill()
            }
        } else {
            let imageRect = CGRect(x: outer, y: isBorder ? footer + outer + extraBottom : 0, width: width, height: height)
            if isCard {
                let radius = max(10, CGFloat(width) * 0.012)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
                shadow.shadowBlurRadius = max(10, CGFloat(width) * 0.015)
                shadow.shadowOffset = NSSize(width: 0, height: -max(3, CGFloat(width) * 0.004))
                shadow.set()
                NSColor.white.setFill()
                NSBezierPath(roundedRect: imageRect, xRadius: radius, yRadius: radius).fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: imageRect, xRadius: radius, yRadius: radius).addClip()
            }
            nsImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
            if isCard {
                NSGraphicsContext.restoreGraphicsState()
            }

            if isBorder {
                let left = CGFloat(outer + inset)
                let right = CGFloat(canvasWidth - outer - inset)
                let top = CGFloat(outer + height) + CGFloat(footer) * (portrait ? 0.08 : 0.2)
                let large = max(14, CGFloat(footer) * 0.23)
                let small = max(11, CGFloat(footer) * 0.17)
                if layout == .centerBrand {
                    let brand = (exif.camera ?? "CAMERA").components(separatedBy: " ").first ?? "CAMERA"
                    draw(brand.uppercased(), atTop: top, x: CGFloat(canvasWidth) / 2,
                         fontSize: large * 1.2, color: .black, alignment: .center,
                         canvasHeight: CGFloat(canvasHeight), bold: true)
                } else if portrait {
                    let availableWidth = CGFloat(canvasWidth - 2 * inset)
                    draw(exif.camera ?? "相机", atTop: top, x: CGFloat(canvasWidth) / 2,
                         fontSize: large, color: .black, alignment: .center,
                         canvasHeight: CGFloat(canvasHeight), maxWidth: availableWidth, bold: true)
                    draw(exif.lens ?? "", atTop: top + large * 1.05, x: CGFloat(canvasWidth) / 2,
                         fontSize: small, color: .darkGray, alignment: .center,
                         canvasHeight: CGFloat(canvasHeight), maxWidth: availableWidth)
                    draw(parameters(exif), atTop: top + large * 1.85, x: CGFloat(canvasWidth) / 2,
                         fontSize: small, color: .darkGray, alignment: .center,
                         canvasHeight: CGFloat(canvasHeight), maxWidth: availableWidth)
                    draw(exif.capturedAt ?? "", atTop: top + large * 2.65, x: CGFloat(canvasWidth) / 2,
                         fontSize: small * 0.85, color: .darkGray, alignment: .center,
                         canvasHeight: CGFloat(canvasHeight), maxWidth: availableWidth)
                    if layout == .nikonCard {
                        NSColor.systemRed.setFill()
                        CGRect(x: CGFloat(canvasWidth) * 0.46, y: CGFloat(outer + extraBottom + footer) * 0.25,
                               width: CGFloat(canvasWidth) * 0.08, height: max(3, shorterSide * 0.004)).fill()
                    }
                } else {
                    draw(exif.camera ?? "相机", atTop: top, x: left, fontSize: large,
                         color: .black, alignment: .left, canvasHeight: CGFloat(canvasHeight), bold: true)
                    draw(exif.lens ?? "", atTop: top + large * 1.45, x: left,
                         fontSize: small, color: .darkGray, alignment: .left, canvasHeight: CGFloat(canvasHeight))
                    draw(parameters(exif), atTop: top, x: right, fontSize: large * 0.85,
                         color: .black, alignment: .right, canvasHeight: CGFloat(canvasHeight), bold: true)
                    draw(exif.capturedAt ?? "", atTop: top + large * 1.45, x: right,
                         fontSize: small, color: .darkGray, alignment: .right, canvasHeight: CGFloat(canvasHeight))
                }
            } else {
                let label = layout == .folderAndDate
                    ? "\(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent)  \(exif.capturedAt ?? "")"
                    : parameters(exif)
                let fontSize = max(15, portrait ? shorterSide * 0.03 : CGFloat(height) * 0.026)
                let padding = fontSize * 0.55
                let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
                let textWidth = min((label as NSString).size(withAttributes: [.font: font]).width, CGFloat(width) * 0.88)
                let plate = CGRect(x: CGFloat(width) - textWidth - padding * 3,
                                   y: (portrait ? shorterSide : CGFloat(height)) * 0.045,
                                   width: textWidth + padding * 2,
                                   height: fontSize * 1.7)
                NSColor.black.withAlphaComponent(0.58).setFill()
                NSBezierPath(roundedRect: plate, xRadius: padding * 0.4, yRadius: padding * 0.4).fill()
                draw(label, atTop: CGFloat(height) - plate.maxY + padding * 0.3,
                     x: plate.maxX - padding, fontSize: fontSize,
                     color: layout == .folderAndDate ? NSColor(calibratedRed: 0.91, green: 0.55, blue: 0.2, alpha: 1) : .white,
                     alignment: .right, canvasHeight: CGFloat(canvasHeight), bold: true)
            }
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    static func jpegData(photo: PhotoEntry, preset: WatermarkPreset, sourcePath: String? = nil,
                         matchOrientation: Bool = false) throws -> Data {
        guard let data = try render(photo: photo, preset: preset, sourcePath: sourcePath,
                                    matchOrientation: matchOrientation).representation(
            using: .jpeg, properties: [.compressionFactor: 0.92]
        ) else { throw WatermarkError.encodingFailed }
        return data
    }

    static func previewData(photo: PhotoEntry, preset: WatermarkPreset, sourcePath: String? = nil,
                            matchOrientation: Bool = false) throws -> Data {
        guard let data = try render(photo: photo, preset: preset, sourcePath: sourcePath,
                                    matchOrientation: matchOrientation, maxPixelSize: 1200).representation(
            using: .jpeg, properties: [.compressionFactor: 0.8]
        ) else { throw WatermarkError.encodingFailed }
        return data
    }

    static func previewData(photo: PhotoEntry, configuration: WatermarkConfiguration,
                            sourcePath: String? = nil) throws -> Data {
        guard let data = try WatermarkCustomRenderer.render(photo: photo, configuration: configuration,
                                                            sourcePath: sourcePath, maxPixelSize: 1200)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw WatermarkError.encodingFailed
        }
        return data
    }

    static func jpegData(photo: PhotoEntry, configuration: WatermarkConfiguration,
                         sourcePath: String? = nil) throws -> Data {
        guard let data = try WatermarkCustomRenderer.render(photo: photo, configuration: configuration,
                                                            sourcePath: sourcePath)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw WatermarkError.encodingFailed
        }
        return data
    }

    @discardableResult
    static func export(photo: PhotoEntry, preset: WatermarkPreset, sourcePath: String,
                       matchOrientation: Bool, to directory: URL) throws -> URL {
        let data = try jpegData(photo: photo, preset: preset, sourcePath: sourcePath,
                                matchOrientation: matchOrientation)
        return try write(data, sourcePath: sourcePath, to: directory)
    }

    @discardableResult
    static func export(photo: PhotoEntry, configuration: WatermarkConfiguration,
                       sourcePath: String, to directory: URL) throws -> URL {
        let data = try jpegData(photo: photo, configuration: configuration, sourcePath: sourcePath)
        return try write(data, sourcePath: sourcePath, to: directory)
    }

    private static func write(_ data: Data, sourcePath: String, to directory: URL) throws -> URL {
        let source = URL(fileURLWithPath: sourcePath)
        let name = source.deletingPathExtension().lastPathComponent + "_watermark"
        let fileManager = FileManager.default
        let temporary = directory.appendingPathComponent(".swiftcull-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        defer { try? fileManager.removeItem(at: temporary) }

        var suffix = 1
        while true {
            let candidateName = suffix == 1 ? name : "\(name)_\(suffix)"
            let destination = directory.appendingPathComponent(candidateName).appendingPathExtension("jpg")
            do {
                try fileManager.moveItem(at: temporary, to: destination)
                return destination
            } catch {
                guard fileManager.fileExists(atPath: destination.path) else { throw error }
                suffix += 1
            }
        }
    }

    private static func parameters(_ info: PhotoExifInfo) -> String {
        [info.focalLength, info.aperture, info.shutterSpeed, info.iso]
            .compactMap { $0 }.joined(separator: "  ").nilIfEmpty ?? "拍摄参数不可用"
    }

    private static func draw(_ text: String, atTop top: CGFloat, x: CGFloat, fontSize: CGFloat,
                             color: NSColor, alignment: NSTextAlignment, canvasHeight: CGFloat,
                             maxWidth: CGFloat? = nil, bold: Bool = false) {
        guard !text.isEmpty else { return }
        let weight: NSFont.Weight = bold ? .semibold : .regular
        var fittedSize = fontSize
        if let maxWidth {
            let measured = (text as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: weight)
            ]).width
            if measured > maxWidth {
                fittedSize = max(fontSize * 0.7, fontSize * maxWidth / measured)
            }
        }
        let font = NSFont.systemFont(ofSize: fittedSize, weight: weight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let originX: CGFloat
        switch alignment {
        case .right: originX = x - size.width
        case .center: originX = x - size.width / 2
        default: originX = x
        }
        if let maxWidth {
            let clipX: CGFloat
            switch alignment {
            case .right: clipX = x - maxWidth
            case .center: clipX = x - maxWidth / 2
            default: clipX = x
            }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: CGRect(x: clipX, y: canvasHeight - top - size.height,
                                      width: maxWidth, height: size.height)).addClip()
        }
        (text as NSString).draw(at: CGPoint(x: originX, y: canvasHeight - top - size.height), withAttributes: attributes)
        if maxWidth != nil { NSGraphicsContext.restoreGraphicsState() }
    }
}
