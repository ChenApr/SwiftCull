import Foundation
import CryptoKit

final class RatingService: @unchecked Sendable {
    static let shared = RatingService()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for photoId: String, folderPath: String) -> String {
        let folder = URL(fileURLWithPath: folderPath).standardizedFileURL.path
        let identity = SHA256.hash(data: Data(folder.utf8)).map { String(format: "%02x", $0) }.joined()
        return "com.photofilter.rating.v2.\(identity).\(photoId)"
    }

    func getRating(for photoId: String, folderPath: String) -> Int {
        // Legacy basename-only keys cannot be attributed to a folder safely.
        // Retain them, but migrate only ratings backed by that folder's sidecar.
        defaults.integer(forKey: key(for: photoId, folderPath: folderPath))
    }

    func setRating(_ rating: Int, for photoId: String, folderPath: String) {
        defaults.set(min(5, max(0, rating)), forKey: key(for: photoId, folderPath: folderPath))
    }
}
