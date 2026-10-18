import AppKit
import SwiftUI

@main
struct PreviewReturnSmoke {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let domain = "SwiftCull.PreviewReturnSmoke.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(110, forKey: "photoGridSize")
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        let store = PhotoStore(ratingService: RatingService(defaults: defaults),
                               dateIndex: PhotoDateIndex(directory: cacheDirectory))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        store.photos = (0..<600).map { index in
            PhotoEntry(baseName: "photo-\(index)", jpgPath: nil, nefPath: nil, movPath: nil,
                       jpgFileSize: nil, nefFileSize: nil, movFileSize: nil,
                       fileDate: date.addingTimeInterval(Double(index) * 3600), modificationDate: date)
        }
        store.applyFilters()
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 1000, height: 740),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "SwiftCull preview return smoke"
        let host = NSHostingView(rootView: PhotoBrowserView()
            .environmentObject(store).defaultAppStorage(defaults))
        window.contentView = host
        window.orderFront(nil)

        Task { @MainActor in
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for grouping in [PhotoGroupingMode.all, .month, .day] {
                    defaults.set(grouping.rawValue, forKey: "photoGroupingMode")
                    try! await Task.sleep(for: .milliseconds(500))
                    if grouping != .all {
                        for _ in 0..<100 where !store.captureDatesReady {
                            try! await Task.sleep(for: .milliseconds(30))
                        }
                        precondition(store.captureDatesReady, "Date grouping must be ready before testing its layout")
                    }
                    guard let scroll = scrollView(in: host) else { fatalError("No grid scroll view") }
                    store.selectPhoto(store.filteredPhotos[300])
                    try! await Task.sleep(for: .milliseconds(600))
                    let originalOffset = scroll.contentView.bounds.origin
                    let originalViewport = scroll.contentView.bounds.size
                    precondition(originalOffset.y > 500, "Test must start deep in the grid")

                    // Native scrollTo can normalize the grid's 4pt content inset.
                    // Reject any row-sized movement or delayed jump, allowing that inset.
                    for _ in 0..<3 {
                        store.toggleSinglePreview()
                        try! await Task.sleep(for: .milliseconds(40))
                        precondition(scrollView(in: host) === scroll,
                                     "Entering preview must preserve the grid's native scroll view")
                        store.toggleSinglePreview()
                        // Check both the first rendered frames and the old 300ms restore boundary.
                        for delay in [16, 60, 350] {
                            try! await Task.sleep(for: .milliseconds(delay))
                            precondition(scrollView(in: host) === scroll,
                                         "Returning must reuse the grid instead of rebuilding at the top")
                            precondition(abs(scroll.contentView.bounds.origin.y - originalOffset.y) <= 4.01,
                                         "Returning must preserve position: \(appearance.rawValue)/\(grouping.rawValue), \(delay)ms, expected \(originalOffset), got \(scroll.contentView.bounds.origin), viewport \(originalViewport) -> \(scroll.contentView.bounds.size)")
                        }
                    }

                    store.toggleSinglePreview()
                    store.selectPhoto(store.filteredPhotos[420])
                    try! await Task.sleep(for: .milliseconds(150))
                    let navigatedOffset = scroll.contentView.bounds.origin
                    precondition(abs(navigatedOffset.y - originalOffset.y) <= 4.01,
                                 "The hidden grid must remain frozen during preview navigation")
                    store.toggleSinglePreview()
                    try! await Task.sleep(for: .milliseconds(16))
                    for _ in 0..<30 where abs(scroll.contentView.bounds.origin.y - originalOffset.y) < 100 {
                        try! await Task.sleep(for: .milliseconds(10))
                    }
                    precondition(abs(scroll.contentView.bounds.origin.y - originalOffset.y) > 100,
                                 "Returning must reveal the final preview selection")
                    let restored = scroll.contentView.bounds.origin
                    try! await Task.sleep(for: .milliseconds(350))
                    precondition(abs(scroll.contentView.bounds.origin.y - restored.y) < 1,
                                 "Restoring must not schedule a second delayed jump")
                    print("Preview return passed: \(appearance.rawValue), \(grouping.rawValue)")
                }
            }
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: cacheDirectory)
            window.orderOut(nil)
            print("Preview return smoke passed: retained grid, stable first frames, frozen preview, restored selection, light/dark, all/month/day")
            exit(0)
        }
        app.run()
    }

    @MainActor
    static func scrollView(in view: NSView) -> NSScrollView? {
        // The preview now owns a native zoom scroll view; locate the retained grid.
        if view is PhotoZoomScrollView { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
}
