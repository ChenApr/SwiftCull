import Foundation
import CryptoKit

/// Disposable cache outside the photo folder. Only date-based browsing opens image headers.
actor PhotoDateIndex {
    static let shared = PhotoDateIndex()

    private struct FileStamp: Codable, Equatable {
        let path: String
        let size: Int?
        let modified: Date?

        init(path: String) {
            self.path = path
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            size = values?.fileSize
            modified = values?.contentModificationDate
        }
    }

    private struct Record: Codable {
        let files: [FileStamp]
        let captured: Date?
    }

    private let directory: URL
    private let readDate: @Sendable (PhotoEntry) -> Date?
    private var folder: String?
    private var records: [String: Record] = [:]
    private var cacheFile: URL?
    private var isDirty = false

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SwiftCull/PhotoDates", isDirectory: true),
         readDate: @escaping @Sendable (PhotoEntry) -> Date? = { FileService.captureDate(for: $0) }) {
        self.directory = directory
        self.readDate = readDate
    }

    func dates(for photos: [PhotoEntry], folderPath: String) -> [String: Date] {
        let identity = URL(fileURLWithPath: folderPath).standardizedFileURL.path
        let name = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(name + ".json")
        if folder != identity {
            flush()
            folder = identity
            cacheFile = file
            records = (try? Data(contentsOf: file)).flatMap {
                try? JSONDecoder().decode([String: Record].self, from: $0)
            } ?? [:]
        }
        var result: [String: Date] = [:]
        for photo in photos {
            guard !Task.isCancelled else { break }
            // Finder-tag writes and external changes can happen after the initial scan.
            let files = photo.associatedFilePaths.map(FileStamp.init)
            if records[photo.sourceID]?.files != files {
                records[photo.sourceID] = Record(files: files, captured: readDate(photo))
                isDirty = true
            }
            result[photo.sourceID] = records[photo.sourceID]?.captured ?? photo.fileDate
        }
        return result
    }

    /// Persist once per index request, rather than rewriting a growing JSON file
    /// after every batch. A cancelled request can retain its completed records.
    func flush() {
        guard isDirty, let file = cacheFile else { return }
        if let data = try? JSONEncoder().encode(records) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? data.write(to: file, options: .atomic)) != nil { isDirty = false }
        }
    }
}
