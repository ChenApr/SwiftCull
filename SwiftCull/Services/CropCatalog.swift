import Foundation
import CryptoKit

/// Stores only virtual version metadata. The source folder is never modified.
enum CropCatalog {
    private static func fileURL(for folder: String) -> URL {
        let digest = SHA256.hash(data: Data(URL(fileURLWithPath: folder).standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let support = ProcessInfo.processInfo.environment["SWIFTCULL_CROPS_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SwiftCull/Crops", isDirectory: true)
        return support
            .appendingPathComponent(digest).appendingPathExtension("json")
    }

    static func load(folder: String) -> [String: [CropVersion]] {
        guard let data = try? Data(contentsOf: fileURL(for: folder)),
              let versions = try? JSONDecoder().decode([String: [CropVersion]].self, from: data) else { return [:] }
        return versions
    }

    static func save(_ versions: [String: [CropVersion]], folder: String) throws {
        let url = fileURL(for: folder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(versions)
        try data.write(to: url, options: .atomic)
    }

    static func remove(folder: String) throws {
        let url = fileURL(for: folder)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
