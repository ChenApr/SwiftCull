import AppKit
import Accelerate
import ImageIO

/// Native implementation of the bundled semi-utils layouts. Dimensions and placements follow
/// the corresponding templates in semi-utils/config/templates (Apache-2.0).
enum SemiWatermarkRenderer {
    static func render(photo: PhotoEntry, preset: WatermarkPreset, sourcePath: String?,
                       matchOrientation: Bool, maxPixelSize: Int?,
                       configuration: WatermarkConfiguration? = nil) throws -> NSBitmapImageRep {
        guard let path = sourcePath ?? photo.watermarkSourcePath(preferRaw: false),
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            throw WatermarkError.unreadableImage
        }
        let image = try CropImageService.image(path: path, crop: photo.cropRect,
                                               maxPixelSize: maxPixelSize)
        let metadata = Metadata(path: path, source: source, fallbackDate: photo.fileDate)
        let selected = preset.resolved(isPortrait: image.height > image.width,
                                       matchOrientation: matchOrientation)
        let effectiveConfiguration = configuration?.adapted(to: selected)
        switch selected.layout {
        case .standard, .card, .nikonCard, .centerBrand:
            return try bordered(image, metadata: metadata, preset: selected,
                                configuration: effectiveConfiguration)
        case .blur, .nikonBlur:
            return try blurred(image, metadata: metadata, nikon: selected.layout == .nikonBlur,
                               configuration: effectiveConfiguration)
        case .cornerParameters:
            return try overlay(image) { canvas in
                let short = CGFloat(min(image.width, image.height))
                let height = selected.isPortraitPreset ? short * 0.03 : CGFloat(image.height) * 0.03
                let inset = CGFloat(image.height) * 0.05
                drawSlot(.overlayParameters, defaultText: metadata.parameters,
                         defaultPosition: .bottomRight, baselinePercent: 3,
                         image: image, canvas: canvas, metadata: metadata, configuration: effectiveConfiguration,
                         x: canvas.width - inset, bottom: inset, height: height,
                         color: .white, weight: .bold, alignment: .right, maxWidth: canvas.width * 0.9)
                drawExtras(effectiveConfiguration, metadata: metadata, image: image, canvas: canvas,
                           photoRect: canvas, footer: 0)
            }
        case .folderAndDate:
            return try overlay(image) { canvas in
                let short = CGFloat(min(image.width, image.height))
                let height = selected.isPortraitPreset ? short * 0.03 : CGFloat(image.height) * 0.03
                drawSlot(.overlayFolderDate, defaultText: "\(metadata.folder)    \(metadata.date)",
                         defaultPosition: .bottomRight, baselinePercent: 3,
                         image: image, canvas: canvas, metadata: metadata, configuration: effectiveConfiguration,
                         x: canvas.width * 0.93, bottom: canvas.height * 0.02, height: height,
                         color: NSColor(calibratedRed: 232 / 255, green: 141 / 255,
                                        blue: 52 / 255, alpha: 1), weight: .regular,
                         alignment: .right, maxWidth: canvas.width * 0.85)
                drawExtras(effectiveConfiguration, metadata: metadata, image: image, canvas: canvas,
                           photoRect: canvas, footer: 0)
            }
        }
    }

    private static func bordered(_ image: CGImage, metadata: Metadata,
                                 preset: WatermarkPreset,
                                 configuration: WatermarkConfiguration?) throws -> NSBitmapImageRep {
        let portrait = preset.isPortraitPreset
        let short = CGFloat(min(image.width, image.height))
        let imageHeight = CGFloat(image.height)
        let isCard = preset.layout == .card || preset.layout == .nikonCard
        let isLogoOnly = preset.layout == .centerBrand
        let shadowRadius: CGFloat = (isCard || configuration?.shadow == true) && (configuration?.shadow ?? true)
            ? (isCard ? pixel(portrait ? short * 0.027 : 100) : pixel(short * 0.015)) : 0
        let shadowPadding = shadowRadius * 2
        let shadowHeight = imageHeight + shadowPadding * 2
        let extraPadding = short * CGFloat(configuration?.paddingPercent ?? 0) / 100
        let sideMargin: CGFloat = (isCard ? (portrait && preset.layout == .card ? pixel(short * 0.027) : 100)
            : (isLogoOnly ? pixel(portrait ? short * 0.02 : imageHeight * 0.02) : 0)) + extraPadding
        let topMargin: CGFloat = (isCard ? sideMargin : 0) + (isCard ? 0 : extraPadding)
        let footer = pixel(portrait ? short * 0.13 : shadowHeight * 0.12)
            + short * CGFloat(configuration?.footerPercent ?? 0) / 100
        let finalBottomMargin: CGFloat = isCard ? pixel((portrait ? short : imageHeight) * 0.02) : 0
        let canvasWidth = CGFloat(image.width) + shadowPadding * 2 + sideMargin * 2
        let canvasHeight = shadowHeight + topMargin + footer + finalBottomMargin
        let canvasSize = CGSize(width: Int(canvasWidth), height: Int(canvasHeight))

        return try bitmap(size: canvasSize) { canvas in
            (configuration.flatMap { NSColor.watermarkHex($0.backgroundHex) } ?? .white).setFill()
            canvas.fill()
            if configuration?.background == .blurred,
               let background = softBackground(image, radius: short * 0.03) {
                background.draw(in: canvas)
            }
            let photoRect = CGRect(x: sideMargin + shadowPadding,
                                   y: finalBottomMargin + footer + shadowPadding,
                                   width: CGFloat(image.width), height: CGFloat(image.height))
            let radius: CGFloat = (isCard ? (portrait ? short * 0.01 : imageHeight * 0.01) : 0)
                + short * CGFloat(configuration?.cornerRadiusPercent ?? 0) / 100
            drawPhoto(image, in: photoRect, radius: radius,
                      shadowRadius: shadowRadius, shadowColor: .black)

            let logoComponent = configuration?.components.first { $0.slot == (isLogoOnly ? .centerLogo : .footerLogo) }
            let logo = logoComponent?.imageData.flatMap(NSImage.init(data:)) ?? logo(for: metadata.make)
            guard let logo else {
                drawFooterText(canvas: canvas, image: image, metadata: metadata,
                               portrait: portrait, card: isCard, logoRect: nil,
                               footer: footer, sideMargin: sideMargin,
                               bottomMargin: finalBottomMargin, logoOnly: isLogoOnly,
                               configuration: configuration, photoRect: photoRect)
                drawExtras(configuration, metadata: metadata, image: image, canvas: canvas,
                           photoRect: photoRect, footer: footer)
                return
            }
            if isLogoOnly {
                if configuration == nil || logoComponent != nil {
                    let height = (portrait ? short * 0.09 : footer)
                        * CGFloat(logoComponent.map { $0.fontPercent / (portrait ? 9 : 12) } ?? 1)
                    let aspect = logo.size.width / max(logo.size.height, 1)
                    if logoComponent?.position == nil || logoComponent?.position == .footerCenter {
                        let rect = CGRect(x: canvas.midX - height * aspect / 2,
                                          y: finalBottomMargin + (footer - height) / 2,
                                          width: height * aspect, height: height)
                        logo.draw(in: rect)
                    } else if var moved = logoComponent {
                        moved.imageData = moved.imageData ?? logo.tiffRepresentation
                        drawAtPosition("", component: moved, image: image, canvas: canvas,
                                       photoRect: photoRect, height: height, color: .black, weight: .regular)
                    }
                }
            } else {
                drawFooterText(canvas: canvas, image: image, metadata: metadata,
                               portrait: portrait, card: isCard,
                               logoRect: logoComponent?.position == .footerRight || configuration == nil ? logo : nil,
                               footer: footer, sideMargin: sideMargin,
                               bottomMargin: finalBottomMargin, logoOnly: false,
                               configuration: configuration, photoRect: photoRect)
                if let logoComponent, logoComponent.position != .footerRight {
                    var moved = logoComponent
                    moved.imageData = moved.imageData ?? logo.tiffRepresentation
                    let size = footer * CGFloat(moved.fontPercent / (portrait ? 6.8 : 7.2))
                    drawAtPosition("", component: moved, image: image, canvas: canvas,
                                   photoRect: photoRect, height: size, color: .black, weight: .regular)
                }
            }
            drawExtras(configuration, metadata: metadata, image: image, canvas: canvas,
                       photoRect: photoRect, footer: footer)
        }
    }

    private static func drawFooterText(canvas: CGRect, image: CGImage, metadata: Metadata,
                                       portrait: Bool, card: Bool, logoRect logo: NSImage?,
                                       footer: CGFloat, sideMargin: CGFloat,
                                       bottomMargin: CGFloat, logoOnly: Bool,
                                       configuration: WatermarkConfiguration?, photoRect: CGRect) {
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

        drawSlot(.footerCamera, defaultText: metadata.camera, defaultPosition: .footerLeft,
                 baselinePercent: portrait ? 1.9323 : 3.051, image: image, canvas: canvas,
                 metadata: metadata, configuration: configuration,
                 x: leftX, bottom: upperBottom, height: boldLine * fontScale,
                 color: .black, weight: .bold, alignment: .left, maxWidth: canvas.width * 0.44,
                 photoRect: photoRect)
        drawSlot(.footerLens, defaultText: metadata.lens, defaultPosition: .footerLeft,
                 baselinePercent: portrait ? 1.71 : 2.7, image: image, canvas: canvas,
                 metadata: metadata, configuration: configuration,
                 x: leftX, bottom: lowerBottom, height: line * fontScale,
                 color: darkText, weight: .light, alignment: .left, maxWidth: canvas.width * 0.44,
                 photoRect: photoRect)

        let rightFont = font(size: boldLine * fontScale, weight: .bold)
        let rightBottomFont = font(size: line * fontScale, weight: .light)
        let rightWidth = max(measure(metadata.parameters, font: rightFont),
                             measure(metadata.date, font: rightBottomFont))
        let rightStart = rightEnd - rightWidth
        let rightAlignment: NSTextAlignment = (!card && !portrait) ? .left : .right
        let rightAnchor = rightAlignment == .left ? rightStart : rightEnd
        drawSlot(.footerParameters, defaultText: metadata.parameters, defaultPosition: .footerRight,
                 baselinePercent: portrait ? 1.9323 : 3.051, image: image, canvas: canvas,
                 metadata: metadata, configuration: configuration,
                 x: rightAnchor, bottom: upperBottom, height: boldLine * fontScale,
                 color: darkText, weight: .bold, alignment: rightAlignment,
                 maxWidth: canvas.width * 0.44, photoRect: photoRect)
        drawSlot(.footerDate, defaultText: metadata.date, defaultPosition: .footerRight,
                 baselinePercent: portrait ? 1.71 : 2.7, image: image, canvas: canvas,
                 metadata: metadata, configuration: configuration,
                 x: rightAnchor, bottom: lowerBottom, height: line * fontScale,
                 color: darkText, weight: .light, alignment: rightAlignment,
                 maxWidth: canvas.width * 0.44, photoRect: photoRect)

        if let logo, configuration == nil || configuration?.components.contains(where: { $0.slot == .footerLogo }) == true {
            let delimiterWidth = max(1, CGFloat(image.width) * 0.003)
            let delimiterX = canvas.width - sideMargin - rightWidth
                - 2 * commonSpacing - delimiterWidth
            if !card {
                NSColor(calibratedRed: 216 / 255, green: 216 / 255,
                        blue: 214 / 255, alpha: 1).setFill()
                CGRect(x: delimiterX, y: bottomMargin + elementMargin - elementHeight * 0.05,
                       width: delimiterWidth, height: elementHeight * 1.1).fill()
            }
            let logoSize = elementHeight * CGFloat(configuration?.components.first(where: { $0.slot == .footerLogo })
                .map { $0.fontPercent / (portrait ? 6.8 : 7.2) } ?? 1)
            let rect = CGRect(x: delimiterX - commonSpacing - logoSize,
                              y: bottomMargin + elementMargin,
                              width: logoSize, height: logoSize)
            logo.draw(in: rect)
        }
    }

    private static func blurred(_ image: CGImage, metadata: Metadata,
                                nikon: Bool, configuration: WatermarkConfiguration?) throws -> NSBitmapImageRep {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let short = min(width, height)
        let canvasSize = CGSize(width: Int(width * 1.35 + short * CGFloat(configuration?.paddingPercent ?? 0) * 2 / 100),
                                height: Int(height * 1.35 + short * CGFloat(configuration?.footerPercent ?? 0) / 100))
        let blurRadius = short * 0.03
        let roundedRadius = short * (0.02 + CGFloat(configuration?.cornerRadiusPercent ?? 0) / 100)
        let shadowRadius = (configuration?.shadow ?? true) ? short * 0.01 : 0
        let shadowPadding = shadowRadius * 2
        let cameraHeight = short * 0.04
        let parameterHeight = short * 0.03
        let spacing = short * 0.03
        let compositeHeight = height + shadowPadding * 2 + cameraHeight
            + parameterHeight + spacing * 2
        let bottom = (canvasSize.height - compositeHeight) / 2 - short * 0.03
        // PIL trims the glyphs to the requested height before concatenating them. AppKit
        // draws from a baseline, so the equivalent visual bounds need separate offsets.
        let cameraOffset = short * (nikon ? 0.0337 : 0.0224)
        let parameterOffset = short * (nikon ? 0.0263 : 0.0188)
        let photoOffset = short * (nikon ? 0.0024 : -0.0051)

        return try bitmap(size: canvasSize) { canvas in
            if configuration?.background == .solid {
                (configuration.flatMap { NSColor.watermarkHex($0.backgroundHex) } ?? .white).setFill()
                canvas.fill()
            } else if let background = softBackground(image, radius: blurRadius) {
                background.draw(in: CGRect(x: (canvas.width - width * 2) / 2,
                                           y: (canvas.height - height * 2) / 2,
                                           width: width * 2, height: height * 2))
            }
            let photoRect = CGRect(x: (canvas.width - width) / 2,
                                   y: bottom + parameterHeight + cameraHeight
                                       + spacing * 2 + shadowPadding + photoOffset,
                                   width: width, height: height)
            drawPhoto(image, in: photoRect, radius: roundedRadius,
                      shadowRadius: shadowRadius, shadowColor: .black)
            let textCenter = canvas.midX
            let parameterBottom = bottom + shadowPadding - parameterOffset
            let cameraBottom = bottom + shadowPadding + parameterHeight + spacing - cameraOffset
            if nikon, configuration == nil, let range = metadata.camera.range(of: "Z") {
                let before = String(metadata.camera[..<range.lowerBound])
                let after = String(metadata.camera[range.upperBound...])
                drawRichCamera(before: before, after: after, x: textCenter,
                               bottom: cameraBottom, height: cameraHeight * 1.5,
                               maxWidth: canvas.width * 0.85)
            } else if nikon, let component = configuration?.components.first(where: { $0.slot == .blurCamera }),
                      component.kind == .camera, component.text.isEmpty || component.text == "文字",
                      component.colorHex == "#FFFFFF", component.bold,
                      component.position == .bottomCenter {
                if let range = metadata.camera.range(of: "Z") {
                    drawRichCamera(before: String(metadata.camera[..<range.lowerBound]),
                                   after: String(metadata.camera[range.upperBound...]), x: textCenter,
                                   bottom: cameraBottom, height: cameraHeight * 1.5
                                       * CGFloat(component.fontPercent / 4), maxWidth: canvas.width * 0.85)
                } else {
                    drawSlot(.blurCamera, defaultText: metadata.camera, defaultPosition: .bottomCenter,
                             baselinePercent: 4, image: image, canvas: canvas, metadata: metadata,
                             configuration: configuration, x: textCenter, bottom: cameraBottom,
                             height: cameraHeight, color: .white, weight: .bold,
                             alignment: .center, maxWidth: canvas.width * 0.85,
                             photoRect: photoRect)
                }
            } else {
                drawSlot(.blurCamera, defaultText: metadata.camera, defaultPosition: .bottomCenter,
                         baselinePercent: 4, image: image, canvas: canvas, metadata: metadata,
                         configuration: configuration, x: textCenter, bottom: cameraBottom,
                         height: cameraHeight, color: .white, weight: .bold,
                         alignment: .center, maxWidth: canvas.width * 0.85,
                         photoRect: photoRect)
            }
            drawSlot(.blurParameters, defaultText: metadata.parameters, defaultPosition: .bottomCenter,
                     baselinePercent: 3.7, image: image, canvas: canvas, metadata: metadata,
                     configuration: configuration, x: textCenter, bottom: parameterBottom,
                     height: short * 0.037, color: .white, weight: .light,
                     alignment: .center, maxWidth: canvas.width * 0.85,
                     photoRect: photoRect)
            drawExtras(configuration, metadata: metadata, image: image, canvas: canvas,
                       photoRect: photoRect, footer: canvas.height - photoRect.minY)
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

    private static func text(for component: WatermarkComponent, metadata: Metadata) -> String {
        switch component.kind {
        case .camera: return metadata.camera
        case .lens: return metadata.lens
        case .parameters: return metadata.parameters
        case .date: return metadata.date
        case .folder: return metadata.folder
        case .folderAndDate: return "\(metadata.folder)    \(metadata.date)"
        case .customText: return component.text
        case .logo: return ""
        }
    }

    private static func drawSlot(_ slot: WatermarkComponent.Slot, defaultText: String,
                                 defaultPosition: WatermarkComponent.Position, baselinePercent: Double,
                                 image: CGImage, canvas: CGRect, metadata: Metadata,
                                 configuration: WatermarkConfiguration?, x: CGFloat, bottom: CGFloat,
                                 height: CGFloat, color: NSColor, weight: NSFont.Weight,
                                 alignment: NSTextAlignment, maxWidth: CGFloat,
                                 photoRect: CGRect? = nil) {
        guard let configuration else {
            draw(defaultText, x: x, bottom: bottom, height: height, color: color,
                 weight: weight, alignment: alignment, maxWidth: maxWidth)
            return
        }
        guard let component = configuration.components.first(where: { $0.slot == slot }) else { return }
        let text = text(for: component, metadata: metadata)
        let scaledHeight = height * CGFloat(component.fontPercent / baselinePercent)
        let defaultHex: String = slot == .footerCamera ? "#000000"
            : (slot == .overlayFolderDate ? "#E88D34" :
                ([.blurCamera, .blurParameters, .overlayParameters].contains(slot) ? "#FFFFFF" : "#242424"))
        let chosenColor = component.colorHex == defaultHex ? color :
            (NSColor.watermarkHex(component.colorHex) ?? color)
        let chosenWeight: NSFont.Weight = component.bold ? .bold : (weight == .bold ? .regular : weight)
        if component.position == defaultPosition {
            draw(text, x: x, bottom: bottom, height: scaledHeight, color: chosenColor,
                 weight: chosenWeight, alignment: alignment, maxWidth: maxWidth)
        } else {
            drawAtPosition(text, component: component, image: image, canvas: canvas,
                           photoRect: photoRect ?? CGRect(x: 0, y: max(0, canvas.height - CGFloat(image.height)),
                                                          width: CGFloat(image.width), height: CGFloat(image.height)),
                           height: scaledHeight, color: chosenColor, weight: chosenWeight)
        }
    }

    private static func drawAtPosition(_ text: String, component: WatermarkComponent,
                                       image: CGImage, canvas: CGRect, photoRect: CGRect,
                                       height: CGFloat, color: NSColor, weight: NSFont.Weight) {
        let position = component.position
        let inset = CGFloat(min(image.width, image.height)) * 0.025
        let left = [.topLeft, .bottomLeft, .footerLeft].contains(position)
        let right = [.topRight, .bottomRight, .footerRight].contains(position)
        let x = left ? photoRect.minX + inset : (right ? photoRect.maxX - inset : photoRect.midX)
        let bottom: CGFloat
        if position.isFooter { bottom = max(0, photoRect.minY / 2) }
        else if [.topLeft, .topCenter, .topRight].contains(position) {
            bottom = photoRect.maxY - inset - height * 1.3
        } else { bottom = photoRect.minY + inset }
        let alignment: NSTextAlignment = left ? .left : (right ? .right : .center)
        if component.kind == .logo {
            let logo = component.imageData.flatMap(NSImage.init(data:))
            if let logo {
                let width = min(photoRect.width * 0.4, height * logo.size.width / max(logo.size.height, 1))
                let origin = left ? x : (right ? x - width : x - width / 2)
                logo.draw(in: CGRect(x: origin, y: bottom, width: width, height: height))
            }
        } else {
            draw(text, x: x, bottom: bottom, height: height, color: color,
                 weight: weight, alignment: alignment, maxWidth: photoRect.width * 0.85)
        }
    }

    private static func drawExtras(_ configuration: WatermarkConfiguration?, metadata: Metadata,
                                   image: CGImage, canvas: CGRect, photoRect: CGRect, footer: CGFloat) {
        guard let configuration else { return }
        for component in configuration.components where component.slot == nil {
            if component.position.isFooter && footer <= 0 { continue }
            let height = CGFloat(min(image.width, image.height)) * CGFloat(component.fontPercent / 100)
            let color = NSColor.watermarkHex(component.colorHex) ?? .black
            if component.kind == .logo, component.imageData == nil {
                var resolved = component
                resolved.imageData = logo(for: metadata.make)?.tiffRepresentation
                drawAtPosition("", component: resolved, image: image, canvas: canvas,
                               photoRect: photoRect, height: height, color: color, weight: .regular)
            } else {
                drawAtPosition(text(for: component, metadata: metadata), component: component,
                               image: image, canvas: canvas, photoRect: photoRect,
                               height: height, color: color, weight: component.bold ? .bold : .regular)
            }
        }
    }

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

    static func logo(for make: String) -> NSImage? {
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
