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

    enum Background: String, Codable, CaseIterable, Identifiable, Sendable {
        case solid = "纯色"
        case blurred = "照片模糊"
        var id: String { rawValue }
    }

    static func draft(from preset: WatermarkPreset) -> WatermarkConfiguration {
        let portrait = preset.isPortraitPreset
        let overlay = [.cornerParameters, .folderAndDate, .blur, .nikonBlur].contains(preset.layout)
        let central: WatermarkComponent.Position = overlay ? .topCenter : (portrait ? .footerCenter : .footerLeft)
        let secondary: WatermarkComponent.Position = overlay ? .bottomRight : (portrait ? .footerCenter : .footerRight)
        let textColor = overlay ? "#FFFFFF" : "#202020"
        var configuration = WatermarkConfiguration(
            name: "\(preset.rawValue) · 自定义", basePreset: preset,
            background: [.blur, .nikonBlur].contains(preset.layout) ? .blurred : .solid,
            backgroundHex: [.blur, .nikonBlur].contains(preset.layout) ? "#242424" : "#FFFFFF",
            paddingPercent: [.card, .nikonCard].contains(preset.layout) ? 5 : 3,
            footerPercent: overlay ? 0 : (portrait ? 18 : 13),
            cornerRadiusPercent: [.card, .nikonCard].contains(preset.layout) ? 1.2 : 0,
            shadow: [.card, .nikonCard].contains(preset.layout),
            components: [
                WatermarkComponent(kind: .camera, position: central, fontPercent: 2.4, colorHex: textColor, bold: true),
                WatermarkComponent(kind: .lens, position: central, fontPercent: 1.5, colorHex: textColor),
                WatermarkComponent(kind: .parameters, position: secondary, fontPercent: 1.8, colorHex: textColor, bold: true),
                WatermarkComponent(kind: .date, position: secondary, fontPercent: 1.4, colorHex: textColor)
            ]
        )
        switch preset.layout {
        case .cornerParameters:
            configuration.components = [WatermarkComponent(kind: .parameters, position: .bottomRight,
                                                            fontPercent: 2, colorHex: "#FFFFFF", bold: true)]
        case .folderAndDate:
            configuration.components = [
                WatermarkComponent(kind: .folder, position: .bottomRight, fontPercent: 2,
                                   colorHex: "#FFFFFF", bold: true),
                WatermarkComponent(kind: .date, position: .bottomRight, fontPercent: 1.5,
                                   colorHex: "#FFFFFF")
            ]
        case .centerBrand:
            configuration.components = [WatermarkComponent(kind: .camera, position: .footerCenter,
                                                            fontPercent: 2.8, bold: true)]
        default: break
        }
        return configuration
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

    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case camera = "相机"
        case lens = "镜头"
        case parameters = "拍摄参数"
        case date = "拍摄日期"
        case folder = "文件夹"
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
