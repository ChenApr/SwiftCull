import Foundation

/// A user-created layout. Coordinates are expressed as percentages so one preset works for any image size.
struct WatermarkConfiguration: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var basePreset: WatermarkPreset
    var background: Background = .solid
    var backgroundHex = "#FFFFFF"
    var paddingPercent = 3.0
    var footerPercent = 13.0
    var cornerRadiusPercent = 0.0
    var shadow = false
    var components: [WatermarkComponent]
    /// New drafts retain the geometry of their semi-utils template. Nil keeps older saved presets compatible.
    var templateLayout: Bool?
    /// Preserves the built-in preset's automatic landscape/portrait choice after saving.
    var matchOrientation: Bool?

    enum Background: String, Codable, CaseIterable, Identifiable, Sendable {
        case solid = "纯色"
        case blurred = "照片模糊"
        var id: String { rawValue }
    }

    static func draft(from preset: WatermarkPreset) -> WatermarkConfiguration {
        let portrait = preset.isPortraitPreset
        let blurred = preset.layout == .blur || preset.layout == .nikonBlur
        var configuration = WatermarkConfiguration(
            name: "\(preset.rawValue) · 自定义", basePreset: preset,
            background: blurred ? .blurred : .solid,
            backgroundHex: "#FFFFFF",
            paddingPercent: 0, footerPercent: 0, cornerRadiusPercent: 0,
            shadow: [.card, .nikonCard, .blur, .nikonBlur].contains(preset.layout),
            components: [], templateLayout: true
        )
        switch preset.layout {
        case .cornerParameters:
            configuration.components = [WatermarkComponent(kind: .parameters, position: .bottomRight,
                                                            fontPercent: 3, colorHex: "#FFFFFF", bold: true,
                                                            slot: .overlayParameters)]
        case .folderAndDate:
            configuration.components = [WatermarkComponent(kind: .folderAndDate, position: .bottomRight,
                                                            fontPercent: 3, colorHex: "#E88D34",
                                                            slot: .overlayFolderDate)]
        case .centerBrand:
            configuration.components = [WatermarkComponent(kind: .logo, position: .footerCenter,
                                                            fontPercent: portrait ? 9 : 12,
                                                            slot: .centerLogo)]
        case .blur, .nikonBlur:
            configuration.components = [
                WatermarkComponent(kind: .camera, position: .bottomCenter, fontPercent: 4,
                                   colorHex: "#FFFFFF", bold: true, slot: .blurCamera),
                WatermarkComponent(kind: .parameters, position: .bottomCenter, fontPercent: 3.7,
                                   colorHex: "#FFFFFF", slot: .blurParameters)
            ]
        case .standard, .card, .nikonCard:
            let large = portrait ? 1.9323 : 3.051
            let small = portrait ? 1.71 : 2.7
            configuration.components = [
                WatermarkComponent(kind: .camera, position: .footerLeft, fontPercent: large,
                                   colorHex: "#000000", bold: true, slot: .footerCamera),
                WatermarkComponent(kind: .lens, position: .footerLeft, fontPercent: small,
                                   colorHex: "#242424", slot: .footerLens),
                WatermarkComponent(kind: .parameters, position: .footerRight, fontPercent: large,
                                   colorHex: "#242424", bold: true, slot: .footerParameters),
                WatermarkComponent(kind: .date, position: .footerRight, fontPercent: small,
                                   colorHex: "#242424", slot: .footerDate),
                WatermarkComponent(kind: .logo, position: .footerRight, fontPercent: portrait ? 6.8 : 7.2,
                                   slot: .footerLogo)
            ]
        }
        return configuration
    }

    /// Apply edits relative to the starting template when a photo needs the other orientation.
    /// Unchanged controls take that orientation's exact built-in defaults.
    func adapted(to preset: WatermarkPreset) -> WatermarkConfiguration {
        guard templateLayout == true, preset != basePreset else { return self }
        let original = Self.draft(from: basePreset)
        var adapted = Self.draft(from: preset)
        adapted.id = id
        adapted.name = name
        adapted.matchOrientation = matchOrientation
        adapted.paddingPercent = paddingPercent
        adapted.footerPercent = footerPercent
        adapted.cornerRadiusPercent = cornerRadiusPercent
        if background != original.background { adapted.background = background }
        if backgroundHex != original.backgroundHex { adapted.backgroundHex = backgroundHex }
        if shadow != original.shadow { adapted.shadow = shadow }

        adapted.components = adapted.components.compactMap { target in
            guard let slot = target.slot,
                  let source = components.first(where: { $0.slot == slot }),
                  let baseline = original.components.first(where: { $0.slot == slot }) else { return nil }
            var result = target
            result.id = source.id
            if source.kind != baseline.kind { result.kind = source.kind }
            if source.position != baseline.position { result.position = source.position }
            result.fontPercent = target.fontPercent * source.fontPercent / baseline.fontPercent
            if source.colorHex != baseline.colorHex { result.colorHex = source.colorHex }
            if source.bold != baseline.bold { result.bold = source.bold }
            if source.text != baseline.text { result.text = source.text }
            result.fontID = source.fontID
            result.imageData = source.imageData
            return result
        }
        adapted.components.append(contentsOf: components.filter { $0.slot == nil })
        return adapted
    }
}

struct WatermarkComponent: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var kind: Kind
    var position: Position
    var text = "文字"
    var fontPercent = 1.8
    var colorHex = "#202020"
    var bold = false
    /// Nil preserves the original system font used by older presets and built-in templates.
    var fontID: String?
    var slot: Slot?
    /// PNG or JPEG bytes embedded in the preset so it survives moving the preset file.
    var imageData: Data?

    enum Slot: String, Codable, Sendable {
        case footerCamera, footerLens, footerParameters, footerDate, footerLogo, centerLogo
        case blurCamera, blurParameters, overlayParameters, overlayFolderDate
    }

    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case camera = "相机"
        case lens = "镜头"
        case parameters = "拍摄参数"
        case date = "拍摄日期"
        case folder = "文件夹"
        case folderAndDate = "文件夹与日期"
        case logo = "Logo 图片"
        case customText = "自定义文字"
        var id: String { rawValue }
    }

    enum Position: String, Codable, CaseIterable, Identifiable, Sendable {
        case topLeft = "左上"
        case topCenter = "上方居中"
        case topRight = "右上"
        case bottomLeft = "左下"
        case bottomCenter = "下方居中"
        case bottomRight = "右下"
        case footerLeft = "底栏左"
        case footerCenter = "底栏居中"
        case footerRight = "底栏右"
        var id: String { rawValue }
        var isFooter: Bool { [.footerLeft, .footerCenter, .footerRight].contains(self) }
    }
}
