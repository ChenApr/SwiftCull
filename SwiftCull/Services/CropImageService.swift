import AppKit
import ImageIO
import UniformTypeIdentifiers

enum CropImageError: LocalizedError {
    case unreadable, encoding
    var errorDescription: String? {
        switch self {
        case .unreadable: return "无法读取原照片"
        case .encoding: return "无法生成裁剪后的照片"
        }
    }
}

enum CropImageService {
    static func image(path: String, crop: CropRect? = nil, maxPixelSize: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            throw CropImageError.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let originalWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let originalHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize ?? max(originalWidth, originalHeight),
            kCGImageSourceShouldCacheImmediately: true
        ]
        if maxPixelSize == nil { options[kCGImageSourceShouldCache] = false }
        guard let full = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CropImageError.unreadable
        }
        guard let crop, !crop.isFull else { return full }
        let normalized = crop.normalized
        let rect = CGRect(x: Int((normalized.x * Double(full.width)).rounded(.down)),
                          y: Int((normalized.y * Double(full.height)).rounded(.down)),
                          width: max(1, Int((normalized.width * Double(full.width)).rounded(.down))),
                          height: max(1, Int((normalized.height * Double(full.height)).rounded(.down))))
            .intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard let cropped = full.cropping(to: rect), rect.width >= 1, rect.height >= 1 else {
            throw CropImageError.unreadable
        }
        return cropped
    }

    static func write(photo: PhotoEntry, sourcePath: String, into directory: URL) throws -> URL {
        let source = URL(fileURLWithPath: sourcePath)
        let isRaw = photo.nefPath == sourcePath
        let ext = source.pathExtension.lowercased()
        let outputExtension = isRaw || ext == "tif" || ext == "tiff" ? "tiff" : "jpg"
        let type: CFString = outputExtension == "tiff" ? UTType.tiff.identifier as CFString : UTType.jpeg.identifier as CFString
        let stem = source.deletingPathExtension().lastPathComponent +
            (photo.isVersionCopy ? "_\(safeName(photo.displayName))" : "")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var index = 1
        var destination: URL
        repeat {
            let name = index == 1 ? stem : "\(stem)_\(index)"
            destination = directory.appendingPathComponent(name).appendingPathExtension(outputExtension)
            index += 1
        } while FileManager.default.fileExists(atPath: destination.path)
        if photo.cropRect == nil || photo.cropRect?.isFull == true {
            // Preserve an unedited source exactly when its extension does not need conversion.
            if !isRaw && outputExtension == ext {
                try FileManager.default.copyItem(at: source, to: destination)
                return destination
            }
        }
        let image = try image(path: sourcePath, crop: photo.cropRect)
        let temporary = directory.appendingPathComponent(".swiftcull-crop-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let output = CGImageDestinationCreateWithURL(temporary as CFURL, type, 1, nil) else {
            throw CropImageError.encoding
        }
        let options: [CFString: Any] = outputExtension == "jpg" ? [kCGImageDestinationLossyCompressionQuality: 0.94] : [:]
        CGImageDestinationAddImage(output, image, options as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw CropImageError.encoding }
        while true {
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
                break
            } catch {
                guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
                destination = directory.appendingPathComponent("\(stem)_\(index)")
                    .appendingPathExtension(outputExtension)
                index += 1
            }
        }
        return destination
    }

    static func copyOrRender(photo: PhotoEntry, sourcePath: String, into directory: URL) throws -> URL {
        if photo.cropRect != nil {
            return try write(photo: photo, sourcePath: sourcePath, into: directory)
        }
        let source = URL(fileURLWithPath: sourcePath)
        let stem = source.deletingPathExtension().lastPathComponent +
            (photo.isVersionCopy ? "_\(photo.versionID!.uuidString.prefix(8))" : "")
        let destination = directory.appendingPathComponent(stem).appendingPathExtension(source.pathExtension)
        var candidate = destination
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(stem + "_\(suffix)")
                .appendingPathExtension(source.pathExtension)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: candidate)
        return candidate
    }

    private static func safeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return String(cleaned.prefix(60))
    }
}
