import AppKit
import CryptoKit

private actor RetryFontTransfer {
    private var attempts = 0
    let source: URL
    let directory: URL

    init(source: URL, directory: URL) { self.source = source; self.directory = directory }

    func fetch(_ url: URL) async throws -> URL {
        attempts += 1
        if attempts == 1 { throw URLError(.notConnectedToInternet) }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".ttf")
        try FileManager.default.copyItem(at: source, to: temporary)
        return temporary
    }
}

@main
struct WatermarkFontDownloadSmoke {
    @MainActor
    static func eventually(_ predicate: () -> Bool, file: StaticString = #file, line: UInt = #line) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Font download timed out", file: file, line: line)
    }

    @MainActor
    static func main() async throws {
        if CommandLine.arguments.contains("--cached-only") {
            let font = WatermarkFont.downloadable.first { $0.id == "allura" }!
            precondition(WatermarkFont.isAvailable(font))
            precondition(WatermarkFont.resolve(id: font.id, size: 20, weight: .regular).familyName == font.family)
            print("Offline restart passed: cached Allura registered in a fresh process")
            return
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SwiftCull-FontDownloads-\(UUID())")
        let downloads = root.appendingPathComponent("downloads")
        let bundled = root.appendingPathComponent("bundled")
        try fm.createDirectory(at: bundled, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWIFTCULL_FONT_TEST_SOURCE"]!)
        setenv("SWIFTCULL_WATERMARK_FONT_DOWNLOADS_DIR", downloads.path, 1)
        // Only bundled resources are visible through the development override.
        for option in WatermarkFont.bundled {
            try fm.copyItem(at: source.appendingPathComponent(option.file! + ".ttf"),
                            to: bundled.appendingPathComponent(option.file! + ".ttf"))
        }
        // Resolve actual bundled fonts before clearing the override to exercise
        // optional downloads through the same path as the packaged application.
        setenv("SWIFTCULL_WATERMARK_FONTS_DIR", bundled.path, 1)
        precondition(WatermarkFont.bundled.allSatisfy(WatermarkFont.isAvailable))
        unsetenv("SWIFTCULL_WATERMARK_FONTS_DIR")
        precondition(WatermarkFont.bundled.count == 3 && WatermarkFont.downloadable.count == 15)
        precondition(WatermarkFont.catalog.count == 18 && Set(WatermarkFont.all.map(\.id)).count == 23)
        let smallBytes = try WatermarkFont.bundled.reduce(0) {
            $0 + (try Data(contentsOf: source.appendingPathComponent($1.file! + ".ttf"))).count
        }
        precondition(smallBytes < 1_100_000)
        let option = WatermarkFont.downloadable.first { $0.id == "allura" }!
        var preset = WatermarkConfiguration.draft(from: .standard)
        preset.components[0].fontID = option.id
        precondition(WatermarkFont.missing(in: [preset]).map(\.id) == [option.id])
        do {
            try WatermarkFont.requireAvailable(in: [preset])
            preconditionFailure("A missing saved font was silently substituted")
        } catch is WatermarkFontError {}
        let roundtrip = try JSONDecoder().decode(WatermarkConfiguration.self, from: JSONEncoder().encode(preset))
        precondition(roundtrip.components[0].fontID == option.id)
        preset.components[0].fontID = nil
        try WatermarkFont.requireAvailable(in: [preset])

        // All catalog entries install offline from exact original source bytes.
        // The transport hands ownership of a temporary file to the installer.
        var offlineInstalled = 0
        for font in WatermarkFont.downloadable {
            let fixture = try Data(contentsOf: source.appendingPathComponent(font.file! + ".ttf"))
            let fixtureHash = SHA256.hash(data: fixture).map { String(format: "%02x", $0) }.joined()
            if fixtureHash != font.download?.sha256 {
                // The Marker Gothic release ZIP and Git tree contain builds
                // with different checksums. Production accepts only the pinned
                // Git-tree bytes, never a merely similar local font.
                precondition(font.id == "lxgw-marker-gothic")
                do {
                    try await WatermarkFontDownloads.install(font, directory: downloads) { _ in
                        let temporary = root.appendingPathComponent(UUID().uuidString + ".ttf")
                        try fixture.write(to: temporary)
                        return temporary
                    }
                    preconditionFailure("A different upstream build bypassed validation")
                } catch is WatermarkFontError {}
                continue
            }
            try await WatermarkFontDownloads.install(font, directory: downloads) { _ in
                let temporary = root.appendingPathComponent(UUID().uuidString + ".ttf")
                try FileManager.default.copyItem(at: source.appendingPathComponent(font.file! + ".ttf"), to: temporary)
                return temporary
            }
            precondition(WatermarkFont.isAvailable(font), "Downloaded font did not register: \(font.id)")
            offlineInstalled += 1
        }
        try WatermarkFont.requireAvailable(in: [roundtrip])
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--cached-only"]
        child.environment = ProcessInfo.processInfo.environment
        try child.run()
        child.waitUntilExit()
        precondition(child.terminationStatus == 0)
        let expected = try Data(contentsOf: option.downloadedURL!)
        // Truncated/untrusted bytes cannot overwrite the valid cached font.
        do {
            try await WatermarkFontDownloads.install(option, directory: downloads) { _ in
                let invalid = root.appendingPathComponent("invalid.ttf")
                try Data("not a font".utf8).write(to: invalid)
                return invalid
            }
            preconditionFailure("Invalid font bytes were accepted")
        } catch is WatermarkFontError {}
        let afterInvalidDownload = try Data(contentsOf: option.downloadedURL!)
        precondition(afterInvalidDownload == expected)
        let cancelled = Task {
            try await WatermarkFontDownloads.install(option, directory: root.appendingPathComponent("cancelled")) { _ in
                try await Task.sleep(for: .seconds(2))
                fatalError("Cancelled transfer must never finish")
            }
        }
        cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("Cancellation was ignored") } catch {}
        precondition(!fm.fileExists(atPath: root.appendingPathComponent("cancelled").path))

        // Failure, cancellation, retry and deduplication are observable UI states.
        let transfer = RetryFontTransfer(source: source.appendingPathComponent(option.file! + ".ttf"), directory: root)
        let retrying = WatermarkFontDownloads { try await transfer.fetch($0) }
        retrying.download(option)
        try await eventually { if case .failed = retrying.states[option.id] { return true }; return false }
        retrying.download(option)
        try await eventually { retrying.states[option.id] == .ready }
        let slow = WatermarkFontDownloads { _ in
            try await Task.sleep(for: .seconds(2))
            throw URLError(.timedOut)
        }
        slow.download(option)
        slow.download(option)
        precondition(slow.states[option.id] == .downloading)
        slow.cancel(option)
        try await Task.sleep(for: .milliseconds(30))
        precondition(slow.states[option.id] == nil)
        let successful = WatermarkFontDownloads { _ in
            let temporary = root.appendingPathComponent(UUID().uuidString + ".ttf")
            try FileManager.default.copyItem(at: source.appendingPathComponent(option.file! + ".ttf"), to: temporary)
            return temporary
        }
        successful.download(option)
        successful.download(option)
        try await eventually { successful.states[option.id] == .ready }
        precondition(successful.revision == 1)
        // Optional real transfer: no font is installed system-wide or in the user's cache.
        if ProcessInfo.processInfo.environment["SWIFTCULL_FONT_NETWORK_TEST"] == "1" {
            try await WatermarkFontDownloads.install(option, directory: root.appendingPathComponent("network"))
            let marker = WatermarkFont.downloadable.first { $0.id == "lxgw-marker-gothic" }!
            try await WatermarkFontDownloads.install(marker, directory: downloads)
            precondition(WatermarkFont.isAvailable(marker))
            print("Real upstream download passed: Allura, checksum and font descriptor verified")
        }
        print("Font download smoke passed: 3 bundled fonts (\(smallBytes) bytes), \(offlineInstalled) offline installs, stable preset IDs, missing-font guard, corruption rejection, cancel/failure/retry states and deduplication")
    }
}
