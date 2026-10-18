import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
enum PreviewNavigationSmoke {
    @MainActor
    static func eventually(_ predicate: () -> Bool, file: StaticString = #file, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for preview", file: file, line: line)
    }

    static func writeJPEG(_ url: URL, width: Int, color: NSColor) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: width, height: 2000, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: 2000))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
    }

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let domain = "SwiftCull.PreviewNavigation.\(UUID())"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set("all", forKey: "photoGroupingMode")
        let store = PhotoStore(ratingService: RatingService(defaults: defaults),
                               dateIndex: PhotoDateIndex(directory: root.appendingPathComponent("cache")))
        store.sourcePath = root.path
        store.filterOptions.sortAscending = true
        let host = NSHostingView(rootView: PhotoBrowserView().environmentObject(store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 1000, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)

        Task { @MainActor in
            let colors: [NSColor] = [.red, .green, .blue, .orange]
            for i in 0..<4 {
                try! writeJPEG(root.appendingPathComponent("photo-\(i).jpg"), width: 3000 + i * 100, color: colors[i])
            }
            await store.loadPhotos()
            try! await Task.sleep(for: .milliseconds(200))
            store.selectPhoto(store.filteredPhotos[1])
            store.toggleSinglePreview()
            try! await eventually { (zoom(in: host)?.photoView.image?.size.width ?? 0) > 960 }
            let viewport = zoom(in: host)!
            let firstFull = viewport.photoView.image!
            let secondPhoto = store.filteredPhotos[2]
            let service = ThumbnailService.shared
            try! await eventually { service.getCached(ThumbnailService.inspectorCacheKey(for: secondPhoto)) != nil }
            let warm = service.getCached(ThumbnailService.inspectorCacheKey(for: secondPhoto))!
            let start = ProcessInfo.processInfo.systemUptime
            store.navigateToNext()
            try! await eventually { viewport.photoView.image != nil && viewport.photoView.image !== firstFull }
            precondition(viewport.photoView.image === warm || (viewport.photoView.image?.size.width ?? 0) > 960,
                         "A new selection must use its own warm or screen-sized preview")
            let firstMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            try! await eventually { (viewport.photoView.image?.size.width ?? 0) > 960 }
            store.navigateToPrevious()
            try! await eventually { viewport.photoView.image === firstFull }

            // Reusing an original still resets zoom, and superseded tasks must not
            // replace the final image after several rapid direction changes.
            viewport.zoom(to: 3, animated: false)
            store.navigateToNext()
            try! await Task.sleep(for: .milliseconds(15))
            store.navigateToNext()
            try! await Task.sleep(for: .milliseconds(15))
            store.navigateToPrevious()
            store.navigateToPrevious()
            try! await eventually { viewport.photoView.image === firstFull }
            try! await Task.sleep(for: .milliseconds(300))
            precondition(viewport.photoView.image === firstFull && abs(viewport.magnification - 1) < 0.001)
            precondition(!store.captureDatesReady, "Preview navigation must not start the full-library date index")

            // A retained, hidden grid must not start decoding newly mounted cards.
            let key = ThumbnailService.cacheKey(path: secondPhoto.primaryFilePath, size: 512)
            precondition(service.getCached(key) == nil)
            let thumbnail = NSHostingView(rootView:
                AsyncThumbnailView(photoId: secondPhoto.id, imagePath: secondPhoto.primaryFilePath, size: 512)
                    .environment(\.gridThumbnailLoadingEnabled, false))
            window.contentView = thumbnail
            try! await Task.sleep(for: .milliseconds(250))
            precondition(service.getCached(key) == nil, "Hidden grid started an image decode")
            thumbnail.rootView = AsyncThumbnailView(photoId: secondPhoto.id, imagePath: secondPhoto.primaryFilePath, size: 512)
                .environment(\.gridThumbnailLoadingEnabled, true)
            try! await eventually { service.getCached(key) != nil }
            service.preloadInspectorThumbnails(photos: [])
            print(String(format: "Preview navigation passed: adjacent preview warmup (first image %.1fms), screen-size preview reuse, rapid direction changes, zoom reset, hidden grid suspended/restored, no global metadata scan", firstMS))
            window.orderOut(nil)
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
            exit(0)
        }
        app.run()
    }

    @MainActor
    static func zoom(in view: NSView) -> PhotoZoomScrollView? {
        if let viewport = view as? PhotoZoomScrollView { return viewport }
        return view.subviews.lazy.compactMap { zoom(in: $0) }.first
    }
}
