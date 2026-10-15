import AppKit
import CoreText

struct WatermarkFont: Identifiable {
    let id: String
    let name: String
    let family: String
    let file: String?

    static let bundled: [WatermarkFont] = [
        .init(id: "roboto", name: "Roboto", family: "Roboto", file: "Roboto"),
        .init(id: "merriweather", name: "Merriweather", family: "Merriweather", file: "Merriweather"),
        .init(id: "noto-sans-sc", name: "思源黑体", family: "Noto Sans SC", file: "NotoSansSC"),
        .init(id: "noto-serif-sc", name: "思源宋体", family: "Noto Serif SC", file: "NotoSerifSC"),
        .init(id: "lxgw-wenkai", name: "霞鹜文楷", family: "LXGW WenKai", file: "LXGWWenKai"),
        .init(id: "allura", name: "Allura", family: "Allura", file: "Allura"),
        .init(id: "caveat", name: "Caveat", family: "Caveat", file: "Caveat"),
        .init(id: "dancing-script", name: "Dancing Script", family: "Dancing Script", file: "DancingScript"),
        .init(id: "great-vibes", name: "Great Vibes", family: "Great Vibes", file: "GreatVibes"),
        .init(id: "long-cang", name: "龙藏体", family: "Long Cang", file: "LongCang"),
        .init(id: "ma-shan-zheng", name: "马善政毛笔楷书", family: "Ma Shan Zheng", file: "MaShanZheng"),
        .init(id: "pacifico", name: "Pacifico", family: "Pacifico", file: "Pacifico"),
        .init(id: "parisienne", name: "Parisienne", family: "Parisienne", file: "Parisienne"),
        .init(id: "sacramento", name: "Sacramento", family: "Sacramento", file: "Sacramento"),
        .init(id: "zhi-mang-xing", name: "志莽行书", family: "Zhi Mang Xing", file: "ZhiMangXing")
    ]

    static let local: [WatermarkFont] = [
        .init(id: "local-times-new-roman", name: "Times New Roman", family: "Times New Roman", file: nil),
        .init(id: "local-songti-sc", name: "宋体", family: "Songti SC", file: nil)
    ]

    static func isAvailable(_ option: WatermarkFont) -> Bool {
        registerBundledFonts()
        return NSFont(name: option.family, size: 16) != nil
    }

    static func resolve(id: String?, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let size = max(7, size)
        guard let id, let option = (bundled + local).first(where: { $0.id == id }) else {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        registerBundledFonts()
        guard let font = NSFont(name: option.family, size: size) else {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        return weight >= .semibold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    }

    private static let registration: Void = {
        for option in bundled {
            guard let file = option.file,
                  let url = ProcessInfo.processInfo.environment["SWIFTCULL_WATERMARK_FONTS_DIR"]
                    .map({ URL(fileURLWithPath: $0).appendingPathComponent("\(file).ttf") })
                    ?? Bundle.main.url(forResource: file, withExtension: "ttf", subdirectory: "Fonts")
                    ?? Bundle.main.url(forResource: file, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func registerBundledFonts() { _ = registration }
}
