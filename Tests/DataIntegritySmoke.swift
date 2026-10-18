import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
struct DataIntegritySmoke {
    @MainActor
    static func eventually(_ predicate: () -> Bool, file: StaticString = #file, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for file operation", file: file, line: line)
    }

    static func photo(_ folder: URL, name: String = "same", jpg: Bool = true,
                      raw: Bool = false, video: Bool = false) -> PhotoEntry {
        PhotoEntry(baseName: name,
                   jpgPath: jpg ? folder.appendingPathComponent(name + ".jpg").path : nil,
                   nefPath: raw ? folder.appendingPathComponent(name + ".nef").path : nil,
                   movPath: video ? folder.appendingPathComponent(name + ".mov").path : nil,
                   jpgFileSize: jpg ? 1 : nil, nefFileSize: raw ? 1 : nil, movFileSize: video ? 1 : nil,
                   fileDate: Date(timeIntervalSince1970: 1), modificationDate: Date(timeIntervalSince1970: 1))
    }

    static func writeJPEG(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(output))
    }

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SwiftCull-Integrity-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let domain = "SwiftCull.Integrity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? fm.removeItem(at: root)
        }
        setenv("SWIFTCULL_CROPS_DIRECTORY", root.appendingPathComponent("crops").path, 1)
        let ratings = RatingService(defaults: defaults)
        let metadata = ProjectMetadataService(saveDelay: 60)

        // Directory identity, sidecar migration and cleared-rating reloads.
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        try writeJPEG(a.appendingPathComponent("same.jpg"))
        try writeJPEG(b.appendingPathComponent("same.jpg"))
        defaults.set(5, forKey: "com.photofilter.rating.same")
        let store = PhotoStore(ratingService: ratings, projectMetadata: metadata)

        // Folder drops use the same loader as the picker, without losing the current
        // folder when a file, URL, missing path, or multiple folders are dropped.
        let aImagePath = try fm.contentsOfDirectory(at: a, includingPropertiesForKeys: nil).first!.path
        let bImagePath = try fm.contentsOfDirectory(at: b, includingPropertiesForKeys: nil).first!.path
        precondition(store.openFolder(from: [a]))
        try await eventually { !store.isLoading && !store.isEnriching && store.photos.first?.jpgPath == aImagePath }
        let package = root.appendingPathComponent("Example.app")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        for urls in [[], [a, b], [a.appendingPathComponent("same.jpg")],
                     [root.appendingPathComponent("missing")], [package],
                     [URL(string: "https://example.com/photos")!]] {
            precondition(!store.openFolder(from: urls))
            precondition(store.sourcePath == a.path && store.photos.count == 1)
            precondition(store.exportMessage != nil)
            store.exportMessage = nil
        }
        let unicodeFolder = root.appendingPathComponent("桌面照片 空格 #1")
        try writeJPEG(unicodeFolder.appendingPathComponent("same.jpg"))
        let unicodeImagePath = try fm.contentsOfDirectory(at: unicodeFolder, includingPropertiesForKeys: nil).first!.path
        precondition(store.openFolder(from: [unicodeFolder]))
        try await eventually { !store.isLoading && !store.isEnriching && store.photos.first?.jpgPath == unicodeImagePath }
        let emptyFolder = root.appendingPathComponent("Empty")
        try fm.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        precondition(store.openFolder(from: [emptyFolder]))
        try await eventually { !store.isLoading && !store.isEnriching && store.photos.isEmpty }
        precondition(store.errorMessage == nil)
        precondition(store.openFolder(from: [a]))
        precondition(store.openFolder(from: [b]))
        try await eventually { !store.isLoading && !store.isEnriching && store.photos.first?.jpgPath == bImagePath }
        precondition(store.sourcePath == b.path)
        print("Folder opening passed: valid/empty/Unicode folders, invalid drops preserve state, latest folder wins")

        store.sourcePath = a.path
        await store.loadPhotos()
        precondition(store.photos[0].rating == 0, "Ambiguous legacy keys must not contaminate a folder")
        store.setRating(5, for: store.photos[0])
        store.sourcePath = b.path
        await store.loadPhotos()
        precondition(store.photos[0].rating == 0, "A's rating leaked into B")
        precondition(fm.fileExists(atPath: a.appendingPathComponent(".swiftcull/metadata.json").path))
        store.setRating(3, for: store.photos[0])
        store.sourcePath = a.path
        await store.loadPhotos()
        precondition(store.photos[0].rating == 5)
        store.setRating(0, for: store.photos[0])
        await store.loadPhotos()
        precondition(store.photos[0].rating == 0)
        precondition(ratings.getRating(for: "same", folderPath: b.path) == 3)
        precondition(defaults.integer(forKey: "com.photofilter.rating.same") == 5, "Legacy data was removed")
        metadata.scheduleSave(entries: ["same": PhotoMetadata(rating: 4)], folderPath: a.path)
        await store.loadPhotos()
        precondition(store.photos[0].rating == 4)
        precondition(ratings.getRating(for: "same", folderPath: a.path) == 4)
        metadata.scheduleSave(entries: ["same": PhotoMetadata(rating: 0)], folderPath: a.path)
        await store.loadPhotos()
        precondition(store.photos[0].rating == 0, "An explicit sidecar zero must override stale defaults")
        precondition(ratings.getRating(for: "same", folderPath: a.appendingPathComponent("../A").path) == 0)

        // Independent debounce timers, latest-write wins, pending reads, shutdown flush and retry.
        let debounce = ProjectMetadataService(saveDelay: 0.03)
        debounce.scheduleSave(entries: ["same": PhotoMetadata(rating: 1)], folderPath: a.path)
        debounce.scheduleSave(entries: ["same": PhotoMetadata(rating: 2)], folderPath: a.path)
        debounce.scheduleSave(entries: ["same": PhotoMetadata(rating: 3)], folderPath: b.path)
        try await eventually {
            guard let data = try? Data(contentsOf: a.appendingPathComponent(".swiftcull/metadata.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = json["entries"] as? [String: [String: Int]] else { return false }
            return entries["same"]?["rating"] == 2 &&
                fm.fileExists(atPath: b.appendingPathComponent(".swiftcull/metadata.json").path)
        }
        precondition(debounce.load(from: b.path)["same"]?.rating == 3)
        metadata.scheduleSave(entries: ["same": PhotoMetadata(rating: 4)], folderPath: a.path)
        precondition(metadata.load(from: a.path)["same"]?.rating == 4)
        metadata.scheduleSave(entries: ["same": PhotoMetadata(rating: 5)], folderPath: b.path)
        store.flushPendingWrites()
        precondition(ProjectMetadataService().load(from: b.path)["same"]?.rating == 5)
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        metadata.scheduleSave(entries: ["retry": PhotoMetadata(rating: 2)], folderPath: blocked.path)
        precondition(!metadata.flush().isEmpty)
        precondition(metadata.load(from: blocked.path)["retry"]?.rating == 2)
        try fm.removeItem(at: blocked)
        precondition(metadata.flush().isEmpty)
        precondition(ProjectMetadataService().load(from: blocked.path)["retry"]?.rating == 2)

        // MOV-only and paired formats must all receive and clear the same real xattrs.
        let tags = TagService.shared
        let pair = photo(root, name: "tag-pair", raw: true, video: true)
        for path in pair.associatedFilePaths { try Data().write(to: URL(fileURLWithPath: path)) }
        let result = tags.writeTagsForPhotoPair(["IntegrityTag"], photo: pair)
        precondition(result.succeeded && result.attemptedCount == 3)
        for path in pair.associatedFilePaths { precondition(tags.getTags(for: path).contains("IntegrityTag")) }
        precondition(tags.setTagsForPhotoPair([], photo: pair))
        for path in pair.associatedFilePaths { precondition(tags.getTags(for: path).isEmpty) }
        let video = photo(root, name: "video", jpg: false, video: true)
        try Data().write(to: URL(fileURLWithPath: video.movPath!))
        precondition(tags.setTagsForPhotoPair(["VideoTag"], photo: video))
        precondition(tags.getTagsForPhotoPair(video) == ["VideoTag"])
        precondition(!tags.setTagsForPhotoPair([], photo: photo(root, name: "no-files", jpg: false)))
        let missing = photo(root, name: "missing")
        precondition(!tags.setTagsForPhotoPair(["ShouldFail"], photo: missing))
        let tagStore = PhotoStore(ratingService: ratings, projectMetadata: metadata)
        tagStore.photos = [missing]
        tagStore.applyFilters()
        tagStore.addTag("ShouldFail", to: missing)
        try await eventually { tagStore.exportMessage != nil }
        precondition(tagStore.photos[0].tags.isEmpty)

        // Failed delete: photo and virtual versions stay visible, with an actionable error.
        let denied = FileService { _ in throw CocoaError(.fileWriteNoPermission) }
        let failedStore = PhotoStore(fileService: denied, ratingService: ratings, projectMetadata: metadata)
        failedStore.sourcePath = a.path
        failedStore.photos = [photo(a)]
        failedStore.applyFilters()
        let crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.5)
        precondition(failedStore.saveCrop(crop, aspect: .free, for: failedStore.photos[0], createCopy: true, name: "Keep"))
        let originalCatalog = CropCatalog.load(folder: a.path)
        failedStore.requestDelete(failedStore.photos[0])
        failedStore.confirmDelete()
        // Repeated confirmation while the first operation is running must be harmless.
        failedStore.confirmDelete()
        try await eventually { !failedStore.isDeleting }
        precondition(failedStore.photos.allSatisfy { !$0.isDeleted })
        precondition(failedStore.filteredPhotos.count == 2)
        precondition(CropCatalog.load(folder: a.path) == originalCatalog)
        precondition(failedStore.exportMessage != nil)

        // Partial deletion must remove only successful paths and remain usable for retry.
        let partialFolder = root.appendingPathComponent("partial")
        let fakeTrash = root.appendingPathComponent("fake-trash")
        try fm.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        try writeJPEG(partialFolder.appendingPathComponent("same.jpg"))
        try Data().write(to: partialFolder.appendingPathComponent("same.nef"))
        let partialService = FileService { url in
            if url.pathExtension == "nef" { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: fakeTrash.appendingPathComponent(url.lastPathComponent))
        }
        let partialStore = PhotoStore(fileService: partialService, ratingService: ratings, projectMetadata: metadata)
        partialStore.sourcePath = partialFolder.path
        partialStore.photos = [photo(partialFolder, raw: true)]
        partialStore.applyFilters()
        precondition(partialStore.saveCrop(crop, aspect: .free, for: partialStore.photos[0], createCopy: true, name: "Partial"))
        partialStore.requestDeleteSelected()
        partialStore.confirmDelete()
        try await eventually { !partialStore.isDeleting }
        precondition(partialStore.photos.allSatisfy { !$0.isDeleted && $0.jpgPath == nil && $0.nefPath != nil })
        precondition(partialStore.selectedPhoto?.primaryFilePath.hasSuffix("same.nef") == true)
        precondition(partialStore.exportMessage != nil)
        precondition(CropCatalog.load(folder: partialFolder.path)["same"]?.count == 2)

        // A retry uses surviving paths only; restoring files also restores crop versions.
        let successful = FileService { url in
            try FileManager.default.moveItem(at: url, to: fakeTrash.appendingPathComponent(url.lastPathComponent))
        }
        let successStore = PhotoStore(fileService: successful, ratingService: ratings, projectMetadata: metadata)
        successStore.sourcePath = partialFolder.path
        await successStore.loadPhotos()
        successStore.requestDelete(successStore.photos[0])
        successStore.confirmDelete()
        try await eventually { !successStore.isDeleting }
        precondition(successStore.filteredPhotos.isEmpty && successStore.exportMessage == nil)
        precondition(successStore.selectedPhotos.isEmpty && successStore.selectedPhoto == nil)
        precondition(CropCatalog.load(folder: partialFolder.path)["same"]?.count == 2)
        for ext in ["jpg", "nef"] {
            let filename = "same." + ext
            try fm.moveItem(at: fakeTrash.appendingPathComponent(filename),
                            to: partialFolder.appendingPathComponent(filename))
        }
        await successStore.loadPhotos()
        precondition(successStore.photos.count == 2)
        precondition(successStore.photos.contains { $0.isVersionCopy && $0.cropRect == crop })

        // Delayed deletion in A must not mutate same-name photos after navigation to B.
        let slowFailure = FileService { _ in
            Thread.sleep(forTimeInterval: 0.15)
            throw CocoaError(.fileWriteNoPermission)
        }
        let switching = PhotoStore(fileService: slowFailure, ratingService: ratings, projectMetadata: metadata)
        switching.sourcePath = a.path
        await switching.loadPhotos()
        switching.requestDelete(switching.photos[0])
        switching.confirmDelete()
        switching.sourcePath = b.path
        await switching.loadPhotos()
        try await eventually { !switching.isDeleting }
        precondition(!switching.photos.isEmpty)
        precondition(switching.photos.allSatisfy {
            guard !$0.isDeleted, let path = $0.jpgPath else { return false }
            return URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath()
                == b.resolvingSymlinksInPath()
        }, "Old deletion results changed the newly loaded folder")
        precondition(metadata.flush().isEmpty)
        print("Data integrity smoke passed: scoped ratings, sidecar migration/zero, per-folder debounce/flush/retry, MOV/paired tags and failure UI, failed/partial/retried deletion, restored crops, folder-switch isolation")
    }
}
