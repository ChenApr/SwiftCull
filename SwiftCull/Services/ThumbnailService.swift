import Foundation
import AppKit
import AVFoundation
import CryptoKit
import ImageIO

final class ThumbnailService: @unchecked Sendable {
    static let shared = ThumbnailService()

    // The inspector is at most 460pt wide; 960 pixels cover a Retina display.
    static let inspectorPixelSize = 960

    static func inspectorCacheKey(for photo: PhotoEntry) -> String {
        "inspector-v1|\(photo.primaryFilePath)|\(photo.modificationDate.timeIntervalSince1970)|\(String(describing: photo.cropRect))"
    }

    private enum RenderMode {
        case grid, inspector
    }

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
    private let inspectorQueue = DispatchQueue(label: "com.swiftcull.preview.work", qos: .userInitiated, attributes: .concurrent)
    private let inspectorPreheatQueue = DispatchQueue(label: "com.swiftcull.preview.preheat", qos: .utility, attributes: .concurrent)
    private let diskWriteQueue = DispatchQueue(label: "com.swiftcull.thumbnail.disk", qos: .utility)
    private let stateQueue = DispatchQueue(label: "com.swiftcull.thumbnail.state")
    private let generationSemaphore = DispatchSemaphore(value: 4)
    private let inspectorSemaphore = DispatchSemaphore(value: 2)
    private var inProgress: [String: PendingRequest] = [:]
    private var preheatWaiters: [String: Waiter] = [:]
    private var inspectorPreheatWaiters: [String: Waiter] = [:]
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
        await thumbnail(path: path, id: id, size: size, crop: crop, mode: .grid)
    }

    func inspectorThumbnail(for photo: PhotoEntry) async -> NSImage? {
        await thumbnail(path: photo.primaryFilePath, id: Self.inspectorCacheKey(for: photo),
                        size: CGFloat(Self.inspectorPixelSize) / 2, crop: photo.cropRect, mode: .inspector)
    }

    private func thumbnail(path: String, id: String, size: CGFloat, crop: CropRect?,
                           mode: RenderMode) async -> NSImage? {
        guard !Task.isCancelled, !path.isEmpty else { return nil }
        if let cached = getCached(id) {
            return cached
        }

        let waiter = Waiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.setCompletion { image in continuation.resume(returning: image) }
                enqueue(path: path, id: id, size: size, crop: crop, waiter: waiter, preheat: false, mode: mode)
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
                         preheat: Bool, mode: RenderMode = .grid) {
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
        let queue = mode == .inspector
            ? (preheat ? inspectorPreheatQueue : inspectorQueue)
            : (preheat ? preheatQueue : workQueue)
        queue.async { [weak self] in
            self?.produceThumbnail(path: path, id: id, size: size, crop: crop,
                                   generation: generationForRequest, mode: mode)
        }
    }

    func cancelPending() {
        let waiters = stateQueue.sync { () -> [Waiter] in
            generation += 1
            let waiters = inProgress.values.flatMap(\.waiters)
            inProgress.removeAll()
            preheatWaiters.removeAll()
            inspectorPreheatWaiters.removeAll()
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
        let items = paths
            .filter { !$0.path.isEmpty && getCached(Self.cacheKey(path: $0.path, size: size, crop: $0.crop)) == nil }
            .prefix(80)
        let keyedItems = items.map { (id: Self.cacheKey(path: $0.path, size: size, crop: $0.crop),
                                       path: $0.path, crop: $0.crop) }
        preload(keyedItems, size: size, mode: .grid)
    }

    /// Keep only a few adjacent fit previews warm; never predecode their originals.
    func preloadInspectorThumbnails(photos: [PhotoEntry]) {
        let items = photos.prefix(3).filter {
            !$0.primaryFilePath.isEmpty && getCached(Self.inspectorCacheKey(for: $0)) == nil
        }.map { (id: Self.inspectorCacheKey(for: $0), path: $0.primaryFilePath, crop: $0.cropRect) }
        preload(items, size: CGFloat(Self.inspectorPixelSize) / 2, mode: .inspector)
    }

    private func preload(_ keyedItems: [(id: String, path: String, crop: CropRect?)],
                         size: CGFloat, mode: RenderMode) {
        let desired = Set(keyedItems.map(\.id))
        let changes = stateQueue.sync { () -> (obsolete: [Waiter], additions: [(String, String, CropRect?, Waiter)]) in
            var waiters = mode == .inspector ? inspectorPreheatWaiters : preheatWaiters
            let obsolete = waiters.filter { !desired.contains($0.key) }.map(\.value)
            waiters = waiters.filter { desired.contains($0.key) }
            var additions: [(String, String, CropRect?, Waiter)] = []
            for item in keyedItems where waiters[item.id]?.isActive != true {
                let waiter = Waiter()
                waiters[item.id] = waiter
                additions.append((item.id, item.path, item.crop, waiter))
            }
            if mode == .inspector { inspectorPreheatWaiters = waiters }
            else { preheatWaiters = waiters }
            return (obsolete, additions)
        }
        // Keep requests in the overlap of successive windows. Preheating has no
        // UI callback, so completion/cancellation does not schedule main-actor work.
        changes.obsolete.forEach { $0.resolve(nil) }
        for (id, path, crop, waiter) in changes.additions {
            enqueue(path: path, id: id, size: size, crop: crop, waiter: waiter, preheat: true, mode: mode)
        }
    }

    private func produceThumbnail(path: String, id: String, size: CGFloat, crop: CropRect?,
                                  generation requestGeneration: Int, mode: RenderMode) {
        guard begin(id: id, generation: requestGeneration) else { return }
        let semaphore = mode == .inspector ? inspectorSemaphore : generationSemaphore
        semaphore.wait()
        defer { semaphore.signal() }

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

        // Cropped renders may have been written by an earlier build as JPEGs.
        // Never read those files back: decode the source crop again so a lossy
        // cache entry cannot become the visible or exported image.
        var image = mode == .grid && crop == nil ? loadFromDiskCache(id: id) : nil
        if image == nil {
            if mode == .inspector {
                image = autoreleasepool {
                    videoExtensions.contains(ext)
                        ? Self.createVideoThumbnail(path: path, maxSize: size)
                        : Self.createInspectorThumbnail(path: path, crop: crop)
                }
            } else if let crop {
                image = autoreleasepool {
                    // Cards fill a square. Decode that visible center at the same
                    // 3x fidelity, then release the larger source/crop backing store.
                    Self.createCroppedThumbnail(path: path, crop: crop,
                                                maxPixelSize: Int((size * 3).rounded(.up)), fillsSquare: true)
                }
            } else if videoExtensions.contains(ext) {
                image = Self.createVideoThumbnail(path: path, maxSize: size)
            } else {
                image = Self.createThumbnail(path: path, maxSize: size)
            }
            // Cropped renders are kept in memory for the current request. Do
            // not persist them as JPEGs: that introduces an avoidable lossy
            // round trip for a render that may be used for export or preview.
            // Uncropped grid thumbnails retain the bounded disk cache.
            shouldPersist = image != nil && crop == nil && mode == .grid
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

    /// Decode only enough source pixels for the visible crop, then draw into a
    /// compact buffer so CGImage.cropping cannot retain a large source bitmap.
    private static func createInspectorThumbnail(path: String, crop: CropRect?) -> NSImage? {
        createCroppedThumbnail(path: path, crop: crop, maxPixelSize: inspectorPixelSize)
    }

    private static func createCroppedThumbnail(path: String, crop: CropRect?, maxPixelSize: Int,
                                               fillsSquare: Bool = false) -> NSImage? {
        guard let dimensions = try? CropImageService.orientedDimensions(path: path) else { return nil }
        let sourceEdge = Double(max(dimensions.width, dimensions.height))
        let normalized = crop?.normalized ?? .full
        let visibleWidth = Double(dimensions.width) * normalized.width
        let visibleHeight = Double(dimensions.height) * normalized.height
        let visibleEdge = fillsSquare ? min(visibleWidth, visibleHeight) : max(visibleWidth, visibleHeight)
        guard visibleEdge > 0 else { return nil }
        let decodeSize = Int(min(sourceEdge, (Double(maxPixelSize) * sourceEdge / visibleEdge).rounded(.up)))
        guard let decoded = try? CropImageService.image(path: path, crop: normalized, maxPixelSize: decodeSize) else {
            return nil
        }
        let rendered: CGImage
        if fillsSquare {
            let edge = min(decoded.width, decoded.height)
            let rect = CGRect(x: (decoded.width - edge) / 2, y: (decoded.height - edge) / 2,
                              width: edge, height: edge)
            guard let square = decoded.cropping(to: rect) else { return nil }
            rendered = square
        } else {
            rendered = decoded
        }
        let scale = min(1, Double(maxPixelSize) / Double(max(rendered.width, rendered.height)))
        let width = max(1, Int((Double(rendered.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(rendered.height) * scale).rounded(.down)))
        let colorSpace = decoded.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
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
