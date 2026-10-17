import AVFoundation
import ImageIO
import Photos
import UniformTypeIdentifiers

struct LivePhotoClip: Equatable, Sendable {
    var start: Double
    var end: Double
    var cover: Double

    var duration: Double { end - start }
    var coverOffset: Double { cover - start }

    static func centered(on time: Double, videoDuration: Double) -> LivePhotoClip {
        let length = min(3, max(0, videoDuration))
        let cover = min(max(time, 0), max(0, videoDuration - 0.1))
        let start = min(max(cover - length / 2, 0), max(0, videoDuration - length))
        return LivePhotoClip(start: start, end: start + length, cover: cover)
    }

    func validated(videoDuration: Double) throws -> LivePhotoClip {
        guard videoDuration.isFinite, videoDuration > 0,
              start.isFinite, end.isFinite, cover.isFinite,
              start >= 0, end <= videoDuration + 0.001,
              duration >= 0.5, duration <= 3.001,
              cover >= start, cover <= end else {
            throw LivePhotoError.invalidRange
        }
        var result = self
        result.cover = min(result.cover, result.end - 0.1)
        return result
    }
}

struct LivePhotoPair: Equatable {
    let imageURL: URL
    let videoURL: URL
}

enum LivePhotoDestination {
    case folder(URL)
    case photos
}

enum LivePhotoError: LocalizedError {
    case invalidVideo
    case invalidRange
    case imageExport
    case videoExport(String)
    case invalidPair(String)
    case photosAccessDenied

    var errorDescription: String? {
        switch self {
        case .invalidVideo: return "无法读取此视频或视频没有画面轨道"
        case .invalidRange: return "请选择 0.5 至 3 秒的片段，并将封面帧放在片段内"
        case .imageExport: return "无法生成实况照片封面"
        case .videoExport(let detail): return "无法生成实况照片视频：\(detail)"
        case .invalidPair(let detail): return "实况照片文件校验失败：\(detail)"
        case .photosAccessDenied: return "没有将实况照片添加到“照片”的权限"
        }
    }
}

enum LivePhotoService {
    static func videoDuration(at url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        guard !tracks.isEmpty, duration.isFinite, duration > 0 else { throw LivePhotoError.invalidVideo }
        return duration
    }

    @discardableResult
    static func generate(from sourceURL: URL, clip: LivePhotoClip,
                         destination: LivePhotoDestination) async throws -> LivePhotoPair? {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await videoDuration(at: sourceURL)
        let clip = try clip.validated(videoDuration: duration)

        if case .photos = destination {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                throw LivePhotoError.photosAccessDenied
            }
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftCull-LivePhoto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let identifier = UUID().uuidString
        let imageURL = temporary.appendingPathComponent("live.heic")
        let videoURL = temporary.appendingPathComponent("live.mov")

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(
            at: CMTime(seconds: clip.cover, preferredTimescale: 600))
        try writeImage(image, identifier: identifier, to: imageURL)
        try Task.checkCancellation()

        try await LivePhotoMOVWriter.write(
            asset: asset, clip: clip, identifier: identifier, to: videoURL)
        try await validate(imageURL: imageURL, videoURL: videoURL,
                           identifier: identifier, clip: clip)
        try Task.checkCancellation()

        switch destination {
        case .folder(let directory):
            return try exportPair(imageURL: imageURL, videoURL: videoURL,
                                  sourceName: sourceURL.deletingPathExtension().lastPathComponent,
                                  to: directory)
        case .photos:
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: imageURL, options: nil)
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
            }
            return nil
        }
    }

    private static func writeImage(_ image: CGImage, identifier: String, to url: URL) throws {
        guard let output = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw LivePhotoError.imageExport
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: ["17": identifier],
            kCGImageDestinationLossyCompressionQuality: 0.95
        ]
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw LivePhotoError.imageExport }
    }

    private static func exportPair(imageURL: URL, videoURL: URL,
                                   sourceName: String, to directory: URL) throws -> LivePhotoPair {
        let accessed = directory.startAccessingSecurityScopedResource()
        defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
        let base = sourceName + " Live"
        var candidate = base
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate + ".heic").path)
                || FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate + ".mov").path) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        let imageDestination = directory.appendingPathComponent(candidate + ".heic")
        let videoDestination = directory.appendingPathComponent(candidate + ".mov")
        try FileManager.default.copyItem(at: imageURL, to: imageDestination)
        do {
            try FileManager.default.copyItem(at: videoURL, to: videoDestination)
        } catch {
            try? FileManager.default.removeItem(at: imageDestination)
            throw error
        }
        return LivePhotoPair(imageURL: imageDestination, videoURL: videoDestination)
    }

    private static func validate(imageURL: URL, videoURL: URL,
                                 identifier: String, clip: LivePhotoClip) async throws {
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any],
              maker["17"] as? String == identifier else {
            throw LivePhotoError.invalidPair("封面标识不匹配")
        }

        let asset = AVURLAsset(url: videoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        guard !videoTracks.isEmpty, duration.isFinite,
              abs(duration - clip.duration) <= 0.15 else {
            throw LivePhotoError.invalidPair("视频轨道或时长不正确")
        }

        let metadata = try await asset.load(.metadata)
        let identifiers = AVMetadataItem.metadataItems(
            from: metadata, withKey: "com.apple.quicktime.content.identifier" as NSString,
            keySpace: .quickTimeMetadata)
        guard let movieIdentifier = identifiers.first,
              try await movieIdentifier.load(.stringValue) == identifier else {
            throw LivePhotoError.invalidPair("视频标识不匹配")
        }

        let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
        for track in metadataTracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else { continue }
            while let group = adaptor.nextTimedMetadataGroup() {
                let items = AVMetadataItem.metadataItems(
                    from: group.items,
                    withKey: "com.apple.quicktime.still-image-time" as NSString,
                    keySpace: .quickTimeMetadata)
                if let item = items.first,
                   try await item.load(.numberValue)?.intValue == 0,
                   abs(group.timeRange.start.seconds - clip.coverOffset) <= 1.0 / 15.0 {
                    return
                }
            }
        }
        throw LivePhotoError.invalidPair("缺少封面帧时间元数据")
    }
}
