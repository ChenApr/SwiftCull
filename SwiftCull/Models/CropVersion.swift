import Foundation
import CoreGraphics

/// Coordinates refer to the orientation-corrected full image, with origin at its top left.
struct CropRect: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = CropRect(x: 0, y: 0, width: 1, height: 1)

    var isFull: Bool {
        abs(x) < 0.000_001 && abs(y) < 0.000_001 &&
        abs(width - 1) < 0.000_001 && abs(height - 1) < 0.000_001
    }

    var normalized: CropRect {
        let left = min(0.999, max(0, x))
        let top = min(0.999, max(0, y))
        return CropRect(x: left, y: top,
                        width: min(1 - left, max(0.001, width)),
                        height: min(1 - top, max(0.001, height)))
    }
}

enum CropAspectRatio: String, Codable, CaseIterable, Identifiable, Sendable {
    case free
    case original
    case square
    case threeTwo
    case fourThree
    case sixteenNine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "自由"
        case .original: return "原始比例"
        case .square: return "1:1"
        case .threeTwo: return "3:2"
        case .fourThree: return "4:3"
        case .sixteenNine: return "16:9"
        }
    }

    /// Portrait images use the portrait counterpart of a landscape ratio.
    func imageRatio(width: Int, height: Int) -> Double? {
        switch self {
        case .free: return nil
        case .original: return Double(width) / Double(max(1, height))
        case .square: return 1
        case .threeTwo: return width < height ? 2.0 / 3 : 3.0 / 2
        case .fourThree: return width < height ? 3.0 / 4 : 4.0 / 3
        case .sixteenNine: return width < height ? 9.0 / 16 : 16.0 / 9
        }
    }
}

enum CropGeometry {
    /// Maximize a locked crop within the source, keeping the old crop center where possible.
    static func fitted(_ crop: CropRect, imageWidth: Int, imageHeight: Int,
                       aspect: CropAspectRatio) -> CropRect {
        guard let imageRatio = aspect.imageRatio(width: imageWidth, height: imageHeight),
              imageWidth > 0, imageHeight > 0 else { return crop.normalized }
        let normalizedRatio = imageRatio * Double(imageHeight) / Double(imageWidth)
        let previous = crop.normalized
        let centerX = previous.x + previous.width / 2
        let centerY = previous.y + previous.height / 2
        let area = previous.width * previous.height
        var width = sqrt(area * normalizedRatio)
        var height = width / normalizedRatio
        let scale = min(1, 1 / width, 1 / height)
        width *= scale
        height *= scale
        return CropRect(x: min(max(0, centerX - width / 2), 1 - width),
                        y: min(max(0, centerY - height / 2), 1 - height),
                        width: width, height: height).normalized
    }

    /// Resize around the opposite corner; edge limits preserve the selected ratio.
    static func resized(_ crop: CropRect, dx: Double, dy: Double,
                        right: Bool, bottom: Bool, normalizedRatio: Double?) -> CropRect {
        let start = crop.normalized
        let anchorX = right ? start.x : start.x + start.width
        let anchorY = bottom ? start.y : start.y + start.height
        let xDirection = right ? 1.0 : -1.0
        let yDirection = bottom ? 1.0 : -1.0
        let maxWidth = right ? 1 - anchorX : anchorX
        let maxHeight = bottom ? 1 - anchorY : anchorY
        var width = min(maxWidth, max(0.02, start.width + xDirection * dx))
        var height = min(maxHeight, max(0.02, start.height + yDirection * dy))
        if let normalizedRatio, normalizedRatio > 0 {
            if abs(dx) / max(start.width, 0.02) >= abs(dy) / max(start.height, 0.02) {
                height = width / normalizedRatio
            } else {
                width = height * normalizedRatio
            }
            let scale = min(1, maxWidth / width, maxHeight / height)
            width *= scale
            height *= scale
        }
        return CropRect(x: right ? anchorX : anchorX - width,
                        y: bottom ? anchorY : anchorY - height,
                        width: width, height: height).normalized
    }
}

/// Keep the zoomed image reachable while the crop frame is edited in the window.
enum CropViewport {
    static func imageFrame(canvas: CGSize, image: CGSize, zoom: CGFloat, pan: CGSize) -> CGRect {
        let fit = min(canvas.width / max(1, image.width), canvas.height / max(1, image.height))
        let width = image.width * fit * zoom
        let height = image.height * fit * zoom
        let limitedPan = clampedPan(pan, canvas: canvas, displayedImage: CGSize(width: width, height: height))
        return CGRect(x: (canvas.width - width) / 2 + limitedPan.width,
                      y: (canvas.height - height) / 2 + limitedPan.height,
                      width: width, height: height)
    }

    static func clampedPan(_ pan: CGSize, canvas: CGSize, image: CGSize, zoom: CGFloat) -> CGSize {
        let frame = imageFrame(canvas: canvas, image: image, zoom: zoom, pan: .zero)
        return clampedPan(pan, canvas: canvas, displayedImage: frame.size)
    }

    private static func clampedPan(_ pan: CGSize, canvas: CGSize, displayedImage: CGSize) -> CGSize {
        let horizontalLimit = max(0, (displayedImage.width - canvas.width) / 2)
        let verticalLimit = max(0, (displayedImage.height - canvas.height) / 2)
        return CGSize(width: min(horizontalLimit, max(-horizontalLimit, pan.width)),
                      height: min(verticalLimit, max(-verticalLimit, pan.height)))
    }
}

struct CropVersion: Codable, Hashable, Sendable {
    /// nil identifies the main version, even if its crop is cleared.
    var id: UUID?
    var name: String?
    var crop: CropRect?
    var aspect: CropAspectRatio? = nil
}
