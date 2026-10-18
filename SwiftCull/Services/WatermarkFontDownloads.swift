import AppKit
import Combine
import CoreText
import CryptoKit

@MainActor
final class WatermarkFontDownloads: ObservableObject {
    enum State: Equatable {
        case downloading
        case failed(String)
        case ready
    }

    static let shared = WatermarkFontDownloads()
    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var revision = 0
    private var tasks: [String: Task<Void, Never>] = [:]
    private var requests: [String: UUID] = [:]
    private let transfer: @Sendable (URL) async throws -> URL

    init(transfer: @escaping @Sendable (URL) async throws -> URL = { try await WatermarkFontDownloads.fetch($0) }) {
        self.transfer = transfer
    }

    func download(_ option: WatermarkFont) {
        guard option.download != nil, tasks[option.id] == nil else { return }
        let request = UUID()
        requests[option.id] = request
        states[option.id] = .downloading
        tasks[option.id] = Task {
            do {
                let transfer = transfer
                let install = Task.detached(priority: .utility) {
                    try await Self.install(option, directory: WatermarkFont.downloadDirectory, transfer: transfer)
                }
                try await withTaskCancellationHandler {
                    try await install.value
                } onCancel: { install.cancel() }
                try Task.checkCancellation()
                guard requests[option.id] == request else { return }
                guard WatermarkFont.isAvailable(option) else { throw WatermarkFontError.invalidDownload }
                states[option.id] = .ready
                revision += 1
            } catch {
                guard requests[option.id] == request else { return }
                states[option.id] = .failed(error.localizedDescription)
            }
            if requests[option.id] == request {
                tasks[option.id] = nil
                requests[option.id] = nil
            }
        }
    }

    func cancel(_ option: WatermarkFont) {
        requests[option.id] = nil
        tasks.removeValue(forKey: option.id)?.cancel()
        states[option.id] = nil
    }

    func label(for option: WatermarkFont) -> String {
        if states[option.id] == .ready || option.downloadedURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
            return option.name
        }
        return option.name + "（需下载）"
    }

    /// Stage and verify the exact upstream bytes before replacing a cached font.
    /// A failed/cancelled transfer never publishes a partial font file.
    nonisolated static func install(_ option: WatermarkFont, directory: URL,
                                    transfer: @Sendable (URL) async throws -> URL = { try await WatermarkFontDownloads.fetch($0) }) async throws {
        guard let source = option.download, let file = option.file else { throw WatermarkFontError.invalidDownload }
        let temporary = try await transfer(source.url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
        guard data.count == source.bytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == source.sha256,
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(temporary as CFURL) as? [CTFontDescriptor],
              descriptors.contains(where: {
                  CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String == option.family
              }) else { throw WatermarkFontError.invalidDownload }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(file + ".ttf"), options: .atomic)
    }

    nonisolated static func fetch(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (file, response) = try await URLSession.shared.download(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw URLError(.badServerResponse)
        }
        return file
    }
}
