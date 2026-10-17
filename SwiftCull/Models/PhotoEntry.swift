import SwiftUI

struct PhotoEntry: Identifiable, Hashable, Sendable {
    var id: String
    let baseName: String
    let jpgPath: String?
    let nefPath: String?
    let movPath: String?
    let jpgFileSize: Int64?
    let nefFileSize: Int64?
    let movFileSize: Int64?
    let fileDate: Date
    let modificationDate: Date
    var rating: Int
    var tags: [String]
    var isDeleted: Bool
    /// nil is the main version. Copies share source files but have independent crop state.
    var versionID: UUID? = nil
    var versionName: String? = nil
    var cropRect: CropRect? = nil
    var cropAspect: CropAspectRatio? = nil

    var sourceID: String { baseName }
    var isVersionCopy: Bool { versionID != nil }

    init(baseName: String, jpgPath: String?, nefPath: String?, movPath: String?,
         jpgFileSize: Int64?, nefFileSize: Int64?, movFileSize: Int64?, fileDate: Date, modificationDate: Date) {
        self.id = baseName
        self.baseName = baseName
        self.jpgPath = jpgPath
        self.nefPath = nefPath
        self.movPath = movPath
        self.jpgFileSize = jpgFileSize
        self.nefFileSize = nefFileSize
        self.movFileSize = movFileSize
        self.fileDate = fileDate
        self.modificationDate = modificationDate
        self.rating = 0
        self.tags = []
        self.isDeleted = false
    }

    var hasJpg: Bool { jpgPath != nil }
    var associatedFilePaths: [String] {
        Array(Set([jpgPath, nefPath, movPath].compactMap { $0 })).sorted()
    }

    /// A pair can be only partly trashed. Keep surviving paths usable for retry.
    func removingFiles(at paths: Set<String>) -> PhotoEntry {
        func keep(_ path: String?) -> String? { path.flatMap { paths.contains($0) ? nil : $0 } }
        var updated = PhotoEntry(baseName: baseName, jpgPath: keep(jpgPath),
                                 nefPath: keep(nefPath), movPath: keep(movPath),
                                 jpgFileSize: keep(jpgPath) == nil ? nil : jpgFileSize,
                                 nefFileSize: keep(nefPath) == nil ? nil : nefFileSize,
                                 movFileSize: keep(movPath) == nil ? nil : movFileSize,
                                 fileDate: fileDate, modificationDate: modificationDate)
            .asVersion(CropVersion(id: versionID, name: versionName, crop: cropRect, aspect: cropAspect))
        updated.rating = rating
        updated.tags = tags
        updated.isDeleted = isDeleted
        return updated
    }
    var hasNef: Bool { nefPath != nil }
    var hasMov: Bool { movPath != nil }
    var isVideoOnly: Bool { hasMov && !hasJpg && !hasNef }
    var isLivePhoto: Bool {
        guard hasMov, let jpgPath else { return false }
        return ["heic", "heif"].contains(URL(fileURLWithPath: jpgPath).pathExtension.lowercased())
    }

    var displayName: String { versionName ?? baseName }

    func asVersion(_ version: CropVersion) -> PhotoEntry {
        var copy = self
        copy.versionID = version.id
        copy.versionName = version.name
        copy.cropRect = version.crop
        copy.cropAspect = version.aspect
        copy.id = version.id.map { "\(baseName)::\($0.uuidString)" } ?? baseName
        return copy
    }

    var totalFileSize: Int64 {
        (jpgFileSize ?? 0) + (nefFileSize ?? 0) + (movFileSize ?? 0)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalFileSize, countStyle: .file)
    }

    var formattedDate: String {
        formattedCaptureDate
    }

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var formattedCaptureDate: String {
        Self.displayDateFormatter.string(from: fileDate)
    }

    var formattedModificationDate: String {
        Self.displayDateFormatter.string(from: modificationDate)
    }

    var primaryImagePath: String {
        jpgPath ?? nefPath ?? ""
    }

    func watermarkSourcePath(preferRaw: Bool) -> String? {
        preferRaw ? (nefPath ?? jpgPath) : (jpgPath ?? nefPath)
    }

    var primaryFilePath: String {
        jpgPath ?? nefPath ?? movPath ?? ""
    }

    var fileTypeBadge: String {
        if isLivePhoto { return "LIVE" }
        if hasMov && hasNef && hasJpg { return "RAW+JPG+MOV" }
        if hasMov && hasNef { return "RAW+MOV" }
        if hasMov && hasJpg { return "JPG+MOV" }
        if hasNef && hasJpg { return "RAW+JPG" }
        if hasNef { return "RAW" }
        if hasMov { return "MOV" }
        if let jpgPath, ["heic", "heif"].contains(URL(fileURLWithPath: jpgPath).pathExtension.lowercased()) {
            return "HEIC"
        }
        return "JPG"
    }

    var fileTypeBadgeColor: Color {
        if hasMov && (hasNef || hasJpg) { return .teal }
        if hasMov { return .cyan }
        if hasNef && hasJpg { return .purple }
        if hasNef { return .indigo }
        return .blue
    }

    var hasAnyMark: Bool {
        rating > 0 || !tags.isEmpty
    }
}
