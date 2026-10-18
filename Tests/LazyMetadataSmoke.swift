import AppKit
import ImageIO
import UniformTypeIdentifiers

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

@main
struct LazyMetadataSmoke {
    @MainActor
    static func eventually(_ predicate: () -> Bool, file: StaticString = #file, line: UInt = #line) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for metadata", file: file, line: line)
    }

    static func writeJPEG(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05",
            kCGImagePropertyExifLensModel: "Test lens"
        ]]
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
    }

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SwiftCull-LazyMetadata-\(UUID())")
        let domain = "SwiftCull.LazyMetadata.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? fm.removeItem(at: root) }
        setenv("SWIFTCULL_CROPS_DIRECTORY", root.appendingPathComponent("crops").path, 1)
        let folder = root.appendingPathComponent("photos")
        let count = 130
        for i in 0..<count { try writeJPEG(folder.appendingPathComponent(String(format: "%03d.jpg", i))) }
        let scanned = await FileService.shared.scanFilesFast(at: folder.path)
        let tags = TagService.shared
        precondition(tags.setTagsForPhotoPair(["Existing"], photo: scanned[0]))
        precondition(tags.setTagsForPhotoPair(["HiddenTag"], photo: scanned[count - 1]))
        let counter = ReadCounter()
        let cache = root.appendingPathComponent("date-cache")
        let reader: @Sendable (PhotoEntry) -> Date? = { photo in
            counter.increment()
            Thread.sleep(forTimeInterval: 0.002)
            return Date(timeIntervalSince1970: 1_600_000_000 + Double(photo.baseName)! * 86400)
        }
        let index = PhotoDateIndex(directory: cache, readDate: reader)
        let ratings = RatingService(defaults: defaults)
        let metadata = ProjectMetadataService(saveDelay: 60)
        let store = PhotoStore(ratingService: ratings, projectMetadata: metadata, dateIndex: index)
        store.sourcePath = folder.path
        let start = Date()
        await store.loadPhotos()
        let initialSeconds = Date().timeIntervalSince(start)
        precondition(store.photos.count == count && !store.isEnriching && !store.captureDatesReady)
        precondition(counter.value == 0 && store.photos.allSatisfy { !store.areTagsLoaded(for: $0) })
        let order = store.filteredPhotos.map(\.id)
        store.photoDidAppear(store.photos.first { $0.id == "000" }!)
        store.selectPhoto(store.photos.first { $0.id == "001" }!)
        try await eventually { store.areTagsLoaded(for: store.photos.first { $0.id == "001" }!) }
        precondition(store.photos.filter { store.areTagsLoaded(for: $0) }.count == 2)
        precondition(store.photos.first { $0.id == "000" }!.tags == ["Existing"])
        precondition(counter.value == 0 && store.filteredPhotos.map(\.id) == order)
        let selected = store.selectedPhoto!
        let details = await PhotoExifCache.shared.info(for: selected.primaryImagePath, fallbackDate: selected.fileDate)
        precondition(details?.lens == "Test lens")

        // Unread tags must survive additive edits. Confirm waits for pending baseline reads.
        let unread = store.photos.first { $0.id == "129" }!
        store.enterSelectMode()
        store.selectPhotoIds([unread.id])
        store.batchAddTag("Added")
        store.confirmSelectMode()
        try await eventually { !store.isSelectMode && store.photos.first { $0.id == unread.id }!.tags.contains("Added") }
        store.flushPendingWrites()
        precondition(Set(tags.getTagsForPhotoPair(unread)) == ["HiddenTag", "Added"])

        // Cancelling before the asynchronous baseline arrives must discard the edit.
        let cancelPhoto = store.photos.first { $0.id == "128" }!
        store.enterSelectMode()
        store.selectPhotoIds([cancelPhoto.id])
        store.batchAddTag("Cancelled")
        store.cancelSelectMode()
        store.flushPendingWrites()
        precondition(!store.photos.first { $0.id == cancelPhoto.id }!.tags.contains("Cancelled"))
        precondition(tags.getTagsForPhotoPair(cancelPhoto).isEmpty)

        // Rating-only rollback must preserve tags loaded during the selection session.
        store.enterSelectMode()
        let original = store.photos.first { $0.id == "000" }!
        store.selectPhotoIds([original.id])
        store.batchSetRating(4)
        store.cancelSelectMode()
        precondition(store.photos.first { $0.id == "000" }!.tags == ["Existing"])

        // A tag filter indexes all sources, including photos never displayed, without EXIF work.
        store.filterOptions.tagFilter = "HiddenTag"
        store.applyFilters()
        precondition(store.isEnriching && store.filteredPhotos.count == count)
        try await eventually { !store.isEnriching }
        precondition(store.filteredPhotos.map(\.id) == [unread.id] && counter.value == 0)
        store.filterOptions.tagFilter = nil
        store.filterOptions.sortOption = .date
        store.filterOptions.dateFilterEnabled = true
        store.filterOptions.startDate = Date(timeIntervalSince1970: 1_600_000_000 + 128 * 86400)
        store.applyFilters()
        precondition(store.filteredPhotos.map(\.id) == order, "Preserve order until the complete date index is ready")
        precondition(store.filteredPhotos.count == count, "Do not filter with placeholder file dates")
        try await eventually { store.captureDatesReady && !store.isEnriching }
        precondition(counter.value == count && store.filteredPhotos.map(\.id) == ["129", "128"])
        precondition(store.selectedPhoto == nil)

        // A fresh service uses persistent cache; changed files invalidate only their own record.
        let reloaded = PhotoStore(ratingService: ratings, projectMetadata: metadata,
                                  dateIndex: PhotoDateIndex(directory: cache, readDate: reader))
        reloaded.sourcePath = folder.path
        reloaded.filterOptions.sortOption = .date
        await reloaded.loadPhotos()
        try await eventually { reloaded.captureDatesReady }
        precondition(counter.value == count, "Unchanged photos must use the disk index")
        let changed = folder.appendingPathComponent("000.jpg")
        var data = try Data(contentsOf: changed)
        data.append(0)
        try data.write(to: changed)
        await reloaded.loadPhotos()
        try await eventually { reloaded.captureDatesReady }
        precondition(counter.value == count + 1)

        // Changing demand mid-read must not apply a stale index or reorder the grid.
        let cancelStore = PhotoStore(ratingService: ratings, projectMetadata: metadata,
                                    dateIndex: PhotoDateIndex(directory: root.appendingPathComponent("cancel-cache"), readDate: reader))
        cancelStore.sourcePath = folder.path
        await cancelStore.loadPhotos()
        cancelStore.filterOptions.sortOption = .date
        cancelStore.applyFilters()
        try await eventually { counter.value > count + 1 }
        cancelStore.filterOptions.sortOption = .name
        cancelStore.applyFilters()
        let stableOrder = cancelStore.filteredPhotos.map(\.id)
        try await Task.sleep(for: .milliseconds(250))
        precondition(!cancelStore.captureDatesReady && !cancelStore.isEnriching)
        precondition(cancelStore.filteredPhotos.map(\.id) == stableOrder)
        cancelStore.setDateGroupingEnabled(true)
        try await eventually { cancelStore.captureDatesReady }
        precondition(cancelStore.filteredPhotos.map(\.id) == stableOrder)

        // Switch folders while a date read is in flight; old results must never
        // mark the new folder ready or overwrite its same-name photo.
        let switchingCounter = ReadCounter()
        let switchingReader: @Sendable (PhotoEntry) -> Date? = { photo in
            switchingCounter.increment()
            Thread.sleep(forTimeInterval: 0.002)
            return Date(timeIntervalSince1970: photo.jpgPath!.contains("/other/") ? 42 : 24)
        }
        let switching = PhotoStore(ratingService: ratings, projectMetadata: metadata,
                                  dateIndex: PhotoDateIndex(directory: root.appendingPathComponent("switch-cache"), readDate: switchingReader))
        switching.sourcePath = folder.path
        switching.filterOptions.sortOption = .date
        await switching.loadPhotos()
        try await eventually { switchingCounter.value > 0 }
        let other = root.appendingPathComponent("other")
        try writeJPEG(other.appendingPathComponent("000.jpg"))
        switching.sourcePath = other.path
        await switching.loadPhotos()
        try await eventually { switching.captureDatesReady }
        precondition(switching.photos.count == 1 && switching.photos[0].jpgPath!.contains("/other/"))
        precondition(switching.photos[0].fileDate == Date(timeIntervalSince1970: 42))
        print(String(format: "Lazy metadata passed: %d photos, initial load %.3fs with 0 date reads; visible/selected tags, deferred edits/confirm/cancel, complete filters, persistent cache/invalidation, cancellation and grouping", count, initialSeconds))

        // Optional read-only measurement against a real photo folder. All caches/ratings are isolated.
        if let path = ProcessInfo.processInfo.environment["SWIFTCULL_METADATA_BENCHMARK"] {
            let measured = PhotoStore(ratingService: ratings, projectMetadata: metadata,
                                      dateIndex: PhotoDateIndex(directory: root.appendingPathComponent("benchmark-cache")))
            measured.sourcePath = path
            let opened = Date()
            await measured.loadPhotos()
            let first = Date().timeIntervalSince(opened)
            measured.filterOptions.sortOption = .date
            measured.applyFilters()
            _ = await measured.waitForCaptureDates()
            print(String(format: "Real folder read-only: %d sources, initial listing %.3fs, requested date indexing %.3fs (including 200ms thumbnail head start)", measured.photos.count, first, Date().timeIntervalSince(opened) - first))
        }
    }
}
