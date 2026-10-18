import AppKit
import CoreText
import CryptoKit

struct WatermarkFont: Identifiable, Sendable {
    let id: String
    let name: String
    let family: String
    let file: String?

    static let catalog: [WatermarkFont] = [
        .init(id: "roboto", name: "Roboto", family: "Roboto", file: "Roboto"),
        .init(id: "merriweather", name: "Merriweather", family: "Merriweather", file: "Merriweather"),
        .init(id: "noto-sans-sc", name: "思源黑体", family: "Noto Sans SC", file: "NotoSansSC"),
        .init(id: "noto-serif-sc", name: "思源宋体", family: "Noto Serif SC", file: "NotoSerifSC"),
        .init(id: "lxgw-wenkai", name: "霞鹜文楷", family: "LXGW WenKai", file: "LXGWWenKai"),
        .init(id: "allura", name: "Allura", family: "Allura", file: "Allura"),
        .init(id: "caveat", name: "Caveat", family: "Caveat", file: "Caveat"),
        .init(id: "dancing-script", name: "Dancing Script", family: "Dancing Script", file: "DancingScript"),
        .init(id: "great-vibes", name: "Great Vibes", family: "Great Vibes", file: "GreatVibes"),
        .init(id: "kn-maiyuan", name: "荆南麦圆体", family: "KN Maiyuan", file: "KNMaiyuan"),
        .init(id: "liu-jian-mao-cao", name: "刘建毛草", family: "Liu Jian Mao Cao", file: "LiuJianMaoCao"),
        .init(id: "long-cang", name: "龙藏体", family: "Long Cang", file: "LongCang"),
        .init(id: "lxgw-marker-gothic", name: "霞鹜漫黑", family: "LXGW Marker Gothic", file: "LXGWMarkerGothic"),
        .init(id: "ma-shan-zheng", name: "马善政毛笔楷书", family: "Ma Shan Zheng", file: "MaShanZheng"),
        .init(id: "pacifico", name: "Pacifico", family: "Pacifico", file: "Pacifico"),
        .init(id: "parisienne", name: "Parisienne", family: "Parisienne", file: "Parisienne"),
        .init(id: "sacramento", name: "Sacramento", family: "Sacramento", file: "Sacramento"),
        .init(id: "zhi-mang-xing", name: "志莽行书", family: "Zhi Mang Xing", file: "ZhiMangXing")
    ]

    static let local: [WatermarkFont] = [
        .init(id: "local-times-new-roman", name: "Times New Roman", family: "Times New Roman", file: nil),
        .init(id: "local-georgia", name: "Georgia", family: "Georgia", file: nil),
        .init(id: "local-arial", name: "Arial", family: "Arial", file: nil),
        .init(id: "local-songti-sc", name: "宋体", family: "Songti SC", file: nil),
        .init(id: "local-pingfang-sc", name: "苹方", family: "PingFang SC", file: nil)
    ]

    static let bundled = catalog.filter { ["roboto", "caveat", "dancing-script"].contains($0.id) }
    static let downloadable = catalog.filter { option in !bundled.contains { $0.id == option.id } }
    static var all: [WatermarkFont] { catalog + local }
    var download: WatermarkFontDownload? { file.flatMap { WatermarkFontDownload.catalog[$0] } }

    static var downloadDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["SWIFTCULL_WATERMARK_FONT_DOWNLOADS_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftCull/Fonts", isDirectory: true)
    }

    var downloadedURL: URL? { file.map { Self.downloadDirectory.appendingPathComponent($0 + ".ttf") } }

    static func isAvailable(_ option: WatermarkFont) -> Bool {
        WatermarkFontRegistration.shared.register(option)
        return NSFont(name: option.family, size: 16) != nil
    }

    static func resolve(id: String?, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let size = max(7, size)
        guard let id, let option = all.first(where: { $0.id == id }) else {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        WatermarkFontRegistration.shared.register(option)
        guard let font = NSFont(name: option.family, size: size) else {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        return weight >= .semibold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    }

    static func missing(in configurations: [WatermarkConfiguration]) -> [WatermarkFont] {
        let ids = Set(configurations.flatMap { $0.components.filter { $0.kind != .logo }.compactMap(\.fontID) })
        return all.filter { ids.contains($0.id) && !isAvailable($0) }
    }

    static func requireAvailable(in configurations: [WatermarkConfiguration]) throws {
        let missing = missing(in: configurations)
        if !missing.isEmpty { throw WatermarkFontError.unavailable(missing.map(\.name).joined(separator: "、")) }
    }

    static func registerBundledFonts() { bundled.forEach { WatermarkFontRegistration.shared.register($0) } }
}

enum WatermarkFontError: LocalizedError {
    case unavailable(String), invalidDownload
    var errorDescription: String? {
        switch self {
        case .unavailable(let names): return "字体尚未就绪：\(names)。请下载字体或改用系统字体。"
        case .invalidDownload: return "字体文件校验失败，请重新下载。"
        }
    }
}

/// Registration is process-local and idempotent. Rendering never initiates network requests.
private final class WatermarkFontRegistration: @unchecked Sendable {
    static let shared = WatermarkFontRegistration()
    private let lock = NSLock()
    private var registered: Set<String> = []

    func register(_ option: WatermarkFont) {
        guard let file = option.file else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !registered.contains(option.id) else { return }
        let override = ProcessInfo.processInfo.environment["SWIFTCULL_WATERMARK_FONTS_DIR"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(file + ".ttf") }
        let bundledURL = WatermarkFont.bundled.contains { $0.id == option.id }
            ? (Bundle.main.url(forResource: file, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.main.url(forResource: file, withExtension: "ttf")) : nil
        let url = override ?? bundledURL ?? option.downloadedURL
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        if override == nil && bundledURL == nil {
            guard let download = option.download, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count == download.bytes,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == download.sha256 else { return }
        }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        if NSFont(name: option.family, size: 16) != nil { registered.insert(option.id) }
    }
}
