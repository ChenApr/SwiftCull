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
    case missingPreset

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "无法读取照片图像"
        case .encodingFailed: return "无法生成 JPEG"
        case .missingPreset: return "有自定义预设已被删除，请重新选择"
        }
    }
}

enum WatermarkExportChoice: Hashable, Sendable {
    case builtIn(WatermarkPreset)
    case custom(UUID)
}

struct WatermarkOverlayChoice: Identifiable, Hashable, Sendable {
    let id: UUID
    var choice: WatermarkExportChoice
    var matchOrientation: Bool

    init(id: UUID = UUID(), choice: WatermarkExportChoice, matchOrientation: Bool = true) {
        self.id = id
        self.choice = choice
        self.matchOrientation = matchOrientation
    }
}

struct WatermarkReviewItem: Identifiable, Sendable {
    let photo: PhotoEntry
    let sourcePath: String
    var include = true
    var choice: WatermarkExportChoice = .builtIn(.standard)
    var matchOrientation = true
    var overlays: [WatermarkOverlayChoice] = []
    var id: String { photo.id }
}

/// Immutable choices captured from the review sheet so preview and export use the same settings.
enum WatermarkExportStyle: Sendable {
    case preset(WatermarkPreset)
    case custom(WatermarkConfiguration)
}

struct WatermarkExportLayer: Sendable {
    let style: WatermarkExportStyle
    let matchOrientation: Bool
}

struct WatermarkExportRequest: Sendable {
    let photo: PhotoEntry
    let sourcePath: String
    let style: WatermarkExportStyle
    let matchOrientation: Bool
    let overlays: [WatermarkExportLayer]
}

enum WatermarkReviewPlan {
    static func requests(from items: [WatermarkReviewItem],
                         configurations: [WatermarkConfiguration]) throws -> [WatermarkExportRequest] {
        try items.filter(\.include).map { try request(for: $0, configurations: configurations) }
    }

    static func request(for item: WatermarkReviewItem,
                        configurations: [WatermarkConfiguration]) throws -> WatermarkExportRequest {
        let primary = try layer(for: item.choice, matchOrientation: item.matchOrientation,
                                configurations: configurations)
        let overlays = try item.overlays.map {
            try layer(for: $0.choice, matchOrientation: $0.matchOrientation,
                      configurations: configurations)
        }
        return WatermarkExportRequest(photo: item.photo, sourcePath: item.sourcePath,
                                      style: primary.style, matchOrientation: primary.matchOrientation,
                                      overlays: overlays)
    }

    private static func layer(for choice: WatermarkExportChoice, matchOrientation: Bool,
                              configurations: [WatermarkConfiguration]) throws -> WatermarkExportLayer {
        switch choice {
        case .builtIn(let preset):
            return WatermarkExportLayer(style: .preset(preset), matchOrientation: matchOrientation)
        case .custom(let id):
            guard let configuration = configurations.first(where: { $0.id == id }) else {
                throw WatermarkError.missingPreset
            }
            return WatermarkExportLayer(style: .custom(configuration), matchOrientation: matchOrientation)
        }
    }
}

enum WatermarkService {
    static func renderBase(prepared: WatermarkCustomRenderer.PreparedSource,
                           style: WatermarkExportStyle,
                           matchOrientation: Bool) throws -> SemiWatermarkRenderer.RenderedCanvas {
        switch style {
        case .preset(let preset):
            return try SemiWatermarkRenderer.renderCanvas(prepared: prepared.semi, preset: preset,
                                                           matchOrientation: matchOrientation)
        case .custom(let configuration):
            return try WatermarkCustomRenderer.renderCanvas(prepared: prepared,
                                                              configuration: configuration)
        }
    }

    static func render(prepared: WatermarkCustomRenderer.PreparedSource,
                       base: SemiWatermarkRenderer.RenderedCanvas,
                       overlays: [WatermarkExportLayer]) throws -> NSBitmapImageRep {
        let portrait = prepared.semi.image.height > prepared.semi.image.width
        let configurations: [WatermarkConfiguration] = overlays.map { layer in
            switch layer.style {
            case .preset(let preset):
                return .draft(from: preset.resolved(isPortrait: portrait,
                                                    matchOrientation: layer.matchOrientation))
            case .custom(let saved):
                let preset = saved.basePreset.resolved(isPortrait: portrait,
                                                       matchOrientation: saved.matchOrientation == true)
                return saved.adapted(to: preset)
            }
        }
        return try WatermarkCustomRenderer.overlay(prepared: prepared, configurations: configurations,
                                                   on: base).bitmap
    }

    static func render(prepared: WatermarkCustomRenderer.PreparedSource,
                       request: WatermarkExportRequest) throws -> NSBitmapImageRep {
        let base = try renderBase(prepared: prepared, style: request.style,
                                  matchOrientation: request.matchOrientation)
        return try render(prepared: prepared, base: base, overlays: request.overlays)
    }

    static func previewData(request: WatermarkExportRequest,
                            prepared: WatermarkCustomRenderer.PreparedSource) throws -> Data {
        let base = try renderBase(prepared: prepared, style: request.style,
                                  matchOrientation: request.matchOrientation)
        return try previewData(prepared: prepared, base: base, overlays: request.overlays)
    }

    static func previewData(prepared: WatermarkCustomRenderer.PreparedSource,
                            base: SemiWatermarkRenderer.RenderedCanvas,
                            overlays: [WatermarkExportLayer]) throws -> Data {
        guard let data = try render(prepared: prepared, base: base, overlays: overlays)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw WatermarkError.encodingFailed
        }
        return data
    }

    static func jpegData(request: WatermarkExportRequest) throws -> Data {
        let prepared = try WatermarkCustomRenderer.prepare(photo: request.photo,
                                                            sourcePath: request.sourcePath)
        guard let data = try render(prepared: prepared, request: request)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw WatermarkError.encodingFailed
        }
        return data
    }

    @discardableResult
    static func export(request: WatermarkExportRequest, to directory: URL) throws -> URL {
        let data = try jpegData(request: request)
        return try write(data, sourcePath: request.sourcePath, to: directory)
    }

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
