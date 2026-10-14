import Foundation

@MainActor
final class WatermarkPresetStore: ObservableObject {
    @Published private(set) var configurations: [WatermarkConfiguration] = []
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftCull/WatermarkPresets", isDirectory: true)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        configurations = files.filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let config = try? decoder.decode(WatermarkConfiguration.self, from: data),
                      url.deletingPathExtension().lastPathComponent == config.id.uuidString else { return nil }
                return config
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ configuration: WatermarkConfiguration) throws {
        var validated = configuration
        validated.name = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !validated.name.isEmpty else { throw PresetError.emptyName }
        guard !configurations.contains(where: { $0.id != validated.id && $0.name == validated.name }) else {
            throw PresetError.duplicateName
        }
        guard (0...20).contains(validated.paddingPercent),
              (0...35).contains(validated.footerPercent),
              (0...10).contains(validated.cornerRadiusPercent),
              validated.components.count <= 32,
              validated.components.allSatisfy({ (0.5...8).contains($0.fontPercent) }) else {
            throw PresetError.invalidValue
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(validated.id.uuidString).appendingPathExtension("json")
        let data = try JSONEncoder().encode(validated)
        try data.write(to: target, options: .atomic)
        reload()
    }

    func delete(_ id: UUID) throws {
        let target = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        try FileManager.default.removeItem(at: target)
        reload()
    }

    enum PresetError: LocalizedError {
        case emptyName, duplicateName, invalidValue
        var errorDescription: String? {
            switch self {
            case .emptyName: return "请输入预设名称"
            case .duplicateName: return "已有同名自定义预设"
            case .invalidValue: return "预设参数超出允许范围"
            }
        }
    }
}
