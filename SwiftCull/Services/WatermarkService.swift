import AppKit
import CoreImage
import ImageIO

/// Native renditions of the seven layouts shown in semi-utils' sample presets.
/// Keeping the drawing in Swift lets previews and exports use the same renderer.
enum WatermarkPreset: String, CaseIterable, Identifiable, Sendable {
    case standard = "经典 EXIF 边框"
    case standardCard = "圆角留白边框"
    case nikonBlur = "尼康风格模糊背景"
    case blur = "模糊背景"
    case cornerParameters = "右下角参数"
    case folderAndDate = "文件夹名与日期"
    case centerBrand = "居中品牌边框"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .standard: return "白色边框，显示相机、镜头、拍摄参数与日期"
        case .standardCard: return "圆角照片和宽留白，适合分享"
        case .nikonBlur: return "模糊照片背景，突出相机与拍摄参数"
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
                       maxPixelSize: Int? = nil) throws -> NSBitmapImageRep {
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
        let scale = CGFloat(width) / 3000
        let footer = max(64, Int(CGFloat(height) * 0.12))
        let inset = max(18, Int(CGFloat(width) * 0.045))
        let isBorder = preset == .standard || preset == .standardCard || preset == .centerBrand
        let isBlur = preset == .blur || preset == .nikonBlur
        let outer = preset == .standardCard ? max(24, Int(CGFloat(width) * 0.035)) : 0
        let canvasWidth = width + outer * 2
        let canvasHeight = height + (isBorder ? footer : 0) + outer * 2

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
            if preset == .nikonBlur, title.localizedCaseInsensitiveContains("Nikon") {
                draw("NIKON", atTop: CGFloat(height) * 0.025, x: CGFloat(width) / 2,
                     fontSize: max(12, 24 * scale), color: .systemRed, alignment: .center, canvasHeight: CGFloat(canvasHeight), bold: true)
            }
            if preset == .nikonBlur {
                NSColor.systemRed.setFill()
                CGRect(x: CGFloat(width) * 0.46, y: CGFloat(height) * 0.83,
                       width: CGFloat(width) * 0.08, height: max(3, CGFloat(height) * 0.006)).fill()
            }
        } else {
            let imageRect = CGRect(x: outer, y: isBorder ? footer + outer : 0, width: width, height: height)
            if preset == .standardCard {
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
            if preset == .standardCard {
                NSGraphicsContext.restoreGraphicsState()
            }

            if isBorder {
                let left = CGFloat(outer + inset)
                let right = CGFloat(canvasWidth - outer - inset)
                let top = CGFloat(outer + height) + CGFloat(footer) * 0.2
                let large = max(14, CGFloat(footer) * 0.23)
                let small = max(11, CGFloat(footer) * 0.17)
                if preset == .centerBrand {
                    let brand = (exif.camera ?? "CAMERA").components(separatedBy: " ").first ?? "CAMERA"
                    draw(brand.uppercased(), atTop: top, x: CGFloat(canvasWidth) / 2,
                         fontSize: large * 1.2, color: .black, alignment: .center,
                         canvasHeight: CGFloat(canvasHeight), bold: true)
                } else if height > width {
                    draw(exif.camera ?? "相机", atTop: top, x: CGFloat(canvasWidth) / 2,
                         fontSize: large, color: .black, alignment: .center,
                         canvasHeight: CGFloat(canvasHeight), bold: true)
                    draw(parameters(exif), atTop: top + large * 1.25, x: CGFloat(canvasWidth) / 2,
                         fontSize: small, color: .darkGray, alignment: .center,
                         canvasHeight: CGFloat(canvasHeight))
                    draw(exif.capturedAt ?? "", atTop: top + large * 2.25, x: CGFloat(canvasWidth) / 2,
                         fontSize: small * 0.85, color: .darkGray, alignment: .center,
                         canvasHeight: CGFloat(canvasHeight))
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
                let label = preset == .folderAndDate
                    ? "\(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent)  \(exif.capturedAt ?? "")"
                    : parameters(exif)
                let fontSize = max(15, CGFloat(height) * 0.026)
                let padding = fontSize * 0.55
                let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
                let textWidth = min((label as NSString).size(withAttributes: [.font: font]).width, CGFloat(width) * 0.88)
                let plate = CGRect(x: CGFloat(width) - textWidth - padding * 3,
                                   y: CGFloat(height) * 0.045, width: textWidth + padding * 2,
                                   height: fontSize * 1.7)
                NSColor.black.withAlphaComponent(0.58).setFill()
                NSBezierPath(roundedRect: plate, xRadius: padding * 0.4, yRadius: padding * 0.4).fill()
                draw(label, atTop: CGFloat(height) - plate.maxY + padding * 0.3,
                     x: plate.maxX - padding, fontSize: fontSize,
                     color: preset == .folderAndDate ? NSColor(calibratedRed: 0.91, green: 0.55, blue: 0.2, alpha: 1) : .white,
                     alignment: .right, canvasHeight: CGFloat(canvasHeight), bold: true)
            }
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    static func jpegData(photo: PhotoEntry, preset: WatermarkPreset, sourcePath: String? = nil) throws -> Data {
        guard let data = try render(photo: photo, preset: preset, sourcePath: sourcePath).representation(
            using: .jpeg, properties: [.compressionFactor: 0.92]
        ) else { throw WatermarkError.encodingFailed }
        return data
    }

    static func previewData(photo: PhotoEntry, preset: WatermarkPreset, sourcePath: String? = nil) throws -> Data {
        guard let data = try render(photo: photo, preset: preset, sourcePath: sourcePath, maxPixelSize: 1200).representation(
            using: .jpeg, properties: [.compressionFactor: 0.8]
        ) else { throw WatermarkError.encodingFailed }
        return data
    }

    private static func parameters(_ info: PhotoExifInfo) -> String {
        [info.focalLength, info.aperture, info.shutterSpeed, info.iso]
            .compactMap { $0 }.joined(separator: "  ").nilIfEmpty ?? "拍摄参数不可用"
    }

    private static func draw(_ text: String, atTop top: CGFloat, x: CGFloat, fontSize: CGFloat,
                             color: NSColor, alignment: NSTextAlignment, canvasHeight: CGFloat,
                             bold: Bool = false) {
        guard !text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: fontSize, weight: bold ? .semibold : .regular)
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
        (text as NSString).draw(at: CGPoint(x: originX, y: canvasHeight - top - size.height), withAttributes: attributes)
    }
}
