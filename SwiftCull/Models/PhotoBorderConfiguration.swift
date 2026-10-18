import Foundation
import AppKit

/// Edge-style centered margins. Photos keep their native pixels; the canvas grows around them.
struct PhotoBorderConfiguration: Codable, Hashable, Sendable {
    var aspect: Aspect = .square
    var widthPercent = 56.0 / 1320.0 * 100
    var colorHex = "#FFFFFF"

    var color: NSColor {
        let value = UInt32(colorHex.dropFirst(), radix: 16) ?? 0xFFFFFF
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    mutating func setColor(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        colorHex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                          Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }

    enum Aspect: String, Codable, CaseIterable, Identifiable, Sendable {
        case original, square, portrait45, landscape43, portrait34, landscape169, portrait916
        var id: String { rawValue }
        var title: String {
            switch self {
            case .original: return "等宽留白"
            case .square: return "1:1"
            case .portrait45: return "4:5"
            case .landscape43: return "4:3"
            case .portrait34: return "3:4"
            case .landscape169: return "16:9"
            case .portrait916: return "9:16"
            }
        }
        var ratio: Double? {
            switch self {
            case .original: return nil
            case .square: return 1
            case .portrait45: return 4.0 / 5
            case .landscape43: return 4.0 / 3
            case .portrait34: return 3.0 / 4
            case .landscape169: return 16.0 / 9
            case .portrait916: return 9.0 / 16
            }
        }
    }

    static let palette: [(name: String, hex: String)] = [
        ("白", "#FFFFFF"), ("黑", "#000000"), ("灰", "#8C8C91"), ("米", "#F5F0E0"),
        ("蓝", "#A8C9EB"), ("粉", "#F5D9DB"), ("绿", "#CCDBC7"), ("棕", "#D9B88C")
    ]

    var isValid: Bool {
        widthPercent.isFinite && (0...15).contains(widthPercent) && colorHex.count == 7 &&
        colorHex.first == "#" && UInt32(colorHex.dropFirst(), radix: 16) != nil
    }

    func layout(photoSize: CGSize) -> Layout {
        let pw = Int(photoSize.width.rounded())
        let ph = Int(photoSize.height.rounded())
        guard pw > 0, ph > 0, isValid else { return Layout(canvas: .zero, photoRect: .zero) }
        let b = widthPercent / 100
        guard let ratio = aspect.ratio else {
            let inset = Int((b * Double(min(pw, ph)) / (1 - 2 * b)).rounded())
            return Layout(canvas: CGSize(width: pw + 2 * inset, height: ph + 2 * inset),
                          photoRect: CGRect(x: inset, y: inset, width: pw, height: ph))
        }
        let widthFactor = max(1, ratio)
        let heightFactor = max(1, 1 / ratio)
        let shortSide = max(Double(pw) / (widthFactor - 2 * b),
                            Double(ph) / (heightFactor - 2 * b))
        // Match source parity so both opposing borders contain the same integer pixels.
        var width = max(pw, Int((shortSide * widthFactor).rounded()))
        var height = max(ph, Int((shortSide * heightFactor).rounded()))
        if (width - pw) % 2 != 0 { width += 1 }
        if (height - ph) % 2 != 0 { height += 1 }
        return Layout(canvas: CGSize(width: width, height: height),
                      photoRect: CGRect(x: (width - pw) / 2, y: (height - ph) / 2, width: pw, height: ph))
    }

    struct Layout: Equatable {
        let canvas: CGSize
        /// Bottom-left origin, matching the existing AppKit watermark canvas.
        let photoRect: CGRect
    }
}
