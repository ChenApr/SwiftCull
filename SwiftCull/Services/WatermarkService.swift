import AppKit

/// The 15 built-in template names from semi-utils/config/templates.
enum WatermarkPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard = "标准水印"
    case standardCard = "标准水印2"
    case nikonBlur = "尼康专用背景模糊"
    case blur = "背景模糊"
    case cornerParameters = "右下角参数"
    case folderAndDate = "文件夹名+右下角参数"
    case centerBrand = "logo居中"
    case standardPortrait = "标准水印（竖拍）"
    case standardCardPortrait = "标准水印2（竖拍）"
    case nikonBlurPortrait = "尼康专用背景模糊（竖拍）"
    case nikonPortrait = "尼康竖拍"
    case blurPortrait = "背景模糊（竖拍）"
    case cornerParametersPortrait = "右下角参数（竖拍）"
    case folderAndDatePortrait = "文件夹名+右下角参数（竖拍）"
    case centerBrandPortrait = "logo居中（竖拍）"

    var id: String { rawValue }

    static let landscapePresets: [WatermarkPreset] = [
        .standard, .standardCard, .nikonBlur, .blur,
        .cornerParameters, .folderAndDate, .centerBrand
    ]
    static let portraitPresets: [WatermarkPreset] = [
        .standardPortrait, .standardCardPortrait, .nikonBlurPortrait, .nikonPortrait,
        .blurPortrait, .cornerParametersPortrait, .folderAndDatePortrait, .centerBrandPortrait
    ]

    enum Layout: Equatable, Sendable {
        case standard, card, nikonCard, nikonBlur, blur, cornerParameters, folderAndDate, centerBrand
    }

    var layout: Layout {
        switch self {
        case .standard, .standardPortrait: return .standard
        case .standardCard, .standardCardPortrait: return .card
        case .nikonPortrait: return .nikonCard
        case .nikonBlur, .nikonBlurPortrait: return .nikonBlur
        case .blur, .blurPortrait: return .blur
        case .cornerParameters, .cornerParametersPortrait: return .cornerParameters
        case .folderAndDate, .folderAndDatePortrait: return .folderAndDate
        case .centerBrand, .centerBrandPortrait: return .centerBrand
        }
    }

    var isPortraitPreset: Bool { Self.portraitPresets.contains(self) }

    func resolved(isPortrait: Bool, matchOrientation: Bool) -> WatermarkPreset {
        guard matchOrientation else { return self }
        switch layout {
        case .standard: return isPortrait ? .standardPortrait : .standard
        case .card: return isPortrait ? .standardCardPortrait : .standardCard
        case .nikonCard: return .nikonPortrait
        case .nikonBlur: return isPortrait ? .nikonBlurPortrait : .nikonBlur
        case .blur: return isPortrait ? .blurPortrait : .blur
        case .cornerParameters: return isPortrait ? .cornerParametersPortrait : .cornerParameters
        case .folderAndDate: return isPortrait ? .folderAndDatePortrait : .folderAndDate
        case .centerBrand: return isPortrait ? .centerBrandPortrait : .centerBrand
        }
    }

    var detail: String {
        switch layout {
        case .standard: return "白色边框，显示相机、镜头、拍摄参数与日期"
        case .card, .nikonCard: return "圆角照片与宽留白，显示 EXIF 信息"
        case .nikonBlur: return "模糊照片背景，红色尼康风格点缀"
        case .blur: return "模糊照片背景，居中显示拍摄信息"
        case .cornerParameters: return "在照片右下角叠加拍摄参数"
        case .folderAndDate: return "在照片右下角显示文件夹名和日期"
        case .centerBrand: return "白色边框，底部居中显示相机品牌"
        }
    }
}

enum WatermarkError: LocalizedError {
    case unreadableImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "无法读取照片图像"
        case .encodingFailed: return "无法生成 JPEG"
        }
    }
}

enum WatermarkService {
    static func render(photo: PhotoEntry, preset: WatermarkPreset, sourcePath: String? = nil,
                       matchOrientation: Bool = false, maxPixelSize: Int? = nil) throws -> NSBitmapImageRep {
        try SemiWatermarkRenderer.render(photo: photo, preset: preset, sourcePath: sourcePath,
                                         matchOrientation: matchOrientation, maxPixelSize: maxPixelSize)
    }

    static func jpegData(photo: PhotoEntry, preset: WatermarkPreset, sourcePath: String? = nil,
                         matchOrientation: Bool = false) throws -> Data {
        guard let data = try render(photo: photo, preset: preset, sourcePath: sourcePath,
                                    matchOrientation: matchOrientation).representation(
            using: .jpeg, properties: [.compressionFactor: 0.92]
        ) else { throw WatermarkError.encodingFailed }
        return data
    }

    static func previewData(photo: PhotoEntry, preset: WatermarkPreset, sourcePath: String? = nil,
                            matchOrientation: Bool = false) throws -> Data {
        guard let data = try render(photo: photo, preset: preset, sourcePath: sourcePath,
                                    matchOrientation: matchOrientation, maxPixelSize: 1200).representation(
            using: .jpeg, properties: [.compressionFactor: 0.8]
        ) else { throw WatermarkError.encodingFailed }
        return data
    }

    static func previewData(photo: PhotoEntry, configuration: WatermarkConfiguration,
                            sourcePath: String? = nil) throws -> Data {
        guard let data = try WatermarkCustomRenderer.render(photo: photo, configuration: configuration,
                                                            sourcePath: sourcePath, maxPixelSize: 1200)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw WatermarkError.encodingFailed
        }
        return data
    }

    static func jpegData(photo: PhotoEntry, configuration: WatermarkConfiguration,
                         sourcePath: String? = nil) throws -> Data {
        guard let data = try WatermarkCustomRenderer.render(photo: photo, configuration: configuration,
                                                            sourcePath: sourcePath)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw WatermarkError.encodingFailed
        }
        return data
    }

    @discardableResult
    static func export(photo: PhotoEntry, preset: WatermarkPreset, sourcePath: String,
                       matchOrientation: Bool, to directory: URL) throws -> URL {
        let data = try jpegData(photo: photo, preset: preset, sourcePath: sourcePath,
                                matchOrientation: matchOrientation)
        return try write(data, sourcePath: sourcePath, to: directory)
    }

    @discardableResult
    static func export(photo: PhotoEntry, configuration: WatermarkConfiguration,
                       sourcePath: String, to directory: URL) throws -> URL {
        let data = try jpegData(photo: photo, configuration: configuration, sourcePath: sourcePath)
        return try write(data, sourcePath: sourcePath, to: directory)
    }

    private static func write(_ data: Data, sourcePath: String, to directory: URL) throws -> URL {
        let source = URL(fileURLWithPath: sourcePath)
        let name = source.deletingPathExtension().lastPathComponent + "_watermark"
        let fileManager = FileManager.default
        let temporary = directory.appendingPathComponent(".swiftcull-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        defer { try? fileManager.removeItem(at: temporary) }

        var suffix = 1
        while true {
            let candidateName = suffix == 1 ? name : "\(name)_\(suffix)"
            let destination = directory.appendingPathComponent(candidateName).appendingPathExtension("jpg")
            do {
                try fileManager.moveItem(at: temporary, to: destination)
                return destination
            } catch {
                guard fileManager.fileExists(atPath: destination.path) else { throw error }
                suffix += 1
            }
        }
    }
}
