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
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
            try! await Task.sleep(for: .milliseconds(30))
            precondition(store.isGridScrolling, "Native scroll bounds must pause nonessential metadata work")
            try! await Task.sleep(for: .milliseconds(220))
            precondition(!store.isGridScrolling, "Metadata work must resume after scroll momentum settles")
            scroll.contentView.scroll(to: .zero)
            try! await Task.sleep(for: .milliseconds(200))
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
            // Click a row away from the viewport center after scrolling. Selection
            // must open the inspector without moving that row under the pointer.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 650))
            scroll.reflectScrolledClipView(scroll.contentView)
            try! await Task.sleep(for: .milliseconds(150))
            let pointerOffset = scroll.contentView.bounds.origin.y
            await click(in: host, window: window, at: CGPoint(x: 35, y: 180))
            precondition(store.selectedPhoto != nil && store.isInspectorVisible)
            precondition(abs(scroll.contentView.bounds.origin.y - pointerOffset) < 1,
                         "Clicking a photo must preserve the current grid scroll position")
            let clickedID = store.selectedPhoto!.id
            store.navigateDown()
            try! await Task.sleep(for: .milliseconds(150))
            precondition(store.selectedPhoto?.id != clickedID)
            precondition(abs(scroll.contentView.bounds.origin.y - pointerOffset) > 1,
                         "Keyboard navigation must still reveal the selected row")
            store.toggleInspector()
            store.selectPhoto(nil)
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            try! await Task.sleep(for: .milliseconds(100))
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
            // ESC cancels edits and multi-selection while preserving an open inspector's focus.
            let focused = store.selectedPhoto!
            store.isInspectorVisible = true
            store.batchSetRating(5)
            let monitor = KeyboardShortcutHandler.setupMonitor(for: store)!
            window.makeFirstResponder(nil)
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                          isARepeat: false, keyCode: 53)!
            NSApp.postEvent(escape, atStart: false)
            try! await Task.sleep(for: .milliseconds(150))
            precondition(!store.isSelectMode && store.selectedPhotos.isEmpty, "ESC must exit multi-selection")
            precondition(store.isInspectorVisible && store.selectedPhoto?.id == focused.id,
                         "ESC must preserve the open inspector and current photo")
            precondition(store.selectedPhoto?.rating == focused.rating, "Inspector must show the rolled-back rating")
            store.isInspectorVisible = false
            store.enterSelectMode()
            store.selectPhotoIds([focused.id])
            NSApp.postEvent(escape, atStart: false)
            try! await Task.sleep(for: .milliseconds(150))
            precondition(!store.isSelectMode && !store.isInspectorVisible && store.selectedPhoto == nil,
                         "ESC must keep an already-hidden inspector hidden")
            store.selectPhoto(focused)
            let preview = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: "e", charactersIgnoringModifiers: "e",
                                           isARepeat: false, keyCode: 14)!
            NSApp.postEvent(preview, atStart: false)
            try! await Task.sleep(for: .milliseconds(100))
            precondition(store.viewMode == .single, "E must enter the single-photo preview")
            NSApp.postEvent(escape, atStart: false)
            try! await Task.sleep(for: .milliseconds(100))
            precondition(store.viewMode == .grid && store.selectedPhoto?.id == focused.id &&
                         store.selectedPhotos == [focused.id], "ESC must return from E preview without clearing selection")
            // Exiting preview must take priority over cancelling pending batch edits.
            store.enterSelectMode()
            store.selectPhotoIds([focused.id])
            store.batchSetRating(4)
            store.toggleSinglePreview()
            NSApp.postEvent(escape, atStart: false)
            try! await Task.sleep(for: .milliseconds(100))
            precondition(store.viewMode == .grid && store.isSelectMode && store.selectedPhoto?.rating == 4,
                         "ESC in preview must preserve pending batch edits")
            NSApp.postEvent(escape, atStart: false)
            try! await Task.sleep(for: .milliseconds(100))
            precondition(!store.isSelectMode, "A subsequent ESC in the grid must still cancel batch edits")
            NSEvent.removeMonitor(monitor)
            print("ESC preview return passed: E shortcut, retained selection, pending edits preserved until grid cancellation")
            print("ESC selection cancellation passed: sidebar visibility, retained focus and rating rollback")
            print("Grid interaction smoke passed: resized row navigation, click preserves scroll and opens inspector, keyboard reveals selection, drag keeps inspector hidden, grouped scrolling")
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
