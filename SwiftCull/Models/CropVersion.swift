import Foundation

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

struct CropVersion: Codable, Hashable, Sendable {
    /// nil identifies the main version, even if its crop is cleared.
    var id: UUID?
    var name: String?
    var crop: CropRect?
}
