import Foundation

// MARK: - Sidecar Data Model

struct PhotoMetadata: Codable, Sendable {
    var rating: Int?
}

struct ProjectMetadataFile: Codable {
    static let currentVersion = 1
    let version: Int
    var updatedAt: Date
    var entries: [String: PhotoMetadata]
}

// MARK: - Service

final class ProjectMetadataService: @unchecked Sendable {
    static let shared = ProjectMetadataService()

    private let fileName = "metadata.json"
    private let folderName = ".swiftcull"
    private let saveDelay: TimeInterval
    private struct PendingSave {
        let id: UUID
        let entries: [String: PhotoMetadata]
        let work: DispatchWorkItem
    }
    // Accessed only on queue. A save for one folder must never cancel another.
    private var pending: [String: PendingSave] = [:]
    private let queue = DispatchQueue(label: "com.swiftcull.project-metadata", qos: .utility)

    init(saveDelay: TimeInterval = 2.0) {
        self.saveDelay = saveDelay
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - Path Helpers

    private func sidecarDirectoryURL(for folderPath: String) -> URL {
        URL(fileURLWithPath: folderPath).appendingPathComponent(folderName, isDirectory: true)
    }

    private func sidecarFileURL(for folderPath: String) -> URL {
        sidecarDirectoryURL(for: folderPath).appendingPathComponent(fileName)
    }

    // MARK: - Load

    func load(from folderPath: String) -> [String: PhotoMetadata] {
        queue.sync {
            let path = normalizedPath(folderPath)
            // Return the newest in-memory snapshot even if its disk is temporarily unavailable.
            if let save = pending[path] {
                _ = flushOnQueue(paths: [path])
                return save.entries
            }
            let url = sidecarFileURL(for: path)
            guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder.iso8601Decoder.decode(ProjectMetadataFile.self, from: data).entries
            } catch {
                print("[ProjectMetadata] 读取失败: \(error.localizedDescription)")
                return [:]
            }
        }
    }

    // MARK: - Save (debounced)

    func scheduleSave(entries: [String: PhotoMetadata], folderPath: String) {
        queue.async { [self] in
            let path = normalizedPath(folderPath)
            pending[path]?.work.cancel()
            let id = UUID()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pending[path]?.id == id else { return }
                let errors = self.flushOnQueue(paths: [path])
                errors.forEach { print("[ProjectMetadata] \($0)") }
            }
            pending[path] = PendingSave(id: id, entries: entries, work: work)
            queue.asyncAfter(deadline: .now() + saveDelay, execute: work)
        }
    }

    /// Call from a background task while navigating, or synchronously during termination.
    /// Failed snapshots stay pending so a later flush can retry them.
    @discardableResult
    func flush() -> [String] {
        queue.sync { flushOnQueue(paths: Array(pending.keys)) }
    }

    private func flushOnQueue(paths: [String]) -> [String] {
        var failures: [String] = []
        for path in paths {
            guard let save = pending[path] else { continue }
            save.work.cancel()
            do {
                try saveNow(entries: save.entries, folderPath: path)
                pending.removeValue(forKey: path)
            } catch {
                failures.append("\(path)：\(error.localizedDescription)")
            }
        }
        return failures
    }

    private func saveNow(entries: [String: PhotoMetadata], folderPath: String) throws {
        let dirURL = sidecarDirectoryURL(for: folderPath)
        let fileURL = sidecarFileURL(for: folderPath)

        if !FileManager.default.fileExists(atPath: dirURL.path) {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }
        let file = ProjectMetadataFile(version: ProjectMetadataFile.currentVersion,
                                       updatedAt: Date(), entries: entries)
        let data = try JSONEncoder.iso8601Encoder.encode(file)
        try data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - JSON Encoder/Decoder Helpers

private extension JSONEncoder {
    static var iso8601Encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601Decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
