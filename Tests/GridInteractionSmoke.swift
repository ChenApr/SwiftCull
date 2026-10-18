import AppKit
import SwiftUI

@main
struct GridInteractionSmoke {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let domain = "SwiftCull.GridSmoke.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        let store = PhotoStore(ratingService: RatingService(defaults: defaults))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        store.photos = (0..<200).map { index in
            PhotoEntry(baseName: "photo-\(index)", jpgPath: nil, nefPath: nil, movPath: nil,
                       jpgFileSize: nil, nefFileSize: nil, movFileSize: nil,
                       fileDate: date.addingTimeInterval(Double(index) * 3600), modificationDate: date)
        }
        store.applyFilters()
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 1000, height: 740),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "SwiftCull grid interaction smoke"
        let host = NSHostingView(rootView: grid(store: store, grouping: .all))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            try! await Task.sleep(for: .milliseconds(350))
            guard let scroll = scrollView(in: host) else { fatalError("No native scroll view") }
            for width: CGFloat in [1000, 947, 700] {
                window.setContentSize(NSSize(width: width, height: 740))
                try! await Task.sleep(for: .milliseconds(100))
                let columns = max(1, Int((scroll.contentView.bounds.width - 8 + 4) / 114))
                store.selectPhoto(store.filteredPhotos[0])
                store.navigateDown()
                precondition(store.selectedPhoto?.id == store.filteredPhotos[columns].id,
                             "Down must advance one actual grid row after resizing")
                store.navigateUp()
                precondition(store.selectedPhoto?.id == store.filteredPhotos[0].id)
            }

            window.setContentSize(NSSize(width: 1000, height: 740))
            store.selectPhoto(nil)
            scroll.contentView.scroll(to: .zero)
            try! await Task.sleep(for: .milliseconds(100))
            precondition(!store.isInspectorVisible, "Keyboard selection must not open the inspector")
            await click(in: host, window: window, at: CGPoint(x: 35, y: 35))
            precondition(store.isInspectorVisible, "An ordinary card click must open the inspector")
            store.toggleInspector()
            await click(in: host, window: window, at: CGPoint(x: 35, y: 35))
            precondition(store.isInspectorVisible, "Clicking the same photo must reopen a hidden inspector")
            store.toggleInspector()
            store.selectPhoto(nil)
            await drag(in: host, window: window, from: CGPoint(x: 35, y: 35), to: CGPoint(x: 400, y: 280))
            precondition(store.selectedPhotos.count >= 4, "Dragging must select cards after frame tracking starts")
            precondition(!store.isInspectorVisible, "Drag selection must not open the inspector")
            print("Ungrouped drag selected \(store.selectedPhotos.count) photos")

            store.selectPhoto(nil)
            store.isSelectMode = false
            host.rootView = grid(store: store, grouping: .day)
            try! await Task.sleep(for: .milliseconds(150))
            if let groupedScroll = scrollView(in: host) {
                groupedScroll.contentView.scroll(to: NSPoint(x: 0, y: 150))
                groupedScroll.reflectScrolledClipView(groupedScroll.contentView)
            }
            try! await Task.sleep(for: .milliseconds(100))
            await drag(in: host, window: window, from: CGPoint(x: 35, y: 100), to: CGPoint(x: 400, y: 450))
            precondition(!store.selectedPhotos.isEmpty, "Grouped drag must use current frames after scrolling")
            precondition(!store.isInspectorVisible, "Grouped drag selection must not open the inspector")
            print("Grid interaction smoke passed: resized row navigation, click opens inspector, drag keeps inspector hidden, grouped scrolling")
            defaults.removePersistentDomain(forName: domain)
            window.orderOut(nil)
            exit(0)
        }
        app.run()
    }

    @MainActor
    static func grid(store: PhotoStore, grouping: PhotoGroupingMode) -> some View {
        PhotoGridContent(store: store, gridSize: 110,
                         columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 4)],
                         groupingMode: grouping, isSelectMode: false, lastSelectedPhoto: .constant(nil))
    }

    @MainActor
    static func click(in host: NSView, window: NSWindow, at point: CGPoint) async {
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            window.sendEvent(event)
            try! await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    static func drag(in host: NSView, window: NSWindow, from start: CGPoint, to end: CGPoint) async {
        let points: [(NSEvent.EventType, CGPoint)] = [(.leftMouseDown, start),
            (.leftMouseDragged, CGPoint(x: start.x + 12, y: start.y + 12)),
            (.leftMouseDragged, end), (.leftMouseUp, end)]
        for (type, point) in points {
            let location = host.convert(point, to: nil)
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            window.sendEvent(event)
            try! await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor
    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
}
