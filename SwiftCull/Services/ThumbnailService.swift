import Foundation
import AppKit
import AVFoundation
import CryptoKit
import ImageIO

final class ThumbnailService: @unchecked Sendable {
    static let shared = ThumbnailService()

    /// Every caller, including preheating, uses the same key for the same rendered image.
    static func cacheKey(path: String, size: CGFloat, crop: CropRect? = nil) -> String {
        "\(path)|\(quantizedSize(size))|\(String(describing: crop))"
    }

    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: (@MainActor @Sendable (NSImage?) -> Void)?
        private var resolved = false

        func setCompletion(_ callback: @escaping @MainActor @Sendable (NSImage?) -> Void) {
            lock.lock()
            let alreadyResolved = resolved
            if !alreadyResolved { completion = callback }
            lock.unlock()
            if alreadyResolved { Task { @MainActor in callback(nil) } }
        }

        var isActive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !resolved
        }

        func resolve(_ image: NSImage?) {
            lock.lock()
            guard !resolved else { lock.unlock(); return }
            resolved = true
            let callback = completion
            completion = nil
            lock.unlock()
            if let callback { Task { @MainActor in callback(image) } }
        }
    }

    private struct PendingRequest {
        let generation: Int
        var waiters: [Waiter]
        var started = false
    }

    private let cache = NSCache<NSString, NSImage>()
    private let workQueue = DispatchQueue(label: "com.swiftcull.thumbnail.work", qos: .userInitiated, attributes: .concurrent)
    private let preheatQueue = DispatchQueue(label: "com.swiftcull.thumbnail.preheat", qos: .utility)
    private let diskWriteQueue = DispatchQueue(label: "com.swiftcull.thumbnail.disk", qos: .utility)
    private let stateQueue = DispatchQueue(label: "com.swiftcull.thumbnail.state")
    private let generationSemaphore = DispatchSemaphore(value: 4)
    private var inProgress: [String: PendingRequest] = [:]
    private var preheatWaiters: [Waiter] = []
    private var generation = 0

    private let diskCacheDir: URL
    private let fileManager = FileManager.default

    private static let maxDiskCacheBytes: Int64 = 500 * 1024 * 1024

    private init() {
        cache.countLimit = 800
        cache.totalCostLimit = 300 * 1024 * 1024

        let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheDir = cachesDir.appendingPathComponent("SwiftCull/Thumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
    }

    /// 将显示尺寸量化到固定台阶，使缩放网格时缩略图请求的缓存 key 保持稳定，
    /// 避免每变化 1pt 就重新生成缩略图导致的卡顿与闪烁。
    static func quantizedSize(_ size: CGFloat) -> Int {
        let step = 32
        let steps = max(2, Int((size / CGFloat(step)).rounded(.up)))
        return steps * step
    }

    func getCached(_ id: String) -> NSImage? {
        cache.object(forKey: id as NSString)
    }

    func thumbnail(path: String, id: String, size: CGFloat, crop: CropRect? = nil) async -> NSImage? {
        if let cached = getCached(id) {
            return cached
        }

        let waiter = Waiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.setCompletion { image in continuation.resume(returning: image) }
                enqueue(path: path, id: id, size: size, crop: crop, waiter: waiter, preheat: false)
            }
        } onCancel: {
            waiter.resolve(nil)
        }
    }

    func generateThumbnail(path: String, id: String, size: CGFloat, crop: CropRect? = nil,
                           completion: @escaping @MainActor @Sendable (NSImage?) -> Void) {
        let waiter = Waiter()
        waiter.setCompletion(completion)
        enqueue(path: path, id: id, size: size, crop: crop, waiter: waiter, preheat: false)
    }

    private func enqueue(path: String, id: String, size: CGFloat, crop: CropRect?, waiter: Waiter,
                         preheat: Bool) {
        guard waiter.isActive else { return }
        if let cached = getCached(id) {
            waiter.resolve(cached)
            return
        }

        var requestGeneration = 0
        var promote = false
        let shouldStart = stateQueue.sync {
            guard waiter.isActive else { return false }
            if var pending = inProgress[id] {
                pending.waiters.append(waiter)
                if !preheat && !pending.started {
                    promote = true
                    requestGeneration = pending.generation
                }
                inProgress[id] = pending
                return false
            }

            requestGeneration = generation
            inProgress[id] = PendingRequest(generation: requestGeneration, waiters: [waiter])
            return true
        }

        guard shouldStart || promote else { return }

        let generationForRequest = requestGeneration
        let queue = preheat ? preheatQueue : workQueue
        queue.async { [weak self] in
            self?.produceThumbnail(path: path, id: id, size: size, crop: crop, generation: generationForRequest)
        }
    }

    func cancelPending() {
        let waiters = stateQueue.sync { () -> [Waiter] in
            generation += 1
            let waiters = inProgress.values.flatMap(\.waiters)
            inProgress.removeAll()
            preheatWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resolve(nil) }
    }

    func clearInMemoryCache() {
        cache.removeAllObjects()
    }

    func cleanupDiskCache() {
        workQueue.async { [weak self] in
            self?.performDiskCacheCleanup()
        }
    }

    private func performDiskCacheCleanup() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: diskCacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: []
        ) else { return }

        var totalSize: Int64 = 0
        var fileInfos: [(url: URL, size: Int64, date: Date)] = []

        for file in files {
            guard file.pathExtension == "jpg" else { continue }
            let resources = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(resources?.fileSize ?? 0)
            let date = resources?.contentModificationDate ?? Date.distantPast
            totalSize += size
            fileInfos.append((url: file, size: size, date: date))
        }

        guard totalSize > Self.maxDiskCacheBytes else { return }

        fileInfos.sort { $0.date < $1.date }

        var remaining = totalSize
        for info in fileInfos {
            guard remaining > Self.maxDiskCacheBytes else { break }
            try? fileManager.removeItem(at: info.url)
            remaining -= info.size
        }
    }

    func preloadThumbnails(paths: [(path: String, crop: CropRect?)], size: CGFloat) {
        let obsolete = stateQueue.sync { () -> [Waiter] in
            let old = preheatWaiters
            preheatWaiters = []
            return old
        }
        obsolete.forEach { $0.resolve(nil) }
        let items = paths
            .filter { !$0.path.isEmpty && getCached(Self.cacheKey(path: $0.path, size: size, crop: $0.crop)) == nil }
            .prefix(80)

        for item in items {
            let waiter = Waiter()
            waiter.setCompletion { _ in }
            stateQueue.sync { preheatWaiters.append(waiter) }
            enqueue(path: item.path, id: Self.cacheKey(path: item.path, size: size, crop: item.crop),
                    size: size, crop: item.crop, waiter: waiter, preheat: true)
        }
    }

    private func produceThumbnail(path: String, id: String, size: CGFloat, crop: CropRect?,
                                  generation requestGeneration: Int) {
        guard begin(id: id, generation: requestGeneration) else { return }
        generationSemaphore.wait()
        defer { generationSemaphore.signal() }

        guard isCurrentGeneration(requestGeneration) else {
            return
        }

        guard hasActiveWaiters(id: id, generation: requestGeneration) else {
            _ = finish(id: id, generation: requestGeneration)
            return
        }

        let ext = (path as NSString).pathExtension.lowercased()
        let videoExtensions: Set<String> = ["mov", "mp4", "avi"]
        var shouldPersist = false

        var image = loadFromDiskCache(id: id)
        if image == nil {
            if let crop {
                // ImageIO's limit applies before cropping. Account for a small crop's
                // fraction of the source so the final card still has enough pixels.
                let fraction = max(0.001, min(crop.normalized.width, crop.normalized.height))
                let maxPixels = Int((size * 2 / fraction).rounded(.up))
                if let cgImage = try? CropImageService.image(path: path, crop: crop, maxPixelSize: maxPixels) {
                    image = NSImage(cgImage: cgImage,
                                    size: NSSize(width: cgImage.width, height: cgImage.height))
                }
            } else if videoExtensions.contains(ext) {
                image = Self.createVideoThumbnail(path: path, maxSize: size)
            } else {
                image = Self.createThumbnail(path: path, maxSize: size)
            }
            shouldPersist = image != nil
        }

        if let image, isCurrentGeneration(requestGeneration), hasActiveWaiters(id: id, generation: requestGeneration) {
            cache.setObject(image, forKey: id as NSString, cost: Self.cost(for: image))
        }

        let waiters = finish(id: id, generation: requestGeneration)
        let delivered = isCurrentGeneration(requestGeneration) ? image : nil
        waiters.forEach { $0.resolve(delivered) }

        // Display immediately; JPEG encoding and disk I/O are outside the visible request path.
        if shouldPersist, let image, !waiters.isEmpty, isCurrentGeneration(requestGeneration) {
            diskWriteQueue.async { [weak self] in
                self?.saveToDiskCache(image: image, id: id)
            }
        }
    }

    private func begin(id: String, generation requestGeneration: Int) -> Bool {
        stateQueue.sync {
            guard var pending = inProgress[id], pending.generation == requestGeneration,
                  !pending.started else { return false }
            guard pending.waiters.contains(where: \.isActive) else {
                inProgress.removeValue(forKey: id)
                return false
            }
            pending.started = true
            inProgress[id] = pending
            return true
        }
    }

    private func hasActiveWaiters(id: String, generation requestGeneration: Int) -> Bool {
        stateQueue.sync {
            guard let pending = inProgress[id], pending.generation == requestGeneration else { return false }
            return pending.waiters.contains(where: \.isActive)
        }
    }

    private func isCurrentGeneration(_ requestGeneration: Int) -> Bool {
        stateQueue.sync {
            generation == requestGeneration
        }
    }

    private func finish(id: String, generation requestGeneration: Int) -> [Waiter] {
        stateQueue.sync {
            guard inProgress[id]?.generation == requestGeneration else {
                return []
            }
            return inProgress.removeValue(forKey: id)?.waiters ?? []
        }
    }

    private func loadFromDiskCache(id: String) -> NSImage? {
        let url = cacheFileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }

        let imageOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, imageOptions as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func saveToDiskCache(image: NSImage, id: String) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let url = cacheFileURL(for: id)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.82
        ]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private func cacheFileURL(for id: String) -> URL {
        let digest = SHA256.hash(data: Data(id.utf8))
        var name = ""
        name.reserveCapacity(64)
        for byte in digest {
            let hi = Int(byte >> 4)
            let lo = Int(byte & 0x0F)
            name.append(Self.hexLookup[hi])
            name.append(Self.hexLookup[lo])
        }
        return diskCacheDir.appendingPathComponent("\(name).jpg")
    }

    private static let hexLookup: [Character] = Array("0123456789abcdef")

    private static func cost(for image: NSImage) -> Int {
        if let representation = image.representations.first {
            return representation.pixelsWide * representation.pixelsHigh * 4
        }
        return Int(image.size.width * image.size.height * 4)
    }

    private static func createThumbnail(path: String, maxSize: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]

        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }

        let pixelSize = max(64, Int(maxSize * 2.0))
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func createVideoThumbnail(path: String, maxSize: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize * 2, height: maxSize * 2)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        // Try 0.5s first, then fallback to 0s (first frame)
        let times = [
            CMTime(seconds: 0.5, preferredTimescale: 600),
            CMTime(seconds: 0, preferredTimescale: 600)
        ]

        for time in times {
            do {
                var actualTime = CMTime.zero
                let cgImage = try generator.copyCGImage(at: time, actualTime: &actualTime)
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            } catch {
                continue
            }
        }

        // Last resort: use QuickLook thumbnail
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: Int(maxSize * 2),
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        return nil
    }
}
